// Command forward 是 herdr-forward 的 Go 版 CLI 入口。
//
// Bash 对位：bin/forward（main/dispatch 层，1737 行起）。
// 迁移阶段：Phase 0 仅空转脚手架 —— 打印版本后即退出，真实子命令 dispatch
// 由 Phase 1 起在 internal/cli 内实现（冻结签名见 docs/PLAN-GO-MIGRATION.md §5）。
//
// 退出码契约 C2 由 internal/cli.Main 的返回值承载（本文件只做 os.Exit 转发）。
package main

import (
	"os"

	"github.com/zzjcool/herdr-forward/internal/cli"
)

// version 由构建时注入：ldflags -X main.version=<tag>（见 .goreleaser.yml / Makefile）。
var version = "dev"

func main() {
	cli.Version = version
	os.Exit(cli.Main(os.Args[1:]))
}
