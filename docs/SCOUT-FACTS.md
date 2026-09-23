# SCOUT-FACTS — 侦察事实（2026-09-23，scout-0 产出，供实现 worker 引用）

> 全文见 scout 会话；本文提炼与实现直接相关的关键事实与修正。
> 分档：**已证实**（本机实测）／**文档来源**（herdr.dev 官方）／**未证实**。

## 1. 已证实（本机实测）

### 1.1 隔离 HOME 跑 herdr（E2E 沙箱前提成立）
- `HOME=... XDG_CONFIG_HOME=... XDG_STATE_HOME=... herdr --version` 正常，读隔离路径。
- ⚠ **必须 unset 继承的 env**：`HERDR_SOCKET_PATH HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID`
  （否则 CLI 连到真实运行中的 server）。sandbox 脚本里要显式处理。
- herdr 不自动创建 HOME/XDG 目录；沙箱要落配置需预建目录。

### 1.2 bwrap 沙箱可用（降级方案成立）
- 最小骨架（bwrap 会重置 PATH，shell 内用绝对路径最稳）：
  `bwrap --unshare-net --unshare-pid --unshare-ipc --die-with-parent --dev /dev --proc /proc --ro-bind /usr /usr --ro-bind /bin /bin --ro-bind /lib /lib --ro-bind /lib64 /lib64 --ro-bind /etc /etc --tmpfs /tmp --tmpfs /root /usr/bin/bash -c '...'`
- `--tmpfs /tmp` 会遮蔽宿主 /tmp，需读写宿主 /tmp 时改 `--bind /tmp /tmp`。

### 1.3 用户态 sshd 可行（集成测试 + E2E 数据面成立）
- 自写 sshd_config（Port 高端口 / ListenAddress 127.0.0.1 / 专用 HostKey / UsePAM no /
  PasswordAuthentication no / PermitRootLogin no）+ ssh-keygen host key → `sshd -t` 通过，真起服务监听成功，ssh 公钥认证层正常。
- ⚠ sshd 必须绝对路径调用；ssh 客户端用 `-F /dev/null` 规避宿主 ssh_config 告警。

### 1.4 本机工具
- **无 bats、无 shellcheck、无 shfmt、无 nc**（E 节 CI 需求全部缺失）。
- 有：jq 1.8.2、GNU timeout、flock、bwrap、sshd/ssh、cloudflared、docker（已启动）。
- → T0 的 ci.sh 本机直接跑会因缺 shellcheck/shfmt 挂掉；测试跑依赖纯 bash 断言（无 nc 时用 bash /dev/tcp 或容器内 nc）。

## 2. 文档来源（herdr.dev）

### 2.1 machine → ssh target：socket API 无门
- `herdr api schema --json` 里 **没有 machine.* / endpoint.* / ssh.* method** → 插件不能经 socket API 列 saved machines。
- saved machines 落盘在 client 侧 `endpoints.json`（catalog.rs），**schema 未知**（试了多种形状都读成 `[]`）。
- 兜底方案（PLAN 的 machines.toml）是一期正式路径，不是降级。

### 2.2 manifest 字段（对 T3 worker 的修正）
- `[[actions]]`: id title contexts command platforms；`[[panes]]`: id title command placement platforms width height（popup 限定）；`[[link_handlers]]`: id title pattern action platforms。
- id 规则：ASCII letters/digits/`: . _ -`；**action/pane/link_handler 的 id 不能含点**。
- `%{plugin_root}` 模板变量**不存在** → 必须用 `HERDR_PLUGIN_ROOT` env + 包装脚本。
- command 是 argv 数组不经 shell。
- min_herdr_version 必填，比当前二进制新则拒绝 link。

### 2.3 link_handlers pattern
- Rust regex，匹配 clicked URL；**URL scheme 检测只认 http:// / https://**（bytecode 证据）→
  无 scheme 的 `localhost:3000` 大概率不命中。pattern 设计需带 scheme：`https?://(localhost|127\.0\.0\.1)(:\d+)?`。

### 2.4 tab_bar_right（对 T3 的精确语法）
```toml
[ui]
tab_bar_right = [
  { type = "command", command = "~/.config/herdr/status.sh", interval_seconds = 5, timeout_seconds = 2 },
]
```
- 经 `/bin/sh -lc` 执行；取 stdout **最后一行**；去 ESC 控制序列（**ANSI 颜色别指望渲染**，oneline 输出纯文本）；
  失败/空/timeout 清空条目。interval 1–31536000s，timeout 1–3600s。无硬性宽度限制但应短小。

## 3. 未证实（T4/宿主 smoke 处理）
1. endpoints.json 准确 schema（`machine list --json` 真实形状）—— 需真实 saved machine 环境
2. 无 scheme localhost:3000 Ctrl+click 是否命中（倾向不命中，pattern 已按带 scheme 设计）
3. tab_bar_right 精确宽度截断行为
4. herdr per-attach SSH control socket 能否复用

## 4. 对 worker 任务的直接影响（主 agent 裁决）
- **T0**：本机缺 shellcheck/shfmt/nc —— ci.sh 需支持「工具缺失时明确报错提示安装」或跳过并警示（不静默绿）；容器内装齐（arch Dockerfile: pacman -Sy --noconfirm shellcheck shfmt openbsd-netcat jq openssh bash coreutils util-linux）。
- **T2**：machine_resolve 主路径 = machines.toml（配置文件是正式路径，不是兜底）；socket API 读取路线删除。
- **T3**：link pattern 定稿必须带 scheme；oneline 输出纯文本无 ANSI；manifest 用 HERDR_PLUGIN_ROOT env 包装；id 不能含点。

## 5. 追加实证（machines 集成，2026-09-23）

- `herdr machine list --json` 输出 schema（本机真实验证）：
  `[{"id":"<hex>","label":"<label>","target":"<ssh target>","session":"default","enabled":true,"selected":false}]`
  —— 与二进制证据 SavedSshEndpoint{ssh,label,target,session,enabled} 吻合；§2.1 的
  「endpoints.json schema 未知」结论就此闭环：插件侧经 HERDR_BIN_PATH CLI 透传即可拿到
  saved machines（socket API 仍无对应 method）。
- saved machine 的 target 不支持端口后缀（`host:2222` 会被 herdr machine add 当作
  主机名解析失败）——herdr 自身限制，非插件问题。
- `herdr machine add` 会做远端平台探测（真 SSH 连接 + host key 校验），失败不落盘。
