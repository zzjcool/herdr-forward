# ARCHITECTURE — herdr-forward 冻结版架构与开发规范

> 本文是开工前冻结的架构契约与开发规范。v1 实现期任何偏离必须先改本文（PR 里说明）再改代码。
> 依据：PLAN.md（路线图）、RESEARCH.md（herdr 0.9.1 实测能力）。
> 实现语言：bash（bin/forward），稳定后才考虑 Rust 重写；本文冻结的模块接口按
> 「bash 函数签名 + JSON 数据契约」表述，Rust 化时映射为函数/结构体。

## 0. 目标与不做的事

**目标**：一期交付 `add / list / remove / doctor` 四个 CLI 命令 + tab bar 状态条 +
Port Forward pane + localhost 链接处理，全部 TDD、CI 基线拦截、E2E 在 docker 容器
（bwrap 为无 docker 环境降级备选）内闭环。

**Non-goals（一期）**：
- 不做常驻 daemon、不做自动重连、不做事件驱动自动转发（三期候选）
- 不做 `ssh -R` / `-D`
- 不做 cloudflared publish（二期；但本文冻结其状态文件字段与命令签名，防一期实现把二期堵死）
- 不自动安装 cloudflared / 不写用户 `~/.ssh/config`（只自建 `~/.ssh/herdr-forward/` 子目录）
- 不在 E2E 里触碰本机真实 herdr 环境 / saved machines / 已有 SSH key

## A. 模块划分与接口冻结

### A.1 目录树

```
herdr-forward/
├── herdr-plugin.toml          # manifest（开工时填 actions/panes/link_handlers）
├── bin/
│   └── forward                # CLI 入口：唯一可执行文件，set -Eeuo pipefail，纯 dispatch
├── lib/
│   ├── common.sh              # 日志、错误、依赖检查、原子写、探活原语
│   ├── state.sh               # forwards.json 读写（唯一状态权威）
│   ├── machine.sh             # LABEL → ssh_target 解析（EndpointCatalog / machines.toml）
│   ├── tunnel.sh              # ssh -L 隧道生命周期（ControlMaster 自建）
│   └── notify.sh              # herdr socket API / notification 封装（可降级为 no-op）
├── scripts/
│   ├── ci.sh                  # 基线拦截：lint + 全部测试，任一红即 exit 1
│   ├── install-tabbar.sh      # 帮用户往 config.toml 加 tab_bar_right 条目
│   └── e2e/
│       ├── Dockerfile         # E2E 镜像（archlinux + openssh + jq + 测试依赖）
│       ├── run-docker.sh      # 无人值守入口：build + docker run，退出码即结果
│       ├── run-inside.sh      # 容器内测试主体（entrypoint 调用）
│       └── run-bwrap.sh       # 降级备选：无 docker 环境用 bwrap（见 §C.5）
├── tests/
│   ├── lib/
│   │   └── assertions.sh      # 纯 bash 断言库（见 §B.1，零外部依赖）
│   ├── fixtures/
│   │   └── forwards.*.json    # 状态文件 fixture（合法/损坏/空/多记录）
│   ├── unit/                  # 每命令/每函数级，秒级，无网络无进程
│   ├── integration/           # 真起 sshd/ssh 隧道（本机 user 高端口），数据面回环
│   └── e2e/                   # 只在容器/bwrap 沙箱里跑，绝不碰真实环境
└── docs/
```

**归属规则（防写冲突）**：每个文件同时只有一个 writer（见 §D）；
`tests/lib/assertions.sh`、`tests/run.sh`、`scripts/ci.sh` 归 T0。

### A.2 数据契约（state.sh 冻结，一期就含 publish 字段占位）

`$HERDR_PLUGIN_STATE_DIR/forwards.json`（无 env 时回退 `~/.local/state/herdr-forward/`，
CI/沙箱里始终显式设 env）：

```json
{
  "version": 1,
  "forwards": [
    {
      "id": "f-3000",
      "local_port": 3000,
      "remote_host": "127.0.0.1",
      "remote_port": 3000,
      "machine": "gpu-box",
      "ssh_target": "user@gpu-box.example.com:22",
      "pid": 12345,
      "control_socket": "/home/u/.ssh/herdr-forward/ctl-f-3000",
      "status": "up",
      "created_unix": 1790000000,
      "publish": { "pid": null, "url": null, "started_unix": null }
    }
  ]
}
```

- `status ∈ starting|up|down`（add 写 `up`，doctor 探活时修正）
- `id = "f-<local_port>"`（本地端口唯一；add 重复本地端口 die 2，不覆盖）
- `ssh_target` 冒号带端口（解析结果落盘，remove/doctor 不再二次解析）
- `publish` 为二期占位，一期恒为 null

### A.3 函数签名冻结（lib/*.sh）

```bash
# common.sh
log <level:debug|info|warn|error> <msg...>     # -> $HERDR_PLUGIN_STATE_DIR/logs/forward.log（无 env 则 /dev/stderr）
die <exit_code> <msg...>                       # log error + exit；用户可见错误必须含下一步建议
require_cmd <name> [hint]                      # command -v 失败即 die 127
now_unix                                       # stdout: epoch 秒
atomic_write <file> <tmpdir>                   # stdin 内容 -> 同分区 mktemp -> mv -f
probe_tcp <host> <port> [timeout_s=2]          # bash /dev/tcp 探活，stdout: ok|fail，不因失败 exit
tcp_serve_once <port>                          # 调试用回显：nc 变体探测/bash coproc 兜底，读一行回 'pong'

# state.sh
state_file                                     # stdout: 状态文件绝对路径（env 解析）
state_load                                     # stdout: jq '.forwards' 数组（损坏 -> 空数组 + warn，不 crash）
state_save <json_forwards_array>               # 原子写；jq 格式化排序输出
forward_add_record <record_json>               # 写入（local_port 冲突 die 2）
forward_remove_record <id>                     # 删除（不存在 die 3）
forward_get <id>                               # stdout: 单条 record json（不存在 die 3）
forward_list_json                              # stdout: 完整数组
forward_set_status <id> <status>               # 修状态

# machine.sh
machine_resolve <label>                        # stdout: ssh_target；失败 die 4
                                              # 路径：1) herdr socket API 读 EndpointCatalog（假设#1）
                                              #       2) $HERDR_PLUGIN_CONFIG_DIR/machines.toml 兜底
machines_toml_path                             # stdout: 兜底配置路径
# machines.toml 格式：[machines.gpu-box]  ssh_target = "user@host:22"

# tunnel.sh（ControlMaster 自建，目录 $CONTROL_DIR=${HERDR_PLUGIN_STATE_DIR}/ssh-ctl/）
tunnel_start <id> <local_port> <remote_host:remote_port> <ssh_target>
                                              # fork: ssh -N -L -o BatchMode=yes -o ExitOnForwardFailure=yes
                                              #       -o ControlMaster=auto -o ControlPath=<dir>/ctl-<id> -o ControlPersist=yes
                                              #       -o StrictHostKeyChecking=accept-new（沙箱 host key 一次性）
                                              # stdout: pid；失败 die 5
tunnel_stop <id>                               # ssh -O exit 经 control socket 优雅关 + kill pid 兜底
tunnel_alive <pid>                             # stdout: true|false（kill -0 且非 zombie）
tunnel_probe <local_port>                      # probe_tcp 127.0.0.1 <port> 封装

# notify.sh
notify_toast <title> <body>                    # herdr socket API / notification show；不可用降级 log info，永不阻塞>1s

# bin/forward 子命令（每个 cmd_* 一一对应）
# forward add <local:remote> [--machine LABEL] [--ssh-target TARGET]   # 显式 target 则跳过 machine_resolve
# forward list [--oneline] [--json]
# forward remove <id|--pick|--all]
# forward doctor [--fix|--prune]          # 默认只报告；--fix 修状态；--prune 清死进程记录
# forward publish <port>                   # 二期占位：exit 9 "not implemented in v1"
# forward unpublish                        # 二期占位
# forward watch                            # pane 入口：watch -n 3 forward list（TUI 三期）
```

**tab bar 契约**（`forward list --oneline`，秒回、只读状态文件）：
- 无活跃映射 → 空输出（exit 0）
- 有 → `⇅3000⇅5173`（active only，端口升序；超 6 个截断为 6 个 + `+N`，见假设#5）
- 二期 publish 后加 `🌐` 后缀

**退出码表冻结**：`0 ok / 2 重复端口 / 3 记录不存在 / 4 machine 无法解析 /
5 隧道启动失败 / 9 未实现 / 127 依赖缺失`

### A.4 herdr-plugin.toml 冻结声明（开工时填入）

```toml
[[actions]]
id = "add"
command = ["%{plugin_root}/bin/forward", "add"]   # 模板变量若不支持 → 包装脚本读 HERDR_PLUGIN_ROOT
# ... list/remove/doctor 同构

[[panes]]
id = "ports"
title = "Port Forward"
command = ["%{plugin_root}/bin/forward", "watch"]

[[link_handlers]]
pattern = "(?:https?://)?(localhost|127\\.0\\.0\\.1)(:\\d+)?"   # 无 scheme 命中待验证（假设#4）
action = "noop"                                                 # 占位：一期仅打开浏览器
```

## B. TDD 流程规范

### B.1 测试框架：自写纯 bash 断言库（不引入 bats）

`tests/lib/assertions.sh`（约 80 行，TDD 第 0 步先写它 + 自测）：

```bash
#!/usr/bin/env bash
# 零依赖断言库。每个测试文件 source 本库 + 被测 lib/*.sh。
set -Eeuo pipefail
PASS=0; FAIL=0
t_describe <name>          # 分组（纯标签）
t_it <desc>                # 单用例开始（纯标签）
t_ok   [msg]               # 断言真
t_fail [msg]               # 断言假
t_eq <expected> <actual> [msg]       # 字符串相等
t_match <regex> <actual> [msg]       # regex 命中
t_exit_ok <expected_code> <actual_code> [msg]
t_file_exists <path>
t_json_valid <file>                 # jq empty
t_no_zombie_ssh                     # pgrep -f 'ssh.*herdr-forward' 无残留（集成/E2E 收尾断言）
t_done                              # 汇总，FAIL>0 exit 1
run <func> [args...]                # set +e 包裹，捕获 $out/$err/$rc
```

运行器 `tests/run.sh [unit|integration|e2e]`：遍历目录逐个 `bash` 执行，
任一文件非零退出即整体失败。串行执行（避免端口竞争，测试必须快）。

### B.2 三层测试定义

| 层 | 目录 | 特征 | 允许的副作用 |
|---|---|---|---|
| 单测 | tests/unit | source lib/*.sh 直接调函数；状态用 `TMPDIR=$(mktemp -d)` + fixture；**零网络零进程**（tunnel.sh 只测参数拼装） | 仅 TMPDIR |
| 集成 | tests/integration | 本机用户态 sshd（高端口 22022+，host key 在 TMPDIR）+ 真 ssh -L + nc 回环；随机端口段防冲突；trap 清理 + `t_no_zombie_ssh` 收尾 | TMPDIR + 临时高端口 |
| E2E | tests/e2e | 只在 docker 容器（主）/bwrap（降级）里跑完整用户流 | 仅沙箱内 |

**状态 fixture**（unit 必覆盖）：`forwards.empty.json`、`forwards.valid.json`、
`forwards.multi.json`、`forwards.corrupt.json`（损坏 → state_load 空数组 + warn）。

### B.3 红→绿循环纪律

1. **红**：先写失败测试，跑 `bash tests/run.sh unit` 确认因「功能缺失」而红（非语法错）。
2. **绿**：最小实现让测试过；禁止顺手实现测试未覆盖的行为。
3. **每轮结束**：`scripts/ci.sh` 全绿才算该轮完成；红则修复或 revert，禁止 skip。
4. 重构只在全绿状态下做；重构后重跑 ci.sh。
5. bug 修一律先写复现测试（红）再修（绿）。
6. **基线拦截**：main 分支 ci.sh 必须全绿；本地 commit 前必须跑过。

### B.4 基线拦截脚本 scripts/ci.sh（冻结）

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
fail() { echo "CI FAIL: $*" >&2; exit 1; }
for c in shellcheck shfmt jq; do
  command -v "$c" >/dev/null || fail "$c 未安装"
done

echo "== 1/6 shellcheck（严格） =="
shellcheck -x -S style -o all bin/forward lib/*.sh tests/lib/*.sh tests/**/*.sh scripts/*.sh \
  || fail "shellcheck"

echo "== 2/6 shfmt =="
shfmt -d -ln bash -i 2 bin/forward lib/*.sh tests/lib/*.sh scripts/*.sh \
  || fail "shfmt 格式不一致（跑 shfmt -w）"

echo "== 3/6 unit =="
bash tests/run.sh unit        || fail "unit"

echo "== 4/6 integration =="
bash tests/run.sh integration || fail "integration"

echo "== 5/6 e2e docker =="
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  bash scripts/e2e/run-docker.sh || fail "e2e-docker"
else
  echo "docker 不可用，降级 bwrap e2e"
  bash scripts/e2e/run-bwrap.sh || fail "e2e-bwrap"
fi

echo "== 6/6 e2e 完整性哨兵 =="
# E2E 绝不允许静默跳过：上一步要么跑过 docker 要么跑过 bwrap，两者都不可用即失败
```

## C. E2E 沙箱方案：docker 为主，bwrap 降级

### C.1 设计原则（两方案共同）

- **隔离 HOME/XDG**：容器/沙箱内 HOME 指向独立目录，herdr 的 `~/.config/herdr`、
  `~/.local/state/herdr` 全落在沙箱内。
- **不跑 herdr TUI**：herdr 侧验证 = CLI（`--version` 等非交互命令）+ socket API
  调用日志 + shim 记录；数据面 = 独立 echo 进程（同容器后台进程，简单可靠，
  不引入第二容器）。
- **用户态 sshd**：容器内以普通用户（或容器 root，效果等同无特权环境下的用户态）
  跑 `sshd -D` 监听 127.0.0.1:22022，专用 host key + 专用 sshd_config，公钥登录。
- **绝不出网**：容器不 EXPOSE 端口、不访问外网（cloudflared 二期测试见 C.6）。
- **无人值守**：entrypoint 跑测试脚本，容器退出码即 E2E 结果，ci.sh 直接消费。

### C.2 红线清单（两方案共用，E2E 脚本开工前打印 + CI 哨兵检查）

1. E2E 任何脚本禁止出现对真实 `$HOME` 的 bind/mount（CI 里 grep
   `run-docker.sh|run-bwrap.sh`，`--volume|-v|--bind` 参数值中出现 `$HOME` 或
   `/home/zzjcool` 字面量即 fail）。
2. 禁止读写宿主 `~/.config/herdr`、`~/.local/state/herdr`。
3. 禁止复用/生成 key 到宿主 `~/.ssh`；一切 key 生成在容器/沙箱内。
4. 禁止连接真实 saved machines；ssh_target 只允许 127.0.0.1。
5. 容器不 `-p`/`--publish` 任何端口；bwrap 用 `--unshare-net`。
6. cloudflared 出网测试一律不进默认 E2E（见 C.6）。
7. docker/bwrap 都不可用时 ci.sh 直接 fail，禁止静默跳过 E2E。
8. 宿主 `/usr/bin/herdr` 只读挂载，绝不执行会写宿主状态的操作（挂载前提见 C.4）。

### C.3 主方案：docker 容器（archlinux 镜像，自包含单容器）

选择**单容器自包含**（不用 compose）：一个镜像一个 entrypoint，build 一次反复用，
ci.sh 调用最简单可靠。

**scripts/e2e/Dockerfile（冻结骨架）**：

```dockerfile
FROM docker.io/library/archlinux:latest

# 基础依赖：openssh（sshd+ssh 客户端）、jq、nc、iproute（lo up 不需要——容器 lo 默认 up）
RUN pacman -Syu --noconfirm openssh jq gnu-netcat inetutils bash coreutils

# 非 root 测试用户（贴近真实运行环境）
RUN useradd -m -s /bin/bash fwduser

WORKDIR /plugin
# 插件源码由 run-docker.sh 在 docker run 时 bind mount 只读注入（开发迭代无需重 build）
# ENTRYPOINT 跑容器内测试主体
COPY scripts/e2e/run-inside.sh /usr/local/bin/run-inside.sh
ENTRYPOINT ["/usr/local/bin/run-inside.sh"]
```

**scripts/e2e/run-docker.sh（冻结骨架）**：

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
PROJ="$(cd "$(dirname "$0")/../.." && pwd)"
IMAGE="herdr-forward-e2e:local"

docker build -f "$PROJ/scripts/e2e/Dockerfile" -t "$IMAGE" "$PROJ"

# herdr 二进制挂载分支（见 C.4 假设#6）：
#   可行：宿主 herdr 动态链接依赖与 arch 容器兼容 -> 只读挂载进容器
#   不可行：容器内无 herdr，E2E 走纯 bash 层 + shim
HERDR_MOUNT=()
if [[ -x /usr/bin/herdr ]] && docker run --rm -v /usr/bin/herdr:/usr/local/bin/herdr:ro \
     "$IMAGE" bash -c 'herdr --version' >/dev/null 2>&1; then
  HERDR_MOUNT=(-v /usr/bin/herdr:/usr/local/bin/herdr:ro)
fi

docker run --rm \
  "${HERDR_MOUNT[@]}" \
  -v "$PROJ":/plugin-src:ro \
  -e HERDR_E2E_MODE="${#HERDR_MOUNT[@]}" \
  "$IMAGE" bash /usr/local/bin/run-inside.sh
# 容器退出码即 E2E 结果，直接透传给 ci.sh
```

**scripts/e2e/run-inside.sh（容器内测试主体，冻结骨架）**：

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
source /plugin-src/tests/lib/assertions.sh

# 0) 准备：源码复制到可写区 + 假 HOME
cp -r /plugin-src /work
export HOME=/home/fwduser
export HERDR_PLUGIN_STATE_DIR="$HOME/.local/state/herdr-forward"
export HERDR_PLUGIN_CONFIG_DIR="$HOME/.config/herdr-forward"
mkdir -p "$HERDR_PLUGIN_STATE_DIR" "$HERDR_PLUGIN_CONFIG_DIR" "$HOME/.ssh"

# 1) 用户态 sshd：专用 host key + client key + authorized_keys（全在容器内生成）
ssh-keygen -q -t ed25519 -N '' -f "$HOME/.ssh/hostkey"
ssh-keygen -q -t ed25519 -N '' -f "$HOME/.ssh/id_ed25519"
cp "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/authorized_keys"
cat > "$HOME/sshd_config" <<EOF
Port 22022
ListenAddress 127.0.0.1
HostKey $HOME/.ssh/hostkey
UsePAM no
PasswordAuthentication no
PubkeyAuthentication yes
StrictModes no
AuthorizedKeysFile $HOME/.ssh/authorized_keys
LogLevel DEBUG1
EOF
/usr/bin/sshd -D -e -f "$HOME/sshd_config" &
SSHD_PID=$!
trap 'kill $SSHD_PID ${ECHO_PID:-} 2>/dev/null' EXIT

# 2) 远端 echo 服务（"远程机器上的服务"）
tcp_serve_once_bg 9443 &      # common.sh 回显 helper；或 while nc -l 循环
ECHO_PID=$!

# 3) 兜底 machine 映射（EndpointCatalog 不可用时的一期正式路径）
printf '[machines.sandbox]\nssh_target = "fwduser@127.0.0.1:22022"\n' \
  > "$HERDR_PLUGIN_CONFIG_DIR/machines.toml"

# 4) herdr 层验证（模式 A：真二进制已挂载）
if [[ "${HERDR_E2E_MODE:-0}" == 1 ]]; then
  t_match "herdr" "$(herdr --version 2>&1 | head -1)"   # 非 TUI 命令，CLI 层验证
  t_file_absent "$HOME/.config/herdr"                   # 我们的 E2E 没碰真 herdr 配置目录（负面断言）
fi

# 5) 插件全链路（bash 层，主断言集）
cd /work
t_exit_ok 0 $(run bin/forward add 13000:9443 --machine sandbox; echo $?)
t_eq "up" "$(jq -r '.forwards[0].status' "$HERDR_PLUGIN_STATE_DIR/forwards.json")"
t_eq "pong" "$(printf 'ping' | nc -q 2 127.0.0.1 13000)"     # 数据面回环经 ssh -L
bin/forward list --oneline | grep -q '⇅13000'
bin/forward doctor
kill $ECHO_PID 2>/dev/null; sleep 1
bin/forward doctor --fix
t_eq "down" "$(jq -r '.forwards[0].status' "$HERDR_PLUGIN_STATE_DIR/forwards.json")"
t_exit_ok 0 $(run bin/forward remove f-13000; echo $?)
t_eq "0" "$(jq '.forwards | length' "$HERDR_PLUGIN_STATE_DIR/forwards.json")"
t_no_zombie_ssh
t_done
```

### C.4 herdr 二进制 glibc 依赖风险与降级分支

宿主 `/usr/bin/herdr` 是动态链接二进制，挂载进 arch 容器需 glibc/依赖库兼容。
**两层降级**写死在 run-docker.sh（骨架中已体现）：

- **模式 A（首选）**：`docker run -v /usr/bin/herdr:/usr/local/bin/herdr:ro` 挂宿主
  二进制，前置探测 `herdr --version` 能否在容器内跑（archlinux:latest 与宿主同为
  rolling glibc，成功率较高，但 CI 必须实测探测而非假设）。模式 A 下容器内验证
  herdr CLI 层（`--version`、非交互命令），并确认 herdr 在假 HOME 下不落任何
  宿主可见副作用。
- **模式 B（降级）**：二进制跑不起来（glibc 版本不匹配、依赖 soname 缺失、或 musl
  发行版镜像）→ 容器内不装 herdr，**只跑 bash 层完整断言集**（步骤 5 全量），
  herdr 集成降为**宿主一次性手动 smoke**（`herdr plugin link` + `reload-config` +
  manifest 被接受 + tab bar 出现 + shim 日志验证 `notify_toast` 调用），结果记入
  §G 假设清单，不进 CI。
- 依赖太复杂时**不追求容器内跑真 herdr**——herdr 是 TUI 程序，E2E 里本来就不跑其
  TUI；插件与 herdr 的真实耦合点（manifest schema、link、notification socket）
  用「宿主手动 smoke + manifest TOML 被 herdr 接受」覆盖即可。

### C.5 降级备选：bwrap（无 docker 环境，压缩保留）

结构与本文 v1 草案相同，要点：`--unshare-user --uid 0 --unshare-net --unshare-pid
--unshare-uts --die-with-parent`，`--ro-bind /usr /usr`（复用宿主 ssh/sshd/jq），
假 HOME bind 到 tmpfs，可写区仅沙箱 root；沙箱内 `ip link set lo up` + 用户态 sshd
高端口 + nc 回环，断言集与 C.3 步骤 5 完全一致（同一份 run-inside.sh 逻辑，环境
探测分支）。run-bwrap.sh 骨架沿用：mktemp 沙箱根 → 生成一次性 key → bwrap 注入
env（HOME/XDG_*/HERDR_PLUGIN_*）→ 执行同构测试脚本。红线：绝不 bind 真实 $HOME。

### C.6 cloudflared（二期）E2E 约定

容器无外网（不 EXPOSE、无 `--network` 出网需求），quick tunnel 必然失败——这是
特性不是缺陷：二期 E2E 只测「cloudflared 缺失/失败时 publish 报错友好、状态正确
记 down、unpublish 幂等」；真实出网验证为 opt-in（`HERDR_E2E_ONLINE=1` 手动跑，
不进 CI）。

## D. 任务拆解（TDD 顺序，3 worker 并行）

写冲突规则：每文件唯一 writer；`tests/lib/assertions.sh`、`tests/run.sh`、
`scripts/ci.sh`、`scripts/e2e/*` 归 T0。**每个任务的第一步都是先写失败测试（红），
实现让测试变绿后才算交付。**

```
T0 (串行, 1 worker, ~半天)
 └─ T1 状态层+CLI 核心  ──┬─ 可并行
 └─ T2 隧道管理+doctor ──┤   (T2 硬依赖 = T1 首交付的 lib/state.sh 骨架, <2h)
 └─ T3 展示层+herdr 集成 ──┘
T4 (串行收尾, 主 agent 或任一 worker)
```

| 任务 | 归属文件（唯一 writer） | 依赖 | TDD 顺序 | 验收标准 |
|---|---|---|---|---|
| **T0 测试地基 + E2E 容器** | tests/lib/assertions.sh、tests/run.sh、scripts/ci.sh、scripts/e2e/{Dockerfile,run-docker.sh,run-inside.sh,run-bwrap.sh} | 无 | ①断言库自测（红：空实现→绿：实现）②ci.sh 骨架对空 lib 报红、对空测试绿 ③build E2E 镜像 + 容器内 sshd/nc 回环空转探通（C.4 模式 A/B 探测定型） | `bash tests/run.sh unit` 自测绿；`bash scripts/e2e/run-docker.sh` 容器内 sshd 起来 + `nc 127.0.0.1 22022` TCP 握手 + 回显断言绿；docker 不可用路径跑 run-bwrap.sh 绿；§G 假设#6/#7 打勾或标注降级 |
| **T1 状态层 + CLI 核心** | lib/common.sh、lib/state.sh、bin/forward、tests/unit/{test_common,test_state,test_cli}.sh、tests/fixtures/* | T0 | fixture 先行 → state_load/save（原子写、损坏容错）→ forward_add/remove/get/list_json → bin/forward dispatch + `add --ssh-target` + `list --json` | unit 全绿；损坏 JSON 容错用例绿；重复端口 die 2 用例绿；shellcheck/shfmt 干净；**首交付物 lib/state.sh 骨架（A.3 签名）解锁 T2** |
| **T2 隧道管理 + doctor + machine 解析** | lib/tunnel.sh、lib/machine.sh、lib/notify.sh、tests/unit/{test_tunnel_args,test_machine}.sh、tests/integration/{test_sshd_roundtrip,test_doctor}.sh | T0 + T1 的 state.sh 骨架 | tunnel 参数拼装单测（红→绿）→ machine.toml 解析单测 → 集成：本机用户态 sshd（TMPDIR host key、22022+随机端口）→ tunnel_start/stop/alive/probe → doctor --fix/--prune；EndpointCatalog socket 路径单测 mock，真调用留宿主 smoke | integration：nc 回环经隧道数据验证绿；kill sshd 后 doctor --fix 修 down 绿；`t_no_zombie_ssh` 绿；machine 解析/失败 die 4 用例绿 |
| **T3 展示层 + herdr 集成** | herdr-plugin.toml、scripts/install-tabbar.sh、tests/unit/{test_oneline,test_install_tabbar,test_link_pattern}.sh、README 安装章节 | T0 + T1 的 `list --oneline` 签名（实现可后交，按契约 stub） | oneline 四场景单测（空/单/多/>6 截断）→ link pattern bash regex 同构单测 → installer 对临时 config.toml 副本的幂等插入断言 → 填 manifest | oneline 全场景单测绿；installer 幂等（重复跑不重复插入）；manifest 宿主 `herdr plugin link` 一次性 smoke 被接受 |
| **T4 收尾：全链路 E2E + 发布检查** | docs/、tests/e2e/（补全断言）、PLAN.md 勾验收 | T1+T2+T3 全交付 | 补全 C.3 步骤 4–5 断言到 run-inside.sh → 模式 A/B 各跑一轮 → 对抗式 review（fresh-context pi ×2）→ PLAN 一期验收逐条勾 | `scripts/ci.sh` 一次全绿；§G 清单逐条标注已验证/降级/待宿主 smoke；无僵尸进程残留 |

## E. 开发规范

- **shebang + 严格模式**：所有脚本 `#!/usr/bin/env bash` + `set -Eeuo pipefail`；
  bin/forward 额外 `IFS=$'\n\t'`。
- **shellcheck**：`-S style -o all` 全开，零抑制；确需抑制必须行内注释写原因。
- **shfmt**：`-ln bash -i 2`，commit 前 `-w`。
- **错误处理**：可预期失败走 `die <code> <msg>`，退出码表见 A.3；用户可见错误必须
  含「下一步该做什么」。
- **原子写**：状态文件一律 `atomic_write`（同分区 mktemp + `mv -f`）；禁止 `>
  forwards.json` 直写。
- **日志**：只写 `$HERDR_PLUGIN_STATE_DIR/logs/forward.log`（env 缺失时 stderr），
  带时间戳与级别；>1MB 截断保留后半（common.sh 实现）。
- **禁交互**：不 read stdin、不等确认；确认语义用 `--pick`/`--yes` 显式 flag。
  禁 `sudo`、禁写 `.env/.git/node_modules`。
- **commit 规范**：conventional commits（feat/fix/test/docs/refactor/chore），
  一个红→绿循环一个 commit，message 尾注 `tests: N added, ci: green`。
- **进程纪律**：后台进程一律 `trap ... EXIT` 清理；隧道 fork 用 `setsid` + 记 pid，
  绝不留孤儿 ssh。
- **外部命令**：一律 `require_cmd` 预检；ssh 调用必带 `-o BatchMode=yes -o
  ExitOnForwardFailure=yes`，禁止交互式 ssh。

## F. 风险与降级预案

| # | 风险 | 概率 | 降级预案 |
|---|---|---|---|
| 1 | herdr TUI 无 TTY 起不来 | 高（预期） | **主案已绕开**：E2E 不跑 TUI；herdr 验证 = 容器内 CLI（模式 A）或宿主一次性手动 smoke（模式 B）+ shim/日志验证 |
| 2 | 宿主 herdr 二进制 glibc 依赖与容器不兼容 | 中 | C.4 模式 B：容器只跑 bash 层，herdr 集成降为宿主手动 smoke；ci.sh 不因模式 B 变红 |
| 3 | 容器内非 root 跑 sshd 的权限问题（host key 权限、/var/empty） | 中 | sshd_config 明确 `HostKey`/`AuthorizedKeysFile` 指向用户可写路径；`StrictModes no`（沙箱一次性 key 可接受）；仍失败 → T0 探通前以 root 跑 sshd（容器 root ≠ 宿主特权，不违反红线） |
| 4 | EndpointCatalog 读不到（假设#1） | 中 | machine.sh 的 machines.toml 兜底即正式路径；E2E 主线走兜底；socket 路径单测 mock |
| 5 | docker daemon 环境未来又不可用 | 低 | ci.sh 自动降级 run-bwrap.sh（B.4 步骤 5）；两者都不可用 → fail 并输出指引，绝不静默跳过 |
| 6 | archlinux:latest 滚动更新破坏 E2E 镜像 | 中 | Dockerfile 不锁死 patch 版本但 run-docker.sh 每次重建；破坏时按 B.3 纪律修 Dockerfile（红→绿同样适用基础设施脚本） |

## G. 实现期待验证假设清单（并入 RESEARCH §3 五条）

| # | 假设 | 验证方式 |
|---|---|---|
| 1 | 插件能否经 socket API 读 EndpointCatalog/SavedSshEndpoint 拿 saved machine 的 ssh target | 宿主一次性 smoke：`HERDR_SOCKET_PATH` 下发 catalog 查询；不可用 → machines.toml 兜底为正式路径，**E2E 容器内验证兜底解析全流程** |
| 2 | manifest `command` 里 `%{plugin_root}` 模板变量是否支持 | 宿主 smoke：填模板变量 link 后 reload-config，观察 action 执行；不支持 → 包装脚本读 `HERDR_PLUGIN_ROOT` env（RESEARCH §2.2 确认有传） |
| 3 | 能否复用 herdr per-attach SSH control socket | 宿主 smoke：attach 后找 control socket 尝试 `ssh -O check`；不可复用（预期如此）→ 按冻结方案自建 ControlMaster，仅文档记录 |
| 4 | link_handlers regex 对无 scheme 的 `localhost:3000` 是否命中 | 宿主 smoke：pane echo 观察 Ctrl+click；单测层先验证我们 pattern 的 bash regex 同构命中；不命中 → pattern 已含 `(?:https?://)?` 前缀备好 |
| 5 | tab_bar_right 输出宽度/ANSI 截断行为 | 宿主 smoke：构造 8 个映射看是否截断；截断 → oneline 上限 6 个 + `+N`（已冻结进 A.3 契约，先写单测） |
| 6 | docker 容器内挂载宿主 herdr 可跑（glibc 兼容）+ 假 HOME 隔离成立 | **T0 E2E spike（C.4 模式 A/B 探测）**：`docker run -v /usr/bin/herdr:ro ... herdr --version` + 容器内断言 herdr 状态落点在假 HOME |
| 7 | 容器内用户态 sshd + 公钥登录可行 | **T0 E2E spike**：run-inside.sh 步骤 1–2 空转探通（sshd 起来 + nc 握手 + 回显） |
| 8 | herdr `plugin link` 是否要求 TTY | 宿主 smoke（F-1 关联）：`herdr plugin link < /dev/null` 观察行为 |
