#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2312,SC2317,SC2329 # cleanup and fixture assertions are best-effort.
# Go CLI integration: real sshd + ControlMaster + payload round-trip.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${ROOT}/tests/assertions.sh"
for tool in sshd ssh-keygen python3 jq ssh; do
  command -v "${tool}" >/dev/null 2>&1 || {
    printf 'integration requires %s\n' "${tool}" >&2
    exit 1
  }
done

TMP="$(mktemp -d "${TMPDIR:-/tmp}/hf-go-cli.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT
PLUGIN="${TMP}/plugin"
mkdir -p "${PLUGIN}/bin" "${TMP}/home/.ssh" "${TMP}/state"
cp "${ROOT}/bin/forward" "${PLUGIN}/bin/forward"
if [[ -x "${ROOT}/bin/forward-go" ]]; then
  cp "${ROOT}/bin/forward-go" "${PLUGIN}/bin/forward-go"
else
  (cd "${ROOT}/go" && GOFLAGS=-mod=vendor go build -o "${PLUGIN}/bin/forward-go" ./cmd/forward)
fi
chmod 0755 "${PLUGIN}/bin/forward" "${PLUGIN}/bin/forward-go"
FW="${PLUGIN}/bin/forward"
export HOME="${TMP}/home" HERDR_PLUGIN_STATE_DIR="${TMP}/state" HERDR_PLUGIN_CONFIG_DIR="${TMP}/config"
mkdir -p "${HERDR_PLUGIN_CONFIG_DIR}"

SSHD_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
REMOTE_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
LOCAL_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
ssh-keygen -q -t ed25519 -N '' -f "${TMP}/clientkey"
ssh-keygen -q -t ed25519 -N '' -f "${TMP}/hostkey"
cp "${TMP}/clientkey.pub" "${TMP}/authorized_keys"
chmod 600 "${TMP}/authorized_keys" "${TMP}/clientkey" "${TMP}/hostkey"
cat >"${TMP}/sshd_config" <<EOF
Port ${SSHD_PORT}
ListenAddress 127.0.0.1
HostKey ${TMP}/hostkey
PidFile ${TMP}/sshd.pid
AuthorizedKeysFile ${TMP}/authorized_keys
PasswordAuthentication no
PubkeyAuthentication yes
PermitRootLogin no
StrictModes no
UsePAM no
AllowTcpForwarding yes
LogLevel ERROR
EOF
# 容器/CI 常以 root 跑测试：PermitRootLogin no 会把同用户的测试 ssh 全拒掉
#（本机非 root 不受影响）。仅测试 sshd，按实际运行用户设置。
if id -u | grep -qx 0; then
  sed -i "s/^PermitRootLogin no$/PermitRootLogin prohibit-password/" "${TMP}/sshd_config"
fi
SSHD_BIN="$(command -v sshd || echo /usr/sbin/sshd)"
"${SSHD_BIN}" -f "${TMP}/sshd_config" -E "${TMP}/sshd.log"
SSHD_PID="$(cat "${TMP}/sshd.pid")"
cat >"${TMP}/echo.py" <<'PY'
import socket, sys
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(8)
while True:
    c, _ = s.accept()
    try:
        c.sendall(c.recv(4096))
    except OSError:
        pass
    c.close()
PY
python3 "${TMP}/echo.py" "${REMOTE_PORT}" &
ECHO_PID=$!
ssh-agent -a "${TMP}/agent.sock" -s >"${TMP}/agent.env"
source "${TMP}/agent.env" >/dev/null
ssh-add "${TMP}/clientkey" >/dev/null

roundtrip() {
  timeout 5 bash -c "exec 3<>/dev/tcp/127.0.0.1/${LOCAL_PORT}; printf 'phase5\\n' >&3; IFS= read -r -t 3 line <&3; printf '%s' \"\${line}\"" 2>/dev/null || true
}
cleanup() {
  set +e
  "${FW}" remove "f-${LOCAL_PORT}" >/dev/null 2>&1 || true
  kill "${ECHO_PID}" "${SSHD_PID}" "${SSH_AGENT_PID:-}" 2>/dev/null || true
}
trap cleanup EXIT

T="${USER:-$(id -un)}@127.0.0.1:${SSHD_PORT}"
t_describe "Go CLI full cycle"
t_it "add starts a real Go ControlMaster"
run "${FW}" add "${LOCAL_PORT}:${REMOTE_PORT}" --ssh-target "${T}"
t_exit_ok 0 "${rc}" "add exits 0"
t_eq "f-${LOCAL_PORT}" "${out}" "add returns id"
t_eq up "$(jq -r '.forwards[0].status' "${HERDR_PLUGIN_STATE_DIR}/forwards.json")" "status is up"
t_file_exists "${HERDR_PLUGIN_STATE_DIR}/ssh-ctl/ctl-f-${LOCAL_PORT}" "control socket exists"

t_it "payload crosses ssh -L"
got="$(roundtrip)"
t_eq phase5 "${got}" "payload round-trip"
run "${FW}" list --oneline
t_contains "⇅${LOCAL_PORT}" "${out}" "tab bar contains active port"
run "${FW}" list --json
t_eq 1 "$(printf '%s' "${out}" | jq '.forwards | length')" "json has one record"

t_it "doctor --fix and --prune preserve live tunnel"
jq '.forwards[0].status = "down"' "${HERDR_PLUGIN_STATE_DIR}/forwards.json" >"${TMP}/state.new"
mv "${TMP}/state.new" "${HERDR_PLUGIN_STATE_DIR}/forwards.json"
run "${FW}" doctor --fix
t_exit_ok 0 "${rc}" "doctor fix exits 0"
t_eq up "$(jq -r '.forwards[0].status' "${HERDR_PLUGIN_STATE_DIR}/forwards.json")" "doctor fixes live status"
run "${FW}" doctor --prune
t_exit_ok 0 "${rc}" "doctor prune exits 0"
t_eq 1 "$(jq '.forwards | length' "${HERDR_PLUGIN_STATE_DIR}/forwards.json")" "live record not pruned"

t_it "remove stops the Go tunnel"
run "${FW}" remove "f-${LOCAL_PORT}"
t_exit_ok 0 "${rc}" "remove exits 0"
t_file_absent "${HERDR_PLUGIN_STATE_DIR}/ssh-ctl/ctl-f-${LOCAL_PORT}" "control socket removed"
if (exec 3<>"/dev/tcp/127.0.0.1/${LOCAL_PORT}") 2>/dev/null; then
  t_fail "local listener still accepts after remove"
else
  t_pass "local listener closed after remove"
fi
t_no_zombie_ssh "no Go tunnel ssh residue"
t_done
