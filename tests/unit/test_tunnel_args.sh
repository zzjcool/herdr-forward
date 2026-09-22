#!/usr/bin/env bash
# tests/unit/test_tunnel_args.sh — lib/tunnel.sh ssh argv assembly (no ssh spawned).
# Covers ARCHITECTURE.md A.3 frozen tunnel option set: ControlPath, UserKnownHostsFile,
# accept-new, BatchMode, ExitOnForwardFailure, ControlPersist, -F /dev/null, -p parse.
set -Eeuo pipefail

T2_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [[ -f "${T2_ROOT}/tests/lib/assertions.sh" ]]; then
  # shellcheck source=/dev/null
  source "${T2_ROOT}/tests/lib/assertions.sh"
fi

# ---------------------------------------------------------------------------
# Fallback assertion subset — used only while T0's tests/lib/assertions.sh is
# not merged (tests/lib/ is T0-owned and must not be written from here).
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
if ! declare -F t_file_exists >/dev/null 2>&1; then
  t_file_exists() {
    if [[ -f "${1}" ]]; then
      T2_PASS=$((T2_PASS + 1))
    else
      T2_FAIL=$((T2_FAIL + 1))
      printf '    FAIL: missing file [%s]\n' "${1}" >&2
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

# Capture helpers: route every command substitution through these so shellcheck
# SC2312 ("masking return value") stays silent.
T2_OUT=""
T2_LINES=()
t2_cap() { T2_OUT="$("$@")"; }
t2_lines() {
  T2_LINES=()
  local raw
  raw="$("$@")"
  mapfile -t T2_LINES <<<"${raw}"
}

# Join argv with a delimiter so adjacency (-L <spec>, -o <opt>) is assertable.
t2_join() {
  local IFS='|'
  printf '%s' "${*}"
}

# ---------------------------------------------------------------------------
# Environment: hermetic state dir under TMPDIR (no user state touched).
# ---------------------------------------------------------------------------
T2_TMP="$(mktemp -d "${TMPDIR:-/tmp}/t2-tunnel-args.XXXXXX")"
trap 'rm -rf "${T2_TMP}"' EXIT
export HERDR_PLUGIN_STATE_DIR="${T2_TMP}/herdr-forward"

T2_TUNNEL="${T2_ROOT}/lib/tunnel.sh"
if [[ ! -f "${T2_TUNNEL}" ]]; then
  printf 'RED: %s not implemented yet\n' "${T2_TUNNEL}" >&2
  exit 1
fi
# shellcheck source=/dev/null
source "${T2_TUNNEL}"

t_describe "tunnel control dir (A.3: \$CONTROL_DIR=\${HERDR_PLUGIN_STATE_DIR}/ssh-ctl/)"
t_it "control dir lives under HERDR_PLUGIN_STATE_DIR/ssh-ctl"
t2_cap tunnel_control_dir
t_eq "${HERDR_PLUGIN_STATE_DIR}/ssh-ctl" "${T2_OUT}" "control dir path"
t2_dir="${T2_OUT}"
t_it "control dir is created with mode 700"
t2_cap stat -c '%a' "${t2_dir}"
t_eq "700" "${T2_OUT}" "control dir perms"
t_it "control path is ctl-<id> inside the control dir"
t2_cap tunnel_control_path f-3000
t_eq "${t2_dir}/ctl-f-3000" "${T2_OUT}" "control path"

t_describe "tunnel_parse_ssh_target (port strip, default 22)"
t_it "no port -> default 22"
t2_lines tunnel_parse_ssh_target 'user@host'
t_eq "22" "${T2_LINES[0]}" "default port"
t_eq "user@host" "${T2_LINES[1]}" "destination"
t_it "explicit port"
t2_lines tunnel_parse_ssh_target 'user@host:2222'
t_eq "2222" "${T2_LINES[0]}" "explicit port"
t_eq "user@host" "${T2_LINES[1]}" "destination"
t_it "fqdn with port"
t2_lines tunnel_parse_ssh_target 'user@gpu-box.example.com:22022'
t_eq "22022" "${T2_LINES[0]}" "fqdn port"
t_eq "user@gpu-box.example.com" "${T2_LINES[1]}" "fqdn destination"
t_it "bracketed IPv6 with port"
t2_lines tunnel_parse_ssh_target 'user@[::1]:2222'
t_eq "2222" "${T2_LINES[0]}" "ipv6 port"
t_eq "user@[::1]" "${T2_LINES[1]}" "ipv6 destination"
t_it "no user, no port"
t2_lines tunnel_parse_ssh_target 'host.local'
t_eq "22" "${T2_LINES[0]}" "default port"
t_eq "host.local" "${T2_LINES[1]}" "bare host destination"
t_it "trailing colon with no port digits is stripped (malformed but tolerated)"
t2_lines tunnel_parse_ssh_target 'user@host:'
t_eq "22" "${T2_LINES[0]}" "default port"
t_eq "user@host" "${T2_LINES[1]}" "destination has no dangling colon"

t_describe "tunnel_ssh_args (A.3 frozen option set)"
t_it "assembles -N -L then the frozen -o set, -F /dev/null, -p, destination"
t2_lines tunnel_ssh_args f-3000 3000 127.0.0.1:8080 'user@host.example:2222'
t2_args=("${T2_LINES[@]}")
t2_joined="$(t2_join "${t2_args[@]}")"
t_eq "-N" "${t2_args[0]}" "no remote command (-N)"
t_match '^-N\|-L\|127\.0\.0\.1:3000:127\.0\.0\.1:8080\|' "${t2_joined}" "loopback -L spec"
t_match '\|-o\|BatchMode=yes\|' "${t2_joined}" "BatchMode"
t_match '\|-o\|ExitOnForwardFailure=yes\|' "${t2_joined}" "ExitOnForwardFailure"
t_match '\|-o\|ControlMaster=auto\|' "${t2_joined}" "ControlMaster=auto"
t_match '\|-o\|ControlPath='"${t2_dir}"'/ctl-f-3000\|' "${t2_joined}" "ControlPath per id"
t_match '\|-o\|ControlPersist=yes\|' "${t2_joined}" "ControlPersist=yes"
t_match '\|-o\|StrictHostKeyChecking=accept-new\|' "${t2_joined}" "accept-new (sandbox host key)"
t_match '\|-o\|UserKnownHostsFile='"${t2_dir}"'/known_hosts\|' "${t2_joined}" "isolated known_hosts"
t_match '\|-F\|/dev/null\|' "${t2_joined}" "ignore user ssh_config"
t_match '\|-p\|2222\|' "${t2_joined}" "port from ssh_target"
t_eq 'user@host.example' "${t2_args[-1]}" "destination is last"
t_it "default port 22 when ssh_target has no :port"
t2_lines tunnel_ssh_args f-22 22 localhost:8000 'user@host'
t2_args=("${T2_LINES[@]}")
t2_joined="$(t2_join "${t2_args[@]}")"
t_match '\|-p\|22\|' "${t2_joined}" "default port"
t_eq 'user@host' "${t2_args[-1]}" "destination is last"
t_it "id is embedded verbatim into the control socket name"
t2_lines tunnel_ssh_args f-5173 5173 10.0.0.9:5173 'bob@10.0.0.9:2200'
t2_args=("${T2_LINES[@]}")
t2_joined="$(t2_join "${t2_args[@]}")"
t_match '\|ControlPath='"${t2_dir}"'/ctl-f-5173\|' "${t2_joined}" "control path"
t_match '\|-L\|127\.0\.0\.1:5173:10\.0\.0\.9:5173\|' "${t2_joined}" "remote spec"
t_match '\|-p\|2200\|' "${t2_joined}" "port"
t_eq 'bob@10.0.0.9' "${t2_args[-1]}" "destination"

t_describe "tunnel_alive (kill -0 + non-zombie)"
t_it "false for a pid that does not exist"
t2_cap tunnel_alive 2147483000
t_eq "false" "${T2_OUT}" "dead pid"
t_it "true for a live non-zombie pid (own shell)"
t2_cap tunnel_alive "$$"
t_eq "true" "${T2_OUT}" "live pid"

t_done
