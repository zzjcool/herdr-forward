#!/usr/bin/env bash
# tests/assertions.sh — 零依赖 bash 断言库（T0 交付物 1）
#
# 归属：T0（唯一 writer）。接口按 ARCHITECTURE.md §B.1 冻结，T0 追加若干便利断言
# （t_pass/t_is/t_isnt/t_contains/t_matches/t_dies_with/t_run/t_summary/t_file_absent），
# 冻结集一个不少、语义不移。
#
# 用法：
#   source tests/assertions.sh
#   t_describe "组名"
#   t_it "用例"
#   run myfunc arg            # 捕获 $out/$err/$rc（run 恒返回 0，不打断 set -e）
#   t_eq "expected" "$actual"
#   t_done                    # 汇总；FAIL>0 时 exit 1；全绿 exit 0
#
# 约定（重要）：
#   * 所有 t_* 断言「只记录、恒返回 0」，退出码只在 t_done/t_summary 统一裁决。
#     这样测试脚本可以用 set -Eeuo pipefail 而断言失败不会中断后续断言。
#   * run 恒返回 0；被测命令的真实退出码在 $rc，stdout 在 $out，stderr 在 $err。
#   * 需要 pgrep/jq 的断言在工具缺失时显式记 FAIL 并打印原因，绝不静默通过。
set -Eeuo pipefail

# 公共状态（由测试文件消费，故显式导出，避免「未使用变量」误报）
PASS=0
FAIL=0
SKIP=0
out=""
err=""
rc=0
export PASS FAIL SKIP out err rc

_T_NAMED_MSG="${_T_NAMED_MSG:-(unnamed)}"

# ---------------------------------------------------------------------------
# 内部：记录与输出（TAP 风格，便于人读也便于 grep）
# ---------------------------------------------------------------------------
_t_note() { printf '# %s\n' "$*"; }

_t_pass() {
  PASS=$((PASS + 1))
  printf 'ok %d - %s\n' "${PASS}" "${1}"
}

_t_fail() {
  FAIL=$((FAIL + 1))
  printf 'not ok %d - %s\n' "${FAIL}" "${1}"
}

# 显式跳过（环境能力缺失等不可控因素）。绝不静默：必须带上原因，且 t_done 会汇总。
_t_skip() {
  SKIP=$((SKIP + 1))
  printf 'ok %d - SKIP: %s\n' "$((PASS + FAIL + SKIP))" "${1}"
}

# ---------------------------------------------------------------------------
# 分组 / 用例标签（纯标签，不断言）
# ---------------------------------------------------------------------------
t_describe() { _t_note "=== ${1:-(unnamed group)}"; }

t_it() { _t_note "--- ${1:-(unnamed case)}"; }

# ---------------------------------------------------------------------------
# B.1 冻结接口
# ---------------------------------------------------------------------------
# t_ok [msg]    断言「上一条命令成功」（消费调用时刻的 $?）
t_ok() {
  local st=$?
  local msg="${1:-${_T_NAMED_MSG}}"
  if [[ "${st}" -eq 0 ]]; then
    _t_pass "${msg}"
  else
    _t_fail "${msg}（期望上一条命令成功，实际 rc=${st}）"
  fi
}

# t_pass [msg]  无条件记录一次通过（与 t_fail 配对，便于分支写法）
t_pass() { _t_pass "${1:-${_T_NAMED_MSG}}"; }

# t_skip <reason>  显式跳过（环境能力缺失）：输出中带 SKIP 与原因，t_done 单独统计
t_skip() { _t_skip "${1:-${_T_NAMED_MSG}}"; }

# t_fail [msg]  无条件记录一次失败
t_fail() { _t_fail "${1:-${_T_NAMED_MSG}}"; }

# t_eq <expected> <actual> [msg]   字符串相等
t_eq() {
  local expected="${1:-}"
  local actual="${2:-}"
  local msg="${3:-${_T_NAMED_MSG}}"
  if [[ "${expected}" == "${actual}" ]]; then
    _t_pass "${msg}"
  else
    _t_fail "${msg}（期望 [${expected}] 实际 [${actual}]）"
  fi
}

# t_is / t_isnt：t_eq 的正/反别名（T0 追加，语义同 t_eq）
t_is() { t_eq "$@"; }

t_isnt() {
  local unexpected="${1:-}"
  local actual="${2:-}"
  local msg="${3:-${_T_NAMED_MSG}}"
  if [[ "${unexpected}" != "${actual}" ]]; then
    _t_pass "${msg}"
  else
    _t_fail "${msg}（不应等于 [${unexpected}]）"
  fi
}

# t_contains <needle> <haystack> [msg]   子串命中
t_contains() {
  local needle="${1:-}"
  local haystack="${2:-}"
  local msg="${3:-${_T_NAMED_MSG}}"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    _t_pass "${msg}"
  else
    _t_fail "${msg}（[${haystack}] 不含 [${needle}]）"
  fi
}

# t_match <regex> <actual> [msg]   regex 命中（任意位置）
t_match() {
  local regex="${1:-}"
  local actual="${2:-}"
  local msg="${3:-${_T_NAMED_MSG}}"
  if [[ "${actual}" =~ ${regex} ]]; then
    _t_pass "${msg}"
  else
    _t_fail "${msg}（[${actual}] 不匹配 /${regex}/）"
  fi
}

t_matches() { t_match "$@"; }

# t_exit_ok <expected_code> <actual_code> [msg]
t_exit_ok() {
  local expected="${1:-}"
  local actual="${2:-}"
  local msg="${3:-${_T_NAMED_MSG}}"
  if [[ "${expected}" =~ ^-?[0-9]+$ && "${actual}" == "${expected}" ]]; then
    _t_pass "${msg}"
  else
    _t_fail "${msg}（期望退出码 ${expected}，实际 ${actual}）"
  fi
}

# t_file_exists <path> [msg]
t_file_exists() {
  local path="${1:-}"
  local msg="${2:-${_T_NAMED_MSG}}"
  if [[ -e "${path}" ]]; then
    _t_pass "${msg}"
  else
    _t_fail "${msg}（文件不存在：${path}）"
  fi
}

# t_file_absent <path> [msg]（T0 追加；E2E 负面断言用：不许碰宿主 herdr 配置）
t_file_absent() {
  local path="${1:-}"
  local msg="${2:-${_T_NAMED_MSG}}"
  if [[ ! -e "${path}" ]]; then
    _t_pass "${msg}"
  else
    _t_fail "${msg}（期望不存在，实际存在：${path}）"
  fi
}

# t_json_valid <file> [msg]   jq empty
t_json_valid() {
  local file="${1:-}"
  local msg="${2:-${_T_NAMED_MSG}}"
  if ! command -v jq >/dev/null 2>&1; then
    _t_fail "${msg}（jq 未安装，无法校验 JSON：${file}）"
    return 0
  fi
  if [[ ! -f "${file}" ]]; then
    _t_fail "${msg}（文件不存在：${file}）"
    return 0
  fi
  run jq empty "${file}"
  if [[ "${rc}" -eq 0 ]]; then
    _t_pass "${msg}"
  else
    _t_fail "${msg}（JSON 非法：${file}；${err}）"
  fi
}

# t_no_zombie_ssh  集成/E2E 收尾断言：无 `ssh ... herdr-forward ...` 残留进程
#
# 契约 B.1 的扫描模式是 `pgrep -f 'ssh.*herdr-forward'`。直接用它有个陷阱：沙箱/runner 的
# 自身命令行可能同时含 "ssh"（如 sshd 路径、--ro-bind .../empty.sshd）与 "herdr-forward"
# （项目路径），造成自匹配假阳性。故先采集当前进程的整条祖先链（bwrap/runner/…）并排除，
# 只关心「我们自己 fork 出来的、真正遗留的」测试进程。
t_no_zombie_ssh() {
  local msg="${1:-无残留 ssh/herdr-forward 进程}"
  if ! command -v pgrep >/dev/null 2>&1; then
    _t_fail "${msg}（pgrep 未安装，无法检测残留）"
    return 0
  fi
  # 祖先链（含自身与父进程，一直上溯到 pid 1；bwrap 在沙箱内就是 pid 1）
  local -a excluded=()
  local cur="$$"
  local ppid=""
  while [[ -n "${cur}" && "${cur}" != "0" ]]; do
    excluded+=("${cur}")
    [[ "${cur}" == "1" ]] && break
    ppid=""
    ppid="$(sed -n 's/^PPid:[[:space:]]*//p' "/proc/${cur}/status" 2>/dev/null | head -1 || true)"
    if [[ -z "${ppid}" || "${ppid}" == "${cur}" ]]; then
      break
    fi
    cur="${ppid}"
  done

  local -a pids=()
  mapfile -t pids < <(pgrep -f 'ssh.*herdr-forward' 2>/dev/null || true)
  local -a residue=()
  local p=""
  local ex=""
  local skip=0
  for p in "${pids[@]}"; do
    [[ -z "${p}" ]] && continue
    skip=0
    for ex in "${excluded[@]}"; do
      if [[ "${p}" == "${ex}" ]]; then
        skip=1
        break
      fi
    done
    [[ "${skip}" -eq 1 ]] && continue
    residue+=("${p}")
  done
  if [[ "${#residue[@]}" -eq 0 ]]; then
    _t_pass "${msg}"
  else
    _t_fail "${msg}（残留 pid: ${residue[*]}）"
  fi
}

# t_done / t_summary  汇总；FAIL>0 exit 1
t_done() {
  local total=$((PASS + FAIL + SKIP))
  printf '1..%d\n' "${total}"
  printf '# PASS: %d FAIL: %d SKIP: %d\n' "${PASS}" "${FAIL}" "${SKIP}"
  if [[ "${FAIL}" -gt 0 ]]; then
    printf '# RESULT: FAIL\n'
    exit 1
  fi
  printf '# RESULT: PASS\n'
  exit 0
}

t_summary() { t_done; }

# ---------------------------------------------------------------------------
# run / t_run：捕获执行
# ---------------------------------------------------------------------------
# run <cmd> [args...]：set +e 包裹，捕获 $out/$err/$rc，恒返回 0。
run() {
  local errfile
  errfile="$(mktemp "${TMPDIR:-/tmp}/assertions-stderr.XXXXXX")"
  set +e
  out="$("$@" 2>"${errfile}")"
  rc=$?
  set -e
  err="$(cat "${errfile}")"
  rm -f "${errfile}"
  # out/err/rc 是公共状态，供调用方消费；恒返回 0 以免打断 set -Eeuo pipefail
  export out err rc
  return 0
}

# t_run <cmd> [args...]：run + 断言 rc==0
t_run() {
  local msg="命令成功：$*"
  run "$@"
  if [[ "${rc}" -eq 0 ]]; then
    _t_pass "${msg}"
  else
    _t_fail "${msg}（rc=${rc}；stderr: ${err}）"
  fi
}

# t_dies_with <expected_code> <cmd> [args...]：run + 断言退出码
# die <code> <msg...> 的实现语义：进程以该码退出，故这里只断言退出码。
t_dies_with() {
  local expected="${1:-}"
  shift || true
  local msg="退出码为 ${expected}：$*"
  run "$@"
  if [[ "${rc}" == "${expected}" ]]; then
    _t_pass "${msg}"
  else
    _t_fail "${msg}（实际 rc=${rc}；stderr: ${err}）"
  fi
}
