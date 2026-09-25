#!/usr/bin/env bash
# lib/tunnel.sh — ssh -L tunnel lifecycle with a self-built ControlMaster.
# Frozen API (ARCHITECTURE.md A.3):
#   tunnel_start <id> <local_port> <remote_host:remote_port> <ssh_target>  -> stdout pid; die 5
#   tunnel_stop  <id>
#   tunnel_alive <pid>        -> stdout true|false (kill -0 and not zombie)
#   tunnel_probe <local_port> -> stdout up|degraded|down (payload probe; see A.3.1)
# Extra liveness primitives used by `forward doctor` (T1 cmd layer delegates here):
#   tunnel_health <id> <pid> <local_port> -> up|degraded|down
#   tunnel_reap   <id> [pid]              -> stop + remove socket/pidfile (idempotent)
#   tunnel_doctor [--fix|--prune]         -> reconcile status against liveness
set -Eeuo pipefail

# ---------------------------------------------------------------------------
# common.sh bridge: log/die/require_cmd/now_unix/atomic_write/probe_tcp 一律来自 T1
# 的 lib/common.sh（唯一权威）。N3（review nit）：此前的「缺 common.sh 就自带一份
# 同构回退实现」副本已删除——它与 common.sh 平行漂移，且让唯一 writer 契约失效。
# 本库必须与 lib/common.sh 一起发布；tests 若需独立 source 本库，common.sh 就
# 在本目录旁边，会被下面的 source 自动加载。
# ---------------------------------------------------------------------------
_TUNNEL_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh disable=SC1091
source "${_TUNNEL_LIB_DIR}/common.sh"

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

# tunnel_ssh_path_escape <path> -> stdout: <path> with every % doubled.
#
# 为什么必须转义（真实环境 bug）：herdr 插件把 state 目录命名为 URL 编码的
# `zzjcool%3Aforward`。ssh 对 `-o ControlPath=` / `-o UserKnownHostsFile=` 的值做
# percent token 展开，`%3` 不是合法 token，于是 ssh 直接失败：
#   vdollar_percent_expand: unknown key %3
#   percent_dollar_expand: failed
# 隧道永远起不来。ssh 认 `%%` 为字面 `%`，故把值里的每个 % 翻倍即可；
# ssh 展开后还原成真实路径。
# 注意：**只**用于交给 ssh -o 的路径值。mkdir / [[ -S ]] / rm 等文件系统操作
# 必须继续用原路径（它们不做 percent 展开），否则会去找一个不存在的 `%%` 目录。
# 纯 bash 参数展开（零 fork）。
tunnel_ssh_path_escape() {
  local path="${1:-}"
  printf '%s\n' "${path//\%/%%}"
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
  local item=""
  while IFS= read -r item; do
    parsed+=("${item}")
  done <<<"${parsed_raw}"
  local port="${parsed[0]}"
  local dest="${parsed[1]}"
  local dir
  dir="$(tunnel_control_dir)"
  # ssh -o 的值必须做 % 转义（state dir 名可能含 %，见 tunnel_ssh_path_escape）。
  local ssh_ctl_path=""
  ssh_ctl_path="$(tunnel_ssh_path_escape "${dir}/ctl-${id}")"
  local ssh_khf=""
  ssh_khf="$(tunnel_ssh_path_escape "${dir}/known_hosts")"
  printf '%s\n' \
    '-N' \
    '-L' "127.0.0.1:${local_port}:${remote}" \
    '-o' 'BatchMode=yes' \
    '-o' 'ExitOnForwardFailure=yes' \
    '-o' 'ControlMaster=auto' \
    '-o' "ControlPath=${ssh_ctl_path}" \
    '-o' 'ControlPersist=yes' \
    '-o' 'StrictHostKeyChecking=accept-new' \
    '-o' "UserKnownHostsFile=${ssh_khf}" \
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

# tunnel_probe <local_port> -> stdout: up|degraded|down
# A.3.1（review D1 契约修正）：不再只做本地 TCP 握手（那样在 master 活着时恒 ok，
# 会把远端应用已死误报为 up），改为经隧道发真 payload 看远端是否可达。
tunnel_probe() {
  local local_port="${1}"
  probe_payload 127.0.0.1 "${local_port}"
}

# tunnel_health <id> <pid> <local_port> -> stdout: up|degraded|down
# A.3.1：master 不活一律 down；否则透传 tunnel_probe 的三级结果（语义见契约）。
tunnel_health() {
  local id="${1}"
  local pid="${2:-}"
  local local_port="${3}"
  local alive probe
  alive="$(tunnel_alive "${pid}")"
  if [[ ${alive} != 'true' ]]; then
    printf 'down\n'
    return 0
  fi
  probe="$(tunnel_probe "${local_port}")"
  printf '%s\n' "${probe}"
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
  # 只有交给 ssh 的值需要 % 转义；ctl 本身仍是文件系统路径（[[ -S ]] / rm 用）。
  local ctl_ssh=""
  ctl_ssh="$(tunnel_ssh_path_escape "${ctl}")"
  local log_file="${dir}/log-${id}"
  local pid_file="${dir}/pid-${id}"
  local target_file="${dir}/target-${id}"
  local args_raw=""
  args_raw="$(tunnel_ssh_args "${id}" "${local_port}" "${remote}" "${ssh_target}")"
  local -a args=()
  local arg=""
  while IFS= read -r arg; do
    args+=("${arg}")
  done <<<"${args_raw}"

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
    state="$(_tunnel_ctl_ssh -o "ControlPath=${ctl_ssh}" -O check dummy@dummy 2>&1)"
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

  # atomic_write needs an explicit same-filesystem tmpdir (A.3 signature). Without it
  # the pid file silently never lands and tunnel_stop loses its pid fallback.
  # 不用 `if ! … | atomic_write`：那会命中 SC2310（条件内 set -e 被禁用）。
  local write_rc=0
  set +o errexit
  printf '%s\n' "${master}" | atomic_write "${pid_file}" "${dir}"
  write_rc=$?
  set -o errexit
  if [[ "${write_rc}" -ne 0 ]]; then
    log warn "tunnel_start: could not record pid ${master} in ${pid_file}; tunnel_stop will fall back to the control socket only."
  fi
  printf '%s\n' "${master}"
}

# tunnel_stop <id> — graceful `ssh -O exit` then pid TERM/KILL fallback.
tunnel_stop() {
  local id="${1}"
  local dir
  dir="$(tunnel_control_dir)"
  local ctl="${dir}/ctl-${id}"
  local pid_file="${dir}/pid-${id}"
  local ctl_ssh=""
  ctl_ssh="$(tunnel_ssh_path_escape "${ctl}")"

  # Graceful shutdown via the control socket. `timeout` can only exec a *program*,
  # never a shell function, so the ssh binary is invoked directly here; wrapping
  # _tunnel_ctl_ssh would exit 127 and silently skip the graceful path.
  if [[ -S "${ctl}" ]]; then
    timeout 5 ssh -F /dev/null -o BatchMode=yes -o "ControlPath=${ctl_ssh}" \
      -O exit dummy@dummy >/dev/null 2>&1 || true
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

  # The master may still be running when neither path above was available (e.g. the
  # control socket was already gone and the pid file was lost). Report it instead of
  # pretending the tunnel is down, so callers keep a truthful status.
  if [[ ${pid} =~ ^[0-9]+$ ]] && kill -0 "${pid}" 2>/dev/null; then
    log warn "tunnel_stop: ssh master ${pid} (${id}) is still alive after TERM/KILL; the tunnel may still be listening."
  fi

  # N2（review nit）：一并清掉本隧道的 ssh 日志 log-<id>（每隧道一份，停后即无用）。
  # 刻意**不删** known_hosts：它是跨隧道共用的沙箱 host key 缓存（StrictHostKeyChecking=accept-new 只信任一次），
  # 删掉会让下一次 start 重新 accept-new——保留它是有意行为，不是遗漏。
  rm -f "${ctl}" "${pid_file}" "${dir}/target-${id}" "${dir}/log-${id}"
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
  rm -f "${dir}/ctl-${id}" "${dir}/pid-${id}" "${dir}/target-${id}" "${dir}/log-${id}"
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

  # client 映射（A.3.3）的监听在 attach 过来的 client 上，本机既无进程也探不到端口：
  # 若混进来会被判 down，--prune 还会把用户登记的映射删掉。
  local json
  json="$(forward_list_json)"
  json="$(jq -c '[.[] | select(.mode != "client")]' <<<"${json}")"
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

    # A.3.1 诚实分级：up=应用层有回包；degraded=远端端口可连但无回包；down=连不上。
    # status 字段仅允许 up|down，故 degraded 报告为 degraded 但 --fix 保守置 down（不 prune）。
    local effective="${probe}"
    [[ ${alive} == 'true' ]] || effective='down'
    local report="${effective}"
    local new_status="${effective}"
    [[ ${effective} == 'degraded' ]] && new_status='down'

    if [[ ${effective} == 'up' ]]; then
      if ((fix)) && [[ ${status} != 'up' ]]; then
        forward_set_status "${id}" up
        printf '%s: fixed -> up\n' "${id}"
      else
        printf '%s: up\n' "${id}"
      fi
    elif [[ ${effective} == 'degraded' ]]; then
      # 绝不自作主张报 up；也不 prune（master 可能还在，删记录会误伤活隧道）。
      if ((fix)) && [[ ${status} != "${new_status}" ]]; then
        forward_set_status "${id}" "${new_status}"
        printf '%s: degraded (no application-layer reply) -> fixed -> %s\n' "${id}" "${new_status}"
      else
        printf '%s: %s (no application-layer reply; status=%s)\n' "${id}" "${report}" "${status}"
      fi
    elif ((prune)) && [[ ${alive} != 'true' ]]; then
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
