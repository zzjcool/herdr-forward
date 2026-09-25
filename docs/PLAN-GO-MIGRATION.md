---

# PLAN-GO-MIGRATION — herdr-forward Bash → Go 渐进式重写实施计划

> 冻结依据：docs/ARCHITECTURE.md（A.2 数据契约 / A.3 函数签名 / A.3.1 探活分级 / A.3.2 machines / A.3.3 桥接）、herdr-plugin.toml、scripts/ci.sh、scripts/e2e/*。任何偏离先改本文再动代码。

## 1. 目标与不做的事

**目标**：全部核心功能由单一 Go 静态二进制（`bin/forward-go`，linux/macos × amd64/arm64）承载；`lib/*.sh` 与 `bin/forward` 的 bash 代码全部删除；`bin/forward` 退化为 ≤5 行 POSIX sh exec shim（保持 manifest/E2E/文档引用路径不变）；GitHub Releases 分发 + postinstall 下载校验；`scripts/e2e` 五套全绿。

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
| C4 | forwards.json | A.2 schema（version:1 + mode/publish 扩展），损坏 → 空数组 + warn；原子写；**jq 排序格式**（键名字母序、2 空格缩进）——Go 结构体字段序按字母序声明以复刻 |
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
    ├── hfcommon/   # ← lib/common.sh：env 解析、log（轮转 1MB/512KB）、atomic write、exitcode、probe_payload
    ├── state/      # ← lib/state.sh（forwards.json）+ machines/bridge 的状态文件
    ├── render/     # ← lib/render.sh：oneline / 表格
    ├── ports/      # ← lib/ports.sh：/proc/net/tcp{,6}（Linux）；exec lsof（macOS）
    ├── machine/    # ← lib/machine.sh + lib/machines.sh：machines.toml 解析、herdr machine list、激活记录
    ├── tunnel/    # ← lib/tunnel.sh：exec ssh ControlMaster 生命周期、doctor
    ├── notify/     # ← lib/notify.sh：herdr socket toast（1s watchdog）
    ├── bridge/     # ← lib/bridge.sh：HF1 协议编解码 + serve/run 监督者 + 退避重连
    ├── sshprobe/   # ← lib/ssh-probe.sh：parse_target / run / plugin 探测
    ├── panel/      # ← lib/panel.sh：watch TUI（备用屏、双缓冲、read 超时刷新）
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
- **文件**：删除 `lib/*.sh` 全部 10 个、`bin/forward` 替换为 shim：
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
- **state.Load/Save**：4 个现有 fixture 逐一复用；round-trip 后**逐字节**等于 jq 输出（键序/缩进/`publish` null 形态）；旧记录缺 `mode` → 默认 tunnel；损坏 → 空+warn。
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
