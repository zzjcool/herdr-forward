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

# 事实 #1 schema 的最小 machine list（fake herdr CLI 输出）
DEFAULT_MACHINES='[{"id":"m1","label":"test-probe","ssh_target":"user@b-host:22","enabled":true}]'

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
  # M2 合入后一并拷入（面板优先用真模块；未合入时走面板自带降级路径）
  if [[ -f "${ROOT}/lib/machines.sh" ]]; then
    cp "${ROOT}/lib/machines.sh" "${PLUGIN_ROOT}/lib/machines.sh"
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
  chmod +x "${FAKE_BIN}/watch" "${FAKE_BIN}/herdr" "${FAKE_BIN}/forward"
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
_pl_run() {
  local input="${1-}"
  local code="${2-}"
  local code_file="${WORK}/code.sh"
  printf '%s\n' "${code}" >"${code_file}"
  _cap "${input}" env \
    HERDR_PLUGIN_STATE_DIR="${STATE_DIR}" \
    HERDR_PLUGIN_ROOT="${PLUGIN_ROOT}" \
    HERDR_BIN_PATH="${FAKE_BIN}/herdr" \
    HF_FAKE_MACHINES="${HF_FAKE_MACHINES:-${DEFAULT_MACHINES}}" \
    HF_VIEW_FILE="${HF_VIEW_FILE:-}" \
    HF_KEY="${HF_KEY:-}" \
    PANEL_REFRESH_S=1 \
    PATH="${FAKE_BIN}:${PATH}" \
    timeout 20 bash "${HARNESS}" "${PLUGIN_ROOT}" "${code_file}"
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
_pl_run /dev/null "panel_render"
t_exit_ok 0 "${rc}" "缺文件 exit 0"
_assert_absent "test-probe" "${out}" "无机器行"

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
  # 剥 ANSI / CR，得到人可读的交互轨迹
  plain="$(sed 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/\r//' "${pty_out}" 2>/dev/null || true)"
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
fi

t_done
