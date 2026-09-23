#!/usr/bin/env bash
# tests/unit/test_install_tabbar.sh — T3：scripts/install-tabbar.sh
# 场景：插入 / 幂等 / 备份 / dry-run / 自定义 command / 非法 TOML / 无 [ui] 段
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALLER="${ROOT}/scripts/install-tabbar.sh"

# --- 断言库：B.1 契约接口；T0 的 tests/lib/assertions.sh 合并前用最小占位子集 ---
if [[ -f "${ROOT}/tests/lib/assertions.sh" ]]; then
  # shellcheck source=/dev/null
  source "${ROOT}/tests/lib/assertions.sh"
else
  echo "WARN: tests/lib/assertions.sh 未就绪（T0 未合并），使用 B.1 契约最小占位子集" >&2
  PASS=0
  FAIL=0
  t_describe() { printf '\n== %s\n' "$*"; }
  t_it() { printf '  - %s\n' "$*"; }
  t_pass() {
    PASS=$((PASS + 1))
    printf '    ok   %s\n' "${1:-}"
  }
  t_fail_note() {
    FAIL=$((FAIL + 1))
    printf '    FAIL %s\n' "${1:-}"
  }
  t_ok() {
    if [[ -n "${1-}" ]]; then t_pass "${2:-ok}"; else t_fail_note "${2:-expected true}"; fi
  }
  t_eq() {
    if [[ "${1-}" == "${2-}" ]]; then
      t_pass "${3:-eq}"
    else
      t_fail_note "${3:-eq}: expected [$1] got [$2]"
    fi
  }
  t_match() {
    if [[ "${2-}" =~ ${1-} ]]; then
      t_pass "${3:-match}"
    else
      t_fail_note "${3:-match}: [$1] not found in [$2]"
    fi
  }
  t_exit_ok() {
    if [[ "${1-}" == "${2-}" ]]; then
      t_pass "${3:-exit $1}"
    else
      t_fail_note "${3:-exit}: expected $1 got $2"
    fi
  }
  t_file_exists() {
    if [[ -e "${1-}" ]]; then t_pass "exists: ${1}"; else t_fail_note "missing: ${1}"; fi
  }
  t_done() {
    printf '\n%d passed, %d failed\n' "${PASS}" "${FAIL}"
    [[ "${FAIL}" -eq 0 ]]
  }
fi

# 合并缺陷修补（T4）：本文件在 T0 断言库存在时走真库分支，而真库未定义
# t_fail_note（它只在下面 else 的占位分支里定义）→ 任何真失败会退化成
# "t_fail_note: command not found" (rc=127)，掩盖真实原因。这里補一个别名。
if ! declare -F t_fail_note >/dev/null 2>&1; then
  t_fail_note() { t_fail "$@"; }
fi

if [[ ! -x "${INSTALLER}" ]]; then
  echo "RED: ${INSTALLER} 不存在或不可执行" >&2
  exit 1
fi

# --- 测试沙箱 ---
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

rc=0
out=""
err=""

# run_installer <config_path> [extra args...] -> 设置 rc/out/err
run_installer() {
  local config="$1"
  shift
  rc=0
  out="$(bash "${INSTALLER}" --config "${config}" "$@" 2>"${WORK}/stderr")" || rc=$?
  err="$(cat "${WORK}/stderr")"
}

# md5 <path> -> 内容散列
md5() { md5sum "$1" | awk '{print $1}'; }

# count_entries <toml_path> -> tab_bar_right 条目数（解析失败记 0）
count_entries() {
  python3 - "$1" <<'PY'
import sys, tomllib
try:
    with open(sys.argv[1], "rb") as fh:
        doc = tomllib.load(fh)
except Exception:
    print(0)
    raise SystemExit(0)
print(len((doc.get("ui") or {}).get("tab_bar_right") or []))
PY
}

# check_shape <toml_path> [expected_command_substr] -> 打印 ok/bad（不靠退出码）
check_shape() {
  python3 - "$1" "${2-}" <<'PY'
import sys, tomllib
try:
    with open(sys.argv[1], "rb") as fh:
        doc = tomllib.load(fh)
    entries = (doc.get("ui") or {}).get("tab_bar_right")
    assert isinstance(entries, list) and len(entries) == 1, entries
    e = entries[0]
    assert set(e) >= {"type", "command", "interval_seconds", "timeout_seconds"}, e
    assert e["type"] == "command", e
    assert 1 <= e["interval_seconds"] <= 31536000, e
    assert 1 <= e["timeout_seconds"] <= 3600, e
    if len(sys.argv) > 2 and sys.argv[2]:
        assert sys.argv[2] in e["command"], e
except Exception:
    print("bad")
    raise SystemExit(0)
print("ok")
PY
}

# command_of <toml_path> -> 第一条 tab_bar_right 条目的 command 字符串（失败时输出空串）
command_of() {
  python3 - "$1" <<'PY' 2>/dev/null || true
import sys, tomllib
try:
    with open(sys.argv[1], "rb") as fh:
        doc = tomllib.load(fh)
    print(doc["ui"]["tab_bar_right"][0]["command"])
except Exception:
    print("")
PY
}

# entry_field <toml_path> <field> -> 第一条目的某个字段（失败时输出空串）
entry_field() {
  python3 - "$1" "$2" <<'PY' 2>/dev/null || true
import sys, tomllib
try:
    with open(sys.argv[1], "rb") as fh:
        doc = tomllib.load(fh)
    print(doc["ui"]["tab_bar_right"][0][sys.argv[2]])
except Exception:
    print("")
PY
}

# exe_path_of <command 字符串> -> 取双引号内的可执行文件路径
exe_path_of() {
  local c="${1#\"}"
  printf '%s\n' "${c%%\"*}"
}

# check_ui_preserved <toml_path> -> 打印 ok/bad
check_ui_preserved() {
  python3 - "$1" <<'PY'
import sys, tomllib
try:
    with open(sys.argv[1], "rb") as fh:
        doc = tomllib.load(fh)
    assert doc["ui"]["tab_bar_position"] == "top", doc["ui"]
    assert len(doc["ui"]["tab_bar_right"]) == 1, doc["ui"]
except Exception:
    print("bad")
    raise SystemExit(0)
print("ok")
PY
}

# check_no_ui_segment_duplicated <toml_path> -> [ui] 出现次数
count_ui_segments() {
  grep -c '^\[ui\]' "$1" 2>/dev/null || true
}

# marker_lines <toml> -> 本插件的标记注释行数
# 不能用子串 'herdr-forward' 计数：command 里的绝对路径（插件根）本身可能
# 包含 'herdr-forward'（详见 README 的 checkout 目录名）。只匹配标记注释本身。
marker_lines() { grep -c '^[[:space:]]*# herdr-forward: tab bar status entry' "$1" 2>/dev/null || true; }

t_describe "install-tabbar.sh"

# ---------------------------------------------------------------------------
t_it "无 [ui] 段：插入 [ui] 头 + tab_bar_right 条目（结构合法）"
config="${WORK}/basic.toml"
cat >"${config}" <<'EOF'
# sample herdr config
theme = "dark"
EOF
run_installer "${config}"
t_exit_ok 0 "${rc}" "安装退出 0"
shape="$(check_shape "${config}")"
t_eq "ok" "${shape}" "生成的 TOML 结构合法（type/command/interval/timeout）"
n_marker="$(marker_lines "${config}")"
t_eq "1" "${n_marker}" "配置中恰好 1 条 herdr-forward 条目"
n_ui="$(count_ui_segments "${config}")"
t_eq "1" "${n_ui}" "恰好 1 个 [ui] 段"

t_it "已存在 [ui] 段：追加进该段而非重复建段，且保留原字段"
config2="${WORK}/has-ui.toml"
cat >"${config2}" <<'EOF'
theme = "dark"

[ui]
tab_bar_position = "top"
EOF
run_installer "${config2}"
t_exit_ok 0 "${rc}" "安装退出 0"
preserved="$(check_ui_preserved "${config2}")"
t_eq "ok" "${preserved}" "保留原有 [ui] 字段且只加 1 条"
n_ui2="$(count_ui_segments "${config2}")"
t_eq "1" "${n_ui2}" "[ui] 段未被重复创建"

t_it "幂等：重复跑不重复插入"
run_installer "${config2}"
run_installer "${config2}"
t_exit_ok 0 "${rc}" "第三次运行退出 0"
n_entries="$(count_entries "${config2}")"
t_eq "1" "${n_entries}" "TOML 条目数仍为 1"
n_marker2="$(marker_lines "${config2}")"
t_eq "1" "${n_marker2}" "文本标记也仅 1 处"

t_it "幂等路径不重写文件且提示 already"
before="$(md5 "${config2}")"
run_installer "${config2}"
after="$(md5 "${config2}")"
t_exit_ok 0 "${rc}" "幂等退出 0"
t_eq "${before}" "${after}" "文件内容未变"
t_match "already" "${out}" "输出含 already"

t_it "备份：实际修改前生成 .bak.<epoch>，内容为改动前的原文件"
backup="$(find "${WORK}" -maxdepth 1 -name 'basic.toml.bak.*' -print -quit)"
t_file_exists "${backup}"
t_match '\.bak\.[0-9]+$' "${backup}" "备份名含 epoch"
first_line="$(head -1 "${backup}")"
t_eq "# sample herdr config" "${first_line}" "备份是改动前内容"

t_it "dry-run：不写文件、不改内容、不建备份、有输出"
config3="${WORK}/dry.toml"
printf 'theme = "dark"\n' >"${config3}"
before3="$(md5 "${config3}")"
run_installer "${config3}" --dry-run
t_exit_ok 0 "${rc}" "dry-run 退出 0"
after3="$(md5 "${config3}")"
t_eq "${before3}" "${after3}" "dry-run 未改文件"
dry_bak="$(find "${WORK}" -maxdepth 1 -name 'dry.toml.bak.*' -print -quit)"
t_eq "" "${dry_bak}" "dry-run 未生成备份"
if [[ -n "${out}" ]]; then t_pass "dry-run 有输出"; else t_fail_note "dry-run 无输出"; fi

t_it "dry-run 对已安装的 config 也 exit 0 且不改文件"
before4="$(md5 "${config2}")"
run_installer "${config2}" --dry-run
after4="$(md5 "${config2}")"
t_exit_ok 0 "${rc}" "dry-run 幂等退出 0"
t_eq "${before4}" "${after4}" "未改文件"

t_it "自定义 command 覆盖（--command）"
config5="${WORK}/custom.toml"
printf 'theme = "dark"\n' >"${config5}"
run_installer "${config5}" --command "/usr/bin/env bash /opt/x/oneline.sh"
t_exit_ok 0 "${rc}" "退出 0"
shape5="$(check_shape "${config5}" "/opt/x/oneline.sh")"
t_eq "ok" "${shape5}" "写入自定义 command"

t_it "目标文件不存在 -> 创建之（含目录）"
config6="${WORK}/nested/dir/config.toml"
mkdir -p "$(dirname "${config6}")"
run_installer "${config6}"
t_exit_ok 0 "${rc}" "退出 0"
t_file_exists "${config6}"

t_it "非法 TOML -> 非 0 退出且不破坏原文件"
config7="${WORK}/broken.toml"
printf 'this is = = not toml\n' >"${config7}"
before7="$(cat "${config7}")"
run_installer "${config7}"
if [[ "${rc}" -ne 0 ]]; then t_pass "非法 TOML 拒绝（rc=${rc}）"; else t_fail_note "非法 TOML 未拒绝"; fi
after7="$(cat "${config7}")"
t_eq "${before7}" "${after7}" "原文件未被破坏"
if [[ -n "${err}" ]]; then t_pass "错误信息走 stderr"; else t_fail_note "错误信息未走 stderr"; fi

t_it "--help 可用且 exit 0（禁交互）"
rc=0
out="$(bash "${INSTALLER}" --help 2>/dev/null)" || rc=$?
t_exit_ok 0 "${rc}" "--help 退出 0"
t_match "config" "${out}" "--help 提到 --config"

t_it "未知参数 -> 非 0（不静默接受）"
run_installer "${config2}" --bogus-flag
if [[ "${rc}" -ne 0 ]]; then t_pass "未知参数拒绝（rc=${rc}）"; else t_fail_note "未知参数被静默接受"; fi

t_it "插入结果符合 RESEARCH §2.3 字段契约（可被 herdr 读取）"
shape6="$(check_shape "${config2}")"
t_eq "ok" "${shape6}" "字段契约符合（type/interval 1–31536000/timeout 1–3600）"

t_it "已存在 tab_bar_right 数组：保留原有条目并在其后追加我们的条目"
config8="${WORK}/has-array.toml"
cat >"${config8}" <<'EOF'
[ui]
tab_bar_position = "top"
tab_bar_right = ["hello", { type = "text", text = "x" }]
EOF
run_installer "${config8}"
t_exit_ok 0 "${rc}" "退出 0"
# shfmt 3.10（宿主）与 3.14（容器）对 `if python3 - <<'PY' … PY then` 的 then
# 位置处理相反 → 改为先落 rc 再判（两版都稳定）。
py_rc=0
set +o errexit
python3 - "${config8}" <<'PY' 2>/dev/null
import sys, tomllib
with open(sys.argv[1], "rb") as fh:
    doc = tomllib.load(fh)
entries = doc["ui"]["tab_bar_right"]
assert len(entries) == 3, entries
assert entries[0] == "hello", entries
assert entries[1] == {"type": "text", "text": "x"}, entries
assert entries[2]["type"] == "command", entries
assert "bin/forward" in entries[2]["command"], entries
PY
py_rc=$?
set -o errexit
if [[ "${py_rc}" -eq 0 ]]; then
  t_pass "原有 2 条保留，我们的条目追加为第 3 条"
else
  t_fail_note "原有条目被破坏或追加位置不对"
fi

# 二次运行：文件内容不变（幂等）
before8="$(md5 "${config8}")"
run_installer "${config8}"
t_exit_ok 0 "${rc}" "二次运行退出 0"
after8="$(md5 "${config8}")"
t_eq "${before8}" "${after8}" "二次运行未改文件（幂等）"

t_it "dry-run 输出为合法 TOML（截取 --- 之间内容可被 tomllib 解析）"
config9="${WORK}/drypar.toml"
printf 'theme = "dark"\n' >"${config9}"
run_installer "${config9}" --dry-run
printf '%s\n' "${out}" | awk '/^---$/{f=!f; next} f' >"${WORK}/dry-out.toml"
py_rc=0
set +o errexit
python3 - "${WORK}/dry-out.toml" <<'PY' 2>/dev/null
import sys, tomllib
with open(sys.argv[1], "rb") as fh:
    doc = tomllib.load(fh)
assert doc["theme"] == "dark"
assert len(doc["ui"]["tab_bar_right"]) == 1
PY
py_rc=$?
set -o errexit
if [[ "${py_rc}" -eq 0 ]]; then
  t_pass "dry-run 输出可直接被 tomllib 解析"
else
  t_fail_note "dry-run 输出不是合法 TOML"
fi

t_it "生成的 command 可在 env -i 的 /bin/sh -lc 下真实执行（无任何 env 依赖）"
# tab_bar_right 的 command 由 herdr 直接经 /bin/sh -lc 执行，env 里 **没有**
# HERDR_PLUGIN_ROOT（该 env 只在插件 action/pane/startup 命令里注入，SCOUT-FACTS §2.2
# 被误用到了 tab bar 场景；§2.4 才是 tab bar 的正确事实）。因此 command 必须是绝对路径。
plug="${WORK}/plug"
mkdir -p "${plug}/bin"
cat >"${plug}/bin/forward" <<'SH'
#!/bin/sh
printf '⇅3000⇅5173\n'
SH
chmod +x "${plug}/bin/forward"
config10="${WORK}/shc.toml"
printf 'theme = "dark"\n' >"${config10}"
run_installer "${config10}" --plugin-root "${plug}"
t_exit_ok 0 "${rc}" "退出 0（--plugin-root 覆盖）"
cmd="$(command_of "${config10}")"
sh_out="$(env -i /bin/sh -lc "${cmd}" | tail -1)"
t_eq "⇅3000⇅5173" "${sh_out}" "env -i /bin/sh -lc 执行并取最后一行"

t_it "回归锚点：旧格式（\$HERDR_PLUGIN_ROOT 字面量）在 env -i 下确实失败"
# shellcheck disable=SC2016  # 单引号内就是要保留的字面量，正是待复现的 bug 形态
old_cmd='"$HERDR_PLUGIN_ROOT/bin/forward" list --oneline'
old_rc=0
set +o errexit
env -i /bin/sh -c "${old_cmd}" >/dev/null 2>&1
old_rc=$?
set -o errexit
if [[ "${old_rc}" -ne 0 ]]; then
  t_pass "旧 command 在干净 env 下非 0（rc=${old_rc}）：证明必须改为绝对路径"
else
  t_fail_note "旧 command 竟然执行成功——本测试的前提事实需要重新核实"
fi

t_describe "install-tabbar.sh（tab bar command = server 上的绝对路径）"

ROOT_PHYS="$(cd -P "${ROOT}" && pwd)"

t_it "默认 command 是本检出的**绝对**路径，且不含 \$HERDR_PLUGIN_ROOT 字面量"
configA="${WORK}/abs.toml"
printf 'theme = "dark"\n' >"${configA}"
run_installer "${configA}"
t_exit_ok 0 "${rc}" "退出 0"
cmdA="$(command_of "${configA}")"
t_match '^"[^"]+/bin/forward" list --oneline$' "${cmdA}" "command 形状 = \"<abs>/bin/forward\" list --oneline"
# 只在字符串模式下匹配字面量，不用 *'$HERDR_PLUGIN_ROOT'* 模式（后者触发 SC2016 提示）
if [[ "${cmdA}" == *"\$HERDR_PLUGIN_ROOT"* ]]; then
  t_fail_note "command 仍含 \$HERDR_PLUGIN_ROOT 字面量：${cmdA}"
else
  t_pass "command 不含 \$HERDR_PLUGIN_ROOT 字面量"
fi
exe_path="$(exe_path_of "${cmdA}")"
t_eq "${ROOT_PHYS}/bin/forward" "${exe_path}" "默认解析到本检出的 bin/forward（物理路径）"
if [[ -x "${exe_path}" ]]; then t_pass "该路径可执行"; else t_fail_note "该路径不可执行：${exe_path}"; fi

t_it "--plugin-root 覆盖：写入给定绝对路径（跨机时 = server B 上的路径，A 上可不存在）"
configB="${WORK}/cross.toml"
printf 'theme = "dark"\n' >"${configB}"
run_installer "${configB}" --plugin-root "/opt/on-server-b/herdr-forward"
t_exit_ok 0 "${rc}" "退出 0（路径在本机不存在也不报错）"
cmdB="$(command_of "${configB}")"
t_eq '"/opt/on-server-b/herdr-forward/bin/forward" list --oneline' "${cmdB}" "command 用 B 上的绝对路径"

if [[ -e "/opt/on-server-b/herdr-forward" ]]; then
  t_skip "本机恰好存在 /opt/on-server-b/herdr-forward，跳过「不存在也接受」断言"
else
  t_pass "跨机路径（本机不存在）被原样写入"
fi

t_it "--plugin-root 相对路径 → 非 0（command 在 server 的 shell 里执行，相对路径不可靠）"
configC="${WORK}/rel.toml"
printf 'theme = "dark"\n' >"${configC}"
run_installer "${configC}" --plugin-root "relative/plugin"
if [[ "${rc}" -ne 0 ]]; then t_pass "相对路径被拒绝（rc=${rc}）"; else t_fail_note "相对路径被静默接受"; fi
if [[ -n "${err}" ]]; then t_pass "错误信息走 stderr"; else t_fail_note "无错误信息"; fi
# 先取值再断言（避免 SC2312：命令替换的退出码被 t_eq 调用掩盖）
cC_after="$(cat "${configC}")"
t_eq "theme = \"dark\"" "${cC_after}" "被拒绝时原文件未改"

t_it "--help 提到 --plugin-root"
rc=0
out="$(bash "${INSTALLER}" --help 2>/dev/null)" || rc=$?
t_exit_ok 0 "${rc}" "--help 退出 0"
t_match "plugin-root" "${out}" "--help 提到 --plugin-root"

t_it "幂等升级：旧格式（\$HERDR_PLUGIN_ROOT 字面量）自动替换为绝对路径 + 备份"
configL="${WORK}/legacy.toml"
cat >"${configL}" <<'EOF'
theme = "dark"

[ui]
tab_bar_position = "top"
tab_bar_right = [
  # herdr-forward: tab bar status entry (managed by scripts/install-tabbar.sh)
  { type = "command", command = "\"$HERDR_PLUGIN_ROOT/bin/forward\" list --oneline", interval_seconds = 7, timeout_seconds = 3 },
]
EOF
legacy_before="$(md5 "${configL}")"
run_installer "${configL}"
t_exit_ok 0 "${rc}" "升级退出 0（不再是 no-op）"
cmdL="$(command_of "${configL}")"
cmdL_exe="$(exe_path_of "${cmdL}")"
t_eq "${ROOT_PHYS}/bin/forward" "${cmdL_exe}" "升级为绝对路径"
legacy_n="$(marker_lines "${configL}")"
t_eq "1" "${legacy_n}" "升级后仍恰好 1 条本插件条目"
n_entriesL="$(count_entries "${configL}")"
t_eq "1" "${n_entriesL}" "tab_bar_right 条目数 1"
if grep -q 'HERDR_PLUGIN_ROOT' "${configL}"; then
  t_fail_note "升级后仍残留 \$HERDR_PLUGIN_ROOT"
else
  t_pass "升级后文件中不再有 \$HERDR_PLUGIN_ROOT"
fi
preserved_ui="$(check_ui_preserved "${configL}")"
t_eq "ok" "${preserved_ui}" "原有 [ui] 字段（tab_bar_position）保留"
legacy_interval="$(entry_field "${configL}" interval_seconds)"
t_eq "7" "${legacy_interval}" "升级保留用户自定义 interval_seconds"
legacy_timeout="$(entry_field "${configL}" timeout_seconds)"
t_eq "3" "${legacy_timeout}" "升级保留用户自定义 timeout_seconds"
legacy_bak="$(find "${WORK}" -maxdepth 1 -name 'legacy.toml.bak.*' -print -quit)"
t_file_exists "${legacy_bak}"
legacy_bak_md5="$(md5 "${legacy_bak}")"
t_eq "${legacy_before}" "${legacy_bak_md5}" "备份内容 = 升级前的旧文件"

t_it "升级后再次运行 → 幂等：不改文件、不新增备份、输出 already"
beforeL="$(md5 "${configL}")"
run_installer "${configL}"
t_exit_ok 0 "${rc}" "退出 0"
afterL="$(md5 "${configL}")"
t_eq "${beforeL}" "${afterL}" "文件未变"
t_match "already" "${out}" "输出含 already"
bak_count="$(find "${WORK}" -maxdepth 1 -name 'legacy.toml.bak.*' | wc -l)"
t_eq "1" "${bak_count}" "没有新增备份"

t_done
