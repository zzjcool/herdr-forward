#!/usr/bin/env bash
# tests/unit/test_state.sh — lib/state.sh 契约单测（A.2 数据契约 + A.3 签名）
# 覆盖：state_file/state_load（损坏容错不 crash）/state_save（原子写、version 封装）/
#       forward_add_record（重复 local_port die 2、字段归一化）/forward_remove_record（不存在 die 3）/
#       forward_get/forward_list_json/forward_set_status
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FIXTURES="${ROOT}/tests/fixtures"

# --- 断言库：B.1 契约接口；T0 的 tests/lib/assertions.sh 合并前用最小占位子集 ---
if [[ -f "${ROOT}/tests/lib/assertions.sh" ]]; then
  # shellcheck source=/dev/null
  source "${ROOT}/tests/lib/assertions.sh"
else
  echo "WARN: tests/lib/assertions.sh 未就绪（T0 未合并），使用 B.1 契约最小占位子集" >&2
  PASS=0
  FAIL=0
  t_describe() { printf '\n== %s\n' "$*"; }
  t_it() { printf '  - %s\n' "$*"; }
  t_pass() {
    PASS=$((PASS + 1))
    printf '    ok   %s\n' "${1:-}"
  }
  t_fail_note() {
    FAIL=$((FAIL + 1))
    printf '    FAIL %s\n' "${1:-}"
  }
  t_ok() { if [[ -n "${1-}" ]]; then t_pass "${2:-ok}"; else t_fail_note "${2:-expected truthy}"; fi; }
  t_eq() {
    if [[ "${1-}" == "${2-}" ]]; then t_pass "${3:-eq}"; else t_fail_note "${3:-eq}: expected [$1] got [$2]"; fi
  }
  t_match() {
    if [[ "${2-}" =~ ${1-} ]]; then t_pass "${3:-match}"; else t_fail_note "${3:-match}: /$1/ not in [$2]"; fi
  }
  t_exit_ok() {
    if [[ "${1-}" == "${2-}" ]]; then t_pass "${3:-exit ok}"; else t_fail_note "${3:-exit}: expected $1 got $2"; fi
  }
  t_file_exists() { if [[ -f "${1-}" ]]; then t_pass "file exists: ${1}"; else t_fail_note "missing file: ${1}"; fi; }
  t_json_valid() { if jq empty "${1-}" >/dev/null 2>&1; then t_pass "json valid: ${1}"; else t_fail_note "invalid json: ${1}"; fi; }
  t_no_zombie_ssh() { t_pass "no-zombie-ssh (占位)"; }
  t_done() {
    printf '\n%d passed, %d failed\n' "${PASS}" "${FAIL}"
    [[ "${FAIL}" -eq 0 ]]
  }
  run() {
    local func="${1-}"
    shift || true
    set +e
    out="$("${func}" "$@" 2>/tmp/.t_run_err.$$)"
    rc=$?
    err="$(cat /tmp/.t_run_err.$$ 2>/dev/null || true)"
    rm -f /tmp/.t_run_err.$$
    set -e
  }
fi

if [[ ! -f "${ROOT}/lib/state.sh" ]]; then
  echo "RED: lib/state.sh 不存在（state 层尚未实现，T2 被阻塞）" >&2
  exit 1
fi
# shellcheck source=/dev/null
source "${ROOT}/lib/common.sh"
# shellcheck source=/dev/null
source "${ROOT}/lib/state.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
export HERDR_PLUGIN_STATE_DIR="${TMP}/state"
mkdir -p "${HERDR_PLUGIN_STATE_DIR}"

# --- 捕获助手：先落变量再断言 ---
out=""
err=""
rc=0
got=""

_capture() {
  set +o errexit
  out="$("$@" 2>"${TMP}/.stderr")"
  rc=$?
  set -o errexit
  err="$(cat "${TMP}/.stderr" 2>/dev/null || true)"
}

# _capture_src <snippet>：子进程 source common+state 后 eval 片段
HELPER="${TMP}/src_snippet.sh"
cat >"${HELPER}" <<'HELPER_EOF'
#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail
source "$1/lib/common.sh"
source "$1/lib/state.sh"
shift
eval "$*"
HELPER_EOF
chmod +x "${HELPER}"
_capture_src() { _capture "${HELPER}" "${ROOT}" "${1-}"; }

_readfile() {
  got=""
  if [[ -f "${1-}" ]]; then
    got="$(cat "${1-}")"
  fi
}

_jqf() {
  got=""
  set +o errexit
  got="$(printf '%s' "${1-}" | jq -r "${2-}" 2>/dev/null)"
  set -o errexit
}

# SF：状态文件路径（先取值再断言，避免 SC2312）
SF=""
sf_path() { SF="$(state_file)"; }

_write_fixture() {
  sf_path
  cp "${FIXTURES}/${1-}" "${SF}"
}

# 每条用例前重置状态文件（删除 = 空状态）
_reset_state() {
  sf_path
  rm -f "${SF}"
}

# _state_json：状态文件内容 -> STATE_JSON（不存在则空串）
STATE_JSON=""
_state_json() {
  sf_path
  STATE_JSON=""
  [[ -f "${SF}" ]] && STATE_JSON="$(cat "${SF}")"
}

t_describe "state.sh: state_file / state_load 容错"

t_it "state_file 位于 \$HERDR_PLUGIN_STATE_DIR/forwards.json"
_capture state_file
t_eq "${HERDR_PLUGIN_STATE_DIR}/forwards.json" "${out}" "state_file 路径"

t_it "state_load 文件缺失 -> 空数组（不 crash）"
_reset_state
_capture state_load
t_exit_ok 0 "${rc}" "缺失不崩"
t_eq "[]" "${out}" "缺失 -> []"

t_it "state_load 损坏 JSON -> 空数组 + warn（不 crash）"
_write_fixture forwards.corrupt.json
sf_path
t_file_exists "${SF}"
_capture state_load
t_exit_ok 0 "${rc}" "损坏不崩"
t_eq "[]" "${out}" "损坏 -> []"
t_match "warn" "${err}" "损坏时有 warn"

t_it "state_load 合法单条 -> 原样数组"
_write_fixture forwards.valid.json
_capture state_load
t_exit_ok 0 "${rc}" "合法不崩"
_jqf "${out}" 'length'
t_eq "1" "${got}" "单条长度 1"
_jqf "${out}" '.[0].id'
t_eq "f-3000" "${got}" "id 保真"

t_it "state_load 多记录 -> 2 条"
_write_fixture forwards.multi.json
_capture state_load
_jqf "${out}" 'length'
t_eq "2" "${got}" "两条"

t_it "state_load 空数组 fixture -> []"
_write_fixture forwards.empty.json
_capture state_load
t_eq "[]" "${out}" "空数组"

t_it "state_load 信封非数组（forwards 缺失）-> 空数组 + warn"
sf_path
printf '{"version":1}' >"${SF}"
_capture state_load
t_exit_ok 0 "${rc}" "缺失 forwards 键不崩"
t_eq "[]" "${out}" "-> []"

t_it "state_load 顶层非对象（标量 JSON）-> 空数组 + warn"
sf_path
printf '"just-a-string"' >"${SF}"
_capture state_load
t_exit_ok 0 "${rc}" "标量不崩"
t_eq "[]" "${out}" "-> []"

t_describe "state.sh: state_save 原子写 + version 封装"

t_it "state_save 落盘 version=1 且 forwards 保序"
_reset_state
state_save '[{"id":"f-1","local_port":1,"status":"up"}]'
sf_path
t_json_valid "${SF}"
_state_json
_jqf "${STATE_JSON}" '.version'
t_eq "1" "${got}" "version=1"
_jqf "${STATE_JSON}" '.forwards | length'
t_eq "1" "${got}" "forwards 1 条"

t_it "state_save 覆盖旧内容（非追加）"
state_save '[{"id":"f-2","local_port":2,"status":"down"}]'
_state_json
_jqf "${STATE_JSON}" '.forwards[0].id'
t_eq "f-2" "${got}" "覆盖为 f-2"

t_it "state_save 非数组输入 -> die 1"
_capture_src 'state_save "{\"not\":\"array\"}"'
t_exit_ok 1 "${rc}" "非数组 die 1"

t_it "state_save 经 state_load 往返一致"
state_save '[{"id":"f-9","local_port":9,"status":"up"},{"id":"f-8","local_port":8,"status":"down"}]'
_capture state_load
_jqf "${out}" '[.[].id] | join(",")'
t_eq "f-9,f-8" "${got}" "往返保序"

t_it "state_save 原子：不残留临时文件"
LEFTOVER="$(find "${TMP}" -name '.atomic.*' 2>/dev/null | wc -l)"
t_eq "0" "${LEFTOVER// /}" "无临时文件"

t_describe "state.sh: forward_add_record"

t_it "add 归一化字段（id/remote_host/status/publish 占位）"
_reset_state
forward_add_record '{"local_port":3000,"remote_port":9443,"machine":"gpu","ssh_target":"u@g:22"}'
_capture state_load
_jqf "${out}" '.[0].id'
t_eq "f-3000" "${got}" "id = f-<local_port>"
_jqf "${out}" '.[0].remote_host'
t_eq "127.0.0.1" "${got}" "remote_host 默认 127.0.0.1"
_jqf "${out}" '.[0].status'
t_match "^(starting|up|down)$" "${got}" "status 合法"
_jqf "${out}" '.[0].publish | type'
t_eq "object" "${got}" "publish 占位对象"
_jqf "${out}" '.[0].publish.url'
t_eq "null" "${got}" "publish.url 一期恒 null"
_jqf "${out}" '.[0].created_unix | type'
t_eq "number" "${got}" "created_unix 数字"

t_it "add 重复 local_port -> die 2（不覆盖，含下一步建议）"
_capture_src 'forward_add_record "{\"local_port\":3000,\"remote_port\":1,\"ssh_target\":\"u@g:22\"}"'
t_exit_ok 2 "${rc}" "重复端口 die 2"
_state_json
_jqf "${STATE_JSON}" '.forwards | length'
t_eq "1" "${got}" "未写入第二条"

t_it "add 相同 local_port 不同 remote_port 仍 die 2"
_capture_src 'forward_add_record "{\"local_port\":3000,\"remote_port\":9999,\"ssh_target\":\"u@g:22\"}"'
t_exit_ok 2 "${rc}" "端口唯一"

t_it "add 缺 local_port -> die 1"
_capture_src 'forward_add_record "{\"remote_port\":1}"'
t_exit_ok 1 "${rc}" "缺 local_port die 1"

t_it "add 非法 local_port（越界）-> die 1"
_capture_src 'forward_add_record "{\"local_port\":99999,\"remote_port\":1}"'
t_exit_ok 1 "${rc}" "越界 die 1"

t_it "add 非 JSON 输入 -> die 1"
_capture_src 'forward_add_record "not-json"'
t_exit_ok 1 "${rc}" "非 JSON die 1"

t_it "add 可追加不同端口"
forward_add_record '{"local_port":5173,"remote_port":5173,"machine":"web","ssh_target":"d@w:22"}'
_capture state_load
_jqf "${out}" 'length'
t_eq "2" "${got}" "两条"

t_describe "state.sh: forward_get / forward_list_json"

t_it "forward_get 命中返回单条"
_capture forward_get f-5173
t_exit_ok 0 "${rc}" "命中 exit 0"
_jqf "${out}" '.id'
t_eq "f-5173" "${got}" "id 正确"

t_it "forward_get 不存在 -> die 3"
_capture forward_get f-99999
t_exit_ok 3 "${rc}" "不存在 die 3"

t_it "forward_list_json 返回完整数组"
_capture forward_list_json
t_exit_ok 0 "${rc}" "list_json exit 0"
_jqf "${out}" 'length'
t_eq "2" "${got}" "两条"
_jqf "${out}" 'type'
t_eq "array" "${got}" "是数组"

t_it "forward_list_json 空状态 -> []"
_reset_state
_capture forward_list_json
t_eq "[]" "${out}" "空数组"

t_describe "state.sh: forward_set_status"

t_it "forward_set_status 改状态为 down"
forward_add_record '{"local_port":4000,"remote_port":4000,"ssh_target":"u@g:22"}'
forward_set_status f-4000 down
_capture forward_get f-4000
_jqf "${out}" '.status'
t_eq "down" "${got}" "状态改成功"

t_it "forward_set_status 非法状态 -> die 1"
_capture_src 'forward_set_status f-4000 bogus'
t_exit_ok 1 "${rc}" "非法状态 die 1"

t_it "forward_set_status 不存在 id -> die 3"
_capture_src 'forward_set_status f-99999 up'
t_exit_ok 3 "${rc}" "不存在 die 3"

t_it "forward_set_status 不影响其他记录"
forward_add_record '{"local_port":4001,"remote_port":4001,"ssh_target":"u@g:22"}'
forward_set_status f-4000 up
_capture forward_get f-4001
_jqf "${out}" '.status'
t_match "^(starting|up|down)$" "${got}" "另一条状态未坏"

t_describe "state.sh: forward_remove_record"

t_it "forward_remove_record 删除并保留其余"
_reset_state
forward_add_record '{"local_port":5000,"remote_port":5000,"ssh_target":"u@g:22"}'
forward_add_record '{"local_port":5001,"remote_port":5001,"ssh_target":"u@g:22"}'
forward_remove_record f-5000
_capture state_load
_jqf "${out}" 'length'
t_eq "1" "${got}" "剩一条"
_jqf "${out}" '.[0].id'
t_eq "f-5001" "${got}" "保留 f-5001"

t_it "forward_remove_record 不存在 -> die 3（含建议）"
_capture_src 'forward_remove_record f-99999'
t_exit_ok 3 "${rc}" "不存在 die 3"
t_match "list" "${err}" "错误提示 forward list"

t_it "forward_remove_record 删最后一条 -> 空数组（不崩）"
forward_remove_record f-5001
_capture state_load
t_eq "[]" "${out}" "空数组"

t_describe "state.sh: 缺字段 fixture 容错"

t_it "state_load 记录缺字段也不崩（fixture 保真）"
_write_fixture forwards.missing_fields.json
_capture state_load
t_exit_ok 0 "${rc}" "缺字段记录不崩"
_jqf "${out}" 'length'
t_eq "2" "${got}" "2 条"

t_done
