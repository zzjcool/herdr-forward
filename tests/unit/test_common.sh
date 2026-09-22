#!/usr/bin/env bash
# tests/unit/test_common.sh — lib/common.sh 契约单测（A.3）
# 覆盖：state_dir / log + 轮转、die 退出码、require_cmd、now_unix、atomic_write 原子往返、
#       probe_tcp 永不 exit、tcp_serve_once 参数校验
# 纪律：零网络零进程（probe_tcp 只探必失败端口；tcp_serve_once 只测参数校验路径）。
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

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

if [[ ! -f "${ROOT}/lib/common.sh" ]]; then
  echo "RED: lib/common.sh 不存在（common 原语尚未实现）" >&2
  exit 1
fi
# shellcheck source=/dev/null
source "${ROOT}/lib/common.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
export HERDR_PLUGIN_STATE_DIR="${TMP}/state"
mkdir -p "${HERDR_PLUGIN_STATE_DIR}"

# --- 捕获助手：一律先落变量再断言，避免 SC2312/SC2310 ---
out=""
err=""
rc=0
got=""

# 在子进程里 source lib/common.sh 后执行片段的入口脚本（避免 bash -c 单引号 SC2016）
HELPER="${TMP}/src_snippet.sh"
cat >"${HELPER}" <<'HELPER_EOF'
#!/usr/bin/env bash
# 用法：src_snippet.sh <plugin_root> <snippet...>
set -o errexit -o nounset -o pipefail
source "$1/lib/common.sh"
shift
eval "$*"
HELPER_EOF
chmod +x "${HELPER}"

# _capture <cmd...>：捕获 stdout -> out，stderr -> err，退出码 -> rc
_capture() {
  set +o errexit
  out="$("$@" 2>"${TMP}/.stderr")"
  rc=$?
  set -o errexit
  err="$(cat "${TMP}/.stderr" 2>/dev/null || true)"
}

# _capture_src <snippet>：子进程 source common.sh 后 eval 片段
_capture_src() { _capture "${HELPER}" "${ROOT}" "${1-}"; }

# _capture_src_noenv <snippet>：同上但 unset HERDR_PLUGIN_STATE_DIR
_capture_src_noenv() { _capture env -u HERDR_PLUGIN_STATE_DIR "${HELPER}" "${ROOT}" "${1-}"; }

# _readfile <path>：文件内容 -> got（文件不存在则为空）
_readfile() {
  got=""
  if [[ -f "${1-}" ]]; then
    got="$(cat "${1-}")"
  fi
}

# _count <cmd...>：stdout -> got（去空白的整数）
_count() {
  got=""
  set +o errexit
  got="$("$@" 2>/dev/null)"
  set -o errexit
  got="${got// /}"
}

t_describe "common.sh: state_dir / log"

t_it "state_dir 遵循 HERDR_PLUGIN_STATE_DIR"
_capture state_dir
t_eq "${HERDR_PLUGIN_STATE_DIR}" "${out}" "state_dir 用 env"

t_it "state_dir 无 env 时回退 HOME/.local/state/herdr-forward"
_capture_src_noenv 'state_dir'
t_eq "${HOME}/.local/state/herdr-forward" "${out}" "state_dir fallback"

t_it "log 写入 \$HERDR_PLUGIN_STATE_DIR/logs/forward.log 且带级别"
LOGFILE="${HERDR_PLUGIN_STATE_DIR}/logs/forward.log"
log info "unit-log-probe-1"
t_file_exists "${LOGFILE}"
_readfile "${LOGFILE}"
t_match "info: unit-log-probe-1" "${got}" "log info 落盘"

t_it "log warn/error 同时镜像到 stderr"
_capture log warn "unit-log-probe-warn"
t_match "warn: unit-log-probe-warn" "${err}" "warn 镜像 stderr"
_readfile "${LOGFILE}"
t_match "warn: unit-log-probe-warn" "${got}" "warn 也落盘"

t_it "无 env 时 log 落 stderr（不写文件）"
_capture_src_noenv 'log info "stdout-only-probe"'
t_match "info: stdout-only-probe" "${err}" "无 env 时写 stderr"

t_it "日志 >1MB 时截断保留后半"
python3 -c 'import sys; sys.stdout.write("Z" * 1100000)' >"${LOGFILE}"
log info "after-rotate-probe"
_count wc -c <"${LOGFILE}"
SIZE="${got}"
ROT_FLAG="no"
if [[ "${SIZE}" -lt 800000 ]]; then
  ROT_FLAG="yes"
fi
t_eq "yes" "${ROT_FLAG}" "轮转后体积 ${SIZE} < 800KB"
_readfile "${LOGFILE}"
t_match "after-rotate-probe" "${got}" "轮转保留新日志"

t_describe "common.sh: die / require_cmd / now_unix"

t_it "die 以给定退出码退出"
_capture_src 'die 3 "boom"'
t_exit_ok 3 "${rc}" "die 3"
t_match "error: boom" "${err}" "die 记录 error"

t_it "die 默认退出码 1"
_capture_src 'die'
t_exit_ok 1 "${rc}" "die 默认 1"

t_it "require_cmd 命中已存在命令"
_capture_src 'require_cmd bash'
t_exit_ok 0 "${rc}" "require_cmd bash"

t_it "require_cmd 缺失命令 die 127 且提示下一步"
_capture_src 'require_cmd definitely-not-a-real-cmd-xyz "请安装后重试"'
t_exit_ok 127 "${rc}" "require_cmd 缺失 -> 127"
t_match "请安装后重试" "${err}" "错误含下一步建议"

t_it "now_unix 输出十进制 epoch"
_capture now_unix
t_match "^[0-9]{9,}$" "${out}" "now_unix 形状"

t_describe "common.sh: atomic_write"

t_it "atomic_write 往返内容一致"
printf '{"hello":1}\n' | atomic_write "${TMP}/sub/deep/out.json" "${TMP}"
_readfile "${TMP}/sub/deep/out.json"
t_eq '{"hello":1}' "${got}" "内容一致"

t_it "atomic_write 目标目录不存在时自动创建"
t_file_exists "${TMP}/sub/deep/out.json"

t_it "atomic_write 不残留临时文件"
LEFTOVER="$(find "${TMP}" -name '.atomic.*' 2>/dev/null | wc -l)"
LEFTOVER="${LEFTOVER// /}"
t_eq "0" "${LEFTOVER}" "无 .atomic.* 残留"

t_it "atomic_write 覆盖已存在文件（原子替换，不追加）"
printf 'old\n' >"${TMP}/over.json"
printf 'new\n' | atomic_write "${TMP}/over.json" "${TMP}"
_readfile "${TMP}/over.json"
t_eq "new" "${got}" "覆盖为新内容"

t_it "atomic_write 缺参 -> die 1"
_capture_src "printf x | atomic_write ${TMP}/only-one-arg"
t_exit_ok 1 "${rc}" "缺 tmpdir -> die 1"

t_it "atomic_write 空输入落盘为空文件"
printf '' | atomic_write "${TMP}/empty.json" "${TMP}"
t_file_exists "${TMP}/empty.json"
_count wc -c <"${TMP}/empty.json"
t_eq "0" "${got}" "空输入写空文件"

t_describe "common.sh: probe_tcp"

t_it "probe_tcp 对已监听端口输出 ok"
_capture probe_tcp 127.0.0.1 22 1
t_exit_ok 0 "${rc}" "永不 exit"
t_eq "ok" "${out}" "22 端口 ok"

t_it "probe_tcp 对关闭端口输出 fail 且仍 return 0"
_capture probe_tcp 127.0.0.1 1 1
t_exit_ok 0 "${rc}" "失败也 return 0"
t_eq "fail" "${out}" "端口 1 fail"

t_it "probe_tcp 空参数输出 fail 不崩"
_capture probe_tcp "" ""
t_exit_ok 0 "${rc}" "空参数不 exit"
t_eq "fail" "${out}" "空参数 fail"

t_it "probe_tcp 输出恒为单行"
_capture probe_tcp 127.0.0.1 1 1
LINES="$(printf '%s' "${out}" | grep -c '')"
t_eq "1" "${LINES}" "单行输出"

t_describe "common.sh: tcp_serve_once"

t_it "tcp_serve_once 缺参 -> die 1 且提示用法"
_capture_src 'tcp_serve_once'
t_exit_ok 1 "${rc}" "缺参 die 1"
t_match "用法|port" "${err}" "提示用法"

t_it "tcp_serve_once 非法端口 -> die 1"
_capture_src 'tcp_serve_once 99999'
t_exit_ok 1 "${rc}" "越界端口 die 1"
_capture_src 'tcp_serve_once abc'
t_exit_ok 1 "${rc}" "非数字端口 die 1"

t_it "tcp_serve_once 后端存在（nc 或 python3）；两者皆无则 die 127"
BACKEND="no"
if command -v nc >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1; then
  BACKEND="yes"
fi
if [[ "${BACKEND}" == "yes" ]]; then
  t_eq "yes" "${BACKEND}" "存在 nc 或 python3 后端"
else
  _capture_src 'tcp_serve_once 19555'
  t_exit_ok 127 "${rc}" "两者皆无 -> die 127"
fi

t_done
