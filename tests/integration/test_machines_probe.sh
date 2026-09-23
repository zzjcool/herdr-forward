#!/usr/bin/env bash
# tests/integration/test_machines_probe.sh — `forward machines activate` 的真 SSH 全链路
#
# 与 unit 层的分工：unit（test_machines_cmd.sh）用假 ssh_probe_plugin 回放四态；
# 本文件起**真的用户态 sshd** + **真的 ssh**，验证探测—推导—写记录—切 tab bar 的整条链。
#
# 关键 fixture 技巧（保证零污染 + 真实）：
#   * 用 127.0.0.2 而非 127.0.0.1 当 ssh_target：127.0.0.1 是 machines_is_local_target 的
#     强信号，会用同机短路跳过 ssh；127.0.0.2 同属 loopback（真连得上）但不触发短路。
#   * sshd 用 `ForceCommand <wrapper>`：wrapper 把 SSH_ORIGINAL_COMMAND 放进一个**假的远端
#     HOME** 里执行 —— 这样远端探测读的 $HOME/.config/herdr/plugins.json 是 TMP 里的 fixture，
#     而**不会**写/读宿主真实 HOME（PermitUserEnvironment 不参与，零污染）。
#   * 宿主的 known_hosts 也在 TMP（测试自身 HOME 被改），先用 accept-new 预热一次，
#     之后 M1 的裸 `ssh -o BatchMode=yes` 才能连上（=真实用户已信任主机键的状态）。
#
# M1（lib/ssh-probe.sh）尚未合入时：本文件仍完整跑 fixture 与降级断言，
# M1 专属断言显式 t_skip（绝不静默跳过），M1 合入后自动变绿。
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if [[ -f "${ROOT}/tests/lib/assertions.sh" ]]; then
  # shellcheck source=/dev/null
  source "${ROOT}/tests/lib/assertions.sh"
fi
if ! declare -F t_fail_note >/dev/null 2>&1; then
  t_fail_note() { t_fail "$@"; }
fi

if [[ ! -f "${ROOT}/lib/machines.sh" ]]; then
  printf 'RED: %s 尚未实现\n' "${ROOT}/lib/machines.sh" >&2
  exit 1
fi

command -v sshd >/dev/null 2>&1 || {
  printf 'integration requires sshd (OpenSSH server)\n' >&2
  exit 1
}
command -v ssh-keygen >/dev/null 2>&1 || {
  printf 'integration requires ssh-keygen\n' >&2
  exit 1
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/machines-probe.XXXXXX")"

# ---------------------------------------------------------------------------
# 隔离：宿主的 HOME / state / config 全在 WORK（绝不碰真实 ~/.config/herdr）
# ---------------------------------------------------------------------------
export HOME="${WORK}/home"
export XDG_CONFIG_HOME="${WORK}/home/.config"
export XDG_STATE_HOME="${WORK}/home/.local/state"
mkdir -p "${HOME}/.ssh" "${XDG_CONFIG_HOME}" "${XDG_STATE_HOME}"
chmod 700 "${HOME}/.ssh"

PLUGIN_ROOT="${WORK}/plugin"
STATE_DIR="${WORK}/plugin-state"
mkdir -p "${PLUGIN_ROOT}/bin" "${PLUGIN_ROOT}/lib" "${PLUGIN_ROOT}/scripts" "${STATE_DIR}"
cp "${ROOT}/bin/forward" "${PLUGIN_ROOT}/bin/forward"
chmod +x "${PLUGIN_ROOT}/bin/forward"
for f in common state machines; do
  cp "${ROOT}/lib/${f}.sh" "${PLUGIN_ROOT}/lib/${f}.sh"
done
# M1 交付的探测实现若已合入就一起带上（联调点；缺失时走降级路径）
HAVE_M1=0
if [[ -f "${ROOT}/lib/ssh-probe.sh" ]]; then
  cp "${ROOT}/lib/ssh-probe.sh" "${PLUGIN_ROOT}/lib/ssh-probe.sh"
  HAVE_M1=1
fi
for s in install-tabbar.sh install-keys.sh; do
  cp "${ROOT}/scripts/${s}" "${PLUGIN_ROOT}/scripts/${s}"
done
chmod +x "${PLUGIN_ROOT}/scripts/"*.sh

export HERDR_PLUGIN_STATE_DIR="${STATE_DIR}"
export HERDR_PLUGIN_CONFIG_DIR="${WORK}/config"
export HERDR_CONFIG_PATH="${HOME}/.config/herdr/config.toml"
mkdir -p "${HERDR_PLUGIN_CONFIG_DIR}" "$(dirname "${HERDR_CONFIG_PATH}")"

FW="${PLUGIN_ROOT}/bin/forward"
STATE_FILE="${STATE_DIR}/activated-machines.json"

# ---------------------------------------------------------------------------
# ssh trust 的注入点（**不是** mock）：OpenSSH 用 getpwuid 的 home 而非 $HOME 定位
# ~/.ssh/known_hosts，所以「把 fixture 主机键写进测试自己的 known_hosts」无法让裸 ssh 看到，
# 而写真实 ~/.ssh/known_hosts 是禁止的。解法：PATH 前置一个只**追加两个选项**的 ssh wrapper
# （UserKnownHostsFile 指向 TMP + accept-new），再 exec 真的 /usr/bin/ssh。
# 这样 M1 的 ssh_probe_run 调用签名一字未改，探测链路（真 ssh / 真 sshd / 真远端命令）
# 完全真实；wrapper 只是替用户把「这台主机已信任」这个既存状态补上。
# ---------------------------------------------------------------------------
mkdir -p "${WORK}/bin"
# shellcheck disable=SC2016  # wrapper 里的 "$@" 必须留给 wrapper 自己展开（不是宿主的）
cat >"${WORK}/bin/ssh" <<EOF
#!/bin/sh
exec /usr/bin/ssh \\
  -o UserKnownHostsFile='${HOME}/.ssh/known_hosts' \\
  -o StrictHostKeyChecking=accept-new \\
  "\$@"
EOF
chmod +x "${WORK}/bin/ssh"
export PATH="${WORK}/bin:${PATH}"

# ---------------------------------------------------------------------------
# 远端 fixture：假 HOME + 假 herdr（PATH 注入）+ plugins.json + 已存在的 state 目录
# ---------------------------------------------------------------------------
REMOTE_HOME="${WORK}/remote-home"
REMOTE_PLUGIN_ROOT="${REMOTE_HOME}/.config/herdr/plugins/github/zzjcool-forward-ab12cd34"
REMOTE_STATE="${REMOTE_HOME}/.local/state/herdr/plugins/zzjcool%3Aforward"
mkdir -p "${REMOTE_HOME}/.local/bin" "${REMOTE_PLUGIN_ROOT}" "${REMOTE_STATE}" \
  "${REMOTE_HOME}/.config/herdr"

printf 'id = "zzjcool:forward"\nname = "herdr-forward"\n' >"${REMOTE_PLUGIN_ROOT}/herdr-plugin.toml"
printf '%s\n' "[{\"plugin_id\":\"zzjcool:forward\",\"enabled\":true,\"plugin_root\":\"${REMOTE_PLUGIN_ROOT}\"}]" \
  >"${REMOTE_HOME}/.config/herdr/plugins.json"

# 远端 herdr：`plugin list` 输出含 zzjcool:forward（M1 的 REMOTE_LIST_CMD 判定 present 的依据）
cat >"${REMOTE_HOME}/.local/bin/herdr" <<'EOF'
#!/bin/sh
case "$1 $2" in
"plugin list")
  printf '%s\n' '[{"plugin_id":"zzjcool:forward","enabled":true,"plugin_root":"'"${HOME}"'/FAKE_NOT_USED"}]'
  ;;
*)
  printf '%s\n' "herdr: unsupported in this fixture: $*" >&2
  exit 2
  ;;
esac
EOF
chmod +x "${REMOTE_HOME}/.local/bin/herdr"

# 远端 PATH 的干净副本：只放探测真正需要的工具（symlink），**不放 herdr**。
# 为什么必须这样：本机 /usr/bin/herdr 是真实存在的（宿主装了 herdr），若远端 PATH 里有
# /usr/bin，REMOTE_LIST_CMD 的 `command -v herdr` 会命中**真实 herdr** 并输出
# "No plugins installed."，把 fixture 变成「B 上没装插件」（假阳性 absent）。
# 真实目标机（B）的 herdr 只装在 ~/.local/bin —— 这正是 fallback 分支存在的理由。
mkdir -p "${WORK}/remote-bin"
for tool in sh python3 sed head grep cat ls cut tr env dirname basename test; do
  real="$(command -v "${tool}" 2>/dev/null || true)"
  [[ -n "${real}" ]] && ln -sf "${real}" "${WORK}/remote-bin/${tool}"
done

# ForceCommand wrapper：把远端命令放进假 HOME 执行（零污染的关键）。
# PATH 刻意**不含** ~/.local/bin：这正是真实世界「非交互 shell 找不到 herdr」的形状，
# 也是 setup-client.sh 的 REMOTE_LIST_CMD（`command -v herdr || PATH=$HOME/.local/bin:$PATH herdr ...`）
# 里 fallback 分支的触发条件。若把 .local/bin 放进 PATH，`command -v` 会命中断言短路。
cat >"${WORK}/remote-wrapper.sh" <<EOF
#!/bin/sh
# 由 sshd ForceCommand 调用；SSH_ORIGINAL_COMMAND 是客户端给的远端命令。
: "\${SSH_ORIGINAL_COMMAND:=true}"
HOME='${REMOTE_HOME}' XDG_CONFIG_HOME='${REMOTE_HOME}/.config' \\
  XDG_STATE_HOME='${REMOTE_HOME}/.local/state' \\
  PATH='${WORK}/remote-bin' \\
  exec /bin/sh -c "\${SSH_ORIGINAL_COMMAND}"
EOF
chmod +x "${WORK}/remote-wrapper.sh"

# ---------------------------------------------------------------------------
# 端口 / 密钥 / sshd
# ---------------------------------------------------------------------------
free_port() {
  local candidate
  local candidates=""
  candidates="$(shuf -i 22000-29999 -n 100)"
  while read -r candidate; do
    if ! (exec 3<>"/dev/tcp/127.0.0.2/${candidate}") 2>/dev/null; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done <<<"${candidates}"
  printf '0\n'
}

SSHD_PORT="$(free_port)"
[[ "${SSHD_PORT}" != "0" ]] || {
  printf 'could not allocate a test port\n' >&2
  exit 1
}

ssh-keygen -q -t ed25519 -N '' -f "${WORK}/hostkey"
ssh-keygen -q -t ed25519 -N '' -f "${WORK}/clientkey"
cp "${WORK}/clientkey.pub" "${WORK}/authorized_keys"
chmod 600 "${WORK}/authorized_keys" "${WORK}/clientkey" "${WORK}/hostkey"

SSH_USER="$(id -un)"

cat >"${WORK}/sshd_config" <<CFG
Port ${SSHD_PORT}
ListenAddress 127.0.0.2
HostKey ${WORK}/hostkey
PidFile ${WORK}/sshd.pid
UsePAM no
PasswordAuthentication no
PubkeyAuthentication yes
PermitRootLogin no
StrictModes no
AuthorizedKeysFile ${WORK}/authorized_keys
ForceCommand ${WORK}/remote-wrapper.sh
LogLevel ERROR
PerSourcePenalties no
CFG
if ! /usr/bin/sshd -t -f "${WORK}/sshd_config" 2>"${WORK}/sshd_t.err"; then
  grep -v '^PerSourcePenalties' "${WORK}/sshd_config" >"${WORK}/sshd_config.2"
  mv "${WORK}/sshd_config.2" "${WORK}/sshd_config"
  /usr/bin/sshd -t -f "${WORK}/sshd_config" 2>>"${WORK}/sshd_t.err" || {
    printf 'sshd -t rejected config:\n' >&2
    cat "${WORK}/sshd_t.err" >&2
    exit 1
  }
fi

SSHD_PID=""
AGENT_PID=""

kill_tree() {
  local root="${1:-}"
  [[ "${root}" =~ ^[0-9]+$ ]] || return 0
  local child
  for child in $(pgrep -P "${root}" 2>/dev/null || true); do
    kill_tree "${child}"
  done
  kill -KILL "${root}" 2>/dev/null || true
}

cleanup() {
  local rc=$?
  set +e
  kill_tree "${SSHD_PID}"
  if [[ -n "${AGENT_PID}" ]]; then
    kill -TERM "${AGENT_PID}" 2>/dev/null
    kill_tree "${AGENT_PID}"
  fi
  rm -rf "${WORK}"
  return "${rc}"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

wait_port() {
  local tries=0
  while ((tries < 50)); do
    if (exec 3<>"/dev/tcp/127.0.0.2/${SSHD_PORT}") 2>/dev/null; then
      return 0
    fi
    tries=$((tries + 1))
    sleep 0.1
  done
  return 1
}

out=""
err=""
rc=0

_cap() {
  rc=0
  out="$("$@" 2>"${WORK}/stderr")" || rc=$?
  err="$(cat "${WORK}/stderr" 2>/dev/null || true)"
  return 0
}

_fw() { _cap "${FW}" "$@"; }

_jf() {
  v="$(jq -r "${2-"."}" "${1-}" 2>/dev/null || true)"
  return 0
}

# _jo <jq-filter>：对 ${out} 求值落 v（先落变量再断言，避免 SC2312）
_jo() {
  v="$(printf '%s' "${out}" | jq -r "${1-"."}" 2>/dev/null || true)"
  return 0
}

# _tb <config>：该 config 里本插件的 tab_bar_right command 落 v（无则空）
_tb() {
  v="$(
    python3 - "${1}" <<'PYEOF' 2>/dev/null || true
import sys, tomllib
try:
    with open(sys.argv[1], "rb") as fh:
        doc = tomllib.load(fh)
    for e in ((doc.get("ui") or {}).get("tab_bar_right") or []):
        if isinstance(e, dict) and "bin/forward" in str(e.get("command", "")):
            print(e["command"]); break
except Exception:
    print("")
PYEOF
  )"
  return 0
}

v=""

# --- 假 herdr（宿主侧 machine list --json）：saved machine 指向 127.0.0.2 sshd ---
cat >"${WORK}/bin/herdr" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "machine" && "\$2" == "list" ]]; then
  cat <<'JSON'
[{"id":"m-loop","label":"loop-remote","target":"${SSH_USER}@127.0.0.2:${SSHD_PORT}","session":"default","enabled":true,"selected":false}]
JSON
  exit 0
fi
exit 127
EOF
chmod +x "${WORK}/bin/herdr"
export HERDR_BIN_PATH="${WORK}/bin/herdr"

# --- ssh-agent（M1 的 ssh 调用不带 -F /dev/null，但走 agent 最稳） ---
ssh-agent -a "${WORK}/agent.sock" -s >"${WORK}/agent.env"
# shellcheck source=/dev/null
source "${WORK}/agent.env" >/dev/null
AGENT_PID="${SSH_AGENT_PID:-}"
export SSH_AUTH_SOCK
ssh-add "${WORK}/clientkey" >/dev/null 2>&1

t_describe "fixture: 用户态 sshd 监听 127.0.0.2（非短路信号）+ 假远端 HOME"

t_it "sshd 起来并监听随机高端口"
/usr/bin/sshd -f "${WORK}/sshd_config" -E "${WORK}/sshd.log"
SSHD_PID="$(cat "${WORK}/sshd.pid")"
wait_port
t_eq "0" "$?" "sshd 已监听"

t_it "预热 known_hosts（accept-new 由 PATH 上的 ssh wrapper 提供），使后续裸 ssh 可连（=真实用户状态）"
_cap timeout 15 ssh -o BatchMode=yes \
  -p "${SSHD_PORT}" "${SSH_USER}@127.0.0.2" 'printf PROBE_OK'
t_eq "0" "${rc}" "预热连接 rc"
t_contains "PROBE_OK" "${out}" "远端命令执行成功"

# 远端 herdr 供 REMOTE_LIST_CMD 判定 present（路径推导仍由 plugins.json 负责）
cat >"${REMOTE_HOME}/.local/bin/herdr" <<'EOF'
#!/bin/sh
case "$1 $2" in
"plugin list")
  printf '%s\n' '[{"plugin_id":"zzjcool:forward","enabled":true}]'
  ;;
*)
  printf '%s\n' "herdr: unsupported in this fixture: $*" >&2
  exit 2
  ;;
esac
EOF
chmod +x "${REMOTE_HOME}/.local/bin/herdr"

t_it "ForceCommand wrapper 生效：远端命令跑在假 HOME 里（零污染证明）"
# shellcheck disable=SC2016  # $HOME 由远端 shell 展开（本用例测的就是远端 HOME）
_cap timeout 15 ssh -o BatchMode=yes -p "${SSHD_PORT}" "${SSH_USER}@127.0.0.2" 'printf "%s" "$HOME"'
t_eq "${REMOTE_HOME}" "${out}" "远端 HOME 是 TMP 里的 fixture，不是宿主真实 HOME"

t_it "127.0.0.2 不被 machines_is_local_target 误判为同机（不触发短路）"
# shellcheck source=/dev/null
source "${PLUGIN_ROOT}/lib/machines.sh"
_cap machines_is_local_target "${SSH_USER}@127.0.0.2:${SSHD_PORT}"
t_eq "no" "${out}" "127.0.0.2 -> no（本用例的前提）"
_cap machines_is_local_target "127.0.0.1"
t_eq "yes" "${out}" "127.0.0.1 仍是强信号"

# ---------------------------------------------------------------------------
t_describe "machines list：saved machine 从假 herdr 读出，未激活"

_cap rm -rf "${STATE_DIR}"
_cap mkdir -p "${STATE_DIR}"
_fw machines list --json
t_exit_ok 0 "${rc}" "list --json rc"
_jo 'length'
t_eq "1" "${v}" "一台 machine"
_jo '.[0].state'
t_eq "inactive" "${v}" "未激活"

# ---------------------------------------------------------------------------
t_describe "probe 链路（M1 的 lib/ssh-probe.sh 合入后为真探测）"

if [[ "${HAVE_M1}" -eq 1 ]]; then
  t_it "activate：真 ssh 探测 present → 推导远端插件根/state → 写记录 + tab bar 指向远端"
  _reset_ok=""
  _cap rm -f "${HERDR_CONFIG_PATH}"
  _fw machines activate loop-remote
  t_exit_ok 0 "${rc}" "activate rc=0（probe present）"
  t_file_exists "${STATE_FILE}" "写了激活记录"
  _jf "${STATE_FILE}" '.active'
  t_eq "m-loop" "${v}" "active=m-loop"
  _jf "${STATE_FILE}" '.machines["m-loop"].server_root'
  t_eq "${REMOTE_PLUGIN_ROOT}" "${v}" "server_root 是远端真实路径（探测推导）"
  _jf "${STATE_FILE}" '.machines["m-loop"].state_dir'
  t_eq "${REMOTE_STATE}" "${v}" "state_dir 是远端真实路径"
  t_file_exists "${HERDR_CONFIG_PATH}" "config 已写"
  _tb "${HERDR_CONFIG_PATH}"
  t_contains "${REMOTE_PLUGIN_ROOT}/bin/forward" "${v}" "tab bar command 指向远端插件根"
  t_contains "${REMOTE_STATE}" "${v}" "tab bar command 带远端 state 目录"

  t_it "doctor：路径未漂移 → 报告无需修复"
  _fw machines doctor
  t_exit_ok 0 "${rc}" "doctor rc=0"
  t_contains "无需修复" "${out}" "报告一致"

  t_it "sshd 被 kill 后 activate → unreachable（die 4），不写记录"
  kill_tree "${SSHD_PID}"
  SSHD_PID=""
  sleep 0.3
  _cap rm -f "${STATE_FILE}" "${HERDR_CONFIG_PATH}"
  # 用一台不同的 machine id 触发全新激活（避免命中已有记录）
  cat >"${WORK}/bin/herdr" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "machine" && "\$2" == "list" ]]; then
  cat <<'JSON'
[{"id":"m-dead","label":"dead-remote","target":"${SSH_USER}@127.0.0.2:${SSHD_PORT}","session":"default","enabled":true,"selected":false}]
JSON
  exit 0
fi
exit 127
EOF
  chmod +x "${WORK}/bin/herdr"
  _fw machines activate dead-remote
  t_exit_ok 4 "${rc}" "unreachable -> die 4"
  t_contains "unreachable" "${err}" "标出 unreachable"
  t_file_absent "${STATE_FILE}" "未写记录"

  t_it "doctor 遇 unreachable：只报告，不动 config 与记录"
  # 先恢复 sshd 造一条有效记录，再 kill 后 doctor
  /usr/bin/sshd -f "${WORK}/sshd_config" -E "${WORK}/sshd.log"
  SSHD_PID="$(cat "${WORK}/sshd.pid")"
  wait_port
  cat >"${WORK}/bin/herdr" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "machine" && "\$2" == "list" ]]; then
  cat <<'JSON'
[{"id":"m-loop","label":"loop-remote","target":"${SSH_USER}@127.0.0.2:${SSHD_PORT}","session":"default","enabled":true,"selected":false}]
JSON
  exit 0
fi
exit 127
EOF
  chmod +x "${WORK}/bin/herdr"
  _cap rm -f "${STATE_FILE}" "${HERDR_CONFIG_PATH}"
  _fw machines activate loop-remote
  t_exit_ok 0 "${rc}" "重新 activate rc=0"
  _md5_before="$(md5sum "${HERDR_CONFIG_PATH}" 2>/dev/null | awk '{print $1}' || true)"
  _root_before="$(jq -r '.machines["m-loop"].server_root' "${STATE_FILE}" 2>/dev/null || true)"
  kill_tree "${SSHD_PID}"
  SSHD_PID=""
  sleep 0.3
  _fw machines doctor
  t_exit_ok 4 "${rc}" "unreachable doctor -> die 4"
  _md5_after="$(md5sum "${HERDR_CONFIG_PATH}" 2>/dev/null | awk '{print $1}' || true)"
  t_eq "${_md5_before}" "${_md5_after}" "config 字节未变（不误删）"
  t_eq "${_root_before}" "$(jq -r '.machines["m-loop"].server_root' "${STATE_FILE}" 2>/dev/null || true)" "记录未变"
else
  t_it "M1（lib/ssh-probe.sh）尚未合入：探测降级 unreachable + die 4，绝不假装 present"
  _cap rm -f "${STATE_FILE}" "${HERDR_CONFIG_PATH}"
  _fw machines activate loop-remote
  t_exit_ok 4 "${rc}" "降级 -> die 4"
  t_contains "unreachable" "${err}" "标出 unreachable"
  t_file_absent "${STATE_FILE}" "未写记录（不会写入指向 A 的假路径）"
  t_file_absent "${HERDR_CONFIG_PATH}" "未改 config"

  t_it "M1 未合入时：本机直连 fixture 仍真实可用（fixture 本身没问题）"
  # shellcheck disable=SC2016  # $HOME 留给远端 shell 展开（与 setup-client.sh 同款）
  _cap timeout 15 ssh -o BatchMode=yes -p "${SSHD_PORT}" "${SSH_USER}@127.0.0.2" \
    'command -v herdr >/dev/null 2>&1 || PATH="$HOME/.local/bin:$PATH" herdr plugin list'
  t_eq "0" "${rc}" "远端两条命令可执行"
  t_contains "zzjcool:forward" "${out}" "远端 plugin list 含本插件（present 判定可用）"

  t_skip "M1 合入后：activate 真探测 present 推导远端路径 + tab bar 指向远端（本文件已就绪）"
  t_skip "M1 合入后：doctor 真探测（路径漂移重写 / unreachable 只报告）"
fi

# ---------------------------------------------------------------------------
t_describe "收尾"

t_it "无残留 ssh/herdr-forward 进程"
sleep 0.5
t_no_zombie_ssh

t_done
