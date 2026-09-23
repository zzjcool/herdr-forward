#!/usr/bin/env bash
# scripts/setup-client.sh — 跨机（client A attach 到 server B）**一键配置 client 侧**。
#
# 用户场景：herdr client 在 A（本机），herdr server 在 B（远程，插件装在 B）。
# A 侧只需要 config.toml 里两样东西：
#   ① [ui].tab_bar_right command 条目 —— command 由 **server B** 在 /bin/sh 下执行，
#      所以必须写 B 上的插件根 + B 上的 state 目录（跨机语义见 install-tabbar.sh 头注）；
#   ② [[keys.command]] plugin_action 绑定 —— 触发时 herdr 让 server 上的插件响应，
#      **A 不需要安装插件本体**。
#
# 本脚本是**编排层**：只做参数校验 + 把两个已有安装器串起来 + 汇总 / 前置条件 checklist。
# 真正的 TOML 写入、幂等、备份、自愈升级都在 install-tabbar.sh / install-keys.sh 里
# （各自有独立测试）—— 本脚本不重复实现，也不直接碰文件。
#
# 能力边界（诚实标注，SCOUT-FACTS 已确认）：
#   A 上的任何进程都无法枚举 B 的插件安装状态（herdr socket API 没有 machine/plugin
#   枚举，插件也不跨机执行）。因此「B 上是否已装插件 / ssh 免密 / jq」只能**打印成
#   checklist 让用户确认**，脚本无法自动验证。脚本会做一次**尽力而为**的本机探测
#   （同机用户 A == B 时命中），探测失败绝不阻塞、绝不影响退出码。
#
# 用法（A 上，无需 A 安装插件）：
#   curl -fsSL https://raw.githubusercontent.com/zzjcool/herdr-forward/main/scripts/setup-client.sh \
#     | bash -s -- --server-root <B 上的插件根>
# 或 git clone 后本地跑（会用同目录的安装器，不下载）：
#   ./scripts/setup-client.sh --config ~/.config/herdr/config.toml \
#     --server-root <B 上的插件根> --server-state-dir <B 上的 state 目录>
set -Eeuo pipefail

readonly PROG_NAME="${0##*/}"
readonly PLUGIN_ID="zzjcool:forward"
readonly RAW_BASE_DEFAULT="https://raw.githubusercontent.com/zzjcool/herdr-forward/main/scripts"
readonly DEFAULT_CONFIG="${XDG_CONFIG_HOME:-${HOME:-/nonexistent}/.config}/herdr/config.toml"

usage() {
  cat <<'EOF'
用法: setup-client.sh [选项]

在 **herdr client（A）** 上一条命令配好跨机 UI：把 tab bar 状态条 + 键绑定写进 A 的
herdr config.toml。两个条目都指向 **herdr server（B）** 上的插件，A 不需要安装插件本体。

选项:
  --config PATH            A（本机）的 config.toml（默认: $XDG_CONFIG_HOME/herdr/config.toml，
                           退 $HOME/.config/herdr/config.toml）
  --server-root PATH       **herdr server（B）** 上的插件根绝对路径。要装 tab bar 时必填
                           （tab bar command 在 B 上执行，A 的本地路径对 B 无意义）。
                           例: /home/me/.config/herdr/plugins/github/zzjcool-forward-xxxxxxxx
  --server-state-dir PATH  **server（B）** 上的插件 state 目录绝对路径
                           （默认从 --server-root 里的 herdr-plugin.toml 的 id 推导：
                           <XDG_STATE_HOME>/herdr/plugins/<id 的 ':' → '%3A'>；
                           推导不出来时退回 .../herdr/plugins/zzjcool%3Aforward）。
  --no-keys               跳过键绑定安装
  --no-tabbar             跳过 tab bar 状态条安装（此时不需要 --server-root）
  --dry-run               只预览，不修改文件
  --help                  显示本帮助

幂等：重复执行不会重复插入（写入层幂等由两个安装器保证），每次真实修改前各自备份
<config>.bak.<epoch>。装完在 herdr 里按 prefix+q（reload_config）或运行
`herdr server reload-config` 生效。

示例（跨机 A → B）:
  setup-client.sh --server-root /home/me/.config/herdr/plugins/github/zzjcool-forward-ab12cd34
EOF
}

die() {
  local code="$1"
  shift
  printf '%s: error: %s\n' "${PROG_NAME}" "$*" >&2
  exit "${code}"
}

note() { printf '%s: %s\n' "${PROG_NAME}" "$*"; }

# --- 参数解析（禁交互：未知参数直接报错，绝不等确认） ---
config_path=""
server_root=""
server_state_dir=""
dry_run=0
do_tabbar=1
do_keys=1
while (($# > 0)); do
  case "$1" in
  --config)
    [[ $# -ge 2 ]] || die 2 "--config 需要参数值"
    config_path="$2"
    shift 2
    ;;
  --server-root)
    [[ $# -ge 2 ]] || die 2 "--server-root 需要参数值（server B 上的插件根绝对路径）"
    server_root="$2"
    shift 2
    ;;
  --server-state-dir)
    [[ $# -ge 2 ]] || die 2 "--server-state-dir 需要参数值"
    server_state_dir="$2"
    shift 2
    ;;
  --dry-run)
    dry_run=1
    shift
    ;;
  --no-keys)
    do_keys=0
    shift
    ;;
  --no-tabbar)
    do_tabbar=0
    shift
    ;;
  --help | -h)
    usage
    exit 0
    ;;
  *)
    die 2 "未知参数: $1（用 --help 查看用法）"
    ;;
  esac
done

[[ -n "${config_path}" ]] || config_path="${DEFAULT_CONFIG}"

if ((do_tabbar == 0 && do_keys == 0)); then
  die 2 "--no-tabbar 与 --no-keys 同时指定：没有可执行的安装步骤，请去掉其一。"
fi
if ((do_tabbar == 1)) && [[ -z "${server_root}" ]]; then
  die 2 "缺少 --server-root（server B 上的插件根绝对路径）。
   tab bar 的 command 在 herdr server 上执行，必须写 server 上的真实路径；A 上的路径对 B 无意义。
   找法：在 B 上运行 \`herdr plugin list\`，或直接看 B 的 ~/.config/herdr/plugins.json 里的 plugin_root。
   只想要键绑定（不需要 server 路径）时加 --no-tabbar。"
fi

# --- 安装器定位：优先同目录（git clone / 插件检出场景），否则按需下载（curl | bash 场景） ---
# ⚠ `curl … | bash -s` 时脚本从 stdin 读入，`BASH_SOURCE[0]` **未定义**，
# 在 set -u 下直接展开会 "unbound variable" 把自己打死 —— 故用 `${BASH_SOURCE[0]:-}`，
# 空值表示 stdin 形态（此时一定走下载分支）。
SELF_PATH="${BASH_SOURCE[0]:-}"
SELF_DIR=""
if [[ -n "${SELF_PATH}" ]]; then
  SELF_DIR="$(cd "$(dirname "${SELF_PATH}")" && pwd)"
fi
readonly SELF_PATH SELF_DIR

download_dir=""
cleanup() {
  if [[ -n "${download_dir}" ]]; then
    rm -rf "${download_dir}"
  fi
}
trap cleanup EXIT

TABBAR_INSTALLER=""
KEYS_INSTALLER=""

locate_installers() {
  if [[ -n "${SELF_DIR}" && -f "${SELF_DIR}/install-tabbar.sh" && -f "${SELF_DIR}/install-keys.sh" ]]; then
    TABBAR_INSTALLER="${SELF_DIR}/install-tabbar.sh"
    KEYS_INSTALLER="${SELF_DIR}/install-keys.sh"
    return 0
  fi

  # curl | bash：标准输入是脚本，同目录没有安装器 —— 按需下载两个安装器到临时目录。
  # 用 HF_RAW_BASE 可指向镜像 / 本地目录（测试用 file://）。
  local raw_base="${HF_RAW_BASE:-${RAW_BASE_DEFAULT}}"
  if ! command -v curl >/dev/null 2>&1; then
    die 1 "缺少依赖 'curl'（用于下载安装器）。请安装 curl，或改用 git clone 后本地跑 scripts/setup-client.sh。"
  fi
  download_dir="$(mktemp -d)"
  local name=""
  for name in install-tabbar.sh install-keys.sh; do
    if ! curl -fsSL "${raw_base}/${name}" -o "${download_dir}/${name}" 2>/dev/null; then
      die 1 "无法从 ${raw_base}/${name} 下载安装器。
   网络不可达 / URL 不对时，请改用：git clone https://github.com/zzjcool/herdr-forward && \\
     ./herdr-forward/scripts/setup-client.sh --server-root <B 上的插件根>
   （本地检出会直接使用同目录的安装器，不需要联网。）"
    fi
    [[ -s "${download_dir}/${name}" ]] ||
      die 1 "下载到的 ${name} 为空（${raw_base}/${name}）。请检查 URL 或改用 git clone 后本地跑。"
  done
  TABBAR_INSTALLER="${download_dir}/install-tabbar.sh"
  KEYS_INSTALLER="${download_dir}/install-keys.sh"
}

# --- state 目录推导：默认从 server-root 的 manifest id 推（':' → '%3A'） ---
# 与 install-tabbar.sh 的默认值同构，但**主机是 server B** —— 故这里用 server-root 的
# manifest 而不是本机路径；id 变了（fork / 改名）时目录跟着变，不是硬编码。
derive_state_dir() {
  local root="$1" id="" encoded=""
  if [[ -f "${root}/herdr-plugin.toml" ]]; then
    id="$(
      python3 - "${root}/herdr-plugin.toml" <<'PY' 2>/dev/null
import sys
try:
    import tomllib
    with open(sys.argv[1], "rb") as fh:
        doc = tomllib.load(fh)
except Exception:
    raise SystemExit(1)
ident = doc.get("id")
print(ident if isinstance(ident, str) and ident else "")
PY
    )" || id=""
    if [[ -z "${id}" ]]; then
      # python3/tomllib 不可用时的退化路径：只取第一处 `id = "..."`。
      id="$(sed -n 's/^[[:space:]]*id[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' \
        "${root}/herdr-plugin.toml" 2>/dev/null | head -1 || true)"
    fi
  fi
  if [[ -z "${id}" ]]; then
    note "提示：读不到 ${root}/herdr-plugin.toml 的 id，state 目录按默认插件 id 推导（${PLUGIN_ID}）。"
    id="${PLUGIN_ID}"
  fi
  encoded="${id//:/%3A}"
  printf '%s/herdr/plugins/%s' "${XDG_STATE_HOME:-${HOME:-/nonexistent}/.local/state}" "${encoded}"
}

state_dir_source="arg"
if [[ -z "${server_state_dir}" ]]; then
  state_dir_source="derived"
  server_state_dir="$(derive_state_dir "${server_root:-${SELF_DIR:-.}/..}")"
fi

# --- B 侧可用性探测（尽力而为：只打印，绝不阻塞） ---
# 同机用户（A == B）时能命中；跨机时必然探测不到 —— 这不是错误，只提示去 server 确认。
# 探测目标：herdr 的 plugins.json 里有本插件，或 plugins/ 下已有 managed checkout / link 目录。
#
# 输出式函数（恒 return 0 并打印 yes/no）：调用处不在 if/|| 条件里直接调用函数，
# 避开 shellcheck SC2310（set -e 在条件中被禁用的误用模式）。
probe_plugin_present() {
  local cfg_home="${XDG_CONFIG_HOME:-${HOME:-/nonexistent}/.config}"
  local plugins_json="${cfg_home}/herdr/plugins.json"
  local plugins_dir="${cfg_home}/herdr/plugins"
  local encoded="${PLUGIN_ID//:/%3A}"
  local candidate=""

  if [[ -f "${plugins_json}" ]]; then
    if command -v python3 >/dev/null 2>&1; then
      local hit_rc=0
      set +o errexit
      python3 - "${plugins_json}" "${PLUGIN_ID}" <<'PY' 2>/dev/null
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        data = json.load(fh)
except Exception:
    raise SystemExit(1)
entries = data if isinstance(data, list) else []
hit = any(isinstance(e, dict) and e.get("plugin_id") == sys.argv[2] for e in entries)
raise SystemExit(0 if hit else 1)
PY
      hit_rc=$?
      set -o errexit
      if [[ "${hit_rc}" -eq 0 ]]; then
        printf 'yes\n'
        return 0
      fi
    elif grep -q "\"plugin_id\"[[:space:]]*:[[:space:]]*\"${PLUGIN_ID}\"" "${plugins_json}" 2>/dev/null; then
      printf 'yes\n'
      return 0
    fi
  fi

  # 目录形态：managed checkout（plugins/github/*forward*）或 link 目录（plugins/config/<encoded>）
  if [[ -d "${plugins_dir}/config/${encoded}" ]]; then
    printf 'yes\n'
    return 0
  fi
  for candidate in "${plugins_dir}/github/"*forward*; do
    if [[ -d "${candidate}" ]]; then
      printf 'yes\n'
      return 0
    fi
  done
  printf 'no\n'
  return 0
}

# --- 主流程：依次调用两个安装器（顺序固定：tab bar → 键位） ---
step=0
total=0
((do_tabbar == 1)) && total=$((total + 1))
((do_keys == 1)) && total=$((total + 1))

dry_flag=()
if ((dry_run == 1)); then
  dry_flag=(--dry-run)
fi

locate_installers

printf '%s: herdr-forward 跨机 client 一键配置（%d 步，config=%s）\n' \
  "${PROG_NAME}" "${total}" "${config_path}"
if ((do_tabbar == 1)); then
  printf '  server 插件根: %s\n' "${server_root}"
  if [[ "${state_dir_source}" == "derived" ]]; then
    printf '  server state 目录: %s（由 server-root 的 manifest id 推导）\n' "${server_state_dir}"
  else
    printf '  server state 目录: %s\n' "${server_state_dir}"
  fi
fi

if ((do_tabbar == 1)); then
  step=$((step + 1))
  printf '\n== [%d/%d] tab bar 状态条（command 在 herdr server 上执行）==\n' "${step}" "${total}"
  bash "${TABBAR_INSTALLER}" --config "${config_path}" \
    --plugin-root "${server_root}" --state-dir "${server_state_dir}" "${dry_flag[@]}" ||
    die 1 "install-tabbar.sh 失败（见上方输出）。config 未被部分破坏；修正后重跑本命令即可。"
fi

if ((do_keys == 1)); then
  step=$((step + 1))
  printf '\n== [%d/%d] 键绑定（plugin_action；由 server 上的插件响应，A 无需装插件）==\n' \
    "${step}" "${total}"
  bash "${KEYS_INSTALLER}" --config "${config_path}" "${dry_flag[@]}" ||
    die 1 "install-keys.sh 失败（见上方输出）。config 未被部分破坏；修正后重跑本命令即可。"
fi

# --- 汇总 ---
cat <<EOF

== 汇总 ==
- config: ${config_path}
EOF
if ((do_tabbar == 1)); then
  printf -- '- tab bar: 已装（command = %s/bin/forward list --oneline，在 server 上执行）\n' "${server_root}"
  printf -- '- tab bar state: %s\n' "${server_state_dir}"
else
  printf -- '- tab bar: 跳过（--no-tabbar）\n'
fi
if ((do_keys == 1)); then
  printf -- '- 键位: 已装（prefix+f 面板 / prefix+shift+f 列表 / prefix+alt+f 探活）\n'
else
  printf -- '- 键位: 跳过（--no-keys）\n'
fi
if ((dry_run == 1)); then
  printf -- '- 模式: dry-run（磁盘未改动）\n'
fi

cat <<EOF

== 下一步 ==
1. 让配置生效：在 herdr 里按 prefix+q（reload_config），或运行：
     herdr server reload-config
2. 之后：prefix+f 打开 Port Forward 面板 / prefix+shift+f 列出转发 / prefix+alt+f 探活检查。
3. tab bar 右侧出现 ⇅<port> 即表示状态条生效（无活跃转发时为空）。

== B（herdr server）侧插件可用性探测（尽力而为）==
EOF
probe_result="$(probe_plugin_present)"
if [[ "${probe_result}" == "yes" ]]; then
  printf '✅ 在 herdr 配置目录里探测到 %s 的安装（managed checkout 或 link）。\n' "${PLUGIN_ID}"
  printf '   若 herdr server 就是本机，前置条件已满足；跨机时这只是本机的副本，仍需看下方清单。\n'
else
  printf 'ℹ️  未在本机探测到 %s 的安装。\n' "${PLUGIN_ID}"
  printf '   若 herdr server 在另一台机器，请在 server 上确认：herdr plugin list 里有 %s\n' "${PLUGIN_ID}"
  printf '   （没有就先装：herdr plugin install zzjcool/herdr-forward）。\n'
fi

cat <<EOF

== B 侧前置条件检查清单（无法从 A 自动检测，请逐条确认）==
[ ] herdr server（B）上已装插件：\`herdr plugin list\` 里有 ${PLUGIN_ID}
[ ] server（B）上的插件根 = ${server_root:-<未提供：用了 --no-tabbar>}
[ ] server（B）上有 jq（本插件依赖）
[ ] server（B）上有 ssh（隧道依赖）
[ ] A → B 可非交互登录：已配置 ssh 免密（key-based）或在 herdr 里已能 attach
EOF
