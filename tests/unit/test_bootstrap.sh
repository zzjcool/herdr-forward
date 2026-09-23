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
  out="$(bash "${BOOTSTRAP}" "$@" 2>"${WORK}/stderr")" || rc=$?
  err="$(cat "${WORK}/stderr")"
}

md5() { md5sum "$1" | awk '{print $1}'; }

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

t_it "README 的 tab bar 一键复制块 == install-tabbar.sh 实际写入的条目"
config10="${WORK}/readme-tabbar.toml"
printf '# sample\n' >"${config10}"
rc=0
out="$(bash "${ROOT}/scripts/install-tabbar.sh" --config "${config10}" 2>/dev/null)" || rc=$?
t_exit_ok 0 "${rc}" "install-tabbar 退出 0"
readme_entry="$(
  python3 - "${ROOT}/README.md" <<'PY'
import re, sys, textwrap
src = open(sys.argv[1], encoding="utf-8").read()
# 取 README 里 tab_bar_right 的手工粘贴块（含 marker 注释的 toml 代码块）。
# README 把该块放在列表项内，故需 dedent（去掉统一缩进）后再比较。
blocks = re.findall(r"```toml\n(.*?)```", src, re.S)
for b in blocks:
    if "tab bar status entry" in b and "tab_bar_right" in b:
        print(textwrap.dedent(b).strip())
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
  t_pass "README tab bar 块与安装器输出逐字一致"
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
