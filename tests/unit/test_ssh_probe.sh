#!/usr/bin/env bash
# tests/unit/test_ssh_probe.sh — lib/ssh-probe.sh 契约单测（M1 计划 §2.1 冻结签名）
#
# 归属：M1（唯一 writer）。被测：lib/ssh-probe.sh 的 4 个公开函数
#   ssh_probe_parse_target / ssh_probe_run / ssh_probe_plugin / kv_get
#
# 覆盖：
#   * parse_target 各形态（user@host / user@host:port / host / [v6]:port / [v6] / 裸 IPv6）
#     与非法输入（空 / 端口非数字 / 方括号未闭合 / 方括号后非法内容）-> die 64
#   * kv_get 首个匹配 / 缺失 / 前导空格不算键（严格 ^KEY=）
#   * ssh_probe_run：argv 形状逐字（timeout 15 + ssh -n -o BatchMode=yes -o ConnectTimeout=8
#     [-p PORT] HOST CMD）、HF_SSH_RC 首行、stdout+stderr 合并、恒 return 0
#   * timeout 包裹是**行为级**断言（timeout shim 记录 argv），并在无 timeout 的 PATH 下
#     验证降级（仍带 ConnectTimeout=8，不静默崩）
#   * ssh_probe_plugin 四状态（present / absent / no-herdr / unreachable）、ssh 调用次数
#     （1 或 2）、HF_REASON 摘要、自定义 plugin_id 代入远端命令
#   * 宿主已提供 die 时复用（错误格式归调用方）；幂等常量不被覆盖
#   * 静态防漂移：setup-client.sh 不再是探测实现的第二份副本
#
# 手法：ssh/timeout 一律用 PATH 前置的 shim（**绝不真连任何主机**）；沙箱 HOME/XDG。
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="${ROOT}/lib/ssh-probe.sh"
SETUP="${ROOT}/scripts/setup-client.sh"

if [[ -f "${ROOT}/tests/lib/assertions.sh" ]]; then
  # shellcheck source=/dev/null
  source "${ROOT}/tests/lib/assertions.sh"
fi
if ! declare -F t_fail_note >/dev/null 2>&1; then
  t_fail_note() { t_fail "$@"; }
fi

if [[ ! -f "${LIB}" ]]; then
  echo "RED: ${LIB} 不存在（lib/ssh-probe.sh 尚未实现）" >&2
  exit 1
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ssh-probe.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT

# 真实环境 config 必须全程零改动（本测试只用沙箱 HOME/XDG）
REAL_CFG="${HOME:-}/.config/herdr/config.toml"
real_cfg_before="$(if [[ -f "${REAL_CFG}" ]]; then md5sum "${REAL_CFG}" | awk '{print $1}'; else printf 'absent'; fi)"

mkdir -p "${WORK}/home" "${WORK}/bin" "${WORK}/sandbox-bin"
SHIM_LOG="${WORK}/shim.log"
: >"${SHIM_LOG}"

# --- ssh shim：只记 argv + 按环境变量回放，永不联网 ---
cat >"${WORK}/bin/ssh" <<'SHIM'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'ARGV' >>"${SSH_SHIM_LOG:?}"
for a in "$@"; do printf ' <%s>' "$a" >>"${SSH_SHIM_LOG}"; done
printf '\n' >>"${SSH_SHIM_LOG}"
cmd=""
for a in "$@"; do cmd="$a"; done
# 单次调用覆盖（验证 rc / 输出合并时用）
if [[ -n "${SSH_SHIM_FORCE_EXIT:-}${SSH_SHIM_FORCE_OUT:-}${SSH_SHIM_FORCE_ERR:-}" ]]; then
  [[ -n "${SSH_SHIM_FORCE_OUT:-}" ]] && printf '%s\n' "${SSH_SHIM_FORCE_OUT}"
  [[ -n "${SSH_SHIM_FORCE_ERR:-}" ]] && printf '%s\n' "${SSH_SHIM_FORCE_ERR}" >&2
  exit "${SSH_SHIM_FORCE_EXIT:-0}"
fi
case "${SSH_SHIM_SCENARIO:-present}" in
present)
  case "${cmd}" in
  *"plugin list"*) printf '1 plugin installed:\n- %s (forward) enabled [github:zzjcool/herdr-forward@deadbeef]\n' "${SSH_SHIM_PLUGIN_ID:-zzjcool:forward}" ;;
  *)
    printf 'HF_ROOT=%s\n' "${SSH_SHIM_ROOT:-/home/b/.config/herdr/plugins/github/zzjcool-forward-deadbeef}"
    printf 'HF_STATE_DIR=%s\n' "${SSH_SHIM_STATE:-/home/b/.local/state/herdr/plugins/zzjcool%3Aforward}"
    ;;
  esac
  ;;
present_default_state)
  case "${cmd}" in
  *"plugin list"*) printf -- '- %s\n' "${SSH_SHIM_PLUGIN_ID:-zzjcool:forward}" ;;
  *) printf 'HF_ROOT=/home/b/plugin-root\nHF_DEFAULT_STATE=/home/b/default/state\n' ;;
  esac
  ;;
present_no_root)
  case "${cmd}" in
  *"plugin list"*) printf -- '- %s\n' "${SSH_SHIM_PLUGIN_ID:-zzjcool:forward}" ;;
  *) printf 'HF_DEFAULT_STATE=/home/b/default/state\n' ;;
  esac
  ;;
absent) printf 'No plugins installed.\n' ;;
noherdr) printf 'HF_NO_HERDR\n' ;;
unreachable)
  printf 'ssh: connect to host %s port 22: Connection refused\n' "${SSH_SHIM_HOST:-fake-host}" >&2
  exit 255
  ;;
esac
exit 0
SHIM
chmod +x "${WORK}/bin/ssh"

# --- timeout shim：把「timeout 15 包裹」变成行为级可断言事实 ---
cat >"${WORK}/bin/timeout" <<'SHIM'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'TIMEOUT <%s>\n' "${1-}" >>"${SSH_SHIM_LOG:?}"
shift
exec "$@"
SHIM
chmod +x "${WORK}/bin/timeout"

# 无 timeout 的 PATH：只放探测链路真正用到的工具（bash/sed/head/tr/grep + shim ssh）
for tool in bash sed head tr grep cat; do
  tool_path="$(command -v "${tool}")"
  ln -sf "${tool_path}" "${WORK}/sandbox-bin/${tool}"
done
ln -sf "${WORK}/bin/ssh" "${WORK}/sandbox-bin/ssh"
if [[ -n "$(command -v timeout || true)" ]] && [[ -e "${WORK}/sandbox-bin/timeout" ]]; then
  rm -f "${WORK}/sandbox-bin/timeout"
fi

BASE_PATH="${PATH}"

# probe <函数调用（bash 源码）> [额外 env...]：在沙箱里 source lib 后执行，捕获 out/err/rc
probe() {
  local snippet="$1"
  shift
  rc=0
  out="$(env -u HERDR_PLUGIN_STATE_DIR \
    "HOME=${WORK}/home" "XDG_CONFIG_HOME=${WORK}/xdg-config" "XDG_STATE_HOME=${WORK}/xdg-state" \
    "PATH=${WORK}/bin:${BASE_PATH}" "SSH_SHIM_LOG=${SHIM_LOG}" \
    "$@" bash -c "set -Eeuo pipefail
source \"${LIB}\"
${snippet}" 2>"${WORK}/stderr")" || rc=$?
  err="$(cat "${WORK}/stderr")"
}

# probe_no_timeout：PATH 里没有 timeout（验证 ConnectTimeout=8 兜底不静默崩）
probe_no_timeout() {
  local snippet="$1"
  shift
  rc=0
  out="$(env -u HERDR_PLUGIN_STATE_DIR \
    "HOME=${WORK}/home" "XDG_CONFIG_HOME=${WORK}/xdg-config" "XDG_STATE_HOME=${WORK}/xdg-state" \
    "PATH=${WORK}/sandbox-bin" "SSH_SHIM_LOG=${SHIM_LOG}" \
    "$@" bash -c "set -Eeuo pipefail
source \"${LIB}\"
${snippet}" 2>"${WORK}/stderr")" || rc=$?
  err="$(cat "${WORK}/stderr")"
}

shim_log() { cat "${SHIM_LOG}"; }

# ===========================================================================
t_describe "lib/ssh-probe.sh — ssh_probe_parse_target"

t_it "user@host -> <user@host> 22（'user@' 必须保留）"
probe 'ssh_probe_parse_target "user@host"'
t_exit_ok 0 "${rc}" "退出 0"
t_eq "user@host 22" "${out}" "user@host 默认端口 22"

t_it "user@host:2222 -> 主机与端口切分正确"
probe 'ssh_probe_parse_target "user@host:2222"'
t_exit_ok 0 "${rc}" "退出 0"
t_eq "user@host 2222" "${out}" "端口 2222"

t_it "裸 host -> 默认 22"
probe 'ssh_probe_parse_target "db.internal"'
t_exit_ok 0 "${rc}" "退出 0"
t_eq "db.internal 22" "${out}" "默认端口 22"

# --- Bug 3（用户实测）：“herdr machine add 接受 ssh:// URI 形态” ---
# 真实数据：{"target": "ssh://zheng@nj.rssyes.com:31415"}。
# 修复前 *:* 分支把 host 整串当主机（host="ssh://zheng@nj.rssyes.com"），
# ssh 收到带 scheme 的主机名 → Could not resolve。
t_it "ssh://user@host:port（A 机真实形态）-> 剥 scheme 后正确切分"
probe 'ssh_probe_parse_target "ssh://zheng@nj.rssyes.com:31415"'
t_exit_ok 0 "${rc}" "退出 0"
t_eq "zheng@nj.rssyes.com 31415" "${out}" "host 剥 ssh://，端口 31415"

t_it "ssh://host（无 user/port）-> host + 默认 22"
probe 'ssh_probe_parse_target "ssh://nj.rssyes.com"'
t_exit_ok 0 "${rc}" "退出 0"
t_eq "nj.rssyes.com 22" "${out}" "无 user 无端口"

t_it "ssh://user@host（无端口）-> user@host + 22"
probe 'ssh_probe_parse_target "ssh://zheng@nj.rssyes.com"'
t_exit_ok 0 "${rc}" "退出 0"
t_eq "zheng@nj.rssyes.com 22" "${out}" "保留 user，默认端口"

t_it "SSH://（大写 scheme）也识别（大小写不敏感）"
probe 'ssh_probe_parse_target "SSH://USER@HOST:22"'
t_exit_ok 0 "${rc}" "退出 0"
t_eq "USER@HOST 22" "${out}" "大写 scheme 同样剥除"

# 回归锁：带 scheme 的实时主机一定不能把 scheme 交给 ssh。
t_it "ssh_probe_run 不把 scheme 当主机名传给 ssh（Bug 3 回归锁）"
: >"${SHIM_LOG}"
probe 'ssh_probe_run "ssh://zheng@nj.rssyes.com:31415" "remote-cmd"'
t_exit_ok 0 "${rc}" "退出 0"
scheme_log="$(shim_log)"
t_contains "<-p> <31415>" "${scheme_log}" "端口由 -p 传递"
t_contains "<zheng@nj.rssyes.com>" "${scheme_log}" "主机已剥 scheme"
if [[ "${scheme_log}" == *"ssh://"* ]]; then
  t_fail_note "传给 ssh 的 argv 里仍有 ssh:// 前缀（ssh 会 Could not resolve）"
else
  t_pass "argv 里无 ssh:// 残留"
fi

t_it "[v6]:22 -> 去掉方括号 + 端口"
probe 'ssh_probe_parse_target "[2001:db8::1]:2222"'
t_exit_ok 0 "${rc}" "退出 0"
t_eq "2001:db8::1 2222" "${out}" "方括号只用于 IPv6 字面量定界"

t_it "[::1] 无端口 -> 主机为 ::1，端口 22"
probe 'ssh_probe_parse_target "[::1]"'
t_exit_ok 0 "${rc}" "退出 0"
t_eq "::1 22" "${out}" "无端口默认 22"

t_it "无方括号的裸 IPv6 -> 整体当主机（无法从中切端口）"
probe 'ssh_probe_parse_target "::1"'
t_exit_ok 0 "${rc}" "退出 0"
t_eq "::1 22" "${out}" "裸 IPv6 当主机 + 默认端口"

t_it "ssh:// + IPv6 方括号：scheme 剥除后方括号分支照常工作"
# 注：带 user@ 的方括号形态（user@[v6]:port）在现有三分支里本就不支持，
# 本次只加 scheme 剥除，不扩大解析语义（保持“剥完再走现有三分支”）。
probe 'ssh_probe_parse_target "ssh://[2001:db8::1]:2222"'
t_exit_ok 0 "${rc}" "退出 0"
t_eq "2001:db8::1 2222" "${out}" "剥 scheme 后再走方括号分支"

t_it "为空 -> die 64（用法错）"
probe 'ssh_probe_parse_target ""'
t_exit_ok 64 "${rc}" "空 target 退出 64"
t_match '错误|error|空' "${err}" "stderr 给出可读原因"

t_it "端口非数字 -> die 64"
probe 'ssh_probe_parse_target "user@host:ssh"'
t_exit_ok 64 "${rc}" "端口非数字退出 64"
t_contains "ssh" "${err}" "stderr 复述非法端口"

t_it "方括号未闭合 -> die 64"
probe 'ssh_probe_parse_target "[::1"'
t_exit_ok 64 "${rc}" "方括号未闭合退出 64"

t_it "方括号后非法内容 -> die 64"
probe 'ssh_probe_parse_target "[::1]x"'
t_exit_ok 64 "${rc}" "方括号后非 ':端口' 退出 64"

t_it "只有端口没有主机（:2222）-> die 64"
probe 'ssh_probe_parse_target ":2222"'
t_exit_ok 64 "${rc}" "缺主机名退出 64"

t_it "宿主已提供 die 时复用其实现（错误格式归调用方，不换成库内兜底）"
rc=0
out="$(PATH="${WORK}/bin:${BASE_PATH}" bash -c "set -Eeuo pipefail
die() { local c=\"\$1\"; shift; printf 'HOST-DIE %s: %s\n' \"\$c\" \"\$*\" >&2; exit \"\$c\"; }
source \"${LIB}\"
ssh_probe_parse_target ''" 2>&1)" || rc=$?
t_exit_ok 64 "${rc}" "仍以 64 退出"
t_contains "HOST-DIE 64" "${out}" "用的是宿主 die（setup-client.sh 的报错格式不被覆盖）"

t_it "幂等常量：调用方预置 SSH_PROBE_TIMEOUT 时库不覆盖（不触发 readonly 报错）"
rc=0
out="$(PATH="${WORK}/bin:${BASE_PATH}" bash -c "set -Eeuo pipefail
export SSH_PROBE_TIMEOUT=42
readonly SSH_PROBE_TIMEOUT
source \"${LIB}\"
printf '%s\n' \"\${SSH_PROBE_TIMEOUT}\"" 2>&1)" || rc=$?
t_exit_ok 0 "${rc}" "source 不因 readonly 报错"
t_eq "42" "${out}" "调用方（setup-client.sh）的值优先"

# ===========================================================================
t_describe "lib/ssh-probe.sh — kv_get"

t_it "第一个匹配胜出；缺失键返回空"
# 片段用**单引号 heredoc**原样收拢（含 $ 与转义，故意留给内层 bash -c 展开）
read -r -d '' kv_snippet <<'EOS' || true
printf -v raw "HF_SSH_RC=0\nHF_ROOT=/first\nHF_ROOT=/second\nOTHER=x"
printf "root=[%s]\n" "$(kv_get "$raw" HF_ROOT)"
printf "rc=[%s]\n" "$(kv_get "$raw" HF_SSH_RC)"
printf "missing=[%s]\n" "$(kv_get "$raw" HF_NOPE)"
EOS
probe "${kv_snippet}"
t_exit_ok 0 "${rc}" "退出 0"
t_contains "root=[/first]" "${out}" "取第一个 HF_ROOT"
t_contains "rc=[0]" "${out}" "HF_SSH_RC 可读"
t_contains "missing=[]" "${out}" "缺失键为空"

t_it "缩进的 LIKE=LINE 不算键（严格 ^KEY=）"
read -r -d '' kv_indent_snippet <<'EOS' || true
printf -v raw "  HF_ROOT=/indented\nHF_ROOT=/real"
printf "[%s]\n" "$(kv_get "$raw" HF_ROOT)"
EOS
probe "${kv_indent_snippet}"
t_contains "[/real]" "${out}" "只认行首 KEY="

# ===========================================================================
t_describe "lib/ssh-probe.sh — ssh_probe_run（argv 逐字 + 恒 return 0）"

t_it "无端口：argv = timeout 15 ssh -n -o BatchMode=yes -o ConnectTimeout=8 HOST CMD"
: >"${SHIM_LOG}"
probe 'ssh_probe_run "user@b-host" "remote-cmd"' SSH_SHIM_SCENARIO=present
t_exit_ok 0 "${rc}" "恒 return 0"
first_line="$(printf '%s\n' "${out}" | head -1 || true)"
t_eq "HF_SSH_RC=0" "${first_line}" "首行是 HF_SSH_RC=<rc>"
run_log="$(shim_log)"
t_contains "TIMEOUT <15>" "${run_log}" "被 timeout 15 包裹（行为级，非源码 grep）"
t_contains "<-n>" "${run_log}" "带 -n（curl|bash 形态下 ssh 不吃脚本本体）"
t_contains "<-o> <BatchMode=yes>" "${run_log}" "BatchMode 只读"
t_contains "<-o> <ConnectTimeout=8>" "${run_log}" "ConnectTimeout=8 兜底"
t_contains "<user@b-host>" "${run_log}" "主机正确"
t_contains "<remote-cmd>" "${run_log}" "远端命令作为单个实参传给 ssh"
if [[ "${run_log}" == *"<-p>"* ]]; then
  t_fail_note "未显式给端口却传了 -p（会覆盖 ssh_config 的 Port）"
else
  t_pass "无显式端口时不传 -p（交给 ssh_config）"
fi

t_it "显式端口：追加 -p PORT，主机名已剥掉端口后缀"
: >"${SHIM_LOG}"
probe 'ssh_probe_run "user@b-host:2222" "remote-cmd"'
t_exit_ok 0 "${rc}" "退出 0"
port_log="$(shim_log)"
t_contains "<-p> <2222>" "${port_log}" "端口用 -p 传递"
t_contains "<user@b-host>" "${port_log}" "主机不含端口"
if [[ "${port_log}" == *"<user@b-host:2222>"* ]]; then
  t_fail_note "主机实参仍带 :2222（拆端口失败）"
else
  t_pass "主机实参不带端口后缀"
fi

t_it "远端失败：HF_SSH_RC=<rc> 且 stdout+stderr 合并进正文，函数仍 return 0"
: >"${SHIM_LOG}"
probe 'ssh_probe_run "b@h" "remote-cmd"; printf "RC=%s\n" "$?"' \
  SSH_SHIM_SCENARIO=unreachable SSH_SHIM_HOST=b-host
t_exit_ok 0 "${rc}" "退出 0（连不上不中断调用方）"
run_first="$(printf '%s\n' "${out}" | head -1 || true)"
t_eq "HF_SSH_RC=255" "${run_first}" "rc 255 写进首行"
t_contains "Connection refused" "${out}" "stderr 被合并进正文"
t_contains "RC=0" "${out}" "函数自身 return 0"

t_it "rc 非 0 的正文顺序：首行 rc，其后逐行是合并输出"
probe 'ssh_probe_run "b@h" "c"' SSH_SHIM_FORCE_EXIT=7 SSH_SHIM_FORCE_OUT="line-A" SSH_SHIM_FORCE_ERR="line-B"
t_eq "HF_SSH_RC=7
line-A
line-B" "${out}" "首行 rc + stdout 再 stderr（2>&1 合并）"

t_it "无 timeout 的 PATH：降级为 ConnectTimeout=8 兜底，不静默崩"
: >"${SHIM_LOG}"
probe_no_timeout 'ssh_probe_run "b@h" "remote-cmd"'
t_exit_ok 0 "${rc}" "退出 0"
notimer_log="$(shim_log)"
t_contains "<-o> <ConnectTimeout=8>" "${notimer_log}" "仍带 ConnectTimeout=8"
if [[ "${notimer_log}" == *"TIMEOUT"* ]]; then
  t_fail_note "PATH 里没有 timeout 却出现了 TIMEOUT 包裹"
else
  t_pass "无 timeout 时不加前缀（文档声明的兜底路径）"
fi

# ===========================================================================
t_describe "lib/ssh-probe.sh — ssh_probe_plugin（四状态 + 调用次数）"

t_it "present：两次 ssh（list + paths），KV 含 HF_ROOT / HF_STATE_DIR"
: >"${SHIM_LOG}"
probe 'ssh_probe_plugin "b-user@b-host"'
t_exit_ok 0 "${rc}" "退出 0"
t_contains "HF_STATUS=present" "${out}" "状态 present"
t_contains "HF_ROOT=/home/b/.config/herdr/plugins/github/zzjcool-forward-deadbeef" "${out}" "插件根"
t_contains "HF_STATE_DIR=/home/b/.local/state/herdr/plugins/zzjcool%3Aforward" "${out}" "state 目录"
calls="$(grep -c '^ARGV' "${SHIM_LOG}" || true)"
t_eq "2" "${calls}" "present 需要两次 ssh（状态 + 路径）"
present_log="$(shim_log)"
t_contains "plugin list" "${present_log}" "第一次跑 herdr plugin list"

t_it "present 且 state 目录未创建：给 HF_DEFAULT_STATE（HF_STATE_DIR 缺席）"
: >"${SHIM_LOG}"
probe 'ssh_probe_plugin "b@h"' SSH_SHIM_SCENARIO=present_default_state
t_contains "HF_STATUS=present" "${out}" "状态 present"
t_contains "HF_DEFAULT_STATE=/home/b/default/state" "${out}" "默认位置"
if printf '%s\n' "${out}" | grep -q '^HF_STATE_DIR='; then
  t_fail_note "state 未创建时不应给 HF_STATE_DIR"
else
  t_pass "state 未创建时不冒充 HF_STATE_DIR"
fi

t_it "present 但读不到 plugin_root：不打印 HF_ROOT（调用方按缺席处理）"
: >"${SHIM_LOG}"
probe 'ssh_probe_plugin "b@h"' SSH_SHIM_SCENARIO=present_no_root
t_contains "HF_STATUS=present" "${out}" "状态 present"
if printf '%s\n' "${out}" | grep -q '^HF_ROOT='; then
  t_fail_note "读不到 plugin_root 却打了 HF_ROOT"
else
  t_pass "HF_ROOT 缺席"
fi

t_it "absent：一次 ssh，只有 HF_STATUS=absent"
: >"${SHIM_LOG}"
probe 'ssh_probe_plugin "b@h"' SSH_SHIM_SCENARIO=absent
t_exit_ok 0 "${rc}" "退出 0"
t_eq "HF_STATUS=absent" "${out}" "只输出状态行"
t_eq "1" "$(grep -c '^ARGV' "${SHIM_LOG}" || true)" "absent 只探测一次"

t_it "no-herdr：一次 ssh，HF_STATUS + HF_REASON（PATH 诊断，不误判为未安装）"
: >"${SHIM_LOG}"
probe 'ssh_probe_plugin "b@h"' SSH_SHIM_SCENARIO=noherdr
t_exit_ok 0 "${rc}" "退出 0"
t_contains "HF_STATUS=no-herdr" "${out}" "状态 no-herdr"
t_match 'HF_REASON=.*PATH' "${out}" "HF_REASON 说明 PATH 问题"
t_eq "1" "$(grep -c '^ARGV' "${SHIM_LOG}" || true)" "no-herdr 只探测一次"
if printf '%s\n' "${out}" | grep -q 'absent'; then
  t_fail_note "no-herdr 被误判为 absent"
else
  t_pass "no-herdr 与 absent 区分"
fi

t_it "unreachable：一次 ssh，HF_STATUS + HF_REASON（首 3 行摘要）"
: >"${SHIM_LOG}"
probe 'ssh_probe_plugin "b@h"' SSH_SHIM_SCENARIO=unreachable SSH_SHIM_HOST=b-host
t_exit_ok 0 "${rc}" "退出 0"
t_contains "HF_STATUS=unreachable" "${out}" "状态 unreachable"
t_contains "Connection refused" "${out}" "HF_REASON 带远端错误摘要"
t_eq "1" "$(grep -c '^ARGV' "${SHIM_LOG}" || true)" "unreachable 只探测一次"

t_it "自定义 plugin_id：代入远端两条命令（状态匹配与 id 编码都跟着变）"
: >"${SHIM_LOG}"
probe 'ssh_probe_plugin "b@h" "acme:other"' SSH_SHIM_SCENARIO=present SSH_SHIM_PLUGIN_ID=acme:other
t_contains "HF_STATUS=present" "${out}" "命中自定义 id"
plugin_log="$(shim_log)"
t_contains "acme:other" "${plugin_log}" "list 匹配用自定义 id"
t_contains "acme%3Aother" "${plugin_log}" "state 目录按自定义 id 编码（':' -> '%3A'）"

t_it "目标非法：die 64（与 parse_target 同源，不静默把非法 target 当主机）"
: >"${SHIM_LOG}"
probe 'ssh_probe_plugin "b@h:notaport"'
t_exit_ok 64 "${rc}" "非法端口退出 64"
t_contains "notaport" "${err}" "stderr 复述非法端口"
t_eq "0" "$(grep -c '^ARGV' "${SHIM_LOG}" || true)" "非法 target 一次 ssh 都不发"

# ===========================================================================
t_describe "静态防漂移：setup-client.sh 不再是探测实现的第二份副本"

t_it "setup-client.sh 不含 ssh 调用细节（已全部搬进 lib/ssh-probe.sh）"
# 只盯**实现构造**（argv 拼接、远端命令常量、计时器检测），不误伤注释与给用户看的排查提示
# （后者是 setup-client.sh 的对外输出，逐字不变）。
: >"${SHIM_LOG}"
for needle in 'cmd+=(ssh' 'cmd+=(-p' 'SSH_TIMER_BIN=' 'SSH_CONNECT_TIMEOUT' \
  'REMOTE_LIST_CMD=' 'REMOTE_PATHS_CMD=' 'HF_NO_HERDR' 'ssh_probe()'; do
  if grep -qF -- "${needle}" "${SETUP}"; then
    t_fail_note "setup-client.sh 仍含探测实现构造：${needle}（复制粘贴回归）"
  else
    t_pass "setup-client.sh 不含 ${needle}"
  fi
done

# 用户可见的排查提示可以照旧提到 BatchMode，但那必须出现在 printf 的字符串里，
# 不能是真正的 ssh argv 拼接。
impl_calls="$(grep -cE '^[[:space:]]*cmd\+=\(' "${SETUP}" || true)"
t_eq "0" "${impl_calls}" "setup-client.sh 里没有 cmd+=（argv 拼接已收进 lib）"

t_it "探测实现只出现在 lib/ssh-probe.sh（单一权威）"
lib_has=0
for needle in "BatchMode=yes" "REMOTE_LIST_CMD=" "REMOTE_PATHS_CMD="; do
  if grep -qF -- "${needle}" "${LIB}"; then
    lib_has=$((lib_has + 1))
  fi
done
t_eq "3" "${lib_has}" "lib 拥有全部探测实现细节"

t_it "timeout 15 的包裹在 lib 内（setup-client.sh 只保留策略常量）"
if grep -qE 'cmd\+=\("\$\{SSH_TIMER_BIN\}" "\$\{SSH_PROBE_TIMEOUT\}"\)' "${LIB}"; then
  t_pass "lib 用 \"\$SSH_TIMER_BIN\" \"\$SSH_PROBE_TIMEOUT\" 前置（挂死保护）"
else
  t_fail_note "lib 内找不到 timeout 包裹（挂死保护缺失）"
fi

t_it "lib/ssh-probe.sh shellcheck 严格模式干净（工具缺失则显式 SKIP）"
if command -v shellcheck >/dev/null 2>&1; then
  sc_rc=0
  sc_out="$(shellcheck -x -S style -o all "${LIB}" 2>&1)" || sc_rc=$?
  t_exit_ok 0 "${sc_rc}" "shellcheck 无告警（${sc_out:0:200}）"
else
  t_skip "shellcheck 未安装，无法校验 ${LIB}"
fi

t_it "lib/ssh-probe.sh shfmt 格式一致（工具缺失则显式 SKIP）"
if command -v shfmt >/dev/null 2>&1; then
  fmt_rc=0
  fmt_out="$(shfmt -d -ln bash -i 2 "${LIB}" 2>&1)" || fmt_rc=$?
  t_exit_ok 0 "${fmt_rc}" "shfmt -d 无差异（${fmt_out:0:200}）"
else
  t_skip "shfmt 未安装，无法校验 ${LIB}"
fi

# ===========================================================================
t_describe "安全：真实 ~/.config/herdr 全程零改动"

t_it "真实 config 未被本次测试触碰"
real_cfg_after="$(if [[ -f "${REAL_CFG}" ]]; then md5sum "${REAL_CFG}" | awk '{print $1}'; else printf 'absent'; fi)"
t_eq "${real_cfg_before}" "${real_cfg_after}" "${REAL_CFG} 未变"

t_done
