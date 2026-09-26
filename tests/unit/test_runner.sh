#!/usr/bin/env bash
# tests/run.sh 自测（T0 交付物 2 的红→绿驱动）。
# 手法：造一个临时 tests 树（tmp/unit, tmp/integration, tmp/e2e）喂给 runner，
# 断言它的发现/汇总/退出码行为，不依赖仓库里真实存在的测试文件。
set -Eeuo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TESTS_DIR}/../.." && pwd)"
RUNNER="${REPO_ROOT}/tests/run.sh"

if [[ ! -f "${RUNNER}" ]]; then
  echo "RED: runner 不存在：${RUNNER}（TDD 第一步先红）" >&2
  exit 1
fi

# shellcheck source=tests/assertions.sh
source "${REPO_ROOT}/tests/assertions.sh"

TMPDIR_T0="$(mktemp -d)"
trap 'rm -rf "${TMPDIR_T0}"' EXIT

# 造一棵假仓库：tests/run.sh 必须按「脚本自身所在仓库」定位测试，故拷一份 runner。
fake_repo() {
  local root="${TMPDIR_T0}/repo-$1"
  rm -rf "${root}"
  mkdir -p "${root}/tests/unit" "${root}/tests/integration"
  cp "${RUNNER}" "${root}/tests/run.sh"
  cp "${REPO_ROOT}/tests/assertions.sh" "${root}/tests/assertions.sh"
  printf '%s\n' "${root}"
}

t_describe "tests/run.sh 发现与汇总"

t_it "unit 层：只发现 tests/unit/test_*.sh，绿文件 rc=0"
root="$(fake_repo ok)"
cat >"${root}/tests/unit/test_pass.sh" <<'EOS'
#!/usr/bin/env bash
set -Eeuo pipefail
echo "unit-ok-ran"
exit 0
EOS
cat >"${root}/tests/unit/helper.sh" <<'EOS'
#!/usr/bin/env bash
# 非 test_*.sh，必须不被 runner 当作测试执行
touch "${TMPDIR_T0}/helper-ran"
EOS
rm -f "${TMPDIR_T0}/helper-ran"
run bash "${root}/tests/run.sh" unit
t_is 0 "${rc}" "unit 全绿时 rc=0"
t_contains "unit-ok-ran" "${out}" "runner 执行了 test_*.sh"
t_contains "--- RUN tests/unit/test_pass.sh" "${out}" "runner 日志里出现被测文件"
t_file_absent "${TMPDIR_T0}/helper-ran"

t_it "unit 层：红文件使 runner rc=1，且继续跑完其它文件"
root="$(fake_repo fail)"
cat >"${root}/tests/unit/test_a_fail.sh" <<'EOS'
#!/usr/bin/env bash
set -Eeuo pipefail
echo "a-ran"
exit 1
EOS
cat >"${root}/tests/unit/test_b_pass.sh" <<'EOS'
#!/usr/bin/env bash
set -Eeuo pipefail
echo "b-ran"
exit 0
EOS
run bash "${root}/tests/run.sh" unit
t_is 1 "${rc}" "有失败文件时必须 rc=1"
t_contains "a-ran" "${out}" "失败文件被执行"
t_contains "b-ran" "${out}" "失败后仍继续执行后续文件"

t_it "缺失层：显式 SKIP 输出，不静默、不改 rc"
root="$(fake_repo empty)"
rmdir "${root}/tests/integration"
run bash "${root}/tests/run.sh" all
t_is 0 "${rc}" "无测试文件时 rc=0（否则 T0 阶段 ci 无法绿）"
t_contains "SKIP" "${out}" "缺失层必须显式 SKIP 提示"

t_it "all 层：按 unit/integration 顺序执行"
root="$(fake_repo all)"
for layer in unit integration; do
  cat >"${root}/tests/${layer}/test_${layer}.sh" <<EOS
#!/usr/bin/env bash
set -Eeuo pipefail
echo "ran-${layer} order=\${ORDER_NOTE:-}"
printf '%s\n' "${layer}" >>"${TMPDIR_T0}/order.txt"
exit 0
EOS
done
rm -f "${TMPDIR_T0}/order.txt"
run bash "${root}/tests/run.sh" all
t_is 0 "${rc}" "all 全绿 rc=0"
order_file="$(tr '\n' ' ' <"${TMPDIR_T0}/order.txt" || true)"
order_trimmed="${order_file% }"
t_is "unit integration" "${order_trimmed}" "执行顺序 unit→integration"

t_it "未知层参数：必须报错非零退出"
run bash "${root}/tests/run.sh" nonsense
t_isnt 0 "${rc}" "未知 layer 应非零退出"
t_contains "usage" "${err}${out}" "未知 layer 要有用法提示"

t_done
