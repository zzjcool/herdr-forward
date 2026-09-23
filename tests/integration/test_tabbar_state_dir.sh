#!/usr/bin/env bash
# tests/integration/test_tabbar_state_dir.sh — 真实环境 bug #3 的端到端回归锚点。
#
# 背景（现场）：herdr 给插件注入 HERDR_PLUGIN_STATE_DIR=
#   ~/.local/state/herdr/plugins/zzjcool%3Aforward
# 插件 action / Port Forward 面板就在那里写 forwards.json。而 tab_bar_right 的
# command 由 herdr server 经 /bin/sh -lc 直接执行，**没有**该 env → bin/forward
# 回退到 ~/.local/state/herdr-forward → 两边状态文件分叉：
#   * 面板里 add 的转发，tab bar 永远看不到；
#   * tab bar 读的那个目录永远是空的 → 状态条形同虚设。
#
# 本文件用**真 bin/forward**（不是 stub）走完整链路：
#   1. 在「插件 state 目录」写一条 up 记录（= 面板/action 的写入结果）
#   2. install-tabbar.sh 生成条目（--state-dir 指向同一个目录）
#   3. 用 env -i /bin/sh -lc 执行生成的 command（= tab bar 的真实执行上下文）
#   4. 断言输出 ⇅<port>（修好前这里必为空）
#   5. 反证：worker-7 形态（绝对路径、无 env 前缀）在同一上下文里输出为空
#
# 隔离：config 与 state 全落在 TMPDIR，绝不碰真实 ~/.config/herdr 与真实
# ~/.local/state/herdr（含 % 的目录名只出现在 TMPDIR 下）。
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [[ -f "${ROOT}/tests/lib/assertions.sh" ]]; then
  # shellcheck source=/dev/null
  source "${ROOT}/tests/lib/assertions.sh"
fi
if ! declare -F t_fail_note >/dev/null 2>&1; then
  t_fail_note() { t_fail "$@"; }
fi

# 断言库在部分环境（T0 未合并）缺 t_skip；本文件只在 docker/bwrap 外跑，用不上它。
if ! declare -F t_skip >/dev/null 2>&1; then
  t_skip() { printf '# skip: %s\n' "${1:-}"; }
fi

INSTALLER="${ROOT}/scripts/install-tabbar.sh"
CLI="${ROOT}/bin/forward"
for f in "${INSTALLER}" "${CLI}"; do
  if [[ ! -f "${f}" ]]; then
    echo "RED: 缺少 ${f}" >&2
    exit 1
  fi
done

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# 与 herdr 真实布局同构：state 目录名 = <XDG_STATE_HOME>/herdr/plugins/<id 的 URL 编码>
PLUGIN_STATE_DIR="${WORK}/xdg-state/herdr/plugins/zzjcool%3Aforward"
mkdir -p "${PLUGIN_STATE_DIR}"
CONFIG="${WORK}/config.toml"
cat >"${CONFIG}" <<'EOF'
theme = "dark"

[ui]
tab_bar_position = "top"
tab_bar_right = [
  { type = "hostname" },
]
EOF

# command_of <toml> -> 本插件的 tab_bar_right command（无则空）
command_of() {
  python3 - "$1" <<'PY' 2>/dev/null || true
import sys, tomllib
try:
    with open(sys.argv[1], "rb") as fh:
        doc = tomllib.load(fh)
    for e in ((doc.get("ui") or {}).get("tab_bar_right") or []):
        if isinstance(e, dict) and "bin/forward" in str(e.get("command", "")):
            print(e["command"])
            break
except Exception:
    print("")
PY
}

# run_tabbar_command <command> -> stdout（模拟 herdr 的执行上下文：env -i + sh -lc）
run_tabbar_command() {
  env -i PATH=/usr/bin:/bin HOME="${WORK}/home" /bin/sh -lc "$1" 2>"${WORK}/run-err" || true
}

t_describe "tab bar 与插件 action 共用同一个 state 目录（真实环境 bug #3）"

t_it "构造：面板侧写入一条 up 记录到插件 state 目录（= action 的写入结果）"
cat >"${PLUGIN_STATE_DIR}/forwards.json" <<'JSON'
{
  "version": 1,
  "forwards": [
    {
      "id": "f-3000",
      "local_port": 3000,
      "remote_host": "127.0.0.1",
      "remote_port": 3000,
      "machine": "gpu-box",
      "ssh_target": "user@gpu-box:22",
      "pid": 12345,
      "control_socket": "",
      "status": "up",
      "created_unix": 1790000000,
      "publish": { "pid": null, "url": null, "started_unix": null }
    }
  ]
}
JSON
t_file_exists "${PLUGIN_STATE_DIR}/forwards.json"

# 插件 action 的视角：HERDR_PLUGIN_STATE_DIR 指向该目录时 CLI 看得到映射
t_it "插件 action 视角：HERDR_PLUGIN_STATE_DIR=<该目录> 时 list --oneline 有输出"
action_view="$(HERDR_PLUGIN_STATE_DIR="${PLUGIN_STATE_DIR}" bash "${CLI}" list --oneline 2>/dev/null || true)"
t_eq "⇅3000" "${action_view}" "action 视角看到 ⇅3000"

# 无 env 的裸 CLI（= tab bar 修好前的状态）看不到 —— 这就是「分叉」本身
t_it "裸 CLI 视角（无 env）：回退目录里没有这条记录（分叉证据）"
bare_view="$(env -i PATH=/usr/bin:/bin HOME="${WORK}/home" /bin/sh -lc "\"${ROOT}/bin/forward\" list --oneline" 2>/dev/null || true)"
t_eq "" "${bare_view}" "无 env 时输出为空（读的是回退目录 ~/.local/state/herdr-forward）"

t_it "安装器写出的 command 带 state env 前缀，且指向插件 state 目录"
rc=0
env -u HERDR_PLUGIN_STATE_DIR XDG_STATE_HOME="${WORK}/xdg-state" \
  bash "${INSTALLER}" --config "${CONFIG}" --state-dir "${PLUGIN_STATE_DIR}" >/dev/null 2>"${WORK}/stderr" || rc=$?
t_exit_ok 0 "${rc}" "install-tabbar.sh 退出 0"
cmd="$(command_of "${CONFIG}")"
if [[ "${cmd}" == *"HERDR_PLUGIN_STATE_DIR='${PLUGIN_STATE_DIR}'"* ]]; then
  t_pass "command 含 env HERDR_PLUGIN_STATE_DIR='<插件 state 目录>' 前缀"
else
  t_fail_note "command 缺少正确的 state env 前缀：${cmd}"
fi

t_it "端到端：tab bar 执行上下文（env -i /bin/sh -lc）输出 ⇅3000"
tb_view="$(run_tabbar_command "${cmd}" | tail -1)"
t_eq "⇅3000" "${tb_view}" "tab bar 与面板看到同一份状态（本 bug 的正面断言）"
tb_all="$(run_tabbar_command "${cmd}")"
t_eq "⇅3000" "${tb_all##*$'\n'}" "取最后一行 = oneline 契约"

t_it "回归锚点：worker-7 形态（绝对路径、无 env 前缀）在同一上下文里输出为空"
legacy_cmd="\"${ROOT}/bin/forward\" list --oneline"
legacy_view="$(run_tabbar_command "${legacy_cmd}" | tail -1)"
t_eq "" "${legacy_view}" "无 env 前缀 → 状态条永远空（证明本修复必要）"

t_it "state 目录名里的 %3A 不破坏 sh 解析（无需转义，但不能被 shell 吃掉）"
if [[ "${PLUGIN_STATE_DIR}" == *"%3A"* ]]; then
  t_pass "测试用的 state 目录含 %3A（与真实布局一致）"
else
  t_fail_note "测试目录未包含 %3A，覆盖不到真实布局：${PLUGIN_STATE_DIR}"
fi
# 用一个只回显 env 的探针脚本穿过两层 sh（避开嵌套引号的 shellcheck 噪音）
# shellcheck disable=SC2016  # 单引号内就是探针脚本正文，$VAR 故意留给它自己展开
printf '#!/bin/sh\nprintf %%s "$HERDR_PLUGIN_STATE_DIR"\n' >"${WORK}/probe.sh"
chmod +x "${WORK}/probe.sh"
probe_state="$(env -i PATH=/usr/bin:/bin /bin/sh -lc "env HERDR_PLUGIN_STATE_DIR=${PLUGIN_STATE_DIR@Q} ${WORK}/probe.sh" 2>/dev/null || true)"
# ${VAR@Q} 是 bash 单引号引用；若外层 sh 不支持也不要紧：这里由 bash 先拼好字符串
t_eq "${PLUGIN_STATE_DIR}" "${probe_state}" "%3A 原样穿过两层 sh（未被 percent 展开）"

t_it "幂等：重跑安装器不重复插入、不改文件"
before="$(md5sum "${CONFIG}" | awk '{print $1}')"
rc=0
env -u HERDR_PLUGIN_STATE_DIR XDG_STATE_HOME="${WORK}/xdg-state" \
  bash "${INSTALLER}" --config "${CONFIG}" --state-dir "${PLUGIN_STATE_DIR}" >/dev/null 2>&1 || rc=$?
t_exit_ok 0 "${rc}" "重跑退出 0"
after="$(md5sum "${CONFIG}" | awk '{print $1}')"
t_eq "${before}" "${after}" "文件未变（幂等）"

t_done
