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

UID_NUM="$(id -u)"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

require() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }

require cargo
require systemctl
require ssh-agent

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

# Step 8. Configure KeePassXC -------------------------------------------------
log "Patching KeePassXC settings in $KEEPASSXC_INI"
mkdir -p "$(dirname "$KEEPASSXC_INI")"
touch "$KEEPASSXC_INI"

# Merge a key=value into an [INI] section, creating the section if absent.
# Usage: ini_set <section> <key> <value>
ini_set() {
  local section="$1" key="$2" value="$3" file="$KEEPASSXC_INI"
  local tmp
  tmp="$(mktemp)"
  # If the key exists anywhere, rewrite it; if the section exists, ensure the
  # key is set under it; otherwise append a new section.
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
  cat "$tmp" > "$file"
  rm -f "$tmp"
}

ini_set SSHAgent Enabled true
ini_set FdoSecrets ConfirmAccessItem false
ini_set FdoSecrets Enabled true
ini_set Security LockDatabaseIdle true
ini_set Security LockDatabaseIdleSeconds 30
ini_set Security LockDatabaseScreenLock true

# Step 9. Reload and enable units ---------------------------------------------
log "Reloading systemd user daemon and enabling units"
systemctl --user daemon-reload
systemctl --user enable --now keepassxc-ssh-agent.service
systemctl --user enable --now ssh-keepass-proxy.socket
systemctl --user restart keepassxc-ssh-agent.service ssh-keepass-proxy.service

# Done -----------------------------------------------------------------------
log "Install complete. Next manual steps from README:"
echo "  - Put your SSH keys into the KeePassXC database as SSH agent entries."
echo "  - After confirming KeePassXC holds all keys, remove on-disk private key files from ~/.ssh/ (Step 9 of README)."
echo "  - Log out and log back in, then run the verification block in Step 10 of the README."