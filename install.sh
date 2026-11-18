#!/usr/bin/env bash
# install.sh — install ssh-keepass-proxy on a stock Debian 13 + XFCE + GNOME
# workstation, per README.md. Run from the repo root.
#
# Usage: ./install.sh
#
# Idempotent: safe to re-run. Uses sudo only for the system-wide Xsession
# wrapper rename in Step 6 of the README.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$REPO_DIR/config"
SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
AUTOSTART_DIR="$HOME/.config/autostart"
KEEPASSXC_DROPIN_DIR="$SYSTEMD_USER_DIR/app-org.keepassxc.KeePassXC@autostart.service.d"
KEEPASSXC_INI="$HOME/.config/keepassxc/keepassxc.ini"
CACHE_INI="${XDG_CACHE_HOME:-$HOME/.cache}/keepassxc/keepassxc.ini"
ENV_D_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/environment.d"
DOCTOR="$REPO_DIR/config/ssh-keepass-doctor.sh"
DOCTOR_LOCK="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/ssh-keepass-doctor.lock"

UID_NUM="$(id -u)"
REAL_SOCK="/run/user/${UID_NUM}/keepassxc-ssh-agent.sock"
PROXY_SOCK="/run/user/${UID_NUM}/ssh-auth-proxy.sock"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

require() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }

require cargo
require systemctl
require ssh-agent
require flock
require xfconf-query

# Step 1. Build the proxy -----------------------------------------------------
log "Building the proxy (cargo build --release)"
cargo build --release --manifest-path "$REPO_DIR/Cargo.toml"
test -x "$REPO_DIR/target/release/ssh-keepass-proxy" || die "binary not found after build"

# Step 2. Install the systemd user units --------------------------------------
log "Installing systemd user units to $SYSTEMD_USER_DIR"
mkdir -p "$SYSTEMD_USER_DIR"
install -m 0644 "$CONFIG_DIR/systemd/user/keepassxc-ssh-agent.service" "$SYSTEMD_USER_DIR/"
install -m 0644 "$CONFIG_DIR/systemd/user/ssh-keepass-proxy.socket" "$SYSTEMD_USER_DIR/"
install -m 0644 "$CONFIG_DIR/systemd/user/ssh-keepass-proxy.service" "$SYSTEMD_USER_DIR/"
install -m 0644 "$CONFIG_DIR/systemd/user/ssh-keepass-doctor.service" "$SYSTEMD_USER_DIR/"
install -m 0644 "$CONFIG_DIR/systemd/user/ssh-keepass-doctor.timer" "$SYSTEMD_USER_DIR/"

# Step 3. Wrap the KeePassXC autostart Exec= line -----------------------------
log "Installing KeePassXC autostart .desktop to $AUTOSTART_DIR"
mkdir -p "$AUTOSTART_DIR"
# Substitute the user's uid into the templated .desktop file.
sed "s/__UID__/$UID_NUM/g" "$CONFIG_DIR/autostart/org.keepassxc.KeePassXC.desktop" \
  > "$AUTOSTART_DIR/org.keepassxc.KeePassXC.desktop"
chmod 0644 "$AUTOSTART_DIR/org.keepassxc.KeePassXC.desktop"

# Step 4. Install the KeePassXC ordering drop-in ------------------------------
log "Installing KeePassXC ordering drop-in to $KEEPASSXC_DROPIN_DIR"
mkdir -p "$KEEPASSXC_DROPIN_DIR"
install -m 0644 \
  "$CONFIG_DIR/systemd/user/app-org.keepassxc.KeePassXC@autostart.service.d/after-ssh-agent.conf" \
  "$KEEPASSXC_DROPIN_DIR/"

# Step 5. Mask the competing SSH agent providers ------------------------------
log "Masking competing SSH agent providers"
COMPETING=(
  gcr-ssh-agent.service gcr-ssh-agent.socket
  gnome-keyring-daemon.service gnome-keyring-daemon.socket
  gpg-agent-ssh.socket
  ssh-agent.socket
)
for unit in "${COMPETING[@]}"; do
  systemctl --user stop "$unit" 2>/dev/null || true
  systemctl --user mask "$unit" >/dev/null
done

# Step 6. Disable the Xsession ssh-agent wrapper -------------------------------
XSESSION_SRC="/etc/X11/Xsession.d/90x11-common_ssh-agent"
XSESSION_DISABLED="/etc/X11/Xsession.d/90x11-common_ssh-agent.disabled"
if [ -f "$XSESSION_SRC" ] && [ ! -L "$XSESSION_SRC" ]; then
  log "Disabling Xsession ssh-agent wrapper (requires sudo)"
  sudo mv "$XSESSION_SRC" "$XSESSION_DISABLED"
elif [ -f "$XSESSION_DISABLED" ]; then
  log "Xsession ssh-agent wrapper already disabled"
else
  warn "Xsession wrapper not found at $XSESSION_SRC and not previously disabled — skipping"
fi

# Step 7. Set SSH_AUTH_SOCK in the session ------------------------------------
log "Installing ~/.xsessionrc"
install -m 0755 "$CONFIG_DIR/xsessionrc" "$HOME/.xsessionrc"

log "Wiring SSH_AUTH_SOCK into ~/.zshrc"
ZSHRC="$HOME/.zshrc"
touch "$ZSHRC"
FRAGMENT_MARKER="# Use the ssh-keepass-proxy socket (unlock-prompts KeePassXC on demand)."
if ! grep -Fq "$FRAGMENT_MARKER" "$ZSHRC"; then
  printf '\n%s\nexport SSH_AUTH_SOCK="$XDG_RUNTIME_DIR/ssh-auth-proxy.sock"\n' \
    "$FRAGMENT_MARKER" >> "$ZSHRC"
  log "  added SSH_AUTH_SOCK line to $ZSHRC"
else
  log "  $ZSHRC already wires SSH_AUTH_SOCK; leaving it"
fi

# The systemd user manager builds its base environment from environment.d
# files at login, and unset-environment cannot remove a base value, so this
# file is what keeps the session-wide SSH_AUTH_SOCK pinned to the proxy socket.
log "Installing $ENV_D_DIR/ssh.conf (session-wide base SSH_AUTH_SOCK)"
mkdir -p "$ENV_D_DIR"
ENV_D_TMP="$(mktemp "$ENV_D_DIR/ssh.conf.XXXXXX")"
printf 'SSH_AUTH_SOCK=%s\n' "$PROXY_SOCK" > "$ENV_D_TMP"
chmod 0644 "$ENV_D_TMP"
mv "$ENV_D_TMP" "$ENV_D_DIR/ssh.conf"

# Hold the doctor lock while KeePassXC and agent-related steps run, so the
# watchdog does not interleave with the installer.
log "Acquiring the doctor lock $DOCTOR_LOCK"
exec 9>"$DOCTOR_LOCK"
flock 9

# Step 8. Configure KeePassXC -------------------------------------------------
log "Patching KeePassXC settings in $KEEPASSXC_INI"
mkdir -p "$(dirname "$KEEPASSXC_INI")"
touch "$KEEPASSXC_INI"

# Merge key=value into the [INI] section of FILE, creating the section if
# absent. Writes through a temp file and mv, never in place.
# Usage: ini_set <file> <section> <key> <value>
ini_set() {
  local file="$1" section="$2" key="$3" value="$4" tmp mode
  # The key matches in any section; the current key set has no collisions.
  mode="$(stat -c '%a' "$file")"
  tmp="$(mktemp "${file}.XXXXXX")"
  if grep -qE "^\s*${key}\s*=" "$file"; then
    # Replace existing key=value in place (preserves section it lives in).
    sed -E "s|^\s*${key}\s*=.*|${key}=${value}|" "$file" > "$tmp"
  elif grep -qE "^\[${section}\]" "$file"; then
    # Section exists; insert key right after the section header.
    awk -v sec="$section" -v kv="${key}=${value}" '
      $0 == "["sec"]" { print; print kv; next }
      { print }
    ' "$file" > "$tmp"
  else
    # Append a new section.
    cp "$file" "$tmp"
    printf '\n[%s]\n%s=%s\n' "$section" "$key" "$value" >> "$tmp"
  fi
  chmod "$mode" "$tmp"
  mv "$tmp" "$file"
}

ini_set "$KEEPASSXC_INI" SSHAgent Enabled true
ini_set "$KEEPASSXC_INI" FdoSecrets ConfirmAccessItem false
ini_set "$KEEPASSXC_INI" FdoSecrets Enabled true
ini_set "$KEEPASSXC_INI" Security LockDatabaseIdle true
ini_set "$KEEPASSXC_INI" Security LockDatabaseIdleSeconds 30
ini_set "$KEEPASSXC_INI" Security LockDatabaseScreenLock true

# Pin the agent socket in the local-cache ini. KeePassXC 2.7.x prefers this
# override over $SSH_AUTH_SOCK for the SSH agent connection, so a settings
# save can no longer retune KeePassXC to a competing agent. KeePassXC holds
# the file in memory and overwrites it on exit, so write only while it is not
# running.
if pgrep -x keepassxc >/dev/null 2>&1; then
  warn "KeePassXC is running; skipped writing the override into $CACHE_INI"
  warn "close KeePassXC and re-run install.sh, or set the SSH_AUTH_SOCK override field in the KeePassXC settings dialog (SSH Agent page)"
else
  mkdir -p "$(dirname "$CACHE_INI")"
  test -f "$CACHE_INI" || touch "$CACHE_INI"
  ini_set "$CACHE_INI" SSHAgent AuthSockOverride "$REAL_SOCK"
fi

# Step 9. Reload and enable units ---------------------------------------------
log "Reloading systemd user daemon and enabling units"
systemctl --user daemon-reload
systemctl --user enable --now keepassxc-ssh-agent.service
systemctl --user enable --now ssh-keepass-proxy.socket
systemctl --user enable --now ssh-keepass-doctor.timer
systemctl --user restart keepassxc-ssh-agent.service ssh-keepass-proxy.service

# Step 10. Disable the xfce4-session built-in SSH agent -----------------------
log "Disabling the xfce4-session built-in SSH agent (xfconf)"
xfconf-query -c xfce4-session -p /startup/ssh-agent/enabled -n -t bool -s false >/dev/null

# Step 11. Stop and remove stray and competing running SSH agents -------------
log "Purging stray and competing SSH agents (doctor --purge)"
# The installer holds the doctor lock for Steps 8–11; tell the child not to
# lock again, which would deadlock against this parent.
SSH_KEEPASS_DOCTOR_NO_LOCK=1 "$DOCTOR" --purge || warn "doctor --purge did not complete cleanly; see its output above (re-run install.sh after closing KeePassXC)"

flock -u 9

# Done -----------------------------------------------------------------------
log "Install complete. Next manual steps from README:"
echo "  - Step 8: confirm the SSH_AUTH_SOCK override field in the KeePassXC settings dialog (SSH Agent page)."
echo "  - Step 9: remove the on-disk private key files from ~/.ssh/ after the real agent holds all keys."
echo "  - Step 13: log out and back in, then run the verification block."
echo "  - Run $DOCTOR any time for a status check; use --fix or --purge for repairs."
