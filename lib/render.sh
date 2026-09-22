#!/usr/bin/env bash
# lib/render.sh — 展示层纯函数（无副作用、无网络、无进程）
# A.3 扩展：tab bar oneline 渲染契约见 docs/ARCHITECTURE.md A.3
#   「tab bar 契约（forward list --oneline，秒回、只读状态文件）」
#   输出恒为纯文本（无 ANSI）：herdr tab_bar_right 不渲染颜色（SCOUT-FACTS §2.4）
set -Eeuo pipefail

# tab bar 单行最多渲染的端口数（ARCHITECTURE 假设#5 的防御性上限，先冻结行为）
readonly RENDER_ONELINE_MAX=6

# _render_warn <msg...>：有 common.sh 的 log 就用，否则退到 stderr
_render_warn() {
  if declare -F log >/dev/null 2>&1; then
    log warn "$@"
  else
    printf 'render: warning: %s\n' "$*" >&2
  fi
}

# render_oneline <forwards_json>
#   输入：forwards 数组 JSON（state_load / forward_list_json 的输出形状）
#   输出：`⇅3000⇅5173`（仅 status=up，端口升序；>6 条取前 6 个再追加 `+N`）
#   空数组 / 损坏 JSON / 非数组 / 空参数 -> 空串，恒 exit 0（tab bar 命令必须秒回不失败）
render_oneline() {
  local forwards_json="${1-}"
  [[ -z "${forwards_json}" ]] && return 0

  if ! command -v jq >/dev/null 2>&1; then
    _render_warn "render_oneline: jq 未安装，oneline 降级为空"
    return 0
  fi

  # 非数组（对象信封 / 标量 / null）与非法 JSON 一律降级空串，绝不因坏输入 exit 非 0
  local kind summary
  if ! kind="$(printf '%s' "${forwards_json}" | jq -r 'type' 2>/dev/null)"; then
    _render_warn "render_oneline: forwards JSON 不可解析，oneline 降级为空"
    return 0
  fi
  [[ "${kind}" == "array" ]] || return 0

  if ! summary="$(
    printf '%s' "${forwards_json}" |
      jq -c '[.[] | select(.status == "up") | .local_port | numbers] | sort | {total: length, shown: .[0:6]}' \
        2>/dev/null
  )"; then
    _render_warn "render_oneline: forwards JSON 不可解析，oneline 降级为空"
    return 0
  fi
  [[ -z "${summary}" ]] && return 0

  local total out="" port ports
  total="$(printf '%s' "${summary}" | jq -r '.total')"
  ports="$(printf '%s' "${summary}" | jq -r '.shown[]')"
  while IFS= read -r port; do
    [[ -z "${port}" ]] && continue
    out+="⇅${port}"
  done <<<"${ports}"

  if ((total > RENDER_ONELINE_MAX)); then
    out+="+$((total - RENDER_ONELINE_MAX))"
  fi

  printf '%s' "${out}"
}
