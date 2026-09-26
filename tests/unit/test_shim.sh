#!/usr/bin/env bash
# POSIX entrypoint contract: missing release binary must be actionable and 127.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${ROOT}/tests/assertions.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/forward-shim.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${WORK}/bin"
cp "${ROOT}/bin/forward" "${WORK}/bin/forward"
chmod 0755 "${WORK}/bin/forward"
run "${WORK}/bin/forward" list
t_exit_ok 127 "${rc}" 'shim missing binary exits 127'
t_contains 'forward-go' "${err}" 'error names missing binary'
t_contains 'plugin install' "${err}" 'error gives reinstall instruction'
t_contains 'make build' "${err}" 'error gives offline development instruction'
t_done
