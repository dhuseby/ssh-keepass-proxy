# ssh-keepass-proxy

A socket-activated SSH agent proxy. When an SSH client connects to the proxy socket, the proxy asks KeePassXC to unlock its database. KeePassXC shows the unlock dialog. After you unlock the database, KeePassXC loads its SSH keys into the real `ssh-agent`. The proxy then relays bytes between the SSH client and the real agent.

The only source of truth for SSH keys is KeePassXC. No on-disk private key files are used. No other SSH agent can start.

## Purpose

Stock Debian 13 with XFCE and GNOME starts more than one SSH agent. The Xsession wrapper starts `ssh-agent`. GNOME Keyring starts an SSH component. GCR starts an SSH agent wrapper. GnuPG can emulate an SSH agent. These agents compete for the `SSH_AUTH_SOCK` environment variable. They also read on-disk private key files.

This setup replaces all of them with one chain:

1. `keepassxc-ssh-agent.service` runs a plain `ssh-agent -D -a $XDG_RUNTIME_DIR/keepassxc-ssh-agent.sock`. This agent holds the keys that KeePassXC loads. No on-disk key file is read by it.
2. `ssh-keepass-proxy.socket` listens on `$XDG_RUNTIME_DIR/ssh-auth-proxy.sock`. systemd socket-activates `ssh-keepass-proxy.service` on the first connection.
3. `ssh-keepass-proxy.service` is the Rust binary in this repository. On each connection it checks whether the KeePassXC database is unlocked. If the database is locked, the proxy calls the `org.freedesktop.secrets` D-Bus interface to trigger the unlock prompt. When the database is unlocked, the proxy connects to the real agent socket and relays bytes in both directions until the SSH client disconnects.

Every SSH client reads `SSH_AUTH_SOCK` set to the proxy socket. No SSH client talks to the real agent directly.

## Architecture

### Data flow

```
SSH client  -->  ssh-auth-proxy.sock  -->  ssh-keepass-proxy
                                              |
                                              |  if KeePassXC database locked:
                                              |    gdbus call org.freedesktop.Secret.Service.Unlock
                                              |    -->  KeePassXC shows unlock dialog
                                              |    <--  database unlocked
                                              |
                                              v
                                      keepassxc-ssh-agent.sock
                                              |
                                              v
                                      ssh-agent -D  (holds keys loaded by KeePassXC)
```

### systemd user units

Three units live in `~/.config/systemd/user/`:

**`keepassxc-ssh-agent.service`** — runs the real agent.
```ini
[Unit]
Description=Real ssh-agent holding KeePassXC-loaded keys (ssh-keepass-proxy backend)
Documentation=man:ssh-agent(1)
PartOf=ssh-keepass-proxy.service

[Service]
Environment=SSH_AUTH_SOCK=%t/keepassxc-ssh-agent.sock
ExecStart=/usr/bin/ssh-agent -D -a %t/keepassxc-ssh-agent.sock
Restart=on-failure

[Install]
WantedBy=default.target
```

**`ssh-keepass-proxy.socket`** — the socket that SSH clients connect to.
```ini
[Unit]
Description=Socket for ssh-keepass-proxy (SSH agent proxy with KeePassXC unlock-on-demand)
Documentation=man:ssh-agent(1)

[Socket]
ListenStream=%t/ssh-auth-proxy.sock
SocketMode=0600
Accept=no

[Install]
WantedBy=sockets.target
```

**`ssh-keepass-proxy.service`** — the proxy binary, started by the socket.
```ini
[Unit]
Description=SSH agent proxy with KeePassXC unlock-on-demand
After=keepassxc-ssh-agent.service
Requires=keepassxc-ssh-agent.service

[Service]
Type=simple
ExecStart=%h/Projects/personal/ssh-keepass-proxy/target/release/ssh-keepass-proxy
Environment=RUST_LOG=info
# Socket-activated: systemd passes the listen socket as fd 3 (LISTEN_FDS=1).
StandardOutput=journal
StandardError=journal
Restart=on-failure
RestartSec=1

[Install]
WantedBy=default.target
```

### KeePassXC autostart Exec= wrapper (primary)

KeePassXC must talk to the real agent, not to the proxy. If KeePassXC used the proxy socket, the first key operation would trigger the proxy to ask KeePassXC to unlock itself. This makes a deadlock (see "Deadlock" under Installation).

KeePassXC starts via XDG autostart (launched by `xfce4-session`), not via the systemd `app-org.keepassxc.KeePassXC@autostart.service`. The autostart `.desktop` file is therefore the place that must set `SSH_AUTH_SOCK` to the real agent socket. The `Exec=` line is wrapped with `env`:

Path: `~/.config/autostart/org.keepassxc.KeePassXC.desktop`
```
Exec=env SSH_AUTH_SOCK=/run/user/<uid>/keepassxc-ssh-agent.sock keepassxc
```

`.desktop` files do not expand `$XDG_RUNTIME_DIR`, so the literal `/run/user/<uid>/` path is used. The proxy socket is only for SSH clients; KeePassXC never connects to it.

### KeePassXC ordering drop-in (redundant but harmless)

A systemd drop-in file also orders KeePassXC after `keepassxc-ssh-agent.service` and sets its `SSH_AUTH_SOCK` to the real agent socket. This drop-in is redundant: it only applies to the systemd `app-org.keepassxc.KeePassXC@autostart.service`, which does not start because KeePassXC is already running via XDG autostart ("Another instance is already running"). The drop-in is kept as a secondary measure in case KeePassXC is ever started via the systemd app- service instead of XDG autostart.

Path: `~/.config/systemd/user/app-org.keepassxc.KeePassXC@autostart.service.d/after-ssh-agent.conf`
```ini
[Unit]
After=keepassxc-ssh-agent.service
Requires=keepassxc-ssh-agent.service

[Service]
Environment=SSH_AUTH_SOCK=%t/keepassxc-ssh-agent.sock
```

### Environment wiring

Two files set `SSH_AUTH_SOCK` to the proxy socket:

`~/.xsessionrc` (sets the variable for the X session):
```sh
# Point the X session at the ssh-keepass-proxy socket, which unlock-prompts
# KeePassXC on demand and relays to the real ssh-agent.
# Pre-setting SSH_AUTH_SOCK also makes /etc/X11/Xsession.d/90x11-common_ssh-agent
# skip wrapping the session in its own (competing) ssh-agent.
if [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -S "$XDG_RUNTIME_DIR/ssh-auth-proxy.sock" -o -d "$XDG_RUNTIME_DIR" ]; then
  export SSH_AUTH_SOCK="$XDG_RUNTIME_DIR/ssh-auth-proxy.sock"
fi
```

`~/.zshrc` (sets the variable for each new shell):
```sh
# Use the ssh-keepass-proxy socket (unlock-prompts KeePassXC on demand).
export SSH_AUTH_SOCK="$XDG_RUNTIME_DIR/ssh-auth-proxy.sock"
```

### KeePassXC configuration

KeePassXC settings in `~/.config/keepassxc/keepassxc.ini`:
```ini
[SSHAgent]
Enabled=true

[FdoSecrets]
ConfirmAccessItem=false
Enabled=true

[Security]
LockDatabaseIdle=true
LockDatabaseIdleSeconds=30
LockDatabaseScreenLock=true
```

The `SSHAgent.Enabled` key makes KeePassXC load SSH keys into the agent on unlock. The `FdoSecrets.Enabled` key exposes the `org.freedesktop.secrets` D-Bus interface that the proxy calls. The `Security` section locks the database after 30 seconds idle and on screen lock. When the database locks, the keys stay in the agent until the next lock event KeePassXC applies. The proxy checks the database lock state, not the agent identity list, as the source of truth.

## How this differs from stock Debian 13 + XFCE4 + Gnome

| Stock provider | Stock behavior | This setup |
|---|---|---|
| `/etc/X11/Xsession.d/90x11-common_ssh-agent` | Wraps the X session in a new `ssh-agent` if `SSH_AUTH_SOCK` is empty. | Renamed to `.disabled`. Does not run. |
| `ssh-agent.socket` (systemd user unit) | Socket-activates `ssh-agent.service` on demand. | Masked (`/dev/null`). Cannot start. |
| `gcr-ssh-agent.service` + `.socket` | Socket-activates the GCR SSH agent wrapper. | Masked. Cannot start. |
| `gnome-keyring-daemon.service` + `.socket` | Socket-activates GNOME Keyring. The keyring runs an SSH component. | Masked. The keyring cannot start. KeePassXC `FdoSecrets` is the only secrets service. |
| `gpg-agent-ssh.socket` | Lets `gpg-agent` emulate an SSH agent. | Masked. The GnuPG SSH emulation cannot start. |
| On-disk private key files in `~/.ssh/` | `ssh-agent` and `ssh` read them directly. | Removed. The only key material is in the KeePassXC database. |
| `SSH_AUTH_SOCK` | Set by Xsession or by a keyring component. | Set to the proxy socket by `~/.xsessionrc` and `~/.zshrc`. |

## Installation

These steps configure a stock Debian 13 computer with XFCE and GNOME to work as described above. Run each command in a terminal. Replace `dave` with your user name where applicable.

### Quick install with `install.sh`

The repo contains canonical copies of every service and config file under `config/`, plus an idempotent `install.sh` that performs Steps 1–8 of this guide for you:

```
config/
├── autostart/
│   └── org.keepassxc.KeePassXC.desktop   (Step 3; uid templated as __UID__)
├── systemd/user/
│   ├── keepassxc-ssh-agent.service        (Step 2)
│   ├── ssh-keepass-proxy.service          (Step 2)
│   ├── ssh-keepass-proxy.socket           (Step 2)
│   └── app-org.keepassxc.KeePassXC@autostart.service.d/
│       └── after-ssh-agent.conf           (Step 4)
├── xsessionrc                             (Step 7)
└── zshrc-fragment.sh                      (Step 7)
```

From the repo root:

```sh
./install.sh
```

`install.sh` does the following:
1. Builds the proxy with `cargo build --release`.
2. Copies the three systemd user units into `~/.config/systemd/user/`.
3. Installs the KeePassXC autostart `.desktop` file (substituting your uid into `/run/user/<uid>/...`).
4. Installs the KeePassXC ordering drop-in.
5. Masks the competing SSH agent providers (Step 5).
6. Renames `/etc/X11/Xsession.d/90x11-common_ssh-agent` to `.disabled` (uses `sudo`; Step 6).
7. Installs `~/.xsessionrc` and appends the `SSH_AUTH_SOCK` line to `~/.zshrc` if it is not already present.
8. Patches the `SSHAgent`, `FdoSecrets`, and `Security` sections of `~/.config/keepassxc/keepassxc.ini`.
9. Reloads the systemd user daemon and enables/starts the units.

`install.sh` is idempotent. It does **not** delete on-disk private key files (Step 9 of the manual guide) — that is a manual, irreversible action you must perform yourself after confirming KeePassXC holds every key. The KeePassXC GUI key entry step (Step 8 of the manual guide) is also manual.

### Manual install

### Step 1. Build the proxy

Install Rust if it is not installed:
```sh
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
source "$HOME/.cargo/env"
```

Clone or copy this project to `~/Projects/personal/ssh-keepass-proxy`. Then build the release binary:
```sh
cd ~/Projects/personal/ssh-keepass-proxy
cargo build --release
```

The binary is at `target/release/ssh-keepass-proxy`.

### Step 2. Install the systemd user units

Create the three unit files in `~/.config/systemd/user/`:

`keepassxc-ssh-agent.service`:
```sh
cat > ~/.config/systemd/user/keepassxc-ssh-agent.service <<'EOF'
[Unit]
Description=Real ssh-agent holding KeePassXC-loaded keys (ssh-keepass-proxy backend)
Documentation=man:ssh-agent(1)
PartOf=ssh-keepass-proxy.service

[Service]
Environment=SSH_AUTH_SOCK=%t/keepassxc-ssh-agent.sock
ExecStart=/usr/bin/ssh-agent -D -a %t/keepassxc-ssh-agent.sock
Restart=on-failure

[Install]
WantedBy=default.target
EOF
```

`ssh-keepass-proxy.socket`:
```sh
cat > ~/.config/systemd/user/ssh-keepass-proxy.socket <<'EOF'
[Unit]
Description=Socket for ssh-keepass-proxy (SSH agent proxy with KeePassXC unlock-on-demand)
Documentation=man:ssh-agent(1)

[Socket]
ListenStream=%t/ssh-auth-proxy.sock
SocketMode=0600
Accept=no

[Install]
WantedBy=sockets.target
EOF
```

`ssh-keepass-proxy.service`:
```sh
cat > ~/.config/systemd/user/ssh-keepass-proxy.service <<'EOF'
[Unit]
Description=SSH agent proxy with KeePassXC unlock-on-demand
After=keepassxc-ssh-agent.service
Requires=keepassxc-ssh-agent.service

[Service]
Type=simple
ExecStart=%h/Projects/personal/ssh-keepass-proxy/target/release/ssh-keepass-proxy
Environment=RUST_LOG=info
# Socket-activated: systemd passes the listen socket as fd 3 (LISTEN_FDS=1).
StandardOutput=journal
StandardError=journal
Restart=on-failure
RestartSec=1

[Install]
WantedBy=default.target
EOF
```

Enable and start the units:
```sh
systemctl --user daemon-reload
systemctl --user enable --now keepassxc-ssh-agent.service
systemctl --user enable --now ssh-keepass-proxy.socket
systemctl --user restart keepassxc-ssh-agent.service ssh-keepass-proxy.service
```

The `restart` command starts the proxy service immediately. The socket unit activates the service on the first connection, but an explicit restart makes both services active now.

### Step 3. Wrap the KeePassXC autostart Exec= line

This step prevents a deadlock (see "Deadlock" below). It makes KeePassXC use the real agent socket, not the proxy socket.

KeePassXC starts via XDG autostart, not via the systemd app- service. The `Exec=` line in the autostart `.desktop` file is therefore wrapped with `env` so KeePassXC talks directly to the real `ssh-agent`:

```sh
mkdir -p ~/.config/autostart
cat > ~/.config/autostart/org.keepassxc.KeePassXC.desktop <<'EOF'
[Desktop Entry]
Name=KeePassXC
GenericName=Password Manager
Exec=env SSH_AUTH_SOCK=/run/user/1000/keepassxc-ssh-agent.sock keepassxc
TryExec=keepassxc
Icon=keepassxc
StartupWMClass=keepassxc
StartupNotify=true
Terminal=false
Type=Application
Version=1.0
Categories=Utility;Security;Qt;
MimeType=application/x-keepass2;
X-GNOME-Autostart-enabled=true
X-GNOME-Autostart-Delay=2
X-KDE-autostart-after=panel
X-LXQt-Need-Tray=true
EOF
```

`.desktop` files do not expand `$XDG_RUNTIME_DIR`, so use the literal `/run/user/1000/` path. Replace `1000` with your uid if it is different (`id -u`).

#### Deadlock

If KeePassXC inherits the proxy socket from the X session, the first key operation deadlocks:

1. KeePassXC connects to the proxy socket.
2. The proxy checks `db_unlocked()` → false (database is locked).
3. The proxy triggers the unlock prompt via D-Bus and blocks (up to 300s).
4. KeePassXC is blocked waiting for the agent to respond.
5. KeePassXC cannot show its own unlock dialog because it is blocked.
6. **Deadlock** — keys never load.

The `Exec=` wrapper prevents this by pointing KeePassXC at the real agent socket. The proxy socket is only for SSH clients.

### Step 4. Install the KeePassXC ordering drop-in (redundant but harmless)

This drop-in is now redundant because Step 3 wraps the `Exec=` line. The drop-in only applies to the systemd `app-org.keepassxc.KeePassXC@autostart.service`, which does not start while KeePassXC is running via XDG autostart. Keep the drop-in as a secondary measure in case KeePassXC is ever started via the systemd app- service.

```sh
mkdir -p ~/.config/systemd/user/app-org.keepassxc.KeePassXC@autostart.service.d
cat > ~/.config/systemd/user/app-org.keepassxc.KeePassXC@autostart.service.d/after-ssh-agent.conf <<'EOF'
[Unit]
After=keepassxc-ssh-agent.service
Requires=keepassxc-ssh-agent.service

[Service]
Environment=SSH_AUTH_SOCK=%t/keepassxc-ssh-agent.sock
EOF
systemctl --user daemon-reload
```

### Step 5. Mask the competing SSH agent providers

Run these commands. Masking links the unit file to `/dev/null` so the unit cannot start, manually or automatically.

```sh
systemctl --user stop gcr-ssh-agent.service gcr-ssh-agent.socket 2>/dev/null
systemctl --user mask gcr-ssh-agent.service gcr-ssh-agent.socket

systemctl --user stop gnome-keyring-daemon.service gnome-keyring-daemon.socket 2>/dev/null
systemctl --user mask gnome-keyring-daemon.service gnome-keyring-daemon.socket

systemctl --user stop gpg-agent-ssh.socket 2>/dev/null
systemctl --user mask gpg-agent-ssh.socket

systemctl --user mask ssh-agent.socket
```

### Step 6. Disable the Xsession ssh-agent wrapper

This is a system-wide change. It needs `sudo`:
```sh
sudo mv /etc/X11/Xsession.d/90x11-common_ssh-agent /etc/X11/Xsession.d/90x11-common_ssh-agent.disabled
```

This stops the Xsession script from wrapping the session in its own `ssh-agent`.

### Step 7. Set SSH_AUTH_SOCK in the session

Create `~/.xsessionrc`:
```sh
cat > ~/.xsessionrc <<'EOF'
# Point the X session at the ssh-keepass-proxy socket, which unlock-prompts
# KeePassXC on demand and relays to the real ssh-agent.
# Pre-setting SSH_AUTH_SOCK also makes /etc/X11/Xsession.d/90x11-common_ssh-agent
# skip wrapping the session in its own (competing) ssh-agent.
if [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -S "$XDG_RUNTIME_DIR/ssh-auth-proxy.sock" -o -d "$XDG_RUNTIME_DIR" ]; then
  export SSH_AUTH_SOCK="$XDG_RUNTIME_DIR/ssh-auth-proxy.sock"
fi
EOF
```

Add this line to `~/.zshrc` (or `~/.bashrc` if you use bash):
```sh
export SSH_AUTH_SOCK="$XDG_RUNTIME_DIR/ssh-auth-proxy.sock"
```

### Step 8. Configure KeePassXC

The autostart `.desktop` file was created in Step 3. Open KeePassXC (it starts at login, or run `keepassxc` manually). Go to **Settings**:
- **SSH Agent**: enable "Enable SSH Agent".
- **Secret Service Integration**: enable "Enable Secret Service integration".
- **Security**: enable "Lock databases after inactivity" and set the idle seconds to 30. Enable "Lock databases when session is locked".

Put your SSH keys into the KeePassXC database as SSH agent entries. KeePassXC loads them into the real agent when the database unlocks.

### Step 9. Remove on-disk private key files

After you confirm that KeePassXC holds all your SSH keys, remove the private key files from `~/.ssh/`. Keep the `.pub` files, `authorized_keys`, `known_hosts`, `allowed_signers*`, and `config`.

Example:
```sh
rm ~/.ssh/id_rsa ~/.ssh/id_rsa.pub
```

Do this only after you test that an SSH operation triggers the KeePassXC unlock prompt and succeeds. Deletion is permanent. Restore from backup if you need the key back.

### Step 10. Verify the setup

Log out and log back in, then run these checks. Each line shows the expected result after it.

```sh
echo "$SSH_AUTH_SOCK"
# expect: /run/user/<uid>/ssh-auth-proxy.sock

systemctl --user is-active keepassxc-ssh-agent.service ssh-keepass-proxy.service ssh-keepass-proxy.socket
# expect: active active active

systemctl --user is-enabled ssh-agent.socket gcr-ssh-agent.service gcr-ssh-agent.socket gnome-keyring-daemon.service gnome-keyring-daemon.socket gpg-agent-ssh.socket
# expect: masked masked masked masked masked masked

ls -l "$XDG_RUNTIME_DIR/ssh-auth-proxy.sock" "$XDG_RUNTIME_DIR/keepassxc-ssh-agent.sock"
# expect: both socket files present

test -f /etc/X11/Xsession.d/90x11-common_ssh-agent && echo ACTIVE || echo DISABLED
# expect: DISABLED

grep '^Exec=' ~/.config/autostart/org.keepassxc.KeePassXC.desktop
# expect: Exec=env SSH_AUTH_SOCK=/run/user/<uid>/keepassxc-ssh-agent.sock keepassxc

cat ~/.config/systemd/user/app-org.keepassxc.KeePassXC@autostart.service.d/after-ssh-agent.conf
# expect: the drop-in file contents shown in Step 4

ssh-add -l
# This connects to the proxy. If the KeePassXC database is locked,
# KeePassXC shows the unlock dialog. After you unlock it, ssh-add lists the keys.
```

## Deploying to a second computer

To replicate the setup on a second Debian 13 computer over SSH, run these commands from the first computer. Replace `lister` with the SSH host alias of the target computer.

1. Sync the proxy source and rebuild on the target:
```sh
scp Cargo.toml src/main.rs Cargo.lock lister:~/Projects/personal/ssh-keepass-proxy/
ssh lister 'cd ~/Projects/personal/ssh-keepass-proxy && cargo build --release'
```

2. Disable the Xsession wrapper on the target:
```sh
ssh lister 'sudo mv /etc/X11/Xsession.d/90x11-common_ssh-agent /etc/X11/Xsession.d/90x11-common_ssh-agent.disabled'
```

3. Install the canonical `~/.xsessionrc` on the target:
```sh
ssh lister 'cat > ~/.xsessionrc <<'"'"'EOF'"'"'
# Point the X session at the ssh-keepass-proxy socket, which unlock-prompts
# KeePassXC on demand and relays to the real ssh-agent.
# Pre-setting SSH_AUTH_SOCK also makes /etc/X11/Xsession.d/90x11-common_ssh-agent
# skip wrapping the session in its own (competing) ssh-agent.
if [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -S "$XDG_RUNTIME_DIR/ssh-auth-proxy.sock" -o -d "$XDG_RUNTIME_DIR" ]; then
  export SSH_AUTH_SOCK="$XDG_RUNTIME_DIR/ssh-auth-proxy.sock"
fi
EOF'
```

4. Mask the competing providers on the target:
```sh
ssh lister 'systemctl --user mask ssh-agent.socket gcr-ssh-agent.service gcr-ssh-agent.socket gnome-keyring-daemon.service gnome-keyring-daemon.socket gpg-agent-ssh.socket'
```

5. Reload and restart the proxy chain on the target:
```sh
ssh lister 'systemctl --user daemon-reload; systemctl --user restart keepassxc-ssh-agent.service ssh-keepass-proxy.service ssh-keepass-proxy.socket'
```

6. Remove the on-disk private key files on the target:
```sh
ssh lister 'rm ~/.ssh/id_rsa ~/.ssh/id_rsa.pub'
```

7. Verify the plumbing from the first computer:
```sh
ssh lister 'zsh -i -c "echo \$SSH_AUTH_SOCK"'
# expect: /run/user/<uid>/ssh-auth-proxy.sock

ssh lister 'systemctl --user is-active keepassxc-ssh-agent.service ssh-keepass-proxy.service ssh-keepass-proxy.socket'
# expect: active active active

ssh lister 'for u in ssh-agent.socket gcr-ssh-agent.service gcr-ssh-agent.socket gnome-keyring-daemon.service gnome-keyring-daemon.socket gpg-agent-ssh.socket; do printf "%-45s %s\n" "$u" "$(systemctl --user is-enabled "$u")"; done'
# expect: masked x6
```

Then sit at the target computer. Run an SSH or git command. Confirm that KeePassXC shows the unlock dialog and the command succeeds.

## Current deployment

This setup runs on two computers:

| Computer | OS | Desktop | Status |
|---|---|---|---|
| holly | Debian 13 (trixie) | XFCE | Installed and verified |
| lister | Debian 13 (trixie) | XFCE | Installed and verified |

Both computers have the same proxy source, the same systemd user units, the same masked providers, and the same `SSH_AUTH_SOCK` wiring.

## Operation

### Normal use

Run any SSH command. If the KeePassXC database is locked, the KeePassXC window comes to the front and shows the unlock dialog. Type your database password. KeePassXC unlocks, loads the keys into the agent, and the SSH command continues.

The database locks again after 30 seconds of idle time. The next SSH operation triggers the unlock prompt again.

### Logs

Read the proxy logs with:
```sh
journalctl --user -u ssh-keepass-proxy.service -f
```

## Troubleshooting

### The proxy does not start

Check the service status:
```sh
systemctl --user status ssh-keepass-proxy.service
journalctl --user -u ssh-keepass-proxy.service
```

The binary path in the unit file must match the location of the built binary.

### ssh-add -l returns "Could not open a connection to your authentication agent"

The proxy socket is not present. Check that the socket unit is active:
```sh
systemctl --user status ssh-keepass-proxy.socket
ls -l "$XDG_RUNTIME_DIR/ssh-auth-proxy.sock"
```

If the socket unit is inactive, start it:
```sh
systemctl --user start ssh-keepass-proxy.socket
```

### KeePassXC does not show the unlock prompt

KeePassXC must run and the `FdoSecrets` plugin must be enabled. Check:
```sh
gdbus call --session --dest org.freedesktop.secrets --object-path /org/freedesktop/secrets --method org.freedesktop.DBus.Ping
```

If this fails, KeePassXC is not running or the Secret Service integration is disabled. Start KeePassXC and enable the setting in **Settings > Secret Service Integration**.

### KeePassXC cannot load keys into the agent (deadlock)

If KeePassXC inherits the proxy socket (`ssh-auth-proxy.sock`) from the X session, the first key operation deadlocks:

1. KeePassXC connects to the proxy socket.
2. The proxy checks `db_unlocked()` → false (database is locked).
3. The proxy triggers the unlock prompt via D-Bus and blocks (up to 300s).
4. KeePassXC is blocked waiting for the agent to respond.
5. KeePassXC cannot show its own unlock dialog because it is blocked.
6. **Deadlock** — keys never load.

KeePassXC must use the real agent socket, not the proxy socket. The primary fix is the `Exec=` wrapper in the autostart `.desktop` file:

```sh
grep '^Exec=' ~/.config/autostart/org.keepassxc.KeePassXC.desktop
# expect: Exec=env SSH_AUTH_SOCK=/run/user/<uid>/keepassxc-ssh-agent.sock keepassxc
```

If this line still reads `Exec=keepassxc`, KeePassXC inherits the proxy socket and deadlocks. Reinstall the autostart file as shown in Step 3.

The systemd drop-in is a secondary measure:
```sh
cat ~/.config/systemd/user/app-org.keepassxc.KeePassXC@autostart.service.d/after-ssh-agent.conf
```
The drop-in only takes effect if KeePassXC is started via the systemd app- service instead of XDG autostart. On a normal XFCE session the drop-in is redundant; the `Exec=` wrapper is what prevents the deadlock.

To confirm KeePassXC is running with the correct socket, restart it from the autostart entry (or manually with the `env` wrapper) and unlock the database:
```sh
kill $(pgrep keepassxc); sleep 2
env SSH_AUTH_SOCK=/run/user/1000/keepassxc-ssh-agent.sock keepassxc &
```
Then unlock the database in the KeePassXC GUI and verify:
```sh
SSH_AUTH_SOCK=/run/user/1000/keepassxc-ssh-agent.sock ssh-add -l   # should list keys
```

## Restoring stock behavior

To undo this setup and return to the stock Debian SSH agent behavior:

1. Unmask the providers:
```sh
systemctl --user unmask ssh-agent.socket gcr-ssh-agent.service gcr-ssh-agent.socket \
  gnome-keyring-daemon.service gnome-keyring-daemon.socket gpg-agent-ssh.socket
systemctl --user enable ssh-agent.socket gcr-ssh-agent.socket \
  gnome-keyring-daemon.service gnome-keyring-daemon.socket gpg-agent-ssh.socket
```

2. Restore the Xsession wrapper:
```sh
sudo mv /etc/X11/Xsession.d/90x11-common_ssh-agent.disabled /etc/X11/Xsession.d/90x11-common_ssh-agent
```

3. Remove the custom units and the drop-in:
```sh
systemctl --user disable --now keepassxc-ssh-agent.service ssh-keepass-proxy.service ssh-keepass-proxy.socket
rm ~/.config/systemd/user/keepassxc-ssh-agent.service
rm ~/.config/systemd/user/ssh-keepass-proxy.service
rm ~/.config/systemd/user/ssh-keepass-proxy.socket
rm -r ~/.config/systemd/user/app-org.keepassxc.KeePassXC@autostart.service.d
systemctl --user daemon-reload
```

4. Restore the KeePassXC autostart `Exec=` line:
```sh
# Edit ~/.config/autostart/org.keepassxc.KeePassXC.desktop and change the
# Exec= line back to: Exec=keepassxc
```

5. Remove the environment wiring:
```sh
rm ~/.xsessionrc
# Edit ~/.zshrc and remove the SSH_AUTH_SOCK line.
```

6. Log out and log back in. The stock `ssh-agent` or GNOME Keyring SSH component takes over.

7. Restore your on-disk private key files from backup if you deleted them. Deletion is permanent. Keep a backup before you remove key files in Step 9.