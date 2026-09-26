# Phase 5 交付报告

## 做了什么

- 删除产品 Bash 模块 11 个（main 实际目录计数，原计划「10」为笔误）：共删除 4,702 行
  （`git diff --numstat`：1190 + 409 + 128 + 748 + 117 + 883 + 145 + 64 + 276 + 354 + 388）。
- `bin/forward` 从 1,814 行 Bash dispatch 收缩为 9 行 POSIX shim；无
  `bin/forward-go` 时明确提示 reinstall/local build 并 exit 127。
- `scripts/postinstall.sh` 重写为 POSIX Release bootstrap：平台映射、manifest version、
  curl/wget fallback、sha256sum/shasum、临时目录解包、镜像覆盖、离线开关、exit 1 恢复指引，
  下载成功后 Go 安装器写键位并 reload-config。
- 删除 `scripts/setup-client.sh`（588 行）及 29 个 Bash 内部函数单测/集成/difftest
  helper（11,582 行）；纯删除合计 41 files / 16,872 lines。保留 Go integration、
  Docker/bwrap E2E 与两机 62 条用户流程。`tests/assertions.sh` 移到测试根，避免伪装为产品
  `lib/`。
- `tests/difftest/run.sh` 改成 Go-only golden contract；438 cases 的当前 Go stdout/exit
  固化到 `tests/difftest/golden.tsv`（base64 stdout，空 stdout 用 `-` 表示）。
- §16.2 ports 测试只断言 JSON `port`/`addr`，PROCESS 允许平台相关形态。
- 删除 CI 的 `forward-go` 暂存适配器；lint/shfmt 目标仅剩 shim、postinstall、wrapper、
  E2E/test runner；Go startup hook 移除已退役 Bash module 存在性探针。
- README、ARCHITECTURE、PLAN、E2E results、release checklist 更新；version bump 到 0.2.0。

## 测试覆盖

- Unit：Go shim、Release 下载成功、checksum 错误、无 curl/wget、SKIP_DOWNLOAD、安装器、
  link manifest、runner。
- Integration：真实 sshd/ssh -L、payload round-trip、ControlMaster、percent state dir、
  bridge HF1/client mapping、tab-bar state dir。
- E2E：Docker 130 条；bwrap 122 条通过 + 4 条因宿主无 Go 工具链的显式 SKIP（预构建 Go CLI
  仍用于完整用户路径）；两机真实 herdr/TUI/tmux 62 条。
- Release smoke 清单：`docs/RELEASE-CHECKLIST.md`。真实 GitHub Release 在线安装由主 agent
  在发布决策后执行，不在本地 worker 阶段伪造。

## 验收输出（原样摘要）

```text
$ npm run typecheck && npm test
> herdr-forward@0.2.0 typecheck
> cd go && go vet -mod=vendor ./...
> herdr-forward@0.2.0 test
> cd go && go test -mod=vendor ./...
[all Go packages] ok

$ make check
... go mod verify
all modules verified
vendor-check OK（go/vendor 与 go.mod/go.sum 一致）

$ bash tests/run.sh unit
=== summary ===
files: 8  failed: 0

$ bash tests/run.sh integration
=== summary ===
files: 4  failed: 0

$ bash tests/difftest/run.sh
1..438
# PASS: 438 FAIL: 0
# RESULT: PASS（Go 输出与固化 golden 逐字节一致）

$ bash scripts/e2e/run-docker.sh
1..130
# PASS: 130 FAIL: 0 SKIP: 0
# RESULT: PASS
[e2e-docker] 容器退出码：0

$ bash scripts/e2e/run-bwrap.sh
1..126
# PASS: 122 FAIL: 0 SKIP: 4
# RESULT: PASS
[e2e-bwrap] 沙箱退出码：0

$ bash scripts/e2e/run-two-machines.sh
1..62
# PASS: 62 FAIL: 0 SKIP: 0
# RESULT: PASS

$ bash scripts/ci.sh
sentinel 通过（E2E=docker；无 Bash 模块引用；无预编译产物）
CI OK: 6/6 全部通过
```

终态静态门：

```text
$ grep -RIn --exclude=ci.sh -E 'lib/[[:alnum:]_.-]+\.sh' bin scripts tests docs README.md
(no output)
$ git ls-files | grep -E '(^|/)(forward-go|dist/)'
(no output)
$ wc -l bin/forward
9 bin/forward
```

## Golden 化方案

旧 Bash 对照器、phase2/phase3 Bash path probe 随产品 Bash 退役；不是放松断言，而是把
438 个既有迁移护栏的当前 Go 输出固化为可审阅文件。每个 case 独立临时 state dir，runner
比较进程退出码和 stdout 的逐字节 base64。普通 CI 只读 `golden.tsv`；只有明确设置
`GOLDEN_UPDATE=1` 才能重写整个 golden 文件。

## Release 检查单

见 `docs/RELEASE-CHECKLIST.md`，包括四平台资产命名/checksums、本地 HTTP 镜像安装失败路径、
真实 GitHub Release `HERDR_E2E_ONLINE=1` 场景，以及 PLAN §11 的 macOS smoke。

## 有意偏离

1. Phase 5 原始文字要求删除 difftest 段；本实现保留并改为 Go-only golden，因为逐字节护栏
   是终局契约，删除会降低而非保持保障。
2. `tests/assertions.sh` 从 `tests/lib/` 移到 `tests/`，因为产品 `lib/` 已完全退役；测试
   harness 仍是 Bash，但不再是产品模块。
3. bwrap 宿主无 Go 时只显示 4 个显式工具链限制 SKIP；Docker/宿主 CI 的 golden、Go build
   与两机 E2E 均为绿色，未静默跳过业务断言。
4. 真实 GitHub Release 的 push/tag 发布与在线安装不是本 worker 的权限边界，留给主 agent；
   本地 Release HTTP server 已覆盖成功、无下载器、checksum 不符、SKIP_DOWNLOAD。

## Commit / tag / MR

- Commit: `feat(go): Phase 5 bash 退役 + postinstall Releases 下载 + difftest golden 化` (HEAD；见 git log)
- Local tags (not pushed): `go-mig/phase5`, `v0.2.0-go-mig`
- MR/PR: 按任务硬要求不 push 分支或 tag，故没有远端 MR；主 agent 收口时直接使用该 commit。
