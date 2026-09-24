#!/usr/bin/env bash
# tests/unit/test_panel_bridge.sh — 面板的远程开发部分（ARCHITECTURE §A.3.3）
#
# 覆盖：有 client 在线时显示 CLIENT 行与 LISTENING 段（已映射端口不重复列出）/
#   client 映射在 FORWARDS 里带实时状态 / f<n>、d<n> 两键操作只 fork CLI 子命令 /
#   active 机器行显示桥接状态 / 没有 client 时这些段全部不出现（本机面板零变化）。
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
source "${ROOT}/tests/lib/assertions.sh"

unset HERDR_SOCKET_PATH HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_BIN_PATH HERDR_ENV

TMP="$(mktemp -d "${TMPDIR:-/tmp}/hf-panel-bridge.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT
export HERDR_PLUGIN_STATE_DIR="${TMP}/state"
mkdir -p "${HERDR_PLUGIN_STATE_DIR}"

# shellcheck source=/dev/null
source "${ROOT}/lib/common.sh"
# shellcheck source=/dev/null
source "${ROOT}/lib/state.sh"
# shellcheck source=/dev/null
source "${ROOT}/lib/bridge.sh"
# shellcheck source=/dev/null
source "${ROOT}/lib/panel.sh"

# 面板的外部数据源一律 stub（不跑 herdr / ss）
machines_view_json() { printf '%s\n' "${HF_MACHINES:-[]}"; }
ports_listening_json() {
  printf '%s\n' '[{"port":3000,"addr":"127.0.0.1","process":"node"},{"port":5173,"addr":"::","process":"vite"},{"port":8080,"addr":"0.0.0.0","process":""}]'
}

# 假 bin/forward：记录面板 fork 的子命令
export FORWARD_ROOT="${TMP}/plugin"
mkdir -p "${FORWARD_ROOT}/bin"
CALLS="${TMP}/calls"
cat >"${FORWARD_ROOT}/bin/forward" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"${CALLS}"
EOF
chmod +x "${FORWARD_ROOT}/bin/forward"

BD="$(bridge_dir)"
SESSION="${BD}/session-$$.json"
client_online() {
  local status="${1:-{\}}"
  local now=""
  now="$(date +%s)"
  printf '{"client_host":"laptop","client_label":"dev-box","last_seen_unix":%s,"status":%s}\n' "${now}" "${status}" >"${SESSION}"
}

out=""
# 在当前 shell 里渲染（不是 $(...) 子 shell）：面板记下的序号表是全局变量，
# 两键操作要读到它们 —— 与 panel_main 的真实调用方式一致。
render() {
  panel_render >"${TMP}/frame" 2>/dev/null
  out="$(<"${TMP}/frame")"
}
calls() {
  got_calls=""
  if [[ -f ${CALLS} ]]; then
    got_calls="$(<"${CALLS}")"
  fi
}
got_calls=""

t_describe "没有 client 连着：面板与之前一致"
render
t_isnt "" "${out}" "有输出"
if [[ ${out} == *"CLIENT"* || ${out} == *"LISTENING"* ]]; then
  t_fail "不应出现 CLIENT / LISTENING 段"
else
  t_pass "无 CLIENT / LISTENING 段"
fi
t_contains "--machine" "${out}" "空表提示仍是 tunnel 用法"

t_describe "有 client 连着：CLIENT 行 + LISTENING 段"
client_online
render
t_contains "CLIENT  laptop 已连接" "${out}" "CLIENT 行"
t_contains "LISTENING" "${out}" "LISTENING 段"
t_match 'f1  3000 +node' "${out}" "f1 = 3000"
t_match 'f2  5173 +vite' "${out}" "f2 = 5173"
t_match 'f3  8080 +-' "${out}" "f3 = 8080（无进程名）"
t_contains "f+序号 映射端口" "${out}" "按键帮助提到 f+序号"
t_contains "f+序号" "${out}" "空表提示改为映射到 client"

t_describe "已映射的端口不再出现在 LISTENING；client 映射带实时状态"
forward_add_record '{"local_port":15173,"remote_port":5173,"remote_host":"localhost","mode":"client"}'
client_online '{"f-15173":{"state":"up","reason":""}}'
render
t_match '1 +client:15173 +localhost:5173 +up +→ laptop 的 localhost' "${out}" "FORWARDS 行"
t_match 'f1  3000' "${out}" "3000 仍可映射"
t_match 'f2  8080' "${out}" "5173 已映射，不再列出"
t_contains "d+序号 删除映射" "${out}" "按键帮助提到 d+序号"

t_describe "f<n> / d<n> 只 fork CLI"
t_it "f 然后 2 → forward add 8080 --client"
: >"${CALLS}"
_panel_pick pick-forward <<<"2"
calls
t_eq "add 8080 --client" "${got_calls}" "子命令"
# shellcheck disable=SC2154 # PANEL_FLASH 由 lib/panel.sh 定义
t_contains "已映射本机 8080" "${PANEL_FLASH}" "下一帧显示结果"

t_it "d 然后 1 → forward remove f-15173"
: >"${CALLS}"
_panel_pick pick-remove <<<"1"
calls
t_eq "remove f-15173" "${got_calls}" "子命令"

t_it "序号越界 / 非数字 → 不执行"
: >"${CALLS}"
_panel_pick pick-forward <<<"9"
_panel_pick pick-remove <<<"x"
calls
t_eq "" "${got_calls}" "没有子命令"

t_it "按键映射"
run panel_handle_key f
t_eq "pick-forward" "${out}" "f"
run panel_handle_key d
t_eq "pick-remove" "${out}" "d"

t_describe "A 侧：active 机器行显示桥接状态"
rm -f "${SESSION}"
HF_MACHINES='[{"id":"m-dev","label":"dev-box","target":"dev@b-host","enabled":true,"state":"active"}]'
lock="$(bridge_client_lock m-dev)"
cfile="$(bridge_client_file m-dev)"
mkdir -p "${lock}"
printf '%s\n' "$$" >"${lock}/pid"
printf '{"pid":%s,"machine":"m-dev","label":"dev-box","target":"dev@b-host","state":"connected","reason":"","forwards":{"f-5173":{"spec":"5173 5173","state":"up","reason":""}}}\n' "$$" >"${cfile}"
render
line="$(printf '%s\n' "${out}" | grep -F 'dev-box' | grep -F '[✓]' || true)"
t_contains "tab bar" "${line}" "仍标注 tab bar"
t_contains "桥接已连接 · 1 个映射" "${line}" "桥接状态"
t_match '- +5173 +dev-box:5173 +up +经桥接' "${out}" "经桥接的映射列出但不编号"

t_done
