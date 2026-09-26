# herdr-forward Release 检查单

适用于 `v*` GitHub Release；Phase 5 的本地终态 tag 为
`go-mig/phase5` / `v0.2.0-go-mig`（按任务要求不 push）。真实发布由主 agent
决定并执行。

## 发布前（本地、无网络也可）

- [ ] `make check` 通过（gofmt/vet/test/vendor-check）。
- [ ] `bash tests/run.sh unit` 通过。
- [ ] `bash tests/run.sh integration` 通过（真实 sshd、ssh -L、HF1 bridge）。
- [ ] `bash tests/difftest/run.sh` 输出 `1..438`、`PASS: 438 FAIL: 0`。
- [ ] `bash scripts/ci.sh` 通过；docker 主路径已经跑过；无 docker 时单独跑
      `bash scripts/e2e/run-bwrap.sh`。
- [ ] `git ls-files | grep -E '(^|/)(forward-go|dist/)'` 无输出。
- [ ] `grep -R 'lib/.*\.sh' bin scripts tests docs README.md` 无输出。
- [ ] manifest 的 `version` 与 Release 资产版本保持一致；当前 Go 起点为 `0.2.0`。

## Release 资产与安装器

- [ ] GoReleaser 生成：
  `herdr-forward_<version>_{linux,darwin}_{amd64,arm64}.tar.gz` 四个包。
- [ ] 每个包含单一可执行文件 `forward`（以及 LICENSE/README），不含 `forward-go`。
- [ ] `checksums.txt` 上传且包含四个 archive 的 SHA-256。
- [ ] 用本地 HTTP 镜像复跑 `tests/unit/test_postinstall.sh`：正常下载、checksum
      不符、无 curl/wget、`HERDR_FORWARD_SKIP_DOWNLOAD=1` 四条路径。
- [ ] `HERDR_FORWARD_BIN_BASE=<mirror>/...` 能覆盖下载根；成功后
      `bin/forward-go` 为 0755，键位安装随后执行 `forward internal install-keys`。
- [ ] 下载/校验/解包失败为 exit 1，stderr 含 `git clone` + `make build` 手动恢复路径。

## 真实 GitHub Release 安装门

在隔离 HOME 中运行（只允许主 agent 在确认 Release 已发布后执行）：

```sh
HERDR_E2E_ONLINE=1 bash scripts/e2e/run-real-install.sh
```

必须覆盖：

- [ ] 已运行 herdr server 上安装新版本，无需重启即可 `prefix+f`。
- [ ] 旧版本升级时 plugin checkout 更新，`forward-go` 重新下载/校验，键位幂等，
      server reload-config 成功。
- [ ] 新用户安装时同样下载/校验/安装键位/reload，Port Forward 面板能打开。
- [ ] 面板按 Enter 不退出，x 能退出；无 saved machine 给出 machine add 引导。

## §11 macOS 手动 smoke（发布门，非 CI）

逐条执行 PLAN-GO-MIGRATION §11 的清单：

1. `herdr plugin install zzjcool/herdr-forward`：验证 curl 下载、checksum、键位、reload。
2. `forward add 13000:9443 --ssh-target user@host`：验证 tab bar `⇅13000`、面板显示、
   remove 后无残留。
3. `forward ports`：核对 Go 的 `lsof` 路径与 Activity Monitor。
4. A(mac) 激活 B：验证 bridge client 的 localhost 端口与 Ctrl+click。
5. 非 TTY `forward watch` 退化正常；raw mode 退出后 termios 无残留。

## 已知边界

- CI 没有 macOS runner；macOS smoke 是 Release 门，不可用 Linux 结果替代。
- 真实 GitHub Release 的 tag/push/发布决定不在 worker Phase 5 本地工作区内完成。
