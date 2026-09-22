#!/usr/bin/env bash
# tests/integration/test_cli_full_cycle.sh — bin/forward cmd 层 ↔ lib/tunnel.sh 真接线全链路。
#
# 目的（ARCHITECTURE §D T4 行）：证明「cmd 层真的调隧道层」，而不只是各自单测绿。
# 本文件用真实进程，不用任何 stub：
#   * 用户态 sshd（TMPDIR host key/authorized_keys，随机高端口，仅 127.0.0.1）
#   * 一个真 echo 服务充当「远端机器上的服务」
#   * `bin/forward add` 走 --ssh-target 路径 → 必须真起 ssh -L ControlMaster
#   * `bin/forward list` / `--oneline` 读状态文件
#   * 数据面：连本地端口必须收到 echo 回包（证明 -L 真的通了）
#   * `bin/forward doctor` / `--fix` / `--prune` 必须委托 lib/tunnel.sh 的
#     tunnel_doctor/tunnel_reap（判据：--prune 会清掉 control socket 文件 ——
#     bin/forward 的内置降级实现不碰 socket，只有隧道层会 reap）
#   * `bin/forward remove` 必须真的停隧道：本地端口不再监听 + 无残留 ssh 进程
#
# 认证说明（实测）：T2 冻结的 ssh argv 带 `-F /dev/null`。OpenSSH 的默认身份文件
# 路径取自 **passwd 的 home**（不是 $HOME），所以 -F /dev/null 下 ssh 仍会去翻
# /home/<user>/.ssh/*，而我们把 key 生成在 TMPDIR。因此必须用 ssh-agent 提供身份
# （与 test_sshd_roundtrip.sh 同法）。
#
# 隔离：状态/配置/密钥全在 TMPDIR；绝不碰真实 HOME/config/saved machines。
# CLI 契约：A.3 冻结 `forward add <local>:<remote>`（remote_host 恒 127.0.0.1）。
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [[ -f "${ROOT}/tests/lib/assertions.sh" ]]; then
  # shellcheck source=/dev/null
  source "${ROOT}/tests/lib/assertions.sh"
fi

# --- B.1 契约最小占位（T0 未合并时也能跑；语义与真库一致） ---
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
if ! declare -F t_match >/dev/null 2>&1; then
  t_match() {
    if [[ "${2}" =~ ${1} ]]; then
      T2_PASS=$((T2_PASS + 1))
    else
      T2_FAIL=$((T2_FAIL + 1))
      printf '    FAIL: %s\n      regex:  [%s]\n      actual: [%s]\n' "${3:-t_match}" "${1}" "${2}" >&2
    fi
  }
fi
if ! declare -F t_exit_ok >/dev/null 2>&1; then
  t_exit_ok() {
    if [[ "${1}" == "${2}" ]]; then
      T2_PASS=$((T2_PASS + 1))
    else
      T2_FAIL=$((T2_FAIL + 1))
      printf '    FAIL: %s expected exit [%s] got [%s]\n' "${3:-t_exit_ok}" "${1}" "${2}" >&2
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
    printf '\n[cli-full-cycle] pass=%d fail=%d\n' "${T2_PASS}" "${T2_FAIL}"
    if ((T2_FAIL > 0)); then exit 1; fi
    exit 0
  }
fi

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

FORWARD_BIN="${ROOT}/bin/forward"
if [[ ! -x "${FORWARD_BIN}" ]]; then
  printf 'RED: %s 不存在或不可执行（CLI 尚未实现）\n' "${FORWARD_BIN}" >&2
  exit 1
fi
if [[ ! -f "${ROOT}/lib/tunnel.sh" ]]; then
  printf 'RED: %s 不存在（隧道层尚未实现）\n' "${ROOT}/lib/tunnel.sh" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 隔离环境
# ---------------------------------------------------------------------------
T2_TMP="$(mktemp -d "${TMPDIR:-/tmp}/t2-cli-cycle.XXXXXX")"
export HERDR_PLUGIN_STATE_DIR="${T2_TMP}/herdr-forward"
export HERDR_PLUGIN_CONFIG_DIR="${T2_TMP}/config"
export HOME="${T2_TMP}"
mkdir -p "${HERDR_PLUGIN_CONFIG_DIR}" "${HERDR_PLUGIN_STATE_DIR}" "${HOME}/.ssh"
chmod 700 "${HOME}/.ssh"

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

cleanup() {
  local rc=$?
  set +e
  if [[ -n ${TUNNEL_ID} ]]; then
    "${FORWARD_BIN}" remove "${TUNNEL_ID}" >/dev/null 2>&1
  fi
  # 兜底：按 state dir 特征收掉本测试的隧道进程
  local p="" cmd=""
  for p in $(pgrep -f 'ssh -N -L' 2>/dev/null || true); do
    cmd="$(tr '\0' ' ' <"/proc/${p}/cmdline" 2>/dev/null || true)"
    if [[ "${cmd}" == *"${HERDR_PLUGIN_STATE_DIR}"* ]]; then
      kill -KILL "${p}" 2>/dev/null || true
    fi
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

# t2_roundtrip <local_port> <payload> -> stdout: 服务端回包
t2_roundtrip() {
  local port="${1}" payload="${2}"
  timeout 10 bash -c "exec 3<>/dev/tcp/127.0.0.1/${port}; printf '%s\n' '${payload}' >&3; IFS= read -r -t 5 line <&3; printf '%s' \"\${line}\"" 2>/dev/null || true
}

# t2_state <jq filter> -> stdout
t2_state() {
  jq -r "${1}" "${HERDR_PLUGIN_STATE_DIR}/forwards.json" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# fixture：sshd + echo 服务 + ssh-agent
# ---------------------------------------------------------------------------
SSHD_PORT="$(t2_free_port)"
REMOTE_PORT="$(t2_free_port)"
[[ ${SSHD_PORT} != "0" && ${REMOTE_PORT} != "0" ]] || {
  printf 'could not allocate test ports\n' >&2
  exit 1
}

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

# echo 服务（"远端机器上的服务"）：逐行回显
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
    client, _ = server.accept()
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

t_describe "fixture：用户态 sshd + echo 服务 + ssh-agent"
t_it "sshd 与 echo 服务都监听成功"
/usr/bin/sshd -f "${T2_TMP}/sshd_config" -E "${T2_TMP}/sshd.log"
SSHD_PID="$(cat "${T2_TMP}/sshd.pid")"
t2_wait_port "${SSHD_PORT}"
t_eq "0" "$?" "sshd listening"
python3 "${T2_TMP}/echo.py" "${REMOTE_PORT}" &
ECHO_PID=$!
disown "${ECHO_PID}" 2>/dev/null || true
t2_wait_port "${REMOTE_PORT}"
t_eq "0" "$?" "echo service listening"

t_it "agent 提供的 client key 能直接登录该 sshd（前置条件自检）"
t2_run timeout 15 ssh -F /dev/null -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
  -o UserKnownHostsFile="${T2_TMP}/kh_direct" -p "${SSHD_PORT}" "${SSH_USER}@127.0.0.1" 'echo DIRECT_OK'
t_eq "0" "${T2_RC}" "direct ssh exit"
t_match 'DIRECT_OK' "${T2_OUT}" "direct ssh ran a command"

t_describe "cmd 层 add：真的经 tunnel_start 起隧道"
LOCAL_PORT="$(t2_free_port)"
TUNNEL_ID="f-${LOCAL_PORT}"
t_it "forward add <local>:<remote> --ssh-target user@127.0.0.1:<port> 退出 0"
t2_run "${FORWARD_BIN}" add "${LOCAL_PORT}:${REMOTE_PORT}" --ssh-target "${SSH_USER}@127.0.0.1:${SSHD_PORT}"
t_eq "0" "${T2_RC}" "add exit 0（stderr: ${T2_ERR}）"
t_eq "${TUNNEL_ID}" "${T2_OUT}" "stdout 是记录 id"
t_it "状态文件记录 status=up 且 pid 指向活着的控制主进程"
ST_STATUS="$(t2_state '.forwards[0].status')"
t_eq "up" "${ST_STATUS}" "status up"
t_file_exists "${HERDR_PLUGIN_STATE_DIR}/ssh-ctl/ctl-${TUNNEL_ID}"
MASTER_PID="$(t2_state '.forwards[0].pid')"
t_match '^[0-9]+$' "${MASTER_PID}" "pid 是数字"
t2_run bash -c "kill -0 ${MASTER_PID}"
t_eq "0" "${T2_RC}" "master pid 活着"
t_it "list / list --oneline 反映该映射"
t2_run "${FORWARD_BIN}" list
t_eq "0" "${T2_RC}" "list exit 0"
t_match 'up' "${T2_OUT}" "表格显示 up"
t2_run "${FORWARD_BIN}" list --oneline
t_eq "0" "${T2_RC}" "list --oneline exit 0"
t_match "⇅${LOCAL_PORT}" "${T2_OUT}" "oneline 含 ⇅${LOCAL_PORT}"

t_describe "数据面：本地端口经 ssh -L 收到远端 echo 回包"
t_it "第一次请求回环成功"
RT1="$(t2_roundtrip "${LOCAL_PORT}" "cli-cycle-1")"
t_eq "pong" "${RT1}" "tunneled echo reply"
t_it "第二次请求仍回环（转发稳定）"
RT2="$(t2_roundtrip "${LOCAL_PORT}" "cli-cycle-2")"
t_eq "pong" "${RT2}" "second tunneled reply"

t_describe "doctor 委托隧道层：报告 / --fix 修 stale / 不误删活隧道"
t_it "forward doctor 无异常（exit 0）"
t2_run "${FORWARD_BIN}" doctor
t_eq "0" "${T2_RC}" "doctor exit 0"
t_match "${TUNNEL_ID}" "${T2_OUT}" "报告里提到该 id"
t_it "forward doctor --prune 不误删活隧道"
t2_run "${FORWARD_BIN}" doctor --prune
t_eq "0" "${T2_RC}" "doctor --prune exit 0"
N_AFTER_PRUNE="$(t2_state '.forwards | length')"
t_eq "1" "${N_AFTER_PRUNE}" "活记录保留"
t_it "forward doctor --fix 把 stale=down 修回 up"
t2_run bash -c "jq '.forwards[0].status = \"down\"' '${HERDR_PLUGIN_STATE_DIR}/forwards.json' > tmp && mv tmp '${HERDR_PLUGIN_STATE_DIR}/forwards.json'"
ST_DOWN="$(t2_state '.forwards[0].status')"
t_eq "down" "${ST_DOWN}" "状态被强制为 down"
t2_run "${FORWARD_BIN}" doctor --fix
t_eq "0" "${T2_RC}" "doctor --fix exit 0"
ST_UP="$(t2_state '.forwards[0].status')"
t_eq "up" "${ST_UP}" "状态修复为 up"

t_describe "remove：真的停隧道 + 清状态"
t_it "forward remove <id> 退出 0"
TUNNEL_ID_SAVED="${TUNNEL_ID}"
t2_run "${FORWARD_BIN}" remove "${TUNNEL_ID_SAVED}"
t_eq "0" "${T2_RC}" "remove exit 0（stderr: ${T2_ERR}）"
TUNNEL_ID=""
t_it "状态记录已删空"
N_EMPTY="$(t2_state '.forwards | length')"
t_eq "0" "${N_EMPTY}" "无记录残留"
t_it "本地端口不再监听"
sleep 0.4
t2_run bash -c "exec 3<>/dev/tcp/127.0.0.1/${LOCAL_PORT}"
if [[ "${T2_RC}" -ne 0 ]]; then
  t_pass "port closed"
else
  t_fail "port still listening after remove"
fi
t_it "无残留 ssh 进程 / 无 control socket"
sleep 0.4
RESIDUE=""
for p in $(pgrep -f 'ssh' 2>/dev/null || true); do
  cmd="$(tr '\0' ' ' <"/proc/${p}/cmdline" 2>/dev/null || true)"
  if [[ "${cmd}" == *"${HERDR_PLUGIN_STATE_DIR}"* ]]; then
    RESIDUE="${RESIDUE}${p} "
  fi
done
if [[ -z "${RESIDUE// /}" ]]; then
  t_pass "no lingering ssh for this state dir"
else
  t_fail "lingering ssh pids: ${RESIDUE}"
fi
if [[ -e "${HERDR_PLUGIN_STATE_DIR}/ssh-ctl/ctl-${TUNNEL_ID_SAVED}" ]]; then
  t_fail "control socket still present after remove"
else
  t_pass "control socket removed"
fi

t_describe "doctor --prune 清理死隧道（control socket 由隧道层 reap）"
t_it "重建一条映射后杀掉 sshd + -9 控制主进程（留下 stale socket）"
LOCAL_PORT2="$(t2_free_port)"
ID2="f-${LOCAL_PORT2}"
t2_run "${FORWARD_BIN}" add "${LOCAL_PORT2}:${REMOTE_PORT}" --ssh-target "${SSH_USER}@127.0.0.1:${SSHD_PORT}"
t_eq "0" "${T2_RC}" "add #2 exit 0"
TUNNEL_ID="${ID2}"
MASTER2="$(t2_state '.forwards[0].pid')"
t2_kill_tree "${SSHD_PID}"
SSHD_PID=""
# 关键判据：用 -9 杀 ssh 控制主进程，ssh 自己的 socket 清理代码不会运行，
# control socket 文件必然残留。只有 lib/tunnel.sh 的 tunnel_reap 会删它；
# bin/forward 的内置降级实现只删状态记录、不碰 socket。
kill -KILL "${MASTER2}" 2>/dev/null || true
sleep 1
t_file_exists "${HERDR_PLUGIN_STATE_DIR}/ssh-ctl/ctl-${ID2}" "stale control socket 已就位（前置条件）"
t_it "doctor 报告 down 且 exit 0"
t2_run "${FORWARD_BIN}" doctor
t_eq "0" "${T2_RC}" "doctor exit 0"
t_match "${ID2}" "${T2_OUT}" "报告里提到该 id"
t_it "doctor --prune 清掉死记录，并让隧道层 reap 掉 stale control socket"
t2_run "${FORWARD_BIN}" doctor --prune
t_eq "0" "${T2_RC}" "doctor --prune exit 0"
N_CLEARED="$(t2_state '.forwards | length')"
t_eq "0" "${N_CLEARED}" "死记录被清"
TUNNEL_ID=""
if [[ -e "${HERDR_PLUGIN_STATE_DIR}/ssh-ctl/ctl-${ID2}" ]]; then
  t_fail "control socket survived prune（doctor 未委托 tunnel_reap）"
else
  t_pass "control socket removed by prune（隧道层已接线）"
fi

t_it "收尾无僵尸 ssh"
sleep 0.5
RESIDUE2=""
for p in $(pgrep -f 'ssh' 2>/dev/null || true); do
  cmd="$(tr '\0' ' ' <"/proc/${p}/cmdline" 2>/dev/null || true)"
  if [[ "${cmd}" == *"${HERDR_PLUGIN_STATE_DIR}"* ]]; then
    RESIDUE2="${RESIDUE2}${p} "
  fi
done
if [[ -z "${RESIDUE2// /}" ]]; then
  t_pass "no lingering ssh after prune"
else
  t_fail "lingering ssh pids: ${RESIDUE2}"
fi

t_done
