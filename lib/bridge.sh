#!/usr/bin/env bash
# lib/bridge.sh — client（A）↔ server（B）桥接：让 B 上声明的端口映射落在 A 的 localhost。
#
# 为什么需要（herdr 执行模型，docs/ARCHITECTURE.md §A.3.3）：
#   A 经 saved machine 查看 B 时，插件 action / 面板 / tab bar command 全在 **B** 上执行，
#   而 B 碰不到 A 的端口。于是由 A 主动维持一条到 B 的 SSH 会话：
#     * 远端命令是 B 上的 `forward bridge serve`，会话的 stdin/stdout 即下面的行协议；
#     * 会话自身是 ControlMaster：A 收到 B 的期望集合后，用 `ssh -O forward/cancel` 在同一
#       条连接上增删 `-L localhost:<lp>:localhost:<rp>` —— 监听在 A，目标是 B 的 localhost。
#   会话结束 = master 退出 = 映射全部随之释放，不会留下孤儿隧道。
#
# 行协议（一行一条，空格分隔，首词恒为 HF1）：
#   B → A  HF1 HELLO <server-host>
#          HF1 SYNC <id:lp:rp,...|->      期望集合全量（启动时 + 每次变化时）
#          HF1 OPEN <url>                 请 A 打开浏览器（只接受已映射端口的 localhost URL）
#   A → B  HF1 HELLO <client-host> <client-label...>
#          HF1 STATUS <id> up|down [reason...]
#          HF1 PING                       心跳：B 据此判定 client 在线
#
# 安全边界（A 侧强制执行，B 越不过）：id 必须是 f-<lp>、A 侧端口 1024-65535、至多
#   BRIDGE_MAX_FORWARDS 条；绑定地址恒为 A 的 loopback，目标恒为 B 的 localhost。
#   B 因此既不能让 A 连向 A 侧网络，也不能把 A 的端口暴露到 A 的局域网。
#
# 状态文件：
#   B 侧  $(state_dir)/bridge/session-<serve pid>.json   每条 serve 一份（多 client 互不覆盖）
#   A 侧  $(state_dir)/bridge/client-<machine>.json      supervisor 状态 + 已生效映射
#         $(state_dir)/bridge/client-<machine>.lock/pid  单实例锁（mkdir 原子）
#
# 依赖 lib/common.sh（log/die/require_cmd/now_unix/atomic_write/probe_tcp/state_dir）、
# lib/state.sh（state_load）与 jq、ssh。
set -o errexit -o nounset -o pipefail

_BRIDGE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh disable=SC1091
source "${_BRIDGE_LIB_DIR}/common.sh"
if ! declare -F state_load >/dev/null 2>&1; then
  # shellcheck source=./state.sh disable=SC1091
  source "${_BRIDGE_LIB_DIR}/state.sh"
fi

# --- 常量（已定义则不覆盖：测试用更短的间隔） ---
if [[ -z ${BRIDGE_PROTO:-} ]]; then
  readonly BRIDGE_PROTO="HF1"
fi
if [[ -z ${BRIDGE_MAX_FORWARDS:-} ]]; then
  readonly BRIDGE_MAX_FORWARDS=32
fi
if [[ -z ${BRIDGE_MIN_LOCAL_PORT:-} ]]; then
  readonly BRIDGE_MIN_LOCAL_PORT=1024
fi
# B 侧：client 最后一次心跳距今不超过该秒数即视为在线
if [[ -z ${BRIDGE_LIVE_WINDOW_S:-} ]]; then
  readonly BRIDGE_LIVE_WINDOW_S=20
fi
# A → B 心跳间隔；B 侧会话文件至少按此频率刷新
if [[ -z ${BRIDGE_PING_S:-} ]]; then
  readonly BRIDGE_PING_S=5
fi
# B 侧检查期望集合 / A 侧检查停止信号的间隔
if [[ -z ${BRIDGE_POLL_S:-} ]]; then
  readonly BRIDGE_POLL_S=1
fi
if [[ -z ${BRIDGE_BACKOFF_MIN_S:-} ]]; then
  readonly BRIDGE_BACKOFF_MIN_S=2
fi
if [[ -z ${BRIDGE_BACKOFF_MAX_S:-} ]]; then
  readonly BRIDGE_BACKOFF_MAX_S=60
fi
# 一次连接存活超过该秒数才把退避重置为最小值（防止「连上即断」时狂刷重连）
if [[ -z ${BRIDGE_STABLE_S:-} ]]; then
  readonly BRIDGE_STABLE_S=60
fi
if [[ -z ${BRIDGE_SERVER_ALIVE_S:-} ]]; then
  readonly BRIDGE_SERVER_ALIVE_S=15
fi

# ---------------------------------------------------------------------------
# 路径
# ---------------------------------------------------------------------------

# bridge_dir -> stdout: $(state_dir)/bridge（首次使用时建 700 目录）
bridge_dir() {
  local dir=""
  dir="$(state_dir)/bridge"
  if [[ ! -d ${dir} ]]; then
    mkdir -p "${dir}"
    chmod 700 "${dir}" 2>/dev/null || true
  fi
  printf '%s\n' "${dir}"
}

# _bridge_safe_id <machine-id> -> stdout: 只含 [A-Za-z0-9_.-] 的文件名片段
_bridge_safe_id() {
  local raw="${1-}"
  printf '%s\n' "${raw//[^A-Za-z0-9_.-]/_}"
}

bridge_session_file() {
  local pid="${1-}"
  local dir=""
  dir="$(bridge_dir)"
  printf '%s\n' "${dir}/session-${pid}.json"
}

bridge_client_file() {
  local mid=""
  mid="$(_bridge_safe_id "${1-}")"
  local dir=""
  dir="$(bridge_dir)"
  printf '%s\n' "${dir}/client-${mid}.json"
}

bridge_client_lock() {
  local mid=""
  mid="$(_bridge_safe_id "${1-}")"
  local dir=""
  dir="$(bridge_dir)"
  printf '%s\n' "${dir}/client-${mid}.lock"
}

# bridge_client_log <machine> -> stdout: 该桥接最近一次连接的 ssh stderr（每次重连截断）
bridge_client_log() {
  local mid=""
  mid="$(_bridge_safe_id "${1-}")"
  local dir=""
  dir="$(bridge_dir)"
  printf '%s\n' "${dir}/client-${mid}.ssh.log"
}

# bridge_control_path <machine> -> stdout: 桥接 ControlMaster 的 socket 路径
#   Unix socket 路径上限约 104-108 字节，且 ssh 建 master 时会再追加 ~17 字节随机后缀，
#   state 目录较深时退到 ${TMPDIR:-/tmp}/hf-<uid>/。
bridge_control_path() {
  local mid=""
  mid="$(_bridge_safe_id "${1-}")"
  local dir=""
  dir="$(state_dir)/ssh-ctl"
  local path="${dir}/b-${mid:0:12}"
  if ((${#path} > 88)); then
    dir="${TMPDIR:-/tmp}/hf-${UID}"
    path="${dir}/b-${mid:0:12}"
  fi
  if [[ ! -d ${dir} ]]; then
    mkdir -p "${dir}"
    chmod 700 "${dir}" 2>/dev/null || true
  fi
  printf '%s\n' "${path}"
}

# _bridge_ssh_escape <path> -> stdout: % 翻倍（ssh 对 ControlPath 做 % token 展开，
#   而插件 state 目录名里就有 %3A）
_bridge_ssh_escape() {
  local path="${1-}"
  printf '%s\n' "${path//\%/%%}"
}

# _bridge_bounded <secs> <cmd...>：有 timeout 就限时执行（macOS 默认没有 timeout）
_bridge_bounded() {
  local secs="${1-}"
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "${secs}" "$@"
  else
    "$@"
  fi
}

# _bridge_ctl_exit <control_path>：请该 socket 上的 master 退出（socket 不存在则什么都不做）
_bridge_ctl_exit() {
  local ctl="${1-}"
  [[ -S ${ctl} ]] || return 0
  local ctl_ssh=""
  ctl_ssh="$(_bridge_ssh_escape "${ctl}")"
  local -a cmd=(ssh -F /dev/null -o BatchMode=yes -o "ControlPath=${ctl_ssh}" -O exit hf-bridge)
  if command -v timeout >/dev/null 2>&1; then
    timeout 5 "${cmd[@]}" >/dev/null 2>&1 || true
  else
    "${cmd[@]}" >/dev/null 2>&1 || true
  fi
  return 0
}

# _bridge_hostname -> stdout: 本机主机名（容器里可能没有 hostname 命令）
_bridge_hostname() {
  local name="${HOSTNAME:-}"
  if [[ -z ${name} ]]; then
    name="$(uname -n 2>/dev/null || true)"
  fi
  name="${name//[[:space:]]/_}"
  printf '%s\n' "${name:-unknown}"
}

# ---------------------------------------------------------------------------
# 协议（纯函数，单测覆盖）
# ---------------------------------------------------------------------------

# bridge_valid_entry <id> <local_port> <remote_port> -> stdout "yes"（合法）/ 空
#   无前导零（bash 算术会把 08 当八进制）；id 必须与本地端口一致（state.sh 的 id 规则）。
bridge_valid_entry() {
  local fid="${1-}"
  local lp="${2-}"
  local rp="${3-}"
  [[ ${lp} =~ ^[1-9][0-9]{0,4}$ && ${rp} =~ ^[1-9][0-9]{0,4}$ ]] || return 0
  ((lp >= BRIDGE_MIN_LOCAL_PORT && lp <= 65535)) || return 0
  ((rp <= 65535)) || return 0
  [[ ${fid} == "f-${lp}" ]] || return 0
  printf 'yes\n'
}

# bridge_fmt_sync <desired_json> -> stdout: "HF1 SYNC <id:lp:rp,...|->"
bridge_fmt_sync() {
  local json="${1:-[]}"
  local body=""
  body="$(printf '%s' "${json}" | jq -r '[.[] | "\(.id):\(.local_port):\(.remote_port)"] | join(",")' 2>/dev/null || true)"
  printf '%s SYNC %s\n' "${BRIDGE_PROTO}" "${body:--}"
}

# bridge_parse_sync <payload> -> stdout: "id lp rp" 每行一条
#   非法条目丢弃并 warn（绝不因 B 发来的坏数据中断桥接）；超过上限的部分截断。
bridge_parse_sync() {
  local payload="${1-}"
  [[ -n ${payload} && ${payload} != "-" ]] || return 0
  local -a items=()
  IFS=',' read -r -a items <<<"${payload}"
  local item="" fid="" lp="" rp="" ok=""
  local n=0
  for item in "${items[@]}"; do
    [[ -n ${item} ]] || continue
    fid=""
    lp=""
    rp=""
    IFS=':' read -r fid lp rp <<<"${item}"
    ok="$(bridge_valid_entry "${fid}" "${lp}" "${rp}")"
    if [[ ${ok} != "yes" ]]; then
      log warn "bridge: 忽略非法映射请求 '${item}'（要求 f-<lp>:<lp>:<rp>，本地端口 ${BRIDGE_MIN_LOCAL_PORT}-65535）。"
      continue
    fi
    if ((n >= BRIDGE_MAX_FORWARDS)); then
      log warn "bridge: 映射请求超过上限 ${BRIDGE_MAX_FORWARDS} 条，其余已忽略。"
      break
    fi
    printf '%s %s %s\n' "${fid}" "${lp}" "${rp}"
    n=$((n + 1))
  done
  return 0
}

# _bridge_sq <string> -> stdout: POSIX sh 单引号字面量（远端 shell 用）
_bridge_sq() {
  local s="${1-}"
  local q="'"
  local escaped="${s//${q}/${q}\\${q}${q}}"
  printf "'%s'\n" "${escaped}"
}

# bridge_remote_serve_cmd <remote_root> <remote_state_dir> -> stdout: 远端命令串
#   经 SSH 跑的不是 herdr 插件上下文，没有 HERDR_PLUGIN_STATE_DIR，必须显式带上 B 的
#   插件 state 目录（否则会落到 ~/.local/state/herdr-forward，与 B 的面板分叉）。
bridge_remote_serve_cmd() {
  local root="${1-}"
  local sdir="${2-}"
  local q_state="" q_bin=""
  q_state="$(_bridge_sq "HERDR_PLUGIN_STATE_DIR=${sdir}")"
  q_bin="$(_bridge_sq "${root}/bin/forward")"
  printf 'env %s %s bridge serve\n' "${q_state}" "${q_bin}"
}

# bridge_ssh_destination <target> -> stdout: ssh 可直接使用的目的地
#   herdr saved machine 的 target 形如 alias / user@host / ssh://user@host:port；
#   激活记录里也可能是 user@host:port。ssh 不认 host:port 形式，统一转成 ssh:// URI。
bridge_ssh_destination() {
  local target="${1-}"
  case "${target}" in
  [Ss][Ss][Hh]://*)
    printf '%s\n' "${target}"
    return 0
    ;;
  *) ;;
  esac
  if [[ ${target} =~ ^([^:@/]+@)?\[[0-9A-Fa-f:.]+\]:[0-9]+$ || ${target} =~ ^([^:@/]+@)?[^:@/\[]+:[0-9]+$ ]]; then
    printf 'ssh://%s\n' "${target}"
    return 0
  fi
  printf '%s\n' "${target}"
}

# bridge_ssh_args <control_path> -> stdout: 桥接 master 的 ssh 选项（每行一个 argv 元素）
#   刻意沿用用户的 ~/.ssh/config（saved machine 常是 Host 别名，要靠它的 HostName /
#   IdentityFile / ProxyJump），但把会改变信任边界的选项钉死：
#     ForwardAgent/ForwardX11 关（不把 A 的 agent / 显示暴露给 B）、ClearAllForwardings
#     （不带上用户为 B 配的 LocalForward/RemoteForward）、独立 ControlMaster/ControlPath。
#   HERDR_FORWARD_SSH_CONFIG：可选的 -F 配置文件（测试与自定义部署用）。
bridge_ssh_args() {
  local ctl="${1-}"
  local ctl_ssh=""
  ctl_ssh="$(_bridge_ssh_escape "${ctl}")"
  if [[ -n ${HERDR_FORWARD_SSH_CONFIG:-} ]]; then
    printf '%s\n' '-F' "${HERDR_FORWARD_SSH_CONFIG}"
  fi
  printf '%s\n' \
    '-T' \
    '-o' 'BatchMode=yes' \
    '-o' 'ConnectTimeout=10' \
    '-o' "ServerAliveInterval=${BRIDGE_SERVER_ALIVE_S}" \
    '-o' 'ServerAliveCountMax=3' \
    '-o' 'ControlMaster=yes' \
    '-o' 'ControlPersist=no' \
    '-o' "ControlPath=${ctl_ssh}" \
    '-o' 'ClearAllForwardings=yes' \
    '-o' 'ExitOnForwardFailure=no' \
    '-o' 'ForwardAgent=no' \
    '-o' 'ForwardX11=no' \
    '-o' 'PermitLocalCommand=no'
}

# ---------------------------------------------------------------------------
# B 侧：期望集合 + 会话存活
# ---------------------------------------------------------------------------

# bridge_desired_json -> stdout: [{id,local_port,remote_port}]（mode=client，本地端口升序）
bridge_desired_json() {
  local all=""
  all="$(state_load)"
  printf '%s' "${all}" | jq -c '[.[] | select(.mode == "client") | {id, local_port, remote_port}] | sort_by(.local_port)'
}

# bridge_sessions_json -> stdout: [{pid,client_host,client_label,started_unix,last_seen_unix,status,live}]
#   live = serve 进程还在 且 client 心跳在 BRIDGE_LIVE_WINDOW_S 秒内。
#   serve 被 SIGKILL 时 EXIT trap 来不及删会话文件：进程已死的文件顺手清掉。
bridge_sessions_json() {
  local dir=""
  dir="$(bridge_dir)"
  local now=""
  now="$(now_unix)"
  local -a docs=()
  local f="" pid="" doc="" seen="" live=""
  for f in "${dir}"/session-*.json; do
    [[ -f ${f} ]] || continue
    pid="${f##*/session-}"
    pid="${pid%.json}"
    [[ ${pid} =~ ^[0-9]+$ ]] || continue
    if ! kill -0 "${pid}" 2>/dev/null; then
      rm -f "${f}" 2>/dev/null || true
      continue
    fi
    doc="$(jq -c 'if type == "object" then . else empty end' "${f}" 2>/dev/null || true)"
    [[ -n ${doc} ]] || continue
    seen="$(printf '%s' "${doc}" | jq -r '.last_seen_unix // 0 | floor' 2>/dev/null || true)"
    [[ ${seen} =~ ^[0-9]+$ ]] || seen=0
    live="false"
    if ((now - seen <= BRIDGE_LIVE_WINDOW_S)); then
      live="true"
    fi
    docs+=("$(printf '%s' "${doc}" | jq -c --argjson live "${live}" --argjson pid "${pid}" '. + {pid: $pid, live: $live}')")
  done
  if ((${#docs[@]} == 0)); then
    printf '[]\n'
    return 0
  fi
  printf '%s\n' "${docs[@]}" | jq -c -s 'sort_by(.last_seen_unix) | reverse'
}

# bridge_live_status_json [sessions_json] -> stdout: {"<id>":{state,reason,client}}
#   只统计 live 会话；同一映射被多个 client 报告时 up 优先。
bridge_live_status_json() {
  local sessions="${1-}"
  if [[ -z ${sessions} ]]; then
    sessions="$(bridge_sessions_json)"
  fi
  printf '%s' "${sessions}" | jq -c '
    [ .[] | select(.live) | . as $s | (.status // {}) | to_entries[]
      | {id: .key, state: (.value.state // "down"), reason: (.value.reason // ""),
         client: ($s.client_host // "")} ]
    | group_by(.id)
    | map((map(select(.state == "up")) | first) // first)
    | map({key: .id, value: {state, reason, client}}) | from_entries
  '
}

# bridge_merge_live <forwards_json> [sessions_json] -> stdout: forwards 数组（client 映射带实时状态）
#   client 映射的 status：up/down = client 报告值；pending = client 在线但尚未报告；
#   waiting = 没有 client 连着（映射已登记，client 连上后自动生效）。tunnel 映射原样。
bridge_merge_live() {
  local forwards="${1:-[]}"
  local sessions="${2-}"
  if [[ -z ${sessions} ]]; then
    sessions="$(bridge_sessions_json)"
  fi
  local live=""
  live="$(bridge_live_status_json "${sessions}")"
  local any=""
  any="$(printf '%s' "${sessions}" | jq -r 'any(.[]; .live) | tostring')"
  printf '%s' "${forwards}" | jq -c --argjson live "${live}" --argjson any "${any:-false}" '
    map(if .mode == "client" then
          ($live[.id]) as $l
          | .status = (if $l then $l.state elif $any then "pending" else "waiting" end)
          | .status_reason = (if $l then $l.reason else "" end)
          | .client = (if $l then $l.client else "" end)
        else . end)
  '
}

# bridge_any_live [sessions_json] -> stdout "yes"（至少一个 client 在线）/ 空
bridge_any_live() {
  local sessions="${1-}"
  if [[ -z ${sessions} ]]; then
    sessions="$(bridge_sessions_json)"
  fi
  local any=""
  any="$(printf '%s' "${sessions}" | jq -r 'any(.[]; .live) | tostring' 2>/dev/null || true)"
  if [[ ${any} == "true" ]]; then
    printf 'yes\n'
  fi
  return 0
}

# bridge_enqueue_open <url>：交给在线 client 打开（serve 循环取走并转发 HF1 OPEN）
bridge_enqueue_open() {
  local url="${1-}"
  local dir=""
  dir="$(bridge_dir)/open"
  mkdir -p "${dir}"
  local now=""
  now="$(now_unix)"
  printf '%s\n' "${url}" | atomic_write "${dir}/${now}-${RANDOM}${RANDOM}.url" "${dir}"
}

# ---------------------------------------------------------------------------
# B 侧：serve 循环（stdin/stdout = 协议；由 A 经 SSH 启动）
# ---------------------------------------------------------------------------

_BRIDGE_SERVE_FILE=""

_bridge_serve_cleanup() {
  if [[ -n ${_BRIDGE_SERVE_FILE} ]]; then
    rm -f "${_BRIDGE_SERVE_FILE}" 2>/dev/null || true
  fi
}

# _bridge_serve_write：把 serve 的会话状态原子写盘（读 bridge_serve 的局部变量，动态作用域）
#   srv_state / srv_reason 以端口号为下标（映射 id 恒为 f-<端口>）：bash 3.2 没有关联数组。
_bridge_serve_write() {
  local rows="" k=""
  for k in "${!srv_state[@]}"; do
    rows+="f-${k}"$'\t'"${srv_state[k]}"$'\t'"${srv_reason[k]-}"$'\n'
  done
  local doc=""
  doc="$(printf '%s' "${rows}" | jq -R -s -c \
    --arg host "${srv_client_host}" --arg label "${srv_client_label}" \
    --arg server "${srv_host}" \
    --argjson started "${srv_started}" --argjson seen "${srv_last_seen}" '
      {client_host: $host, client_label: $label, server_host: $server,
       started_unix: $started, last_seen_unix: $seen,
       status: (split("\n") | map(select(length > 0) | split("\t"))
                | map({key: .[0], value: {state: .[1], reason: (.[2] // "")}}) | from_entries)}
    ')"
  printf '%s\n' "${doc}" | atomic_write "${_BRIDGE_SERVE_FILE}" "$(dirname "${_BRIDGE_SERVE_FILE}")"
}

# _bridge_serve_flush_opens：把排队的打开请求转给 client（rm 成功者独占，多 serve 不重发）
#   请求的端口必须已出现在最近一次发出的 SYNC 里才发：否则 client 会先收到 OPEN、
#   后收到含该端口的 SYNC，而 client 只肯打开已生效映射的端口。30 秒没轮上的请求作废。
_bridge_serve_flush_opens() {
  [[ -n ${srv_client_host} ]] || return 0
  local dir=""
  dir="$(bridge_dir)/open"
  [[ -d ${dir} ]] || return 0
  local f="" url="" stamp="" port=""
  local now=""
  now="$(now_unix)"
  for f in "${dir}"/*.url; do
    [[ -f ${f} ]] || continue
    url="$(<"${f}")"
    stamp="${f##*/}"
    stamp="${stamp%%-*}"
    if [[ ! ${stamp} =~ ^[0-9]+$ ]] || ((now - stamp > 30)); then
      rm -f "${f}" 2>/dev/null || true
      continue
    fi
    if [[ ! ${url} =~ ^https?://localhost:([0-9]{1,5})([/?#][^[:space:]]*)?$ ]]; then
      rm -f "${f}" 2>/dev/null || true
      continue
    fi
    port="${BASH_REMATCH[1]}"
    [[ ${last_sync} == *"f-${port}:"* ]] || continue
    rm "${f}" 2>/dev/null || continue
    printf '%s OPEN %s\n' "${BRIDGE_PROTO}" "${url}"
  done
  return 0
}

# bridge_serve：B 侧常驻循环。stdout 只写协议行（日志一律走 log → forward.log / stderr）。
bridge_serve() {
  require_cmd jq "桥接需要 jq。请在本机安装 jq 后重试。"
  local me="${BASHPID:-$$}"
  _BRIDGE_SERVE_FILE="$(bridge_session_file "${me}")"
  trap '_bridge_serve_cleanup' EXIT
  trap 'exit 0' TERM HUP INT PIPE

  local -a srv_state=()
  local -a srv_reason=()
  local srv_client_host=""
  local srv_client_label=""
  local srv_host=""
  srv_host="$(_bridge_hostname)"
  local srv_started=""
  srv_started="$(now_unix)"
  local srv_last_seen="${srv_started}"
  _bridge_serve_write
  local last_write="${srv_started}"
  local dirty=0

  printf '%s HELLO %s\n' "${BRIDGE_PROTO}" "${srv_host}"
  log info "bridge serve: 会话开始（pid=${me}）。"

  local desired="" sync="" last_sync="" line="" buf="" rrc=0 now="" read_at=0
  local verb="" rest="" fid="" st="" reason="" port=""
  local -a words=()
  while true; do
    set +o errexit
    desired="$(bridge_desired_json 2>/dev/null)"
    set -o errexit
    [[ -n ${desired} ]] || desired="[]"
    sync="$(bridge_fmt_sync "${desired}")"
    if [[ ${sync} != "${last_sync}" ]]; then
      printf '%s\n' "${sync}"
      last_sync="${sync}"
      # 已不在期望集合里的映射，其旧状态没有意义（否则会残留一条过期的 up）
      for port in "${!srv_state[@]}"; do
        if [[ ${sync} != *" f-${port}:"* && ${sync} != *",f-${port}:"* ]]; then
          unset "srv_state[${port}]" "srv_reason[${port}]"
          dirty=1
        fi
      done
    fi
    _bridge_serve_flush_opens

    line=""
    rrc=0
    read_at="${SECONDS}"
    IFS= read -r -t "${BRIDGE_POLL_S}" line || rrc=$?
    if ((rrc != 0)); then
      if ! hf_read_timed_out "${rrc}" "${read_at}" "${BRIDGE_POLL_S}"; then
        break # EOF：client 断开
      fi
      buf+="${line}" # 超时时 read 已消费的半行留到下次拼上
    else
      line="${buf}${line}"
      buf=""
      words=()
      IFS=' ' read -r -a words <<<"${line}"
      verb="${words[1]-}"
      now="$(now_unix)"
      if [[ ${words[0]-} == "${BRIDGE_PROTO}" ]]; then
        case "${verb}" in
        HELLO)
          srv_client_host="${words[2]-}"
          rest="${line#*HELLO }"
          rest="${rest#"${srv_client_host}"}"
          srv_client_label="${rest# }"
          srv_last_seen="${now}"
          dirty=1
          log info "bridge serve: client ${srv_client_host}（${srv_client_label}）已连接。"
          ;;
        STATUS)
          fid="${words[2]-}"
          st="${words[3]-}"
          reason="${line#*STATUS "${fid}" "${st}"}"
          reason="${reason# }"
          if [[ ${fid} =~ ^f-([1-9][0-9]{0,4})$ && (${st} == "up" || ${st} == "down") ]]; then
            port="${BASH_REMATCH[1]}"
            if ((port <= 65535)); then
              srv_state[port]="${st}"
              srv_reason[port]="${reason:0:200}"
              dirty=1
            fi
          fi
          srv_last_seen="${now}"
          ;;
        PING)
          srv_last_seen="${now}"
          ;;
        *)
          log warn "bridge serve: 忽略未知协议行：${line:0:120}"
          ;;
        esac
      fi
    fi

    now="$(now_unix)"
    if ((dirty == 1 || now - last_write >= BRIDGE_PING_S)); then
      _bridge_serve_write
      last_write="${now}"
      dirty=0
    fi
  done
  log info "bridge serve: client 断开，会话结束（pid=${me}）。"
  return 0
}

# ---------------------------------------------------------------------------
# A 侧：supervisor（一台机器一个；断线指数退避重连）
# ---------------------------------------------------------------------------

# bridge_machine_record <machine> -> stdout: 激活记录 JSON（无则空）
#   直接读 activated-machines.json（与 lib/machines.sh 同一文件，只读），不依赖 machines.sh。
bridge_machine_record() {
  local mid="${1-}"
  local file=""
  file="$(state_dir)/activated-machines.json"
  [[ -f ${file} ]] || return 0
  jq -c --arg id "${mid}" '.machines[$id] // empty' "${file}" 2>/dev/null || true
}

# _bridge_lock_holder <machine> -> stdout: 持锁 supervisor 的 pid（活着才输出）
_bridge_lock_holder() {
  local lock=""
  lock="$(bridge_client_lock "${1-}")"
  [[ -f "${lock}/pid" ]] || return 0
  local pid=""
  pid="$(<"${lock}/pid")"
  if [[ ${pid} =~ ^[0-9]+$ ]] && kill -0 "${pid}" 2>/dev/null; then
    printf '%s\n' "${pid}"
  fi
  return 0
}

# bridge_running <machine> -> stdout "yes"（supervisor 活着）/ 空
bridge_running() {
  local holder=""
  holder="$(_bridge_lock_holder "${1-}")"
  if [[ -n ${holder} ]]; then
    printf 'yes\n'
  fi
  return 0
}

# _bridge_lock_acquire <machine> <pid> -> stdout "ok" / "busy"
#   mkdir 原子：并发的两个 `bridge up` 只有一个能拿到；持锁进程已死则回收。
_bridge_lock_acquire() {
  local mid="${1-}"
  local me="${2-}"
  local lock=""
  lock="$(bridge_client_lock "${mid}")"
  local tries=0 holder=""
  while ((tries < 3)); do
    if mkdir "${lock}" 2>/dev/null; then
      printf '%s\n' "${me}" >"${lock}/pid"
      printf 'ok\n'
      return 0
    fi
    holder="$(_bridge_lock_holder "${mid}")"
    if [[ -n ${holder} && ${holder} != "${me}" ]]; then
      printf 'busy\n'
      return 0
    fi
    rm -rf "${lock}" 2>/dev/null || true
    tries=$((tries + 1))
  done
  printf 'busy\n'
}

# _bridge_client_write <state> [reason]：supervisor 状态原子写盘（读 bridge_run 的局部变量）
#   cl_spec / cl_status / cl_reason 以 A 侧端口号为下标（映射 id 恒为 f-<端口>）。
_bridge_client_write() {
  local state="${1-}"
  local reason="${2-}"
  local rows="" k=""
  for k in "${!cl_status[@]}"; do
    rows+="f-${k}"$'\t'"${cl_spec[k]-}"$'\t'"${cl_status[k]}"$'\t'"${cl_reason[k]-}"$'\n'
  done
  local now=""
  now="$(now_unix)"
  local doc=""
  doc="$(printf '%s' "${rows}" | jq -R -s -c \
    --argjson pid "${cl_pid}" --arg machine "${cl_mid}" --arg label "${cl_label}" \
    --arg target "${cl_target}" --arg server "${cl_server_host}" \
    --arg state "${state}" --arg reason "${reason}" \
    --argjson now "${now}" --argjson since "${cl_since}" --argjson retry "${cl_next_retry}" '
      {pid: $pid, machine: $machine, label: $label, target: $target, server_host: $server,
       state: $state, reason: $reason, since_unix: $since, updated_unix: $now,
       next_retry_unix: (if $retry > 0 then $retry else null end),
       forwards: (split("\n") | map(select(length > 0) | split("\t"))
                  | map({key: .[0], value: {spec: .[1], state: .[2], reason: (.[3] // "")}})
                  | from_entries)}
    ')"
  local file=""
  file="$(bridge_client_file "${cl_mid}")"
  printf '%s\n' "${doc}" | atomic_write "${file}" "$(dirname "${file}")"
}

# _bridge_mux <control_path> <forward|cancel> <local_port> <remote_port> -> 0 成功 / 非 0 + stdout 原因
_bridge_mux() {
  local ctl="${1-}"
  local op="${2-}"
  local lp="${3-}"
  local rp="${4-}"
  local ctl_ssh=""
  ctl_ssh="$(_bridge_ssh_escape "${ctl}")"
  local out=""
  local rc=0
  set +o errexit
  out="$(_bridge_bounded 10 ssh -F /dev/null -o BatchMode=yes -o "ControlPath=${ctl_ssh}" \
    -O "${op}" -L "localhost:${lp}:localhost:${rp}" hf-bridge 2>&1)"
  rc=$?
  set -o errexit
  if ((rc != 0)); then
    out="${out//$'\n'/ }"
    printf '%s\n' "${out:0:160}"
  fi
  return "${rc}"
}

# 会话 fd：_BRIDGE_FD_IN 读 ssh 的 stdout，_BRIDGE_FD_OUT 写 ssh 的 stdin。
#   固定编号而非 {fd} 自动分配（bash 3.2 没有）；supervisor 进程里没有别的代码用 7/8。
_BRIDGE_FD_IN=7
_BRIDGE_FD_OUT=8

# _bridge_send <line>：写给 B（写失败 = 会话已断，由读循环在下一轮发现 EOF）
_bridge_send() {
  printf '%s\n' "${1-}" 1>&"${_BRIDGE_FD_OUT}" 2>/dev/null || true
}

# _bridge_reconcile <sync-payload>：把 A 上已生效的映射对齐到 B 的期望集合
#   与 _bridge_apply_one / _bridge_retry_failed 一样只在 bridge_run 的循环里调用
#   （那里 errexit 已关），失败一律按返回码处理并报告给 B。
_bridge_reconcile() {
  local payload="${1-}"
  local parsed=""
  parsed="$(bridge_parse_sync "${payload}")"
  # bridge_parse_sync 已校验：id 恒为 f-<lp>，lp 无前导零且 ≤ 65535，可直接当数组下标
  local -a want=()
  local fid="" lp="" rp="" k=""
  while IFS=' ' read -r fid lp rp; do
    [[ -n ${fid} ]] || continue
    want[lp]="${lp} ${rp}"
  done <<<"${parsed}"

  local why=""
  for k in "${!cl_spec[@]}"; do
    if [[ ${want[k]-} != "${cl_spec[k]}" ]]; then
      if [[ ${cl_status[k]-} == "up" ]]; then
        IFS=' ' read -r lp rp <<<"${cl_spec[k]}"
        why="$(_bridge_mux "${cl_ctl}" cancel "${lp}" "${rp}")"
        log info "bridge ${cl_mid}: 已撤销 localhost:${lp} → ${cl_label}:${rp}${why:+（${why}）}"
      fi
      unset "cl_spec[${k}]" "cl_status[${k}]" "cl_reason[${k}]"
    fi
  done

  for k in "${!want[@]}"; do
    [[ -z ${cl_spec[k]-} ]] || continue
    cl_spec[k]="${want[k]}"
    _bridge_apply_one "${k}"
  done
  _bridge_client_write connected
}

# _bridge_apply_one <local_port>：按 cl_spec 在 master 上开一条 -L，并把结果报告给 B
_bridge_apply_one() {
  local k="${1-}"
  local lp="" rp=""
  IFS=' ' read -r lp rp <<<"${cl_spec[k]}"
  local busy=""
  busy="$(probe_tcp 127.0.0.1 "${lp}" 1)"
  if [[ ${busy} == "ok" ]]; then
    cl_status[k]="down"
    cl_reason[k]="client 端口 ${lp} 已被占用（${cl_host}）"
    _bridge_send "${BRIDGE_PROTO} STATUS f-${k} down ${cl_reason[k]}"
    return 0
  fi
  local why="" rc=0
  why="$(_bridge_mux "${cl_ctl}" forward "${lp}" "${rp}")"
  rc=$?
  if ((rc == 0)); then
    cl_status[k]="up"
    cl_reason[k]=""
    _bridge_send "${BRIDGE_PROTO} STATUS f-${k} up"
    log info "bridge ${cl_mid}: localhost:${lp} → ${cl_label}:${rp} 已生效。"
  else
    cl_status[k]="down"
    cl_reason[k]="ssh 拒绝转发：${why:-rc=${rc}}"
    _bridge_send "${BRIDGE_PROTO} STATUS f-${k} down ${cl_reason[k]}"
  fi
  return 0
}

# _bridge_retry_failed：重试 down 的映射（端口被短暂占用、旧 master 尚未释放等会自愈）
_bridge_retry_failed() {
  local k="" changed=0
  for k in "${!cl_status[@]}"; do
    [[ ${cl_status[k]} == "down" ]] || continue
    _bridge_apply_one "${k}"
    changed=1
  done
  if ((changed == 1)); then
    _bridge_client_write connected
  fi
  return 0
}

# _bridge_open_url <url>：只打开「已生效映射端口」的 localhost URL（防 B 借机让 A 打开任意地址）
_bridge_open_url() {
  local url="${1-}"
  if [[ ! ${url} =~ ^https?://(localhost|127\.0\.0\.1)(:([0-9]{1,5}))?([/?#][^[:space:]]*)?$ ]]; then
    log warn "bridge ${cl_mid}: 拒绝打开非 localhost URL：${url:0:120}"
    return 0
  fi
  local port="${BASH_REMATCH[3]}"
  if [[ -z ${port} ]]; then
    port=80
    [[ ${url} == https://* ]] && port=443
  fi
  # 端口要当数组下标（算术求值）：前导零会按八进制解析，先挡掉
  if [[ ! ${port} =~ ^[1-9][0-9]*$ ]] || ((port > 65535)) || [[ ${cl_status[port]-} != "up" ]]; then
    log warn "bridge ${cl_mid}: 拒绝打开 ${url:0:120}（端口 ${port} 不是本桥接已生效的映射）。"
    return 0
  fi
  local opener="${HERDR_FORWARD_OPENER:-}"
  if [[ -z ${opener} ]]; then
    if command -v xdg-open >/dev/null 2>&1; then
      opener="xdg-open"
    elif command -v open >/dev/null 2>&1; then
      opener="open"
    else
      log warn "bridge ${cl_mid}: 本机没有 xdg-open/open，无法打开 ${url}。"
      return 0
    fi
  fi
  log info "bridge ${cl_mid}: 打开 ${url}"
  # 关掉会话 fd：浏览器等长寿子进程若继承了 ssh stdin 的写端，会话就收不到 EOF
  hf_detach_exec "${opener}" "${url}" </dev/null >/dev/null 2>&1 7<&- 8>&- &
  disown "$!" 2>/dev/null || true
  return 0
}

# _bridge_connect_once：建一条会话并跑到它结束；stdout 恒空，返回 ssh 的退出码
_bridge_connect_once() {
  local dest="" remote=""
  dest="$(bridge_ssh_destination "${cl_target}")"
  remote="$(bridge_remote_serve_cmd "${cl_root}" "${cl_rstate}")"
  local args_raw=""
  args_raw="$(bridge_ssh_args "${cl_ctl}")"
  local -a args=()
  local arg=""
  while IFS= read -r arg; do
    args+=("${arg}")
  done <<<"${args_raw}"
  local errlog=""
  errlog="$(bridge_client_log "${cl_mid}")"
  : >"${errlog}"
  # 上一个 supervisor 若被 SIGKILL，它的 master 可能还活着并占着映射端口：先请它退出
  _bridge_ctl_exit "${cl_ctl}"
  rm -f "${cl_ctl}" 2>/dev/null || true

  local -a cl_spec=()
  local -a cl_status=()
  local -a cl_reason=()
  cl_server_host=""
  _bridge_client_write connecting

  # 两个 FIFO 接 ssh 的 stdin/stdout（bash 3.2 没有 coproc）。打开顺序必须与子进程的
  # 重定向顺序一致（先 in 后 out）：FIFO 的 open 会阻塞到对端也打开为止。
  local fifo_dir=""
  fifo_dir="$(mktemp -d "${TMPDIR:-/tmp}/hf-bridge.XXXXXX")" || return 255
  if ! mkfifo "${fifo_dir}/in" "${fifo_dir}/out"; then
    rm -rf "${fifo_dir}"
    return 255
  fi
  # shellcheck disable=SC2029 # remote 是 bridge_remote_serve_cmd 按远端 shell 转义好的命令串
  ssh "${args[@]}" "${dest}" "${remote}" <"${fifo_dir}/in" >"${fifo_dir}/out" 2>>"${errlog}" &
  _BRIDGE_RUN_SSH_PID=$!
  exec 8>"${fifo_dir}/in" 7<"${fifo_dir}/out"
  rm -rf "${fifo_dir}"

  _bridge_send "${BRIDGE_PROTO} HELLO ${cl_host} ${cl_label}"

  local line="" buf="" rrc=0 now="" last_ping="" read_at=0
  last_ping="$(now_unix)"
  while ((_BRIDGE_RUN_STOP == 0)); do
    line=""
    rrc=0
    read_at="${SECONDS}"
    IFS= read -r -t "${BRIDGE_POLL_S}" -u "${_BRIDGE_FD_IN}" line || rrc=$?
    if ((rrc != 0)); then
      if ! hf_read_timed_out "${rrc}" "${read_at}" "${BRIDGE_POLL_S}"; then
        break
      fi
      buf+="${line}"
    else
      line="${buf}${line}"
      buf=""
      case "${line}" in
      "${BRIDGE_PROTO} HELLO "*)
        cl_server_host="${line#"${BRIDGE_PROTO} HELLO "}"
        cl_since="$(now_unix)"
        _bridge_client_write connected
        log info "bridge ${cl_mid}: 已连上 ${cl_label}（${cl_server_host}）。"
        ;;
      "${BRIDGE_PROTO} SYNC "*)
        _bridge_reconcile "${line#"${BRIDGE_PROTO} SYNC "}"
        ;;
      "${BRIDGE_PROTO} OPEN "*)
        _bridge_open_url "${line#"${BRIDGE_PROTO} OPEN "}"
        ;;
      *)
        log warn "bridge ${cl_mid}: 忽略未知协议行：${line:0:120}"
        ;;
      esac
    fi
    now="$(now_unix)"
    if ((now - last_ping >= BRIDGE_PING_S)); then
      _bridge_send "${BRIDGE_PROTO} PING"
      last_ping="${now}"
      _bridge_retry_failed
    fi
    if [[ -n ${cl_herdr_sock} && ! -S ${cl_herdr_sock} ]]; then
      log info "bridge ${cl_mid}: 本机 herdr server 已退出，桥接随之停止。"
      _BRIDGE_RUN_STOP=1
    fi
  done

  exec 7<&- 8>&-
  kill -TERM "${_BRIDGE_RUN_SSH_PID}" 2>/dev/null || true
  local rc=0
  wait "${_BRIDGE_RUN_SSH_PID}" 2>/dev/null || rc=$?
  _BRIDGE_RUN_SSH_PID=""
  return "${rc}"
}

# _bridge_exit_reason <ssh_rc> -> stdout: 给人看的断线原因
_bridge_exit_reason() {
  local rc="${1-}"
  local errlog=""
  errlog="$(bridge_client_log "${cl_mid}")"
  local tail_out=""
  if [[ -s ${errlog} ]]; then
    tail_out="$(tail -n 3 "${errlog}" 2>/dev/null || true)"
    tail_out="${tail_out//$'\n'/ }"
  fi
  case "${rc}" in
  127 | 126)
    printf '%s\n' "远端找不到插件的 bin/forward（插件未装或已移动）。请重新激活该机器。"
    ;;
  64)
    printf '%s\n' "远端插件版本过旧（不支持 bridge serve）。请在远端重新执行 herdr plugin install zzjcool/herdr-forward --yes。"
    ;;
  255)
    printf '%s\n' "SSH 连接失败：${tail_out:-无更多信息}"
    ;;
  *)
    printf '%s\n' "会话结束（rc=${rc}）${tail_out:+：${tail_out}}"
    ;;
  esac
}

# EXIT trap 在 bridge_run 返回之后才跑，届时它的局部变量已不存在，故清理所需的放全局。
_BRIDGE_RUN_MID=""
_BRIDGE_RUN_CTL=""
_BRIDGE_RUN_SSH_PID=""
_BRIDGE_RUN_STOP=0

_bridge_run_cleanup() {
  if [[ -n ${_BRIDGE_RUN_SSH_PID} ]]; then
    kill -TERM "${_BRIDGE_RUN_SSH_PID}" 2>/dev/null || true
  fi
  if [[ -n ${_BRIDGE_RUN_CTL} ]]; then
    _bridge_ctl_exit "${_BRIDGE_RUN_CTL}"
  fi
  if [[ -n ${_BRIDGE_RUN_MID} ]]; then
    local lock=""
    lock="$(bridge_client_lock "${_BRIDGE_RUN_MID}")"
    rm -rf "${lock}" 2>/dev/null || true
  fi
  return 0
}

_bridge_run_stop() {
  _BRIDGE_RUN_STOP=1
  if [[ -n ${_BRIDGE_RUN_SSH_PID} ]]; then
    kill -TERM "${_BRIDGE_RUN_SSH_PID}" 2>/dev/null || true
  fi
  return 0
}

# bridge_run <machine>：前台 supervisor（`forward bridge up` 用 setsid 把它放到后台）
#   整个循环关掉 errexit：长驻进程不能因为某次 jq/写盘的偶发失败就悄悄退出，
#   失败一律记日志后进入下一轮重连。
bridge_run() {
  require_cmd ssh "桥接需要 OpenSSH 客户端。"
  require_cmd jq "桥接需要 jq。"
  local cl_mid="${1-}"
  if [[ -z ${cl_mid} ]]; then
    die 64 "用法：forward bridge run <machine-id>"
  fi
  local cl_pid="${BASHPID:-$$}"
  local got=""
  got="$(_bridge_lock_acquire "${cl_mid}" "${cl_pid}")"
  if [[ ${got} != "ok" ]]; then
    local holder=""
    holder="$(_bridge_lock_holder "${cl_mid}")"
    printf '桥接 %s 已在运行（pid=%s），无需重复启动。\n' "${cl_mid}" "${holder:-?}"
    return 0
  fi

  _BRIDGE_RUN_MID="${cl_mid}"
  _BRIDGE_RUN_STOP=0
  local cl_ctl=""
  cl_ctl="$(bridge_control_path "${cl_mid}")"
  _BRIDGE_RUN_CTL="${cl_ctl}"
  trap '_bridge_run_cleanup' EXIT
  trap '_bridge_run_stop' TERM INT
  trap '' HUP PIPE

  local cl_host=""
  cl_host="$(_bridge_hostname)"
  local cl_herdr_sock="${HERDR_SOCKET_PATH:-}"
  local cl_label="" cl_target="" cl_root="" cl_rstate="" cl_server_host=""
  local cl_since=0 cl_next_retry=0
  local -a cl_spec=()
  local -a cl_status=()
  local -a cl_reason=()
  local backoff="${BRIDGE_BACKOFF_MIN_S}"
  local rec="" rc=0 started=0 lasted=0 reason="" last_reason="" waited=0 now=0

  set +o errexit
  while ((_BRIDGE_RUN_STOP == 0)); do
    rec="$(bridge_machine_record "${cl_mid}")"
    cl_label="$(printf '%s' "${rec}" | jq -r '.label // ""' 2>/dev/null || true)"
    cl_target="$(printf '%s' "${rec}" | jq -r '.ssh_target // ""' 2>/dev/null || true)"
    cl_root="$(printf '%s' "${rec}" | jq -r '.server_root // ""' 2>/dev/null || true)"
    cl_rstate="$(printf '%s' "${rec}" | jq -r '.state_dir // ""' 2>/dev/null || true)"
    cl_label="${cl_label:-${cl_mid}}"
    if [[ -z ${rec} || -z ${cl_target} || -z ${cl_root} || -z ${cl_rstate} ]]; then
      cl_next_retry=0
      _bridge_client_write stopped "激活记录缺失或不完整（需要 ssh_target / server_root / state_dir）。请重新激活该机器。"
      log warn "bridge ${cl_mid}: 激活记录缺失或不完整，桥接停止。"
      break
    fi

    started="$(now_unix)"
    cl_since="${started}"
    cl_next_retry=0
    _bridge_connect_once
    rc=$?
    ((_BRIDGE_RUN_STOP == 0)) || break

    now="$(now_unix)"
    lasted=$((now - started))
    if ((lasted >= BRIDGE_STABLE_S)); then
      backoff="${BRIDGE_BACKOFF_MIN_S}"
    fi
    reason="$(_bridge_exit_reason "${rc}")"
    cl_next_retry=$((now + backoff))
    cl_since="${now}"
    _bridge_client_write retrying "${reason}"
    # 同一原因反复重连只在第一次 warn（机器长时间离线时日志不刷屏）
    if [[ ${reason} != "${last_reason}" ]]; then
      log warn "bridge ${cl_mid}: ${reason}；${backoff}s 后重连。"
      last_reason="${reason}"
    else
      log info "bridge ${cl_mid}: 仍无法连接，${backoff}s 后重连。"
    fi

    waited=0
    while ((_BRIDGE_RUN_STOP == 0 && waited < backoff)); do
      sleep 1
      waited=$((waited + 1))
    done
    backoff=$((backoff * 2))
    if ((backoff > BRIDGE_BACKOFF_MAX_S)); then
      backoff="${BRIDGE_BACKOFF_MAX_S}"
    fi
  done

  cl_next_retry=0
  cl_spec=()
  cl_status=()
  cl_reason=()
  if ((_BRIDGE_RUN_STOP == 1)); then
    reason="已停止"
  fi
  _bridge_client_write stopped "${reason:-已停止}"
  set -o errexit
  log info "bridge ${cl_mid}: supervisor 退出。"
  return 0
}

# bridge_up <machine> <forward_bin>：后台启动 supervisor（已在运行则直接返回）
bridge_up() {
  local mid="${1-}"
  local bin="${2-}"
  if [[ -z ${mid} || -z ${bin} ]]; then
    die 64 "用法：bridge_up <machine-id> <bin/forward 路径>"
  fi
  local holder=""
  holder="$(_bridge_lock_holder "${mid}")"
  if [[ -n ${holder} ]]; then
    printf '桥接已在运行（pid=%s）。\n' "${holder}"
    return 0
  fi
  local dir="" safe=""
  dir="$(bridge_dir)"
  safe="$(_bridge_safe_id "${mid}")"
  local outlog="${dir}/client-${safe}.out"
  : >"${outlog}"
  # 新会话：面板 / popup 关闭时 herdr 对其进程组发的信号不能带走 supervisor
  hf_detach_exec "${bin}" bridge run "${mid}" </dev/null >>"${outlog}" 2>&1 &
  disown "$!" 2>/dev/null || true
  local tries=0
  while ((tries < 20)); do
    holder="$(_bridge_lock_holder "${mid}")"
    [[ -z ${holder} ]] || break
    sleep 0.1
    tries=$((tries + 1))
  done
  if [[ -z ${holder} ]]; then
    printf '桥接进程未能启动；日志：%s\n' "${outlog}" >&2
    return 1
  fi
  printf '桥接已启动（pid=%s）。\n' "${holder}"
  return 0
}

# bridge_down <machine>：停 supervisor（它的 EXIT trap 会关掉 master，映射随之释放）；幂等
bridge_down() {
  local mid="${1-}"
  local holder=""
  holder="$(_bridge_lock_holder "${mid}")"
  if [[ -n ${holder} ]]; then
    kill -TERM "${holder}" 2>/dev/null || true
    local waits=0
    while ((waits < 50)) && kill -0 "${holder}" 2>/dev/null; do
      sleep 0.1
      waits=$((waits + 1))
    done
    kill -KILL "${holder}" 2>/dev/null || true
  fi
  local ctl=""
  ctl="$(bridge_control_path "${mid}")"
  _bridge_ctl_exit "${ctl}"
  local lock="" file=""
  lock="$(bridge_client_lock "${mid}")"
  file="$(bridge_client_file "${mid}")"
  rm -rf "${lock}" 2>/dev/null || true
  rm -f "${file}" 2>/dev/null || true
  return 0
}

# bridge_clients_json -> stdout: A 侧所有 supervisor 状态（附 running）
bridge_clients_json() {
  local dir=""
  dir="$(bridge_dir)"
  local -a docs=()
  local f="" doc="" mid="" running=""
  for f in "${dir}"/client-*.json; do
    [[ -f ${f} ]] || continue
    doc="$(jq -c 'if type == "object" then . else empty end' "${f}" 2>/dev/null || true)"
    [[ -n ${doc} ]] || continue
    mid="$(printf '%s' "${doc}" | jq -r '.machine // ""')"
    running="$(bridge_running "${mid}")"
    if [[ ${running} == "yes" ]]; then
      running="true"
    else
      running="false"
    fi
    docs+=("$(printf '%s' "${doc}" | jq -c --argjson r "${running}" '. + {running: $r}')")
  done
  if ((${#docs[@]} == 0)); then
    printf '[]\n'
    return 0
  fi
  printf '%s\n' "${docs[@]}" | jq -c -s '.'
}

# bridge_client_forwards_json -> stdout: A 侧经桥接生效中的映射（供 list / tab bar 合并展示）
bridge_client_forwards_json() {
  local clients=""
  clients="$(bridge_clients_json)"
  printf '%s' "${clients}" | jq -c '
    [ .[] | select(.running and .state == "connected") | . as $c
      | (.forwards // {}) | to_entries[]
      | (.value.spec | split(" ")) as $p
      | {id: .key, local_port: ($p[0] | tonumber), remote_host: "localhost",
         remote_port: ($p[1] | tonumber), machine: ($c.label // $c.machine),
         ssh_target: ($c.target // ""), pid: $c.pid, status: .value.state,
         status_reason: .value.reason, mode: "bridge"} ]
    | sort_by(.local_port)
  '
}
