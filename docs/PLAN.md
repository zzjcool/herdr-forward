# PLAN — herdr-forward 路线图

> 定位：herdr saved SSH machines 的端口暴露/连通性管理插件。
> 一个插件、一张转发表：每行一个本地端口，生命周期 = forward（ssh -L 拉到本地）
> → 可选 publish（cloudflared 发布到公网）→ remove。

## 一期：ssh -L 转发 + 三层展示（MVP）

### 数据模型
state dir（`HERDR_PLUGIN_STATE_DIR`）下 `forwards.json`：
```json
{
  "forwards": [
    {
      "id": "f-3000",
      "local_port": 3000,
      "remote_host": "127.0.0.1",
      "remote_port": 3000,
      "machine": "gpu-box",            // saved machine label 或手写 ssh target
      "ssh_target": "user@gpu-box.example.com",
      "pid": 12345,                     // 隧道进程
      "status": "up|down|starting",
      "created_unix": 1790000000
    }
  ]
}
```
读写必须原子（tmp + rename），tab bar 命令和 pane 都读它。

### 组件（开工时再实现，此处仅冻结接口）
1. `bin/forward` —— CLI（bash v1，稳定后可换 Rust）：
   - `forward add <local:remote> [--machine LABEL]`：解析端口对、起隧道（后台
     `ssh -N -L`，自建 ControlMaster `~/.ssh/herdr-forward/`，`ExitOnForwardFailure=yes`）、
     写状态、`herdr notification show` toast
   - `forward list [--oneline]`：`--oneline` 给 tab bar（`⇅3000⇅5173`），
     默认表格给 pane
   - `forward remove <id|--pick>`：kill 隧道 + 清状态
   - `forward doctor`：探活（连本地端口 TCP 握手），修状态
2. 隧道管理：v1 不做常驻 daemon —— add 时 fork 的 ssh 进程即隧道本体，
   状态文件记 pid；doctor/面板展示时探活。挂了就显示 down，用户手动重启
   （v2 再考虑事件驱动自动重启）
3. 展示：
   - tab bar：`[ui].tab_bar_right` 追加 command 条目（README 写安装步骤，
     installer 脚本 `scripts/install-tabbar.sh` 帮用户改 config.toml）
   - pane：`forward watch`（watch -n 3 或极简 TUI）
   - link_handler：Ctrl+click localhost:PORT
4. 事件（可选，一期末）：订阅 `pane.output_matched`，正则抓远程 pane 输出里的
   `listening on :PORT`，通知用户"要转发这个端口吗"

### 待验证清单（见 RESEARCH.md §3，实现前先跑通）
machine→ssh target 的获取路径是第一优先：能读 EndpointCatalog 就自动列 machines，
不能就配置文件兜底（config dir 放 `machines.toml`）。

### 一期验收（T4 收尾勾验，2026-09-23；证据见 docs/E2E-RESULTS.md）

Legend：`[x]` 可自动验证且已绿 ／ `[~]` 部分验证（沙箱内绿，剩宿主 smoke）／ `[ ]` 未做。

- [x] **add/list/remove/doctor 四个命令全可用（bash 层）**
  E2E 容器内真起用户态 sshd + echo 服务，走完整 cmd 全链路：
  `add <local>:<remote> --ssh-target …` → status=up + pid 活 → 本地端口经 `ssh -L`
  真收到 echo 回包 → `list` / `--oneline` 反映 → `doctor`/`--fix`/`--prune` 正确 →
  `remove` 后无监听、无残留 ssh、control socket 已删。
  落点：`tests/integration/test_cli_full_cycle.sh`（35 断言）+ `scripts/e2e/run-inside.sh` §A2。
- [~] **`herdr plugin link` 后上述命令全可用（经 herdr action/panes 触发）**
  命令本身已验证；`herdr-plugin.toml` 已按 SCOUT-FACTS §2.2 用
  `/bin/sh -c` + `$HERDR_PLUGIN_ROOT` 包装（`%{plugin_root}` 模板变量确认不存在）。
  剩余：真机 `herdr plugin link` + `reload-config` 后触发 action 属**宿主 smoke 待办**
  （需真实 herdr 会话，沙箱内无 TUI/server）。
- [~] **tab bar 显示活跃映射，Ctrl+click localhost 打开浏览器**
  `list --oneline` 输出契约（仅 up、端口升序、>6 截断 `+N`、纯文本无 ANSI）单测全绿，
  且 E2E 内 `list --oneline` 真输出 `⇅<port>`；link pattern 定稿带 scheme，
  bash ERE + python `re` 双引擎同构用例绿。
  剩余：真实 tab bar 渲染/截断与 Ctrl+click 命中属**宿主 smoke 待办**（假设#4/#5）。
- [x] **pane 显示表格：本地端口 / 远端 / machine / 状态 / pid**
  `forward list` 表格列已实现并断言（含 pid/status/machine）。
  `forward watch` pane 入口存在（缺 `watch` 时 die 127 有提示）。
  （真实 pane 渲染外观 = 宿主 smoke 待办。）
- [~] **断网恢复后 doctor 修正状态，无僵尸 ssh 进程**
  已验：远端 sshd 死亡/控制主进程 `kill -9` 后 `doctor` 报 down、`--fix` 修状态、
  `--prune` 清记录 **并 reap 掉 stale control socket**；收尾 `t_no_zombie_ssh` 绿。
  剩余：「真实网络断开 → 恢复」场景（非进程死亡）属**宿主 smoke 待办**。
- [x] **CI 基线拦截可跑**：`bash scripts/ci.sh` 严格模式 **6/6 通过**
  （shellcheck 30 目标 + shfmt + unit + integration + E2E + 哨兵）；
  缺工具时 `HERDR_FORWARD_CI_LAX=1` 显式 WARN 降级，绝不静默绿。
- [x] **E2E 沙箱闭环**：`bash scripts/e2e/run-docker.sh` 退出码 0（容器内 59 断言全绿，
  模式 A：容器内可跑宿主 herdr 0.9.1）；无 docker 时 `run-bwrap.sh` 亦绿（53 断言）。
- [ ] **二期接口未被堵死**：状态文件已含 `publish:{pid,url,started_unix}` 占位（恒 null），
  `publish`/`unpublish` 命令占位 exit 9（A.3 冻结）。二期实现本身未做。

## 二期：Publish（cloudflared quick tunnel）

- `forward publish <port|--pick>`：起 `cloudflared tunnel --url http://localhost:PORT`
  （后台，stdout 抓 `https://*.trycloudflare.com` URL），状态文件记 pid+url
- 面板行加 `published: https://xxx.trycloudflare.com`（Ctrl+click 复制/打开）
- tab bar `--oneline` 输出加公网标记（如 `⇅3000🌐`）
- `forward unpublish`：kill cloudflared
- 前置：检测 cloudflared 是否安装，缺失时 action 给安装提示（不自动装）
- ⚠ 文案纪律：公网动作一律叫 Publish，不用 tunnel（命名裁决，见 RESEARCH §2.5）

### 二期验收
- publish/unpublish 往返干净，URL 实时显示在 pane
- quick tunnel 进程退出（超时/网络）后面板正确显示 down

## 三期（候选，不承诺）
- `ssh -R` 反向（本地→远程机器方向）
- SOCKS `-D`
- 事件驱动自动转发（检测 dev server 启动 → 询问 → add）
- 隧道自动重连

## 发布检查单
- [x] 公开前：GitHub `herdr-forward in:name` total_count == 0（否则换名）（2026-09-23 实查：仅 zzjcool/herdr-forward 自身）
- [x] README 首句写明双能力：remote port → localhost，localhost → public URL
- [x] 明确和 herdr-portfwd / herdr-fwd / herdr-tunnel 的差异（saved machines 显式映射）
- [ ] 反悔信号监控（RESEARCH §2.5）
