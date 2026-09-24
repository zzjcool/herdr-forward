#!/usr/bin/env bash
# scripts/e2e/run-real-install.sh — 从 GitHub 真实安装 / 升级插件后，在真 herdr TUI 里按 prefix+f
#
# 为什么需要（真实用户反馈）：往**正在运行**的 herdr 里安装 / 升级插件后按 prefix+f 没反应。
# 容器 E2E 不出网，只能用 plugin link 模拟；这里走真正的 `herdr plugin install`（git clone +
# [[build]] + 注册），在本机隔离的 HOME 里起 herdr server 与 TUI client（tmux 充当虚拟终端），
# 键位照搬真实用户：prefix = ctrl+space、reload = prefix+q、detach = prefix+d。
#
#   场景 1（升级，用户当时的状态）：装旧版 6381736 → server 启动（旧 startup hook 写键位）
#     → prefix+q 重载 → prefix+f 打开旧面板 → herdr 不停，`herdr plugin install` 升级
#     → prefix+f 打开的是新面板（无 saved machine 时给出 machine add 引导）→ Enter 不关面板
#   场景 2（全新用户）：herdr 已在运行、未装插件 → prefix+q → `herdr plugin install`
#     → 不重启、不手动重载，prefix+f 直接打开面板
#
# 出网 = opt-in（ARCHITECTURE §C.6）：需要 HERDR_E2E_ONLINE=1；HERDR_FORWARD_E2E_REF 指定
# 要装的分支（默认仓库默认分支）。绝不碰用户真实的 herdr：独立 HOME/XDG、清空 HERDR_*、
# 独立 tmux socket，结束时停掉隔离 server 并删除临时目录。
set -Eeuo pipefail

unset HERDR_SOCKET_PATH HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_BIN_PATH HERDR_ENV HERDR_PLUGIN_ID || true

PROJ="$(cd "$(dirname "$0")/../.." && pwd)"
REPO="${HERDR_FORWARD_E2E_REPO:-zzjcool/herdr-forward}"
REF="${HERDR_FORWARD_E2E_REF:-}"
OLD_SHA="6381736234e5caba1dbf042b60e24a716d0a88c4"
HERDR="${HERDR_FORWARD_E2E_HERDR:-/usr/bin/herdr}"

if [[ ${HERDR_E2E_ONLINE:-0} != 1 ]]; then
  echo "run-real-install: 需要出网（从 GitHub 安装），默认不跑；HERDR_E2E_ONLINE=1 显式开启" >&2
  exit 127
fi
for tool in tmux git jq python3; do
  command -v "${tool}" >/dev/null 2>&1 || {
    echo "run-real-install: 缺少 ${tool}" >&2
    exit 127
  }
done
[[ -x ${HERDR} ]] || {
  echo "run-real-install: 找不到 herdr（${HERDR}）" >&2
  exit 127
}

# shellcheck source=/dev/null
source "${PROJ}/tests/lib/assertions.sh"
rc=0
WAITED_RC=1

ROOTS=()
cleanup() {
  local code=$?
  set +e
  local r=""
  for r in "${ROOTS[@]}"; do
    iso_env "${r}" tmux -L "$(basename "${r}")" kill-server >/dev/null 2>&1
    iso_env "${r}" "${HERDR}" server stop >/dev/null 2>&1
  done
  sleep 1
  for r in "${ROOTS[@]}"; do
    pkill -f -- "${r}/" >/dev/null 2>&1
    rm -rf "${r}"
  done
  return "${code}"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# iso_env <root> <cmd...>：在隔离的 HOME 里执行（herdr 的 socket / config / state 全在 root 下）
iso_env() {
  local root="$1"
  shift
  env -u HERDR_SOCKET_PATH -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
    -u HERDR_BIN_PATH -u HERDR_ENV -u HERDR_PLUGIN_ID -u TMUX -u TMUX_PANE \
    HOME="${root}/home" XDG_CONFIG_HOME="${root}/home/.config" XDG_STATE_HOME="${root}/home/.local/state" \
    LANG=C.UTF-8 LC_ALL=C.UTF-8 PATH="$(dirname "${HERDR}"):/usr/bin:/bin" "$@"
}

ROOT=""
new_root() {
  ROOT="$(mktemp -d "${TMPDIR:-/tmp}/hf-real-install.XXXXXX")"
  ROOTS+=("${ROOT}")
  mkdir -p "${ROOT}/home/.config/herdr" "${ROOT}/home/.local/state"
  printf '%s\n' 'onboarding = false' '' '[update]' 'version_check = false' 'manifest_check = false' '' \
    '[keys]' 'prefix = "ctrl+space"' 'reload_config = "prefix+q"' 'detach = "prefix+d"' \
    >"${ROOT}/home/.config/herdr/config.toml"
}
hh() { iso_env "${ROOT}" "${HERDR}" "$@"; }
tm() { iso_env "${ROOT}" tmux -L "$(basename "${ROOT}")" "$@"; }
start_server() {
  iso_env "${ROOT}" setsid "${HERDR}" server </dev/null >>"${ROOT}/server.out" 2>&1 &
  local i=0
  while ((i < 40)) && [[ ! -S "${ROOT}/home/.config/herdr/herdr.sock" ]]; do
    sleep 0.25
    i=$((i + 1))
  done
}
start_ui() {
  tm -f /dev/null new-session -d -s ui -x 160 -y 45 "${HERDR}"
  tm set -g prefix None
  tm set -g status off
  tm set -g escape-time 0
}
ui_screen() { tm capture-pane -p -t ui 2>/dev/null | sed 's/[[:space:]]*$//'; }
ui_keys() { tm send-keys -t ui "$@"; }
ui_prefix() { # prefix = ctrl+space（NUL）
  tm send-keys -t ui -H 00
  sleep 0.3
  ui_keys "$1"
}
ui_shows() {
  local screen=""
  screen="$(ui_screen)"
  [[ ${screen} =~ $1 ]] && printf 'yes\n'
  return 0
}
ui_hides() {
  local screen=""
  screen="$(ui_screen)"
  [[ ${screen} =~ $1 ]] || printf 'yes\n'
  return 0
}
panel_still_open() {
  sleep 1.5
  ui_shows 'herdr-forward · Port Forward'
}
# installed_sha -> stdout: registry 里记录的 resolved_commit（按分支安装时 plugin list 只显示分支名）
installed_sha() {
  jq -r '.[] | select(.plugin_id == "zzjcool:forward") | .source.resolved_commit // empty' \
    "${ROOT}/home/.config/herdr/plugins.json" 2>/dev/null || true
}
# postinstall_log -> stdout: build 步骤自己的日志（herdr 成功时不回显 build 的输出）
postinstall_log() {
  cat "${ROOT}/home/.local/state/herdr/plugins/zzjcool%3Aforward/logs/postinstall.log" 2>/dev/null || true
}
startup_hook_done() {
  local logs="" n=""
  set +o errexit
  logs="$(hh plugin log list --plugin zzjcool:forward 2>/dev/null)"
  set -o errexit
  n="$(printf '%s' "${logs}" | jq -r '[.result.logs[]? | select(.event == "startup" and .status != "running")] | length' 2>/dev/null || true)"
  [[ ${n} =~ ^[1-9] ]] && printf 'yes\n'
  return 0
}
wait_for() {
  local secs="${1}"
  shift
  local tries=$((secs * 2))
  local got=""
  WAITED_RC=1
  while ((tries > 0)); do
    got="$("$@" 2>/dev/null || true)"
    if [[ ${got} == "yes" ]]; then
      WAITED_RC=0
      return 0
    fi
    sleep 0.5
    tries=$((tries - 1))
  done
  return 0
}
install_new() {
  local -a ref_args=()
  if [[ -n ${REF} ]]; then
    ref_args=(--ref "${REF}")
  fi
  run iso_env "${ROOT}" timeout 300 "${HERDR}" plugin install "${REPO}" "${ref_args[@]}" --yes
}
check_new_panel() {
  ui_prefix f
  wait_for 10 ui_shows 'herdr-forward · Port Forward'
  t_exit_ok 0 "${WAITED_RC}" "prefix+f 打开 Port Forward 面板"
  wait_for 5 ui_shows 'MACHINES \(0\)  还没有 saved machine'
  t_exit_ok 0 "${WAITED_RC}" "新面板：还没有 saved machine 时给出 machine add 引导"
  local hint=""
  hint="$(ui_shows '未列出 saved machines')"
  t_eq "" "${hint}" "不再误报「machine list 可能失败」"
  ui_keys Enter
  wait_for 5 panel_still_open
  t_exit_ok 0 "${WAITED_RC}" "按 Enter 面板不会关"
  ui_keys x
  wait_for 5 ui_hides 'Port Forward'
  t_exit_ok 0 "${WAITED_RC}" "x 关闭面板"
}

# --- 场景 1：升级（用户当时的状态） ----------------------------------------------
t_describe "场景 1：旧版在用 → herdr 不停，直接 herdr plugin install 升级 → prefix+f"
new_root
run iso_env "${ROOT}" timeout 300 "${HERDR}" plugin install "${REPO}" --ref "${OLD_SHA}" --yes
t_exit_ok 0 "${rc}" "装旧版 ${OLD_SHA:0:7}"
start_server
wait_for 30 startup_hook_done
t_exit_ok 0 "${WAITED_RC}" "旧版 startup hook 跑完（写入键位）"
start_ui
wait_for 20 ui_shows '(spaces|machines) +│'
t_exit_ok 0 "${WAITED_RC}" "herdr 界面已打开"
ui_prefix q
sleep 1.5
ui_prefix f
wait_for 10 ui_shows 'herdr-forward · Port Forward'
t_exit_ok 0 "${WAITED_RC}" "基线：prefix+q 重载后，旧版的 prefix+f 能打开面板"
ui_keys x
wait_for 5 ui_hides 'Port Forward'
install_new
t_exit_ok 0 "${rc}" "herdr plugin install 升级（server 保持运行）"
sha="$(installed_sha)"
t_match '^[0-9a-f]{40}$' "${sha}" "registry 记录了新的 resolved_commit"
t_isnt "${OLD_SHA}" "${sha}" "已不是旧版（现在 @${sha:0:7}）"
log_text="$(postinstall_log)"
t_contains "keys already installed" "${log_text}" "升级时 build 步骤发现键位已在，不重复写"
check_new_panel

# --- 场景 2：全新用户 -------------------------------------------------------------
t_describe "场景 2：herdr 正在运行、未装插件 → herdr plugin install → prefix+f"
new_root
start_server
start_ui
wait_for 20 ui_shows '(spaces|machines) +│'
t_exit_ok 0 "${WAITED_RC}" "herdr 界面已打开（未装插件）"
ui_prefix q
sleep 1
install_new
t_exit_ok 0 "${rc}" "herdr plugin install 退出 0"
log_text="$(postinstall_log)"
t_contains "keys installed" "${log_text}" "安装的 build 步骤写入了键位"
t_contains "reloaded" "${log_text}" "并重载了正在运行的 herdr"
check_new_panel

t_done
