# tests/difftest — Bash ↔ Go 差分测试 harness

PLAN-GO-MIGRATION §6 Phase 1 / §10 W1 的交付物。目的：**在同一输入上把生产 bash 实现与
Go 实现逐字节比对**，为「迁移期零行为变化」提供实测证据，并守住 PLAN R1 风险
（jq → `encoding/json` 的键序/缩进/`null` 形态漂移会静默破坏 C4 消费者）。

## 用法

```bash
bash tests/difftest/run.sh
```

- 退出码 `0` = 全绿；`1` = 有 `not ok`。
- 依赖：`jq`（bash 侧 `lib/state.sh` 的硬依赖）、`go` 工具链。缺任一个都**硬失败**，
  不静默跳过。
- 输出为 TAP 风格，与 `tests/run.sh` 的断言风格一致（`ok N - ...` / `# PASS/FAIL`）。

> 注意：本 harness 与 `tests/run.sh` 的 `unit|integration|e2e` 层**不是**同一入口。
> `tests/difftest/` 是 Phase 1 新增的独立层，已由 W4 挂进 `scripts/ci.sh` 的
> `0b/6 difftest` 段（作为独立门，同时也是 E2E 容器内的一段：`run-inside.sh` B2）。

## 结构

| 文件 | 角色 |
|---|---|
| `run.sh` | 驱动器：装夹具、分别跑两侧、逐字节比对、汇总 TAP |
| `bashside.sh` | bash 侧对位入口：`source lib/common.sh lib/state.sh`，转调真实生产函数 |
| `fixtures/full.two.json` | schema 完整（含 `mode`）的两条 tunnel 记录语料 |
| `fixtures/mix.client.tunnel.json` | 一条 tunnel + 一条 client（含 `status:starting`） |
| `fixtures/many.up.json` | 8 条 `up` tunnel 记录（验 `--oneline` 的 `+N` 截断） |
| `../fixtures/forwards.*.json` | 仓库既有 4 个夹具（只读复用，PLAN §8 要求） |

`bashside.sh` 刻意**不复制**任何逻辑 —— 它就是生产 bash 的函数调用，否则差分测试
失去意义（复制品会与生产漂移，测出的「一致」是假象）。

## Go 侧接线（两套形态，结果等价）

`run.sh` 按以下顺序决定 Go 侧调用方式：

1. **优先** `bin/forward-go internal difftest <case>` —— 若 `bin/forward-go` 能对
   `internal difftest selftest` 回 `difftest-ok`（即 W4 已把 dispatch 接上），
   被测的就是最终产物的同一条代码路径。
2. **回退** 到 W1 自带的开发驱动器：`go build -o <tmp> ./internal/difftest/cmd`。

两套都是同一个 `difftest.Main`（`go/internal/difftest/`），因此结果等价。

> 为什么需要「回退」这套：`go/cmd/` 与 `go/internal/cli/` 是 W4 的 writer 范围
> （PLAN §10 写冲突规则），W1 不能往里加子命令。把驱动器放进
> `go/internal/difftest/` 目录内部，就完全落在 W1 的唯一 writer 范围内。
> W4 接线后只需在 `cli.Main` 加一行 `case "internal": return difftest.Main(args)`
> （本包已自带 `internal` / `difftest` 前缀跳过，无需改本包）。

## 覆盖的用例（426 条）

| 组 | 用例 | 比对方式 |
|---|---|---|
| 1 | `state_load` × 5 个 fixture（corrupt/empty/missing_fields/multi/valid）+ 文件不存在 | 归一化后 `jq -S -c` 语义比对 |
| 2 | `state_save` 往返（Load→Save）× 5 个 fixture | **逐字节** + 文件权限 0600 |
| 3 | `probe_payload` 三态（up/degraded/down）+ 拒连 | 同一真实监听 socket 上跑两侧，stdout 逐字符 |
| 4 | `add` / `add` 重复端口 / `remove` / `remove` 不存在 / `set-status` / `set-status` 非法值 | 落盘**逐字节** + 退出码（0/2/3/1） |
| 5 | legacy 无 `mode` 记录的既定偏差 | 显式钉住形态 + 归一化后语义一致 |
| 6 | **CLI `list`**（W4）：table/`--json`/`--oneline` × 双 tunnel / 空状态 / 文件不存在 / client 离线；client 在线（up·down·未上报）；本机 bridge 行；`>6` 截断；`FORWARD_STATE_VERSION=2`；损坏记录；参数错误（rc + 去时间戳 stderr） | **逐字节** stdout + 退出码 |
| 7 | **CLI `ports`**（W4）：table/`--json`/`--json extra`/多余参数，两侧都屏蔽 `ss`/`lsof` 同读 `/proc` | **逐字节** stdout + 退出码 |
| 8 | **CLI `help` / 未知子命令 / 缺子命令**（W4） | **逐字节** stdout（usage 文本冻结）+ 退出码 |
| 9 | **CLI `add` / `remove` / `doctor` / `publish` / `unpublish`**（Phase 2）：add 参数校验矩阵（缺/非法 spec、端口越界、未知 flag、多余位置参数、缺目标、machine 无法解析、`--client` 端口下限与互斥）；remove（缺 id/未知/多余/不存在/`--pick`/`--all`）；publish · unpublish（恒 9，含多余参数）；doctor 参数错误 + 死记录报告/`--fix`/`--prune`/`fix+prune` + 真监听 socket 的 up·degraded·stale 修正 + client 记录三态不动 | stdout + rc（参数错误另比去时间戳 stderr）+ **落盘状态逐字节**（`created_unix` 掩掉） |
| 10 | **tunnel ssh argv**（Phase 2）：`lib/tunnel.sh tunnel_ssh_args` vs `internal/tunnel.SSHArgs` —— 常规/缺省端口/方括号 IPv6（含无端口）/尾部冒号/非数字端口后缀/远端规格可变/state 目录含 `%`（percent 转义） | argv **逐行** |
| 11 | **HF1 行协议**（Phase 3）：`hf-fmt` 编码（HELLO/SYNC 空与多条/含非法条目/OPEN/STATUS 无·带 reason/PING）× `hf-parse` 解析（合法矩阵 + 非 HF1 前缀/未知动作/空行/仅前缀/STATUS 缺字段/注入尝试）× `hf-valid` C6 边界（合法/端口下限/前导零/id 不一致/越界/非数字/路径穿越）× `ssh-dest`（别名/`user@host`/`host:port`→URI/`ssh://`/`[v6]:port`/裸 IPv6）× `remote-cmd`（含空格与单引号）× `bridge-ssh-args`（信任边界 argv） | **逐字节** stdout + 退出码 |
| 12 | **machines 合并视图 + 激活 schema**（Phase 3）：`view-json`（active/activated/local/inactive + orphan）× `active` / `has`（命中·未命中·orphan）/ `resolve`（id·label·大小写不敏感·orphan label·不存在）× **空状态**（无 activated-machines.json） | **逐字节** stdout + 退出码 |
| 13 | **端口字面量边界矩阵**（Phase 3）：lp ∈ {1024,1025,9999,10000,65535,99999,0,80,102,1023}、rp ∈ {1,22,80,1024,65535,65536}、前导零 {01024,05173,010234}、六位端口 | **逐字节** stdout + 退出码 |

组 3 的 probe 用例用的是 Go 侧 `serve reply|silent|close` 起的**真实**监听 socket
（`net.Listen("tcp","127.0.0.1:0")`，端口由内核分配后打印，无竞态），bash 与 Go
两侧探测的是**同一个**服务 —— 这才是真差分。

### 组 9/10 的两侧接线（Phase 2 补齐的部分）

* **组 9 的 `HERDR_PLUGIN_CONFIG_DIR`**：`add --machine …` 会读 machines.toml，两侧各指到自己的
  临时 config 目录，绝不碰用户真实配置。
* **组 9 的状态比对**：两侧用**不同时刻**的真实时钟写 `created_unix`，故比对前把该字段归零
  （`masked_state`），其余 11 个字段逐字节比。
* **组 9 的 doctor 夹具**：down/degraded 用组 3 起的**真实监听 socket**（reply 服务 => up；
  silent 服务 => degraded）；活记录用当前测试进程的 pid 当 master（`kill -0` 判定为活）。
* **组 10 的隧道 argv**：bash 侧 `bashside.sh tunnel-args` 直接调 `lib/tunnel.sh` 的
  `tunnel_ssh_args`（生产函数）；Go 侧 `internal difftest tunnel-args` 调 `tunnel.SSHArgs`。
  两侧都不 spawn ssh。真实隧道行为（起 master / -O exit / reap socket / 无残留进程）走 E2E 与
  `tests/difftest/phase2-go-path.sh`。

### 真实隧道行为由谁裁判（Phase 2）

| 断言 | 裁判 |
|---|---|
| add → status=up + master pid 活 + ctl socket 存在 | E2E A2 段（docker）+ `phase2-go-path.sh` |
| 经 `ssh -L` 的数据面回环 | E2E A2 段（nc）+ `phase2-go-path.sh`（无 nc 时 `/dev/tcp`） |
| doctor `--fix` 修 down、`--prune` 不误删活隧道 | E2E A2 段 + integration `test_cli_full_cycle.sh` + `phase2-go-path.sh` |
| `--prune` 真 reap 死隧道（删 stale control socket） | integration `test_cli_full_cycle.sh` + `phase2-go-path.sh` |
| remove 后无监听 / 无 ctl socket / `t_no_zombie_ssh` | E2E A2 段 + `phase2-go-path.sh` |

`tests/difftest/phase2-go-path.sh` 不在 `tests/run.sh` 的判据内（文件名不是 `test_*.sh`），
是**可复现的证据脚本**：它在隔离 HOME 里起真 sshd + echo 服务，用「记录型 shim」替换
`bin/forward-go`（记录一行后 exec 真二进制），因此能同时断言「dispatch 到了 Go」与
「Go 实现的行为」。Phase 3 起它同时钉住 dispatch 边界的翻转：`add --client` 与
`machines`/`bridge`/`open-url` **必须**被路由到 Go，而 `bootstrap`/`help` 仍留 bash。

### 组 11/12 的两侧接线（Phase 3）

* **bash 侧**：`tests/difftest/phase3-bashside.sh` —— 与 `bashside.sh` 同一纪律，只
  `source` 真 `lib/bridge.sh` + `lib/machines.sh` + `lib/ssh-probe.sh` 后转调生产函数，
  **不复制**任何逻辑。
* **Go 侧**：`bin/forward-go internal difftest hf-parse|hf-fmt|hf-valid|ssh-dest|remote-cmd|
  bridge-ssh-args|bridge-active|probe-kv`（`go/internal/difftest/phase3.go`）。
* **组 12 的 herdr 列表**：两侧都用同一份假 `herdr`（`machine list --json` 回放固定 JSON），
  经 `HERDR_BIN_PATH` 注入；激活状态文件由 `seed_activation` 铺进各自的状态目录。

### HF1 两侧同切的证据（Phase 3）

| 断言 | 裁判 |
|---|---|
| `forward bridge serve` 走 Go | `phase3-go-path.sh` 第 1 段（记录型 shim 的 marker） |
| `forward bridge run` 走 Go | `phase3-go-path.sh` 第 1 段 |
| HELLO/SYNC/STATUS 真协议往返（含「期望集合变化 → 推送新 SYNC」） | `phase3-go-path.sh` 第 2 段（真 Go serve 进程经 FIFO 驱动） |
| C6 边界在**真实 serve 进程**上拒绝越界 id/端口/前导零 | `phase3-go-path.sh` 第 2 段 |
| OPEN 只在端口已进 SYNC 后转发 | `phase3-go-path.sh` 第 3 段 |
| 退避状态机（127 → retrying + next_retry_unix） | `phase3-go-path.sh` 第 4 段 |
| 真 ssh 的桥接数据面（loopback-only / 端口占用自愈 / 断线重连） | integration `test_bridge_roundtrip.sh` + 两机 E2E |

### 组 6/7/8 的两侧接线（为什么这么搭，Phase 1 的原始设计）

* **Go 侧**：现场 `go build ./cmd/forward` 到 `${TMP}/forward-go`（仓库的 `bin/` 绝不落产物）。
  比的是**用户可见 CLI** 的字节，而不是 internal 层的函数输出。
* **bash 侧**：把 `bin/forward` 拷成 staged root（`lib/` 用符号链接），**不带** `forward-go`，
  于是同一份脚本走纯 bash 路径（`bin/forward` 只对 `list|ports` 做条件 exec）。
* **`ss` 屏蔽（组 7）**：bash 的 `ports_listening_json` 优先用 `ss`（能拿到进程名），而 Go 侧读
  `/proc` 拿不到 —— 这是已知偏离（W4 报告与 PLAN 的偏离记录均登记）。组 7 给 bash 侧一个
  只含 symlink 的 PATH 农场（白名单里没有 `ss`/`lsof`），两侧因此同源（都读 `/proc`），
  比的是「同一数据源下的输出」。监听集合会随环境变化，故组 7 有「不一致则重试一次」的抖动防护。

## 已知偏差（有意保留，已在组 5 断言）

**legacy 无 `mode` 记录**：bash 的 `state_load` 是 `jq -c '.forwards'` 原样透传，
写回时不补 `mode`；Go 的冻结类型化模型（`state.Forward` 含 `Mode` 字段）会在
Load→Save 往返中**物化** `mode:"tunnel"`。

- 两者语义等价：消费侧（`bin/forward`、`lib/bridge.sh`）统一按 `.mode // "tunnel"`
  处理，`mode:"tunnel"` 与「无 mode 键」同义。
- 组 5 同时断言：① bash 写回无 `mode` 键；② Go 写回物化 `tunnel`；
  ③ 归一化后两侧逐字节一致；④ 除 `mode` 外其余字段逐键一致。
- 这样任何一侧的**真实**漂移（不止 mode）都会立刻变红，而不是被归一化吞掉。

其余字段（缺 `id`/`status`/`remote_host` 等）同理：Go 用零值填充，bash 原样透传 ——
组 1/2 的归一化比对已把这一层显式拉平（`bashside.sh` 的 `DIFFTEST_NORMALIZE`
与 `internal/state.normalize` 一一对应）。

## 与 bug 打过的一次真实交手（留痕）

首版 `run.sh` 忘了给 Go 侧注入 `HERDR_PLUGIN_STATE_DIR`，于是 Go 端回退到
`~/.local/state/herdr-forward`，把夹具写进了**真实用户目录**，同时让 13 条用例
假红。修法是 `go_side <state_dir>` 每次显式注入 env —— 差分测试必须**完全在临时
目录里跑**，绝不触碰宿主状态。这条纪律现在写在 `go_side` 的注释里。

## golden 字节从哪来

`go/internal/state/state_test.go` 里的 golden 字符串是照抄 bash 实测输出：

```bash
T="$(mktemp -d)"; HERDR_PLUGIN_STATE_DIR="$T" bash -c \
  'source lib/common.sh; source lib/state.sh; forward_add_record "$1"' _ \
  "$(jq -c -n '{local_port:3000,remote_port:9443,ssh_target:"u@h:22",machine:"m",pid:12345,control_socket:"/tmp/ctl",status:"up",created_unix:1790000000}')"
cat "$T/forwards.json"
```

得到 `jq -S -c` 的**紧凑单行**形态（键名字母序递归、`publish` 三 `null`、结尾单换行、
文件 0600）。⚠ 注意：`docs/PLAN-GO-MIGRATION.md` 的 C4 与 §8 文字里写的
「2 空格缩进」与 bash 实测不符（`jq -c` 是紧凑输出）—— 实现以 **bash 实测字节**
为准，文字偏差已在 W1 报告「未决问题」登记。
