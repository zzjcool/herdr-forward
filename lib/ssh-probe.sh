#!/usr/bin/env bash
# lib/ssh-probe.sh — 远端（herdr server / B）插件可用性探测：只读、BatchMode、有界超时。
#
# 单一实现，多处消费（消除复制粘贴）：
#   1. scripts/setup-client.sh —— 跨机一键配置：checkout 形态 source 同目录上级的 lib/；
#      curl|bash 形态按需下载本文件后 source（见该脚本 load_ssh_probe_lib）。
#   2. bin/forward machines activate —— 复用同一探测推导 B 的插件根 / state 目录（M2）。
#   3. tests/unit/test_ssh_probe.sh —— 契约单测。
#
# 契约（M1 计划 §2.1 冻结签名）：
#   ssh_probe_parse_target <target>           -> stdout "<host> <port>"；非法 die 64
#   ssh_probe_run <ssh_target> <remote_cmd>   -> stdout "HF_SSH_RC=<rc>\n<merged>"；恒 return 0
#   ssh_probe_plugin <ssh_target> [plugin_id] -> stdout KV 行（HF_STATUS / HF_ROOT / HF_STATE_DIR /
#                                                HF_DEFAULT_STATE / HF_REASON）
#   kv_get <多行文本> <KEY>                   -> stdout 第一个 KEY= 的值（无则空）
#
# 依赖说明（**有意不 source lib/common.sh**）：
#   * curl|bash 形态下本文件是单独下载的（临时目录里没有 common.sh），source 会失败；
#   * scripts/setup-client.sh 自带 die（消息格式 `setup-client.sh: error: ...`），若本库把
#     common.sh 的 die 引进来，跨机配置的报错格式会被换掉。
#   故：宿主已提供 die（bin/forward 经 common.sh / setup-client.sh 自带）时**直接复用**，
#   错误格式与调用方一致；都没有时才启用下面 3 行兜底 —— 它不是 common.sh 的副本
#   （没有 log / 轮转 / 原子写），只保证「退出码 + 消息 + 退出」语义一致。
#
# 只读保证：只跑 `herdr plugin list` 与远端路径推导（读 plugins.json / 目录 glob），
# 绝不执行 `herdr plugin install` 等写动作；ssh 一律 `-n -o BatchMode=yes`（非交互、不吃 stdin）。
set -o errexit -o nounset -o pipefail

# shellcheck disable=SC2317 # 宿主（common.sh / setup-client.sh）已提供 die 时不执行；仅独立使用兜底
if ! declare -F die >/dev/null 2>&1; then
  die() {
    local code="${1:-1}"
    shift || true
    printf 'ssh-probe: error: %s\n' "$*" >&2
    exit "${code}"
  }
fi

# --- 探测参数（幂等：调用方已设定则不覆盖，便于调用方拥有超时策略） ---
# scripts/setup-client.sh 先 `readonly SSH_PROBE_TIMEOUT=15` 再 source 本库，其值优先。
if [[ -z ${SSH_PROBE_TIMEOUT:-} ]]; then
  readonly SSH_PROBE_TIMEOUT=15
fi
if [[ -z ${SSH_CONNECT_TIMEOUT:-} ]]; then
  readonly SSH_CONNECT_TIMEOUT=8
fi

# kv_get <多行文本> <KEY> -> 第一个 KEY= 的值（无则空）。随库导出（setup-client.sh 也用）。
kv_get() {
  printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -1 || true
}
# --- ssh_probe_parse_target <target> -> stdout "<host> <port>"（非法 die 64） ---
# 支持形态（README / --help 承诺的 user@host[:port] 是主路径；方括号仅用于 IPv6）：
#   host | user@host               -> host 原样 + 默认端口 22
#   user@host:2222                 -> user@host 2222（用整串展开，故 user@ 不会丢）
#   [v6]:22 / [::1]                -> 去掉方括号 + 22（IPv6 字面量端口无法用 ':' 切分，故需括号）
#   含 2 个及以上 ':' 且无括号       -> 视作裸 IPv6 主机，端口 22
#   空 / 端口非数字 / 括号不配对      -> die 64（用法错）
# 内部派生 _SSH_PROBE_HOST / _SSH_PROBE_PORT / _SSH_PROBE_HAS_PORT（供 ssh_probe_run 用）。
_SSH_PROBE_HOST=""
_SSH_PROBE_PORT=""
_SSH_PROBE_HAS_PORT=0

# _ssh_probe_split_target <target>：只解析不输出（失败即 die 64），副作用是上面 3 个内部变量。
_ssh_probe_split_target() {
  local target="${1:-}"
  _SSH_PROBE_HOST=""
  _SSH_PROBE_PORT=""
  _SSH_PROBE_HAS_PORT=0
  if [[ -z "${target}" ]]; then
    die 64 "ssh target 为空（期望 user@host[:port]）"
  fi
  if [[ "${target}" == \[* ]]; then
    # 方括号形态：必须是 [主机] 或 [主机]:端口，且不允许嵌套方括号。
    if [[ "${target}" != *\]* ]]; then
      die 64 "ssh target 方括号未闭合: '${target}'（期望 [ipv6]:port）"
    fi
    local bracketed="${target%%\]*}"
    local rest="${target#"${bracketed}"}"
    _SSH_PROBE_HOST="${bracketed#\[}"
    rest="${rest#\]}"
    if [[ -z "${_SSH_PROBE_HOST}" ]]; then
      die 64 "ssh target 缺少主机名: '${target}'"
    fi
    if [[ -n "${rest}" ]]; then
      if [[ "${rest}" != :* || -z "${rest#:}" ]]; then
        die 64 "ssh target 方括号后只能接 :端口: '${target}'"
      fi
      _SSH_PROBE_PORT="${rest#:}"
      _SSH_PROBE_HAS_PORT=1
    fi
  elif [[ "${target}" == *:*:* ]]; then
    # 多个 ':' 且无括号：裸 IPv6 字面量（无法从中可靠切出端口），整体当主机。
    _SSH_PROBE_HOST="${target}"
  elif [[ "${target}" == *:* ]]; then
    _SSH_PROBE_HOST="${target%%:*}"
    _SSH_PROBE_PORT="${target#*:}"
    _SSH_PROBE_HAS_PORT=1
  else
    _SSH_PROBE_HOST="${target}"
  fi
  if [[ -z "${_SSH_PROBE_HOST}" ]]; then
    die 64 "ssh target 缺少主机名: '${target}'"
  fi
  if ((_SSH_PROBE_HAS_PORT == 1)); then
    if [[ ! "${_SSH_PROBE_PORT}" =~ ^[0-9]+$ ]]; then
      die 64 "ssh target 端口非法: '${_SSH_PROBE_PORT}'（期望 user@host[:port]）"
    fi
  else
    _SSH_PROBE_PORT=22
  fi
}

ssh_probe_parse_target() {
  _ssh_probe_split_target "${1:-}"
  printf '%s %s\n' "${_SSH_PROBE_HOST}" "${_SSH_PROBE_PORT}"
}

# --- ssh_probe_run <ssh_target> <remote_cmd> -> stdout "HF_SSH_RC=<rc>\n<merged stdout+stderr>" ---
# 恒 return 0（探测失败由调用方按 HF_SSH_RC 判状态，绝不因连不上而中断安装/面板）。
# argv 形状：`[timeout 15] ssh -n -o BatchMode=yes -o ConnectTimeout=8 [-p PORT] HOST REMOTE_CMD`
#   * -n 必需：`curl … | bash -s` 形态下 stdin 是**脚本本体**，ssh 读走它就等于吃掉剩余脚本；
#   * -p 只在 target 显式带端口时传（裸 host 时交给 ssh_config 的 Port/默认 22，行为不变）；
#   * timeout 缺失时靠 ConnectTimeout=8 兜住建连阶段（不静默降级，行为仍可预期）。
ssh_probe_run() {
  local target="${1:-}"
  local remote="${2:-}"
  _ssh_probe_split_target "${target}"
  # shellcheck disable=SC2034 # 仅作「计时器是否可用」标志：为空则不加 timeout 前缀（仅 ConnectTimeout 兜底）
  local SSH_TIMER_BIN=""
  if command -v timeout >/dev/null 2>&1; then
    SSH_TIMER_BIN="timeout"
  fi
  local rc=0
  local merged=""
  local -a cmd=()
  if [[ -n "${SSH_TIMER_BIN}" ]]; then
    cmd+=("${SSH_TIMER_BIN}" "${SSH_PROBE_TIMEOUT}")
  fi
  cmd+=(ssh -n -o BatchMode=yes -o "ConnectTimeout=${SSH_CONNECT_TIMEOUT}")
  if ((_SSH_PROBE_HAS_PORT == 1)); then
    cmd+=(-p "${_SSH_PROBE_PORT}")
  fi
  cmd+=("${_SSH_PROBE_HOST}" "${remote}")
  merged="$("${cmd[@]}" 2>&1)" || rc=$?
  printf 'HF_SSH_RC=%d\n%s\n' "${rc}" "${merged}"
  return 0
}

# --- 远端命令（原样搬运自 setup-client.sh，错误信息与探测语义逐字不变） ---
# shellcheck disable=SC2016 # 单引号是有意的：$HOME/$PATH 必须由 **远端** shell 展开
if [[ -z ${REMOTE_LIST_CMD:-} ]]; then
  readonly REMOTE_LIST_CMD='if command -v herdr >/dev/null 2>&1; then herdr plugin list; else PATH="$HOME/.local/bin:$PATH" herdr plugin list 2>/dev/null || echo HF_NO_HERDR; fi'
fi

# 远端路径探测：plugins.json 的 plugin_root → 退回 plugins/github/*forward* glob →
# state 目录按远端 HOME/XDG 推导（HF_STATE_DIR=已存在 / HF_DEFAULT_STATE=默认位置）。
# 注意：这里是**单引号本地字符串**（整体作为一个 ssh 实参），内部一律不用 '。
# 文本里的 __HF_PLUGIN_ID__ / __HF_PLUGIN_ID_ENC__ 由 ssh_probe_plugin 代入（远端文本里本来
# 就有 %s 与 \"，故不能整段当 printf 模板用）。
# shellcheck disable=SC2016 # 同上：整段是远端脚本，变量必须留给远端展开
if [[ -z ${REMOTE_PATHS_CMD:-} ]]; then
  readonly REMOTE_PATHS_CMD='
cfg="${XDG_CONFIG_HOME:-$HOME/.config}/herdr"
root=""
if [ -f "$cfg/plugins.json" ] && command -v python3 >/dev/null 2>&1; then
  root=$(python3 -c "import json,sys
try:
    d=json.load(open(sys.argv[1], encoding=\"utf-8\"))
except Exception:
    raise SystemExit(0)
for e in (d if isinstance(d, list) else []):
    if isinstance(e, dict) and e.get(\"plugin_id\") == sys.argv[2]:
        print(e.get(\"plugin_root\", \"\"))
        break" "$cfg/plugins.json" __HF_PLUGIN_ID__ 2>/dev/null) || root=""
fi
if [ -z "$root" ]; then
  for d in "$cfg"/plugins/github/*forward*; do
    if [ -d "$d" ]; then root="$d"; fi
  done
fi
if [ -n "$root" ]; then printf "HF_ROOT=%s\n" "$root"; fi
enc="__HF_PLUGIN_ID_ENC__"
if [ -n "$root" ] && [ -f "$root/herdr-plugin.toml" ]; then
  id=$(sed -n "s/^[[:space:]]*id[[:space:]]*=[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$root/herdr-plugin.toml" | head -1)
  if [ -n "$id" ]; then enc=$(printf "%s" "$id" | sed "s/:/%3A/g"); fi
fi
state="${XDG_STATE_HOME:-$HOME/.local/state}/herdr/plugins/$enc"
if [ -d "$state" ]; then printf "HF_STATE_DIR=%s\n" "$state"; else printf "HF_DEFAULT_STATE=%s\n" "$state"; fi
'
fi

# --- ssh_probe_plugin <ssh_target> [plugin_id=zzjcool:forward] -> stdout KV 行 ---
# HF_STATUS=present|absent|no-herdr|unreachable
#   present      -> HF_ROOT=<B 插件根>（读不到则该行缺席）+ HF_STATE_DIR（已存在）/ HF_DEFAULT_STATE
#   no-herdr     -> HF_REASON=<远端找不到 herdr>
#   unreachable  -> HF_REASON=<首 3 行错误摘要（合并 stdout+stderr）>
# 调用次数与 setup-client.sh 现状一致：absent / no-herdr / unreachable = 1 次 ssh，present = 2 次。
# 远端命令以单引号字符串整体作为一个 ssh 实参（内部变量留给远端展开）。
ssh_probe_plugin() {
  local target="${1:-}"
  local plugin_id="${2:-zzjcool:forward}"
  local plugin_id_enc="${plugin_id//:/%3A}"
  local paths_cmd="${REMOTE_PATHS_CMD//__HF_PLUGIN_ID_ENC__/${plugin_id_enc}}"
  paths_cmd="${paths_cmd//__HF_PLUGIN_ID__/${plugin_id}}"

  local raw=""
  local rc=""
  local body=""
  raw="$(ssh_probe_run "${target}" "${REMOTE_LIST_CMD}")"
  rc="$(kv_get "${raw}" HF_SSH_RC)"
  # 第 1 行是 HF_SSH_RC，其余是远端 stdout+stderr 合并。
  body="$(printf '%s\n' "${raw}" | sed '1d')"

  if [[ "${rc:-1}" != "0" ]]; then
    local reason=""
    reason="$(printf '%s' "${body}" | head -3 | tr '\n' ' ' || true)"
    printf 'HF_STATUS=unreachable\n'
    printf 'HF_REASON=%s\n' "${reason}"
    return 0
  fi
  if [[ "${body}" == *HF_NO_HERDR* ]]; then
    printf 'HF_STATUS=no-herdr\n'
    printf 'HF_REASON=远端非交互 shell 里找不到 herdr（PATH 未含 ~/.local/bin？）\n'
    return 0
  fi
  if ! printf '%s' "${body}" | grep -qF "${plugin_id}"; then
    printf 'HF_STATUS=absent\n'
    return 0
  fi

  printf 'HF_STATUS=present\n'
  local paths_raw=""
  local path_root=""
  local path_state=""
  paths_raw="$(ssh_probe_run "${target}" "${paths_cmd}")"
  path_root="$(kv_get "${paths_raw}" HF_ROOT)"
  path_state="$(kv_get "${paths_raw}" HF_STATE_DIR)"
  if [[ -n "${path_root}" ]]; then
    printf 'HF_ROOT=%s\n' "${path_root}"
  fi
  if [[ -n "${path_state}" ]]; then
    printf 'HF_STATE_DIR=%s\n' "${path_state}"
  else
    local path_default=""
    path_default="$(kv_get "${paths_raw}" HF_DEFAULT_STATE)"
    if [[ -n "${path_default}" ]]; then
      printf 'HF_DEFAULT_STATE=%s\n' "${path_default}"
    fi
  fi
  return 0
}
