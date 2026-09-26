#!/usr/bin/env bash
# tests/integration/test_bridge_roundtrip.sh — A.3.3 远程开发主路径的数据面证明。
#
# 场景（同一台主机上用两套 state 目录扮演两台机器）：
#   A = client：HERDR_PLUGIN_STATE_DIR=A_STATE，里面有一条指向 B 的激活记录；
#   B = server：HERDR_PLUGIN_STATE_DIR=B_STATE，B 的「服务」是 loopback 上的 echo。
#   A 经用户态 sshd 连到「B」（ssh 目的地是 ssh config 里的 Host 别名，模拟 herdr
#   saved machine 的 target 形态），B 上登记的 client 映射必须出现在 A 的 localhost。
#
# 覆盖：桥接建立 → B 侧 forward add（有 client 在线时默认 client 映射）→ A 的
#   localhost 真收到 B 服务的回包 → 状态回报（B 的 list/oneline、A 的 list）→
#   remove 撤监听 → A 端口被占时如实报 down → 断线（杀 A 的 ssh）后自动重连并恢复
#   映射 → open-url 只在 A 上打开已映射端口 → doctor --prune 不误删 client 映射 →
#   bridge down 后无监听、无残留进程。
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
source "${ROOT}/tests/assertions.sh"

for tool in sshd ssh-keygen python3 jq ssh; do
  if ! command -v "${tool}" >/dev/null 2>&1; then
    printf 'integration requires %s\n' "${tool}" >&2
    exit 1
  fi
done

# 与宿主 herdr 隔离：绝不连真实 server（SCOUT-FACTS §1.1）
unset HERDR_SOCKET_PATH HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_BIN_PATH HERDR_ENV

out=""
rc=0
T="$(mktemp -d "${TMPDIR:-/tmp}/hf-bridge-it.XXXXXX")"
SSH_USER="$(id -un)"
# 与 herdr 真实分配的插件 state 目录同形（含 %3A）：ControlPath 等 ssh -o 值必须转义 %
A_STATE="${T}/A/herdr/plugins/zzjcool%3Aforward"
B_STATE="${T}/B/herdr/plugins/zzjcool%3Aforward"
mkdir -p "${A_STATE}" "${B_STATE}"
PLUGIN_ROOT="${T}/plugin"
mkdir -p "${PLUGIN_ROOT}/bin"
cp "${ROOT}/bin/forward" "${PLUGIN_ROOT}/bin/forward"
if [[ -x "${ROOT}/bin/forward-go" ]]; then
  cp "${ROOT}/bin/forward-go" "${PLUGIN_ROOT}/bin/forward-go"
else
  (cd "${ROOT}/go" && GOFLAGS=-mod=vendor go build -o "${PLUGIN_ROOT}/bin/forward-go" ./cmd/forward)
fi
chmod 0755 "${PLUGIN_ROOT}/bin/forward" "${PLUGIN_ROOT}/bin/forward-go"
FWD="${PLUGIN_ROOT}/bin/forward"

# 测试用更短的间隔（supervisor 在 A 侧，继承本进程环境）
export BRIDGE_BACKOFF_MIN_S=1 BRIDGE_PING_S=1 BRIDGE_SERVER_ALIVE_S=5

SSHD_PID=""
SVC_PID=""
BLOCK_PID=""

kill_tree() {
  local root="${1:-}"
  [[ ${root} =~ ^[0-9]+$ ]] || return 0
  local kids="" child=""
  kids="$(pgrep -P "${root}" 2>/dev/null || true)"
  for child in ${kids}; do
    kill_tree "${child}"
  done
  kill -KILL "${root}" 2>/dev/null || true
}

cleanup() {
  local rc=$?
  set +e
  HERDR_PLUGIN_STATE_DIR="${A_STATE}" "${FWD}" bridge down all >/dev/null 2>&1
  kill_tree "${SVC_PID}"
  kill_tree "${BLOCK_PID}"
  kill_tree "${SSHD_PID}"
  if ((rc != 0)) || [[ ${FAIL:-0} != 0 ]]; then
    printf '\n# --- diagnostics ---\n'
    for f in "${A_STATE}"/bridge/*.log "${A_STATE}"/bridge/*.out "${A_STATE}"/logs/forward.log "${B_STATE}"/logs/forward.log "${T}"/sshd.log; do
      [[ -f ${f} ]] || continue
      printf '# == %s\n' "${f}"
      sed 's/^/#   /' "${f}" | tail -n 25
    done
  fi
  rm -rf "${T}"
  return "${rc}"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

free_port() {
  python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'
}

# roundtrip <port> -> stdout: 回包首行（失败为空）
roundtrip() {
  local port="${1}"
  timeout 5 bash -c "exec 3<>/dev/tcp/127.0.0.1/${port}; printf 'ping\n' >&3; IFS= read -r -t 3 line <&3; printf '%s' \"\${line}\"" 2>/dev/null || true
}

port_open() {
  if (exec 3<>"/dev/tcp/127.0.0.1/${1}") 2>/dev/null; then
    printf 'yes\n'
  else
    printf 'no\n'
  fi
}

# wait_for <seconds> <cmd...>：cmd 的 stdout 为 yes 即返回 0
wait_for() {
  local secs="${1}"
  shift
  local tries=$((secs * 5))
  local got=""
  while ((tries > 0)); do
    got="$("$@" 2>/dev/null || true)"
    if [[ ${got} == "yes" ]]; then
      return 0
    fi
    sleep 0.2
    tries=$((tries - 1))
  done
  return 1
}

a_fwd() { HERDR_PLUGIN_STATE_DIR="${A_STATE}" "${FWD}" "$@"; }
b_fwd() { HERDR_PLUGIN_STATE_DIR="${B_STATE}" "${FWD}" "$@"; }

a_bridge_state() {
  jq -r '.state // ""' "${A_STATE}/bridge/client-mB.json" 2>/dev/null || true
}
is_connected() {
  local st=""
  st="$(a_bridge_state)"
  [[ ${st} == "connected" ]] && printf 'yes\n'
  return 0
}
roundtrip_ok() {
  local got=""
  got="$(roundtrip "${1}")"
  [[ ${got} == "pong" ]] && printf 'yes\n'
  return 0
}
port_closed() {
  local got=""
  got="$(port_open "${1}")"
  [[ ${got} == "no" ]] && printf 'yes\n'
  return 0
}
b_status_is() {
  local want="${2}" got=""
  got="$(b_fwd list --json | jq -r --arg id "${1}" '.forwards[] | select(.id == $id) | .status')"
  [[ ${got} == "${want}" ]] && printf 'yes\n'
  return 0
}

SSHD_PORT="$(free_port)"
SVC_PORT="$(free_port)"
A_PORT="$(free_port)"
A_PORT2="$(free_port)"
A_PORT3="$(free_port)"

# --- fixture: 用户态 sshd -----------------------------------------------------
ssh-keygen -q -t ed25519 -N '' -f "${T}/hostkey"
ssh-keygen -q -t ed25519 -N '' -f "${T}/clientkey"
cp "${T}/clientkey.pub" "${T}/authorized_keys"
chmod 600 "${T}/authorized_keys" "${T}/clientkey" "${T}/hostkey"
cat >"${T}/sshd_config" <<CFG
Port ${SSHD_PORT}
ListenAddress 127.0.0.1
HostKey ${T}/hostkey
PidFile ${T}/sshd.pid
UsePAM no
PasswordAuthentication no
PubkeyAuthentication yes
PermitRootLogin no
StrictModes no
AuthorizedKeysFile ${T}/authorized_keys
AllowTcpForwarding yes
LogLevel ERROR
PerSourcePenalties no
CFG
if ! /usr/bin/sshd -t -f "${T}/sshd_config" 2>/dev/null; then
  grep -v '^PerSourcePenalties' "${T}/sshd_config" >"${T}/sshd_config.2"
  mv "${T}/sshd_config.2" "${T}/sshd_config"
fi
# root 环境下（容器/CI）PermitRootLogin no 会拒掉同用户测试登录，降级为仅密钥
if id -u | grep -qx 0; then
  sed -i "s/^PermitRootLogin no$/PermitRootLogin prohibit-password/" "${T}/sshd_config"
fi
/usr/bin/sshd -f "${T}/sshd_config" -E "${T}/sshd.log"
sleep 0.3
SSHD_PID="$(cat "${T}/sshd.pid")"

# B 的 ssh 目的地是 Host 别名（herdr saved machine 的常见形态），靠 -F 配置解析
cat >"${T}/ssh_config" <<CFG
Host b-box
  HostName 127.0.0.1
  Port ${SSHD_PORT}
  User ${SSH_USER}
  IdentityFile ${T}/clientkey
  IdentitiesOnly yes
  UserKnownHostsFile ${T}/known_hosts
  StrictHostKeyChecking accept-new
  LogLevel ERROR
CFG
export HERDR_FORWARD_SSH_CONFIG="${T}/ssh_config"

# B 的服务：每行回 pong
python3 -c '
import socket, sys, threading
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(16)
def h(c):
    try:
        f = c.makefile("rwb")
        for _ in f:
            f.write(b"pong\n"); f.flush()
    except Exception:
        pass
    finally:
        c.close()
while True:
    c, _ = s.accept()
    threading.Thread(target=h, args=(c,), daemon=True).start()
' "${SVC_PORT}" &
SVC_PID=$!
disown "${SVC_PID}" 2>/dev/null || true

# A 的激活记录：B 已探测到插件（插件根 = 本检出，state = B_STATE）
jq -n --arg root "${PLUGIN_ROOT}" --arg sd "${B_STATE}" '
  {version: 1, active: "mB",
   machines: {mB: {label: "b-box", ssh_target: "b-box", server_root: $root,
                   state_dir: $sd, local: false, activated_unix: 1790000000}}}
' >"${A_STATE}/activated-machines.json"

OPENED="${T}/opened.txt"
cat >"${T}/opener.sh" <<SH
#!/bin/sh
printf '%s\n' "\$1" >>"${OPENED}"
SH
chmod +x "${T}/opener.sh"

# --- 1. 桥接建立 --------------------------------------------------------------
t_describe "bridge：A 连上 B"
t_it "bridge up 在后台起 supervisor 并连上 B"
HERDR_FORWARD_OPENER="${T}/opener.sh" run a_fwd bridge up mB
t_exit_ok 0 "${rc}" "bridge up 退出 0"
t_match '已启动' "${out}" "报告已启动"
wait_for 15 is_connected
t_exit_ok 0 "$?" "A 侧状态变为 connected"

t_it "重复 bridge up 幂等（不起第二个 supervisor）"
run a_fwd bridge up mB
t_exit_ok 0 "${rc}" "第二次 bridge up 退出 0"
t_match '已在运行' "${out}" "报告已在运行"

t_it "B 侧看到一个在线 client"
run b_fwd bridge status --json
live_n="$(printf '%s' "${out}" | jq '[.sessions[] | select(.live)] | length')"
t_eq "1" "${live_n}" "B 有 1 个在线会话"

# --- 2. B 登记映射 → A 的 localhost 可用 --------------------------------------
t_describe "B 登记 client 映射 → 出现在 A 的 localhost"
t_it "有 client 在线时 forward add 默认登记为 client 映射"
run b_fwd add "${A_PORT}:${SVC_PORT}"
t_exit_ok 0 "${rc}" "add 退出 0"
t_eq "f-${A_PORT}" "${out}" "stdout 是 id"
mode="$(jq -r --arg id "f-${A_PORT}" '.forwards[] | select(.id == $id) | .mode' "${B_STATE}/forwards.json")"
t_eq "client" "${mode}" "记录为 mode=client"

t_it "A 的 localhost:<port> 收到 B 服务的回包"
wait_for 10 roundtrip_ok "${A_PORT}"
t_exit_ok 0 "$?" "经桥接往返成功（pong）"

t_it "B 的 list 显示实时状态 up，tab bar 行含该端口"
wait_for 10 b_status_is "f-${A_PORT}" up
t_exit_ok 0 "$?" "B list --json status=up"
run b_fwd list --oneline
t_contains "⇅${A_PORT}" "${out}" "B 的 oneline 含端口"

t_it "A 的 list 显示经桥接生效的映射"
run a_fwd list --json
a_row="$(printf '%s' "${out}" | jq -c --argjson p "${A_PORT}" '.forwards[] | select(.local_port == $p)')"
a_mode="$(printf '%s' "${a_row}" | jq -r '.mode')"
a_status="$(printf '%s' "${a_row}" | jq -r '.status')"
t_eq "bridge" "${a_mode}" "A 侧 mode=bridge"
t_eq "up" "${a_status}" "A 侧 status=up"

t_it "监听只在 A 的 loopback（不暴露到局域网）"
listen="$(ss -Htln "sport = :${A_PORT}" 2>/dev/null | awk '{print $4}' | sort -u | paste -sd ' ' -)"
t_match '^(127\.0\.0\.1|\[::1\]):[0-9]+( (127\.0\.0\.1|\[::1\]):[0-9]+)?$' "${listen}" "仅 loopback 监听（${listen}）"

# --- 3. remove 撤监听 ---------------------------------------------------------
t_describe "B remove → A 撤监听"
run b_fwd remove "f-${A_PORT}"
t_exit_ok 0 "${rc}" "remove 退出 0"
wait_for 10 port_closed "${A_PORT}"
t_exit_ok 0 "$?" "A 的端口已关闭"

# --- 4. A 端口被占 → 如实报 down ----------------------------------------------
t_describe "A 端口被占用时如实报告"
python3 -c 'import socket,sys,time;s=socket.socket();s.bind(("127.0.0.1",int(sys.argv[1])));s.listen(1);time.sleep(600)' "${A_PORT2}" &
BLOCK_PID=$!
disown "${BLOCK_PID}" 2>/dev/null || true
wait_for 5 port_open "${A_PORT2}"
t_exit_ok 0 "$?" "占位监听已就绪"
run b_fwd add "${A_PORT2}:${SVC_PORT}" --client
t_exit_ok 0 "${rc}" "add --client 退出 0"
wait_for 10 b_status_is "f-${A_PORT2}" down
t_exit_ok 0 "$?" "B 看到 status=down"
reason="$(b_fwd list --json | jq -r --arg id "f-${A_PORT2}" '.forwards[] | select(.id == $id) | .status_reason')"
t_contains "占用" "${reason}" "down 原因写明端口被占（${reason}）"
kill_tree "${BLOCK_PID}"
BLOCK_PID=""
t_it "占用解除后自动重试成功"
wait_for 15 b_status_is "f-${A_PORT2}" up
t_exit_ok 0 "$?" "重试后 status=up"
b_fwd remove "f-${A_PORT2}" >/dev/null

# --- 5. 断线重连 --------------------------------------------------------------
t_describe "断线后自动重连并恢复映射"
b_fwd add "${A_PORT3}:${SVC_PORT}" >/dev/null 2>&1
wait_for 10 roundtrip_ok "${A_PORT3}"
t_exit_ok 0 "$?" "重连前映射可用"
sup_pid="$(jq -r '.pid' "${A_STATE}/bridge/client-mB.json")"
ssh_pid="$(pgrep -P "${sup_pid}" -x ssh | head -1 || true)"
t_match '^[0-9]+$' "${ssh_pid}" "找到 supervisor 的 ssh 子进程"
kill -KILL "${ssh_pid}" 2>/dev/null || true
wait_for 10 port_closed "${A_PORT3}"
t_exit_ok 0 "$?" "ssh 被杀后端口随之释放"
wait_for 20 roundtrip_ok "${A_PORT3}"
t_exit_ok 0 "$?" "supervisor 重连后映射自动恢复"
new_sup="$(jq -r '.pid' "${A_STATE}/bridge/client-mB.json")"
t_eq "${sup_pid}" "${new_sup}" "仍是同一个 supervisor（进程内重连）"

# --- 6. open-url --------------------------------------------------------------
t_describe "open-url：Ctrl+click 在 A 上打开（URL 改写为 A 侧端口）"
run b_fwd open-url "http://localhost:${SVC_PORT}/app?x=1"
t_exit_ok 0 "${rc}" "open-url 退出 0"
opened_ok() {
  [[ -f ${OPENED} ]] && grep -qF "http://localhost:${A_PORT3}/app?x=1" "${OPENED}" && printf 'yes\n'
  return 0
}
wait_for 10 opened_ok
t_exit_ok 0 "$?" "A 的 opener 收到改写后的 URL"

# --- 7. doctor 不误删 ---------------------------------------------------------
t_describe "doctor --prune 不删 client 映射"
run b_fwd doctor --prune
t_exit_ok 0 "${rc}" "doctor 退出 0"
still="$(jq -r --arg id "f-${A_PORT3}" '[.forwards[] | select(.id == $id)] | length' "${B_STATE}/forwards.json")"
t_eq "1" "${still}" "client 映射仍在"
t_contains "client:up" "${out}" "doctor 报告 client 映射实时状态"

# --- 8. bridge down -----------------------------------------------------------
t_describe "bridge down 收干净"
run a_fwd bridge down mB
t_exit_ok 0 "${rc}" "bridge down 退出 0"
wait_for 10 port_closed "${A_PORT3}"
t_exit_ok 0 "$?" "A 的映射端口已释放"
if kill -0 "${sup_pid}" 2>/dev/null; then
  t_fail "supervisor 仍在运行（pid=${sup_pid}）"
else
  t_pass "supervisor 已退出"
fi
sleep 0.5
resid="$(pgrep -af 'ssh' 2>/dev/null | grep -F "${T}" | grep -v -F 'sshd' || true)"
t_eq "" "${resid}" "无残留 ssh 进程"
waiting="$(b_fwd list --json | jq -r --arg id "f-${A_PORT3}" '.forwards[] | select(.id == $id) | .status')"
wait_for 25 b_status_is "f-${A_PORT3}" waiting
t_exit_ok 0 "$?" "B 侧映射回到 waiting（client 已断开；此前为 ${waiting}）"

t_done
