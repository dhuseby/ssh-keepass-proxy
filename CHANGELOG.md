# Changelog

All notable changes to this project are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the version numbers follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html). During 0.y.z (initial development), a minor-number bump marks backward-compatible feature additions, and a patch-number bump marks backward-compatible fixes.

## [0.2.0] - 2026-11-17

### Added

- `config/ssh-keepass-doctor.sh`, a user-level tool that checks the full setup, repairs config drift, and stops stray `ssh-agent` processes. Modes: no flags = check only; `--fix` = repairs without killing; `--purge` = repair plus a one-prompt cleanup of stray agents (`SSH_KEEPASS_PURGE=1` skips the prompt). It prints `[ok]`/`[drift]`/`[warn]`/`[error]`/`[fixed]` lines, serializes runs with `flock`, and exits 0 (healthy), 1 (problems remain), or 2 (environment error).
- `config/systemd/user/ssh-keepass-doctor.service` (oneshot, runs the doctor with `--fix`) and `config/systemd/user/ssh-keepass-doctor.timer` (`OnBootSec=2min`, `OnUnitActiveSec=5min`, `Persistent=true`): the setup self-heals every 5 minutes and repairs the autostart wrapper file after KeePassXC settings saves overwrite it.
- SSH-agent identity diagnostics in the proxy. After a connection triggers the unlock prompt, the proxy queries the real agent over the ssh-agent protocol with a bounded poll (5 tries, 400 ms apart) and logs `real agent holds N identities after unlock`, or `real agent holds no identities after unlock; KeePassXC may be pinned to a competing agent` when the count stays zero. Query failures log a warning and never affect the relay.
- Seven unit tests for the reply parser (`parse_identities_answer`), including the accepted 1,000,000-count boundary.
- Installer steps: KeePassXC agent pinning writes `AuthSockOverride` into `~/.cache/keepassxc/keepassxc.ini` (skipped with a warning while KeePassXC runs), `~/.config/environment.d/ssh.conf` pins the session-wide base `SSH_AUTH_SOCK` to the proxy socket, Step 10 disables the xfce4-session built-in SSH agent with xfconf, and Step 11 runs the doctor with `--purge`. The installer now holds the doctor lock across Steps 8–11 and passes `SSH_KEEPASS_DOCTOR_NO_LOCK=1` to the Step 11 child so it cannot deadlock against its parent.

### Changed

- Primary pin for the agent socket moved to the KeePassXC config key `SSHAgent/AuthSockOverride` (`~/.cache/keepassxc/keepassxc.ini`); the autostart `Exec=` wrapper is now the secondary pin and a doctor-repaired file. The settings dialog round-trips the override, so a settings save no longer loses the pin.
- `install.sh` installs five systemd user units (the three proxy/agent units plus the two doctor units), takes the target file as the first `ini_set` argument, writes all repairs through a temp file and `mv`, and preserves file modes.
- The 250 ms grace sleep in the triggered unlock path of the proxy is replaced by the bounded identity poll described above.

### Fixed

- Keys loading into a competing agent: on stock XFCE, xfce4-session starts a built-in `ssh-agent`, and a clobbered autostart wrapper made KeePassXC load its keys into that stray agent while the real agent stayed empty. The root cause is now pinned by the override, the stray is removed by `--purge`, and the built-in agent is disabled by an xfconf property.
- Session-wide `SSH_AUTH_SOCK` kept reappearing and pointing at a foreign socket: systemd 257 rebuilds the user-manager base environment from `environment.d` files, and `unset-environment` removes only overlay values. The base now carries the proxy socket via `~/.config/environment.d/ssh.conf`, which the installer and the doctor repair.
- clippy warning in `single_instance_lock` (`OpenOptions` now sets `truncate(true)` for the lock file).

### Documentation

- README restructured around the primary override pin and the doctor: five units with verbatim listings, new Steps 10 (xfconf disable), 11 (stray purge), and 12 (doctor and watchdog), the verification block as Step 13, new log lines documented, an upgraded "keys load into a competing agent" troubleshooting subsection, second-computer deployment and restoring-stock-behavior sections refreshed.

## [0.1.0] - 2026-08-06

### Added

- Socket-activated SSH agent proxy (`ssh-keepass-proxy`) that unlock-prompts KeePassXC on demand, then relays the ssh-agent protocol unchanged to the real agent at `/run/user/<uid>/keepassxc-ssh-agent.sock`.
- `keepassxc-ssh-agent.service` (the real agent unit), `ssh-keepass-proxy.socket` (systemd-managed listen socket), `ssh-keepass-proxy.service`, and the KeePassXC autostart ordering drop-in.
- KeePassXC autostart wrapper pinning `Exec=env SSH_AUTH_SOCK=/run/user/<uid>/keepassxc-ssh-agent.sock keepassxc`.
- Masking of the six competing agent providers, the `/etc/X11/Xsession.d/90x11-common_ssh-agent` rename (sudo), and the session wiring through `~/.xsessionrc` and `~/.zshrc`.
- `install.sh` with Steps 1–9 and a README with manual steps, verification, troubleshooting, second-computer deployment, and stock-behavior restore instructions.

[0.2.0]: https://github.com/dhuseby/ssh-keepass-proxy/releases/tag/v0.2.0
[0.1.0]: https://github.com/dhuseby/ssh-keepass-proxy/releases/tag/v0.1.0
