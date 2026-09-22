#!/usr/bin/env bash
# lib/tunnel.sh — ssh -L tunnel lifecycle with a self-built ControlMaster.
# Frozen API (ARCHITECTURE.md A.3):
#   tunnel_start <id> <local_port> <remote_host:remote_port> <ssh_target>  -> stdout pid; die 5
#   tunnel_stop  <id>
#   tunnel_alive <pid>        -> stdout true|false (kill -0 and not zombie)
#   tunnel_probe <local_port> -> stdout ok|fail (probe_tcp wrapper)
# Extra liveness primitives used by `forward doctor` (T1 cmd layer delegates here):
#   tunnel_health <id> <pid> <local_port> -> up|down
#   tunnel_reap   <id> [pid]              -> stop + remove socket/pidfile (idempotent)
#   tunnel_doctor [--fix|--prune]         -> reconcile status against liveness
set -Eeuo pipefail

# ---------------------------------------------------------------------------
# common.sh bridge: when T1's lib/common.sh is present it wins; otherwise fall
# back to a minimal, behaviour-compatible subset so this library loads and is
# unit-testable on its own (tests/unit + tests/integration before T1 merges).
# ---------------------------------------------------------------------------
_TUNNEL_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${_TUNNEL_LIB_DIR}/common.sh" ]]; then
  # shellcheck source=/dev/null
  source "${_TUNNEL_LIB_DIR}/common.sh"
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
if ! declare -F die >/dev/null 2>&1; then
  die() {
    local code="${1}"
    shift
    log error "${*}"
    exit "${code}"
  }
fi
if ! declare -F require_cmd >/dev/null 2>&1; then
  require_cmd() {
    local name="${1}"
    local hint="${2:-}"
    if ! command -v "${name}" >/dev/null 2>&1; then
      die 127 "missing dependency: ${name}${hint:+ (${hint})}"
    fi
  }
fi
if ! declare -F now_unix >/dev/null 2>&1; then
  now_unix() { date +%s; }
fi
if ! declare -F atomic_write >/dev/null 2>&1; then
  atomic_write() {
    local file="${1}"
    local tmpdir="${2:-$(dirname "${file}")}"
    local tmp
    tmp="$(mktemp "${tmpdir}/.atomic.XXXXXX")"
    cat >"${tmp}"
    mv -f "${tmp}" "${file}"
  }
fi
if ! declare -F probe_tcp >/dev/null 2>&1; then
  probe_tcp() {
    local host="${1}"
    local port="${2}"
    local timeout_s="${3:-2}"
    if timeout "${timeout_s}" bash -c "exec 3<>/dev/tcp/${host}/${port}" 2>/dev/null; then
      printf 'ok\n'
    else
      printf 'fail\n'
    fi
  }
fi

# ---------------------------------------------------------------------------
# Control dir / socket / ssh_target parsing
# ---------------------------------------------------------------------------

# stdout: absolute control directory (created with mode 700 on first use).
tunnel_control_dir() {
  local base="${HERDR_PLUGIN_STATE_DIR:-${HOME:-/tmp}/.local/state/herdr-forward}"
  local dir="${base}/ssh-ctl"
  if [[ ! -d "${dir}" ]]; then
    mkdir -p "${dir}"
    chmod 700 "${dir}"
  fi
  printf '%s\n' "${dir}"
}

# tunnel_control_path <id> -> stdout: ctl-<id> path inside the control dir.
tunnel_control_path() {
  local id="${1}"
  local dir
  dir="$(tunnel_control_dir)"
  printf '%s\n' "${dir}/ctl-${id}"
}

# tunnel_parse_ssh_target <ssh_target> -> stdout: <port> newline <destination>.
# Trailing ":<port>" is stripped (default 22); bracketed IPv6 kept intact.
tunnel_parse_ssh_target() {
  local target="${1}"
  local port=22
  local dest="${target}"
  if [[ ${target} =~ ^(.*\[[0-9A-Fa-f:.]+\]):([0-9]+)$ ]]; then
    dest="${BASH_REMATCH[1]}"
    port="${BASH_REMATCH[2]}"
  elif [[ ${target} =~ ^\[[0-9A-Fa-f:.]+\]$ ]]; then
    : # bracketed IPv6 without an explicit port -> default 22
  elif [[ ${target} =~ ^(.*):([0-9]+)$ ]]; then
    dest="${BASH_REMATCH[1]}"
    port="${BASH_REMATCH[2]}"
  elif [[ ${target} == *: ]]; then
    dest="${target%:}"
  fi
  printf '%s\n' "${port}" "${dest}"
}

# tunnel_ssh_args <id> <local_port> <remote_host:remote_port> <ssh_target>
# stdout: one argv element per line (unit-testable seam; no ssh is spawned).
tunnel_ssh_args() {
  local id="${1}"
  local local_port="${2}"
  local remote="${3}"
  local ssh_target="${4}"
  local parsed_raw=""
  parsed_raw="$(tunnel_parse_ssh_target "${ssh_target}")"
  local -a parsed=()
  mapfile -t parsed <<<"${parsed_raw}"
  local port="${parsed[0]}"
  local dest="${parsed[1]}"
  local dir
  dir="$(tunnel_control_dir)"
  printf '%s\n' \
    '-N' \
    '-L' "127.0.0.1:${local_port}:${remote}" \
    '-o' 'BatchMode=yes' \
    '-o' 'ExitOnForwardFailure=yes' \
    '-o' 'ControlMaster=auto' \
    '-o' "ControlPath=${dir}/ctl-${id}" \
    '-o' 'ControlPersist=yes' \
    '-o' 'StrictHostKeyChecking=accept-new' \
    '-o' "UserKnownHostsFile=${dir}/known_hosts" \
    '-F' '/dev/null' \
    '-p' "${port}" \
    "${dest}"
}

# ---------------------------------------------------------------------------
# Liveness primitives
# ---------------------------------------------------------------------------

# tunnel_alive <pid> -> stdout: true|false (kill -0 and state is not Z).
tunnel_alive() {
  local pid="${1:-}"
  if [[ ! ${pid} =~ ^[0-9]+$ ]]; then
    printf 'false\n'
    return 0
  fi
  if ! kill -0 "${pid}" 2>/dev/null; then
    printf 'false\n'
    return 0
  fi
  if [[ -r "/proc/${pid}/stat" ]]; then
    local stat_line
    stat_line="$(<"/proc/${pid}/stat")"
    local state="${stat_line##*) }"
    state="${state:0:1}"
    if [[ ${state} == 'Z' ]]; then
      printf 'false\n'
      return 0
    fi
  fi
  printf 'true\n'
}

# tunnel_probe <local_port> -> stdout: ok|fail (A.3: probe_tcp 127.0.0.1 <port>).
tunnel_probe() {
  local local_port="${1}"
  probe_tcp 127.0.0.1 "${local_port}"
}

# tunnel_health <id> <pid> <local_port> -> stdout: up|down
tunnel_health() {
  local id="${1}"
  local pid="${2:-}"
  local local_port="${3}"
  local alive probe
  alive="$(tunnel_alive "${pid}")"
  probe="$(tunnel_probe "${local_port}")"
  if [[ ${alive} == 'true' && ${probe} == 'ok' ]]; then
    printf 'up\n'
  else
    printf 'down\n'
  fi
}

# ---------------------------------------------------------------------------
# Start / stop
# ---------------------------------------------------------------------------

# ssh -O needs a destination argument even for socket-only operations.
# Always returns 0 so callers can capture stderr without tripping `set -e`.
_tunnel_ctl_ssh() {
  ssh -F /dev/null -o BatchMode=yes "$@" || true
}

# tunnel_start <id> <local_port> <remote_host:remote_port> <ssh_target>
# Forks a detached ssh master and prints the *master* pid (with ControlPersist
# the launcher exits, so the pid is discovered via `ssh -O check`).
tunnel_start() {
  local id="${1}"
  local local_port="${2}"
  local remote="${3}"
  local ssh_target="${4}"
  require_cmd ssh
  local dir
  dir="$(tunnel_control_dir)"
  local ctl="${dir}/ctl-${id}"
  local log_file="${dir}/log-${id}"
  local pid_file="${dir}/pid-${id}"
  local target_file="${dir}/target-${id}"
  local args_raw=""
  args_raw="$(tunnel_ssh_args "${id}" "${local_port}" "${remote}" "${ssh_target}")"
  local -a args=()
  mapfile -t args <<<"${args_raw}"

  printf '%s\n' "${ssh_target}" >"${target_file}"

  : >"${log_file}"
  local launcher
  if command -v setsid >/dev/null 2>&1; then
    setsid ssh "${args[@]}" </dev/null >>"${log_file}" 2>&1 &
  else
    ssh "${args[@]}" </dev/null >>"${log_file}" 2>&1 &
  fi
  launcher=$!
  disown "${launcher}" 2>/dev/null || true

  local master=""
  local state=""
  local tries=0
  while ((tries < 50)); do
    state="$(_tunnel_ctl_ssh -o "ControlPath=${ctl}" -O check dummy@dummy 2>&1)"
    if [[ ${state} =~ Master\ running\ \(pid=([0-9]+)\) ]]; then
      master="${BASH_REMATCH[1]}"
      break
    fi
    tries=$((tries + 1))
    sleep 0.1
  done

  if [[ -z ${master} ]]; then
    kill -TERM "${launcher}" 2>/dev/null || true
    local tail_out=""
    if [[ -f "${log_file}" ]]; then
      tail_out="$(tail -n 5 "${log_file}" 2>/dev/null || true)"
    fi
    die 5 "tunnel start failed: ${id} -> 127.0.0.1:${local_port} via ${ssh_target}${tail_out:+ (ssh: ${tail_out})}"
  fi

  printf '%s\n' "${master}" | atomic_write "${pid_file}"
  printf '%s\n' "${master}"
}

# tunnel_stop <id> — graceful `ssh -O exit` then pid TERM/KILL fallback.
tunnel_stop() {
  local id="${1}"
  local dir
  dir="$(tunnel_control_dir)"
  local ctl="${dir}/ctl-${id}"
  local pid_file="${dir}/pid-${id}"

  if [[ -S "${ctl}" ]]; then
    timeout 5 _tunnel_ctl_ssh -o "ControlPath=${ctl}" -O exit dummy@dummy >/dev/null 2>&1 || true
  fi

  local pid=""
  if [[ -f "${pid_file}" ]]; then
    pid="$(<"${pid_file}")"
  fi
  if [[ ${pid} =~ ^[0-9]+$ ]] && kill -0 "${pid}" 2>/dev/null; then
    kill -TERM "${pid}" 2>/dev/null || true
    local waits=0
    while ((waits < 30)); do
      kill -0 "${pid}" 2>/dev/null || break
      waits=$((waits + 1))
      sleep 0.1
    done
    kill -KILL "${pid}" 2>/dev/null || true
  fi

  rm -f "${ctl}" "${pid_file}" "${dir}/target-${id}"
}

# tunnel_reap <id> [pid] — stop + hard-kill leftover pid + drop stale files.
tunnel_reap() {
  local id="${1}"
  local pid="${2:-}"
  local dir
  dir="$(tunnel_control_dir)"
  tunnel_stop "${id}"
  if [[ ${pid} =~ ^[0-9]+$ ]] && kill -0 "${pid}" 2>/dev/null; then
    kill -KILL "${pid}" 2>/dev/null || true
  fi
  rm -f "${dir}/ctl-${id}" "${dir}/pid-${id}" "${dir}/target-${id}"
}

# ---------------------------------------------------------------------------
# doctor reconcile primitive (A.3: default report; --fix repairs; --prune drops)
# T1's bin/forward cmd_doctor should delegate here; state funcs come from T1.
# ---------------------------------------------------------------------------
tunnel_doctor() {
  local mode="${1:-report}"
  local fix=0
  local prune=0
  case "${mode}" in
  report | '') ;;
  --fix) fix=1 ;;
  --prune) prune=1 ;;
  *)
    die 1 "unknown doctor option: ${mode} (expected --fix, --prune, or none)"
    ;;
  esac
  require_cmd jq

  local json
  json="$(forward_list_json)"
  local count
  count="$(jq 'length' <<<"${json}")"

  local i id pid local_port status alive probe
  for ((i = 0; i < count; i++)); do
    id="$(jq -r ".[${i}].id" <<<"${json}")"
    pid="$(jq -r ".[${i}].pid // empty" <<<"${json}")"
    local_port="$(jq -r ".[${i}].local_port" <<<"${json}")"
    status="$(jq -r ".[${i}].status" <<<"${json}")"
    alive="$(tunnel_alive "${pid}")"
    probe="$(tunnel_probe "${local_port}")"

    if [[ ${alive} == 'true' && ${probe} == 'ok' ]]; then
      if ((fix)) && [[ ${status} != 'up' ]]; then
        forward_set_status "${id}" up
        printf '%s: fixed -> up\n' "${id}"
      else
        printf '%s: up\n' "${id}"
      fi
    elif ((prune)); then
      tunnel_reap "${id}" "${pid}"
      forward_remove_record "${id}"
      printf '%s: pruned\n' "${id}"
    elif ((fix)); then
      forward_set_status "${id}" down
      printf '%s: fixed -> down\n' "${id}"
    else
      printf '%s: down\n' "${id}"
    fi
  done
  return 0
}
