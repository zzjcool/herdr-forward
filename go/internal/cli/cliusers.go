// cliusers.go —— cli 包内的函数式 helper（Phase 3 新增）。
//
// 为什么不直接调 os/exec 的裸 API：这些 helper 把「有界执行」「输出转发到 stderr」
// 「sh 引用」这三类重复形态收口到一处，并保持与 lib/common.sh / lib/bridge.sh 的
// 同名原语（_bridge_bounded / _bridge_sq / hf_detach_exec）逐条对齐。
package cli

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/zzjcool/herdr-forward/internal/bridge"
)

// runBoundedArgv 复刻 `_bridge_bounded <secs> <cmd...>`：有 timeout(1) 就限时执行。
//
// 返回 (合并输出, 是否成功)。
func runBoundedArgv(secs int, argv []string) (string, bool) {
	return runBoundedArgvSecs(secs, argv)
}

// runBoundedArgvOut 是 runBoundedArgv 的显式命名版（读代码时一眼看出「要输出」）。
func runBoundedArgvOut(secs int, argv []string) (string, bool) {
	return runBoundedArgvSecs(secs, argv)
}

// runBoundedArgvSecs 跑一条 argv 并返回合并的 stdout+stderr 与成功标记。
//
// 实现走 Go 的进程 + 计时器（而不是 exec 一个 `timeout`）：语义与 bash 的
// `timeout N cmd` 一致（超时即 kill），且不依赖宿主是否有 coreutils。
func runBoundedArgvSecs(secs int, argv []string) (string, bool) {
	if len(argv) == 0 {
		return "", false
	}
	if _, err := exec.LookPath(argv[0]); err != nil {
		return argv[0] + ": 未找到", false
	}
	cmd := exec.Command(argv[0], argv[1:]...)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	var buf strings.Builder
	cmd.Stdout = &buf
	cmd.Stderr = &buf
	if err := cmd.Start(); err != nil {
		return err.Error(), false
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	select {
	case err := <-done:
		return buf.String(), err == nil
	case <-time.After(time.Duration(secs) * time.Second):
		_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
		<-done
		return buf.String(), false
	}
}

// bridgeSSHDestination 复刻 bridge_ssh_destination（cli 层直接用 bridge 包的实现）。
func bridgeSSHDestination(target string) string { return bridge.SSHDestination(target) }

// shellQuote 复刻 _bridge_sq：POSIX sh 单引号字面量。
func shellQuote(s string) string { return bridge.ShQuote(s) }

// shellQuoteValue 复刻 `env 'KEY=value'` 里的那个引号形态（值整体引用，含 KEY=）。
func shellQuoteValue(s string) string { return bridge.ShQuote(s) }

// bridgeUp 复刻 bridge_up：后台启动 supervisor；返回 (一行回执, 是否成功)。
func bridgeUp(machineID string) (string, bool) {
	return bridge.Up(machineID, binForwardPath())
}

// bridgeDown 复刻 bridge_down。
func bridgeDown(machineID string) { bridge.Down(machineID) }

// bridgeMachines 复刻 `bridge_clients_json | jq -r '.[].machine'`。
func bridgeMachines() []string { return bridge.Machines() }

// bridgeLockHolder 复刻 _bridge_lock_holder（暴露给本包的命令层用）。
func bridgeLockHolder(machine string) string { return bridge.LockHolder(machine) }

// binForwardPath 返回本 CLI 对应的 `bin/forward` 路径（面板/startup hook 都这么调）。
//
// 为什么是 bin/forward 而不是自己：supervisor 是 setsid 出去的长驻进程，用 bin/forward
// 可以让它继续经过 dispatche shim（迁移期回滚点仍在）。
func binForwardPath() string {
	if root := pluginRootOfSelf(); root != "" {
		return root + "/bin/forward"
	}
	if exe, err := os.Executable(); err == nil {
		return exe
	}
	return "forward"
}

// stderr 是 os.Stderr 的短名（便于 printf 风格的两行写法保持可读）。
func stderr() *os.File { return os.Stderr }

// isTerminal 判定 fd 是否是字符设备（TTY）。
//
// bash 用 `[[ -t 0 ]]`；Go 侧对 os.Stdin 做同样的 ModeCharDevice 判定。
func isTerminal(f *os.File) bool {
	info, err := f.Stat()
	if err != nil {
		return false
	}
	return info.Mode()&os.ModeCharDevice != 0
}

// setEnv 设置环境变量（失败只在极少数平台发生，调用方按「尽力」处理）。
func setEnv(key, value string) error { return os.Setenv(key, value) }

// getEnv 读环境变量（空串按未设置，与 bash 的 `${VAR:-}` 一致）。
func getEnv(key string) string { return os.Getenv(key) }

// nb 用于调试（保留 fmt 引用，避免 import 抖动）。
var _ = fmt.Sprintf

// signalContext 返回一个在收到 TERM/HUP/INT 时取消的 context。
//
// 对位 bash 的 `trap 'exit 0' TERM HUP INT PIPE` / `trap '_bridge_run_stop' TERM INT`：
// serve 与 run 都是常驻进程，收到信号要**干净地**收尾（serve 删会话文件、
// run 关 master + 删锁），而不是被默认动作直接打死留下残骸。
func signalContext() context.Context {
	ctx, cancel := context.WithCancel(context.Background())
	ch := make(chan os.Signal, 1)
	signal.Notify(ch, syscall.SIGTERM, syscall.SIGHUP, syscall.SIGINT, syscall.SIGPIPE)
	go func() {
		<-ch
		cancel()
	}()
	return ctx
}
