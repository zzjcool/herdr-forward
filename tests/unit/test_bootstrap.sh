#!/usr/bin/env bash
# tests/unit/test_bootstrap.sh — OOTB：scripts/bootstrap.sh（一站式）
# 场景：一条命令同时装 tab bar + 键位 / 输出后续指引（reload-config + A/B 跨机说明）/
#       --dry-run 不落盘 / 幂等 / --skip-* / CLI 子命令 `forward bootstrap` 转发
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BOOTSTRAP="${ROOT}/scripts/bootstrap.sh"
CLI="${ROOT}/bin/forward"

if [[ -f "${ROOT}/tests/lib/assertions.sh" ]]; then
  # shellcheck source=/dev/null
  source "${ROOT}/tests/lib/assertions.sh"
fi
if ! declare -F t_fail_note >/dev/null 2>&1; then
  t_fail_note() { t_fail "$@"; }
fi

if [[ ! -x "${BOOTSTRAP}" ]]; then
  echo "RED: ${BOOTSTRAP} 不存在或不可执行（bootstrap 尚未实现）" >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

rc=0
out=""
err=""

run_bootstrap() {
  rc=0
  out="$(env -u HERDR_PLUGIN_STATE_DIR XDG_STATE_HOME="${WORK}/xdg-state" \
    bash "${BOOTSTRAP}" "$@" 2>"${WORK}/stderr")" || rc=$?
  err="$(cat "${WORK}/stderr")"
}

md5() { md5sum "$1" | awk '{print $1}'; }

# sh_squote / expected_cmd / cmd_part / state_dir_of / exe_path_of：与
# tests/unit/test_install_tabbar.sh 同构（防漂移靠这里的显式断言，而非共享 helper）。
sh_squote() {
  local value="${1-}" escaped=""
  escaped="${value//\'/\'\\\'\'}"
  printf "'%s'" "${escaped}"
}
# expected_cmd <plugin_root> <state_dir>
expected_cmd() {
  local root="${1-}" state="${2-}" quoted=""
  quoted="$(sh_squote "${state}")"
  printf 'env HERDR_PLUGIN_STATE_DIR=%s "%s/bin/forward" list --oneline' "${quoted}" "${root}"
}
cmd_part() {
  python3 - "$1" "$2" <<'PY' 2>/dev/null || true
import shlex, sys
parts = shlex.split(sys.argv[1], posix=True)
state = ""
exe = ""
i = 0
if parts and parts[0] == "env":
    i = 1
    while i < len(parts):
        key, sep, val = parts[i].partition("=")
        if not sep or key != "HERDR_PLUGIN_STATE_DIR":
            break
        state = val
        i += 1
if i < len(parts):
    exe = parts[i]
print(state if sys.argv[2] == "state" else exe)
PY
}
state_dir_of() { cmd_part "${1-}" state; }
exe_path_of() { cmd_part "${1-}" exe; }

# default_state_dir -> bootstrap.sh 未拿到 env/参数（run_bootstrap 隔离了 env）时
# install-tabbar.sh 推导出的默认 state 目录 = ${XDG_STATE_HOME}/herdr/plugins/zzjcool%3Aforward
default_state_dir() {
  printf '%s/herdr/plugins/zzjcool%%3Aforward' "${WORK}/xdg-state"
}

# tabbar_count <toml> -> 本插件的 tab_bar_right 条目数
tabbar_count() {
  python3 - "$1" <<'PY'
import sys, tomllib
try:
    with open(sys.argv[1], "rb") as fh:
        doc = tomllib.load(fh)
except Exception:
    print(0)
    raise SystemExit(0)
print(sum(1 for e in ((doc.get("ui") or {}).get("tab_bar_right") or [])
          if isinstance(e, dict) and "bin/forward" in str(e.get("command", ""))))
PY
}

# tabbar_command <toml> -> tab_bar_right 里的 command（无则空）
tabbar_command() {
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

# key_count <toml> -> 本插件 keys.command 条目数
key_count() {
  python3 - "$1" <<'PY'
import sys, tomllib
try:
    with open(sys.argv[1], "rb") as fh:
        doc = tomllib.load(fh)
except Exception:
    print(0)
    raise SystemExit(0)
print(sum(1 for e in ((doc.get("keys") or {}).get("command") or [])
          if str(e.get("command", "")).startswith("zzjcool:forward.")))
PY
}

# key_of <toml> <action> -> 该 action 绑定的键
key_of() {
  python3 - "$1" "$2" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as fh:
    doc = tomllib.load(fh)
for e in (doc.get("keys") or {}).get("command") or []:
    if e.get("command") == sys.argv[2]:
        print(e.get("key", ""))
        break
PY
}

t_describe "bootstrap.sh（一站式 OOTB 安装）"

t_it "一次调用同时装 tab bar 与键位，退出 0"
config="${WORK}/config.toml"
printf '# sample\n' >"${config}"
run_bootstrap --config "${config}"
t_exit_ok 0 "${rc}" "bootstrap 退出 0"
tb="$(tabbar_count "${config}")"
t_eq "1" "${tb}" "tab bar 条目已装"
kc="$(key_count "${config}")"
t_eq "3" "${kc}" "3 条键位已装"

t_it "输出后续指引：reload-config / 键位提示 / A↔B 跨机差异"
t_match "reload-config" "${out}" "提示 reload-config"
t_match "prefix" "${out}" "提示键位前缀"
t_match "远程|remote|cross|跨机|另一台" "${out}" "说明跨机（A/B）能力边界"

t_it "幂等：重复执行内容不变"
run_bootstrap --config "${config}"
t_exit_ok 0 "${rc}" "第二次退出 0"
before="$(md5 "${config}")"
run_bootstrap --config "${config}"
after="$(md5 "${config}")"
t_eq "${before}" "${after}" "第三次未改文件"
tb2="$(tabbar_count "${config}")"
t_eq "1" "${tb2}" "tab bar 仍 1 条"
kc2="$(key_count "${config}")"
t_eq "3" "${kc2}" "键位仍 3 条"

t_it "--dry-run：两个安装器都不落盘、不建备份"
config2="${WORK}/dry.toml"
printf '# sample\n' >"${config2}"
before2="$(md5 "${config2}")"
run_bootstrap --config "${config2}" --dry-run
t_exit_ok 0 "${rc}" "dry-run 退出 0"
after2="$(md5 "${config2}")"
t_eq "${before2}" "${after2}" "dry-run 未改文件"
baks="$(find "${WORK}" -maxdepth 1 -name 'dry.toml.bak.*' -print -quit)"
t_eq "" "${baks}" "dry-run 未生成备份"
t_match "dry-run" "${out}" "输出标注 dry-run"

t_it "--no-keys：只装 tab bar；--no-tabbar：只装键位"
config3="${WORK}/nokeys.toml"
printf '# sample\n' >"${config3}"
run_bootstrap --config "${config3}" --no-keys
t_exit_ok 0 "${rc}" "--no-keys 退出 0"
tb3="$(tabbar_count "${config3}")"
t_eq "1" "${tb3}" "--no-keys 只装 tab bar"
kc3="$(key_count "${config3}")"
t_eq "0" "${kc3}" "--no-keys 不装键位"

config4="${WORK}/notabbar.toml"
printf '# sample\n' >"${config4}"
run_bootstrap --config "${config4}" --no-tabbar
t_exit_ok 0 "${rc}" "--no-tabbar 退出 0"
tb4="$(tabbar_count "${config4}")"
t_eq "0" "${tb4}" "--no-tabbar 不装 tab bar"
kc4="$(key_count "${config4}")"
t_eq "3" "${kc4}" "--no-tabbar 只装键位"

t_it "自定义键位透传给 install-keys.sh"
config5="${WORK}/keys.toml"
printf '# sample\n' >"${config5}"
run_bootstrap --config "${config5}" --add-key "prefix+p"
t_exit_ok 0 "${rc}" "退出 0"
k_add="$(key_of "${config5}" "zzjcool:forward.add")"
t_eq "prefix+p" "${k_add}" "--add-key 透传"

t_it "保留用户原有配置（不破坏既有 [keys]/[ui] 字段）"
config6="${WORK}/existing.toml"
cat >"${config6}" <<'EOF'
theme = "dark"

[keys]
prefix = "ctrl+space"

[ui]
tab_bar_position = "top"
EOF
run_bootstrap --config "${config6}"
t_exit_ok 0 "${rc}" "退出 0"
py_rc=0
set +o errexit
python3 - "${config6}" <<'PY' 2>/dev/null
import sys, tomllib
with open(sys.argv[1], "rb") as fh:
    doc = tomllib.load(fh)
assert doc["theme"] == "dark"
assert doc["keys"]["prefix"] == "ctrl+space", doc["keys"]
assert doc["ui"]["tab_bar_position"] == "top", doc["ui"]
assert len(doc["keys"]["command"]) == 3, doc["keys"]
assert len(doc["ui"]["tab_bar_right"]) == 1, doc["ui"]
PY
py_rc=$?
set -o errexit
if [[ "${py_rc}" -eq 0 ]]; then
  t_pass "原有字段保留，两处安装各 1/3 条"
else
  t_fail_note "原有配置被破坏"
fi

t_it "非法 TOML -> 非 0 退出且不破坏原文件"
config7="${WORK}/broken.toml"
printf 'this is = = not toml\n' >"${config7}"
before7="$(cat "${config7}")"
run_bootstrap --config "${config7}"
if [[ "${rc}" -ne 0 ]]; then t_pass "非法 TOML 拒绝（rc=${rc}）"; else t_fail_note "非法 TOML 未拒绝"; fi
after7="$(cat "${config7}")"
t_eq "${before7}" "${after7}" "原文件未被破坏"

t_it "--help 可用且 exit 0"
rc=0
out="$(bash "${BOOTSTRAP}" --help 2>/dev/null)" || rc=$?
t_exit_ok 0 "${rc}" "--help 退出 0"
t_match "config" "${out}" "--help 提到 --config"

t_it "未知参数 -> 非 0（不静默接受）"
run_bootstrap --bogus-flag
if [[ "${rc}" -ne 0 ]]; then t_pass "未知参数拒绝（rc=${rc}）"; else t_fail_note "未知参数被静默接受"; fi

t_describe "bootstrap.sh（tab bar command = 绝对路径 + state env 前缀）"

t_it "默认 tab bar command = env 前缀 + 绝对路径，不含 \$HERDR_PLUGIN_ROOT 字面量"
configAbs="${WORK}/abs-path.toml"
printf '# sample\n' >"${configAbs}"
run_bootstrap --config "${configAbs}"
t_exit_ok 0 "${rc}" "退出 0"
cmdAbs="$(tabbar_command "${configAbs}")"
root_phys="$(cd -P "${ROOT}" && pwd)"
default_sd="$(default_state_dir)"
expectedAbs="$(expected_cmd "${root_phys}" "${default_sd}")"
t_eq "${expectedAbs}" "${cmdAbs}" \
  "command = env HERDR_PLUGIN_STATE_DIR='<state>' \"<abs>/bin/forward\" list --oneline"
if [[ "${cmdAbs}" == *"\$HERDR_PLUGIN_ROOT"* ]]; then
  t_fail_note "command 仍含 \$HERDR_PLUGIN_ROOT 字面量：${cmdAbs}"
else
  t_pass "command 不含 \$HERDR_PLUGIN_ROOT 字面量"
fi
abs_exe="$(exe_path_of "${cmdAbs}")"
t_eq "${root_phys}/bin/forward" "${abs_exe}" "默认解析到本检出（bootstrap 与 install-tabbar 同树）"
abs_state="$(state_dir_of "${cmdAbs}")"
t_eq "${default_sd}" "${abs_state}" "state env 默认 = ${WORK}/xdg-state/herdr/plugins/zzjcool%3Aforward"

# 透传回归：bootstrap 必须把 HERDR_PLUGIN_STATE_DIR（插件 action/startup 上下文里
# herdr 注入的权威 state 目录）透传给 install-tabbar.sh（见 bootstrap.sh 的 state_dir_args）。
t_it "HERDR_PLUGIN_STATE_DIR env 被透传给 install-tabbar.sh（不落回推导默认）"
configEnv="${WORK}/state-from-env.toml"
printf '# sample\n' >"${configEnv}"
rc=0
out="$(env -u HERDR_PLUGIN_STATE_DIR XDG_STATE_HOME="${WORK}/xdg-state" \
  HERDR_PLUGIN_STATE_DIR="${WORK}/authoritative-state%3Aforward" \
  bash "${BOOTSTRAP}" --config "${configEnv}" 2>"${WORK}/stderr")" || rc=$?
set -o errexit
t_exit_ok 0 "${rc}" "退出 0"
env_cmd="$(tabbar_command "${configEnv}")"
env_cmd_state="$(state_dir_of "${env_cmd}")"
t_eq "${WORK}/authoritative-state%3Aforward" "${env_cmd_state}" \
  "command 里的 state 与插件 action 用的是同一个 env 值"

# --state-dir 显式参数优先于 env（跨机场景：在 A 上装、传 B 的 state 目录）
t_it "--state-dir 显式参数透传且优先于 HERDR_PLUGIN_STATE_DIR env"
configSd="${WORK}/state-explicit.toml"
printf '# sample\n' >"${configSd}"
rc=0
out="$(env -u HERDR_PLUGIN_STATE_DIR XDG_STATE_HOME="${WORK}/xdg-state" \
  HERDR_PLUGIN_STATE_DIR="${WORK}/env-should-lose" \
  bash "${BOOTSTRAP}" --config "${configSd}" \
  --state-dir "/srv/server-b/herdr/plugins/zzjcool%3Aforward" 2>"${WORK}/stderr")" || rc=$?
set -o errexit
t_exit_ok 0 "${rc}" "退出 0"
expectedSd="$(expected_cmd "${root_phys}" "/srv/server-b/herdr/plugins/zzjcool%3Aforward")"
sd_cmd="$(tabbar_command "${configSd}")"
t_eq "${expectedSd}" "${sd_cmd}" "--state-dir 压过 env，写进 command"

# state 目录必须能被 /bin/sh 安全解析（env -i 下 tab bar 执行场景）
t_it "生成的 command 可在 env -i 的 /bin/sh -lc 下执行，且子进程看到 state env"
configSh="${WORK}/sh-exec.toml"
printf '# sample\n' >"${configSh}"
run_bootstrap --config "${configSh}"
t_exit_ok 0 "${rc}" "退出 0"
sh_ok="no"
sh_cmd="$(tabbar_command "${configSh}")"
# 模拟 tab bar 真实执行：/bin/sh -lc（login shell，PATH 由 profile 提供）。
# 用 env -i 剥掉所有继承 env（含 HERDR_PLUGIN_STATE_DIR）—— 这正是本 bug 的现场。
sh_rc=0
set +o errexit
env -i PATH=/usr/bin:/bin HOME="${WORK}/home" /bin/sh -lc "${sh_cmd}" \
  >"${WORK}/sh-out" 2>"${WORK}/sh-err"
sh_rc=$?
set -o errexit
if [[ "${sh_rc}" -eq 0 ]]; then sh_ok="yes"; fi
t_eq "yes" "${sh_ok}" "env -i /bin/sh -lc 执行成功（无 HERDR_* env 依赖；state 目录不存在时输出空）"
# 证明确实把 state 传给了子进程：把 state 目录建成真的并放一条 up 记录，看 ⇅ 输出。
real_state="$(default_state_dir)"
mkdir -p "${real_state}"
cat >"${real_state}/forwards.json" <<'JSON'
{ "version": 1, "forwards": [ { "id": "f-3000", "local_port": 3000, "remote_host": "127.0.0.1", "remote_port": 3000, "machine": "m", "ssh_target": "u@h:22", "pid": 1, "control_socket": "", "status": "up", "created_unix": 1790000000, "publish": { "pid": null, "url": null, "started_unix": null } } ] }
JSON
oneline="$(env -i PATH=/usr/bin:/bin HOME="${WORK}/home" /bin/sh -lc "${sh_cmd}" 2>/dev/null | tail -1)"
t_eq "⇅3000" "${oneline}" "state 目录经 env 前缀被真正读到（⇅3000 —— 本 bug 的端到端回归）"
# 反证：没有 env 前缀时同一 state 目录读不到（回退目录为空）→ 状态条永远空
noenv_oneline="$(env -i PATH=/usr/bin:/bin HOME="${WORK}/home" /bin/sh -lc "\"${root_phys}/bin/forward\" list --oneline" 2>/dev/null | tail -1)"
t_eq "" "${noenv_oneline}" "无 env 前缀时输出空（回退目录）—— 证明修复前状态条形同虚设"

t_it "默认 command 可在 env -i 的 /bin/sh -lc 下执行（tab bar 无 HERDR_PLUGIN_ROOT env）"
sh_rc=0
set +o errexit
env -i /bin/sh -lc "${cmdAbs}" >/dev/null 2>&1
sh_rc=$?
set -o errexit
if [[ "${sh_rc}" -eq 0 ]]; then t_pass "env -i 下执行成功（rc=0）"; else t_fail_note "env -i 下执行失败（rc=${sh_rc}）；command=[${cmdAbs}]"; fi

t_it "--plugin-root 透传给 install-tabbar.sh（跨机时 = server B 上的路径）"
configCross="${WORK}/cross.toml"
printf '# sample\n' >"${configCross}"
run_bootstrap --config "${configCross}" --plugin-root "/opt/on-server-b/herdr-forward" \
  --state-dir "/opt/on-server-b/herdr/plugins/zzjcool%3Aforward"
t_exit_ok 0 "${rc}" "退出 0（路径在本机不存在也不报错）"
cmdCross="$(tabbar_command "${configCross}")"
expectedCross="$(expected_cmd "/opt/on-server-b/herdr-forward" "/opt/on-server-b/herdr/plugins/zzjcool%3Aforward")"
t_eq "${expectedCross}" "${cmdCross}" "command 用 B 上的插件路径 + B 上的 state 目录"
kc_cross="$(key_count "${configCross}")"
t_eq "3" "${kc_cross}" "键位不受 --plugin-root 影响（plugin_action 不经路径）"

t_it "--plugin-root 相对路径 -> 非 0（透传后由 install-tabbar.sh 拒绝）"
configRel="${WORK}/rel.toml"
printf '# sample\n' >"${configRel}"
run_bootstrap --config "${configRel}" --plugin-root "relative/plugin"
if [[ "${rc}" -ne 0 ]]; then t_pass "相对路径被拒绝（rc=${rc}）"; else t_fail_note "相对路径被静默接受"; fi

if [[ -e "/opt/on-server-b/herdr-forward" ]]; then
  t_skip "本机恰好存在 /opt/on-server-b/herdr-forward，跳过「不存在也接受」断言"
else
  t_pass "跨机路径（本机不存在）被接受"
fi

t_it "--help 提到 --plugin-root"
rc=0
out="$(bash "${BOOTSTRAP}" --help 2>/dev/null)" || rc=$?
t_exit_ok 0 "${rc}" "--help 退出 0"
t_match "plugin-root" "${out}" "--help 提到 --plugin-root"
t_match "state-dir" "${out}" "--help 提到 --state-dir（本 bug 的修复参数）"

t_it "重跑（含旧格式 config）自动升级为 env 前缀 + 绝对路径映射（幂等修复路径）"
configLegacy="${WORK}/legacy.toml"
# 旧格式：command 里是 $HERDR_PLUGIN_ROOT 字面量（TOML 里写成转义后的形态）
cat >"${configLegacy}" <<'EOF'
[ui]
tab_bar_right = [
  # herdr-forward: tab bar status entry (managed by scripts/install-tabbar.sh)
  { type = "command", command = "\"$HERDR_PLUGIN_ROOT/bin/forward\" list --oneline", interval_seconds = 5, timeout_seconds = 2 },
]
EOF
run_bootstrap --config "${configLegacy}" --plugin-root "${ROOT}" --state-dir "/legacy/state%3Aforward" --no-keys
t_exit_ok 0 "${rc}" "退出 0"
cmdLegacy="$(tabbar_command "${configLegacy}")"
expectedLegacy="$(expected_cmd "${root_phys}" "/legacy/state%3Aforward")"
t_eq "${expectedLegacy}" "${cmdLegacy}" "旧格式被升级为 env 前缀 + 本检出绝对路径"
if grep -q 'HERDR_PLUGIN_ROOT' "${configLegacy}"; then
  t_fail_note "升级后仍残留 \$HERDR_PLUGIN_ROOT"
else
  t_pass "升级后不再有 \$HERDR_PLUGIN_ROOT"
fi
tb_legacy="$(tabbar_count "${configLegacy}")"
t_eq "1" "${tb_legacy}" "仍只 1 条"

# 本 bug 的专属回归：旧格式 = worker-7 形态（绝对路径但无 state env 前缀）
# → 状态条读回退目录（永远空），必须被重写成 env 前缀形态。
t_it "已装但无 state env 前缀（worker-7 形态）→ 重跑 bootstrap 自动补上（本 bug 自愈）"
configNoEnv="${WORK}/no-env-legacy.toml"
python3 - "${configNoEnv}" "${root_phys}" <<'PY'
import sys

path, root = sys.argv[1], sys.argv[2]
entry = (
    '{ type = "command", command = \'"%s/bin/forward" list --oneline\','
    " interval_seconds = 8, timeout_seconds = 3 }"
) % root
text = (
    "[ui]\ntab_bar_right = [\n"
    "  # herdr-forward: tab bar status entry (managed by scripts/install-tabbar.sh)\n"
    "  %s,\n]\n" % entry
)
with open(path, "w", encoding="utf-8") as fh:
    fh.write(text)
PY
noenv_before="$(md5 "${configNoEnv}")"
run_bootstrap --config "${configNoEnv}" --no-keys
t_exit_ok 0 "${rc}" "退出 0"
expectedNoEnv="$(expected_cmd "${root_phys}" "${default_sd}")"
noenv_now="$(tabbar_command "${configNoEnv}")"
t_eq "${expectedNoEnv}" "${noenv_now}" "command 升级为 env 前缀形态（重跑即修）"
noenv_bak="$(find "${WORK}" -maxdepth 1 -name 'no-env-legacy.toml.bak.*' -print -quit)"
t_file_exists "${noenv_bak}"
noenv_bak_md5="$(md5 "${noenv_bak}")"
t_eq "${noenv_before}" "${noenv_bak_md5}" "备份 = 升级前内容"
run_bootstrap --config "${configNoEnv}" --no-keys
t_exit_ok 0 "${rc}" "再跑退出 0"
noenv_again="$(tabbar_command "${configNoEnv}")"
t_eq "${expectedNoEnv}" "${noenv_again}" "再跑不变（幂等）"

run_bootstrap --config "${configLegacy}" --plugin-root "${ROOT}" --state-dir "/legacy/state%3Aforward" --no-keys
t_exit_ok 0 "${rc}" "再跑退出 0"
legacy_again="$(tabbar_command "${configLegacy}")"
t_eq "${cmdLegacy}" "${legacy_again}" "再跑不变（幂等）"

t_describe "bin/forward bootstrap（隐藏子命令转发）"

t_it "forward bootstrap 转发到 scripts/bootstrap.sh"
config8="${WORK}/cli.toml"
printf '# sample\n' >"${config8}"
rc=0
out="$(HERDR_PLUGIN_ROOT="${ROOT}" bash "${CLI}" bootstrap --config "${config8}" 2>"${WORK}/stderr")" || rc=$?
err="$(cat "${WORK}/stderr")"
t_exit_ok 0 "${rc}" "forward bootstrap 退出 0"
tb8="$(tabbar_count "${config8}")"
t_eq "1" "${tb8}" "经 CLI 装好 tab bar"
kc8="$(key_count "${config8}")"
t_eq "3" "${kc8}" "经 CLI 装好键位"

t_it "forward bootstrap --dry-run 不落盘"
config9="${WORK}/cli-dry.toml"
printf '# sample\n' >"${config9}"
before9="$(md5 "${config9}")"
rc=0
out="$(HERDR_PLUGIN_ROOT="${ROOT}" bash "${CLI}" bootstrap --config "${config9}" --dry-run 2>/dev/null)" || rc=$?
t_exit_ok 0 "${rc}" "退出 0"
after9="$(md5 "${config9}")"
t_eq "${before9}" "${after9}" "未改文件"

t_it "forward bootstrap 在缺失 scripts/bootstrap.sh 时报错友好（含下一步）"
PLUGIN_STUB="${WORK}/stub-plugin"
mkdir -p "${PLUGIN_STUB}/bin" "${PLUGIN_STUB}/lib"
cp "${ROOT}/bin/forward" "${PLUGIN_STUB}/bin/forward"
chmod +x "${PLUGIN_STUB}/bin/forward"
cp "${ROOT}/lib/common.sh" "${ROOT}/lib/state.sh" "${PLUGIN_STUB}/lib/"
rc=0
out="$(HERDR_PLUGIN_STATE_DIR="${WORK}/stub-state" bash "${PLUGIN_STUB}/bin/forward" bootstrap 2>"${WORK}/stderr")" || rc=$?
err="$(cat "${WORK}/stderr")"
if [[ "${rc}" -ne 0 ]]; then t_pass "缺失脚本 -> 非 0（rc=${rc}）"; else t_fail_note "缺失脚本未报错"; fi
t_match "bootstrap|scripts" "${err}" "错误信息指明原因"

t_describe "README 指引与实际安装器一致（防漂移）"

t_it "README 的 tab bar 一键复制块 == install-tabbar.sh 实际写入的条目（占位符代入后）"
# README 的跨机块用 <server-plugin-root> / <server-state-dir> 占位（正确值取决于
# server B）。本机自证时把两个占位符都代入「本机 + 本机默认 state」再与安装器输出
# 逐字比对 —— 仍能拦住漂移（含 state env 前缀这类新形态）。
config10="${WORK}/readme-tabbar.toml"
printf '# sample\n' >"${config10}"
readme_state="$(default_state_dir)"
rc=0
out="$(env -u HERDR_PLUGIN_STATE_DIR XDG_STATE_HOME="${WORK}/xdg-state" \
  bash "${ROOT}/scripts/install-tabbar.sh" --config "${config10}" 2>/dev/null)" || rc=$?
t_exit_ok 0 "${rc}" "install-tabbar 退出 0"
roadme_root="$(cd -P "${ROOT}" && pwd)"
readme_entry="$(
  python3 - "${ROOT}/README.md" "${roadme_root}" "${readme_state}" <<'PY'
import re, sys, textwrap
src = open(sys.argv[1], encoding="utf-8").read()
root = sys.argv[2]
state = sys.argv[3]
# 取 README 里 tab_bar_right 的手工粘贴块（含 marker 注释的 toml 代码块）。
# README 把该块放在列表项内，故需 dedent（去掉统一缩进）后再比较。
blocks = re.findall(r"```toml\n(.*?)```", src, re.S)
for b in blocks:
    if "tab bar status entry" in b and "tab_bar_right" in b:
        print(
            textwrap.dedent(b)
            .replace("<server-plugin-root>", root)
            .replace("<server-state-dir>", state)
            .strip()
        )
        break
PY
)"
actual_entry="$(
  python3 - "${config10}" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as fh:
    doc = tomllib.load(fh)
entry = doc["ui"]["tab_bar_right"][0]
def toml_string(v):
    return '"' + v.replace("\\", "\\\\").replace('"', '\\"') + '"'
print("[ui]")
print("tab_bar_right = [")
print("  # herdr-forward: tab bar status entry (managed by scripts/install-tabbar.sh)")
print("  { type = " + toml_string(entry["type"]) + ", command = " + toml_string(entry["command"])
      + ", interval_seconds = " + str(entry["interval_seconds"])
      + ", timeout_seconds = " + str(entry["timeout_seconds"]) + " },")
print("]")
PY
)"
if [[ -n "${readme_entry}" && "${readme_entry}" == "${actual_entry}" ]]; then
  t_pass "README tab bar 块（占位符代入后）与安装器输出逐字一致"
else
  t_fail_note "README tab bar 块与安装器输出不一致
--- README ---
${readme_entry}
--- actual ---
${actual_entry}"
fi

t_it "README 的键位一键复制块 == install-keys.sh 实际写入的 3 条"
config11="${WORK}/readme-keys.toml"
printf '# sample\n' >"${config11}"
rc=0
out="$(bash "${ROOT}/scripts/install-keys.sh" --config "${config11}" 2>/dev/null)" || rc=$?
t_exit_ok 0 "${rc}" "install-keys 退出 0"
readme_keys="$(
  python3 - "${ROOT}/README.md" <<'PY'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
for b in re.findall(r"```toml\n(.*?)```", src, re.S):
    if "keybindings (managed by scripts/install-keys.sh)" in b:
        print(b.strip())
        break
PY
)"
py_rc=0
set +o errexit
python3 - "${readme_keys}" "${config11}" <<'PY' 2>/dev/null
import sys, tomllib
readme = tomllib.loads(sys.argv[1])
with open(sys.argv[2], "rb") as fh:
    actual = tomllib.load(fh)
want = readme["keys"]["command"]
got = [e for e in actual["keys"]["command"] if str(e.get("command", "")).startswith("zzjcool:forward.")]
assert want == got, (want, got)
PY
py_rc=$?
set -o errexit
if [[ "${py_rc}" -eq 0 ]]; then
  t_pass "README 键位块与安装器输出语义一致"
else
  t_fail_note "README 键位块与安装器输出不一致"
fi

t_it "README 明说能力边界：同机自动 / 跨机需一步（诚实文档）"
readme_ok="no"
set +o errexit
readme_scan="$(
  python3 - "${ROOT}/README.md" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
auto = "startup" in src and ("automatically" in src or "automatic" in src)
cross = "cross-machine" in src.lower() or "Cross-machine" in src
manual = "--config" in src and "bootstrap.sh" in src
print("ok" if (auto and cross and manual) else "bad")
PY
)"
set -o errexit
if [[ "${readme_scan}" == "ok" ]]; then
  readme_ok="yes"
fi
t_eq "yes" "${readme_ok}" "README 覆盖同机自动 + 跨机一步 + 手工块"

t_done
