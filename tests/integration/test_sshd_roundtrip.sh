#!/usr/bin/env bash
# tests/integration/test_sshd_roundtrip.sh — full data-plane proof (TDD core).
#
# User-mode sshd on a random high port (22000-29999) + a loopback echo service
# ("the remote machine's service"). tunnel_start builds a ControlMaster, and we
# assert a real payload round-trips through 127.0.0.1:<local_port>. Then
# tunnel_stop must tear everything down: listener gone, socket removed, master
# dead, and NO residual ssh/sshd processes.
#
# Auth uses ssh-agent: frozen ssh args include -F /dev/null (which makes ssh
# ignore $HOME for identity files), so the client key must be offered by an agent.
#
# Cleanup is strictly PID/tree-scoped — never a broad `pkill -f <pattern>`,
# which can match this very script's argv and kill the test.
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
if ! declare -F t_file_exists >/dev/null 2>&1; then
  t_file_exists() {
    if [[ -e "${1}" ]]; then
      T2_PASS=$((T2_PASS + 1))
    else
      T2_FAIL=$((T2_FAIL + 1))
      printf '    FAIL: missing file [%s]\n' "${1}" >&2
    fi
  }
fi
if ! declare -F t_done >/dev/null 2>&1; then
  t_done() {
    printf '\n[t2 fallback] pass=%d fail=%d\n' "${T2_PASS}" "${T2_FAIL}"
    if ((T2_FAIL > 0)); then exit 1; fi
  }
fi

# Capture stdout/rc without tripping `set -e`.
T2_OUT=""
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
  if ((T2_RC != 0)) && [[ -n ${T2_ERR} ]]; then
    printf '    [t2_run %s] rc=%d stderr:\n%s\n' "${1}" "${T2_RC}" "${T2_ERR}" >&2
  fi
}

command -v sshd >/dev/null 2>&1 || {
  printf 'integration requires sshd (OpenSSH server)\n' >&2
  exit 1
}
command -v ssh-keygen >/dev/null 2>&1 || {
  printf 'integration requires ssh-keygen\n' >&2
  exit 1
}
if ! command -v python3 >/dev/null 2>&1; then
  printf 'integration requires python3 for the echo service\n' >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Isolation: state + keys live in TMPDIR. The state dir name intentionally
# contains "herdr-forward" so a `ssh.*herdr-forward` zombie pattern is meaningful.
# ---------------------------------------------------------------------------
T2_TMP="$(mktemp -d "${TMPDIR:-/tmp}/t2-roundtrip.XXXXXX")"
export HERDR_PLUGIN_STATE_DIR="${T2_TMP}/herdr-forward"
export HERDR_PLUGIN_CONFIG_DIR="${T2_TMP}/config"
export HOME="${T2_TMP}"
mkdir -p "${HERDR_PLUGIN_CONFIG_DIR}"

SSHD_PID=""
ECHO_PID=""
AGENT_PID=""
TUNNEL_ID=""
LOCAL_PORT=""

# Kill a pid plus its full recursive descendant tree (PID-scoped, no patterns).
t2_kill_tree() {
  local root="${1:-}"
  [[ ${root} =~ ^[0-9]+$ ]] || return 0
  local kids child
  kids="$(pgrep -P "${root}" 2>/dev/null || true)"
  for child in ${kids}; do
    t2_kill_tree "${child}"
  done
  kill -KILL "${root}" 2>/dev/null || true
}

cleanup() {
  local rc=$?
  set +e
  if [[ -n ${TUNNEL_ID} ]]; then
    # shellcheck source=/dev/null
    (
      source "${T2_ROOT}/lib/tunnel.sh"
      tunnel_stop "${TUNNEL_ID}"
    ) >/dev/null 2>&1
  fi
  t2_kill_tree "${ECHO_PID}"
  t2_kill_tree "${SSHD_PID}"
  if [[ -n ${AGENT_PID} ]]; then
    kill -TERM "${AGENT_PID}" 2>/dev/null
    t2_kill_tree "${AGENT_PID}"
  fi
  rm -rf "${T2_TMP}"
  return "${rc}"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# t2_free_port -> stdout: an unused TCP port in 22000-29999.
t2_free_port() {
  local candidates=""
  candidates="$(shuf -i 22000-29999 -n 100)"
  local candidate
  while read -r candidate; do
    if ! (exec 3<>"/dev/tcp/127.0.0.1/${candidate}") 2>/dev/null; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done <<<"${candidates}"
  printf '0\n'
}

# Wait until a TCP port accepts connections (bounded).
t2_wait_port() {
  local port="${1}"
  local tries=0
  while ((tries < 50)); do
    if (exec 3<>"/dev/tcp/127.0.0.1/${port}") 2>/dev/null; then
      return 0
    fi
    tries=$((tries + 1))
    sleep 0.1
  done
  return 1
}

# t2_roundtrip <local_port> <payload> -> stdout: server reply (empty on failure).
t2_roundtrip() {
  local port="${1}"
  local payload="${2}"
  timeout 10 bash -c "exec 3<>/dev/tcp/127.0.0.1/${port}; printf '%s\n' '${payload}' >&3; IFS= read -r -t 5 line <&3; printf '%s' \"\${line}\"" 2>/dev/null || true
}

SSHD_PORT="$(t2_free_port)"
REMOTE_PORT="$(t2_free_port)"
[[ ${SSHD_PORT} != "0" && ${REMOTE_PORT} != "0" ]] || {
  printf 'could not allocate test ports\n' >&2
  exit 1
}

# --- keys ------------------------------------------------------------------
ssh-keygen -q -t ed25519 -N '' -f "${T2_TMP}/hostkey"
ssh-keygen -q -t ed25519 -N '' -f "${T2_TMP}/clientkey"
cp "${T2_TMP}/clientkey.pub" "${T2_TMP}/authorized_keys"
chmod 600 "${T2_TMP}/authorized_keys" "${T2_TMP}/clientkey" "${T2_TMP}/hostkey"

SSH_USER="$(id -un)"

# sshd_config per SCOUT-FACTS §1.3; PerSourcePenalties off keeps failures snappy.
cat >"${T2_TMP}/sshd_config" <<CFG
Port ${SSHD_PORT}
ListenAddress 127.0.0.1
HostKey ${T2_TMP}/hostkey
PidFile ${T2_TMP}/sshd.pid
UsePAM no
PasswordAuthentication no
PubkeyAuthentication yes
PermitRootLogin no
StrictModes no
AuthorizedKeysFile ${T2_TMP}/authorized_keys
LogLevel ERROR
PerSourcePenalties no
CFG
if ! /usr/bin/sshd -t -f "${T2_TMP}/sshd_config" 2>"${T2_TMP}/sshd_t.err"; then
  # Older sshd without PerSourcePenalties: drop the directive and retry.
  grep -v '^PerSourcePenalties' "${T2_TMP}/sshd_config" >"${T2_TMP}/sshd_config.2"
  mv "${T2_TMP}/sshd_config.2" "${T2_TMP}/sshd_config"
  /usr/bin/sshd -t -f "${T2_TMP}/sshd_config" 2>>"${T2_TMP}/sshd_t.err" || {
    printf 'sshd -t rejected config:\n' >&2
    cat "${T2_TMP}/sshd_t.err" >&2
    exit 1
  }
fi

# --- echo service (the "remote machine" service) ---------------------------
cat >"${T2_TMP}/echo.py" <<'PY'
import socket, sys, threading

server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(("127.0.0.1", int(sys.argv[1])))
server.listen(16)


def handle(conn):
    try:
        stream = conn.makefile("rwb")
        for _line in stream:
            stream.write(b"pong\n")
            stream.flush()
    except Exception:
        pass
    finally:
        conn.close()


while True:
    try:
        client, _ = server.accept()
    except Exception:
        break
    threading.Thread(target=handle, args=(client,), daemon=True).start()
PY

ssh-agent -a "${T2_TMP}/agent.sock" -s >"${T2_TMP}/agent.env"
# shellcheck source=/dev/null
export SSH_AGENT_PID=""
# shellcheck source=/dev/null
source "${T2_TMP}/agent.env" >/dev/null
AGENT_PID="${SSH_AGENT_PID:-}"
export SSH_AUTH_SOCK
ssh-add "${T2_TMP}/clientkey" >/dev/null 2>&1

t_describe "fixture: user-mode sshd + echo service on loopback"
t_it "sshd starts and listens on the random high port"
/usr/bin/sshd -f "${T2_TMP}/sshd_config" -E "${T2_TMP}/sshd.log"
SSHD_PID="$(cat "${T2_TMP}/sshd.pid")"
t2_wait_port "${SSHD_PORT}"
t_eq "0" "$?" "sshd listening"

python3 "${T2_TMP}/echo.py" "${REMOTE_PORT}" &
ECHO_PID=$!
disown "${ECHO_PID}" 2>/dev/null || true
t2_wait_port "${REMOTE_PORT}"
t_eq "0" "$?" "echo service listening"

t_it "public-key ssh to the fixture works (the agent is honored)"
t2_run timeout 15 ssh -F /dev/null \
  -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
  -o UserKnownHostsFile="${T2_TMP}/known_hosts_direct" \
  -p "${SSHD_PORT}" "${SSH_USER}@127.0.0.1" 'echo DIRECT_OK'
t_eq "0" "${T2_RC}" "direct ssh exit"
t_match 'DIRECT_OK' "${T2_OUT}" "direct ssh ran a command"

# --- load the library under test -------------------------------------------
T2_TUNNEL="${T2_ROOT}/lib/tunnel.sh"
if [[ ! -f "${T2_TUNNEL}" ]]; then
  printf 'RED: %s not implemented yet\n' "${T2_TUNNEL}" >&2
  exit 1
fi
# shellcheck source=/dev/null
source "${T2_TUNNEL}"

t_describe "tunnel_start creates a live ControlMaster"
LOCAL_PORT="$(t2_free_port)"
TUNNEL_ID="f-${LOCAL_PORT}"
t2_run tunnel_start "${TUNNEL_ID}" "${LOCAL_PORT}" "127.0.0.1:${REMOTE_PORT}" "${SSH_USER}@127.0.0.1:${SSHD_PORT}"
t_eq "0" "${T2_RC}" "tunnel_start exit"
MASTER_PID="${T2_OUT}"
t_match '^[0-9]+$' "${MASTER_PID}" "stdout is the master pid"
t_file_exists "${HERDR_PLUGIN_STATE_DIR}/ssh-ctl/ctl-${TUNNEL_ID}"
t_it "master pid is alive and the local port is listening"
t2_run tunnel_alive "${MASTER_PID}"
t_eq "true" "${T2_OUT}" "master alive"
t2_run tunnel_probe "${LOCAL_PORT}"
t_eq "up" "${T2_OUT}" "local port probes up (payload round-trip)"
t_it "master pid matches the local listener owner"
t2_cap_ss="$(ss -ltnp 2>/dev/null | grep ":${LOCAL_PORT} " || true)"
t_match "pid=${MASTER_PID}" "${t2_cap_ss}" "ss shows the master pid as listener owner"

t_describe "data plane: payload round-trips through the tunnel"
t_it "ping over 127.0.0.1:<local_port> returns pong"
t2_cap_rt="$(t2_roundtrip "${LOCAL_PORT}" ping)"
t_eq "pong" "${t2_cap_rt}" "tunneled echo reply"
t_it "a second request also round-trips (forward is stable)"
t2_cap_rt="$(t2_roundtrip "${LOCAL_PORT}" ping)"
t_eq "pong" "${t2_cap_rt}" "second tunneled reply"

t_describe "tunnel_stop tears the tunnel down"
tunnel_stop "${TUNNEL_ID}"
t_it "local port stops accepting connections"
sleep 0.3
t2_run tunnel_probe "${LOCAL_PORT}"
t_eq "down" "${T2_OUT}" "port closed after stop (down, not just fail)"
t_it "control socket and pid file are removed"
# B.1 的 t_ok 语义是「断言上一条命令成功」。这里位于 if 的 else 分支，$? 是 [[ -e ]]
# 的 1，用 t_ok 会误判为失败 → 必须用无参条件断言语义的 t_pass。
if [[ -e "${HERDR_PLUGIN_STATE_DIR}/ssh-ctl/ctl-${TUNNEL_ID}" ]]; then
  t_fail "control socket still present after stop"
else
  t_pass "control socket removed"
fi
t2_run tunnel_alive "${MASTER_PID}"
t_eq "false" "${T2_OUT}" "master no longer alive"

t_describe "N2: tunnel_stop 清理 log-f-<id>，但保留 known_hosts（刻意行为）"
t_it "stale per-tunnel log file is removed by tunnel_stop"
if [[ -e "${HERDR_PLUGIN_STATE_DIR}/ssh-ctl/log-${TUNNEL_ID}" ]]; then
  t_fail "log file survived tunnel_stop"
else
  t_pass "log-<id> removed"
fi
t_it "known_hosts is intentionally preserved across stops (one-time host key)"
if [[ -e "${HERDR_PLUGIN_STATE_DIR}/ssh-ctl/known_hosts" ]]; then
  t_pass "known_hosts kept (deliberate)"
else
  t_fail "known_hosts should be kept across tunnel_stop"
fi

t_describe "no residual processes"
t_it "no ssh process references this test's state dir"
sleep 0.5
t2_resid="$(pgrep -af -- 'ssh' 2>/dev/null | grep -F "${HERDR_PLUGIN_STATE_DIR}" || true)"
t_eq "" "${t2_resid}" "no lingering ssh for this state dir"
TUNNEL_ID=""

t_done
