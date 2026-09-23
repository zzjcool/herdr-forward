#!/usr/bin/env bash
# scripts/startup-hook.sh — herdr [[startup]] hook（OOTB 自动装 tab bar）
#
# 背景：herdr plugin v1 的 manifest 不能声明 tab_bar_right（SCOUT-FACTS §2.2），
# 而 `[[startup]]` 会在 server 恢复会话、API socket ready 后跑一次（handoff 再跑）
# —— 正好拿来「装完插件就自动补上 tab bar 条目」。
#
# 能力与边界（诚实声明）：
#   * tab_bar_right 是 **client** 的 presentation 配置，但其中 command 条目在
#     **server** 上解析执行。server 与 client 同机时（本地用户，占大多数）两者
#     的 config 就是同一份 —— 本 hook 直接装，用户零操作。
#   * server 与 client 跨机时，server 进程碰不到 client 的文件系统（物理边界），
#     本 hook 只能写 server 自己的 config，并对 client 侧打印一行指引。绝不自作
#     聪明地去猜远端路径、绝不报错阻塞 server。
#
# 行为契约（startup 上下文的首要目标 = 永不阻塞 server）：
#   * 恒 exit 0：任何失败（非法 TOML / 目录不可写 / 缺依赖 / 无 HOME）都降级为
#     日志 + stderr 提示，不抛出非 0。
#   * 幂等：委托给 install-tabbar.sh（注释标记识别），装过就跳过。
#   * --config PATH 可显式覆盖（用于测试与「在 A 上补装」场景）。
#   * --dry-run 透传。
#   * 未知参数只告警，不 abort。
set -Eeuo pipefail

readonly PROG_NAME="${0##*/}"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SELF_DIR
readonly TABBAR_INSTALLER="${SELF_DIR}/install-tabbar.sh"

# 复用插件自己的 log（写入 $HERDR_PLUGIN_STATE_DIR/logs/forward.log；env 缺失退 stderr）
_lib_dir="${SELF_DIR}/../lib"
if [[ -f "${_lib_dir}/common.sh" ]]; then
  # shellcheck source=/dev/null
  source "${_lib_dir}/common.sh"
fi

# _hook_log <level> <msg...>：有 common.sh 的 log 就用，否则退 stderr。
_hook_log() {
  if declare -F log >/dev/null 2>&1; then
    log "$@"
  else
    local level="${1:-info}"
    shift || true
    printf 'startup-hook: %s: %s\n' "${level}" "$*" >&2
  fi
}

# _hook_warn <msg...>：日志 + stderr 双写（用户可能在 herdr 日志里找原因）
_hook_warn() {
  _hook_log warn "$@"
  printf '%s: warn: %s\n' "${PROG_NAME}" "$*" >&2
}

usage() {
  cat <<'EOF'
用法: startup-hook.sh [选项]

herdr [[startup]] 钩子：检测到 tab bar 状态条缺失时自动执行 install-tabbar.sh。
恒 exit 0（startup 失败不阻塞 herdr server）。

选项:
  --config PATH   显式指定目标 config（默认取 HERDR_CONFIG_PATH，再退
                  $XDG_CONFIG_HOME/herdr/config.toml）
  --dry-run       只预览，不修改文件
  --help          显示本帮助

绝对路径解析：hook 在 server 上跑，tab bar command 也在 server 上执行，因此
install-tabbar.sh 自动解析出的「本机绝对路径」就是正确的 server 路径（不存在 $HERDR_PLUGIN_ROOT
那样在 tab bar 执行上下文里缺失的 env）。跨机场景的 client 侧请用 bootstrap.sh --plugin-root。

跨机说明：本 hook 只写「本机」（= herdr server 所在机器）的 config。client 若在
另一台机器，请在那台机器上运行 <插件根>/scripts/bootstrap.sh --plugin-root <server 插件根>。
EOF
}

config_path=""
dry_run=0
while (($# > 0)); do
  case "$1" in
  --config)
    if [[ $# -lt 2 ]]; then
      _hook_warn "--config 缺少参数值，按默认路径继续"
      shift
      continue
    fi
    config_path="$2"
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
    # startup 上下文里「因为一个拼错的参数就不装 UI」不划算：告警后继续。
    _hook_warn "未知参数 '$1'（忽略，继续按默认行为安装）"
    shift
    ;;
  esac
done

# --- 解析目标 config（优先显式 > herdr 注入 > XDG/HOME 默认） ---
if [[ -z "${config_path}" ]]; then
  if [[ -n "${HERDR_CONFIG_PATH:-}" ]]; then
    config_path="${HERDR_CONFIG_PATH}"
  elif [[ -n "${XDG_CONFIG_HOME:-}" ]]; then
    config_path="${XDG_CONFIG_HOME}/herdr/config.toml"
  elif [[ -n "${HOME:-}" ]]; then
    config_path="${HOME}/.config/herdr/config.toml"
  fi
fi

if [[ -z "${config_path}" ]]; then
  _hook_warn "无法确定 herdr config 路径（--config / HERDR_CONFIG_PATH / XDG_CONFIG_HOME / HOME 均不可用）；跳过 tab bar 自动安装。请在 client 机器运行 <插件根>/scripts/bootstrap.sh --config <config 路径>。"
  exit 0
fi

if [[ ! -f "${TABBAR_INSTALLER}" ]]; then
  _hook_warn "缺少 ${TABBAR_INSTALLER}；跳过 tab bar 自动安装。请在 client 机器运行 scripts/install-tabbar.sh。"
  exit 0
fi

_hook_log info "startup: 检查 tab bar 条目（config=${config_path}）"

dry_flag=()
if ((dry_run)); then
  dry_flag=(--dry-run)
fi

# install-tabbar.sh 自己幂等（已有条目则 exit 0 并提示 already；检测到旧格式的
# $HERDR_PLUGIN_ROOT 字面量则自动升级为绝对路径），故直接调用即可。
# 不传 --plugin-root：install-tabbar.sh 解析自身真实位置，得到的就是 **server 上的**
# 绝对路径（hook 与 command 同在 server 执行），这比猜路径可靠。
# set +e 包裹：任何非 0 都降级为日志，绝不冒泡（startup 不得打断 server）。
installer_rc=0
installer_out=""
set +o errexit
installer_out="$(bash "${TABBAR_INSTALLER}" --config "${config_path}" "${dry_flag[@]}" 2>&1)"
installer_rc=$?
set -o errexit

if [[ "${installer_rc}" -eq 0 ]]; then
  if [[ "${installer_out}" == *already* ]]; then
    _hook_log info "startup: tab bar 条目已存在，跳过（幂等）"
  else
    _hook_log info "startup: tab bar 条目已写入 ${config_path}；执行 reload-config 后生效"
  fi
  printf '%s\n' \
    "提示：tab bar 条目已就绪。若你的 herdr client 跑在另一台机器（跨机 attach），" \
    "那台机器需要单独运行 <插件根>/scripts/bootstrap.sh --config <A 的 config> " \
    "--plugin-root <本机（server B）的插件根> —— server 侧无法代写 client 配置。"
  exit 0
fi

_hook_warn "tab bar 自动安装失败（rc=${installer_rc}，config=${config_path}）；已跳过，herdr server 不受影响。"
printf '%s\n' "${installer_out}" >&2 || true
printf '%s\n' \
  "下一步：手动运行 <插件根>/scripts/install-tabbar.sh --config ${config_path} 查看具体原因；" \
  "跨机（client 在另一台机器）时请在 client 机器运行 <插件根>/scripts/bootstrap.sh。" >&2
exit 0
