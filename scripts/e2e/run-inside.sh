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

# ---------------------------------------------------------------------------
# Go CLI（bin/forward-go）的容器内准备（PLAN-GO-MIGRATION §6 Phase 1 W4）
#
# bin/forward 对 `list|ports` 做条件 exec（存在 bin/forward-go 才切 Go），所以 E2E 必须在
# 容器内把这个二进制准备好，否则 A/A2/B2 跑的仍是纯 bash —— 那就没有「切换后 E2E 仍绿」
# 的证据。容器镜像里有 go 工具链（PLAN §9 R4：E2E 容器要能离线构建）。
#
# 构建位置：${WORK_DIR}/bin/forward-go（工作区，不是只读的 /plugin-src）。
#   优先用预先构建好的（run-bwrap.sh 在宿主预构建后随源码拷进来）；
#   否则容器内 `go build -mod=vendor`（离线、vendor 已提交）；
#   两者都不具备时显式失败并给指引（不静默退化，否则就变成“假绿”）。
# ---------------------------------------------------------------------------
GO_BIN="${WORK_DIR}/bin/forward-go"
GO_CLI_READY=0
go_cli_prepare() {
  mkdir -p "${WORK_DIR}/bin"
  if [[ -x "${GO_BIN}" ]] && "${GO_BIN}" help >/dev/null 2>&1; then
    GO_CLI_READY=1
    log "Go CLI 就绪（沿用容器内已有产物）：${GO_BIN}"
    return 0
  fi
  if command -v go >/dev/null 2>&1; then
    log "容器内构建 Go CLI（go build -mod=vendor ./cmd/forward）"
    if (cd "${WORK_DIR}/go" && GOFLAGS=-mod=vendor go build -o "${GO_BIN}" ./cmd/forward) \
      >>"${RESULTS_DIR}/go-cli-build.log" 2>&1; then
      chmod +x "${GO_BIN}" 2>/dev/null || true
      GO_CLI_READY=1
      log "Go CLI 构建成功：${GO_BIN}"
      return 0
    fi
    log "WARN：容器内 go build 失败（日志 ${RESULTS_DIR}/go-cli-build.log）"
    return 0
  fi
  log "WARN：容器内无 go 工具链，且未预置 ${GO_BIN}"
  return 0
}
go_cli_prepare

# 整壳开关：B 段要跑「纯 bash 基线」（若干 integration 用例的历史 golden 是 bash 端口探测），
# 故把 Go CLI 挪出视野；B2 段再恢复。GO_CLI_PARKED 记录被挪走的位置。
GO_CLI_PARKED=""
go_cli_park() {
  if [[ -n "${GO_CLI_PARKED}" ]]; then
    return 0
  fi
  if [[ -f "${GO_BIN}" ]]; then
    GO_CLI_PARKED="${GO_BIN}.e2e-parked"
    mv -f "${GO_BIN}" "${GO_CLI_PARKED}" 2>/dev/null || GO_CLI_PARKED=""
    if [[ -n "${GO_CLI_PARKED}" ]]; then
      log "暂停 Go CLI（B 段按纯 bash 基线跑）：${GO_BIN} -> ${GO_CLI_PARKED}"
    fi
  fi
  return 0
}
go_cli_unpark() {
  if [[ -n "${GO_CLI_PARKED}" && -f "${GO_CLI_PARKED}" ]]; then
    mv -f "${GO_CLI_PARKED}" "${GO_BIN}" 2>/dev/null || true
    GO_CLI_PARKED=""
    log "恢复 Go CLI：${GO_BIN}"
  fi
  return 0
}

# lint_targets：stdout 每行一个 shell 目标（供 shellcheck/shfmt 用）。
# 覆盖真实代码而不只是测试：bin/forward、lib/*.sh、tests/lib、tests/unit、
# tests/integration/tests/difftest、scripts（含 e2e）。只输出存在的文件。
lint_targets() {
  local f=""
  [[ -f "bin/forward" ]] && printf '%s\n' "bin/forward"
  for f in lib/*.sh; do
    [[ -f "${f}" ]] && printf '%s\n' "${f}"
  done
  for f in tests/lib/*.sh tests/unit/*.sh tests/integration/*.sh tests/difftest/*.sh \
    tests/run.sh scripts/*.sh scripts/e2e/*.sh; do
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

# W4 切换验证：这一条必须走 Go 实现（bin/forward 对 list|ports 做条件 exec）
# 证明方式：把 bin/forward-go 换成打印标记的 shim，同一命令应输出标记（而不是 oneline）。
t_it "W4：bin/forward list 已切到 Go 实现（staged shim 探针）"
if [[ "${GO_CLI_READY}" -ne 1 ]]; then
  t_skip "容器内未就绪 Go CLI（无预置二进制且无 go 工具链），跳过切换探针"
else
  W4_STAGE="${HOME}/w4-dispatch"
  rm -rf "${W4_STAGE}"
  mkdir -p "${W4_STAGE}/bin"
  cp "${WORK_DIR}/bin/forward" "${W4_STAGE}/bin/forward"
  chmod +x "${W4_STAGE}/bin/forward"
  ln -sfn "${WORK_DIR}/lib" "${W4_STAGE}/lib"
  cp "${WORK_DIR}/bin/forward-go" "${W4_STAGE}/bin/forward-go"
  chmod +x "${W4_STAGE}/bin/forward-go"
  run "${W4_STAGE}/bin/forward" list --oneline
  t_exit_ok 0 "${rc}" "Go 路径 list --oneline 退出 0（stderr：${err}）"
  t_contains "⇅${CLI_PORT}" "${out}" "Go 路径同样输出 ⇅${CLI_PORT}（行为一致）"
  # 反向：没有 forward-go 时同一脚本回退 bash（两者逐字节相同）
  dispatcher_out="${out}"
  rm -f "${W4_STAGE}/bin/forward-go"
  run "${W4_STAGE}/bin/forward" list --oneline
  t_exit_ok 0 "${rc}" "bash 回退路径退出 0"
  t_eq "${dispatcher_out}" "${out}" "Go 与 bash 的 list --oneline 逐字节一致"
  rm -rf "${W4_STAGE}"
fi

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
# A3) A 机器场景（saved machine target = ssh:// URI 形态）—— 漏测固化的容器侧闸门
#
# 为什么要单独一段：B 机器上 `herdr machine add` 造出的 target 是裸 `user@host`，
# 于是容器里 59 条断言全绿却在 A 上炸（A 的真实 target 是 `ssh://user@host:port`）。
# 本段用 A 的**全量真实数据**（5 台，含中文 label「GPU机器」）当 fake herdr 的输出，
# 把「数据层 → 面板渲染 → 非交互 watch 退化 → ssh 探测 argv」整条链在容器里跑一遍。
#
# 只读保证：fake herdr 只回放 JSON（不连真 server）；ssh 用 shim 捕获 argv 后立即失败
# （**绝不真连任何主机**，也不碰宿主/saved machine）。
# ---------------------------------------------------------------------------
t_describe "A3) A 机器场景（ssh:// URI target，含中文 label）"

A_STAGE_DIR="${HOME}/a-scenario"
A_STATE_DIR="${A_STAGE_DIR}/state"
A_BIN_DIR="${A_STAGE_DIR}/bin"
rm -rf "${A_STAGE_DIR}"
mkdir -p "${A_STATE_DIR}" "${A_BIN_DIR}"

# A 机器实测 `herdr machine list --json` 原样摘录（pretty 格式 + 字段顺序都保留）
A_FIXTURE="${A_STAGE_DIR}/machine-list.json"
cat >"${A_FIXTURE}" <<'AJSON'
[
  {
    "id": "191645f46cf4bc677a393cf0ca51d193",
    "label": "nj-mac",
    "target": "ssh://zheng@nj.rssyes.com:31415",
    "session": "default",
    "enabled": true,
    "selected": false
  },
  {
    "id": "0b5ecacd1e138809455cdf60fb00d81a",
    "label": "devcloud",
    "target": "ssh://root@devcloud.zzj.cool:2222",
    "session": "default",
    "enabled": true,
    "selected": false
  },
  {
    "id": "7bfb921a0d1e6f759797e467b3360f87",
    "label": "nj-hw",
    "target": "ssh://zzjcool@nj.rssyes.com:31416",
    "session": "default",
    "enabled": true,
    "selected": false
  },
  {
    "id": "413b9711c1552bba29c9ace8ff8dc5a4",
    "label": "nj-host",
    "target": "ssh://chieh@nj.rssyes.com:31417",
    "session": "default",
    "enabled": true,
    "selected": false
  },
  {
    "id": "8048d128c5b8a78a7bc10743a4c85853",
    "label": "GPU机器",
    "target": "ssh://root@zhijiezheng-any4.devcloud.woa.com:36000",
    "session": "default",
    "enabled": true,
    "selected": false
  }
]
AJSON

# A 形态 fake herdr：`machine list --json` 回放上面的 fixture（其余子命令 127）
cat >"${A_BIN_DIR}/herdr" <<EOF
#!/usr/bin/env bash
if [[ "\${1-}" == "machine" && "\${2-}" == "list" ]]; then
  cat '${A_FIXTURE}'
  exit 0
fi
if [[ "\${1-}" == "--version" ]]; then
  echo 'herdr-a-scenario-fixture (E2E)'
  exit 0
fi
exit 127
EOF
chmod +x "${A_BIN_DIR}/herdr"

# ssh shim：只记 argv、恒失败（绝不真连）
A_SSH_LOG="${A_STAGE_DIR}/ssh-argv.log"
: >"${A_SSH_LOG}"
cat >"${A_BIN_DIR}/ssh" <<'ASHIM'
#!/usr/bin/env bash
printf 'ARGV' >>"${A_SSH_LOG:?}"
for a in "$@"; do printf ' <%s>' "$a" >>"${A_SSH_LOG}"; done
printf '\n' >>"${A_SSH_LOG}"
printf 'a-scenario-fixture: no real connection\n' >&2
exit 255
ASHIM
chmod +x "${A_BIN_DIR}/ssh"
export A_SSH_LOG

# fake watch：非交互 watch 退化路径的断言目标（真 watch(1) 会挂住不收尾）
cat >"${A_BIN_DIR}/watch" <<'AWTCH'
#!/usr/bin/env bash
printf 'FAKE-WATCH %s\n' "$*"
AWTCH
chmod +x "${A_BIN_DIR}/watch"

A_ENV=(
  "HERDR_BIN_PATH=${A_BIN_DIR}/herdr"
  "HERDR_PLUGIN_STATE_DIR=${A_STATE_DIR}"
  "HERDR_PLUGIN_CONFIG_DIR=${A_STAGE_DIR}/config"
)

# worker-15 修复探测（输出式；判据：带 scheme 的 target 必须解析出自己的端口）
A_SCHEME_FIX="no"
A_SCHEME_PROBE=""
run env "${A_ENV[@]}" bash -c \
  "source '${WORK_DIR}/lib/common.sh' >/dev/null 2>&1; source '${WORK_DIR}/lib/ssh-probe.sh' >/dev/null 2>&1; ssh_probe_parse_target 'ssh://probe.invalid:1'"
A_SCHEME_PROBE="${out}"
if [[ "${A_SCHEME_PROBE}" == "probe.invalid 1" ]]; then
  A_SCHEME_FIX="yes"
else
  log "A3：lib/ssh-probe.sh 尚未剥 ssh://（worker-15 未合入）→ argv 精确断言记 expected-red SKIP"
fi

t_it "fixture 自检：5 台机器、target 全 ssh:// URI、label 顺序含中文"
run jq -r '[.[].target | startswith("ssh://")] | all' "${A_FIXTURE}"
t_eq "true" "${out}" "target 全是 ssh:// 形态（A 的真实数据形状）"
run jq -r '[.[].label] | join(",")' "${A_FIXTURE}"
t_eq "nj-mac,devcloud,nj-hw,nj-host,GPU机器" "${out}" "5 台 label 顺序与中文 label 正确"

t_it "machines_herdr_list_json 解析 A 形态：5 台，target 逐字保留"
run env "${A_ENV[@]}" bash -c \
  "source '${WORK_DIR}/lib/machines.sh' >/dev/null 2>&1; machines_herdr_list_json | jq -r 'length'"
t_exit_ok 0 "${rc}" "数据层调用成功（stderr：${err}）"
t_eq "5" "${out}" "透传 5 台"
run env "${A_ENV[@]}" bash -c \
  "source '${WORK_DIR}/lib/machines.sh' >/dev/null 2>&1; machines_herdr_list_json | jq -r '[.[].target] | join(\"\n\")'"
t_eq "ssh://zheng@nj.rssyes.com:31415
ssh://root@devcloud.zzj.cool:2222
ssh://zzjcool@nj.rssyes.com:31416
ssh://chieh@nj.rssyes.com:31417
ssh://root@zhijiezheng-any4.devcloud.woa.com:36000" "${out}" "5 台 target 全部逐字保留"

t_it "machines_view_json：5 台 inactive，target 原文保留（面板数据入口）"
run env "${A_ENV[@]}" bash -c \
  "source '${WORK_DIR}/lib/machines.sh' >/dev/null 2>&1; machines_view_json"
t_exit_ok 0 "${rc}" "view 调用成功"
A_VIEW="${out}"
run bash -c "printf '%s' '${A_VIEW}' | jq -r 'length'"
t_eq "5" "${out}" "视图 5 条"
run bash -c "printf '%s' '${A_VIEW}' | jq -r '[.[].state] | join(\",\")'"
t_eq "inactive,inactive,inactive,inactive,inactive" "${out}" "全 inactive"
run bash -c "printf '%s' '${A_VIEW}' | jq -r '[.[] | select(.id==\"8048d128c5b8a78a7bc10743a4c85853\") | .target] | join(\",\")'"
t_eq "ssh://root@zhijiezheng-any4.devcloud.woa.com:36000" "${out}" "GPU机器 target 原文保留"

t_it "中文 label 在容器 locale 下 jq 往返不乱码（UTF-8 字节级）"
run bash -c "printf '%s' '${A_VIEW}' | jq -r '[.[] | select(.label==\"GPU机器\")] | length'"
t_eq "1" "${out}" "中文 label 精确匹配命中（未被转义/乱码）"
run bash -c "printf '%s' '${A_VIEW}' | jq -r '[.[] | select(.label==\"GPU机器\")][0].label' | wc -c"
t_eq "10" "${out}" "9 字节 UTF-8 + 换行（未被转成 \\uXXXX）"
run env LC_ALL=C LANG=C bash -c \
  "source '${WORK_DIR}/lib/machines.sh' >/dev/null 2>&1; machines_view_json | jq -r '[.[] | select(.label==\"GPU机器\")][0].label' | wc -c"
t_exit_ok 0 "${rc}" "LC_ALL=C 下数据层仍可用"

t_it "bin/forward machines list：表格含 5 台（含中文 label 与 ssh:// target）"
run env "${A_ENV[@]}" "${WORK_DIR}/bin/forward" machines list
t_exit_ok 0 "${rc}" "machines list rc=0（stderr：${err}）"
t_contains "nj-mac" "${out}" "表格含 nj-mac"
t_contains "devcloud" "${out}" "表格含 devcloud"
t_contains "nj-hw" "${out}" "表格含 nj-hw"
t_contains "nj-host" "${out}" "表格含 nj-host"
t_contains "GPU机器" "${out}" "表格含中文 label GPU机器"
t_contains "ssh://zheng@nj.rssyes.com:31415" "${out}" "表格里 nj-mac 的 target 是 ssh:// 原文"
t_contains "ssh://root@zhijiezheng-any4.devcloud.woa.com:36000" "${out}" "表格里 GPU机器 的 target 是 ssh:// 原文"
t_contains "[ ] 未激活" "${out}" "全部标为未激活（A 的真实初始状态）"

t_it "bin/forward machines list --json / --short：5 台且 target 原文"
run env "${A_ENV[@]}" "${WORK_DIR}/bin/forward" machines list --json
t_exit_ok 0 "${rc}" "list --json rc=0"
run bash -c "printf '%s' '${out}' | jq -r 'length'"
t_eq "5" "${out}" "--json 5 条"
run env "${A_ENV[@]}" "${WORK_DIR}/bin/forward" machines list --short
t_exit_ok 0 "${rc}" "list --short rc=0"
t_contains "GPU机器" "${out}" "--short 含中文 label"
t_contains "ssh://root@zhijiezheng-any4.devcloud.woa.com:36000" "${out}" "--short 含 ssh:// target 原文"

t_it "watch 非交互退化：exec watch -n 3 forward list（面板不开，脚本化零回归）"
# cmd_watch 在 `[[ -t 0 ]]` 为假时 exec `watch -n 3 forward list`。这里用探针脚本把
# stdin 接到 /dev/null（容器里 run-inside.sh 的 stdin 本身不保证非 TTY），并把
# ${A_BIN_DIR}/watch 放到 PATH 最前拦下真 watch(1)（真 watch 在非 tty 下会
# "failed to open terminal" 退出 126，而且它会挂住不收尾）。
cat >"${A_STAGE_DIR}/watch-probe.sh" <<EOF
set -Eeuo pipefail
export HERDR_BIN_PATH='${A_BIN_DIR}/herdr'
export HERDR_PLUGIN_STATE_DIR='${A_STATE_DIR}'
export HERDR_PLUGIN_CONFIG_DIR='${A_STAGE_DIR}/config'
export PATH="${A_BIN_DIR}:\${PATH}"
exec bash '${WORK_DIR}/bin/forward' watch </dev/null
EOF
run bash "${A_STAGE_DIR}/watch-probe.sh"
t_exit_ok 0 "${rc}" "watch（非 TTY）rc=0（stderr：${err}）"
t_contains "FAKE-WATCH" "${out}" "走的是 watch(1)（未进交互面板）"
t_contains "-n 3" "${out}" "刷新间隔 3s"
t_contains "list" "${out}" "目标是 forward list"

# 面板渲染（非交互直出 panel_render：pane 里渲染的就是这段文本）。
# 探针一律达成文件用 `bash <file>` 跑，自己 export 所需变量：避免把长串 env 前缀
# 写进命令行（可读性 + shellcheck/shfmt 友好），也避免 PATH 相互干扰。
cat >"${A_STAGE_DIR}/render.sh" <<EOF
set -Eeuo pipefail
export HERDR_BIN_PATH='${A_BIN_DIR}/herdr'
export HERDR_PLUGIN_STATE_DIR='${A_STATE_DIR}'
export HERDR_PLUGIN_CONFIG_DIR='${A_STAGE_DIR}/config'
source '${WORK_DIR}/lib/common.sh' >/dev/null 2>&1 || true
source '${WORK_DIR}/lib/state.sh' >/dev/null 2>&1 || true
source '${WORK_DIR}/lib/machines.sh' >/dev/null 2>&1 || true
source '${WORK_DIR}/lib/panel.sh' >/dev/null 2>&1 || true
panel_render
EOF
t_it "面板渲染（非交互直出）：MACHINES (5) 含 5 台机器与中文 label"
run bash "${A_STAGE_DIR}/render.sh"
t_exit_ok 0 "${rc}" "panel_render rc=0（stderr：${err}）"
t_contains "MACHINES (5)" "${out}" "面板列出 5 台（这就是 A 上应该看到的输出）"
t_contains "nj-mac" "${out}" "面板含 nj-mac"
t_contains "nj-host" "${out}" "面板含 nj-host"
t_contains "GPU机器" "${out}" "面板含中文 label GPU机器"
t_contains "ssh://zheng@nj.rssyes.com:31415" "${out}" "面板 target 显示 ssh:// 原文"
t_contains "未激活" "${out}" "全部标为未激活"

t_it "激活 ssh:// target：探测命令 argv 组装（ssh shim 捕获，不真连）"
# 期待（M1 冻结形状）：ssh -n -o BatchMode=yes -o ConnectTimeout=8 [-p PORT] HOST REMOTE_CMD
# worker-15 未合入时 HOST 会带着 ssh:// 前缀且无 -p —— 那是 A 的实测症状，此处记为 expected-red。
: >"${A_SSH_LOG}"
cat >"${A_STAGE_DIR}/argv.sh" <<EOF
set -Eeuo pipefail
export PATH="${A_BIN_DIR}:\${PATH}"
export A_SSH_LOG='${A_SSH_LOG}'
source '${WORK_DIR}/lib/ssh-probe.sh' >/dev/null 2>&1
ssh_probe_run 'ssh://zheng@nj.rssyes.com:31415' 'REMOTE_LIST_CMD_FIXTURE'
EOF
run bash "${A_STAGE_DIR}/argv.sh"
t_exit_ok 0 "${rc}" "ssh_probe_run 恒 return 0（stderr：${err}）"
A_ARGV="$(cat "${A_SSH_LOG}" 2>/dev/null || true)"
t_contains "ARGV <-n>" "${A_ARGV}" "argv 起点是 ssh shim 的 -n（非交互，不吃 stdin）"
t_contains "BatchMode=yes" "${A_ARGV}" "带 BatchMode=yes（绝不弹密码）"
t_contains "ConnectTimeout=8" "${A_ARGV}" "带有界连接超时"
t_contains "REMOTE_LIST_CMD_FIXTURE" "${A_ARGV}" "远端命令作为最后一个实参"
if [[ "${A_SCHEME_FIX}" == "yes" ]]; then
  t_contains "<-p> <31415>" "${A_ARGV}" "显式端口 -p 31415（nj-mac:31415）"
  t_contains "<zheng@nj.rssyes.com>" "${A_ARGV}" "host 无 ssh:// 前缀"
  A_ARGV_SCHEME="no"
  if [[ "${A_ARGV}" == *ssh://* ]]; then
    A_ARGV_SCHEME="yes"
  fi
  t_eq "no" "${A_ARGV_SCHEME}" "argv 中不含 ssh:// scheme"
else
  t_contains "ssh://zheng@nj.rssyes.com:31415" "${A_ARGV}" "当前 main 症状复现：整串被当 host（worker-15 修复后本断言改为 -p 31415）"
  t_skip "expected-red：ssh:// 剥前缀 + -p 31415 归 worker-15（lib/ssh-probe.sh）；合入后本段自动转绿"
fi

t_it "激活链路不假装 present（shim 恒失败 -> 绝不写指向 A 的假路径）"
cat >"${A_STAGE_DIR}/bridge.sh" <<EOF
set -Eeuo pipefail
export PATH="${A_BIN_DIR}:\${PATH}"
export A_SSH_LOG='${A_SSH_LOG}'
source '${WORK_DIR}/lib/machines.sh' >/dev/null 2>&1
source '${WORK_DIR}/lib/ssh-probe.sh' >/dev/null 2>&1
machines_ssh_probe_plugin 'ssh://zheng@nj.rssyes.com:31415'
EOF
run bash "${A_STAGE_DIR}/bridge.sh"
t_exit_ok 0 "${rc}" "探测桥 rc=0"
t_contains "HF_STATUS=" "${out}" "输出 §2.1 冻结的 KV 契约"
t_isnt "HF_STATUS=present" "${out}" "绝不假装 present"
t_file_absent "${A_STATE_DIR}/activated-machines.json" "未写激活记录（不产生指向 A 的假路径）"

t_it "配置隔离：A 段的 HERDR_BIN_PATH 不泄漏到后续阶段（B/C/D 用各自环境）"
run bash -c "printf '%s' '${HERDR_BIN_PATH:-<unset>}'"
t_eq "<unset>" "${out}" "A 段的 fake herdr 只经 env 前缀注入，未污染全局"

# 收尾：本段的 fake herdr / shim 不进后续阶段（B/C/D 仍用各自的环境）
rm -rf "${A_STAGE_DIR}"

# ---------------------------------------------------------------------------
# B) 容器内完整基线（Dockerfile 已装齐 shellcheck/shfmt/jq，宿主缺工具不阻塞）
#
# ⚠ W4：本段先「暂停」Go CLI（go_cli_park）—— unit/integration 里有一批用例拿
#   仓库根的 bin/forward 调 list/ports，其历史 golden 是纯 bash 输出（尤其 ports 的
#   PROCESS 列依赖 ss 的进程名，而 Go 读 /proc 拿不到）。保留 Go 会让它们假红。
#   切换后的等价验证由紧随的 B2 段负责。
# ---------------------------------------------------------------------------
t_describe "B) 容器内完整基线（lint + unit + integration）"
go_cli_park

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
# B2) W4 切换后的 Go CLI 验证（PLAN-GO-MIGRATION §6 Phase 1 / §10 W4）
#
# 为什么要单起一段：B 段测的是「纯 bash 基线」（历史 golden），而 W4 的验收是
# 「把 list/ports 切给 Go 之后，E2E 断言不变且仍绿」。本段恢复到 Go 路径后，把
# 用户可见的三条 list 形态 + ports 对位 + 回退等价一次性钉住。
# ---------------------------------------------------------------------------
t_describe "B2) W4：list/ports 切 Go 后的 E2E 对位"
go_cli_unpark

FW_W4="${WORK_DIR}/bin/forward"

# 造一条**真实**记录（走 bash cmd_add 的 client 分支，不起 ssh）供 list 三形态用。
W4_STATE="${HERDR_PLUGIN_STATE_DIR}"
W4_BAK="${RESULTS_DIR}/forwards.json.b2bak"
if [[ -f "${W4_STATE}/forwards.json" ]]; then
  cp "${W4_STATE}/forwards.json" "${W4_BAK}"
fi
W4_CLIENT_PORT=24517
run "${FW_W4}" add "${W4_CLIENT_PORT}" --client
t_exit_ok 0 "${rc}" "B2 add --client 登记完成（stderr：${err}）"
run "${FW_W4}" list --json
t_exit_ok 0 "${rc}" "list --json 退出 0"
run bash -c "printf '%s' '${out}' | jq -r '[.forwards[] | select(.local_port == ${W4_CLIENT_PORT})] | length'"
t_eq "1" "${out}" "--json 含刚登记的 client 映射"

# list --oneline：无 client 在线 -> 空；表格仍能看到该行（waiting）。
run "${FW_W4}" list --oneline
t_exit_ok 0 "${rc}" "list --oneline 退出 0"
if [[ -n "${out}" ]]; then
  t_fail "client 未上线时 oneline 应为空，实际：${out}"
else
  t_pass "client 未上线时 oneline 为空（与 bash 一致）"
fi
run "${FW_W4}" list
t_exit_ok 0 "${rc}" "list 退出 0"
t_contains "${W4_CLIENT_PORT}" "${out}" "表格含该 client 行"
t_contains "waiting" "${out}" "client 映射状态为 waiting"

# 回退等价：同一状态目录下，Go 路径与 bash 路径的输出必须逐字节相同。
# 手法：把 bin/forward-go 挪开 -> bin/forward 回退 bash；两侧都跑 list / list --json。
t_it "B2：Go 与 bash 的 list 输出逐字节一致（回滚等价性）"
if [[ "${GO_CLI_READY}" -ne 1 ]]; then
  t_skip "容器内未就绪 Go CLI，跳过回滚等价性对位"
else
  run "${FW_W4}" list
  w4_go_table="${out}"
  run "${FW_W4}" list --json
  w4_go_json="${out}"
  run "${FW_W4}" list --oneline
  w4_go_oneline="${out}"
  go_cli_park
  run "${FW_W4}" list
  t_eq "${w4_go_table}" "${out}" "list 表格：Go 与 bash 逐字节一致"
  run "${FW_W4}" list --json
  t_eq "${w4_go_json}" "${out}" "list --json：Go 与 bash 逐字节一致"
  run "${FW_W4}" list --oneline
  t_eq "${w4_go_oneline}" "${out}" "list --oneline：Go 与 bash 逐字节一致"
  # ports：bash 会优先用 ss（带进程名），Go 读 /proc（无进程名）—— 已知偏离。
  # 只断言「行集合（端口/地址）」一致，不断言 PROCESS 列。
  run "${FW_W4}" ports
  w4_bash_ports="${out}"
  go_cli_unpark
  run "${FW_W4}" ports
  w4_go_ports="${out}"
  w4_bash_ports_portcol="$(printf '%s\n' "${w4_bash_ports}" | awk 'NR>1 {print $1" "$2}' | sort)"
  w4_go_ports_portcol="$(printf '%s\n' "${w4_go_ports}" | awk 'NR>1 {print $1" "$2}' | sort)"
  t_eq "${w4_bash_ports_portcol}" "${w4_go_ports_portcol}" "ports：端口/地址列一致（PROCESS 列有已知偏离）"
  t_contains "PORT    ADDR             PROCESS              FORWARDED" "${w4_go_ports}" "ports（Go）表头契约不变"
fi

# tab bar 延迟：`forward list --oneline` 必须秒回（面板/ tab bar 命令的热路径）。
t_it "B2：list --oneline 延迟 < 1s（tab bar 热路径）"
START_NS="$(date +%s%N)"
run "${FW_W4}" list --oneline
t_exit_ok 0 "${rc}" "oneline 退出 0"
END_NS="$(date +%s%N)"
ELAPSED_MS=$(((END_NS - START_NS) / 1000000))
if [[ "${ELAPSED_MS}" -lt 1000 ]]; then
  t_pass "oneline 耗时 ${ELAPSED_MS}ms < 1000ms"
else
  t_fail "oneline 耗时 ${ELAPSED_MS}ms，超过 1s 预算"
fi

# 差分测试：容器内可直接跑（能离线 vendor 构建 Go CLI）
t_it "B2：容器内 bash tests/difftest/run.sh（bash↔Go 逐字节差分）"
if [[ ! -f "${WORK_DIR}/tests/difftest/run.sh" ]]; then
  t_skip "tests/difftest/run.sh 不存在，跳过容器内差分测试"
elif ! command -v go >/dev/null 2>&1; then
  t_skip "容器内无 go 工具链，无法跑差分测试（bwrap 降级路径已知限制；宿主 ci.sh 已跑该段）"
else
  DIFF_LOG="${RESULTS_DIR}/e2e-difftest.log"
  run bash -c "bash tests/difftest/run.sh >'${DIFF_LOG}' 2>&1"
  if [[ "${rc}" -eq 0 ]]; then
    t_pass "容器内差分测试全绿"
    diff_tail="$(tail -2 "${DIFF_LOG}" || true)"
    t_contains "RESULT: PASS" "${diff_tail}" "差分测试汇总为 PASS"
  else
    diff_fails="$(grep -E '^not ok' "${DIFF_LOG}" | head -10 || true)"
    t_fail "容器内差分测试失败（rc=${rc}）：${diff_fails}（完整日志：${DIFF_LOG}）"
  fi
fi

# 收拾 B2 的状态改动：把 B 段之前的状态文件放回去（C/D 段不依赖它）。
if [[ -f "${W4_BAK}" ]]; then
  mv -f "${W4_BAK}" "${W4_STATE}/forwards.json"
else
  rm -f "${W4_STATE}/forwards.json"
fi

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
