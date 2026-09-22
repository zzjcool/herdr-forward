# E2E 镜像（ARCHITECTURE §C.3）：archlinux 基础 + 完整测试基线工具集。
#
# 为什么在镜像里装 shellcheck/shfmt：宿主可能没有（SCOUT-FACTS §1.4），
# 但「完整 ci 基线」必须在容器内可跑 —— 容器是 E2E 的权威环境。
# 源码不在 build 时拷入：run-docker.sh 在 `docker run` 时只读 bind mount，
# 开发迭代无需重 build。
FROM docker.io/library/archlinux:latest

# openssh      sshd + ssh 客户端（用户态 sshd 回环）
# jq           状态文件断言（断言库 t_json_valid 依赖）
# python       T1/T2/T3 单测集成测试的硬依赖（tomllib/TOML 解析、Rust regex 代理、
#              echo 服务、test_common 日志轮转）；arch 包名为 python，提供 python3 二进制
# openbsd-netcat  nc：客户端与端口探活（archlinux 无 gnu-netcat 包）
# socat        echo 服务承载进程：openbsd nc 无 -e/-c，不能自己回显；
#              socat 的 EXEC:/bin/cat（或 while-read 脚本）fork-per-conn 提供真回显，
#              即契约 §C.3 里「同容器后台 echo 进程」的可靠落地
# coreutils/util-linux  timeout/pgrep/ss 等测试原语
# shellcheck/shfmt 不用 pacman 版：下方用二进制固定版本覆盖（见注释）
RUN pacman -Sy --noconfirm \
  openssh jq python openbsd-netcat socat bash coreutils util-linux \
  iproute2 \
  && pacman -Scc --noconfirm \
  && command -v jq nc socat sshd ssh-keygen bash python3

# shellcheck 与 shfmt 用二进制固定版本覆盖 pacman 版：
# pacman 的 shfmt 是滚动更新（实测 3.14.x），与宿主/开发者常用 3.10 对同一构造
# 会给出不同格式 —— 同一份源码在 CI 与本地得出不同结论是基线拦截最忌讳的。
# 固定到与项目声明一致的版本，保证“格式化结果唯一”。
ARG SHFMT_VERSION=3.10.0
ARG SHELLCHECK_VERSION=0.10.0
RUN curl -fsSL -o /usr/local/bin/shfmt \
  "https://github.com/mvdan/sh/releases/download/v${SHFMT_VERSION}/shfmt_v${SHFMT_VERSION}_linux_amd64" \
  && chmod 0755 /usr/local/bin/shfmt \
  && curl -fsSL -o /tmp/sc.tar.xz \
  "https://github.com/koalaman/shellcheck/releases/download/v${SHELLCHECK_VERSION}/shellcheck-v${SHELLCHECK_VERSION}.linux.x86_64.tar.xz" \
  && tar -xJf /tmp/sc.tar.xz -C /tmp \
  && install -m 0755 "/tmp/shellcheck-v${SHELLCHECK_VERSION}/shellcheck" /usr/local/bin/shellcheck \
  && rm -rf /tmp/sc.tar.xz "/tmp/shellcheck-v${SHELLCHECK_VERSION}" \
  && shfmt --version && shellcheck --version | head -2

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
