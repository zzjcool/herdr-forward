#!/usr/bin/env bash
# lib/state.sh — forwards.json 读写（唯一状态权威）
# A.2 数据契约：{version:1, forwards:[{id,local_port,remote_host,remote_port,machine,
#   ssh_target,pid,control_socket,status,created_unix,mode,publish:{pid,url,started_unix}}]}
#   mode（A.3.3 追加）：tunnel = 本机 ssh -L（默认，旧记录缺字段即 tunnel）；
#   client = 监听在 attach 过来的 client（A）的 localhost，由桥接会话代为打开。
# A.3 冻结签名：state_file / state_load / state_save / forward_add_record /
#   forward_remove_record / forward_get / forward_list_json / forward_set_status
#
# 依赖 lib/common.sh（log/die/now_unix/atomic_write/state_dir），使用前须先 source。
# 唯一 writer：T1。见 docs/ARCHITECTURE.md §A.2 / §A.3。
set -o errexit -o nounset -o pipefail

# 状态文件 schema 版本（A.2）
if [[ -z ${FORWARD_STATE_VERSION:-} ]]; then
  readonly FORWARD_STATE_VERSION=1
fi

# 合法状态取值（A.2）
if [[ -z ${FORWARD_VALID_STATUS:-} ]]; then
  readonly FORWARD_VALID_STATUS="starting up down"
fi

# _state_require_jq：state 层强依赖 jq
_state_require_jq() {
  require_cmd jq "状态层需要 jq 解析 forwards.json。请安装后重试（如 pacman -S jq）。"
}

# state_file：stdout 状态文件绝对路径（env 解析，A.2）
state_file() {
  local dir=""
  dir="$(state_dir)"
  printf '%s\n' "${dir}/forwards.json"
}

# _state_tmpdir：与状态文件同分区的临时目录（atomic_write 前提）
_state_tmpdir() {
  local dir=""
  dir="$(state_dir)"
  printf '%s\n' "${dir}"
}

# state_load：stdout jq '.forwards' 数组；损坏 -> [] + warn，绝不 crash
state_load() {
  _state_require_jq
  local file=""
  file="$(state_file)"

  if [[ ! -f "${file}" ]]; then
    printf '[]\n'
    return 0
  fi

  # 文件不可解析 / 顶层非对象 / 缺 forwards 键 / forwards 非数组 一律降级空数组 + warn
  local kind=""
  set +o errexit
  kind="$(jq -r 'type' "${file}" 2>/dev/null)"
  local rc=$?
  set -o errexit
  if [[ "${rc}" -ne 0 || "${kind}" != "object" ]]; then
    log warn "状态文件不可解析或非对象：${file}，按空状态继续（原文件保留，未被覆盖）。"
    printf '[]\n'
    return 0
  fi

  local forwards_kind=""
  set +o errexit
  forwards_kind="$(jq -r '.forwards | type' "${file}" 2>/dev/null)"
  rc=$?
  set -o errexit
  if [[ "${rc}" -ne 0 || "${forwards_kind}" != "array" ]]; then
    log warn "状态文件缺少 forwards 数组：${file}，按空状态继续（原文件保留，未被覆盖）。"
    printf '[]\n'
    return 0
  fi

  local arr=""
  set +o errexit
  arr="$(jq -c '.forwards' "${file}" 2>/dev/null)"
  rc=$?
  set -o errexit
  if [[ "${rc}" -ne 0 ]]; then
    log warn "读取 forwards 数组失败：${file}，按空状态继续。"
    printf '[]\n'
    return 0
  fi

  printf '%s\n' "${arr}"
}

# state_save <json_forwards_array>：原子写；version 封装 + jq 格式化排序
state_save() {
  _state_require_jq
  local forwards_json="${1-}"
  if [[ -z "${forwards_json}" ]]; then
    die 1 "state_save 需要 JSON 数组参数。请检查调用方（内部错误）。"
  fi

  local kind=""
  set +o errexit
  kind="$(printf '%s' "${forwards_json}" | jq -r 'type' 2>/dev/null)"
  local rc=$?
  set -o errexit
  if [[ "${rc}" -ne 0 ]]; then
    die 1 "state_save 收到非法 JSON。请检查调用方（内部错误）。"
  fi
  if [[ "${kind}" != "array" ]]; then
    die 1 "state_save 只接受 JSON 数组（收到 ${kind}）。请检查调用方（内部错误）。"
  fi

  local doc=""
  set +o errexit
  doc="$(printf '%s' "${forwards_json}" | jq -S -c --argjson v "${FORWARD_STATE_VERSION}" \
    '{version: $v, forwards: .}')"
  rc=$?
  set -o errexit
  if [[ "${rc}" -ne 0 ]]; then
    die 1 "state_save 组装状态文档失败。请检查输入 JSON 结构后重试。"
  fi

  local file=""
  local tmpdir=""
  file="$(state_file)"
  tmpdir="$(_state_tmpdir)"
  printf '%s\n' "${doc}" | atomic_write "${file}" "${tmpdir}"
}

# _state_valid_port <port>：合法 TCP 端口（1-65535 整数）
_state_valid_port() {
  local port="${1-}"
  [[ "${port}" =~ ^[0-9]+$ ]] || return 1
  ((port >= 1 && port <= 65535))
}

# forward_add_record <record_json>：写入（local_port/id 冲突 die 2，不覆盖）
forward_add_record() {
  _state_require_jq
  local record="${1-}"
  if [[ -z "${record}" ]]; then
    die 1 "forward_add_record 需要 record JSON 参数。请检查调用方（内部错误）。"
  fi

  local kind=""
  set +o errexit
  kind="$(printf '%s' "${record}" | jq -r 'type' 2>/dev/null)"
  local rc=$?
  set -o errexit
  if [[ "${rc}" -ne 0 || "${kind}" != "object" ]]; then
    die 1 "forward_add_record 需要 JSON 对象（收到 ${kind:-非法 JSON}）。请检查调用方（内部错误）。"
  fi

  local local_port=""
  set +o errexit
  local_port="$(printf '%s' "${record}" | jq -r '.local_port // empty' 2>/dev/null)"
  set -o errexit
  if [[ -z "${local_port}" ]]; then
    die 1 "forward_add_record 缺少 local_port。请在 record JSON 中提供 1-65535 的 local_port。"
  fi
  local port_ok=""
  set +o errexit
  _state_valid_port "${local_port}"
  local port_rc=$?
  set -o errexit
  [[ "${port_rc}" -eq 0 ]] && port_ok="yes"
  if [[ -z "${port_ok}" ]]; then
    die 1 "forward_add_record 的 local_port 非法：${local_port}。请使用 1-65535 的整数。"
  fi

  local id="f-${local_port}"
  local existing=""
  existing="$(state_load)"

  local dup=""
  set +o errexit
  dup="$(printf '%s' "${existing}" | jq -r --arg id "${id}" \
    --argjson lp "${local_port}" \
    '[.[] | select(.id == $id or .local_port == $lp)] | length' 2>/dev/null)"
  set -o errexit
  if [[ "${dup}" != "0" ]]; then
    die 2 "本地端口 ${local_port} 已被占用（记录 ${id} 已存在）。请先 forward list 查看，或用 forward remove ${id} 删除后再 add。"
  fi

  # 归一化：补全缺省字段，publish 占位恒 null（一期）
  local ready=""
  local now=""
  now="$(now_unix)"
  set +o errexit
  ready="$(printf '%s' "${record}" | jq -c --arg id "${id}" \
    --argjson now "${now}" '
      {
        id: $id,
        local_port: .local_port,
        remote_host: (.remote_host // "127.0.0.1"),
        remote_port: (.remote_port // .local_port),
        machine: (.machine // ""),
        ssh_target: (.ssh_target // ""),
        pid: (.pid // null),
        control_socket: (.control_socket // ""),
        status: (.status // "starting"),
        created_unix: (.created_unix // $now),
        mode: (if .mode == "client" then "client" else "tunnel" end),
        publish: {pid: null, url: null, started_unix: null}
      }
    ' 2>/dev/null)"
  rc=$?
  set -o errexit
  if [[ "${rc}" -ne 0 ]]; then
    die 1 "forward_add_record 归一化记录失败。请检查 record JSON 字段后重试。"
  fi

  local merged=""
  set +o errexit
  merged="$(jq -c --argjson rec "${ready}" '. + [$rec]' <<<"${existing}" 2>/dev/null)"
  rc=$?
  set -o errexit
  if [[ "${rc}" -ne 0 ]]; then
    die 1 "forward_add_record 合并状态失败。请检查现有状态文件后重试。"
  fi

  state_save "${merged}"
}

# forward_remove_record <id>：删除（不存在 die 3）
forward_remove_record() {
  _state_require_jq
  local id="${1-}"
  if [[ -z "${id}" ]]; then
    die 3 "forward_remove_record 需要 id 参数。请用 forward list 查看 id 后重试。"
  fi

  local existing=""
  existing="$(state_load)"

  local found=""
  set +o errexit
  found="$(printf '%s' "${existing}" | jq -r --arg id "${id}" \
    '[.[] | select(.id == $id)] | length' 2>/dev/null)"
  set -o errexit
  if [[ "${found}" == "0" || -z "${found}" ]]; then
    die 3 "记录不存在：${id}。请用 forward list 查看现有 id 后重试。"
  fi

  local remaining=""
  set +o errexit
  remaining="$(printf '%s' "${existing}" | jq -c --arg id "${id}" \
    '[.[] | select(.id != $id)]' 2>/dev/null)"
  set -o errexit

  state_save "${remaining}"
}

# forward_get <id>：stdout 单条 record json（不存在 die 3）
forward_get() {
  _state_require_jq
  local id="${1-}"
  if [[ -z "${id}" ]]; then
    die 3 "forward_get 需要 id 参数。请用 forward list 查看 id 后重试。"
  fi

  local existing=""
  existing="$(state_load)"

  local rec=""
  set +o errexit
  rec="$(printf '%s' "${existing}" | jq -c --arg id "${id}" \
    '[.[] | select(.id == $id)] | .[0] // empty' 2>/dev/null)"
  set -o errexit
  if [[ -z "${rec}" ]]; then
    die 3 "记录不存在：${id}。请用 forward list 查看现有 id 后重试。"
  fi

  printf '%s\n' "${rec}"
}

# forward_list_json：stdout 完整数组（= state_load）
forward_list_json() {
  state_load
}

# forward_set_status <id> <status>：修状态（非法 status die 1，不存在 id die 3）
forward_set_status() {
  _state_require_jq
  local id="${1-}"
  local status="${2-}"
  if [[ -z "${id}" || -z "${status}" ]]; then
    die 1 "forward_set_status 用法：forward_set_status <id> <status>。status 取 starting|up|down。"
  fi

  # 用 read -ra + 显式 IFS=' ' 拆分（不依赖调用方 IFS；bin/forward 设了 IFS=$'\n\t'）
  local valid="false"
  local -a allowed=()
  IFS=' ' read -ra allowed <<<"${FORWARD_VALID_STATUS}"
  local candidate=""
  for candidate in "${allowed[@]}"; do
    if [[ "${candidate}" == "${status}" ]]; then
      valid="true"
    fi
  done
  if [[ "${valid}" != "true" ]]; then
    die 1 "非法状态：${status}。允许值：${FORWARD_VALID_STATUS// /, }。"
  fi

  local existing=""
  existing="$(state_load)"

  local found=""
  set +o errexit
  found="$(printf '%s' "${existing}" | jq -r --arg id "${id}" \
    '[.[] | select(.id == $id)] | length' 2>/dev/null)"
  set -o errexit
  if [[ "${found}" == "0" || -z "${found}" ]]; then
    die 3 "记录不存在：${id}。请用 forward list 查看现有 id 后重试。"
  fi

  local updated=""
  set +o errexit
  updated="$(printf '%s' "${existing}" | jq -c --arg id "${id}" --arg st "${status}" \
    '[.[] | if .id == $id then .status = $st else . end]' 2>/dev/null)"
  set -o errexit

  state_save "${updated}"
}

# --- 附加 helper（A.3 未冻结；T1 提供给 T2 复用，报告已标注） ---

# forward_set_pid <id> <pid|"">：设置隧道 pid（空 -> null）
forward_set_pid() {
  _state_require_jq
  local id="${1-}"
  local pid="${2-}"
  if [[ -z "${id}" ]]; then
    die 1 "forward_set_pid 用法：forward_set_pid <id> <pid|空>。"
  fi

  local existing=""
  existing="$(state_load)"

  local found=""
  set +o errexit
  found="$(printf '%s' "${existing}" | jq -r --arg id "${id}" \
    '[.[] | select(.id == $id)] | length' 2>/dev/null)"
  set -o errexit
  if [[ "${found}" == "0" || -z "${found}" ]]; then
    die 3 "记录不存在：${id}。请用 forward list 查看现有 id 后重试。"
  fi

  local updated=""
  set +o errexit
  updated="$(printf '%s' "${existing}" | jq -c --arg id "${id}" --arg pid "${pid}" \
    '[.[] | if .id == $id then .pid = (if ($pid | length) > 0 then ($pid | tonumber) else null end) else . end]' 2>/dev/null)"
  set -o errexit

  state_save "${updated}"
}
