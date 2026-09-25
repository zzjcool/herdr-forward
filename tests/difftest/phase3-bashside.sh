#!/usr/bin/env bash
# tests/difftest/phase3-bashside.sh — Phase 3 差分测试的 bash 对位入口
# （PLAN-GO-MIGRATION §6 Phase 3）
#
# 与 bashside.sh 同一条纪律：**不复制**任何逻辑 —— source 真实的 lib/bridge.sh 与
# lib/machines.sh（唯一权威），把子命令转发到对应函数。否则差分测试测出的「一致」是假的。
#
# 环境：HERDR_PLUGIN_STATE_DIR 必填（run.sh 会给 bash/go 两侧各自独立目录）。
#
# 子命令（与 go/internal/difftest/phase3.go 一一对应）：
#   hf-parse <line>          bridge_parse_sync / 各 printf 的解析侧
#   hf-fmt <kind> …          bridge_fmt_sync + 各协议行的 printf
#   hf-valid <id> <lp> <rp>  bridge_valid_entry
#   ssh-dest <target>        bridge_ssh_destination
#   remote-cmd <root> <st>   bridge_remote_serve_cmd
#   bridge-ssh-args <ctl>    bridge_ssh_args（一行一个 argv）
#   bridge-active <sub> …    machines_activation_* / machines_view_json / machines_resolve_id
#   probe-kv <text> <KEY>    kv_get（lib/ssh-probe.sh）
set -Eeuo pipefail

P3_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
P3_ROOT="$(cd "${P3_HERE}/../.." && pwd)"

# shellcheck source=/dev/null
source "${P3_ROOT}/lib/common.sh"
# shellcheck source=/dev/null
source "${P3_ROOT}/lib/state.sh"
# shellcheck source=/dev/null
source "${P3_ROOT}/lib/bridge.sh"
# shellcheck source=/dev/null
source "${P3_ROOT}/lib/machines.sh"
# shellcheck source=/dev/null
source "${P3_ROOT}/lib/ssh-probe.sh"

P3_SUBCMD="${1-}"
shift || true

case "${P3_SUBCMD}" in
hf-parse)
  # 解析侧的 bash 对位：用与 Go 侧同一套「能识别 / 不能识别」判据。
  # 识别判据 = 首词是 HF1 且第二词是已知动作（bash 的 serve/run 也是这么分派的）。
  line="${1-}"
  read -r -a p3_words <<<"${line}" || true
  p3_verb="${p3_words[1]-}"
  p3_known=""
  case "${p3_verb}" in
  HELLO | SYNC | OPEN | STATUS | PING) p3_known="yes" ;;
  *) ;;
  esac
  if [[ "${p3_words[0]-}" != "HF1" || -z "${p3_known}" ]]; then
    printf 'ERR\n'
    exit 0
  fi
  printf 'OK %s\n' "${p3_verb}"
  case "${p3_verb}" in
  HELLO)
    p3_host="${p3_words[2]-}"
    p3_rest="${line#*HELLO }"
    p3_rest="${p3_rest#"${p3_host}"}"
    if [[ -n "${p3_rest}" && "${p3_rest:0:1}" == " " ]]; then
      p3_rest="${p3_rest:1}"
    fi
    printf 'HELLO host=%s labels=%s\n' "${p3_host}" "${p3_rest// /|}"
    ;;
  SYNC)
    p3_payload=""
    if ((${#p3_words[@]} > 2)); then
      p3_payload="${line#*SYNC }"
    fi
    p3_out="$(bridge_parse_sync "${p3_payload}")"
    p3_n=0
    p3_entries=""
    while IFS=' ' read -r p3_id p3_lp p3_rp; do
      [[ -n "${p3_id}" ]] || continue
      p3_n=$((p3_n + 1))
      p3_entries+="${p3_entries:+,}${p3_id}:${p3_lp}:${p3_rp}"
    done <<<"${p3_out}"
    printf 'SYNC n=%d entries=%s\n' "${p3_n}" "${p3_entries}"
    ;;
  OPEN)
    p3_url=""
    if ((${#p3_words[@]} > 2)); then
      p3_url="${line#*OPEN }"
    fi
    printf 'OPEN url=%s\n' "${p3_url}"
    ;;
  STATUS)
    p3_fid="${p3_words[2]-}"
    p3_st="${p3_words[3]-}"
    p3_reason="${line#*STATUS "${p3_fid}" "${p3_st}"}"
    p3_reason="${p3_reason# }"
    printf 'STATUS id=%s state=%s reason=%s\n' "${p3_fid}" "${p3_st}" "${p3_reason}"
    ;;
  PING) : ;;
  *) ;;
  esac
  ;;
hf-fmt)
  p3_kind="${1-}"
  shift || true
  case "${p3_kind}" in
  hello)
    p3_host="${1-}"
    p3_labels=""
    if (($# > 1)); then
      shift
      p3_labels=" $*"
    fi
    printf 'HF1 HELLO %s%s\n' "${p3_host}" "${p3_labels}"
    ;;
  sync)
    p3_payload="${1:--}"
    p3_rows="$(bridge_parse_sync "${p3_payload}")"
    p3_body=""
    while IFS=' ' read -r p3_id p3_lp p3_rp; do
      [[ -n "${p3_id}" ]] || continue
      p3_body+="${p3_body:+,}${p3_id}:${p3_lp}:${p3_rp}"
    done <<<"${p3_rows}"
    printf 'HF1 SYNC %s\n' "${p3_body:--}"
    ;;
  open)
    printf 'HF1 OPEN %s\n' "${1-}"
    ;;
  status)
    p3_id="${1-}"
    p3_state="${2-}"
    shift 2 || true
    if (($# > 0)); then
      printf 'HF1 STATUS %s %s %s\n' "${p3_id}" "${p3_state}" "$*"
    else
      printf 'HF1 STATUS %s %s\n' "${p3_id}" "${p3_state}"
    fi
    ;;
  ping)
    printf 'HF1 PING\n'
    ;;
  *)
    printf 'phase3-bashside hf-fmt: 未知种类 %q\n' "${p3_kind}" >&2
    exit 64
    ;;
  esac
  ;;
hf-valid)
  bridge_valid_entry "${1-}" "${2-}" "${3-}"
  ;;
ssh-dest)
  bridge_ssh_destination "${1-}"
  ;;
remote-cmd)
  bridge_remote_serve_cmd "${1-}" "${2-}"
  ;;
bridge-ssh-args)
  bridge_ssh_args "${1-}"
  ;;
bridge-active)
  p3_sub="${1-}"
  shift || true
  case "${p3_sub}" in
  active)
    machines_activation_active
    ;;
  has)
    machines_activation_has "${1-}"
    ;;
  view-json)
    machines_view_json | jq -c '.'
    ;;
  resolve)
    p3_id=""
    set +o errexit
    p3_id="$(machines_resolve_id "${1-}" 2>/dev/null)"
    p3_rc=$?
    set -o errexit
    if ((p3_rc != 0)) || [[ -z ${p3_id} ]]; then
      printf 'ERR\n'
    else
      printf '%s\n' "${p3_id}"
    fi
    ;;
  *)
    printf 'phase3-bashside bridge-active: 未知子命令 %q\n' "${p3_sub}" >&2
    exit 64
    ;;
  esac
  ;;
probe-kv)
  kv_get "${1-}" "${2-}"
  ;;
*)
  printf 'phase3-bashside: 未知子命令 %q\n' "${P3_SUBCMD}" >&2
  exit 64
  ;;
esac
