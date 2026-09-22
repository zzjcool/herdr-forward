#!/usr/bin/env bash
# tests/unit/test_machine.sh — lib/machine.sh: LABEL -> ssh_target via machines.toml.
# SCOUT-FACTS §2.1/§4: machines.toml is the official path (no socket API route).
# Cases: normal / explicit port / no port (default 22) / unknown label /
#        missing file / corrupt file.
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

# Capture stdout/stderr/rc without tripping `set -e`.
T2_OUT=""
T2_ERR=""
T2_RC=0
t2_run() {
  local out_file err_file
  out_file="$(mktemp)"
  err_file="$(mktemp)"
  set +e
  "$@" >"${out_file}" 2>"${err_file}"
  T2_RC=$?
  set -e
  T2_OUT="$(<"${out_file}")"
  T2_ERR="$(<"${err_file}")"
  rm -f "${out_file}" "${err_file}"
}

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------
T2_TMP="$(mktemp -d "${TMPDIR:-/tmp}/t2-machine.XXXXXX")"
trap 'rm -rf "${T2_TMP}"' EXIT
export HERDR_PLUGIN_STATE_DIR="${T2_TMP}/state"
export HERDR_PLUGIN_CONFIG_DIR="${T2_TMP}/config"
mkdir -p "${HERDR_PLUGIN_CONFIG_DIR}"

T2_TOML="${HERDR_PLUGIN_CONFIG_DIR}/machines.toml"

write_valid_toml() {
  cat >"${T2_TOML}" <<'TOML'
# herdr-forward saved machines (fallback path, see docs/ARCHITECTURE.md A.3)
[machines.gpu-box]
ssh_target = "user@gpu-box.example.com"

[machines.lab]
ssh_target = "bob@10.0.0.9:2200"

[machines.local]
ssh_target = "alice@127.0.0.1:22"
TOML
}

T2_MACHINE="${T2_ROOT}/lib/machine.sh"
if [[ ! -f "${T2_MACHINE}" ]]; then
  printf 'RED: %s not implemented yet\n' "${T2_MACHINE}" >&2
  exit 1
fi
# shellcheck source=/dev/null
source "${T2_MACHINE}"

t_describe "machines_toml_path"
t_it "path is \$HERDR_PLUGIN_CONFIG_DIR/machines.toml"
t2_run machines_toml_path
t_eq "${HERDR_PLUGIN_CONFIG_DIR}/machines.toml" "${T2_OUT}" "toml path"

t_describe "machine_resolve — normal"
write_valid_toml
t_it "label without port resolves and gets the default :22 suffix"
t2_run machine_resolve gpu-box
t_eq "user@gpu-box.example.com:22" "${T2_OUT}" "normalized ssh_target"
t_eq "0" "${T2_RC}" "exit 0"
t_it "label with explicit port keeps it"
t2_run machine_resolve lab
t_eq "bob@10.0.0.9:2200" "${T2_OUT}" "ssh_target with port"
t_it "label with :22 stays :22"
t2_run machine_resolve local
t_eq "alice@127.0.0.1:22" "${T2_OUT}" "explicit :22"

t_describe "machine_resolve — failures (die 4)"
t_it "unknown label dies 4 and lists available labels"
t2_run machine_resolve nope
t_exit_ok 4 "${T2_RC}" "unknown label exit"
t_match 'nope' "${T2_ERR}" "names the missing label"
t_match 'gpu-box' "${T2_ERR}" "lists available labels"
t_it "missing machines.toml dies 4 with a create suggestion + one-line example"
rm -f "${T2_TOML}"
t2_run machine_resolve gpu-box
t_exit_ok 4 "${T2_RC}" "missing file exit"
t_match 'machines\.toml' "${T2_ERR}" "mentions the file"
t_match 'ssh_target' "${T2_ERR}" "shows the one-line example"
t_it "unterminated quote in ssh_target dies 4"
mkdir -p "${HERDR_PLUGIN_CONFIG_DIR}"
printf '[machines.broken]\nssh_target = "user@host\n' >"${T2_TOML}"
t2_run machine_resolve broken
t_exit_ok 4 "${T2_RC}" "corrupt exit"
t_it "unquoted ssh_target value dies 4"
printf '[machines.broken]\nssh_target = user@host\n' >"${T2_TOML}"
t2_run machine_resolve broken
t_exit_ok 4 "${T2_RC}" "unquoted exit"
t_it "empty ssh_target dies 4"
printf '[machines.broken]\nssh_target = ""\n' >"${T2_TOML}"
t2_run machine_resolve broken
t_exit_ok 4 "${T2_RC}" "empty exit"
t_it "section present but ssh_target key missing dies 4"
printf '[machines.broken]\nother = "x"\n' >"${T2_TOML}"
t2_run machine_resolve broken
t_exit_ok 4 "${T2_RC}" "missing key exit"

t_done
