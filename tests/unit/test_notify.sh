#!/usr/bin/env bash
# tests/unit/test_notify.sh — lib/notify.sh: never blocks, always degrades to log.
# Required by task: the degrade path (fake/unavailable socket) must be unit-tested.
set -Eeuo pipefail

T2_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [[ -f "${T2_ROOT}/tests/lib/assertions.sh" ]]; then
  # shellcheck source=/dev/null
  source "${T2_ROOT}/tests/lib/assertions.sh"
fi

# ---------------------------------------------------------------------------
# Fallback assertion subset (T0's tests/lib/ is not writable from T2).
# ---------------------------------------------------------------------------
T2_PASS=0
T2_FAIL=0
if ! declare -F t_describe >/dev/null 2>&1; then
  t_describe() { printf '\n== %s ==\n' "${1}"; }
fi
if ! declare -F t_it >/dev/null 2>&1; then
  t_it() { printf '  - %s\n' "${1}"; }
fi
if ! declare -F t_ok >/dev/null 2>&1; then
  t_ok() { T2_PASS=$((T2_PASS + 1)); }
fi
if ! declare -F t_fail >/dev/null 2>&1; then
  t_fail() {
    T2_FAIL=$((T2_FAIL + 1))
    printf '    FAIL: %s\n' "${1:-}" >&2
  }
fi
if ! declare -F t_eq >/dev/null 2>&1; then
  t_eq() {
    if [[ "${1}" == "${2}" ]]; then
      T2_PASS=$((T2_PASS + 1))
    else
      T2_FAIL=$((T2_FAIL + 1))
      printf '    FAIL: %s\n      expected: [%s]\n      actual:   [%s]\n' "${3:-t_eq}" "${1}" "${2}" >&2
    fi
  }
fi
if ! declare -F t_match >/dev/null 2>&1; then
  t_match() {
    if [[ "${2}" =~ ${1} ]]; then
      T2_PASS=$((T2_PASS + 1))
    else
      T2_FAIL=$((T2_FAIL + 1))
      printf '    FAIL: %s\n      regex:  [%s]\n      actual: [%s]\n' "${3:-t_match}" "${1}" "${2}" >&2
    fi
  }
fi
if ! declare -F t_exit_ok >/dev/null 2>&1; then
  t_exit_ok() {
    if [[ "${1}" == "${2}" ]]; then
      T2_PASS=$((T2_PASS + 1))
    else
      T2_FAIL=$((T2_FAIL + 1))
      printf '    FAIL: %s expected exit [%s] got [%s]\n' "${3:-t_exit_ok}" "${1}" "${2}" >&2
    fi
  }
fi
if ! declare -F t_json_valid >/dev/null 2>&1; then
  t_json_valid() {
    if command -v jq >/dev/null 2>&1 && jq empty "${1}" >/dev/null 2>&1; then
      T2_PASS=$((T2_PASS + 1))
    else
      T2_FAIL=$((T2_FAIL + 1))
      printf '    FAIL: invalid json [%s]\n' "${1}" >&2
    fi
  }
fi
if ! declare -F t_done >/dev/null 2>&1; then
  t_done() {
    printf '\n[t2 fallback] pass=%d fail=%d\n' "${T2_PASS}" "${T2_FAIL}"
    if ((T2_FAIL > 0)); then exit 1; fi
  }
fi

T2_OUT=""
T2_ERR=""
T2_RC=0
t2_run() {
  local out_file err_file
  out_file="$(mktemp)"
  err_file="$(mktemp)"
  set +e
  ("$@") >"${out_file}" 2>"${err_file}"
  T2_RC=$?
  set -e
  T2_OUT="$(<"${out_file}")"
  T2_ERR="$(<"${err_file}")"
  rm -f "${out_file}" "${err_file}"
}

# Sets T2_LOGGED=1 when the degrade message reached stderr or forward.log.
t2_logged() {
  local needle="${1}"
  T2_LOGGED=0
  if [[ ${T2_ERR} == *"${needle}"* ]]; then
    T2_LOGGED=1
    return 0
  fi
  local log_file="${HERDR_PLUGIN_STATE_DIR}/logs/forward.log"
  if [[ -f ${log_file} ]] && grep -qF -- "${needle}" "${log_file}"; then
    T2_LOGGED=1
  fi
  return 0
}

T2_TMP="$(mktemp -d "${TMPDIR:-/tmp}/t2-notify.XXXXXX")"
trap 'rm -rf "${T2_TMP}"' EXIT
export HERDR_PLUGIN_STATE_DIR="${T2_TMP}/herdr-forward"

T2_NOTIFY="${T2_ROOT}/lib/notify.sh"
if [[ ! -f "${T2_NOTIFY}" ]]; then
  printf 'RED: %s not implemented yet\n' "${T2_NOTIFY}" >&2
  exit 1
fi
# shellcheck source=/dev/null
source "${T2_NOTIFY}"

t_describe "notify_payload (JSON line construction)"
if command -v jq >/dev/null 2>&1; then
  t_it "produces a single valid JSON line carrying title and body"
  t2_run notify_payload 'Build failed' 'port 3000 down'
  t_eq "0" "${T2_RC}" "exit"
  t2_file="${T2_TMP}/payload.json"
  printf '%s\n' "${T2_OUT}" >"${t2_file}"
  t_json_valid "${t2_file}"
  t_match 'Build failed' "${T2_OUT}" "title present"
  t_match 'port 3000 down' "${T2_OUT}" "body present"
  t_it "escapes embedded double quotes so the JSON stays valid"
  t2_run notify_payload 'say "hi"' 'a "b" c'
  printf '%s\n' "${T2_OUT}" >"${t2_file}"
  t_json_valid "${t2_file}"
  t_match '\\"hi\\"' "${T2_OUT}" "escaped quote"
else
  t_it "jq absent: payload still produced without crashing"
  t2_run notify_payload 't' 'b'
  t_eq "0" "${T2_RC}" "exit"
fi

t_describe "notify_toast degrade paths (must never fail nor block >1s)"
t_it "HERDR_SOCKET_PATH unset -> returns 0 and logs the message"
unset HERDR_SOCKET_PATH || true
t2_run notify_toast 'Title A' 'Body A'
t_exit_ok 0 "${T2_RC}" "exit 0"
t2_logged 'Title A'
if ((T2_LOGGED)); then
  t_ok "degraded to log"
else
  t_fail "degrade message not found on stderr or forward.log"
fi
t_it "HERDR_SOCKET_PATH points at a nonexistent path -> returns 0"
export HERDR_SOCKET_PATH="${T2_TMP}/does-not-exist.sock"
t2_run notify_toast 'Title B' 'Body B'
t_exit_ok 0 "${T2_RC}" "exit 0"
t_it "HERDR_SOCKET_PATH points at a regular file -> returns 0"
export HERDR_SOCKET_PATH="${T2_TMP}/regular.file"
: >"${HERDR_SOCKET_PATH}"
t2_run notify_toast 'Title C' 'Body C'
t_exit_ok 0 "${T2_RC}" "exit 0"
t_it "no arguments -> returns 0 (never crashes the caller)"
unset HERDR_SOCKET_PATH || true
t2_run notify_toast
t_exit_ok 0 "${T2_RC}" "exit 0"

t_describe "notify_toast bounded on a blocking sink (FIFO)"
if command -v mkfifo >/dev/null 2>&1; then
  t_it "FIFO with no reader: returns 0 within ~2s (watchdog)"
  export HERDR_SOCKET_PATH="${T2_TMP}/blocking.fifo"
  mkfifo "${HERDR_SOCKET_PATH}"
  t2_start="${SECONDS}"
  set +e
  (notify_toast 'Fifo' 'Body') >/dev/null 2>&1
  t2_rc_fifo=$?
  set -e
  t2_elapsed=$((SECONDS - t2_start))
  t_exit_ok 0 "${t2_rc_fifo}" "exit 0"
  if ((t2_elapsed <= 2)); then
    t_ok "bounded"
  else
    t_fail "blocked for ${t2_elapsed}s"
  fi
else
  t_it "mkfifo absent: bounded-sink case skipped (no mkfifo)"
  t_ok "skipped"
fi

t_describe "notify_toast positive path on a real unix socket (guarded)"
if command -v python3 >/dev/null 2>&1; then
  t_it "JSON line delivered to a listening AF_UNIX socket"
  t2_sock="${T2_TMP}/herdr.sock"
  t2_recv="${T2_TMP}/received.txt"
  cat >"${T2_TMP}/srv.py" <<'PY'
import socket, sys
path, out = sys.argv[1], sys.argv[2]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(path)
s.listen(1)
s.settimeout(5)
try:
    conn, _ = s.accept()
    conn.settimeout(5)
    data = b""
    while b"\n" not in data:
        chunk = conn.recv(4096)
        if not chunk:
            break
        data += chunk
    with open(out, "wb") as fh:
        fh.write(data)
    conn.close()
except Exception:
    pass
finally:
    s.close()
PY
  timeout 10 python3 "${T2_TMP}/srv.py" "${t2_sock}" "${t2_recv}" &
  t2_srv=$!
  t2_waited=0
  while [[ ! -S "${t2_sock}" ]] && ((t2_waited < 50)); do
    sleep 0.1
    t2_waited=$((t2_waited + 1))
  done
  export HERDR_SOCKET_PATH="${t2_sock}"
  t2_run notify_toast 'Live Title' 'Live Body'
  t_exit_ok 0 "${T2_RC}" "exit 0"
  wait "${t2_srv}" 2>/dev/null || true
  if [[ -s "${t2_recv}" ]]; then
    t_match 'Live Title' "$(<"${t2_recv}")" "payload delivered"
  else
    t_fail "no payload received on the unix socket"
  fi
else
  t_it "python3 absent: positive socket case skipped"
  t_ok "skipped"
fi

t_done
