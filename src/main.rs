use std::io;
use std::io::{Read, Write};
use std::net::Shutdown;
use std::os::fd::FromRawFd;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use anyhow::{Context, Result, anyhow};
use nix::fcntl::{Flock, FlockArg};
use nix::unistd::getuid;
use tracing::{debug, error, info, warn};

const SD_LISTEN_FDS_START: i32 = 3;

// ssh-agent protocol (RFC draft-miller-ssh-agent) message types used here.
const SSH_AGENTC_REQUEST_IDENTITIES: u8 = 11;
const SSH_AGENT_IDENTITIES_ANSWER: u8 = 12;

fn runtime_dir() -> PathBuf {
    let uid = getuid().as_raw();
    PathBuf::from(format!("/run/user/{uid}"))
}

fn real_agent_socket() -> PathBuf {
    runtime_dir().join("keepassxc-ssh-agent.sock")
}

fn proxy_socket() -> PathBuf {
    runtime_dir().join("ssh-auth-proxy.sock")
}

fn gdbus(args: &[&str]) -> io::Result<std::process::Output> {
    Command::new("gdbus").args(args).output()
}

fn db_unlocked() -> bool {
    let out = match gdbus(&[
        "call",
        "--session",
        "--dest",
        "org.freedesktop.secrets",
        "--object-path",
        "/org/freedesktop/secrets/aliases/default",
        "--method",
        "org.freedesktop.DBus.Properties.Get",
        "org.freedesktop.Secret.Collection",
        "Locked",
    ]) {
        Ok(o) => o,
        Err(e) => {
            warn!("gdbus Get Locked failed: {e}");
            return false;
        }
    };
    let stdout = String::from_utf8_lossy(&out.stdout);
    stdout.contains("false")
}

fn trigger_unlock_prompt() {
    let out = match gdbus(&[
        "call",
        "--session",
        "--dest",
        "org.freedesktop.secrets",
        "--object-path",
        "/org/freedesktop/secrets",
        "--method",
        "org.freedesktop.Secret.Service.Unlock",
        "[objectpath '/org/freedesktop/secrets/aliases/default']",
    ]) {
        Ok(o) => o,
        Err(e) => {
            warn!("gdbus Unlock failed: {e}");
            return;
        }
    };
    let s = String::from_utf8_lossy(&out.stdout);
    if let Some(start) = s.find("objectpath '") {
        let rest = &s[start + "objectpath '".len()..];
        if let Some(end) = rest.find('\'') {
            let prompt = &rest[..end];
            if !prompt.is_empty() && prompt != "/" {
                let _ = Command::new("gdbus")
                    .args([
                        "call",
                        "--session",
                        "--dest",
                        "org.freedesktop.secrets",
                        "--object-path",
                        prompt,
                        "--method",
                        "org.freedesktop.Secret.Prompt.Prompt",
                        "",
                    ])
                    .stdout(std::process::Stdio::null())
                    .status();
            }
        }
    }
}

fn agent_is_up(sock: &Path) -> bool {
    let out = match Command::new("ssh-add")
        .env("SSH_AUTH_SOCK", sock)
        .arg("-l")
        .output()
    {
        Ok(o) => o,
        Err(_) => return false,
    };
    matches!(out.status.code(), Some(0) | Some(1))
}

fn parse_identities_answer(buf: &[u8]) -> Option<usize> {
    if buf.first() != Some(&SSH_AGENT_IDENTITIES_ANSWER) {
        return None;
    }
    if buf.len() < 5 {
        return None;
    }
    let count = u32::from_be_bytes([buf[1], buf[2], buf[3], buf[4]]);
    if count <= 1_000_000 {
        Some(count as usize)
    } else {
        None
    }
}

fn count_identities(sock: &Path) -> Result<usize> {
    let mut stream =
        UnixStream::connect(sock).with_context(|| format!("connecting to {}", sock.display()))?;
    stream
        .write_all(&[0, 0, 0, 1, SSH_AGENTC_REQUEST_IDENTITIES])
        .context("sending identities request")?;

    let mut len_buf = [0u8; 4];
    stream
        .read_exact(&mut len_buf)
        .context("reading agent reply length")?;
    let len = u32::from_be_bytes(len_buf);
    if len == 0 {
        return Err(anyhow!("agent reply length is zero"));
    }
    if len > 1_048_576 {
        return Err(anyhow!("agent reply too long: {len} bytes"));
    }
    let mut payload = vec![0u8; len as usize];
    stream
        .read_exact(&mut payload)
        .context("reading agent reply payload")?;
    parse_identities_answer(&payload).ok_or_else(|| anyhow!("unexpected agent reply"))
}

fn wait_for_db_unlocked(timeout: Duration) -> Result<()> {
    let deadline = Instant::now() + timeout;
    loop {
        if db_unlocked() {
            return Ok(());
        }
        if Instant::now() >= deadline {
            return Err(anyhow!(
                "timed out waiting for KeePassXC database to unlock"
            ));
        }
        std::thread::sleep(Duration::from_millis(250));
    }
}

static UNLOCK_IN_PROGRESS: Mutex<Option<()>> = Mutex::new(None);

fn ensure_unlocked(sock: &Path) -> Result<bool> {
    // The real agent must be up; if it's down, prompting would be pointless.
    if !agent_is_up(sock) {
        return Err(anyhow!(
            "real ssh-agent socket not responding; is keepassxc-ssh-agent.service running?"
        ));
    }

    let _guard = match UNLOCK_IN_PROGRESS.lock() {
        Ok(g) => g,
        Err(_) => return Err(anyhow!("unlock mutex poisoned")),
    };

    // The KeePassXC database lock state is the source of truth. The agent may
    // hold keys whose entries are configured to survive a lock, so we cannot
    // use "agent has identities" as a proxy for "database is unlocked".
    if db_unlocked() {
        return Ok(false);
    }

    info!("KeePassXC locked; triggering unlock prompt");
    trigger_unlock_prompt();
    wait_for_db_unlocked(Duration::from_secs(300))
        .context("waiting for KeePassXC database to unlock")?;
    Ok(true)
}

fn pump(a: UnixStream, b: UnixStream) {
    let a1 = a.try_clone().expect("clone a");
    let b1 = b.try_clone().expect("clone b");
    let t1 = std::thread::spawn(move || copy(a1, b1));
    let _ = copy(b, a);
    let _ = t1.join();
}

fn copy(mut src: UnixStream, mut dst: UnixStream) -> io::Result<u64> {
    let mut total = 0u64;
    let mut buf = [0u8; 16384];
    loop {
        let n = match src.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => n,
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e),
        };
        dst.write_all(&buf[..n])?;
        total += n as u64;
    }
    let _ = dst.shutdown(Shutdown::Write);
    Ok(total)
}

// After this connection triggered the unlock prompt, poll the real agent's
// identity count. KeePassXC loads keys a few seconds after unlock; a nonzero
// count confirms the keys landed here and not in a competing agent. Bounded:
// at most 5 polls 400 ms apart, and errors never block the relay.
fn poll_identities_after_unlock(real: &Path) {
    for attempt in 0..5 {
        if attempt > 0 {
            std::thread::sleep(Duration::from_millis(400));
        }
        match count_identities(real) {
            Ok(n) => {
                if n == 0 {
                    continue;
                }
                info!("real agent holds {n} identities after unlock");
                return;
            }
            Err(e) => {
                warn!("identity count failed: {e:#}");
                return;
            }
        }
    }
    warn!(
        "real agent holds no identities after unlock; KeePassXC may be pinned to a competing agent"
    );
}

fn handle_client(client: UnixStream, real: PathBuf) {
    let real_sock = real.clone();
    let triggered = match ensure_unlocked(&real_sock) {
        Ok(triggered) => triggered,
        Err(e) => {
            error!("unlock/setup failed: {e:#}");
            return;
        }
    };
    if triggered {
        poll_identities_after_unlock(&real);
    }
    let upstream = match UnixStream::connect(&real) {
        Ok(s) => s,
        Err(e) => {
            error!("connect to real agent {}: {e}", real.display());
            return;
        }
    };
    debug!("connected to real agent {}", real.display());
    pump(client, upstream);
}

fn take_socket_activated_listener() -> Option<UnixListener> {
    let n: i32 = std::env::var("LISTEN_FDS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(0);
    if n < 1 {
        return None;
    }
    for i in 0..n {
        let fd = SD_LISTEN_FDS_START + i;
        if let Ok(listener) = unsafe { UnixListener::from_raw_fd(fd) }.try_clone() {
            return Some(listener);
        }
    }
    None
}

fn single_instance_lock() -> Result<bool> {
    let lock_path = runtime_dir().join("ssh-keepass-proxy.lock");
    let f = std::fs::OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(true)
        .open(&lock_path)
        .with_context(|| format!("opening {}", lock_path.display()))?;
    match Flock::lock(f, FlockArg::LockExclusiveNonblock) {
        Ok(_guard) => {
            std::fs::remove_file(&lock_path).ok();
            Ok(true)
        }
        Err((_f, nix::errno::Errno::EWOULDBLOCK)) => Ok(false),
        Err((_, e)) => Err(anyhow!("flock: {e}")),
    }
}

fn make_listener(path: &Path) -> Result<UnixListener> {
    let _ = std::fs::remove_file(path);
    let listener =
        UnixListener::bind(path).with_context(|| format!("binding {}", path.display()))?;
    let _ = std::fs::set_permissions(path, std::os::unix::fs::PermissionsExt::from_mode(0o600));
    Ok(listener)
}

fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .init();

    let real = real_agent_socket();
    let proxy_path = proxy_socket();

    if !real.exists() {
        warn!(
            "real agent socket {} not present; keepassxc-ssh-agent.service may not be running",
            real.display()
        );
    }

    if !single_instance_lock()? {
        debug!("another instance is already running; exiting");
        return Ok(());
    }

    let listener = if let Some(l) = take_socket_activated_listener() {
        info!("socket-activated: using systemd-provided listener");
        l
    } else {
        info!("manual mode: binding {}", proxy_path.display());
        make_listener(&proxy_path)?
    };

    info!("ssh-keepass-proxy listening on {}", proxy_path.display());
    info!("relaying to real agent at {}", real.display());

    loop {
        let (client, peer) = match listener.accept() {
            Ok(v) => v,
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(e) => {
                error!("accept: {e}");
                return Err(e.into());
            }
        };
        let peer_str = peer
            .as_pathname()
            .map(|p| p.display().to_string())
            .unwrap_or_else(|| "<unknown>".to_string());
        debug!("accepted connection from {peer_str}");
        let real = real.clone();
        std::thread::spawn(move || handle_client(client, real));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_buffer_is_rejected() {
        assert_eq!(parse_identities_answer(&[]), None);
    }

    #[test]
    fn truncated_buffer_is_rejected() {
        assert_eq!(parse_identities_answer(&[12, 0, 0, 0]), None);
    }

    #[test]
    fn wrong_reply_type_is_rejected() {
        assert_eq!(parse_identities_answer(&[13, 0, 0, 0, 3]), None);
    }

    #[test]
    fn zero_identities_parses() {
        assert_eq!(parse_identities_answer(&[12, 0, 0, 0, 0]), Some(0));
    }

    #[test]
    fn three_identities_parse() {
        assert_eq!(parse_identities_answer(&[12, 0, 0, 0, 3]), Some(3));
    }

    #[test]
    fn oversize_count_is_rejected() {
        assert_eq!(parse_identities_answer(&[12, 0x00, 0x0F, 0x42, 0x41]), None);
    }

    #[test]
    fn maximum_count_is_accepted() {
        assert_eq!(
            parse_identities_answer(&[12, 0x00, 0x0F, 0x42, 0x40]),
            Some(1_000_000)
        );
    }
}
