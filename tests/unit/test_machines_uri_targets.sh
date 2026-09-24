#!/usr/bin/env bash
# tests/unit/test_machines_uri_targets.sh — A 机器真实数据（saved machine target = ssh:// URI）固化回归
#
# 为什么单独一个文件（漏测复盘）：
#   B 机器（开发机）上 `herdr machine add` 造出来的 saved machine target 是**裸** `user@host`
#   形态，于是 data 层 / 渲染层 / 探测层的测试全都只覆盖了裸形态。A 机器的真实数据是
#   `ssh://user@host:port` URI 形态（herdr 接受 URI），暴露了两处漏测：
#     ① `_ssh_probe_split_target` 不认 `ssh://` → 整串被当 host（ssh 解析失败）；
#     ② is_local 同机判定同样只看剥完 scheme 的形态。
#   本文件把 A 的**全量真实数据**（5 台，含中文 label）钉成 fixture，两层都断言到。
#
# 覆盖：
#   * machines_herdr_list_json 对 A 形态 JSON（pretty 真格式）的解析：5 台、id/label/target 逐字
#   * machines_view_json 的 merge 输出**保留 target 原文**（不归一化、不截断、不加引号）
#   * 中文 label「GPU机器」在 LANG/LC_ALL 未设环境下的 jq 往返不乱码（UTF-8 字节级相等）
#   * 5 台 ssh:// target 的 machines_is_local_target 恒为 no（+ 已激活后仍 no）
#   * ssh_probe_parse_target：不 die + 「<host> <port>」两字段 + 端口是数字（当前 main 通过）
#   * 剥 scheme 后的精确 host/port 与 ssh argv（`-p 31415 zheng@nj.rssyes.com`）：
#     **expected-red** —— ssh:// 剥前缀修复归 worker-15；未合入时显式 t_skip（不阻塞），
#     合入后本文件自动转绿（判据见 _scheme_fix_state）。
#
# 手法：HERDR_BIN_PATH 指向 TMP 里的假 herdr（回放 A 真实 JSON）；ssh 用 PATH 前置 shim
#       只记 argv、恒失败（**绝不真连任何主机**）；状态目录全在 TMP（零污染，不碰真实 HOME）。
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if [[ -f "${ROOT}/tests/lib/assertions.sh" ]]; then
  # shellcheck source=/dev/null
  source "${ROOT}/tests/lib/assertions.sh"
fi
if ! declare -F t_fail_note >/dev/null 2>&1; then
  t_fail_note() { t_fail "$@"; }
fi

MACHINES_LIB="${ROOT}/lib/machines.sh"
SSH_PROBE_LIB="${ROOT}/lib/ssh-probe.sh"
if [[ ! -f "${MACHINES_LIB}" ]]; then
  printf 'RED: %s 尚未实现\n' "${MACHINES_LIB}" >&2
  exit 1
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/machines-uri.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT

# --- 环境隔离：绝不动真实 ~/.config/herdr 与真实状态目录 ---
export HERDR_PLUGIN_STATE_DIR="${TMP}/state"
export HERDR_PLUGIN_CONFIG_DIR="${TMP}/config"
mkdir -p "${HERDR_PLUGIN_STATE_DIR}" "${HERDR_PLUGIN_CONFIG_DIR}" "${TMP}/bin"

# shellcheck source=/dev/null
source "${MACHINES_LIB}"
# M1 的探测库若已合入就一起加载（machines_ssh_probe_plugin 会委托它）
HAVE_PROBE=0
if [[ -f "${SSH_PROBE_LIB}" ]]; then
  # shellcheck source=/dev/null
  source "${SSH_PROBE_LIB}"
  HAVE_PROBE=1
fi

# run/断言库的公共状态
out=""
err=""
rc=0
o=""
e=""
r=0
v=""

_cap() {
  run "$@"
  o="${out}"
  e="${err}"
  r="${rc}"
  return 0
}
_capok() {
  _cap "$@"
  if [[ "${r}" -ne 0 ]]; then
    t_fail_note "命令应成功但 rc=${r}: $* （stderr: ${e}）"
  fi
}
_jqv() {
  v="$(printf '%s' "${1-}" | jq -r "${2-"."}" 2>/dev/null || true)"
}

# ---------------------------------------------------------------------------
# A 机器真实数据（用户实测 `herdr machine list --json` 原样摘录：保留 pretty 格式、
# 字段顺序与中文 label —— 这就是「漏测的那个形状」本身）。
# ---------------------------------------------------------------------------
A_FIXTURE="${TMP}/machine-list.json"
cat >"${A_FIXTURE}" <<'JSON'
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
JSON

A_IDS=(
  "191645f46cf4bc677a393cf0ca51d193"
  "0b5ecacd1e138809455cdf60fb00d81a"
  "7bfb921a0d1e6f759797e467b3360f87"
  "413b9711c1552bba29c9ace8ff8dc5a4"
  "8048d128c5b8a78a7bc10743a4c85853"
)
A_LABELS=("nj-mac" "devcloud" "nj-hw" "nj-host" "GPU机器")
A_TARGETS=(
  "ssh://zheng@nj.rssyes.com:31415"
  "ssh://root@devcloud.zzj.cool:2222"
  "ssh://zzjcool@nj.rssyes.com:31416"
  "ssh://chieh@nj.rssyes.com:31417"
  "ssh://root@zhijiezheng-any4.devcloud.woa.com:36000"
)

# 预拼接期望值（避免把命令替换嵌进断言实参：既触发 SC2312 也更难点定位）。
A_IDS_CSV="$(IFS=, && printf '%s' "${A_IDS[*]}")"
A_LABELS_CSV="$(IFS=, && printf '%s' "${A_LABELS[*]}")"
A_TARGETS_NL="$(printf '%s\n' "${A_TARGETS[@]}")"
A_RAW="$(cat "${A_FIXTURE}")"
A_ZH_BYTES_EXPECTED="$(printf '%s' 'GPU机器' | wc -c)"
A_ZH_LABEL_BYTES=$((A_ZH_BYTES_EXPECTED + 1)) # + 换行

# --- 假 herdr：回放 A 真实 JSON（事实 #1 schema 原样） ---
cat >"${TMP}/bin/herdr" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "machine" && "\$2" == "list" ]]; then
  cat '${A_FIXTURE}'
  exit 0
fi
exit 127
EOF
chmod +x "${TMP}/bin/herdr"
export HERDR_BIN_PATH="${TMP}/bin/herdr"

# --- worker-15 修复探测（输出式：避免在条件里调用函数触发 SC2310） ---
# 判据：带 scheme 的 target 必须解析出它自己的端口。未修复时 `ssh://host:1` 含 2 个 ':'
# 会落「裸 IPv6 主机」分支 -> 端口回落 22，于是判定为未修复。
_scheme_fix_state() {
  local probe=""
  probe="$(ssh_probe_parse_target "ssh://probe.invalid:1" 2>/dev/null || true)"
  if [[ "${probe}" == "probe.invalid 1" ]]; then
    printf 'yes\n'
  else
    printf 'no\n'
  fi
  return 0
}
SCHEME_FIX="no"
if [[ "${HAVE_PROBE}" -eq 1 ]]; then
  SCHEME_FIX="$(_scheme_fix_state)"
fi
if [[ "${SCHEME_FIX}" != "yes" ]]; then
  printf '# 注意：lib/ssh-probe.sh 尚未剥 ssh:// 前缀（worker-15 修复未合入）。\n'
  printf '#       「剥 scheme 后的精确 host/port」与「ssh argv 带 -p PORT」已写好并标记\n'
  printf '#       expected-red：当前显式 SKIP（不阻塞），worker-15 合入后自动转绿。\n'
fi

# --- ssh shim：只记 argv，恒失败（绝不联网、不真连） ---
export SSH_ARGV_LOG="${TMP}/ssh-argv.log"
: >"${SSH_ARGV_LOG}"
cat >"${TMP}/bin/ssh" <<'SHIM'
#!/usr/bin/env bash
printf 'ARGV' >>"${SSH_ARGV_LOG:?}"
for a in "$@"; do printf ' <%s>' "$a" >>"${SSH_ARGV_LOG}"; done
printf '\n' >>"${SSH_ARGV_LOG}"
printf 'herdr-uri-fixture: no real connection\n' >&2
exit 255
SHIM
chmod +x "${TMP}/bin/ssh"

# ---------------------------------------------------------------------------
t_describe "fixture 自检：A 真实 JSON 与断言表一致（防止本文件抄错）"

t_it "fixture 是合法 JSON，5 台 target 全是 ssh:// URI"
_capok jq empty "${A_FIXTURE}"
_jqv "${A_RAW}" 'length'
t_eq "5" "${v}" "5 台机器"
_jqv "${A_RAW}" '[.[].target | startswith("ssh://")] | all'
t_eq "true" "${v}" "target 全是 ssh:// 形态（这就是 A 的数据形状）"
_jqv "${A_RAW}" '[.[].label] | join(",")'
t_eq "nj-mac,devcloud,nj-hw,nj-host,GPU机器" "${v}" "label 顺序与断言表一致"

# ---------------------------------------------------------------------------
t_describe "machines_herdr_list_json：A 形态（pretty JSON）解析"

t_it "原样透传 5 台（id / label / target 逐字）"
_capok machines_herdr_list_json
A_LIST="${o}"
_jqv "${A_LIST}" 'length'
t_eq "5" "${v}" "透传 5 台"
_jqv "${A_LIST}" '[.[].id] | join(",")'
t_eq "${A_IDS_CSV}" "${v}" "id 顺序不变"
_jqv "${A_LIST}" '[.[].label] | join(",")'
t_eq "${A_LABELS_CSV}" "${v}" "label 顺序不变（含中文）"
_jqv "${A_LIST}" '.[0].target'
t_eq "${A_TARGETS[0]}" "${v}" "nj-mac target 原文"
_jqv "${A_LIST}" '.[4].target'
t_eq "${A_TARGETS[4]}" "${v}" "GPU机器 target 原文"

t_it "每台 target 与 fixture 原文逐字节相等（换行拼接，一次覆盖 5 台）"
_jqv "${A_LIST}" '[.[].target] | join("\n")'
t_eq "${A_TARGETS_NL}" "${v}" "5 台 target 全部未被改动"

t_it "session / enabled / selected 字段未被丢（事实 #1 schema 完整透传）"
_jqv "${A_LIST}" '[.[].session] | join(",")'
t_eq "default,default,default,default,default" "${v}" "session 保留"
_jqv "${A_LIST}" '[.[].enabled] | join(",")'
t_eq "true,true,true,true,true" "${v}" "enabled 保留"
_jqv "${A_LIST}" '[.[].selected] | join(",")'
t_eq "false,false,false,false,false" "${v}" "selected 保留"

t_it "紧凑形态（jq -c）与 pretty 形态解析结果一致"
A_COMPACT="$(jq -c '.' "${A_FIXTURE}")"
cp "${A_FIXTURE}" "${TMP}/machine-list.pretty.json"
printf '%s\n' "${A_COMPACT}" >"${A_FIXTURE}"
_capok machines_herdr_list_json
_jqv "${o}" '[.[].target] | join("\n")'
A_COMPACT_TARGETS="${v}"
cp "${TMP}/machine-list.pretty.json" "${A_FIXTURE}"
t_eq "${A_TARGETS_NL}" "${A_COMPACT_TARGETS}" "紧凑形态同样逐字保留"

# ---------------------------------------------------------------------------
t_describe "machines_view_json：merge 输出保留 target 原文"

t_it "无激活记录：5 台全 inactive，target 原文不变（不归一化、不截断）"
rm -rf "${HERDR_PLUGIN_STATE_DIR}"
mkdir -p "${HERDR_PLUGIN_STATE_DIR}"
_capok machines_view_json
A_VIEW="${o}"
_jqv "${A_VIEW}" 'length'
t_eq "5" "${v}" "视图 5 条"
_jqv "${A_VIEW}" '[.[].state] | join(",")'
t_eq "inactive,inactive,inactive,inactive,inactive" "${v}" "全 inactive"
_jqv "${A_VIEW}" '[.[].target] | join("\n")'
t_eq "${A_TARGETS_NL}" "${v}" "target 原文全部保留"
_jqv "${A_VIEW}" '[.[].id] | join(",")'
t_eq "${A_IDS_CSV}" "${v}" "id 全部保留"
_jqv "${A_VIEW}" '[.[].label] | join(",")'
t_eq "${A_LABELS_CSV}" "${v}" "label 全部保留（含中文）"

t_it "激活 nj-mac 后：state=active，target 仍保留 ssh:// 原文（记录不回写 target）"
A_REC="$(jq -c -n --arg label "${A_LABELS[0]}" --arg target "${A_TARGETS[0]}" \
  '{label: $label, ssh_target: $target, server_root: "/b/root", state_dir: "/b/state"}')"
machines_activation_set "${A_IDS[0]}" "${A_REC}"
_capok machines_view_json
_jqv "${o}" '[.[] | select(.state=="active") | .id] | join(",")'
t_eq "${A_IDS[0]}" "${v}" "nj-mac 是 active"
_jqv "${o}" '[.[] | select(.id=="'"${A_IDS[0]}"'") | .target] | join(",")'
t_eq "${A_TARGETS[0]}" "${v}" "激活后 target 仍是 ssh:// 原文（面板要显示原文）"
_jqv "${o}" '.[4].target'
t_eq "${A_TARGETS[4]}" "${v}" "其它机器 target 不受影响"
_jqv "${o}" '.[4].state'
t_eq "inactive" "${v}" "GPU机器 仍未激活"

t_it "视图稳定：同输入两次调用结果一致（面板每 3s 重绘不能抖）"
_capok machines_view_json
A_VIEW_1="${o}"
_capok machines_view_json
t_eq "${A_VIEW_1}" "${o}" "幂等输出"

t_it "machines list --short 的 TSV 里 target 列也是 ssh:// 原文"
if [[ -x "${ROOT}/bin/forward" ]]; then
  _capok env HERDR_BIN_PATH="${HERDR_BIN_PATH}" HERDR_PLUGIN_STATE_DIR="${HERDR_PLUGIN_STATE_DIR}" \
    "${ROOT}/bin/forward" machines list --short
  t_exit_ok 0 "${r}" "list --short rc=0"
  t_contains "${A_TARGETS[4]}" "${o}" "TSV 含 GPU机器 的 ssh:// target 原文"
  t_contains "GPU机器" "${o}" "TSV 含中文 label"
else
  t_skip "bin/forward 不存在，跳过 CLI 形态断言"
fi

# ---------------------------------------------------------------------------
t_describe "中文 label（GPU机器）jq 往返不乱码（LANG/LC_ALL 未设）"

# 容器/CI 里 LANG/LC_ALL 常常是空的；jq 在 C locale 下仍按 UTF-8 字节透传。
# 这里显式 unset 后再断言，确保「乱码」不会只在某台机器的环境里才出现。
t_it "LANG/LC_ALL 未设时：label 字节级相等（GPU机器 = 9 字节 UTF-8）"
cat >"${TMP}/zh_probe.sh" <<EOF
set -Eeuo pipefail
unset LANG LC_ALL LANGUAGE
export HERDR_PLUGIN_STATE_DIR="${TMP}/state-zh"
export HERDR_PLUGIN_CONFIG_DIR="${TMP}/config-zh"
export HERDR_BIN_PATH="${TMP}/bin/herdr"
mkdir -p "\${HERDR_PLUGIN_STATE_DIR}"
source "${MACHINES_LIB}"
machines_herdr_list_json | jq -r '.[4].label'
machines_view_json | jq -r '.[4].label'
machines_herdr_list_json | jq -r '.[4].label' | wc -c
EOF
_capok bash "${TMP}/zh_probe.sh"
A_ZH_LINES="${o}"
t_eq "GPU机器" "${A_ZH_LINES%%$'\n'*}" "list 的 label 未乱码"
A_ZH_VIEW_LABEL="$(printf '%s\n' "${A_ZH_LINES}" | sed -n '2p')"
t_eq "GPU机器" "${A_ZH_VIEW_LABEL}" "view 的 label 未乱码"
A_ZH_BYTES_OUT="$(printf '%s\n' "${A_ZH_LINES}" | sed -n '3p')"
t_eq "${A_ZH_LABEL_BYTES}" "${A_ZH_BYTES_OUT}" "wc -c = ${A_ZH_LABEL_BYTES}（9 字节 + 换行，未被转成 \\uXXXX 转义）"
t_eq "9" "${A_ZH_BYTES_EXPECTED}" "期望值自检：GPU机器 是 9 字节"

t_it "LANG/LC_ALL 未设时：中文 label 能被 resolve_id / lookup_json 还原"
cat >"${TMP}/zh_resolve.sh" <<EOF
set -Eeuo pipefail
unset LANG LC_ALL LANGUAGE
export HERDR_PLUGIN_STATE_DIR="${TMP}/state-zh2"
export HERDR_PLUGIN_CONFIG_DIR="${TMP}/config-zh2"
export HERDR_BIN_PATH="${TMP}/bin/herdr"
mkdir -p "\${HERDR_PLUGIN_STATE_DIR}"
source "${MACHINES_LIB}"
machines_resolve_id "GPU机器"
machines_lookup_json "${A_IDS[4]}" | jq -r '.label'
EOF
_capok bash "${TMP}/zh_resolve.sh"
A_ZH_RESOLVED_ID="$(printf '%s\n' "${o}" | sed -n '1p')"
A_ZH_RESOLVED_LABEL="$(printf '%s\n' "${o}" | sed -n '2p')"
t_eq "${A_IDS[4]}" "${A_ZH_RESOLVED_ID}" "按中文 label 解析到 id"
t_eq "GPU机器" "${A_ZH_RESOLVED_LABEL}" "lookup 回读 label 未乱码"

t_it "view 原始输出是 UTF-8 明文（不转义），含主机名明文"
_capok machines_view_json
t_contains "GPU机器" "${o}" "view 原始输出含 UTF-8 明文 label"
t_contains "zhijiezheng-any4" "${o}" "view 原始输出含主机名明文"

# ---------------------------------------------------------------------------
t_describe "machines_is_local_target：ssh:// target 一律 no（不误判同机）"

t_it "5 台 A 机器全部判为远程（no）"
for _t in "${A_TARGETS[@]}"; do
  _capok machines_is_local_target "${_t}"
  t_eq "no" "${o}" "remote: ${_t}"
done

t_it "view 里 5 台的 local 标记全 false（同机短路不会被 ssh:// 形态误触发）"
rm -rf "${HERDR_PLUGIN_STATE_DIR}"
mkdir -p "${HERDR_PLUGIN_STATE_DIR}"
_capok machines_view_json
_jqv "${o}" '[.[].local] | join(",")'
t_eq "false,false,false,false,false" "${v}" "5 台 local 全 false"

t_it "恒 return 0（可安全用于条件判断）"
_cap machines_is_local_target "${A_TARGETS[0]}"
t_eq "0" "${r}" "rc=0"

t_it "剥完 ssh:// 后若是本机名，仍应判本地（worker-15 修复项，expected-red）"
if [[ "${SCHEME_FIX}" == "yes" ]]; then
  _capok machines_is_local_target "ssh://localhost:22"
  t_eq "yes" "${o}" "ssh://localhost:22 -> yes"
  _capok machines_is_local_target "ssh://user@127.0.0.1:22"
  t_eq "yes" "${o}" "ssh://user@127.0.0.1:22 -> yes"
  _capok machines_is_local_target "ssh://nj.rssyes.com:31415"
  t_eq "no" "${o}" "ssh://nj.rssyes.com:31415 -> no（远程不因剥前缀变本地）"
else
  t_skip "expected-red：is_local 剥 scheme 归 worker-15（lib/machines.sh）；修复后本用例自动转绿"
fi

# ---------------------------------------------------------------------------
t_describe "ssh_probe_parse_target：先「不 die」后「精确 host/port」两档"

t_it "5 台 ssh:// target 都不 die，输出「<host> <port>」两字段且端口是数字"
if [[ "${HAVE_PROBE}" -eq 0 ]]; then
  t_skip "lib/ssh-probe.sh 未合入，跳过 parse 断言"
else
  for _t in "${A_TARGETS[@]}"; do
    _cap ssh_probe_parse_target "${_t}"
    t_eq "0" "${r}" "不 die（rc=0）：${_t}"
    t_match '^[^ ]+ [0-9]+$' "${o}" "两字段 + 数字端口：${_t}"
  done
fi

t_it "无 scheme 的既有形态零回归（user@host[:port] / host / [v6]:port）"
if [[ "${HAVE_PROBE}" -eq 0 ]]; then
  t_skip "lib/ssh-probe.sh 未合入，跳过 parse 断言"
else
  _capok ssh_probe_parse_target "user@b-host:22"
  t_eq "user@b-host 22" "${o}" "user@host:port"
  _capok ssh_probe_parse_target "b-host"
  t_eq "b-host 22" "${o}" "host（默认 22）"
  _capok ssh_probe_parse_target "[::1]:2222"
  t_eq "::1 2222" "${o}" "IPv6 字面量"
fi

t_it "剥 ssh:// 后精确解析出 user@host 与端口（worker-15 修复项，expected-red）"
if [[ "${HAVE_PROBE}" -eq 0 ]]; then
  t_skip "lib/ssh-probe.sh 未合入，跳过 parse 断言"
elif [[ "${SCHEME_FIX}" == "yes" ]]; then
  _capok ssh_probe_parse_target "${A_TARGETS[0]}"
  t_eq "zheng@nj.rssyes.com 31415" "${o}" "nj-mac"
  _capok ssh_probe_parse_target "${A_TARGETS[1]}"
  t_eq "root@devcloud.zzj.cool 2222" "${o}" "devcloud"
  _capok ssh_probe_parse_target "${A_TARGETS[2]}"
  t_eq "zzjcool@nj.rssyes.com 31416" "${o}" "nj-hw"
  _capok ssh_probe_parse_target "${A_TARGETS[3]}"
  t_eq "chieh@nj.rssyes.com 31417" "${o}" "nj-host"
  _capok ssh_probe_parse_target "${A_TARGETS[4]}"
  t_eq "root@zhijiezheng-any4.devcloud.woa.com 36000" "${o}" "GPU机器"
else
  t_skip "expected-red：ssh_probe_parse_target 剥 ssh:// 前缀归 worker-15（lib/ssh-probe.sh）；修复后本用例自动转绿"
fi

t_it "大写 scheme（SSH://USER@HOST:22）也过（worker-15 修复项，expected-red）"
if [[ "${HAVE_PROBE}" -eq 0 ]]; then
  t_skip "lib/ssh-probe.sh 未合入，跳过 parse 断言"
elif [[ "${SCHEME_FIX}" == "yes" ]]; then
  _capok ssh_probe_parse_target "SSH://USER@HOST:22"
  t_eq "USER@HOST 22" "${o}" "大小写不敏感剥前缀"
else
  t_skip "expected-red：scheme 大小写归 worker-15；修复后本用例自动转绿"
fi

# ---------------------------------------------------------------------------
t_describe "ssh argv：激活 ssh:// target 时的命令行组装（shim 捕获，不真连）"

# argv 期望（M1 冻结形状）：
#   ssh -n -o BatchMode=yes -o ConnectTimeout=8 [-p PORT] HOST REMOTE_CMD
# 未修复时 HOST 会带着 `ssh://` 前缀、且没有 -p（ssh 无法解析）—— 这正是 A 的实测症状。
A_ARGV=""
if [[ "${HAVE_PROBE}" -eq 1 ]]; then
  cat >"${TMP}/argv_probe.sh" <<EOF
set -Eeuo pipefail
export PATH="${TMP}/bin:\${PATH}"
source "${SSH_PROBE_LIB}"
ssh_probe_run "${A_TARGETS[0]}" "REMOTE_LIST_CMD_FIXTURE"
EOF
  _capok bash "${TMP}/argv_probe.sh"
  A_ARGV="$(cat "${SSH_ARGV_LOG}")"
fi

t_it "argv 基本形状不变（-n + BatchMode + 有界超时；绝不弹密码）"
if [[ "${HAVE_PROBE}" -eq 0 ]]; then
  t_skip "lib/ssh-probe.sh 未合入，跳过 argv 断言"
else
  t_contains "<-n>" "${A_ARGV}" "带 -n（BatchMode 下不吃 stdin）"
  t_contains "BatchMode=yes" "${A_ARGV}" "带 BatchMode=yes"
  t_contains "ConnectTimeout=8" "${A_ARGV}" "带有界连接超时"
  t_contains "REMOTE_LIST_CMD_FIXTURE" "${A_ARGV}" "远端命令作为最后一个实参"
  t_contains "ARGV" "${A_ARGV}" "ssh shim 被调用（未走真 ssh）"
fi

t_it "argv 里出现 -p 31415 + zheng@nj.rssyes.com（worker-15 修复项，expected-red）"
if [[ "${HAVE_PROBE}" -eq 0 ]]; then
  t_skip "lib/ssh-probe.sh 未合入，跳过 argv 断言"
elif [[ "${SCHEME_FIX}" == "yes" ]]; then
  t_contains "<-p> <31415>" "${A_ARGV}" "显式端口（nj-mac:31415）"
  t_contains "<zheng@nj.rssyes.com>" "${A_ARGV}" "host 无 ssh:// 前缀"
  A_ARGV_HAS_SCHEME="no"
  if [[ "${A_ARGV}" == *"ssh://"* ]]; then
    A_ARGV_HAS_SCHEME="yes"
  fi
  t_eq "no" "${A_ARGV_HAS_SCHEME}" "argv 中不含 ssh:// scheme"
else
  t_contains "ssh://zheng@nj.rssyes.com:31415" "${A_ARGV}" "当前 main：整串被当 host（症状复现，修复后本行断言改为带 -p）"
  t_skip "expected-red：ssh:// 剥前缀 + 端口传递归 worker-15；修复后本用例自动转绿"
fi

# ---------------------------------------------------------------------------
t_describe "激活链路（mock 探测）：ssh:// target 不因 scheme 短路 / 不假装 present"

t_it "machines_ssh_probe_plugin 对 ssh:// target 不 die 且不假装 present"
if [[ "${HAVE_PROBE}" -eq 0 ]]; then
  t_skip "lib/ssh-probe.sh 未合入，跳过探测桥断言"
else
  cat >"${TMP}/probe_bridge.sh" <<EOF
set -Eeuo pipefail
export PATH="${TMP}/bin:\${PATH}"
source "${MACHINES_LIB}"
source "${SSH_PROBE_LIB}"
machines_ssh_probe_plugin "${A_TARGETS[0]}"
EOF
  _capok bash "${TMP}/probe_bridge.sh"
  A_KV="${o}"
  t_contains "HF_STATUS=" "${A_KV}" "输出 §2.1 冻结的 KV 契约"
  t_isnt "HF_STATUS=present" "${A_KV}" "ssh shim 恒失败 -> 绝不假装 present（不写假路径）"
fi

t_done
