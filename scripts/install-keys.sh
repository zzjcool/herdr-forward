#!/usr/bin/env bash
# scripts/install-keys.sh — OOTB：帮用户往 herdr config.toml 追加本插件的
# [[keys.command]] 键绑定（官方 plugin_action 键位方式，见 SCOUT-FACTS §2.2）。
#
# 行为契约：
#   - 目标 config 路径参数化：--config PATH（默认 ~/.config/herdr/config.toml）
#   - 幂等：已存在本插件的键位（由注释标记识别）则不再插入（exit 0）
#   - 备份：真正的修改前先写 <config>.bak.<epoch>（dry-run 不写、不备份）
#   - dry-run：只打印将发生的变化，不落盘
#   - 非法 TOML / 未知参数：非 0 退出，绝不破坏原文件
#   - 键位冲突（同键被别的命令占用）只告警到 stderr，不阻塞（可用 --*-key 覆盖）
#
# 生成的条目（TOML array-of-tables，herdr 官方 schema）：
#   [[keys.command]]
#   key = "prefix+f"
#   type = "plugin_action"
#   command = "zzjcool:forward.add"
#   description = "Port Forward: Add…"
set -Eeuo pipefail

readonly PROG_NAME="${0##*/}"
readonly DEFAULT_CONFIG="${XDG_CONFIG_HOME:-${HOME:-/nonexistent}/.config}/herdr/config.toml"
# 幂等标记：作为 TOML 注释写入，下次运行据此识别（不依赖 key 文本）
readonly MARKER_COMMENT="# herdr-forward: keybindings (managed by scripts/install-keys.sh)"
readonly PLUGIN_ID="zzjcool:forward"

readonly DEFAULT_ADD_KEY="prefix+f"
readonly DEFAULT_LIST_KEY="prefix+shift+f"
readonly DEFAULT_DOCTOR_KEY="prefix+alt+f"

usage() {
  cat <<'EOF'
用法: install-keys.sh [选项]

把 herdr-forward 的键绑定加到 herdr config.toml（[[keys.command]] plugin_action）。

选项:
  --config PATH       目标 config 文件（默认: ~/.config/herdr/config.toml）
  --add-key KEY       打开 Port Forward 面板（默认: prefix+f）
  --list-key KEY      列出转发（默认: prefix+shift+f）
  --doctor-key KEY    探活检查（默认: prefix+alt+f）
  --dry-run           只打印将要写入的内容，不修改文件
  --help              显示本帮助

幂等：重复执行不会重复插入；每次真实修改都会先生成 <config>.bak.<epoch> 备份。
装完执行 reload-config（或重启 herdr）即生效。
EOF
}

die() {
  printf '%s: error: %s\n' "${PROG_NAME}" "$*" >&2
  exit 1
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    die "缺少依赖 '$1'${2:+，请先安装（$2）}"
  fi
}

# find_toml_python：找一个带 tomllib（Python 3.11+）的解释器写入 PY（找不到则 PY 为空）。
#   herdr server 由非交互 ssh / launchd 拉起时 PATH 常只有 /usr/bin:/bin：macOS 那里的
#   python3 是 3.9（无 tomllib），Homebrew 的又不在 PATH 里，所以还要看常见安装位置。
PY=""
find_toml_python() {
  local c=""
  for c in "${HERDR_FORWARD_PYTHON:-}" python3 python3.14 python3.13 python3.12 python3.11 \
    /opt/homebrew/bin/python3 /usr/local/bin/python3 /home/linuxbrew/.linuxbrew/bin/python3 \
    "${HOME:-/nonexistent}/.local/bin/python3" /opt/local/bin/python3; do
    [[ -n ${c} ]] || continue
    command -v "${c}" >/dev/null 2>&1 || continue
    if "${c}" -c 'import tomllib' 2>/dev/null; then
      PY="${c}"
      return 0
    fi
  done
  return 0
}

# --- 参数解析（禁交互：未知参数直接报错，不等确认） ---
config_path=""
add_key=""
list_key=""
doctor_key=""
dry_run=0
while (($# > 0)); do
  case "$1" in
  --config)
    [[ $# -ge 2 ]] || die "--config 需要参数值"
    config_path="$2"
    shift 2
    ;;
  --add-key)
    [[ $# -ge 2 ]] || die "--add-key 需要参数值（如 prefix+f）"
    add_key="$2"
    shift 2
    ;;
  --list-key)
    [[ $# -ge 2 ]] || die "--list-key 需要参数值（如 prefix+shift+f）"
    list_key="$2"
    shift 2
    ;;
  --doctor-key)
    [[ $# -ge 2 ]] || die "--doctor-key 需要参数值（如 prefix+alt+f）"
    doctor_key="$2"
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
[[ -n "${add_key}" ]] || add_key="${DEFAULT_ADD_KEY}"
[[ -n "${list_key}" ]] || list_key="${DEFAULT_LIST_KEY}"
[[ -n "${doctor_key}" ]] || doctor_key="${DEFAULT_DOCTOR_KEY}"

require_cmd mktemp
require_cmd date

find_toml_python
if [[ -z ${PY} ]]; then
  die "找不到带 tomllib 的 Python（需 3.11+），无法安全处理 config.toml。已找过 PATH 里的 python3 与 /opt/homebrew/bin、/usr/local/bin 等位置；请安装（macOS：brew install python）或用 HERDR_FORWARD_PYTHON=/path/to/python3 指定。"
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
# 程序先读进变量再 `-c` 执行：heredoc 放在 $( ) 里时，bash 3.2 会把正文当 shell 扫描，
# 正文里的反引号 / 单引号会让整个脚本解析失败。
PY_BUILD=""
IFS= read -r -d '' PY_BUILD <<'PY' || true
import os
import sys
import tomllib

path = os.environ["HF_CONFIG"]
marker = os.environ["HF_MARKER"]
plugin_id = os.environ["HF_PLUGIN_ID"]
keys = [
    (os.environ["HF_ADD_KEY"], "add", "Port Forward: Add / open panel"),
    (os.environ["HF_LIST_KEY"], "list", "Port Forward: List forwards"),
    (os.environ["HF_DOCTOR_KEY"], "doctor", "Port Forward: Doctor (probe tunnels)"),
]

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
existing = None
if text.strip():
    try:
        existing = tomllib.loads(text)
    except Exception as exc:
        print("invalid TOML in {}: {}".format(path, exc), file=sys.stderr)
        sys.exit(3)

# 幂等：注释标记已存在即认为是本插件安装过
if any(line.strip() == marker for line in text.splitlines()):
    sys.exit(10)


def toml_string(value):
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\t", "\\t") + '"'


# 冲突检测（只告警，不阻塞）：同键已被别的命令占用 -> 提示用户换键
if existing is not None:
    ours_cmds = {"%s.%s" % (plugin_id, action) for _, action, _ in keys}
    occupied = {}
    for entry in (existing.get("keys") or {}).get("command") or []:
        if isinstance(entry, dict) and entry.get("command") not in ours_cmds:
            occupied.setdefault(entry.get("key"), entry.get("command"))
    for key, _action, _desc in keys:
        if key in occupied:
            print(
                "warning: key %r is already bound to %r in %s; install anyway "
                "(pass --add-key/--list-key/--doctor-key to pick another key)"
                % (key, occupied[key], path),
                file=sys.stderr,
            )

lines = text.splitlines()
if lines and lines[-1].strip() != "":
    lines.append("")
lines.append(marker)
for key, action, desc in keys:
    lines.append("[[keys.command]]")
    lines.append("key = " + toml_string(key))
    lines.append('type = "plugin_action"')
    lines.append("command = " + toml_string("%s.%s" % (plugin_id, action)))
    lines.append("description = " + toml_string(desc))
    lines.append("")

out = "\n".join(lines)
if not out.endswith("\n"):
    out += "\n"
sys.stdout.write(out)
PY
new_content=""
rc=0
new_content="$(
  HF_CONFIG="${config_path}" HF_MARKER="${MARKER_COMMENT}" HF_PLUGIN_ID="${PLUGIN_ID}" \
    HF_ADD_KEY="${add_key}" HF_LIST_KEY="${list_key}" HF_DOCTOR_KEY="${doctor_key}" \
    "${PY}" -c "${PY_BUILD}"
)" || rc=$?

if [[ "${rc}" -eq 10 ]]; then
  printf '%s: already installed（%s 已含 herdr-forward 键位，未做修改）\n' "${PROG_NAME}" "${config_path}"
  exit 0
fi
if [[ "${rc}" -ne 0 ]]; then
  die "处理 ${config_path} 失败（rc=${rc}）：文件可能不是合法 TOML，未做任何修改"
fi

# --- 自检：新内容必须是合法 TOML，且本插件键位恰好 3 条、标记恰好 1 处 ---
printf '%s\n' "${new_content}" >"${tmp_file}" || die "无法写入临时文件"
selfcheck_rc=0
set +o errexit
"${PY}" - "${tmp_file}" "${MARKER_COMMENT}" "${PLUGIN_ID}" \
  "${add_key}" "${list_key}" "${doctor_key}" <<'PY' 2>/dev/null
import sys
import tomllib

with open(sys.argv[1], "rb") as fh:
    raw = fh.read().decode()
with open(sys.argv[1], "rb") as fh:
    doc = tomllib.load(fh)
marker = sys.argv[2]
plugin_id = sys.argv[3]
want = [plugin_id + "." + a for a in ("add", "list", "doctor")]
entries = [e for e in ((doc.get("keys") or {}).get("command") or [])
           if isinstance(e, dict) and str(e.get("command", "")).startswith(plugin_id + ".")]
if sorted(e.get("command") for e in entries) != sorted(want):
    sys.exit(1)
for e in entries:
    if e.get("type") != "plugin_action":
        sys.exit(1)
    if not e.get("key") or not e.get("description"):
        sys.exit(1)
if raw.count(marker) != 1:
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
printf '提示：执行 reload-config（或重启 herdr）后，%s / %s / %s 即可用。\n' \
  "${add_key}" "${list_key}" "${doctor_key}"
