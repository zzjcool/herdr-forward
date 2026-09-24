#!/usr/bin/env bash
# tests/unit/test_panel.sh — lib/panel.sh 交互式 Port Forward 面板契约（M3）
#
# 覆盖（计划 §2.4 / §5 风险 1 / §3 表）：
#   * panel_render：machines 三态行（`[✓] active` / `[·] activated` / `[ ] inactive`）、
#     置灰 ANSI、空/缺失时整段省略、无 M2 模块时读 activated-machines.json 降级
#   * panel_handle_key：数字选择（激活 / 停用）、r 刷新、x/q 退出、a 提示 add、未知键 none
#   * panel_confirm：y/yes/n/no/空输入（EOF）→ no（安全默认）
#   * panel_main：按键流驱动状态机 —— 渲染 → 确认 → 「探测中…」占位（先 render 再跑）
#     → 子进程 → 重绘；确认 no 时不跑子进程；stdin EOF 不挂死
#   * _panel_probe：激活/停用只是 `forward machines activate|deactivate <id>` 的包装
#     （§5 风险 1 缓解：CLI 直调路径始终可用）
#   * cmd_watch 分流：stdin 非 TTY → 退化 exec `watch -n 3 forward list`（E2E 兼容）
#
# 手法：最小「确定性插件根」+ 子进程内 source lib/panel.sh 后覆盖 I/O 缝
#   （panel_is_tty / machines_view_json / panel_render / panel_confirm / _panel_probe）。
#   绝不真跑 ssh：激活子进程整体 mock；`watch` / `herdr` / `forward` 用 PATH shim。
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PANEL="${ROOT}/lib/panel.sh"

if [[ -f "${ROOT}/tests/lib/assertions.sh" ]]; then
  # shellcheck source=/dev/null
  source "${ROOT}/tests/lib/assertions.sh"
fi
if ! declare -F t_fail_note >/dev/null 2>&1; then
  t_fail_note() { t_fail "$@"; }
fi

if [[ ! -f "${PANEL}" ]]; then
  echo "RED: ${PANEL} 不存在（lib/panel.sh 尚未实现）" >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

PLUGIN_ROOT="${WORK}/plugin"
STATE_DIR="${WORK}/state"
FAKE_BIN="${WORK}/fakebin"
HARNESS="${WORK}/harness.sh"
# tput 调用留痕（断言 _panel_clear 不再 fork tput）：shim 写这里，测试尾部读它
tput_log="${WORK}/tput.log"
: >"${tput_log}"

# 事实 #1 schema 的最小 machine list（fake herdr CLI 输出）。
# 注意：真 herdr machine list --json 的字段是 "target"（非 ssh_target），
# activated-machines.json 里才是 ssh_target —— 勿混淆（M3 初版写错过）。
DEFAULT_MACHINES='[{"id":"m1","label":"test-probe","target":"user@b-host:22","enabled":true}]'

# 面板子进程 harness：载入 common/state/panel 后 source 掉代码片段文件。
# 片段走文件（heredoc 生成）而非单引号字符串，既避免本层变量展开，也避开 SC2016。
mkdir -p "${WORK}"
cat >"${HARNESS}" <<'SH'
set -Eeuo pipefail
PLUGIN_ROOT="$1"
CODE_FILE="$2"
source "${PLUGIN_ROOT}/lib/common.sh"
source "${PLUGIN_ROOT}/lib/state.sh"
source "${PLUGIN_ROOT}/lib/panel.sh"
source "${CODE_FILE}"
SH

# --- 确定性插件根 + PATH shim ---
stage() {
  rm -rf "${PLUGIN_ROOT}" "${STATE_DIR}" "${FAKE_BIN}"
  mkdir -p "${PLUGIN_ROOT}/bin" "${PLUGIN_ROOT}/lib" "${STATE_DIR}" "${FAKE_BIN}"
  cp "${ROOT}/bin/forward" "${PLUGIN_ROOT}/bin/forward"
  chmod +x "${PLUGIN_ROOT}/bin/forward"
  cp "${ROOT}/lib/common.sh" "${PLUGIN_ROOT}/lib/common.sh"
  cp "${ROOT}/lib/state.sh" "${PLUGIN_ROOT}/lib/state.sh"
  cp "${PANEL}" "${PLUGIN_ROOT}/lib/panel.sh"
  # M2 合入后一并拷入（面板优先用真模块；未合入时走面板自带降级路径）。
  # 注意 machines.sh 会 source 同目录的 ssh-probe.sh（M1 提取），必须一起拷，
  # 否则 _panel_machines_module_loadable 子进程探测失败，面板降级到状态文件。
  if [[ -f "${ROOT}/lib/machines.sh" ]]; then
    cp "${ROOT}/lib/machines.sh" "${PLUGIN_ROOT}/lib/machines.sh"
  fi
  if [[ -f "${ROOT}/lib/ssh-probe.sh" ]]; then
    cp "${ROOT}/lib/ssh-probe.sh" "${PLUGIN_ROOT}/lib/ssh-probe.sh"
  fi

  # fake watch：非 TTY 退化路径的断言目标
  cat >"${FAKE_BIN}/watch" <<'EOF'
#!/usr/bin/env bash
printf 'FAKE-WATCH %s\n' "$*"
EOF
  # fake herdr CLI：machine list --json（事实 #1 schema）
  cat >"${FAKE_BIN}/herdr" <<'EOF'
#!/usr/bin/env bash
if [[ "${1-}" == "machine" && "${2-}" == "list" ]]; then
  printf '%s\n' "${HF_FAKE_MACHINES:-[]}"
  exit 0
fi
exit 1
EOF
  # fake forward：验证面板激活走 CLI 直调路径（§5.1）
  cat >"${FAKE_BIN}/forward" <<'EOF'
#!/usr/bin/env bash
printf 'FWD %s\n' "$*"
EOF
  # fake tput：任何一次调用都留痕（PATH 前置，遮住 /usr/bin/tput）。
  # panel 修复的目标之一就是「每帧不再 fork tput」——这个 shim 就是行为级哨兵。
  cat >"${FAKE_BIN}/tput" <<'EOF'
#!/usr/bin/env bash
printf 'tput %s\n' "$*" >>"${HF_TPUT_LOG:-/dev/null}"
exit 0
EOF
  chmod +x "${FAKE_BIN}/watch" "${FAKE_BIN}/herdr" "${FAKE_BIN}/forward" "${FAKE_BIN}/tput"
}

# --- 捕获（可指定 stdin 文件） ---
out=""
err=""
rc=0
_cap() { # _cap <stdin-file> <cmd...>
  local in="${1-}"
  shift || true
  set +o errexit
  out="$("$@" <"${in}" 2>"${WORK}/.stderr")"
  rc=$?
  set -o errexit
  err="$(cat "${WORK}/.stderr" 2>/dev/null || true)"
}

# _pl_run <stdin-file> <code-string>：在确定性 env 下跑 panel 子进程
# （timeout 兜底：任何挂死都变成可诊断的 rc，不会拖死 CI）。
# HF_HERDR_BIN 可覆盖 HERDR_BIN_PATH（诊断用例需要「未设置」形态）。
_pl_run() {
  local input="${1-}"
  local code="${2-}"
  local code_file="${WORK}/code.sh"
  printf '%s\n' "${code}" >"${code_file}"
  _cap "${input}" env \
    HERDR_PLUGIN_STATE_DIR="${STATE_DIR}" \
    HERDR_PLUGIN_ROOT="${PLUGIN_ROOT}" \
    HERDR_BIN_PATH="${HF_HERDR_BIN:-${FAKE_BIN}/herdr}" \
    HF_FAKE_MACHINES="${HF_FAKE_MACHINES:-${DEFAULT_MACHINES}}" \
    HF_VIEW_FILE="${HF_VIEW_FILE:-}" \
    HF_KEY="${HF_KEY:-}" \
    HF_TPUT_LOG="${tput_log}" \
    PANEL_REFRESH_S=1 \
    PATH="${FAKE_BIN}:${PATH}" \
    timeout 20 bash "${HARNESS}" "${PLUGIN_ROOT}" "${code_file}"
}

# _pl_run_nobin <stdin-file> <code-string>：同 _pl_run 但**不设** HERDR_BIN_PATH
# （Bug 2 诊断用例：``缺 HERDR_BIN_PATH → 纯省略无提示'' 的前提）
_pl_run_nobin() {
  local input="${1-}"
  local code="${2-}"
  local code_file="${WORK}/code.sh"
  printf '%s\n' "${code}" >"${code_file}"
  _cap "${input}" env -u HERDR_BIN_PATH \
    HERDR_PLUGIN_STATE_DIR="${STATE_DIR}" \
    HERDR_PLUGIN_ROOT="${PLUGIN_ROOT}" \
    HF_HERDR_SHIM="" \
    HF_KEY="${HF_KEY:-}" \
    HF_TPUT_LOG="${tput_log}" \
    PANEL_REFRESH_S=1 \
    PATH="${FAKE_BIN}:${PATH}" \
    timeout 20 bash "${HARNESS}" "${PLUGIN_ROOT}" "${code_file}"
}

# _assert_nseq <expected-count> <needle> <haystack> <msg>：次数断言（先落变量，避开 SC2312）
_assert_nseq() {
  local n=""
  n="$(_nseq "${2-}" "${3-}")"
  t_eq "${1-}" "${n}" "${4-}"
}

# _assert_absent <needle> <haystack> <msg>
_assert_absent() {
  if [[ "${2-}" == *"${1-}"* ]]; then
    t_fail_note "${3-}（不应包含 [${1}]，实际 [${2}]）"
  else
    t_pass "${3-}"
  fi
}

# _line_of <haystack> <needle>：取含 needle 的第一行
_line_of() { printf '%s\n' "${1-}" | grep -F -- "${2-}" | head -1 || true; }

# _count <needle> <haystack>
_count() { printf '%s\n' "${2-}" | grep -c -F -- "${1-}" || true; }

# _nseq <needle> <haystack>：出现**次数**（grep -o 逐次计数，不受「同一行多次」影响）。
# 控制序列与正文常写在同一行，_count 会把它们算成 1 行，故终端序列断言必须用这个。
_nseq() {
  local n=""
  n="$(printf '%s' "${2-}" | grep -o -F -- "${1-}" 2>/dev/null | wc -l || true)"
  n="${n//[[:space:]]/}"
  printf '%s\n' "${n:-0}"
}

# _ord <needle> <haystack>：needle 首次出现的字节偏移（无则空）
_ord() {
  local off=""
  off="$(printf '%s' "${2-}" | grep -abo -F -- "${1-}" 2>/dev/null | head -1 | cut -d: -f1 || true)"
  printf '%s\n' "${off:-}"
}

# _assert_order <needle-a> <needle-b> <haystack> <msg>：断言 a 在 b 之前出现
_assert_order() {
  local oa="" ob=""
  oa="$(_ord "${1-}" "${3-}")"
  ob="$(_ord "${2-}" "${3-}")"
  if [[ -n "${oa}" && -n "${ob}" && "${oa}" -lt "${ob}" ]]; then
    t_pass "${4-}"
  else
    t_fail_note "${4-}（顺序断言失败：前@${oa:-?} 后@${ob:-?}）"
  fi
}

# assert_clear_sequence：清屏序列必须能真正抹掉旧帧
#   要么 `\033[2J`（整屏）、要么 `\033[H\033[J`（home + 清到尾）—— 任一即可，
#   但必须至少出现一个「抹除」序列，否则行数变少时旧帧会留残影。
assert_clear_sequence() {
  local msg="${1:-清屏序列含抹除指令}"
  local clr="${SEQ_CLR}"
  local combined="${SEQ_HOME}${SEQ_ERASE_TAIL}"

  if [[ "${out}" == *"${clr}"* ]]; then
    t_pass "${msg}（\\033[2J）"
  elif [[ "${out}" == *"${combined}"* ]]; then
    t_pass "${msg}（\\033[H\\033[J）"
  else
    local shown=""
    shown="$(printf '%s' "${out}" | cat -v)"
    t_fail_note "${msg}：输出里既无 \\033[2J 也无 \\033[H\\033[J（实际：${shown}）"
  fi
}

# assert_plain_clear_emitted [msg]：TERM 未设路径下的宽松版（只看有抹除类序列）
assert_plain_clear_emitted() {
  assert_clear_sequence "${1:-TERM 未设时清屏仍可用}"
}

DIM="$(printf '\033[2m')"

stage

t_describe "lib/panel.sh：machines 三态渲染"

VIEW_3="${WORK}/view-three.json"
cat >"${VIEW_3}" <<'EOF'
[{"id":"m1","label":"test-probe","target":"user@b-host:22","enabled":true,"state":"active"},
 {"id":"m2","label":"gpu-box","target":"user@g-host:22","enabled":true,"state":"activated"},
 {"id":"m3","label":"lab-pc","target":"user@l-host:22","enabled":false,"state":"inactive"}]
EOF

# 渲染片段：视图走 M2 冻结签名 machines_view_json（此处以文件内容 stub）
read -r -d '' SNIP_RENDER <<'CODE' || true
machines_view_json() { cat "${HF_VIEW_FILE}"; }
panel_render
CODE

t_it "active 行：'[✓] 1. label' + target + (tab bar 指向)，不置灰"
HF_VIEW_FILE="${VIEW_3}"
_pl_run /dev/null "${SNIP_RENDER}"
t_exit_ok 0 "${rc}" "panel_render exit 0"
t_contains "[✓] 1. test-probe" "${out}" "active 行前缀与序号"
t_contains "user@b-host:22" "${out}" "active 行显示 ssh_target"
active_line="$(_line_of "${out}" "[✓] 1. test-probe")"
_assert_absent "${DIM}" "${active_line}" "active 行不置灰"
t_contains "tab bar" "${active_line}" "active 行标注 tab bar 已指向该机"

t_it "activated 行：'[·] 2. label' + 置灰 + 说明（已激活，非当前）"
t_contains "[·] 2. gpu-box" "${out}" "activated 行前缀与序号"
act_line="$(_line_of "${out}" "[·] 2. gpu-box")"
t_contains "${DIM}" "${act_line}" "activated 行置灰（ANSI dim）"
t_contains "已激活" "${act_line}" "activated 行说明"
_assert_absent "tab bar →" "${act_line}" "activated 行不标注 tab bar 指向"

t_it "inactive 行：'[ ] 3. label' + 置灰 + 未激活说明"
t_contains "[ ] 3. lab-pc" "${out}" "inactive 行前缀与序号"
inact_line="$(_line_of "${out}" "[ ] 3. lab-pc")"
t_contains "${DIM}" "${inact_line}" "inactive 行置灰"
t_contains "未激活" "${inact_line}" "inactive 行说明"

t_it "面板含 forwards 表头 + 按键帮助（数字选择 / r / x）"
t_contains "FORWARDS" "${out}" "forwards 段标题"
t_contains "按键" "${out}" "按键帮助行"
t_contains "x" "${out}" "帮助含退出键 x"

t_it "空 machines（视角不同：未配 machines）→ 整段省略，面板退化为纯 forwards"
HF_VIEW_FILE=/dev/null
_pl_run /dev/null "${SNIP_RENDER}"
t_exit_ok 0 "${rc}" "空视图 exit 0"
_assert_absent "test-probe" "${out}" "无 machines 数据"
_assert_absent "未激活" "${out}" "不渲染 machines 段"
t_contains "FORWARDS" "${out}" "forwards 段仍在（面板可用）"

t_it "machines_view_json 缺失（M2 未合入的降级）→ 读 activated-machines.json 渲染"
cat >"${STATE_DIR}/activated-machines.json" <<'EOF'
{"version":1,"active":"m1",
 "machines":{"m1":{"label":"test-probe","ssh_target":"user@b-host:22","activated_unix":1790000000,
   "server_root":"/srv/b/.config/herdr/plugins/zzjcool-forward-ab12cd34",
   "state_dir":"/srv/b/.local/state/herdr/plugins/zzjcool%3Aforward"}}}
EOF
_pl_run /dev/null "panel_render"
t_exit_ok 0 "${rc}" "无 M2 模块时 panel_render 仍 exit 0"
t_contains "test-probe" "${out}" "从状态文件降级读出已激活机器"
t_contains "[✓] 1." "${out}" "降级路径也标 active"
rm -f "${STATE_DIR}/activated-machines.json"

t_it "状态文件缺失 → 不报错（machines 段省略）"
# M2 合入后：真 machines.sh 走 herdr list 透传，fake herdr shim 默认返回
# DEFAULT_MACHINES（含 test-probe）。语义改为：空 herdr 视图 + 无状态文件 →
# machines 段省略。原「无状态文件即省略」的假设只成立于 stub 时代。
stage
HF_FAKE_MACHINES="[]"
_pl_run /dev/null "panel_render"
t_exit_ok 0 "${rc}" "缺文件且无 saved machines exit 0"
_assert_absent "test-probe" "${out}" "无机器行"
_assert_absent "未激活" "${out}" "不渲染 machines 段"
t_contains "FORWARDS" "${out}" "forwards 段仍在（面板可用）"
unset HF_FAKE_MACHINES # 上一段的 [] 会因 :- 的非空判定残留，必须显式清掉

# 有 saved machines 但无激活状态 → 未激活置灰行（真路径正常渲染）
stage
_pl_run /dev/null "panel_render"
t_exit_ok 0 "${rc}" "有 saved machines 无状态文件 exit 0"
t_contains "[ ] 1. test-probe" "${out}" "未激活置灰行（来自 herdr list 透传）"
t_contains "FORWARDS" "${out}" "forwards 段仍在"

t_describe "lib/panel.sh：machines 段省略时的诊断提示（Bug 2）"

# 为什么需要它：machines_herdr_list_json 的 warn 只进日志文件，用户在面板里看不到。
# 面板是唯一入口，段位静默消失 = 用户无从知道是「真的没配」还是「herdr 命令挂了」。
# 提示文本必须给出可直接复制排障的命令，否则用户还是只能猜。
t_it "空列表 + HERDR_BIN_PATH 已设 → 追加灰字提示行"
stage
HF_FAKE_MACHINES="[]"
_pl_run /dev/null "panel_render"
t_exit_ok 0 "${rc}" "exit 0（提示不得让面板失败）"
hint_line="$(_line_of "${out}" "未列出 saved machines")"
t_contains "未列出 saved machines" "${out}" "提示行出现"
_assert_absent "MACHINES (" "${out}" "仍不渲染 machines 段（省略不变）"
t_contains "${DIM}" "${hint_line}" "提示行置灰"
t_contains "machine list --json" "${hint_line}" "提示给出可复制跳命令"
t_contains "${FAKE_BIN}/herdr" "${hint_line}" "提示里代入真实 HERDR_BIN_PATH"
unset HF_FAKE_MACHINES

t_it "HERDR_BIN_PATH 缺失 → 纯省略，不加提示（未在插件运行时里）"
stage
_pl_run_nobin /dev/null "panel_render"
t_exit_ok 0 "${rc}" "exit 0"
_assert_absent "未列出 saved machines" "${out}" "无 HERDR_BIN_PATH 时不吓人"
_assert_absent "MACHINES (" "${out}" "machines 段仍省略"
t_contains "FORWARDS" "${out}" "forwards 段仍在（面板可用）"

t_it "有 saved machines 时不加提示（避免了狼来了）"
stage
_pl_run /dev/null "panel_render"
t_exit_ok 0 "${rc}" "exit 0"
t_contains "MACHINES (" "${out}" "machines 段正常渲染"
_assert_absent "未列出 saved machines" "${out}" "有机器时不提示"

t_it "herdr list 失败（rc=7）+ HERDR_BIN_PATH 已设 → 提示行出现"
stage
cat >"${FAKE_BIN}/herdr" <<'EOF'
#!/usr/bin/env bash
echo 'herdr: server not running' >&2
exit 7
EOF
chmod +x "${FAKE_BIN}/herdr"
_pl_run /dev/null "panel_render"
t_exit_ok 0 "${rc}" "herdr 挂掉也不拖趴面板"
t_contains "未列出 saved machines" "${out}" "失败时也给提示（用户可见）"
t_contains "FORWARDS" "${out}" "forwards 段仍正常（面板可用优先）"

t_it "local（同机短路激活）行：也是 [✓] + 不置灰 + 本机说明"
VIEW_LOCAL="${WORK}/view-local-render.json"
printf '%s\n' '[{"id":"m1","label":"self-pc","target":"localhost","enabled":true,"state":"local"}]' >"${VIEW_LOCAL}"
HF_VIEW_FILE="${VIEW_LOCAL}"
_pl_run /dev/null "${SNIP_RENDER}"
t_contains "[✓] 1. self-pc" "${out}" "local 行也用 ✓ 标记"
local_line="$(_line_of "${out}" "[✓] 1. self-pc")"
_assert_absent "${DIM}" "${local_line}" "local 行不置灰"
t_contains "本机" "${local_line}" "local 行说明是本机（无需远程探测）"

t_it "lib/machines.sh 提供 machines_view_json → 面板自动加载它（M2 冻结签名的接入点）"
stage
cat >"${PLUGIN_ROOT}/lib/machines.sh" <<'M2STUB'
set -o errexit -o nounset -o pipefail
machines_view_json() { cat "${HF_VIEW_FILE}"; }
M2STUB
HF_VIEW_FILE="${VIEW_3}"
_pl_run /dev/null 'panel_render'
t_exit_ok 0 "${rc}" "自动加载后 panel_render exit 0"
t_contains "[✓] 1. test-probe" "${out}" "列表来自 modules.sh 的 machines_view_json"
t_contains "[·] 2. gpu-box" "${out}" "三态均由模块提供"
t_contains "[ ] 3. lab-pc" "${out}" "未激活机器也渲染"

t_it "lib/machines.sh source 即 die（依赖缺失的坏模块）→ 面板仍能开，降级读状态文件"
stage
cat >"${PLUGIN_ROOT}/lib/machines.sh" <<'M2BROKEN'
set -o errexit -o nounset -o pipefail
source "/nonexistent/ssh-probe.sh"
M2BROKEN
cat >"${STATE_DIR}/activated-machines.json" <<'EOF'
{"version":1,"active":"m1","machines":{"m1":{"label":"fallback-box","ssh_target":"u@b:22","server_root":"/srv/b/x","state_dir":"/srv/b/s"}}}
EOF
_pl_run /dev/null 'panel_render'
t_exit_ok 0 "${rc}" "坏模块不得拖趴面板（面板必须能开）"
t_contains "fallback-box" "${out}" "降级读 activated-machines.json"
t_contains "FORWARDS" "${out}" "forwards 段正常"
stage

t_describe "lib/panel.sh：按键流（panel_handle_key）"

KEY_INACTIVE="${WORK}/view-inactive.json"
printf '%s\n' '[{"id":"m1","label":"test-probe","target":"t@h:22","enabled":false,"state":"inactive"},{"id":"m2","label":"gpu-box","target":"g@h:22","enabled":true,"state":"activated"}]' >"${KEY_INACTIVE}"
KEY_ACTIVE="${WORK}/view-active.json"
printf '%s\n' '[{"id":"m1","label":"test-probe","target":"t@h:22","enabled":true,"state":"active"},{"id":"m2","label":"gpu-box","target":"g@h:22","enabled":true,"state":"activated"}]' >"${KEY_ACTIVE}"

read -r -d '' SNIP_KEY <<'CODE' || true
machines_view_json() { cat "${HF_VIEW_FILE}"; }
panel_handle_key "${HF_KEY}"
CODE

# _key <view-file> <key> -> $out 是动作字符串
_key() {
  HF_VIEW_FILE="$1"
  HF_KEY="$2"
  _pl_run /dev/null "${SNIP_KEY}"
}

t_it "数字选择未激活机器 → activating:<id>"
_key "${KEY_INACTIVE}" 1
t_exit_ok 0 "${rc}" "exit 0"
t_eq "activating:m1" "${out}" "1 → activating:m1"
_key "${KEY_INACTIVE}" 2
t_eq "activating:m2" "${out}" "2 → activating:m2（第 2 行）"

t_it "数字选择当前 active 机器 → deactivating:<id>（确认后停用）"
_key "${KEY_ACTIVE}" 1
t_eq "deactivating:m1" "${out}" "active 机 → deactivating:m1"

t_it "数字选择 local（同机短路激活）机器 → 同样是 deactivating:<id>"
KEY_LOCAL="${WORK}/view-local.json"
printf '%s\n' '[{"id":"m1","label":"self","target":"localhost","enabled":true,"state":"local"}]' >"${KEY_LOCAL}"
_key "${KEY_LOCAL}" 1
t_eq "deactivating:m1" "${out}" "local 机也是「当前活动」→ 停用"

t_it "越界数字 / 未知键 → none"
_key "${KEY_INACTIVE}" 9
t_eq "none" "${out}" "9（越界）→ none"
_key "${KEY_INACTIVE}" Z
t_eq "none" "${out}" "未知键 → none"

t_it "r → refresh；x / q → quit"
_key "${KEY_INACTIVE}" r
t_eq "refresh" "${out}" "r → refresh"
_key "${KEY_INACTIVE}" x
t_eq "quit" "${out}" "x → quit"
_key "${KEY_INACTIVE}" q
t_eq "quit" "${out}" "q → quit"

t_it "a → none + 提示 forward add 用法（一期不内嵌表单）"
_key "${KEY_INACTIVE}" a
t_eq "none" "${out}" "a → none"
t_contains "forward add" "${err}" "stderr 提示 add 用法"

t_describe "lib/panel.sh：panel_confirm（默认 no）"

IN_YES="${WORK}/in-yes"
IN_NO="${WORK}/in-no"
IN_EOF="${WORK}/in-eof"
printf 'y\n' >"${IN_YES}"
printf 'n\n' >"${IN_NO}"
: >"${IN_EOF}"

read -r -d '' SNIP_CONFIRM <<'CODE' || true
panel_confirm "将通过 SSH 只读探测 test-probe，约 15 秒，继续? [y/N]"
CODE

t_it "输入 y → yes（提示词写 stderr，stdout 保持机器可读契约）"
_pl_run "${IN_YES}" "${SNIP_CONFIRM}"
t_exit_ok 0 "${rc}" "exit 0"
t_eq "yes" "${out}" "y → yes"
t_contains "探测" "${err}" "提示词写到 stderr"

t_it "输入 n / 空输入（EOF）→ no"
_pl_run "${IN_NO}" "${SNIP_CONFIRM}"
t_eq "no" "${out}" "n → no"
_pl_run "${IN_EOF}" "${SNIP_CONFIRM}"
t_eq "no" "${out}" "EOF → no（安全默认）"

t_it "yes / YES / 前后空白也算 yes（宽容解析）"
printf '  yes  \n' >"${WORK}/in-yeslong"
_pl_run "${WORK}/in-yeslong" "${SNIP_CONFIRM}"
t_eq "yes" "${out}" "' yes ' → yes"

t_describe "lib/panel.sh：panel_main 状态机（按键流驱动，子进程 mock）"

IN_ONE_X="${WORK}/in-1x"
printf '1x' >"${IN_ONE_X}"

read -r -d '' SNIP_MAIN_YES <<'CODE' || true
panel_is_tty() { printf 'yes\n'; }
machines_view_json() { cat "${HF_VIEW_FILE}"; }
panel_render() { printf 'RENDER\n'; }
panel_confirm() { printf 'yes\n'; }
_panel_probe() { printf 'PROBE %s\n' "$*"; IFS= read -r -n 1 -t 1 _k || true; }
panel_main
CODE

read -r -d '' SNIP_MAIN_NO <<'CODE' || true
panel_is_tty() { printf 'yes\n'; }
machines_view_json() { cat "${HF_VIEW_FILE}"; }
panel_render() { printf 'RENDER\n'; }
panel_confirm() { printf 'no\n'; }
_panel_probe() { printf 'PROBE %s\n' "$*"; }
panel_main
CODE

read -r -d '' SNIP_MAIN_NO_PROBE <<'CODE' || true
panel_is_tty() { printf 'yes\n'; }
machines_view_json() { cat "${HF_VIEW_FILE}"; }
panel_render() { printf 'RENDER\n'; }
_panel_probe() { printf 'PROBE %s\n' "$*"; }
panel_main
CODE

read -r -d '' SNIP_MAIN_SIMPLE <<'CODE' || true
panel_is_tty() { printf 'yes\n'; }
machines_view_json() { cat "${HF_VIEW_FILE}"; }
panel_render() { printf 'RENDER\n'; }
panel_main
CODE

t_it "数字 → 确认 → 「探测中…」占位（先 render 再跑）→ 子进程 → 重绘"
HF_VIEW_FILE="${KEY_INACTIVE}"
_pl_run "${IN_ONE_X}" "${SNIP_MAIN_YES}"
t_exit_ok 0 "${rc}" "panel_main exit 0（EOF 收尾，不挂死）"
t_contains "PROBE activate m1" "${out}" "调用 activate 子进程（mock 记录参数）"
t_contains "探测中" "${out}" "有探测中占位行"
probe_pos="$(printf '%s\n' "${out}" | grep -n -F 'PROBE activate m1' | head -1 | cut -d: -f1)"
ph_pos="$(printf '%s\n' "${out}" | grep -n -F '探测中' | head -1 | cut -d: -f1)"
if [[ -n "${probe_pos}" && -n "${ph_pos}" && "${ph_pos}" -lt "${probe_pos}" ]]; then
  t_pass "占位行在子进程之前打印（先 render 再跑）"
else
  t_fail_note "占位行顺序错误（占位行号=${ph_pos:-?} 子进程行号=${probe_pos:-?}）"
fi
t_contains "RENDER" "${out}" "面板重绘使用 panel_render（渲染缝）"
probe_count="$(_count 'PROBE ' "${out}")"
t_eq "1" "${probe_count}" "只跑一次探测子进程"

t_it "确认框回答 no → 不跑子进程、不显示占位行"
_pl_run "${IN_ONE_X}" "${SNIP_MAIN_NO}"
t_exit_ok 0 "${rc}" "exit 0"
_assert_absent "PROBE" "${out}" "未调用子进程"
_assert_absent "探测中" "${out}" "未显示占位行"
t_contains "RENDER" "${out}" "面板仍渲染"

t_it "当前 active 机器 → 走 deactivate 路径（停用占位文案）"
HF_VIEW_FILE="${KEY_ACTIVE}"
_pl_run "${IN_ONE_X}" "${SNIP_MAIN_YES}"
t_exit_ok 0 "${rc}" "exit 0"
t_contains "PROBE deactivate m1" "${out}" "active 机选数字 → deactivate"
t_contains "停用中" "${out}" "停用占位文案"

t_it "r 立即刷新：不触发子进程，多渲染一次"
printf 'rx' >"${WORK}/in-rx"
HF_VIEW_FILE="${KEY_INACTIVE}"
_pl_run "${WORK}/in-rx" "${SNIP_MAIN_NO_PROBE}"
t_exit_ok 0 "${rc}" "exit 0"
_assert_absent "PROBE" "${out}" "r 不触发子进程"
renders="$(_count 'RENDER' "${out}")"
if [[ "${renders}" -ge 2 ]]; then
  t_pass "r 触发重绘（渲染 ${renders} 次）"
else
  t_fail_note "r 未触发重绘（渲染 ${renders} 次）"
fi

t_it "x 退出：panel_main 立即返回 0"
printf 'x' >"${WORK}/in-x"
_pl_run "${WORK}/in-x" "${SNIP_MAIN_NO_PROBE}"
t_exit_ok 0 "${rc}" "x → 退出 0"
t_contains "RENDER" "${out}" "退出前至少渲染一次"

t_it "stdin 直接 EOF（终端消失）→ 单次渲染后返回，不空转"
_pl_run /dev/null "${SNIP_MAIN_SIMPLE}"
t_exit_ok 0 "${rc}" "EOF exit 0"
t_contains "RENDER" "${out}" "至少渲染一次"

t_describe "lib/panel.sh：_panel_probe 是 CLI 的包装（§5.1 风险缓解）"

read -r -d '' SNIP_PROBE_A <<'CODE' || true
unset FORWARD_ROOT
_panel_probe activate m1
CODE

read -r -d '' SNIP_PROBE_D <<'CODE' || true
unset FORWARD_ROOT
_panel_probe deactivate m9
CODE

t_it "_panel_probe activate <id> → 真调用 'forward machines activate <id>'（CLI 直调路径）"
_pl_run /dev/null "${SNIP_PROBE_A}"
t_exit_ok 0 "${rc}" "exit 0"
t_contains "machines activate m1" "${out}" "激活走 CLI"

t_it "_panel_probe deactivate <id> → 'forward machines deactivate <id>'"
_pl_run /dev/null "${SNIP_PROBE_D}"
t_exit_ok 0 "${rc}" "exit 0"
t_contains "machines deactivate m9" "${out}" "停用同样走 CLI"

read -r -d '' SNIP_PROBE_REAL <<'CODE' || true
_panel_probe activate m1
CODE

t_it "面板激活只包装已存在的 CLI 子命令（不新增特权路径）"
_pl_run /dev/null "${SNIP_PROBE_REAL}"
t_exit_ok 0 "${rc}" "exit 0"
t_contains "machines activate m1" "${out}" "走 ${PLUGIN_ROOT}/bin/forward"

t_describe "lib/panel.sh：终端序列（备用屏 + 光标隐藏，Bug 1 抖动修复）"

# 终端控制序列常量（与 lib/panel.sh 的实现必须逐字一致）。
# 用 $'...' 直接构造（不再套 $(printf '%b')）：避免嵌套命令替换（SC2312），
# 也让断言里的字面量一眼可读。
SEQ_ALT_ON=$'\033[?1049h'   # 进备用屏
SEQ_ALT_OFF=$'\033[?1049l'  # 出备用屏
SEQ_CUR_HIDE=$'\033[?25l'   # 隐藏光标
SEQ_CUR_SHOW=$'\033[?25h'   # 显示光标
SEQ_SAVE=$'\033[22;0;0t'    # 保存光标
SEQ_RESTORE=$'\033[23;0;0t' # 恢复光标
SEQ_HOME=$'\033[H'          # 光标 home
SEQ_CLR=$'\033[2J'          # 整屏清除
SEQ_ERASE_TAIL=$'\033[J'    # 清到屏幕末尾

# --- 终端序列用例的公共片段 ---
# 为什么要 stub _panel_probe_stdout_tty：单测的 stdout 被 _cap 捕获（是管道），
# 真实的 [[ -t 1 ]] 会是假 —— 必须把这个 I/O 缝打开，否则测不到序列。
# （该缝是**退出码式**：return 0 = stdout 是 tty；若写成 printf 'yes'，
#  命令替换重定向 stdout 会让 [[ -t 1 ]] 永远为假 —— 实测踩过。）
# panel_is_tty（stdin 缝）同样 stub，因为测试用文件喂 stdin。
read -r -d '' SNIP_SEQ_MAIN <<'CODE' || true
panel_is_tty() { printf 'yes\n'; }
_panel_probe_stdout_tty() { _PANEL_OUT_TTY=yes; return 0; }
machines_view_json() { cat "${HF_VIEW_FILE}"; }
panel_render() { printf 'RENDER\n'; }
panel_main
CODE

# _seq_assert_pair <msg>：断言四类序列各只一次，且上/下屏与隐/显光标成对出现
_seq_assert_pair() {
  local msg="${1:-}"
  local n_on="" n_off="" n_hide="" n_show=""
  n_on="$(_nseq "${SEQ_ALT_ON}" "${out}")"
  n_off="$(_nseq "${SEQ_ALT_OFF}" "${out}")"
  n_hide="$(_nseq "${SEQ_CUR_HIDE}" "${out}")"
  n_show="$(_nseq "${SEQ_CUR_SHOW}" "${out}")"
  t_eq "1" "${n_on}" "${msg}：上屏只发一次"
  t_eq "1" "${n_off}" "${msg}：下屏只发一次"
  t_eq "1" "${n_hide}" "${msg}：隐藏光标只发一次"
  t_eq "1" "${n_show}" "${msg}：显示光标只发一次"
  _assert_order "${SEQ_ALT_ON}" "${SEQ_ALT_OFF}" "${out}" "${msg}：上屏在下屏之前（配对）"
  _assert_order "${SEQ_CUR_HIDE}" "${SEQ_CUR_SHOW}" "${out}" "${msg}：隐藏光标在显示光标之前（配对）"
}

t_it "panel_main 进入时发上屏序列；退出时（EOF）发下屏序列，且成对"
stage
_pl_run /dev/null "${SNIP_SEQ_MAIN}"
t_exit_ok 0 "${rc}" "EOF 退出 0"
t_contains "${SEQ_ALT_ON}" "${out}" "进入备用屏（\\033[?1049h）"
t_contains "${SEQ_CUR_HIDE}" "${out}" "隐藏光标（\\033[?25l）"
t_contains "${SEQ_SAVE}" "${out}" "保存光标（\\033[22;0;0t）"
t_contains "${SEQ_CUR_SHOW}" "${out}" "恢复光标可见（\\033[?25h）"
t_contains "${SEQ_RESTORE}" "${out}" "恢复光标（\\033[23;0;0t）"
t_contains "${SEQ_ALT_OFF}" "${out}" "退出备用屏（\\033[?1049l）"
_seq_assert_pair "EOF 路径"

# 上屏必须先于第一帧渲染（否则第一帧会画在旧屏上）。
t_it "上屏序列先于第一帧渲染（不先画后切屏）"
stage
_pl_run /dev/null "${SNIP_SEQ_MAIN}"
_assert_order "${SEQ_ALT_ON}" "RENDER" "${out}" "备用屏先于首帧"
_assert_order "${SEQ_SAVE}" "RENDER" "${out}" "保存光标先于首帧"
_assert_order "${SEQ_CUR_HIDE}" "RENDER" "${out}" "隐藏光标先于首帧"

# x 退出（quit 路径）也必须恢复终端。
t_it "x 退出路径也恢复终端（quit 与 EOF 同样经 trap EXIT）"
stage
printf 'x' >"${WORK}/in-x-seq"
_pl_run "${WORK}/in-x-seq" "${SNIP_SEQ_MAIN}"
t_exit_ok 0 "${rc}" "x 退出 0"
_seq_assert_pair "x 退出路径"

# 异常（set -e 下的非零退出）也必须经 trap EXIT 恢复。
t_it "异常退出（内部 die）也恢复终端（trap EXIT 覆盖所有 return 路径）"
stage
read -r -d '' SNIP_SEQ_DIE <<'CODE' || true
panel_is_tty() { printf 'yes\n'; }
_panel_probe_stdout_tty() { _PANEL_OUT_TTY=yes; return 0; }
machines_view_json() { cat "${HF_VIEW_FILE}"; }
panel_render() { printf 'RENDER\n'; exit 3; }
panel_main
CODE
set +o errexit
_pl_run /dev/null "${SNIP_SEQ_DIE}"
set -o errexit
t_exit_ok 3 "${rc}" "panel_render 里的 exit 3 透传"
t_contains "${SEQ_ALT_OFF}" "${out}" "异常退出也退出备用屏"
t_contains "${SEQ_CUR_SHOW}" "${out}" "异常退出也恢复光标"
_assert_nseq 1 "${SEQ_ALT_OFF}" "${out}" "异常路径下屏不重复"

# 非 TTY：一个控制序列都不许发（现有契约：管道/文件拿到的仍是纯文本）。
t_it "非 TTY（stdin 非终端）时不发任何终端序列（现有契约）"
stage
read -r -d '' SNIP_SEQ_NOTTY <<'CODE' || true
panel_is_tty() { return 0; }
_panel_probe_stdout_tty() { _PANEL_OUT_TTY=yes; return 0; }
set +o errexit
panel_main
_mrc=$?
set -o errexit
printf 'MAIN-RC=%s\n' "${_mrc}"
CODE
_pl_run /dev/null "${SNIP_SEQ_NOTTY}"
t_exit_ok 0 "${rc}" "非 TTY 不报错"
t_contains "MAIN-RC=1" "${out}" "panel_main 返回 1（cmd_watch 退化信号）"
_assert_absent "${SEQ_ALT_ON}" "${out}" "非 TTY 不发上屏"
_assert_absent "${SEQ_ALT_OFF}" "${out}" "非 TTY 不发下屏"
_assert_absent "${SEQ_CUR_HIDE}" "${out}" "非 TTY 不发隐藏光标"
_assert_absent "${SEQ_CUR_SHOW}" "${out}" "非 TTY 不发显示光标"

# stdout 非终端（管道）时也不发序列：否则重定向到文件会写进一堆控制字符。
t_it "stdout 非终端时不发任何终端序列（重定向/管道契约）"
stage
read -r -d '' SNIP_SEQ_OUTPIPE <<'CODE' || true
panel_is_tty() { printf 'yes\n'; }
machines_view_json() { cat "${HF_VIEW_FILE}"; }
panel_render() { printf 'RENDER\n'; }
panel_main
CODE
_pl_run /dev/null "${SNIP_SEQ_OUTPIPE}"
t_exit_ok 0 "${rc}" "exit 0"
t_contains "RENDER" "${out}" "仍正常渲染"
_assert_absent "${SEQ_ALT_ON}" "${out}" "stdout 非 tty 不发上屏"
_assert_absent "${SEQ_ALT_OFF}" "${out}" "stdout 非 tty 不发下屏"

# 无 TERM 也不能挂（本机 TERM 未设时 tput 会直接失败 rc=2）。
t_it "TERM 未设时不挂：上/下屏与清屏均正常（纯 printf 不依赖 terminfo）"
stage
read -r -d '' SNIP_SEQ_NOTERM <<'CODE' || true
panel_is_tty() { printf 'yes\n'; }
_panel_probe_stdout_tty() { _PANEL_OUT_TTY=yes; return 0; }
machines_view_json() { cat "${HF_VIEW_FILE}"; }
panel_render() { printf 'RENDER\n'; }
panel_main
CODE
printf '%s\n' "${SNIP_SEQ_NOTERM}" >"${WORK}/noterm-code.sh"
printf 'x' >"${WORK}/in-x-noterm"
set +o errexit
out="$(env -u TERM HERDR_PLUGIN_STATE_DIR="${STATE_DIR}" HERDR_PLUGIN_ROOT="${PLUGIN_ROOT}" \
  HERDR_BIN_PATH="${FAKE_BIN}/herdr" HF_VIEW_FILE="${VIEW_3}" HF_TPUT_LOG="${tput_log}" \
  PANEL_REFRESH_S=1 PATH="${FAKE_BIN}:${PATH}" \
  timeout 20 bash "${HARNESS}" "${PLUGIN_ROOT}" "${WORK}/noterm-code.sh" <"${WORK}/in-x-noterm" 2>/dev/null)"
rc=$?
set -o errexit
t_exit_ok 0 "${rc}" "TERM 未设仍 exit 0（不挂、不崩）"
t_contains "RENDER" "${out}" "TERM 未设仍能渲染"
t_contains "${SEQ_ALT_ON}" "${out}" "TERM 未设仍发上屏（ANSI 不依赖 terminfo）"
t_contains "${SEQ_ALT_OFF}" "${out}" "TERM 未设仍发下屏"
_seq_assert_pair "TERM 未设"

t_describe "lib/panel.sh：_panel_clear 与帧缓冲（Bug 1 抖动修复）"

# _panel_clear 的核心修复：不再每帧 fork tput（两帧/3s = 每秒 2 个进程）。
# 行为断言的关键：单测里 stdout 不是 tty（被 _cap 捕获），所以必须用 stdout-tty 缝
# （_panel_probe_stdout_tty）把清屏分支打开；否则 _panel_clear 直接 return，测了个寂寞。
t_it "_panel_clear 用纯 printf（stdout 是 tty 时零 tput fork）"
stage
: >"${tput_log}"
read -r -d '' SNIP_CLEAR_TTY <<'CODE' || true
_panel_probe_stdout_tty() { _PANEL_OUT_TTY=yes; return 0; }
_panel_clear
CODE
_pl_run /dev/null "${SNIP_CLEAR_TTY}"
t_exit_ok 0 "${rc}" "_panel_clear exit 0"
if [[ -s "${tput_log}" ]]; then
  _tlog="$(tr '\n' ';' <"${tput_log}")"
  t_fail_note "_panel_clear 仍 fork tput（tput.log: ${_tlog}）"
else
  t_pass "_panel_clear 不再 fork tput（零子进程）"
fi
t_contains "${SEQ_HOME}" "${out}" "清屏发光标 home（\\033[H）"
assert_clear_sequence

# 行为断言：PATH 里完全没有 tput（也没有 TERM）时，清屏仍必须工作（ANSI 不靠 terminfo）。
t_it "PATH 无 tput（且无 TERM）时仍正常清屏（行为级）"
stage
# 构造「除 tput 外都有」的 PATH：逐项 symlink /usr/bin，跳过 tput / busybox。
# 比手写白名单稳健（common.sh 会用到哪些命令不由本测试锁定）。
mkdir -p "${WORK}/no-tput-bin"
rm -f "${WORK}/no-tput-bin"/*
for _bin in /usr/bin/* /bin/*; do
  [[ -e "${_bin}" ]] || continue
  _base="$(basename "${_bin}")"
  [[ "${_base}" == "tput" ]] && continue
  ln -sf "${_bin}" "${WORK}/no-tput-bin/${_base}" 2>/dev/null || true
done
printf '%s\n' "${SNIP_CLEAR_TTY}" >"${WORK}/clear-code.sh"
set +o errexit
out="$(env -u TERM HERDR_PLUGIN_STATE_DIR="${STATE_DIR}" HERDR_PLUGIN_ROOT="${PLUGIN_ROOT}" \
  PATH="${WORK}/no-tput-bin" \
  timeout 20 bash "${HARNESS}" "${PLUGIN_ROOT}" "${WORK}/clear-code.sh" 2>/dev/null)"
rc=$?
set -o errexit
if [[ -x "${WORK}/no-tput-bin/tput" ]]; then
  t_fail_note "no-tput-bin 里居然有 tput（用例前提被破坏）"
else
  t_pass "测试 PATH 里确实没有 tput"
fi
t_exit_ok 0 "${rc}" "无 tput 的 PATH 下 exit 0（不挂）"
t_contains "${SEQ_HOME}" "${out}" "无 tput 也发了清屏序列"
assert_clear_sequence

# 帧缓冲（双缓冲思想）：整帧在变量里拼好、单次输出，避免行间输出与清屏交错
t_it "panel_render 整帧单次输出（_panel_flush 只调一次）"
stage
VIEW_FRAME="${WORK}/view-frame.json"
printf '%s\n' '[{"id":"m1","label":"aa","target":"t@h:22","enabled":true,"state":"inactive"},{"id":"m2","label":"bb","target":"t2@h:22","enabled":true,"state":"active"}]' >"${VIEW_FRAME}"
read -r -d '' SNIP_FRAME <<'CODE' || true
machines_view_json() { cat "${HF_VIEW_FILE}"; }
flush_count=0
note_count=0
_panel_flush() { flush_count=$((flush_count + 1)); printf '%s' "${PANEL_FRAME}"; }
_panel_note() { note_count=$((note_count + 1)); printf '%s\n' "$*"; }
panel_render
printf 'FLUSH=%s\n' "${flush_count}"
printf 'NOTE=%s\n' "${note_count}"
CODE
HF_VIEW_FILE="${VIEW_FRAME}"
_pl_run /dev/null "${SNIP_FRAME}"
t_exit_ok 0 "${rc}" "panel_render exit 0"
t_contains "FLUSH=1" "${out}" "整帧只 flush 一次（不是逐行输出）"
t_contains "NOTE=0" "${out}" "panel_render 不直接调 _panel_note（无行间 I/O 交错）"
t_contains "FORWARDS" "${out}" "帧内容完整（forwards 段）"
t_contains "MACHINES (2)" "${out}" "帧内容完整（machines 段）"
t_contains "[ ] 1. aa" "${out}" "帧内容完整（未激活行）"
t_contains "[✓] 2. bb" "${out}" "帧内容完整（active 行）"

# 实时状态行（_panel_note）必须仍立即落屏：SSH 探测最长 15s，不能等到帧刷完才显示。
t_it "_panel_note 仍直接落屏（探测中占位不能等帧 flush）"
stage
read -r -d '' SNIP_NOTE <<'CODE' || true
_panel_note "LIVE-LINE"
CODE
_pl_run /dev/null "${SNIP_NOTE}"
t_exit_ok 0 "${rc}" "exit 0"
t_contains "LIVE-LINE" "${out}" "_panel_note 立即输出（不经帧缓冲）"

t_describe "cmd_watch：TTY 分流（非 TTY 退化为旧 watch，E2E 兼容）"

t_it "stdin 非 TTY → exec watch -n 3 forward list（现有行为不变）"
stage
_cap /dev/null env HERDR_PLUGIN_STATE_DIR="${STATE_DIR}" PATH="${FAKE_BIN}:${PATH}" \
  bash "${PLUGIN_ROOT}/bin/forward" watch
t_exit_ok 0 "${rc}" "退出 0"
t_contains "FAKE-WATCH" "${out}" "走的是 watch(1)（非面板）"
t_contains "-n 3" "${out}" "刷新间隔 3s 不变"
t_contains "list" "${out}" "watch 的目标是 forward list"
_assert_absent "FORWARDS" "${out}" "非 TTY 不渲染面板"

t_it "stdin 非 TTY 且 lib/panel.sh 缺失 → 仍退化为旧 watch（松散耦合，不报错）"
rm -f "${PLUGIN_ROOT}/lib/panel.sh"
_cap /dev/null env HERDR_PLUGIN_STATE_DIR="${STATE_DIR}" PATH="${FAKE_BIN}:${PATH}" \
  bash "${PLUGIN_ROOT}/bin/forward" watch
t_exit_ok 0 "${rc}" "退出 0"
t_contains "FAKE-WATCH" "${out}" "面板模块缺失不影响 watch"

t_describe "cmd_watch：真实 pty 冒烟（单键确认 + 激活链路；无 script(1) 则显式 SKIP）"

# 为什么要真 pty：单测里 panel_confirm 被 stub，而「终端下读一行会等回车」这类 UX
# 坑只在真 tty 里出现（本用例就是为它加的回归闸门）。绝不真跑 ssh：
# fake forward 把 `machines` 子命令拦住只打标记，其余转发给真 CLI。
t_it "pty：数字 → 无需回车的单键确认 → 「探测中…」→ CLI 子进程 → x 退出"
if ! command -v script >/dev/null 2>&1; then
  t_skip "script(1) 不可用，无法构造真实 pty"
else
  stage
  # 真 CLI 拷为 forward-real，bin/forward 抹成 wrapper：只拦截 `machines` 子命令
  # （打标记后 exit 0，绝不真跑 ssh），其余原样转发给真 CLI。
  cp "${PLUGIN_ROOT}/bin/forward" "${PLUGIN_ROOT}/bin/forward-real"
  chmod +x "${PLUGIN_ROOT}/bin/forward-real"
  cat >"${PLUGIN_ROOT}/bin/forward" <<'EOF'
#!/usr/bin/env bash
if [[ "${1-}" == "machines" ]]; then
  printf 'PROBE %s\n' "$*"
  exit 0
fi
exec "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/forward-real" "$@"
EOF
  chmod +x "${PLUGIN_ROOT}/bin/forward"

  # 面板在这里（无 M2 模块）降级读 activated-machines.json —— 它就是一个真实数据源，
  # 顺带把「M2 未合入时的降级路径」也过一遍真 pty。
  cat >"${STATE_DIR}/activated-machines.json" <<'EOF'
{"version":1,"active":"m1","machines":{"m1":{"label":"test-probe","ssh_target":"user@b-host:22","server_root":"/srv/b/plugins/x","state_dir":"/srv/b/state"},"m2":{"label":"gpu-box","ssh_target":"u@g:22","server_root":"/srv/g/plugins/x","state_dir":"/srv/g/state"}}}
EOF
  pty_out="${WORK}/pty.out"
  # 按键流一次性从 stdin 灌入（**不用 sleep 分段**）：分段时管道 writer 会先于
  # script(1) 退出，pty 宿主拿 EOF 的时机不确定（实测 rc=141 / 丢帧）。
  # 一次性写入 + script 内重定向后，交互顺序完全由面板的 read 循环决定。
  printf '2yx' >"${WORK}/pty-keys"
  set +o errexit
  HERDR_PLUGIN_STATE_DIR="${STATE_DIR}" HERDR_PLUGIN_ROOT="${PLUGIN_ROOT}" \
    PANEL_REFRESH_S=2 \
    timeout 40 script -qec "${PLUGIN_ROOT}/bin/forward watch; echo PANEL-EXIT=\$?" /dev/null \
    <"${WORK}/pty-keys" >"${pty_out}" 2>&1
  pty_rc=$?
  set -o errexit

  plain=""
  # 剥 ANSI / CR，得到人可读的交互轨迹（含 `?` 形式的 DEC 私有序列）
  plain="$(sed $'s/\x1b\\[[0-9;?]*[a-zA-Z]//g; s/\r//' "${pty_out}" 2>/dev/null || true)"
  # 为什么真 pty（而不是继续 stub）：单测里 panel_confirm / panel_render 都被替换，
  # 而「终端下 line-read 会等回车」这类 UX 坑只在真 tty 里出现（本用例就是它的闸门）。
  t_contains "继续? [y/N]" "${plain}" "面板用真 pty 渲染并弹出确认提示"
  t_contains "MACHINES (2)" "${plain}" "面板渲染出 machines 列表（降级数据源）"
  t_contains "PROBE machines activate" "${plain}" "确认后真调 CLI（machines activate <id>）"
  t_contains "探测中" "${plain}" "先落占位行再跑子进程"
  t_contains "PANEL-EXIT=0" "${plain}" "x 正常退出，panel_main 返回 0"
  if [[ "${pty_rc}" -eq 0 ]]; then
    t_pass "pty 会话退出 0（无挂死、无 timeout 杀）"
  else
    t_fail_note "pty 会话非零退出（rc=${pty_rc}）；见 ${pty_out}"
  fi

  # --- 真 pty 下的终端序列审计（Bug 1 的核心闸门） ---
  # 这是整个修复最直接的证据：在**真实终端**里，上/下屏、光标隐藏各只能发生一次。
  _raw="$(cat "${pty_out}")"
  # _assert_cnt <expected> <needle> <msg>：在**未剥 ANSI 的原始 pty 输出**里数出现次数
  # （内部赋值，避免 SC2312）
  _assert_cnt() {
    local n=""
    n="$(_nseq "${2-}" "${_raw}")"
    t_eq "${1-}" "${n}" "${3-}"
  }
  _assert_cnt 1 "${SEQ_ALT_ON}" "pty: 进入备用屏恰好一次"
  _assert_cnt 1 "${SEQ_ALT_OFF}" "pty: 退出备用屏恰好一次（会话结束已恢复）"
  _assert_cnt 1 "${SEQ_CUR_HIDE}" "pty: 隐藏光标恰好一次"
  _assert_cnt 1 "${SEQ_CUR_SHOW}" "pty: 显示光标恰好一次"
  _assert_order "${SEQ_ALT_ON}" "${SEQ_ALT_OFF}" "${_raw}" "pty: 上屏在下屏之前"
  _assert_order "${SEQ_CUR_HIDE}" "${SEQ_CUR_SHOW}" "${_raw}" "pty: 隐藏光标在显示光标之前"

  # 闪烁滥用审计：每帧只允许 `\033[H` + 一个抹除序列，
  # 不得出现「裸 \033[2J（无 home）」「\033[K 擦行」「\033[?25 以外の光标控制」。
  _home_clr="${SEQ_HOME}${SEQ_CLR}"
  _home_erase="${SEQ_HOME}${SEQ_ERASE_TAIL}"
  _n_clr="$(_nseq "${SEQ_CLR}" "${_raw}")"
  _n_home_clr="$(_nseq "${_home_clr}" "${_raw}")"
  _n_home_erase="$(_nseq "${_home_erase}" "${_raw}")"
  _n_home="$(_nseq "${SEQ_HOME}" "${_raw}")"
  if [[ "${_n_clr}" == "$((_n_home_clr + _n_home_erase))" ]]; then
    t_pass "pty: 无裸 \\033[2J（每次抹除都紧跟 home：home+2J 或 home+J）"
  else
    t_fail_note "pty: 抹除序列与 home 不配对（2J=${_n_clr} home+2J=${_n_home_clr} home+J=${_n_home_erase}）"
  fi
  if [[ "${_n_home}" -ge 1 && "${_n_home}" == "${_n_clr}" ]]; then
    t_pass "pty: home 与抹除一一对应（每帧一次，无多余重绘）"
  else
    t_fail_note "pty: home 与抹除数量不等（home=${_n_home} 抹除=${_n_clr}）"
  fi
  if [[ "${_raw}" == *"$(printf '\033[K')"* ]]; then
    t_fail_note "pty: 出现 \\033[K 擦行（属闪烁滥用，应全屏重绘）"
  else
    t_pass "pty: 无 \\033[K 擦行序列"
  fi
  # 除 \033[?25l/h 与 \033[?1049h/l 外，不得有别的 DEC 私有模式切换
  _other_decs="$(printf '%s' "${_raw}" | grep -o -E $'\x1b\\[\?[0-9]+[hl]' 2>/dev/null | grep -v -E '\?25[hl]|\?1049[hl]' || true)"
  if [[ -z "${_other_decs}" ]]; then
    t_pass "pty: 无其他 DEC 私有模式切换（不滥用闪烁序列）"
  else
    _other_shown="$(printf '%s' "${_other_decs}" | tr '\n' ';')"
    t_fail_note "pty: 出现意外 DEC 序列（${_other_shown}）"
  fi
fi

t_done
