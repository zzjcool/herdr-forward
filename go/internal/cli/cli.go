// cli.go — Go 版 CLI 的 dispatch 层（← bin/forward main()/die()/usage()）。
//
// 迁移阶段（PLAN-GO-MIGRATION §6 Phase 1 / §10 W4）的职责边界：
//
//   - 本包**只实现已迁移子命令**（Phase 1：list / ports），其余子命令在下面的 switch 里
//     有显式条目但一律「哨兵退出 9（未实现）」。生产路径上用户永远看不到这条哨兵：
//     bin/forward 只对 `list|ports` 做 `exec bin/forward-go`，别的子命令仍由 bash 处理。
//     为什么仍然把它们列全：① 契约 C1 的 15 个子命令清单要有单一落点，便于后续 phase
//     逐个替换；② unit 测试可以钉住「未迁移子命令绝不悄悄做错事」。
//   - `help` 的输出是字节级冻结契约（usage.go 的 usageText），`internal` 是差分测试
//     探针入口（internal/difftest），`version` 是 Go 侧新增（bash 无此子命令，见报告）。
//
// 退出码契约 C2：0 ok / 2 重复端口 / 3 记录不存在 / 4 machine 无法解析 / 5 隧道启动失败 /
// 9 未实现 / 64 用法错误 / 127 依赖缺失；其余内部错误 1。
package cli

import (
	"fmt"
	"os"

	"github.com/zzjcool/herdr-forward/internal/difftest"
	"github.com/zzjcool/herdr-forward/internal/hfcommon"
)

// Version 是 CLI 版本号，由 cmd/forward 在启动时用构建注入的 main.version 覆盖。
var Version = "dev"

// 退出码（契约 C2 / lib/common.sh 的 die 语义）。
const (
	exitOK             = 0
	exitError          = 1
	exitDuplicatePort  = 2
	exitNotFound       = 3
	exitMachineResolve = 4
	exitTunnelFailed   = 5
	exitNotImplemented = 9
	exitUsage          = 64
	exitMissingDep     = 127
)

// unmigrated 是「在 Bash 侧实现、Go 侧尚未迁移」的子命令集合（C1 的 15 项之一部分）。
//
// Phase 3 之后只剩 2 个：watch / bootstrap（Phase 4 的交互面板 + 安装器）。
// 它们出现在 dispatch 表里只为了让契约清单完整、并让哨兵行为可测：生产路径由
// bin/forward 的白名单保证不会走到这里。
var unmigrated = map[string]bool{
	"watch":     true,
	"bootstrap": true,
}

// Main 是 CLI 入口，返回值即进程退出码。
func Main(args []string) int {
	if len(args) == 0 {
		// bash: `usage >&2` 后 `die 64 "缺少子命令。…"`（两段都进 stderr）
		fmt.Fprint(os.Stderr, usageText)
		return die(exitUsage, "缺少子命令。请从 add / list / remove / doctor 中选择（'forward --help' 查看全部）。")
	}

	sub := args[0]
	rest := args[1:]

	if unmigrated[sub] {
		return die(exitNotImplemented, fmt.Sprintf(
			"子命令 %s 尚未迁移到 Go（应由 bin/forward 的 bash 实现处理）；这条哨兵不该被用户看到，请报告。", sub))
	}

	switch sub {
	case "add":
		return cmdAdd(rest)
	case "list":
		return cmdList(rest)
	case "remove":
		return cmdRemove(rest)
	case "doctor":
		return cmdDoctor(rest)
	case "publish":
		return cmdPublish(rest)
	case "unpublish":
		return cmdUnpublish(rest)
	case "ports":
		return cmdPorts(rest)
	case "machines":
		return cmdMachines(rest)
	case "bridge":
		return cmdBridge(rest)
	case "open-url":
		return cmdOpenURL(rest)
	case "help", "--help", "-h":
		// bash: usage 到 stdout，return 0
		fmt.Print(usageText)
		return exitOK
	case "version", "--version", "-v":
		// Go 侧新增（bash 的 main() 没有 version 分支）；bin/forward 也不 dispatch 它，
		// 因此对用户零行为变化。见报告「有意偏离」。
		fmt.Printf("forward %s\n", Version)
		return exitOK
	case "internal":
		// 差分测试探针入口（tests/difftest/run.sh 优先用 `bin/forward-go internal difftest …`）
		return difftest.Main(args)
	default:
		fmt.Fprint(os.Stderr, usageText)
		return die(exitUsage, fmt.Sprintf("未知子命令：%s。请运行 'forward --help' 查看可用子命令。", sub))
	}
}

// die 复刻 lib/common.sh 的 die：log error + 返回退出码（bash 是 exit，这里交给调用方）。
//
// 复刻说明：bash 的 `log error` 在 HERDR_PLUGIN_STATE_DIR 缺失时会**打印两次**到 stderr
// （先走「无 env」分支，再走末尾的 warn/error 镜像分支），hfcommon.Log 已保持该行为。
func die(code int, msg string) int {
	hfcommon.Log("error", msg)
	return code
}
