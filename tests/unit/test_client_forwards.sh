#!/usr/bin/env bash
# shellcheck disable=SC2312 # assertions intentionally consume command output inline.
# Final CLI client/ports smoke.  This deliberately invokes the Go binary through
# bin/forward; it no longer sources or tests retired Bash implementation details.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${ROOT}/tests/assertions.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/client-forwards-go.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${WORK}/bin" "${WORK}/state"
cp "${ROOT}/bin/forward" "${WORK}/bin/forward"
if [[ -x "${ROOT}/bin/forward-go" ]]; then
  cp "${ROOT}/bin/forward-go" "${WORK}/bin/forward-go"
else
  (cd "${ROOT}/go" && GOFLAGS=-mod=vendor go build -o "${WORK}/bin/forward-go" ./cmd/forward)
fi
chmod 0755 "${WORK}/bin/forward" "${WORK}/bin/forward-go"
FW="${WORK}/bin/forward"
export HERDR_PLUGIN_STATE_DIR="${WORK}/state"

PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
python3 - "${PORT}" <<'PY' &
import socket, sys
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(4)
while True:
    c, _ = s.accept()
    c.close()
PY
SERVER_PID=$!
trap 'kill "${SERVER_PID}" 2>/dev/null || true; rm -rf "${WORK}"' EXIT

# Client mapping lifecycle stays entirely in the Go CLI.
t_describe 'Go client mapping lifecycle'
run "${FW}" add 24517 --client
t_exit_ok 0 "${rc}" 'client add succeeds'
t_eq f-24517 "${out}" 'client add returns id'
run "${FW}" list --json
t_eq client "$(printf '%s' "${out}" | jq -r '.forwards[0].mode')" 'json marks client mode'
run "${FW}" doctor --prune
t_eq 1 "$(printf '%s' "${out}" | grep -c 'client:waiting')" 'doctor reports waiting client'
t_eq 1 "$(jq '.forwards | length' "${HERDR_PLUGIN_STATE_DIR}/forwards.json")" 'doctor keeps client record'

# §16.2 close-out: assert the stable JSON port/address columns, not the
# implementation-dependent PROCESS column (- for /proc, process name for ss).
t_describe 'ports JSON contract (§16.2)'
run "${FW}" ports --json
t_exit_ok 0 "${rc}" 'ports --json succeeds'
row="$(printf '%s' "${out}" | jq -c --argjson p "${PORT}" 'map(select(.port == $p))[0] // {}')"
t_eq "${PORT}" "$(printf '%s' "${row}" | jq -r '.port | tostring')" 'port column is stable'
t_eq 127.0.0.1 "$(printf '%s' "${row}" | jq -r '.addr')" 'address column is stable'
t_match '^(|[^\n]*)$' "$(printf '%s' "${row}" | jq -r '.process // ""')" 'process column may be empty or implementation-provided'
run "${FW}" ports
# The table must retain the port and address regardless of PROCESS formatting.
t_match "${PORT}[[:space:]]+127\\.0\\.0\\.1" "${out}" 'table keeps port/address columns'

run "${FW}" remove f-24517
t_exit_ok 0 "${rc}" 'client remove succeeds'
t_eq 0 "$(jq '.forwards | length' "${HERDR_PLUGIN_STATE_DIR}/forwards.json")" 'client record removed'
t_done
