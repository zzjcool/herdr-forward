#!/usr/bin/env bash
# tests/difftest/bashside.sh — 差分测试的 bash 对位入口（PLAN-GO-MIGRATION §6 Phase 1 / §10 W1）
#
# 只做一件事：source 真实的 lib/common.sh + lib/state.sh，把子命令转发到对应函数，
# 供 tests/difftest/run.sh 与 Go 侧探针逐字节比对。**不复制**任何逻辑 —— 这里的
# bash 就是生产 bash（唯一权威），否则差分测试就失去意义。
#
# 环境：
#   HERDR_PLUGIN_STATE_DIR  必填（状态目录；run.sh 会给 bash/go 两侧各自独立目录）
#   DIFFTEST_NOW_UNIX       可选；设定后覆盖 now_unix()，让 add 的 created_unix 确定化
#
# 子命令：
#   load                     state_load
#   save <array.json>        state_save "$(cat <array.json>)"
#   add <record.json>        forward_add_record "$(cat <record.json>)"
#   remove <id>              forward_remove_record <id>
#   set-status <id> <status> forward_set_status <id> <status>
#   probe <host> <port> <s>  probe_payload <host> <port> <s>
#   normalize                stdin: forward 数组 -> stdout: 补全 schema 的数组（jq）
#                            （用于「bash 原样透传 vs Go 类型化补零」的可比化）
set -Eeuo pipefail

DIFFTEST_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIFFTEST_ROOT="$(cd "${DIFFTEST_HERE}/../.." && pwd)"

# shellcheck source=/dev/null
source "${DIFFTEST_ROOT}/lib/common.sh"
# shellcheck source=/dev/null
source "${DIFFTEST_ROOT}/lib/state.sh"

# 确定化 now_unix（仅测试用；生产路径不受影响）
if [[ -n ${DIFFTEST_NOW_UNIX:-} ]]; then
  now_unix() { printf '%s\n' "${DIFFTEST_NOW_UNIX}"; }
fi

# normalize_filter：把任意 forward 记录补成 Go 冻结结构体的「零值填充」形态。
# 与 internal/state 的 Load 归一化一一对应：
#   mode 缺失 -> tunnel；其余缺失字段 -> ""/0/null；publish 缺键 -> 三 null。
DIFFTEST_NORMALIZE='[
  .[]
  | {
      control_socket: (.control_socket // ""),
      created_unix:   (.created_unix   // 0),
      id:             (.id             // ""),
      local_port:     (.local_port     // 0),
      machine:        (.machine        // ""),
      mode:           (.mode           // "tunnel"),
      pid:            (.pid            // null),
      publish: {
        pid:          (.publish.pid          // null),
        started_unix: (.publish.started_unix // null),
        url:          (.publish.url          // null)
      },
      remote_host:    (.remote_host    // ""),
      remote_port:    (.remote_port    // 0),
      ssh_target:     (.ssh_target     // ""),
      status:         (.status         // "")
    }
]'

DIFFTEST_SUBCMD="${1-}"
shift || true

case "${DIFFTEST_SUBCMD}" in
load)
  state_load
  ;;
save)
  # 先落变量再传参：避免 SC2312（命令替换掩盖 cat 的退出码）
  _diff_payload="$(cat "${1}")"
  state_save "${_diff_payload}"
  ;;
add)
  _diff_payload="$(cat "${1}")"
  forward_add_record "${_diff_payload}"
  ;;
remove)
  forward_remove_record "${1}"
  ;;
set-status)
  forward_set_status "${1}" "${2}"
  ;;
probe)
  probe_payload "${1}" "${2}" "${3}"
  ;;
normalize)
  jq -S -c "${DIFFTEST_NORMALIZE}"
  ;;
*)
  printf 'bashside: 未知子命令 %q\n' "${DIFFTEST_SUBCMD}" >&2
  exit 64
  ;;
esac
