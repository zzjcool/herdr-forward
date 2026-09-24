#!/usr/bin/env bash
# tests/unit/test_bridge.sh — lib/bridge.sh 契约单测（ARCHITECTURE §A.3.3）
#
# 覆盖：协议校验（A 侧的安全边界）/ SYNC 编解码 / ssh 目的地与远端命令引用 /
#   桥接 ssh 选项钉死的信任边界 / B 侧会话存活判定与实时状态合并 /
#   serve 循环（经管道驱动，不起 ssh）/ A 侧 open-url 只放行已映射端口。
# 零网络：真 ssh 的数据面在 tests/integration/test_bridge_roundtrip.sh。
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
source "${ROOT}/tests/lib/assertions.sh"

unset HERDR_SOCKET_PATH HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_BIN_PATH HERDR_ENV
unset HERDR_FORWARD_SSH_CONFIG

TMP="$(mktemp -d "${TMPDIR:-/tmp}/hf-bridge-unit.XXXXXX")"
SERVE_PID=""
cleanup() {
  if [[ -n ${SERVE_PID} ]]; then
    kill "${SERVE_PID}" 2>/dev/null || true
  fi
  rm -rf "${TMP}"
}
trap cleanup EXIT

export HERDR_PLUGIN_STATE_DIR="${TMP}/state"
mkdir -p "${HERDR_PLUGIN_STATE_DIR}"

# shellcheck source=/dev/null
source "${ROOT}/lib/common.sh"
# shellcheck source=/dev/null
source "${ROOT}/lib/state.sh"
# shellcheck source=/dev/null
source "${ROOT}/lib/bridge.sh"

out=""

# ---------------------------------------------------------------------------
t_describe "bridge_valid_entry：A 侧拒绝一切越界请求"

t_it "合法：id 与本地端口一致、端口在范围内"
run bridge_valid_entry f-5173 5173 5173
t_eq "yes" "${out}" "f-5173:5173:5173"
run bridge_valid_entry f-15432 15432 5432
t_eq "yes" "${out}" "本地/远端端口可以不同"
run bridge_valid_entry f-1080 1080 80
t_eq "yes" "${out}" "远端端口可以 < 1024（B 的 localhost:80）"

t_it "拒绝：本地端口 < 1024（A 侧普通用户不该被要求绑特权端口）"
run bridge_valid_entry f-80 80 80
t_eq "" "${out}" "f-80"
t_it "拒绝：id 与本地端口不一致"
run bridge_valid_entry f-3000 3001 3000
t_eq "" "${out}" "id 伪造"
t_it "拒绝：前导零 / 越界 / 非数字"
run bridge_valid_entry f-08080 08080 80
t_eq "" "${out}" "前导零（bash 算术会当八进制）"
run bridge_valid_entry f-70000 70000 80
t_eq "" "${out}" "本地端口越界"
run bridge_valid_entry f-3000 3000 99999
t_eq "" "${out}" "远端端口越界"
run bridge_valid_entry f-3000 3000 'x'
t_eq "" "${out}" "远端端口非数字"

# ---------------------------------------------------------------------------
t_describe "SYNC 编解码"

t_it "空集合编码为 -"
run bridge_fmt_sync '[]'
t_eq "HF1 SYNC -" "${out}" "空集合"
t_it "按顺序编码"
run bridge_fmt_sync '[{"id":"f-3000","local_port":3000,"remote_port":3000},{"id":"f-15173","local_port":15173,"remote_port":5173}]'
t_eq "HF1 SYNC f-3000:3000:3000,f-15173:15173:5173" "${out}" "两条"

t_it "解析：- 与空串都是空集合"
run bridge_parse_sync "-"
t_eq "" "${out}" "-"
run bridge_parse_sync ""
t_eq "" "${out}" "空串"

t_it "解析：非法条目丢弃、合法条目保留（含注入尝试）"
run bridge_parse_sync 'f-3000:3000:3000,f-22:22:22,f-4000:4000:4000;touch /tmp/pwn,f-5000:5000:5000:9,bogus,f-6000:6000:6000'
t_eq $'f-3000 3000 3000\nf-6000 6000 6000' "${out}" "只剩两条合法"

t_it "解析：超过上限截断"
payload=""
for p in $(seq 20001 20040); do
  payload+="f-${p}:${p}:${p},"
done
run bridge_parse_sync "${payload%,}"
lines="$(printf '%s\n' "${out}" | grep -c . || true)"
t_eq "32" "${lines}" "至多 32 条"

# ---------------------------------------------------------------------------
t_describe "ssh 目的地与远端命令"

t_it "saved machine 的各种 target 形态"
run bridge_ssh_destination "workbox"
t_eq "workbox" "${out}" "ssh config 别名原样"
run bridge_ssh_destination "me@b-host"
t_eq "me@b-host" "${out}" "user@host 原样"
run bridge_ssh_destination "me@b-host:2222"
t_eq "ssh://me@b-host:2222" "${out}" "user@host:port 转 URI（ssh 不认 host:port）"
run bridge_ssh_destination "ssh://me@b-host:31415"
t_eq "ssh://me@b-host:31415" "${out}" "ssh:// URI 原样"
run bridge_ssh_destination "[::1]:22"
t_eq "ssh://[::1]:22" "${out}" "[v6]:port 转 URI"
run bridge_ssh_destination "fe80::1"
t_eq "fe80::1" "${out}" "裸 IPv6 原样"

t_it "远端命令在 POSIX sh 下还原出原样的 argv（含空格与单引号）"
run bridge_remote_serve_cmd "/opt/my plugins/it's here" "/st ate/zzjcool%3Aforward"
cmd="${out}"
t_match "^env " "${cmd}" "以 env 起头（与远端登录 shell 无关）"
# 用 printf 顶替 env，观察远端 shell 解析后的 argv
argv="$(sh -c "env() { printf '[%s]' \"\$@\"; }; ${cmd}")"
t_eq "[HERDR_PLUGIN_STATE_DIR=/st ate/zzjcool%3Aforward][/opt/my plugins/it's here/bin/forward][bridge][serve]" "${argv}" "argv 逐字还原"

t_it "桥接 ssh 选项钉死信任边界，ControlPath 里的 % 已转义"
run bridge_ssh_args "/s/zzjcool%3Aforward/ssh-ctl/b-abc"
args="${out//$'\n'/ }"
t_contains "ForwardAgent=no" "${args}" "不转发 A 的 agent"
t_contains "ForwardX11=no" "${args}" "不转发 X11"
t_contains "ClearAllForwardings=yes" "${args}" "不带用户为 B 配的转发"
t_contains "BatchMode=yes" "${args}" "后台不弹密码"
t_contains "ControlMaster=yes" "${args}" "独立 master"
t_contains "ControlPath=/s/zzjcool%%3Aforward/ssh-ctl/b-abc" "${args}" "% 翻倍"
t_isnt "-F" "${args%% *}" "默认沿用用户 ssh 配置（无 -F）"
HERDR_FORWARD_SSH_CONFIG="/x/cfg" run bridge_ssh_args "/c"
t_eq "-F" "${out%%$'\n'*}" "HERDR_FORWARD_SSH_CONFIG -> -F"

# ---------------------------------------------------------------------------
t_describe "B 侧：会话存活与实时状态合并"

BD="$(bridge_dir)"
now="$(now_unix)"

t_it "没有会话：client 映射为 waiting，tunnel 映射原样"
forwards='[{"id":"f-5173","local_port":5173,"remote_port":5173,"mode":"client","status":"starting"},{"id":"f-3000","local_port":3000,"remote_port":9443,"mode":"tunnel","status":"up"}]'
run bridge_merge_live "${forwards}"
st="$(printf '%s' "${out}" | jq -r '[.[].status] | join(",")')"
t_eq "waiting,up" "${st}" "waiting + 原样"
run bridge_any_live
t_eq "" "${out}" "无在线 client"

t_it "在线会话但尚未回报：pending"
printf '{"client_host":"laptop","client_label":"b","last_seen_unix":%s,"status":{}}\n' "${now}" >"${BD}/session-$$.json"
run bridge_any_live
t_eq "yes" "${out}" "有在线 client"
run bridge_merge_live "${forwards}"
st="$(printf '%s' "${out}" | jq -r '.[0].status')"
t_eq "pending" "${st}" "pending"

t_it "在线会话回报 up / down(原因)"
printf '{"client_host":"laptop","last_seen_unix":%s,"status":{"f-5173":{"state":"down","reason":"client 端口 5173 已被占用"}}}\n' "${now}" >"${BD}/session-$$.json"
run bridge_merge_live "${forwards}"
st="$(printf '%s' "${out}" | jq -r '"\(.[0].status)|\(.[0].status_reason)|\(.[0].client)"')"
t_eq "down|client 端口 5173 已被占用|laptop" "${st}" "down + 原因 + client"
printf '{"client_host":"laptop","last_seen_unix":%s,"status":{"f-5173":{"state":"up","reason":""}}}\n' "${now}" >"${BD}/session-$$.json"
run bridge_merge_live "${forwards}"
st="$(printf '%s' "${out}" | jq -r '.[0].status')"
t_eq "up" "${st}" "up"

t_it "心跳超时的会话不算在线"
printf '{"client_host":"laptop","last_seen_unix":%s,"status":{"f-5173":{"state":"up"}}}\n' "$((now - 600))" >"${BD}/session-$$.json"
run bridge_merge_live "${forwards}"
st="$(printf '%s' "${out}" | jq -r '.[0].status')"
t_eq "waiting" "${st}" "过期 up 不再算数"

t_it "serve 进程已死的会话文件被清理"
dead_pid=999999
while kill -0 "${dead_pid}" 2>/dev/null; do dead_pid=$((dead_pid - 1)); done
printf '{"client_host":"ghost","last_seen_unix":%s,"status":{}}\n' "${now}" >"${BD}/session-${dead_pid}.json"
run bridge_sessions_json
t_file_absent "${BD}/session-${dead_pid}.json" "死会话文件已删"
rm -f "${BD}/session-$$.json"

t_it "多 client：任一回报 up 即 up"
sleep 60 &
other=$!
printf '{"client_host":"a1","last_seen_unix":%s,"status":{"f-5173":{"state":"down","reason":"x"}}}\n' "${now}" >"${BD}/session-$$.json"
printf '{"client_host":"a2","last_seen_unix":%s,"status":{"f-5173":{"state":"up"}}}\n' "${now}" >"${BD}/session-${other}.json"
run bridge_live_status_json
st="$(printf '%s' "${out}" | jq -r '."f-5173" | "\(.state)@\(.client)"')"
t_eq "up@a2" "${st}" "up 优先"
kill "${other}" 2>/dev/null || true
wait "${other}" 2>/dev/null || true
rm -f "${BD}"/session-*.json

# ---------------------------------------------------------------------------
t_describe "B 侧 serve 循环（经管道驱动）"

coproc SERVE { exec "${ROOT}/bin/forward" bridge serve 2>"${TMP}/serve.err"; }
SERVE_PID="${SERVE_PID:-}"
# shellcheck disable=SC2154 # SERVE_PID 由 bash 随 coproc SERVE 自动定义
serve_pid="${SERVE_PID}"
exec {s_in}<&"${SERVE[0]}" {s_out}>&"${SERVE[1]}"

# rd -> 读一行协议（5 秒超时）
rd() {
  local line=""
  IFS= read -r -t 5 -u "${s_in}" line || true
  printf '%s' "${line}"
}

t_it "开场：HELLO + 空集合 SYNC"
l1="$(rd)"
l2="$(rd)"
t_match '^HF1 HELLO [^ ]+$' "${l1}" "HELLO <host>"
t_eq "HF1 SYNC -" "${l2}" "初始空集合"
t_file_exists "${BD}/session-${serve_pid}.json" "会话文件已建"

t_it "client HELLO 后 B 视其为在线"
printf 'HF1 HELLO laptop my laptop\n' >&"${s_out}"
sleep 1.5
host="$(jq -r '"\(.client_host)|\(.client_label)"' "${BD}/session-${serve_pid}.json")"
t_eq "laptop|my laptop" "${host}" "记录 client 主机与标签"
run bridge_any_live
t_eq "yes" "${out}" "在线"

t_it "登记 client 映射 → 1 秒内推送新 SYNC"
forward_add_record '{"local_port":5173,"remote_port":5173,"mode":"client"}'
forward_add_record '{"local_port":3000,"remote_port":9443,"ssh_target":"u@h:22"}'
l3="$(rd)"
t_eq "HF1 SYNC f-5173:5173:5173" "${l3}" "只推 client 映射"

t_it "STATUS 回报写进会话文件；非法 STATUS 忽略"
printf 'HF1 STATUS f-5173 down client 端口 5173 已被占用（laptop）\n' >&"${s_out}"
printf 'HF1 STATUS ../../etc bogus\n' >&"${s_out}"
printf 'garbage line\n' >&"${s_out}"
sleep 1.5
st="$(jq -r '.status."f-5173" | "\(.state)|\(.reason)"' "${BD}/session-${serve_pid}.json")"
t_eq "down|client 端口 5173 已被占用（laptop）" "${st}" "down + 原因"
keys="$(jq -r '.status | keys | join(",")' "${BD}/session-${serve_pid}.json")"
t_eq "f-5173" "${keys}" "非法 id 未写入"

t_it "OPEN：端口出现在 SYNC 之前不发，之后才发"
bridge_enqueue_open "http://localhost:6006/x"
sleep 1.5
forward_add_record '{"local_port":6006,"remote_port":6006,"mode":"client"}'
l4="$(rd)"
l5="$(rd)"
t_eq "HF1 SYNC f-5173:5173:5173,f-6006:6006:6006" "${l4}" "先 SYNC"
t_eq "HF1 OPEN http://localhost:6006/x" "${l5}" "后 OPEN"
left="$(find "${BD}/open" -name '*.url' | wc -l)"
t_eq "0" "${left// /}" "请求已出队"

t_it "非 localhost 的打开请求直接丢弃"
bridge_enqueue_open "http://evil.example:6006/"
sleep 1.5
left="$(find "${BD}/open" -name '*.url' | wc -l)"
t_eq "0" "${left// /}" "丢弃"

t_it "映射移除后其旧状态从会话文件消失"
forward_remove_record f-5173
l6="$(rd)"
t_eq "HF1 SYNC f-6006:6006:6006" "${l6}" "新集合"
sleep 1.5
keys="$(jq -r '.status | keys | join(",")' "${BD}/session-${serve_pid}.json")"
t_eq "" "${keys}" "f-5173 的旧状态已清"

t_it "client 断开（EOF）→ serve 退出并删会话文件"
# 管道写端的每一份拷贝都要关掉，serve 才读得到 EOF
orig_w="${SERVE[1]}"
exec {s_out}>&- {orig_w}>&-
waited=0
while kill -0 "${serve_pid}" 2>/dev/null && ((waited < 50)); do
  sleep 0.1
  waited=$((waited + 1))
done
if kill -0 "${serve_pid}" 2>/dev/null; then
  t_fail "serve 在 EOF 后仍在运行"
else
  t_pass "serve 已退出"
fi
SERVE_PID=""
t_file_absent "${BD}/session-${serve_pid}.json" "会话文件已删"
exec {s_in}<&-

# ---------------------------------------------------------------------------
t_describe "A 侧：open-url 只放行已生效映射的 localhost URL"

OPENED="${TMP}/opened"
# shellcheck disable=SC2016 # $1 属于生成的 opener 脚本，不在这里展开
printf '#!/bin/sh\nprintf "%%s\\n" "$1" >>"%s"\n' "${OPENED}" >"${TMP}/opener"
chmod +x "${TMP}/opener"
export HERDR_FORWARD_OPENER="${TMP}/opener"
# shellcheck disable=SC2034 # _bridge_open_url 经动态作用域读取 supervisor 的 cl_* 变量
cl_mid="m1"
# shellcheck disable=SC2034 # 同上
declare -A cl_status=(["f-5173"]="up" ["f-6006"]="down")

t_it "已映射端口：打开"
_bridge_open_url "http://localhost:5173/app"
sleep 0.5
t_eq "http://localhost:5173/app" "$(cat "${OPENED}" 2>/dev/null || true)" "opener 收到 URL"
: >"${OPENED}"

t_it "未生效 / 未映射端口、非 localhost、带凭据的 URL：拒绝"
_bridge_open_url "http://localhost:6006/"
_bridge_open_url "http://localhost:22/"
_bridge_open_url "http://192.168.1.10:5173/"
_bridge_open_url "http://localhost@evil.example:5173/"
_bridge_open_url "file:///etc/passwd"
sleep 0.5
t_eq "" "$(cat "${OPENED}" 2>/dev/null || true)" "一个都没打开"

t_done
