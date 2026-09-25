#!/usr/bin/env bash
# lib/common.sh — 基础设施原语：日志、错误、依赖检查、原子写、TCP 探活
# A.3 冻结签名：log / die / require_cmd / now_unix / atomic_write / probe_tcp / tcp_serve_once
#
# 本文件可被反复 source（幂等，无 source 期副作用）；日志目录与状态目录按需惰性创建。
# 唯一 writer：T1。见 docs/ARCHITECTURE.md §A.1 / §A.3 / §E。
set -o errexit -o nounset -o pipefail

# --- 常量（幂等：已定义则不覆盖，便于测试注入） ---
if [[ -z ${FORWARD_LOG_MAX_BYTES:-} ]]; then
  readonly FORWARD_LOG_MAX_BYTES=1048576 # 1MB，超过则截断保留后半
fi
if [[ -z ${FORWARD_LOG_KEEP_BYTES:-} ]]; then
  readonly FORWARD_LOG_KEEP_BYTES=524288 # 512KB
fi
if [[ -z ${FORWARD_TCP_TIMEOUT_DEFAULT:-} ]]; then
  readonly FORWARD_TCP_TIMEOUT_DEFAULT=2
fi
if [[ -z ${FORWARD_PROBE_TIMEOUT_DEFAULT:-} ]]; then
  readonly FORWARD_PROBE_TIMEOUT_DEFAULT=2 # 等应用层回包的秒数（A.3.1 review 修正）
fi
if [[ -z ${FORWARD_PROBE_PAYLOAD_MARKER:-} ]]; then
  readonly FORWARD_PROBE_PAYLOAD_MARKER='herdr-forward-probe'
fi

# bash 3.2 兼容（macOS 自带的 /bin/bash；herdr server 若由非交互 ssh 拉起，PATH 里
# 只有它）。新版 bash 走无 fork 的内建写法，旧版退回外部命令：
#   printf '%(fmt)T' 需要 4.2；read -N 需要 4.1；${x,,} / ${x^^} 需要 4.0。
if [[ -z ${_HF_BASH42:-} ]]; then
  if ((BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 2))); then
    readonly _HF_BASH42=1
  else
    readonly _HF_BASH42=0
  fi
fi

# hf_lower <string> -> stdout: 小写
hf_lower() {
  if ((_HF_BASH42 == 1)); then
    printf '%s\n' "${1,,}"
  else
    printf '%s\n' "${1-}" | tr '[:upper:]' '[:lower:]'
  fi
}

# hf_upper <string> -> stdout: 大写
hf_upper() {
  if ((_HF_BASH42 == 1)); then
    printf '%s\n' "${1^^}"
  else
    printf '%s\n' "${1-}" | tr '[:lower:]' '[:upper:]'
  fi
}

# hf_detach_exec <cmd...>：把命令 exec 到新会话里（脱离调用方的进程组与控制终端）
#   调用方负责 & 与重定向：hf_detach_exec cmd args </dev/null >>log 2>&1 &
#   macOS 没有 setsid(1)，用系统自带的 perl / python3 调 setsid()；都没有才退 nohup。
hf_detach_exec() {
  if command -v setsid >/dev/null 2>&1; then
    exec setsid "$@"
  elif command -v perl >/dev/null 2>&1; then
    exec perl -MPOSIX -e 'POSIX::setsid(); exec { $ARGV[0] } @ARGV or die "exec $ARGV[0]: $!\n"' "$@"
  elif command -v python3 >/dev/null 2>&1; then
    exec python3 -c 'import os, sys
try:
    os.setsid()
except OSError:
    pass
os.execvp(sys.argv[1], sys.argv[1:])' "$@"
  fi
  exec nohup "$@"
}

# hf_read_timed_out <read_rc> <SECONDS_before_read> <timeout_s>：0 = `read -t` 超时，1 = EOF
#   bash ≥ 4 超时返回 >128；bash 3.2 超时与 EOF 都返回 1，只能看耗时：EOF 立即返回，
#   超时要等满 timeout 整秒（SECONDS 取整，但等满 t 秒必然跨过 t 个整秒边界）。
#   3.2 超时还会丢掉已读的半行，所以调用方的半行拼接只在新版 bash 上生效。
hf_read_timed_out() {
  local rc="${1-1}" started="${2-0}" timeout="${3-1}"
  if ((rc > 128)); then
    return 0
  fi
  if ((BASH_VERSINFO[0] >= 4)); then
    return 1
  fi
  ((SECONDS - started >= timeout))
}

# state_dir
#   stdout: 插件状态目录绝对路径（A.2：env 优先，缺失回退 ~/.local/state/herdr-forward）
#   备注：A.3 未冻结此名，属 T1 附加 helper（log / state_file / control socket 共用）。
state_dir() {
  printf '%s\n' "${HERDR_PLUGIN_STATE_DIR:-${HOME:-/tmp}/.local/state/herdr-forward}"
}

# log <level:debug|info|warn|error> <msg...>
#   写 $HERDR_PLUGIN_STATE_DIR/logs/forward.log；env 缺失退 /dev/stderr。
#   warn/error 额外镜像到 stderr（用户/CI 可见）。永不因日志失败而中断调用方。
#   review M2：原实现每次调用 fork `date`+`mkdir`+`wc`+`tail`（500 条 ~2.8s）。
#   现改为纯 builtin：EPOCHSECONDS + `printf %(%…Z)T` 生成 UTC 时间戳；
#   目录创建用进程内标志去重；轮转阈值用有界 read 取字节数（无 fork）。
_log_dir_ready="" # 进程内缓存：日志目录已确保存在（每次调用免 fork mkdir）
log() {
  local level="${1:-info}"
  shift || true
  local msg="$*"

  local ts=""
  if ((_HF_BASH42 == 1)); then
    # TZ=UTC0 只作用于本条 printf（bash 普通 builtin 的临时环境赋值不泄漏）；
    # EPOCHSECONDS 缺失时回退 -1（printf 语义：取当前时间），故无 date fork。
    TZ=UTC0 printf -v ts '%(%Y-%m-%dT%H:%M:%SZ)T' "${EPOCHSECONDS:--1}"
  else
    # 关掉协议 fd：命令替换子 shell 若继承 supervisor 的 7/8，bash 3.2 会把写进管道的
    # 协议行（HF1 PING）卷进时间戳。
    ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ' 7<&- 8<&- 2>/dev/null || true)"
  fi
  local line="[${ts}] ${level}: ${msg}"

  if [[ -n "${HERDR_PLUGIN_STATE_DIR:-}" ]]; then
    local logdir="${HERDR_PLUGIN_STATE_DIR}/logs"
    local logfile="${logdir}/forward.log"
    if [[ -z "${_log_dir_ready}" || ! -d "${logdir}" ]]; then
      mkdir -p "${logdir}" 2>/dev/null || true
      _log_dir_ready=1
    fi
    _log_rotate "${logfile}"
    if ! printf '%s\n' "${line}" >>"${logfile}" 2>/dev/null; then
      # 目录被外部删掉等异常：重建一次再重试，仍失败则退 stderr（永不中断调用方）
      mkdir -p "${logdir}" 2>/dev/null || true
      printf '%s\n' "${line}" >>"${logfile}" 2>/dev/null || printf '%s\n' "${line}" >&2
    fi
  else
    printf '%s\n' "${line}" >&2
  fi

  if [[ "${level}" == "warn" || "${level}" == "error" ]]; then
    printf '%s\n' "${line}" >&2
  fi
}

# _log_rotate <logfile>：>FORWARD_LOG_MAX_BYTES 时保留最后 FORWARD_LOG_KEEP_BYTES 字节
#   review M2：用有界 read（最多读 MAX+1 字节，以字节计）+ builtin 子串切片，
#   取代 `wc -c`/`tail -c` 两个 fork。恒定内存/时间上界，大文件也不拖慢调用方。
_log_rotate() {
  local logfile="${1-}"
  [[ -f "${logfile}" ]] || return 0
  if ((_HF_BASH42 == 0)); then
    local size=""
    size="$(wc -c <"${logfile}" 2>/dev/null || true)"
    size="${size//[[:space:]]/}"
    [[ ${size} =~ ^[0-9]+$ ]] || return 0
    ((size > FORWARD_LOG_MAX_BYTES)) || return 0
    local kept=""
    kept="$(tail -c "${FORWARD_LOG_KEEP_BYTES}" "${logfile}" 2>/dev/null || true)"
    printf '%s\n' "${kept}" >"${logfile}" 2>/dev/null || true
    return 0
  fi
  local LC_ALL=C # 使 ${#var} / ${var: -n} 按字节而非字符计数（与 wc -c 语义一致）
  local data=""
  IFS= read -r -N $((FORWARD_LOG_MAX_BYTES + 1)) -d "" data <"${logfile}" 2>/dev/null || true
  [[ "${#data}" =~ ^[0-9]+$ ]] || return 0
  ((${#data} > FORWARD_LOG_MAX_BYTES)) || return 0
  printf '%s\n' "${data: -FORWARD_LOG_KEEP_BYTES}" >"${logfile}" 2>/dev/null || true
}

# die <exit_code> <msg...>：log error + exit；用户可见错误必须含下一步建议
die() {
  local code="${1:-1}"
  shift || true
  log error "$*"
  exit "${code}"
}

# require_cmd <name> [hint]：command -v 失败即 die 127
require_cmd() {
  local name="${1-}"
  local hint="${2:-}"
  if ! command -v "${name}" >/dev/null 2>&1; then
    if [[ -n "${hint}" ]]; then
      die 127 "缺少依赖命令：${name}。${hint}"
    fi
    die 127 "缺少依赖命令：${name}。请先安装后重试（如 apt/pacman/brew install ${name}）。"
  fi
}

# now_unix：stdout epoch 秒
now_unix() {
  if [[ -n "${EPOCHSECONDS:-}" ]]; then
    printf '%s\n' "${EPOCHSECONDS}"
    return 0
  fi
  local t=""
  t="$(date +%s 7<&- 8<&-)"
  printf '%s\n' "${t}"
}

# atomic_write <file> <tmpdir>：stdin 内容 -> 同分区 mktemp -> mv -f
atomic_write() {
  local file="${1-}"
  local tmpdir="${2-}"
  if [[ -z "${file}" || -z "${tmpdir}" ]]; then
    die 1 "atomic_write 用法：atomic_write <file> <tmpdir>（stdin 传入内容）"
  fi
  mkdir -p "${tmpdir}" 2>/dev/null || true
  mkdir -p "$(dirname "${file}")" 2>/dev/null || true

  local tmp=""
  if ! tmp="$(mktemp "${tmpdir%/}/.atomic.XXXXXX" 2>/dev/null)"; then
    die 1 "atomic_write 无法在 ${tmpdir} 创建临时文件。请检查目录权限/磁盘空间后重试。"
  fi
  # shellcheck disable=SC2064  # 立即展开 ${tmp}，便于 trap 清理确定文件
  trap "rm -f '${tmp}'" RETURN INT TERM

  if ! cat >"${tmp}"; then
    rm -f "${tmp}"
    die 1 "atomic_write 写入临时文件失败：${tmp}。请检查磁盘空间后重试。"
  fi
  if ! mv -f "${tmp}" "${file}"; then
    rm -f "${tmp}"
    die 1 "atomic_write 落盘失败：${file}。请检查目标目录权限后重试。"
  fi
  trap - RETURN INT TERM
}

# probe_tcp <host> <port> [timeout_s=2]：stdout ok|fail，恒 return 0（不因失败 exit）
probe_tcp() {
  local host="${1-}"
  local port="${2-}"
  local timeout_s="${3:-${FORWARD_TCP_TIMEOUT_DEFAULT}}"
  if [[ -z "${host}" || -z "${port}" ]]; then
    printf 'fail\n'
    return 0
  fi

  local rc=0
  # 显式构造探测脚本，避免 shellcheck SC2016（单引号内 /dev/tcp 变量不展开）误报。
  # 用 && 串联：首个 exec 失败即短路，退出码不被后续 exec 掩盖。
  local script=""
  printf -v script 'exec 3<>"%s" && exec 3>&- && exec 3<&-' "/dev/tcp/${host}/${port}"
  set +o errexit
  if command -v timeout >/dev/null 2>&1; then
    timeout "${timeout_s}" bash -c "${script}" >/dev/null 2>&1
    rc=$?
  else
    bash -c "${script}" >/dev/null 2>&1
    rc=$?
  fi
  set -o errexit

  if [[ "${rc}" -eq 0 ]]; then
    printf 'ok\n'
  else
    printf 'fail\n'
  fi
  return 0
}

# probe_payload <host> <port> [timeout_s=2]：
#   A.3.1（review D1 契约修正）：连上后发一行 payload 并等**任意**应用层回包：
#     up       连接成功且 timeout 内收到至少 1 字节回包（远端应用真的在服务）
#     degraded 连接成功但无回包（远端端口可连，协议未知/不应答）
#     down     连接被拒/重置/超时失败或参数为空
#   恒 return 0（不因失败 exit），stdout 恒单行。
#   为什么需要它：ssh -L 的本地监听器在 master 活着时**永远**接受本地连接，
#   TCP-only 探活于是把「远端应用已死」误判为 up（review D1 红线的根因）。
probe_payload() {
  local host="${1-}"
  local port="${2-}"
  local timeout_s="${3:-${FORWARD_PROBE_TIMEOUT_DEFAULT}}"
  if [[ -z "${host}" || -z "${port}" ]]; then
    printf 'down\n'
    return 0
  fi

  # 显式构造探测脚本，避免 shellcheck SC2016 误报；退出码即分类依据：
  #   0   = 读到回包 -> up
  #   128+= timeout 杀掉的 read（读超时）-> degraded
  #   其他 = connect/write 失败 -> down
  #   bash 3.2 的 read 超时也返回 1（同 EOF），按耗时补成 142（见 hf_read_timed_out）。
  local script=""
  # shellcheck disable=SC2016 # $SECONDS / $rc 属于子 bash，必须原样写进脚本
  printf -v script 'exec 3<>"%s" 2>/dev/null || exit 2
printf "%%s\\n" "%s" >&3 2>/dev/null || exit 3
s=$SECONDS
IFS= read -r -n 1 -t "%s" -u 3 _ 2>/dev/null
rc=$?
if [ "$rc" -eq 1 ] && [ "${BASH_VERSINFO[0]}" -lt 4 ] && [ $((SECONDS - s)) -ge "%s" ]; then rc=142; fi
exit "$rc"' \
    "/dev/tcp/${host}/${port}" "${FORWARD_PROBE_PAYLOAD_MARKER}" "${timeout_s}" "${timeout_s}"

  local rc=0
  set +o errexit
  if command -v timeout >/dev/null 2>&1; then
    timeout "$((timeout_s + 2))" bash -c "${script}" >/dev/null 2>&1
    rc=$?
  else
    bash -c "${script}" >/dev/null 2>&1
    rc=$?
  fi
  set -o errexit

  if [[ "${rc}" -eq 0 ]]; then
    printf 'up\n'
  elif [[ "${rc}" -ge 128 ]]; then
    printf 'degraded\n'
  else
    printf 'down\n'
  fi
  return 0
}

# tcp_serve_once <port>：调试用一次性回显服务（读一行回 pong）
#   nc 变体探测（GNU/openbsd），无 nc 时 python3 兜底，都没有则 die 127。
tcp_serve_once() {
  local port="${1-}"
  if [[ -z "${port}" ]]; then
    die 1 "tcp_serve_once 用法：tcp_serve_once <port>。请传入监听端口后重试。"
  fi
  if ! [[ "${port}" =~ ^[0-9]+$ ]] || ((port < 1 || port > 65535)); then
    die 1 "tcp_serve_once 端口非法：${port}。请使用 1-65535 的整数。"
  fi

  if command -v nc >/dev/null 2>&1; then
    _tcp_serve_once_nc "${port}"
    return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    _tcp_serve_once_python "${port}"
    return 0
  fi
  die 127 "tcp_serve_once 需要 nc 或 python3。请安装其一（如 pacman -S openbsd-netcat python）后重试。"
}

# tcp_serve_once_bg <port> [reply]：循环服务版本（A.3 未冻结，T1 附加；
# ARCHITECTURE §C.3 run-inside.sh 引用了此名，属必要补全）。
tcp_serve_once_bg() {
  local port="${1-}"
  local reply="${2:-pong}"
  [[ -n "${port}" ]] || die 1 "tcp_serve_once_bg 用法：tcp_serve_once_bg <port> [reply]。请传入端口。"
  if ! command -v python3 >/dev/null 2>&1; then
    die 127 "tcp_serve_once_bg 需要 python3。请安装后重试（如 pacman -S python）。"
  fi
  exec python3 -u -c '
import socket, sys
port = int(sys.argv[1]); reply = sys.argv[2].encode()
srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", port)); srv.listen(16)
while True:
    conn, _ = srv.accept()
    try:
        conn.recv(4096)
        conn.sendall(reply)
    except OSError:
        pass
    finally:
        conn.close()
' "${port}" "${reply}"
}

# _tcp_serve_once_nc <port>：用 nc 读一行回 pong（兼容 GNU 与 openbsd 语法）
_tcp_serve_once_nc() {
  local port="${1-}"
  local reply="${2:-pong}"
  local out=""
  local rc=0
  set +o errexit
  _nc_is_openbsd
  rc=$?
  if [[ "${rc}" -eq 0 ]]; then
    out="$(printf '%s\n' "${reply}" | nc -l 127.0.0.1 "${port}")"
  else
    out="$(printf '%s\n' "${reply}" | nc -l -p "${port}")"
  fi
  set -o errexit
  printf '%s\n' "${out}"
}

# _nc_is_openbsd：nc -h 里出现 "-p port" 说明是 openbsd 变体（GNU 用 -p port 亦兼容）
_nc_is_openbsd() {
  local help=""
  set +o errexit
  help="$(nc -h 2>&1 || true)"
  set -o errexit
  [[ "${help}" == *"-p port"* ]]
}

# _tcp_serve_once_python <port>：python3 一次性监听，读一行回 pong
_tcp_serve_once_python() {
  local port="${1-}"
  local reply="${2:-pong}"
  set +o errexit
  python3 -u -c '
import socket, sys
port = int(sys.argv[1]); reply = sys.argv[2].encode()
srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", port)); srv.listen(1)
conn, _ = srv.accept()
try:
    conn.recv(4096)
    conn.sendall(reply)
finally:
    conn.close()
    srv.close()
' "${port}" "${reply}"
  set -o errexit
}
