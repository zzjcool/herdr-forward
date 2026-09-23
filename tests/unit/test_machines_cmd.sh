#!/usr/bin/env bash
# tests/unit/test_machines_cmd.sh — `forward machines ...` 子命令契约单测（plan §2.3 / §3）
#
# 覆盖：列表三种输出（表格 / --json / --short）/ activate 同机短路（**不调 ssh**，shim 里
#       埋 exit 99 断言未触发）/ activate 远端 present（写记录 + tab bar command 指向 B 路径
#       + install-keys 真跑）/ absent -> die 4 且 stderr 含可复制安装命令 / no-herdr 与
#       unreachable -> die 4 + 排查清单 / 未知 id -> die 3 / deactivate 恢复本机路径 /
#       deactivate all / doctor（stale 重写、unreachable 只报告）/ 幂等（重复 activate 不重复条目）。
#
# 手法：
#   * HERDR_BIN_PATH 指向 TMP 里的假 herdr shim（输出固定 JSON，事实 #1 schema）。
#   * ssh 也用 PATH 前置的假 shim：本测试**绝不真连主机**。但 activate 走的是 lib/machines.sh
#     的 machines_ssh_probe_plugin，它委托给 M1 的 ssh_probe_plugin —— 我们用
#     `ssh_probe_plugin` 的假函数（通过 lib/ssh-probe.sh 注入点）四态回放，不需要真 ssh。
#     ssh shim 仍装一份并在里面 `exit 99`：如果代码路径真的 fork 了 ssh，测试会立刻暴露。
#   * install-tabbar.sh / install-keys.sh 用**真安装器** + 临时 config（$HERDR_CONFIG_PATH），
#     这样才能断言「config 里的 command 真的指向 B」而不只是「函数被调用过」。
#   * 状态目录与 HOME 全在 TMP；绝不触碰真实 ~/.config/herdr。
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if [[ -f "${ROOT}/tests/lib/assertions.sh" ]]; then
  # shellcheck source=/dev/null
  source "${ROOT}/tests/lib/assertions.sh"
fi
if ! declare -F t_fail_note >/dev/null 2>&1; then
  t_fail_note() { t_fail "$@"; }
fi

if [[ ! -f "${ROOT}/lib/machines.sh" ]]; then
  printf 'RED: %s 尚未实现\n' "${ROOT}/lib/machines.sh" >&2
  exit 1
fi
if ! grep -q 'cmd_machines' "${ROOT}/bin/forward"; then
  printf 'RED: bin/forward 尚未接入 machines 子命令\n' >&2
  exit 1
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/machines-cmd.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT

# --- 隔离环境：HOME / XDG / state / config 全在 WORK，绝不碰真实 herdr 配置 ---
PLUGIN_ROOT="${WORK}/plugin"
STATE_DIR="${WORK}/state"
mkdir -p "${PLUGIN_ROOT}/bin" "${PLUGIN_ROOT}/lib" "${PLUGIN_ROOT}/scripts" \
  "${STATE_DIR}" "${WORK}/home" "${WORK}/bin" "${WORK}/config"
cp "${ROOT}/bin/forward" "${PLUGIN_ROOT}/bin/forward"
chmod +x "${PLUGIN_ROOT}/bin/forward"
for f in common state machines; do
  cp "${ROOT}/lib/${f}.sh" "${PLUGIN_ROOT}/lib/${f}.sh"
done
# 真安装器（断言 config 真的被改写，而不只是「函数被调用」）
cp "${ROOT}/scripts/install-tabbar.sh" "${PLUGIN_ROOT}/scripts/install-tabbar.sh"
cp "${ROOT}/scripts/install-keys.sh" "${PLUGIN_ROOT}/scripts/install-keys.sh"
chmod +x "${PLUGIN_ROOT}/scripts/"*.sh

export HERDR_PLUGIN_STATE_DIR="${STATE_DIR}"
export HERDR_PLUGIN_CONFIG_DIR="${WORK}/config"
export HERDR_CONFIG_PATH="${WORK}/home/.config/herdr/config.toml"
export HOME="${WORK}/home"
mkdir -p "$(dirname "${HERDR_CONFIG_PATH}")"

FW="${PLUGIN_ROOT}/bin/forward"
STATE_FILE="${STATE_DIR}/activated-machines.json"
B_ROOT="/home/remote-user/.config/herdr/plugins/github/zzjcool-forward-ab12cd34"
B_STATE="/home/remote-user/.local/state/herdr/plugins/zzjcool%3Aforward"

out=""
err=""
rc=0

_cap() {
  rc=0
  out="$("$@" 2>"${WORK}/stderr")" || rc=$?
  err="$(cat "${WORK}/stderr" 2>/dev/null || true)"
  return 0
}

# _fw <args...>：在隔离 env 下跑 CLI
_fw() { _cap "${FW}" "$@"; }

# --- 假 herdr：machine list --json ---
_fake_herdr() {
  local payload="${1-}"
  cat >"${WORK}/bin/herdr" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "machine" && "\$2" == "list" ]]; then
  cat <<'JSONEOF'
${payload}
JSONEOF
  exit 0
fi
exit 127
EOF
  chmod +x "${WORK}/bin/herdr"
  export HERDR_BIN_PATH="${WORK}/bin/herdr"
}

STD_MACHINES='[{"id":"m-probe","label":"test-probe","target":"user@b-host:22","session":"default","enabled":true,"selected":false},{"id":"m-local","label":"this-host","target":"127.0.0.1","session":"default","enabled":true,"selected":false},{"id":"m-gpu","label":"gpu-box","target":"ubuntu@gpu.example.com:2222","session":"default","enabled":true,"selected":false}]'

# --- 假 ssh：任何真调用都是测试缺陷（activate 应走 ssh_probe_plugin 函数注入点）---
cat >"${WORK}/bin/ssh" <<'EOF'
#!/usr/bin/env bash
echo "TEST-ERROR: 本测试不应真连主机（ssh 被调用：$*）" >&2
exit 99
EOF
chmod +x "${WORK}/bin/ssh"
export PATH="${WORK}/bin:${PATH}"

# --- 探测四态注入：写一份 lib/ssh-probe.sh 假实现（M1 的冻结签名）---
# _inject_probe <status> [root] [state] [reason]
_inject_probe() {
  local status="${1-}"
  local root="${2-}"
  local state="${3-}"
  local reason="${4-}"
  cat >"${PLUGIN_ROOT}/lib/ssh-probe.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
ssh_probe_plugin() {
  printf 'HF_STATUS=%s\n' '${status}'
  [[ -n '${root}' ]] && printf 'HF_ROOT=%s\n' '${root}'
  [[ -n '${state}' ]] && printf 'HF_STATE_DIR=%s\n' '${state}'
  [[ -n '${reason}' ]] && printf 'HF_REASON=%s\n' '${reason}'
  return 0
}
EOF
}

# --- tab bar 检查助手（与 test_startup_hook.sh 同构，python3 tomllib）---
tabbar_count() {
  python3 - "$1" <<'PY'
import sys, tomllib, os
if not os.path.exists(sys.argv[1]):
    print(0); raise SystemExit(0)
try:
    with open(sys.argv[1], "rb") as fh:
        doc = tomllib.load(fh)
except Exception:
    print(0); raise SystemExit(0)
print(sum(1 for e in ((doc.get("ui") or {}).get("tab_bar_right") or [])
          if isinstance(e, dict) and "bin/forward" in str(e.get("command", ""))))
PY
}

tabbar_command() {
  python3 - "$1" <<'PY' 2>/dev/null || true
import sys, tomllib, os
try:
    with open(sys.argv[1], "rb") as fh:
        doc = tomllib.load(fh)
    for e in ((doc.get("ui") or {}).get("tab_bar_right") or []):
        if isinstance(e, dict) and "bin/forward" in str(e.get("command", "")):
            print(e["command"]); break
except Exception:
    print("")
PY
}

keys_count() {
  python3 - "$1" <<'PY'
import sys, tomllib, os
if not os.path.exists(sys.argv[1]):
    print(0); raise SystemExit(0)
try:
    with open(sys.argv[1], "rb") as fh:
        doc = tomllib.load(fh)
except Exception:
    print(0); raise SystemExit(0)
print(len((doc.get("keys") or {}).get("command") or []))
PY
}

# _clean_config：删掉 config，保证「本机/远端路径」断言从干净态开始
_clean_config() {
  rm -f "${HERDR_CONFIG_PATH}" "${HERDR_CONFIG_PATH}".bak.* 2>/dev/null || true
}

# _reset_state
_reset_state() {
  rm -rf "${STATE_DIR}"
  mkdir -p "${STATE_DIR}"
  _clean_config
}

# --- 断言取值 helper：一律「先算进 v 再断言」---
# 为什么不用 `t_eq "期望" "$(cmd ...)"`：SC2312（命令替换掩藏返回值）在 -S style 下是
# 告警级，CI 不允许新增抑制；先落变量既过 lint 也更容易定位失败。
v=""

# _jo <jq-filter>：对 ${out} 求值落 v
_jo() {
  v="$(printf '%s' "${out}" | jq -r "${1-"."}" 2>/dev/null || true)"
  return 0
}

# _jf <file> <jq-filter>：对文件求值落 v
_jf() {
  v="$(jq -r "${2-"."}" "${1-}" 2>/dev/null || true)"
  return 0
}

# _tb <file>：该 config 里本插件的 tab_bar_right command 落 v（显式传路径，避免歧义）
_tb() {
  v="$(tabbar_command "${1}")"
  return 0
}

# _tbn <file>：该 config 里本插件的 tab_bar_right 条目数落 v
_tbn() {
  v="$(tabbar_count "${1}")"
  return 0
}

# _kcn <file>：该 config 里的 [[keys.command]] 条数落 v
_kcn() {
  v="$(keys_count "${1}")"
  return 0
}

# _md5 <file>：文件 md5 落 v（不存在时空串）
_md5() {
  if [[ -f "${1-}" ]]; then
    v="$(md5sum "${1}" | awk '{print $1}')"
  else
    v=""
  fi
  return 0
}

# ---------------------------------------------------------------------------
t_describe "forward machines（dispatch + usage）"

t_it "无子命令 / 未知子命令 -> exit 64"
_reset_state
_fake_herdr "${STD_MACHINES}"
_fw machines
t_exit_ok 64 "${rc}" "无子命令 -> 64"
t_contains "list" "${err}" "提示可用子命令"
_fw machines definitely-not-a-subcommand
t_exit_ok 64 "${rc}" "未知子命令 -> 64"

t_it "machines --help -> exit 0 并列出四个子命令"
_fw machines --help
t_exit_ok 0 "${rc}" "--help -> 0"
for c in list activate deactivate doctor; do
  t_contains "${c}" "${out}" "帮助含 ${c}"
done

t_it "顶层 --help 列出 machines 子命令组"
_fw --help
t_contains "machines" "${out}" "help 含 machines"

t_it "list 未知参数 -> 64；list 位置参数 -> 64"
_fw machines list --nope
t_exit_ok 64 "${rc}" "未知参数 -> 64"
_fw machines list extra
t_exit_ok 64 "${rc}" "位置参数 -> 64"

# ---------------------------------------------------------------------------
t_describe "machines list（表格 / --json / --short）"

t_it "表格输出含 label/target 与三态标记图例"
_reset_state
_fake_herdr "${STD_MACHINES}"
_fw machines list
t_exit_ok 0 "${rc}" "list rc"
t_contains "test-probe" "${out}" "含 label"
t_contains "user@b-host:22" "${out}" "含 target"
t_contains "[✓ local]" "${out}" "同机标记"
t_contains "[ ]" "${out}" "未激活标记"

t_it "--json 输出 machines_view_json（数组，含 state 字段）"
_fw machines list --json
t_exit_ok 0 "${rc}" "--json rc"
_jo 'type'
t_eq "array" "${v}" "顶层数组"
_jo 'length'
t_eq "3" "${v}" "三台"
_jo '.[] | select(.id=="m-local") | .state'
t_eq "local" "${v}" "同机 state=local"

t_it "--short 每机器一行、tab 分隔、首列是标记（面板消费契约）"
_fw machines list --short
t_exit_ok 0 "${rc}" "--short rc"
v="$(printf '%s\n' "${out}" | grep -c . || true)"
t_eq "3" "${v}" "三行"
t_match $'^\\[ \\]\tm-probe\ttest-probe\tuser@b-host:22\tinactive\t' "${out}" "未激活行格式"

t_it "HERDR_BIN_PATH 缺失：表格给出原因，exit 0（不 die —— 面板要能退化）"
_reset_state
_cap env -u HERDR_BIN_PATH "${FW}" machines list
t_exit_ok 0 "${rc}" "不 die"
t_contains "没有可用的 saved machines" "${out}" "说明空的原因"

t_it "HERDR_BIN_PATH 缺失：--json 输出 []"
_cap env -u HERDR_BIN_PATH "${FW}" machines list --json
t_eq "[]" "${out}" "空数组"

# ---------------------------------------------------------------------------
t_describe "machines activate（同机短路 / present / absent / no-herdr / unreachable）"

t_it "未知 id/label -> die 3 且列出可用机器"
_reset_state
_fake_herdr "${STD_MACHINES}"
_inject_probe present "${B_ROOT}" "${B_STATE}"
_fw machines activate definitely-nope
t_exit_ok 3 "${rc}" "die 3"
t_contains "test-probe" "${err}" "列出可用 machine"
t_file_absent "${STATE_FILE}" "未写激活记录"

t_it "同机（localhost/127.0.0.1）：短路激活，**不发起 SSH**（ssh shim exit 99 未触发）"
_reset_state
_fw machines activate this-host
t_exit_ok 0 "${rc}" "activate rc"
t_contains "同机" "${out}" "明示同机短路"
t_isnt "99" "${rc}" "未调用 ssh shim"
t_file_exists "${STATE_FILE}" "写了激活记录"
_jf "${STATE_FILE}" '.active'
t_eq "m-local" "${v}" "active=m-local"
_jf "${STATE_FILE}" '.machines["m-local"].local'
t_eq "true" "${v}" "记录标记 local=true"
_jf "${STATE_FILE}" '.machines["m-local"].server_root'
t_eq "${PLUGIN_ROOT}" "${v}" "server_root=本机插件根"
_jf "${STATE_FILE}" '.machines["m-local"].state_dir'
t_eq "${STATE_DIR}" "${v}" "state_dir=本机 state"
t_file_absent "${HERDR_CONFIG_PATH}" "同机短路不改 config"

t_it "activate 也接受 label（大小写不敏感）"
_reset_state
_fw machines activate TEST-PROBE
t_exit_ok 0 "${rc}" "label activate rc"
_jf "${STATE_FILE}" '.active'
t_eq "m-probe" "${v}" "解析到 m-probe"

t_it "远端 present：写记录（B 的路径）+ tab bar command 指向 B 的 root 与 state"
_reset_state
_inject_probe present "${B_ROOT}" "${B_STATE}"
_fw machines activate test-probe
t_exit_ok 0 "${rc}" "activate rc"
t_contains "探测" "${out}" "明示探测"
_jf "${STATE_FILE}" '.active'
t_eq "m-probe" "${v}" "active=m-probe"
_jf "${STATE_FILE}" '.machines["m-probe"].server_root'
t_eq "${B_ROOT}" "${v}" "记录 server_root=B"
_jf "${STATE_FILE}" '.machines["m-probe"].state_dir'
t_eq "${B_STATE}" "${v}" "记录 state_dir=B"
_jf "${STATE_FILE}" '.machines["m-probe"].local'
t_eq "false" "${v}" "记录 local=false"
t_file_exists "${HERDR_CONFIG_PATH}" "config 已生成"
_tbn "${HERDR_CONFIG_PATH}"
t_eq "1" "${v}" "tab bar 恰一条"
_tb "${HERDR_CONFIG_PATH}"
t_contains "${B_ROOT}/bin/forward" "${v}" "command 指向 B 的插件根"
t_contains "${B_STATE}" "${v}" "command 带 B 的 state 目录"
t_contains "reload" "${out}" "打印 reload 提示"

t_it "present 但 HF_ROOT 为空 -> die 4（不写记录，避免写入假路径）"
_reset_state
_inject_probe present "" "${B_STATE}"
_fw machines activate test-probe
t_exit_ok 4 "${rc}" "die 4"
t_contains "插件根" "${err}" "说明缺插件根"
t_file_absent "${STATE_FILE}" "未写记录"

t_it "远端 absent：die 4 + stderr 含可复制安装命令，不写记录"
_reset_state
_inject_probe absent
_fw machines activate test-probe
t_exit_ok 4 "${rc}" "absent -> die 4"
t_contains "absent" "${err}" "标出 absent"
t_contains "ssh user@b-host:22 'herdr plugin install zzjcool/herdr-forward --yes'" "${err}" "给出安装命令"
t_file_absent "${STATE_FILE}" "未写记录"
t_file_absent "${HERDR_CONFIG_PATH}" "未改 config"

t_it "远端 no-herdr：die 4 + 排查清单（PATH 提示）"
_reset_state
_inject_probe no-herdr "" "" "远端非交互 shell 里找不到 herdr（PATH 未含 ~/.local/bin？）"
_fw machines activate test-probe
t_exit_ok 4 "${rc}" "no-herdr -> die 4"
t_contains "no-herdr" "${err}" "标出 no-herdr"
t_contains "BatchMode" "${err}" "给排查命令"
t_file_absent "${STATE_FILE}" "未写记录"

t_it "远端 unreachable：die 4 + 原因 + 排查清单（VPN/ssh config）"
_reset_state
_inject_probe unreachable "" "" "ssh: connect to host b-host port 22: Connection refused"
_fw machines activate test-probe
t_exit_ok 4 "${rc}" "unreachable -> die 4"
t_contains "unreachable" "${err}" "标出 unreachable"
t_contains "Connection refused" "${err}" "透传 HF_REASON"
t_contains "VPN" "${err}" "给排查清单"
t_file_absent "${STATE_FILE}" "未写记录"
t_file_absent "${HERDR_CONFIG_PATH}" "未改 config"

t_it "M1 未合入（无 lib/ssh-probe.sh）时：unreachable 降级，不假装 present"
_reset_state
rm -f "${PLUGIN_ROOT}/lib/ssh-probe.sh"
_fw machines activate test-probe
t_exit_ok 4 "${rc}" "降级 -> die 4"
t_contains "unreachable" "${err}" "标出 unreachable"
t_contains "ssh-probe" "${err}" "说明缺探测模块（M1 交付）"
t_file_absent "${STATE_FILE}" "未写记录"

t_it "activate 缺参数 -> 64"
_reset_state
_fw machines activate
t_exit_ok 64 "${rc}" "缺参数 -> 64"

# ---------------------------------------------------------------------------
t_describe "machines activate 幂等 / install-keys"

t_it "重复 activate 同一台：记录覆盖，tab bar 不重复插入（幂等）"
_reset_state
_inject_probe present "${B_ROOT}" "${B_STATE}"
_fw machines activate test-probe
t_exit_ok 0 "${rc}" "第一次 activate"
FIRST_CMD="$(tabbar_command "${HERDR_CONFIG_PATH}")"
_fw machines activate test-probe
t_exit_ok 0 "${rc}" "第二次 activate"
_tbn "${HERDR_CONFIG_PATH}"
t_eq "1" "${v}" "tab bar 仍只一条（未重复插入）"
_tb "${HERDR_CONFIG_PATH}"
t_eq "${FIRST_CMD}" "${v}" "command 未变"
_jf "${STATE_FILE}" '.machines | length'
t_eq "1" "${v}" "记录仍只有一条"

t_it "activate 也安装了键位（真安装器 + 真 config）"
_kcn "${HERDR_CONFIG_PATH}"
t_eq "3" "${v}" "三条 [[keys.command]]"

t_it "重复 activate 不重复键位"
_fw machines activate test-probe
_kcn "${HERDR_CONFIG_PATH}"
t_eq "3" "${v}" "键位仍三条"

t_it "远端路径漂移：重新 activate 就地重写 tab bar command（不新增条目）"
_reset_state
_inject_probe present "${B_ROOT}" "${B_STATE}"
_fw machines activate test-probe
NEW_ROOT="/home/remote-user/.config/herdr/plugins/github/zzjcool-forward-ffffffff"
NEW_STATE="/home/remote-user/.local/state/herdr/plugins/zzjcool%3Aforward"
_inject_probe present "${NEW_ROOT}" "${NEW_STATE}"
_fw machines activate test-probe
t_exit_ok 0 "${rc}" "重激活 rc"
_tbn "${HERDR_CONFIG_PATH}"
t_eq "1" "${v}" "仍只一条"
_tb_new="$(tabbar_command "${HERDR_CONFIG_PATH}")"
t_contains "${NEW_ROOT}/bin/forward" "${_tb_new}" "command 已指向新 root"
t_contains "${NEW_STATE}" "${_tb_new}" "command 已指向新 state"
_jf "${STATE_FILE}" '.machines["m-probe"].server_root'
t_eq "${NEW_ROOT}" "${v}" "记录已更新"

t_it "--config 覆盖：写进指定的 config 文件而非 HERDR_CONFIG_PATH"
_reset_state
_inject_probe present "${B_ROOT}" "${B_STATE}"
OTHER_CFG="${WORK}/other/herdr/config.toml"
_fw machines activate test-probe --config "${OTHER_CFG}"
t_exit_ok 0 "${rc}" "activate --config rc"
t_file_exists "${OTHER_CFG}" "写到了 --config 指定的文件"
_tbn "${OTHER_CFG}"
t_eq "1" "${v}" "该文件里有条目"
t_file_absent "${HERDR_CONFIG_PATH}" "HERDR_CONFIG_PATH 未被触碰"

# ---------------------------------------------------------------------------
t_describe "machines deactivate"

t_it "deactivate <当前 active>：清 active、记录保留为历史、tab bar 恢复本机路径"
_reset_state
_inject_probe present "${B_ROOT}" "${B_STATE}"
_fw machines activate test-probe
_tb "${HERDR_CONFIG_PATH}"
t_contains "${B_ROOT}" "${v}" "先切到 B"
_fw machines deactivate m-probe
t_exit_ok 0 "${rc}" "deactivate rc"
_jf "${STATE_FILE}" '.active'
t_eq "null" "${v}" "active 清空"
_jf "${STATE_FILE}" '.machines | length'
t_eq "1" "${v}" "记录保留（历史）"
_tb_back="$(tabbar_command "${HERDR_CONFIG_PATH}")"
t_contains "${PLUGIN_ROOT}/bin/forward" "${_tb_back}" "tab bar 恢复本机路径"
t_isnt "$(printf '%s' "${_tb_back}" | grep -c "${B_ROOT}" || true)" "1" "不再指向 B"
_tbn "${HERDR_CONFIG_PATH}"
t_eq "1" "${v}" "仍只一条（就地重写）"

t_it "deactivate <非当前 active>：只删该条历史记录，tab bar 不动"
_reset_state
_inject_probe present "${B_ROOT}" "${B_STATE}"
_fw machines activate test-probe
_fw machines activate gpu-box
tb_before="$(tabbar_command "${HERDR_CONFIG_PATH}")"
_fw machines deactivate test-probe
t_exit_ok 0 "${rc}" "deactivate 非 active rc"
_jf "${STATE_FILE}" '.machines["m-probe"]'
t_eq "null" "${v}" "该条记录已删"
_jf "${STATE_FILE}" '.active'
t_eq "m-gpu" "${v}" "active 未变"
_jf "${STATE_FILE}" '.active'
t_contains "m-gpu" "${v}" "仍是 gpu"
_tb "${HERDR_CONFIG_PATH}"
t_eq "${tb_before}" "${v}" "tab bar 未改"

t_it "deactivate 未知 id -> die 3"
_fw machines deactivate definitely-nope
t_exit_ok 3 "${rc}" "die 3"

t_it "deactivate <未激活但有记录> 之外：不存在的记录 -> die 3（不静默成功）"
_reset_state
_fw machines deactivate test-probe
t_exit_ok 3 "${rc}" "无记录 -> die 3"

t_it "deactivate all：清 active + 删全部记录 + 恢复本机路径"
_reset_state
_inject_probe present "${B_ROOT}" "${B_STATE}"
_fw machines activate test-probe
_fw machines activate gpu-box
_fw machines deactivate all
t_exit_ok 0 "${rc}" "deactivate all rc"
_jf "${STATE_FILE}" '.active'
t_eq "null" "${v}" "active null"
_jf "${STATE_FILE}" '.machines | length'
t_eq "0" "${v}" "记录全清"
_tb "${HERDR_CONFIG_PATH}"
t_contains "${PLUGIN_ROOT}/bin/forward" "${v}" "tab bar 恢复本机"

t_it "deactivate 缺参数 -> 64"
_fw machines deactivate
t_exit_ok 64 "${rc}" "缺参数 -> 64"

# ---------------------------------------------------------------------------
t_describe "machines doctor"

t_it "无 active：exit 0 且提示无需检查（不探测）"
_reset_state
_inject_probe unreachable
_fw machines doctor
t_exit_ok 0 "${rc}" "无 active rc"
t_contains "没有处于激活状态" "${out}" "说明无需检查"

t_it "active 且远端路径未变：报告无需修复，config 不变"
_reset_state
_inject_probe present "${B_ROOT}" "${B_STATE}"
_fw machines activate test-probe
tb_before="$(tabbar_command "${HERDR_CONFIG_PATH}")"
_fw machines doctor
t_exit_ok 0 "${rc}" "doctor rc"
t_contains "无需修复" "${out}" "报告一致"
_tb "${HERDR_CONFIG_PATH}"
t_eq "${tb_before}" "${v}" "config 未变"

t_it "active 且远端路径漂移：重写记录 + 重写 tab bar"
_reset_state
OLD_ROOT="/home/remote-user/.config/herdr/plugins/github/zzjcool-forward-old"
OLD_STATE="/home/remote-user/.local/state/herdr/plugins/zzjcool%3Aforward"
_inject_probe present "${OLD_ROOT}" "${OLD_STATE}"
_fw machines activate test-probe
NEW_ROOT="/home/remote-user/.config/herdr/plugins/github/zzjcool-forward-new"
NEW_STATE="/home/remote-user/.local/state/herdr/plugins/zzjcool%3Aforward-new"
_inject_probe present "${NEW_ROOT}" "${NEW_STATE}"
_fw machines doctor
t_exit_ok 0 "${rc}" "doctor rc"
t_contains "stale" "${out}" "报告 stale"
_jf "${STATE_FILE}" '.machines["m-probe"].server_root'
t_eq "${NEW_ROOT}" "${v}" "记录已重写"
_tb "${HERDR_CONFIG_PATH}"
t_contains "${NEW_ROOT}/bin/forward" "${v}" "tab bar 已重写"
_tbn "${HERDR_CONFIG_PATH}"
t_eq "1" "${v}" "仍只一条"

t_it "active 但远端 unreachable：只报告 stale，**不动** config 与记录"
_reset_state
_inject_probe present "${B_ROOT}" "${B_STATE}"
_fw machines activate test-probe
tb_before="$(tabbar_command "${HERDR_CONFIG_PATH}")"
md5_before="$(md5sum "${HERDR_CONFIG_PATH}" | awk '{print $1}')"
_inject_probe unreachable "" "" "Connection timed out"
_fw machines doctor
t_exit_ok 4 "${rc}" "doctor unreachable -> die 4"
t_contains "unreachable" "${err}" "报告 unreachable"
t_contains "保持原样" "${out}${err}" "明示未改动"
_tb "${HERDR_CONFIG_PATH}"
t_eq "${tb_before}" "${v}" "tab bar 未变"
_md5 "${HERDR_CONFIG_PATH}"
t_eq "${md5_before}" "${v}" "config 文件字节未变"
_jf "${STATE_FILE}" '.machines["m-probe"].server_root'
t_eq "${B_ROOT}" "${v}" "记录未变"

t_it "active 但远端 absent（插件被卸载）：die 4 且不动 config/记录"
_reset_state
_inject_probe present "${B_ROOT}" "${B_STATE}"
_fw machines activate test-probe
md5_before="$(md5sum "${HERDR_CONFIG_PATH}" | awk '{print $1}')"
_inject_probe absent
_fw machines doctor
t_exit_ok 4 "${rc}" "doctor absent -> die 4"
t_contains "absent" "${err}" "报告 absent"
_md5 "${HERDR_CONFIG_PATH}"
t_eq "${md5_before}" "${v}" "config 字节未变"
_jf "${STATE_FILE}" '.machines["m-probe"].server_root'
t_eq "${B_ROOT}" "${v}" "记录未变"

t_it "同机 active 且记录路径与当前检出一致：报告一致"
_reset_state
_fw machines activate this-host
_fw machines doctor
t_exit_ok 0 "${rc}" "同机 doctor rc"
t_contains "一致" "${out}" "报告一致"

t_it "doctor 未知参数 -> 64；位置参数 -> 64"
_reset_state
_fw machines doctor --nope
t_exit_ok 64 "${rc}" "未知参数 -> 64"
_fw machines doctor extra
t_exit_ok 64 "${rc}" "位置参数 -> 64"

# ---------------------------------------------------------------------------
t_describe "既有子命令零回归"

t_it "add / list / remove / doctor / publish / unpublish / help 仍可调度（machines 未破坏 dispatch）"
_reset_state
_fake_herdr "${STD_MACHINES}"
_fw add 3301:9443 --ssh-target "u@host:22"
t_exit_ok 0 "${rc}" "add rc"
_fw list --json
t_exit_ok 0 "${rc}" "list rc"
_jo '.forwards[0].local_port'
t_eq "3301" "${v}" "list 仍读 forwards.json"
_fw list --oneline
t_exit_ok 0 "${rc}" "list --oneline rc"
_fw remove f-3301
t_exit_ok 0 "${rc}" "remove rc"
_fw publish
t_exit_ok 9 "${rc}" "publish 仍 9"
_fw unpublish
t_exit_ok 9 "${rc}" "unpublish 仍 9"
_fw definitely-not-a-subcommand
t_exit_ok 64 "${rc}" "未知子命令仍 64"
_fw --help
t_exit_ok 0 "${rc}" "help 仍 0"

t_it "machines 段不引入新的硬依赖（render.sh / tunnel.sh 缺失时 list 仍可用）"
t_file_absent "${PLUGIN_ROOT}/lib/render.sh" "测试环境无 render.sh（走内置降级）"
t_file_absent "${PLUGIN_ROOT}/lib/tunnel.sh" "测试环境无 tunnel.sh（add 走松散耦合降级）"
_fw add 3302:9443 --ssh-target "u@host:22"
t_exit_ok 0 "${rc}" "无 tunnel.sh 时 add 仍 rc=0（松散耦合）"
# 无 tunnel 模块时 add 记 status=down（oneline 只显示 up）；手工置 up 以驱动内置降级渲染
jq -c '( .forwards[] | select(.id == "f-3302") | .status ) = "up"' \
  "${STATE_DIR}/forwards.json" >"${WORK}/fw.tmp"
mv "${WORK}/fw.tmp" "${STATE_DIR}/forwards.json"
_fw list --oneline
t_exit_ok 0 "${rc}" "无 render.sh 仍 rc=0"
t_contains "⇅3302" "${out}" "内置降级输出"
_fw list --json
t_exit_ok 0 "${rc}" "list --json 仍 rc=0"
_fw machines list --json
t_exit_ok 0 "${rc}" "machines list --json 仍 rc=0（两个状态文件互不干扰）"
_jo '[.[] | select(.state == "active")] | length'
t_eq "0" "${v}" "machines 视图无 active"

t_done
