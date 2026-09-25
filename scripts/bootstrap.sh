#!/usr/bin/env bash
# scripts/bootstrap.sh — OOTB 一站式安装：tab bar 状态条 + 可选键位 + 后续指引。
#
# 定位（autokeys 后的措辞）：同机启动时 `[[startup]]` hook 已会**自动**把 tab bar 与
# 键位都装上（见 scripts/startup-hook.sh）。本脚本是**手动补装 / 重装 / 换键 / 跨机**
# 场景的入口，两条路径写的是同一组幂等安装器，不会打架。
#
# 背景（SCOUT-FACTS §2.2）：herdr plugin v1 的 manifest 不能声明 keys / tab_bar，
# 这两项属于 herdr 自己的 config.toml。本脚本把两个幂等安装器串起来，用户 link 后
# 一条命令即可拿到完整 UI：
#   - 同机用户：`[[startup]]` hook 会自动跑 install-tabbar + install-keys（见
#     scripts/startup-hook.sh），本脚本用于补装 / 换键 / 跨机场景 / 显式重装。
#   - 跨机（client A attach 到 server B）：tab_bar_right 条目在 server 上解析执行，
#     但配置本身是 client 的；B 的进程碰不到 A 的文件系统。B 侧 startup hook 只能
#     降级为提示。跨机时请在 A 上运行本脚本、用 --config 指向 A 的 config.toml，
#     **并用 --plugin-root 指向 B 上的插件路径**（command 在 B 上执行）。
#
# 行为契约：
#   - --config PATH 透传给两个安装器（默认 ~/.config/herdr/config.toml）
#   - --plugin-root PATH 透传给 install-tabbar.sh（tab bar command 里写的绝对路径）：
#     语义是「**herdr server** 上的插件根」。默认可不传；**跨机时必须在 A 上显式传 B 的路径**
#     （command 在 B 上执行，A 的本地路径对 B 无意义）。
#   - --state-dir PATH 透传给 install-tabbar.sh（写进 tab bar command 的 env 前缀，
#     = **herdr server** 上的插件 state 目录）。不传时依次取 HERDR_PLUGIN_STATE_DIR
#     （插件 action/startup 上下文里有）→ install-tabbar.sh 的 XDG 推导默认值。
#     为什么必须显式：tab bar command 的执行上下文里**没有** HERDR_PLUGIN_STATE_DIR，
#     缺了它 bin/forward 会回退到 ~/.local/state/herdr-forward，与插件 action 写入的
#     ~/.local/state/herdr/plugins/zzjcool%3Aforward 分叉 → tab bar 永远空（真实 bug #3）。
#   - --dry-run 透传（两个安装器都不落盘）
#   - --no-tabbar / --no-keys 跳过对应安装器
#   - 键位参数 --add-key/--list-key/--doctor-key 透传给 install-keys.sh
#   - 任一安装器失败 -> 整体非 0（后续步骤不再执行），绝不静默吞错
#   - 输出指引：reload-config、键位提示、跨机能力边界
set -Eeuo pipefail

readonly PROG_NAME="${0##*/}"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SELF_DIR
readonly TABBAR_INSTALLER="${SELF_DIR}/install-tabbar.sh"
readonly KEYS_INSTALLER="${SELF_DIR}/install-keys.sh"
readonly DEFAULT_CONFIG="${XDG_CONFIG_HOME:-${HOME:-/nonexistent}/.config}/herdr/config.toml"

usage() {
  cat <<'EOF'
用法: bootstrap.sh [选项]

一站式装好 herdr-forward 的 UI：tab bar 状态条 + 键绑定。

注：同机启动时 `[[startup]]` hook 已会自动装好这两项（幂等，装过就跳过）。
本命令用于**手动补装 / 重装 / 换键 / 跨机**场景。

选项:
  --config PATH       目标 config 文件（默认: ~/.config/herdr/config.toml）
  --plugin-root PATH  tab bar command 里写的插件绝对路径 = **herdr server** 上的插件根
                      （默认自动解析为本脚本所在检出；跨机时传 server B 上的路径）
  --state-dir PATH    tab bar command 里写的插件 state 目录 = **herdr server** 上的
                      ${XDG_STATE_HOME:-~/.local/state}/herdr/plugins/zzjcool%3Aforward
                      （默认取 HERDR_PLUGIN_STATE_DIR，再退上述路径）。tab bar 执行
                      上下文里没有该 env，不写进 command 就会和插件 action 的状态目录分叉。
  --dry-run           只预览，不修改文件
  --no-tabbar         跳过 tab bar 状态条安装
  --no-keys           跳过键绑定安装
  --add-key KEY       键绑定：打开 Port Forward 面板（默认: prefix+f）
  --list-key KEY      键绑定：列出转发（默认: prefix+shift+f）
  --doctor-key KEY    键绑定：探活检查（默认: prefix+alt+f）
  --help              显示本帮助

两个安装器都是幂等的（重复执行不重复插入）；真实修改前会各自备份
<config>.bak.<epoch>。装完执行 reload-config（或重启 herdr）即生效。

跨机用户（client 与 herdr server 不在同一台机器）：本脚本只改「本机」config。
需要为另一台机器装 tab bar 时，把本脚本拷过去用 --config 指定其 config.toml，
并用 --plugin-root 指定 **server** 上的插件路径（tab bar command 在 server 上执行）。
EOF
}

die() {
  printf '%s: error: %s\n' "${PROG_NAME}" "$*" >&2
  exit 1
}

# --- 参数解析（禁交互） ---
config_path=""
plugin_root=""
state_dir=""
dry_run=0
do_tabbar=1
do_keys=1
key_args=()
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
  --state-dir)
    [[ $# -ge 2 ]] || die "--state-dir 需要参数值"
    state_dir="$2"
    shift 2
    ;;
  --dry-run)
    dry_run=1
    shift
    ;;
  --no-tabbar)
    do_tabbar=0
    shift
    ;;
  --no-keys)
    do_keys=0
    shift
    ;;
  --add-key | --list-key | --doctor-key)
    [[ $# -ge 2 ]] || die "$1 需要参数值（如 prefix+f）"
    key_args+=("$1" "$2")
    shift 2
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

dry_flag=()
if ((dry_run)); then
  dry_flag=(--dry-run)
fi

# --plugin-root 只对 tab bar 有意义（键位是 plugin_action，不经路径）
plugin_root_args=()
if [[ -n "${plugin_root}" ]]; then
  plugin_root_args=(--plugin-root "${plugin_root}")
fi

# --state-dir 显式 > HERDR_PLUGIN_STATE_DIR（插件 action/startup 上下文里有这个 env，
# 那正是 herdr 给本插件分配的权威 state 目录）> 交给 install-tabbar.sh 自己推导。
# 显式传递也让「透传」在测试里可断言。
state_dir_args=()
if [[ -n "${state_dir}" ]]; then
  state_dir_args=(--state-dir "${state_dir}")
elif [[ -n "${HERDR_PLUGIN_STATE_DIR:-}" ]]; then
  state_dir_args=(--state-dir "${HERDR_PLUGIN_STATE_DIR}")
fi

step=0
total=0
((do_tabbar)) && total=$((total + 1))
((do_keys)) && total=$((total + 1))
if ((total == 0)); then
  die "--no-tabbar 与 --no-keys 同时指定：没有可执行的安装步骤，请去掉其一。"
fi

printf '%s: herdr-forward OOTB 安装（%d 步，config=%s）\n' "${PROG_NAME}" "${total}" "${config_path}"

if ((do_tabbar)); then
  step=$((step + 1))
  printf '\n== [%d/%d] tab bar 状态条 ==\n' "${step}" "${total}"
  [[ -f "${TABBAR_INSTALLER}" ]] ||
    die "缺少 ${TABBAR_INSTALLER}。请确认插件安装完整（herdr plugin link/install 后重试）。"
  # ${a[@]+"${a[@]}"}：空数组在 bash < 4.4 + set -u 下直接展开会报 unbound variable
  bash "${TABBAR_INSTALLER}" --config "${config_path}" ${plugin_root_args[@]+"${plugin_root_args[@]}"} \
    ${state_dir_args[@]+"${state_dir_args[@]}"} ${dry_flag[@]+"${dry_flag[@]}"} ||
    die "install-tabbar.sh 失败（见上方输出）。文件未被部分破坏；修正后重跑本命令即可。"
fi

if ((do_keys)); then
  step=$((step + 1))
  printf '\n== [%d/%d] 键绑定 ==\n' "${step}" "${total}"
  [[ -f "${KEYS_INSTALLER}" ]] ||
    die "缺少 ${KEYS_INSTALLER}。请确认插件安装完整（herdr plugin link/install 后重试）。"
  bash "${KEYS_INSTALLER}" --config "${config_path}" ${key_args[@]+"${key_args[@]}"} ${dry_flag[@]+"${dry_flag[@]}"} ||
    die "install-keys.sh 失败（见上方输出）。文件未被部分破坏；修正后重跑本命令即可。"
fi

# --- 后续指引（诚实标注能力边界） ---
cat <<EOF

== 下一步 ==
1. 让配置生效：在 herdr 里按 prefix+q（reload_config），或运行：
     herdr server reload-config
   注：同机启动时 [[startup]] hook 会自动装好 tab bar 与键位（幂等）；
   本命令是手动补装 / 重装 / 换键 / 跨机时的入口。
2. 键位（装好后可用）：prefix+f 打开 Port Forward 面板 / prefix+shift+f 列出转发
   / prefix+alt+f 探活检查。若与你的其它键位冲突，可重跑：
     ${PROG_NAME} --config ${config_path} --add-key prefix+<你的键>
   （startup hook 的自动路径遇到冲突会**保守跳过**、绝不覆盖你的绑定，并打印换键提示。）
3. tab bar 右侧出现 ⇅<port> 即表示状态条生效（无活跃转发时为空）。

== 跨机说明（client A attach 到 server B）==
- tab_bar_right 的 command 在 server（B）上执行，但配置属于 client（A）。
- B 上的插件进程碰不到 A 的文件系统，因此 B 侧无法自动替 A 写配置——这是物理
  边界，不是缺陷。同机用户（A == B）则由 [[startup]] hook 自动完成，无需本命令。
- 为 A 安装：把本插件的 scripts/ 拷到 A（或 A 上直接 link 插件），然后在 A 上运行：
     <插件根>/scripts/bootstrap.sh --config ~/.config/herdr/config.toml \
       --plugin-root <server B 上的插件根> --state-dir <server B 上的插件 state 目录>
  ⚠ --plugin-root 必须写 **B** 上的路径（command 在 B 上执行），不是 A 的本地路径；
    --state-dir 同理必须是 B 上的 ${XDG_STATE_HOME:-~/.local/state}/herdr/plugins/zzjcool%3Aforward ——
    否则 tab bar 会读 A 的（不存在的）状态，显示永远为空。
    或按 README 的「一键复制块」手工添加等价条目。
EOF
