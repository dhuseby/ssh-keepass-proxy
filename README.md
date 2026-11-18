# ssh-keepass-proxy

A socket-activated SSH agent proxy. When an SSH client connects to the proxy socket, the proxy asks KeePassXC to unlock its database. KeePassXC shows the unlock dialog. After you unlock the database, KeePassXC loads its SSH keys into the real `ssh-agent`. The proxy then relays bytes between the SSH client and the real agent.

The only source of truth for SSH keys is KeePassXC. No on-disk private key files are used. No other SSH agent can start. One exception stays live: `xfce4-session` starts a built-in SSH agent that is not a systemd unit and cannot be masked. An xfconf property disables it (Step 10), and the doctor watchdog keeps that property set (Step 12).

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

Five units live in `~/.config/systemd/user/`:

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

**`ssh-keepass-doctor.service`** — one-shot `--fix` repair run; started by the timer.
```ini
[Unit]
Description=Repair ssh-keepass-proxy drift (KeePassXC pinning, xfce4-session agent, user environment)

[Service]
Type=oneshot
ExecStart=%h/Projects/personal/ssh-keepass-proxy/config/ssh-keepass-doctor.sh --fix
StandardOutput=journal
StandardError=journal
```

**`ssh-keepass-doctor.timer`** — starts the doctor two minutes after boot, then every five minutes.
```ini
[Unit]
Description=Periodically repair ssh-keepass-proxy drift

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target
```

Both doctor units run the script from this checkout (`%h/Projects/personal/ssh-keepass-proxy/config/ssh-keepass-doctor.sh`); there is no installed copy. Step 12 describes the doctor.

### KeePassXC agent socket pinning

KeePassXC must talk to the real agent, not to the proxy. If KeePassXC used the proxy socket, the first key operation would trigger the proxy to ask KeePassXC to unlock itself. This makes a deadlock (see "Deadlock" under Installation).

Two pins keep KeePassXC on the real agent socket:

**Primary: the `AuthSockOverride` key.** KeePassXC 2.7.x prefers this key in its local-cache settings over `$SSH_AUTH_SOCK` for its SSH agent connection, so a settings save can no longer retune KeePassXC to a competing agent.

Path: `~/.cache/keepassxc/keepassxc.ini`
```ini
[SSHAgent]
AuthSockOverride=/run/user/<uid>/keepassxc-ssh-agent.sock
```

KeePassXC holds this file in memory and rewrites it on exit, so a settings save can drop the key again. install.sh and the doctor write the key only while KeePassXC is closed; the next doctor `--fix` run restores it (Step 12).

**Secondary: the autostart `.desktop` file.** KeePassXC starts via XDG autostart (launched by `xfce4-session`), not via the systemd `app-org.keepassxc.KeePassXC@autostart.service`. The autostart `.desktop` file is therefore the place that must set `SSH_AUTH_SOCK` to the real agent socket. The `Exec=` line is wrapped with `env`:

Path: `~/.config/autostart/org.keepassxc.KeePassXC.desktop`
```
Exec=env SSH_AUTH_SOCK=/run/user/<uid>/keepassxc-ssh-agent.sock keepassxc
```

`.desktop` files do not expand `$XDG_RUNTIME_DIR`, so the literal `/run/user/<uid>/` path is used. The proxy socket is only for SSH clients; KeePassXC never connects to it.

### KeePassXC ordering drop-in (redundant but harmless)

A systemd drop-in file also orders KeePassXC after `keepassxc-ssh-agent.service` and sets its `SSH_AUTH_SOCK` to the real agent socket. This drop-in is redundant: it only applies to the systemd `app-org.keepassxc.KeePassXC@autostart.service`, which does not start because KeePassXC is already running via XDG autostart ("Another instance is already running"). The drop-in is kept as a backstop in case KeePassXC is ever started via the systemd app- service instead of XDG autostart.

Path: `~/.config/systemd/user/app-org.keepassxc.KeePassXC@autostart.service.d/after-ssh-agent.conf`
```ini
[Unit]
After=keepassxc-ssh-agent.service
Requires=keepassxc-ssh-agent.service

[Service]
Environment=SSH_AUTH_SOCK=%t/keepassxc-ssh-agent.sock
```

### Environment wiring

Three files set `SSH_AUTH_SOCK` to the proxy socket:

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

`~/.config/environment.d/ssh.conf` (session-wide base environment of the systemd user manager; user units and systemd-spawned processes inherit it):
```
SSH_AUTH_SOCK=/run/user/<uid>/ssh-auth-proxy.sock
```

On systemd 257 the user manager builds its base environment from `environment.d` files at login, and `systemctl --user unset-environment` removes only overlay values — a base value from this file shows through after every unset. That is why the base file carries the proxy socket instead of relying on unset, and why the healthy session-wide values are: the proxy socket, or no `SSH_AUTH_SOCK` at all. The doctor checks and repairs this file (Step 12).

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

The `SSHAgent.Enabled` key makes KeePassXC load SSH keys into the agent on unlock. The `FdoSecrets.Enabled` key exposes the `org.freedesktop.secrets` D-Bus interface that the proxy calls. The `Security` section locks the database after 30 seconds idle and on screen lock. When the database locks, the keys stay in the agent until the next lock event KeePassXC applies. The proxy checks the database lock state, not the agent identity list, as the source of truth. After each unlock it reads the real agent's identity count and logs it (see Logs); the count is diagnostic only and never changes what the proxy relays.

## How this differs from stock Debian 13 + XFCE4 + Gnome

| Stock provider | Stock behavior | This setup |
|---|---|---|
| `/etc/X11/Xsession.d/90x11-common_ssh-agent` | Wraps the X session in a new `ssh-agent` if `SSH_AUTH_SOCK` is empty. | Renamed to `.disabled`. Does not run. |
| `ssh-agent.socket` (systemd user unit) | Socket-activates `ssh-agent.service` on demand. | Masked (`/dev/null`). Cannot start. |
| `gcr-ssh-agent.service` + `.socket` | Socket-activates the GCR SSH agent wrapper. | Masked. Cannot start. |
| `gnome-keyring-daemon.service` + `.socket` | Socket-activates GNOME Keyring. The keyring runs an SSH component. | Masked. The keyring cannot start. KeePassXC `FdoSecrets` is the only secrets service. |
| `gpg-agent-ssh.socket` | Lets `gpg-agent` emulate an SSH agent. | Masked. The GnuPG SSH emulation cannot start. |
| `xfce4-session` built-in SSH agent | Starts its own `ssh-agent` at session start and exports `SSH_AUTH_SOCK`. | Disabled with the xfconf property `/startup/ssh-agent/enabled=false` (Step 10). Not a systemd unit, so it cannot be masked; the doctor watchdog keeps the property set (Step 12). |
| On-disk private key files in `~/.ssh/` | `ssh-agent` and `ssh` read them directly. | Removed. The only key material is in the KeePassXC database. |
| `SSH_AUTH_SOCK` | Set by Xsession or by a keyring component. | Set to the proxy socket by `~/.xsessionrc`, `~/.zshrc`, and `~/.config/environment.d/ssh.conf`. |

## Installation

These steps configure a stock Debian 13 computer with XFCE and GNOME to work as described above. Run each command in a terminal. Replace `dave` with your user name where applicable.

### Quick install with `install.sh`

The repo contains canonical copies of every service and config file under `config/`, plus an idempotent `install.sh` that performs Steps 1–8, 10, and 11 of this guide for you:

```
config/
├── autostart/
│   └── org.keepassxc.KeePassXC.desktop   (Step 3; uid templated as __UID__)
├── systemd/user/
│   ├── keepassxc-ssh-agent.service        (Step 2)
│   ├── ssh-keepass-proxy.service          (Step 2)
│   ├── ssh-keepass-proxy.socket           (Step 2)
│   ├── ssh-keepass-doctor.service         (Step 2)
│   ├── ssh-keepass-doctor.timer           (Step 2)
│   └── app-org.keepassxc.KeePassXC@autostart.service.d/
│       └── after-ssh-agent.conf           (Step 4)
├── ssh-keepass-doctor.sh                  (Steps 11–13; runs from this checkout)
├── xsessionrc                             (Step 7)
└── zshrc-fragment.sh                      (Step 7)
```

From the repo root:

```sh
./install.sh
```

`install.sh` does the following:
1. Builds the proxy with `cargo build --release` (Step 1).
2. Copies the five systemd user units into `~/.config/systemd/user/` (Step 2).
3. Installs the KeePassXC autostart `.desktop` file (substituting your uid into `/run/user/<uid>/...`) (Step 3).
4. Installs the KeePassXC ordering drop-in (Step 4).
5. Masks the competing SSH agent providers (Step 5).
6. Renames `/etc/X11/Xsession.d/90x11-common_ssh-agent` to `.disabled` (uses `sudo`; Step 6).
7. Installs `~/.xsessionrc`, appends the `SSH_AUTH_SOCK` line to `~/.zshrc` if it is not already present, and writes `SSH_AUTH_SOCK` into `~/.config/environment.d/ssh.conf` (Step 7).
8. Patches the `SSHAgent`, `FdoSecrets`, and `Security` sections of `~/.config/keepassxc/keepassxc.ini` and writes `AuthSockOverride` into `~/.cache/keepassxc/keepassxc.ini` (skipped with a warning while KeePassXC is running) (Step 8).
9. Reloads the systemd user daemon, enables/starts the proxy units, and enables the doctor timer (Step 2).
10. Disables the xfce4-session built-in SSH agent with xfconf (Step 10).
11. Runs the doctor with `--purge`; it asks once before it stops the stray agents (Step 11).

`install.sh` is idempotent. Steps 8–11 hold the doctor's lock (`$XDG_RUNTIME_DIR/ssh-keepass-doctor.lock`), so the watchdog timer cannot interleave with them. It does **not** delete on-disk private key files (Step 9 of the manual guide) — that is a manual, irreversible action you must perform yourself after confirming KeePassXC holds every key. The KeePassXC GUI key entry step (Step 8 of the manual guide) is also manual.

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

Create the five unit files in `~/.config/systemd/user/`:

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

`ssh-keepass-doctor.service`:
```sh
cat > ~/.config/systemd/user/ssh-keepass-doctor.service <<'EOF'
[Unit]
Description=Repair ssh-keepass-proxy drift (KeePassXC pinning, xfce4-session agent, user environment)

[Service]
Type=oneshot
ExecStart=%h/Projects/personal/ssh-keepass-proxy/config/ssh-keepass-doctor.sh --fix
StandardOutput=journal
StandardError=journal
EOF
```

`ssh-keepass-doctor.timer`:
```sh
cat > ~/.config/systemd/user/ssh-keepass-doctor.timer <<'EOF'
[Unit]
Description=Periodically repair ssh-keepass-proxy drift

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target
EOF
```

Enable and start the units:
```sh
systemctl --user daemon-reload
systemctl --user enable --now keepassxc-ssh-agent.service
systemctl --user enable --now ssh-keepass-proxy.socket
systemctl --user enable --now ssh-keepass-doctor.timer
systemctl --user restart keepassxc-ssh-agent.service ssh-keepass-proxy.service
```

The `restart` command starts the proxy service immediately. The socket unit activates the service on the first connection, but an explicit restart makes the proxy and the real agent active now. The doctor service has no `[Install]` section; only the timer starts it.

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

If this file is ever overwritten and the wrapper line is lost, the doctor detects the wrong `Exec=` line and re-renders the file from the repo template (`config/autostart/org.keepassxc.KeePassXC.desktop`) on `--fix` (Step 12). The `AuthSockOverride` pin (Step 8) is the primary pin and does not depend on this file.

#### Deadlock

If KeePassXC inherits the proxy socket from the X session, the first key operation deadlocks:

1. KeePassXC connects to the proxy socket.
2. The proxy checks `db_unlocked()` → false (database is locked).
3. The proxy triggers the unlock prompt via D-Bus and blocks (up to 300s).
4. KeePassXC is blocked waiting for the agent to respond.
5. KeePassXC cannot show its own unlock dialog because it is blocked.
6. **Deadlock** — keys never load.

The `Exec=` wrapper prevents this by pointing KeePassXC at the real agent socket. The `AuthSockOverride` key (Step 8) is the second gate: KeePassXC 2.7.x connects to the override socket even when `$SSH_AUTH_SOCK` is wrong. The proxy socket is only for SSH clients.

### Step 4. Install the KeePassXC ordering drop-in (redundant but harmless)

This drop-in is now redundant because Step 3 wraps the `Exec=` line. The drop-in only applies to the systemd `app-org.keepassxc.KeePassXC@autostart.service`, which does not start while KeePassXC is running via XDG autostart. Keep the drop-in as a backstop in case KeePassXC is ever started via the systemd app- service.

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

Write the session-wide base file for the systemd user manager (see "Environment wiring" for why `unset-environment` cannot replace this):
```sh
mkdir -p ~/.config/environment.d
printf 'SSH_AUTH_SOCK=/run/user/1000/ssh-auth-proxy.sock\n' > ~/.config/environment.d/ssh.conf
```

### Step 8. Configure KeePassXC

The autostart `.desktop` file was created in Step 3. Open KeePassXC (it starts at login, or run `keepassxc` manually). Go to **Settings**:
- **SSH Agent**: enable "Enable SSH Agent", and set the **SSH_AUTH_SOCK override** field on the same page to `/run/user/1000/keepassxc-ssh-agent.sock` (use your uid).
- **Secret Service Integration**: enable "Enable Secret Service integration".
- **Security**: enable "Lock databases after inactivity" and set the idle seconds to 30. Enable "Lock databases when session is locked".

The settings live in two files. `~/.config/keepassxc/keepassxc.ini` holds the settings keys; install.sh writes them:
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

`~/.cache/keepassxc/keepassxc.ini` is the local-cache file. KeePassXC 2.7.x prefers the `AuthSockOverride` key there over `$SSH_AUTH_SOCK` for its SSH agent connection, which makes it the primary pin ("KeePassXC agent socket pinning"). install.sh writes it:
```ini
[SSHAgent]
AuthSockOverride=/run/user/1000/keepassxc-ssh-agent.sock
```

KeePassXC holds the cache file in memory and rewrites it on exit, so install.sh skips the override write with a warning while KeePassXC is running. Either set the override field in the GUI and save, or close KeePassXC and re-run install.sh. The doctor repairs the key on the next `--fix` run while KeePassXC is closed (Step 12).

Put your SSH keys into the KeePassXC database as SSH agent entries. KeePassXC loads them into the real agent when the database unlocks.

### Step 9. Remove on-disk private key files

After you confirm that KeePassXC holds all your SSH keys, remove the private key files from `~/.ssh/`. Keep the `.pub` files, `authorized_keys`, `known_hosts`, `allowed_signers*`, and `config`.

Example:
```sh
rm ~/.ssh/id_rsa ~/.ssh/id_rsa.pub
```

Do this only after you test that an SSH operation triggers the KeePassXC unlock prompt and succeeds. Deletion is permanent. Restore from backup if you need the key back.

### Step 10. Disable the xfce4-session built-in SSH agent

The `xfce4-session` startup starts its own `ssh-agent` and exports `SSH_AUTH_SOCK` unless an xfconf property disables it. The agent is not a systemd unit, so masking (Step 5) cannot stop it. Create the property:

```sh
xfconf-query -c xfce4-session -p /startup/ssh-agent/enabled -n -t bool -s false
```

The `-n` flag creates the property if it does not exist yet. The doctor re-creates the property if it goes missing (Step 12).

### Step 11. Stop and remove stray and competing running SSH agents

Masked units cannot start, but an `ssh-agent` that started before the masking still holds your keys and exports a competing socket. The doctor finds every running `ssh-agent` with `pgrep -x ssh-agent`, skips the real agent's own process (`keepassxc-ssh-agent.service` MainPID), and re-checks `/proc/<pid>/comm` before it acts. Run:

```sh
config/ssh-keepass-doctor.sh --purge
```

`--purge` applies `--fix` and stops the strays. It asks once before the first kill:

```
Stop and remove these stray ssh-agent processes? Their loaded keys are lost here; KeePassXC reloads them after the next unlock.
  pids: 12345
Proceed? [y/N]
```

Answer `y`. Per stray, the doctor drops its loaded keys over the stray's own socket (`SSH_AUTH_SOCK=<discovered socket> ssh-add -D`, best effort), sends `kill`, waits one second, then sends `kill -KILL`. It never touches the real agent's process. Scripted runs skip the prompt with `SSH_KEEPASS_PURGE=1`.

Manual equivalents, if you prefer not to let the doctor kill anything:
```sh
pgrep -x ssh-agent                          # the stray pids (the real agent's pid is not among them)
lsof -a -p <pid> -U                         # the stray's unix socket, if lsof is installed
SSH_AUTH_SOCK=<stray socket> ssh-add -D     # best-effort key flush; never run this against the proxy socket
kill <pid>; sleep 1; kill -KILL <pid>
systemctl --user unset-environment SSH_AUTH_SOCK
```

`unset-environment` removes only the manager's overlay value. On systemd 257 a base value from `~/.config/environment.d/ssh.conf` (Step 7) shows through after every unset. A leftover base value is correct when it is the proxy socket; a competing value means Step 7 was not applied.

### Step 12. Doctor check and watchdog

`config/ssh-keepass-doctor.sh` runs from this checkout; install.sh does not copy it. Without flags it checks every component and changes nothing. With `--fix` it repairs configuration drift — the autostart wrapper file, the KeePassXC `AuthSockOverride` key, the xfconf property, the `environment.d` pin, and the systemd user environment — and never kills a process. `--purge` is Step 11.

Each run serializes on `flock` over `${XDG_RUNTIME_DIR}/ssh-keepass-doctor.lock`, so two runs cannot interleave. Exit codes: `0` healthy, `1` problems remain, `2` environment error. Output lines are tagged `[ok]`, `[drift]`, `[warn]`, `[error]`, `[fixed]`, or `[info]`. A healthy check run looks like:

```
[info] ssh-keepass-doctor check: starting
[ok] proxy socket unit: active, enabled
[info] proxy service unit: is-active=active is-enabled=disabled (inactive and disabled are normal for a socket-activated unit)
[ok] keepassxc-ssh-agent.service active
[ok] proxy socket file present: /run/user/1000/ssh-auth-proxy.sock
[ok] real agent socket file present: /run/user/1000/keepassxc-ssh-agent.sock
[ok] autostart wrapper file pinned to the real agent socket
[ok] KeePassXC socket override pinned to the real agent socket
[ok] gcr-ssh-agent.service masked
[ok] gcr-ssh-agent.socket masked
[ok] gnome-keyring-daemon.service masked
[ok] gnome-keyring-daemon.socket masked
[ok] gpg-agent-ssh.socket masked
[ok] ssh-agent.socket masked
[ok] Xsession ssh-agent wrapper absent
[ok] xfce4-session built-in ssh-agent disabled
[ok] environment.d ssh.conf pins the proxy socket
[ok] systemd user environment carries the proxy socket
[ok] no stray ssh-agent processes
[ok] real agent holds 5 identities
[info] doctor finished: healthy
```

A `[warn]` on identities is not drift: `real agent holds 0 identities` means the database is locked or KeePassXC loaded no keys. Unlock the database and run the check again (see Troubleshooting).

Two systemd user units make the check self-healing. `ssh-keepass-doctor.timer` starts `ssh-keepass-doctor.service` two minutes after boot and again every five minutes (`OnBootSec=2min`, `OnUnitActiveSec=5min`, `Persistent=true`). The service runs the doctor with `--fix`, and its output lands in the journal:
```sh
journalctl --user -u ssh-keepass-doctor.service
```

### Step 13. Verify the setup

Log out and log back in, then run these checks. Each line shows the expected result after it.

```sh
echo "$SSH_AUTH_SOCK"
# expect: /run/user/<uid>/ssh-auth-proxy.sock

systemctl --user is-active keepassxc-ssh-agent.service ssh-keepass-proxy.service ssh-keepass-proxy.socket
# expect: active active active

systemctl --user is-active ssh-keepass-doctor.timer
# expect: active

systemctl --user is-enabled ssh-agent.socket gcr-ssh-agent.service gcr-ssh-agent.socket gnome-keyring-daemon.service gnome-keyring-daemon.socket gpg-agent-ssh.socket
# expect: masked masked masked masked masked masked

ls -l "$XDG_RUNTIME_DIR/ssh-auth-proxy.sock" "$XDG_RUNTIME_DIR/keepassxc-ssh-agent.sock"
# expect: both socket files present

test -f /etc/X11/Xsession.d/90x11-common_ssh-agent && echo ACTIVE || echo DISABLED
# expect: DISABLED

xfconf-query -c xfce4-session -p /startup/ssh-agent/enabled
# expect: false

grep -F 'AuthSockOverride' ~/.cache/keepassxc/keepassxc.ini
# expect: AuthSockOverride=/run/user/<uid>/keepassxc-ssh-agent.sock

grep '^Exec=' ~/.config/autostart/org.keepassxc.KeePassXC.desktop
# expect: Exec=env SSH_AUTH_SOCK=/run/user/<uid>/keepassxc-ssh-agent.sock keepassxc

cat ~/.config/systemd/user/app-org.keepassxc.KeePassXC@autostart.service.d/after-ssh-agent.conf
# expect: the drop-in file contents shown in Step 4

cat ~/.config/environment.d/ssh.conf
# expect: SSH_AUTH_SOCK=/run/user/<uid>/ssh-auth-proxy.sock

config/ssh-keepass-doctor.sh && echo HEALTHY
# expect: [ok] lines throughout, exit code 0, and HEALTHY

ssh-add -l
# This connects to the proxy. If the KeePassXC database is locked,
# KeePassXC shows the unlock dialog. After you unlock it, ssh-add lists the keys.
```

## Deploying to a second computer

To replicate the setup on a second Debian 13 computer over SSH, run these commands from the first computer. Replace `lister` with the SSH host alias of the target computer.

1. Sync the project and rebuild on the target. The doctor runs from the repo checkout, so the whole checkout must land there:
```sh
rsync -a --exclude target . lister:~/Projects/personal/ssh-keepass-proxy/
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

4. Write the session-wide base file on the target:
```sh
ssh lister 'mkdir -p ~/.config/environment.d && printf "SSH_AUTH_SOCK=/run/user/$(id -u)/ssh-auth-proxy.sock\n" > ~/.config/environment.d/ssh.conf'
```

5. Install the five systemd user units on the target:
```sh
ssh lister 'cd ~/Projects/personal/ssh-keepass-proxy && install -m 0644 config/systemd/user/keepassxc-ssh-agent.service config/systemd/user/ssh-keepass-proxy.service config/systemd/user/ssh-keepass-proxy.socket config/systemd/user/ssh-keepass-doctor.service config/systemd/user/ssh-keepass-doctor.timer ~/.config/systemd/user/'
```

6. Mask the competing providers on the target:
```sh
ssh lister 'systemctl --user mask ssh-agent.socket gcr-ssh-agent.service gcr-ssh-agent.socket gnome-keyring-daemon.service gnome-keyring-daemon.socket gpg-agent-ssh.socket'
```

7. Reload, enable the doctor timer, and restart the proxy chain on the target:
```sh
ssh lister 'systemctl --user daemon-reload; systemctl --user enable --now ssh-keepass-doctor.timer; systemctl --user restart keepassxc-ssh-agent.service ssh-keepass-proxy.service ssh-keepass-proxy.socket'
```

8. Remove the on-disk private key files on the target:
```sh
ssh lister 'rm ~/.ssh/id_rsa ~/.ssh/id_rsa.pub'
```

9. Verify the plumbing from the first computer:
```sh
ssh lister 'zsh -i -c "echo \$SSH_AUTH_SOCK"'
# expect: /run/user/<uid>/ssh-auth-proxy.sock

ssh lister 'systemctl --user is-active keepassxc-ssh-agent.service ssh-keepass-proxy.service ssh-keepass-proxy.socket ssh-keepass-doctor.timer'
# expect: active active active active

ssh lister 'for u in ssh-agent.socket gcr-ssh-agent.service gcr-ssh-agent.socket gnome-keyring-daemon.service gnome-keyring-daemon.socket gpg-agent-ssh.socket; do printf "%-45s %s\n" "$u" "$(systemctl --user is-enabled "$u")"; done'
# expect: masked x6

ssh lister '~/Projects/personal/ssh-keepass-proxy/config/ssh-keepass-doctor.sh; echo "doctor exit $?"'
# expect: [ok] lines throughout and "doctor exit 0"
```

Then sit at the target computer. Run an SSH or git command. Confirm that KeePassXC shows the unlock dialog and the command succeeds. Steps 3, 8, and 10 of the manual guide (the autostart wrapper, the KeePassXC settings, the xfconf property) still apply on a fresh target; running `./install.sh` there does all of them in one go.

## Current deployment

This setup runs on two computers:

| Computer | OS | Desktop | Status |
|---|---|---|---|
| lister | Debian 13 (trixie) | XFCE | This computer. Runs this revision, installed with the current install.sh: the doctor script, its timer, the `AuthSockOverride` key, and the xfconf property are in place |
| holly | Debian 13 (trixie) | XFCE | Runs the previous revision; re-run install.sh there to bring it to this revision |

lister runs this revision after the recent full install. holly runs the previous revision until install.sh is re-run there. After that re-run, both computers have the same proxy source, the same five systemd user units, the same masked providers, and the same `SSH_AUTH_SOCK` wiring.

## Operation

### Normal use

Run any SSH command. If the KeePassXC database is locked, the KeePassXC window comes to the front and shows the unlock dialog. Type your database password. KeePassXC unlocks, loads the keys into the agent, and the SSH command continues.

The database locks again after 30 seconds of idle time. The next SSH operation triggers the unlock prompt again.

### Logs

Read the proxy logs with:
```sh
journalctl --user -u ssh-keepass-proxy.service -f
```

After a connection that triggered the unlock prompt, the proxy asks the real agent over the ssh-agent protocol how many identities it holds. It polls at most five times, 400 ms apart, and logs one of these lines (info level for the first, warning for the second):

```
real agent holds 3 identities after unlock
```

```
real agent holds no identities after unlock; KeePassXC may be pinned to a competing agent
```

The first line confirms the keys landed in the real agent. The second means the database unlocked but no keys arrived on this socket; see "Keys load into a competing agent" under Troubleshooting. A query error logs `identity count failed: <error chain>` as a warning and never fails the relay.

The doctor runs under the timer every five minutes and writes its `[ok]`/`[drift]`/`[fixed]`/`[warn]` output to the journal:
```sh
journalctl --user -u ssh-keepass-doctor.service
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

KeePassXC must use the real agent socket, not the proxy socket. The primary pin is the `AuthSockOverride` key in the local-cache settings (Step 8). Check it:
```sh
grep -F 'AuthSockOverride' ~/.cache/keepassxc/keepassxc.ini
# expect: AuthSockOverride=/run/user/<uid>/keepassxc-ssh-agent.sock
```

If the key is missing or points elsewhere, close KeePassXC and run:
```sh
config/ssh-keepass-doctor.sh --fix
```
The doctor writes the key only while KeePassXC is closed, because KeePassXC holds the file in memory and rewrites it on exit. The KeePassXC GUI (**Settings > SSH Agent > SSH_AUTH_SOCK override**) is the alternate remedy.

The secondary pin is the `Exec=` wrapper in the autostart `.desktop` file:
```sh
grep '^Exec=' ~/.config/autostart/org.keepassxc.KeePassXC.desktop
# expect: Exec=env SSH_AUTH_SOCK=/run/user/<uid>/keepassxc-ssh-agent.sock keepassxc
```

If this line still reads `Exec=keepassxc`, KeePassXC inherits the proxy socket and deadlocks. `config/ssh-keepass-doctor.sh --fix` re-renders the file from the repo template.

The systemd drop-in is a backstop:
```sh
cat ~/.config/systemd/user/app-org.keepassxc.KeePassXC@autostart.service.d/after-ssh-agent.conf
```
The drop-in only takes effect if KeePassXC is started via the systemd app- service instead of XDG autostart. On a normal XFCE session the drop-in is redundant; the two pins above are what prevent the deadlock.

To confirm KeePassXC is running with the correct socket, restart it from the autostart entry (or manually with the `env` wrapper) and unlock the database:
```sh
kill $(pgrep keepassxc); sleep 2
env SSH_AUTH_SOCK=/run/user/1000/keepassxc-ssh-agent.sock keepassxc &
```
Then unlock the database in the KeePassXC GUI and verify:
```sh
SSH_AUTH_SOCK=/run/user/1000/keepassxc-ssh-agent.sock ssh-add -l   # should list keys
```

### Keys load into a competing agent (zero-identities warning)

Symptom: the proxy logs `real agent holds no identities after unlock; KeePassXC may be pinned to a competing agent`, or the doctor prints `[warn] real agent holds 0 identities; run the doctor again after you unlock the database`. The database unlocked, but the keys went to another agent socket (or to none). An empty count is also normal when the database has no SSH agent entries.

Run the check and read the `[drift]` lines:
```sh
config/ssh-keepass-doctor.sh
```

A missing or wrong `AuthSockOverride` key, a wrong autostart `Exec=` line, or a competing session-wide `SSH_AUTH_SOCK` each point at the socket KeePassXC or the clients follow. Close KeePassXC and repair all of them at once:
```sh
config/ssh-keepass-doctor.sh --fix
```

Then start KeePassXC, unlock the database, and run `ssh-add -l`. The proxy should log `real agent holds N identities after unlock`.

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

3. Re-enable the xfce4-session built-in SSH agent (`-r` resets, that is removes, the property):
```sh
xfconf-query -c xfce4-session -p /startup/ssh-agent/enabled -r
```

4. Stop the doctor timer and remove the custom units and the drop-in:
```sh
systemctl --user disable --now ssh-keepass-doctor.timer
systemctl --user disable --now keepassxc-ssh-agent.service ssh-keepass-proxy.service ssh-keepass-proxy.socket
rm ~/.config/systemd/user/ssh-keepass-doctor.timer
rm ~/.config/systemd/user/ssh-keepass-doctor.service
rm ~/.config/systemd/user/keepassxc-ssh-agent.service
rm ~/.config/systemd/user/ssh-keepass-proxy.service
rm ~/.config/systemd/user/ssh-keepass-proxy.socket
rm -r ~/.config/systemd/user/app-org.keepassxc.KeePassXC@autostart.service.d
systemctl --user daemon-reload
```

5. Restore the KeePassXC autostart `Exec=` line:
```sh
# Edit ~/.config/autostart/org.keepassxc.KeePassXC.desktop and change the
# Exec= line back to: Exec=keepassxc
```

6. Clear the KeePassXC socket override. Stop KeePassXC first — it holds the file in memory and rewrites it on exit, so an edit while it runs is lost:
```sh
kill $(pgrep -x keepassxc)
sed -i '/^AuthSockOverride=/d' ~/.cache/keepassxc/keepassxc.ini
```
Deleting the line removes the key; setting it empty (`AuthSockOverride=`) also clears it.

7. Remove the environment wiring:
```sh
rm ~/.xsessionrc
rm ~/.config/environment.d/ssh.conf
# Edit ~/.zshrc and remove the SSH_AUTH_SOCK line.
```

8. Log out and log back in. The stock `ssh-agent` (the Xsession wrapper or the xfce4-session built-in) or GNOME Keyring SSH component takes over.

9. Restore your on-disk private key files from backup if you deleted them. Deletion is permanent. Keep a backup before you remove key files in Step 9.