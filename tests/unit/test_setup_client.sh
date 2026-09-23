#!/usr/bin/env bash
# tests/unit/test_setup_client.sh — 跨机 client 一键配置：scripts/setup-client.sh
#
# 场景（用户视角）：A（本地 herdr client）SSH attach 到 B（远程 server，插件装在 B）。
# A 侧要「一键配置、不再手工贴 TOML」：A 只需要 client config.toml 里的
#   ① [[keys.command]] plugin_action 绑定（触发时 herdr 让 server 上的插件执行，A 无需装插件）
#   ② [ui].tab_bar_right command 条目（command 在 **server B** 上执行，故必须写 B 的路径）
# setup-client.sh 是**编排层**：参数校验 → 依次调 install-tabbar.sh / install-keys.sh
# （跨机语义与幂等由这两个安装器实现并有各自测试）→ 汇总 + B 侧前置条件 checklist。
#
# 本测试覆盖：
#   - --help / 未知参数 / 缺 --server-root / 两个 --no-* 同时给 → 参数校验
#   - 真实安装器编排：config 里同时出现 tab bar 条目 + 3 条键位
#   - 参数透传（--server-root/--server-state-dir/--config 各自的落点）与调用顺序
#   - 跳过开关 --no-keys / --no-tabbar
#   - 幂等：跑两次 config 逐字节不变，第二次都是 already installed
#   - 汇总输出含 reload 提示 + B 侧 checklist
#   - 安装器失败传导（tabbar 失败 → 不再跑 keys；退出码非 0）
#   - state 目录推导（从 --server-root 的 manifest id 推导，':' → '%3A'）
#   - B 侧插件可用性探测两分支（fixture：有 / 无插件安装），探测失败绝不阻塞
#   - curl|bash 形态（无同目录安装器时从 HF_RAW_BASE 拉取；拉取失败 → 友好报错）
#   - shellcheck/shfmt 干净；README 与脚本的防漂移断言
#   - 全局安全断言：真实 ~/.config/herdr 永远不被触碰
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SETUP="${ROOT}/scripts/setup-client.sh"

if [[ -f "${ROOT}/tests/lib/assertions.sh" ]]; then
  # shellcheck source=/dev/null
  source "${ROOT}/tests/lib/assertions.sh"
fi
if ! declare -F t_fail_note >/dev/null 2>&1; then
  t_fail_note() { t_fail "$@"; }
fi

if [[ ! -f "${SETUP}" ]]; then
  echo "RED: ${SETUP} 不存在（scripts/setup-client.sh 尚未实现）" >&2
  exit 1
fi

# 真实环境的 config：全程必须零改动（本测试只用沙箱 HOME/XDG 路径）
REAL_HOME="${HOME:-}"
REAL_CFG="${REAL_HOME}/.config/herdr/config.toml"
real_cfg_before="$(if [[ -f "${REAL_CFG}" ]]; then md5sum "${REAL_CFG}" | awk '{print $1}'; else printf 'absent'; fi)"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

mkdir -p "${WORK}/home" "${WORK}/xdg-config" "${WORK}/xdg-state"

# 被测脚本 + 环境（沙箱 HOME / XDG；HERDR_PLUGIN_STATE_DIR 剔除以避免宿主污染）
SETUP_BIN="${SETUP}"
setup_env=(
  "HOME=${WORK}/home"
  "XDG_CONFIG_HOME=${WORK}/xdg-config"
  "XDG_STATE_HOME=${WORK}/xdg-state"
)

rc=0
out=""
err=""

run_setup() {
  rc=0
  out="$(env -u HERDR_PLUGIN_STATE_DIR "${setup_env[@]}" bash "${SETUP_BIN}" "$@" 2>"${WORK}/stderr")" || rc=$?
  err="$(cat "${WORK}/stderr")"
}

# 同 run_setup，但不设 XDG_CONFIG_HOME（验证默认路径退回 $HOME/.config）
run_setup_noxdg() {
  rc=0
  out="$(env -u HERDR_PLUGIN_STATE_DIR -u XDG_CONFIG_HOME \
    "HOME=${WORK}/home" "XDG_STATE_HOME=${WORK}/xdg-state" \
    bash "${SETUP_BIN}" "$@" 2>"${WORK}/stderr")" || rc=$?
  err="$(cat "${WORK}/stderr")"
}

md5() { md5sum "$1" | awk '{print $1}'; }

# 本插件在沙箱里的默认 state 目录（XDG_STATE_HOME 隔离后 install-tabbar.sh 的推导值）
sandbox_state_dir() { printf '%s/herdr/plugins/zzjcool%%3Aforward' "${WORK}/xdg-state"; }

# keys_count <toml> -> 本插件 plugin_action 键位数
keys_count() {
  python3 - "$1" <<'PY'
import sys, tomllib
try:
    with open(sys.argv[1], "rb") as fh:
        doc = tomllib.load(fh)
except Exception:
    print(-1)
    raise SystemExit(0)
entries = (doc.get("keys") or {}).get("command") or []
print(sum(1 for e in entries if str(e.get("command", "")).startswith("zzjcool:forward.")))
PY
}

# tabbar_count <toml> -> 本插件 tab_bar_right 条目数
tabbar_count() {
  python3 - "$1" <<'PY'
import sys, tomllib
try:
    with open(sys.argv[1], "rb") as fh:
        doc = tomllib.load(fh)
except Exception:
    print(-1)
    raise SystemExit(0)
print(sum(1 for e in ((doc.get("ui") or {}).get("tab_bar_right") or [])
          if isinstance(e, dict) and "bin/forward" in str(e.get("command", ""))))
PY
}

# tabbar_command <toml> -> tab_bar_right 里本插件的 command（无则空）
tabbar_command() {
  python3 - "$1" <<'PY' 2>/dev/null || true
import sys, tomllib
try:
    with open(sys.argv[1], "rb") as fh:
        doc = tomllib.load(fh)
    for e in ((doc.get("ui") or {}).get("tab_bar_right") or []):
        if isinstance(e, dict) and "bin/forward" in str(e.get("command", "")):
            print(e["command"])
            break
except Exception:
    print("")
PY
}

# 新 config 夹具
new_config() {
  local path="$1"
  mkdir -p "$(dirname "${path}")"
  printf '# sample herdr config\n' >"${path}"
  printf '%s' "${path}"
}

t_describe "setup-client.sh — 参数与校验"

t_it "--help 退出 0，列出全部冻结参数"
run_setup --help
t_exit_ok 0 "${rc}" "退出 0"
for flag in --config --server-root --server-state-dir --server-host --no-keys --no-tabbar; do
  t_contains "${flag}" "${out}" "帮助含 ${flag}"
done

t_it "未知参数：非 0 退出，且不创建 config"
c_unknown="${WORK}/unknown.toml"
run_setup --config "${c_unknown}" --bogus
t_exit_ok 2 "${rc}" "未知参数 -> 退出 2"
t_file_absent "${c_unknown}" "未创建 config"
t_match "bogus|未知参数|unknown" "${err}" "错误信息指明参数"

t_it "缺 --server-root（要装 tab bar）：非 0 退出 + 明确提示，不写 config"
c_noroot="${WORK}/noroot.toml"
run_setup --config "${c_noroot}"
t_exit_ok 2 "${rc}" "缺 --server-root -> 退出 2"
t_file_absent "${c_noroot}" "未创建 config"
t_contains "--server-root" "${err}" "stderr 指出缺少 --server-root"

t_it "--no-tabbar 时不需要 --server-root（键位与路径无关）"
c_keyonly="${WORK}/keyonly.toml"
new_config "${c_keyonly}" >/dev/null
run_setup --config "${c_keyonly}" --no-tabbar
t_exit_ok 0 "${rc}" "退出 0"
ck_n=$(keys_count "${c_keyonly}")
t_eq "3" "${ck_n}" "只装了 3 条键位"
ct_n=$(tabbar_count "${c_keyonly}")
t_eq "0" "${ct_n}" "未装 tab bar"

t_it "--no-keys --no-tabbar 同时给：非 0（没有可执行步骤）"
c_none="${WORK}/none.toml"
run_setup --config "${c_none}" --no-keys --no-tabbar
t_exit_ok 2 "${rc}" "退出 2"
t_file_absent "${c_none}" "未创建 config"

t_describe "setup-client.sh — 用真实安装器编排（跨机参数）"

SERVER_ROOT_FIXTURE="${WORK}/server-checkout"
mkdir -p "${SERVER_ROOT_FIXTURE}/bin"
cat >"${SERVER_ROOT_FIXTURE}/herdr-plugin.toml" <<'EOF'
id = "zzjcool:forward"
name = "forward"
version = "0.1.0"
EOF
SERVER_STATE="/srv/herdr-state/herdr/plugins/zzjcool%3Aforward"

t_it "完整安装：tab bar（写 server 路径）+ 3 条键位，一次到位"
c_full="${WORK}/full.toml"
new_config "${c_full}" >/dev/null
run_setup --config "${c_full}" \
  --server-root "${SERVER_ROOT_FIXTURE}" --server-state-dir "${SERVER_STATE}"
t_exit_ok 0 "${rc}" "退出 0"
ct_full=$(tabbar_count "${c_full}")
t_eq "1" "${ct_full}" "恰好 1 条 tab bar 条目"
ck_full=$(keys_count "${c_full}")
t_eq "3" "${ck_full}" "恰好 3 条键位"
full_cmd="$(tabbar_command "${c_full}")"
t_contains "${SERVER_ROOT_FIXTURE}/bin/forward" "${full_cmd}" "tab bar command 用 server 上的插件根"
t_contains "${SERVER_STATE}" "${full_cmd}" "tab bar command 带 server 的 state 目录"

t_it "汇总输出：reload 提示 + B 侧 checklist + 装了什么"
t_match "reload-config|prefix\\+q" "${out}" "含 reload 提示"
t_contains "zzjcool:forward" "${out}" "checklist 提到插件 id"
t_match "ssh|jq" "${out}" "checklist 覆盖 ssh/jq 前置条件"
t_match "server-root|插件根" "${out}" "汇总提到 server 插件根"

t_it "调用顺序：tab bar 先于键位（步骤编号可断言）"
tb_pos="$(printf '%s' "${out}" | grep -bo 'tab bar' | head -1 | cut -d: -f1 || true)"
key_pos="$(printf '%s' "${out}" | grep -bo '键绑定' | head -1 | cut -d: -f1 || true)"
if [[ -n "${tb_pos}" && -n "${key_pos}" && "${tb_pos}" -lt "${key_pos}" ]]; then
  t_pass "tab bar 步骤出现在键位步骤之前"
else
  t_fail_note "步骤顺序异常（tab bar@${tb_pos:-无} 键位@${key_pos:-无}）"
fi

t_it "state 目录未显式给：从 --server-root 的 manifest id 推导（':' -> '%3A'）"
c_derive="${WORK}/derive.toml"
new_config "${c_derive}" >/dev/null
run_setup --config "${c_derive}" --server-root "${SERVER_ROOT_FIXTURE}"
t_exit_ok 0 "${rc}" "退出 0"
derive_cmd="$(tabbar_command "${c_derive}")"
derived_state=$(sandbox_state_dir)
t_contains "${derived_state}" "${derive_cmd}" "推导出的 state 目录写进 command"

t_it "manifest id 变了 -> 推导出的 state 目录跟着变（不是硬编码）"
alt_root="${WORK}/alt-checkout"
mkdir -p "${alt_root}"
printf 'id = "acme:other"\n' >"${alt_root}/herdr-plugin.toml"
c_alt="${WORK}/alt.toml"
new_config "${c_alt}" >/dev/null
run_setup --config "${c_alt}" --server-root "${alt_root}"
t_exit_ok 0 "${rc}" "退出 0"
alt_cmd="$(tabbar_command "${c_alt}")"
t_contains "acme%3Aother" "${alt_cmd}" "state 目录由 manifest id 推导"

t_it "幂等：连跑两次，config 逐字节不变，第二次都报 already installed"
c_idem="${WORK}/idem.toml"
new_config "${c_idem}" >/dev/null
run_setup --config "${c_idem}" --server-root "${SERVER_ROOT_FIXTURE}" --server-state-dir "${SERVER_STATE}"
t_exit_ok 0 "${rc}" "第一次退出 0"
after1="$(md5 "${c_idem}")"
run_setup --config "${c_idem}" --server-root "${SERVER_ROOT_FIXTURE}" --server-state-dir "${SERVER_STATE}"
t_exit_ok 0 "${rc}" "第二次退出 0"
after2="$(md5 "${c_idem}")"
t_eq "${after1}" "${after2}" "config 未变"
ct_idem=$(tabbar_count "${c_idem}")
t_eq "1" "${ct_idem}" "tab bar 条目未重复"
ck_idem=$(keys_count "${c_idem}")
t_eq "3" "${ck_idem}" "键位未重复"
t_match "already installed" "${out}" "第二次都提示已安装"

t_it "--dry-run：磁盘零改动，但仍打印将写入的内容"
c_dry="${WORK}/dry.toml"
new_config "${c_dry}" >/dev/null
before_dry="$(md5 "${c_dry}")"
run_setup --config "${c_dry}" --server-root "${SERVER_ROOT_FIXTURE}" --server-state-dir "${SERVER_STATE}" --dry-run
t_exit_ok 0 "${rc}" "退出 0"
after_dry=$(md5 "${c_dry}")
t_eq "${before_dry}" "${after_dry}" "文件未变"
t_match "dry-run|dry_run" "${out}" "输出标注 dry-run"

t_it "默认 config 路径：XDG_CONFIG_HOME 优先（与其他安装器一致）"
xdg_cfg="${WORK}/xdg-config/herdr/config.toml"
run_setup --no-tabbar
t_exit_ok 0 "${rc}" "退出 0"
t_file_exists "${xdg_cfg}" "写到了 XDG_CONFIG_HOME 下的默认路径"
ck_xdg=$(keys_count "${xdg_cfg}")
t_eq "3" "${ck_xdg}" "默认路径装了 3 条键位"

t_it "默认 config 路径：XDG_CONFIG_HOME 未设时退回 \$HOME/.config/herdr/config.toml"
home_cfg="${WORK}/home/.config/herdr/config.toml"
run_setup_noxdg --no-tabbar
t_exit_ok 0 "${rc}" "退出 0"
t_file_exists "${home_cfg}" "写到了 HOME 下的默认路径"
ck_home=$(keys_count "${home_cfg}")
t_eq "3" "${ck_home}" "默认路径装了 3 条键位"

t_describe "setup-client.sh — 参数透传与失败传导（stub 安装器，含 curl 形态）"

STUB_DIR="${WORK}/stub-scripts"
mkdir -p "${STUB_DIR}"
STUB_LOG="${WORK}/stub.log"
cat >"${STUB_DIR}/install-tabbar.sh" <<'EOF'
#!/usr/bin/env bash
printf 'TABBAR %s\n' "$*" >>"${STUB_LOG}"
exit "${STUB_FAIL_TABBAR:-0}"
EOF
cat >"${STUB_DIR}/install-keys.sh" <<'EOF'
#!/usr/bin/env bash
printf 'KEYS %s\n' "$*" >>"${STUB_LOG}"
exit "${STUB_FAIL_KEYS:-0}"
EOF
chmod +x "${STUB_DIR}/install-tabbar.sh" "${STUB_DIR}/install-keys.sh"

# curl 形态：拷一个孤立的 setup-client.sh（同目录没有安装器）-> 必须走 HF_RAW_BASE 下载
CURL_DIR="${WORK}/curl-form"
mkdir -p "${CURL_DIR}"
cp "${SETUP}" "${CURL_DIR}/setup-client.sh"

t_it "curl|bash 形态（无同目录安装器）：从 HF_RAW_BASE 拉安装器并按顺序透传参数"
: >"${STUB_LOG}"
SETUP_BIN="${CURL_DIR}/setup-client.sh"
setup_env=(
  "HOME=${WORK}/home"
  "XDG_CONFIG_HOME=${WORK}/xdg-config"
  "XDG_STATE_HOME=${WORK}/xdg-state"
  "STUB_LOG=${STUB_LOG}"
  "HF_RAW_BASE=file://${STUB_DIR}"
)
c_stub1="${WORK}/stub1.toml"
run_setup --config "${c_stub1}" --server-root "${SERVER_ROOT_FIXTURE}" --server-state-dir "${SERVER_STATE}"
t_exit_ok 0 "${rc}" "退出 0"
log1="$(cat "${STUB_LOG}")"
t_match '^TABBAR .*--plugin-root ' "${log1}" "tabbar 收到 --plugin-root"
t_contains "--state-dir ${SERVER_STATE}" "${log1}" "tabbar 收到 --state-dir"
t_contains "--config ${c_stub1}" "${log1}" "tabbar 收到 --config"
t_contains "--config ${c_stub1}" "$(printf '%s' "${log1}" | grep '^KEYS' || true)" "keys 收到 --config"
# 调用顺序：TABBAR 行号 < KEYS 行号（grep -n 逐行取，不依赖多行正则）
tb_line="$(printf '%s\n' "${log1}" | grep -n '^TABBAR' | head -1 | cut -d: -f1 || true)"
key_line="$(printf '%s\n' "${log1}" | grep -n '^KEYS' | head -1 | cut -d: -f1 || true)"
if [[ -n "${tb_line}" && -n "${key_line}" && "${tb_line}" -lt "${key_line}" ]]; then
  t_pass "TABBAR 先于 KEYS 调用（行 ${tb_line} < ${key_line}）"
else
  t_fail_note "调用顺序异常（TABBAR@${tb_line:-无} KEYS@${key_line:-无}）"
fi

t_it "--no-keys / --no-tabbar 真的跳过对应安装器（stub 侧可见）"
: >"${STUB_LOG}"
run_setup --config "${WORK}/stub-nokeys.toml" --server-root "${SERVER_ROOT_FIXTURE}" --no-keys
t_exit_ok 0 "${rc}" "退出 0"
t_eq "1" "$(grep -c '^TABBAR' "${STUB_LOG}" || true)" "只调 tabbar"
t_eq "0" "$(grep -c '^KEYS' "${STUB_LOG}" || true)" "未调 keys"
: >"${STUB_LOG}"
run_setup --config "${WORK}/stub-notabbar.toml" --no-tabbar
t_exit_ok 0 "${rc}" "退出 0"
t_eq "1" "$(grep -c '^KEYS' "${STUB_LOG}" || true)" "只调 keys"
t_eq "0" "$(grep -c '^TABBAR' "${STUB_LOG}" || true)" "未调 tabbar"

t_it "tab bar 安装器失败：整体非 0，且不再执行键位步骤（不静默吞错）"
: >"${STUB_LOG}"
setup_env+=("STUB_FAIL_TABBAR=3")
run_setup --config "${WORK}/stub-fail.toml" --server-root "${SERVER_ROOT_FIXTURE}"
t_isnt "0" "${rc}" "退出码非 0"
t_eq "1" "$(grep -c '^TABBAR' "${STUB_LOG}" || true)" "tabbar 被调用"
t_eq "0" "$(grep -c '^KEYS' "${STUB_LOG}" || true)" "失败后未调 keys"
t_match "install-tabbar" "${err}" "stderr 指明失败的安装器"
# 去掉失败开关，恢复后续用例
setup_env=(
  "HOME=${WORK}/home"
  "XDG_CONFIG_HOME=${WORK}/xdg-config"
  "XDG_STATE_HOME=${WORK}/xdg-state"
  "STUB_LOG=${STUB_LOG}"
  "HF_RAW_BASE=file://${STUB_DIR}"
)

t_it "下载失败（HF_RAW_BASE 不可达）：非 0 + 指明下一步（git clone 后本地跑）"
HF_BAD_DIR="${WORK}/bad-curl"
mkdir -p "${HF_BAD_DIR}"
cp "${SETUP}" "${HF_BAD_DIR}/setup-client.sh"
SETUP_BIN="${HF_BAD_DIR}/setup-client.sh"
setup_env=(
  "HOME=${WORK}/home"
  "XDG_CONFIG_HOME=${WORK}/xdg-config"
  "XDG_STATE_HOME=${WORK}/xdg-state"
  "HF_RAW_BASE=file://${WORK}/does-not-exist"
)
c_dl="${WORK}/dl-fail.toml"
run_setup --config "${c_dl}" --server-root "${SERVER_ROOT_FIXTURE}"
t_isnt "0" "${rc}" "退出码非 0"
t_file_absent "${c_dl}" "未写 config"
t_match "git clone|clone|scripts/setup-client" "${err}" "错误信息给出下一步"

t_it "真 stdin 形态（cat script | bash -s）：BASH_SOURCE 未定义也不得 unbound"
: >"${STUB_LOG}"
SETUP_BIN="${SETUP}"
setup_env=(
  "HOME=${WORK}/home"
  "XDG_CONFIG_HOME=${WORK}/xdg-config"
  "XDG_STATE_HOME=${WORK}/xdg-state"
  "STUB_LOG=${STUB_LOG}"
  "HF_RAW_BASE=file://${STUB_DIR}"
  "STUB_FAIL_TABBAR=0"
)
c_stdin="${WORK}/stdin.toml"
# `bash -s < script` 与 `curl | bash -s` 等价（脚本从 stdin 读入，BASH_SOURCE 未定义），
# 且避开 shellcheck SC2002（useless cat）。
rc=0
out="$(env -u HERDR_PLUGIN_STATE_DIR "${setup_env[@]}" bash -s -- \
  --config "${c_stdin}" --server-root "${SERVER_ROOT_FIXTURE}" <"${SETUP}" 2>"${WORK}/stderr")" || rc=$?
err="$(cat "${WORK}/stderr")"
t_exit_ok 0 "${rc}" "退出 0"
stdin_log="$(cat "${STUB_LOG}")"
t_isnt "" "${stdin_log}" "安装器被调用（下载分支）"
if [[ "${err}" == *"unbound variable"* ]]; then
  t_fail_note "stdin 形态触发了 unbound variable（set -u 下 BASH_SOURCE 未定义）"
else
  t_pass "无 unbound variable"
fi

# 恢复被测脚本/环境到真实安装器
SETUP_BIN="${SETUP}"
setup_env=(
  "HOME=${WORK}/home"
  "XDG_CONFIG_HOME=${WORK}/xdg-config"
  "XDG_STATE_HOME=${WORK}/xdg-state"
)

t_describe "setup-client.sh — B 侧可用性探测（尽力而为，绝不阻塞）"

t_it "探测命中（fixture：plugins.json 里有 zzjcool:forward）-> 打印 ✅ 类信息，退出 0"
probe_yes="${WORK}/probe-yes"
mkdir -p "${probe_yes}/herdr"
cat >"${probe_yes}/herdr/plugins.json" <<'EOF'
[
  {
    "plugin_id": "zzjcool:forward",
    "plugin_root": "/home/u/.config/herdr/plugins/github/zzjcool-forward-deadbeef",
    "enabled": true
  }
]
EOF
c_probe1="${WORK}/probe1.toml"
new_config "${c_probe1}" >/dev/null
setup_env=(
  "HOME=${WORK}/home"
  "XDG_CONFIG_HOME=${probe_yes}"
  "XDG_STATE_HOME=${WORK}/xdg-state"
)
run_setup --config "${c_probe1}" --server-root "${SERVER_ROOT_FIXTURE}" --server-state-dir "${SERVER_STATE}"
t_exit_ok 0 "${rc}" "退出 0"
t_contains "zzjcool:forward" "${out}" "输出点名插件 id"
t_match "✅|探测到|已安装|found" "${out}" "给出命中标记"

t_it "探测未命中（空 fixture）-> 提示去 server 确认，退出码仍为 0"
probe_no="${WORK}/probe-no"
mkdir -p "${probe_no}/herdr"
c_probe2="${WORK}/probe2.toml"
new_config "${c_probe2}" >/dev/null
setup_env=(
  "HOME=${WORK}/home"
  "XDG_CONFIG_HOME=${probe_no}"
  "XDG_STATE_HOME=${WORK}/xdg-state"
)
run_setup --config "${c_probe2}" --server-root "${SERVER_ROOT_FIXTURE}" --server-state-dir "${SERVER_STATE}"
t_exit_ok 0 "${rc}" "探测失败不阻塞（退出 0）"
t_match "herdr plugin (list|install)|server 上确认" "${out}" "提示在 server 上确认插件"

t_it "探测命中分支（managed checkout 目录形态）"
probe_co="${WORK}/probe-checkout"
mkdir -p "${probe_co}/herdr/plugins/github/zzjcool-forward-f3758c0ba1da"
c_probe3="${WORK}/probe3.toml"
new_config "${c_probe3}" >/dev/null
setup_env=(
  "HOME=${WORK}/home"
  "XDG_CONFIG_HOME=${probe_co}"
  "XDG_STATE_HOME=${WORK}/xdg-state"
)
run_setup --config "${c_probe3}" --server-root "${SERVER_ROOT_FIXTURE}" --server-state-dir "${SERVER_STATE}"
t_exit_ok 0 "${rc}" "退出 0"
t_match "✅|探测到|已安装|found" "${out}" "checkout 目录也算命中"

setup_env=(
  "HOME=${WORK}/home"
  "XDG_CONFIG_HOME=${WORK}/xdg-config"
  "XDG_STATE_HOME=${WORK}/xdg-state"
)

t_describe "setup-client.sh — --server-host：ssh 真实探测（fake ssh shim，绝不真连任何主机）"

# 假 ssh：只把参数写进日志，按 SSH_SHIM_SCENARIO 输出，永不联网。
# 注入 PATH 后 setup-client.sh 里的 `ssh` 全是这个 shim —— 测试期间不可能连到真主机。
SSH_SHIM_DIR="${WORK}/ssh-shim"
SSH_SHIM_LOG="${WORK}/ssh-shim.log"
mkdir -p "${SSH_SHIM_DIR}"
cat >"${SSH_SHIM_DIR}/ssh" <<'SHIM'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'ARGV' >>"${SSH_SHIM_LOG:?}"
for a in "$@"; do printf ' <%s>' "$a" >>"${SSH_SHIM_LOG}"; done
printf '\n' >>"${SSH_SHIM_LOG}"
cmd=""
for a in "$@"; do cmd="$a"; done
# 真 ssh 会读 stdin —— `curl … | bash -s` 形态下这是**脚本本体**，会被吃掉！
# 这里按需复现该行为（只在专门用例里开，避免在普通用例中阻塞在测试自身的 stdin 上）。
shim_has_n=0
for a in "$@"; do [[ "$a" == "-n" ]] && shim_has_n=1; done
if [[ "${SSH_SHIM_DRAIN_STDIN:-0}" == "1" && "${shim_has_n}" == "0" ]]; then
  cat >/dev/null 2>&1 || true
fi
scenario="${SSH_SHIM_SCENARIO:-installed}"
if [[ "${scenario}" == "unreachable" ]]; then
  printf 'ssh: connect to host %s port 22: Connection refused\n' "${SSH_SHIM_HOST:-fake-host}" >&2
  exit 255
fi
case "${cmd}" in
*"plugin install"*)
  printf 'UNEXPECTED-INSTALL\n'
  exit 3
  ;;
*"plugin list"*)
  if [[ "${scenario}" == "noherdr" ]]; then
    printf 'HF_NO_HERDR\n'
  elif [[ "${scenario}" == "absent" ]]; then
    printf 'No plugins installed.\n'
  else
    cat <<'OUT'
1 plugin installed:
- zzjcool:forward (forward) enabled [github:zzjcool/herdr-forward@deadbeef]
  config: /home/b/.config/herdr/plugins/config/zzjcool%3Aforward
OUT
  fi
  ;;
*)
  cat <<'OUT'
HF_ROOT=/home/b/.config/herdr/plugins/github/zzjcool-forward-deadbeef
HF_STATE_DIR=/home/b/.local/state/herdr/plugins/zzjcool%3Aforward
HF_DEFAULT_STATE=/home/b/.local/state/herdr/plugins/zzjcool%3Aforward
OUT
  ;;
esac
exit 0
SHIM
chmod +x "${SSH_SHIM_DIR}/ssh"

# 基础 PATH（shim 目录按需前置，避免多次调用叠加）
BASE_PATH="${PATH}"

run_setup_shim() {
  local scenario="$1"
  shift
  rc=0
  out="$(env -u HERDR_PLUGIN_STATE_DIR \
    "HOME=${WORK}/home" "XDG_CONFIG_HOME=${WORK}/xdg-config" "XDG_STATE_HOME=${WORK}/xdg-state" \
    "PATH=${SSH_SHIM_DIR}:${BASE_PATH}" "SSH_SHIM_LOG=${SSH_SHIM_LOG}" \
    "SSH_SHIM_SCENARIO=${scenario}" \
    bash "${SETUP_BIN}" "$@" 2>"${WORK}/stderr")" || rc=$?
  err="$(cat "${WORK}/stderr")"
}

PROBED_ROOT="/home/b/.config/herdr/plugins/github/zzjcool-forward-deadbeef"
PROBED_STATE="/home/b/.local/state/herdr/plugins/zzjcool%3Aforward"

t_it "未提供 --server-host：一次 ssh 都不调用（向后兼容，本机探测路径不变）"
: >"${SSH_SHIM_LOG}"
c_no_ssh="${WORK}/no-ssh.toml"
new_config "${c_no_ssh}" >/dev/null
run_setup_shim installed --config "${c_no_ssh}" \
  --server-root "${SERVER_ROOT_FIXTURE}" --server-state-dir "${SERVER_STATE}"
t_exit_ok 0 "${rc}" "退出 0"
t_eq "0" "$(grep -c . "${SSH_SHIM_LOG}" || true)" "ssh 未被调用"
no_ssh_cmd="$(tabbar_command "${c_no_ssh}")"
t_contains "${SERVER_ROOT_FIXTURE}/bin/forward" "${no_ssh_cmd}" "走显式 --server-root"
t_match "本机探测|未在本机探测|✅" "${out}" "仍是本机尽力探测叙事"

t_it "--server-host 装了：✅ + 自动推导 B 的插件根与 state 目录（用户零路径参数）"
: >"${SSH_SHIM_LOG}"
c_ssh_ok="${WORK}/ssh-ok.toml"
new_config "${c_ssh_ok}" >/dev/null
run_setup_shim installed --config "${c_ssh_ok}" --server-host b-user@b-host
t_exit_ok 0 "${rc}" "退出 0"
ssh_cmd_ok="$(tabbar_command "${c_ssh_ok}")"
t_contains "${PROBED_ROOT}/bin/forward" "${ssh_cmd_ok}" "tab bar 用 ssh 探测到的 B 插件根"
t_contains "${PROBED_STATE}" "${ssh_cmd_ok}" "tab bar 用 ssh 探测到的 B state 目录"
t_contains "✅" "${out}" "打印 ✅（真实探测命中）"
t_contains "${PROBED_ROOT}" "${out}" "输出展示探测到的插件根"
t_contains "--server-root" "${out}" "说明 --server-root 已自动填入"
shim_log="$(cat "${SSH_SHIM_LOG}")"
t_contains "<-o> <BatchMode=yes>" "${shim_log}" "BatchMode 只读探测"
# timeout 由 ssh_probe 以 `"$SSH_TIMER_BIN" "$SSH_PROBE_TIMEOUT"` 前置（shim 看不到这层 argv，
# 只有 timeout 自己看不到——故此处做源码级防漂移断言）。
if grep -qE 'cmd\+=\("\$\{SSH_TIMER_BIN\}" "\$\{SSH_PROBE_TIMEOUT\}"\)' "${SETUP}" &&
  grep -qE '^readonly SSH_PROBE_TIMEOUT=15$' "${SETUP}"; then
  t_pass "探测被 timeout 15 包裹（源码断言：SSH_TIMER_BIN + SSH_PROBE_TIMEOUT=15）"
else
  t_fail_note "探测未用 timeout 15 包裹（挂死保护缺失）"
fi
t_contains "<-o> <ConnectTimeout=8>" "${shim_log}" "带 ConnectTimeout=8"
t_contains "<b-user@b-host>" "${shim_log}" "目标主机正确"
t_contains "plugin list" "${shim_log}" "用 herdr plugin list 探测 B"
if [[ "${shim_log}" == *"plugin install"* ]]; then
  t_fail_note "探测阶段出现了 plugin install（绝不自动装）"
else
  t_pass "探测阶段零安装动作"
fi

t_it "--server-host user@host:port：端口以 -p 传给 ssh，主机名剥掉端口后缀"
: >"${SSH_SHIM_LOG}"
c_ssh_port="${WORK}/ssh-port.toml"
new_config "${c_ssh_port}" >/dev/null
run_setup_shim installed --config "${c_ssh_port}" --server-host b-user@b-host:2222
t_exit_ok 0 "${rc}" "退出 0"
shim_port="$(cat "${SSH_SHIM_LOG}")"
t_contains "<-p> <2222>" "${shim_port}" "端口用 -p 2222 传递"
t_contains "<b-user@b-host>" "${shim_port}" "主机名不含端口"

t_it "--server-host 显式 --server-root：显式优先，但 state 目录仍用 ssh 探测值（跨机正确的 B 路径）"
: >"${SSH_SHIM_LOG}"
c_ssh_win="${WORK}/ssh-win.toml"
new_config "${c_ssh_win}" >/dev/null
run_setup_shim installed --config "${c_ssh_win}" \
  --server-host b-user@b-host --server-root "${SERVER_ROOT_FIXTURE}"
t_exit_ok 0 "${rc}" "退出 0"
win_cmd="$(tabbar_command "${c_ssh_win}")"
t_contains "${SERVER_ROOT_FIXTURE}/bin/forward" "${win_cmd}" "显式 root 生效（未被探测值覆盖）"
t_contains "${PROBED_STATE}" "${win_cmd}" "state 目录用 ssh 探测值（不是 A 的 HOME 推导）"

# 显式 --server-state-dir 也不被覆盖
t_it "--server-host 显式 --server-state-dir：显式优先"
c_ssh_win2="${WORK}/ssh-win2.toml"
new_config "${c_ssh_win2}" >/dev/null
run_setup_shim installed --config "${c_ssh_win2}" --server-host b-user@b-host \
  --server-root "${SERVER_ROOT_FIXTURE}" --server-state-dir "${SERVER_STATE}"
t_exit_ok 0 "${rc}" "退出 0"
win2_cmd="$(tabbar_command "${c_ssh_win2}")"
t_contains "${SERVER_STATE}" "${win2_cmd}" "显式 state 目录生效"

t_it "--server-host 没装（--no-tabbar）：递上可复制的安装命令，且绝不自动安装"
: >"${SSH_SHIM_LOG}"
c_absent="${WORK}/ssh-absent.toml"
new_config "${c_absent}" >/dev/null
run_setup_shim absent --config "${c_absent}" --server-host b-user@b-host --no-tabbar
t_exit_ok 0 "${rc}" "退出 0（键位照常安装）"
t_contains "ssh b-user@b-host 'herdr plugin install zzjcool/herdr-forward --yes'" "${out}" "递上可直接复制的安装命令"
shim_calls="$(cat "${SSH_SHIM_LOG}")"
if [[ "${shim_calls}" == *"plugin install"* ]]; then
  t_fail_note "脚本自动执行了安装（应只打印命令）"
else
  t_pass "未自动安装（尊重用户）"
fi
absent_keys="$(keys_count "${c_absent}")"
t_eq "3" "${absent_keys}" "键位照常装上（探测结果不影响安装步骤）"

t_it "--server-host 没装 + 要 tab bar + 没给 --server-root：退出 2，stderr 递上安装命令"
c_absent2="${WORK}/ssh-absent2.toml"
new_config "${c_absent2}" >/dev/null
run_setup_shim absent --config "${c_absent2}" --server-host b-user@b-host
t_exit_ok 2 "${rc}" "退出 2（无法确定 B 插件根）"
t_contains "herdr plugin install zzjcool/herdr-forward --yes" "${err}" "stderr 含安装命令"
t_contains "--server-root" "${err}" "stderr 提到 --server-root"

# 连不上：ssh shim 退 255，必须降级而不是崩
t_it "--server-host 连不上：降级到 checklist 模式，显式 --server-root 仍照常安装（绝不阻塞）"
: >"${SSH_SHIM_LOG}"
c_bad="${WORK}/ssh-bad.toml"
new_config "${c_bad}" >/dev/null
run_setup_shim unreachable --config "${c_bad}" --server-host b-user@b-host \
  --server-root "${SERVER_ROOT_FIXTURE}" --server-state-dir "${SERVER_STATE}"
t_exit_ok 0 "${rc}" "退出 0（探测失败不阻塞安装）"
bad_cmd="$(tabbar_command "${c_bad}")"
t_contains "${SERVER_ROOT_FIXTURE}/bin/forward" "${bad_cmd}" "回落到显式 --server-root"
t_match "降级|探测失败|Connection refused" "${out}" "打印降级原因（不静默）"
t_contains "zzjcool:forward" "${out}" "checklist 仍提示去 B 确认插件"
if [[ "${out}" == *"✅"* ]]; then
  t_fail_note "探测失败却打了 ✅"
else
  t_pass "失败时不打 ✅"
fi

t_it "--server-host 连不上 + --no-tabbar：退出 0，降级 checklist，无 unbound 崩溃"
run_setup_shim unreachable --config "${WORK}/ssh-bad2.toml" --server-host b-user@b-host --no-tabbar
t_exit_ok 0 "${rc}" "退出 0"
t_match "降级|探测失败|checklist|前置条件" "${out}" "降级到 checklist 模式"
if [[ "${err}" == *"unbound variable"* ]]; then
  t_fail_note "崩溃：unbound variable"
else
  t_pass "无 unbound variable"
fi

t_it "--server-host 连不上 + 要 tab bar + 没给 --server-root：退出 2 并说明探测失败"
run_setup_shim unreachable --config "${WORK}/ssh-bad3.toml" --server-host b-user@b-host
t_exit_ok 2 "${rc}" "退出 2"
t_contains "--server-root" "${err}" "stderr 指出缺少 --server-root"
t_match "ssh|探测" "${err}" "stderr 说明 ssh 探测失败"

t_it "--server-host 为空值：退出 2（参数校验）"
run_setup_shim installed --config "${WORK}/ssh-empty.toml" --server-host ""
t_isnt "0" "${rc}" "空值被拒"

t_it "--server-host 连得上但远端无 herdr（PATH 问题）：单独诊断 + 降级，不误导为「没装插件」"
run_setup_shim noherdr --config "${WORK}/ssh-noherdr.toml" --server-host b-user@b-host --no-tabbar
t_exit_ok 0 "${rc}" "退出 0"
t_match "找不到 herdr|PATH" "${out}" "打印 PATH 诊断（而不是「B 没装插件」）"
if [[ "${out}" == *"herdr plugin install"* ]]; then
  t_fail_note "误判为未安装并递了安装命令（应与 PATH 问题区分）"
else
  t_pass "未误判为未安装"
fi
noherdr_keys="$(keys_count "${WORK}/ssh-noherdr.toml")"
t_eq "3" "${noherdr_keys}" "键位照常装上（不阻塞）"

t_describe "setup-client.sh — 真 stdin 形态（curl|bash -s）+ ssh 探测（回归：ssh 不得吃掉脚本）"

t_it "stdin 形态 + --server-host（shim 模拟 ssh 读 stdin）：脚本必须跑完，配置必须装上"
stdin_cfg="${WORK}/stdin-ssh.toml"
new_config "${stdin_cfg}" >/dev/null
: >"${SSH_SHIM_LOG}"
rc=0
out="$(env -u HERDR_PLUGIN_STATE_DIR \
  "HOME=${WORK}/home" "XDG_CONFIG_HOME=${WORK}/xdg-config" "XDG_STATE_HOME=${WORK}/xdg-state" \
  "PATH=${SSH_SHIM_DIR}:${BASE_PATH}" "SSH_SHIM_LOG=${SSH_SHIM_LOG}" \
  "SSH_SHIM_SCENARIO=installed" "SSH_SHIM_DRAIN_STDIN=1" \
  "HF_RAW_BASE=file://${ROOT}/scripts" \
  bash -s -- --config "${stdin_cfg}" --server-host b-user@b-host <"${SETUP}" 2>"${WORK}/stderr")" || rc=$?
err="$(cat "${WORK}/stderr")"
t_exit_ok 0 "${rc}" "退出 0"
if [[ "${err}" == *"unbound variable"* ]]; then
  t_fail_note "崩溃：unbound variable"
else
  t_pass "无 unbound variable"
fi
stdin_keys="$(keys_count "${stdin_cfg}")"
t_eq "3" "${stdin_keys}" "脚本跑到底（3 条键位都装上）——未被 ssh 吃掉剩余脚本"
stdin_tb="$(tabbar_count "${stdin_cfg}")"
t_eq "1" "${stdin_tb}" "tab bar 也装上（探测后的自动推导路径走通）"
t_contains "✅" "${out}" "仍打印 ssh 探测结论（探测之后还有输出）"
shim_calls_stdin="$(cat "${SSH_SHIM_LOG}")"
t_contains "<-n>" "${shim_calls_stdin}" "ssh 用 -n（不读脚本本身）"

t_describe "setup-client.sh — 静态检查与文档防漂移"

t_it "shellcheck 严格模式干净（工具缺失则显式 SKIP）"
if command -v shellcheck >/dev/null 2>&1; then
  sc_rc=0
  sc_out="$(shellcheck -x -S style -o all "${SETUP}" 2>&1)" || sc_rc=$?
  t_exit_ok 0 "${sc_rc}" "shellcheck 无告警（${sc_out:0:200}）"
else
  t_skip "shellcheck 未安装，无法校验 ${SETUP}"
fi

t_it "shfmt 格式一致（工具缺失则显式 SKIP）"
if command -v shfmt >/dev/null 2>&1; then
  fmt_rc=0
  fmt_out="$(shfmt -d -ln bash -i 2 "${SETUP}" 2>&1)" || fmt_rc=$?
  t_exit_ok 0 "${fmt_rc}" "shfmt -d 无差异（${fmt_out:0:200}）"
else
  t_skip "shfmt 未安装，无法校验 ${SETUP}"
fi

t_it "README：一键命令升级为 --server-host 形态，旧 --server-root 用法保留"
readme_ssh_ok="$(
  python3 - "${ROOT}/README.md" <<'PY'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
has_host = "--server-host" in src
has_old = "--server-root" in src
# --server-host 必须出现在调用 setup-client.sh 的命令行里（有 --server-host 这个 flag 的实参）
call = bool(re.search(r"setup-client\.sh[^\n]*--server-host|<B 的 ssh[^\n]*", src)) and has_host
has_install_hint = "herdr plugin install zzjcool/herdr-forward --yes" in src
print("ok" if (has_host and has_old and call and has_install_hint) else
      f"host={has_host} old={has_old} call={call} hint={has_install_hint}")
PY
)"
t_eq "ok" "${readme_ssh_ok}" "README 含 --server-host 一键形态 + 旧用法 + 安装命令提示"

t_it "README：一键叙事用 setup-client.sh（curl 一行 + clone 备选），手工块保留为 fallback"
readme_ok="$(
  python3 - "${ROOT}/README.md" <<'PY'
import sys
try:
    src = open(sys.argv[1], encoding="utf-8").read()
except OSError:
    print("no-readme")
    raise SystemExit(0)
one_liner = "scripts/setup-client.sh" in src
raw = "raw.githubusercontent.com/zzjcool/herdr-forward" in src and "setup-client.sh" in src
clone = "git clone" in src
manual = "tab_bar_right" in src and "herdr-forward: tab bar status entry" in src
keys_manual = "herdr-forward: keybindings" in src
print("ok" if (one_liner and raw and clone and manual and keys_manual) else "bad")
PY
)"
t_eq "ok" "${readme_ok}" "README 含一键命令 + clone 备选 + 手工 fallback 块"

t_it "README 记录的 setup-client 参数都在 --help 里（防文档漂移）"
run_setup --help
help_out="${out}"
drift_ok="$(
  python3 - "${ROOT}/README.md" "${help_out}" <<'PY'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
help_text = sys.argv[2]
# README 里针对 setup-client.sh 的调用行/代码块里出现的 --flag
blocks = re.findall(r"```sh\n(.*?)```", src, re.S)
mentioned = set()
for b in blocks:
    if "setup-client.sh" in b:
        mentioned |= set(re.findall(r"--[a-z][a-z-]+", b))
# 说明性文字里也可能提到参数
for line in src.splitlines():
    if "setup-client.sh" in line:
        mentioned |= set(re.findall(r"--[a-z][a-z-]+", line))
missing = sorted(f for f in mentioned if f not in ("--ref",) and f not in help_text)
print("ok" if not missing else "missing:" + ",".join(missing))
PY
)"
t_eq "ok" "${drift_ok}" "README 提到的参数均被 --help 覆盖"

t_it "README 的手工 tab bar 块仍是安装器真实输出（占位符代入后逐字一致）"
c_readme="${WORK}/readme-tabbar.toml"
new_config "${c_readme}" >/dev/null
rs_rc=0
env -u HERDR_PLUGIN_STATE_DIR XDG_STATE_HOME="${WORK}/xdg-state" \
  bash "${ROOT}/scripts/install-tabbar.sh" --config "${c_readme}" \
  --plugin-root "${SERVER_ROOT_FIXTURE}" >/dev/null 2>&1 || rs_rc=$?
t_exit_ok 0 "${rs_rc}" "install-tabbar 退出 0"
readme_state=$(sandbox_state_dir)
readme_entry="$(
  python3 - "${ROOT}/README.md" "${SERVER_ROOT_FIXTURE}" "${readme_state}" <<'PY'
import re, sys, textwrap
src = open(sys.argv[1], encoding="utf-8").read()
blocks = re.findall(r"```toml\n(.*?)```", src, re.S)
for b in blocks:
    if "tab bar status entry" in b and "tab_bar_right" in b:
        print(textwrap.dedent(b)
              .replace("<server-plugin-root>", sys.argv[2])
              .replace("<server-state-dir>", sys.argv[3])
              .strip())
        break
PY
)"
actual_entry="$(
  python3 - "${c_readme}" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as fh:
    doc = tomllib.load(fh)
entry = doc["ui"]["tab_bar_right"][0]
def toml_string(v):
    return '"' + v.replace("\\", "\\\\").replace('"', '\\"') + '"'
print("[ui]")
print("tab_bar_right = [")
print("  # herdr-forward: tab bar status entry (managed by scripts/install-tabbar.sh)")
print("  { type = " + toml_string(entry["type"]) + ", command = " + toml_string(entry["command"])
      + ", interval_seconds = " + str(entry["interval_seconds"])
      + ", timeout_seconds = " + str(entry["timeout_seconds"]) + " },")
print("]")
PY
)"
t_eq "${actual_entry}" "${readme_entry}" "README fallback 块与安装器输出一致"

t_describe "安全：真实 ~/.config/herdr 全程零改动"

t_it "真实 config 未被本次测试触碰"
real_cfg_after="$(if [[ -f "${REAL_CFG}" ]]; then md5sum "${REAL_CFG}" | awk '{print $1}'; else printf 'absent'; fi)"
t_eq "${real_cfg_before}" "${real_cfg_after}" "${REAL_CFG} 未变"

t_done
