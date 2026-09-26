#!/usr/bin/env bash
# Final Phase 5 CI gate: Go implementation + golden contract + retained E2E.
set -Eeuo pipefail

cd "$(dirname "$0")/.."
LAX="${HERDR_FORWARD_CI_LAX:-0}"

fail() {
  printf 'CI FAIL: %s\n' "$*" >&2
  exit 1
}
warn() { printf 'CI WARN: %s\n' "$*" >&2; }

check_tool() {
  local tool="$1"
  if command -v "${tool}" >/dev/null 2>&1; then
    return 0
  fi
  if [[ "${LAX}" == 1 ]]; then
    warn "缺少 ${tool}，LAX=1 跳过依赖它的检查"
    return 0
  fi
  fail "${tool} 未安装。请安装 shellcheck/shfmt/jq，或显式设置 HERDR_FORWARD_CI_LAX=1。"
}

check_tool shellcheck
check_tool shfmt
check_tool jq
HAS_LINT=0
command -v shellcheck >/dev/null 2>&1 && HAS_LINT=1

printf '%s\n' '== 1/6 Go + golden contract =='
if ! command -v go >/dev/null 2>&1; then
  if [[ "${LAX}" == 1 ]]; then
    warn '缺少 go，LAX=1 跳过 Go/golden 检查'
  else
    fail 'go 未安装；Phase 5 的唯一实现是 Go 二进制。'
  fi
else
  (cd go && go vet -mod=vendor ./...) || fail 'go vet'
  (cd go && go test -mod=vendor ./...) || fail 'go test'
  (cd go && go build -mod=vendor ./...) || fail 'go build'
  bash tests/difftest/run.sh || fail 'golden contract'
  printf '%s\n' '   Go + golden contract 通过（438/438）'
fi

shell_targets=()
for f in bin/forward scripts/*.sh scripts/e2e/*.sh tests/run.sh tests/assertions.sh tests/unit/*.sh tests/integration/*.sh tests/difftest/run.sh; do
  [[ -f "${f}" ]] && shell_targets+=("${f}")
done

printf '%s\n' '== 2/6 shellcheck（严格） =='
if [[ "${HAS_LINT}" -eq 0 ]]; then
  printf '%s\n' 'SKIP shellcheck（LAX=1 且工具缺失）'
else
  shellcheck -x -S style -o all "${shell_targets[@]}" || fail 'shellcheck'
  printf '   shellcheck 通过（%d 个目标）\n' "${#shell_targets[@]}"
fi

printf '%s\n' '== 3/6 shfmt =='
if command -v shfmt >/dev/null 2>&1; then
  shfmt -d -ln bash -i 2 "${shell_targets[@]}" || fail 'shfmt'
  printf '   shfmt 通过（%d 个目标）\n' "${#shell_targets[@]}"
else
  printf '%s\n' 'SKIP shfmt（LAX=1 且工具缺失）'
fi

printf '%s\n' '== 4/6 unit =='
bash tests/run.sh unit || fail unit

printf '%s\n' '== 5/6 integration =='
bash tests/run.sh integration || fail integration

printf '%s\n' '== 6/6 E2E + sentinel =='
E2E_PATH=''
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  bash scripts/e2e/run-docker.sh || fail 'e2e docker'
  E2E_PATH=docker
  if [[ -f scripts/e2e/run-two-machines.sh ]]; then
    two_rc=0
    bash scripts/e2e/run-two-machines.sh || two_rc=$?
    if [[ "${two_rc}" -eq 127 ]]; then
      warn '两机 E2E 前置条件不满足，已显式标记为宿主 herdr smoke 待跑'
    elif [[ "${two_rc}" -ne 0 ]]; then
      fail 'two-machines E2E'
    fi
  fi
elif command -v bwrap >/dev/null 2>&1; then
  warn 'docker 不可用，执行 bwrap E2E 降级路径'
  bash scripts/e2e/run-bwrap.sh || fail 'e2e bwrap'
  E2E_PATH=bwrap
else
  fail 'docker 与 bwrap 都不可用，禁止静默跳过 E2E。'
fi
[[ -n "${E2E_PATH}" ]] || fail 'E2E sentinel：没有真实执行路径'

lib_prefix='lib/'
sh_suffix='.sh'
if grep -RIn --exclude=ci.sh -E "${lib_prefix}[[:alnum:]_.-]+\\${sh_suffix}" bin scripts tests docs README.md >/tmp/herdr-forward-lib-refs.$$ 2>/dev/null; then
  cat /tmp/herdr-forward-lib-refs.$$ >&2
  rm -f /tmp/herdr-forward-lib-refs.$$
  fail '发现退役 Bash 模块引用'
fi
rm -f /tmp/herdr-forward-lib-refs.$$
if git ls-files | grep -E '(^|/)(forward-go|dist/)' >/dev/null 2>&1; then
  fail '仓库跟踪了预编译二进制或 dist/'
fi
printf '   sentinel 通过（E2E=%s；无 Bash 模块引用；无预编译产物）\n' "${E2E_PATH}"
printf '%s\n' 'CI OK: 6/6 全部通过'
