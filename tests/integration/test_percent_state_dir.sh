#!/usr/bin/env bash
# tests/integration/test_percent_state_dir.sh — 真实环境 bug 的端到端回归锚点。
#
# 背景：herdr 插件的 state 目录名是 URL 编码的 `zzjcool%3Aforward`，而 ssh 会对
# `-o ControlPath=` / `-o UserKnownHostsFile=` 的值做 percent token 展开：
#   %3 不是合法 token -> "vdollar_percent_expand: unknown key %3" -> 隧道起不来。
# 既有 E2E/集成测试沙箱用干净目录名（无 %），所以 537 断言全绿也漏掉了它。
#
# 本文件就是补上那个缺失维度：state dir 指向含 % 的目录（$TMPDIR/plugins/zzjcool%3Aforward），
# 然后用**真 sshd + 真 ssh -L** 跑完整 add → 数据面回环 → remove，断言：
#   * `forward add` 退出 0（不转义时这里必定 die 5）
#   * control socket / known_hosts 落在**未转义**的真实路径上（文件系统不做 percent 展开）
#   * 本地端口经隧道真的收到远端 echo 回包
#   * ssh 进程 argv 里交给 ssh 的 ControlPath 是转义过的（%%3A），证明修法生效
#   * remove 后端口关闭、socket 删除、无残留 ssh/sshd
#
# 隔离：全部落在 TMPDIR，绝不碰真实 ~/.local/state/herdr（state dir 名里的 % 只出现在 TMPDIR 下）。
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [[ -f "${ROOT}/tests/assertions.sh" ]]; then
  # shellcheck source=/dev/null
  source "${ROOT}/tests/assertions.sh"
fi

# --- B.1 契约最小占位（语义与 T0 断言库一致） ---
T2_PASS=0
T2_FAIL=0
if ! declare -F t_describe >/dev/null 2>&1; then
  t_describe() { printf '\n== %s ==\n' "${1}"; }
fi
if ! declare -F t_it >/dev/null 2>&1; then
  t_it() { printf '  - %s\n' "${1}"; }
fi
if ! declare -F t_pass >/dev/null 2>&1; then
  t_pass() { T2_PASS=$((T2_PASS + 1)); }
fi
if ! declare -F t_fail >/dev/null 2>&1; then
  t_fail() {
    T2_FAIL=$((T2_FAIL + 1))
    printf '    FAIL: %s\n' "${1:-}" >&2
  }
fi
if ! declare -F t_ok >/dev/null 2>&1; then
  t_ok() { T2_PASS=$((T2_PASS + 1)); }
fi
if ! declare -F t_eq >/dev/null 2>&1; then
  t_eq() {
    if [[ "${1}" == "${2}" ]]; then
      T2_PASS=$((T2_PASS + 1))
    else
      T2_FAIL=$((T2_FAIL + 1))
      printf '    FAIL: %s\n      expected: [%s]\n      actual:   [%s]\n' "${3:-t_eq}" "${1}" "${2}" >&2
    fi
  }
fi
if ! declare -F t_contains >/dev/null 2>&1; then
  t_contains() {
    if [[ "${2}" == *"${1}"* ]]; then
      T2_PASS=$((T2_PASS + 1))
    else
      T2_FAIL=$((T2_FAIL + 1))
      printf '    FAIL: %s\n      needle:   [%s]\n      haystack: [%s]\n' "${3:-t_contains}" "${1}" "${2}" >&2
    fi
  }
fi
if ! declare -F t_file_exists >/dev/null 2>&1; then
  t_file_exists() {
    if [[ -e "${1}" ]]; then
      T2_PASS=$((T2_PASS + 1))
    else
      T2_FAIL=$((T2_FAIL + 1))
      printf '    FAIL: missing file [%s]\n' "${1}" >&2
    fi
  }
fi
if ! declare -F t_done >/dev/null 2>&1; then
  t_done() {
    printf '\n[percent-state-dir] pass=%d fail=%d\n' "${T2_PASS}" "${T2_FAIL}"
    if ((T2_FAIL > 0)); then exit 1; fi
    exit 0
  }
fi

command -v sshd >/dev/null 2>&1 || {
  printf 'integration requires sshd (OpenSSH server)\n' >&2
  exit 1
}
command -v ssh-keygen >/dev/null 2>&1 || {
  printf 'integration requires ssh-keygen\n' >&2
  exit 1
}
command -v python3 >/dev/null 2>&1 || {
  printf 'integration requires python3 for the echo service\n' >&2
  exit 1
}

# t2_run <cmd...>：捕获 stdout/stderr/rc，不打断 set -e
T2_OUT=""
T2_ERR=""
T2_RC=0
t2_run() {
  local out_file err_file
  out_file="$(mktemp)"
  err_file="$(mktemp)"
  set +e
  ("$@") >"${out_file}" 2>"${err_file}"
  T2_RC=$?
  set -e
  T2_OUT="$(<"${out_file}")"
  T2_ERR="$(<"${err_file}")"
  rm -f "${out_file}" "${err_file}"
}

# ---------------------------------------------------------------------------
# 隔离环境：state / config / HOME / 密钥全在 TMPDIR；state 目录名含 %（核心变量）
# ---------------------------------------------------------------------------
T2_TMP="$(mktemp -d "${TMPDIR:-/tmp}/t2-percent.XXXXXX")"
# 关键：模拟 herdr 的 URL 编码插件目录名 zzjcool%3Aforward
export HERDR_PLUGIN_STATE_DIR="${T2_TMP}/plugins/zzjcool%3Aforward"
export HERDR_PLUGIN_CONFIG_DIR="${T2_TMP}/config"
export HOME="${T2_TMP}/home"
mkdir -p "${HERDR_PLUGIN_CONFIG_DIR}" "${HERDR_PLUGIN_STATE_DIR}" "${HOME}/.ssh"
chmod 700 "${HOME}/.ssh"
PLUGIN_ROOT="${T2_TMP}/plugin"
mkdir -p "${PLUGIN_ROOT}/bin"
cp "${ROOT}/bin/forward" "${PLUGIN_ROOT}/bin/forward"
if [[ -x "${ROOT}/bin/forward-go" ]]; then
  cp "${ROOT}/bin/forward-go" "${PLUGIN_ROOT}/bin/forward-go"
else
  (cd "${ROOT}/go" && GOFLAGS=-mod=vendor go build -o "${PLUGIN_ROOT}/bin/forward-go" ./cmd/forward)
fi
chmod 0755 "${PLUGIN_ROOT}/bin/forward" "${PLUGIN_ROOT}/bin/forward-go"
FORWARD_BIN="${PLUGIN_ROOT}/bin/forward"

SSHD_PID=""
ECHO_PID=""
AGENT_PID=""
TUNNEL_ID=""
LOCAL_PORT=""

# t2_kill_tree <pid>：只杀该 pid 的递归子孙（PID 域，绝不用宽泛 pkill 模式）
t2_kill_tree() {
  local root="${1:-}"
  [[ ${root} =~ ^[0-9]+$ ]] || return 0
  local kids child
  kids="$(pgrep -P "${root}" 2>/dev/null || true)"
  for child in ${kids}; do
    t2_kill_tree "${child}"
  done
  kill -KILL "${root}" 2>/dev/null || true
}

# t2_residue_pids -> stdout: 本测试 state dir 相关的残留 ssh/sshd pid（空格分隔）
t2_residue_pids() {
  local p="" cmd="" out=""
  for p in $(pgrep -f 'ssh' 2>/dev/null || true); do
    cmd="$(tr '\0' ' ' <"/proc/${p}/cmdline" 2>/dev/null || true)"
    if [[ ${cmd} == *"${HERDR_PLUGIN_STATE_DIR}"* ]]; then
      out="${out}${p} "
    fi
  done
  printf '%s\n' "${out}"
}

cleanup() {
  local rc=$?
  set +e
  if [[ -n ${TUNNEL_ID} ]]; then
    "${FORWARD_BIN}" remove "${TUNNEL_ID}" >/dev/null 2>&1
  fi
  # 兜底：按 state dir 特征收掉本测试的隧道进程
  local p
  for p in $(t2_residue_pids); do
    kill -KILL "${p}" 2>/dev/null
  done
  t2_kill_tree "${ECHO_PID}"
  t2_kill_tree "${SSHD_PID}"
  if [[ -n ${AGENT_PID} ]]; then
    kill -TERM "${AGENT_PID}" 2>/dev/null
    t2_kill_tree "${AGENT_PID}"
  fi
  rm -rf "${T2_TMP}"
  return "${rc}"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# t2_free_port -> stdout: 22000-29999 里的空闲端口
t2_free_port() {
  local candidates="" candidate=""
  candidates="$(shuf -i 22000-29999 -n 100)"
  while read -r candidate; do
    if ! (exec 3<>"/dev/tcp/127.0.0.1/${candidate}") 2>/dev/null; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done <<<"${candidates}"
  printf '0\n'
}

t2_wait_port() {
  local port="${1}" tries=0
  while ((tries < 50)); do
    if (exec 3<>"/dev/tcp/127.0.0.1/${port}") 2>/dev/null; then
      return 0
    fi
    tries=$((tries + 1))
    sleep 0.1
  done
  return 1
}

# t2_roundtrip <local_port> <payload> -> stdout: 服务端回包（失败为空）
t2_roundtrip() {
  local port="${1}" payload="${2}"
  timeout 10 bash -c "exec 3<>/dev/tcp/127.0.0.1/${port}; printf '%s\n' '${payload}' >&3; IFS= read -r -t 5 line <&3; printf '%s' \"\${line}\"" 2>/dev/null || true
}

SSHD_PORT="$(t2_free_port)"
REMOTE_PORT="$(t2_free_port)"
[[ ${SSHD_PORT} != "0" && ${REMOTE_PORT} != "0" ]] || {
  printf 'could not allocate test ports\n' >&2
  exit 1
}

# --- fixture：host key / client key / authorized_keys ----------------------
ssh-keygen -q -t ed25519 -N '' -f "${T2_TMP}/hostkey"
ssh-keygen -q -t ed25519 -N '' -f "${T2_TMP}/clientkey"
cp "${T2_TMP}/clientkey.pub" "${T2_TMP}/authorized_keys"
chmod 600 "${T2_TMP}/authorized_keys" "${T2_TMP}/clientkey" "${T2_TMP}/hostkey"

SSH_USER="$(id -un)"

cat >"${T2_TMP}/sshd_config" <<CFG
Port ${SSHD_PORT}
ListenAddress 127.0.0.1
HostKey ${T2_TMP}/hostkey
PidFile ${T2_TMP}/sshd.pid
UsePAM no
PasswordAuthentication no
PubkeyAuthentication yes
PermitRootLogin no
StrictModes no
AuthorizedKeysFile ${T2_TMP}/authorized_keys
LogLevel ERROR
PerSourcePenalties no
CFG
if ! /usr/bin/sshd -t -f "${T2_TMP}/sshd_config" 2>"${T2_TMP}/sshd_t.err"; then
  # 老 sshd 无 PerSourcePenalties：去掉该指令重试
  grep -v '^PerSourcePenalties' "${T2_TMP}/sshd_config" >"${T2_TMP}/sshd_config.2"
  mv "${T2_TMP}/sshd_config.2" "${T2_TMP}/sshd_config"
  /usr/bin/sshd -t -f "${T2_TMP}/sshd_config" 2>>"${T2_TMP}/sshd_t.err" || {
    printf 'sshd -t rejected config:\n' >&2
    cat "${T2_TMP}/sshd_t.err" >&2
    exit 1
  }
fi

# echo 服务（"远端机器上的服务"）：逐行回显 pong
cat >"${T2_TMP}/echo.py" <<'PY'
import socket, sys, threading

server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(("127.0.0.1", int(sys.argv[1])))
server.listen(16)


def handle(conn):
    try:
        stream = conn.makefile("rwb")
        for _line in stream:
            stream.write(b"pong\n")
            stream.flush()
    except Exception:
        pass
    finally:
        conn.close()


while True:
    try:
        client, _ = server.accept()
    except Exception:
        break
    threading.Thread(target=handle, args=(client,), daemon=True).start()
PY

# ssh-agent：-F /dev/null 下身份文件按 passwd home 解析，必须用 agent 提供 key
ssh-agent -a "${T2_TMP}/agent.sock" -s >"${T2_TMP}/agent.env"
export SSH_AGENT_PID=""
# shellcheck source=/dev/null
source "${T2_TMP}/agent.env" >/dev/null
AGENT_PID="${SSH_AGENT_PID:-}"
export SSH_AUTH_SOCK
ssh-add "${T2_TMP}/clientkey" >/dev/null 2>&1

t_describe "fixture：用户态 sshd + echo 服务（state dir 名含 %）"
t_if_pct="absent"
[[ ${HERDR_PLUGIN_STATE_DIR} == *%* ]] && t_if_pct="present"
t_eq "present" "${t_if_pct}" "state dir 名确实含 %"
# root 环境下（容器/CI）PermitRootLogin no 会拒掉同用户测试登录，降级为仅密钥
if id -u | grep -qx 0; then
  sed -i "s/^PermitRootLogin no$/PermitRootLogin prohibit-password/" "${T2_TMP}/sshd_config"
fi
/usr/bin/sshd -f "${T2_TMP}/sshd_config" -E "${T2_TMP}/sshd.log"
SSHD_PID="$(cat "${T2_TMP}/sshd.pid")"
t2_wait_port "${SSHD_PORT}"
t_eq "0" "$?" "sshd listening"
python3 "${T2_TMP}/echo.py" "${REMOTE_PORT}" &
ECHO_PID=$!
disown "${ECHO_PID}" 2>/dev/null || true
t2_wait_port "${REMOTE_PORT}"
t_eq "0" "$?" "echo service listening"

t_it "前置对照：把**未转义**的含 % 路径交给 ssh -o ControlPath 会被 ssh 拒绝"
t2_run bash -c "ssh -F /dev/null -o BatchMode=yes -o 'ControlPath=${HERDR_PLUGIN_STATE_DIR}/ssh-ctl/ctl-probe' -O check dummy@dummy 2>&1 || true"
t_contains "unknown key %3" "${T2_OUT}" "未转义路径触发 percent_expand 报错（bug 可复现）"

t_it "agent 提供的 client key 能直接登录该 sshd（前置条件自检）"
t2_run timeout 15 ssh -F /dev/null -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
  -o UserKnownHostsFile="${T2_TMP}/kh_direct" -p "${SSHD_PORT}" "${SSH_USER}@127.0.0.1" 'echo DIRECT_OK'
t_eq "0" "${T2_RC}" "direct ssh exit"
t_contains "DIRECT_OK" "${T2_OUT}" "direct ssh ran a command"

t_describe "regression：state dir 含 % 时 add 必须成功（修复前此处在 die 5）"
LOCAL_PORT="$(t2_free_port)"
TUNNEL_ID="f-${LOCAL_PORT}"
t2_run "${FORWARD_BIN}" add "${LOCAL_PORT}:${REMOTE_PORT}" --ssh-target "${SSH_USER}@127.0.0.1:${SSHD_PORT}"
t_eq "0" "${T2_RC}" "add exit 0（stderr: ${T2_ERR}）"
if ((T2_RC == 0)); then
  t_pass "隧道启动成功（ssh 未因 %3 拒绝 ControlPath）"
else
  t_fail "隧道启动失败：${T2_ERR}"
fi
t_eq "${TUNNEL_ID}" "${T2_OUT}" "stdout 是记录 id"

t_it "文件系统落点仍用**未转义**的真实路径（socket / known_hosts）"
t_file_exists "${HERDR_PLUGIN_STATE_DIR}/ssh-ctl/ctl-${TUNNEL_ID}"
t_file_exists "${HERDR_PLUGIN_STATE_DIR}/ssh-ctl/known_hosts"
if [[ -e "${T2_TMP}/plugins/zzjcool%%3Aforward" ]]; then
  t_fail "出现了 %% 字面目录：文件系统侧不该被转义"
else
  t_pass "无 %% 字面目录（文件系统侧未转义）"
fi

t_it "交给 ssh 的 argv 里 ControlPath 是转义后的值（%%3A）"
MASTER_PID="$(jq -r '.forwards[0].pid' "${HERDR_PLUGIN_STATE_DIR}/forwards.json" 2>/dev/null || true)"
t2_run bash -c "tr '\0' '\n' < '/proc/${MASTER_PID}/cmdline' 2>/dev/null | grep -F 'ControlPath=' || true"
t_contains "zzjcool%%3Aforward" "${T2_OUT}" "ssh argv 使用 %%3A（转义生效）"
if [[ ${T2_OUT} == *"zzjcool%3Aforward/ssh-ctl"* && ${T2_OUT} != *"zzjcool%%3Aforward/ssh-ctl"* ]]; then
  t_fail "ssh argv 仍是未转义的 %3A：${T2_OUT}"
else
  t_pass "ssh argv 不含未转义的 %3A 路径"
fi

t_describe "数据面：经含 % 的 state dir 起的隧道回环"
t_it "第一次请求回环成功"
RT1="$(t2_roundtrip "${LOCAL_PORT}" "percent-state-1")"
t_eq "pong" "${RT1}" "tunneled echo reply"
t_it "第二次请求仍回环（转发稳定）"
RT2="$(t2_roundtrip "${LOCAL_PORT}" "percent-state-2")"
t_eq "pong" "${RT2}" "second tunneled reply"

t_describe "remove：真的停隧道（含 % 的 ControlPath 也要能 -O exit）"
TUNNEL_ID_SAVED="${TUNNEL_ID}"
t2_run "${FORWARD_BIN}" remove "${TUNNEL_ID_SAVED}"
t_eq "0" "${T2_RC}" "remove exit 0（stderr: ${T2_ERR}）"
TUNNEL_ID=""
t_it "状态记录已删空"
t2_run bash -c "jq -r '.forwards | length' '${HERDR_PLUGIN_STATE_DIR}/forwards.json' 2>/dev/null || true"
t_eq "0" "${T2_OUT}" "无记录残留"
t_it "本地端口不再监听"
sleep 0.4
t2_run bash -c "exec 3<>/dev/tcp/127.0.0.1/${LOCAL_PORT}"
if [[ "${T2_RC}" -ne 0 ]]; then
  t_pass "port closed"
else
  t_fail "port still listening after remove"
fi
t_it "control socket 与 ssh master 都不残留"
if [[ -e "${HERDR_PLUGIN_STATE_DIR}/ssh-ctl/ctl-${TUNNEL_ID_SAVED}" ]]; then
  t_fail "control socket still present after remove"
else
  t_pass "control socket removed"
fi
sleep 0.5
RESIDUE="$(t2_residue_pids)"
if [[ -z ${RESIDUE// /} ]]; then
  t_pass "no lingering ssh for this state dir"
else
  t_fail "lingering ssh pids: ${RESIDUE}"
fi

t_done
