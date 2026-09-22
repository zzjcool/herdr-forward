# RESEARCH — herdr 0.9.1 插件能力与端口转发现状（2026-09-23 实测）

> 本文档是立项调研的落地记录。所有"实测"条目都在本机 herdr 0.9.1（Arch, /usr/bin/herdr）
> 上验证过；标注"文档/搜索"的来自 herdr.dev 官方文档与 GitHub 检索（search 子 agent 带出处）。
> 逆向来源是 `strings /usr/bin/herdr`，只用于确认 schema 字段名，不作为行为依据。

## 1. herdr 有没有内置端口映射？

**没有。**（文档 + changelog + HN 社区帖确认）

- 0.9.0 machines：同一窗口管理 Local + saved SSH machines（`herdr machine add/list/remove/rename`）
- 0.9.1 "CLI forwarding"：`herdr --machine <id> <command>` 把 **herdr API 命令**转发到远程
  server 执行，与 TCP 端口无关
- 远程 attach 内部的 `local_forward_socket_path` 只转发 herdr 自己的 Unix socket 桥
  （`SshStdioBridge`），不是任意应用端口
- Issue #4350：作者确认 herdr transport 不用 `-L/-R/-D`
- HN 有用户问过 "支持 ssh -L 吗"，无人回应
- 社区 X11 讨论结论：用你自己的 `ssh -Y`

竞品/相邻项目（GitHub in:name 实测 2026-09-22/23）：

| 仓库 | 行为 | 与本项目关系 |
|---|---|---|
| miko-misa/herdr-portfwd | ControlMaster `-O forward`，`--remote` 场景，两端装 | 最近竞品；不基于 0.9 saved machines |
| go-min/herdr-fwd | 远程会话自动转发 loopback | 自动 vs 我们的显式映射 |
| randomradio/herdr-ports | 远程 workspace 端口转本地（域名式） | 语义重叠 |
| ivorpad/herdr-ports | 本机监听端口列表/查杀 | 不同赛道 |
| ivorpad/herdr-tunnel | 本地端口暴露公网 | 与我们二期 cloudflared 撞方向，名字已占 |
| pikujs/herdr-agent-gateway | agent HTTP 网关 | 占住 gateway 语义 |

## 2. 插件系统关键事实（决定我们的架构）

### 2.1 执行位置 —— 最重要的一条
- 插件/自定义命令跑在**当前选中的 server** 上；herdr 不把本地插件拷到 SSH host
  （文档 connecting-machines）
- **实测**：demo 插件 action invoke 在本地执行（host=hw 本机名），
  context 携带 workspace/tab/focused pane cwd/agent 状态
- 推论：本地 herdr server 跑在笔记本上 → 本地插件能 bind 端口、能起 `ssh -L`。
  saved-machines 架构下这是主路径（miko-misa 在 `--remote` 时代的"两端装"痛点被绕开）

### 2.2 manifest（herdr-plugin.toml，二进制 schema 确认 + 实测）
- 顶层必填 `id/name/version/min_herdr_version`；可选 `description/platforms`
- 表：`[[build]] [[startup]] [[actions]] [[events]] [[panes]] [[link_handlers]]`
- `command` 是 **argv 数组，不经 shell**（tab_bar_right 的 command 例外，是字符串经 shell）
- `[[startup]]` 一次性初始化（API ready 后跑，handoff 再跑），不是受监管 daemon
- env：`HERDR_SOCKET_PATH HERDR_BIN_PATH HERDR_PLUGIN_ROOT HERDR_PLUGIN_CONFIG_DIR
  HERDR_PLUGIN_STATE_DIR HERDR_PLUGIN_CONTEXT_JSON` 等
- link_handlers：`pattern` 是 Rust regex，`action` 必须指向本插件已声明的 action，
  Ctrl+click 触发（含 macOS）
- panes：`id/title/command` + `placement`（split/overlay/popup/tab），popup 可设
  width/height；split/zoomed 需 target_pane_id

### 2.3 展示三层（本期 UI 的全部落点）
1. **tab bar 状态条**（实测可用）：`[ui].tab_bar_right` 支持
   `{ type = "command", command, interval_seconds, timeout_seconds }`，
   在 server 机器周期执行、stdout 渲染到 tab 栏右侧。已实测 reload-config 接受。
   ⚠ command 必须"秒回"（读状态文件），不能在命令里做 SSH 探活
2. **插件 pane**（`[[panes]]`）：Ports 面板，跑 watch/TUI，交互式管理
3. **通知 + 链接**：`notification.show` socket API + link_handlers Ctrl+click

### 2.4 包管理
- 无中心 registry。`herdr plugin install <owner>/<repo>[/subdir] [--ref REF] [--yes]`
  （v1 只认 GitHub owner/repo 简写）；herdr 自己 git clone 到 managed checkout，
  锁 resolved_commit；更新 = 重新 install
- 本地开发：`herdr plugin link <path> [--disabled]`（symlink）
- 冲突规则：同 id 本地 link 过 → 必须 unlink 才能 install GitHub 版
- 目录：`~/.config/herdr/plugins/`（registry symlink）、
  `~/.config/herdr/plugins/config/<id>/`（配置）、
  `~/.local/state/herdr/plugins/<id>/`（状态）
- id 规则：非空、≤120、ASCII 字母数字 `: . _ -`，惯例 `owner:name`

### 2.5 命名裁决记录（两轮 advisor，均 GitHub 实测查名）
- 第一轮：`herdr-ssh-forward`（fwd/ports/tunnel/portfwd 全被占用）
- 第二轮（cloudflared 二期加入后推翻）：**`herdr-forward`，id `zzjcool:forward`，
  界面名 Port Forward，公网动作叫 Publish 不叫 tunnel**
- 反悔信号（来自裁决，写入发布检查单）：
  - 公开前再查 `herdr-forward in:name`，total_count > 0 就换名
  - 发布后 issue 若多数只要公网 URL、或抱怨 cloudflared 多装二进制 → 拆第二个插件
  - README 首句必须写明两个能力（远程端口转本地 + 本地端口发布公网）

## 3. 待验证假设（实现期要逐个打勾）

- [ ] 插件能否通过 socket API 读到 `EndpointCatalog`/`SavedSshEndpoint`（拿到 saved
  machine 的 SSH target）？读不到则用户在插件配置里手写 machine→ssh target 映射
- [ ] `[[panes]]` command 里 `%{plugin_root}` 这类模板变量是否支持（若不支持则用
  `HERDR_PLUGIN_ROOT` env 在包装脚本里解析）
- [ ] herdr 自己的 per-attach SSH control socket 能否复用（省一条连接），
  还是必须自建 ControlMaster
- [ ] link_handlers 的 regex 对 `localhost:3000`（无 scheme）能否命中，
  还是只匹配带 http:// 的
- [ ] tab_bar_right command 的输出宽度/ANSI 限制（长了会不会截断）

## 4. 参考链接

- 官方文档：https://herdr.dev/docs/plugins/ 、https://herdr.dev/docs/socket-api/ 、
  https://herdr.dev/docs/connecting-machines/ 、https://herdr.dev/docs/persistence-remote/
- 源码（Apache-2.0）：https://github.com/herdrdev/herdr
- changelog：https://herdr.dev/latest.json
- 竞品：https://github.com/miko-misa/herdr-portfwd
- Cloudflare quick tunnel：https://try.cloudflare.com/ （`cloudflared tunnel --url`）
