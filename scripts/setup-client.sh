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
#   A 上的任何进程都无法*本地*枚举 B 的插件安装状态（herdr socket API 没有 machine/plugin
#   枚举，插件也不跨机执行）。但 A attach B 走的就是 **SSH** —— 所以当用户给出
#   `--server-host <ssh target>` 时，本脚本会**通过 ssh 真实探测 B**（timeout 15，
#   BatchMode 只读，`ssh -n`）：探到插件 → 自动推导 B 的插件根 + state 目录（用户连
#   --server-root 都不用传）；没探到 → 把可直接复制的安装命令递到手上（**不自动装**，
#   尊重用户）；探测失败（连不上/没权限）→ 降级成本机尽力探测 + 手工 checklist，
#   绝不阻塞安装。
#   不传 --server-host 时行为不变（本机尽力探测 + checklist，向后兼容）。
#
# 用法（A 上，无需 A 安装插件）：
#   curl -fsSL https://raw.githubusercontent.com/zzjcool/herdr-forward/main/scripts/setup-client.sh \
#     | bash -s -- --server-host <B 的 ssh target>
# 或 git clone 后本地跑（会用同目录的安装器，不下载）：
#   ./scripts/setup-client.sh --config ~/.config/herdr/config.toml --server-host me@b
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
  --server-host TARGET     **herdr server（B）** 的 ssh target，形如 user@host 或 user@host:port。
                           给出后会通过 ssh 真实探测 B（只读，timeout 15，BatchMode）：
                             · B 已装插件 → 自动探测 B 的插件根与 state 目录，
                               --server-root/--server-state-dir 都不用传；
                             · B 未装插件 → 打印可复制的安装命令（不自动装）；
                             · 连不上/无权限 → 降级为本机探测 + checklist，绝不阻塞。
                           不传则维持旧行为（本机尽力探测 + checklist）。
  --server-root PATH       **herdr server（B）** 上的插件根绝对路径。要装 tab bar 时必填
                           （tab bar command 在 B 上执行，A 的本地路径对 B 无意义）。
                           给了 --server-host 且探测命中时可省（自动填入）。
                           例: /home/me/.config/herdr/plugins/github/zzjcool-forward-xxxxxxxx
  --server-state-dir PATH  **server（B）** 上的插件 state 目录绝对路径
                           （默认：--server-host 探测到的值；否则从 --server-root 里的
                           herdr-plugin.toml 的 id 推导：<XDG_STATE_HOME>/herdr/plugins/<id 的 ':' → '%3A'>；
                           推导不出来时退回 .../herdr/plugins/zzjcool%3Aforward）。
  --no-keys               跳过键绑定安装
  --no-tabbar             跳过 tab bar 状态条安装（此时不需要 --server-root）
  --dry-run               只预览，不修改文件
  --help                  显示本帮助

幂等：重复执行不会重复插入（写入层幂等由两个安装器保证），每次真实修改前各自备份
<config>.bak.<epoch>。装完在 herdr 里按 prefix+q（reload_config）或运行
`herdr server reload-config` 生效。

示例（跨机 A → B，路径全自动）:
  setup-client.sh --server-host me@b-host
旧用法（不传 --server-host：本机探测 + checklist）:
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

# kv_get（多行文本 + KEY -> 值）与探测实现由 lib/ssh-probe.sh 提供（单一权威，脚本只是消费方）。
# 见下方 load_ssh_probe_lib：checkout 形态 source 同仓库的 lib/，curl|bash 形态按需下载。
# --- 安装器定位：优先同目录（git clone / 插件检出场景），否则按需下载（curl | bash 场景） ---

# --- 参数解析（禁交互：未知参数直接报错，绝不等确认） ---
config_path=""
server_root=""
server_state_dir=""
server_host=""
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
  --server-host)
    [[ $# -ge 2 ]] || die 2 "--server-host 需要参数值（B 的 ssh target，形如 user@host[:port]）"
    server_host="$2"
    [[ -n "${server_host}" ]] || die 2 "--server-host 不能为空（不要探测 B 时请去掉该参数）"
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

# ⚠ `curl … | bash -s` 时脚本从 stdin 读入，`BASH_SOURCE[0]` **未定义**，
# 在 set -u 下直接展开会 "unbound variable" 把自己打死 —— 故用 `${BASH_SOURCE[0]:-}`，
# 空值表示 stdin 形态（此时一定走下载分支）。
SELF_PATH="${BASH_SOURCE[0]:-}"
SELF_DIR=""
if [[ -n "${SELF_PATH}" ]]; then
  SELF_DIR="$(cd "$(dirname "${SELF_PATH}")" && pwd)"
fi
readonly SELF_PATH SELF_DIR

# 下载暂存目录：安装器与 ssh 探测库**共用**一个，退出时统一清理（用完即弃，不落用户磁盘）。
download_dir=""
ensure_download_dir() {
  if [[ -z "${download_dir}" ]]; then
    download_dir="$(mktemp -d)"
  fi
}
cleanup() {
  if [[ -n "${download_dir}" ]]; then
    rm -rf "${download_dir}"
  fi
}
trap cleanup EXIT

# --- ssh 探测 B（仅当给了 --server-host）：只读、超时、失败降级，绝不阻塞安装 ---
# 探测策略（超时秒数）由本脚本拥有：lib/ssh-probe.sh 幂等复用同值，不覆盖调用方设定。
# 每次探测都是 `timeout 15 ssh -n -o BatchMode=yes -o ConnectTimeout=8 <host> '<远端命令>'`
# （`-n` 必需：curl|bash -s 时 stdin 是脚本本体，ssh 不读它就等于吃掉剩余脚本）
# （本机没有 `timeout` 时至少仍有 ConnectTimeout=8 兜底建连阶段；不静默降级）。
readonly SSH_PROBE_TIMEOUT=15

# --- 加载 ssh 探测库（ssh_probe_parse_target / ssh_probe_run / ssh_probe_plugin / kv_get） ---
#   * checkout（git clone / 插件检出）：直接用同仓库的 lib/ssh-probe.sh，无需联网；
#   * curl|bash：**按需**下载 —— 只有真的要探测 B（给了 --server-host）时才拉库，
#     保证「旧用法（不传 --server-host）」不必联网、行为与提取前完全一致。
SSH_PROBE_LIB_LOADED=0
load_ssh_probe_lib() {
  if ((SSH_PROBE_LIB_LOADED == 1)); then
    return 0
  fi
  local lib=""
  if [[ -n "${SELF_DIR}" && -f "${SELF_DIR}/../lib/ssh-probe.sh" ]]; then
    lib="${SELF_DIR}/../lib/ssh-probe.sh"
  else
    local raw_base="${HF_RAW_BASE:-${RAW_BASE_DEFAULT}}"
    local lib_url="${raw_base%/scripts}/lib/ssh-probe.sh"
    if ! command -v curl >/dev/null 2>&1; then
      die 1 "缺少依赖 'curl'（用于下载 ssh 探测库）。请安装 curl，或改用 git clone 后本地跑 scripts/setup-client.sh。"
    fi
    ensure_download_dir
    lib="${download_dir}/ssh-probe.sh"
    if ! curl -fsSL "${lib_url}" -o "${lib}" 2>/dev/null; then
      die 1 "无法从 ${lib_url} 下载 ssh 探测库。
   网络不可达 / URL 不对时，请改用：git clone https://github.com/zzjcool/herdr-forward && \\
     ./herdr-forward/scripts/setup-client.sh --server-host <B 的 ssh target>
   （本地检出会直接使用同仓库的 lib/ssh-probe.sh，不需要联网。）"
    fi
    [[ -s "${lib}" ]] ||
      die 1 "下载到的 ssh-probe.sh 为空（${lib_url}）。请检查 URL 或改用 git clone 后本地跑。"
  fi
  # shellcheck source=../lib/ssh-probe.sh disable=SC1091
  source "${lib}"
  SSH_PROBE_LIB_LOADED=1
}

# --- --server-host：target 校验（用法错 -> 退出 2）并加载探测库 ---
# 解析实现单一权威在 lib/ssh-probe.sh（支持 user@host / user@host:port / host / [v6]:port）。
# 但**用户可见的报错文案与接受范围**必须与提取前逐字一致（回归闸门），故这里保留一层
# 兼容前置校验：
#   * 文案回归：`--server-host 端口非法: '<port>'` / `--server-host 缺少主机名: '<host>'`；
#   * 范围回归：旧实现不接受方括号 IPv6（`[::1]:2222` 会被当成「端口非法」）——lib 的
#     parse_target 额外支持方括号（供 M2 的 machines activate 用），但 setup-client.sh
#     **有意不启用该放宽**，以免静默改变已发布 CLI 的行为。
# 前置校验通过后目标必然是 lib 也接受的形态（两边对 user@host[:port] 的切分语义一致），
# 故 ssh_probe_parse_target 不会失败。
ssh_host=""
if [[ -n "${server_host}" ]]; then
  load_ssh_probe_lib
  if [[ "${server_host}" == *:* ]]; then
    legacy_port="${server_host#*:}"
    [[ "${legacy_port}" =~ ^[0-9]+$ ]] ||
      die 2 "--server-host 端口非法: '${legacy_port}'（期望 user@host[:port]）"
    [[ -n "${server_host%%:*}" ]] ||
      die 2 "--server-host 缺少主机名: '${server_host}'"
  fi
  parsed_target="$(ssh_probe_parse_target "${server_host}")"
  ssh_host="${parsed_target% *}"
fi

# ssh 探测结果状态：skipped | present | absent | no-herdr | unreachable
# 判定逻辑单一权威在 lib/ssh-probe.sh 的 ssh_probe_plugin（只读探测 + KV 输出，见该文件头注）。
ssh_status="skipped"
ssh_probe_root=""
ssh_probe_state=""
ssh_probe_reason=""
ssh_install_hint=""

if [[ -n "${server_host}" ]]; then
  ssh_install_hint="ssh ${server_host} 'herdr plugin install zzjcool/herdr-forward --yes'"
  ssh_probe_kv="$(ssh_probe_plugin "${server_host}" "${PLUGIN_ID}")"
  ssh_status="$(kv_get "${ssh_probe_kv}" HF_STATUS)"
  ssh_probe_reason="$(kv_get "${ssh_probe_kv}" HF_REASON)"
  case "${ssh_status}" in
  present)
    ssh_probe_root="$(kv_get "${ssh_probe_kv}" HF_ROOT)"
    ssh_probe_state="$(kv_get "${ssh_probe_kv}" HF_STATE_DIR)"
    if [[ -z "${ssh_probe_state}" ]]; then
      ssh_probe_state="$(kv_get "${ssh_probe_kv}" HF_DEFAULT_STATE)"
    fi
    ;;
  absent | no-herdr | unreachable) ;;
  *)
    # 库里没见过的状态（理论上不可达）：按连不上处理，降级而不是崩。
    ssh_status="unreachable"
    ;;
  esac
fi

# --- 自动填入：--server-host 探测命中时，用户连 --server-root 都不用传 ---
server_root_source="arg"
if [[ -z "${server_root}" && "${ssh_status}" == "present" && -n "${ssh_probe_root}" ]]; then
  server_root="${ssh_probe_root}"
  server_root_source="ssh"
fi

if ((do_tabbar == 1)) && [[ -z "${server_root}" ]]; then
  # 探测没命中/没给 --server-host：把「怎么拿到 B 的插件根」直接递到手上，再拒。
  hint=""
  case "${ssh_status}" in
  absent)
    hint="ssh 探测到 B 上**没有**装插件。先在 B 上装（复制执行即可，本脚本不会替你装）：
     ${ssh_install_hint}
   装完重跑本命令就不必再传 --server-root；或先显式指定：
     --server-root \$(ssh ${ssh_host} \"herdr plugin list --json | python3 -c 'import json,sys;print(json.load(sys.stdin)[\"result\"][\"plugins\"][0][\"plugin_root\"])'\")"
    ;;
  no-herdr)
    hint="ssh 连上了 B，但远端非交互 shell 里找不到 herdr：${ssh_probe_reason}
   请在 B 上把 herdr 放进 PATH，或用 --server-root 显式指定 B 的插件根。"
    ;;
  unreachable)
    hint="ssh 探测 B 失败（不影响后面的安装步骤）：${ssh_probe_reason}
   免密没配好 / 主机名不对时，请在 A 上先确认 \`ssh ${ssh_host} true\` 能过，
   然后传 --server-root 显式指定 B 的插件根。"
    ;;
  skipped)
    hint="未提供 --server-host，脚本无法探测 B 的插件根（A 上的路径对 B 无意义）。"
    ;;
  present)
    hint="ssh 探测到 B 已装插件，但读不到它的 plugin_root（B 的 plugins.json / 目录结构异常）。"
    ;;
  *)
    hint="探测状态未知（${ssh_status}）；请用 --server-root 显式指定 B 的插件根。"
    ;;
  esac
  die 2 "缺少 --server-root（server B 上的插件根绝对路径）。
   tab bar 的 command 在 herdr server 上执行，必须写 server 上的真实路径；A 上的路径对 B 无意义。
   ${hint}
   找法：在 B 上运行 \`herdr plugin list\`，或直接看 B 的 ~/.config/herdr/plugins.json 里的 plugin_root。
   只想要键绑定（不需要 server 路径）时加 --no-tabbar。"
fi

TABBAR_INSTALLER=""
KEYS_INSTALLER=""

locate_installers() {
  if [[ -n "${SELF_DIR}" && -f "${SELF_DIR}/install-tabbar.sh" && -f "${SELF_DIR}/install-keys.sh" ]]; then
    TABBAR_INSTALLER="${SELF_DIR}/install-tabbar.sh"
    KEYS_INSTALLER="${SELF_DIR}/install-keys.sh"
    return 0
  fi

  # curl | bash：标准输入是脚本，同目录没有安装器 —— 按需下载两个安装器到临时目录
  # （与 ssh 探测库共用 ensure_download_dir，退出时同一个 trap 清理）。
  # 用 HF_RAW_BASE 可指向镜像 / 本地目录（测试用 file://）。
  local raw_base="${HF_RAW_BASE:-${RAW_BASE_DEFAULT}}"
  if ! command -v curl >/dev/null 2>&1; then
    die 1 "缺少依赖 'curl'（用于下载安装器）。请安装 curl，或改用 git clone 后本地跑 scripts/setup-client.sh。"
  fi
  ensure_download_dir
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

# state 目录优先级：显式 --server-state-dir > ssh 探测到的 B 上的 state 目录 > 由（可能来自
# ssh 探测的）server-root 的 manifest id 推导 > 默认 id。
# ssh 探测值优先于本机推导，因为 state 目录取决于 **B 的** $XDG_STATE_HOME/$HOME 与插件 id ——
# 用 A 的 HOME 推导会写出 A 的路径，tab bar（在 B 上执行）就会读错 forwards.json。
state_dir_source="arg"
if [[ -z "${server_state_dir}" ]]; then
  if [[ "${ssh_status}" == "present" && -n "${ssh_probe_state}" ]]; then
    state_dir_source="ssh"
    server_state_dir="${ssh_probe_state}"
  else
    state_dir_source="derived"
    server_state_dir="$(derive_state_dir "${server_root:-${SELF_DIR:-.}/..}")"
  fi
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
  if [[ "${server_root_source}" == "ssh" ]]; then
    printf '  server 插件根: %s（由 --server-host ssh 探测自动填入，可省 --server-root）\n' "${server_root}"
  else
    printf '  server 插件根: %s\n' "${server_root}"
  fi
  case "${state_dir_source}" in
  ssh) printf '  server state 目录: %s（由 --server-host ssh 探测得到）\n' "${server_state_dir}" ;;
  derived) printf '  server state 目录: %s（由 server-root 的 manifest id 推导）\n' "${server_state_dir}" ;;
  *) printf '  server state 目录: %s\n' "${server_state_dir}" ;;
  esac
fi

if ((do_tabbar == 1)); then
  step=$((step + 1))
  printf '\n== [%d/%d] tab bar 状态条（command 在 herdr server 上执行）==\n' "${step}" "${total}"
  bash "${TABBAR_INSTALLER}" --config "${config_path}" \
    --plugin-root "${server_root}" --state-dir "${server_state_dir}" ${dry_flag[@]+"${dry_flag[@]}"} ||
    die 1 "install-tabbar.sh 失败（见上方输出）。config 未被部分破坏；修正后重跑本命令即可。"
fi

if ((do_keys == 1)); then
  step=$((step + 1))
  printf '\n== [%d/%d] 键绑定（plugin_action；由 server 上的插件响应，A 无需装插件）==\n' \
    "${step}" "${total}"
  # ${a[@]+"${a[@]}"}：空数组在 bash < 4.4 + set -u 下直接展开会报 unbound variable
  bash "${KEYS_INSTALLER}" --config "${config_path}" ${dry_flag[@]+"${dry_flag[@]}"} ||
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
EOF

# --- B 侧探测结论：ssh 真实探测（有 --server-host）优先，否则本机尽力探测 + checklist ---
ssh_report() {
  case "${ssh_status}" in
  present)
    printf "✅ ssh 真实探测 %s：B 上已装 %s。\\n" "${server_host}" "${PLUGIN_ID}"
    if [[ -n "${ssh_probe_root}" ]]; then
      printf '   B 的插件根（探测值）: %s\n' "${ssh_probe_root}"
    else
      printf '   （B 的 plugins.json 里读不到 plugin_root；插件根请手动确认。）\n'
    fi
    if [[ -n "${ssh_probe_state}" ]]; then
      printf '   B 的 state 目录（探测值）: %s\n' "${ssh_probe_state}"
    fi
    printf '   探测只读（BatchMode + timeout %ss），未在 B 上做任何修改。\n' "${SSH_PROBE_TIMEOUT}"
    ;;
  absent)
    printf "ℹ️  ssh 真实探测 %s：B 上**没有**装 %s。\\n" "${server_host}" "${PLUGIN_ID}"
    printf '   ⚠ 不要在 A 上装（插件必须跑在 herdr server 所在的 B 上）。\n'
    printf '   在 B 上装（复制执行即可，本脚本不会替你装）：\n'
    printf '     %s\n' "${ssh_install_hint}"
    ;;
  no-herdr)
    printf "⚠️  ssh 连上了 %s，但远端非交互 shell 里找不到 herdr：\\n" "${server_host}"
    printf '     %s\n' "${ssh_probe_reason}"
    printf '   请在 B 上把 herdr 放进 PATH（非交互 ssh 不读 ~/.bashrc），或按下方清单手工确认。\n'
    ;;
  unreachable)
    printf "⚠️  ssh 探测 %s 失败，**已降级**为本机探测 + 手工 checklist（不影响本次安装）：\\n" "${server_host}"
    printf '     %s\n' "${ssh_probe_reason}"
    printf '   排查：在 A 上先跑 ssh -o BatchMode=yes %s herdr plugin list（非交互）；\n' "${server_host}"
    printf '   免密没配好 / 主机名或端口不对时，修好后重跑本命令即可自动推导 B 的路径。\n'
    ;;
  skipped)
    printf 'ℹ️  未提供 --server-host：无法从 A 真实探测 B（ssh 通道未指定）。\n'
    printf '   下次可用一条命令连路径一起自动推导：setup-client.sh --server-host <B 的 ssh target>\n'
    ;;
  *)
    printf '⚠️  未预期的探测状态（%s），已降级为手工 checklist。\n' "${ssh_status}"
    ;;
  esac
}

if [[ "${ssh_status}" != "skipped" ]]; then
  printf '\n== B（herdr server）侧探测（经 ssh 通道，真实）==\n'
  ssh_report
else
  printf '\n== B（herdr server）侧插件可用性探测（本机尽力而为；未给 --server-host）==\n'
  probe_result="$(probe_plugin_present)"
  if [[ "${probe_result}" == "yes" ]]; then
    printf '✅ 在 herdr 配置目录里探测到 %s 的安装（managed checkout 或 link）。\n' "${PLUGIN_ID}"
    printf '   若 herdr server 就是本机，前置条件已满足；跨机时这只是本机的副本，仍需看下方清单。\n'
  else
    printf 'ℹ️  未在本机探测到 %s 的安装。\n' "${PLUGIN_ID}"
    printf '   若 herdr server 在另一台机器，请在 server 上确认：herdr plugin list 里有 %s\n' "${PLUGIN_ID}"
    printf '   （没有就先装：herdr plugin install zzjcool/herdr-forward）。\n'
  fi
fi

cat <<EOF

== B 侧前置条件检查清单（ssh 探测之外的项仍需手工确认）==
[ ] herdr server（B）上已装插件：\`herdr plugin list\` 里有 ${PLUGIN_ID}
[ ] server（B）上的插件根 = ${server_root:-<未提供：用了 --no-tabbar>}
[ ] server（B）上有 jq（本插件依赖）
[ ] server（B）上有 ssh（隧道依赖）
[ ] A → B 可非交互登录：已配置 ssh 免密（key-based）或在 herdr 里已能 attach
EOF
