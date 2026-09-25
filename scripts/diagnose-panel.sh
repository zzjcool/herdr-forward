#!/usr/bin/env bash
# scripts/diagnose-panel.sh — 「面板看不到 saved machines」现场诊断（只读，不改任何东西）
#
# 使用场景（A 机器实测痛点）：
#   在 herdr 里 `prefix+f` 打开 Port Forward 面板，下半屏 MACHINES 是空的（或整段不显示），
#   但你在终端里手敲 `forward machines list` 却能列出来。这种「pane 环境 != 直接终端」的差异
#   只能靠现场证据定位 —— 本脚本把面板真正依赖的每一条输入逐一打印出来，一次跑完就能看出
#   是哪一层断了。
#
# 只读保证：
#   * 不写 config.toml / 不建/改激活记录 / 不发任何 SSH 连接（machine list 是本机 herdr CLI 调用）
#   * 唯一可能的写入是插件自己的日志（machines 数据层降级时会 log warn）——那正是排查需要的信息
#
# 用法：
#   bash scripts/diagnose-panel.sh            # 人可读报告
#   bash scripts/diagnose-panel.sh --json     # 只输出机器可读的 JSON 结论（供 issue 粘贴）
#
# 退出码：0 恒（诊断工具本身不因环境问题失败；结论写在报告里）
set -Eeuo pipefail

JSON_MODE=0
for arg in "$@"; do
  case "${arg}" in
  --json) JSON_MODE=1 ;;
  -h | --help)
    printf 'usage: %s [--json]\n' "${0##*/}"
    printf '  --json  只输出机器可读结论（默认输出人可读报告）\n'
    exit 0
    ;;
  *)
    printf 'error: 未知参数：%s（用法：%s [--json]）\n' "${arg}" "${0##*/}" >&2
    exit 64
    ;;
  esac
done

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SELF_DIR}/.." && pwd)"
LIB_DIR="${PLUGIN_ROOT}/lib"

# ---------------------------------------------------------------------------
# 采集（全部只读；每个探针都自己吞掉失败，rc 单独记录）
# ---------------------------------------------------------------------------
NOW_UTC="$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || true)"

HERDR_BIN="${HERDR_BIN_PATH:-}"
HERDR_BIN_EXEC="no"
if [[ -n "${HERDR_BIN}" ]] && { [[ -x "${HERDR_BIN}" ]] || command -v "${HERDR_BIN}" >/dev/null 2>&1; }; then
  HERDR_BIN_EXEC="yes"
fi

HERDR_ON_PATH="$(command -v herdr 2>/dev/null || true)"

HERDR_VERSION=""
if [[ "${HERDR_BIN_EXEC}" == "yes" ]]; then
  HERDR_VERSION="$(timeout 10 "${HERDR_BIN}" --version 2>&1 || true)"
elif [[ -n "${HERDR_ON_PATH}" ]]; then
  HERDR_VERSION="$(timeout 10 "${HERDR_ON_PATH}" --version 2>&1 || true)"
fi

# pane 环境信号：在 herdr pane 里这些会被 herdr 注入；直接终端里通常只有 LANG 之类
PANE_ID="${HERDR_PANE_ID:-}"
SOCKET_PATH="${HERDR_SOCKET_PATH:-}"
TAB_ID="${HERDR_TAB_ID:-}"
WORKSPACE_ID="${HERDR_WORKSPACE_ID:-}"

STATE_DIR="${HERDR_PLUGIN_STATE_DIR:-${HOME:-/tmp}/.local/state/herdr-forward}"
CONFIG_DIR="${HERDR_PLUGIN_CONFIG_DIR:-${HOME:-/tmp}/.config/herdr-forward}"
LOG_FILE="${STATE_DIR}/logs/forward.log"
ACT_FILE="${STATE_DIR}/activated-machines.json"

# plugins.json（herdr 侧登记的插件根 / state 目录；面板读的是它运行处的插件）
HERDR_CFG="${HERDR_CONFIG_PATH:-${XDG_CONFIG_HOME:-${HOME:-/tmp}/.config}/herdr/config.toml}"
PLUGINS_JSON="$(dirname "${HERDR_CFG}")/plugins.json"

MACHINE_JSON=""
MACHINE_RC=""
MACHINE_ERR=""
if [[ -n "${HERDR_BIN}" ]]; then
  set +o errexit
  MACHINE_JSON="$(timeout 10 "${HERDR_BIN}" machine list --json 2>"${TMPDIR:-/tmp}/diag-panel.err")"
  MACHINE_RC=$?
  set -o errexit
  MACHINE_ERR="$(cat "${TMPDIR:-/tmp}/diag-panel.err" 2>/dev/null || true)"
  rm -f "${TMPDIR:-/tmp}/diag-panel.err"
else
  MACHINE_RC="n/a"
  MACHINE_ERR="HERDR_BIN_PATH 未设置（面板运行时由 herdr 注入；直接终端里通常为空）"
fi

MACHINE_COUNT="n/a"
if [[ -n "${MACHINE_JSON}" ]]; then
  MACHINE_COUNT="$(printf '%s' "${MACHINE_JSON}" | jq -r 'if type=="array" then length elif (.machines|type)=="array" then .machines|length elif (.result.machines|type)=="array" then .result.machines|length else "?" end' 2>/dev/null || echo '?')"
fi

MACHINE_TARGETS=""
if [[ -n "${MACHINE_JSON}" ]]; then
  MACHINE_TARGETS="$(printf '%s' "${MACHINE_JSON}" | jq -r '
    (if type == "array" then .
     elif (.machines | type) == "array" then .machines
     elif (.result.machines | type) == "array" then .result.machines
     elif (.result | type) == "array" then .result
     else [] end)
    | [.[] | (.target // "")] | join(",")
  ' 2>/dev/null || true)"
fi
HAS_URI_TARGET="no"
if [[ "${MACHINE_TARGETS}" == *"ssh://"* ]]; then
  HAS_URI_TARGET="yes"
fi

VIEW_JSON=""
VIEW_RC=0
VIEW_ERR=""
PANEL_RENDER=""
PANEL_RC=0

# lib 层探针在**子进程 + 沙箱状态目录**里跑，保证本工具对真实 state 目录零写入：
#   * 数据层降级时会 log warn 到 $HERDR_PLUGIN_STATE_DIR/logs/forward.log —— 那就是写操作；
#   * 沙箱里预放一份 activated-machines.json 的**副本**，面板渲染结果与真实上下文等价；
#   * lib 自身的 set -Eeuo pipefail 也影响不到本脚本。
DIAG_SANDBOX="${TMPDIR:-/tmp}/diag-panel-sandbox.$$"
rm -rf "${DIAG_SANDBOX}"
mkdir -p "${DIAG_SANDBOX}"
if [[ -f "${ACT_FILE}" ]]; then
  cp "${ACT_FILE}" "${DIAG_SANDBOX}/activated-machines.json"
fi

DIAG_PROBE_SH="${DIAG_SANDBOX}/probe.sh"
cat >"${DIAG_PROBE_SH}" <<EOF
set -Eeuo pipefail
export HERDR_PLUGIN_STATE_DIR='${DIAG_SANDBOX}'
export HERDR_PLUGIN_CONFIG_DIR='${DIAG_SANDBOX}/config'
export HERDR_BIN_PATH='${HERDR_BIN}'
export HERDR_PLUGIN_ROOT='${PLUGIN_ROOT}'
source '${LIB_DIR}/common.sh' >/dev/null 2>&1 || true
source '${LIB_DIR}/state.sh' >/dev/null 2>&1 || true
source '${LIB_DIR}/machines.sh' >/dev/null 2>&1 || true
source '${LIB_DIR}/panel.sh' >/dev/null 2>&1 || true
case "\$1" in
view)
  if declare -F machines_view_json >/dev/null 2>&1; then
    machines_view_json
  else
    printf 'lib/machines.sh 未加载（machines_view_json 不存在）\n' >&2
    exit 1
  fi
  ;;
panel)
  if declare -F panel_render >/dev/null 2>&1; then
    panel_render
  else
    printf 'lib/panel.sh 未加载（panel_render 不存在）\n' >&2
    exit 1
  fi
  ;;
*)
  printf 'diag-probe: 未知模式 %s\n' "\$1" >&2
  exit 64
  ;;
esac
EOF

# _diag_probe <view|panel>：结果写全局 DIAG_OUT / DIAG_ERR / DIAG_RC（恒不中断）
DIAG_OUT=""
DIAG_ERR=""
DIAG_RC=0
_diag_probe() {
  local errf="${DIAG_SANDBOX}/probe.err"
  DIAG_OUT=""
  DIAG_ERR=""
  DIAG_RC=0
  set +o errexit
  DIAG_OUT="$(bash "${DIAG_PROBE_SH}" "${1-}" 2>"${errf}")"
  DIAG_RC=$?
  set -o errexit
  DIAG_ERR="$(cat "${errf}" 2>/dev/null || true)"
  return 0
}

_diag_probe view
VIEW_JSON="${DIAG_OUT}"
VIEW_ERR="${DIAG_ERR}"
VIEW_RC="${DIAG_RC}"

_diag_probe panel
PANEL_RENDER="${DIAG_OUT}"
PANEL_RC="${DIAG_RC}"
rm -rf "${DIAG_SANDBOX}"

VIEW_COUNT="n/a"
if [[ -n "${VIEW_JSON}" ]]; then
  VIEW_COUNT="$(printf '%s' "${VIEW_JSON}" | jq -r 'if type=="array" then length else "?" end' 2>/dev/null || echo '?')"
fi

LOG_TAIL=""
if [[ -f "${LOG_FILE}" ]]; then
  LOG_TAIL="$(tail -n 40 "${LOG_FILE}" 2>/dev/null || true)"
fi

ACT_SUMMARY=""
if [[ -f "${ACT_FILE}" ]]; then
  ACT_SUMMARY="$(jq -c '{active: (.active // null), machines: ((.machines // {}) | keys)}' "${ACT_FILE}" 2>/dev/null || echo '(activated-machines.json 无法解析)')"
fi

# ---------------------------------------------------------------------------
# 结论（症状 -> 最可能原因；只给判据，不猜）
# ---------------------------------------------------------------------------
VERDICT=""
VERDICT_HINT=""
if [[ -z "${HERDR_BIN}" ]]; then
  VERDICT="HERDR_BIN_PATH 未设置"
  VERDICT_HINT="面板是在 herdr 里跑的，那个上下文会注入 HERDR_BIN_PATH。若这里为空，说明你是在普通终端里跑的 —— 请在 herdr 的 pane 里跑本脚本（或先 export HERDR_BIN_PATH=$(printf '%s' "${HERDR_ON_PATH:-/path/to/herdr}")）。"
elif [[ "${HERDR_BIN_EXEC}" != "yes" ]]; then
  VERDICT="HERDR_BIN_PATH 指向的文件不可执行"
  VERDICT_HINT="${HERDR_BIN} 不存在或没有 x 位；herdr 升级/换路径后残留的旧值会造成「面板永远空」。"
elif [[ "${MACHINE_RC}" != "0" ]]; then
  VERDICT="herdr machine list --json 失败（rc=${MACHINE_RC}）"
  VERDICT_HINT="herdr server 没起来 / 当前 socket 不认这个 CLI 会话时都会这样。${MACHINE_ERR}"
elif [[ "${MACHINE_COUNT}" == "0" ]]; then
  VERDICT="herdr 里没有任何 saved machine"
  VERDICT_HINT="用 'herdr machine add <ssh target> --label <label>' 保存一台，再回面板按 r 刷新。"
elif [[ "${VIEW_COUNT}" == "0" ]]; then
  VERDICT="herdr 有机器但 machines_view_json 返回空"
  VERDICT_HINT="数据层加载失败（lib/machines.sh / jq 缺失）。看下方「插件日志 tail」与 stderr。"
elif [[ "${PANEL_RC}" != "0" || "${PANEL_RENDER}" != *"MACHINES"* ]]; then
  VERDICT="数据层有机器，但面板渲染没有 MACHINES 段"
  VERDICT_HINT="面板模块加载或渲染路径异常；下方「面板渲染（非交互）」的 stderr 是主要线索。"
elif [[ "${HAS_URI_TARGET}" == "yes" ]]; then
  VERDICT="面板输入链路正常；fixture 含 ssh:// URI target"
  VERDICT_HINT="URI 形态的 target 在旧版本上会让 SSH 探测解析失败（host 带 ssh:// 前缀）。功能可用性与 herdr 版本见下方。"
else
  VERDICT="面板输入链路正常"
  VERDICT_HINT="若面板里仍看不到 MACHINES：确认打开面板后按 r 刷新；并核对 herdr 版本（下方）与激活记录。"
fi

# ---------------------------------------------------------------------------
# 输出
# ---------------------------------------------------------------------------
if [[ "${JSON_MODE}" -eq 1 ]]; then
  jq -c -n \
    --arg ts "${NOW_UTC}" \
    --arg plugin_root "${PLUGIN_ROOT}" \
    --arg herdr_bin "${HERDR_BIN}" \
    --arg herdr_bin_exec "${HERDR_BIN_EXEC}" \
    --arg herdr_version "${HERDR_VERSION}" \
    --arg herdr_on_path "${HERDR_ON_PATH}" \
    --arg pane_id "${PANE_ID}" \
    --arg socket_path "${SOCKET_PATH}" \
    --arg state_dir "${STATE_DIR}" \
    --arg machine_rc "${MACHINE_RC}" \
    --arg machine_count "${MACHINE_COUNT}" \
    --arg has_uri_target "${HAS_URI_TARGET}" \
    --arg view_rc "${VIEW_RC}" \
    --arg view_count "${VIEW_COUNT}" \
    --arg panel_rc "${PANEL_RC}" \
    --arg verdict "${VERDICT}" \
    --arg hint "${VERDICT_HINT}" \
    '{
      generated_utc: $ts, plugin_root: $plugin_root,
      herdr_bin_path: $herdr_bin, herdr_bin_executable: $herdr_bin_exec,
      herdr_version: $herdr_version, herdr_on_path: $herdr_on_path,
      pane: {id: $pane_id, socket: $socket_path}, plugin_state_dir: $state_dir,
      machine_list_rc: $machine_rc, machine_count: $machine_count,
      has_ssh_uri_target: $has_uri_target,
      view_rc: $view_rc, view_count: $view_count, panel_render_rc: $panel_rc,
      verdict: $verdict, hint: $hint
    }'
  exit 0
fi

printf '=== herdr-forward 面板诊断（只读） ===\n'
printf '生成时间(UTC): %s\n' "${NOW_UTC}"
printf '插件根:        %s\n' "${PLUGIN_ROOT}"
printf '结论:          %s\n' "${VERDICT}"
printf '建议:          %s\n' "${VERDICT_HINT}"

printf '\n--- [1] HERDR_BIN_PATH ---\n'
printf '  HERDR_BIN_PATH : %s\n' "${HERDR_BIN:-<未设置>}"
printf '  可执行         : %s\n' "${HERDR_BIN_EXEC}"
printf '  PATH 上的 herdr: %s\n' "${HERDR_ON_PATH:-<无>}"
printf '  版本           : %s\n' "${HERDR_VERSION:-<取不到>}"

printf '\n--- [2] herdr 会话上下文（pane 与直接终端的差异就在这一层） ---\n'
printf '  HERDR_PANE_ID     : %s\n' "${PANE_ID:-<未设置>}"
printf '  HERDR_SOCKET_PATH : %s\n' "${SOCKET_PATH:-<未设置>}"
printf '  HERDR_TAB_ID      : %s\n' "${TAB_ID:-<未设置>}"
printf '  HERDR_WORKSPACE_ID: %s\n' "${WORKSPACE_ID:-<未设置>}"
if [[ -z "${PANE_ID}" && -z "${SOCKET_PATH}" ]]; then
  printf '  → 看起来不在 herdr pane 里（这些变量由 herdr 注入）。请从 herdr 内运行本脚本复现问题。\n'
fi

printf '\n--- [3] %s machine list --json ---\n' "${HERDR_BIN:-<HERDR_BIN_PATH 未设置>}"
printf '  rc: %s\n' "${MACHINE_RC}"
printf '  解析到的机器数: %s\n' "${MACHINE_COUNT}"
if [[ -n "${MACHINE_ERR}" ]]; then
  printf '  stderr:\n'
  printf '%s\n' "${MACHINE_ERR}" | sed 's/^/    /'
fi
printf '  原始输出:\n'
if [[ -n "${MACHINE_JSON}" ]]; then
  printf '%s\n' "${MACHINE_JSON}" | sed 's/^/    /'
else
  printf '    <空>\n'
fi

printf '\n--- [4] 插件状态目录与激活记录 ---\n'
printf '  HERDR_PLUGIN_STATE_DIR: %s\n' "${STATE_DIR}"
printf '  HERDR_PLUGIN_CONFIG_DIR: %s\n' "${CONFIG_DIR}"
PLUGINS_EXISTS=0
if [[ -f "${PLUGINS_JSON}" ]]; then
  PLUGINS_EXISTS=1
fi
printf '  plugins.json: %s (%s)\n' "${PLUGINS_JSON}" "${PLUGINS_EXISTS}"
if [[ -n "${ACT_SUMMARY}" ]]; then
  printf '  activated-machines.json: %s\n' "${ACT_SUMMARY}"
else
  printf '  activated-machines.json: <不存在>（从未激活过任何机器，正常）\n'
fi

printf '\n--- [5] machines_view_json（面板数据入口） ---\n'
printf '  rc: %s\n' "${VIEW_RC}"
if [[ -n "${VIEW_ERR}" ]]; then
  printf '  stderr:\n'
  printf '%s\n' "${VIEW_ERR}" | sed 's/^/    /'
fi
printf '  输出:\n'
if [[ -n "${VIEW_JSON}" ]]; then
  printf '%s\n' "${VIEW_JSON}" | sed 's/^/    /'
else
  printf '    <空>\n'
fi

printf '\n--- [6] 面板渲染（非交互，panel_render 直出） ---\n'
printf '  rc: %s\n' "${PANEL_RC}"
if [[ -n "${PANEL_RENDER}" ]]; then
  printf '%s\n' "${PANEL_RENDER}" | sed 's/^/    /'
else
  printf '    <空>\n'
fi

printf '\n--- [7] 插件日志 tail（%s） ---\n' "${LOG_FILE}"
if [[ -n "${LOG_TAIL}" ]]; then
  printf '%s\n' "${LOG_TAIL}" | sed 's/^/  /'
else
  printf '  <无日志或日志文件不存在>\n'
fi

printf '\n--- [8] 下一步 ---\n'
printf '  * 面板里按 r 立即刷新；MACHINES 段为空时先看 [1][2][3] 三层。\n'
printf '  * 上面 output 里出现 ssh:// 形态 target（本机: %s）时，请确认 herdr-forward 版本已含 ssh:// 解析修复。\n' "${HAS_URI_TARGET}"
printf '  * 提交 issue 时请贴 "bash %s --json" 的结果（不含密钥）。\n' "${0##*/}"
exit 0
