#!/usr/bin/env bash
# scripts/e2e/run-docker.sh — E2E 无人值守入口（ARCHITECTURE §C.3）
#
# 职责：build 镜像 →（可选）挂载宿主 herdr 二进制 → docker run → 透传容器退出码。
# 容器退出码即 E2E 结果，ci.sh 直接消费。
#
# 红线（§C.2，ci.sh 第 6 段静态 grep 看守）：
#   * bind mount 只允许仓库源码与 test-results 目录，绝不挂载 $HOME 或 /home/*
#   * 不 --publish/-p/EXPOSE 任何端口（测试全在容器内 127.0.0.1 回环）
#   * 不 --network host（默认 bridge 即可；容器内不访问外网，cloudflared 属二期）
#   * 宿主 herdr 只读挂载（模式 A 探测定型）；跑不动则降级模式 B（容器内 shim）
#   * 容器内跑 herdr CLI 前由 run-inside.sh 显式 unset HERDR_SOCKET_PATH 等继承 env
set -Eeuo pipefail

PROJ="$(cd "$(dirname "$0")/../.." && pwd)"
IMAGE="${HERDR_FORWARD_E2E_IMAGE:-herdr-forward-e2e:local}"
DOCKERFILE="${PROJ}/scripts/e2e/Dockerfile"
RESULTS_DIR="${PROJ}/test-results"

log() { printf '[e2e-docker] %s\n' "$*"; }

if ! command -v docker >/dev/null 2>&1; then
  echo "E2E docker 不可用：未找到 docker CLI（降级路径见 scripts/e2e/run-bwrap.sh）" >&2
  exit 127
fi
if ! docker info >/dev/null 2>&1; then
  echo "E2E docker 不可用：docker daemon 未运行（降级路径见 scripts/e2e/run-bwrap.sh）" >&2
  exit 127
fi

log "构建镜像 ${IMAGE}"
# 首次构建要拉 archlinux 与 pacman 包，给足超时；--network 默认（build 需要出网装包）
if ! timeout 900 docker build -f "${DOCKERFILE}" -t "${IMAGE}" "${PROJ}"; then
  echo "E2E docker 构建失败（Dockerfile: ${DOCKERFILE}）" >&2
  exit 1
fi

# 探测模式 A：宿主 herdr 二进制能否在容器内跑（§C.4 假设#6 两层降级的第一步）
# 只读挂载 + 立即执行 --version；成功才把挂载带进正式 run。
HERDR_MOUNT=()
HERDR_PROBE_MODE="B"
if [[ -x /usr/bin/herdr ]]; then
  log "探测宿主 herdr 二进制在容器内的可执行性（模式 A/B）"
  if timeout 120 docker run --rm \
    -v /usr/bin/herdr:/usr/local/bin/herdr:ro \
    --entrypoint /usr/local/bin/herdr \
    "${IMAGE}" --version >/dev/null 2>&1; then
    HERDR_PROBE_MODE="A"
    HERDR_MOUNT=(-v /usr/bin/herdr:/usr/local/bin/herdr:ro)
    log "探测结论：模式 A（容器内可跑挂载的宿主 herdr）"
  else
    log "探测结论：模式 B（宿主 herdr 在容器内不可跑 → 容器内 shim + 纯 bash 层）"
  fi
else
  log "宿主无 /usr/bin/herdr → 模式 B"
fi

# test-results 目录用于把探测结论带出容器（容器内 /work/test-results 指向这里）
mkdir -p "${RESULTS_DIR}"

log "运行容器（模式 ${HERDR_PROBE_MODE}）"
# 注意：不 --publish、不 --network host；源码只读挂载，结果目录可写挂载。
set +e
timeout 600 docker run --rm \
  "${HERDR_MOUNT[@]}" \
  -v "${PROJ}":/plugin-src:ro \
  -v "${RESULTS_DIR}":/work/test-results \
  -e HERDR_E2E_MODE="${HERDR_PROBE_MODE}" \
  "${IMAGE}"
rc=$?
set -e

log "容器退出码：${rc}"
if [[ -f "${RESULTS_DIR}/e2e-mode.txt" ]]; then
  log "模式探测结果："
  sed 's/^/    /' "${RESULTS_DIR}/e2e-mode.txt"
fi
exit "${rc}"
