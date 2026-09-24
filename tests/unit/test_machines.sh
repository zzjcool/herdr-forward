#!/usr/bin/env bash
# tests/unit/test_machines.sh — lib/machines.sh 数据层单测（plan §2.2 / §3）
#
# 覆盖：herdr list 透传（含包了一层 machines / result.machines 的形态）/ HERDR_BIN_PATH
#       缺失或执行失败 -> [] + warn 不 die / activated-machines.json CRUD（set upsert、
#       clear_active、remove、reset、get 缺失 -> 3）/ 状态文件损坏容错（保留原文件）/
#       view_json 合并三态（active/activated/inactive/local/orphan）/ is_local_target 各形态 /
#       resolve_id 的 id 与 label 解析 / ssh 探测桥的 M1 委托点。
#
# 手法：HERDR_BIN_PATH 指向 TMP 里的假 herdr shim（echo 固定 JSON，事实 #1 schema）；
#       状态目录用 TMP，绝不触碰真实 ~/.config/herdr 或 ~/.local/state。
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
if [[ ! -f "${MACHINES_LIB}" ]]; then
  printf 'RED: %s 尚未实现\n' "${MACHINES_LIB}" >&2
  exit 1
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/machines-unit.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT

# --- 环境隔离 ---
export HERDR_PLUGIN_STATE_DIR="${TMP}/state"
export HERDR_PLUGIN_CONFIG_DIR="${TMP}/config"
mkdir -p "${HERDR_PLUGIN_STATE_DIR}" "${HERDR_PLUGIN_CONFIG_DIR}"
# shellcheck source=/dev/null
source "${MACHINES_LIB}"

# run/断言库的公共状态（test_cli.sh 同款姿势：shellcheck 看不见条件 source 分支里的定义）
out=""
err=""
rc=0
# 本文件的捕获槽（避免在断言实参里嵌套命令替换 —— shellcheck SC2312 且更难定位）
o=""
e=""
r=0
v=""

# _cap <cmd...>：执行并捕获到 o/e/r，恒不中断（命令失败不是测试失败，断言负责裁决）
_cap() {
  run "$@"
  o="${out}"
  e="${err}"
  r="${rc}"
  return 0
}

# _capok <cmd...>：同 _cap，但非零退出直接记 FAIL（"应成功"的前提被破坏）
_capok() {
  _cap "$@"
  if [[ "${r}" -ne 0 ]]; then
    t_fail_note "命令应成功但 rc=${r}: $* （stderr: ${e}）"
  fi
}

# _jqv <json> <jq-filter>：结果落 v（不做断言）
_jqv() {
  v="$(printf '%s' "${1-}" | jq -r "${2-"."}" 2>/dev/null || true)"
}

# _jqc <json> <jq-filter>：结果落 v（-c 紧凑）
_jqc() {
  v="$(printf '%s' "${1-}" | jq -c "${2-"."}" 2>/dev/null || true)"
}

# _jqf <file> <jq-filter>：从状态文件取值落 v
_jqf() {
  v="$(jq -r "${2-"."}" "${1-}" 2>/dev/null || true)"
}

SF="${HERDR_PLUGIN_STATE_DIR}/activated-machines.json"

# _fake_herdr <json-payload> [exit_rc]：写假 herdr shim 并指向它
_fake_herdr() {
  local payload="${1-}"
  local rc="${2:-0}"
  cat >"${TMP}/herdr" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "machine" && "\$2" == "list" ]]; then
  cat <<'JSONEOF'
${payload}
JSONEOF
  exit ${rc}
fi
exit 127
EOF
  chmod +x "${TMP}/herdr"
  export HERDR_BIN_PATH="${TMP}/herdr"
}

# _std_herdr：标准三台 fixture（probe=远端、gpu=远端、local=本机）
_std_herdr() {
  _fake_herdr '[{"id":"m-probe","label":"test-probe","target":"user@b-host:22","session":"default","enabled":true,"selected":false},{"id":"m-gpu","label":"gpu-box","target":"ubuntu@gpu.example.com:2222","session":"default","enabled":true,"selected":true},{"id":"m-local","label":"this-host","target":"localhost","session":"default","enabled":true,"selected":false}]'
}

_reset_state() {
  rm -rf "${HERDR_PLUGIN_STATE_DIR}"
  mkdir -p "${HERDR_PLUGIN_STATE_DIR}"
  SF="${HERDR_PLUGIN_STATE_DIR}/activated-machines.json"
}

# ---------------------------------------------------------------------------
t_describe "machines_state_file"

t_it "有 HERDR_PLUGIN_STATE_DIR 时用它"
_capok machines_state_file
t_eq "${HERDR_PLUGIN_STATE_DIR}/activated-machines.json" "${o}" "env 优先"

t_it "无 env 时回退 <HOME>/.local/state/herdr-forward/"
_cap env -u HERDR_PLUGIN_STATE_DIR bash -c "source '${MACHINES_LIB}'; machines_state_file"
t_eq "0" "${r}" "rc"
t_contains "/.local/state/herdr-forward/activated-machines.json" "${o}" "回退路径形状"

t_it "与 lib/state.sh 的 state_file 同目录（状态层单一目录）"
# 用临时脚本文件而非 bash -c 字符串：内层 $() 要留给子 bash 展开，
# 混在引号里既触发 SC2016/SC2086 也难读。
cat >"${TMP}/both_state_files.sh" <<EOF
set -Eeuo pipefail
source "${ROOT}/lib/machines.sh"
source "${ROOT}/lib/state.sh"
printf '%s\n' "\$(machines_state_file)"
printf '%s\n' "\$(state_file)"
EOF
_capok bash "${TMP}/both_state_files.sh"
MS_FILE="${o%%$'\n'*}"
SS_FILE="${o##*$'\n'}"
t_eq "$(dirname "${MS_FILE}")" "$(dirname "${SS_FILE}")" "machines 与 forwards 状态文件同目录"
t_eq "activated-machines.json" "$(basename "${MS_FILE}")" "machines 状态文件名"

# ---------------------------------------------------------------------------
t_describe "machines_herdr_list_json（事实 #1 schema 透传 + 三级降级）"

t_it "shim 返回数组：原样透传"
_reset_state
_std_herdr
_capok machines_herdr_list_json
_jqv "${o}" 'length'
t_eq "3" "${v}" "透传 3 台"
_jqv "${o}" '.[0].id'
t_eq "m-probe" "${v}" "首个 id"
_jqv "${o}" '.[1].label'
t_eq "gpu-box" "${v}" "label 保留"

t_it "只保留带 id 的对象（脏数据过滤）"
_fake_herdr '[{"id":"ok"},{"label":"no-id"},{"id":"ok2","enabled":false}]'
_capok machines_herdr_list_json
_jqv "${o}" '[.[].id] | join(",")'
t_eq "ok,ok2" "${v}" "过滤无 id 项"

t_it "接受 {\"machines\":[...]} 包裹层"
_fake_herdr '{"machines":[{"id":"wrapped","label":"w","target":"w@h","enabled":true}]}'
_capok machines_herdr_list_json
_jqv "${o}" '.[0].id'
t_eq "wrapped" "${v}" "machines 包裹层"

t_it "接受 {\"result\":{\"machines\":[...]}} 包裹层"
_fake_herdr '{"result":{"machines":[{"id":"nested","label":"n","target":"n@h","enabled":true}]}}'
_capok machines_herdr_list_json
_jqv "${o}" '.[0].id'
t_eq "nested" "${v}" "result.machines 包裹层"

t_it "HERDR_BIN_PATH 未设置 -> [] + warn（不 die）"
_reset_state
_cap env -u HERDR_BIN_PATH bash -c "source '${MACHINES_LIB}'; machines_herdr_list_json"
t_eq "[]" "${o}" "空列表"
t_eq "0" "${r}" "不因缺 env 失败"
t_contains "HERDR_BIN_PATH" "${e}" "warn 说明原因"

t_it "HERDR_BIN_PATH 指向不可执行路径 -> [] + warn"
unset HERDR_BIN_PATH
export HERDR_BIN_PATH="${TMP}/does-not-exist"
_capok machines_herdr_list_json
t_eq "[]" "${o}" "空列表"
t_contains "不可执行" "${e}" "warn 说明原因"

t_it "herdr 非零退出 -> [] + warn（不 die）"
_fake_herdr 'boo' 7
_capok machines_herdr_list_json
t_eq "[]" "${o}" "空列表"
t_eq "0" "${r}" "不 die"
t_contains "失败" "${e}" "warn 提到失败"

# Bug 2：原本 herdr 的 stderr 被 2>/dev/null 丢弃，日志里只剩 rc，用户排障时无从下手。
# 现在至少要有 rc + stderr 摘要（截断）落进 forward.log，供用户打开日志定位。
t_it "list 失败：日志里带 rc + herdr stderr 摘要（Bug 2 诊断加固）"
_reset_state
cat >"${TMP}/herdr" <<'EOF'
#!/usr/bin/env bash
printf 'herdr: cannot connect to server at /run/user/1000/herdr.sock\n' >&2
exit 7
EOF
chmod +x "${TMP}/herdr"
export HERDR_BIN_PATH="${TMP}/herdr"
_capok machines_herdr_list_json
t_eq "[]" "${o}" "空列表"
LOGFILE="${HERDR_PLUGIN_STATE_DIR}/logs/forward.log"
t_file_exists "${LOGFILE}" "warn 已落日志文件"
logtail="$(cat "${LOGFILE}" 2>/dev/null || true)"
t_contains "rc=7" "${logtail}" "日志含退出码 rc=7"
t_contains "cannot connect to server" "${logtail}" "日志含 herdr stderr 摘要（不再被 2>/dev/null 吞掉）"

# timeout 杀掉（rc=124）也属于「herdr 挂了」：stderr 可能为空，但 rc 必须在日志里。
t_it "list 超时/被杀：日志里带 rc 且不崩（诊断信息不丢）"
_reset_state
cat >"${TMP}/herdr" <<'EOF'
#!/usr/bin/env bash
sleep 30
EOF
chmod +x "${TMP}/herdr"
export HERDR_BIN_PATH="${TMP}/herdr"
# MACHINES_HERDR_TIMEOUT 是 readonly（模块内定义），无法重设；用 timeout shim 让
# 外层 timeout 立即失败，模拟「herdr 卡住被杀」而不真等 5 秒。
mkdir -p "${TMP}/fast-timeout"
cat >"${TMP}/fast-timeout/timeout" <<'EOF'
#!/usr/bin/env bash
shift || true
exit 124
EOF
chmod +x "${TMP}/fast-timeout/timeout"
_cap env PATH="${TMP}/fast-timeout:${PATH}" bash -c "source '${MACHINES_LIB}'; machines_herdr_list_json"
t_eq "[]" "${o}" "超时 -> 空列表"
t_eq "0" "${r}" "不 die"
_tf="${TMP}/fast-timeout/my-state"
set +o errexit
out="$(env PATH="${TMP}/fast-timeout:${PATH}" HERDR_PLUGIN_STATE_DIR="${_tf}" HERDR_BIN_PATH="${TMP}/herdr" \
  bash -c "source '${MACHINES_LIB}'; machines_herdr_list_json" 2>&1)"
set -o errexit
t_contains "124" "${out}" "rc=124 可见（用户知道是超时不是空配置）"

t_it "输出不是 JSON -> [] + warn（不 die）"
_fake_herdr 'not json at all'
_capok machines_herdr_list_json
t_eq "[]" "${o}" "空列表"
t_contains "JSON" "${e}" "warn 提到 JSON"

t_it "合法 JSON 但非数组/非对象 -> []"
_fake_herdr '"a string"'
_capok machines_herdr_list_json
t_eq "[]" "${o}" "空列表"

# ---------------------------------------------------------------------------
t_describe "machines_activation_load / save（§1 schema + 损坏容错）"

t_it "文件不存在：空文档（正常首次运行，不 warn）"
_reset_state
_capok machines_activation_load
_jqv "${o}" '.version'
t_eq "1" "${v}" "version=1"
_jqv "${o}" '.active'
t_eq "null" "${v}" "active=null"
_jqc "${o}" '.machines'
t_eq "{}" "${v}" "machines={}"

t_it "文件损坏（非 JSON）：空文档 + warn，且原文件保留未被覆盖"
_reset_state
printf '{ this is not json' >"${SF}"
_capok machines_activation_load
_jqc "${o}" '.machines'
t_eq "{}" "${v}" "损坏 -> 空文档"
t_contains "不可解析" "${e}" "warn 说明"
_jqf "${SF}" '.version'
t_eq "" "${v}" "原文件保留（读不出 version 说明没被覆盖成合法文档）"

t_it "文件是数组（非对象）：空文档 + warn"
_reset_state
printf '[1,2,3]' >"${SF}"
_capok machines_activation_load
_jqc "${o}" '.machines'
t_eq "{}" "${v}" "非对象 -> 空文档"

t_it "machines 字段是数组：空文档 + warn"
_reset_state
printf '{"version":1,"active":null,"machines":[1]}' >"${SF}"
_capok machines_activation_load
_jqc "${o}" '.machines'
t_eq "{}" "${v}" "machines 非对象 -> 空文档"

t_it "active 是非法类型（数字）时归一化为 null"
_reset_state
printf '{"version":1,"active":42,"machines":{}}' >"${SF}"
_capok machines_activation_load
_jqv "${o}" '.active'
t_eq "null" "${v}" "非法 active 归一化"

t_it "save 拒绝非对象 / 缺 machines / 非 JSON 输入（die 1）"
_reset_state
_cap machines_activation_save '[1,2]'
t_exit_ok 1 "${r}" "数组输入 -> die 1"
_cap machines_activation_save '{"active":null}'
t_exit_ok 1 "${r}" "缺 machines -> die 1"
_cap machines_activation_save 'not json'
t_exit_ok 1 "${r}" "非 JSON -> die 1"

t_it "save 落盘合法 JSON 且 version/active/machines 齐备"
_reset_state
machines_activation_save '{"version":1,"active":"m1","machines":{"m1":{"label":"x"}}}'
t_json_valid "${SF}" "落盘 JSON 合法"
_jqf "${SF}" '.active'
t_eq "m1" "${v}" "active 写入"
_jqf "${SF}" '.version'
t_eq "1" "${v}" "version=1"

# ---------------------------------------------------------------------------
t_describe "machines_activation_set / get / has / clear_active / remove / reset"

t_it "set 写入记录、置 active、并自动补 activated_unix"
_reset_state
machines_activation_set m-probe '{"label":"test-probe","ssh_target":"user@b-host:22","server_root":"/b/root","state_dir":"/b/state"}'
_jqf "${SF}" '.active'
t_eq "m-probe" "${v}" "active=m-probe"
_jqf "${SF}" '.machines["m-probe"].label'
t_eq "test-probe" "${v}" "label"
_jqf "${SF}" '.machines["m-probe"].server_root'
t_eq "/b/root" "${v}" "server_root"
_jqf "${SF}" '.machines["m-probe"].state_dir'
t_eq "/b/state" "${v}" "state_dir"
_jqf "${SF}" '.machines["m-probe"].activated_unix'
t_match '^[0-9]+$' "${v}" "activated_unix 已补"

t_it "set 是 upsert：同 id 覆盖、切换 active、其它 id 记录保留（切换语义）"
machines_activation_set m-gpu '{"label":"gpu-box","ssh_target":"ubuntu@gpu:2222"}'
machines_activation_set m-probe '{"label":"test-probe","ssh_target":"user@b-host:22","server_root":"/b/root2","state_dir":"/b/state"}'
_jqf "${SF}" '.machines | length'
t_eq "2" "${v}" "两台记录都在"
_jqf "${SF}" '.active'
t_eq "m-probe" "${v}" "active 切回 m-probe"
_jqf "${SF}" '.machines["m-probe"].server_root'
t_eq "/b/root2" "${v}" "记录被覆盖"
_jqf "${SF}" '.machines["m-gpu"].label'
t_eq "gpu-box" "${v}" "另一台记录未被删"

t_it "set 幂等：同内容重复 set 不产生重复条目"
machines_activation_set m-probe '{"label":"test-probe","ssh_target":"user@b-host:22","server_root":"/b/root2","state_dir":"/b/state"}'
_jqf "${SF}" '.machines | length'
t_eq "2" "${v}" "条目数不变"

t_it "set 拒绝非法 record / 空 id（die 1）"
_cap machines_activation_set m1 '[]'
t_exit_ok 1 "${r}" "数组 record -> die 1"
_cap machines_activation_set "" '{}'
t_exit_ok 1 "${r}" "空 id -> die 1"

t_it "get 命中返回记录；不存在 die 3 且指引 machines list"
_capok machines_activation_get m-gpu
_jqv "${o}" '.label'
t_eq "gpu-box" "${v}" "get 命中"
_cap machines_activation_get nope
t_exit_ok 3 "${r}" "缺失 -> die 3"
t_contains "machines list" "${e}" "指引 machines list"

t_it "activation_has 恒 return 0，stdout yes|no"
_capok machines_activation_has m-probe
t_eq "yes" "${o}" "有记录 -> yes"
t_eq "0" "${r}" "rc=0"
_capok machines_activation_has nope
t_eq "no" "${o}" "无记录 -> no"

t_it "activation_active 返回当前 active；无则空行"
_capok machines_activation_active
t_eq "m-probe" "${o}" "active id"
machines_activation_clear_active
_capok machines_activation_active
t_eq "" "${o}" "清空后为空"

t_it "clear_active 只清 active，记录保留（历史可见）"
_jqf "${SF}" '.active'
t_eq "null" "${v}" "active 清空"
_jqf "${SF}" '.machines | length'
t_eq "2" "${v}" "记录保留"

t_it "remove 删单条；它若正是 active 则同时清 active"
machines_activation_set m-probe '{"label":"test-probe"}'
machines_activation_remove m-probe
_jqf "${SF}" '.active'
t_eq "null" "${v}" "active 同清"
_jqf "${SF}" '.machines | length'
t_eq "1" "${v}" "只剩 m-gpu"
_jqf "${SF}" '.machines | keys[0]'
t_eq "m-gpu" "${v}" "删对了"

t_it "reset 清空 active + 全部记录"
machines_activation_reset
_jqf "${SF}" '.active'
t_eq "null" "${v}" "active null"
_jqf "${SF}" '.machines'
t_eq "{}" "${v}" "machines 空"

# ---------------------------------------------------------------------------
t_describe "machines_is_local_target（只认强信号，§5 风险 #2）"

t_it "localhost / 127.0.0.1 / ::1 / [::1] 及 user@:port 形态 -> yes"
for _t in localhost LOCALHOST 127.0.0.1 ::1 "[::1]" "localhost:22" "user@localhost:22" "user@127.0.0.1" "user@[::1]:2222"; do
  _capok machines_is_local_target "${_t}"
  t_eq "yes" "${o}" "local: ${_t}"
done

# 本机主机名候选（顺序与 lib 的 _machines_host_names 一致）。
# 容器（archlinux 基础镜像）没有 hostname 可执行文件，退回 uname -n / $HOSTNAME；
# 两者都拿不到就显式 t_skip（绝不静默通过，也绝不因缺工具就让整个文件 rc=127 崩掉）。
host_name() {
  local got=""
  got="$(hostname 2>/dev/null || true)"
  [[ -n "${got}" ]] || got="$(uname -n 2>/dev/null || true)"
  [[ -n "${got}" ]] || got="${HOSTNAME:-}"
  printf '%s\n' "${got}"
}

t_it "本机 hostname（短名）精确等值 -> yes"
HOST_FULL="$(host_name)"
HOST_SHORT="$(hostname -s 2>/dev/null || true)"
[[ -n "${HOST_SHORT}" ]] || HOST_SHORT="${HOST_FULL}"
if [[ -z "${HOST_FULL}" ]]; then
  t_skip "本机取不到主机名（无 hostname/uname -n/\$HOSTNAME）"
fi
if [[ -n "${HOST_FULL}" ]]; then
  _capok machines_is_local_target "${HOST_FULL}"
  t_eq "yes" "${o}" "hostname: ${HOST_FULL}"
  _capok machines_is_local_target "user@${HOST_FULL}:22"
  t_eq "yes" "${o}" "user@hostname:port"
  _capok machines_is_local_target "${HOST_SHORT}"
  t_eq "yes" "${o}" "hostname -s: ${HOST_SHORT}"
else
  t_skip "无主机名可用，跳过 hostname 系列用例"
fi

t_it "远程主机 / 前缀相似名 / 空值 -> no（不误判为同机）"
for _t in "user@b-host:22" "gpu.example.com" "127.0.0.2" "127.0.0.10" "notlocalhost" "malocalhost" "user@remote" ""; do
  _capok machines_is_local_target "${_t}"
  t_eq "no" "${o}" "remote: ${_t:-<empty>}"
done
if [[ -n "${HOST_FULL}" ]]; then
  _capok machines_is_local_target "${HOST_FULL}.example.com"
  t_eq "no" "${o}" "remote: ${HOST_FULL}.example.com（FQDN 后缀，不是本机精确名）"
fi

# Bug 3：herdr machine add 接受 ssh:// URI 形态；is_local 必须先剥 scheme 再比，
# 否则 'ssh://localhost:22' 会被当作远程机（多跑一次必败的探测）。
t_it "ssh:// URI 形态：剥 scheme 后再判同机（Bug 3）"
for _t in "ssh://localhost" "ssh://localhost:22" "ssh://user@localhost:22" "SSH://127.0.0.1" "ssh://user@127.0.0.1:2222"; do
  _capok machines_is_local_target "${_t}"
  t_eq "yes" "${o}" "local(ssh://): ${_t}"
done

# 用户 A 机的真实形态：ssh://zheng@nj.rssyes.com:31415 必须判 not local（不得把 scheme 当主机名）。
t_it "A 机真实形态 ssh://zheng@nj.rssyes.com:31415 -> no（Bug 3 回归锁）"
_capok machines_is_local_target "ssh://zheng@nj.rssyes.com:31415"
t_eq "no" "${o}" "nj-mac 形态 -> no"
_capok machines_is_local_target "ssh://nj.rssyes.com"
t_eq "no" "${o}" "无 user/port 的 ssh:// 也 no"
if [[ -n "${HOST_FULL}" ]]; then
  _capok machines_is_local_target "ssh://${HOST_FULL}:2222"
  t_eq "yes" "${o}" "本机名的 ssh:// 形态 -> yes"
fi

t_it "恒 return 0（可安全用于条件判断）"
_cap machines_is_local_target "user@b-host:22"
t_eq "0" "${r}" "rc=0"

# ---------------------------------------------------------------------------
t_describe "machines_view_json（合并三态，面板/CLI 单一权威）"

t_it "无激活记录：inactive + 同机项 local"
_reset_state
_std_herdr
_capok machines_view_json
_jqv "${o}" 'length'
t_eq "3" "${v}" "3 条"
_jqv "${o}" '[.[] | select(.id=="m-probe") | .state] | join(",")'
t_eq "inactive" "${v}" "m-probe inactive"
_jqv "${o}" '[.[] | select(.id=="m-local") | .state] | join(",")'
t_eq "local" "${v}" "m-local local"
_jqv "${o}" '[.[] | select(.id=="m-local") | .local] | join(",")'
t_eq "true" "${v}" "local 标记"
_jqv "${o}" '[.[] | select(.id=="m-probe") | .orphan] | join(",")'
t_eq "false" "${v}" "非 orphan"
_jqv "${o}" '[.[] | select(.id=="m-gpu") | .target] | join(",")'
t_eq "ubuntu@gpu.example.com:2222" "${v}" "target 透传"
_jqv "${o}" '[.[] | select(.id=="m-gpu") | .enabled] | join(",")'
t_eq "true" "${v}" "enabled 透传"

t_it "激活一台后：active / inactive / local 三态齐备"
machines_activation_set m-gpu '{"label":"gpu-box","ssh_target":"ubuntu@gpu.example.com:2222","server_root":"/b/r","state_dir":"/b/s"}'
_capok machines_view_json
_jqv "${o}" '[.[] | select(.id=="m-gpu") | .state] | join(",")'
t_eq "active" "${v}" "m-gpu active"
_jqv "${o}" '[.[] | select(.id=="m-probe") | .state] | join(",")'
t_eq "inactive" "${v}" "m-probe inactive"
_jqv "${o}" '[.[] | select(.id=="m-local") | .state] | join(",")'
t_eq "local" "${v}" "m-local local"

t_it "切换 active：旧机器变 activated（记录保留），新机器 active"
machines_activation_set m-probe '{"label":"test-probe","ssh_target":"user@b-host:22","server_root":"/b/r2","state_dir":"/b/s2"}'
_capok machines_view_json
_jqv "${o}" '[.[] | select(.id=="m-probe") | .state] | join(",")'
t_eq "active" "${v}" "新 active"
_jqv "${o}" '[.[] | select(.id=="m-gpu") | .state] | join(",")'
t_eq "activated" "${v}" "旧机器 activated"
_jqf "${SF}" '.machines | length'
t_eq "2" "${v}" "两条记录"

t_it "clear_active 后：曾激活的显示 activated，无 active"
machines_activation_clear_active
_capok machines_view_json
_jqv "${o}" '[.[] | select(.id=="m-probe") | .state] | join(",")'
t_eq "activated" "${v}" "m-probe activated"
_jqv "${o}" '[.[] | select(.state=="active")] | length'
t_eq "0" "${v}" "无 active"

t_it "同机且已激活：state=active 且保留 local 标记"
_reset_state
machines_activation_set m-local '{"label":"this-host","ssh_target":"localhost","local":true,"server_root":"/a/root","state_dir":"/a/state"}'
_capok machines_view_json
_jqv "${o}" '[.[] | select(.id=="m-local") | .state] | join(",")'
t_eq "active" "${v}" "同机 active"
_jqv "${o}" '[.[] | select(.id=="m-local") | .local] | join(",")'
t_eq "true" "${v}" "local 标记保留"

t_it "herdr 列表里已不存在的激活记录 -> orphan 条目（可被发现/停用）"
_reset_state
machines_activation_set m-gone '{"label":"gone-box","ssh_target":"user@gone:22","server_root":"/g","state_dir":"/gs"}'
_fake_herdr '[{"id":"m-probe","label":"test-probe","target":"user@b-host:22","enabled":true}]'
_capok machines_view_json
_jqv "${o}" 'length'
t_eq "2" "${v}" "含 orphan"
_jqv "${o}" '[.[] | select(.id=="m-gone") | .orphan] | join(",")'
t_eq "true" "${v}" "orphan 标记"
_jqv "${o}" '[.[] | select(.id=="m-gone") | .state] | join(",")'
t_eq "active" "${v}" "orphan 且 active 可见"
_jqv "${o}" '[.[] | select(.id=="m-gone") | .label] | join(",")'
t_eq "gone-box" "${v}" "orphan label 取自记录"
_jqv "${o}" '[.[] | select(.id=="m-gone") | .target] | join(",")'
t_eq "user@gone:22" "${v}" "orphan target 取自记录"

t_it "herdr 不可用且无激活记录：[]（不 die，面板可退化）"
_reset_state
_cap env -u HERDR_BIN_PATH bash -c "source '${MACHINES_LIB}'; machines_view_json"
t_eq "[]" "${o}" "空视图"
t_eq "0" "${r}" "不 die"

t_it "输出恒为 jq 可解析的数组"
_std_herdr
machines_activation_set m-probe '{"label":"test-probe"}'
_capok machines_view_json
_jqv "${o}" 'type'
t_eq "array" "${v}" "顶层是数组"

t_it "输出稳定排序（同输入两次调用结果一致）"
_capok machines_view_json
FIRST="${o}"
_capok machines_view_json
t_eq "${FIRST}" "${o}" "幂等输出"

# ---------------------------------------------------------------------------
t_describe "machines_lookup_json / machines_resolve_id（id|label 双入口）"

t_it "lookup by id 命中 herdr 列表"
_reset_state
_std_herdr
_capok machines_lookup_json m-probe
_jqv "${o}" '.target'
t_eq "user@b-host:22" "${v}" "target"
_jqv "${o}" '.label'
t_eq "test-probe" "${v}" "label"

t_it "lookup 未命中列表但命中激活记录（orphan）"
machines_activation_set m-gone '{"label":"gone-box","ssh_target":"user@gone:22"}'
_capok machines_lookup_json m-gone
_jqv "${o}" '.target'
t_eq "user@gone:22" "${v}" "从记录取 target"
_jqv "${o}" '.label'
t_eq "gone-box" "${v}" "从记录取 label"

t_it "lookup 两边都没有 -> die 3"
_cap machines_lookup_json nope
t_exit_ok 3 "${r}" "die 3"

t_it "resolve_id 接受 label（大小写不敏感）"
_capok machines_resolve_id test-probe
t_eq "m-probe" "${o}" "label -> id"
_capok machines_resolve_id TEST-PROBE
t_eq "m-probe" "${o}" "label 大小写不敏感"

t_it "resolve_id 接受 id 本身"
_capok machines_resolve_id m-gpu
t_eq "m-gpu" "${o}" "id 直接命中"

t_it "resolve_id 找不到 -> die 3 且列出可用 machine"
_cap machines_resolve_id definitely-nope
t_exit_ok 3 "${r}" "die 3"
t_contains "m-probe" "${e}" "错误里列出可用 id"

t_it "HERDR_BIN_PATH 缺失时仍能命中激活记录里的 label"
machines_activation_set m-gone '{"label":"gone-box"}'
_cap env -u HERDR_BIN_PATH bash -c "source '${MACHINES_LIB}'; machines_resolve_id gone-box"
t_eq "m-gone" "${o}" "从记录解析"
t_eq "0" "${r}" "rc=0"

# ---------------------------------------------------------------------------
t_describe "machines_kv_get（与 M1 lib/ssh-probe.sh 的 kv_get 同语义）"

KV_TEXT=$'HF_STATUS=present\nHF_ROOT=/home/me/plugins/fwd\nHF_STATE_DIR=/home/me/.local/state/herdr/plugins/zzjcool%3Aforward'

t_it "取第一个 KEY= 的值；键不存在 / 空输入 -> 空"
_capok machines_kv_get "${KV_TEXT}" HF_STATUS
t_eq "present" "${o}" "HF_STATUS"
_capok machines_kv_get "${KV_TEXT}" HF_ROOT
t_eq "/home/me/plugins/fwd" "${o}" "HF_ROOT"
_capok machines_kv_get "${KV_TEXT}" HF_STATE_DIR
t_eq "/home/me/.local/state/herdr/plugins/zzjcool%3Aforward" "${o}" "HF_STATE_DIR（含 %3A）"
_capok machines_kv_get "${KV_TEXT}" HF_MISSING
t_eq "" "${o}" "缺键 -> 空"
_capok machines_kv_get "" HF_STATUS
t_eq "" "${o}" "空输入 -> 空"

t_it "恒 return 0"
_cap machines_kv_get "" NOTHING
t_eq "0" "${r}" "rc=0"

# ---------------------------------------------------------------------------
t_describe "machines_ssh_probe_plugin（M1 联调点）"

t_it "M1 的 ssh_probe_plugin 未定义时降级 unreachable + 原因（绝不输出 present）"
if declare -F ssh_probe_plugin >/dev/null 2>&1; then
  t_skip "lib/ssh-probe.sh 已合入，本用例只覆盖未合入的降级路径"
else
  _capok machines_ssh_probe_plugin "user@b-host:22"
  # 先落变量：继续用 _cap 会把 o 覆盖（_cap 同时是「读上一个输出」和「写下一次输出」）
  PROBE_OUT="${o}"
  t_contains "HF_STATUS=unreachable" "${PROBE_OUT}" "降级为 unreachable"
  t_contains "HF_REASON=" "${PROBE_OUT}" "给出原因"
  _cap machines_kv_get "${PROBE_OUT}" HF_STATUS
  t_isnt "present" "${o}" "绝不假装 present"
fi

t_it "M1 合入后本函数委托给它（注入假 ssh_probe_plugin 验证委托与 KV 透传）"
_cap bash -c '
set -Eeuo pipefail
source "'"${MACHINES_LIB}"'"
ssh_probe_plugin() { printf "HF_STATUS=present\nHF_ROOT=/delegated/root\nHF_STATE_DIR=/delegated/state\n"; }
machines_ssh_probe_plugin "user@b-host:22"
'
t_eq "0" "${r}" "rc=0"
DELEGATED_OUT="${o}"
_cap machines_kv_get "${DELEGATED_OUT}" HF_STATUS
t_eq "present" "${o}" "委托给 M1 实现"
_cap machines_kv_get "${DELEGATED_OUT}" HF_ROOT
t_eq "/delegated/root" "${o}" "HF_ROOT 透传"
_cap machines_kv_get "${DELEGATED_OUT}" HF_STATE_DIR
t_eq "/delegated/state" "${o}" "HF_STATE_DIR 透传"

t_done
