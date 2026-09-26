#!/usr/bin/env bash
# scripts/e2e/run-two-machines.sh — 两台「机器」上的真实用户场景（ARCHITECTURE §A.3.3）
#
# A = laptop（用户 fwduser）与 B = devbox（用户 bob）各一个容器，经一张 --internal 私有网络
# 互通；两边都跑真 herdr（宿主二进制只读挂载，§C.4 模式 A）与真 sshd。A 上的 **真 herdr TUI
# client** 跑在 tmux 里：tmux 充当虚拟终端（send-keys 按键、capture-pane 读屏），整个流程
# 和用户手工操作一样，没有「绕过 UI 直接调 CLI」的捷径：
#
#   herdr machine add devbox → 打开 herdr → prefix+f → 面板里按 1、y 激活 devbox
#   → prefix+w 切到 devbox → prefix+f（此时解析的是 B 的键位）→ B 的面板里按 f、1
#   → A 的 localhost 取到 B 只绑 127.0.0.1 的服务 → tab bar 出现 ⇅5173
#   → 在 B 的 pane 里 Ctrl+click 一个 localhost 链接 → A 上打开
#   → 断网 / A 的 herdr server 重启后自愈 → 回到 Local 用面板停用 devbox
#
# 判定同时看屏幕（capture-pane）与屏幕外的事实（A 的 localhost 回包、监听者、进程、
# 两边插件日志），任何一步只「看起来对」都不算过。
#
# 红线（§C.2，与 run-docker.sh 同一套）：只挂载仓库源码与宿主 herdr（只读）；不发布端口、
# 不用 host 网络；私有网络 --internal（容器不出网）；宿主侧不跑任何 herdr 命令。
set -Eeuo pipefail

# 宿主侧绝不连真实 herdr server（SCOUT-FACTS §1.1）；容器内另有独立 HOME
unset HERDR_SOCKET_PATH HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_BIN_PATH HERDR_ENV || true

PROJ="$(cd "$(dirname "$0")/../.." && pwd)"
IMAGE="${HERDR_FORWARD_E2E_IMAGE:-herdr-forward-e2e:local}"
HERDR_HOST_BIN="${HERDR_FORWARD_E2E_HERDR:-/usr/bin/herdr}"
SUFFIX="$$-${RANDOM}"
INJECT_DIR="${TMPDIR:-/tmp}/hf-two-machines-${SUFFIX}"
PLUGIN_TAR="${INJECT_DIR}/plugin.tar"
NET="hf2m-${SUFFIX}"
A="hf2m-a-${SUFFIX}"
B="hf2m-b-${SUFFIX}"

A_HOME="/home/fwduser"
B_HOME="/home/bob"
A_STATE="${A_HOME}/.local/state/herdr/plugins/zzjcool%3Aforward"
B_STATE="${B_HOME}/.local/state/herdr/plugins/zzjcool%3Aforward"
B_FWD="${B_HOME}/plugin/bin/forward"
# A 的 herdr server 的环境：插件命令继承它；短间隔让断网/重连在测试时长内完成
A_SERVER_ENV=(
  "BRIDGE_SERVER_ALIVE_S=2"
  "BRIDGE_BACKOFF_MAX_S=5"
  "HERDR_FORWARD_OPENER=${A_HOME}/opener.sh"
)

log() { printf '[two-machines] %s\n' "$*"; }

# shellcheck source=/dev/null
source "${PROJ}/tests/assertions.sh"
out=""
rc=0
WAITED_RC=1

# --- 前置条件 -----------------------------------------------------------------
if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  echo "two-machines: docker 不可用" >&2
  exit 127
fi
if [[ ! -x ${HERDR_HOST_BIN} ]]; then
  echo "two-machines: 宿主没有 herdr（${HERDR_HOST_BIN}）；本验证需要真 herdr（§C.4 模式 A）" >&2
  exit 127
fi
log "构建/复用镜像 ${IMAGE}"
timeout 900 docker build -q -f "${PROJ}/scripts/e2e/Dockerfile" -t "${IMAGE}" "${PROJ}" >/dev/null
log "构建一次 Go CLI，并注入两机 tar（Phase 4 §16.4）"
mkdir -p "${INJECT_DIR}"
if ! (cd "${PROJ}/go" && GOFLAGS=-mod=vendor go build -o "${INJECT_DIR}/forward-go" ./cmd/forward) >"${INJECT_DIR}/go-build.log" 2>&1; then
  echo "two-machines: Go CLI 构建失败（${INJECT_DIR}/go-build.log）" >&2
  cat "${INJECT_DIR}/go-build.log" >&2
  exit 1
fi
# Build a single source tar for both containers.  The binary is appended under
# bin/forward-go so the two-machine assertions exercise the same Go dispatch,
# independent of ci.sh's migration adapter parking the checkout artifact.
tar --exclude=.git --exclude=.pi-subagents --exclude=test-results --exclude=node_modules \
  -cf "${PLUGIN_TAR}" -C "${PROJ}" .
tar --transform='s,^forward-go$,bin/forward-go,' -rf "${PLUGIN_TAR}" -C "${INJECT_DIR}" forward-go
if ! timeout 60 docker run --rm -v "${HERDR_HOST_BIN}:/usr/local/bin/herdr:ro" \
  --entrypoint /usr/local/bin/herdr "${IMAGE}" --version >/dev/null 2>&1; then
  echo "two-machines: 宿主 herdr 在容器内跑不起来（模式 B）；本验证需要真 herdr" >&2
  exit 127
fi

cleanup() {
  local code=$?
  set +e
  if ((code != 0)) || [[ ${FAIL:-0} != 0 ]]; then
    printf '\n# --- diagnostics ---\n'
    printf '# A screen:\n'
    docker exec "${A}" tmux -L hf capture-pane -p -t ui 2>/dev/null | sed 's/[[:space:]]*$//' | awk 'NF' | sed 's/^/# | /'
    docker exec "${A}" bash -c "tail -n 20 '${A_STATE}'/bridge/*.log '${A_STATE}'/bridge/*.out '${A_STATE}'/logs/forward.log ~/.config/herdr/herdr-client.log 2>/dev/null" 2>/dev/null | sed 's/^/# A  /'
    docker exec -u bob "${B}" bash -c "tail -n 20 '${B_STATE}'/logs/forward.log ~/sshd.log ~/herdr-server.out 2>/dev/null" 2>/dev/null | sed 's/^/# B  /'
  fi
  docker rm -f "${A}" "${B}" >/dev/null 2>&1
  docker network rm "${NET}" >/dev/null 2>&1
  rm -rf "${INJECT_DIR}"
  return "${code}"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# --- 执行助手 -----------------------------------------------------------------
ax() { docker exec "${A}" bash -c "$1"; }
bx() { docker exec -u bob "${B}" bash -c "$1"; }
b_fwd() { docker exec -u bob "${B}" env "HERDR_PLUGIN_STATE_DIR=${B_STATE}" "${B_FWD}" "$@"; }

# --- UI 助手：tmux 是真 herdr TUI 的虚拟终端 ------------------------------------
ui_screen() { docker exec "${A}" tmux -L hf capture-pane -p -t ui 2>/dev/null | sed 's/[[:space:]]*$//'; }
ui_keys() { docker exec "${A}" tmux -L hf send-keys -t ui "$@"; }
# ui_prefix <key>：herdr 的 prefix + 一个键。A 的键位照搬真实用户的配置：prefix = ctrl+space
# （终端里就是 NUL 字节 0x00），reload = prefix+q，detach = prefix+d。tmux 的键名送不到
# herdr，直接写原始字节才行（真 TUI 实测）。
ui_prefix() {
  docker exec "${A}" tmux -L hf send-keys -t ui -H 00
  sleep 0.3
  ui_keys "$1"
}
# ui_type <text>：在当前 pane 的 shell 里输入一行并回车
ui_type() {
  ui_keys -l "$1"
  ui_keys Enter
}
ui_shows() {
  local screen=""
  screen="$(ui_screen)"
  [[ ${screen} =~ $1 ]] && printf 'yes\n'
  return 0
}
ui_hides() {
  local screen=""
  screen="$(ui_screen)"
  [[ ${screen} =~ $1 ]] || printf 'yes\n'
  return 0
}
tab_bar_has() {
  local screen=""
  screen="$(ui_screen)"
  [[ ${screen%%$'\n'*} == *"$1"* ]] && printf 'yes\n'
  return 0
}
# viewing <user@host>：在当前 pane 里问一句「我在哪」，确认输入真的落在那台机器上
viewing() {
  ui_type "clear; echo WHERE-\$(whoami)@\$(uname -n)"
  sleep 1
  ui_shows "WHERE-$1"
}
# ui_ctrl_click <text>：找到屏幕上的 text，在它中间发一次 Ctrl+左键（SGR 1006 编码，
# 与真实终端里按住 Ctrl 点击发出的序列逐字节相同）
ui_ctrl_click() {
  local needle="$1" cell="" x="" y=""
  cell="$(docker exec "${A}" tmux -L hf capture-pane -p -t ui | python3 -c '
import sys, unicodedata
needle = sys.argv[1]
for row, line in enumerate(sys.stdin.read().split("\n"), 1):
    i = line.find(needle)
    if i >= 0 and "echo" not in line:
        col = sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in line[:i])
        print(row, col + 1 + len(needle) // 2)
        break' "${needle}")"
  [[ -n ${cell} ]] || return 1
  y="${cell% *}"
  x="${cell#* }"
  local press="" release=""
  press="$(printf '\033[<16;%s;%sM' "${x}" "${y}" | od -An -tx1)"
  release="$(printf '\033[<16;%s;%sm' "${x}" "${y}" | od -An -tx1)"
  # shellcheck disable=SC2086 # 十六进制字节序列要按空白拆成多个参数
  docker exec "${A}" tmux -L hf send-keys -t ui -H ${press} ${release}
}

# a_get <port> -> stdout: A 上 GET http://localhost:<port>/ 的最后一行（失败为空）
a_get() {
  docker exec "${A}" bash -c "exec 3<>/dev/tcp/127.0.0.1/${1} 2>/dev/null && printf 'GET / HTTP/1.0\r\n\r\n' >&3 && timeout 3 cat <&3 | tr -d '\r' | tail -n 1" 2>/dev/null || true
}
serves() {
  local got=""
  got="$(a_get "${1}")"
  [[ ${got} == "${2}" ]] && printf 'yes\n'
  return 0
}
a_closed() {
  local n=""
  n="$(ax "ss -Htln 'sport = :${1}' | wc -l")"
  [[ ${n} == "0" ]] && printf 'yes\n'
  return 0
}
a_bridge_state_is() {
  local got=""
  got="$(ax "jq -r '.state' '${A_STATE}'/bridge/client-*.json 2>/dev/null")"
  [[ ${got} == "${1}" ]] && printf 'yes\n'
  return 0
}
b_status_all() {
  local got=""
  got="$(b_fwd list --json | jq -r '[.forwards[].status] | unique | join(",")')"
  [[ ${got} == "${1}" ]] && printf 'yes\n'
  return 0
}
opened() {
  local got=""
  got="$(ax "cat '${A_HOME}/opened.txt' 2>/dev/null")"
  [[ ${got} == *"${1}"* ]] && printf 'yes\n'
  return 0
}
# plugin_actions <a|b> -> stdout: 该机器上本插件跑过的 action id（每行一个）
plugin_actions() {
  local cmd="herdr plugin log list --plugin zzjcool:forward 2>/dev/null | jq -r '.result.logs[] | select(.action_id != null) | .action_id'"
  if [[ $1 == "a" ]]; then
    ax "${cmd}"
  else
    bx "${cmd}"
  fi
}
b_key_count() {
  bx "python3 - <<'PY'
import os, tomllib
p = os.path.expanduser('~/.config/herdr/config.toml')
try:
    d = tomllib.load(open(p, 'rb'))
except Exception:
    print(0); raise SystemExit
print(sum(1 for k in d.get('keys', {}).get('command', []) if str(k.get('command', '')).startswith('zzjcool:forward.')))
PY"
}
panel_still_open() {
  sleep 1.5
  ui_shows 'herdr-forward · Port Forward'
}

# wait_for <seconds> <cmd...>：cmd 的 stdout 为 yes 即 WAITED_RC=0（否则 1）。恒 return 0：
#   set -e 下超时不能直接中断脚本，否则这一步的失败不会被记成 not ok
wait_for() {
  local secs="${1}"
  shift
  local tries=$((secs * 2))
  local got=""
  WAITED_RC=1
  while ((tries > 0)); do
    got="$("$@" 2>/dev/null || true)"
    if [[ ${got} == "yes" ]]; then
      WAITED_RC=0
      return 0
    fi
    sleep 0.5
    tries=$((tries - 1))
  done
  return 0
}

# --- 1. 网络与容器 ------------------------------------------------------------
log "网络 ${NET}（--internal，不出网）+ 容器 ${A} / ${B}"
docker network create --internal "${NET}" >/dev/null
MOUNTS=(
  -v "${HERDR_HOST_BIN}:/usr/local/bin/herdr:ro"
  -v "${PROJ}:/plugin-src:ro"
  -v "${PLUGIN_TAR}:/plugin-go.tar:ro"
)
docker run -d --init --name "${B}" --hostname devbox --network "${NET}" --network-alias devbox \
  --user root "${MOUNTS[@]}" --entrypoint sleep "${IMAGE}" infinity >/dev/null
docker run -d --init --name "${A}" --hostname laptop --network "${NET}" --network-alias laptop \
  "${MOUNTS[@]}" --entrypoint sleep "${IMAGE}" infinity >/dev/null

# The tar already contains the full checkout plus bin/forward-go; no second
# source copy is allowed to accidentally drop the injected Go artifact.
COPY_PLUGIN='mkdir -p ~/plugin && tar -C ~/plugin -xf /plugin-go.tar && chmod 0755 ~/plugin/bin/forward-go'

# --- 2. B：用户 bob、sshd、两个只绑 loopback 的 dev server、herdr server ---------
log "B：用户 bob + sshd + dev server + herdr server"
docker exec "${B}" useradd -m -s /bin/bash bob
bx "set -e
${COPY_PLUGIN}
mkdir -p ~/.ssh ~/www && chmod 700 ~/.ssh
ssh-keygen -q -t ed25519 -N '' -f ~/.ssh/hostkey
cat > ~/sshd_config <<EOF
Port 22022
ListenAddress 0.0.0.0
HostKey ${B_HOME}/.ssh/hostkey
PidFile ${B_HOME}/sshd.pid
UsePAM no
PasswordAuthentication no
PubkeyAuthentication yes
StrictModes no
AuthorizedKeysFile ${B_HOME}/.ssh/authorized_keys
AllowTcpForwarding yes
LogLevel ERROR
EOF
echo hello-from-devbox > ~/www/index.html
mkdir -p /tmp/w8080 && echo hello-8080 > /tmp/w8080/index.html"
docker exec -d -u bob "${B}" /usr/bin/sshd -D -f "${B_HOME}/sshd_config" -E "${B_HOME}/sshd.log"
docker exec -d -u bob -w "${B_HOME}/www" "${B}" python3 -m http.server --bind 127.0.0.1 5173
docker exec -d -u bob -w /tmp/w8080 "${B}" python3 -m http.server --bind 127.0.0.1 8080
bx "setsid herdr server </dev/null >~/herdr-server.out 2>&1 &
for _ in \$(seq 1 20); do [ -S ~/.config/herdr/herdr.sock ] && break; sleep 0.25; done"

# --- 3. A：密钥、ssh config 别名、herdr 配置、插件、herdr server -----------------
log "A：密钥 + ssh config 别名 devbox + 插件 + herdr server"
ax "set -e
mkdir -p ~/.ssh ~/.config/herdr && chmod 700 ~/.ssh
ssh-keygen -q -t ed25519 -N '' -f ~/.ssh/id_ed25519
printf 'Host devbox\n  HostName devbox\n  Port 22022\n  User bob\n  IdentityFile ~/.ssh/id_ed25519\n' > ~/.ssh/config
chmod 600 ~/.ssh/config
printf '#!/bin/sh\nprintf \"%%s\\\\n\" \"\$1\" >> ${A_HOME}/opened.txt\n' > ~/opener.sh
chmod +x ~/opener.sh
printf 'onboarding = false\n\n[update]\nversion_check = false\nmanifest_check = false\n\n[keys]\nprefix = \"ctrl+space\"\nreload_config = \"prefix+q\"\ndetach = \"prefix+d\"\n\n[ui]\ntab_bar_right = [\n  { type = \"hostname\" },\n]\n' > ~/.config/herdr/config.toml
${COPY_PLUGIN}"
A_PUB="$(ax 'cat ~/.ssh/id_ed25519.pub')"
bx "printf '%s\n' '${A_PUB}' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
B_HOSTKEY="$(bx 'cut -d" " -f1,2 ~/.ssh/hostkey.pub')"
ax "printf '[devbox]:22022 %s\n' '${B_HOSTKEY}' > ~/.ssh/known_hosts"
docker exec -d "${A}" env "${A_SERVER_ENV[@]}" bash -c 'exec setsid herdr server </dev/null >>~/herdr-server.out 2>&1'
# shellcheck disable=SC2016 # 整段在容器里的 bash 中展开
ax 'for _ in $(seq 1 20); do [ -S ~/.config/herdr/herdr.sock ] && break; sleep 0.25; done'

t_describe "前置：B 在「server 运行中」装插件（startup hook 未跑，键位未装）"
# shellcheck disable=SC2016 # $(whoami) 要在 B 上展开
run ax 'ssh -o BatchMode=yes devbox "echo ok-\$(whoami)"'
t_eq "ok-bob" "${out}" "A → B ssh（ssh config 别名 devbox）"
bx "herdr plugin link ${B_HOME}/plugin >/dev/null"
n="$(b_key_count)"
t_eq "0" "${n}" "B 的 config 里还没有本插件键位"

# --- 4. 打开真 herdr TUI（此时 A 还没装插件）--------------------------------------
t_describe "A：打开 herdr（tmux 里的真 TUI client），按 prefix+q 重载"
ax 'tmux -L hf -f /dev/null new-session -d -s ui -x 160 -y 45 -e LANG=C.UTF-8 -e LC_ALL=C.UTF-8 herdr
tmux -L hf set -g prefix None
tmux -L hf set -g status off
tmux -L hf set -g escape-time 0'
# 还没有 saved machine 时侧栏标题是「spaces」、没有「Local」行，以 shell 提示符为准
wait_for 20 ui_shows '(spaces|machines) +│'
t_exit_ok 0 "${WAITED_RC}" "herdr 界面已打开"
wait_for 10 viewing "fwduser@laptop"
t_exit_ok 0 "${WAITED_RC}" "当前在 Local（输入落在 A 的 shell）"
ui_prefix q
sleep 1

# --- 5. 往正在运行的 herdr 里装插件（真实用户的顺序）----------------------------------
t_describe "A：往正在运行的 herdr 里装插件 → 不重启、不手动重载，prefix+f 就能用"
# herdr plugin install = 注册插件 + 运行 manifest 的 [[build]]；容器不出网，用 link 注册，
# 再像 herdr 那样在插件根目录下跑同一个 build 命令（herdr 不给 build 注入任何 HERDR_* 变量）。
run ax "herdr plugin link ${A_HOME}/plugin >/dev/null && cd ${A_HOME}/plugin && env -u HERDR_SOCKET_PATH HERDR_FORWARD_SKIP_DOWNLOAD=1 bash scripts/postinstall.sh"
t_exit_ok 0 "${rc}" "安装（build 步骤）退出 0"
t_match '已装好键位|键位：已写入|install-keys: 已写入' "${out}" "build 步骤装好了键位"
t_contains "现在就可以按 prefix+f" "${out}" "build 步骤重载了正在运行的 herdr"
ui_prefix f
wait_for 10 ui_shows 'herdr-forward · Port Forward'
t_exit_ok 0 "${WAITED_RC}" "prefix+f 打开 Port Forward 面板（server 未重启）"
wait_for 5 ui_shows 'MACHINES \(0\)  还没有 saved machine'
t_exit_ok 0 "${WAITED_RC}" "还没有 saved machine 时明说，并给出下一步"
screen="$(ui_screen)"
t_contains "herdr machine add <ssh 目标> --label <名字>" "${screen}" "面板给出 machine add 命令"
hint="$(ui_shows '未列出 saved machines')"
t_eq "" "${hint}" "不再误报「machine list 可能失败」"
ui_keys Enter
wait_for 5 panel_still_open
t_exit_ok 0 "${WAITED_RC}" "按 Enter 面板不会关"
ui_keys x
wait_for 5 ui_hides 'Port Forward'
t_exit_ok 0 "${WAITED_RC}" "x 关闭面板"

t_describe "A：herdr machine add devbox（用户在终端里做的那一步）"
run ax 'timeout 90 herdr machine add devbox --label devbox </dev/null 2>&1'
t_exit_ok 0 "${rc}" "machine add 退出 0"
t_contains "Remote server is ready" "${out}" "herdr 认为远端 server 就绪"
wait_for 20 ui_shows 'devbox'
t_exit_ok 0 "${WAITED_RC}" "侧栏出现 devbox"

# --- 5. A 的面板里激活 devbox -------------------------------------------------------
t_describe "A：prefix+f 打开 Port Forward 面板，按 1、y 激活 devbox"
ui_prefix f
wait_for 10 ui_shows 'MACHINES \(1\)'
t_exit_ok 0 "${WAITED_RC}" "面板弹出并列出 saved machine"
screen="$(ui_screen)"
t_match '\[ \] 1\. devbox' "${screen}" "devbox 为未激活"
t_match 'Port Forward─{60,}' "${screen}" "popup 按 manifest 的 80% 宽度打开（面板行不折断）"
ui_keys 1
wait_for 5 ui_shows '将通过 SSH 只读探测 devbox'
t_exit_ok 0 "${WAITED_RC}" "激活前确认"
ui_keys y
wait_for 60 ui_shows '按任意键返回面板'
t_exit_ok 0 "${WAITED_RC}" "激活完成"
screen="$(ui_screen)"
t_contains "远端键位已装好并已重载" "${screen}" "B 的键位由 A 代装并重载"
t_contains "桥接已启动" "${screen}" "桥接已启动"
t_contains "已自动重载 herdr 配置" "${screen}" "A 自动重载（tab bar 立即切换，不用手动 reload）"
n="$(b_key_count)"
t_eq "3" "${n}" "B 的 config 现在有 3 条本插件键位"
actions="$(plugin_actions a)"
t_contains "add" "${actions}" "A 上跑的是 A 自己插件的 add action"
ui_keys x
wait_for 5 ui_hides 'Port Forward'
t_exit_ok 0 "${WAITED_RC}" "x 关闭面板（暂停时按的键直接生效）"
wait_for 20 a_bridge_state_is connected
t_exit_ok 0 "${WAITED_RC}" "A 的桥接 connected"

# --- 6. 切到 devbox，用 B 的面板映射端口 ---------------------------------------------
t_describe "prefix+w 切到 devbox；prefix+f 打开的是 B 的面板"
ui_prefix w
sleep 1
ui_keys Down
sleep 0.5
ui_keys Enter
wait_for 15 viewing "bob@devbox"
t_exit_ok 0 "${WAITED_RC}" "输入现在落在 B 的 shell"
ui_prefix f
wait_for 10 ui_shows 'CLIENT  laptop 已连接'
t_exit_ok 0 "${WAITED_RC}" "B 的面板：client laptop 已连接"
screen="$(ui_screen)"
t_match 'f1  5173 +python3' "${screen}" "LISTENING 列出 B 的 5173"
t_match 'f2  8080 +python3' "${screen}" "LISTENING 列出 B 的 8080"
hint="$(ui_shows '未列出 saved machines')"
t_eq "" "${hint}" "B 上不再出现 saved machines 排障提示"
actions="$(plugin_actions b)"
t_contains "add" "${actions}" "按键由 B 的插件处理（B 的插件日志有 add）"

t_it "B 的面板里按 f、1 → A 的 localhost:5173 取到 B 的服务"
ui_keys f
sleep 0.5
ui_keys 1
wait_for 10 ui_shows '已映射本机 5173'
t_exit_ok 0 "${WAITED_RC}" "面板提示已映射"
wait_for 15 serves 5173 hello-from-devbox
t_exit_ok 0 "${WAITED_RC}" "A GET localhost:5173 = B 的页面"
run ax "ss -Htlnp 'sport = :5173'"
listeners="$(printf '%s\n' "${out}" | awk '{print $4}' | sort -u | paste -sd ' ' -)"
t_match '^(\[::1\]:5173 )?127\.0\.0\.1:5173( \[::1\]:5173)?$' "${listeners}" "A 只在 loopback 监听（${listeners}）"
t_contains '"ssh"' "${out}" "监听者是桥接的 ssh"
run ax '(exec 3<>/dev/tcp/devbox/5173) 2>&1; echo rc=$?'
t_contains "rc=1" "${out}" "A 直连 devbox:5173 被拒（B 的服务只在它自己的 loopback）"
ui_keys x
wait_for 5 ui_hides 'Port Forward'
t_exit_ok 0 "${WAITED_RC}" "关闭 B 的面板"
wait_for 20 tab_bar_has "⇅5173"
t_exit_ok 0 "${WAITED_RC}" "tab bar 显示 ⇅5173（A 的 tab bar 条目由 herdr 在 B 上执行）"

# --- 7. Ctrl+click -------------------------------------------------------------------
t_describe "在 B 的 pane 里 Ctrl+click http://localhost:8080 → A 上打开"
ui_type "clear; echo open-me http://localhost:8080/ok"
wait_for 5 ui_shows 'open-me http://localhost:8080/ok'
t_exit_ok 0 "${WAITED_RC}" "链接已出现在屏幕上"
set +o errexit
ui_ctrl_click "http://localhost:8080/ok"
clicked=$?
set -o errexit
t_exit_ok 0 "${clicked}" "在链接上 Ctrl+点击"
wait_for 15 opened "http://localhost:8080/ok"
t_exit_ok 0 "${WAITED_RC}" "A 的浏览器打开了该链接（B 的 link handler → 桥接）"
wait_for 10 serves 8080 hello-8080
t_exit_ok 0 "${WAITED_RC}" "8080 已自动映射，A GET localhost:8080 = B 的服务"
wait_for 20 tab_bar_has "⇅8080"
t_exit_ok 0 "${WAITED_RC}" "tab bar 显示 ⇅8080"

# --- 8. 自愈 -------------------------------------------------------------------------
t_describe "A 断网 → 映射释放；恢复网络 → 自动恢复（TUI 一直开着）"
docker network disconnect "${NET}" "${A}"
wait_for 20 a_bridge_state_is retrying
t_exit_ok 0 "${WAITED_RC}" "A 的桥接进入 retrying"
wait_for 10 a_closed 5173
t_exit_ok 0 "${WAITED_RC}" "离线期间 A 的 5173 已释放"
docker network connect --alias laptop "${NET}" "${A}"
wait_for 40 serves 5173 hello-from-devbox
t_exit_ok 0 "${WAITED_RC}" "网络恢复后映射自动回来"

t_describe "A 的 herdr server 重启 → startup hook 拉回桥接"
ax 'herdr server stop >/dev/null 2>&1 || true'
wait_for 15 a_closed 5173
t_exit_ok 0 "${WAITED_RC}" "server 停止后 A 的映射端口释放"
docker exec -d "${A}" env "${A_SERVER_ENV[@]}" bash -c 'exec setsid herdr server </dev/null >>~/herdr-server.out 2>&1'
wait_for 30 serves 5173 hello-from-devbox
t_exit_ok 0 "${WAITED_RC}" "server 重启后映射自动回来"
run ax "grep -c 'startup: 桥接' '${A_STATE}/logs/forward.log'"
t_match '^[1-9]' "${out}" "A 的日志记录了 startup hook 拉起桥接"

# --- 9. 回到 Local，用面板停用 ---------------------------------------------------------
t_describe "回到 Local：prefix+f，按 1、y 停用 devbox"
ui_prefix w
sleep 1
ui_keys Up
sleep 0.5
ui_keys Enter
wait_for 20 viewing "fwduser@laptop"
t_exit_ok 0 "${WAITED_RC}" "回到 Local"
ui_prefix f
wait_for 10 ui_shows '\[✓\] 1\. devbox'
t_exit_ok 0 "${WAITED_RC}" "面板显示 devbox 为当前活动"
screen="$(ui_screen)"
t_contains "桥接已连接" "${screen}" "面板显示桥接已连接"
ui_keys 1
wait_for 5 ui_shows '停用 devbox'
t_exit_ok 0 "${WAITED_RC}" "停用前确认"
ui_keys y
wait_for 30 ui_shows '按任意键返回面板'
t_exit_ok 0 "${WAITED_RC}" "停用完成"
ui_keys x
wait_for 10 a_closed 5173
t_exit_ok 0 "${WAITED_RC}" "A 的 5173 已释放"
wait_for 10 a_closed 8080
t_exit_ok 0 "${WAITED_RC}" "A 的 8080 已释放"
run ax 'pgrep -af "bridge (run|serve)" || true'
t_eq "" "${out}" "A 上没有残留的桥接进程"
wait_for 30 b_status_all waiting
t_exit_ok 0 "${WAITED_RC}" "B 上的映射回到 waiting（client 已离开，重连后会自动生效）"

ui_prefix d
wait_for 10 ui_hides 'machines'
t_exit_ok 0 "${WAITED_RC}" "prefix+d 退出 herdr client"

t_done
