#!/usr/bin/env bash
# scripts/install-tabbar.sh — 帮用户往 herdr config.toml 的 [ui].tab_bar_right 加一条
# 「端口转发状态条」command 条目（RESEARCH §2.3 / SCOUT-FACTS §2.4）。
#
# 行为契约：
#   - 目标 config 路径参数化：--config PATH（默认 ~/.config/herdr/config.toml）
#   - 幂等：已存在本插件的条目（由注释标记识别）则不再插入（exit 0）
#   - 自愈升级：已装用户若是**旧格式**（command 里含 $HERDR_PLUGIN_ROOT 字面量），
#     就地替换为绝对路径格式（保留用户改过的 interval/timeout），重跑即修复
#   - 备份：真正的修改前先写 <config>.bak.<epoch>（dry-run 不写、不备份）
#   - dry-run：只打印将发生的变化，不落盘
#   - 非法 TOML / 未知参数：非 0 退出，绝不破坏原文件
#
# 生成的条目（TOML inline table，herdr TabBarRightEntryConfig::Command）：
#   { type = "command", command = "...", interval_seconds = 5, timeout_seconds = 2 }
#
# ⚠ command 的执行模型（SCOUT-FACTS §2.4，实测）：
#   tab_bar_right 的 command 由 herdr 直接经 `/bin/sh -lc` 执行，**env 里没有**
#   HERDR_PLUGIN_ROOT（那个 env 只在插件 action / pane / startup 命令里由 herdr 注入，
#   SCOUT-FACTS §2.2）。早期实现误把 §2.2 套到 tab bar 场景，写成
#   "$HERDR_PLUGIN_ROOT/bin/forward" —— env 展开为空串 → 实际执行 `/bin/forward`
#   → command 失败 → herdr 清空该条目（tab bar 静默空白）。复现：
#     env -i /bin/sh -c '"$HERDR_PLUGIN_ROOT/bin/forward" list --oneline'
#     → /bin/forward: No such file or directory
#   故 command 必须是**绝对路径**，且该路径是 **herdr server** 上的路径（command 在
#   server 上执行）。跨机（client A / server B）时用 --plugin-root 显式传 B 的路径；
#   不传则按本脚本的真实位置（<plugin_root>/scripts/）自动解析 —— 同机/在 server 上跑
#   时这个默认值永远正确。
#   render_oneline 输出纯文本无 ANSI，符合该执行模型。
set -Eeuo pipefail

readonly PROG_NAME="${0##*/}"
readonly DEFAULT_CONFIG="${XDG_CONFIG_HOME:-${HOME:-/nonexistent}/.config}/herdr/config.toml"
# 幂等标记：作为 TOML 注释写入，下次运行据此识别（不依赖 command 文本）
readonly MARKER_COMMENT="# herdr-forward: tab bar status entry (managed by scripts/install-tabbar.sh)"
# 旧格式特征串（单引号 = 字面量，**故意不展开**）：命中即触发自愈升级。
# shellcheck disable=SC2016  # 单引号内的 $HERDR_PLUGIN_ROOT 就是要匹配的字面量
readonly LEGACY_ENV_MARK='$HERDR_PLUGIN_ROOT'

# _resolve_self：解析本脚本的真实路径（跟随符号链接，不依赖 GNU readlink -f —— BSD
# readlink 无 -f）。herdr plugin link 会把整个插件目录做成符号链接，这里跟到真实树。
_resolve_self() {
  local src="${1-}" dir=""
  while [[ -L "${src}" ]]; do
    dir="$(cd -P "$(dirname "${src}")" && pwd)"
    src="$(readlink "${src}")"
    [[ "${src}" == /* ]] || src="${dir}/${src}"
  done
  local base=""
  base="$(cd -P "$(dirname "${src}")" && pwd)"
  printf '%s/%s' "${base}" "$(basename "${src}")"
}

# 本脚本位于 <plugin_root>/scripts/ → 上一级即插件根。
SELF_PATH="$(_resolve_self "${BASH_SOURCE[0]}")"
DEFAULT_PLUGIN_ROOT="$(cd -P "$(dirname "${SELF_PATH}")/.." && pwd)"

usage() {
  cat <<'EOF'
用法: install-tabbar.sh [选项]

把 herdr-forward 的状态条加到 herdr config.toml 的 [ui].tab_bar_right。

选项:
  --config PATH       目标 config 文件（默认: ~/.config/herdr/config.toml）
  --plugin-root PATH  插件在 **herdr server** 上的绝对路径（默认自动解析为本脚本所在
                      插件检出；跨机场景下必须传 server B 上的路径）
  --command CMD       tab bar 执行的 command 字符串（覆盖默认生成的绝对路径命令）
  --dry-run           只打印将要写入的内容，不修改文件
  --help              显示本帮助

幂等：重复执行不会重复插入；检测到旧格式（command 含 $HERDR_PLUGIN_ROOT 字面量，
在 tab bar 场景下无法解析）时会自动升级为绝对路径。每次真实修改都会先生成
<config>.bak.<epoch> 备份。
EOF
}

die() {
  printf '%s: error: %s\n' "${PROG_NAME}" "$*" >&2
  exit 1
}

# --- 参数解析（禁交互：未知参数直接报错，不等确认） ---
config_path=""
command_str=""
plugin_root=""
dry_run=0
while (($# > 0)); do
  case "$1" in
  --config)
    [[ $# -ge 2 ]] || die "--config 需要参数值"
    config_path="$2"
    shift 2
    ;;
  --plugin-root)
    [[ $# -ge 2 ]] || die "--plugin-root 需要参数值"
    plugin_root="$2"
    shift 2
    ;;
  --command)
    [[ $# -ge 2 ]] || die "--command 需要参数值"
    command_str="$2"
    shift 2
    ;;
  --dry-run)
    dry_run=1
    shift
    ;;
  --help | -h)
    usage
    exit 0
    ;;
  *)
    die "未知参数: $1（用 --help 查看用法）"
    ;;
  esac
done

[[ -n "${config_path}" ]] || config_path="${DEFAULT_CONFIG}"

if [[ -n "${plugin_root}" ]]; then
  # command 在 server 的 /bin/sh 里执行，其 cwd 不可知 → 相对路径不可靠，直接拒绝。
  [[ "${plugin_root}" == /* ]] ||
    die "--plugin-root 必须是绝对路径（收到 '${plugin_root}'）：tab bar command 由 herdr server 在任意 cwd 下执行。"
  # 规范化：去掉尾部斜杠（保留根 "/"）
  while [[ "${plugin_root}" != "/" && "${plugin_root}" == */ ]]; do
    plugin_root="${plugin_root%/}"
  done
else
  plugin_root="${DEFAULT_PLUGIN_ROOT}"
fi

# 默认 command：server 上的绝对路径 + 固定参数（不经 env、不经 shell 变量）
if [[ -z "${command_str}" ]]; then
  command_str="\"${plugin_root}/bin/forward\" list --oneline"
fi

if [[ ! -e "${plugin_root}/bin/forward" ]]; then
  printf '%s: 注意：%s/bin/forward 在本机不存在。跨机（client A / server B）时这是正常的；请确认该路径在 **herdr server** 上存在，否则 tab bar 仍会空白。\n' \
    "${PROG_NAME}" "${plugin_root}" >&2
fi

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    die "缺少依赖 '$1'${2:+，请先安装（$2）}"
  fi
}
require_cmd python3 "用于安全解析/生成 TOML（Python 3.11+）"
require_cmd mktemp
require_cmd date

if ! python3 -c 'import tomllib' 2>/dev/null; then
  die "python3 缺少 tomllib（需 Python 3.11+），无法安全处理 config.toml"
fi

# --- 目标目录准备 ---
config_dir="$(dirname "${config_path}")"
if [[ ! -d "${config_dir}" ]]; then
  if ((dry_run)); then
    printf '[dry-run] 将创建目录 %s\n' "${config_dir}"
  else
    mkdir -p "${config_dir}" || die "无法创建目录 ${config_dir}"
  fi
fi

tmp_file="$(mktemp)"
trap 'rm -f "${tmp_file}"' EXIT

# --- 计算出改动后的完整 TOML 文本 ---
# 退出码：0=有新内容 10=已安装（幂等） 其它=失败
new_content=""
rc=0
new_content="$(
  HF_CONFIG="${config_path}" HF_COMMAND="${command_str}" HF_MARKER="${MARKER_COMMENT}" \
    HF_LEGACY="${LEGACY_ENV_MARK}" \
    python3 - <<'PY'
import os
import sys
import tomllib

path = os.environ["HF_CONFIG"]
command = os.environ["HF_COMMAND"]
marker = os.environ["HF_MARKER"]
legacy = os.environ["HF_LEGACY"]

raw = b""
if os.path.exists(path):
    try:
        with open(path, "rb") as fh:
            raw = fh.read()
    except OSError as exc:
        print("cannot read {}: {}".format(path, exc), file=sys.stderr)
        sys.exit(2)

text = raw.decode() if raw else ""

# 语法校验（非空文件必须是合法 TOML）——非法即拒绝，绝不改写
if text.strip():
    try:
        tomllib.loads(text)
    except Exception as exc:
        print("invalid TOML in {}: {}".format(path, exc), file=sys.stderr)
        sys.exit(3)


def toml_string(value):
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\t", "\\t") + '"'


def sane_int(value, default, lo, hi):
    try:
        num = int(value)
    except Exception:
        return default
    return num if lo <= num <= hi else default


def locate_array(src, keyword):
    """定位 `keyword = [ ... ]` 的方括号位置（字符级扫描，跳过字符串内的括号）。"""
    key_at = src.find(keyword)
    if key_at == -1:
        return None
    eq_at = src.find("=", key_at)
    if eq_at == -1:
        return None
    open_at = src.find("[", eq_at)
    if open_at == -1:
        return None
    depth = 0
    in_str = False
    escape = False
    for pos in range(open_at, len(src)):
        ch = src[pos]
        if in_str:
            if escape:
                escape = False
            elif ch == "\\":
                escape = True
            elif ch == '"':
                in_str = False
            continue
        if ch == '"':
            in_str = True
        elif ch == "[":
            depth += 1
        elif ch == "]":
            depth -= 1
            if depth == 0:
                return (open_at, pos)
    return None


def split_top_level(inner):
    """按顶层逗号切分数组内容（不切字符串/嵌套表内的逗号）。"""
    parts = []
    depth = 0
    in_str = False
    escape = False
    start = 0
    for pos, ch in enumerate(inner):
        if in_str:
            if escape:
                escape = False
            elif ch == "\\":
                escape = True
            elif ch == '"':
                in_str = False
            continue
        if ch == '"':
            in_str = True
        elif ch in "{[":
            depth += 1
        elif ch in "}]":
            depth -= 1
        elif ch == "," and depth == 0:
            parts.append(inner[start:pos])
            start = pos + 1
    parts.append(inner[start:])
    return parts


def indent_block(text):
    return "\n".join("  " + line if line.strip() else line for line in text.splitlines())


def render_entry(interval, timeout):
    return '{ type = "command", command = %s, interval_seconds = %d, timeout_seconds = %d }' % (
        toml_string(command),
        interval,
        timeout,
    )


marker_present = any(line.strip() == marker for line in text.splitlines())

if marker_present:
    doc = tomllib.loads(text)
    entries = (doc.get("ui") or {}).get("tab_bar_right") or []
    if not isinstance(entries, list):
        entries = []

    # 已装用户的**旧格式**：我们管理的条目 command 仍是 $HERDR_PLUGIN_ROOT 字面量。
    legacy_entries = [
        e for e in entries if isinstance(e, dict) and legacy in str(e.get("command", ""))
    ]
    if len(legacy_entries) != 1:
        # 已是新格式（或存在我们无法安全判定的结构）→ 幂等 no-op
        sys.exit(10)

    old = legacy_entries[0]
    bounds = locate_array(text, "tab_bar_right")
    if bounds is None:
        print("marker present but tab_bar_right array not located", file=sys.stderr)
        sys.exit(4)
    open_at, close_at = bounds
    inner = text[open_at + 1 : close_at]

    interval = sane_int(old.get("interval_seconds"), 5, 1, 31536000)
    timeout = sane_int(old.get("timeout_seconds"), 2, 1, 3600)

    chunks = []
    replaced = 0
    for part in split_top_level(inner):
        stripped = part.strip()
        if not stripped:
            continue
        if marker in [line.strip() for line in stripped.splitlines()]:
            chunks.append(marker + "\n" + render_entry(interval, timeout))
            replaced += 1
        else:
            # 用户的其它条目原样保留（只规范化缩进）
            chunks.append(stripped)
    if replaced != 1:
        print("legacy marker entry not found in array (%d)" % replaced, file=sys.stderr)
        sys.exit(4)

    rebuilt = "[\n" + "".join(indent_block(chunk) + ",\n" for chunk in chunks) + "]"
    out = text[:open_at] + rebuilt + text[close_at + 1 :]
    if not out.endswith("\n"):
        out += "\n"
    sys.stdout.write(out)
    sys.exit(0)


entry = render_entry(5, 2)
block_lines = ["tab_bar_right = [", "  " + marker, "  " + entry + ",", "]"]

lines = text.splitlines()

# 找 [ui] 段
ui_start = None
ui_end = len(lines)
for idx, line in enumerate(lines):
    stripped = line.strip()
    if stripped == "[ui]":
        ui_start = idx
        continue
    if ui_start is not None and stripped.startswith("[") and stripped.endswith("]"):
        ui_end = idx
        break

if ui_start is None:
    # 无 [ui]：文件末尾新建
    if lines and lines[-1].strip() != "":
        lines.append("")
    lines.append("[ui]")
    lines.extend(block_lines)
else:
    # 有 [ui]：看段内是否已有 tab_bar_right
    arr_idx = None
    for idx in range(ui_start + 1, ui_end):
        if lines[idx].strip().startswith("tab_bar_right"):
            arr_idx = idx
            break

    if arr_idx is None:
        # 段内无该键：插到段尾（跳过尾部空行）
        insert_at = ui_end
        while insert_at - 1 > ui_start and lines[insert_at - 1].strip() == "":
            insert_at -= 1
        lines[insert_at:insert_at] = block_lines
    else:
        # 段内已有该键：定位数组边界，把我们的条目追加进去
        joined = "\n".join(lines)
        key_at = joined.find("tab_bar_right", sum(len(x) + 1 for x in lines[:arr_idx]))
        bounds = locate_array(joined, "tab_bar_right") if key_at != -1 else None
        if bounds is None:
            print("cannot locate tab_bar_right array", file=sys.stderr)
            sys.exit(4)
        open_at, close_at = bounds
        inner = joined[open_at + 1 : close_at].strip()
        rebuilt = "[\n"
        if inner:
            rebuilt += "  " + inner + ",\n"
        rebuilt += "  " + marker + "\n"
        rebuilt += "  " + entry + ",\n"
        rebuilt += "]"
        lines = (joined[:open_at] + rebuilt + joined[close_at + 1 :]).splitlines()

out = "\n".join(lines)
if not out.endswith("\n"):
    out += "\n"
sys.stdout.write(out)
PY
)" || rc=$?

if [[ "${rc}" -eq 10 ]]; then
  printf '%s: already installed（%s 已含 herdr-forward 条目，未做修改）\n' "${PROG_NAME}" "${config_path}"
  exit 0
fi
if [[ "${rc}" -ne 0 ]]; then
  die "处理 ${config_path} 失败（rc=${rc}）：未做任何修改；原因见上方 stderr（非法 TOML 或结构异常）。"
fi

# --- 自检：新内容必须是合法 TOML，且本插件条目恰好 1 条 ---
# 不用 `if ! python3 - <<'PY' … PY then` 形式：shfmt 3.10（宿主）与 3.14（容器）
# 对该 heredoc 后的 `then` 位置处理相反。改为先落 rc 再判（两版都稳定，
# 且不触发 SC2310：条件内 set -e 被禁用）。
printf '%s\n' "${new_content}" >"${tmp_file}" || die "无法写入临时文件"
selfcheck_rc=0
set +o errexit
python3 - "${tmp_file}" "${MARKER_COMMENT}" "${command_str}" <<'PY' 2>/dev/null
import sys
import tomllib

with open(sys.argv[1], "rb") as fh:
    raw = fh.read().decode()
with open(sys.argv[1], "rb") as fh:
    doc = tomllib.load(fh)
entries = (doc.get("ui") or {}).get("tab_bar_right") or []
if not isinstance(entries, list):
    sys.exit(1)
# 我们的条目必须恰好一条（command 匹配），允许用户原有其它条目共存
ours = [e for e in entries if isinstance(e, dict) and e.get("command") == sys.argv[3]]
if len(ours) != 1:
    sys.exit(1)
entry = ours[0]
if set(entry) < {"type", "command", "interval_seconds", "timeout_seconds"}:
    sys.exit(1)
if entry["type"] != "command":
    sys.exit(1)
if not (1 <= int(entry["interval_seconds"]) <= 31536000):
    sys.exit(1)
if not (1 <= int(entry["timeout_seconds"]) <= 3600):
    sys.exit(1)
if raw.count(sys.argv[2]) != 1:
    sys.exit(1)
PY
selfcheck_rc=$?
set -o errexit
if [[ "${selfcheck_rc}" -ne 0 ]]; then
  die "内部错误：生成的内容不是合法 TOML 或条目数异常，已中止（原文件未改）"
fi

# --- 落盘 ---
if ((dry_run)); then
  printf '[dry-run] 将写入 %s：\n---\n%s\n---\n' "${config_path}" "${new_content}"
  exit 0
fi

if [[ -f "${config_path}" ]]; then
  backup="${config_path}.bak.$(date +%s)"
  cp -p "${config_path}" "${backup}" || die "备份失败: ${backup}"
  printf '%s: 备份原文件 -> %s\n' "${PROG_NAME}" "${backup}"
fi

mv -f "${tmp_file}" "${config_path}" || die "写入失败: ${config_path}"
printf '%s: 已写入 %s\n' "${PROG_NAME}" "${config_path}"
printf '提示：执行 reload-config（或重启 herdr）后，tab bar 右侧会显示 ⇅<port> 状态条。\n'
