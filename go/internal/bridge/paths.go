// paths.go —— 桥接的路径解析与状态文件读写（← lib/bridge.sh 的路径段 + 会话/客户端文档）。
//
// 状态文件（A.3.3「单 writer」）：
//
//	B 侧  $(state_dir)/bridge/session-<serve pid>.json   每条 serve 一份（多 client 互不覆盖）
//	A 侧  $(state_dir)/bridge/client-<machine>.json      supervisor 状态 + 已生效映射
//	      $(state_dir)/bridge/client-<machine>.lock/pid  单实例锁（mkdir 原子）
//	      $(state_dir)/bridge/client-<machine>.ssh.log   最近一次连接的 ssh stderr
//	      $(state_dir)/bridge/open/<epoch>-<rand>.url    待转发的打开请求（B 侧队列）
//
// ControlMaster socket 路径有个真实约束：Unix socket 路径上限约 104-108 字节，且 ssh 建
// master 时会再追加 ~17 字节随机后缀，state 目录较深时（herdr 的 `zzjcool%3Aforward`）
// 必须退到 `${TMPDIR:-/tmp}/hf-<uid>/`（与 bash 的 88 字节阈值一致）。
package bridge

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"

	"github.com/zzjcool/herdr-forward/internal/hfcommon"
)

// Dir 复刻 bridge_dir：$(state_dir)/bridge（首次使用时建 700 目录）。
func Dir() string {
	dir := filepath.Join(hfcommon.StateDir(), "bridge")
	if st, err := os.Stat(dir); err != nil || !st.IsDir() {
		_ = os.MkdirAll(dir, 0o700)
		_ = os.Chmod(dir, 0o700)
	}
	return dir
}

// SafeID 复刻 _bridge_safe_id：非 [A-Za-z0-9_.-] 一律换成下划线（用于拼文件名）。
func SafeID(raw string) string {
	return strings.Map(func(r rune) rune {
		switch {
		case r >= 'A' && r <= 'Z', r >= 'a' && r <= 'z', r >= '0' && r <= '9':
			return r
		case r == '_' || r == '.' || r == '-':
			return r
		default:
			return '_'
		}
	}, raw)
}

// SessionFile 复刻 bridge_session_file：bridge/session-<pid>.json。
func SessionFile(pid string) string {
	return filepath.Join(Dir(), "session-"+pid+".json")
}

// ClientFile 复刻 bridge_client_file：bridge/client-<safe(machine)>.json。
func ClientFile(machine string) string {
	return filepath.Join(Dir(), "client-"+SafeID(machine)+".json")
}

// ClientLock 复刻 bridge_client_lock：bridge/client-<safe(machine)>.lock（目录）。
func ClientLock(machine string) string {
	return filepath.Join(Dir(), "client-"+SafeID(machine)+".lock")
}

// ClientLog 复刻 bridge_client_log：bridge/client-<safe(machine)>.ssh.log。
func ClientLog(machine string) string {
	return filepath.Join(Dir(), "client-"+SafeID(machine)+".ssh.log")
}

// ControlPath 复刻 bridge_control_path：ControlMaster 的 socket 路径（含长度退避）。
//
//	bash: dir=$(state_dir)/ssh-ctl; path="${dir}/b-${mid:0:12}"
//	      if ((${#path} > 88)); then dir="${TMPDIR:-/tmp}/hf-${UID}"; ... fi
func ControlPath(machine string) string {
	safe := SafeID(machine)
	if len(safe) > 12 {
		safe = safe[:12]
	}
	dir := filepath.Join(hfcommon.StateDir(), "ssh-ctl")
	path := filepath.Join(dir, "b-"+safe)
	if len(path) > 88 {
		dir = filepath.Join(tmpDir(), fmt.Sprintf("hf-%d", os.Getuid()))
		path = filepath.Join(dir, "b-"+safe)
	}
	if st, err := os.Stat(dir); err != nil || !st.IsDir() {
		_ = os.MkdirAll(dir, 0o700)
		_ = os.Chmod(dir, 0o700)
	}
	return path
}

// tmpDir 复刻 `${TMPDIR:-/tmp}`（空串按未设置处理）。
func tmpDir() string {
	if dir := os.Getenv("TMPDIR"); dir != "" {
		return dir
	}
	return "/tmp"
}

// SSHEscape 复刻 _bridge_ssh_escape：% 翻倍。
//
// 为什么需要：ssh 对 ControlPath 做 `%` token 展开，而 herdr 的插件 state 目录名里
// 就有 `%3A` —— 不转义的话 ssh 会把 `%3` 当 token，路径直接错位。
func SSHEscape(path string) string {
	return strings.ReplaceAll(path, "%", "%%")
}

// Hostname 复刻 _bridge_hostname：$HOSTNAME，缺失时 uname -n，再把空白换成下划线。
func Hostname() string {
	name := os.Getenv("HOSTNAME")
	if name == "" {
		if out, ok := runBounded(2, "uname", "-n"); ok {
			name = strings.TrimRight(out, "\n")
		}
	}
	name = strings.Join(strings.Fields(name), "_")
	if name == "" {
		return "unknown"
	}
	return name
}

// OpenDir 复刻 `$(bridge_dir)/open`：待转发的打开请求队列（B 侧）。
func OpenDir() string { return filepath.Join(Dir(), "open") }

// runBounded 跑一条外部命令并返回 stdout（有 timeout(1) 就限时执行；macOS 默认没有
// timeout —— 与 lib/bridge.sh 的 _bridge_bounded 同一兜底策略）。恒不阻塞过久。
func runBounded(secs int, name string, args ...string) (string, bool) {
	if _, err := exec.LookPath(name); err != nil {
		return "", false
	}
	argv := []string{name}
	argv = append(argv, args...)
	if _, err := exec.LookPath("timeout"); err == nil {
		argv = append([]string{"timeout", fmt.Sprintf("%d", secs)}, argv...)
	}
	cmd := exec.Command(argv[0], argv[1:]...)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	out, err := cmd.Output()
	if err != nil {
		return "", false
	}
	return string(out), true
}
