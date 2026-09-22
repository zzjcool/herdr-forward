#!/usr/bin/env bash
# scripts/install-tabbar.sh — 帮用户往 herdr config.toml 的 [ui].tab_bar_right 加一条
# 「端口转发状态条」command 条目（RESEARCH §2.3 / SCOUT-FACTS §2.4）。
#
# 行为契约：
#   - 目标 config 路径参数化：--config PATH（默认 ~/.config/herdr/config.toml）
#   - 幂等：已存在本插件的条目（由注释标记识别）则不再插入（exit 0）
#   - 备份：真正的修改前先写 <config>.bak.<epoch>（dry-run 不写、不备份）
#   - dry-run：只打印将发生的变化，不落盘
#   - 非法 TOML / 未知参数：非 0 退出，绝不破坏原文件
#
# 生成的条目（TOML inline table，herdr TabBarRightEntryConfig::Command）：
#   { type = "command", command = "...", interval_seconds = 5, timeout_seconds = 2 }
# ⚠ command 经 /bin/sh -lc 执行、取 stdout 最后一行（SCOUT-FACTS §2.4）→
#   默认命令用 $HERDR_PLUGIN_ROOT 包装（env 由 herdr 官方注入，SCOUT-FACTS §2.2）；
#   render_oneline 输出纯文本无 ANSI，符合该执行模型。
set -Eeuo pipefail

readonly PROG_NAME="${0##*/}"
readonly DEFAULT_CONFIG="${XDG_CONFIG_HOME:-${HOME:-/nonexistent}/.config}/herdr/config.toml"
# 幂等标记：作为 TOML 注释写入，下次运行据此识别（不依赖 command 文本）
readonly MARKER_COMMENT="# herdr-forward: tab bar status entry (managed by scripts/install-tabbar.sh)"
# 注意：这里要生成字面量 $HERDR_PLUGIN_ROOT（由 herdr 注入的 env），故需转义
readonly DEFAULT_COMMAND="\"\$HERDR_PLUGIN_ROOT/bin/forward\" list --oneline"

usage() {
  cat <<'EOF'
用法: install-tabbar.sh [选项]

把 herdr-forward 的状态条加到 herdr config.toml 的 [ui].tab_bar_right。

选项:
  --config PATH     目标 config 文件（默认: ~/.config/herdr/config.toml）
  --command CMD     tab bar 执行的 command 字符串（默认读 $HERDR_PLUGIN_ROOT/bin/forward）
  --dry-run         只打印将要写入的内容，不修改文件
  --help            显示本帮助

幂等：重复执行不会重复插入；每次真实修改都会先生成 <config>.bak.<epoch> 备份。
EOF
}

die() {
  printf '%s: error: %s\n' "${PROG_NAME}" "$*" >&2
  exit 1
}

# --- 参数解析（禁交互：未知参数直接报错，不等确认） ---
config_path=""
command_str=""
dry_run=0
while (($# > 0)); do
  case "$1" in
  --config)
    [[ $# -ge 2 ]] || die "--config 需要参数值"
    config_path="$2"
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
[[ -n "${command_str}" ]] || command_str="${DEFAULT_COMMAND}"

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
    python3 - <<'PY'
import os
import sys
import tomllib

path = os.environ["HF_CONFIG"]
command = os.environ["HF_COMMAND"]
marker = os.environ["HF_MARKER"]

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

# 幂等：注释标记已存在即认为是本插件安装过
if any(line.strip() == marker for line in text.splitlines()):
    sys.exit(10)


def toml_string(value):
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\t", "\\t") + '"'


entry = '{ type = "command", command = %s, interval_seconds = 5, timeout_seconds = 2 }' % toml_string(command)
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
        # 段内已有该键：定位数组边界（字符级扫描，跳过字符串内的括号）
        joined = "\n".join(lines)
        key_at = joined.find("tab_bar_right", sum(len(x) + 1 for x in lines[:arr_idx]))
        eq_at = joined.find("=", key_at)
        open_at = joined.find("[", eq_at)
        if open_at == -1:
            print("cannot locate tab_bar_right array", file=sys.stderr)
            sys.exit(4)
        depth = 0
        in_str = False
        escape = False
        close_at = -1
        for pos in range(open_at, len(joined)):
            ch = joined[pos]
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
                    close_at = pos
                    break
        if close_at == -1:
            print("cannot locate tab_bar_right array end", file=sys.stderr)
            sys.exit(4)

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
  die "处理 ${config_path} 失败（rc=${rc}）：文件可能不是合法 TOML，未做任何修改"
fi

# --- 自检：新内容必须是合法 TOML，且本插件条目恰好 1 条 ---
printf '%s\n' "${new_content}" >"${tmp_file}" || die "无法写入临时文件"
if ! python3 - "${tmp_file}" "${MARKER_COMMENT}" "${command_str}" <<'PY' 2>/dev/null; then
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
