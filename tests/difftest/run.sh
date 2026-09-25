#!/usr/bin/env bash
# tests/difftest/run.sh — Bash ↔ Go 差分测试 harness（PLAN-GO-MIGRATION §6 Phase 1 / §10 W1）
#
# 目的：在**同一输入**上分别跑生产 bash 实现（lib/common.sh + lib/state.sh）与 Go
# 实现（internal/hfcommon + internal/state），把两边输出**逐字节**比对。这是 C4/R1
# 风险（jq → encoding/json 的输出漂移）的唯一实测防线，也是 Phase 1「切 list/ports
# 时行为零变化」的证据。
#
# 用法：bash tests/difftest/run.sh
#   退出码 0 = 全绿；1 = 有 FAIL；缺 jq/go 时显式 FAIL（不静默跳过）。
#
# 接线策略（为什么有两套 Go 调用形态）：
#   1. 若 bin/forward-go 已支持 `internal difftest selftest`（W4 把 dispatch 接上后），
#      优先用它 —— 被测的就是最终产物的同一条代码路径；
#   2. 否则回退到 W1 自带的开发驱动器（go/internal/difftest/cmd）：与 (1) 调用同一个
#      difftest.Main，结果等价，且不依赖 W4 的 writer 范围（见 PLAN §10 写冲突规则）。
set -Eeuo pipefail

DIFFTEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${DIFFTEST_DIR}/../.." && pwd)"
FIXTURES="${ROOT}/tests/fixtures"
OWN_FIXTURES="${DIFFTEST_DIR}/fixtures"

PASS=0
FAIL=0
FAILED_CASES=()

TMP="$(mktemp -d)"
SERVER_PIDS=()
cleanup() {
  # 先按登记 PID 收，再按临时目录路径兜底（防 start_server 在子 shell 里漏登记）。
  local p
  for p in "${SERVER_PIDS[@]:-}"; do
    if [[ -n "${p}" ]]; then
      kill "${p}" 2>/dev/null || true
    fi
  done
  pkill -f "${TMP}/difftest serve" 2>/dev/null || true
  pkill -f "${ROOT}/bin/forward-go internal difftest serve" 2>/dev/null || true
  rm -rf "${TMP}"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 断言与输出
# ---------------------------------------------------------------------------
note() { printf '# %s\n' "$*"; }
ok() {
  PASS=$((PASS + 1))
  printf 'ok %d - %s\n' "$((PASS + FAIL))" "${1}"
}
bad() {
  FAIL=$((FAIL + 1))
  FAILED_CASES+=("${1}")
  printf 'not ok %d - %s\n' "$((PASS + FAIL))" "${1}"
}

# _eq <name> <expected> <actual>
_eq() {
  local name="$1" want="$2" got="$3"
  if [[ "${want}" == "${got}" ]]; then
    ok "${name}"
  else
    bad "${name}"
    printf '#   want: %s\n#   got : %s\n' "${want}" "${got}" >&2
  fi
}

# _readfile <path>：文件内容 -> 全局 got（文件不存在则为空）。
# 采用「先落变量再断言」的仓库既定写法，避免 SC2312（命令替换掩盖 cat 退出码）。
get=""
_readfile() {
  get=""
  if [[ -f "${1-}" ]]; then
    get="$(cat "${1-}")"
  fi
}

# _eq_files <name> <fileA> <fileB>：两个文件内容逐字节比较
_eq_files() {
  local name="$1" fa="$2" fb="$3" va="" vb=""
  _readfile "${fa}"
  va="${get}"
  _readfile "${fb}"
  vb="${get}"
  if [[ "${va}" == "${vb}" ]]; then
    ok "${name}"
  else
    bad "${name}"
    printf '#   %s: %s\n#   %s: %s\n' "${fa}" "${va}" "${fb}" "${vb}" >&2
  fi
}

# ---------------------------------------------------------------------------
# 前置检查
# ---------------------------------------------------------------------------
if ! command -v jq >/dev/null 2>&1; then
  echo "RED: 差分测试需要 jq（bash 侧 state.sh 的硬依赖）。请安装：pacman -S jq / apt-get install jq" >&2
  exit 1
fi
if ! command -v go >/dev/null 2>&1; then
  echo "RED: 差分测试需要 go 工具链（编译 Go 侧探针）。见 https://go.dev/dl/" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Go 侧探针接线
# ---------------------------------------------------------------------------
GO_CMD=()
WIRED=""

# 形态 1：bin/forward-go 已接线（W4 交付后）
if [[ -x "${ROOT}/bin/forward-go" ]]; then
  if out="$("${ROOT}/bin/forward-go" internal difftest selftest 2>/dev/null)" && [[ "${out}" == "difftest-ok" ]]; then
    GO_CMD=("${ROOT}/bin/forward-go" internal difftest)
    WIRED="bin/forward-go internal difftest"
  fi
fi

# 形态 2：回退到 W1 的自带开发驱动器
if [[ -z "${WIRED}" ]]; then
  if ! (cd "${ROOT}/go" && GOFLAGS=-mod=vendor go build -o "${TMP}/difftest" ./internal/difftest/cmd >"${TMP}/build.log" 2>&1); then
    echo "RED: 无法编译 Go 差分探针（go/internal/difftest/cmd）。构建输出：" >&2
    cat "${TMP}/build.log" >&2
    exit 1
  fi
  GO_CMD=("${TMP}/difftest")
  WIRED="go/internal/difftest/cmd（开发驱动器）"
fi
note "Go 侧接线：${WIRED}"

# go <state_dir> <args...>：跑 Go 侧探针
#
# ⚠ 必须每次显式注入 HERDR_PLUGIN_STATE_DIR：否则 hfcommon.StateDir() 会回退到
# 真实用户的 ~/.local/state/herdr-forward，差分测试就会污染（并读错）宿主环境。
go_side() {
  local st="$1"
  shift
  HERDR_PLUGIN_STATE_DIR="${st}" "${GO_CMD[@]}" "$@"
}

# bash <state_dir> <args...>：跑 bash 侧对位入口
bash_side() {
  local st="$1"
  shift
  HERDR_PLUGIN_STATE_DIR="${st}" DIFFTEST_NOW_UNIX="${DIFFTEST_NOW_UNIX:-}" \
    bash "${DIFFTEST_DIR}/bashside.sh" "$@"
}

# normalize 把 stdin 的 forward 数组补全为 Go 冻结结构体的零值填充形态（jq）。
# 与 internal/state.Load 的归一化一一对应（见 bashside.sh 的 DIFFTEST_NORMALIZE）。
normalize_stream() { HERDR_PLUGIN_STATE_DIR="${TMP}" bash "${DIFFTEST_DIR}/bashside.sh" normalize; }

# 供两侧各用的独立状态目录（互不污染）
BASE_STATE="${TMP}/bash-state"
GO_STATE="${TMP}/go-state"
mkdir -p "${BASE_STATE}" "${GO_STATE}"

# seed <state_dir> <fixture>
seed() {
  local st="$1" fixture="$2"
  mkdir -p "${st}"
  rm -f "${st}/forwards.json"
  cp "${fixture}" "${st}/forwards.json"
}

# 跑一条子命令，stdout -> OUT，stderr -> ERR，rc -> RC（不因 set -e 中断）
OUT=""
ERR=""
RC=0
capture() {
  local errfile="${TMP}/stderr.$$"
  set +e
  OUT="$("$@" 2>"${errfile}")"
  RC=$?
  set -e
  ERR="$(cat "${errfile}" 2>/dev/null || true)"
  rm -f "${errfile}"
}

# ===========================================================================
# 组 1：state_load —— 5 个 fixture 上 bash state_load vs Go Load
#
# 比对方式：两侧都过一遍 normalize（Go 侧输出已归一，normalize 幂等），
# 再 jq -S -c 规范化比较。这样比的是「语义等价的记录集合」，
# 而把「bash 原样透传 vs Go 类型化补零」的已知差异（见 README「已知偏差」）
# 显式纳入归一化，不掩盖真正的字段错位。
# ===========================================================================
printf '=== 组 1：state_load（5 个 fixture） ===\n'
fixtures_list="$(find "${FIXTURES}" -maxdepth 1 -name 'forwards.*.json' | sort)"
while IFS= read -r fixture; do
  [[ -n "${fixture}" ]] || continue
  name="$(basename "${fixture}")"

  seed "${BASE_STATE}" "${fixture}"
  capture bash_side "${BASE_STATE}" load
  bash_norm="$(printf '%s' "${OUT}" | normalize_stream | jq -S -c '.')"

  seed "${GO_STATE}" "${fixture}"
  capture go_side "${GO_STATE}" state-load
  go_norm="$(printf '%s' "${OUT}" | jq -S -c '.')"

  _eq "state_load ${name}" "${bash_norm}" "${go_norm}"
done <<<"${fixtures_list}"

# 状态文件不存在
seed "${BASE_STATE}" "${FIXTURES}/forwards.empty.json"
rm -f "${BASE_STATE}/forwards.json"
capture bash_side "${BASE_STATE}" load
bash_norm="$(printf '%s' "${OUT}" | normalize_stream | jq -S -c '.')"
seed "${GO_STATE}" "${FIXTURES}/forwards.empty.json"
rm -f "${GO_STATE}/forwards.json"
_norm() { printf '%s' "$1" | jq -S -c '.'; }

capture go_side "${GO_STATE}" state-load
go_norm="$(_norm "${OUT}")"
_eq "state_load 文件不存在" "${bash_norm}" "${go_norm}"

# ===========================================================================
# 组 2：state_save 往返 —— Load → Save 的**逐字节**比对
#
# 这是 R1 的核心断言：Go 落的文件必须与 jq -S -c 的输出一个字节都不差
# （紧凑单行、键名字母序、publish 三 null、结尾单换行、600 权限）。
# ===========================================================================
printf '=== 组 2：state_save 往返（逐字节） ===\n'
for fixture in \
  "${FIXTURES}/forwards.empty.json" \
  "${FIXTURES}/forwards.valid.json" \
  "${FIXTURES}/forwards.multi.json" \
  "${FIXTURES}/forwards.missing_fields.json" \
  "${OWN_FIXTURES}/full.two.json"; do
  name="$(basename "${fixture}")"

  # bash：load -> normalize -> save（写 bash 状态目录）
  seed "${BASE_STATE}" "${fixture}"
  capture bash_side "${BASE_STATE}" load
  rm -f "${TMP}/norm.json" 2>/dev/null || true
  printf '%s' "${OUT}" | normalize_stream | jq -S -c '.' >"${TMP}/norm.json"
  capture bash_side "${BASE_STATE}" save "${TMP}/norm.json"
  if [[ "${RC}" -ne 0 ]]; then
    bad "state_save ${name}（bash save rc=${RC}: ${ERR}）"
    continue
  fi
  _readfile "${BASE_STATE}/forwards.json"
  bash_bytes="${get}"

  # go：load -> save（写 go 状态目录）
  seed "${GO_STATE}" "${fixture}"
  capture go_side "${GO_STATE}" state-load
  printf '%s' "${OUT}" >"${TMP}/go-array.json"
  capture go_side "${GO_STATE}" state-save "${TMP}/go-array.json"
  if [[ "${RC}" -ne 0 ]]; then
    bad "state_save ${name}（go save rc=${RC}: ${ERR}）"
    continue
  fi
  _readfile "${GO_STATE}/forwards.json"
  go_bytes="${get}"

  _eq "state_save ${name} 逐字节" "${bash_bytes}" "${go_bytes}"
done

# 权限：0600
seed "${GO_STATE}" "${FIXTURES}/forwards.valid.json"
capture go_side "${GO_STATE}" state-load
printf '%s' "${OUT}" >"${TMP}/go-array.json"
capture go_side "${GO_STATE}" state-save "${TMP}/go-array.json"
perm="?"
if [[ -f "${GO_STATE}/forwards.json" ]]; then
  perm="$(stat -c '%a' "${GO_STATE}/forwards.json" 2>/dev/null || true)"
fi
_eq "state_save 文件权限 0600" "600" "${perm}"

# ===========================================================================
# 组 3：probe_payload 三态（真实监听 socket，同一服务上跑两侧）
# ===========================================================================
printf '=== 组 3：probe_payload 三态 ===\n'

# start_server <reply|silent|close> -> 端口写入全局 SERVER_PORT（Go 侧 serve 用 :0 让内核分配）
#
# ⚠ 绝不能用 `PORT="$(start_server ...)"` 的形式调用：命令替换会把整个函数放进子
# shell，于是后台 serve 与其 PID 登记都留在子 shell 里 —— 子 shell 一退出进程就被
# 摘除父进程，EXIT 陷阱永远收不到它（首版就踩了这个坑，留下 21 个孤儿 serve）。
# 因此这里显式用全局变量回传，调用处以普通语句形式执行。
SERVER_PORT=""
start_server() {
  local mode="$1"
  local outfile="${TMP}/srv.${mode}.out"
  rm -f "${outfile}"
  go_side "${GO_STATE}" serve "${mode}" >"${outfile}" 2>"${TMP}/srv.${mode}.err" &
  SERVER_PIDS+=("$!")
  local i=""
  for ((i = 0; i < 100; i++)); do
    [[ -s "${outfile}" ]] && break
    sleep 0.1
  done
  SERVER_PORT="$(head -1 "${outfile}")"
}

probe_both() {
  local label="$1" port="$2" timeout_s="$3"
  capture bash_side "${BASE_STATE}" probe 127.0.0.1 "${port}" "${timeout_s}"
  local bash_h="${OUT}"
  capture go_side "${GO_STATE}" probe 127.0.0.1 "${port}" "${timeout_s}"
  local go_h="${OUT}"
  _eq "probe ${label}（bash=${bash_h} go=${go_h}）" "${bash_h}" "${go_h}"
  _eq "probe ${label} 期望 ${label}" "${label}" "${go_h}"
}

start_server reply
REPLY_PORT="${SERVER_PORT}"
start_server silent
SILENT_PORT="${SERVER_PORT}"
start_server close
CLOSE_PORT="${SERVER_PORT}"

if [[ -z "${REPLY_PORT}" || -z "${SILENT_PORT}" || -z "${CLOSE_PORT}" ]]; then
  bad "启动测试服务失败（reply=${REPLY_PORT} silent=${SILENT_PORT} close=${CLOSE_PORT}）"
else
  probe_both up "${REPLY_PORT}" 2
  probe_both degraded "${SILENT_PORT}" 1
  probe_both down "${CLOSE_PORT}" 2
fi

# 拒绝连接（选一个确认无人监听的端口）
DEAD_PORT=""
for ((candidate = 45900; candidate < 46000; candidate++)); do
  if ! (exec 3<>"/dev/tcp/127.0.0.1/${candidate}") 2>/dev/null; then
    DEAD_PORT="${candidate}"
    break
  fi
done
if [[ -z "${DEAD_PORT}" ]]; then
  bad "找不到空闲端口做拒连用例"
else
  capture bash_side "${BASE_STATE}" probe 127.0.0.1 "${DEAD_PORT}" 1
  bash_h="${OUT}"
  capture go_side "${GO_STATE}" probe 127.0.0.1 "${DEAD_PORT}" 1
  _eq "probe 拒连（bash=${bash_h} go=${OUT}）" "down" "${OUT}"
  _eq "probe 拒连两侧一致" "${bash_h}" "${OUT}"
fi

# ===========================================================================
# 组 4：状态写入（add / remove / set-status）—— 落盘字节 + 退出码
# ===========================================================================
printf '=== 组 4：状态写入（add / remove / set-status） ===\n'

# 固定 created_unix，让两侧字节可比（生产用 now_unix）
export DIFFTEST_NOW_UNIX=1790000000

# --- add：同一 record，两侧落盘应逐字节一致 ---
cat >"${TMP}/add-record.json" <<'JSON'
{"local_port":3000,"remote_host":"127.0.0.1","remote_port":9443,
 "machine":"gpu-box","ssh_target":"user@gpu-box.example.com:22",
 "pid":12345,"control_socket":"/home/u/.local/state/herdr-forward/ssh-ctl/ctl-f-3000",
 "status":"up","created_unix":1790000000}
JSON

seed "${BASE_STATE}" "${FIXTURES}/forwards.empty.json"
rm -f "${BASE_STATE}/forwards.json"
capture bash_side "${BASE_STATE}" add "${TMP}/add-record.json"
bash_rc="${RC}"
seed "${GO_STATE}" "${FIXTURES}/forwards.empty.json"
rm -f "${GO_STATE}/forwards.json"
capture go_side "${GO_STATE}" add "${TMP}/add-record.json"
go_rc="${RC}"
_eq "add 退出码" "${bash_rc}" "${go_rc}"
_eq_files "add 落盘逐字节" "${BASE_STATE}/forwards.json" "${GO_STATE}/forwards.json"

# --- add 重复端口：都应拒绝（rc 2）且不改文件 ---
_readfile "${BASE_STATE}/forwards.json"
before_bash="${get}"
_readfile "${GO_STATE}/forwards.json"
before_go="${get}"
capture bash_side "${BASE_STATE}" add "${TMP}/add-record.json"
bash_rc="${RC}"
capture go_side "${GO_STATE}" add "${TMP}/add-record.json"
go_rc="${RC}"
_eq "add 重复端口 rc（bash=${bash_rc} go=${go_rc}）" "2" "${go_rc}"
_eq "add 重复端口 bash rc" "2" "${bash_rc}"
_readfile "${BASE_STATE}/forwards.json"
_eq "add 重复端口不改 bash 文件" "${before_bash}" "${get}"
_readfile "${GO_STATE}/forwards.json"
_eq "add 重复端口不改 go 文件" "${before_go}" "${get}"

# ⚠ 组 4 的落盘比对一律用「schema 完整」的记录（带 mode）：
#   这是 bash 自己 add 出来的记录形态，也是生产里绝大多数记录。
#   「legacy 无 mode 记录」的既定偏差单独在组 5 断言（不在这里混入）。
SCHEMA_FIXTURE="${OWN_FIXTURES}/full.two.json"

# --- remove ---
seed "${BASE_STATE}" "${SCHEMA_FIXTURE}"
capture bash_side "${BASE_STATE}" remove f-5173
bash_rc="${RC}"
seed "${GO_STATE}" "${SCHEMA_FIXTURE}"
capture go_side "${GO_STATE}" remove f-5173
go_rc="${RC}"
_eq "remove rc" "${bash_rc}" "${go_rc}"
_eq_files "remove 落盘逐字节" "${BASE_STATE}/forwards.json" "${GO_STATE}/forwards.json"

# --- remove 不存在 ---
seed "${BASE_STATE}" "${SCHEMA_FIXTURE}"
capture bash_side "${BASE_STATE}" remove f-nope
bash_rc="${RC}"
seed "${GO_STATE}" "${SCHEMA_FIXTURE}"
capture go_side "${GO_STATE}" remove f-nope
go_rc="${RC}"
_eq "remove 不存在 rc（bash=${bash_rc} go=${go_rc}）" "3" "${go_rc}"
_eq "remove 不存在 bash rc" "3" "${bash_rc}"

# --- set-status ---
seed "${BASE_STATE}" "${SCHEMA_FIXTURE}"
capture bash_side "${BASE_STATE}" set-status f-3000 down
bash_rc="${RC}"
seed "${GO_STATE}" "${SCHEMA_FIXTURE}"
capture go_side "${GO_STATE}" set-status f-3000 down
go_rc="${RC}"
_eq "set-status rc" "${bash_rc}" "${go_rc}"
_eq_files "set-status 落盘逐字节" "${BASE_STATE}/forwards.json" "${GO_STATE}/forwards.json"

# --- set-status 非法值 ---
seed "${BASE_STATE}" "${SCHEMA_FIXTURE}"
capture bash_side "${BASE_STATE}" set-status f-3000 bogus
bash_rc="${RC}"
seed "${GO_STATE}" "${SCHEMA_FIXTURE}"
capture go_side "${GO_STATE}" set-status f-3000 bogus
go_rc="${RC}"
_eq "set-status 非法值 rc（bash=${bash_rc} go=${go_rc}）" "1" "${go_rc}"
_eq "set-status 非法值 bash rc" "1" "${bash_rc}"

# ===========================================================================
# 组 5：已知偏差（legacy 无 mode 记录）—— 显式钉住，防静默漂移
#
# PLAN §8 要求「旧记录缺 mode → 默认 tunnel」。Go 的冻结类型化模型会在写回时
# **物化** mode="tunnel"；bash 的 state_load 是原样透传，写回时不补 mode。
# 二者语义等价（消费侧统一 `jq '.mode // "tunnel"'`），但字节不同。
# 这里同时断言：① 偏差确实存在（形态符合预期）；② 归一化后语义完全一致。
# ===========================================================================
printf '=== 组 5：已知偏差（legacy 无 mode 记录） ===\n'

seed "${BASE_STATE}" "${FIXTURES}/forwards.multi.json"
capture bash_side "${BASE_STATE}" remove f-5173
_readfile "${BASE_STATE}/forwards.json"
bash_legacy="${get}"

seed "${GO_STATE}" "${FIXTURES}/forwards.multi.json"
capture go_side "${GO_STATE}" remove f-5173
_readfile "${GO_STATE}/forwards.json"
go_legacy="${get}"

# ① bash 写回不带 mode 键
if [[ "${bash_legacy}" == *'"mode"'* ]]; then
  bad "legacy：bash 写回应保持无 mode 键（形态变了？）"
else
  ok "legacy：bash 写回原样透传（无 mode 键）"
fi

# ② go 写回物化 mode=tunnel
if [[ "${go_legacy}" == *'"mode":"tunnel"'* ]]; then
  ok "legacy：go 写回物化 mode=tunnel（PLAN §8 旧记录兼容）"
else
  bad "legacy：go 写回应物化 mode=tunnel"
fi

# ③ 归一化后（消费侧视角）两侧语义逐字节一致
bash_sem="$(printf '%s' "${bash_legacy}" | jq -S -c '{version: .version, forwards: [.forwards[] | .mode = (.mode // "tunnel")]}')"
go_sem="$(printf '%s' "${go_legacy}" | jq -S -c '{version: .version, forwards: [.forwards[] | .mode = (.mode // "tunnel")]}')"
_eq "legacy：归一化后语义一致（消费侧等价）" "${bash_sem}" "${go_sem}"

# ④ 其它字段不得被 Go 写回改动（除 mode 外逐键一致）
bash_nomode="$(printf '%s' "${bash_legacy}" | jq -S -c '{version: .version, forwards: [.forwards[] | del(.mode)]}')"
go_nomode="$(printf '%s' "${go_legacy}" | jq -S -c '{version: .version, forwards: [.forwards[] | del(.mode)]}')"
_eq "legacy：除 mode 外其余字段逐键一致" "${bash_nomode}" "${go_nomode}"

unset DIFFTEST_NOW_UNIX

# ===========================================================================
# 汇总
# ===========================================================================
printf '1..%d\n' "$((PASS + FAIL))"
printf '# PASS: %d FAIL: %d\n' "${PASS}" "${FAIL}"
if [[ "${FAIL}" -gt 0 ]]; then
  printf '# RESULT: FAIL\n'
  printf '# 失败用例：\n' >&2
  printf '#   - %s\n' "${FAILED_CASES[@]}" >&2
  exit 1
fi
printf '# RESULT: PASS（bash 与 go 逐字节一致）\n'
# 末尾不再显式 exit 0：shellcheck 的 SC2317 会把「脚本末尾必然退出」误判成
# 前面的函数/陷阱不可达，隐式 0 退出既等价又保持 shellcheck 干净。
