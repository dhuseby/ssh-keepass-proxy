#!/usr/bin/env bash
# ssh-keepass-doctor: check, repair, and purge tool for the ssh-keepass-proxy setup.
#
# Default mode checks every component and changes nothing.
#   --fix    repairs configuration drift; never kills a process
#   --purge  applies --fix and also stops stray ssh-agent processes (asks first)
#
# Runs at user level; never uses sudo. Repairs cover the KeePassXC pins, the
# xfce4-session agent, the session-wide SSH_AUTH_SOCK wiring, and the systemd
# user environment.
set -euo pipefail

MODE="check"
case "${1:-}" in
  "") ;;
  --fix) MODE="fix" ;;
  --purge) MODE="purge" ;;
  -h|--help) printf 'usage: %s [--fix] [--purge]\n' "${0##*/}"; exit 0 ;;
  *)
    printf '%s: unknown option: %s\nusage: %s [--fix] [--purge]\n' "${0##*/}" "$1" "${0##*/}" >&2
    exit 2
    ;;
esac

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UID_NUM="$(id -u)"
RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/${UID_NUM}}"
REAL_SOCK="${RUNTIME_DIR}/keepassxc-ssh-agent.sock"
PROXY_SOCK="${RUNTIME_DIR}/ssh-auth-proxy.sock"
AUTOSTART_FILE="${HOME}/.config/autostart/org.keepassxc.KeePassXC.desktop"
TEMPLATE="${REPO_DIR}/config/autostart/org.keepassxc.KeePassXC.desktop"
CACHE_INI="${XDG_CACHE_HOME:-${HOME}/.cache}/keepassxc/keepassxc.ini"
ENV_D_FILE="${XDG_CONFIG_HOME:-${HOME}/.config}/environment.d/ssh.conf"
LOCK_FILE="${RUNTIME_DIR}/ssh-keepass-doctor.lock"
COMPETING=(
  gcr-ssh-agent.service
  gcr-ssh-agent.socket
  gnome-keyring-daemon.service
  gnome-keyring-daemon.socket
  gpg-agent-ssh.socket
  ssh-agent.socket
)

# Exit code: 0 healthy (or fully repaired), 1 problems remain, 2 environment error.
RESULT=0
declare -A STRAY_SOCK=()

log()   { printf '%s\n' "$*"; }
ok()    { log "[ok] $*"; }
warn()  { log "[warn] $*"; }
drift() { log "[drift] $*"; if [ "${RESULT}" -lt 1 ]; then RESULT=1; fi; }
err()   { log "[error] $*"; RESULT=2; }
fixed() { log "[fixed] $*"; }

keepassxc_running() { pgrep -x keepassxc >/dev/null 2>&1; }

manager_ssh_auth_sock() {
  systemctl --user show-environment 2>/dev/null | sed -n 's/^SSH_AUTH_SOCK=//p' | head -n 1
}

# ini_get FILE SECTION KEY: print the value of KEY inside [SECTION], else nothing.
# Reads per key; never prints or changes other lines.
ini_get() {
  awk -v sec="[${2}]" -v key="${3}" '
    { sub(/\r$/, "") }
    $0 == sec { insec = 1; next }
    insec && index($0, key "=") == 1 { sub(/^[^=]*=/, ""); print; exit }
    insec && /^\[/ { exit }
  ' "${1}" 2>/dev/null || true
}

# ini_set_key FILE SECTION KEY VALUE: write KEY=VALUE inside [SECTION] via a
# temp file and mv; every other line, including @Variant(...) values, stays
# byte-identical.
ini_set_key() {
  local file="$1" sec="$2" key="$3" val="$4" tmp mode
  mode="$(stat -c '%a' "${file}")"
  tmp="$(mktemp "${file}.XXXXXX")"
  awk -v sec="[${sec}]" -v key="${key}" -v val="${val}" '
    { sub(/\r$/, "") }
    $0 == sec { print; insec = 1; seen = 1; next }
    insec && index($0, key "=") == 1 { print key "=" val; done = 1; next }
    insec && /^\[/ { print key "=" val; done = 1; insec = 0; print; next }
    { print }
    END {
      if (insec && !done) { print key "=" val; done = 1 }
      if (!seen && !done) { print ""; print sec; print key "=" val }
    }
  ' "${file}" > "${tmp}"
  chmod "${mode}" "${tmp}"
  mv "${tmp}" "${file}"
}

find_strays() {
  STRAY_SOCK=()
  local main_pid pid comm cmdline sock found=0
  main_pid="$(systemctl --user show -P MainPID keepassxc-ssh-agent.service 2>/dev/null || echo 0)"
  if [ -z "${main_pid}" ]; then main_pid=0; fi
  for pid in $(pgrep -x ssh-agent 2>/dev/null || true); do
    comm="$(cat "/proc/${pid}/comm" 2>/dev/null || true)"
    if [ "${comm}" != "ssh-agent" ]; then continue; fi
    if [ "${pid}" = "${main_pid}" ]; then continue; fi
    cmdline="$(tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null || printf '?')"
    sock=""
    if command -v lsof >/dev/null 2>&1; then
      sock="$(lsof -a -p "${pid}" -U 2>/dev/null | awk '$5 == "unix" { print $NF }' | grep -E '^/' | tail -n 1 || true)"
    fi
    STRAY_SOCK["${pid}"]="${sock}"
    if [ -n "${sock}" ]; then
      drift "stray ssh-agent pid ${pid}: ${cmdline} (socket: ${sock})"
    else
      drift "stray ssh-agent pid ${pid}: ${cmdline} (no listening socket found)"
    fi
    found=1
  done
  if [ "${found}" -eq 0 ]; then
    ok "no stray ssh-agent processes"
  fi
  return 0
}

check_identities() {
  if [ ! -S "${REAL_SOCK}" ]; then
    return 0
  fi
  local tmp rc
  rc=0
  tmp="$(mktemp)"
  SSH_AUTH_SOCK="${REAL_SOCK}" ssh-add -l > "${tmp}" 2>&1 || rc=$?
  case "${rc}" in
    0) ok "real agent holds $(grep -c . "${tmp}") identities" ;;
    1) warn "real agent holds 0 identities; run the doctor again after you unlock the database" ;;
    2) warn "ssh-add cannot reach the real agent (is keepassxc-ssh-agent.service running?)" ;;
    *) err "real agent identity check failed (ssh-add exit ${rc}): $(tail -n 1 "${tmp}")" ;;
  esac
  rm -f "${tmp}"
}

run_checks() {
  RESULT=0
  local val

  # 1. proxy units: the socket unit must be enabled and active; the service
  #    unit is socket-activated, so inactive/disabled is normal for it.
  val="$(systemctl --user is-active ssh-keepass-proxy.socket 2>/dev/null || true)"
  local val2
  val2="$(systemctl --user is-enabled ssh-keepass-proxy.socket 2>/dev/null || true)"
  if [ "${val}" = "active" ] && [ "${val2}" = "enabled" ]; then
    ok "proxy socket unit: active, enabled"
  else
    drift "proxy socket unit: is-active=${val:-unknown} is-enabled=${val2:-unknown} (want active, enabled)"
  fi
  val="$(systemctl --user is-active ssh-keepass-proxy.service 2>/dev/null || true)"
  val2="$(systemctl --user is-enabled ssh-keepass-proxy.service 2>/dev/null || true)"
  log "[info] proxy service unit: is-active=${val:-unknown} is-enabled=${val2:-unknown} (inactive and disabled are normal for a socket-activated unit)"

  # 2. real agent service
  val="$(systemctl --user is-active keepassxc-ssh-agent.service 2>/dev/null || true)"
  if [ "${val}" = "active" ]; then
    ok "keepassxc-ssh-agent.service active"
  else
    drift "keepassxc-ssh-agent.service: is-active=${val:-unknown} (want active)"
  fi

  # 3. socket files
  if [ -S "${PROXY_SOCK}" ]; then
    ok "proxy socket file present: ${PROXY_SOCK}"
  else
    drift "proxy socket file missing: ${PROXY_SOCK}"
  fi
  if [ -S "${REAL_SOCK}" ]; then
    ok "real agent socket file present: ${REAL_SOCK}"
  else
    drift "real agent socket file missing: ${REAL_SOCK}"
  fi

  # 4. autostart wrapper file
  val="Exec=env SSH_AUTH_SOCK=${REAL_SOCK} keepassxc"
  if [ -f "${AUTOSTART_FILE}" ] && grep -Fqx "${val}" "${AUTOSTART_FILE}"; then
    ok "autostart wrapper file pinned to the real agent socket"
  elif [ -f "${AUTOSTART_FILE}" ]; then
    drift "autostart wrapper file Exec= line is not '${val}'"
  else
    drift "autostart wrapper file missing: ${AUTOSTART_FILE}"
  fi

  # 5. KeePassXC socket override
  val=""
  if [ -f "${CACHE_INI}" ]; then
    val="$(ini_get "${CACHE_INI}" SSHAgent AuthSockOverride)"
  fi
  if [ "${val}" = "${REAL_SOCK}" ]; then
    ok "KeePassXC socket override pinned to the real agent socket"
  else
    drift "KeePassXC socket override AuthSockOverride is '${val}' (want '${REAL_SOCK}')"
  fi

  # 6. competing provider units stay masked
  local unit st
  for unit in "${COMPETING[@]}"; do
    st="$(systemctl --user is-enabled "${unit}" 2>/dev/null || true)"
    if [ "${st}" = "masked" ]; then
      ok "${unit} masked"
    else
      drift "${unit} not masked (is-enabled=${st:-unknown})"
    fi
  done

  # 7. Xsession ssh-agent wrapper stays absent
  if [ -e /etc/X11/Xsession.d/90x11-common_ssh-agent ]; then
    drift "/etc/X11/Xsession.d/90x11-common_ssh-agent exists (want absent)"
  else
    ok "Xsession ssh-agent wrapper absent"
  fi

  # 8. xfce4-session built-in ssh-agent stays disabled
  val="$(xfconf-query -c xfce4-session -p /startup/ssh-agent/enabled 2>/dev/null || true)"
  if [ "${val}" = "false" ]; then
    ok "xfce4-session built-in ssh-agent disabled"
  else
    drift "xfce4-session /startup/ssh-agent/enabled='${val:-missing}' (want false)"
  fi

  # 9. session-wide SSH_AUTH_SOCK: the systemd user manager must not point at
  #    a competing agent. The 257 manager rebuilds its environment base from
  #    environment.d files, and unset-environment cannot remove a base value,
  #    so the base file carries the proxy socket and the live value must be
  #    the proxy socket or absent.
  if [ -f "${ENV_D_FILE}" ] && grep -Fqx "SSH_AUTH_SOCK=${PROXY_SOCK}" "${ENV_D_FILE}"; then
    ok "environment.d ssh.conf pins the proxy socket"
  else
    drift "environment.d/ssh.conf does not pin SSH_AUTH_SOCK=${PROXY_SOCK}"
  fi
  val="$(manager_ssh_auth_sock)"
  case "${val}" in
    "") ok "systemd user environment has no SSH_AUTH_SOCK" ;;
    "${PROXY_SOCK}") ok "systemd user environment carries the proxy socket" ;;
    *) drift "systemd user environment SSH_AUTH_SOCK='${val}' (want '${PROXY_SOCK}' or unset)" ;;
  esac

  # 10. stray ssh-agent processes
  find_strays

  # 11. identities in the real agent
  check_identities
}

apply_fixes() {
  local val tmp

  # 4. restore the autostart wrapper file from the repo template
  val="Exec=env SSH_AUTH_SOCK=${REAL_SOCK} keepassxc"
  if [ -f "${AUTOSTART_FILE}" ] && grep -Fqx "${val}" "${AUTOSTART_FILE}"; then
    :
  else
    if [ -f "${TEMPLATE}" ]; then
      mkdir -p "$(dirname "${AUTOSTART_FILE}")"
      tmp="$(mktemp "$(dirname "${AUTOSTART_FILE}")/org.keepassxc.KeePassXC.desktop.XXXXXX")"
      sed "s/__UID__/${UID_NUM}/g" "${TEMPLATE}" > "${tmp}"
      chmod 0644 "${tmp}"
      mv "${tmp}" "${AUTOSTART_FILE}"
      fixed "restored ${AUTOSTART_FILE} from the repo template"
    else
      err "repo template missing: ${TEMPLATE}"
    fi
  fi

  # 5. write the KeePassXC socket override (only while KeePassXC is closed)
  if [ -f "${CACHE_INI}" ]; then
    if [ "$(ini_get "${CACHE_INI}" SSHAgent AuthSockOverride)" != "${REAL_SOCK}" ]; then
      if keepassxc_running; then
        warn "KeePassXC is running; skip writing ${CACHE_INI} (KeePassXC overwrites the file on exit); use the KeePassXC GUI SSH_AUTH_SOCK override field, or close KeePassXC and re-run with --fix"
      else
        ini_set_key "${CACHE_INI}" SSHAgent AuthSockOverride "${REAL_SOCK}"
        fixed "wrote AuthSockOverride=${REAL_SOCK} into ${CACHE_INI}"
      fi
    fi
  else
    warn "cannot repair the override; ${CACHE_INI} is missing"
  fi

  # 8. disable the xfce4-session built-in ssh-agent
  val="$(xfconf-query -c xfce4-session -p /startup/ssh-agent/enabled 2>/dev/null || true)"
  if [ "${val}" != "false" ]; then
    if xfconf-query -c xfce4-session -p /startup/ssh-agent/enabled -n -t bool -s false >/dev/null 2>&1; then
      fixed "created xfconf property /startup/ssh-agent/enabled=false"
    else
      warn "failed to create the xfconf property /startup/ssh-agent/enabled"
    fi
  fi

  # 9. pin the proxy socket in the environment.d base, then refresh the
  #    manager: the 257 manager derives its base environment from
  #    environment.d files and unset-environment cannot remove a base value,
  #    so a correct file plus a reload is the only live repair.
  if [ -f "${ENV_D_FILE}" ] && grep -Fqx "SSH_AUTH_SOCK=${PROXY_SOCK}" "${ENV_D_FILE}"; then
    :
  else
    if mkdir -p "$(dirname "${ENV_D_FILE}")"; then
      tmp="$(mktemp "${ENV_D_FILE}.XXXXXX")"
      printf 'SSH_AUTH_SOCK=%s\n' "${PROXY_SOCK}" > "${tmp}"
      chmod 0644 "${tmp}"
      mv "${tmp}" "${ENV_D_FILE}"
      fixed "wrote SSH_AUTH_SOCK=${PROXY_SOCK} into ${ENV_D_FILE}"
    else
      warn "cannot create $(dirname "${ENV_D_FILE}")"
    fi
  fi
  val="$(manager_ssh_auth_sock)"
  if [ -n "${val}" ] && [ "${val}" != "${PROXY_SOCK}" ]; then
    systemctl --user daemon-reload >/dev/null 2>&1 || true
    systemctl --user unset-environment SSH_AUTH_SOCK >/dev/null 2>&1 || true
    val="$(manager_ssh_auth_sock)"
    if [ -z "${val}" ] || [ "${val}" = "${PROXY_SOCK}" ]; then
      fixed "systemd user environment SSH_AUTH_SOCK is now '${val:-unset}'"
    else
      drift "systemd user environment SSH_AUTH_SOCK='${val}' survived the repair"
    fi
  fi
}

purge_strays() {
  local pid comm sock
  local pids=()
  for pid in "${!STRAY_SOCK[@]}"; do
    comm="$(cat "/proc/${pid}/comm" 2>/dev/null || true)"
    if [ "${comm}" = "ssh-agent" ]; then
      pids+=("${pid}")
    fi
  done
  if [ "${#pids[@]}" -eq 0 ]; then
    log "[info] nothing to purge"
    return 0
  fi
  if [ "${SSH_KEEPASS_PURGE:-}" != "1" ]; then
    printf 'Stop and remove these stray ssh-agent processes? Their loaded keys are lost here; KeePassXC reloads them after the next unlock.\n  pids: %s\n' "${pids[*]}" >&2
    local reply=""
    read -r -p "Proceed? [y/N] " reply || { log "[info] no confirmation received; purge cancelled"; return 1; }
    case "${reply}" in
      y|Y|yes|Yes|YES) ;;
      *) log "[info] purge cancelled"; return 1 ;;
    esac
  fi
  for pid in "${pids[@]}"; do
    sock="${STRAY_SOCK[${pid}]:-}"
    if [ -n "${sock}" ]; then
      SSH_AUTH_SOCK="${sock}" ssh-add -D >/dev/null 2>&1 || true
    fi
    kill "${pid}" 2>/dev/null || true
    sleep 1
    kill -KILL "${pid}" 2>/dev/null || true
    log "[fixed] stopped stray ssh-agent pid ${pid}"
  done
  return 0
}

log "[info] ssh-keepass-doctor ${MODE}: starting"

if [ ! -d "${RUNTIME_DIR}" ]; then
  err "XDG_RUNTIME_DIR is not a directory: ${RUNTIME_DIR}"
  log "[info] doctor finished: environment error"
  exit 2
fi

# The installer holds the doctor lock for its KeePassXC and agent-related
# steps and invokes this script as a child during Step 11; locking again here
# would deadlock against the parent, so SSH_KEEPASS_DOCTOR_NO_LOCK=1 skips
# locking and trusts the parent to hold the lock.
if [ "${SSH_KEEPASS_DOCTOR_NO_LOCK:-}" != "1" ]; then
  exec 9>"${LOCK_FILE}"
  if ! flock -n 9; then
    log "[info] another doctor run holds the lock; waiting"
    flock 9
  fi
fi

run_checks
if [ "${MODE}" = "fix" ]; then
  apply_fixes
  run_checks
elif [ "${MODE}" = "purge" ]; then
  if purge_strays; then
    apply_fixes
  fi
  run_checks
fi

if [ "${RESULT}" -eq 0 ]; then
  log "[info] doctor finished: healthy"
else
  log "[info] doctor finished: problems remain (exit ${RESULT})"
fi
exit "${RESULT}"
