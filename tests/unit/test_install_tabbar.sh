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

marker_lines() { grep -c 'herdr-forward' "$1" 2>/dev/null || true; }

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
t_ok "${out}" "dry-run 有输出"

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
t_ok "${err}" "错误信息走 stderr"

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
if python3 - "${config8}" <<'PY'; then
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
if python3 - "${WORK}/dry-out.toml" <<'PY'; then
import sys, tomllib
with open(sys.argv[1], "rb") as fh:
    doc = tomllib.load(fh)
assert doc["theme"] == "dark"
assert len(doc["ui"]["tab_bar_right"]) == 1
PY
  t_pass "dry-run 输出可直接被 tomllib 解析"
else
  t_fail_note "dry-run 输出不是合法 TOML"
fi

t_it "生成的 command 可在 /bin/sh -lc 下执行并返回 oneline（SCOUT-FACTS §2.4）"
plug="${WORK}/plug"
mkdir -p "${plug}/bin"
cat >"${plug}/bin/forward" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '⇅3000⇅5173\n'
SH
chmod +x "${plug}/bin/forward"
config10="${WORK}/shc.toml"
printf 'theme = "dark"\n' >"${config10}"
run_installer "${config10}"
t_exit_ok 0 "${rc}" "退出 0"
cmd="$(
  python3 - "${config10}" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as fh:
    doc = tomllib.load(fh)
print(doc["ui"]["tab_bar_right"][0]["command"])
PY
)"
sh_out="$(HERDR_PLUGIN_ROOT="${plug}" /bin/sh -lc "${cmd}" | tail -1)"
t_eq "⇅3000⇅5173" "${sh_out}" "/bin/sh -lc 执行并取最后一行"

t_done
