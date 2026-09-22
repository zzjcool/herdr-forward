#!/usr/bin/env bash
# scripts/e2e/run-inside.sh — 容器内 E2E 主体（ARCHITECTURE §C.3）
#
# 入口：Dockerfile 的 ENTRYPOINT（也可 `docker run <img> bash /usr/local/bin/run-inside.sh`）。
# 退出码即 E2E 结果，ci.sh 直接消费。
#
# T0 阶段范围（ARCHITECTURE §D T0 行）：E2E 沙箱「空转探通」——
#   A) 用户态 sshd（127.0.0.1:22022）+ echo 服务（127.0.0.1:23000）回环断言
#   B) 容器内完整基线（shellcheck + shfmt + unit + integration）
#   C) herdr 二进制挂载模式探测（§C.4 模式 A/B，假设#6），结果写 /work/test-results/e2e-mode.txt
#   D) 清理后台进程 + 无残留断言
#
# 注：这里不调用 scripts/ci.sh —— 那会经 ci.sh 第 5 段再调 run-docker.sh 造成容器内递归
# （容器内无 docker）。B 段直接调 lint/测试命令，达到「容器内有完整基线」的同一目的。
#
# lint 风格约定（shellcheck -S style -o all 零告警）：
#   * 探测型函数不返回值，改写全局变量（避免函数出现在 if/&&/|| 条件里触发 SC2310）
#   * 禁止 `A && B || C`（SC2015），一律 if/else
#   * fifo 回显用 fd 而非同一文件同时重定向（SC2094）
set -Eeuo pipefail

# --- 红线（§C.2 + SCOUT-FACTS §1.1）：绝不继承宿主的 herdr 连接 env，否则 CLI 会连到
# 真实运行中的 server。容器默认无这些变量，但 bwrap 降级在宿主跑，必须显式 unset。
unset HERDR_SOCKET_PATH HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID || true

SRC_DIR="/plugin-src"
WORK_DIR="/work"
RESULTS_DIR="${WORK_DIR}/test-results"

log() { printf '[e2e] %s\n' "$*"; }

# ---------------------------------------------------------------------------
# 0) 准备：源码拷到可写区（/plugin-src 只读）+ 隔离 HOME
# ---------------------------------------------------------------------------
log "准备可写工作区与隔离 HOME"
mkdir -p "${WORK_DIR}"
# /work/test-results 是宿主 bind mount（结果出口），绝不把它当普通目录覆盖；
# .git / .pi-subagents / node_modules 与测试无关且可能巨大（worktree 嵌套），跳过。
# dotglob 让 .gitignore 之类的点文件也能拷进去。
shopt -s dotglob nullglob
for entry in "${SRC_DIR}"/*; do
  base="${entry##*/}"
  case "${base}" in
  test-results | .git | .pi-subagents | node_modules)
    continue
    ;;
  *) ;;
  esac
  cp -a "${entry}" "${WORK_DIR}/"
done
shopt -u dotglob nullglob
mkdir -p "${RESULTS_DIR}"

export HOME="${HOME:-/home/fwduser}"
export HERDR_PLUGIN_STATE_DIR="${HOME}/.local/state/herdr-forward"
export HERDR_PLUGIN_CONFIG_DIR="${HOME}/.config/herdr-forward"
# 显式建目录：herdr 不自动建 HOME/XDG（SCOUT-FACTS §1.1）；ssh-keygen 在部分环境下
# 也不会自建 ~/.ssh 父目录（bwrap 实测），一律显式创建。
mkdir -p "${HOME}/.ssh" "${HERDR_PLUGIN_STATE_DIR}" "${HERDR_PLUGIN_CONFIG_DIR}"
chmod 700 "${HOME}/.ssh"

# 负面断言基线：E2E 不得触碰隔离 HOME 下的真 herdr 配置目录
REAL_HERDR_CONFIG_SNAPSHOT=""
if [[ -d "${HOME}/.config/herdr" ]]; then
  REAL_HERDR_CONFIG_SNAPSHOT="$(find "${HOME}/.config/herdr" -type f 2>/dev/null | sort || true)"
fi

# 断言库（T0 交付物 1）
# shellcheck source=tests/lib/assertions.sh
source "${WORK_DIR}/tests/lib/assertions.sh"

# lint_targets：stdout 每行一个 shell 目标（供 shellcheck/shfmt 用）。
# 覆盖真实代码而不只是测试：bin/forward、lib/*.sh、tests/lib、tests/unit、
# tests/integration、scripts（含 e2e）。只输出存在的文件（T0 早期阶段可能缺）。
lint_targets() {
  local f=""
  [[ -f "bin/forward" ]] && printf '%s\n' "bin/forward"
  for f in lib/*.sh; do
    [[ -f "${f}" ]] && printf '%s\n' "${f}"
  done
  for f in tests/lib/*.sh tests/unit/*.sh tests/integration/*.sh tests/run.sh scripts/*.sh scripts/e2e/*.sh; do
    [[ -f "${f}" ]] && printf '%s\n' "${f}"
  done
  return 0
}

# ---------------------------------------------------------------------------
# 全局探测状态（探测函数写入，调用方读取；避免 SC2310）
# ---------------------------------------------------------------------------
SSHD_PORT=22022
ECHO_PORT=23000
SSHD_PID=""
ECHO_PID=""
PORT_UP=0    # wait_port 结果：1=端口可连
TCP_OK=0     # tcp_connected 结果
BANNER=""    # read_banner 结果
ROUNDTRIP="" # echo_roundtrip 结果
CLEANED=0    # 幂等清理标记（D 段显式调一次 + trap 兼底）

cleanup() {
  if [[ "${CLEANED}" -eq 1 ]]; then
    return 0
  fi
  CLEANED=1
  log "清理后台进程"
  if [[ -n "${ECHO_PID}" ]]; then
    kill "${ECHO_PID}" 2>/dev/null || true
  fi
  if [[ -n "${SSHD_PID}" ]]; then
    kill "${SSHD_PID}" 2>/dev/null || true
  fi
  # 兜底：按命令行特征收尾（避免 setsid 后 pid 树变化留下孤儿）
  pkill -f 'sshd -D -e -f .*sshd_config' 2>/dev/null || true
  pkill -f "socat TCP-LISTEN:${ECHO_PORT}" 2>/dev/null || true
  pkill -f 'nc -l -s 127.0.0.1 -p 23000' 2>/dev/null || true
  wait 2>/dev/null || true
  return 0
}
trap 'cleanup' EXIT

# tcp_connected <port>：一次 TCP 三握手，结果写 TCP_OK
tcp_connected() {
  local port="$1"
  TCP_OK=0
  if (exec 3<>"/dev/tcp/127.0.0.1/${port}") 2>/dev/null; then
    TCP_OK=1
  fi
}

# wait_port <port> [tries]：轮询等待端口可连，结果写 PORT_UP
wait_port() {
  local port="$1" tries="${2:-20}" i=0
  PORT_UP=0
  for ((i = 0; i < tries; i++)); do
    tcp_connected "${port}"
    if [[ "${TCP_OK}" -eq 1 ]]; then
      PORT_UP=1
      return 0
    fi
    sleep 0.3
  done
  return 0
}

# read_banner <port> [timeout]：读 SSH banner 首行，结果写 BANNER
read_banner() {
  local port="$1" timeout="${2:-5}" line=""
  BANNER=""
  exec 3<>"/dev/tcp/127.0.0.1/${port}" 2>/dev/null || return 0
  IFS= read -r -t "${timeout}" line <&3 || true
  exec 3<&- 3>&-
  BANNER="${line}"
  return 0
}

# echo_roundtrip <port> <payload>：发送一行并读回一行，结果写 ROUNDTRIP
# nc 单连接串行，遇到偶发 connect 竞态就重试。
echo_roundtrip() {
  local port="$1" payload="$2" i=0 line=""
  ROUNDTRIP=""
  for ((i = 0; i < 10; i++)); do
    line=""
    exec 3<>"/dev/tcp/127.0.0.1/${port}" 2>/dev/null || {
      sleep 0.3
      continue
    }
    printf '%s\n' "${payload}" >&3
    IFS= read -r -t 3 line <&3 || true
    exec 3<&- 3>&-
    if [[ -n "${line}" ]]; then
      ROUNDTRIP="${line}"
      return 0
    fi
    sleep 0.3
  done
  return 0
}

# ---------------------------------------------------------------------------
# A) 用户态 sshd + echo 服务回环（假设#7）
# ---------------------------------------------------------------------------
t_describe "A) 用户态 sshd + echo 回环（契约 §C.1 / 假设#7）"

t_it "生成容器内专用 host key / client key / authorized_keys"
run ssh-keygen -q -t ed25519 -N '' -f "${HOME}/.ssh/hostkey" </dev/null
t_exit_ok 0 "${rc}" "host key 生成"
run ssh-keygen -q -t ed25519 -N '' -f "${HOME}/.ssh/id_ed25519" </dev/null
t_exit_ok 0 "${rc}" "client key 生成"
run cp "${HOME}/.ssh/id_ed25519.pub" "${HOME}/.ssh/authorized_keys"
t_exit_ok 0 "${rc}" "authorized_keys 就位"
run chmod 700 "${HOME}/.ssh"
run chmod 600 "${HOME}/.ssh/authorized_keys" "${HOME}/.ssh/hostkey"
t_file_exists "${HOME}/.ssh/hostkey" "host key 文件存在"
t_file_exists "${HOME}/.ssh/authorized_keys" "authorized_keys 文件存在"

t_it "sshd_config 通过 sshd -t 语法校验（用户态、仅 127.0.0.1）"
cat >"${HOME}/sshd_config" <<EOF
Port ${SSHD_PORT}
ListenAddress 127.0.0.1
HostKey ${HOME}/.ssh/hostkey
PidFile ${HOME}/sshd.pid
UsePAM no
PasswordAuthentication no
PubkeyAuthentication yes
PermitRootLogin no
StrictModes no
AuthorizedKeysFile ${HOME}/.ssh/authorized_keys
LogLevel VERBOSE
EOF
# 绝对路径调用 sshd（SCOUT-FACTS §1.3）
run /usr/bin/sshd -t -f "${HOME}/sshd_config"
t_exit_ok 0 "${rc}" "sshd -t 校验通过（stderr: ${err}）"

t_it "以普通用户启动 sshd 并监听 127.0.0.1:${SSHD_PORT}"
setsid /usr/bin/sshd -D -e -f "${HOME}/sshd_config" >"${HOME}/sshd.log" 2>&1 &
SSHD_PID=$!
wait_port "${SSHD_PORT}" 20
if [[ "${PORT_UP}" -eq 1 ]]; then
  t_pass "sshd 端口 ${SSHD_PORT} 可 TCP 握手"
else
  sshd_log="$(tail -5 "${HOME}/sshd.log" 2>/dev/null || true)"
  t_fail "sshd 端口 ${SSHD_PORT} 未就绪；日志：${sshd_log}"
fi

t_it "nc 能完成 127.0.0.1:${SSHD_PORT} TCP 握手（验收口径）"
if command -v nc >/dev/null 2>&1; then
  run nc -z -w 5 127.0.0.1 "${SSHD_PORT}"
  t_exit_ok 0 "${rc}" "nc -z 127.0.0.1:${SSHD_PORT} 握手成功（stderr: ${err}）"
else
  t_skip "环境无 nc（宿主缺 nc；容器内已安装）；TCP 握手已由 /dev/tcp 断言覆盖"
fi

t_it "端口 ${SSHD_PORT} 返回 SSH 协议 banner"
read_banner "${SSHD_PORT}" 5
t_match '^SSH-2\.0-' "${BANNER}" "banner 形如 SSH-2.0-*（实际：${BANNER}）"

t_it "端口 ${SSHD_PORT} 也可经 nc 读到 banner（nc 读流能力）"
if command -v nc >/dev/null 2>&1; then
  run bash -c "timeout 5 nc -q 1 127.0.0.1 ${SSHD_PORT} </dev/null"
  t_exit_ok 0 "${rc}" "nc 连接 ${SSHD_PORT} 并正常退出"
  t_match '^SSH-2\.0-' "${out}" "nc 读到 SSH banner"
else
  t_skip "环境无 nc；banner 已由 /dev/tcp 断言覆盖"
fi

t_it "公钥登录可用（ssh 客户端，-F /dev/null 规避宿主 ssh_config）"
ssh_user="$(id -un)"
run /usr/bin/ssh -F /dev/null -p "${SSHD_PORT}" -i "${HOME}/.ssh/id_ed25519" \
  -o StrictHostKeyChecking=no -o UserKnownHostsFile="${HOME}/known_hosts" \
  -o BatchMode=yes -o ConnectTimeout=5 "${ssh_user}@127.0.0.1" 'echo REMOTE_OK'
t_exit_ok 0 "${rc}" "ssh 公钥登录成功（stderr: ${err}）"
t_contains "REMOTE_OK" "${out}" "远程命令输出回传"

t_it "echo 服务监听 127.0.0.1:${ECHO_PORT} 并回显"
# 任务书要求「起一个 echo 服务（后台进程，如 while read; do echo）监听 23000」。
# openbsd nc 没有 -e/-c（不能自己回显），故用 socat fork-per-conn 拉起同一份
# while-read 回显脚本 —— 语义等价，且并发/重连可靠（nc+fifo 回环实测不稳）。
ECHO_SERVER="${HOME}/echo-server.sh"
cat >"${ECHO_SERVER}" <<'ECHOSRV'
#!/usr/bin/env bash
# 行回显：读一行、回一行（E2E 数据面探通用的「远端服务」替身）
while IFS= read -r line; do
  printf '%s\n' "${line}"
done
ECHOSRV
chmod +x "${ECHO_SERVER}"
socat TCP-LISTEN:"${ECHO_PORT}",reuseaddr,fork,bind=127.0.0.1 EXEC:"${ECHO_SERVER}" >"${HOME}/echo.log" 2>&1 &
ECHO_PID=$!
wait_port "${ECHO_PORT}" 20
if [[ "${PORT_UP}" -eq 1 ]]; then
  t_pass "echo 服务端口 ${ECHO_PORT} 可 TCP 握手"
else
  t_fail "echo 服务端口 ${ECHO_PORT} 未就绪"
fi

echo_roundtrip "${ECHO_PORT}" "ping-t0-1"
t_eq "ping-t0-1" "${ROUNDTRIP}" "回显往返 #1（bash /dev/tcp 客户端）"
echo_roundtrip "${ECHO_PORT}" "ping-t0-2"
t_eq "ping-t0-2" "${ROUNDTRIP}" "回显往返 #2（服务持续可用）"
echo_roundtrip "${ECHO_PORT}" "ping-t0-3"
t_eq "ping-t0-3" "${ROUNDTRIP}" "回显往返 #3"

t_it "nc 客户端发一行能收到回显（验收口径）"
if command -v nc >/dev/null 2>&1; then
  run bash -c "printf 'nc-echo-check\\n' | timeout 5 nc -q 1 127.0.0.1 ${ECHO_PORT}"
  t_exit_ok 0 "${rc}" "nc 回显命令成功"
  t_contains "nc-echo-check" "${out}" "nc 收到回显内容"
  run nc -z -w 5 127.0.0.1 "${ECHO_PORT}"
  t_exit_ok 0 "${rc}" "nc -z 127.0.0.1:${ECHO_PORT} 握手成功"
else
  t_skip "环境无 nc；回显已由 /dev/tcp 断言覆盖"
fi

# ---------------------------------------------------------------------------
# A2) machines.toml + 完整 cmd 全链路（契约 §C.3 步骤 3 与 5）
#     §C.3 步骤 5 的原始断言块写的是 `bin/forward add 13000:9443 --machine sandbox`，
#     但实际 `--machine` 解析出的 target 是 FQDN、并不能登进本沙箱用户态 sshd；
#     且 T2 冻结的 ssh argv 带 `-F /dev/null`，而 OpenSSH 默认身份文件按 **passwd
#     home** 解析（不是 $HOME），所以容器内的 key 必须由 ssh-agent 提供。
#     这里用等价的真实全链路：machines.toml 解析 + --ssh-target 直连沙箱 sshd。
# ---------------------------------------------------------------------------
t_describe "A2) machines.toml 布置 + cmd 全链路（§C.3 步骤 3/5）"

CLI_PORT=24000
CLI_ID=""
AGENT_PID=""

cli_cleanup() {
  if [[ -n "${CLI_ID}" ]]; then
    "${WORK_DIR}/bin/forward" remove "${CLI_ID}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${AGENT_PID}" ]]; then
    kill -TERM "${AGENT_PID}" 2>/dev/null || true
  fi
  return 0
}

# 说明：echo 服务在 A 段已启动（ECHO_PORT），此处不再重复启动。

t_it "准备 ssh-agent 并将容器内 client key 加入（-F /dev/null 认证前提）"
if ! command -v ssh-agent >/dev/null 2>&1; then
  t_skip "环境无 ssh-agent，无法提供 -F /dev/null 下所需的身份"
else
  # ssh-agent -s 输出需在当前 shell eval 才能导出 env；用 run 无法回传，
  # 故这里直接 eval（输出是 SSHAUTH 赋值语句，安全）并与 t_* 分开。
  run ssh-agent -a "${HOME}/agent.sock" -s
  t_exit_ok 0 "${rc}" "ssh-agent 启动"
  eval "${out}" >/dev/null 2>&1 || true
  AGENT_PID="${SSH_AGENT_PID:-}"
  export SSH_AUTH_SOCK SSH_AGENT_PID
  run ssh-add "${HOME}/.ssh/id_ed25519"
  t_exit_ok 0 "${rc}" "client key 已加入 agent（rc=${rc}）"
fi

t_it "machines.toml 写入 [machines.sandbox] 并被 machine_resolve 解析"
E2E_USER="$(id -un)"
printf '[machines.sandbox]\nssh_target = "%s@127.0.0.1:%s"\n' "${E2E_USER}" "${SSHD_PORT}" \
  >"${HERDR_PLUGIN_CONFIG_DIR}/machines.toml"
t_file_exists "${HERDR_PLUGIN_CONFIG_DIR}/machines.toml" "machines.toml 已布置"
run bash -c "source '${WORK_DIR}/lib/machine.sh' && machine_resolve sandbox"
t_exit_ok 0 "${rc}" "machine_resolve sandbox 退出 0（rc=${rc}）"
t_eq "${E2E_USER}@127.0.0.1:${SSHD_PORT}" "${out}" "解析出沙箱 ssh_target"

t_it "未声明 label -> die 4（配置路径错误可诊断）"
run bash -c "source '${WORK_DIR}/lib/machine.sh' && machine_resolve no-such-label"
t_exit_ok 4 "${rc}" "未声明 label -> 4"

t_it "bin/forward add <local>:<remote> --ssh-target -> 真起隧道"
run "${WORK_DIR}/bin/forward" add "${CLI_PORT}:${ECHO_PORT}" \
  --ssh-target "${E2E_USER}@127.0.0.1:${SSHD_PORT}"
t_exit_ok 0 "${rc}" "add 退出 0（stderr：${err}）"
CLI_ID="${out}"
t_eq "f-${CLI_PORT}" "${CLI_ID}" "返回记录 id"
t_it "状态记录 status=up 且控制主进程活着"
run bash -c "jq -r '.forwards[0].status' '${HERDR_PLUGIN_STATE_DIR}/forwards.json'"
t_eq "up" "${out}" "status up"
run bash -c "pid=\$(jq -r '.forwards[0].pid' '${HERDR_PLUGIN_STATE_DIR}/forwards.json'); kill -0 \"\$pid\""
t_exit_ok 0 "${rc}" "master pid 活着"

t_it "数据面：连本地端口经 ssh -L 收到远端 echo 回包"
echo_roundtrip "${CLI_PORT}" "e2e-cli-cycle"
t_eq "e2e-cli-cycle" "${ROUNDTRIP}" "隧道化回显往返"

t_it "list --oneline 反映活跃映射（tab bar 契约）"
run "${WORK_DIR}/bin/forward" list --oneline
t_exit_ok 0 "${rc}" "list --oneline 退出 0"
t_contains "⇅${CLI_PORT}" "${out}" "oneline 含 ⇅${CLI_PORT}"

t_it "doctor 无异常且不误删活隧道"
run "${WORK_DIR}/bin/forward" doctor
t_exit_ok 0 "${rc}" "doctor 退出 0"
run "${WORK_DIR}/bin/forward" doctor --prune
t_exit_ok 0 "${rc}" "doctor --prune 退出 0"
run bash -c "jq -r '.forwards | length' '${HERDR_PLUGIN_STATE_DIR}/forwards.json'"
t_eq "1" "${out}" "活记录在 --prune 后保留"

t_it "remove 后无监听、无残留进程、无 control socket"
run "${WORK_DIR}/bin/forward" remove "${CLI_ID}"
t_exit_ok 0 "${rc}" "remove 退出 0（stderr：${err}）"
SOCKET_PATH="${HERDR_PLUGIN_STATE_DIR}/ssh-ctl/ctl-${CLI_ID}"
CLI_ID=""
sleep 0.5
tcp_connected "${CLI_PORT}"
if [[ "${TCP_OK}" -eq 1 ]]; then
  t_fail "remove 后本地端口 ${CLI_PORT} 仍可连"
else
  t_pass "remove 后本地端口已关闭"
fi
t_file_absent "${SOCKET_PATH}" "remove 后 control socket 已删"

cli_cleanup

# ---------------------------------------------------------------------------
# B) 容器内完整基线（Dockerfile 已装齐 shellcheck/shfmt/jq，宿主缺工具不阻塞）
# ---------------------------------------------------------------------------
t_describe "B) 容器内完整基线（lint + unit + integration）"

t_it "lint 工具齐备（容器是权威基线环境；bwrap 降级时宿主缺工具则显式 SKIP）"
LINT_TOOLS_MISSING=""
for tool in shellcheck shfmt jq; do
  run command -v "${tool}"
  if [[ "${rc}" -eq 0 ]]; then
    t_pass "环境内存在 ${tool}"
  else
    LINT_TOOLS_MISSING="${LINT_TOOLS_MISSING}${tool} "
    t_skip "环境内缺 ${tool}（容器内应齐备；bwrap 复用宿主工具集）"
  fi
done

if [[ -n "${LINT_TOOLS_MISSING// /}" ]]; then
  log "WARN：缺 ${LINT_TOOLS_MISSING}-– 容器内是权威基线（本降级路径不阻塞 ci）"
fi

t_it "shellcheck 严格模式（-S style -o all）零告警"
cd "${WORK_DIR}"
mkdir -p "${RESULTS_DIR}"
SC_TARGETS_FILE="${RESULTS_DIR}/shellcheck-targets.txt"
lint_targets >"${SC_TARGETS_FILE}"
mapfile -t sc_targets <"${SC_TARGETS_FILE}"
if ! command -v shellcheck >/dev/null 2>&1; then
  t_skip "shellcheck 不可用，无法执行严格检查（已在工具检查段 WARN）"
elif [[ "${#sc_targets[@]}" -eq 0 ]]; then
  t_fail "没有可检目标（异常）"
else
  run shellcheck -x -S style -o all "${sc_targets[@]}"
  t_exit_ok 0 "${rc}" "shellcheck 干净（${#sc_targets[@]} 个目标；输出：${out}${err}）"
fi

t_it "shfmt 格式一致（-d -ln bash -i 2）"
mapfile -t fmt_targets <"${SC_TARGETS_FILE}"
if ! command -v shfmt >/dev/null 2>&1; then
  t_skip "shfmt 不可用，无法执行格式检查（已在工具检查段 WARN）"
else
  run shfmt -d -ln bash -i 2 "${fmt_targets[@]}"
  t_exit_ok 0 "${rc}" "shfmt 无 diff（输出：${out}${err}）"
fi

t_it "unit 层全绿"
UNIT_LOG="${RESULTS_DIR}/e2e-unit.log"
run bash -c "bash tests/run.sh unit >'${UNIT_LOG}' 2>&1"
if [[ "${rc}" -eq 0 ]]; then
  t_pass "环境内 unit 全绿"
  unit_log_body="$(cat "${UNIT_LOG}" || true)"
  t_contains "RESULT: PASS" "${unit_log_body}" "unit 汇总为 PASS"
else
  unit_fail_lines="$(grep -E '^not ok|FAIL tests' "${UNIT_LOG}" | head -10 || true)"
  t_fail "环境内 unit 失败（rc=${rc}）；失败行：${unit_fail_lines}（完整日志：${UNIT_LOG}）"
fi

t_it "integration 层（无文件时显式 SKIP，不视为失败）"
run bash tests/run.sh integration
t_exit_ok 0 "${rc}" "环境内 integration 通过/SKIP"

# ---------------------------------------------------------------------------
# C) herdr 挂载模式探测（§C.4 假设#6）
# ---------------------------------------------------------------------------
t_describe "C) herdr 二进制挂载模式探测（契约 §C.4，假设#6）"

mkdir -p "${RESULTS_DIR}"
MODE_FILE="${RESULTS_DIR}/e2e-mode.txt"
REPORT_FILE="${RESULTS_DIR}/e2e-report.txt"
NOW_UTC="$(date -u '+%Y-%m-%dT%H:%M:%SZ' || true)"

HERDR_BIN=""
for cand in /usr/local/bin/herdr /usr/bin/herdr; do
  if [[ -x "${cand}" ]]; then
    HERDR_BIN="${cand}"
    break
  fi
done
# bwrap 降级路径把宿主 herdr 挂到非标准位置（如 /e2e-herdr-bin/herdr）→ 再查 PATH
if [[ -z "${HERDR_BIN}" ]]; then
  herdr_on_path="$(command -v herdr 2>/dev/null || true)"
  if [[ -n "${herdr_on_path}" && -x "${herdr_on_path}" ]]; then
    HERDR_BIN="${herdr_on_path}"
  fi
fi

E2E_MODE="B"
HERDR_VERSION_OUT=""
if [[ -n "${HERDR_BIN}" ]]; then
  t_it "模式 A 探测：容器内执行挂载的宿主 herdr --version"
  run "${HERDR_BIN}" --version
  if [[ "${rc}" -eq 0 ]]; then
    E2E_MODE="A"
    HERDR_VERSION_OUT="${out}"
    t_pass "模式 A 成立：${HERDR_BIN} 在容器内可跑（${out}）"
  else
    t_pass "模式 B 成立：herdr 存在但容器内不可执行（rc=${rc}；${err}）"
  fi
else
  t_it "模式 B：容器内无挂载 herdr（走纯 bash 层 + shim）"
  t_pass "模式 B 成立：未挂载宿主 herdr 二进制"
fi

t_it "模式 B 下提供 herdr shim（记录调用，不碰真 server）"
if [[ "${E2E_MODE}" == "B" ]]; then
  SHIM_DIR="${HOME}/.local/bin"
  mkdir -p "${SHIM_DIR}"
  cat >"${SHIM_DIR}/herdr" <<'SHIM'
#!/usr/bin/env bash
# E2E shim：把 herdr CLI 调用记录到文件，绝不连接真实 server（假设#6 模式 B）
printf '%s\n' "$*" >>"${HERDR_E2E_SHIM_LOG:-/dev/null}"
if [[ "${1:-}" == "--version" ]]; then
  echo "herdr-shim (E2E mode B)"
fi
exit 0
SHIM
  chmod +x "${SHIM_DIR}/herdr"
  export PATH="${SHIM_DIR}:${PATH}"
  export HERDR_E2E_SHIM_LOG="${RESULTS_DIR}/herdr-shim-calls.log"
  : >"${HERDR_E2E_SHIM_LOG}"
  run herdr --version
  t_exit_ok 0 "${rc}" "shim 可执行"
  t_contains "herdr-shim" "${out}" "shim 输出可辨识"
  t_file_exists "${HERDR_E2E_SHIM_LOG}" "shim 调用日志已生成"
else
  t_pass "模式 A 已定型，无需 shim"
fi

t_it "E2E 不污染隔离 HOME 下的真 herdr 配置目录（负面断言）"
if [[ -d "${HOME}/.config/herdr" ]]; then
  herdr_cfg_after="$(find "${HOME}/.config/herdr" -type f 2>/dev/null | sort || true)"
  t_eq "${REAL_HERDR_CONFIG_SNAPSHOT}" "${herdr_cfg_after}" "E2E 前后 ~/.config/herdr 文件集不变"
else
  t_file_absent "${HOME}/.config/herdr" "E2E 未创建 ~/.config/herdr"
fi

# 汇总输出字段（先算好，避免在 heredoc 里做命令替换触发 SC2312）
if [[ -n "${HERDR_BIN}" ]]; then
  HERDR_MOUNTED_FLAG=1
else
  HERDR_MOUNTED_FLAG=0
fi
HERDR_PATH_OUT="${HERDR_BIN:-none}"
HERDR_VERSION_FIELD="${HERDR_VERSION_OUT:-n/a}"
if [[ "${E2E_MODE}" == "A" ]]; then
  MODE6_RESULT="模式 A：容器内可跑挂载的宿主 herdr"
  ASSUMPTION6_RUNNABLE="yes"
else
  MODE6_RESULT="模式 B：容器内不可跑，降级 shim + 纯 bash 层"
  ASSUMPTION6_RUNNABLE="no"
fi

cat >"${MODE_FILE}" <<EOF
# herdr-forward E2E 模式探测（ARCHITECTURE §C.4 假设#6）
# 生成时间：${NOW_UTC}
mode=${E2E_MODE}
herdr_mounted=${HERDR_MOUNTED_FLAG}
herdr_path=${HERDR_PATH_OUT}
herdr_version=${HERDR_VERSION_FIELD}
assumption_6=verified
assumption_6_result=${MODE6_RESULT}
EOF

cat >"${REPORT_FILE}" <<EOF
# E2E 探通报告（T0，ARCHITECTURE §G）
assumption_6_mounted_herdr_runnable=${ASSUMPTION6_RUNNABLE}
assumption_6_mode=${E2E_MODE}
assumption_7_user_sshd_pubkey_login=yes
assumption_7_sshd_port=${SSHD_PORT}
assumption_7_echo_roundtrip_port=${ECHO_PORT}
isolation_home=${HOME}
EOF

t_it "模式探测结果落盘"
t_file_exists "${MODE_FILE}" "e2e-mode.txt 已写出"
run cat "${MODE_FILE}"
t_contains "mode=${E2E_MODE}" "${out}" "mode 字段正确"
t_contains "assumption_6=verified" "${out}" "假设#6 已标注验证"
run cat "${REPORT_FILE}"
t_contains "assumption_7_user_sshd_pubkey_login=yes" "${out}" "假设#7 已标注验证"

# ---------------------------------------------------------------------------
# D) 清理 + 无残留
# ---------------------------------------------------------------------------
t_describe "D) 清理与残留检查"
log "停止后台进程"
cleanup
sleep 1

t_it "socat echo 服务后台进程无残留"
run pgrep -f 'sshd -D -e -f .*sshd_config'
t_isnt 0 "${rc}" "无残留 sshd 测试进程（残留：${out}）"
run pgrep -f "socat TCP-LISTEN:${ECHO_PORT}"
t_isnt 0 "${rc}" "无残留 echo 进程（残留：${out}）"

t_it "端口已释放"
run bash -c "exec 3<>/dev/tcp/127.0.0.1/${SSHD_PORT}; exit \$?"
t_isnt 0 "${rc}" "sshd 端口 ${SSHD_PORT} 已关闭"
run bash -c "exec 3<>/dev/tcp/127.0.0.1/${ECHO_PORT}; exit \$?"
t_isnt 0 "${rc}" "echo 端口 ${ECHO_PORT} 已关闭"

t_it "断言库收尾断言 t_no_zombie_ssh"
t_no_zombie_ssh "E2E 无残留 ssh/herdr-forward 进程"

printf '\n[e2e] 探通结论：假设#6 模式=%s，假设#7 用户态 sshd+回显=OK\n' "${E2E_MODE}"
t_done
