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
# 组 6/7/8：CLI 层差分（W4：list / ports / help）
#
# 与前 5 组的区别：前面比的是 internal 层函数（state/render/probe 的纯函数形态），
# 这里比的是**用户可见的 CLI 输出**（`bin/forward` vs Go 实现）。
#
# 两侧接线：
#   * Go 侧 = 编译真实 CLI（go/cmd/forward -> ${TMP}/forward-go），不是探针；
#   * bash 侧 = 把 bin/forward + lib/ 拷/链成「staged root」，**不带** forward-go，
#     于是同一份脚本走纯 bash 路径（`bin/forward` 只对 list|ports 做条件 exec）。
# 两者共享同一份状态目录内容（各自一份拷贝，避免相互写坏）。
# ===========================================================================
printf '=== 组 6/7/8：CLI 差分（list / ports / help） ===\n'

# --- Go CLI 构建（一次性） ---
CLI_GO="${TMP}/forward-go"
if ! (cd "${ROOT}/go" && GOFLAGS=-mod=vendor go build -o "${CLI_GO}" ./cmd/forward >"${TMP}/cli-build.log" 2>&1); then
  echo "RED: 无法编译 Go CLI（go/cmd/forward）。构建输出：" >&2
  cat "${TMP}/cli-build.log" >&2
  exit 1
fi
note "CLI 差分：Go 侧 = ${CLI_GO}（真实 go/cmd/forward）"

# --- bash 侧 staged root（只有 bash，绝不带 forward-go） ---
BASH_ROOT="${TMP}/bashroot"
mkdir -p "${BASH_ROOT}/bin"
cp "${ROOT}/bin/forward" "${BASH_ROOT}/bin/forward"
chmod +x "${BASH_ROOT}/bin/forward"
ln -sfn "${ROOT}/lib" "${BASH_ROOT}/lib"
if [[ -x "${BASH_ROOT}/bin/forward-go" ]]; then
  bad "staged bash root 里不应存在 bin/forward-go"
fi
note "CLI 差分：bash 侧 = ${BASH_ROOT}/bin/forward（staged，无 forward-go → 纯 bash）"

# ss/lsof 屏蔽农场：让 bash 的 ports_listening_json 与 Go 一样走 /proc（同源），
# 否则 bash 会用 ss 拿到进程名而 Go 拿不到（已知偏离，见 README）。
NO_SS_FARM="${TMP}/farm-noss"
mkdir -p "${NO_SS_FARM}"
for tool in bash sh jq awk mkdir rm mv mktemp dirname cat date tr sed grep head tail wc ls uname stat readlink chmod printf env sort sleep kill; do
  tool_path="$(command -v "${tool}" 2>/dev/null || true)"
  [[ -z "${tool_path}" ]] && continue
  ln -sf "${tool_path}" "${NO_SS_FARM}/${tool}"
done

# cli_go <state_dir> <args...>：跑 Go CLI
cli_go() {
  local st="$1"
  shift
  HERDR_PLUGIN_STATE_DIR="${st}" "${CLI_GO}" "$@"
}

# cli_bash <state_dir> <args...>：跑 staged bash CLI（PATH 里没有 ss/lsof → 走 /proc）
cli_bash() {
  local st="$1"
  shift
  HERDR_PLUGIN_STATE_DIR="${st}" env PATH="${NO_SS_FARM}" \
    bash "${BASH_ROOT}/bin/forward" "$@"
}

# strip_ts：把 log 行首的时间戳拿掉，便于比较 warn/error 文案（时间不可比）
strip_ts() { sed -E 's/^\[[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z\] //'; }

# cli_pair <name> <fixture|-> <setup_fn|-> <args...>
#   在各自的临时状态目录里铺同一份夹具，跑两侧，比 stdout + rc（+可选 stderr）。
#   参数里的 "-" 表示不铺状态文件（文件不存在）。
CLI_PAIR_STRICT_STDERR=0
cli_pair_stdout() {
  local name="$1" fixture="$2" setup="$3"
  shift 3
  local bst="${TMP}/cli-bash-state" gst="${TMP}/cli-go-state"
  rm -rf "${bst}" "${gst}"
  mkdir -p "${bst}/bridge" "${gst}/bridge"
  if [[ "${fixture}" != "-" ]]; then
    cp "${fixture}" "${bst}/forwards.json"
    cp "${fixture}" "${gst}/forwards.json"
  fi
  if [[ "${setup}" != "-" ]]; then
    "${setup}" "${bst}"
    "${setup}" "${gst}"
  fi
  capture cli_bash "${bst}" "$@"
  local b_out="${OUT}" b_err="${ERR}" b_rc="${RC}"
  capture cli_go "${gst}" "$@"
  local g_out="${OUT}" g_err="${ERR}" g_rc="${RC}"
  _eq "${name} 退出码（bash=${b_rc} go=${g_rc}）" "${b_rc}" "${g_rc}"
  _eq "${name} stdout 逐字节" "${b_out}" "${g_out}"
  if [[ "${CLI_PAIR_STRICT_STDERR}" -eq 1 ]]; then
    local b_err_clean="" g_err_clean=""
    b_err_clean="$(printf '%s' "${b_err}" | strip_ts)"
    g_err_clean="$(printf '%s' "${g_err}" | strip_ts)"
    _eq "${name} stderr（去时间戳）" "${b_err_clean}" "${g_err_clean}"
  fi
}

# --- 会话夹具 builders（在各自状态目录里造 session / client 文件） ---
#   ⚠ 会话存活判定用当前 shell 的 $$（staged bash 与 Go 都会 kill -0 它）。
#   BRIDGE_LIVE_WINDOW_S 放大到 3600，避免夹具铺设与执行之间跨过 20s 窗口。
export BRIDGE_LIVE_WINDOW_S=3600

setup_session_up() {
  local now=""
  now="$(date +%s)"
  printf '{"client_host":"laptop","client_label":"b-box","last_seen_unix":%s,"status":{"f-5173":{"state":"up","reason":""}}}\n' "${now}" >"$1/bridge/session-$$.json"
}
setup_session_down() {
  local now=""
  now="$(date +%s)"
  printf '{"client_host":"laptop","last_seen_unix":%s,"status":{"f-5173":{"state":"down","reason":"client 端口 5173 已被占用（laptop）"}}}\n' "${now}" >"$1/bridge/session-$$.json"
}
setup_session_nostatus() {
  local now=""
  now="$(date +%s)"
  printf '{"client_host":"laptop","last_seen_unix":%s}\n' "${now}" >"$1/bridge/session-$$.json"
}
setup_client_self() {
  printf '{"pid":%s,"machine":"web-box","label":"web-box-label","target":"u@web:22","state":"connected","forwards":{"f-8080":{"spec":"8080 80","state":"up","reason":""},"f-9090":{"spec":"9090 90","state":"down","reason":"remote busy"}}}\n' "$$" >"$1/bridge/client-web-box.json"
  mkdir -p "$1/bridge/client-web-box.lock"
  printf '%s\n' "$$" >"$1/bridge/client-web-box.lock/pid"
}

CLI_TWO="${OWN_FIXTURES}/full.two.json"
CLI_MIX="${OWN_FIXTURES}/mix.client.tunnel.json"
CLI_MANY="${OWN_FIXTURES}/many.up.json"
CLI_EMPTY="${FIXTURES}/forwards.empty.json"

# 组 6：list —— table / --json / --oneline × 多夹具（≥ 3×3）
for form in "" "--json" "--oneline"; do
  form_name="table"
  list_args=(list)
  if [[ "${form}" == "--json" ]]; then
    form_name="json"
    list_args=(list --json)
  fi
  if [[ "${form}" == "--oneline" ]]; then
    form_name="oneline"
    list_args=(list --oneline)
  fi
  cli_pair_stdout "list ${form_name} 双 tunnel" "${CLI_TWO}" - "${list_args[@]}"
  cli_pair_stdout "list ${form_name} 空状态" "${CLI_EMPTY}" - "${list_args[@]}"
  cli_pair_stdout "list ${form_name} 状态文件不存在" - - "${list_args[@]}"
  cli_pair_stdout "list ${form_name} client 离线(waiting)" "${CLI_MIX}" - "${list_args[@]}"
done

# client 在线（up / down / 未上报）与自机 bridge 行
cli_pair_stdout "list json client 在线 up" "${CLI_MIX}" setup_session_up list --json
cli_pair_stdout "list table client 在线 up" "${CLI_MIX}" setup_session_up list
cli_pair_stdout "list oneline client 在线 up" "${CLI_MIX}" setup_session_up list --oneline
cli_pair_stdout "list json client 在线 down" "${CLI_MIX}" setup_session_down list --json
cli_pair_stdout "list table client 在线 down" "${CLI_MIX}" setup_session_down list
cli_pair_stdout "list json client 在线未上报(pending)" "${CLI_MIX}" setup_session_nostatus list --json
cli_pair_stdout "list table 本机 bridge 行" "${CLI_MIX}" setup_client_self list
cli_pair_stdout "list json 本机 bridge 行" "${CLI_MIX}" setup_client_self list --json
cli_pair_stdout "list oneline 本机 bridge 行" "${CLI_MIX}" setup_client_self list --oneline

# >6 条 up -> oneline 截断 +N
cli_pair_stdout "list oneline >6 截断" "${CLI_MANY}" - list --oneline
cli_pair_stdout "list table 8 条" "${CLI_MANY}" - list

# FORWARD_STATE_VERSION=2：--json 的 version 字段
_cli_version_bash="${TMP}/cli-bash-state"
_cli_version_go="${TMP}/cli-go-state"
rm -rf "${_cli_version_bash}" "${_cli_version_go}"
mkdir -p "${_cli_version_bash}" "${_cli_version_go}"
cp "${CLI_TWO}" "${_cli_version_bash}/forwards.json"
cp "${CLI_TWO}" "${_cli_version_go}/forwards.json"
export FORWARD_STATE_VERSION=2
capture cli_bash "${_cli_version_bash}" list --json
b_v="${OUT}"
capture cli_go "${_cli_version_go}" list --json
_eq "list --json FORWARD_STATE_VERSION=2 逐字节" "${b_v}" "${OUT}"
unset FORWARD_STATE_VERSION

# 损坏状态（forwards 里有非对象元素）：bash 的 jq 报错 -> stdout 空/仅表头、rc 0
CORRUPT_FORWARDS="${TMP}/corrupt-forwards.json"
printf '{"version":1,"forwards":[5]}\n' >"${CORRUPT_FORWARDS}"
cli_pair_stdout "list json 损坏记录(stdout+rc)" "${CORRUPT_FORWARDS}" - list --json
cli_pair_stdout "list table 损坏记录(stdout+rc)" "${CORRUPT_FORWARDS}" - list
cli_pair_stdout "list oneline 损坏记录(stdout+rc)" "${CORRUPT_FORWARDS}" - list --oneline

# 参数错误：比 rc + 去时间戳的 stderr（warn/error 文案是用户可见契约）
CLI_PAIR_STRICT_STDERR=1
cli_pair_stdout "list --oneline --json 互斥" "${CLI_TWO}" - list --oneline --json
cli_pair_stdout "list --json --oneline 互斥" "${CLI_TWO}" - list --json --oneline
cli_pair_stdout "list 未知参数" "${CLI_TWO}" - list --wat
cli_pair_stdout "list 位置参数" "${CLI_TWO}" - list foo
cli_pair_stdout "ports 多余参数" "${CLI_TWO}" - ports extra
CLI_PAIR_STRICT_STDERR=0

# 组 7：ports —— table / --json（两侧都读 /proc；进程名可能随实际负载变动，失败重试一次）
#
# cli_pair_retry <name> <fixture> <with_client_map:0|1> <args...>
#   同 cli_pair_stdout，但在两侧不一致时**重试一次**（环境里监听端口集可能在两次
#   调用之间变化 —— 例如别的进程刚好关了一个监听）。
cli_pair_retry() {
  local name="$1" fixture="$2" with_client_map="$3"
  shift 3
  local attempt=1
  local b_out="" g_out="" b_rc="" g_rc=""
  while [[ "${attempt}" -le 2 ]]; do
    local bst="${TMP}/cli-bash-state" gst="${TMP}/cli-go-state"
    rm -rf "${bst}" "${gst}"
    mkdir -p "${bst}" "${gst}"
    if [[ "${fixture}" != "-" ]]; then
      cp "${fixture}" "${bst}/forwards.json"
      cp "${fixture}" "${gst}/forwards.json"
    fi
    if [[ "${with_client_map}" == "1" ]]; then
      setup_ports_state "${bst}" "${gst}"
    fi
    capture cli_bash "${bst}" "$@"
    b_out="${OUT}"
    b_rc="${RC}"
    capture cli_go "${gst}" "$@"
    g_out="${OUT}"
    g_rc="${RC}"
    if [[ "${b_out}" == "${g_out}" && "${b_rc}" == "${g_rc}" ]]; then
      break
    fi
    attempt=$((attempt + 1))
  done
  _eq "${name} 退出码（bash=${b_rc} go=${g_rc}）" "${b_rc}" "${g_rc}"
  _eq "${name} stdout 逐字节" "${b_out}" "${g_out}"
}

# setup_ports_state <bash_state_dir> <go_state_dir>：两侧各造一条 client 映射
#   （remote_port = 5173，本机常有一个监听；是否命中取决于环境，但两侧同源，仍等价）。
setup_ports_state() {
  local doc='{"version":1,"forwards":[{"control_socket":"","created_unix":1,"id":"f-5173","local_port":5173,"machine":"","mode":"client","pid":null,"publish":{"pid":null,"url":null,"started_unix":null},"remote_host":"localhost","remote_port":5173,"ssh_target":"","status":"up"}]}'
  printf '%s\n' "${doc}" >"$1/forwards.json"
  printf '%s\n' "${doc}" >"$2/forwards.json"
}

cli_pair_retry "ports table（ss 屏蔽，同读 /proc）" "${CLI_TWO}" 0 ports
cli_pair_retry "ports --json（ss 屏蔽，同读 /proc）" "${CLI_TWO}" 0 ports --json
cli_pair_retry "ports table（带 client 映射）" "${CLI_TWO}" 1 ports
cli_pair_retry "ports --json（带 client 映射）" "${CLI_TWO}" 1 ports --json
cli_pair_retry "ports --json extra 参数（rc 0）" "${CLI_TWO}" 0 ports --json extra

# 组 8：help —— 用户可见契约，逐字节
capture bash "${BASH_ROOT}/bin/forward" help
b_help="${OUT}"
capture "${CLI_GO}" help
g_help="${OUT}"
_eq "help stdout 逐字节（usage 文本冻结）" "${b_help}" "${g_help}"

# 未知子命令：bash 打印 usage + die 64；Go 侧同一个 dispatch 表应同形（stdout+rc）
_cli_unk_bash="${TMP}/cli-bash-state"
_cli_unk_go="${TMP}/cli-go-state"
rm -rf "${_cli_unk_bash}" "${_cli_unk_go}"
mkdir -p "${_cli_unk_bash}" "${_cli_unk_go}"
capture bash "${BASH_ROOT}/bin/forward" no-such-subcommand
b_unk_out="${OUT}"
b_unk_rc="${RC}"
b_unk_err="$(printf '%s' "${ERR}" | strip_ts)"
capture "${CLI_GO}" no-such-subcommand
g_unk_out="${OUT}"
g_unk_rc="${RC}"
g_unk_err="$(printf '%s' "${ERR}" | strip_ts)"
_eq "未知子命令 rc" "${b_unk_rc}" "${g_unk_rc}"
_eq "未知子命令 stdout（usage）逐字节" "${b_unk_out}" "${g_unk_out}"
_eq "未知子命令 stderr（去时间戳）" "${b_unk_err}" "${g_unk_err}"

# 缺子命令：bash 打 usage 到 stderr + die 64
capture bash "${BASH_ROOT}/bin/forward"
b_no_out="${OUT}"
b_no_rc="${RC}"
b_no_err="$(printf '%s' "${ERR}" | strip_ts)"
capture "${CLI_GO}"
g_no_out="${OUT}"
g_no_rc="${RC}"
g_no_err="$(printf '%s' "${ERR}" | strip_ts)"
_eq "缺子命令 rc" "${b_no_rc}" "${g_no_rc}"
_eq "缺子命令 stdout" "${b_no_out}" "${g_no_out}"
_eq "缺子命令 stderr（去时间戳）" "${b_no_err}" "${g_no_err}"

unset BRIDGE_LIVE_WINDOW_S

# ===========================================================================
# 组 9：CLI 差分（Phase 2：add / remove / doctor / publish / unpublish）
#
# 比对对象与组 6/7/8 相同（bash staged root vs 真 Go CLI），但额外：
#   * 两侧各自一份 HERDR_PLUGIN_CONFIG_DIR（machines.toml 解析不碰用户真实配置）；
#   * 落盘状态也纳入比较（created_unix 用 0 掩掉，因为两侧用不同的真实时钟）。
#
# ⚠ 真实隧道行为（起 ssh、-O exit、reap socket）不在本组：那是 E2E 的裁判。
#   这里只钉「参数校验 / 退出码 / 用户可见文案 / 状态字段变换」。
# ===========================================================================
printf '=== 组 9：CLI 差分（add / remove / doctor / publish / unpublish） ===\n'

cli_bash_cfg() {
  local st="$1"
  shift
  HERDR_PLUGIN_STATE_DIR="${st}" HERDR_PLUGIN_CONFIG_DIR="${st}/cfg" \
    env PATH="${NO_SS_FARM}" bash "${BASH_ROOT}/bin/forward" "$@"
}
cli_go_cfg() {
  local st="$1"
  shift
  HERDR_PLUGIN_STATE_DIR="${st}" HERDR_PLUGIN_CONFIG_DIR="${st}/cfg" "${CLI_GO}" "$@"
}

# masked_state <file> -> stdout: 把 created_unix 归零后的 jq -S -c 形态
masked_state() {
  jq -S -c '{version: (.version // 1), forwards: [(.forwards // [])[] | .created_unix = 0]}' "$1" 2>/dev/null || printf '<unreadable>'
}

# cli_pair_state <name> <fixture|-> <args...>
CLI9_STRICT_STDERR=0
cli_pair_state() {
  local name="$1" fixture="$2"
  shift 2
  local bst="${TMP}/cli9-bash-state" gst="${TMP}/cli9-go-state"
  rm -rf "${bst}" "${gst}"
  mkdir -p "${bst}/cfg" "${gst}/cfg" "${bst}/bridge" "${gst}/bridge"
  if [[ "${fixture}" != "-" ]]; then
    cp "${fixture}" "${bst}/forwards.json"
    cp "${fixture}" "${gst}/forwards.json"
  fi
  capture cli_bash_cfg "${bst}" "$@"
  local b_out="${OUT}" b_rc="${RC}" b_err="" g_out="" g_rc="" g_err=""
  b_err="$(printf '%s' "${ERR}" | strip_ts)"
  capture cli_go_cfg "${gst}" "$@"
  g_out="${OUT}"
  g_rc="${RC}"
  g_err="$(printf '%s' "${ERR}" | strip_ts)"
  # 两侧落盘状态（created_unix 掩掉）—— 先落变量再断言，避开 SC2312。
  local b_state="" g_state=""
  b_state="$(masked_state "${bst}/forwards.json")"
  g_state="$(masked_state "${gst}/forwards.json")"
  _eq "${name} 退出码（bash=${b_rc} go=${g_rc}）" "${b_rc}" "${g_rc}"
  _eq "${name} stdout 逐字节" "${b_out}" "${g_out}"
  if [[ "${CLI9_STRICT_STDERR}" -eq 1 ]]; then
    _eq "${name} stderr（去时间戳）" "${b_err}" "${g_err}"
  fi
  _eq "${name} 落盘状态（created_unix 掩掉）" \
    "${b_state}" "${g_state}"
}

CLI9_STRICT_STDERR=1
# add：参数校验与退出码（全部零副作用）
cli_pair_state "add 缺 spec" - add
cli_pair_state "add 非法 spec" - add 5173:x
cli_pair_state "add 非法 spec（多冒号）" - add 1:2:3
cli_pair_state "add 端口 0" - add 0
cli_pair_state "add 端口越界" - add 70000
cli_pair_state "add 未知参数" - add 5173 --wat
cli_pair_state "add 多余位置参数" - add 5173 5173
cli_pair_state "add 缺目标机器" - add 3000
cli_pair_state "add machine 无法解析" - add 3000 --machine nope
cli_pair_state "add --machine 缺值" - add 3000 --machine
cli_pair_state "add --ssh-target 缺值" - add 3000 --ssh-target
cli_pair_state "add client 端口 <1024" - add 80 --client
cli_pair_state "add client 互斥" - add 6000 --client --ssh-target u@h:22
cli_pair_state "add 隧道路径不可达（--client 路径写记录）" - add 5173 --client
CLI9_STRICT_STDERR=0

# remove：不存在的记录 / 参数错误 / 一期未实现
CLI9_STRICT_STDERR=1
cli_pair_state "remove 缺 id" "${CLI_TWO}" remove
cli_pair_state "remove 未知参数" "${CLI_TWO}" remove --wat
cli_pair_state "remove 多余参数" "${CLI_TWO}" remove f-3000 extra
cli_pair_state "remove 记录不存在" "${CLI_TWO}" remove f-nope
CLI9_STRICT_STDERR=0
cli_pair_state "remove --pick（exit 9）" "${CLI_TWO}" remove --pick
cli_pair_state "remove --all（exit 9）" "${CLI_TWO}" remove --all

# publish / unpublish：恒 exit 9（忽略参数）
cli_pair_state "publish（exit 9）" - publish 3000
cli_pair_state "publish 无参（exit 9）" - publish
cli_pair_state "publish 多余参数（exit 9）" - publish 3000 extra
cli_pair_state "unpublish（exit 9）" - unpublish
cli_pair_state "unpublish 带参（exit 9）" - unpublish 3000

# doctor：参数错误
CLI9_STRICT_STDERR=1
cli_pair_state "doctor 未知参数" "${CLI_TWO}" doctor --wat
cli_pair_state "doctor 位置参数" "${CLI_TWO}" doctor xyz
CLI9_STRICT_STDERR=0

# doctor：死记录（pid 不存在、端口无人监听）—— 报告 / --fix / --prune
DEAD_FIXTURE="${TMP}/cli9-dead.json"
cat >"${DEAD_FIXTURE}" <<JSON
{"version":1,"forwards":[
 {"control_socket":"","created_unix":1,"id":"f-45811","local_port":45811,"machine":"","mode":"tunnel","pid":999998,"publish":{"pid":null,"url":null,"started_unix":null},"remote_host":"127.0.0.1","remote_port":45811,"ssh_target":"u@h:22","status":"up"},
 {"control_socket":"","created_unix":1,"id":"f-45812","local_port":45812,"machine":"","mode":"tunnel","pid":999999,"publish":{"pid":null,"url":null,"started_unix":null},"remote_host":"127.0.0.1","remote_port":45812,"ssh_target":"u@h:22","status":"down"}
]}
JSON
cli_pair_state "doctor 报告（两条 down）" "${DEAD_FIXTURE}" doctor
cli_pair_state "doctor --fix（down 保持 down）" "${DEAD_FIXTURE}" doctor --fix
cli_pair_state "doctor --prune（清掉死记录）" "${DEAD_FIXTURE}" doctor --prune
cli_pair_state "doctor --fix --prune（prune 优先）" "${DEAD_FIXTURE}" doctor --fix --prune

# doctor：master 活着 + 真实监听 socket（组 3 起来的 reply/silent 服务）
if [[ -n "${REPLY_PORT}" && -n "${SILENT_PORT}" ]]; then
  LIVE_FIXTURE="${TMP}/cli9-live.json"
  printf '{"version":1,"forwards":[{"control_socket":"","created_unix":1,"id":"f-%s","local_port":%s,"machine":"","mode":"tunnel","pid":%s,"publish":{"pid":null,"url":null,"started_unix":null},"remote_host":"127.0.0.1","remote_port":%s,"ssh_target":"u@h:22","status":"up"},{"control_socket":"","created_unix":1,"id":"f-%s","local_port":%s,"machine":"","mode":"tunnel","pid":%s,"publish":{"pid":null,"url":null,"started_unix":null},"remote_host":"127.0.0.1","remote_port":%s,"ssh_target":"u@h:22","status":"up"}]}\n' \
    "${REPLY_PORT}" "${REPLY_PORT}" "$$" "${REPLY_PORT}" \
    "${SILENT_PORT}" "${SILENT_PORT}" "$$" "${SILENT_PORT}" >"${LIVE_FIXTURE}"
  cli_pair_state "doctor 报告（up + degraded）" "${LIVE_FIXTURE}" doctor
  cli_pair_state "doctor --fix（degraded -> down）" "${LIVE_FIXTURE}" doctor --fix

  # master 活着但 status=down（stale）-> --fix 修回 up
  STALE_FIXTURE="${TMP}/cli9-stale.json"
  jq -c '.forwards[0].status = "down"' "${LIVE_FIXTURE}" >"${STALE_FIXTURE}"
  cli_pair_state "doctor --fix（stale=down -> up）" "${STALE_FIXTURE}" doctor --fix
fi

# doctor：client 记录不参与隧道分级（两种 --fix/--prune 都不能碰）
CLIENT_FIXTURE="${TMP}/cli9-client.json"
cat >"${CLIENT_FIXTURE}" <<'JSON'
{"version":1,"forwards":[{"control_socket":"","created_unix":1,"id":"f-5173","local_port":5173,"machine":"","mode":"client","pid":null,"publish":{"pid":null,"url":null,"started_unix":null},"remote_host":"localhost","remote_port":5173,"ssh_target":"","status":"starting"}]}
JSON
cli_pair_state "doctor（仅 client 记录，waiting 行）" "${CLIENT_FIXTURE}" doctor
cli_pair_state "doctor --prune（client 记录不删）" "${CLIENT_FIXTURE}" doctor --prune
cli_pair_state "doctor --fix（client 记录不改）" "${CLIENT_FIXTURE}" doctor --fix

# ===========================================================================
# 组 10：tunnel ssh argv 逐行差分（lib/tunnel.sh vs internal/tunnel）
#
# Phase 2 的核心风险（PLAN §6）：ControlMaster option set 必须逐 flag 复刻。
# 这里用两侧的「纯 argv 拼装」入口（不 spawn ssh）逐行比对。
# ===========================================================================
printf '=== 组 10：tunnel ssh argv 差分 ===\n'

TUNNEL_ARG_STATE="${TMP}/cli10-state"
mkdir -p "${TUNNEL_ARG_STATE}"
tunnel_args_pair() {
  local name="$1" state="$2"
  shift 2
  mkdir -p "${state}"
  capture bash_side "${state}" tunnel-args "$@"
  local b_out="${OUT}" b_rc="${RC}"
  capture go_side "${state}" tunnel-args "$@"
  _eq "${name} argv 逐行" "${b_out}" "${OUT}"
  _eq "${name} rc" "${b_rc}" "${RC}"
}

tunnel_args_pair "argv 常规（显式端口）" "${TUNNEL_ARG_STATE}" f-3000 3000 127.0.0.1:8080 'user@host.example:2222'
tunnel_args_pair "argv 缺省端口 22" "${TUNNEL_ARG_STATE}" f-22 22 localhost:8000 'user@host'
tunnel_args_pair "argv 方括号 IPv6 + 端口" "${TUNNEL_ARG_STATE}" f-9000 9000 127.0.0.1:8080 'user@[::1]:2222'
tunnel_args_pair "argv 方括号 IPv6 无端口" "${TUNNEL_ARG_STATE}" f-9001 9001 127.0.0.1:8080 '[::1]'
tunnel_args_pair "argv 尾部冒号" "${TUNNEL_ARG_STATE}" f-9002 9002 127.0.0.1:8080 'user@host:'
tunnel_args_pair "argv 非数字端口后缀（不剥端口）" "${TUNNEL_ARG_STATE}" f-9003 9003 127.0.0.1:8080 'user@host:abc'
tunnel_args_pair "argv 远端规格随参数" "${TUNNEL_ARG_STATE}" f-5173 5173 '10.0.0.9:5173' 'bob@10.0.0.9:2200'

# state 目录名含 %（herdr 真实布局 zzjcool%3Aforward）：ControlPath/UserKnownHostsFile 的 %% 转义
TUNNEL_PCT_STATE="${TMP}/cli10-zzjcool%3Aforward"
tunnel_args_pair "argv state 目录含 %（percent 转义）" "${TUNNEL_PCT_STATE}" f-9000 9000 127.0.0.1:8080 'user@host'

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
