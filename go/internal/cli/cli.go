package cli

import (
	"fmt"
	"os"
)

// Version 是 CLI 版本号，由 cmd/forward 在启动时用构建注入的 main.version 覆盖。
var Version = "dev"

// Main 是 CLI 入口，返回值即进程退出码（契约 C2：0 ok / 64 用法 / ...）。
//
// Phase 0 空转语义：仅识别版本查询，其余一律打印脚手架提示并以 0 退出 ——
// 本阶段没有任何真实子命令逻辑，也还没有任何 bash 代码 dispatch 到本二进制
// （bin/forward 的 dispatch 行从 Phase 1 起逐子命令添加），因此对用户零行为变化。
func Main(args []string) int {
	if len(args) > 0 {
		switch args[0] {
		case "--version", "-v", "version":
			fmt.Printf("forward %s (scaffold)\n", Version)
			return 0
		case "help", "--help", "-h":
			fmt.Fprint(os.Stdout, usage())
			return 0
		}
	}
	fmt.Fprint(os.Stderr, usage())
	return 0
}

func usage() string {
	return fmt.Sprintf(`forward %s (scaffold)

herdr-forward Go 版 CLI 尚在脚手架阶段（docs/PLAN-GO-MIGRATION.md Phase 0）：
真实子命令 dispatch 后续 phase 实现。当前仅支持：
  forward --version    打印版本
`, Version)
}
