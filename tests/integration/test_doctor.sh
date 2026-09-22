#!/usr/bin/env bash
# tests/integration/test_doctor.sh — `forward doctor` reconcile semantics via the
# tunnel liveness primitives (A.3: default report / --fix repairs / --prune clears).
#
# Scenario: a live tunnel is recorded in state, then its remote sshd is destroyed.
#   * tunnel_health      -> down
#   * tunnel_doctor      -> reports `down`, exit 0 (report never mutates)
#   * tunnel_doctor --fix   -> flips the record to status=down
#   * tunnel_doctor --prune -> removes the dead record entirely
# and afterwards there is NO zombie ssh left behind.
#
# T1's lib/state.sh is not merged yet, so this test installs an inline jq-backed
# state double that satisfies the frozen A.3 signatures (forward_list_json,
# forward_set_status, forward_remove_record). Lib functions bind to it lazily.
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
  if ((T2_RC != 0)) && [[ -n ${T2_ERR} ]]; then
    printf '    [t2_run %s] rc=%d stderr:\n%s\n' "${1}" "${T2_RC}" "${T2_ERR}" >&2
  fi
}

command -v sshd >/dev/null 2>&1 || {
  printf 'integration requires sshd\n' >&2
  exit 1
}
command -v jq >/dev/null 2>&1 || {
  printf 'integration requires jq (state double)\n' >&2
  exit 1
}

T2_TMP="$(mktemp -d "${TMPDIR:-/tmp}/t2-doctor.XXXXXX")"
export HERDR_PLUGIN_STATE_DIR="${T2_TMP}/herdr-forward"
export HERDR_PLUGIN_CONFIG_DIR="${T2_TMP}/config"
export HOME="${T2_TMP}"
mkdir -p "${HERDR_PLUGIN_CONFIG_DIR}" "${HERDR_PLUGIN_STATE_DIR}"

# ---------------------------------------------------------------------------
# Inline jq-backed state double (frozen A.3 state.sh signatures).
# ---------------------------------------------------------------------------
T2_STATE_JSON="${HERDR_PLUGIN_STATE_DIR}/forwards.json"

state_save() {
  local json="${1}"
  printf '%s\n' "${json}" | jq '.' >"${T2_STATE_JSON}.tmp"
  mv -f "${T2_STATE_JSON}.tmp" "${T2_STATE_JSON}"
}
forward_list_json() {
  if [[ -f "${T2_STATE_JSON}" ]]; then
    jq -c '.forwards' "${T2_STATE_JSON}"
  else
    printf '[]\n'
  fi
}
forward_set_status() {
  local id="${1}"
  local status="${2}"
  local json
  json="$(jq -c --arg id "${id}" --arg s "${status}" \
    '.forwards = [.forwards[] | if .id == $id then .status = $s else . end]' "${T2_STATE_JSON}")"
  state_save "${json}"
}
forward_remove_record() {
  local id="${1}"
  local json
  json="$(jq -c --arg id "${id}" \
    '.forwards = [.forwards[] | select(.id != $id)]' "${T2_STATE_JSON}")"
  state_save "${json}"
}
t2_status_of() {
  jq -r --arg id "${1}" '.forwards[] | select(.id == $id) | .status' "${T2_STATE_JSON}"
}
t2_record_count() {
  jq '.forwards | length' "${T2_STATE_JSON}"
}

SSHD_PID=""
ECHO_PID=""
AGENT_PID=""
TUNNEL_ID=""
LOCAL_PORT=""

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

SSHD_PORT="$(t2_free_port)"
REMOTE_PORT="$(t2_free_port)"
[[ ${SSHD_PORT} != "0" && ${REMOTE_PORT} != "0" ]] || {
  printf 'could not allocate test ports\n' >&2
  exit 1
}

ssh-keygen -q -t ed25519 -N '' -f "${T2_TMP}/hostkey"
ssh-keygen -q -t ed25519 -N '' -f "${T2_TMP}/clientkey"
cp "${T2_TMP}/clientkey.pub" "${T2_TMP}/authorized_keys"
chmod 600 "${T2_TMP}/authorized_keys" "${T2_TMP}/clientkey" "${T2_TMP}/hostkey"

SSH_USER="$(id -un)"

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
  grep -v '^PerSourcePenalties' "${T2_TMP}/sshd_config" >"${T2_TMP}/sshd_config.2"
  mv "${T2_TMP}/sshd_config.2" "${T2_TMP}/sshd_config"
  /usr/bin/sshd -t -f "${T2_TMP}/sshd_config" 2>>"${T2_TMP}/sshd_t.err" || {
    printf 'sshd -t rejected config:\n' >&2
    cat "${T2_TMP}/sshd_t.err" >&2
    exit 1
  }
fi

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

T2_TUNNEL="${T2_ROOT}/lib/tunnel.sh"
if [[ ! -f "${T2_TUNNEL}" ]]; then
  printf 'RED: %s not implemented yet\n' "${T2_TUNNEL}" >&2
  exit 1
fi
# shellcheck source=/dev/null
source "${T2_TUNNEL}"

t_describe "fixture: live tunnel recorded in state"
/usr/bin/sshd -f "${T2_TMP}/sshd_config" -E "${T2_TMP}/sshd.log"
SSHD_PID="$(cat "${T2_TMP}/sshd.pid")"
t2_wait_port "${SSHD_PORT}"
python3 "${T2_TMP}/echo.py" "${REMOTE_PORT}" &
ECHO_PID=$!
disown "${ECHO_PID}" 2>/dev/null || true
t2_wait_port "${REMOTE_PORT}"

LOCAL_PORT="$(t2_free_port)"
TUNNEL_ID="f-${LOCAL_PORT}"
t2_run tunnel_start "${TUNNEL_ID}" "${LOCAL_PORT}" "127.0.0.1:${REMOTE_PORT}" "${SSH_USER}@127.0.0.1:${SSHD_PORT}"
t_eq "0" "${T2_RC}" "tunnel_start exit"
MASTER_PID="${T2_OUT}"

CTL_PATH="$(tunnel_control_path "${TUNNEL_ID}")"
RECORD_JSON="$(jq -cn \
  --arg id "${TUNNEL_ID}" \
  --argjson lp "${LOCAL_PORT}" \
  --argjson rp "${REMOTE_PORT}" \
  --argjson pid "${MASTER_PID}" \
  --arg target "${SSH_USER}@127.0.0.1:${SSHD_PORT}" \
  --arg ctl "${CTL_PATH}" \
  '{version:1,forwards:[{id:$id,local_port:$lp,remote_host:"127.0.0.1",remote_port:$rp,machine:"local",ssh_target:$target,pid:$pid,control_socket:$ctl,status:"up",created_unix:0,publish:{pid:null,url:null,started_unix:null}}]}')"
state_save "${RECORD_JSON}"

t_it "health is up while the tunnel is live"
t2_run tunnel_health "${TUNNEL_ID}" "${MASTER_PID}" "${LOCAL_PORT}"
t_eq "up" "${T2_OUT}" "health up"
t_it "doctor report leaves the record untouched and exits 0"
t2_run tunnel_doctor
t_eq "0" "${T2_RC}" "doctor report exit"
t_match "up" "${T2_OUT}" "reports up"
t2_run t2_status_of "${TUNNEL_ID}"
t_eq "up" "${T2_OUT}" "status unchanged by report"

t_describe "remote death: kill sshd listener + full descendant tree"
t2_kill_tree "${SSHD_PID}"
SSHD_PID=""
sleep 1
t_it "the listener is gone (connect refused)"
t2_run t2_wait_port "${SSHD_PORT}"
t_eq "1" "${T2_RC}" "sshd port closed"
t_it "tunnel_health now reports down"
t2_run tunnel_health "${TUNNEL_ID}" "${MASTER_PID}" "${LOCAL_PORT}"
t_eq "down" "${T2_OUT}" "health down"

t_describe "doctor --fix repairs the stale status"
t2_run tunnel_doctor --fix
t_eq "0" "${T2_RC}" "doctor --fix exit"
t_match "fixed" "${T2_OUT}" "announces the fix"
t2_run t2_status_of "${TUNNEL_ID}"
t_eq "down" "${T2_OUT}" "status flipped to down"
t_it "the record is still present after --fix (no data loss)"
t2_run t2_record_count
t_eq "1" "${T2_OUT}" "one record remains"

t_describe "doctor --prune clears the dead record"
t2_run tunnel_doctor --prune
t_eq "0" "${T2_RC}" "doctor --prune exit"
t_match "pruned" "${T2_OUT}" "announces the prune"
t2_run t2_record_count
t_eq "0" "${T2_OUT}" "record removed"
t_it "the stale control socket is gone after prune"
if [[ -e "${HERDR_PLUGIN_STATE_DIR}/ssh-ctl/ctl-${TUNNEL_ID}" ]]; then
  t_fail "control socket survived prune"
else
  t_ok "control socket removed"
fi
TUNNEL_ID=""

t_describe "no zombie ssh after doctor"
t_it "no ssh process references this test's state dir"
sleep 0.5
t2_resid="$(pgrep -af -- 'ssh' 2>/dev/null | grep -F "${HERDR_PLUGIN_STATE_DIR}" || true)"
t_eq "" "${t2_resid}" "no lingering ssh for this state dir"

t_done
