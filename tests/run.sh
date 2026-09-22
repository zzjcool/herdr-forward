#!/usr/bin/env bash
# tests/run.sh — 测试 runner（T0 交付物 2）
#
# 用法：bash tests/run.sh unit|integration|e2e|all
#   unit        纯函数/状态层，零网络零进程
#   integration 本机用户态 sshd + 真 ssh -L（高端口）
#   e2e         只在 docker/bwrap 沙箱里跑，绝不碰真实环境
#   all         按 unit → integration → e2e 顺序全跑
#
# 行为契约：
#   * 发现规则：<layer>/test_*.sh（其他文件名不执行，避免误跑 helper）
#   * 串行执行（避免端口竞争），每个文件独立 bash 子进程
#   * 任一文件非零退出 → 整体 rc=1，但**继续跑完**其余文件（汇总全貌）
#   * 层目录缺失或层内无测试文件 → 打印 SKIP，不视为失败（T0/早期阶段
#     integration 与 e2e 可能还没有文件；静默跳过是禁止的，必须显式 SKIP）
#   * 未知 layer 参数 → 打印 usage，exit 2
set -Eeuo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TESTS_DIR}/.." && pwd)"

LAYERS_ALL=(unit integration e2e)

usage() {
  printf 'usage: bash tests/run.sh <%s|all>\n' "$(IFS='|' && echo "${LAYERS_ALL[*]}")" >&2
}

resolve_layers() {
  local arg="${1:-all}"
  case "${arg}" in
  all) printf '%s\n' "${LAYERS_ALL[@]}" ;;
  unit | integration | e2e) printf '%s\n' "${arg}" ;;
  *)
    printf 'error: 未知测试层：%s\n' "${arg}" >&2
    usage
    exit 2
    ;;
  esac
}

main() {
  local layer_arg="${1:-all}"
  local layers_csv=""
  layers_csv="$(resolve_layers "${layer_arg}")"
  local -a layers=()
  mapfile -t layers <<<"${layers_csv}"

  cd "${REPO_ROOT}"

  local total_files=0
  local total_failed=0
  local -a failed_files=()
  local layer=""
  local dir=""
  local -a files=()
  local f=""

  for layer in "${layers[@]}"; do
    dir="${TESTS_DIR}/${layer}"
    printf '=== layer: %s ===\n' "${layer}"
    if [[ ! -d "${dir}" ]]; then
      printf 'SKIP %s: 目录不存在（%s）\n' "${layer}" "${dir}"
      continue
    fi
    mapfile -t files < <(find "${dir}" -maxdepth 1 -type f -name 'test_*.sh' | sort || true)
    if [[ "${#files[@]}" -eq 0 ]]; then
      printf 'SKIP %s: 无 test_*.sh 测试文件\n' "${layer}"
      continue
    fi
    for f in "${files[@]}"; do
      [[ -z "${f}" ]] && continue
      total_files=$((total_files + 1))
      printf '%s\n' "--- RUN ${f#"${REPO_ROOT}"/}"
      if bash "${f}"; then
        printf '%s\n' "--- OK  ${f#"${REPO_ROOT}"/}"
      else
        local rc=$?
        total_failed=$((total_failed + 1))
        failed_files+=("${f#"${REPO_ROOT}"/}")
        printf '%s\n' "--- FAIL ${f#"${REPO_ROOT}"/} (rc=${rc})"
      fi
    done
  done

  printf '\n=== summary ===\n'
  printf 'files: %d  failed: %d\n' "${total_files}" "${total_failed}"
  if [[ "${total_failed}" -gt 0 ]]; then
    printf 'failed files:\n'
    printf '  %s\n' "${failed_files[@]}"
    exit 1
  fi
  exit 0
}

main "$@"
