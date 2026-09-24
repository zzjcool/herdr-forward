#!/usr/bin/env bash
# tests/unit/test_client_forwards.sh — CLI 的 client 映射（ARCHITECTURE §A.3.3，B 侧视角）
#
# 覆盖：add --client / 有 client 在线时的隐式 client 映射 / 无 client 时维持 die 4 /
#   参数互斥与端口下限 / list（表格、--json、--oneline）的实时状态 / remove /
#   doctor --prune 不误删 / ports 标注已映射端口。
# 在线 client 用一份会话文件模拟（pid=本测试进程、心跳=现在），不起 ssh。
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
source "${ROOT}/tests/lib/assertions.sh"

unset HERDR_SOCKET_PATH HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_BIN_PATH HERDR_ENV

TMP="$(mktemp -d "${TMPDIR:-/tmp}/hf-client-fwd.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT
export HERDR_PLUGIN_STATE_DIR="${TMP}/state"
mkdir -p "${HERDR_PLUGIN_STATE_DIR}/bridge"
FW="${ROOT}/bin/forward"
SF="${HERDR_PLUGIN_STATE_DIR}/forwards.json"
SESSION="${HERDR_PLUGIN_STATE_DIR}/bridge/session-$$.json"

out=""
err=""
rc=0

reset_state() {
  rm -f "${SF}" "${SESSION}"
}

# client_online [status_json]：模拟一个在线 client（可带它对各映射的回报）
client_online() {
  local status="${1:-{\}}"
  local now=""
  now="$(date +%s)"
  printf '{"client_host":"laptop","client_label":"b-box","last_seen_unix":%s,"status":%s}\n' "${now}" "${status}" >"${SESSION}"
}

field() {
  jq -r --arg id "$1" ".forwards[] | select(.id == \$id) | $2" "${SF}"
}

t_describe "add：client 映射的登记方式"

t_it "--client：没有 client 在线也能预先登记（waiting）"
reset_state
run "${FW}" add 5173 --client
t_exit_ok 0 "${rc}" "exit 0"
t_eq "f-5173" "${out}" "stdout 只输出 id"
t_contains "没有 client 连着" "${err}" "提示连上后自动生效"
mode="$(field f-5173 .mode)"
t_eq "client" "${mode}" "mode=client"
rh="$(field f-5173 .remote_host)"
t_eq "localhost" "${rh}" "目标恒为本机 localhost"
target="$(field f-5173 .ssh_target)"
t_eq "" "${target}" "不涉及 ssh_target"

t_it "没给目标、没有 client 在线：维持原语义（die 4，并提示 --client）"
reset_state
run "${FW}" add 3000
t_exit_ok 4 "${rc}" "die 4"
t_contains "--client" "${err}" "提示 --client"

t_it "没给目标、有 client 在线：默认登记为 client 映射"
reset_state
client_online
run "${FW}" add 15173:5173
t_exit_ok 0 "${rc}" "exit 0"
t_contains "client 在线" "${err}" "提示即将生效"
mode="$(field f-15173 .mode)"
rp="$(field f-15173 .remote_port)"
t_eq "client|5173" "${mode}|${rp}" "client 映射，本机端口 5173"

t_it "--client 与 --machine/--ssh-target 互斥"
run "${FW}" add 6000 --client --ssh-target u@h:22
t_exit_ok 64 "${rc}" "互斥 -> 64"

t_it "client 映射的本地端口不得 < 1024"
run "${FW}" add 80 --client
t_exit_ok 64 "${rc}" "端口 80 -> 64"
t_contains "10080:80" "${err}" "给出可用的替代写法（替代端口本身 ≥ 1024）"

t_it "与已有记录端口冲突 -> die 2"
run "${FW}" add 15173 --client
t_exit_ok 2 "${rc}" "重复 -> 2"

t_describe "list：client 映射的实时状态"

t_it "client 未回报：pending；表格标明 client"
reset_state
"${FW}" add 5173 --client >/dev/null 2>&1
client_online
run "${FW}" list --json
st="$(printf '%s' "${out}" | jq -r '.forwards[0].status')"
t_eq "pending" "${st}" "pending"
run "${FW}" list
t_match 'client:laptop|client' "${out}" "MACHINE 列标 client"

t_it "client 回报 up：oneline 出现端口"
client_online '{"f-5173":{"state":"up","reason":""}}'
run "${FW}" list --oneline
t_eq "⇅5173" "${out}" "tab bar 行"
run "${FW}" list
t_match '5173 +localhost:5173 +client:laptop +up' "${out}" "表格一行"

t_it "client 回报 down：oneline 不显示，表格给出原因"
client_online '{"f-5173":{"state":"down","reason":"client 端口 5173 已被占用（laptop）"}}'
run "${FW}" list --oneline
t_eq "" "${out}" "down 不上 tab bar"
run "${FW}" list
t_contains "已被占用" "${out}" "原因可见"

t_it "client 离线：waiting，oneline 为空"
rm -f "${SESSION}"
run "${FW}" list --json
st="$(printf '%s' "${out}" | jq -r '.forwards[0].status')"
t_eq "waiting" "${st}" "waiting"
run "${FW}" list --oneline
t_eq "" "${out}" "空"

t_describe "remove / doctor"

t_it "remove client 映射：删记录，不碰任何隧道"
run "${FW}" remove f-5173
t_exit_ok 0 "${rc}" "exit 0"
left="$(jq '.forwards | length' "${SF}")"
t_eq "0" "${left}" "已删"

t_it "doctor --prune：清掉死的 tunnel 记录，client 映射原样保留"
reset_state
"${FW}" add 5173 --client >/dev/null 2>&1
jq '.forwards += [{"id":"f-3999","local_port":3999,"remote_host":"127.0.0.1","remote_port":1,"machine":"","ssh_target":"u@h:22","pid":null,"control_socket":"","status":"up","created_unix":1,"mode":"tunnel","publish":{"pid":null,"url":null,"started_unix":null}}]' "${SF}" >"${SF}.new"
mv "${SF}.new" "${SF}"
run "${FW}" doctor --prune
t_exit_ok 0 "${rc}" "doctor 退出 0"
ids="$(jq -r '[.forwards[].id] | join(",")' "${SF}")"
t_eq "f-5173" "${ids}" "只剩 client 映射"
t_contains "client:waiting" "${out}" "doctor 报告 client 映射状态"

t_describe "ports：标注已映射到 client 的端口"
mkdir -p "${TMP}/bin"
cat >"${TMP}/bin/ss" <<'SS'
#!/bin/sh
printf '%s\n' 'LISTEN 0 1 127.0.0.1:5173 0.0.0.0:* users:(("node",pid=1,fd=2))' 'LISTEN 0 1 0.0.0.0:8080 0.0.0.0:*'
SS
chmod +x "${TMP}/bin/ss"
PATH="${TMP}/bin:${PATH}" run "${FW}" ports
t_match '5173 +127\.0\.0\.1 +node +client:5173' "${out}" "5173 已映射"
t_match '8080 +0\.0\.0\.0 +- +-' "${out}" "8080 未映射"
PATH="${TMP}/bin:${PATH}" run "${FW}" ports --json
n="$(printf '%s' "${out}" | jq 'length')"
t_eq "2" "${n}" "--json 两条"

t_done
