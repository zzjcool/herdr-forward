#!/usr/bin/env bash
# 断言库自测（T0 交付物 1 的红→绿驱动）。先跑红（tests/lib/assertions.sh 不存在
# 时 source 失败 / 接口缺失），实现后转绿。
#
# 手法：把「待验证的断言调用片段」用 quoted heredoc 写进临时脚本，在子进程里执行，
# 再用本库断言子进程的 rc / stdout / stderr。既能测通过路径（绿），也能测失败路径
# （断言不成立时必须记 FAIL 并让 t_done 非零退出）。
# 用 heredoc（而非单引号字符串）是为了让 shellcheck 也能检查这些片段，且保持
# ${TMPDIR_T0} 等变量在子进程内展开。
set -Eeuo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_FILE="${TESTS_DIR}/../lib/assertions.sh"

if [[ ! -f "${LIB_FILE}" ]]; then
  echo "RED: 断言库不存在：${LIB_FILE}（TDD 第一步先红）" >&2
  exit 1
fi

# shellcheck source=tests/lib/assertions.sh
source "${LIB_FILE}"

TMPDIR_T0="$(mktemp -d)"
export TMPDIR_T0
PROBE_FILE="${TMPDIR_T0}/probe.sh"
trap 'rm -rf "${TMPDIR_T0}"' EXIT

# 把 stdin 的片段包装成完整测试脚本：严格模式 + source 本库 + 片段 + t_done。
write_probe() {
  local body
  body="$(cat)"
  {
    printf 'set -Eeuo pipefail\n'
    printf 'source %q\n' "${LIB_FILE}"
    printf '%s\n' "${body}"
    printf 't_done\n'
  } >"${PROBE_FILE}"
}

# probe_passes <msg>：stdin 片段必须全绿（rc=0 且无 not ok）。
probe_passes() {
  local msg="${1:-probe}"
  local body
  body="$(cat)"
  printf '%s\n' "${body}" >"${TMPDIR_T0}/last-body.sh"
  write_probe <"${TMPDIR_T0}/last-body.sh"
  run bash "${PROBE_FILE}"
  t_is 0 "${rc}" "${msg}：期望 rc=0（err=${err}）"
  t_isnt 1 "$(printf '%s' "${out}" | grep -c 'not ok' || true)" "${msg}：期望无失败断言"
}

# probe_fails <msg>：stdin 片段必须红（rc 非零且输出含 not ok）。
probe_fails() {
  local msg="${1:-probe}"
  local body
  body="$(cat)"
  printf '%s\n' "${body}" >"${TMPDIR_T0}/last-body.sh"
  write_probe <"${TMPDIR_T0}/last-body.sh"
  run bash "${PROBE_FILE}"
  t_is 1 "${rc}" "${msg}：期望 rc=1"
  t_contains "not ok" "${out}" "${msg}：期望输出含 not ok"
}

t_describe "assertions.sh 接口存在性（B.1 冻结集）"
t_it "所有冻结函数都已定义"
for fn in t_describe t_it t_ok t_fail t_eq t_match t_exit_ok t_file_exists \
  t_json_valid t_no_zombie_ssh t_done run; do
  if declare -F "${fn}" >/dev/null 2>&1; then
    t_ok "定义存在：${fn}"
  else
    t_fail "定义缺失：${fn}"
  fi
done

t_describe "扩展便利接口（T0 追加，非冻结）"
t_it "扩展函数都已定义"
for fn in t_pass t_is t_isnt t_contains t_matches t_dies_with t_run t_summary t_file_absent t_skip; do
  if declare -F "${fn}" >/dev/null 2>&1; then
    t_ok "定义存在：${fn}"
  else
    t_fail "定义缺失：${fn}"
  fi
done

t_describe "通过路径：真断言必须全绿"
t_it "t_ok / t_eq / t_is / t_match / t_contains 的绿路径"
probe_passes "真断言绿路径" <<'PROBE'
[[ 1 -eq 1 ]] && t_ok "t_ok 条件为真" || t_fail "t_ok 条件为真"
t_eq "abc" "abc" "t_eq 相等"
t_is "abc" "abc" "t_is 相等"
t_match "^ab" "abc" "t_match 命中"
t_contains "bc" "abc" "t_contains 命中"
t_pass "无条件通过"
PROBE

t_it "t_isnt / t_exit_ok / t_file_exists / t_json_valid / t_dies_with / t_run"
probe_passes "其余真断言的绿路径" <<'PROBE'
t_isnt "a" "b" "t_isnt 不等"
t_exit_ok 3 3 "t_exit_ok 码相符"
printf 'x' >"${TMPDIR_T0}/f.txt"
t_file_exists "${TMPDIR_T0}/f.txt" "t_file_exists 存在"
t_file_absent "${TMPDIR_T0}/no-such-file" "t_file_absent 不存在"
printf '%s\n' '{"a":1}' >"${TMPDIR_T0}/ok.json"
t_json_valid "${TMPDIR_T0}/ok.json" "t_json_valid 合法"
run bash -c 'exit 0'
t_run bash -c 'exit 0' "t_run 成功命令"
t_dies_with 3 bash -c 'exit 3' "t_dies_with 退出码 3"
run bash -c 'echo captured-line'
t_contains 'captured-line' "${out}" "run 捕获 stdout"
t_is 0 "${rc}" "run 捕获 rc"
PROBE

t_it "t_summary 可作为 t_done 别名收尾"
probe_passes "t_summary 收尾" <<'PROBE'
t_ok "先通过一条"
t_summary
PROBE

t_describe "失败路径：假断言必须红（防止静默通过）"
t_it "每个断言在条件不成立时记 FAIL 并 rc!=0"
probe_fails "t_eq 不等应红" <<'PROBE'
t_eq "a" "b"
PROBE
probe_fails "t_is 不等应红" <<'PROBE'
t_is "a" "b"
PROBE
probe_fails "t_isnt 相等应红" <<'PROBE'
t_isnt "a" "a"
PROBE
probe_fails "t_contains 未命中应红" <<'PROBE'
t_contains "zzz" "abc"
PROBE
probe_fails "t_match 未命中应红" <<'PROBE'
t_match "^z" "abc"
PROBE
probe_fails "t_matches 未命中应红" <<'PROBE'
t_matches "^z" "abc"
PROBE
probe_fails "t_exit_ok 码不符应红" <<'PROBE'
t_exit_ok 3 4
PROBE
probe_fails "t_file_exists 缺失应红" <<'PROBE'
t_file_exists "${TMPDIR_T0}/definitely-absent"
PROBE
probe_fails "t_file_absent 存在应红" <<'PROBE'
t_file_absent "${TMPDIR_T0}/probe.sh"
PROBE
probe_fails "t_json_valid 坏 JSON 应红" <<'PROBE'
printf 'x' >"${TMPDIR_T0}/bad.json"
t_json_valid "${TMPDIR_T0}/bad.json"
PROBE
probe_fails "t_dies_with 退出码不符应红" <<'PROBE'
t_dies_with 3 bash -c 'exit 4'
PROBE
probe_fails "t_dies_with 命令成功应红" <<'PROBE'
t_dies_with 3 bash -c 'exit 0'
PROBE
probe_fails "t_fail 分支必须记 FAIL" <<'PROBE'
[[ 1 -eq 2 ]] && t_ok "此处应为假" || t_fail "假路径"
PROBE
probe_fails "t_ok 在前置命令失败时必须红" <<'PROBE'
set +e
false
t_ok "上一条命令应为真"
PROBE

t_describe "run/t_run 捕获语义"
t_it "run 捕获 rc/out/err 且不因被测命令失败而终止"
probe_passes "run 捕获语义" <<'PROBE'
run bash -c 'echo O; echo E >&2; exit 7'
t_is 7 "${rc}" "run 捕获 rc"
t_is "O" "${out}" "run 捕获 stdout"
t_is "E" "${err}" "run 捕获 stderr"
run bash -c 'exit 9'
t_is 9 "${rc}" "run 二次捕获 rc"
t_is 0 "$?" "run 自身返回 0（不打断 set -e）"
PROBE

t_it "t_run 断言命令成功；失败命令时记 FAIL"
probe_fails "t_run 对失败命令应红" <<'PROBE'
t_run bash -c 'exit 9'
PROBE

t_describe "t_no_zombie_ssh 僵尸检测"
t_it "无残留时通过"
probe_passes "无残留应绿" <<'PROBE'
if command -v pgrep >/dev/null 2>&1; then
  t_no_zombie_ssh
else
  t_ok "pgrep 不可用，跳过残留检测"
fi
PROBE

t_it "存在 ssh ... herdr-forward 残留时必须红"
probe_fails "残留进程必须被检出" <<'PROBE'
if ! command -v pgrep >/dev/null 2>&1; then
  t_ok "pgrep 不可用，跳过"
else
  bash -c 'exec -a "ssh -N -L 23000:127.0.0.1:23000 -o ControlPath=/tmp/fake/herdr-forward/ctl-f-3000 fwduser@127.0.0.1" sleep 30' &
  fake_pid=$!
  sleep 0.5
  t_no_zombie_ssh
  kill "${fake_pid}" 2>/dev/null || true
  wait "${fake_pid}" 2>/dev/null || true
fi
PROBE

t_describe "计数与收尾语义"
t_it "PASS 在通过断言后递增，FAIL 在失败断言后递增"
probe_passes "PASS 计数递增" <<'PROBE'
before="${PASS}"
t_ok "一"
t_ok "二"
[[ "$((PASS - before))" -eq 2 ]] && t_pass "PASS 递增 2" || t_fail "PASS 未递增（before=${before} after=${PASS}）"
PROBE

probe_fails "FAIL 计数在失败后递增" <<'PROBE'
before="${FAIL}"
t_fail "故意失败"
[[ "$((FAIL - before))" -eq 1 ]] && t_pass "FAIL 递增 1" || t_fail "FAIL 未递增（before=${before} after=${FAIL}）"
PROBE

t_it "t_done 输出 TAP 计划行与统计"
probe_passes "t_done 统计输出" <<'PROBE'
t_ok "一条通过"
PROBE
t_contains "1..1" "${out}" "t_done 输出 TAP 计划行"
t_contains "PASS: 1 FAIL: 0" "${out}" "t_done 输出统计行"

t_it "t_skip 计入总数、不算失败且必须带原因"
probe_passes "t_skip 收尾" <<'PROBE'
t_skip "环境缺 nc，走等价断言"
t_ok "另一条通过"
[[ "${SKIP}" -eq 1 ]] && t_pass "SKIP 计数为 1" || t_fail "SKIP 未计数"
PROBE
t_contains "SKIP: 环境缺 nc" "${out}" "t_skip 输出带原因"
t_contains "SKIP: 1" "${out}" "汇总行包含 SKIP 计数"
t_contains "FAIL: 0" "${out}" "t_skip 不计入 FAIL"

t_done
