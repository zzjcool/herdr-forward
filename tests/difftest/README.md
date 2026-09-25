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
> `tests/difftest/` 是 Phase 1 新增的独立层，由 W4 决定是否挂进 `scripts/ci.sh`
> （PLAN §6 Phase 1 验收里 difftest 是独立门；`scripts/ci.sh` 归 W4/主 agent）。

## 结构

| 文件 | 角色 |
|---|---|
| `run.sh` | 驱动器：装夹具、分别跑两侧、逐字节比对、汇总 TAP |
| `bashside.sh` | bash 侧对位入口：`source lib/common.sh lib/state.sh`，转调真实生产函数 |
| `fixtures/full.two.json` | schema 完整（含 `mode`）的两条记录语料；供需要「bash 自产形态」的用例 |
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

## 覆盖的用例（38 条）

| 组 | 用例 | 比对方式 |
|---|---|---|
| 1 | `state_load` × 5 个 fixture（corrupt/empty/missing_fields/multi/valid）+ 文件不存在 | 归一化后 `jq -S -c` 语义比对 |
| 2 | `state_save` 往返（Load→Save）× 5 个 fixture | **逐字节** + 文件权限 0600 |
| 3 | `probe_payload` 三态（up/degraded/down）+ 拒连 | 同一真实监听 socket 上跑两侧，stdout 逐字符 |
| 4 | `add` / `add` 重复端口 / `remove` / `remove` 不存在 / `set-status` / `set-status` 非法值 | 落盘**逐字节** + 退出码（0/2/3/1） |
| 5 | legacy 无 `mode` 记录的既定偏差 | 显式钉住形态 + 归一化后语义一致 |

probe 用例用的是 Go 侧 `serve reply|silent|close` 起的**真实**监听 socket
（`net.Listen("tcp","127.0.0.1:0")`，端口由内核分配后打印，无竞态），bash 与 Go
两侧探测的是**同一个**服务 —— 这才是真差分。

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
