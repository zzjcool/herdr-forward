#!/usr/bin/env bash
# lib/machines.sh — herdr saved machines（A 视角）视图 + 激活状态（activated-machines.json）
#
# 与 lib/machine.sh 的分工（名近但**正交**，勿混用；两侧头部注释互相指认）：
#   lib/machine.sh  单数：machines.toml 的 LABEL → ssh_target 解析（一期正式路径，`forward add --machine`）
#   lib/machines.sh 复数：herdr saved machines 列表（`$HERDR_BIN_PATH machine list --json`）
#                        + 激活状态持久化 + 面板/CLI 共用合并视图（`forward machines ...`）
# 两者互不依赖，可各自单独 source。
#
# 冻结签名（machines-integration-plan §2.2）：
#   machines_state_file / machines_herdr_list_json / machines_activation_load /
#   machines_activation_save / machines_activation_set / machines_activation_clear_active /
#   machines_activation_get / machines_view_json / machines_is_local_target
# 附加 helper（同文件，供 bin/forward 复用）：machines_lookup_json / machines_resolve_id /
#   machines_activation_has / machines_activation_remove / machines_activation_reset /
#   machines_ssh_probe_plugin / machines_kv_get
#
# 依赖 lib/common.sh（log / die / require_cmd / now_unix / atomic_write / state_dir）与 jq。
#
# 降级契约（§1，硬要求）：$HERDR_BIN_PATH 缺失 / `machine list` 失败 / 输出非 JSON
#   一律退化为空列表 + log warn，**绝不 die** —— 插件在没配 machines 的机器（B 侧）上
#   也必须能打开面板。
set -Eeuo pipefail

# common.sh 是唯一权威（N3 契约：lib 内不得自带 log/die 回退副本）
_TUNNEL_MACHINES_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh disable=SC1091
source "${_TUNNEL_MACHINES_LIB_DIR}/common.sh"

# activated-machines.json schema 版本（§1）
if [[ -z ${MACHINES_ACTIVATION_VERSION:-} ]]; then
  readonly MACHINES_ACTIVATION_VERSION=1
fi
# `machine list --json` 的探测超时（秒）：面板/CLI 都不能被一个卡住的 herdr 挂死
if [[ -z ${MACHINES_HERDR_TIMEOUT:-} ]]; then
  readonly MACHINES_HERDR_TIMEOUT=5
fi

_machines_require_jq() {
  require_cmd jq "machines 数据层需要 jq 解析 JSON。请安装后重试（如 pacman -S jq）。"
}

# machines_state_file -> stdout: $HERDR_PLUGIN_STATE_DIR/activated-machines.json
machines_state_file() {
  local dir=""
  dir="$(state_dir)"
  printf '%s\n' "${dir}/activated-machines.json"
}

# _machines_empty_doc -> stdout: {version, active:null, machines:{}}（恒合法）
_machines_empty_doc() {
  printf '{"version":%d,"active":null,"machines":{}}\n' "${MACHINES_ACTIVATION_VERSION}"
}

# ---------------------------------------------------------------------------
# herdr saved machines 列表
# ---------------------------------------------------------------------------

# machines_herdr_list_json -> stdout: machine 数组（事实 #1 schema 原样透传）
#   `$HERDR_BIN_PATH machine list --json`（timeout 包裹）；缺失/失败/非 JSON -> "[]" + warn。
#   容错：也接受被包了一层的 {"result":{"machines":[...]}} / {"machines":[...]}
#   （herdr 各子命令 --json 的包裹层不统一，见 setup-client.sh 的 plugin list --json 实证）。
machines_herdr_list_json() {
  local bin="${HERDR_BIN_PATH:-}"
  if [[ -z ${bin} ]]; then
    log warn "未设置 HERDR_BIN_PATH（herdr 插件运行时注入），saved machines 列表按空处理。既非错误也无需处理：在 herdr 里通过插件打开面板时该变量会自动存在。"
    printf '[]\n'
    return 0
  fi
  if [[ ! -x ${bin} ]] && ! command -v "${bin}" >/dev/null 2>&1; then
    log warn "HERDR_BIN_PATH=${bin} 不可执行，saved machines 列表按空处理。请在 herdr 内运行（herdr 注入的路径才有效），或检查 herdr 安装。"
    printf '[]\n'
    return 0
  fi

  local raw=""
  local rc=0
  set +o errexit
  if command -v timeout >/dev/null 2>&1; then
    raw="$(timeout "${MACHINES_HERDR_TIMEOUT}" "${bin}" machine list --json 2>/dev/null)"
    rc=$?
  else
    raw="$("${bin}" machine list --json 2>/dev/null)"
    rc=$?
  fi
  set -o errexit

  if [[ ${rc} -ne 0 || -z ${raw} ]]; then
    log warn "获取 saved machines 失败（${bin} machine list --json，rc=${rc}），按空列表继续。可手动执行该命令排查（herdr 未启动 / 未登录时也会如此）。"
    printf '[]\n'
    return 0
  fi

  local arr=""
  local jrc=0
  set +o errexit
  arr="$(printf '%s' "${raw}" | jq -c '
    (if type == "array" then .
     elif type == "object" and (.machines | type) == "array" then .machines
     elif type == "object" and (.result | type) == "object" and (.result.machines | type) == "array" then .result.machines
     elif type == "object" and (.result | type) == "array" then .result
     else error("not a machine array") end)
    | [ .[] | select(type == "object") | select(.id != null) ]
  ' 2>/dev/null)"
  jrc=$?
  set -o errexit

  if [[ ${jrc} -ne 0 || -z ${arr} ]]; then
    log warn "saved machines 输出不是预期的 JSON 数组（${bin} machine list --json），按空列表继续。请升级 herdr 或报告该输出格式。"
    printf '[]\n'
    return 0
  fi

  printf '%s\n' "${arr}"
}

# ---------------------------------------------------------------------------
# activated-machines.json 读写（§1 schema：{version, active, machines{}}）
# ---------------------------------------------------------------------------

# machines_activation_load -> stdout: 规范化后的 {version, active, machines} 对象
#   文件缺失 -> 空文档（正常首次运行，不 warn）；损坏 / 非对象 / machines 非对象
#   -> 空文档 + warn（原文件保留，绝不覆盖）。
machines_activation_load() {
  _machines_require_jq
  local file=""
  file="$(machines_state_file)"

  if [[ ! -f ${file} ]]; then
    _machines_empty_doc
    return 0
  fi

  local kind=""
  local rc=0
  set +o errexit
  kind="$(jq -r 'type' "${file}" 2>/dev/null)"
  rc=$?
  set -o errexit
  if [[ ${rc} -ne 0 || ${kind} != "object" ]]; then
    log warn "激活状态文件不可解析或非对象：${file}，按空状态继续（原文件保留，未被覆盖）。"
    _machines_empty_doc
    return 0
  fi

  local machines_kind=""
  set +o errexit
  machines_kind="$(jq -r '.machines | type' "${file}" 2>/dev/null)"
  rc=$?
  set -o errexit
  if [[ ${rc} -ne 0 || ${machines_kind} != "object" ]]; then
    log warn "激活状态文件缺少 machines 对象：${file}，按空状态继续（原文件保留，未被覆盖）。"
    _machines_empty_doc
    return 0
  fi

  local doc=""
  set +o errexit
  doc="$(jq -c --argjson v "${MACHINES_ACTIVATION_VERSION}" '
    {
      version: $v,
      active: (if (.active | type) == "string" and (.active | length) > 0 then .active else null end),
      machines: .machines
    }
  ' "${file}" 2>/dev/null)"
  rc=$?
  set -o errexit
  if [[ ${rc} -ne 0 || -z ${doc} ]]; then
    log warn "读取激活状态文件失败：${file}，按空状态继续（原文件保留，未被覆盖）。"
    _machines_empty_doc
    return 0
  fi

  printf '%s\n' "${doc}"
}

# machines_activation_save <full_json>：校验 + 规范化 + 原子写
machines_activation_save() {
  _machines_require_jq
  local doc="${1-}"
  if [[ -z ${doc} ]]; then
    die 1 "machines_activation_save 需要 JSON 参数。请检查调用方（内部错误）。"
  fi

  local kind=""
  local rc=0
  set +o errexit
  kind="$(printf '%s' "${doc}" | jq -r 'type' 2>/dev/null)"
  rc=$?
  set -o errexit
  if [[ ${rc} -ne 0 || ${kind} != "object" ]]; then
    die 1 "machines_activation_save 需要 JSON 对象（收到 ${kind:-非法 JSON}）。请检查调用方（内部错误）。"
  fi

  local machines_kind=""
  set +o errexit
  machines_kind="$(printf '%s' "${doc}" | jq -r '.machines | type' 2>/dev/null)"
  rc=$?
  set -o errexit
  if [[ ${rc} -ne 0 || ${machines_kind} != "object" ]]; then
    die 1 "machines_activation_save 的 JSON 缺少 machines 对象（收到 ${machines_kind:-非法}）。请检查调用方（内部错误）。"
  fi

  local ready=""
  set +o errexit
  ready="$(printf '%s' "${doc}" | jq -S -c --argjson v "${MACHINES_ACTIVATION_VERSION}" '
    {
      version: $v,
      active: (if (.active | type) == "string" and (.active | length) > 0 then .active else null end),
      machines: .machines
    }
  ' 2>/dev/null)"
  rc=$?
  set -o errexit
  if [[ ${rc} -ne 0 || -z ${ready} ]]; then
    die 1 "machines_activation_save 组装状态文档失败。请检查输入 JSON 结构后重试。"
  fi

  local file=""
  local tmpdir=""
  file="$(machines_state_file)"
  tmpdir="$(state_dir)"
  printf '%s\n' "${ready}" | atomic_write "${file}" "${tmpdir}"
}

# machines_activation_set <id> <record_json>：upsert（覆盖同 id 记录）并把 active 置为该 id
machines_activation_set() {
  _machines_require_jq
  local id="${1-}"
  local record="${2-}"
  if [[ -z ${id} ]]; then
    die 1 "machines_activation_set 需要 <id> 参数。请检查调用方（内部错误）。"
  fi
  if [[ -z ${record} ]]; then
    die 1 "machines_activation_set 需要 <record_json> 参数。请检查调用方（内部错误）。"
  fi

  local kind=""
  local rc=0
  set +o errexit
  kind="$(printf '%s' "${record}" | jq -r 'type' 2>/dev/null)"
  rc=$?
  set -o errexit
  if [[ ${rc} -ne 0 || ${kind} != "object" ]]; then
    die 1 "machines_activation_set 的 record 必须是 JSON 对象（收到 ${kind:-非法 JSON}）。请检查调用方（内部错误）。"
  fi

  # activated_unix 缺失时补 now（幂等重写会刷新为新的激活时间——符合 §1「重新探测 + 覆盖记录」）
  local now=""
  now="$(now_unix)"
  local fixed=""
  set +o errexit
  fixed="$(printf '%s' "${record}" | jq -c --argjson now "${now}" '
    if (.activated_unix | type) == "number" then . else . + {activated_unix: $now} end
  ' 2>/dev/null)"
  rc=$?
  set -o errexit
  if [[ ${rc} -ne 0 || -z ${fixed} ]]; then
    die 1 "machines_activation_set 规范化 record 失败。请检查 record JSON。"
  fi

  local doc=""
  local out=""
  doc="$(machines_activation_load)"
  set +o errexit
  out="$(printf '%s' "${doc}" | jq -S -c --arg id "${id}" --argjson rec "${fixed}" '
    .machines[$id] = $rec | .active = $id
  ' 2>/dev/null)"
  rc=$?
  set -o errexit
  if [[ ${rc} -ne 0 || -z ${out} ]]; then
    die 1 "machines_activation_set 写入记录失败（id=${id}）。请检查 record JSON。"
  fi

  machines_activation_save "${out}"
}

# machines_activation_clear_active：active -> null（记录保留，历史可查）
machines_activation_clear_active() {
  _machines_require_jq
  local doc=""
  local out=""
  local rc=0
  doc="$(machines_activation_load)"
  set +o errexit
  out="$(printf '%s' "${doc}" | jq -S -c '.active = null' 2>/dev/null)"
  rc=$?
  set -o errexit
  if [[ ${rc} -ne 0 || -z ${out} ]]; then
    local file=""
    file="$(machines_state_file)"
    die 1 "清空 active 失败。请检查 ${file} 是否可写。"
  fi
  machines_activation_save "${out}"
}

# machines_activation_reset：清空 active + 删除全部记录（`machines deactivate all`）
machines_activation_reset() {
  _machines_require_jq
  local out=""
  local rc=0
  set +o errexit
  out="$(jq -S -c -n --argjson v "${MACHINES_ACTIVATION_VERSION}" '{version: $v, active: null, machines: {}}' 2>/dev/null)"
  rc=$?
  set -o errexit
  if [[ ${rc} -ne 0 || -z ${out} ]]; then
    die 1 "重置激活状态失败。请检查 jq 是否可用。"
  fi
  machines_activation_save "${out}"
}

# machines_activation_remove <id>：删除单条记录（若它正是 active，则同时清 active）
machines_activation_remove() {
  _machines_require_jq
  local id="${1-}"
  if [[ -z ${id} ]]; then
    die 1 "machines_activation_remove 需要 <id> 参数。请检查调用方（内部错误）。"
  fi
  local doc=""
  local out=""
  local rc=0
  doc="$(machines_activation_load)"
  set +o errexit
  out="$(printf '%s' "${doc}" | jq -S -c --arg id "${id}" '
    .machines |= del(.[$id]) | .active = (if .active == $id then null else .active end)
  ' 2>/dev/null)"
  rc=$?
  set -o errexit
  if [[ ${rc} -ne 0 || -z ${out} ]]; then
    die 1 "删除激活记录失败（id=${id}）。请检查状态文件可写。"
  fi
  machines_activation_save "${out}"
}

# machines_activation_has <id> -> stdout: yes|no（恒 return 0，可安全用于条件）
machines_activation_has() {
  local id="${1-}"
  if [[ -z ${id} ]]; then
    printf 'no\n'
    return 0
  fi
  local doc=""
  doc="$(machines_activation_load)"
  local has=""
  set +o errexit
  has="$(printf '%s' "${doc}" | jq -r --arg id "${id}" 'if .machines[$id] == null then "no" else "yes" end' 2>/dev/null)"
  set -o errexit
  if [[ ${has} == "yes" ]]; then
    printf 'yes\n'
  else
    printf 'no\n'
  fi
  return 0
}

# machines_activation_get <id> -> stdout: 记录 JSON；不存在 -> die 3
machines_activation_get() {
  _machines_require_jq
  local id="${1-}"
  if [[ -z ${id} ]]; then
    die 3 "machines_activation_get 需要 <id> 参数。请检查调用方（内部错误）。"
  fi
  local doc=""
  local rec=""
  doc="$(machines_activation_load)"
  set +o errexit
  rec="$(printf '%s' "${doc}" | jq -c --arg id "${id}" '.machines[$id] // empty' 2>/dev/null)"
  set -o errexit
  if [[ -z ${rec} ]]; then
    die 3 "machine '${id}' 没有激活记录。请用 'forward machines list' 查看，或先 'forward machines activate ${id}'。"
  fi
  printf '%s\n' "${rec}"
}

# machines_activation_active -> stdout: 当前 active 的 id（无则空行，恒 return 0）
machines_activation_active() {
  local doc=""
  doc="$(machines_activation_load)"
  local active=""
  set +o errexit
  active="$(printf '%s' "${doc}" | jq -r '.active // ""' 2>/dev/null)"
  set -o errexit
  printf '%s\n' "${active}"
  return 0
}

# ---------------------------------------------------------------------------
# 同机判定（§1 同机短路；§5 风险 #2：只认强信号，拿不准一律走 ssh 探测）
# ---------------------------------------------------------------------------

# machines_is_local_target <ssh_target> -> stdout: yes|no
#   强信号：localhost / 127.0.0.1 / ::1（含 user@ 前缀与 :port）与
#   `hostname` / `hostname -s` / `hostname -f` 精确等值（大小写不敏感）。
#   不做 DNS 解析、不读 /etc/hosts —— 误判为远程只是多跑一次 ssh 探测，误判为本机才会写错路径。
machines_is_local_target() {
  local raw="${1-}"
  if [[ -z ${raw} ]]; then
    printf 'no\n'
    return 0
  fi

  local host="${raw}"
  # user@ 前缀（ssh_target 形如 user@host[:port]）
  if [[ ${host} == *@* ]]; then
    host="${host##*@}"
  fi
  # [v6] 或 [v6]:port
  if [[ ${host} =~ ^\[([^]]+)\](:([0-9]+))?$ ]]; then
    host="${BASH_REMATCH[1]}"
  elif [[ ${host} =~ ^([^:]+):([0-9]+)$ ]]; then
    # 恰好一个冒号且后半是端口 -> 剥离（`::1` 因首字符是 ':' 不落此分支）
    host="${BASH_REMATCH[1]}"
  fi

  local lowered="${host,,}"
  case "${lowered}" in
  localhost | localhost.localdomain | 127.0.0.1 | ::1 | 0:0:0:0:0:0:0:1)
    printf 'yes\n'
    return 0
    ;;
  *) ;;
  esac

  # 本机主机名（短名/FQDN）精确等值；hostname 缺失时各行为空，逐行比较天然跳过。
  local names=""
  local name=""
  names="$(_machines_host_names)"
  while IFS= read -r name; do
    [[ -z ${name} ]] && continue
    if [[ "${name,,}" == "${lowered}" ]]; then
      printf 'yes\n'
      return 0
    fi
  done <<<"${names}"

  printf 'no\n'
  return 0
}

# _machines_host_names -> stdout: 本机主机名候选（每行一个，顺序即优先级）
#   hostname / hostname -s / hostname -f；容器等精简环境可能**没有 hostname 可执行文件**
#   （archlinux 基础镜像就没装 inetutils），那时退回 `uname -n`（内核同源，等价信号）
#   与 $HOSTNAME。全部拿不到就输出空 —— 调用方逐行比较，空行天然被跳过，不误判。
_machines_host_names() {
  local got=""
  got="$(hostname 2>/dev/null || true)"
  got+="$(printf '\n%s' "$(hostname -s 2>/dev/null || true)")"
  got+="$(printf '\n%s' "$(hostname -f 2>/dev/null || true)")"
  if [[ -z "${got//$'\n'/}" ]]; then
    got="$(uname -n 2>/dev/null || true)"
    got+="$(printf '\n%s' "${HOSTNAME:-}")"
  fi
  printf '%s\n' "${got}"
  return 0
}
# ---------------------------------------------------------------------------
# 合并视图（面板/CLI 单一权威）
# ---------------------------------------------------------------------------

# machines_view_json -> stdout: [ {id,label,target,enabled,state,local,orphan} ]
#   state（§2.2）：active=当前 active；activated=激活过但非当前；local=同机（未激活）；
#   inactive=未激活。优先级 active > activated > local > inactive。
#   历史记录里 herdr 已不存在的 machine（saved machine 被删）也会作为 orphan 条目出现，
#   否则用户无法在面板里看到 / 停用这些残留。
machines_view_json() {
  _machines_require_jq

  local doc=""
  local list=""
  local active=""
  doc="$(machines_activation_load)"
  list="$(machines_herdr_list_json)"
  active="$(printf '%s' "${doc}" | jq -r '.active // ""')"

  local -a entries=()
  local -a seen=()
  local rows=""
  rows="$(printf '%s' "${list}" | jq -c '.[] | select(type == "object")')"

  local row=""
  local id=""
  local label=""
  local target=""
  local enabled=""
  local has_rec=""
  local is_local=""
  local state=""

  while IFS= read -r row; do
    [[ -z ${row} ]] && continue
    id="$(printf '%s' "${row}" | jq -r '.id | tostring')"
    label="$(printf '%s' "${row}" | jq -r 'if (.label | type) == "string" and (.label | length) > 0 then .label else (.id | tostring) end')"
    target="$(printf '%s' "${row}" | jq -r 'if (.target | type) == "string" then .target else "" end')"
    enabled="$(printf '%s' "${row}" | jq -r 'if (.enabled | type) == "boolean" then (.enabled | tostring) else "true" end')"
    has_rec="$(printf '%s' "${doc}" | jq -r --arg id "${id}" 'if .machines[$id] == null then "no" else "yes" end')"

    # 同机判定单一权威 = machines_is_local_target；激活记录里的 local 标记可覆盖它
    is_local="$(machines_is_local_target "${target}")"
    if [[ ${has_rec} == "yes" ]]; then
      local rec_local=""
      rec_local="$(printf '%s' "${doc}" | jq -r --arg id "${id}" 'if .machines[$id].local == true then "yes" else "no" end')"
      [[ ${rec_local} == "yes" ]] && is_local="yes"
    fi

    if [[ ${active} == "${id}" ]]; then
      state="active"
    elif [[ ${has_rec} == "yes" ]]; then
      state="activated"
    elif [[ ${is_local} == "yes" ]]; then
      state="local"
    else
      state="inactive"
    fi

    seen+=("${id}")
    entries+=("$(jq -c -n \
      --arg id "${id}" --arg label "${label}" --arg target "${target}" \
      --arg enabled "${enabled}" --arg state "${state}" \
      --arg local "${is_local}" \
      '{id: $id, label: $label, target: $target, enabled: ($enabled == "true"),
        state: $state, local: ($local == "yes"), orphan: false}')")
  done <<<"${rows}"

  # orphan：激活记录里有、herdr 列表里没有的 id（saved machine 已被删除）。
  # 不显示它们，用户就没有任何入口看到 / 停用这些残留。
  local keys=""
  local orphan_id=""
  local rec=""
  local in_list=""
  keys="$(printf '%s' "${doc}" | jq -r '.machines | keys[]')"
  while IFS= read -r orphan_id; do
    [[ -z ${orphan_id} ]] && continue
    in_list="no"
    local s=""
    for s in ${seen[@]+"${seen[@]}"}; do
      [[ ${s} == "${orphan_id}" ]] && in_list="yes"
    done
    [[ ${in_list} == "yes" ]] && continue

    rec="$(printf '%s' "${doc}" | jq -c --arg id "${orphan_id}" '.machines[$id] // {}')"
    label="$(printf '%s' "${rec}" | jq -r --arg id "${orphan_id}" 'if (.label | type) == "string" and (.label | length) > 0 then .label else $id end')"
    target="$(printf '%s' "${rec}" | jq -r 'if (.ssh_target | type) == "string" then .ssh_target else "" end')"
    is_local="$(machines_is_local_target "${target}")"
    local rec_local2=""
    rec_local2="$(printf '%s' "${rec}" | jq -r 'if .local == true then "yes" else "no" end')"
    [[ ${rec_local2} == "yes" ]] && is_local="yes"
    if [[ ${active} == "${orphan_id}" ]]; then
      state="active"
    else
      state="activated"
    fi

    entries+=("$(jq -c -n \
      --arg id "${orphan_id}" --arg label "${label}" --arg target "${target}" \
      --arg state "${state}" --arg local "${is_local}" \
      '{id: $id, label: $label, target: $target, enabled: true,
        state: $state, local: ($local == "yes"), orphan: true}')")
  done <<<"${keys}"

  if [[ ${#entries[@]} -eq 0 ]]; then
    printf '[]\n'
    return 0
  fi
  printf '%s\n' "${entries[@]}" | jq -c -s '.'
}

# machines_lookup_json <id> -> stdout: {id,label,target,enabled}
#   先查 herdr 列表，查不到退回激活记录（orphan）；都查不到 -> die 3
machines_lookup_json() {
  _machines_require_jq
  local id="${1-}"
  if [[ -z ${id} ]]; then
    die 3 "machines_lookup_json 需要 <id> 参数。请检查调用方（内部错误）。"
  fi

  local list=""
  local hit=""
  list="$(machines_herdr_list_json)"
  set +o errexit
  hit="$(printf '%s' "${list}" | jq -c --arg id "${id}" 'first(.[] | select((.id | tostring) == $id)) // empty' 2>/dev/null)"
  set -o errexit
  if [[ -n ${hit} ]]; then
    printf '%s' "${hit}" | jq -c '
      {id: (.id | tostring),
       label: (if (.label | type) == "string" and (.label | length) > 0 then .label else (.id | tostring) end),
       target: (if (.target | type) == "string" then .target else "" end),
       enabled: (if (.enabled | type) == "boolean" then .enabled else true end)}
    '
    return 0
  fi

  local doc=""
  local rec=""
  doc="$(machines_activation_load)"
  set +o errexit
  rec="$(printf '%s' "${doc}" | jq -c --arg id "${id}" '.machines[$id] // empty' 2>/dev/null)"
  set -o errexit
  if [[ -n ${rec} ]]; then
    printf '%s' "${rec}" | jq -c --arg id "${id}" '
      {id: $id,
       label: (if (.label | type) == "string" and (.label | length) > 0 then .label else $id end),
       target: (if (.ssh_target | type) == "string" then .ssh_target else "" end),
       enabled: true}
    '
    return 0
  fi

  die 3 "machine '${id}' 不存在：herdr saved machines 与激活记录里都没有它。请用 'forward machines list' 查看可用 id/label。"
}

# machines_resolve_id <id|label> -> stdout: machine id
#   `machines activate/deactivate` 接受 id 或 label（用户看面板时记的是 label）。
#   匹配顺序：herdr 列表 id 精确 -> label 精确 -> label 大小写不敏感 -> 激活记录同上。
#   都匹配不到 -> die 3 + 列出可用 id（含 label）。
machines_resolve_id() {
  _machines_require_jq
  local arg="${1-}"
  if [[ -z ${arg} ]]; then
    die 3 "缺少 <id|label>。请用 'forward machines list' 查看可用 machine。"
  fi

  local list=""
  local doc=""
  list="$(machines_herdr_list_json)"
  doc="$(machines_activation_load)"

  local hit=""
  local rc=0
  set +o errexit
  hit="$(printf '%s' "${list}" | jq -r --arg a "${arg}" '
    (first(.[] | select((.id | tostring) == $a))) //
    (first(.[] | select(.label == $a))) //
    (first(.[] | select((.label | type) == "string" and (.label | ascii_downcase) == ($a | ascii_downcase)))) //
    empty | (.id | tostring)
  ' 2>/dev/null)"
  rc=$?
  set -o errexit
  if [[ ${rc} -eq 0 && -n ${hit} ]]; then
    printf '%s\n' "${hit}"
    return 0
  fi

  set +o errexit
  hit="$(printf '%s' "${doc}" | jq -r --arg a "${arg}" '
    (first(.machines | to_entries[] | select(.key == $a))) //
    (first(.machines | to_entries[] | select(.value.label == $a))) //
    (first(.machines | to_entries[] | select((.value.label | type) == "string" and (.value.label | ascii_downcase) == ($a | ascii_downcase)))) //
    empty | .key
  ' 2>/dev/null)"
  rc=$?
  set -o errexit
  if [[ ${rc} -eq 0 && -n ${hit} ]]; then
    printf '%s\n' "${hit}"
    return 0
  fi

  local available=""
  set +o errexit
  available="$(printf '%s' "${list}" | jq -r '[.[] | ((.id | tostring) + (if (.label | type) == "string" and (.label | length) > 0 then "(" + .label + ")" else "" end))] | join(", ")' 2>/dev/null)"
  set -o errexit
  if [[ -n ${available} ]]; then
    die 3 "machine '${arg}' 不存在。可用的 saved machines：${available}。请用 'forward machines list' 查看。"
  fi
  die 3 "machine '${arg}' 不存在，且 herdr 当前没有返回任何 saved machines（HERDR_BIN_PATH 未设置 / herdr 未运行？）。请用 'forward machines list' 确认。"
}

# ---------------------------------------------------------------------------
# SSH 探测桥（M1 的 lib/ssh-probe.sh）
# ---------------------------------------------------------------------------

# machines_kv_get <multi_line_text> <KEY> -> stdout: 第一个 KEY= 的值（无则空行）
#   与 M1 的 lib/ssh-probe.sh 的 kv_get 同语义；M1 已合入后委托优先（review nit：
#   消除双实现），仅在 ssh-probe 未加载时用本地副本（bin/forward 两者都 source，
#   实际路径永远是委托版）。
machines_kv_get() {
  if declare -F kv_get >/dev/null 2>&1; then
    kv_get "${1-}" "${2-}"
    return 0
  fi
  local text="${1-}"
  local key="${2-}"
  if [[ -z ${key} ]]; then
    printf '\n'
    return 0
  fi
  local line=""
  while IFS= read -r line; do
    if [[ ${line} == "${key}="* ]]; then
      printf '%s\n' "${line#"${key}="}"
      return 0
    fi
  done <<<"${text}"
  printf '\n'
  return 0
}

# machines_ssh_probe_plugin <ssh_target> -> stdout: §2.1 冻结的 KV 契约
#   HF_STATUS=present|absent|no-herdr|unreachable（+present 时的 HF_ROOT/HF_STATE_DIR/
#   HF_DEFAULT_STATE，+失败时的 HF_REASON）。
#   M1（lib/ssh-probe.sh）合入后本函数自动委托它的 ssh_probe_plugin —— 联调点：
#   M1 只需保证 §2.1 签名一致，本文件零改动。未合入时输出 unreachable 降级，
#   **绝不假装 present**（否则会写出一条指向 A 的假路径）。
machines_ssh_probe_plugin() {
  local target="${1-}"
  if declare -F ssh_probe_plugin >/dev/null 2>&1; then
    ssh_probe_plugin "${target}"
    return 0
  fi
  printf 'HF_STATUS=unreachable\n'
  printf 'HF_REASON=%s\n' "SSH 探测模块 lib/ssh-probe.sh 未安装（M1 交付；当前检出缺少该文件）"
  return 0
}
