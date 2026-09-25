#!/usr/bin/env bash
# tests/difftest/phase2-go-path.sh — Phase 2 的「Go 路径」验收探针（宿主可跑，无需 docker）
#
# 为什么单独一个脚本：验收要求证明 add / remove / doctor 真的走了 Go 实现，而
# `scripts/e2e/run-inside.sh`（docker/bwrap E2E）不打印「哪一侧处理了这次调用」。
# 本脚本用**记录型 shim** 替换 bin/forward-go（记录一行后 exec 真二进制），因此
# 「dispatch 到 Go」与「Go 实现的行为」同时被证明，且全部在隔离 HOME/state 目录里跑。
#
# 覆盖（每一条都走 bin/forward 的条件 exec -> bin/forward-go）：
#   * add <local>:<remote> --ssh-target -> 真起 ssh -L ControlMaster（状态 up + pid + ctl）
#   * 经 ssh -L 的本地端口回环收到远端 echo 回包（数据面）
#   * doctor --fix 把 stale=down 修回 up（A.3.1 诚实分级）
#   * doctor --prune 不误删活隧道；对被杀死的 master 真 reap（删 stale control socket）
#   * remove -> 本地端口关闭 + control socket 删除 + master 退出 + 无残留 ssh
#     （t_no_zombie_ssh 口径：pgrep -f 'ssh.*herdr-forward'，排除自身祖先链）
#
# 前置：本机有 sshd（/usr/bin/sshd）、ssh-keygen、ssh-agent、python3、jq、go；端口
# 22111/23111 空闲。不参与 tests/run.sh（文件名不是 test_*.sh）—— 它是**证据复现脚本**，
# 与 difftest 组 9/10 的「纯 argv/CLI 对位」互补；需要 docker/bwrap 的完整 E2E 见 scripts/e2e。
#
# 用法：bash tests/difftest/phase2-go-path.sh
#
# lint 风格约定（沿用 scripts/e2e/run-inside.sh 的既定做法，shellcheck -S style 零告警）：
#   * 探测型函数不返回值，改写全局变量（避免函数出现在 if/&&/|| 条件里触发 SC2310）；
#   * 命令替换一律先落变量再断言（SC2312）。
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/hf-phase2-go.XXXXXX")"
ROOT="${SANDBOX}/staged"
MARKER="${SANDBOX}/marker.log"

export HERDR_PLUGIN_STATE_DIR="${SANDBOX}/state"
export HERDR_PLUGIN_CONFIG_DIR="${SANDBOX}/config"
export HOME="${SANDBOX}/home"
export GO_DISPATCH_MARKER="${MARKER}"
mkdir -p "${HERDR_PLUGIN_STATE_DIR}" "${HERDR_PLUGIN_CONFIG_DIR}" "${HOME}/.ssh" "${ROOT}/bin"
chmod 700 "${HOME}/.ssh"

SSHD_PORT=22111
ECHO_PORT=23111
PASS=0
FAIL=0
out=""
err=""
rc=0
ST_PID=""
ST_PID2=""
SSHD_PID=""
ECHO_PID=""
RESIDUE=0

ok() {
  printf 'ok   - %s\n' "$*"
  PASS=$((PASS + 1))
}
no() {
  printf 'FAIL - %s\n' "$*" >&2
  FAIL=$((FAIL + 1))
}
eq() {
  if [[ "${1}" == "${2}" ]]; then
    ok "${3}"
  else
    no "${3} (got [${1}] want [${2}])"
  fi
}

# run <cmd...>：捕获 stdout/stderr/rc，不打断 set -e
run() {
  set +e
  out="$("$@" 2>"${SANDBOX}/.err")"
  rc=$?
  set -e
  err="$(cat "${SANDBOX}/.err" 2>/dev/null || true)"
}

# state_field <jq filter>：读状态文件 -> 全局 sf
sf=""
state_field() {
  sf=""
  if [[ -f "${HERDR_PLUGIN_STATE_DIR}/forwards.json" ]]; then
    set +e
    sf="$(jq -r "$1" "${HERDR_PLUGIN_STATE_DIR}/forwards.json" 2>/dev/null)"
    set -e
  fi
}

# tcp_connected <port>：一次 TCP 三握手，结果写全局 TCP_OK
TCP_OK=0
tcp_connected() {
  TCP_OK=0
  if (exec 3<>"/dev/tcp/127.0.0.1/${1}") 2>/dev/null; then
    TCP_OK=1
  fi
}

# wait_port <port> [tries]：轮询等待端口可连，结果写全局 PORT_UP（恒 return 0）
PORT_UP=0
wait_port() {
  local port="$1" tries="${2:-40}" i=0
  PORT_UP=0
  for ((i = 0; i < tries; i++)); do
    tcp_connected "${port}"
    if [[ "${TCP_OK}" -eq 1 ]]; then
      PORT_UP=1
      return 0
    fi
    sleep 0.2
  done
  return 0
}

cleanup() {
  if [[ -n "${SSHD_PID}" ]]; then kill "${SSHD_PID}" 2>/dev/null || true; fi
  if [[ -n "${ECHO_PID}" ]]; then kill "${ECHO_PID}" 2>/dev/null || true; fi
  if [[ -n "${SSH_AGENT_PID:-}" ]]; then kill "${SSH_AGENT_PID}" 2>/dev/null || true; fi
  rm -rf "${SANDBOX}"
  return 0
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 0) staged root：bin/forward（真脚本）+ lib 符号链接 + forward-go 记录型 shim
#
# 为什么要 staged root 而不是直接调仓库根的 bin/forward：验收要证明「dispatch 到了 Go」，
# 而仓库根的 bin/forward-go 是构建产物（.gitignore），本脚本绝不往仓库 bin/ 写东西。
# shim 记录一行后 exec 真二进制 —— 行为与产物完全一致，只是多了一条可断言的痕迹。
# ---------------------------------------------------------------------------
cp "${REPO_ROOT}/bin/forward" "${ROOT}/bin/forward"
chmod +x "${ROOT}/bin/forward"
ln -sfn "${REPO_ROOT}/lib" "${ROOT}/lib"
(cd "${REPO_ROOT}/go" && GOFLAGS=-mod=vendor go build -o "${ROOT}/bin/forward-go.real" ./cmd/forward)
cat >"${ROOT}/bin/forward-go" <<'SHIM'
#!/bin/sh
# 记录型 shim（E2E 证据用）：记录调用后 exec 真二进制，行为与产物逐字节一致。
printf 'forward-go %s\n' "$*" >>"${GO_DISPATCH_MARKER:-/dev/null}"
exec "$(dirname "$0")/forward-go.real" "$@"
SHIM
chmod +x "${ROOT}/bin/forward-go"
FW="${ROOT}/bin/forward"

# ---------------------------------------------------------------------------
# 1) 真 sshd（用户态、仅 127.0.0.1）+ echo 服务
# ---------------------------------------------------------------------------
ssh-keygen -q -t ed25519 -N '' -f "${HOME}/.ssh/id_ed25519"
ssh-keygen -q -t ed25519 -N '' -f "${SANDBOX}/hostkey"
cp "${HOME}/.ssh/id_ed25519.pub" "${HOME}/.ssh/authorized_keys"
chmod 600 "${HOME}/.ssh/authorized_keys"
cat >"${SANDBOX}/sshd_config" <<EOF
Port ${SSHD_PORT}
ListenAddress 127.0.0.1
HostKey ${SANDBOX}/hostkey
PidFile ${SANDBOX}/sshd.pid
AuthorizedKeysFile ${HOME}/.ssh/authorized_keys
PasswordAuthentication no
PubkeyAuthentication yes
UsePAM no
StrictModes no
EOF
# 隧道 argv 带 `-F /dev/null`，ssh 按 **passwd home** 解析身份文件（不是 $HOME），
# 所以容器/宿主上的 key 必须由 ssh-agent 提供（与 scripts/e2e/run-inside.sh A2 段同一原因）。
run ssh-agent -a "${SANDBOX}/agent.sock" -s
eq "${rc}" "0" "ssh-agent 启动"
eval "${out}" >/dev/null 2>&1 || true
export SSH_AUTH_SOCK SSH_AGENT_PID
run ssh-add "${HOME}/.ssh/id_ed25519"
eq "${rc}" "0" "client key 已加入 agent"

/usr/bin/sshd -f "${SANDBOX}/sshd_config" -E "${SANDBOX}/sshd.log"
SSHD_PID="$(cat "${SANDBOX}/sshd.pid")"
python3 - "${ECHO_PORT}" <<'PY' &
import socket, sys
port = int(sys.argv[1])
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", port))
s.listen(8)
while True:
    c, _ = s.accept()
    data = c.recv(4096)
    c.sendall(data)
    c.close()
PY
ECHO_PID=$!
wait_port "${SSHD_PORT}"
eq "${PORT_UP}" "1" "sshd 端口 ${SSHD_PORT} 可 TCP 握手"
wait_port "${ECHO_PORT}"
eq "${PORT_UP}" "1" "echo 服务端口 ${ECHO_PORT} 可 TCP 握手"

E2E_USER="$(id -un)"
SSH_TARGET="${E2E_USER}@127.0.0.1:${SSHD_PORT}"

# ---------------------------------------------------------------------------
# 2) add 走 Go 路径起真隧道
# ---------------------------------------------------------------------------
LP=24111
run "${FW}" add "${LP}:${ECHO_PORT}" --ssh-target "${SSH_TARGET}"
eq "${rc}" "0" "add 退出 0（stderr：${err}）"
eq "${out}" "f-${LP}" "add stdout = id（Go 路径）"
if grep -q "forward-go add" "${MARKER}"; then
  ok "dispatch：add 交给了 Go"
else
  no "dispatch：add 未走 Go 实现"
fi
state_field '.forwards[0].status'
eq "${sf}" "up" "状态 status=up"
state_field '.forwards[0].pid'
ST_PID="${sf}"
alive=1
kill -0 "${ST_PID}" 2>/dev/null || alive=0
eq "${alive}" "1" "master pid ${ST_PID} 活着"
if [[ -S "${HERDR_PLUGIN_STATE_DIR}/ssh-ctl/ctl-f-${LP}" ]]; then
  ok "control socket 文件存在"
else
  no "control socket 缺失"
fi
if [[ -f "${HERDR_PLUGIN_STATE_DIR}/ssh-ctl/pid-f-${LP}" ]]; then
  ok "Go 写了 pid-<id>（tunnel_stop 的 pid 兜底线索）"
else
  no "pid-<id> 缺失"
fi

# ---------------------------------------------------------------------------
# 3) 数据面：经 ssh -L 的本地端口回环（无 nc 的环境用 bash /dev/tcp，口径等价）
# ---------------------------------------------------------------------------
run timeout 5 bash -c "exec 3<>/dev/tcp/127.0.0.1/${LP}; printf 'phase2-roundtrip\\n' >&3; head -1 <&3"
eq "${out}" "phase2-roundtrip" "经 ssh -L 回环收到远端 echo 回包"
run "${FW}" list --oneline
eq "${rc}" "0" "list --oneline 退出 0（Go）"
if [[ "${out}" == *"⇅${LP}"* ]]; then
  ok "list --oneline 含 ⇅${LP}"
else
  no "oneline 缺端口：${out}"
fi

# ---------------------------------------------------------------------------
# 4) doctor --fix 把 stale=down 修回 up（A.3.1 诚实分级）
# ---------------------------------------------------------------------------
jq '.forwards[0].status = "down"' "${HERDR_PLUGIN_STATE_DIR}/forwards.json" \
  >"${SANDBOX}/t.json"
mv "${SANDBOX}/t.json" "${HERDR_PLUGIN_STATE_DIR}/forwards.json"
run "${FW}" doctor --fix
eq "${rc}" "0" "doctor --fix 退出 0（报告：${out}）"
state_field '.forwards[0].status'
eq "${sf}" "up" "doctor --fix 把 down 修回 up"
if grep -q "forward-go doctor" "${MARKER}"; then
  ok "dispatch：doctor 交给了 Go"
else
  no "doctor 未走 Go 实现"
fi

# doctor --prune 不误删活隧道
run "${FW}" doctor --prune
eq "${rc}" "0" "doctor --prune 退出 0"
state_field '.forwards | length'
eq "${sf}" "1" "doctor --prune 保留活记录"

# ---------------------------------------------------------------------------
# 5) 真 reap：kill -9 master 留下 stale socket -> --prune 删记录并 reap socket
# ---------------------------------------------------------------------------
kill -9 "${ST_PID}" 2>/dev/null || true
sleep 0.6
if [[ -e "${HERDR_PLUGIN_STATE_DIR}/ssh-ctl/ctl-f-${LP}" ]]; then
  ok "stale control socket 已就位（前置条件）"
else
  no "前置条件不成立：stale control socket 不在"
fi
run "${FW}" doctor --prune
state_field '.forwards | length'
eq "${sf}" "0" "doctor --prune 清掉死记录"
if [[ -e "${HERDR_PLUGIN_STATE_DIR}/ssh-ctl/ctl-f-${LP}" ]]; then
  no "prune 未 reap stale control socket"
else
  ok "prune reap 掉 stale control socket"
fi

# ---------------------------------------------------------------------------
# 6) remove 走 Go：删记录 + 停隧道 + 无监听 + 无 control socket + 无残留 ssh
# ---------------------------------------------------------------------------
LP2=24112
run "${FW}" add "${LP2}:${ECHO_PORT}" --ssh-target "${SSH_TARGET}"
eq "${out}" "f-${LP2}" "第二条 add 就位"
state_field '.forwards[0].pid'
ST_PID2="${sf}"
run "${FW}" remove "f-${LP2}"
eq "${rc}" "0" "remove 退出 0"
if grep -q "forward-go remove" "${MARKER}"; then
  ok "dispatch：remove 交给了 Go"
else
  no "remove 未走 Go 实现"
fi
state_field '.forwards | length'
eq "${sf}" "0" "remove 删掉记录"
sleep 0.5
tcp_connected "${LP2}"
if [[ "${TCP_OK}" -eq 1 ]]; then
  no "remove 后端口仍可连"
else
  ok "remove 后本地端口已关闭"
fi
if [[ -e "${HERDR_PLUGIN_STATE_DIR}/ssh-ctl/ctl-f-${LP2}" ]]; then
  no "remove 后 control socket 仍在"
else
  ok "remove 后 control socket 已删"
fi
# 先落变量再断言（避免 SC2310：kill 出现在 if 条件里会让 set -e 失效）
killed=1
kill -0 "${ST_PID2}" 2>/dev/null || killed=0
if [[ "${killed}" -eq 1 ]]; then
  no "remove 后 master pid ${ST_PID2} 仍活着"
else
  ok "remove 后 master pid 已退出"
fi

# t_no_zombie_ssh 口径（tests/lib/assertions.sh）：pgrep -f 'ssh.*herdr-forward'，
# 但排除自身祖先链 —— 探测命令自己的命令行就含这个模式，否则是自匹配假阳性。
excluded=()
cur=$$
while [[ -n "${cur}" && "${cur}" != "0" ]]; do
  excluded+=("${cur}")
  [[ "${cur}" == "1" ]] && break
  cur="$(sed -n 's/^PPid:[[:space:]]*//p' "/proc/${cur}/status" 2>/dev/null | head -1 || true)"
  [[ -z "${cur}" ]] && break
done
RESIDUE=0
while IFS= read -r rp; do
  [[ -z "${rp}" ]] && continue
  skip=0
  for ex in "${excluded[@]}"; do
    if [[ "${rp}" == "${ex}" ]]; then skip=1; fi
  done
  if [[ "${skip}" -eq 0 ]]; then
    RESIDUE=$((RESIDUE + 1))
    printf '       residue pid: %s\n' "${rp}"
  fi
done < <(pgrep -f 'ssh.*herdr-forward' 2>/dev/null || true)
eq "${RESIDUE}" "0" "t_no_zombie_ssh 口径无残留（pgrep -f 'ssh.*herdr-forward'，排除祖先链）"

# ---------------------------------------------------------------------------
# 7) dispatch 边界：`add --client` 现已交给 Go（Phase 3 的迁移点）
#
# Phase 2 时这条路径留在 bash（client 映射的写侧依赖 lib/bridge.sh）；Phase 3 把桥接写侧
# 迁到 Go 后，显式 --client 也路由到 Go。证据：shim 的 marker 出现该次调用，且记录形态
# 与 bash 版一致（mode=client）。
# ---------------------------------------------------------------------------
CLIENT_PORT=24517
before="$(wc -l <"${MARKER}")"
run "${FW}" add "${CLIENT_PORT}" --client
after="$(wc -l <"${MARKER}")"
eq "${rc}" "0" "add --client 退出 0（Go 分支）"
eq "${out}" "f-${CLIENT_PORT}" "add --client stdout = id"
if [[ "${after}" -gt "${before}" ]]; then
  ok "dispatch：add --client 交给了 Go（Phase 3 迁移点）"
else
  no "dispatch：add --client 未走 Go 实现"
fi
state_field "[.forwards[] | select(.id == \"f-${CLIENT_PORT}\")][0].mode"
eq "${sf}" "client" "Go 已写入 mode=client 记录"

# ---------------------------------------------------------------------------
# 8) Phase 3 新增子命令整组走 Go：machines / bridge / open-url
#
# 证据：shim 的 marker 出现对应调用（machines list / bridge status / open-url）。
# 只跑**零副作用**的形态（list / status / help）；activate/doctor 会 ssh 到远端，
# 交给 tests/unit/test_machines_cmd.sh 与 integration/test_machines_probe.sh。
# ---------------------------------------------------------------------------
for migrated in "machines list --short" "bridge status" "machines help"; do
  read -r -a migrated_argv <<<"${migrated}"
  before="$(wc -l <"${MARKER}")"
  run timeout 20 "${FW}" "${migrated_argv[@]}"
  after="$(wc -l <"${MARKER}")"
  if [[ "${after}" -gt "${before}" ]]; then
    ok "migrated 子命令走 Go：${migrated}（rc=${rc}）"
  else
    no "migrated 子命令未走 Go：${migrated}（rc=${rc}）"
  fi
done

# open-url 无 client 在线时走本机浏览器（HERDR_FORWARD_OPENER 指到探针脚本），
# 本身不做任何写操作；这里只要求它被路由到 Go。
before="$(wc -l <"${MARKER}")"
run timeout 20 "${FW}" open-url "http://localhost:3000/x"
after="$(wc -l <"${MARKER}")"
if [[ "${after}" -gt "${before}" ]]; then
  ok "migrated 子命令走 Go：open-url（rc=${rc}）"
else
  no "migrated 子命令未走 Go：open-url（rc=${rc}）"
fi

# ---------------------------------------------------------------------------
# 9) 仍未迁移的子命令零变化：bootstrap 仍由 bash 处理
#
# `watch` 故意不做样本：非 TTY 下它 exec `watch -n 3 forward list`，嵌套的 list 本来就
# 应该走 Go（list 是已迁移的），marker 出现 GO 行是正确行为而不是回归。
# ---------------------------------------------------------------------------
for unmigrated in "bootstrap" "help"; do
  read -r -a unmigrated_argv <<<"${unmigrated}"
  before="$(wc -l <"${MARKER}")"
  run timeout 20 "${FW}" "${unmigrated_argv[@]}"
  after="$(wc -l <"${MARKER}")"
  eq "${before}" "${after}" "未迁移子命令留 bash：${unmigrated}（rc=${rc}，marker 无新增）"
done

# ---------------------------------------------------------------------------
# 汇总
# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "${PASS}" "${FAIL}"
if [[ "${FAIL}" -gt 0 ]]; then
  exit 1
fi
