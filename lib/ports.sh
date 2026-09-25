#!/usr/bin/env bash
# lib/ports.sh — 本机 TCP 监听端口发现（面板「LISTENING」段：一键映射到 client）
#
# 只列经 localhost 可达的监听（loopback / 通配地址）：桥接的目标恒为 B 的 localhost，
# 绑在具体网卡地址上的服务用 localhost 连不到，列出来只会误导。端口 < 1024 不列
# （sshd 等系统服务；需要时仍可手动 forward add）。
#
# 数据源按可用性降级：ss（Linux，带进程名）→ /proc/net/tcp{,6}（无进程名）→ lsof（macOS）。
set -o errexit -o nounset -o pipefail

_PORTS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh disable=SC1091
source "${_PORTS_LIB_DIR}/common.sh"

# ports_addr_is_local <addr> -> stdout "yes"（经 localhost 可达）/ 空
#   addr 已去掉方括号与 %iface 后缀。localhost 只解析到 127.0.0.1 / ::1：绑在其它
#   127.x 上的（systemd-resolved 的 127.0.0.53、容器 DNS 的 127.0.0.11）经桥接连不到。
ports_addr_is_local() {
  local addr="${1-}"
  case "${addr}" in
  '*' | 0.0.0.0 | :: | ::1 | 127.0.0.1 | ::ffff:127.0.0.1) printf 'yes\n' ;;
  *) ;;
  esac
  return 0
}

# _ports_emit <port> <addr> <process>：过滤后输出一行 TSV
_ports_emit() {
  local port="${1-}"
  local addr="${2-}"
  local proc="${3-}"
  [[ ${port} =~ ^[1-9][0-9]{0,4}$ ]] || return 0
  ((port >= 1024 && port <= 65535)) || return 0
  addr="${addr#\[}"
  addr="${addr%\]}"
  addr="${addr%%\%*}"
  local ok=""
  ok="$(ports_addr_is_local "${addr}")"
  [[ ${ok} == "yes" ]] || return 0
  printf '%s\t%s\t%s\n' "${port}" "${addr}" "${proc}"
}

# ports_parse_ss <ss -Htlnp 输出> -> stdout: port<TAB>addr<TAB>process
ports_parse_ss() {
  local text="${1-}"
  local line="" local_addr="" proc="" port="" addr=""
  local -a cols=()
  while IFS= read -r line; do
    [[ -n ${line} ]] || continue
    IFS=' ' read -r -a cols <<<"${line}"
    local_addr="${cols[3]-}"
    [[ ${local_addr} == *:* ]] || continue
    port="${local_addr##*:}"
    addr="${local_addr%:*}"
    proc=""
    if [[ ${line} =~ users:\(\(\"([^\"]*)\" ]]; then
      proc="${BASH_REMATCH[1]}"
    fi
    _ports_emit "${port}" "${addr}" "${proc}"
  done <<<"${text}"
  return 0
}

# _ports_proc_addr <hex> -> stdout: 人类可读地址（/proc/net/tcp 的 little-endian 十六进制）
_ports_proc_addr() {
  local hex="${1-}"
  hex="$(hf_upper "${hex}")"
  if ((${#hex} == 8)); then
    printf '%d.%d.%d.%d\n' "$((16#${hex:6:2}))" "$((16#${hex:4:2}))" "$((16#${hex:2:2}))" "$((16#${hex:0:2}))"
    return 0
  fi
  case "${hex}" in
  00000000000000000000000000000000) printf '::\n' ;;
  00000000000000000000000001000000) printf '::1\n' ;;
  0000000000000000FFFF0000*)
    local v4="${hex:24:8}"
    printf '::ffff:%d.%d.%d.%d\n' "$((16#${v4:6:2}))" "$((16#${v4:4:2}))" "$((16#${v4:2:2}))" "$((16#${v4:0:2}))"
    ;;
  *) printf '%s\n' "${hex}" ;;
  esac
}

# ports_parse_proc <内容> -> stdout: port<TAB>addr<TAB>（/proc 不给进程名）
ports_parse_proc() {
  local text="${1-}"
  local line="" local_hex="" state="" addr="" port_hex=""
  local -a cols=()
  while IFS= read -r line; do
    IFS=' ' read -r -a cols <<<"${line}"
    local_hex="${cols[1]-}"
    state="${cols[3]-}"
    [[ ${state} == "0A" && ${local_hex} == *:* ]] || continue
    port_hex="${local_hex##*:}"
    [[ ${port_hex} =~ ^[0-9A-Fa-f]{4}$ ]] || continue
    addr="$(_ports_proc_addr "${local_hex%%:*}")"
    _ports_emit "$((16#${port_hex}))" "${addr}" ""
  done <<<"${text}"
  return 0
}

# ports_parse_lsof <lsof -nP -iTCP -sTCP:LISTEN 输出> -> stdout: port<TAB>addr<TAB>process
ports_parse_lsof() {
  local text="${1-}"
  local line="" name="" proc="" port="" addr=""
  local -a cols=()
  while IFS= read -r line; do
    IFS=' ' read -r -a cols <<<"${line}"
    [[ ${cols[0]-} != "COMMAND" ]] || continue
    proc="${cols[0]-}"
    name="${cols[8]-}"
    [[ ${name} == *:* ]] || continue
    port="${name##*:}"
    addr="${name%:*}"
    _ports_emit "${port}" "${addr}" "${proc}"
  done <<<"${text}"
  return 0
}

# ports_listening_json -> stdout: [{port, addr, process}]（按端口去重、升序；无数据源 -> []）
ports_listening_json() {
  local rows=""
  if command -v ss >/dev/null 2>&1; then
    local raw=""
    raw="$(ss -Htlnp 2>/dev/null || true)"
    rows="$(ports_parse_ss "${raw}")"
  elif [[ -r /proc/net/tcp ]]; then
    local raw4="" raw6=""
    raw4="$(</proc/net/tcp)"
    if [[ -r /proc/net/tcp6 ]]; then
      raw6="$(</proc/net/tcp6)"
    fi
    rows="$(ports_parse_proc "${raw4}"$'\n'"${raw6}")"
  elif command -v lsof >/dev/null 2>&1; then
    local rawl=""
    rawl="$(lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null || true)"
    rows="$(ports_parse_lsof "${rawl}")"
  fi
  printf '%s' "${rows}" | jq -R -s -c '
    split("\n") | map(select(length > 0) | split("\t")
      | {port: (.[0] | tonumber), addr: .[1], process: (.[2] // "")})
    | group_by(.port)
    | map((map(select(.process != "")) | first) // first)
    | sort_by(.port)
  '
}
