#!/usr/bin/env bash
# tests/unit/test_lib_single_source.sh — N3（review nit）：lib/*.sh 不得各自复制
# common.sh 的 log/die/require_cmd/... 回退副本（那些副本与 T1 的 common.sh 漂移，
# 且让「唯一 writer」契约失效）。
#
# 契约：machine.sh / tunnel.sh / notify.sh 一律 source 同目录的真 common.sh；
#       「有 common.sh 就用，没有就自己造一份 log」的 guard 块必须删除。
#
# 本测试是**静态守卫 + 行为回归**双层：
#   1) 静态：源码中不得出现 `if ! declare -F log` 这类回退 guard；
#   2) 行为：source 各 lib 后，log 必须写进 $HERDR_PLUGIN_STATE_DIR/logs/forward.log
#      （证明用的是真 common.sh 的 log，而不是「只写 stderr」的回退副本）。
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [[ -f "${ROOT}/tests/lib/assertions.sh" ]]; then
  # shellcheck source=/dev/null
  source "${ROOT}/tests/lib/assertions.sh"
fi
if ! declare -F t_fail_note >/dev/null 2>&1; then
  t_fail_note() { t_fail "$@"; }
fi

LIBS=(machine tunnel notify)

TMP="$(mktemp -d "${TMPDIR:-/tmp}/n3-single-source.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT

t_describe "N3: lib/*.sh 不再自带 common.sh 回退副本"

t_it "每个 lib 都存在"
for lib in "${LIBS[@]}"; do
  file="${ROOT}/lib/${lib}.sh"
  if [[ -f "${file}" ]]; then
    t_pass "${lib}.sh 存在"
  else
    t_fail_note "${lib}.sh 缺失"
  fi
done

t_it "每个 lib 都 source 同目录的 common.sh（单一权威）"
for lib in "${LIBS[@]}"; do
  file="${ROOT}/lib/${lib}.sh"
  if grep -qE '^\s*source "\$\{[A-Za-z_]+_LIB_DIR\}/common\.sh"' "${file}"; then
    t_pass "${lib}.sh sources common.sh"
  else
    t_fail_note "${lib}.sh 未 source common.sh"
  fi
done

t_it "不再有 'declare -F log/... >/dev/null 2>&1' 回退 guard（副本已删）"
for lib in "${LIBS[@]}"; do
  file="${ROOT}/lib/${lib}.sh"
  hits="$(grep -nE '^[[:space:]]*if ![[:space:]]*declare -F (log|die|require_cmd|now_unix|atomic_write|probe_tcp)\b' "${file}" || true)"
  if [[ -z "${hits}" ]]; then
    t_pass "${lib}.sh 无回退 guard"
  else
    t_fail_note "${lib}.sh 仍有回退 guard：${hits//$'\n'/; }"
  fi
done

t_it "不再有回退副本里才有的内联定义（date '+%Y-%m-%dT%H:%M:%S%z'）"
for lib in "${LIBS[@]}"; do
  file="${ROOT}/lib/${lib}.sh"
  if grep -qF "date '+%Y-%m-%dT%H:%M:%S%z'" "${file}"; then
    t_fail_note "${lib}.sh 仍内联复制了 log 回退实现"
  else
    t_pass "${lib}.sh 无内联 log 副本"
  fi
done

t_describe "N3 行为回归：source 各 lib 后 log 走真 common.sh（落盘而非仅 stderr）"

for lib in "${LIBS[@]}"; do
  t_it "source ${lib}.sh 后 log info 写进 forward.log"
  state="${TMP}/${lib}-state"
  mkdir -p "${state}"
  probe="n3-${lib}-probe"
  set +o errexit
  (HERDR_PLUGIN_STATE_DIR="${state}" bash -c '
set -Eeuo pipefail
source "$1/lib/'"${lib}"'.sh"
log info "'"${probe}"'"
' _ "${ROOT}") >/dev/null 2>&1
  set -o errexit
  logfile="${state}/logs/forward.log"
  if [[ -f "${logfile}" ]] && grep -qF -- "${probe}" "${logfile}"; then
    t_pass "${lib}: log 落盘（真 common.sh）"
  else
    t_fail_note "${lib}: log 未落盘 —— 仍在用只写 stderr 的回退副本（logfile=${logfile}）"
  fi
done

t_done
