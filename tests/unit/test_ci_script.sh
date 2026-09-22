#!/usr/bin/env bash
# scripts/ci.sh 自测（T0 交付物 3 的红→绿驱动）。
#
# 手法：造一棵「假仓库」（拷贝 ci.sh + tests/run.sh + 一个平凡通过的 unit 用例 +
# 假 e2e 脚本），再造一个「假 PATH」（symlink 农场）来精确控制哪些工具「已安装」，
# 然后断言 ci.sh 在各种组合下的行为：
#   * 缺 shellcheck/shfmt/jq → CI FAIL + 安装提示（绝不静默绿）
#   * HERDR_FORWARD_CI_LAX=1   → 显式 WARN 降级，rc 可绿
#   * 无 bin/ lib/             → shellcheck 段显式 SKIP，单测与哨兵照跑
#   * E2E 红线哨兵              → mount $HOME / --publish / EXPOSE / --net=host 必须红
#   * docker 与 bwrap 都不可用  → 必须红（禁止静默跳过 E2E）
set -Eeuo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TESTS_DIR}/../.." && pwd)"
CI_SH="${REPO_ROOT}/scripts/ci.sh"

if [[ ! -f "${CI_SH}" ]]; then
  echo "RED: scripts/ci.sh 不存在：${CI_SH}（TDD 第一步先红）" >&2
  exit 1
fi

# shellcheck source=tests/lib/assertions.sh
source "${REPO_ROOT}/tests/lib/assertions.sh"

TMPDIR_T0="$(mktemp -d)"
export TMPDIR_T0
trap 'rm -rf "${TMPDIR_T0}"' EXIT

# ---------------------------------------------------------------------------
# 假 PATH（symlink 农场）：只暴露白名单工具，从而模拟「工具缺失」。
# ---------------------------------------------------------------------------
FAKE_BIN="${TMPDIR_T0}/fakebin"
mkdir -p "${FAKE_BIN}"
FAKE_BIN_EXTRA="${TMPDIR_T0}/fakebin-extra"
mkdir -p "${FAKE_BIN_EXTRA}"

ALL_TOOLS=(
  bash sh jq shfmt shellcheck
  grep find sort sed cat rm mv cp mkdir mktemp tr awk head tail dirname basename
  uname env timeout pgrep ps kill sleep ls chmod touch tee date id printf
  ssh sshd ssh-keygen ip nc
)

# 安全护栏：docker/bwrap 不用 symlink 入农场（避免误写到真实二进制）。
# 需要它们可用时用 make_fake_docker / make_fake_bwrap 生成替身脚本。
link_tools() { # link_tools <destdir> <tool...>
  local dest="$1"
  shift
  local t=""
  for t in "$@"; do
    case "${t}" in
    docker | bwrap)
      echo "link_tools: 拒绝 symlink ${t}（用 make_fake_${t} 代替）" >&2
      continue
      ;;
    *) ;;
    esac
    local src=""
    src="$(command -v "${t}" 2>/dev/null || true)"
    [[ -z "${src}" ]] && continue
    ln -sf "${src}" "${dest}/${t}"
  done
}

# 基础农场：除 shellcheck/shfmt/docker/bwrap 之外全给（模拟「lint 工具缺失」）。
build_base_farm() {
  rm -rf "${FAKE_BIN:?}"/* "${FAKE_BIN_EXTRA:?}"/*
  local -a subset=()
  local t=""
  for t in "${ALL_TOOLS[@]}"; do
    [[ "${t}" == "shellcheck" || "${t}" == "shfmt" || "${t}" == "docker" || "${t}" == "bwrap" ]] && continue
    subset+=("${t}")
  done
  link_tools "${FAKE_BIN}" "${subset[@]}"
}

# 按需补装工具到农场。
install_tool() {
  link_tools "${FAKE_BIN}" "$@"
}

# 假 docker CLI：ci.sh 用 `docker info` 探测可用性；其余命令 e2e 脚本自行提供。
# 注意：不要拿真实 docker/bwrap 做 symlink（写穿会失败甚至破坏宿主机）。
make_fake_docker() {
  rm -f "${FAKE_BIN}/docker"
  cat >"${FAKE_BIN}/docker" <<'EOS'
#!/usr/bin/env bash
set -Eeuo pipefail
case "${1:-}" in
info)
  echo "Server Version: fake-for-test"
  exit 0
  ;;
*)
  echo "fake docker $*"
  exit 0
  ;;
esac
EOS
  chmod +x "${FAKE_BIN}/docker"
}

# ---------------------------------------------------------------------------
# 假仓库
# ---------------------------------------------------------------------------
fake_repo() { # fake_repo <name>
  local root="${TMPDIR_T0}/repo-$1"
  rm -rf "${root}"
  mkdir -p "${root}/scripts/e2e" "${root}/tests/lib" "${root}/tests/unit"
  cp "${CI_SH}" "${root}/scripts/ci.sh"
  cp "${REPO_ROOT}/tests/run.sh" "${root}/tests/run.sh"
  cp "${REPO_ROOT}/tests/lib/assertions.sh" "${root}/tests/lib/assertions.sh"
  cat >"${root}/tests/unit/test_trivial.sh" <<'EOS'
#!/usr/bin/env bash
set -Eeuo pipefail
echo "trivial-unit-ok"
exit 0
EOS
  cat >"${root}/scripts/e2e/run-docker.sh" <<'EOS'
#!/usr/bin/env bash
set -Eeuo pipefail
echo "FAKE_E2E_DOCKER_RAN"
exit 0
EOS
  cat >"${root}/scripts/e2e/run-bwrap.sh" <<'EOS'
#!/usr/bin/env bash
set -Eeuo pipefail
echo "FAKE_E2E_BWRAP_RAN"
exit 0
EOS
  printf '%s\n' "${root}"
}

run_ci() { # run_ci <repo-root> [env assignments...]
  local root="$1"
  shift
  run env PATH="${FAKE_BIN}" "$@" bash "${root}/scripts/ci.sh"
}

t_describe "ci.sh：工具缺失必须显式报错（禁止静默绿）"

t_it "缺 shellcheck：CI FAIL + 安装提示，rc!=0"
build_base_farm
root="$(fake_repo nosc)"
run_ci "${root}"
t_isnt 0 "${rc}" "缺 shellcheck 时 rc!=0"
t_contains "CI FAIL" "${err}${out}" "缺 shellcheck 要打印 CI FAIL"
t_contains "shellcheck" "${err}${out}" "报错要点名缺失工具"
t_contains "未安装" "${err}${out}" "报错要说明未安装"
t_contains "HERDR_FORWARD_CI_LAX" "${err}${out}" "报错要给出显式降级开关"

t_it "缺 shfmt（已有 shellcheck）：rc!=0 且点名 shfmt"
build_base_farm
install_tool shellcheck
root="$(fake_repo noshfmt)"
run_ci "${root}"
t_isnt 0 "${rc}" "缺 shfmt 时 rc!=0"
t_contains "shfmt" "${err}${out}" "报错要点名 shfmt"

t_it "缺 jq：rc!=0 且点名 jq"
build_base_farm
install_tool shellcheck shfmt
rm -f "${FAKE_BIN}/jq"
root="$(fake_repo nojq)"
run_ci "${root}"
t_isnt 0 "${rc}" "缺 jq 时 rc!=0"
t_contains "jq" "${err}${out}" "报错要点名 jq"

t_describe "ci.sh：显式降级开关"

t_it "HERDR_FORWARD_CI_LAX=1 + 缺 lint 工具：rc=0 但必须打印 WARN"
build_base_farm
make_fake_docker
root="$(fake_repo lax)"
run_ci "${root}" HERDR_FORWARD_CI_LAX=1
t_is 0 "${rc}" "LAX=1 时允许绿（err=${err}）"
t_contains "WARN" "${out}" "LAX 降级必须显式 WARN，不许静默"
t_isnt 1 "$(printf '%s' "${out}${err}" | grep -c 'CI FAIL' || true)" "LAX 下不应出现 CI FAIL"

t_describe "ci.sh：空 lib/bin 阶段（T0）行为"

t_it "无 bin/ 与 lib/：shellcheck 段 SKIP，unit 与哨兵照跑，rc=0"
build_base_farm
install_tool shellcheck shfmt
make_fake_docker
root="$(fake_repo emptylib)"
run_ci "${root}"
t_is 0 "${rc}" "空 lib/bin 时 ci 应全绿（err=${err}）"
t_contains "SKIP" "${out}" "缺失目录要显式 SKIP 提示"
t_contains "trivial-unit-ok" "${out}" "unit 单测照跑"
t_contains "FAKE_E2E_DOCKER_RAN" "${out}" "e2e docker 路径照跑"
t_contains "sentinel" "${out}" "哨兵段必须执行"

t_it "有 bin/lib 时对它们跑 shellcheck（style 违规必须红）"
build_base_farm
install_tool shellcheck shfmt
make_fake_docker
root="$(fake_repo withlib)"
mkdir -p "${root}/bin" "${root}/lib"
cat >"${root}/lib/bad.sh" <<'EOS'
#!/usr/bin/env bash
set -Eeuo pipefail
MSG="style-violation"
echo "$MSG"
EOS
run_ci "${root}"
t_isnt 0 "${rc}" "style 违规时 shellcheck 段必须红"
t_contains "bad.sh" "${out}${err}" "报错要指出违规文件"

t_describe "ci.sh：E2E 红线哨兵"

t_it "run-docker.sh 里 mount \$HOME → 必须红"
build_base_farm
install_tool shellcheck shfmt
make_fake_docker
root="$(fake_repo redlinehome)"
cat >"${root}/scripts/e2e/run-docker.sh" <<'EOS'
#!/usr/bin/env bash
set -Eeuo pipefail
echo "FAKE_E2E_DOCKER_RAN"
docker run --rm -v "${HOME}":/leak alpine true
EOS
run_ci "${root}"
t_isnt 0 "${rc}" "红线违规必须 rc!=0"
t_contains "RED LINE" "${out}${err}" "红线违规要有明确标记"

t_it "run-docker.sh 里 --publish 端口 → 必须红"
build_base_farm
install_tool shellcheck shfmt
make_fake_docker
root="$(fake_repo redlineport)"
cat >"${root}/scripts/e2e/run-docker.sh" <<'EOS'
#!/usr/bin/env bash
set -Eeuo pipefail
echo "FAKE_E2E_DOCKER_RAN"
docker run --rm --publish 8080:80 alpine true
EOS
run_ci "${root}"
t_isnt 0 "${rc}" "--publish 必须 rc!=0"
t_contains "RED LINE" "${out}${err}" "--publish 要有明确红线标记"

t_it "run-bwrap.sh 缺 --unshare-net → 必须红"
build_base_farm
install_tool shellcheck shfmt
make_fake_docker
root="$(fake_repo redlinenet)"
cat >"${root}/scripts/e2e/run-bwrap.sh" <<'EOS'
#!/usr/bin/env bash
set -Eeuo pipefail
echo "FAKE_E2E_BWRAP_RAN"
bwrap --ro-bind /usr /usr /usr/bin/bash -c true
EOS
run_ci "${root}"
t_isnt 0 "${rc}" "bwrap 未 --unshare-net 必须 rc!=0"
t_contains "RED LINE" "${out}${err}" "缺 --unshare-net 要有明确红线标记"

t_it "run-docker.sh 里 --net=host → 必须红"
build_base_farm
install_tool shellcheck shfmt
make_fake_docker
root="$(fake_repo redlinehostnet)"
cat >"${root}/scripts/e2e/run-docker.sh" <<'EOS'
#!/usr/bin/env bash
set -Eeuo pipefail
echo "FAKE_E2E_DOCKER_RAN"
docker run --rm --network host alpine true
EOS
run_ci "${root}"
t_isnt 0 "${rc}" "--network host 必须 rc!=0"
t_contains "RED LINE" "${out}${err}" "host 网络要有明确红线标记"

t_describe "ci.sh：E2E 完整性（禁止静默跳过）"

t_it "docker 与 bwrap 都不可用 → 必须红并给指引"
build_base_farm
install_tool shellcheck shfmt
root="$(fake_repo nodig)"
run_ci "${root}"
t_isnt 0 "${rc}" "两者都不可用时 rc!=0"
combined="${out}${err}"
t_contains "docker" "${combined}" "报错要提到 docker"
t_contains "bwrap" "${combined}" "报错要提到 bwrap 降级路径"

t_it "两 E2E 脚本都不存在时哨兵必须红（E2E 绝不允许静默跳过）"
build_base_farm
install_tool shellcheck shfmt
make_fake_docker
root="$(fake_repo noe2escripts)"
rm -f "${root}/scripts/e2e/run-docker.sh" "${root}/scripts/e2e/run-bwrap.sh"
run_ci "${root}"
t_isnt 0 "${rc}" "无 E2E 脚本时必须红"
t_contains "E2E" "${out}${err}" "报错要提到 E2E 完整性"

t_done
