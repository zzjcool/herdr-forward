#!/usr/bin/env bash
# scripts/ci.sh — 基线拦截（T0 交付物 3；契约见 ARCHITECTURE.md §B.4）
#
# 6 段：1) shellcheck 严格  2) shfmt  3) unit  4) integration
#       5) e2e（docker 优先，不可用降级 bwrap）  6) e2e 完整性哨兵 + 红线 grep
#
# 工具缺失策略（B.4 + SCOUT-FACTS §1.4：本机无 shellcheck/shfmt/nc）：
#   * shellcheck/shfmt/jq 任一缺失 → CI FAIL 并打印安装提示（绝不静默绿）
#   * 设 HERDR_FORWARD_CI_LAX=1 → 显式 WARN 降级（仍打印警告，不静默）
#
# 缺失目录策略（B.4 未写明，按最小惊讶原则；T0 阶段 lib/、bin/ 尚不存在）：
#   * shellcheck 目标按「实际存在的文件」动态构造：bin/forward、lib/*.sh 缺失时
#     逐项打印 SKIP，但 tests/、scripts/ 下已存在的文件照检；全部不存在则整段 SKIP
#   * 测试层缺失由 tests/run.sh 自行打印 SKIP（见该脚本行为契约），ci 不重复判断
#   * E2E 绝不静默跳过：两脚本缺失，或 docker/bwrap 都不可用 → CI FAIL（红线 §C.2.7）
#
# 红线检查（ARCHITECTURE §C.2）：对 scripts/e2e/run-docker.sh、run-bwrap.sh、
# run-inside.sh、Dockerfile 做 grep 静态扫描，命中即 CI FAIL（RE LINE 标记）。
set -Eeuo pipefail

cd "$(dirname "$0")/.."

LAX="${HERDR_FORWARD_CI_LAX:-0}"
TOOL_HINT="安装提示：Arch 用 'pacman -S --noconfirm shellcheck shfmt jq'，
Debian/Ubuntu 用 'apt-get install -y shellcheck jq' + shfmt（https://github.com/mvdan/sh/releases）"

fail() {
  echo "CI FAIL: $*" >&2
  exit 1
}

warn() { echo "CI WARN: $*" >&2; }

redline() {
  echo "CI RED LINE VIOLATION: $*" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# 工具预检
# ---------------------------------------------------------------------------
HAS_SHELLCHECK=0
HAS_SHFMT=0

# 工具预检：不可用时 fail（LAX=1 时只 WARN）。
# 注意：check_tool 恒返回 0（缺失时才不返回——fail 直接 exit），因此调用处是普通
# 语句而非条件，避开 shellcheck SC2310（set -e 在条件中被禁用的误用模式）。
check_tool() { # check_tool <name>
  local name="$1"
  if command -v "${name}" >/dev/null 2>&1; then
    return 0
  fi
  if [[ "${LAX}" == "1" ]]; then
    warn "缺少 ${name} —— HERDR_FORWARD_CI_LAX=1 显式降级，跳过依赖它的检查段"
    return 0
  fi
  fail "${name} 未安装。${TOOL_HINT}
  或设 HERDR_FORWARD_CI_LAX=1 显式降级（会打印 CI WARN，不静默通过）"
}

precheck_tools() {
  check_tool shellcheck
  check_tool shfmt
  # jq 是 unit 层断言与状态文件校验的硬依赖，缺失没有降级语义
  # （断言库 t_json_valid 会显式记 FAIL）
  check_tool jq
  if command -v shellcheck >/dev/null 2>&1; then HAS_SHELLCHECK=1; fi
  if command -v shfmt >/dev/null 2>&1; then HAS_SHFMT=1; fi
}
precheck_tools

# ---------------------------------------------------------------------------
# 1/6 shellcheck（严格：-S style -o all）
# ---------------------------------------------------------------------------
echo "== 1/6 shellcheck（严格） =="
if [[ "${HAS_SHELLCHECK}" -eq 0 ]]; then
  echo "SKIP 1/6 shellcheck（工具缺失，已在预检 WARN）"
else
  # 目标动态构造：存在的文件才加入；缺失的部分显式 SKIP（T0 阶段 lib/、bin/ 还没交付）
  shellcheck_targets=()
  if [[ -f bin/forward ]]; then
    shellcheck_targets+=("bin/forward")
  else
    echo "SKIP shellcheck 目标 bin/forward（尚未交付）"
  fi
  if compgen -G 'lib/*.sh' >/dev/null 2>&1; then
    for f in lib/*.sh; do
      shellcheck_targets+=("${f}")
    done
  else
    echo "SKIP shellcheck 目标 lib/*.sh（尚未交付）"
  fi
  for f in tests/lib/*.sh tests/run.sh scripts/*.sh tests/**/*.sh; do
    [[ -f "${f}" ]] && shellcheck_targets+=("${f}")
  done
  if compgen -G 'scripts/e2e/*.sh' >/dev/null 2>&1; then
    for f in scripts/e2e/*.sh; do
      shellcheck_targets+=("${f}")
    done
  fi

  if [[ "${#shellcheck_targets[@]}" -eq 0 ]]; then
    echo "SKIP 1/6 shellcheck（没有任何可检目标）"
  else
    printf '   目标 %d 个\n' "${#shellcheck_targets[@]}"
    shellcheck -x -S style -o all "${shellcheck_targets[@]}" || fail "shellcheck（严格模式有告警）"
  fi
fi

# ---------------------------------------------------------------------------
# 2/6 shfmt（格式检查，不自动改）
# ---------------------------------------------------------------------------
echo "== 2/6 shfmt（-d -ln bash -i 2） =="
if [[ "${HAS_SHFMT}" -eq 0 ]]; then
  echo "SKIP 2/6 shfmt（工具缺失，已在预检 WARN）"
else
  shfmt_targets=()
  for f in bin/forward tests/run.sh tests/lib/*.sh scripts/*.sh; do
    [[ -f "${f}" ]] && shfmt_targets+=("${f}")
  done
  if compgen -G 'lib/*.sh' >/dev/null 2>&1; then
    for f in lib/*.sh; do
      shfmt_targets+=("${f}")
    done
  fi
  if compgen -G 'scripts/e2e/*.sh' >/dev/null 2>&1; then
    for f in scripts/e2e/*.sh; do
      shfmt_targets+=("${f}")
    done
  fi

  if [[ "${#shfmt_targets[@]}" -eq 0 ]]; then
    echo "SKIP 2/6 shfmt（没有任何可检目标）"
  else
    shfmt -d -ln bash -i 2 "${shfmt_targets[@]}" || fail "shfmt 格式不一致（跑 shfmt -w -ln bash -i 2）"
  fi
fi

# ---------------------------------------------------------------------------
# 3/6 unit
# ---------------------------------------------------------------------------
echo "== 3/6 unit =="
bash tests/run.sh unit || fail "unit"

# ---------------------------------------------------------------------------
# 4/6 integration
# ---------------------------------------------------------------------------
echo "== 4/6 integration =="
bash tests/run.sh integration || fail "integration"

# ---------------------------------------------------------------------------
# 5/6 e2e（docker 优先 → bwrap 降级；两者都不可用即 FAIL）
# ---------------------------------------------------------------------------
echo "== 5/6 e2e =="
E2E_PATH=""
if [[ ! -f scripts/e2e/run-docker.sh && ! -f scripts/e2e/run-bwrap.sh ]]; then
  fail "E2E 完整性：scripts/e2e/run-docker.sh 与 run-bwrap.sh 都不存在，E2E 不允许静默跳过"
fi

if [[ -f scripts/e2e/run-docker.sh ]] && command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  echo "   路径：docker"
  bash scripts/e2e/run-docker.sh || fail "E2E docker 路径失败"
  E2E_PATH="docker"
elif [[ -f scripts/e2e/run-bwrap.sh ]] && command -v bwrap >/dev/null 2>&1; then
  echo "   路径：docker 不可用 → 降级 bwrap"
  warn "docker 不可用，降级 bwrap E2E（E2E 仍真实执行，未跳过）"
  bash scripts/e2e/run-bwrap.sh || fail "E2E bwrap 降级路径失败"
  E2E_PATH="bwrap"
else
  fail "E2E 完整性：docker 与 bwrap 都不可用（或对应脚本缺失），禁止静默跳过。
  指引：安装并启动 docker，或安装 bubblewrap（bwrap）；两者都没有时 E2E 无法闭环。"
fi

# 5b：两机远程开发 E2E（ARCHITECTURE §A.3.3）—— 两个容器各跑真 herdr + 真 sshd。
# 需要 docker 与容器内可跑的宿主 herdr（§C.4 模式 A）；脚本以 127 表示前置条件不满足，
# 此时显式 WARN 跳过（远程开发的数据面仍由 integration 层的 test_bridge_roundtrip 覆盖）。
if [[ "${E2E_PATH}" == "docker" && -f scripts/e2e/run-two-machines.sh ]]; then
  echo "   两机远程开发 E2E：scripts/e2e/run-two-machines.sh"
  two_rc=0
  bash scripts/e2e/run-two-machines.sh || two_rc=$?
  if [[ "${two_rc}" -eq 127 ]]; then
    warn "两机 E2E 前置条件不满足（无宿主 herdr 或其在容器内跑不起来），已显式跳过"
  elif [[ "${two_rc}" -ne 0 ]]; then
    fail "两机远程开发 E2E 失败（rc=${two_rc}）"
  fi
fi

# ---------------------------------------------------------------------------
# 6/6 e2e 完整性哨兵 + 红线检查
# ---------------------------------------------------------------------------
echo "== 6/6 e2e 完整性哨兵（sentinel + 红线） =="

if [[ -z "${E2E_PATH}" ]]; then
  fail "E2E sentinel：第 5 段未真实执行任何 E2E 路径"
fi
printf '   E2E 实际执行路径：%s\n' "${E2E_PATH}"

# 去注释（整行或行首空白后的 # 起注释），避免红线规则被说明文字误伤。
strip_comments() { sed -E 's/(^|[[:space:]])#.*$//' "$1"; }

# 取脚本去掉注释后的正文（提前取，避免在 if/|| 条件中直接调用函数触发 SC2310）
SCRIPT_BODY=""
load_body() { SCRIPT_BODY="$(strip_comments "$1")"; }

# 红线 1：mount/bind 参数值中出现 $HOME / ${HOME} / /home/ 字面量 → 命中真实 HOME
# （模式用变量装，避免 single-quote 误报 SC2016）
RE_HOME_MOUNT='(--volume|--bind|(^|[[:space:]])-v)([=[:space:]])'
RE_HOME_VALUE='[$]HOME|[$][{]HOME[}]|/home/'
redline_home_mount() { # 返回 0 = 命中红线
  local f="$1" hits=""
  [[ -f "${f}" ]] || return 1
  load_body "${f}"
  hits="$(grep -E -e "${RE_HOME_MOUNT}" <<<"${SCRIPT_BODY}" | grep -E -e "${RE_HOME_VALUE}" || true)"
  [[ -n "${hits}" ]]
}

# 红线 5：容器禁止发布端口。
# 拆分原因：`-p` 语义歧义（docker -p 发布端口，但 ssh -p / nc -p 是常规用法），
# 故 `-p` 只在同一行出现 `docker run` 时才判定；--publish/EXPOSE 无歧义，全局判定。
RE_PUBLISH_LONG='--publish|(^|[[:space:]])EXPOSE([[:space:]]|$)'
RE_DOCKER_RUN='(^|[[:space:]])docker[[:space:]]+run([[:space:]]|$)'
RE_PUBLISH_SHORT='(^|[[:space:]])-p([[:space:]]*[0-9]|[0-9])'
redline_publish() {
  local f="$1" hits="" short_hits=""
  [[ -f "${f}" ]] || return 1
  load_body "${f}"
  hits="$(grep -E -e "${RE_PUBLISH_LONG}" <<<"${SCRIPT_BODY}" || true)"
  short_hits="$(grep -E -e "${RE_DOCKER_RUN}" <<<"${SCRIPT_BODY}" | grep -E -e "${RE_PUBLISH_SHORT}" || true)"
  [[ -n "${hits}${short_hits}" ]]
}

# 红线 5b：禁止 host 网络（--network host / --net=host）
RE_HOST_NET='(^|[[:space:]])(--network|--net)[=[:space:]]+host'
redline_host_net() {
  local f="$1" hits=""
  [[ -f "${f}" ]] || return 1
  load_body "${f}"
  hits="$(grep -E -e "${RE_HOST_NET}" <<<"${SCRIPT_BODY}" || true)"
  [[ -n "${hits}" ]]
}

# 红线 5c：bwrap 必须 --unshare-net
redline_bwrap_netns() { # 返回 0 = 命中红线（缺少 --unshare-net）
  local f="$1" body=""
  [[ -f "${f}" ]] || return 1
  load_body "${f}"
  body="${SCRIPT_BODY}"
  [[ "${body}" == *bwrap* ]] || return 1
  [[ "${body}" == *--unshare-net* ]] && return 1
  return 0
}

# 红线 8 + SCOUT-FACTS §1.1：容器/沙箱内跑 herdr CLI 前必须 unset 继承的 HERDR_* env，
# 否则会连到宿主真实运行中的 server。规则：脚本提到 herdr 就必须出现 HERDR_SOCKET_PATH
# 的 unset 保护。
redline_herdr_env() { # 返回 0 = 命中红线
  local f="$1" body=""
  [[ -f "${f}" ]] || return 1
  load_body "${f}"
  body="${SCRIPT_BODY}"
  [[ "${body}" == *herdr* ]] || return 1
  [[ "${body}" == *HERDR_SOCKET_PATH* ]] && return 1
  return 0
}

E2E_SCRIPTS=()
for f in scripts/e2e/run-docker.sh scripts/e2e/run-bwrap.sh scripts/e2e/run-inside.sh scripts/e2e/Dockerfile scripts/e2e/run-two-machines.sh; do
  [[ -f "${f}" ]] && E2E_SCRIPTS+=("${f}")
done

REDLINE_HIT=0
redline_probe() { # redline_probe <check_fn> <file> <msg>
  local fn="$1" f="$2" msg="$3" hit=0
  "${fn}" "${f}" && hit=1
  if [[ "${hit}" -eq 1 ]]; then
    echo "RED LINE[${f}]：${msg}" >&2
    REDLINE_HIT=1
  fi
  return 0
}

for f in scripts/e2e/run-docker.sh scripts/e2e/run-bwrap.sh scripts/e2e/run-two-machines.sh; do
  redline_probe redline_home_mount "${f}" "mount/bind 参数疑似挂载真实 \$HOME（§C.2.1）"
done
for f in scripts/e2e/run-docker.sh scripts/e2e/run-inside.sh scripts/e2e/Dockerfile scripts/e2e/run-two-machines.sh; do
  redline_probe redline_publish "${f}" "出现 --publish/-p/EXPOSE，容器不得发布端口（§C.2.5）"
done
for f in scripts/e2e/run-docker.sh scripts/e2e/run-bwrap.sh scripts/e2e/run-two-machines.sh; do
  redline_probe redline_host_net "${f}" "使用 host 网络（§C.2.5）"
done
redline_probe redline_bwrap_netns scripts/e2e/run-bwrap.sh \
  "bwrap 调用缺少 --unshare-net（§C.2.5）"
for f in scripts/e2e/run-inside.sh scripts/e2e/run-bwrap.sh scripts/e2e/run-two-machines.sh; do
  redline_probe redline_herdr_env "${f}" \
    "引用 herdr 但未 unset HERDR_SOCKET_PATH（会连到宿主真实 server；§C.2 + SCOUT-FACTS §1.1）"
done

if [[ "${REDLINE_HIT}" -ne 0 ]]; then
  redline "E2E 脚本命中红线，见上方明细（契约 ARCHITECTURE §C.2）"
fi

printf '   红线扫描通过（扫描 %d 个文件）\n' "${#E2E_SCRIPTS[@]}"
echo "CI OK: 6/6 全部通过"
