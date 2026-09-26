# E2E-RESULTS — Phase 5 终态验收记录

> Phase 5：Bash 退役、Go-only Releases 安装 bootstrap、golden contract。
> 历史 Bash 结果保留在 git 历史；本文件记录当前终态门。

## 1. 当前结果

| 门 | 结果 |
|---|---|
| `npm run typecheck` | 通过（`go vet -mod=vendor ./...`） |
| `npm test` | 通过（`go test -mod=vendor ./...`） |
| `make check` | 通过（gofmt/vet/test/vendor-check） |
| `bash tests/run.sh unit` | 8 files, failed: 0 |
| `bash tests/run.sh integration` | 4 files, failed: 0 |
| `bash tests/difftest/run.sh` | `1..438`, `PASS: 438 FAIL: 0` |
| `bash scripts/e2e/run-docker.sh` | `1..130`, `PASS: 130 FAIL: 0 SKIP: 0` |
| `bash scripts/e2e/run-bwrap.sh` | `PASS: 122 FAIL: 0 SKIP: 4`（宿主无 Go 时复用预构建 CLI，golden 在宿主 CI 门运行） |
| `bash scripts/e2e/run-two-machines.sh` | `1..62`, `PASS: 62 FAIL: 0 SKIP: 0` |
| `grep` 退役产品模块引用 | 无输出 |
| `git ls-files` 预编译产物哨兵 | 无输出 |

Docker E2E 当前 `run-inside.sh` 全程使用 Go binary，覆盖用户态 sshd、真实
ControlMaster、payload 回环、doctor 应用层探活、client mapping、machines
`ssh://` URI、Go panel frame、watch 非 TTY 退化、HF1 serve、golden 438 和残留清理。
两机 E2E 保留真实 herdr/TUI/tmux 流程，覆盖激活、远端面板、端口映射、Ctrl+click、
断网重连、server 重启自愈和停用。

## 2. Phase 5 测试裁决

- `lib/*.sh` 10 个产品文件已删除；直接 source/调用这些内部函数的 Bash unit、
  integration 和 Bash-side difftest 退役。
- `tests/difftest/run.sh` 不再执行 Bash 对照器。438 个固定 case 逐一执行 Go CLI，
  与 `tests/difftest/golden.tsv` 中保存的 exit code + base64(stdout) 逐字节比对。
  `GOLDEN_UPDATE=1` 是显式维护动作，普通 CI 不会写 golden。
- §16.2 ports 测试只断言 JSON 的 `port`/`addr`；`process` 允许 `/proc` 路径的空值或
  平台工具提供的进程名，不放松端口/地址断言。
- `phase2-go-path.sh`、`phase3-go-path.sh` 及 Bash-side 协议脚本已退役；真 SSH、
  HF1 和两机流程由 Go integration/E2E 裁判。

## 3. Release / macOS 门

Release 资产和人工检查单见 [`docs/RELEASE-CHECKLIST.md`](RELEASE-CHECKLIST.md)。
真实 GitHub Release 的在线安装必须在主 agent 发布 `v0.2.0-go-mig` 后执行：

```sh
HERDR_E2E_ONLINE=1 bash scripts/e2e/run-real-install.sh
```

Linux CI 不能替代 §11 macOS smoke；macOS 必须人工验证 curl/checksum、tunnel add、
`lsof` ports、跨机 bridge、Ctrl+click、非 TTY watch 和 raw mode 清理。
