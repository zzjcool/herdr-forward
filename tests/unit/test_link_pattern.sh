#!/usr/bin/env bash
# tests/unit/test_link_pattern.sh — T3：[[link_handlers]] pattern 同构验证
#
# 目的：herdr 的 link_handlers.pattern 是 **Rust regex**（SCOUT-FACTS §2.2/2.3），
# 运行在 herdr 进程里，我们无法在测试里直接跑 Rust 引擎。本测试做「同构」验证：
#   1) 从 herdr-plugin.toml（唯一权威）用 python3 tomllib 取出 pattern，断言 = 冻结常量；
#   2) 用 python3 re 编译/匹配（覆盖 (?:...) / \d 等 Rust regex 常用子集），
#      作为 Rust 侧语义的代理；
#   3) 用 bash ERE（把 (?: -> (、\d -> [0-9] 做同构翻译）匹配同一批用例；
#   4) 断言两个引擎对全部用例的命中/不命中判定完全一致。
#
# 事实依据（SCOUT-FACTS §2.3）：herdr URL 检测只认 http:// / https://，
# 无 scheme 的 `localhost:3000` 不命中 → pattern 必须带 scheme。
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MANIFEST="${ROOT}/herdr-plugin.toml"

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
  t_eq() {
    if [[ "${1-}" == "${2-}" ]]; then
      t_pass "${3:-eq}"
    else
      t_fail_note "${3:-eq}: expected [$1] got [$2]"
    fi
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

# 一期 link pattern 定稿（与 herdr-plugin.toml 中 [[link_handlers]] 的 pattern 必须一致）
readonly PATTERN_EXPECTED='^https?://(?:localhost|127\.0\.0\.1)(?::\d{1,5})?(?:[/?#].*)?$'
# 同构的 bash ERE：Rust `(?:` -> ERE `(`；Rust `\d` -> ERE `[0-9]`（语义等价子集）
readonly PATTERN_BASH_ERE='^https?://(localhost|127\.0\.0\.1)(:[0-9]{1,5})?([/?#].*)?$'
# 二期 guard：trycloudflare URL 由二期独立 handler 处理，一期 pattern 必须不命中它
readonly PATTERN_PHASE2_EXPECTED='^https://[a-z0-9-]+\.trycloudflare\.com(?:[/?#].*)?$'
readonly PATTERN_PHASE2_BASH_ERE='^https://[a-z0-9-]+\.trycloudflare\.com([/?#].*)?$'

# 用例集：每行 "<engine-expectation>|<url>"；engine 1=命中 0=不命中
readonly CASES=(
  # 命中：带 scheme 的 localhost / 127.0.0.1
  '1|http://localhost:3000'
  '1|https://localhost:5173'
  '1|http://127.0.0.1:8080'
  '1|https://127.0.0.1'
  '1|http://localhost'
  '1|http://localhost:3000/dashboard'
  '1|http://127.0.0.1:8080/api?x=1'
  # 不命中：无 scheme（herdr 只认 http/https，SCOUT-FACTS §2.3）
  '0|localhost:3000'
  '0|127.0.0.1:8080'
  # 不命中：纯文本 / 非 URL
  '0|localhost'
  '0|3000'
  '0|foo:bar'
  '0|see http://localhost:3000 for details'
  # 不命中：合法 URL 但 host 不是 loopback
  '0|https://example.com'
  '0|https://example.com:3000'
  '0|https://x.trycloudflare.com'
  # 不命中：非 http(s) scheme / 端口越界
  '0|ftp://localhost:3000'
  '0|http://localhost:999999'
  '0|http://localhost:0abc'
)

# 二期 guard 用例：这些 URL 一期不命中、二期专属 pattern 命中（前瞻锁定，不实现二期功能）
readonly CASES_PHASE2=(
  'https://x.trycloudflare.com'
  'https://random-words-here.trycloudflare.com'
  'https://abc123.trycloudflare.com/some/path'
)

# --- 1) manifest 提取（唯一权威来源） ---
if [[ ! -f "${MANIFEST}" ]]; then
  echo "RED: ${MANIFEST} 不存在" >&2
  exit 1
fi

t_describe "link_handlers pattern 同构（Rust regex ↔ bash ERE）"

t_it "manifest 可被 tomllib 解析且声明了 [[link_handlers]]"
if ! manifest_dump="$(
  python3 - "${MANIFEST}" <<'PY' 2>&1
import sys, tomllib
with open(sys.argv[1], "rb") as fh:
    doc = tomllib.load(fh)
handlers = doc.get("link_handlers")
if not handlers:
    print("NO_LINK_HANDLERS")
    sys.exit(3)
for h in handlers:
    print("FIELD\t{}".format(h.get("id", "")))
    print("PATTERN\t{}".format(h.get("pattern", "")))
    print("ACTION\t{}".format(h.get("action", "")))
PY
)"; then
  t_fail_note "manifest link_handlers 解析失败: ${manifest_dump}"
  manifest_dump=""
else
  t_pass "manifest 解析 + link_handlers 存在"
fi

manifest_pattern="$(printf '%s' "${manifest_dump}" | awk -F'\t' '$1=="PATTERN"{print $2; exit}')"
manifest_action="$(printf '%s' "${manifest_dump}" | awk -F'\t' '$1=="ACTION"{print $2; exit}')"

t_it "manifest pattern == 冻结常量（防漂移）"
t_eq "${PATTERN_EXPECTED}" "${manifest_pattern}" "pattern 与冻结版一致"

t_it "pattern 用 TOML literal string（basic string 会吞 \d / \.）"
if grep -q "pattern = '" "${MANIFEST}"; then
  t_pass "使用单引号 literal string"
else
  t_fail_note "pattern 必须用 TOML 单引号 literal string"
fi

t_it "pattern 在 Rust 语义代理（python3 re）下可编译"
if python3 -c "
import re, sys
re.compile(sys.argv[1])
" "${manifest_pattern}" 2>/dev/null; then
  t_pass "python3 re 编译通过"
else
  t_fail_note "python3 re 无法编译 pattern: ${manifest_pattern}"
fi

t_it "pattern 不含 bash ERE 不支持的构造（(?:...) / \\d 已翻译）"
translated="${manifest_pattern//'(?:'/'('}"
translated="${translated//'\d'/'[0-9]'}"
# 翻译后必须逐字等于测试里冻结的 bash ERE（保证两边同步演进）
t_eq "${PATTERN_BASH_ERE}" "${translated}" "Rust->ERE 翻译结果"

# --- 2) 双引擎逐用例对照 ---
t_it "双引擎逐用例判定一致且等于期望（${#CASES[@]} 例）"
mismatch=0
for case in "${CASES[@]}"; do
  expect="${case%%|*}"
  url="${case#*|}"

  if python3 -c "
import re, sys
pat = sys.argv[1]
url = sys.argv[2]
print(1 if re.fullmatch(pat, url) else 0)
" "${manifest_pattern}" "${url}" 2>/dev/null | grep -qx '1'; then
    py_hit=1
  else
    py_hit=0
  fi

  if [[ "${url}" =~ ${PATTERN_BASH_ERE} ]]; then
    bash_hit=1
  else
    bash_hit=0
  fi

  if [[ "${py_hit}" != "${expect}" || "${bash_hit}" != "${expect}" || "${py_hit}" != "${bash_hit}" ]]; then
    mismatch=$((mismatch + 1))
    printf '    FAIL url=[%s] expect=%s py=%s bash=%s\n' "${url}" "${expect}" "${py_hit}" "${bash_hit}"
  fi
done
t_eq "0" "${mismatch}" "全部用例双引擎一致"

# --- 3) 二期 guard（前瞻锁定；一期不实现二期 handler） ---
t_it "一期 pattern 不命中 trycloudflare URL；二期候选 pattern 命中（${#CASES_PHASE2[@]} 例）"
p2_mismatch=0
for url in "${CASES_PHASE2[@]}"; do
  if python3 -c "
import re, sys
print(1 if re.fullmatch(sys.argv[1], sys.argv[2]) else 0)
" "${PATTERN_PHASE2_EXPECTED}" "${url}" 2>/dev/null | grep -qx '1'; then
    p2_hit=1
  else
    p2_hit=0
  fi
  if [[ "${url}" =~ ${PATTERN_PHASE2_BASH_ERE} ]]; then
    p2_bash=1
  else
    p2_bash=0
  fi
  if [[ "${p2_hit}" != "1" || "${p2_bash}" != "1" ]]; then
    p2_mismatch=$((p2_mismatch + 1))
    printf '    FAIL phase2 url=[%s] py=%s bash=%s\n' "${url}" "${p2_hit}" "${p2_bash}"
  fi
done
t_eq "0" "${p2_mismatch}" "二期候选 pattern 命中其用例"

t_it "link_handler action 指向 manifest 中已声明的 action id"
py_rc=0
set +o errexit
python3 - "${MANIFEST}" "${manifest_action}" <<'PY' 2>/dev/null
import sys, tomllib
with open(sys.argv[1], "rb") as fh:
    doc = tomllib.load(fh)
ids = {a.get("id") for a in doc.get("actions", [])}
sys.exit(0 if sys.argv[2] in ids else 1)
PY
py_rc=$?
set -o errexit
if [[ "${py_rc}" -eq 0 ]]; then
  t_pass "action '${manifest_action}' 已声明"
else
  t_fail_note "action '${manifest_action}' 未在 [[actions]] 中声明"
fi

# --- 4) manifest 结构冒烟（python3.11+ 内置 tomllib；RESEARCH §2.2 schema） ---
t_describe "manifest 结构冒烟（tomllib）"

t_it "顶层必填字段 / 平台 / 版本下限"
py_rc=0
set +o errexit
python3 - "${MANIFEST}" <<'PY' 2>/dev/null
import sys, tomllib
with open(sys.argv[1], "rb") as fh:
    doc = tomllib.load(fh)
for key in ("id", "name", "version", "min_herdr_version", "description", "platforms"):
    if not doc.get(key):
        print("missing {}".format(key))
        sys.exit(1)
if doc["id"] != "zzjcool:forward":
    sys.exit(1)
if doc["min_herdr_version"] != "0.8.0":
    sys.exit(1)
if set(doc["platforms"]) - {"linux", "macos"}:
    sys.exit(1)
sys.exit(0)
PY
py_rc=$?
set -o errexit
if [[ "${py_rc}" -eq 0 ]]; then
  t_pass "顶层字段齐全，id/min_herdr_version/platforms 符合冻结声明"
else
  t_fail_note "manifest 顶层字段不合规"
fi

t_it "[[actions]] >= 4 且 id 唯一、无点、command 是非空 argv 数组"
py_rc=0
set +o errexit
python3 - "${MANIFEST}" <<'PY' 2>/dev/null
import sys, tomllib
with open(sys.argv[1], "rb") as fh:
    doc = tomllib.load(fh)
actions = doc.get("actions", [])
if len(actions) < 4:
    sys.exit(1)
ids = [a.get("id") for a in actions]
if len(ids) != len(set(ids)):
    sys.exit(1)
for a in actions:
    aid = a.get("id", "")
    if not aid or "." in aid:
        sys.exit(1)
    argv = a.get("command")
    if not isinstance(argv, list) or not argv or not all(isinstance(x, str) and x for x in argv):
        sys.exit(1)
    if not a.get("title"):
        sys.exit(1)
sys.exit(0)
PY
py_rc=$?
set -o errexit
if [[ "${py_rc}" -eq 0 ]]; then
  t_pass "actions 结构合规（>=4，argv 数组，id 无点）"
else
  t_fail_note "[[actions]] 结构不合规"
fi

t_it "[[panes]] 声明 Ports 面板，id 无点、command 是 argv 数组"
py_rc=0
set +o errexit
python3 - "${MANIFEST}" <<'PY' 2>/dev/null
import sys, tomllib
with open(sys.argv[1], "rb") as fh:
    doc = tomllib.load(fh)
panes = doc.get("panes", [])
if not panes:
    sys.exit(1)
if not any(p.get("id") == "ports" for p in panes):
    sys.exit(1)
for p in panes:
    if not p.get("id") or "." in p["id"] or not p.get("title"):
        sys.exit(1)
    argv = p.get("command")
    if not isinstance(argv, list) or not argv:
        sys.exit(1)
    if "width" in p or "height" in p:
        # popup 限定字段：非 popup placement 不得出现
        if p.get("placement") != "popup":
            sys.exit(1)
sys.exit(0)
PY
py_rc=$?
set -o errexit
if [[ "${py_rc}" -eq 0 ]]; then
  t_pass "panes 结构合规（含 ports 面板）"
else
  t_fail_note "[[panes]] 结构不合规"
fi

t_it "[[link_handlers]] 结构合规且 action 引用存在"
py_rc=0
set +o errexit
python3 - "${MANIFEST}" <<'PY' 2>/dev/null
import sys, tomllib
with open(sys.argv[1], "rb") as fh:
    doc = tomllib.load(fh)
handlers = doc.get("link_handlers", [])
action_ids = {a.get("id") for a in doc.get("actions", [])}
if not handlers:
    sys.exit(1)
for h in handlers:
    if not h.get("id") or "." in h["id"]:
        sys.exit(1)
    if not h.get("title") or not h.get("pattern"):
        sys.exit(1)
    if h.get("action") not in action_ids:
        sys.exit(1)
sys.exit(0)
PY
py_rc=$?
set -o errexit
if [[ "${py_rc}" -eq 0 ]]; then
  t_pass "link_handlers 结构合规，action 引用存在"
else
  t_fail_note "[[link_handlers]] 结构不合规"
fi

t_it "所有 command 均不依赖未证实的 %{plugin_root} 模板变量（SCOUT-FACTS §2.2）"
py_rc=0
set +o errexit
python3 - "${MANIFEST}" <<'PY' 2>/dev/null
import sys, tomllib
with open(sys.argv[1], "rb") as fh:
    doc = tomllib.load(fh)
argv_lists = []
for key in ("actions", "panes", "startup", "events", "build"):
    for entry in doc.get(key, []) or []:
        if isinstance(entry, dict):
            argv_lists.append(entry.get("command"))
bad = [argv for argv in argv_lists if isinstance(argv, list) and any("%{plugin_root}" in a for a in argv)]
sys.exit(1 if bad else 0)
PY
py_rc=$?
set -o errexit
if [[ "${py_rc}" -eq 0 ]]; then
  t_pass "command argv 未使用 %{plugin_root}"
else
  t_fail_note "有 command argv 仍引用未证实的 %{plugin_root}"
fi

t_it "command argv 均通过 \$HERDR_PLUGIN_ROOT env 解析插件路径（官方注入，SCOUT-FACTS §2.2）"
py_rc=0
set +o errexit
python3 - "${MANIFEST}" <<'PY' 2>/dev/null
import sys, tomllib
with open(sys.argv[1], "rb") as fh:
    doc = tomllib.load(fh)
needs_root = []
for key in ("actions", "panes"):
    for entry in doc.get(key, []) or []:
        if not isinstance(entry, dict):
            continue
        argv = entry.get("command")
        if isinstance(argv, list) and any("/bin/forward" in a or "bin/forward" in a for a in argv):
            joined = " ".join(argv)
            if "HERDR_PLUGIN_ROOT" not in joined:
                needs_root.append(entry.get("id"))
sys.exit(1 if needs_root else 0)
PY
py_rc=$?
set -o errexit
if [[ "${py_rc}" -eq 0 ]]; then
  t_pass "调用 bin/forward 的 command 均经 \$HERDR_PLUGIN_ROOT 解析"
else
  t_fail_note "有 command 直接写死 bin/forward 路径，未经 \$HERDR_PLUGIN_ROOT"
fi

# --- M1（review minor）：remove action 不得指向一期未实现的 --pick（用户可见死按钮） ---
t_describe "M1: remove action 是一期可达路径，不复用未实现的 --pick"

manifest_remove_cmd="$(
  python3 - "${MANIFEST}" <<'PY' 2>/dev/null
import sys, tomllib
with open(sys.argv[1], "rb") as fh:
    doc = tomllib.load(fh)
for a in doc.get("actions", []):
    if a.get("id") == "remove":
        print(" ".join(a.get("command", [])))
        break
PY
)"
manifest_add_cmd="$(
  python3 - "${MANIFEST}" <<'PY' 2>/dev/null
import sys, tomllib
with open(sys.argv[1], "rb") as fh:
    doc = tomllib.load(fh)
for a in doc.get("actions", []):
    if a.get("id") == "add":
        print(" ".join(a.get("command", [])))
        break
PY
)"

t_it "remove action 已声明且非空"
if [[ -n "${manifest_remove_cmd}" ]]; then
  t_pass "remove command: ${manifest_remove_cmd:0:80}..."
else
  t_fail_note "manifest 未声明 remove action 或 command 为空"
fi

t_it "remove action 不再调用 forward remove --pick（一期 dead button）"
if [[ "${manifest_remove_cmd}" == *"remove --pick"* || "${manifest_remove_cmd}" == *"remove' '--pick"* ]]; then
  t_fail_note "remove action 指向一期未实现的 --pick（应改为打开 ports pane）"
else
  t_pass "未指向 --pick"
fi

t_it "remove action 走 pane open 路径（同 add）以在面板内完成交互式移除"
if [[ "${manifest_remove_cmd}" == *"plugin pane open"* && "${manifest_remove_cmd}" == *"--entrypoint ports"* ]]; then
  t_pass "remove 打开 ports pane"
else
  t_fail_note "remove action 必须打开 ports pane（plugin pane open --entrypoint ports）"
fi

t_it "add 与 remove 复用同一 pane open 路径（--plugin/--entrypoint/--placement 一致）"
pane_substr='plugin pane open --plugin zzjcool:forward --entrypoint ports --placement popup'
if [[ "${manifest_add_cmd}" == *"${pane_substr}"* && "${manifest_remove_cmd}" == *"${pane_substr}"* ]]; then
  t_pass "add/remove 的 pane open 片段一致"
else
  t_fail_note "add/remove 的 pane open 路径不一致（add=[${manifest_add_cmd:0:60}] remove=[${manifest_remove_cmd:0:60}]）"
fi

t_it "remove action 的 manifest 注释声明「移除经 pane/list 交互完成」"
# 避免 heredoc-in-if（shfmt 3.10 与 3.14 对该构造的 `; then` 归位不一致）：
# 先捕获到变量，再用 [[ ]] 判定，格式在两种 shfmt 版本下都唯一。
remove_comment_ok="no"
set +o errexit
remove_comment_out="$(
  python3 - "${MANIFEST}" <<'PY' 2>/dev/null
import sys, re
src = open(sys.argv[1], encoding="utf-8").read()
# 取 remove action 声明块之前的注释段（含 id 行）
m = re.search(r'((?:^#.*\n)+)\[\[actions\]\]\s*\nid = "remove"', src, re.M)
if m and "pane" in m.group(1) and "移除" in m.group(1):
    print("ok")
PY
)"
set -o errexit
if [[ "${remove_comment_out}" == "ok" ]]; then
  remove_comment_ok="yes"
fi
t_eq "yes" "${remove_comment_ok}" "remove action 块前声明了 pane/list 交互路径"

# --- OOTB：[[startup]] 钩子 + bootstrap action（任务 §2/§3） ---
t_describe "OOTB: [[startup]] hook 与 bootstrap action"

t_it "manifest 声明 [[startup]]，command 是 argv 数组且经 \$HERDR_PLUGIN_ROOT"
py_rc=0
set +o errexit
python3 - "${MANIFEST}" <<'PY' 2>/dev/null
import sys, tomllib
with open(sys.argv[1], "rb") as fh:
    doc = tomllib.load(fh)
startup = doc.get("startup") or []
assert len(startup) == 1, startup
argv = startup[0].get("command")
assert isinstance(argv, list) and argv, argv
joined = " ".join(argv)
assert "startup-hook.sh" in joined, joined
assert "HERDR_PLUGIN_ROOT" in joined, joined
PY
py_rc=$?
set -o errexit
if [[ "${py_rc}" -eq 0 ]]; then
  t_pass "startup hook 声明合规（argv 数组 + HERDR_PLUGIN_ROOT + startup-hook.sh）"
else
  t_fail_note "[[startup]] 缺失或结构不合规"
fi

t_it "startup hook 可以无副作用地跑通（隔离 HOME + dry-run 的等价路径）"
# manifest 的 startup argv 是本插件 scripts/startup-hook.sh；这里用同一脚本 + --dry-run
# 验证「钩子本身可执行且不落盘」。复用 unit 层已有覆盖，不重复造 env 拼装。
START_TMP="$(mktemp -d)"
cfg="${START_TMP}/config.toml"
printf 'theme = "dark"\n' >"${cfg}"
startup_ok="no"
set +o errexit
HERDR_PLUGIN_ROOT="$(cd "$(dirname "${MANIFEST}")" && pwd)" \
  HERDR_PLUGIN_STATE_DIR="${START_TMP}/state" \
  HERDR_PLUGIN_EVENT=startup \
  bash "${ROOT}/scripts/startup-hook.sh" --config "${cfg}" --dry-run >/dev/null 2>&1
s_rc=$?
set -o errexit
cfg_after="$(cat "${cfg}")"
if [[ "${s_rc}" -eq 0 && "${cfg_after}" == 'theme = "dark"' ]]; then
  startup_ok="yes"
fi
rm -rf "${START_TMP}"
t_eq "yes" "${startup_ok}" "startup hook 可执行且 --dry-run 无副作用"

t_it "bootstrap action 存在（title 'Port Forward: Setup UI'）"
py_rc=0
set +o errexit
python3 - "${MANIFEST}" <<'PY' 2>/dev/null
import sys, tomllib
with open(sys.argv[1], "rb") as fh:
    doc = tomllib.load(fh)
actions = {a.get("id"): a for a in doc.get("actions", [])}
assert "bootstrap" in actions, sorted(actions)
a = actions["bootstrap"]
assert a.get("title") == "Port Forward: Setup UI", a
argv = a.get("command")
assert isinstance(argv, list) and argv, argv
joined = " ".join(argv)
assert "bootstrap" in joined and "HERDR_PLUGIN_ROOT" in joined, joined
PY
py_rc=$?
set -o errexit
if [[ "${py_rc}" -eq 0 ]]; then
  t_pass "bootstrap action 声明合规"
else
  t_fail_note "bootstrap action 缺失或结构不合规"
fi

t_it "bootstrap action 与 forward bootstrap 子命令一致（CLI 是单一路径）"
man_bootstrap="$(
  python3 - "${MANIFEST}" <<'PY' 2>/dev/null
import sys, tomllib
with open(sys.argv[1], "rb") as fh:
    doc = tomllib.load(fh)
for a in doc.get("actions", []):
    if a.get("id") == "bootstrap":
        print(" ".join(a.get("command", [])))
        break
PY
)"
if [[ "${man_bootstrap}" == *"bin/forward\" bootstrap"* || "${man_bootstrap}" == *"bin/forward' 'bootstrap"* || "${man_bootstrap}" == *"bin/forward bootstrap"* ]]; then
  t_pass "action 走 bin/forward bootstrap"
else
  t_fail_note "bootstrap action 未走 bin/forward bootstrap（[${man_bootstrap:0:100}]）"
fi

t_done
