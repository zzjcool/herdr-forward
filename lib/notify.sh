#!/usr/bin/env bash
# lib/notify.sh — best-effort herdr toast; NEVER blocks >1s and NEVER fails the caller.
# Frozen API (ARCHITECTURE.md A.3):
#   notify_toast <title> <body>   # herdr socket API; unavailable -> log info, never block >1s
set -Eeuo pipefail

_TUNNEL_NOTIFY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${_TUNNEL_NOTIFY_LIB_DIR}/common.sh" ]]; then
  # shellcheck source=/dev/null
  source "${_TUNNEL_NOTIFY_LIB_DIR}/common.sh"
fi

if ! declare -F log >/dev/null 2>&1; then
  log() {
    local level="${1}"
    shift
    local ts
    ts="$(date '+%Y-%m-%dT%H:%M:%S%z')"
    printf '[%s] %s %s\n' "${ts}" "${level}" "${*}" >&2
  }
fi

# notify_payload <title> <body> -> stdout: one JSON line for the herdr socket.
notify_payload() {
  local title="${1:-}"
  local body="${2:-}"
  if command -v jq >/dev/null 2>&1; then
    jq -cn --arg t "${title}" --arg b "${body}" '{type:"toast",title:$t,body:$b}'
    return 0
  fi
  local t="${title//\\/\\\\}"
  t="${t//\"/\\\"}"
  local b="${body//\\/\\\\}"
  b="${b//\"/\\\"}"
  t="${t//$'\n'/\\n}"
  b="${b//$'\n'/\\n}"
  printf '{"type":"toast","title":"%s","body":"%s"}\n' "${t}" "${b}"
}

# --- transports (each expects: <socket_path> <payload>) ---
_notify_send_python() {
  python3 -c 'import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(1)
s.connect(sys.argv[1])
s.sendall(sys.argv[2].encode() + b"\n")
s.close()' "${1}" "${2}"
}

_notify_send_socat() {
  printf '%s\n' "${2}" | socat - "UNIX-CONNECT:${1}"
}

_notify_send_nc() {
  printf '%s\n' "${2}" | nc -U "${1}"
}

# notify_send <socket_path> <payload> -> 0 on delivery, 1 otherwise. Bounded by a
# 1s watchdog so a wedged sink can never hang the caller.
notify_send() {
  local sock="${1}"
  local payload="${2}"
  local fn=""
  if command -v python3 >/dev/null 2>&1; then
    fn="_notify_send_python"
  elif command -v socat >/dev/null 2>&1; then
    fn="_notify_send_socat"
  elif command -v nc >/dev/null 2>&1; then
    fn="_notify_send_nc"
  else
    return 1
  fi

  "${fn}" "${sock}" "${payload}" >/dev/null 2>&1 &
  local pid=$!
  local waits=0
  while ((waits < 10)); do
    if ! kill -0 "${pid}" 2>/dev/null; then
      break
    fi
    waits=$((waits + 1))
    sleep 0.1
  done
  if kill -0 "${pid}" 2>/dev/null; then
    kill -KILL "${pid}" 2>/dev/null || true
    wait "${pid}" 2>/dev/null || true
    return 1
  fi
  wait "${pid}" 2>/dev/null || return 1
  return 0
}

# notify_toast <title> <body> — try the herdr socket; any failure degrades to log.
# Always returns 0 so callers can treat notification as fire-and-forget.
notify_toast() {
  local title="${1:-}"
  local body="${2:-}"
  local sock="${HERDR_SOCKET_PATH:-}"
  if [[ -n ${sock} && -S ${sock} && -w ${sock} ]]; then
    local payload=""
    payload="$(notify_payload "${title}" "${body}")"
    local sent=1
    if [[ -n ${payload} ]]; then
      local send_rc=0
      set +e
      notify_send "${sock}" "${payload}"
      send_rc=$?
      set -e
      if ((send_rc != 0)); then sent=0; fi
    fi
    if ((sent)); then
      log debug "notify: toast sent via ${sock}"
      return 0
    fi
    log debug "notify: socket ${sock} unusable, degrading to log"
  fi
  log info "notify: ${title}${body:+ — ${body}}"
  return 0
}
