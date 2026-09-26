#!/usr/bin/env bash
# tests/unit/test_install_keys.sh — OOTB：scripts/install-keys.sh
# 场景：插入（空文件/已有 [keys] 段/已有他人 [[keys.command]]）/ 幂等 / 备份 /
#       dry-run / 自定义键位 / 键位冲突告警 / 非法 TOML / 未知参数 / --help
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALLER="${ROOT}/scripts/install-keys.sh"

# --- 断言库：B.1 契约接口；T0 的 tests/assertions.sh 合并前用最小占位子集 ---
if [[ -f "${ROOT}/tests/assertions.sh" ]]; then
  # shellcheck source=/dev/null
  source "${ROOT}/tests/assertions.sh"
else
  echo "WARN: tests/assertions.sh 未就绪，使用 B.1 契约最小占位子集" >&2
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

if ! declare -F t_fail_note >/dev/null 2>&1; then
  t_fail_note() { t_fail "$@"; }
fi

if [[ ! -x "${INSTALLER}" ]]; then
  echo "RED: ${INSTALLER} 不存在或不可执行（OOTB installer 尚未实现）" >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

rc=0
out=""
err=""

run_installer() {
  local config="$1"
  shift
  rc=0
  out="$(bash "${INSTALLER}" --config "${config}" "$@" 2>"${WORK}/stderr")" || rc=$?
  err="$(cat "${WORK}/stderr")"
}

md5() { md5sum "$1" | awk '{print $1}'; }

# count_ours <toml> -> 本插件 action 的 keys.command 条目数
count_ours() {
  python3 - "$1" <<'PY'
import sys, tomllib
try:
    with open(sys.argv[1], "rb") as fh:
        doc = tomllib.load(fh)
except Exception:
    print(0)
    raise SystemExit(0)
entries = (doc.get("keys") or {}).get("command") or []
print(sum(1 for e in entries if str(e.get("command", "")).startswith("zzjcool:forward.")))
PY
}

# check_shape <toml> -> ok/bad（三条键位的官方 schema：key/type/command/description）
check_shape() {
  python3 - "$1" <<'PY'
import sys, tomllib
try:
    with open(sys.argv[1], "rb") as fh:
        doc = tomllib.load(fh)
    entries = [e for e in ((doc.get("keys") or {}).get("command") or [])
               if str(e.get("command", "")).startswith("zzjcool:forward.")]
    assert len(entries) == 3, entries
    cmds = sorted(e["command"] for e in entries)
    assert cmds == ["zzjcool:forward.add", "zzjcool:forward.doctor", "zzjcool:forward.list"], cmds
    for e in entries:
        assert e["type"] == "plugin_action", e
        assert e["key"].startswith("prefix+"), e
        assert e["description"], e
except Exception:
    print("bad")
    raise SystemExit(0)
print("ok")
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

marker_lines() { grep -c 'herdr-forward: keybindings' "$1" 2>/dev/null || true; }

t_describe "install-keys.sh"

# ---------------------------------------------------------------------------
t_it "无 [keys] 段：写入 3 条 [[keys.command]]（官方 plugin_action schema）"
config="${WORK}/basic.toml"
cat >"${config}" <<'EOF'
# sample herdr config
theme = "dark"
EOF
run_installer "${config}"
t_exit_ok 0 "${rc}" "安装退出 0"
shape_basic="$(check_shape "${config}")"
t_eq "ok" "${shape_basic}" "3 条键位 schema 合规"
n_ours="$(count_ours "${config}")"
t_eq "3" "${n_ours}" "恰好 3 条本插件键位"
n_marker="$(marker_lines "${config}")"
t_eq "1" "${n_marker}" "幂等标记恰好 1 处"

t_it "已有 [keys] 段：保留原字段，只追加 [[keys.command]]"
config2="${WORK}/has-keys.toml"
cat >"${config2}" <<'EOF'
[keys]
prefix = "ctrl+space"
reload_config = "prefix+q"
EOF
run_installer "${config2}"
t_exit_ok 0 "${rc}" "退出 0"
py_rc=0
set +o errexit
python3 - "${config2}" <<'PY' 2>/dev/null
import sys, tomllib
with open(sys.argv[1], "rb") as fh:
    doc = tomllib.load(fh)
assert doc["keys"]["prefix"] == "ctrl+space", doc["keys"]
assert doc["keys"]["reload_config"] == "prefix+q", doc["keys"]
assert len(doc["keys"]["command"]) == 3, doc["keys"]
PY
py_rc=$?
set -o errexit
if [[ "${py_rc}" -eq 0 ]]; then
  t_pass "[keys] 原字段保留且只加 3 条 command"
else
  t_fail_note "[keys] 段被破坏或条目数不对"
fi
t_eq "1" "$(grep -c '^\[keys\]' "${config2}" || true)" "[keys] 段未被重复创建"

t_it "已有他人 [[keys.command]]：保留原条目，我们的追加在后"
config3="${WORK}/foreign.toml"
cat >"${config3}" <<'EOF'
[[keys.command]]
key = "prefix+l"
type = "plugin_action"
command = "other.plugin.apply"
description = "foreign"
EOF
run_installer "${config3}"
t_exit_ok 0 "${rc}" "退出 0"
py_rc=0
set +o errexit
python3 - "${config3}" <<'PY' 2>/dev/null
import sys, tomllib
with open(sys.argv[1], "rb") as fh:
    doc = tomllib.load(fh)
entries = doc["keys"]["command"]
assert len(entries) == 4, entries
assert entries[0]["command"] == "other.plugin.apply", entries
assert [e["command"] for e in entries[1:]] == [
    "zzjcool:forward.add", "zzjcool:forward.list", "zzjcool:forward.doctor"], entries
PY
py_rc=$?
set -o errexit
if [[ "${py_rc}" -eq 0 ]]; then
  t_pass "他人条目保留，本插件 3 条追加在后"
else
  t_fail_note "他人 [[keys.command]] 被破坏"
fi

t_it "幂等：重复跑不重复插入，文件内容不变，输出含 already"
run_installer "${config3}"
run_installer "${config3}"
t_exit_ok 0 "${rc}" "第三次运行退出 0"
n_ours3="$(count_ours "${config3}")"
t_eq "3" "${n_ours3}" "条目数仍为 3"
n_marker3="$(marker_lines "${config3}")"
t_eq "1" "${n_marker3}" "标记仍仅 1 处"
before="$(md5 "${config3}")"
run_installer "${config3}"
after_idem="$(md5 "${config3}")"
t_eq "${before}" "${after_idem}" "幂等路径不重写文件"
t_match "already" "${out}" "输出含 already"

t_it "备份：真实修改前生成 <config>.bak.<epoch>，内容为改动前原文件"
backup="$(find "${WORK}" -maxdepth 1 -name 'basic.toml.bak.*' -print -quit)"
t_file_exists "${backup}"
t_match '\.bak\.[0-9]+$' "${backup}" "备份名含 epoch"
backup_head="$(head -1 "${backup}")"
t_eq "# sample herdr config" "${backup_head}" "备份是改动前内容"

t_it "dry-run：不写文件、不建备份、输出为可解析 TOML 且含 --dry-run 提示"
config4="${WORK}/dry.toml"
printf 'theme = "dark"\n' >"${config4}"
before4="$(md5 "${config4}")"
run_installer "${config4}" --dry-run
t_exit_ok 0 "${rc}" "dry-run 退出 0"
after4="$(md5 "${config4}")"
t_eq "${before4}" "${after4}" "dry-run 未改文件"
dry_bak="$(find "${WORK}" -maxdepth 1 -name 'dry.toml.bak.*' -print -quit)"
t_eq "" "${dry_bak}" "dry-run 未生成备份"
t_match "dry-run" "${out}" "输出标注 dry-run"
printf '%s\n' "${out}" | awk '/^---$/{f=!f; next} f' >"${WORK}/dry-out.toml"
py_rc=0
set +o errexit
python3 - "${WORK}/dry-out.toml" <<'PY' 2>/dev/null
import sys, tomllib
with open(sys.argv[1], "rb") as fh:
    doc = tomllib.load(fh)
assert doc["theme"] == "dark"
assert len(doc["keys"]["command"]) == 3, doc["keys"]
PY
py_rc=$?
set -o errexit
if [[ "${py_rc}" -eq 0 ]]; then
  t_pass "dry-run 预览是合法 TOML"
else
  t_fail_note "dry-run 预览不是合法 TOML"
fi

t_it "自定义键位（--add-key/--list-key/--doctor-key 覆盖默认）"
config5="${WORK}/custom.toml"
printf 'theme = "dark"\n' >"${config5}"
run_installer "${config5}" --add-key "prefix+a" --list-key "prefix+b" --doctor-key "prefix+d"
t_exit_ok 0 "${rc}" "退出 0"
k_add5="$(key_of "${config5}" "zzjcool:forward.add")"
t_eq "prefix+a" "${k_add5}" "--add-key 生效"
k_list5="$(key_of "${config5}" "zzjcool:forward.list")"
t_eq "prefix+b" "${k_list5}" "--list-key 生效"
k_doc5="$(key_of "${config5}" "zzjcool:forward.doctor")"
t_eq "prefix+d" "${k_doc5}" "--doctor-key 生效"

t_it "默认键位 = prefix+f / prefix+shift+f / prefix+alt+f"
k_add="$(key_of "${config}" "zzjcool:forward.add")"
t_eq "prefix+f" "${k_add}" "add -> prefix+f"
k_list="$(key_of "${config}" "zzjcool:forward.list")"
t_eq "prefix+shift+f" "${k_list}" "list -> prefix+shift+f"
k_doc="$(key_of "${config}" "zzjcool:forward.doctor")"
t_eq "prefix+alt+f" "${k_doc}" "doctor -> prefix+alt+f"

t_it "键位已被他人占用：告警但不致命（用户可用 --add-key 规避）"
config6="${WORK}/conflict.toml"
cat >"${config6}" <<'EOF'
[[keys.command]]
key = "prefix+f"
type = "plugin_action"
command = "other.plugin.apply"
description = "foreign"
EOF
run_installer "${config6}"
t_exit_ok 0 "${rc}" "冲突时仍装（不阻塞用户）"
t_match "conflict|冲突" "${err}" "stderr 有冲突告警"
n_ours6="$(count_ours "${config6}")"
t_eq "3" "${n_ours6}" "本插件 3 条仍写入"

t_it "目标文件不存在 -> 创建之（含目录）"
config7="${WORK}/nested/dir/config.toml"
run_installer "${config7}"
t_exit_ok 0 "${rc}" "退出 0"
t_file_exists "${config7}"

t_it "非法 TOML -> 非 0 退出且不破坏原文件"
config8="${WORK}/broken.toml"
printf 'this is = = not toml\n' >"${config8}"
before8="$(cat "${config8}")"
run_installer "${config8}"
if [[ "${rc}" -ne 0 ]]; then t_pass "非法 TOML 拒绝（rc=${rc}）"; else t_fail_note "非法 TOML 未拒绝"; fi
after8="$(cat "${config8}")"
t_eq "${before8}" "${after8}" "原文件未被破坏"
if [[ -n "${err}" ]]; then t_pass "错误信息走 stderr"; else t_fail_note "错误信息未走 stderr"; fi

t_it "--help 可用且 exit 0（禁交互）"
rc=0
out="$(bash "${INSTALLER}" --help 2>/dev/null)" || rc=$?
t_exit_ok 0 "${rc}" "--help 退出 0"
t_match "config" "${out}" "--help 提到 --config"
t_match "keys" "${out}" "--help 提到 keys"

t_it "未知参数 -> 非 0（不静默接受）"
run_installer "${config3}" --bogus-flag
if [[ "${rc}" -ne 0 ]]; then t_pass "未知参数拒绝（rc=${rc}）"; else t_fail_note "未知参数被静默接受"; fi

t_it "写入的键位可被 herdr 读取（tomllib 解析全库 + 只看 type/command 契约）"
shape_final="$(check_shape "${config3}")"
t_eq "ok" "${shape_final}" "最终文件键位契约仍合规"

t_done
