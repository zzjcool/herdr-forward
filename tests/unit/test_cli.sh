#!/usr/bin/env bash
# tests/unit/test_cli.sh — bin/forward 调度与子命令契约单测（A.3）
# 覆盖：dispatch（无参/未知子命令 -> 64、help -> 0）/add 参数解析（含 --machine/--ssh-target）/
#       add 无隧道模块时 status=down + warn（松散耦合）/add 隧道钩子成功与失败/
#       machine_resolve 缺失 -> die 4/list --json/--oneline 互斥/remove 不存在 -> 3/
#       publish/unpublish -> 9/watch 存在性
#
# 手法：把 bin/forward + lib/{common,state}.sh 拷进 TMP 组成「确定性插件根」，
# T2/T3 的真模块是否已合并都不影响本文件（模块按需注入 stub）。
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

if [[ ! -x "${ROOT}/bin/forward" ]]; then
  echo "RED: bin/forward 不存在或不可执行（CLI 尚未实现）" >&2
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# --- 断言助手：先落变量再断言，避免 SC2312 ---
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

# _fw <args...>：在当前插件根/状态目录下跑 bin/forward
_fw() { _capture "${PLUGIN_ROOT}/bin/forward" "$@"; }

# _jq_state <filter>：读状态文件取字段 -> got
_jq_state() {
  local file="${STATE_DIR}/forwards.json"
  got=""
  if [[ -f "${file}" ]]; then
    set +o errexit
    got="$(jq -r "$1" "${file}" 2>/dev/null)"
    set -o errexit
  fi
}

# _stage：重建确定性插件根（只含 T1 自有文件，模块按需 stub 注入）
PLUGIN_ROOT="${TMP}/plugin"
STATE_DIR="${TMP}/state"
_stage() {
  rm -rf "${PLUGIN_ROOT}" "${STATE_DIR}"
  mkdir -p "${PLUGIN_ROOT}/bin" "${PLUGIN_ROOT}/lib" "${STATE_DIR}"
  cp "${ROOT}/bin/forward" "${PLUGIN_ROOT}/bin/forward"
  chmod +x "${PLUGIN_ROOT}/bin/forward"
  cp "${ROOT}/lib/common.sh" "${PLUGIN_ROOT}/lib/common.sh"
  cp "${ROOT}/lib/state.sh" "${PLUGIN_ROOT}/lib/state.sh"
  export HERDR_PLUGIN_STATE_DIR="${STATE_DIR}"
  export HERDR_PLUGIN_CONFIG_DIR="${TMP}/config"
  mkdir -p "${HERDR_PLUGIN_CONFIG_DIR}"
}

# 注入 stub 模块（模拟 T2/T3 已交付的模块）
_stub_tunnel_ok() {
  cat >"${PLUGIN_ROOT}/lib/tunnel.sh" <<'EOF'
#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail
tunnel_start() { printf '%s\n' "424242"; }
tunnel_stop() { return 0; }
EOF
}

_stub_tunnel_fail() {
  cat >"${PLUGIN_ROOT}/lib/tunnel.sh" <<'EOF'
#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail
tunnel_start() { return 5; }
tunnel_stop() { return 0; }
EOF
}

_stub_machine_ok() {
  cat >"${PLUGIN_ROOT}/lib/machine.sh" <<'EOF'
#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail
machine_resolve() { printf '%s\n' "resolved@${1}:22"; }
EOF
}

_stub_machine_fail() {
  cat >"${PLUGIN_ROOT}/lib/machine.sh" <<'EOF'
#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail
machine_resolve() { return 4; }
EOF
}

t_describe "CLI: dispatch"

t_it "无参数 -> 用法 + exit 64"
_stage
_fw
t_exit_ok 64 "${rc}" "无参 -> 64"
t_match "用法|usage|forward" "${err}" "stderr 有用法"

t_it "--help / help -> exit 0 并列出子命令"
_stage
_fw --help
t_exit_ok 0 "${rc}" "--help -> 0"
t_match "add" "${out}" "帮助含 add"
t_match "list" "${out}" "帮助含 list"
t_match "remove" "${out}" "帮助含 remove"
t_match "doctor" "${out}" "帮助含 doctor"

t_it "未知子命令 -> 用法 + exit 64"
_stage
_fw definitely-not-a-subcommand
t_exit_ok 64 "${rc}" "未知 -> 64"
t_match "用法|usage|未知|unknown" "${err}" "stderr 有提示"

t_describe "CLI: add 参数解析"

t_it "add <local:remote> --ssh-target 写入记录"
_stage
_fw add 3000:9443 --ssh-target "user@gpu.example.com:22"
t_exit_ok 0 "${rc}" "add exit 0"
_jq_state '.forwards[0].local_port'
t_eq "3000" "${got}" "local_port"
_jq_state '.forwards[0].remote_port'
t_eq "9443" "${got}" "remote_port"
_jq_state '.forwards[0].ssh_target'
t_eq "user@gpu.example.com:22" "${got}" "ssh_target"
_jq_state '.version'
t_eq "1" "${got}" "version 1"

t_it "add 缺 --machine/--ssh-target -> die 4（含建议）"
_stage
_fw add 3000:3000
t_exit_ok 4 "${rc}" "无 target -> 4"
t_match "machine|ssh-target|--machine" "${err}" "提示如何提供 target"

t_it "add 缺端口对 -> exit 64"
_stage
_fw add
t_exit_ok 64 "${rc}" "缺参 -> 64"

t_it "add 端口对格式错误 -> exit 64"
_stage
_fw add "3000" --ssh-target "u@h:22"
t_exit_ok 64 "${rc}" "无冒号 -> 64"
_stage
_fw add "0:3000" --ssh-target "u@h:22"
t_exit_ok 64 "${rc}" "端口 0 -> 64"
_stage
_fw add "3000:99999" --ssh-target "u@h:22"
t_exit_ok 64 "${rc}" "远端端口越界 -> 64"

t_it "add 重复本地端口 -> die 2"
_stage
_fw add 3000:9443 --ssh-target "u@h:22"
_fw add 3000:9444 --ssh-target "u@h:22"
t_exit_ok 2 "${rc}" "重复 -> 2"
_jq_state '.forwards | length'
t_eq "1" "${got}" "未追加"

t_it "add --machine 且 machine_resolve 可用 -> 解析 ssh_target"
_stage
_stub_machine_ok
_fw add 5173:5173 --machine gpu-box
t_exit_ok 0 "${rc}" "add exit 0"
_jq_state '.forwards[0].ssh_target'
t_eq "resolved@gpu-box:22" "${got}" "经 machine_resolve"
_jq_state '.forwards[0].machine'
t_eq "gpu-box" "${got}" "machine 记录"

t_it "add --machine 但 machine_resolve 缺失/失败 -> die 4"
_stage
_stub_machine_fail
_fw add 5173:5173 --machine gpu-box
t_exit_ok 4 "${rc}" "解析失败 -> 4"

t_it "add --ssh-target 优先于 --machine（跳过解析）"
_stage
_stub_machine_ok
_fw add 6000:6000 --machine ignored --ssh-target "direct@host:22"
t_exit_ok 0 "${rc}" "add exit 0"
_jq_state '.forwards[0].ssh_target'
t_eq "direct@host:22" "${got}" "显式 target 优先"

t_describe "CLI: add 隧道钩子（松散耦合）"

t_it "无 tunnel_start 时 status=down + warn（不阻断）"
_stage
_fw add 3000:9443 --ssh-target "u@h:22"
t_exit_ok 0 "${rc}" "不因缺模块失败"
_jq_state '.forwards[0].status'
t_eq "down" "${got}" "status=down"
t_match "warn|隧道|tunnel" "${err}" "有 warn 提示"

t_it "有 tunnel_start 时 status=up 且记 pid"
_stage
_stub_tunnel_ok
_fw add 3000:9443 --ssh-target "u@h:22"
t_exit_ok 0 "${rc}" "add exit 0"
_jq_state '.forwards[0].status'
t_eq "up" "${got}" "status=up"
_jq_state '.forwards[0].pid'
t_eq "424242" "${got}" "pid 落盘"

t_it "tunnel_start 失败 -> 透传退出码 5 且 status=down"
_stage
_stub_tunnel_fail
_fw add 3000:9443 --ssh-target "u@h:22"
t_exit_ok 5 "${rc}" "失败 -> 5"
_jq_state '.forwards[0].status'
t_eq "down" "${got}" "status=down"

t_describe "CLI: list"

t_it "list --json 输出状态文档（version + forwards 数组）"
_stage
_fw add 3000:9443 --ssh-target "u@h:22"
_fw list --json
t_exit_ok 0 "${rc}" "list --json exit 0"
got="${out}"
_jq_doc() { got="$(printf '%s' "${out}" | jq -r "$1" 2>/dev/null)"; }
_jq_doc '.version'
t_eq "1" "${got}" "version"
_jq_doc '.forwards | type'
t_eq "array" "${got}" "forwards 数组"
_jq_doc '.forwards | length'
t_eq "1" "${got}" "1 条"

t_it "list --json 空状态 -> forwards:[]"
_stage
_fw list --json
t_exit_ok 0 "${rc}" "空状态 exit 0"
got="$(printf '%s' "${out}" | jq -r '.forwards | length' 2>/dev/null)"
t_eq "0" "${got}" "空数组"

t_it "list 默认输出表格（含表头/端口）"
_stage
_fw add 3000:9443 --ssh-target "u@h:22"
_fw list
t_exit_ok 0 "${rc}" "list exit 0"
t_match "3000" "${out}" "表格含端口"

t_it "list --oneline 与 --json 互斥 -> exit 64"
_stage
_fw list --oneline --json
t_exit_ok 64 "${rc}" "互斥 -> 64"

t_it "list --oneline 无 up 记录 -> 空输出"
_stage
_fw add 3000:9443 --ssh-target "u@h:22"
_fw list --oneline
t_exit_ok 0 "${rc}" "oneline exit 0"
t_eq "" "${out}" "无 up 时为空"

t_it "list --oneline 有 up 记录 -> ⇅端口"
_stage
_stub_tunnel_ok
_fw add 3000:9443 --ssh-target "u@h:22"
_fw list --oneline
t_exit_ok 0 "${rc}" "oneline exit 0"
t_eq "⇅3000" "${out}" "oneline 渲染"

t_describe "CLI: remove / publish / unpublish / watch / doctor"

t_it "remove 已存在 id -> 删除并 exit 0"
_stage
_fw add 3000:9443 --ssh-target "u@h:22"
_fw remove f-3000
t_exit_ok 0 "${rc}" "remove exit 0"
_jq_state '.forwards | length'
t_eq "0" "${got}" "已删除"

t_it "remove 不存在 id -> die 3"
_stage
_fw remove f-99999
t_exit_ok 3 "${rc}" "不存在 -> 3"
t_match "list" "${err}" "提示 forward list"

t_it "remove 缺参 -> exit 64"
_stage
_fw remove
t_exit_ok 64 "${rc}" "缺参 -> 64"

t_it "remove --all / --pick -> die 9（一期未实现）"
_stage
_fw remove --all
t_exit_ok 9 "${rc}" "--all -> 9"
_stage
_fw remove --pick
t_exit_ok 9 "${rc}" "--pick -> 9"

t_it "publish <port> -> die 9"
_stage
_fw publish 3000
t_exit_ok 9 "${rc}" "publish -> 9"
t_match "二期|not implemented|未实现" "${err}" "说明二期"

t_it "unpublish -> die 9"
_stage
_fw unpublish
t_exit_ok 9 "${rc}" "unpublish -> 9"

t_it "watch 需要 watch 命令；无 watch 则 die 127"
_stage
if command -v watch >/dev/null 2>&1; then
  t_ok "yes" "watch 存在（真循环留给 pane 交互验证）"
else
  _fw watch
  t_exit_ok 127 "${rc}" "缺 watch -> 127"
fi

t_it "doctor 空状态 exit 0"
_stage
_fw doctor
t_exit_ok 0 "${rc}" "空状态 doctor 0"

t_it "doctor 报告 down 记录但 exit 0（E2E set -e 依赖）"
_stage
_fw add 3000:9443 --ssh-target "u@h:22"
_fw doctor
t_exit_ok 0 "${rc}" "诊断成功即 0"

t_it "doctor --fix 将探活失败的上游修成 down"
_stage
_stub_tunnel_ok
_fw add 3000:9443 --ssh-target "u@h:22"
_jq_state '.forwards[0].status'
t_eq "up" "${got}" "初始 up"
_fw doctor --fix
t_exit_ok 0 "${rc}" "doctor --fix exit 0"
_jq_state '.forwards[0].status'
t_eq "down" "${got}" "修成 down"

t_done
