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

# M3：machines 激活状态（可选依赖；缺失 / 读失败都不影响现行为）
if [[ -f "${_lib_dir}/machines.sh" ]]; then
  # shellcheck source=/dev/null
  source "${_lib_dir}/machines.sh"
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

# _hook_activation_plan：stdout 输出 tab bar 目标三行（plan / plugin_root / state_dir）。
#
# M3（计划 §2.5）：若 activated-machines.json 里有 active 且该机器**不是本机**，
# tab bar 就应该指向那台机器 —— 因为 tab bar 的 command 在 **herdr server** 上执行，
# 而激活语义就是「让本机 client 的状态条读远端 B 的 forward 状态」。
#
# 决策树（保守 + 恒不发错）：
#   lib/machines.sh 缺失 / 读失败 / active 为空 → plan=local（现行为）
#   active 存在但同机（machines_is_local_target=yes） → plan=local
#   active 存在且非同机但记录缺 server_root/state_dir → plan=local + warn（半截记录）
#   其他 → plan=remote + B 的 plugin-root / state-dir
#
# 为什么不在这里重新 SSH 探测：startup 路径必须秒回（server 启动关键路径），
# 只信激活时落盘的记录。路径漂移由 `forward machines doctor` 负责。
_hook_activation_plan() {
  if ! declare -F machines_activation_load >/dev/null 2>&1; then
    printf 'local\n-\n-\n'
    return 0
  fi

  local doc=""
  set +o errexit
  # 不重定向 stderr：machines_activation_load 的契约是「损坏 -> 空对象 + warn」，
  # warn 必须能浮到 hook 的 stderr（用户排查入口），不能静默吞掉。
  doc="$(machines_activation_load)"
  set -o errexit

  if ! command -v jq >/dev/null 2>&1 || [[ -z "${doc}" ]]; then
    printf 'local\n-\n-\n'
    return 0
  fi

  # 防御 M2 之外的坏上游（旧版本 / 被手改的激活文件）：hook 自己也要不崩。
  local kind=""
  set +o errexit
  kind="$(printf '%s' "${doc}" | jq -r 'type' 2>/dev/null)"
  set -o errexit
  if [[ "${kind}" != "object" ]]; then
    _hook_warn "激活状态不可解析（应为对象，实为 '${kind}'）；本次按本机路径处理。"
    printf 'local\n-\n-\n'
    return 0
  fi

  local active=""
  set +o errexit
  active="$(printf '%s' "${doc}" | jq -r '.active // empty' 2>/dev/null)"
  set -o errexit
  if [[ -z "${active}" ]]; then
    printf 'local\n-\n-\n'
    return 0
  fi

  local target=""
  target="$(printf '%s' "${doc}" | jq -r --arg id "${active}" \
    '.machines[$id].ssh_target // empty' 2>/dev/null || true)"

  # 归一化后再交给 M2 的判定：激活记录里的 ssh_target 可能带 user@ / :port
  # （`user@host:22`、`[::1]:22`），而 machines_is_local_target 的契约只认主机。
  local host="${target}"
  host="${host#*@}"
  if [[ "${host}" == \[*\]:* ]]; then
    host="${host%%\]:*}]" # [v6]:port → [v6]
  elif [[ "${host}" == *:* ]]; then
    host="${host%%:*}"
  fi
  [[ -n "${host}" ]] || host="${target}"

  local is_local=""
  if declare -F machines_is_local_target >/dev/null 2>&1; then
    is_local="$(machines_is_local_target "${host}" 2>/dev/null || true)"
  fi
  if [[ "${is_local}" == "yes" ]]; then
    _hook_log info "startup: active machine '${active}' 就是本机，tab bar 保持本机路径。"
    printf 'local\n-\n-\n'
    return 0
  fi

  local root="" state=""
  root="$(printf '%s' "${doc}" | jq -r --arg id "${active}" \
    '.machines[$id].server_root // empty' 2>/dev/null || true)"
  state="$(printf '%s' "${doc}" | jq -r --arg id "${active}" \
    '.machines[$id].state_dir // empty' 2>/dev/null || true)"

  if [[ -z "${root}" || -z "${state}" ]]; then
    _hook_warn "active machine '${active}' 的激活记录不完整（server_root='${root}' state_dir='${state}'）；本次按本机路径处理。请在 client 侧重跑 'forward machines activate ${active}'。"
    printf 'local\n-\n-\n'
    return 0
  fi

  printf 'remote\n%s\n%s\n' "${root}" "${state}"
  return 0
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
  --state-dir PATH 显式指定插件 state 目录（默认取 HERDR_PLUGIN_STATE_DIR，再交
                  install-tabbar.sh 按 XDG 推导）。写进 tab bar command 的 env 前缀。
  --dry-run       只预览，不修改文件
  --help          显示本帮助

绝对路径解析：hook 在 server 上跑，tab bar command 也在 server 上执行，因此
install-tabbar.sh 自动解析出的「本机绝对路径」就是正确的 server 路径（不存在 $HERDR_PLUGIN_ROOT
那样在 tab bar 执行上下文里缺失的 env）。跨机场景的 client 侧请用 bootstrap.sh --plugin-root。

state 目录：hook 自己跑在插件上下文里，HERDR_PLUGIN_STATE_DIR 就是 herdr 给本插件分配的
state 目录（插件 action / 面板 add 写的就是它）。tab bar command 的执行上下文里**没有**
这个 env，故 hook 把它显式传给 install-tabbar.sh 写进 command —— 不这样做两处会分叉到
~/.local/state/herdr-forward 与 ~/.local/state/herdr/plugins/zzjcool%3Aforward，tab bar 永远空。

跨机说明：本 hook 只写「本机」（= herdr server 所在机器）的 config。client 若在
另一台机器，请在那台机器上运行 <插件根>/scripts/bootstrap.sh --plugin-root <server 插件根>。
EOF
}

config_path=""
state_dir=""
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
  --state-dir)
    if [[ $# -lt 2 ]]; then
      _hook_warn "--state-dir 缺少参数值，按 HERDR_PLUGIN_STATE_DIR/推导默认继续"
      shift
      continue
    fi
    state_dir="$2"
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

# --- 目标机器解析（M3：active machine 优先） ---
# 有 active 且非同机时，tab bar 指向那台机器的插件根/state 目录；否则现行为。
# 显式 --state-dir 仍然优先（用户/测试的显式意图压过智能推导）。
activation_plan="local"
activation_root=""
activation_state=""
plugin_root_args=()
plan_out=""
set +o errexit
plan_out="$(_hook_activation_plan)"
set -o errexit
activation_plan="$(printf '%s\n' "${plan_out}" | sed -n '1p')"
activation_root="$(printf '%s\n' "${plan_out}" | sed -n '2p')"
activation_state="$(printf '%s\n' "${plan_out}" | sed -n '3p')"

if [[ ! -f "${TABBAR_INSTALLER}" ]]; then
  _hook_warn "缺少 ${TABBAR_INSTALLER}；跳过 tab bar 自动安装。请在 client 机器运行 scripts/install-tabbar.sh。"
  exit 0
fi

_hook_log info "startup: 检查 tab bar 条目（config=${config_path}）"

dry_flag=()
if ((dry_run)); then
  dry_flag=(--dry-run)
fi

if [[ "${activation_plan}" == "remote" && -n "${activation_root}" && -n "${activation_state}" ]]; then
  # active machine 在另一台：tab bar 的 command 要在那台机器上解析，故用它的插件根。
  plugin_root_args=(--plugin-root "${activation_root}")
  state_dir_args=(--state-dir "${activation_state}")
  if [[ -n "${state_dir}" ]]; then
    # 显式意图压过智能推导（只覆盖 state 目录，plugin-root 仍取记录）。
    state_dir_args=(--state-dir "${state_dir}")
  fi
  _hook_log info "startup: active machine 命中，tab bar 将指向 ${activation_root}（state=${state_dir_args[1]}）。"
else
  # 现行为：state 目录 = 插件上下文里 herdr 注入的权威值（插件 action / 面板 add 写的就是它）。
  # 显式传下去，install-tabbar.sh 会把它嵌进 tab bar command 的 env 前缀。
  # --state-dir 显式参数 > HERDR_PLUGIN_STATE_DIR > 交给安装器推导。
  state_dir_args=()
  if [[ -n "${state_dir}" ]]; then
    state_dir_args=(--state-dir "${state_dir}")
  elif [[ -n "${HERDR_PLUGIN_STATE_DIR:-}" ]]; then
    state_dir_args=(--state-dir "${HERDR_PLUGIN_STATE_DIR}")
  fi
fi

# install-tabbar.sh 自己幂等（已有条目则 exit 0 并提示 already；检测到属于本插件但
# 与当前期望不同的条目——旧的 $HERDR_PLUGIN_ROOT 字面量形式或缺 state env 前缀——
# 则就地重写），故直接调用即可。
# 不传 --plugin-root：install-tabbar.sh 解析自身真实位置，得到的就是 **server 上的**
# 绝对路径（hook 与 command 同在 server 执行），这比猜路径可靠。
# set +e 包裹：任何非 0 都降级为日志，绝不冒泡（startup 不得打断 server）。
installer_rc=0
installer_out=""
set +o errexit
installer_out="$(bash "${TABBAR_INSTALLER}" --config "${config_path}" "${state_dir_args[@]}" "${dry_flag[@]}" "${plugin_root_args[@]}" 2>&1)"
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
    "--plugin-root <本机（server B）的插件根> --state-dir <本机（server B）的插件 state 目录> " \
    "—— server 侧无法代写 client 配置。"
  exit 0
fi

_hook_warn "tab bar 自动安装失败（rc=${installer_rc}，config=${config_path}）；已跳过，herdr server 不受影响。"
printf '%s\n' "${installer_out}" >&2 || true
printf '%s\n' \
  "下一步：手动运行 <插件根>/scripts/install-tabbar.sh --config ${config_path} 查看具体原因；" \
  "跨机（client 在另一台机器）时请在 client 机器运行 <插件根>/scripts/bootstrap.sh。" >&2
exit 0
