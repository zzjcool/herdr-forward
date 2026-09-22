#!/usr/bin/env bash
# scripts/e2e/run-bwrap.sh — 无 docker 环境的 E2E 降级方案（ARCHITECTURE §C.5）
#
# 与 run-docker.sh 同一份断言逻辑：复用 scripts/e2e/run-inside.sh，通过 bwrap 注入
# 隔离 HOME + 只读根文件系统 + 独立 net namespace，实现「沙箱内跑完整 E2E」。
#
# 红线（§C.2.5，ci.sh 第 6 段静态 grep 看守）：
#   * 必须 --unshare-net（不共享宿主网络）
#   * 绝不 bind 真实 $HOME；HOME 指向 mktemp 沙箱
#   * 宿主 /usr /bin /lib /lib64 /etc 只读复用（拿 sshd/ssh/jq/socat），绝不写回
#   * sandbox 内跑 herdr CLI 前由 run-inside.sh 显式 unset HERDR_SOCKET_PATH 等继承 env
#
# bwrap 特有处理（SCOUT-FACTS §1.2 + 本 T0 实测）：
#   * `--unshare-net` 新建 net namespace，loopback 初始即 UP，无需 `ip link set lo up`
#   * 用户命名空间里宿主 root 在沙箱内映射为非 root，而 OpenSSH 10 要求 privsep 目录
#     /usr/share/empty.sshd 属 root 且非 group/world-writable → 用 `--tmpfs` 覆盖成
#     沙箱内 root 所有（否则 sshd 拒绝启动："/usr/share/empty.sshd must be owned by root"）
#   * bwrap 重置 PATH，shell 内一律绝对路径；沙箱 PATH 里补上宿主工具目录
#   * 宿主可能没装 nc/shellcheck/shfmt（SCOUT-FACTS §1.4）→ 能 bind 的 bind 进来，
#     实在没有的由 run-inside.sh 显式 WARN 并走等价断言（不静默跳过）
set -Eeuo pipefail

# --- 红线（§C.2 + SCOUT-FACTS §1.1）：本脚本在宿主跑，bwrap 默认继承宿主 env。
# 若宿主设了 HERDR_SOCKET_PATH/HERDR_PANE_ID 等，沙箱里的 herdr 探测就可能连到真实
# 运行中的 server。在启动沙箱前显式清除，确保不泄漏进沙箱。
unset HERDR_SOCKET_PATH HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID || true

PROJ="$(cd "$(dirname "$0")/../.." && pwd)"
RESULTS_DIR="${PROJ}/test-results"
RUN_INSIDE="${PROJ}/scripts/e2e/run-inside.sh"

log() { printf '[e2e-bwrap] %s\n' "$*"; }

if ! command -v bwrap >/dev/null 2>&1; then
  echo "E2E bwrap 不可用：未找到 bwrap（安装 bubblewrap 后重试）" >&2
  exit 127
fi
if [[ ! -f "${RUN_INSIDE}" ]]; then
  echo "E2E bwrap 不可用：缺少 ${RUN_INSIDE}" >&2
  exit 127
fi

# 沙箱根：一次性，结束即删。HOME 与源码挂载都在这里。
# 目录名刻意不含 "herdr-forward"：t_no_zombie_ssh 用 `pgrep -f 'ssh.*herdr-forward'`
# 扫进程，而 bwrap 会把整条命令行（含沙箱路径）暴露在 /proc 里，若路径含该字串会自匹配成假阳性。
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/hf-e2e-bwrap.XXXXXX")"
CLEANED=0
cleanup() {
  if [[ "${CLEANED}" -eq 1 ]]; then
    return 0
  fi
  CLEANED=1
  log "清理沙箱 ${SANDBOX}"
  rm -rf "${SANDBOX}"
  return 0
}
trap 'cleanup' EXIT

mkdir -p "${SANDBOX}/home" "${SANDBOX}/work" "${SANDBOX}/src" "${SANDBOX}/tools" "${RESULTS_DIR}"

# 源码只读复制进沙箱（复制而非 bind 宿主仓库，避免沙箱内任何误写回到宿主工作区）。
# 跳过与测试无关且可能巨大的目录（.pi-subagents 里有嵌套 worktree，动辄上百 MB）。
log "复制源码到沙箱（只读使用）"
shopt -s dotglob nullglob
for entry in "${PROJ}"/*; do
  base="${entry##*/}"
  case "${base}" in
  test-results | .git | .pi-subagents | node_modules) continue ;;
  *) ;;
  esac
  cp -a "${entry}" "${SANDBOX}/src/"
done
shopt -u dotglob nullglob
# /work/test-results 用 bind mount 指向宿主结果目录（结果出口），不预建同名空目录。
# 宿主额外工具（shellcheck/shfmt 可能装在 ~/.local/bin，宿主 /usr 下没有；宿主也可能没有 nc）。
# 只拷「需要的几个二进制」到沙箱专用目录，绝不把整个 ~/.local/bin 暴露进沙箱
# （那里还有 herdr/cloudflared 等，会污染沙箱 PATH 与 herdr 探测）。
TOOL_BIND=()
path_prefix="/e2etools"
for tool in shellcheck shfmt nc socat jq; do
  tool_path="$(command -v "${tool}" 2>/dev/null || true)"
  [[ -z "${tool_path}" ]] && continue
  case "${tool_path}" in
  /usr/* | /bin/*) continue ;; # 已在只读根里，无需额外注入
  *) ;;
  esac
  cp -a "${tool_path}" "${SANDBOX}/tools/${tool}"
  log "注入沙箱工具：${tool}（源 ${tool_path}）"
done
TOOL_BIND=(--ro-bind "${SANDBOX}/tools" "${path_prefix}")
for tool in nc shellcheck shfmt; do
  if ! command -v "${tool}" >/dev/null 2>&1; then
    log "警告：宿主缺 ${tool}，沙箱内该断言将显式 SKIP（不静默通过）"
  fi
done

# 宿主 herdr 二进制挂载点（§C.4 假设#6 模式 A 探测）。
# 不能挂到 /usr/local/bin/herdr：沙箱内 /usr 只读，bwrap 会报 "Read-only file system"；
# 改用一个顶层只读 bind 点，并把它加入沙箱 PATH。
HERDR_BIND_DIR="/e2e-herdr-bin"
HERDR_MODE="B"
HERDR_BIND=()
if [[ -x /usr/bin/herdr ]]; then
  log "探测宿主 herdr 在 bwrap 沙箱内的可执行性（模式 A/B）"
  if timeout 60 bwrap \
    --unshare-user \
    --unshare-net --unshare-pid --unshare-ipc --unshare-uts --die-with-parent --new-session \
    --dev /dev --proc /proc \
    --ro-bind /usr /usr --ro-bind /bin /bin --ro-bind /lib /lib --ro-bind /lib64 /lib64 --ro-bind /etc /etc \
    --tmpfs /tmp --tmpfs /usr/share/empty.sshd \
    --dir "${HERDR_BIND_DIR}" \
    --ro-bind /usr/bin/herdr "${HERDR_BIND_DIR}/herdr" \
    --setenv PATH "${HERDR_BIND_DIR}:/usr/bin:/bin" \
    /usr/bin/bash -c "${HERDR_BIND_DIR}/herdr --version" >/dev/null 2>&1; then
    HERDR_MODE="A"
    HERDR_BIND=(--dir "${HERDR_BIND_DIR}" --ro-bind /usr/bin/herdr "${HERDR_BIND_DIR}/herdr")
    log "探测结论：模式 A（沙箱内可跑宿主 herdr）"
  else
    log "探测结论：模式 B（宿主 herdr 在沙箱内不可跑 → 沙箱内 shim + 纯 bash 层）"
  fi
else
  log "宿主无 /usr/bin/herdr → 模式 B"
fi

log "启动 bwrap 沙箱（模式 ${HERDR_MODE}）"
export HERDR_E2E_MODE="${HERDR_MODE}"
export HERDR_E2E_RESULTS_DIR="${RESULTS_DIR}"

set +e
# 挂载说明：
#   /plugin-src  -> 沙箱内只读源码
#   /work        -> 沙箱内可写区（run-inside.sh 把 /plugin-src 拷进来跑）
#   HOME=/root   -> 沙箱内 home（bind 到 mktemp 沙箱，绝不指向宿主 $HOME）
#   /etc         -> 只读复用宿主 etc（sshd 需要 nsswitch.conf、passwd、group 等）
#   /usr/share/empty.sshd -> tmpfs 覆盖，满足 sshd 对 privsep 目录的属主要求
bwrap \
  --unshare-user \
  --unshare-net --unshare-pid --unshare-ipc --unshare-uts \
  --die-with-parent --new-session \
  --dev /dev --proc /proc \
  --ro-bind /usr /usr --ro-bind /bin /bin --ro-bind /lib /lib --ro-bind /lib64 /lib64 \
  --ro-bind /etc /etc \
  --tmpfs /tmp \
  --tmpfs /usr/share/empty.sshd \
  --ro-bind "${SANDBOX}/src" /plugin-src \
  --bind "${SANDBOX}/work" /work \
  --bind "${RESULTS_DIR}" /work/test-results \
  --bind "${SANDBOX}/home" /root \
  "${TOOL_BIND[@]}" \
  "${HERDR_BIND[@]}" \
  --setenv HOME /root \
  --setenv HERDR_E2E_MODE "${HERDR_MODE}" \
  --setenv PATH "${HERDR_BIND_DIR}:${path_prefix}:/usr/local/bin:/usr/bin:/bin" \
  -- /usr/bin/bash /plugin-src/scripts/e2e/run-inside.sh
rc=$?
set -e

log "沙箱退出码：${rc}"
cleanup
exit "${rc}"
