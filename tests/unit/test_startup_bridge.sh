#!/usr/bin/env bash
# tests/unit/test_startup_bridge.sh — startup hook 拉起桥接（ARCHITECTURE §A.3.3）
#
# A 的 herdr server 每次启动都跑 [[startup]]：若 active 是远端机器，hook 要执行
# `bin/forward bridge up <id>`（后台、幂等）。本机 / 无 active / dry-run / B 侧（无激活
# 记录）一律不碰桥接；bridge up 失败也恒 exit 0。
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
source "${ROOT}/tests/lib/assertions.sh"

unset HERDR_SOCKET_PATH HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_BIN_PATH HERDR_ENV

WORK="$(mktemp -d "${TMPDIR:-/tmp}/startup-bridge.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT
PLUGIN="${WORK}/plugin"
STATE="${WORK}/state"
CONFIG="${WORK}/config.toml"
CALLS="${WORK}/calls"
mkdir -p "${PLUGIN}/bin" "${PLUGIN}/lib" "${PLUGIN}/scripts" "${STATE}" "${WORK}/home"
for f in startup-hook install-tabbar install-keys; do
  cp "${ROOT}/scripts/${f}.sh" "${PLUGIN}/scripts/${f}.sh"
done
for f in common state machines bridge; do
  cp "${ROOT}/lib/${f}.sh" "${PLUGIN}/lib/${f}.sh"
done
# 假 bin/forward：只记录 hook 调用了什么（tab bar 命令里也引用它，但 hook 不执行 tab bar）
cat >"${PLUGIN}/bin/forward" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"${CALLS}"
[ "\${HF_FAIL_BRIDGE:-}" = 1 ] && exit 3
echo "桥接已启动（pid=4242）。"
EOF
chmod +x "${PLUGIN}/bin/forward"

out=""
err=""
rc=0

write_activation() {
  local active="${1-}"
  local target="${2-}"
  if [[ -z ${active} ]]; then
    rm -f "${STATE}/activated-machines.json"
    return 0
  fi
  jq -n --arg a "${active}" --arg t "${target}" '
    {version: 1, active: $a,
     machines: {($a): {label: "dev-box", ssh_target: $t,
                       server_root: "/home/dev/plugin", state_dir: "/home/dev/state", local: false}}}
  ' >"${STATE}/activated-machines.json"
}

hook() {
  : >"${CALLS}"
  printf 'theme = "dark"\n' >"${CONFIG}"
  run env HOME="${WORK}/home" HERDR_PLUGIN_STATE_DIR="${STATE}" \
    bash "${PLUGIN}/scripts/startup-hook.sh" --config "${CONFIG}" "$@"
}

bridge_calls() {
  grep -c '^bridge up' "${CALLS}" || true
}

t_describe "startup hook × 桥接"

t_it "active 是远端机器 → bridge up <id>"
write_activation m-dev dev@b-host
hook
t_exit_ok 0 "${rc}" "exit 0"
n="$(bridge_calls)"
t_eq "1" "${n}" "调用一次"
line="$(grep '^bridge up' "${CALLS}" || true)"
t_eq "bridge up m-dev" "${line}" "参数是 active 的 id"

t_it "bridge up 失败 → 仍 exit 0（startup 不阻塞 server）"
HF_FAIL_BRIDGE=1 hook
t_exit_ok 0 "${rc}" "exit 0"
t_contains "桥接未能启动" "${err}" "给出提示"

t_it "active 是本机 → 不碰桥接"
write_activation m-self localhost
hook
n="$(bridge_calls)"
t_eq "0" "${n}" "未调用"

t_it "没有 active（B 侧的常态）→ 不碰桥接"
write_activation "" ""
hook
n="$(bridge_calls)"
t_eq "0" "${n}" "未调用"

t_it "--dry-run → 不碰桥接"
write_activation m-dev dev@b-host
hook --dry-run
n="$(bridge_calls)"
t_eq "0" "${n}" "未调用"

t_describe "startup hook × 自动 reload-config（写过 config 后让 server 立刻广播新键位）"

# 假 herdr：只记录 hook 调用了什么
RELOADS="${WORK}/reloads"
cat >"${WORK}/fake-herdr" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"${RELOADS}"
EOF
chmod +x "${WORK}/fake-herdr"
write_activation "" ""

# as_plugin <hook args...>：模拟 herdr 以插件身份拉起（注入 HERDR_PLUGIN_ID / HERDR_BIN_PATH），不重置 config
as_plugin() {
  run env HOME="${WORK}/home" HERDR_PLUGIN_STATE_DIR="${STATE}" \
    HERDR_PLUGIN_ID=zzjcool:forward HERDR_BIN_PATH="${WORK}/fake-herdr" \
    bash "${PLUGIN}/scripts/startup-hook.sh" --config "${CONFIG}" "$@"
}
reload_calls() {
  grep -c '^server reload-config$' "${RELOADS}" 2>/dev/null || true
}

t_it "首次写入键位与 tab bar → 自动 reload-config 一次，并告诉用户可以直接用"
: >"${RELOADS}"
printf 'theme = "dark"\n' >"${CONFIG}"
as_plugin
t_exit_ok 0 "${rc}" "exit 0"
n="$(reload_calls)"
t_eq "1" "${n}" "reload-config 调用一次"
t_contains "已自动重载" "${out}" "提示已自动重载"

t_it "再次启动（config 已是最新）→ 不重载"
: >"${RELOADS}"
as_plugin
n="$(reload_calls)"
t_eq "0" "${n}" "未调用"

t_it "不是由 herdr 以插件身份拉起（无 HERDR_PLUGIN_ID）→ 不重载用户的真实 server"
: >"${RELOADS}"
printf 'theme = "dark"\n' >"${CONFIG}"
run env HOME="${WORK}/home" HERDR_PLUGIN_STATE_DIR="${STATE}" HERDR_BIN_PATH="${WORK}/fake-herdr" \
  bash "${PLUGIN}/scripts/startup-hook.sh" --config "${CONFIG}"
n="$(reload_calls)"
t_eq "0" "${n}" "未调用"

t_it "--dry-run → 不重载"
: >"${RELOADS}"
printf 'theme = "dark"\n' >"${CONFIG}"
as_plugin --dry-run
n="$(reload_calls)"
t_eq "0" "${n}" "未调用"

t_done
