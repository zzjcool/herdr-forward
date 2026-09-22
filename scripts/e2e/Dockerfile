# E2E 镜像（ARCHITECTURE §C.3）：archlinux 基础 + 完整测试基线工具集。
#
# 为什么在镜像里装 shellcheck/shfmt：宿主可能没有（SCOUT-FACTS §1.4），
# 但「完整 ci 基线」必须在容器内可跑 —— 容器是 E2E 的权威环境。
# 源码不在 build 时拷入：run-docker.sh 在 `docker run` 时只读 bind mount，
# 开发迭代无需重 build。
FROM docker.io/library/archlinux:latest

# openssh      sshd + ssh 客户端（用户态 sshd 回环）
# jq           状态文件断言（断言库 t_json_valid 依赖）
# openbsd-netcat  nc：客户端与端口探活（archlinux 无 gnu-netcat 包）
# python3      集成测试的 echo 服务、tcp_serve_once_bg 兜底、test_common 日志轮转、
#              test_link_pattern 的 tomllib 解析（缺它 unit 三个文件 rc=127）
# socat        echo 服务承载进程：openbsd nc 无 -e/-c，不能自己回显；
#              socat 的 EXEC:/bin/cat（或 while-read 脚本）fork-per-conn 提供真回显，
#              即契约 §C.3 里「同容器后台 echo 进程」的可靠落地
# shellcheck/shfmt  容器内完整 ci 基线（宿主可能缺）
# coreutils/util-linux  timeout/pgrep/ss 等测试原语
RUN pacman -Sy --noconfirm \
  openssh jq openbsd-netcat socat python3 bash coreutils util-linux \
  shellcheck shfmt iproute2 \
  && pacman -Scc --noconfirm \
  && command -v shellcheck shfmt jq nc socat python3 sshd ssh-keygen bash

# 非 root 测试用户（贴近真实运行环境，且验证用户态 sshd 在无特权下可行）
RUN useradd -m -s /bin/bash fwduser

# /work：容器内可写工作区（run-inside.sh 把 /plugin-src 拷到这里跑）。
# run-docker.sh 再把宿主 test-results 目录 bind 到 /work/test-results，把探测结果带出容器。
RUN mkdir -p /work && chown fwduser:fwduser /work

# 容器内测试主体（宿主只读挂载源码到 /plugin-src；结果写 /work/test-results）
COPY scripts/e2e/run-inside.sh /usr/local/bin/run-inside.sh
RUN chmod +x /usr/local/bin/run-inside.sh

# 注意：不 EXPOSE、不 --publish —— E2E 只在容器内回环（§C.2.5）
USER fwduser
WORKDIR /home/fwduser

ENTRYPOINT ["/usr/local/bin/run-inside.sh"]
