---

# PLAN-GO-MIGRATION — herdr-forward Bash → Go 渐进式重写实施计划

> 冻结依据：docs/ARCHITECTURE.md（A.2 数据契约 / A.3 函数签名 / A.3.1 探活分级 / A.3.2 machines / A.3.3 桥接）、herdr-plugin.toml、scripts/ci.sh、scripts/e2e/*。任何偏离先改本文再动代码。

## 1. 目标与不做的事

**目标**：全部核心功能由单一 Go 静态二进制（`bin/forward-go`，linux/macos × amd64/arm64）承载；`retired Bash modules` 与 `bin/forward` 的 bash 代码全部删除；`bin/forward` 退化为 ≤5 行 POSIX sh exec shim（保持 manifest/E2E/文档引用路径不变）；GitHub Releases 分发 + postinstall 下载校验；`scripts/e2e` 五套全绿。

**Non-goals**：
- 不换 ssh 库：`ssh -L` 桥接/隧道继续 exec 系统 `ssh` 子进程（保 ~/.ssh/config、agent、known_hosts）
- 不改 herdr 插件机制：manifest 的 actions/panes/build/startup 落点路径不变，`$HERDR_BIN_PATH machine list --json` 继续 exec
- 不做 cloudflared（仍 exit 9 占位）；不动 bin/cli.js（npm 占位包）
- 不重写 E2E 断言集（它是迁移的裁判，只允许增量适配，不许放松）
- macOS Bash 3.2 兼容 hack 不再需要 —— Go 天然跨平台，但 macOS 无 E2E，靠单测 + 手动 smoke 清单兜底

## 2. 冻结契约清单（迁移中一律不变）

| # | 契约 | 内容 |
|---|---|---|
| C1 | CLI argv | 15 个子命令及全部 flag（见 bin/forward usage，1737-1748 行 dispatch） |
| C2 | 退出码 | `0 ok / 2 端口重复 / 3 记录不存在 / 4 machine 解析失败 / 5 隧道失败 / 9 未实现 / 64 用法 / 127 依赖缺失 / 1 激活半成品` |
| C3 | tab bar oneline | `⇅3000⇅5173`，仅 up、升序、>6 条截断 `+N`、纯文本无 ANSI、坏输入 → 空串恒 exit 0 |
| C4 | forwards.json | A.2 schema（version:1 + mode/publish 扩展），损坏 → 空数组 + warn；原子写；**jq 排序格式**（键名字母序；W1 实测修正：bash `state_save` 用 `jq -S -c`，磁盘上是**紧凑单行**而非缩进多行——Go 以 bash 字节为准）——Go 结构体字段序按字母序声明以复刻 |
| C5 | `list --json` / `machines list --json|--short` / `bridge status --json` | 输出形状逐字段不变 |
| C6 | HF1 行协议 | `HELLO/SYNC/OPEN/STATUS/PING` 一行一条，A 侧安全边界（id=f-<lp>、lp∈[1024,65535]、≤32 条、恒 loopback） |
| C7 | 探活三级 | `up/degraded/down`（A.3.1：本地可连≠远端可达，payload marker `herdr-forward-probe`） |
| C8 | activated-machines.json / bridge client-*.json session-*.json | A.3.2/A.3.3 schema |
| C9 | publish/unpublish | exit 9 not implemented |
| C10 | manifest 路径 | `bin/forward` 这个路径永远可执行（最终是 sh shim） |

## 3. 共存策略裁决（主线）

**主线：`bin/forward`（bash）在整个迁移期保持唯一入口，按子命令 dispatch 到 Go 二进制。**

```bash
# bin/forward dispatch 顶部（迁移期增量添加）：
case "${1-}" in
list | ports) exec "${FORWARD_ROOT}/bin/forward-go" "$@" ;;
esac
```

理由：
1. manifest / startup hook / E2E / 用户文档引用的路径**从头到尾只有一个**，永不改 manifest；
2. 回滚 = 删一行 dispatch，bash 实现在 Phase 5 前始终在场；
3. 子命令粒度与 E2E 断言粒度对齐（run-inside.sh 按子命令走全链路），每切一个命令即可跑全套护栏；
4. 否决「Go 实现纯函数层被 bash 调用」：jq 依赖活得最久、双实现共存窗口更长、每次调用多一个进程边界；也否决「Go 直接顶替 bin/forward」：大爆炸，违反用户决策 #3。

**跨语言数据面**：迁移期 bash panel / bash bridge-serve 可能消费 Go 产出的 JSON —— C4/C5/C6 冻结保证互操作；桥接两侧（serve/run）**同 phase 内一起切**，避免 mixed-version 协议偏差无 E2E 覆盖。

## 4. Go 目录布局（映射）

```
go/
├── go.mod / go.sum / vendor/          # 模块 github.com/zzjcool/herdr-forward
├── cmd/forward/main.go                # 入口：os.Exit(cli.Main(os.Args[1:]))
└── internal/
    ├── hfcommon/   # ← retired Bash common module：env 解析、log（轮转 1MB/512KB）、atomic write、exitcode、probe_payload
    ├── state/      # ← retired Bash state module（forwards.json）+ machines/bridge 的状态文件
    ├── render/     # ← retired Bash render module：oneline / 表格
    ├── ports/      # ← retired Bash ports module：/proc/net/tcp{,6}（Linux）；exec lsof（macOS）
    ├── machine/    # ← retired Bash machine module + retired Bash machines module：machines.toml 解析、herdr machine list、激活记录
    ├── tunnel/    # ← retired Bash tunnel module：exec ssh ControlMaster 生命周期、doctor
    ├── notify/     # ← retired Bash notify module：herdr socket toast（1s watchdog）
    ├── bridge/     # ← retired Bash bridge module：HF1 协议编解码 + serve/run 监督者 + 退避重连
    ├── sshprobe/   # ← retired Bash SSH probe module：parse_target / run / plugin 探测
    ├── panel/      # ← retired Bash panel module：watch TUI（备用屏、双缓冲、read 超时刷新）
    └── cli/        # ← bin/forward cmd_* 层：子命令 dispatch、usage、参数校验
```

**依赖纪律**：stdlib 优先；仅允许三个 vendored 依赖 —— `BurntSushi/toml`（machines.toml + herdr config.toml 编辑）、`golang.org/x/term`（panel raw mode）。E2E 容器运行期不出网，`go mod vendor` 必须完整。禁止 gopsutil（macOS 走系统 lsof 即可，减一个重依赖）。

> **Phase 1 并行协调修正**：W2/W3 依赖 `state.Forward` 与 `hfcommon.Health` 类型才能并行编译，故共享类型桩（`go/internal/state/types.go`、`go/internal/hfcommon/health.go`，均按 §5 冻结签名）已由主 agent 预先提交（a1e1150）。W1 拥有这两个文件的后续全权（实现可重构，冻结签名不得变）；W2/W3 只 import，不得修改。

**依赖映射**（用户已验证，落地为）：jq→encoding/json；/dev/tcp/nc→net.Dial（C7 probe 用 `net.DialTimeout`+`SetReadDeadline`）；tcp_serve_once→测试内 net.Listen；setsid 链→`exec.Cmd{SysProcAttr:{Setsid:true}}`（hf_detach_exec 的 perl/python3/nohup 三级兜底全部删除）；timeout→context；/proc/net/tcp 解析→纯 Go（hex 端口/地址、states 0A=LISTEN）；macOS 端口→`exec lsof -nP -iTCP -sTCP:LISTEN`。

## 5. 冻结 Go 接口（worker 不得自行发明）

```go
// internal/hfcommon
type Health int
const (HealthUp Health = iota; HealthDegraded; HealthDown)

func StateDir() string                      // HERDR_PLUGIN_STATE_DIR 优先，回退 ~/.local/state/herdr-forward
func ConfigDir() string
func Log(level, msg string)                 // logs/forward.log，>1MB 轮转保 512KB；warn/error 镜像 stderr
func AtomicWrite(path string, content []byte) error
func ProbePayload(host string, port, timeoutSec int) Health   // C7：发 marker 行，读任意回包
func NowUnix() int64

// internal/state
type Mode string                            // "tunnel"（缺省，旧记录兼容）| "client"
type Forward struct {                       // 字段序 = jq 字母序，json tag 见 C4
    ControlSocket string                    `json:"control_socket"`
    CreatedUnix    int64                    `json:"created_unix"`
    ID             string                    `json:"id"`
    LocalPort      int                       `json:"local_port"`
    Machine        string                    `json:"machine"`
    Mode           Mode                      `json:"mode"`
    Pid            *int                      `json:"pid"`
    Publish        Publish                   `json:"publish"`
    RemoteHost     string                    `json:"remote_host"`
    RemotePort     int                       `json:"remote_port"`
    SshTarget      string                    `json:"ssh_target"`
    Status         string                    `json:"status"`
}
type Publish struct{ Pid *int; URL *string; StartedUnix *int64 } // json: pid,url,started_unix
func FilePath() string
func Load() ([]Forward, error)              // 损坏→warn+空切片，不报错
func Save(fw []Forward) error               // {version:1,forwards:[...]}，jq 同构格式
func Add(f Forward) error                    // local_port 冲突 → ErrDuplicatePort
func Remove(id string) error                 // 不存在 → ErrNotFound
func SetStatus(id, status string) error

// internal/render
func Oneline(fw []Forward) string            // C3；坏输入由 Load 已归一
func Table(fw []Forward, nowUnix int64) string

// internal/ports
type Listener struct{ Port int; Addr, Process string }
func List() ([]Listener, error)              // 只列 127.0.0.1/::1/通配 且 ≥1024；剥 [ ] %iface

// internal/machine
func NormalizeSshTarget(t string) (string, error)   // 补 :22，保 IPv6 方括号
func ResolveFromToml(label string) (string, error)  // machines.toml；失败=ErrMachineUnresolved
func HerdrMachineListJSON(binPath string) []byte    // 缺/败/非 JSON → "[]" + warn，不 die

// internal/tunnel
type Manager struct{ /* state dir, control dir */ }
func NewManager() *Manager
func (m *Manager) Start(id string, lp int, rh string, rp int, sshTarget string) (pid int, err error) // die 5 语义
func (m *Manager) Stop(id string) error        // ssh -O exit + kill 兜底 + reap socket
func (m *Manager) Reap(id string, pid int) error
func Alive(pid int) bool
func (m *Manager) Probe(lp int) Health          // = hfcommon.ProbePayload("127.0.0.1", lp, 2)
func (m *Manager) Health(id string, pid, lp int) Health
func (m *Manager) Doctor(fix, prune bool) error // A.3.1 诚实分级；client 记录跳过

// internal/bridge（HF1）
type Msg interface{ String() string }
type Hello struct{ Host string; Labels []string }
type Sync struct{ Forwards []SyncEntry }        // id:lp:rp
type Open struct{ URL string }
type Status struct{ ID, State, Reason string }
type Ping struct{}
func ParseLine(line string) (Msg, error)
func ValidateForward(e SyncEntry) error         // C6 全部安全边界
func Serve(ctx context.Context) error           // forward bridge serve
func RunSupervisor(ctx context.Context, machineID string) error  // forward bridge run；退避 2s→60s

// internal/cli
func Main(args []string) int                    // 返回值即进程退出码（C2）
```

## 6. 阶段拆分（6 个 phase）

### Phase 0 — Go 脚手架 + 发布流水线空转（无行为变化）
- **文件**：`go/{go.mod,cmd/forward/main.go,internal/*}` 空骨架、`Makefile`（build/lint/test/vendor-check，build 输出到 `bin/forward-go`）、`.goreleaser.yml`、`.github/workflows/{ci.yml,release.yml}`、`.gitignore`（+`bin/forward-go`、`dist/`）、`scripts/ci.sh`（新增第 0 段 `go vet && go build && go test ./go/...`，go 缺失 → fail，LAX 降级同现有语义）、`scripts/e2e/Dockerfile`（pacman 列表 + `go`）。
- **依赖**：无。
- **验收**：`bash scripts/ci.sh` 6/6+go 段全绿（bash 行为零变化）；`goreleaser build --snapshot` 产出 4 平台产物 + checksums.txt；容器内 `go build` 成功（vendor 完整、无网络构建）。
- **回滚点**：tag `go-mig/phase0`。

### Phase 1 — 纯函数/只读层：state、render、ports、machine 解析 → 切 `list`、`ports`
- **文件**：`internal/{hfcommon,state,render,ports,machine,cli}`；`bin/forward` 加 dispatch 行 `list|ports)`；Go 单测（复用 `tests/fixtures/forwards.*.json` 为 golden）；`tests/difftest/run.sh`（差分测试 harness：同一 fixture 上 bash 函数 vs Go 输出逐字节比对）。
- **依赖**：Phase 0。
- **验收**：`go test ./go/...`（覆盖下方 §8 清单）；difftest 对 render_oneline / state_load / ports 过滤全绿；`bash scripts/ci.sh` 全绿（docker E2E 内 `list --oneline` 真输出 `⇅<port>`、`ports` 列表与 bash 版一致）；tab bar 秒回性不变（run-inside 内加耗时断言 <1s）。
- **回滚点**：删 dispatch 一行。
- **可并行**：4 worker，见 §10。

### Phase 2 — 状态写入 + 隧道生命周期 → 切 `add`、`remove`、`doctor`（含 `--fix/--prune`）、`publish/unpublish`（仍 exit 9）、notify
- **文件**：`internal/{tunnel,notify}` + cli 对应命令；tunnel 参数拼装 golden argv 单测（对标 `tests/unit/test_tunnel_args.sh`）；`bin/forward` dispatch 行扩为 `list|ports|add|remove|doctor|publish|unpublish)`。
- **依赖**：Phase 1（state/hfcommon）。
- **验收**：全套 E2E 绿——重点：E2E 容器内 add→up、`nc` 经 ssh -L 回包、doctor --fix 修 down、--prune reap、`t_no_zombie_ssh`、remove 后无监听无 control socket；`machines activate` 走的 `add --client` 路径此刻仍由 bash bridge 承担（未切，继续走 bash 分支，双实现共存由 C4/C5 兜住）。
- **风险点**：probe_payload 三级语义（C7）与 ControlMaster argv 精确复刻。

### Phase 3 — machines + 桥接 → 切 `machines {list,activate,deactivate,doctor}`、`bridge {up,down,status,serve,run}`、`open-url`、`add --client`
- **文件**：`internal/{machine(激活/视图),bridge,sshprobe}`；bridge serve 与 run **同一 phase 一起切**；`tests/difftest` 加 HF1 编解码差分。
- **依赖**：Phase 2。
- **验收**：`bash scripts/ci.sh` 全绿，**含 `run-two-machines.sh`**（真 herdr TUI + tmux 按键全流程：激活→prefix+f→⇅5173→Ctrl+click→断网重连→server 重启拉回桥接）；`tests/integration/test_bridge_roundtrip.sh` 绿（退避重连、loopback-only、端口占用自愈、OPEN 校验）。
- **风险点**：HF1 混合版本窗口（bash serve vs Go run）——本 phase 结束即消除；两机 E2E 是唯一裁判。

### Phase 4 — 交互面板 + 安装器 Go 化 → 切 `watch`、`bootstrap`、installers
- **文件**：`internal/panel`（备用屏 \033[?1049h 进出、双缓冲、read 超时=刷新、EOF 退出、非 TTY 退化为 `watch -n 3`、能力只增不减：保留数字键/f/d/Enter 语义）；installer 逻辑迁到 `forward internal install-tabbar|install-keys|startup-hook`；`scripts/{startup-hook,postinstall}.sh` 改为 ≤15 行 POSIX sh 薄 wrapper（binary 缺失 → 一行提示 + exit 0，永不阻塞 server）；`scripts/{install-tabbar,install-keys,bootstrap,diagnose-panel}.sh` 删除或改 wrapper。
- **依赖**：Phase 3。
- **验收**：两机 E2E 全绿（面板交互路径全按键化验证）；单测覆盖 panel_render 帧输出；startup-hook 恒 exit 0 契约（unit）。
- **风险点**：panel 883 行 read 循环的按键语义回归（Enter 不关面板、Ctrl+click SGR 序列走 herdr link_handler 不受影响）。

### Phase 5 — Bash 退役 + Releases 真实安装验证
- **文件**：删除产品 Bash modules 全部 11 个（main 实际 lib/ 目录含 11 个文件；原文的「10」是计数笔误）、`bin/forward` 替换为 shim：
  ```sh
  #!/bin/sh
  # herdr-forward CLI — exec Go binary（下载失败时给出明确指引）
  d=$(dirname "$0")
  if [ ! -x "$d/forward-go" ]; then
    printf 'herdr-forward: 缺少二进制 %s/forward-go。\n' "$d" >&2
    printf '重新安装：herdr plugin install zzjcool/herdr-forward\n（离线/开发：git clone 后 make build）\n' >&2
    exit 127
  fi
  exec "$d/forward-go" "$@"
  ```
  删除 bash 版 unit/integration 测试中针对 lib 内部函数的部分（E2E 断言全保留）；`scripts/ci.sh` shellcheck/shfmt 目标收缩到剩余 sh 脚本、删 difftest 段；`package.json` files 去掉 lib/；README/docs 更新。
- **依赖**：Phase 4。
- **验收（终态门）**：`bash scripts/ci.sh` 全绿（docker 主路径 + bwrap 降级路径各跑一次）；`HERDR_E2E_ONLINE=1 bash scripts/e2e/run-real-install.sh` 对**打了 tag 的真实 GitHub release** 全绿（install→下载→校验→prefix+f→升级场景）；`grep -r 'lib/.*\.sh' bin/ scripts/` 无引用；仓库无预编译二进制（CI 哨兵：`git ls-files | grep -E 'forward-go|dist/'` 为空）。

> **迁移期间基线纪律**：worker 在 Phase 0 实测发现 `main` 上存在既有红灯（tests/unit/test_bridge.sh SC2034，disable 注释只覆盖了下一条赋值，`cl_status[6006]=` 漏盖，已于迁移开始时修复）。今后任何 phase 验收时，与既有基线的偏差必须先对照 pristine main 确认是否新增回归，不得把既有红灯计入本 phase 失败，也不得借此放松断言。

## 7. Releases 流水线与 postinstall 下载

**GoReleaser**（裁决：不手写 matrix —— checksums.txt、4 平台命名、GH Action 集成都是现成的，手写只会重造）。`.goreleaser.yml`：`goos: [linux, darwin] × goarch: [amd64, arm64]`，archive 名 `herdr-forward_{version}_{os}_{arch}.tar.gz`（内含单二进制 `forward` + LICENSE/README），`ldflags: -s -w -X main.version={{.Version}}`；`.github/workflows/release.yml`：push tag `v*` → goreleaser → 上传（含 checksums.txt）；`ci.yml`：ubuntu-latest 跑 `scripts/ci.sh`（有 docker）。

**postinstall 下载（scripts/postinstall.sh 重写，纯 POSIX sh —— 裁决理由：`[[build]]` 在二进制存在**之前**运行，不能用 Go 二进制 bootstrap 自己，鸡生蛋；curl（macOS 必有、Linux 普遍）与 wget 双兜底是唯一零新增依赖方案）：

```sh
# 伪代码骨架（实现保持现有 note/say 风格）
HERDR_FORWARD_SKIP_DOWNLOAD=1 → 跳过（离线 E2E / 本地 make build 后）
os/arch = uname -s / -m 映射 → linux_amd64 | linux_arm64 | darwin_amd64 | darwin_arm64
url = ${HERDR_FORWARD_BIN_BASE:-https://github.com/zzjcool/herdr-forward/releases/latest/download}/herdr-forward_<ver>_<os>_<arch>.tar.gz
# 版本从 herdr-plugin.toml 读（版本号 = tag）
curl -fsSL 或 wget -qO 下载 tar.gz + checksums.txt（哪个在用哪个，都没有 → 明确报错）
sha256 校验：sha256sum（Linux）/ shasum -a 256（macOS）
解到 tmpdir → mv 到 bin/forward-go → chmod 0755
失败 → 打印手动指引（git clone + make build / 重试 / 检查网络）→ exit 1
成功 → 继续装键位（exec bin/forward internal install-keys + herdr server reload-config）
```

**裁决：下载失败 exit 1**（中止 install）。插件的全部价值在这个二进制上，静默半装比 install 失败更糟；错误信息含完整手动恢复路径。

**本地开发（`herdr plugin link`）**：link 不跑 build，开发者 `make build`（shim 的 127 报错即指引）。**E2E**：docker（Dockerfile 加 go，run-inside 内 `go build`，vendor 免网络）+ bwrap（宿主先 `make build` 再进沙箱，无 go 则显式 fail 带指引）+ two-machines（构建一次，两个容器都注入）。

## 8. 必须写 Go 单测的关键纯函数

- **render.Oneline**：空/单/多/>6 截断 `+N`/全 down/坏 JSON → 空串；⇅ 多字节字符；exit 0 恒定。
- **state.Load/Save**：4 个现有 fixture 逐一复用；round-trip 后**逐字节**等于 jq 输出（键序/紧凑单行格式/`publish` null 形态）；旧记录缺 `mode` → 默认 tunnel；损坏 → 空+warn。
- **ports.List**：`/proc/net/tcp{,6}` hex 解析（LISTEN=0A、`0100007F`→127.0.0.1、IPv6 展开剥 zone）；过滤矩阵——127.0.0.11（容器 DNS）、127.0.0.53、0.0.0.0/::/::1/`::ffff:127.0.0.1` 通、端口 <1024/前导零/越界不通。
- **machine.NormalizeSshTarget**：`user@host`→`:22`、`user@host:2222`、`user@[::1]:22`、裸 `[::1]`、非法 → 64。
- **bridge.ParseLine + ValidateForward + String()**：C6 全边界（id 形态、端口区间、≤32、OPEN 只接受已 SYNC 端口的 localhost URL）——与 bash 实现做差分。
- **tunnel 参数拼装**：golden argv 数组（BatchMode/ExitOnForwardFailure/ControlMaster/ControlPersist/StrictHostKeyChecking 逐 flag）。
- **hfcommon.ProbePayload**：up（回包）/degraded（连上无回包）/down（拒绝）三态 + 有界超时。
- **supervisor 退避状态机**：2s→60s 指数、稳定 60s 复位、socket 消失退出。

## 9. 风险清单

| # | 风险 | 缓解 |
|---|---|---|
| R1 | jq→encoding/json 输出差异（键序、缩进、`null` 形态）破坏 C4/C5 消费者（bash panel 期、E2E jq 断言） | 字段字母序声明 + 逐字节差分测试（difftest 贯穿 Phase 1-4） |
| R2 | macOS 无 E2E：Bash 3.2 hack（hf_detach_exec 三级兜底、`read -t` 半行、`printf %()T`）删除后的行为回归 | SysProcAttr/uniform Go 路径 + §11 手动 smoke 清单（install 下载、tunnel add、tab bar、panel、ports(lsof)、bridge）；CI 无法覆盖，列入发布检查单 |
| R3 | E2E 容器内 Go 构建（离线） | Dockerfile 装 go + `go mod vendor` 提交进仓库 + CI 哨兵「vendor 与 go.mod 一致」；bwrap 在宿主预构建 |
| R4 | postinstall 下载失败场景（无 curl/wget、网络断、checksum 不符） | exit 1 + 手动指引；HERDR_FORWARD_BIN_BASE 支持镜像；run-real-install E2E 打真 tag 验证全链路 |
| R5 | HF1 混合版本窗口（Phase 3 内 bash serve × Go run） | 协议 C6 冻结 + 编解码差分；两机 E2E 收口；serve/run 同 phase 切完 |
| R6 | panel 交互回归（883 行 read 循环语义） | 两机 E2E 的按键路径 + panel_render 帧单测；面板只增不减原则（CLI 直调等价路径保留） |
| R7 | 升级场景：旧 bash 版在用 → install 新版 | forwards.json schema 不变（C4 兼容旧记录）；run-real-install 场景 1 覆盖 |
| R8 | `herdr plugin link` 本地开发无网络 | link 不跑 build + make build + shim 127 指引；E2E 用 SKIP_DOWNLOAD |

## 10. Phase 1 并行 worker 拆分（4 worker，fire-then-wait 派发）

| worker | 任务 | 唯一 writer 范围 | 依赖 |
|---|---|---|---|
| W1 | `internal/hfcommon` + `internal/state` + **difftest harness**（`tests/difftest/run.sh` + fixture 语料装载） | go/internal/hfcommon/、go/internal/state/、tests/difftest/ | Phase 0 |
| W2 | `internal/render` + `internal/ports` + 各自 Go 单测（oneline 全场景、/proc 解析矩阵） | go/internal/render/、go/internal/ports/ | Phase 0 |
| W3 | `internal/machine`（NormalizeSshTarget、toml 解析、HerdrMachineListJSON）+ `internal/sshprobe`（parse_target） | go/internal/machine/、go/internal/sshprobe/ | Phase 0（BurntSushi/toml vendored 由 W1 先 `go mod vendor`？→ 调整：vendor 提交放 Phase 0 由主 agent 完成，W3 只消费） |
| W4 | `internal/cli` dispatch 骨架 + `list`/`ports` 子命令 + bin/forward dispatch 行 + E2E 适配 + 全套 `scripts/ci.sh` 绿 | go/internal/cli/、go/cmd/、bin/forward（仅 dispatch 一行） | **串行在 W1/W2 之后**（W1/W2 交付后开工；W3 可并行，其产物 phase 2 才接线） |

写冲突规则沿用 ARCHITECTURE §D：`bin/forward` dispatch 行只允许 W4 改；`scripts/ci.sh`、`scripts/e2e/*` 归 W4（或主 agent）。

## 11. macOS 手动 smoke 清单（发布门，非 CI）

1. `herdr plugin install zzjcool/herdr-forward`（真 curl 下载 + checksum + 键位 + reload）
2. `forward add 13000:9443 --ssh-target user@host` → tab bar ⇅13000 → panel 显示 → remove 无残留
3. `forward ports`（lsof 路径）与 `Activity Monitor` 核对
4. 桥接：A(mac) 激活 B → 端口出现在 A 的 localhost → Ctrl+click 打开
5. 非 TTY `forward watch` 退化正常；终端 raw mode 无残留 termios 状态

## 12. 规模预估

| Phase | 规模（Go+测试新代码） | 估时 |
|---|---|---|
| 0 脚手架+流水线 | ~300 行 + 配置 | 0.5-1 天 |
| 1 纯函数层 | ~1200 行（含 difftest） | 2-3 天（4 worker 并行 ≈ 1 天墙钟） |
| 2 隧道/doctor | ~1500 行 | 3-4 天 |
| 3 machines+bridge | ~2500 行 | 4-5 天 |
| 4 panel+安装器 | ~1500 行 | 2-3 天 |
| 5 退役+真安装验证 | ~删除 6500 行 bash + 少量 | 1-2 天 |

## 13. W4 实测与偏离记录（Phase 1 · cli 接线 + 切 list/ports）

铁律：「任何偏离先改本文再动代码」。以下逐条登记 W4 实施中的**实测结论**与**有意偏离**，
区分「契约不变」（用户可见行为零变化）与「已知形态差异」（会被 difftest 显式拉平或钉住）。

### 13.1 接线方式：条件式 dispatch（相对 §3 字面「无条件 exec」的偏离）

§3 写的是「已迁移子命令 `exec bin/forward-go "$@"`」。W4 实作为**条件式**：

```bash
case "${1-}" in
list | ports)
  if [[ -x "${FORWARD_ROOT}/bin/forward-go" ]]; then
    exec "${FORWARD_ROOT}/bin/forward-go" "$@"
  fi
  ;;
*) ;;
esac
```

理由（两条，都是实测踩出来的）：

1. **staged root 测试会 127 假红**：`test_cli.sh`、`test_machines_cmd.sh`、`test_bootstrap.sh`、
   `test_panel_bridge.sh`、`test_machines_bridge.sh` 都把 `bin/forward` + 部分 `lib/` 拷成
   独立 root 再调用，那里没有 `forward-go`；无条件 exec 会让这些用例 rc=127 直接弄红 ci.sh。
2. **回滚故事**：删掉这个 `if` 块（或让 `bin/forward-go` 不可执行）bash 立即恢复全权处理，
   无需改任何其它文件。已实测：删除 `bin/forward-go` 后 `list`/`ports` 与 Go 版输出逐字节一致
   （E2E B2「回滚等价性」三条断言 + difftest 组 6/7 的 bash 侧 staged root 都是这条证据）。

### 13.2 `bin/forward-go` 的产物位置与 CI 确定性（迁移期适配器）

* 产物仍固定为仓库根 `bin/forward-go`（Makefile / goreleaser / postinstall.sh 的既有约定），
  `.gitignore` 已排除它。difftest 与 E2E **绝不**往仓库根的 `bin/` 写二进制（difftest 写
  `${TMP}`、E2E 写容器内 `/work/bin` 或沙箱 `src/bin`）。
* `scripts/ci.sh` 在整轮开始前把本地已构建的 `bin/forward-go` **暂存到 `$TMPDIR`**（EXIT 陷阱
  还原）。原因：unit/integration 里有一批直接调仓库根 `bin/forward` 的用例，其 golden 是纯
  bash 输出（尤其 `ports` 的 PROCESS 列——见 13.4），本地恰好 `make build` 过就会「本机红、
  CI 绿」。暂存到 `$TMPDIR` 而非仓库内加后缀，是为了不让任何残留文件被 E2E 的源码拷贝或
  两机 tar 带进沙箱。**该适配器在 Phase 3（bash 退役）时必须删除。**

### 13.3 `list --json` 走「原始 jq 视图」而非类型化模型（实现裁决）

`state.Load()` 返回冻结类型 `[]state.Forward`，它无法表达 bash 的 jq 透传语义：
未知键要保留、缺失键要缺失、数字字面量要逐字节保留（`2.50` 不能变 `2.5`）、
`forwards` 里出现非对象元素时 jq 会**报错**而不是补零。因此 `list --json` 另走一条
「顺序保留对象 + 保留数字字面量」的原始视图（`go/internal/cli/jsonjq.go` + `view.go`），
并在其中逐字复刻 `retired Bash state module` 的三条 warn 文案。实测比对 60+ 组 golden 全绿。

配套的 jq 兼容规则（全部由本机 jq 1.8.2 实测反推，单测钉住）：
字符串转义（`"` `\` `\b` `\t` `\n` `\f` `\r`、其余 <0x20 与 **0x7f** 转 `\u00xx` 小写；
U+2028/U+2029 与 `<` `>` `&` **不**转义）；数字规范化（decNumber `decNumberToString`：
`1e3`->`1E+3`、`1.5e3`->`1.5E+3`、`1e-6`->`0.000001`、`1e-7`->`1E-7`、`0.0000000`->`0E-7`、
`2.50`->`2.50`、`-0`->`-0`、`0e5`->`0E+5`、`1000000e-6`->`1.000000`）。

**已知边缘（Go 与 bash 一致的降级）**：`forwards` 含非对象元素时，bash 的
`bridge_merge_live` 因 jq 报错得到空串 → `list --json` **stdout 为空、rc 0**，
`list`/`list --oneline` 只输出表头/空串、rc 0。Go 侧刻意复刻这一形态（difftest 组 6 三条用例
比 stdout + rc）。

### 13.4 `ports` 的 PROCESS 列：Go 恒为空（有意偏离，已在 difftest/E2E 拉平）

bash 的 `ports_listening_json` 优先用 `ss -Htlnp`（能拿到进程名），Go 的 W3 冻结实现
`ports.List()` 在 Linux 上读 `/proc/net/tcp{,6}`（**拿不到进程名**），故 PROCESS 列恒为 `-`。
- difftest 组 7：给 bash 侧一个**不含 `ss`/`lsof`** 的 symlink PATH 农场 → 两侧同源（都读
  `/proc`），比的是同一数据源下的输出字节。
- E2E B2：`ports` 只断言「端口 + 地址」列一致（显式不比对 PROCESS 列）。
- 升级到 `lsof`/`ss` 采集进程名属 Phase 2+ 的独立决定（未在 W4 变更 W3 的冻结实现）。

另：`ports --json` 在 bash 里**没有** `-S`，键序是插入序 `port,addr,process`（与
`list --json` 的 `-S` 字母序不同）→ Go 侧为此单独用「保留插入序」的编码路径。

### 13.5 Go 侧新增的 `version` 子命令（对用户零影响）

`bin/forward` 的 `main()` **没有** `version` 分支（`forward --version` 实际是
usage + rc 64）。Go 的 `Main` 增加了 `version|--version|-v` → `forward <Version>` rc 0。
由于 `bin/forward` 只 dispatch `list|ports`，这条分支在迁移期**不可达**（用户可见行为零变化）；
保留它是为了让最终 Go 二进制在 Phase 5 接管时不需要额外补默认行为。已在此登记。

### 13.6 表格渲染：代理行而非改冻结签名

`render.Table` 是冻结实现，且对 `ModeClient` 硬编码 `"client"`、第 6 列恒 `-`。
而 bash 的表格对 client 记录要显示 `client:<client>`（MACHINE 列）与 `status_reason`（第 6 列），
对 bridge 记录要显示 `<machine>(桥接)`。W4 **不改 render.Table**，而是在 `list.go` 里把视图行
「投影」成 render.Table 能表达的形状（client 行借用 `ModeTunnel` + `Machine`/`SshTarget`
承载那两个值）。投影规则与 `@tsv` 转义（只转 `\` `\t` `\n` `\r`）写在 `rowToForward` 的注释里。

受限于冻结字段的零值语义，下列**手改/损坏记录**才可能触及的形态仍有差异（W1/W2 已登记，
difftest 用 schema 完整夹具规避）：远端主机缺失/null → bash `:9443` vs Go `127.0.0.1:9443`；
`remote_port` 缺失 → bash `:null` vs Go `:0`；`status` 为 null → bash 空 vs Go `-`；
bridge 行 `machine` 为 null → bash `(桥接)` vs Go `-(桥接)`。

### 13.7 桥接只读合并落在 cli 层（Phase 3 会取代）

`list` 需要 client 的实时状态与 A 侧 bridge 行（契约 C5/C6），否则切换瞬间 tab bar / 面板
会丢状态。W4 在 `go/internal/cli/view.go` 复刻了 `retired Bash bridge module` 的只读半边
（`bridge_sessions_json` / `bridge_live_status_json` / `bridge_merge_live` /
`bridge_clients_json` / `bridge_client_forwards_json`），含以下刻意复刻的细节：
`kill -0` 的 EPERM 也算「死」并**顺手删除**会话文件、`sort_by(.last_seen_unix) | reverse` 的
等值倒序、`group_by(.id)` 的「up 优先否则取首条」、`BRIDGE_LIVE_WINDOW_S` 环境变量可覆盖。
Phase 3 迁移 bridge 写侧时，本文件退化为薄包装。

### 13.8 `FORWARD_STATE_VERSION` 的 jq 宽松数字（部分偏离）

jq 的 `--argjson` 接受 `01` / `1.` / `.5` / `+1`（规范化成 `1` / `1` / `0.5` / `1`），
而 Go 的 `encoding/json` 拒绝这四种。W4 在 cli 层做了**宽容解析**（`lenientNumberLiteral`），
四种形态的产物与 jq 逐字节一致（difftest 组 6 + 单测钉住）。非法的输入（如 `abc`）：
bash 是 jq 报错 rc **2**、stdout 空；Go 打印一条自己的可诊断 error 后**同样 rc 2**、stdout 空
——退出码与 stdout 一致，stderr 文案不同（difftest 该用例只比 rc/stdout，不比文案）。

### 13.9 CI / E2E 接线实测

* `scripts/ci.sh` 新增 `0b/6 difftest`：go/go.mod 或 `tests/difftest/run.sh` 缺失 → SKIP；
  go 缺失且非 LAX → FAIL、LAX → WARN（**两条分支都不打印 `CI FAIL`**，因为
  `tests/unit/test_ci_script.sh` 断言 LAX 输出里不得出现该字串）。
* shellcheck/shfmt 目标列表纳入 `tests/difftest/*.sh`（`[[ -f ]]` 守卫）；
  `run-inside.sh` 的 `lint_targets` 同步。
* E2E：`run-inside.sh` 启动时构建/恢复 `/work/bin/forward-go`；A/A2 段跑切换后的路径
  （含 staged shim 的切换探针 + 回退逐字节对位）；**B 段前暂停 Go CLI** 以跑纯 bash 基线；
  新增 **B2 段**跑切换后对位（list 三形态、ports 端口/地址列、回滚等价性、oneline 延迟、
  容器内 difftest）。`run-bwrap.sh` 在宿主预构建并拷进沙箱（沙箱内无 go 工具链）。
* 两机 E2E 在 W4 仍是**纯 bash 判定**（tar 排除 `.git`/`.pi-subagents`/`test-results`/
  `node_modules`，不含 `bin/forward-go`）：B 上 `forward list --json` 的状态断言与 tab bar
  断言因此走 bash。Go 的桥接合并由 difftest 组 6 + E2E B2 覆盖；Phase 3 切 machines/bridge
  时把 Go CLI 一并注入两机 tar。

### 13.10 验证结果（W4）

| 门 | 命令 | 结果 |
|---|---|---|
| Go 门 | `make check` | gofmt/vet/test/vendor-check 全绿 |
| 差分 | `bash tests/difftest/run.sh` | `1..123` / `PASS: 123 FAIL: 0` / `RESULT: PASS` |
| 基线 | `bash scripts/ci.sh` | `CI OK: 6/6 全部通过`（含 docker E2E `130 PASS / 0 FAIL`、两机 E2E `62 PASS / 0 FAIL`） |
| E2E 切后 | `run-inside.sh` B2 段 | 回滚等价性 3 条逐字节 + ports 端口/地址列一致 + oneline 65ms |

## 14. Phase 2 实测与偏离记录（状态写入 + 隧道生命周期）

铁律与 §13 相同。以下逐条登记 Phase 2 实施中的**实测结论**与**有意偏离**，并区分
「用户可见契约不变」与「已知形态差异」。

### 14.1 dispatch 的 add 细分（相对 §6「dispatch 行扩为 list|ports|add|remove|doctor|publish|unpublish」的偏离）

§6 的字面写法是 `add` 整体切 Go。Phase 2 实作为**按参数细分**（`bin/forward` 的
`_hf_add_dispatch_go`）：

```bash
add)
  if [[ -x "${FORWARD_ROOT}/bin/forward-go" ]] && (($# > 1)); then
    if [[ "$(_hf_add_dispatch_go "${@:2}")" == "yes" ]]; then
      exec "${FORWARD_ROOT}/bin/forward-go" "$@"
    fi
  fi
  ;;
```

`_hf_add_dispatch_go` 的规则（保守优先）：

* 参数里出现**精确** `--client` → 归 bash；
* 否则出现 `--ssh-target` / `--ssh-target=*` / `--machine` / `--machine=*` → 切 Go；
* 其余（无目标、只有位置参数）→ 归 bash。

理由：**client 映射的写侧（retired Bash bridge module）属 Phase 3**，而 `add --client` 与「没给目标但
有 client 在线 → 隐式 client 映射」这两种形态都要写 client 记录 + 影响桥接。Phase 3 之前
把它们留在 bash 是唯一能保证「双实现不打架」的切法；`panel.sh` 与 `machines activate` 走的
正是这条路径（`retired panel implementation (former line 797)` 的 `"${bin}" add "${item}" --client`）。

Go 侧的 `cmd_add` **完整实现**了 client 分支（含 `bridge_any_live` 的只读判定与
`_hf_add_client` 的两行 stderr 文案），因此 Phase 3 把 bridge 写侧迁完后不需要再补语义；
difftest 组 9 的 `add 5173 --client` / `add 80 --client` 用例走的是 **bash 侧 staged root**，
用 `internal/cli` 的单测覆盖 Go 侧这一分支（`TestAddClientRecordsWaitingWithoutLiveClient`）。

### 14.2 Doctor 的 `status` 缺失：`""` vs bash 的 `"null"`（已知形态差异）

bash 的 `tunnel_doctor` 用 `jq -r ".[i].status"` 取状态：字段**缺失**时 jq 输出字面
`null`，于是报告行是 `f-x: degraded (no application-layer reply; status=null)`；Go 的
`state.Load` 把缺失字段填零值 `""`，报告行成为 `… status=`。只有手改/损坏记录才可能触及；
`--fix` 的比较 `status != "up"` / `!= "down"` 在两种形态下结果相同（都不等于 up/down）。

### 14.3 `ssh -O check` / `-O exit` 的 5s 硬上限（新增）

bash 只给 `-O exit` 包了 `timeout 5`，`-O check` 没有上限。Go 侧两者都包 `context` 5s
（`ctlSSHTimeout`）—— ControlMaster socket 卡住时 bash 的 Start 会无限期轮询（50×0.1s 的
循环体内每次都挂），Go 保证有界。这是**加固**而不是行为变化：正常环境两者都在毫秒级返回。

### 14.4 launcher 的回收：goroutine Wait（相对 bash `disown`）

bash 用 `setsid ssh … &` + `disown`，让 launcher 被 init 收养；Go 用
`SysProcAttr{Setsid:true}` + `go cmd.Wait()`。ControlPersist=yes 下 launcher 很快就退出，
`Wait` 保证它不会变成僵尸（E2E 的 `t_no_zombie_ssh` 是这条的证据）。

### 14.5 Doctor 不依赖 jq（相对 bash 的 `require_cmd jq`）

bash 的 `tunnel_doctor` 第一行 `require_cmd jq`（缺失 → die 127）。Go 的 `tunnel.Doctor`
直接读 `state.Load()`，不需要 jq。用户可见行为零变化（jq 是 bash 侧的硬依赖，插件环境必有），
差异只在「Go 侧少一个外部依赖」。

### 14.6 tunnel_failure 路径的 stderr 分层（已知文案差异）

`add` 隧道失败时，bash 的顺序是：`tunnel_start` 的 stderr 被 `2>errfile` 捕获 → die 5 打印
`隧道启动失败（<id>）：<err>。…`。Go 侧同形（error 文本前缀与 bash 的
`tunnel start failed: <id> -> 127.0.0.1:<lp> via <target> (ssh: <tail>)` 逐字一致），
但 **stderr 前缀里的时间戳来自 `hfcommon.Log` 的 error 镜像**（`[ts] error: …`），
而 bash 的同一条也是经 `log error`，因此两边的**可见行数**一致。difftest 组 9 的 add 用例
全部是**参数错误**（在写记录之前就 die，零副作用），隧道失败路径由 integration
`test_cli_full_cycle.sh` + `phase2-go-path.sh` 覆盖。

### 14.7 notify 的传输实现与转义（有意偏离）

* bash 依次试 `python3` / `socat` / `nc`（各起一个 session + watchdog 进程）；Go 用
  `net.DialTimeout("unix", …)` + `SetWriteDeadline(1s)`，不派生任何进程。语义等价
  （1s 内投不出去就降级），且消除了对三个外部命令的依赖。
* payload 转义：bash 在**有 jq** 时用 `jq -cn`（完整 jq 转义），无 jq 时用手写回退
  （只转 `\` `"` 换行）。Go 恒用完整 jq 规则 —— 与「bash 有 jq」逐字节一致，是更严格的一侧。
* `socketUsable` 用 `os.Stat` + `syscall.Access(W_OK)` 表达 `[[ -S && -w ]]`；`-/w` 的
  root 语义（root 对任何文件 W_OK 都通过）在两者下一致。

### 14.8 `notify` 尚无调用方（Phase 2 只交付库）

Phase 2 的任务范围是「mirror retired Bash notify module」；`bin/forward` 里没有任何 `notify_toast` 调用
（既有的调用点都在 panel/桥接，属 Phase 3/4）。因此本 phase 交付的是**库 + 单测**，
difftest 无 notify 组（bash 侧也没有可对位的 CLI 入口）。

### 14.9 组 9/10 的状态比对口径

* `created_unix` 用两侧各自的真实时钟写入 → 比对前归零（`masked_state`），其余 11 字段逐字节。
* doctor 的 down/degraded 用例用组 3 起的**真实监听 socket**（reply ⇒ up / silent ⇒ degraded）；
  活记录的 `master` pid 用当前测试进程（`kill -0` 判活）。
* 两侧各指独立的 `HERDR_PLUGIN_CONFIG_DIR`（`add --machine` 要读 machines.toml）。

### 14.10 验证结果（Phase 2）

| 门 | 命令 | 结果 |
|---|---|---|
| Go 门 | `make check` | gofmt/vet/test/vendor-check 全绿 |
| 差分 | `bash tests/difftest/run.sh` | `1..270` / `PASS: 270 FAIL: 0` / `RESULT: PASS`（Phase 1 为 123） |
| 基线 | `bash scripts/ci.sh` | `CI OK: 6/6 全部通过`（含 docker E2E `130 PASS / 0 FAIL`、两机 E2E `62 PASS / 0 FAIL`） |
| Go 路径证据 | `bash tests/difftest/phase2-go-path.sh` | `40 passed, 0 failed`（真 sshd + 真 ssh -L + 记录型 dispatch shim） |

## 15. Phase 3 实测与偏离记录（machines + 桥接）

铁律与 §13/§14 相同。以下逐条登记 Phase 3 实施中的**实测结论**与**有意偏离**。

### 15.1 dispatch 的整组切换（相对 §6 字面「machines/bridge/open-url 整组切」的落地细节）

§6 写的是「`machines {list,activate,deactivate,doctor}`、`bridge {up,down,status,serve,run}`、
`open-url`、`add --client`」。实作为：

```bash
case "${1-}" in
list | ports | remove | doctor | publish | unpublish | machines | bridge | open-url)
  if [[ -x "${FORWARD_ROOT}/bin/forward-go" ]]; then
    exec "${FORWARD_ROOT}/bin/forward-go" "$@"
  fi
  ;;
add)
  # _hf_add_dispatch_go：出现任一目标 flag（--client / --ssh-target / --machine，含 = 形态）-> Go
  ;;
esac
```

与 Phase 2 的两点差异：

1. **`--client` 不再被排除**：Phase 2 的谓词把 `--client` 精确匹配留给 bash（client 映射的
   写侧依赖 retired Bash bridge module）。Phase 3 把桥接写侧迁到 Go 后，这条排除不再需要 ——
   `tests/difftest/phase2-go-path.sh` 第 7 段由「marker 无新增」翻转为「marker 有新增」，
   由脚本本身钉住这次翻转（不放松断言，只换判据方向）。
2. **「无目标」的 add 仍留 bash**：那条路径要按「有没有 client 在线」在**运行时**决定走
   client 分支还是 die 4。Go 侧 `cmdAdd` 已实现完整语义（`anyClientLive`），但迁移期白名单
   只看 argv、看不到在线状态。留 bash 是行为零变化的选择；Phase 5 删 dispatch 后自然统一。

`watch` / `bootstrap` 两子命令的**函数体一字未改**（用 git show 逐字节比对确认），
且 `retired Bash panel module`、`scripts/startup-hook.sh`、`scripts/postinstall.sh`、`herdr-plugin.toml`
在本 phase 零改动。

### 15.2 `internal/jqjson`：jq 兼容 JSON 模型抽出为公共包（重构，无行为变化）

Phase 1 的 `list --json` 需要在 `go/internal/cli/jsonjq.go` 里自带「顺序保留对象 + 保留数字
字面量」的 jq 兼容模型。Phase 3 的 bridge 状态文档（`session-*.json` / `client-*.json`）
**也用 jq 的插入序**（bash 是 `jq -c`，不是 `-S`），而 machines 的落盘用 `jq -S -c`（字母序）。

因此把该文件整体迁到 `go/internal/jqjson`（`Parse/Encode/Truthy/ToString/Str/FormatNumber/
EncodeString/Object/Number`），符号从包内私有改为导出；`internal/cli` 改为 import。
**逐字节行为不变**：difftest 组 6/8/9（list/help/add/doctor 输出）在重构前后同为绿。

### 15.3 `machines list` 三种形态用 Go 的 rune 填充（与 bash 的 printf 等价）

bash 的表格是 `printf '%-10s …'` 打表头 + `awk -F'\t' '{printf "%-10s …"}'` 打数据行。
两者的填充口径**不同**：bash `printf` 按**字符（locale）**填充，gawk 在 UTF-8 locale 下按
**显示宽度**填充（中文 label 会多占位）。实测（本机 gawk 5.4 + en_US.UTF-8）：

```
bash printf '%-24s' GPU机器   -> 24 字符（22 字节）
input | awk '{printf "%-24s", $3}' -> 26 字节（按宽度算）
```

Go 的 `fmt.Printf("%-24s", …)` 与 bash `printf` 同口径（按 rune）。因此 Go 侧输出等于
**bash 的 printf 形态**，而 bash 的实际输出在**中文 label** 上会多两个空格 —— 这是
`machines list` 表格的**已知形态差异**，只在 label 含宽字符时可见（`--json`/`--short`
完全一致，已由 difftest 组 12 逐字节钉住）。

本 phase 未能把这条差异拉平的原因：`awk` 的宽度表随 locale 与实现版本变化（gawk 编译选项
影响 `wcwidth` 表），而 Go 侧引入「终端显示宽度」需要额外依赖（PLAN §4 只允许两个 vendored
依赖）。**裁决：Go 以 bash printf 形态为准**（确定性更高），并在 §15.8 记为待裁决项。

### 15.4 HF1 的 STATUS 解析：宽容识别 + 调用方校验（difftest 抓到的真实分叉）

首版 `ParseLine` 对 `HF1 STATUS f-5173`（缺 state 字段）返回 error，理由是「字段不全」。
difftest 组 11 立刻抓到与 bash 的不一致：**bash 的 serve 先 `IFS=' ' read -a words` 拿到
words[2]/words[3]，再用正则 + `up|down` 校验**，因此畸形 STATUS 仍被识别为 STATUS，
并且在 STATUS 分支里**无条件刷新 `srv_last_seen`**（= 算作心跳）。

Go 首版走「未知协议行」分支 → 不刷新心跳 → 与 bash 分叉（后果：B 侧会话文件的心跳时间
不更新，A 侧看到的心跳超时判定与 bash 不同）。修法：`ParseLine` 对 STATUS 一律**宽容解析**
（字段缺失填空串），校验交给 `Serve.handleLine`（复用 `statusPort` + state 白名单）。
与 C6 的安全边界无关 —— 越界 id 仍被 `statusPort` 拒（difftest 组 11 + phase3-go-path.sh 都断言）。

### 15.5 reason 提取：最短前缀匹配而非「重分词」

`STATUS` 的 reason 是**行尾原文**（可含空格、全角括号）。bash 用
`rest="${line#*STATUS "${fid}" "${st}"}"; rest="${rest# }"` —— 语义是：

* `#*pattern` 取**最短前缀**，即 pattern 的**首次出现**位置；pattern 不在时原样返回；
* 末尾只吃掉**一个**空格。

用 `strings.Fields(line)[4:]` 重写会在两处不等价（多个连续空格压缩、首次出现位置）。
因此实现为 `stripReasonPrefix`（`strings.Index` + 单个前导空格）。difftest 组 11 的
「STATUS down 带 reason（含空格）」用例覆盖。

### 15.6 serve 的读循环用常驻 reader goroutine（相对 bash `read -t` 的唯一差异）

bash 的 serve 循环用 `read -r -t BRIDGE_POLL_S`：每拍最多等 1 秒，超时后回到循环顶部
刷新期望集合 / 打开队列 / 会话文件。Go 侧实现为「一条常驻 reader goroutine + 每秒 ticker」：

* **为什么不用「每次读开一条 goroutine + select timeout」**：心跳间隔 1s、serve 常驻数天，
  那种写法按秒泄漏协程（每拍一条永不返回的 `ReadString`）。
* **语义差异（唯一一处）**：超时那一刻的**半行**。bash 把半行留在变量里下一轮拼；Go 的
  `ReadString` 会一直等到换行才交付。结果都是「这一行被完整交给协议分发」，只是交付时刻
  晚（不影响正确性：协议是行导向的）；而 EOF 时未闭合的半行两边都丢弃（bash 的
  `read` 返回非 0 且 `hf_read_timed_out` 判为 EOF → break，`line` 里的残余不再使用）。

### 15.7 桥接读侧半边搬迁（`internal/cli/view.go` → `internal/bridge/readside.go`）

§13.7 预告了这次搬迁（「Phase 3 迁移 bridge 写侧时，本文件退化为薄包装」）。`sessions_json`
/ `live_status_json` / `merge_live` / `any_live` / `clients_json` / `client_forwards_json`
现在住在 `internal/bridge/readside.go`，`cli/view.go` 只保留 `loadView` 的胶水与投影
（`rowToForward`）。**difftest 组 6 的 client 在线/离线/bridge 行用例在搬迁前后同为绿**
（逐字节）。

### 15.8 有意偏离与未决项

* **`machines list` 表格的中文 label 宽度**（§15.3）：Go 按 bash `printf` 的 rune 口径输出，
  bash 实际输出是 awk 的显示宽度口径。只在宽字符 label 上可见。未拉平的理由见 §15.3；
  已登记为**待裁决项**（若后续要求表格逐字节一致，需要引入显示宽度表或改用 `--short`）。
* **`bridge serve` 的会话文件名**：仍用 `session-<pid>.json`（pid = 当前进程），与 bash 的
  `BASHPID` 同语义。Go 没有 `BASHPID` 的 subshell 概念，但 serve 是独立进程，两者一致。
* **`bridge run` 的 ssh stderr 落盘**：bash 用 `2>>"${errlog}"`（追加）；Go 用
  `O_CREATE|O_APPEND`，并在每次重连前 `os.Remove`（= bash 的 `: >"${errlog}"`）。
  `_bridge_exit_reason` 的 `tail -3` 因此读到同一内容。
* **`notify` 在 `open-url` 路径上的调用**：Phase 2 已交付 `internal/notify`（§14.8 记「尚无
  调用方」），本 phase 起 `open-url` 会在「有 client 在线」时投递 toast（与 bash 一致）。
* **`scripts/ci.sh` 的迁移期适配器延到 Phase 5**：§13.2 写「该适配器在 Phase 3 时删除」，
  实测**仍需要** —— 原因见该脚本内新增的注释：unit 层还有走真实/staged root 调
  `bin/forward` 的用例（`test_client_forwards.sh` 的 `ports` 段依赖 bash 的 `ss` 进程名、
  `test_machines_uri_targets.sh` 会调 `machines list --short`），其 golden 是 bash 输出。
  这些用例要到 Phase 5（bash 版测试退役）才消失，故删除点顺延到那里。
* **`doctor` 的 bridge 状态行**：bash 用 `jq` 拼字符串；Go 用同一份 `bridge.Clients()` 文档
  逐个字段读（`bridge.ObjStr`），输出形状一致（`运行中，<state>（<reason>）`）。

### 15.9 验证结果（Phase 3）

| 门 | 命令 | 结果 |
|---|---|---|
| Go 门 | `make check` | gofmt/vet/test/vendor-check 全绿 |
| 差分 | `bash tests/difftest/run.sh` | `1..426` / `PASS: 426 FAIL: 0` / `RESULT: PASS`（Phase 2 为 270） |
| 基线 | `bash scripts/ci.sh` | `CI OK: 6/6 全部通过`（含 docker E2E `130 PASS / 0 FAIL`、两机 E2E `62 PASS / 0 FAIL`） |
| 集成 | `bash tests/run.sh integration` | 7 文件全绿（含 `test_bridge_roundtrip.sh`：真 sshd + 真 ssh 的桥接数据面） |
| Go 路径证据（Phase 2） | `bash tests/difftest/phase2-go-path.sh` | `40 passed, 0 failed`（dispatch 边界翻转后仍全绿） |
| Go 路径证据（Phase 3） | `bash tests/difftest/phase3-go-path.sh` | `21 passed, 0 failed`（**serve 与 run 双侧都走 Go** + 真协议往返 + 退避状态机） |

## 16. Phase 3 未决问题裁决（主 agent，2026-09-25）

Phase 3 验收（独立复跑：difftest 426/426、ci.sh 6/6、phase2/phase3-go-path 40+21 全绿）后，对 worker 报告 §7 五条未决问题的裁决：

1. **§15.3 表格宽度**：**保 Go 的确定性**（= bash printf 字节口径，不做显示宽度对齐）。理由：difftest 的逐字节契约是整个迁移的护栏，引入 awk 宽度对齐会破坏字节可比性；宽字符机器名属边角显示美观问题，Phase 5 后如需再单独提案。已生效。
2. **本地 `make build` 后手跑 unit 3 红**（`test_client_forwards.sh` 的 ports PROCESS 列）：已知偏离 §13.4 的自然结果，CI 判据不受影响。**Phase 5 收口清单**：删 ci.sh 适配器时，把这 3 条断言改为同时接受 bash/Go 两种 PROCESS 形态（或改用 --json 断言端口/地址列，对齐 E2E 口径）。
3. **activated-machines.json 双读取点**（machine 写侧 / bridge 只读）：接受当前策略（与 bash 同构）。约束：Phase 4/5 若新增字段，两处必须同步改，difftest 的 schema 对照用例负责抓漂移。
4. **两机 E2E tar 未含 forward-go**：**Phase 4 处理**——把 Go CLI 注入两机 tar，让两机 E2E 直接裁判 Go 路径（62 断言是最接近真实用户的验收）。归入 Phase 4 任务书。
5. **watch/bootstrap 仍在 bash**：Phase 4 主任务，无异议。

## 17. Phase 5 完成记录（go-mig/phase5）

Phase 5 终态收口：

- 删除产品 Bash modules 11 个（main 实际 lib/ 目录含 11 个；原文计数已在本记录纠正）；`bin/forward` 变为 9 行 POSIX shim，缺少
  `forward-go` 明确提示并返回 127；其余 Bash 测试中直接覆盖内部函数的用例退役。
- `scripts/postinstall.sh` 变为纯 POSIX Release bootstrap：uname 平台映射、manifest
  version、curl/wget 双兜底、sha256sum/shasum 校验、临时目录解包、`HERDR_FORWARD_BIN_BASE`
  镜像和 `HERDR_FORWARD_SKIP_DOWNLOAD=1` 离线开关；下载失败/校验失败统一 exit 1 并给出
  `git clone` + `make build` 恢复指引，成功后安装键位并 reload-config。
- `tests/difftest/run.sh` 保留 438 个逐字节用例，但改为 Go-only golden：
  `tests/difftest/golden.tsv` 记录 exit code 与 base64(stdout)。旧 Bash 对照器、
  `phase2-go-path.sh`、`phase3-go-path.sh` 随 Bash 退役；真 ssh/HF1 护栏由 Go 集成/E2E
  覆盖。`GOLDEN_UPDATE=1` 仅供审阅后的维护者刷新，不在 CI 中写 golden。
- §16.2 的 ports 断言改为验证 JSON 的端口/地址列，PROCESS 列明确允许空或平台进程名，
  不削弱 E2E 的监听/回环断言。
- `scripts/ci.sh` 删除迁移期二进制暂存适配器，lint 目标收缩到 shim、postinstall、
  wrappers、E2E/difftest runner，并保留 golden 作为终态契约门（相对 Phase 5 原始草案
  「删除 difftest 段」的有意裁决：永久护栏优先于移除校验）。
- 同步清除 Go startup-hook 中对已删除 `retired Bash machines module` 的存在性探针；startup hook
  继续从 Go 的 `activated-machines.json` 读取 active 记录并拉起 bridge，避免 server
  重启后桥接不自愈。这是 Bash 退役后的必要 Go 适配，不改变用户契约。

终态验收清单与 release smoke 见 §11；真实 GitHub Release 的在线安装由主 agent 在发布
决策后执行，worker 只负责本地 Release 下载/失败路径测试。
