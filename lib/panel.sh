#!/usr/bin/env bash
# lib/panel.sh — Port Forward 交互面板（纯 bash，无 TUI 依赖）
#
# 归属：M3（计划 §2.4 冻结契约）。唯一 writer：M3。
#
# 设计要点（计划 §2.4 / §5 风险 1）：
#   * 纯 bash + jq + coreutils；不引入任何 TUI 框架（Non-goal）。
#   * 「双缓冲」= 单次 printf 渲染整屏，刷新前 `tput cup 0 0` + `tput ed`
#     （无 tput 时退 ANSI `\e[H\e[2J`），避免逐行重绘的撕裂/闪烁。
#   * 刷新间隔 PANEL_REFRESH_S（默认 3s）由 `read -n 1 -t` 的超时承担：
#     超时 = 自动刷新，按键 = 立即处理，EOF = 干净退出。
#   * machines 数据经 M2 冻结签名 `machines_view_json`（stdout: 数组，字段
#     id/label/target/enabled/state）。该函数缺失时（M2 未合入 / 面板被单独
#     source）降级为直接读 $HERDR_PLUGIN_STATE_DIR/activated-machines.json。
#   * **面板只是 CLI 的包装**：激活/停用一律 fork `forward machines activate|deactivate
#     <id>`（_panel_probe）。CLI 直调路径永远可用 —— 面板 UX 出问题时可绕开
#     （§5 风险 1 的回滚点）。
#   * 非 TTY（stdin 非终端）时 panel_main 直接返回 1，由 cmd_watch 退化为旧
#     `watch -n 3 forward list`，保证既有 E2E / 脚本化调用零回归。
#
# 依赖：lib/common.sh（log / state_dir）、lib/state.sh（forward_list_json）、jq。
# 测试缝（I/O 边界，单测可覆盖）：panel_is_tty / panel_render / panel_confirm /
#   panel_machines_json / _panel_probe / _panel_clear。
set -o errexit -o nounset -o pipefail

# common.sh bridge（N3 契约：lib/*.sh 一律 source 同目录的真 common.sh，不自带回退副本）。
# bin/forward 已把 common.sh 作为硬依赖先载入；单测 harness 也先 source 它。
_PANEL_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh disable=SC1091
source "${_PANEL_LIB_DIR}/common.sh"

# 面板自动刷新间隔（秒）；测试用 PANEL_REFRESH_S 缩短
if [[ -z ${PANEL_REFRESH_S:-} ]]; then
  readonly PANEL_REFRESH_S=3
fi

# ANSI：置灰「非当前」行（terminal 不支持时只是多几个不可见字节，无副作用）
readonly PANEL_DIM=$'\033[2m'
readonly PANEL_RESET=$'\033[0m'

# --- 内部小工具 -------------------------------------------------------------

# _panel_warn <msg...>：面板告警（走 common.sh 的 log，与 CLI 同一份日志）
_panel_warn() { log warn "$@"; }

# _panel_note <msg...>：面板正文（stdout；stderr 留给日志/错误）
_panel_note() { printf '%s\n' "$*"; }

# _panel_hint <msg...>：非正文提示（stderr，不污染渲染/机器可读契约）
_panel_hint() { printf 'panel: %s\n' "$*" >&2; }

# panel_is_tty：stdout "yes" 表示 stdin 是可交互终端（测试可覆盖此缝）
panel_is_tty() {
  if [[ -t 0 ]]; then
    printf 'yes\n'
  fi
  return 0
}

# _panel_clear：把光标移回左上并清到屏幕末尾（整屏重绘 = 双缓冲的「翻页」）。
# 只在 stdout 是终端时输出控制序列：管道/文件（测试、日志）拿到的仍是纯文本。
_panel_clear() {
  [[ -t 1 ]] || return 0
  if command -v tput >/dev/null 2>&1; then
    tput cup 0 0 2>/dev/null || true
    tput ed 2>/dev/null || true
  else
    printf '\033[H\033[2J'
  fi
  return 0
}

# _panel_is_array <text> -> stdout "yes"（是 JSON 数组）
# 输出式而非退出码式（与 bin/forward 的 _hf_has_func 同构）：避免 set -e 在 if 条件里被禁用。
_panel_is_array() {
  local text="${1-}"
  [[ -n "${text}" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  local kind=""
  kind="$(printf '%s' "${text}" | jq -r 'type' 2>/dev/null || true)"
  if [[ "${kind}" == "array" ]]; then
    printf 'yes\n'
  fi
  return 0
}

# _panel_view_from_state_file：M2 模块缺失时的降级视图（同一 schema）。
# 只报「已激活」记录：active → state=active，其余 → state=activated（无 inactive 概念）。
_panel_view_from_state_file() {
  local file=""
  file="$(state_dir)/activated-machines.json"
  if [[ ! -f "${file}" ]] || ! command -v jq >/dev/null 2>&1; then
    printf '[]\n'
    return 0
  fi
  local view=""
  view="$(jq -c '
    (.active // null) as $a
    | ((.machines // {}) | to_entries | map({
        id: .key,
        label: (.value.label // .key),
        target: (.value.ssh_target // ""),
        enabled: true,
        state: (if .key == $a then "active" else "activated" end)
      }))
  ' "${file}" 2>/dev/null || true)"
  [[ -n "${view}" ]] || view='[]'
  printf '%s\n' "${view}"
  return 0
}

# _panel_machines_module <path> -> stdout "yes"（可安全加载）
# 先在**子进程**里试加载一次：M2 的 lib/machines.sh 会 source lib/ssh-probe.sh 等依赖，
# 若依赖缺失它会 die（= 直接 exit）。子进程里 die 只杀掉探测，面板仍能降级到
# activated-machines.json —— 「面板必须能开」优先于「machines 列表完整」（plan §1 降级）。
_panel_machines_module_loadable() {
  local path="${1-}"
  [[ -f "${path}" ]] || return 0
  local probe=""
  # 探测失败是**预期分支**（坏模块），故整段用 set +e 包住；
  # 不返回非零（空输出 = 不可加载），避免 errexit 把面板一并带下去。
  set +o errexit
  probe="$(bash -c 'source "$1" >/dev/null 2>&1' _ "${path}" 2>/dev/null && printf 'yes')"
  set -o errexit
  if [[ "${probe}" == "yes" ]]; then
    printf 'yes\n'
  fi
  return 0
}

# _panel_try_load_machines：尽力把 M2 的 lib/machines.sh 载进本进程（只做一次）。
# 为什么需要它：M2 会在 bin/forward 里 source 自己的模块，但**面板也可能被单独 source**
# （单测 harness / 未来其他入口），而 machines_view_json 是列表数据的权威来源。
# 加载失败只是退回文件降级路径，绝不让面板开不起来。
panel_render_machines_loaded=""
_panel_try_load_machines() {
  [[ -n "${panel_render_machines_loaded}" ]] && return 0
  panel_render_machines_loaded="done"
  declare -F machines_view_json >/dev/null 2>&1 && return 0
  local path="${_PANEL_LIB_DIR}/machines.sh"
  local ok=""
  ok="$(_panel_machines_module_loadable "${path}")"
  [[ "${ok}" == "yes" ]] || return 0
  set +o errexit
  # shellcheck source=/dev/null
  source "${path}" >/dev/null 2>&1
  set -o errexit
  if ! declare -F machines_view_json >/dev/null 2>&1; then
    _panel_warn "lib/machines.sh 已加载但未提供 machines_view_json；面板退回读 activated-machines.json。"
  fi
  return 0
}

# panel_machines_json -> stdout: 合并视图数组（面板的唯一数据入口）
#   优先 M2 的 machines_view_json（冻结签名）；不可用/返回非数组时降级读状态文件。
panel_machines_json() {
  _panel_try_load_machines
  local view="" is_array=""
  if declare -F machines_view_json >/dev/null 2>&1; then
    view="$(machines_view_json 2>/dev/null || true)"
    is_array="$(_panel_is_array "${view}")"
    if [[ "${is_array}" == "yes" ]]; then
      printf '%s\n' "${view}"
      return 0
    fi
    _panel_warn "machines_view_json 未返回数组，面板降级为读 activated-machines.json。"
  fi
  _panel_view_from_state_file
  return 0
}

# _panel_field <json> <index:1-based> <field> -> stdout 值（无则空）
_panel_field() {
  local json="${1-}"
  local n="${2-1}"
  local field="${3-}"
  printf '%s' "${json}" | jq -r --argjson n "${n}" --arg f "${field}" \
    '.[$n - 1][$f] // empty' 2>/dev/null || true
}

# _panel_count_json <json> -> stdout 数组长度（非数组 / 坏输入 -> 0）
_panel_count_json() {
  local json="${1-}"
  local n=""
  n="$(printf '%s' "${json}" | jq -r 'if type == "array" then length else 0 end' 2>/dev/null || true)"
  [[ "${n}" =~ ^[0-9]+$ ]] || n=0
  printf '%s\n' "${n}"
}

# --- 渲染 -------------------------------------------------------------------

# _panel_render_forwards：上半屏（forward 映射表格）
_panel_render_forwards() {
  if ! declare -F forward_list_json >/dev/null 2>&1; then
    _panel_note "FORWARDS"
    _panel_note "  （状态层不可用：缺少 lib/state.sh；在插件根下运行即可）"
    return 0
  fi

  local json=""
  json="$(forward_list_json 2>/dev/null || true)"
  [[ -n "${json}" ]] || json='[]'

  local count=""
  count="$(_panel_count_json "${json}")"
  _panel_note "FORWARDS (${count})"
  if ((count == 0)); then
    _panel_note "  （无映射）终端里运行 forward add 3000:3000 --machine <label> 添加。"
    return 0
  fi

  printf '  %-6s %-22s %-9s %-7s\n' "LOCAL" "REMOTE" "STATUS" "PID"
  while IFS=$'\t' read -r lp rp st pid; do
    [[ -z "${lp}" ]] && continue
    printf '  %-6s %-22s %-9s %-7s\n' "${lp}" "${rp}" "${st}" "${pid}"
  done < <(printf '%s' "${json}" | jq -r '
    .[] | [ (.local_port | tostring),
            ((.remote_host // "127.0.0.1") + ":" + (.remote_port | tostring)),
            (.status // "-"),
            (if .pid == null then "-" else (.pid | tostring) end) ] | @tsv
  ' 2>/dev/null || true)
  return 0
}

# panel_render：整屏文本（forwards 表 + machines 列表 + 按键帮助）。
# machines 段在三态下的行格式（§2.4 冻结）：
#   [✓] N. label   target   （当前活动 · tab bar 指向该机）
#   [·] N. label   target   （已激活, 非当前）        ← 整行置灰
#   [ ] N. label   target   （未激活 · 按 N 激活）    ← 整行置灰
# 视图为空（B 视角 / 未配 machines）时整段省略 —— 面板退化为纯 forwards，兼容现状。
panel_render() {
  local json=""
  json="$(panel_machines_json)"
  local total=""
  total="$(_panel_count_json "${json}")"

  _panel_note "herdr-forward · Port Forward   刷新 ${PANEL_REFRESH_S}s · r 立即刷新 · x 退出"
  printf '%s\n' "──────────────────────────────────────────────────────────────"
  _panel_render_forwards

  if ((total > 0)); then
    printf '%s\n' "──────────────────────────────────────────────────────────────"
    printf 'MACHINES (%s)  数字键 = 激活 / 停用\n' "${total}"
    local i=1 id="" label="" target="" state="" mark="" desc="" row=""
    for ((i = 1; i <= total; i++)); do
      id="$(_panel_field "${json}" "${i}" id)"
      [[ -n "${id}" ]] || continue
      label="$(_panel_field "${json}" "${i}" label)"
      [[ -n "${label}" ]] || label="${id}"
      target="$(_panel_field "${json}" "${i}" target)"
      [[ -n "${target}" ]] || target="-"
      state="$(_panel_field "${json}" "${i}" state)"
      case "${state}" in
      active)
        mark="[✓]"
        desc="（当前活动 · tab bar 指向该机）"
        row="$(printf '  %s %s. %-16s %-20s %s' "${mark}" "${i}" "${label}" "${target}" "${desc}")"
        ;;
      local)
        mark="[✓]"
        desc="（本机 · 无需远程探测）"
        row="$(printf '  %s %s. %-16s %-20s %s' "${mark}" "${i}" "${label}" "${target}" "${desc}")"
        ;;
      activated)
        mark="[·]"
        desc="（已激活, 非当前 · 按 ${i} 切回）"
        row="$(printf '  %s %s. %-16s %-20s %s' "${mark}" "${i}" "${label}" "${target}" "${desc}")"
        row="${PANEL_DIM}${row}${PANEL_RESET}"
        ;;
      *)
        mark="[ ]"
        desc="（未激活 · 按 ${i} 探测并激活）"
        row="$(printf '  %s %s. %-16s %-20s %s' "${mark}" "${i}" "${label}" "${target}" "${desc}")"
        row="${PANEL_DIM}${row}${PANEL_RESET}"
        ;;
      esac
      _panel_note "${row}"
    done
  fi

  printf '%s\n' "──────────────────────────────────────────────────────────────"
  printf '按键: 1-9 选择机器（激活前会确认） · r 刷新 · a 添加转发用法 · x 退出\n'
  return 0
}

# --- 交互 -------------------------------------------------------------------

# panel_handle_key <key> -> stdout: none|refresh|quit|activating:<id>|deactivating:<id>
#   恒 return 0 且只打印一行：调用方（panel_main）据此分派。
panel_handle_key() {
  local key="${1-}"
  case "${key}" in
  r | R)
    printf 'refresh\n'
    return 0
    ;;
  x | X | q | Q)
    printf 'quit\n'
    return 0
    ;;
  a | A)
    _panel_hint "添加转发：终端里运行 'forward add <local>:<remote> [--machine LABEL] [--ssh-target user@host:22]'（一期不在面板内嵌表单）。"
    printf 'none\n'
    return 0
    ;;
  *) : ;; # 其余：交给下面的数字分派 / none 兑底
  esac

  if [[ "${key}" =~ ^[1-9]$ ]]; then
    local json="" id="" state=""
    json="$(panel_machines_json)"
    id="$(_panel_field "${json}" "${key}" id)"
    if [[ -n "${id}" ]]; then
      state="$(_panel_field "${json}" "${key}" state)"
      # 'local' = 同机短路的激活（plan §1：短路时记录里它就置为 active），
      # 所以它和 'active' 一样是「当前活动」→ 数字键的含义是停用而不是再激活。
      if [[ "${state}" == "active" || "${state}" == "local" ]]; then
        printf 'deactivating:%s\n' "${id}"
      else
        printf 'activating:%s\n' "${id}"
      fi
      return 0
    fi
  fi

  printf 'none\n'
  return 0
}

# panel_confirm <prompt> -> stdout yes|no（提示词写 stderr）
#   宽容解析：y|Y|yes|YES（含前后空白）→ yes；其余（含 EOF / 空输入）→ no。
#   安全默认是 no：面板误触、stdin 被重定向时都不会意外发起 SSH 探测。
#
#   读取方式按输入源分流（真实 pty 冒烟发现的 UX 坑）：
#     * 交互终端：单键确认（读 1 个字符），不必再敲回车；
#     * 管道/重定向（测试、脚本）：读整行，保留 ' yes ' 这类宽容解析与 EOF=no 语义。
panel_confirm() {
  local prompt="${1-}"
  printf '%s ' "${prompt}" >&2

  local ans=""
  set +o errexit
  if [[ -t 0 ]]; then
    IFS= read -r -n 1 ans
    printf '\n' >&2 # 终端里单键不回显换行，补一个免得后续输出接在提示后
  else
    IFS= read -r ans
  fi
  set -o errexit

  # 去前后空白（bash 内建，无 fork）
  ans="${ans#"${ans%%[![:space:]]*}"}"
  ans="${ans%"${ans##*[![:space:]]}"}"
  ans="${ans,,}"

  if [[ "${ans}" == "y" || "${ans}" == "yes" ]]; then
    printf 'yes\n'
  else
    printf 'no\n'
  fi
  return 0
}

# _panel_probe <activate|deactivate> <machine-id>：**唯一的执行入口**。
# 只 fork CLI 子命令（`forward machines <action> <id>`），面板本身不含任何特权逻辑 ——
# 面板 UX 失效时用户随时可以手敲同一条命令（§5 风险 1 的回滚点）。
# 恒 return 0：探测失败只提示，不让面板循环崩掉（用户要能继续操作）。
_panel_probe() {
  local action="${1-}"
  local id="${2-}"
  local bin=""
  if [[ -n "${FORWARD_ROOT:-}" && -x "${FORWARD_ROOT}/bin/forward" ]]; then
    bin="${FORWARD_ROOT}/bin/forward"
  else
    bin="$(command -v forward 2>/dev/null || true)"
  fi

  if [[ -z "${bin}" ]]; then
    _panel_note "  ⚠ 找不到 forward 可执行文件：请手动运行 forward machines ${action} ${id}"
    return 0
  fi

  local rc=0
  set +o errexit
  "${bin}" machines "${action}" "${id}"
  rc=$?
  set -o errexit
  if [[ "${rc}" -ne 0 ]]; then
    _panel_note "  ⚠ 命令失败（rc=${rc}）。可直接重试：forward machines ${action} ${id}"
  fi
  return 0
}

# _panel_label_of <view-json> <id> -> stdout label（无则回退 id）
_panel_label_of() {
  local json="${1-}"
  local id="${2-}"
  local label=""
  label="$(printf '%s' "${json}" | jq -r --arg id "${id}" \
    '[.[] | select(.id == $id)][0].label // empty' 2>/dev/null || true)"
  if [[ -n "${label}" ]]; then
    printf '%s\n' "${label}"
  else
    printf '%s\n' "${id}"
  fi
  return 0
}

# _panel_act <activating|deactivating> <id>：确认 → 占位行（先 render 再跑）→ 子进程
_panel_act() {
  local action="${1-}"
  local id="${2-}"
  local json="" label="" ans=""
  json="$(panel_machines_json)"
  label="$(_panel_label_of "${json}" "${id}")"

  if [[ "${action}" == "activating" ]]; then
    ans="$(panel_confirm "将通过 SSH 只读探测 ${label}，约 15 秒，继续? [y/N]")"
    if [[ "${ans}" != "yes" ]]; then
      _panel_note "  （已取消，未发起任何连接）"
      return 0
    fi
    # 占位行先落屏，再跑子进程：SSH 探测最长 ~15s，期间面板不能是黑屏/无反馈。
    _panel_note "  ⏳ 探测中…（只读 SSH，最长约 15 秒）"
    _panel_probe activate "${id}"
  else
    ans="$(panel_confirm "停用 ${label}（tab bar 恢复本机路径），继续? [y/N]")"
    if [[ "${ans}" != "yes" ]]; then
      _panel_note "  （已取消）"
      return 0
    fi
    _panel_note "  ⏳ 停用中…"
    _panel_probe deactivate "${id}"
  fi
  return 0
}

# panel_main：主循环（cmd_watch 在 TTY 下委托给它）。
#   非 TTY -> return 1，让 cmd_watch 退化为旧 `watch`（脚本化调用 / E2E 零回归）。
panel_main() {
  local tty=""
  tty="$(panel_is_tty)"
  if [[ "${tty}" != "yes" ]]; then
    return 1
  fi

  local refresh="${PANEL_REFRESH_S:-3}"
  local key="" rrc=0 action=""

  while true; do
    _panel_clear
    panel_render

    key=""
    rrc=0
    set +o errexit
    IFS= read -r -n 1 -t "${refresh}" key
    rrc=$?
    set -o errexit

    if [[ "${rrc}" -gt 128 ]]; then
      continue # 超时 = 自动刷新（forward 状态可能是别的 pane 改的）
    fi
    if [[ "${rrc}" -ne 0 || -z "${key}" ]]; then
      return 0 # EOF（终端消失 / 输入被关闭）：干净退出，不留垃圾
    fi

    action="$(panel_handle_key "${key}")"
    case "${action}" in
    quit)
      return 0
      ;;
    refresh)
      continue
      ;;
    activating:* | deactivating:*)
      _panel_act "${action%%:*}" "${action#*:}"
      ;;
    *)
      : # none：未知键静默忽略，下一轮重绘（不提示噪音）
      ;;
    esac
  done
}
