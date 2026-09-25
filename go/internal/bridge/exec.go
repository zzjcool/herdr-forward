// exec.go —— 桥接用到的进程/端口原语（← lib/bridge.sh 的 _bridge_ctl_exit / _bridge_mux /
// _bridge_open_url 的 detach 部分 + lib/common.sh 的 probe_tcp）。
package bridge

import (
	"fmt"
	"net"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// mux 复刻 _bridge_mux：在已建立的 master 上增删一条 `-L`。
//
// 返回值：空串 = 成功；非空 = 失败原因（**单行、最多 160 字符**，与 bash 的
// `out="${out//$'\n'/ }"; printf '%s\n' "${out:0:160}"` 逐字对齐）。
func mux(controlPath, op string, localPort, remotePort int) string {
	argv := MuxArgv(controlPath, op, localPort, remotePort)
	out, ok := runWithTimeout(muxTimeout, argv)
	if ok {
		return ""
	}
	flat := strings.ReplaceAll(out, "\n", " ")
	return clip(flat, 160)
}

// ctlExit 复刻 _bridge_ctl_exit：请该 socket 上的 master 退出（socket 不存在则什么都不做）。
func ctlExit(controlPath string) {
	if _, err := osStatSocket(controlPath); err != nil {
		return
	}
	_, _ = runWithTimeout(ctlExitTimeout, CtlExitArgv(controlPath))
}

// osStatSocket 判定路径存在且是 socket（bash 的 `[[ -S ${ctl} ]]`）。
//
// 与 bash 的细微差异：bash 的 -S 只判「存在 + 是 socket」，不判可访问性；Go 的
// os.Stat 在真实环境里对同一路径的结论完全一致（都是「socket 文件已删/未建 → 不调用」）。
func osStatSocket(path string) (bool, error) {
	info, err := os.Stat(path)
	if err != nil {
		return false, err
	}
	if info.Mode()&os.ModeSocket == 0 {
		return false, fmt.Errorf("not a socket")
	}
	return true, nil
}

// runWithTimeout 跑一条 argv，返回合并输出与「是否成功」。恒不 panic、有硬上限。
func runWithTimeout(d time.Duration, argv []string) (string, bool) {
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
	case <-time.After(d):
		_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
		<-done
		return buf.String(), false
	}
}

// portBusy 复刻 `probe_tcp 127.0.0.1 <port> 1`：A 侧端口是否已被**别的进程**占着。
//
// 为什么这是桥接必需的：`ssh -O forward -L` 在本地端口被占时会失败，而失败原因是
// 「A 的端口被占」这个**用户能自己解决**的事实 —— 因此要提前探测并把原因如实报给 B
// （而不是把它当成 ssh 的通用错误）。
func portBusy(port int) bool {
	conn, err := net.DialTimeout("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(port)), time.Second)
	if err != nil {
		return false
	}
	_ = conn.Close()
	return true
}

// detachExec 复刻 hf_detach_exec 的使用形态：把 opener 放到新会话里跑，并**关掉会话 fd**。
//
// bash 的原始动机（注释留痕）：浏览器等长寿子进程若继承了 ssh stdin 的写端，会话就
// 收不到 EOF。Go 侧对应「不给子进程继承任何桥接管道」—— exec.Cmd 默认只继承
// stdin/stdout/stderr，而这里三个都接到 /dev/null，所以天然没有这个问题；
// Setsid 仍保留（脱离调用方的进程组与控制终端，面板/popup 关闭时的信号带不走它）。
func detachExec(name string, args ...string) {
	cmd := exec.Command(name, args...)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	devNull, err := os.OpenFile(os.DevNull, os.O_RDWR, 0)
	if err == nil {
		cmd.Stdin = devNull
		cmd.Stdout = devNull
		cmd.Stderr = devNull
	}
	if err := cmd.Start(); err != nil {
		return
	}
	go func() { _ = cmd.Wait() }()
	if devNull != nil {
		// 子进程已拿到 fd 副本，父进程侧可以立刻关掉（避免 fd 泄漏）；
		// 子进程自己持有到退出为止。
		_ = devNull.Close()
	}
}
