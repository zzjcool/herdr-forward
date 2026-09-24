#!/usr/bin/env bash
# tests/unit/test_machines_bridge.sh — `forward machines activate` 的远程开发链路（§A.3.3）
#
# A 视角的完整激活：探测 B → （未装）经用户同意代装 → 远端键位配置 + 重载 →
# 启动桥接；停用时停桥接。ssh 是按远端命令分派的假实现（不连任何主机），探测
# 走 lib/ssh-probe.sh 注入点（与 test_machines_cmd.sh 同一手法）。
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
source "${ROOT}/tests/lib/assertions.sh"

unset HERDR_SOCKET_PATH HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_ENV
unset HERDR_FORWARD_SSH_CONFIG

WORK="$(mktemp -d "${TMPDIR:-/tmp}/machines-bridge.XXXXXX")"
PLUGIN_ROOT="${WORK}/plugin"
STATE_DIR="${WORK}/state"
FW="${PLUGIN_ROOT}/bin/forward"
cleanup() {
  HERDR_PLUGIN_STATE_DIR="${STATE_DIR}" "${FW}" bridge down all >/dev/null 2>&1 || true
  rm -rf "${WORK}"
}
trap cleanup EXIT

mkdir -p "${PLUGIN_ROOT}/bin" "${PLUGIN_ROOT}/lib" "${PLUGIN_ROOT}/scripts" \
  "${STATE_DIR}" "${WORK}/home" "${WORK}/bin"
cp "${ROOT}/bin/forward" "${FW}"
chmod +x "${FW}"
for f in common state machines bridge ports; do
  cp "${ROOT}/lib/${f}.sh" "${PLUGIN_ROOT}/lib/${f}.sh"
done
cp "${ROOT}/scripts/install-tabbar.sh" "${ROOT}/scripts/install-keys.sh" "${PLUGIN_ROOT}/scripts/"
chmod +x "${PLUGIN_ROOT}/scripts/"*.sh

export HERDR_PLUGIN_STATE_DIR="${STATE_DIR}"
export HERDR_CONFIG_PATH="${WORK}/home/.config/herdr/config.toml"
export HOME="${WORK}/home"
export BRIDGE_BACKOFF_MIN_S=1
mkdir -p "$(dirname "${HERDR_CONFIG_PATH}")"

B_ROOT="/home/dev/.config/herdr/plugins/github/zzjcool-forward-ab12cd34"
B_STATE="/home/dev/.local/state/herdr/plugins/zzjcool%3Aforward"
SSH_LOG="${WORK}/ssh.log"
INSTALLED="${WORK}/installed"

# 假 herdr：machine list --json
cat >"${WORK}/bin/herdr" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "machine" && "$2" == "list" ]]; then
  printf '%s\n' '[{"id":"m-dev","label":"dev-box","target":"ssh://dev@b-host:2222","session":"default","enabled":true,"selected":false},{"id":"m-other","label":"other","target":"dev@c-host","session":"default","enabled":true,"selected":false}]'
  exit 0
fi
if [[ "$1" == "server" && "$2" == "reload-config" ]]; then
  printf 'reload\n' >>"${HF_RELOAD_LOG}"
  exit 0
fi
exit 127
EOF
chmod +x "${WORK}/bin/herdr"
export HERDR_BIN_PATH="${WORK}/bin/herdr"
export HF_RELOAD_LOG="${WORK}/reloads"

# 假 ssh：按远端命令分派；每次调用记一行「目的地<TAB>命令」
cat >"${WORK}/bin/ssh" <<EOF
#!/usr/bin/env bash
dest="" cmd=""
while (( \$# > 0 )); do
  case "\$1" in
    -o|-F|-p|-S|-O|-L) shift 2 ;;
    -*) shift ;;
    *) dest="\$1"; shift; cmd="\$*"; break ;;
  esac
done
printf '%s\t%s\n' "\${dest}" "\${cmd}" >>"${SSH_LOG}"
case "\${cmd}" in
  *"plugin install"*) echo "installed zzjcool:forward"; : >"${INSTALLED}"; exit 0 ;;
  *startup-hook.sh*) echo "提示：herdr-forward 键位已就绪："; exit 0 ;;
  *reload-config*) exit 0 ;;
  *"bridge serve"*) echo "ssh: connect to host b-host port 2222: Connection refused" >&2; exit 255 ;;
esac
exit 99
EOF
chmod +x "${WORK}/bin/ssh"
export PATH="${WORK}/bin:${PATH}"

# 探测注入：装过（marker 存在）= present，否则 absent
cat >"${PLUGIN_ROOT}/lib/ssh-probe.sh" <<EOF
#!/usr/bin/env bash
ssh_probe_plugin() {
  if [[ -f "${INSTALLED}" ]]; then
    printf 'HF_STATUS=present\nHF_ROOT=%s\nHF_STATE_DIR=%s\n' '${B_ROOT}' '${B_STATE}'
  else
    printf 'HF_STATUS=absent\n'
  fi
  return 0
}
EOF

out=""
err=""
rc=0

ssh_calls() {
  local pattern="${1}"
  if [[ -f ${SSH_LOG} ]]; then
    grep -c -F -- "${pattern}" "${SSH_LOG}" || true
  else
    printf '0\n'
  fi
}

client_state() {
  "${FW}" bridge status --json | jq -r --arg id "$1" 'first(.clients[] | select(.machine == $id) | "\(.running)|\(.state)|\(.reason)") // "none"'
}

t_describe "activate：B 未装插件"

t_it "非交互且未给 --install：不代装，给出命令与 --install 提示"
run "${FW}" machines activate m-dev
t_exit_ok 4 "${rc}" "die 4"
t_contains "herdr plugin install zzjcool/herdr-forward --yes" "${err}" "给出安装命令"
t_contains "--install" "${err}" "提示 --install"
installs="$(ssh_calls 'plugin install')"
t_eq "0" "${installs}" "没有代装"
t_file_absent "${STATE_DIR}/activated-machines.json" "未写激活记录"

t_it "--no-install：同上（显式拒绝）"
run "${FW}" machines activate m-dev --no-install
t_exit_ok 4 "${rc}" "die 4"

t_it "--install：代装 → 重新探测 → 配远端键位并重载 → 启动桥接"
run "${FW}" machines activate dev-box --install
t_exit_ok 0 "${rc}" "exit 0"
t_contains "安装完成" "${out}" "报告安装完成"
installs="$(ssh_calls 'plugin install')"
t_eq "1" "${installs}" "代装一次"
dest="$(grep -F 'plugin install' "${SSH_LOG}" | cut -f1)"
t_eq "ssh://dev@b-host:2222" "${dest}" "按 saved machine 的 target 连（ssh:// 原样）"
hooks="$(ssh_calls 'startup-hook.sh')"
reloads="$(ssh_calls 'reload-config')"
t_eq "1|1" "${hooks}|${reloads}" "远端 startup hook 跑过且 server 已重载"
hook_cmd="$(grep -F 'startup-hook.sh' "${SSH_LOG}" | cut -f2)"
t_contains "HERDR_PLUGIN_STATE_DIR=${B_STATE}" "${hook_cmd}" "远端 hook 用 B 的 state 目录"
t_contains "远端键位已装好并已重载" "${out}" "告诉用户 B 上 prefix+f 可用"
active="$(jq -r '.active' "${STATE_DIR}/activated-machines.json")"
t_eq "m-dev" "${active}" "active=m-dev"

t_it "桥接已在后台启动，连不上时进入 retrying 并给出原因"
wait_state() {
  local want="$1" tries=50 got=""
  while ((tries > 0)); do
    got="$(client_state m-dev)"
    # shellcheck disable=SC2053 # want 是 glob 模式（原因文本只校验前缀）
    [[ ${got} == ${want} ]] && return 0
    sleep 0.2
    tries=$((tries - 1))
  done
  printf '%s\n' "${got}"
  return 1
}
wait_state 'true|retrying|SSH 连接失败*' >/dev/null
t_exit_ok 0 "$?" "running + retrying + 原因"
serve_calls="$(ssh_calls 'bridge serve')"
t_match '^[1-9][0-9]*$' "${serve_calls}" "supervisor 已尝试连接 B 的 bridge serve"
serve_cmd="$(grep -F 'bridge serve' "${SSH_LOG}" | head -1 | cut -f2)"
t_contains "HERDR_PLUGIN_STATE_DIR=${B_STATE}" "${serve_cmd}" "serve 用 B 的 state 目录"
t_contains "${B_ROOT}/bin/forward" "${serve_cmd}" "serve 用 B 的插件根"
sup1="$(jq -r '.pid' "${STATE_DIR}/bridge/client-m-dev.json")"

t_describe "activate：B 已装插件（重复激活幂等）"
reloads_before="$(grep -c reload "${HF_RELOAD_LOG}" 2>/dev/null || true)"
t_eq "0" "${reloads_before:-0}" "终端里手敲的激活（无 HERDR_PLUGIN_ID）不重载本机 herdr"
# 从 Port Forward 面板激活 = 以 herdr 插件身份运行（herdr 注入 HERDR_PLUGIN_ID）
HERDR_PLUGIN_ID=zzjcool:forward run "${FW}" machines activate m-dev
t_exit_ok 0 "${rc}" "exit 0"
t_contains "已在运行" "${out}" "桥接不重复启动"
sup2="$(jq -r '.pid' "${STATE_DIR}/bridge/client-m-dev.json")"
t_eq "${sup1}" "${sup2}" "同一个 supervisor"
reloads_after="$(grep -c reload "${HF_RELOAD_LOG}" 2>/dev/null || true)"
t_eq "1" "${reloads_after}" "以插件身份激活后自动重载本机 herdr（tab bar 立即切换）"
t_contains "已自动重载 herdr 配置" "${out}" "告诉用户已自动重载"

t_describe "machines doctor 报告桥接状态"
run "${FW}" machines doctor
t_contains "bridge      : 运行中" "${out}" "doctor 显示桥接运行中"

t_describe "deactivate：停桥接"
run "${FW}" machines deactivate m-dev
t_exit_ok 0 "${rc}" "exit 0"
st="$(client_state m-dev)"
t_eq "none" "${st}" "桥接状态已清"
if kill -0 "${sup1}" 2>/dev/null; then
  t_fail "supervisor 仍在运行（pid=${sup1}）"
else
  t_pass "supervisor 已退出"
fi

t_done
