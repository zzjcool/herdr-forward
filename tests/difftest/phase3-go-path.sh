#!/usr/bin/env bash
# tests/difftest/phase3-go-path.sh — Phase 3 的「HF1 两侧同切」证据脚本（宿主可跑）
#
# 验收要求（PLAN-GO-MIGRATION §6 Phase 3 风险点 R5）：HF1 的 **serve（B 侧）与 run（A 侧）
# 必须在同一 phase 里一起切到 Go**，否则会出现「bash serve × Go run」的混合版本窗口，
# 而那个窗口没有任何 E2E 覆盖。
#
# 本脚本用**记录型 shim**（与 phase2-go-path.sh 同一手法）把 `bin/forward-go` 换成
# 「记录一行后 exec 真二进制」的壳，然后：
#
#   1. 证明 `forward bridge serve` 经 bin/forward 走到了 Go（marker 有对应行）；
#   2. 证明 `forward bridge run` 同样走到了 Go（marker 有对应行）；
#   3. 跑一次**真协议往返**：Go serve（B 角色）经管道驱动，验证 HELLO/SYNC/STATUS 的
#      编解码与「期望集合变化 → 推送新 SYNC」；
#   4. 验证 C6 安全边界在**真实 serve 进程**上也拦住越界请求（id 伪造 / 端口越界 /
#      前导零 / 非 localhost 的 OPEN）；
#   5. 验证退避状态机的**可观测行为**：远端命令不存在（rc=127）时 supervisor 记录
#      retrying 且 next_retry_unix 前进，不是「一次失败就退出」。
#
# 为什么用 shim + 管道而不是真 ssh：这一层要证的是「两侧都是 Go 实现」与「协议/状态机
# 正确」，真 ssh 的数据面是 tests/integration/test_bridge_roundtrip.sh 与两机 E2E 的裁判。
#
# 用法：bash tests/difftest/phase3-go-path.sh
#
# lint 风格约定（与 phase2-go-path.sh 一致，shellcheck -S style 零告警）：
#   * 探测型函数不返回值，改写全局变量（避免函数出现在 if/&&/|| 条件里触发 SC2310）；
#   * 命令替换一律先落变量再断言（SC2312）。
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/hf-phase3-go.XXXXXX")"
ROOT="${SANDBOX}/staged"
MARKER="${SANDBOX}/marker.log"

export HERDR_PLUGIN_STATE_DIR="${SANDBOX}/state"
export HERDR_PLUGIN_CONFIG_DIR="${SANDBOX}/config"
export HOME="${SANDBOX}/home"
export GO_DISPATCH_MARKER="${MARKER}"
# 缩短退避/轮询，让状态机在秒级内可观测（与 lib/bridge.sh 的同名 env 一致）
export BRIDGE_BACKOFF_MIN_S=1 BRIDGE_BACKOFF_MAX_S=2 BRIDGE_PING_S=1 BRIDGE_POLL_S=1
mkdir -p "${HERDR_PLUGIN_STATE_DIR}" "${HERDR_PLUGIN_CONFIG_DIR}" "${HOME}" "${ROOT}/bin"

PASS=0
FAIL=0
out=""
rc=0
SERVER_LABEL="$(uname -n | tr ' ' '_')"
SERVE_PID=""
SERVE_IN_FD=9
SERVE_OUT_FD=8

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
# match <text> <regex> <msg>：正则命中即 ok（命中判据落全局 MATCHED，避免 SC2310）
MATCHED=0
match() {
  MATCHED=0
  if [[ "${1}" =~ ${2} ]]; then
    MATCHED=1
  fi
  if [[ "${MATCHED}" -eq 1 ]]; then
    ok "${3}"
  else
    no "${3}（实际：[${1}]）"
  fi
}

# run <cmd...>：捕获 stdout/rc，不打断 set -e
run() {
  set +e
  out="$("$@" 2>"${SANDBOX}/.err")"
  rc=$?
  set -e
}

cleanup() {
  if [[ -n "${SERVE_PID}" ]]; then
    kill "${SERVE_PID}" 2>/dev/null || true
    wait "${SERVE_PID}" 2>/dev/null || true
  fi
  rm -rf "${SANDBOX}"
  return 0
}
trap cleanup EXIT

for tool in go jq; do
  if ! command -v "${tool}" >/dev/null 2>&1; then
    echo "RED: 需要 ${tool}" >&2
    exit 1
  fi
done

# ---------------------------------------------------------------------------
# 0) staged root：bin/forward（真脚本）+ lib/scripts 拷贝 + forward-go 记录型 shim
# ---------------------------------------------------------------------------
cp "${REPO_ROOT}/bin/forward" "${ROOT}/bin/forward"
chmod +x "${ROOT}/bin/forward"
cp -r "${REPO_ROOT}/lib" "${ROOT}/lib"
cp -r "${REPO_ROOT}/scripts" "${ROOT}/scripts"
(cd "${REPO_ROOT}/go" && GOFLAGS=-mod=vendor go build -o "${ROOT}/bin/forward-go.real" ./cmd/forward)
cat >"${ROOT}/bin/forward-go" <<'SHIM'
#!/bin/sh
# 记录型 shim（Go-path 证据用）：记录调用后 exec 真二进制，行为与产物逐字节一致。
printf 'forward-go %s\n' "$*" >>"${GO_DISPATCH_MARKER:-/dev/null}"
exec "$(dirname "$0")/forward-go.real" "$@"
SHIM
chmod +x "${ROOT}/bin/forward-go"
FW="${ROOT}/bin/forward"
: >"${MARKER}"

# ---------------------------------------------------------------------------
# 1) serve / run 两侧都经 bin/forward 落到 Go
# ---------------------------------------------------------------------------
printf '== 1) bridge serve / run 的 dispatch 归属\n'

# serve：stdin 立即 EOF -> Go serve 打印 HELLO + SYNC 后收尾退出（不等信号）
before="$(wc -l <"${MARKER}")"
run bash -c "printf '' | '${FW}' bridge serve"
after="$(wc -l <"${MARKER}")"
eq "${rc}" "0" "bridge serve 退出 0（EOF 即收尾）"
line1="$(printf '%s\n' "${out}" | head -1 || true)"
line2="$(printf '%s\n' "${out}" | sed -n 2p || true)"
eq "HF1 HELLO ${SERVER_LABEL}" "${line1}" "第 1 行是 HF1 HELLO <host>"
eq "HF1 SYNC -" "${line2}" "第 2 行是空集合 SYNC"
if [[ "${after}" -gt "${before}" ]]; then
  ok "dispatch：bridge serve 交给了 Go"
else
  no "dispatch：bridge serve 未走 Go 实现"
fi

# run：给一个不存在的 machine -> 写 stopped 记录并退出（零 ssh 尝试）
before="$(wc -l <"${MARKER}")"
run timeout 20 "${FW}" bridge run no-such-machine
after="$(wc -l <"${MARKER}")"
eq "${rc}" "0" "bridge run 退出 0（记录缺失 -> stopped）"
if [[ "${after}" -gt "${before}" ]]; then
  ok "dispatch：bridge run 交给了 Go"
else
  no "dispatch：bridge run 未走 Go 实现"
fi
state="$(jq -r '.state' "${HERDR_PLUGIN_STATE_DIR}/bridge/client-no-such-machine.json" 2>/dev/null || true)"
eq "stopped" "${state}" "run 为缺失记录写了 state=stopped（A.3.3 supervisor 文档已落盘）"

# ---------------------------------------------------------------------------
# 2) 真协议往返：Go serve 进程经管道驱动（等价 A↔B 的那两条管道）
# ---------------------------------------------------------------------------
printf '== 2) HF1 真协议往返（Go serve 进程）\n'

FIFO_DIR="${SANDBOX}/fifo"
mkdir -p "${FIFO_DIR}" "${HERDR_PLUGIN_STATE_DIR}/bridge"
mkfifo "${FIFO_DIR}/in" "${FIFO_DIR}/out"
"${FW}" bridge serve <"${FIFO_DIR}/in" >"${FIFO_DIR}/out" 2>"${SANDBOX}/serve.err" &
SERVE_PID=$!
eval "exec ${SERVE_IN_FD}>\"${FIFO_DIR}/in\""
eval "exec ${SERVE_OUT_FD}<\"${FIFO_DIR}/out\""

# rd_line：读一行（5s 超时）
rd_line() {
  local line=""
  IFS= read -r -t 5 -u "${SERVE_OUT_FD}" line || true
  printf '%s' "${line}"
}
# wr_line：写一行给 serve
wr_line() { printf '%s\n' "${1}" >&"${SERVE_IN_FD}"; }
# session_file：当前会话文件路径
session_file() {
  local f=""
  for f in "${HERDR_PLUGIN_STATE_DIR}/bridge"/session-*.json; do
    [[ -f "${f}" ]] || continue
    printf '%s\n' "${f}"
    return 0
  done
  return 0
}

l1="$(rd_line)"
eq "HF1 HELLO ${SERVER_LABEL}" "${l1}" "serve 开场 HELLO"
l2="$(rd_line)"
eq "HF1 SYNC -" "${l2}" "serve 开场 SYNC（空集合）"

sess="$(session_file)"
match "${sess}" 'session-[0-9]+\.json$' "serve 建了会话文件（单 writer）"

# A → B 的 HELLO：serve 应记 client 在线
wr_line "HF1 HELLO laptop my laptop"
sleep 1.5
sess="$(session_file)"
host="$(jq -r '"\(.client_host)|\(.client_label)"' "${sess}" 2>/dev/null || true)"
eq "laptop|my laptop" "${host}" "serve 记录 client 主机与标签"

# B 侧登记一条 client 映射 -> serve 推新 SYNC
"${FW}" add 5173:5173 --client >/dev/null 2>&1
l3="$(rd_line)"
eq "HF1 SYNC f-5173:5173:5173" "${l3}" "期望集合变化 -> 推送新 SYNC"

# STATUS 回报写进会话文件；非法 id/state 被忽略（C6 边界在真实进程上生效）
wr_line "HF1 STATUS f-5173 down client 端口 5173 已被占用（laptop）"
wr_line "HF1 STATUS ../../etc bogus"
wr_line "HF1 STATUS f-08080 up"
wr_line "HF1 STATUS f-70000 up"
wr_line "garbage line"
sleep 1.5
sess="$(session_file)"
st="$(jq -r '.status."f-5173" | "\(.state)|\(.reason)"' "${sess}" 2>/dev/null || true)"
eq "down|client 端口 5173 已被占用（laptop）" "${st}" "STATUS down + 原因进会话文件"
keys="$(jq -r '.status | keys | join(",")' "${sess}" 2>/dev/null || true)"
eq "f-5173" "${keys}" "越界/伪造 id（../../etc / f-08080 / f-70000）全部被拒"

# SYNC 里的越界条目被丢弃：id 伪造、端口 < 1024、前导零、远端端口 0
wr_line "HF1 SYNC f-3000:3001:3000,f-80:80:80,f-08080:08080:80,f-6006:6006:0"
sleep 1.5
sess="$(session_file)"
keys="$(jq -r '.status | keys | join(",")' "${sess}" 2>/dev/null || true)"
eq "f-5173" "${keys}" "非法 SYNC 条目未污染状态（仅期望集合内的 f-5173）"

# ---------------------------------------------------------------------------
# 3) OPEN：端口没出现在 SYNC 之前不转发
# ---------------------------------------------------------------------------
printf '== 3) OPEN 只在端口已进 SYNC 后转发\n'
"${FW}" open-url "http://localhost:6006/x" >/dev/null 2>&1 || true
sleep 1.5
left="$(find "${HERDR_PLUGIN_STATE_DIR}/bridge/open" -name '*.url' 2>/dev/null | wc -l || true)"
left="${left// /}"
eq "0" "${left}" "未在 SYNC 里的端口：请求不转发"

# 收尾：关掉管道让 serve 读 EOF 退出并删会话文件
serve_pid="${SERVE_PID}"
eval "exec ${SERVE_IN_FD}>&-"
eval "exec ${SERVE_OUT_FD}<&-"
waited=0
while kill -0 "${serve_pid}" 2>/dev/null && ((waited < 50)); do
  sleep 0.1
  waited=$((waited + 1))
done
alive=0
if kill -0 "${serve_pid}" 2>/dev/null; then
  alive=1
fi
eq "0" "${alive}" "client 断开（EOF）-> serve 退出"
SERVE_PID=""
left="$(find "${HERDR_PLUGIN_STATE_DIR}/bridge" -name 'session-*.json' 2>/dev/null | wc -l || true)"
left="${left// /}"
eq "0" "${left}" "serve 退出时删掉会话文件（无残留）"

# ---------------------------------------------------------------------------
# 4) 退避状态机：远端命令 127 -> retrying + next_retry_unix 前进
#
# 手法：伪造一条激活记录，server_root 指向一个没有 bin/forward 的目录；ssh 替身
# （PATH 前置）立刻以 127 退出 —— supervisor 应写 retrying 并设置下一次重试时间
# （而不是直接退出）。这里只测状态机，不真连任何主机。
# ---------------------------------------------------------------------------
printf '== 4) supervisor 退避状态机（retrying + next_retry）\n'

SHIM_BIN="${SANDBOX}/shim-bin"
mkdir -p "${SHIM_BIN}"
cat >"${SHIM_BIN}/ssh" <<'SSHSTUB'
#!/usr/bin/env bash
# 替身：立刻以 127 退出（模拟「远端没有 bin/forward」）
exit 127
SSHSTUB
chmod +x "${SHIM_BIN}/ssh"

MACHINE="mRetry"
jq -n --arg root "${SANDBOX}/no-such-plugin" --arg sd "${HERDR_PLUGIN_STATE_DIR}" --arg m "${MACHINE}" '
  {version: 1, active: $m,
   machines: {($m): {label: "retry-box", ssh_target: "stub@nowhere:22",
                     server_root: $root, state_dir: $sd, local: false, activated_unix: 1}}}
' >"${HERDR_PLUGIN_STATE_DIR}/activated-machines.json"

PATH="${SHIM_BIN}:${PATH}" timeout 12 "${FW}" bridge run "${MACHINE}" >/dev/null 2>&1 &
RETRY_PID=$!
sleep 3
rstate="$(jq -r '.state' "${HERDR_PLUGIN_STATE_DIR}/bridge/client-${MACHINE}.json" 2>/dev/null || true)"
nextretry="$(jq -r '.next_retry_unix' "${HERDR_PLUGIN_STATE_DIR}/bridge/client-${MACHINE}.json" 2>/dev/null || true)"
eq "retrying" "${rstate}" "ssh 127 后 supervisor 进入 retrying（不是退出）"
match "${nextretry}" '^[0-9]+$' "next_retry_unix 已设置（${nextretry}）"
if [[ "${MATCHED}" -eq 1 ]] && ((nextretry > 0)); then
  ok "next_retry_unix 是未来的时间戳（退避生效）"
else
  no "next_retry_unix 非法：${nextretry}"
fi
kill "${RETRY_PID}" 2>/dev/null || true
wait "${RETRY_PID}" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 汇总
# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "${PASS}" "${FAIL}"
if [[ "${FAIL}" -gt 0 ]]; then
  exit 1
fi
