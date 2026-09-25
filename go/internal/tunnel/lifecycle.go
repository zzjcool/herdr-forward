// tunnel_start.go —— Start / Stop / Reap / Alive / Probe / Health / Doctor
// （← lib/tunnel.sh 的对应函数）。契约说明见 tunnel.go 顶部注释。
package tunnel

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/zzjcool/herdr-forward/internal/hfcommon"
)

// Alive 复刻 tunnel_alive：kill -0 且 /proc/<pid>/stat 的状态首字符不是 'Z'。
//
// 与 bash 一致：kill -0 的任何错误（ESRCH / EPERM）都算「死」（EPERM 的复刻理由见
// cli/view.go 的 pidAlive 注释）。pid <= 0 视为 false（bash 的正则 `^[0-9]+$` 会拒掉
// 负数与 0 之外的畸形值；0 是 `kill -0 0` 的进程组语义，绝不该被当成隧道）。
func Alive(pid int) bool {
	if pid <= 0 {
		return false
	}
	if err := syscall.Kill(pid, 0); err != nil {
		return false
	}
	data, err := os.ReadFile(fmt.Sprintf("/proc/%d/stat", pid))
	if err != nil {
		// bash 在 /proc 不可读（macOS 无 /proc）时直接判活 —— 保持同一形态。
		return true
	}
	// stat 的第 3 个字段是 state，但 comm（第 2 字段）可能含空格与括号，
	// 故从**最后一个** ')' 之后取第一个非空格字符（bash: `${stat_line##*) }`）。
	idx := strings.LastIndex(string(data), ") ")
	if idx < 0 {
		return true
	}
	rest := strings.TrimLeft(string(data)[idx+2:], " ")
	if rest == "" {
		return true
	}
	return rest[0] != 'Z'
}

// ctlCheck 跑 `ssh -O check`（带 5s 上限），返回合并的 stdout+stderr 与进程错误。
// bash 用 `_tunnel_ctl_ssh`（永远 return 0，让调用方拿 stderr 做正则匹配）。
func ctlCheck(ctlEscaped string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), ctlSSHTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, "ssh", "-F", "/dev/null", "-o", "BatchMode=yes",
		"-o", "ControlPath="+ctlEscaped, "-O", "check", "dummy@dummy")
	out, err := cmd.CombinedOutput()
	if ctx.Err() != nil {
		return string(out), fmt.Errorf("ssh -O check 超时（%s）", ctlSSHTimeout)
	}
	return string(out), err
}

// Start 复刻 tunnel_start：拉起 detach 的 ssh master，返回 master pid（die 5 语义）。
//
// 返回的 error 已经是**用户可见的完整文案**（与 bash 的 `die 5 "tunnel start failed: …"`
// 同形），调用方（cli.cmd_add）直接把它塞进「隧道启动失败（<id>）：<err>。…」即可。
func (m *Manager) Start(id string, lp int, rh string, rp int, sshTarget string) (int, error) {
	if _, err := exec.LookPath("ssh"); err != nil {
		return 0, ErrSSHMissing
	}
	args, err := SSHArgs(id, lp, fmt.Sprintf("%s:%d", rh, rp), sshTarget)
	if err != nil {
		return 0, err
	}
	dir, err := ControlDir()
	if err != nil {
		return 0, err
	}
	ctl := filepath.Join(dir, "ctl-"+id)
	ctlEscaped := SSHPathEscape(ctl)
	logFile := filepath.Join(dir, "log-"+id)
	pidFile := filepath.Join(dir, "pid-"+id)
	targetFile := filepath.Join(dir, "target-"+id)

	// 记录本次 start 用的 target（bash 亦然：调试时能看到最后一次尝试的目标）。
	if err := os.WriteFile(targetFile, []byte(sshTarget+"\n"), 0o600); err != nil {
		hfcommon.Logf("warn", "tunnel_start: 无法写入 %s: %v", targetFile, err)
	}
	// bash: `: >"${log_file}"` —— 另起一份日志（同隧道的旧输出不再关心）。
	logHandle, err := os.OpenFile(logFile, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
	if err != nil {
		return 0, fmt.Errorf("tunnel start failed: %s -> 127.0.0.1:%d via %s (无法打开日志 %s: %v)",
			id, lp, sshTarget, logFile, err)
	}
	defer func() { _ = logHandle.Close() }()

	devNull, err := os.Open(os.DevNull)
	if err != nil {
		return 0, fmt.Errorf("tunnel start failed: %s -> 127.0.0.1:%d via %s (无法打开 %s: %v)",
			id, lp, sshTarget, os.DevNull, err)
	}
	defer func() { _ = devNull.Close() }()

	cmd := exec.Command("ssh", args...)
	cmd.Stdin = devNull
	cmd.Stdout = logHandle
	cmd.Stderr = logHandle
	// PLAN §4：setsid 链（setsid/perl/python3/nohup）整体删除，改用新会话。
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := cmd.Start(); err != nil {
		return 0, fmt.Errorf("tunnel start failed: %s -> 127.0.0.1:%d via %s (ssh 无法启动: %v)",
			id, lp, sshTarget, err)
	}
	launcher := cmd.Process.Pid
	// bash 用 `disown` 让 launcher 不被自己回收；Go 侧用一个 goroutine Wait 回收，
	// 避免 launcher 变僵尸（ControlPersist 下它会很快退出）。
	go func() { _ = cmd.Wait() }()

	master := 0
	for i := 0; i < checkAttempts; i++ {
		state, _ := ctlCheck(ctlEscaped)
		if mm := reMaster.FindStringSubmatch(state); mm != nil {
			if n, convErr := strconv.Atoi(mm[1]); convErr == nil {
				master = n
				break
			}
		}
		if i < checkAttempts-1 {
			time.Sleep(checkInterval)
		}
	}

	if master == 0 {
		_ = syscall.Kill(launcher, syscall.SIGTERM)
		tailOut := tailLines(logFile, 5)
		msg := fmt.Sprintf("tunnel start failed: %s -> 127.0.0.1:%d via %s", id, lp, sshTarget)
		if tailOut != "" {
			msg += " (ssh: " + tailOut + ")"
		}
		return 0, fmt.Errorf("%s", msg)
	}

	// pid 文件是 tunnel_stop 的兜底线索；写失败只 warn（绝不让隧道白起）。
	if err := hfcommon.AtomicWrite(pidFile, []byte(strconv.Itoa(master)+"\n")); err != nil {
		hfcommon.Logf("warn", "tunnel_start: could not record pid %d in %s; tunnel_stop will fall back to the control socket only.", master, pidFile)
	}
	return master, nil
}

// tailLines 复刻 `tail -n 5 <file>`（文件不存在/读不到 -> 空串）。
func tailLines(path string, n int) string {
	data, err := os.ReadFile(path)
	if err != nil || len(data) == 0 {
		return ""
	}
	lines := strings.Split(strings.TrimSuffix(string(data), "\n"), "\n")
	if len(lines) > n {
		lines = lines[len(lines)-n:]
	}
	return strings.Join(lines, "\n")
}

// Stop 复刻 tunnel_stop：优雅 `ssh -O exit` → pid 兜底 TERM/KILL → 删伴生文件。
//
// 恒返回 nil（bash 的 tunnel_stop 恒 return 0：所有 kill/ssh 失败都被 `|| true` 吞掉），
// 返回值只为对齐冻结签名。ctl 不存在时不跑 ssh；pid 文件丢失时只删文件（并 warn）。
func (m *Manager) Stop(id string) error {
	dir, err := ControlDir()
	if err != nil {
		return nil
	}
	ctl := filepath.Join(dir, "ctl-"+id)
	pidFile := filepath.Join(dir, "pid-"+id)
	ctlEscaped := SSHPathEscape(ctl)

	// 优雅关闭：只有 socket 真的存在才值得花 5s 去 -O exit（bash 的 `[[ -S ctl ]]`）。
	if st, statErr := os.Stat(ctl); statErr == nil && st.Mode()&os.ModeSocket != 0 {
		ctx, cancel := context.WithTimeout(context.Background(), ctlSSHTimeout)
		cmd := exec.CommandContext(ctx, "ssh", "-F", "/dev/null", "-o", "BatchMode=yes",
			"-o", "ControlPath="+ctlEscaped, "-O", "exit", "dummy@dummy")
		cmd.Stdout = nil
		cmd.Stderr = nil
		_ = cmd.Run()
		cancel()
	}

	pid := readPidFile(pidFile)
	if pid > 0 && Alive(pid) {
		_ = syscall.Kill(pid, syscall.SIGTERM)
		for i := 0; i < stopWaitPolls; i++ {
			if !Alive(pid) {
				break
			}
			time.Sleep(stopWaitInterval)
		}
		_ = syscall.Kill(pid, syscall.SIGKILL)
	}

	// 两条路径都不可用时 master 可能还活着（比如 socket 已丢、pid 文件也丢了）：
	// 如实报出而不是假装隧道已停。
	if pid > 0 && Alive(pid) {
		hfcommon.Logf("warn", "tunnel_stop: ssh master %d (%s) is still alive after TERM/KILL; the tunnel may still be listening.", pid, id)
	}

	removeTunnelFiles(dir, id)
	return nil
}

// Reap 复刻 tunnel_reap：Stop + 对残留 pid 再补一刀 KILL + 删文件（幂等）。
func (m *Manager) Reap(id string, pid int) error {
	dir, err := ControlDir()
	if err != nil {
		return err
	}
	_ = m.Stop(id)
	if pid > 0 && Alive(pid) {
		_ = syscall.Kill(pid, syscall.SIGKILL)
	}
	removeTunnelFiles(dir, id)
	return nil
}

// removeTunnelFiles 复刻 tunnel_stop 末尾的 rm -f（**刻意保留** known_hosts）。
func removeTunnelFiles(dir, id string) {
	for _, name := range []string{"ctl-" + id, "pid-" + id, "target-" + id, "log-" + id} {
		_ = os.Remove(filepath.Join(dir, name))
	}
}

// readPidFile 读 pid-<id>：bash 用 `[[ ${pid} =~ ^[0-9]+$ ]]` 判定，非纯数字视为无 pid。
func readPidFile(path string) int {
	data, err := os.ReadFile(path)
	if err != nil {
		return 0
	}
	text := strings.TrimSpace(string(data))
	if text == "" {
		return 0
	}
	for i := 0; i < len(text); i++ {
		if text[i] < '0' || text[i] > '9' {
			return 0
		}
	}
	n, err := strconv.Atoi(text)
	if err != nil {
		return 0
	}
	return n
}

// Probe 复刻 tunnel_probe：经本地转发端口发真 payload（契约 C7 / A.3.1）。
func (m *Manager) Probe(lp int) hfcommon.Health {
	return hfcommon.ProbePayload("127.0.0.1", lp, probeTimeoutSec)
}

// Health 复刻 tunnel_health：master 不活一律 down，否则透传 probe 的三级结果。
func (m *Manager) Health(id string, pid, lp int) hfcommon.Health {
	if !Alive(pid) {
		return hfcommon.HealthDown
	}
	return m.Probe(lp)
}
