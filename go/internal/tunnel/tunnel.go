// Package tunnel —— exec ssh ControlMaster 生命周期（← lib/tunnel.sh）。
//
// 行为权威是 lib/tunnel.sh 的原文（迁移期铁律：零行为变化），因此这里逐条复刻它，
// 包括看起来多余的细节：
//
//   - control dir = $HERDR_PLUGIN_STATE_DIR/ssh-ctl（首次使用时 0700）；ctl 文件叫
//     ctl-<id>，另有 pid-<id> / target-<id> / log-<id> 三个伴生文件；
//   - 交给 ssh 的路径值（ControlPath / UserKnownHostsFile）必须把 `%` 翻倍
//     （herdr 的 state 目录名是 URL 编码的 `zzjcool%3Aforward`，ssh 会做 percent
//     token 展开并因 `%3` 直接失败）；文件系统操作继续用未转义的原路径；
//   - ssh argv 的逐 flag 顺序与取值与 bash 完全一致（见 SSHArgs）；
//   - 后台 ssh 用 SysProcAttr{Setsid:true} 起新会话，**不再**保留 bash 的
//     setsid/perl/python3/nohup 四级兜底链（PLAN §4 依赖映射；macOS 无 setsid 的
//     兼容 hack 随之消失）；
//   - Stop = `ssh -O exit`（5s 上限）→ pid 文件 TERM（≤3s 轮询）→ KILL → 删
//     ctl/pid/target/log（**刻意保留** known_hosts：它是跨隧道共用的沙箱 host key 缓存）；
//   - master pid 只能靠 `ssh -O check` 的 `Master running (pid=N)` 发现，因为
//     ControlPersist=yes 会让最初的 launcher 迅速退出（bash 亦然）。
//
// 有意偏离（已在报告登记；无用户可见契约变化）：
//   - `ssh -O check` / `-O exit` 加 5s 上限（bash 只有 -O exit 有 `timeout 5`）；
//   - Start 用 goroutine Wait 回收 launcher（bash 靠 disown + 自身退出让 init 收养）；
//   - Doctor 的 status 字段缺失时用 ""（bash 的 `jq -r .status` 会打印 "null"）。
package tunnel

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/zzjcool/herdr-forward/internal/hfcommon"
)

// ErrSSHMissing 是 `require_cmd ssh` 失败的载体（bash: die 127）。调用方
// （cli 的 cmd_add）**不**直接把它映射成 127 —— bash 的 cmd_add 把 tunnel_start
// 的任何非零 rc 统一转成 die 5，Go 保持同一形态。
var ErrSSHMissing = errors.New("缺少依赖命令：ssh。请先安装后重试（如 apt/pacman/brew install ssh）。")

// ctlDirName 是 control dir 的目录名（← lib/tunnel.sh 的 `ssh-ctl`）。
const ctlDirName = "ssh-ctl"

// 重试旋钮：生产值与 lib/tunnel.sh 一致；单测可缩小它们以避免 5s/3s 的真实等待。
var (
	checkAttempts    = 50                     // tunnel_start 轮询 `-O check` 的次数
	checkInterval    = 100 * time.Millisecond // 每次间隔（bash: sleep 0.1）
	stopWaitPolls    = 30                     // tunnel_stop TERM 后的轮询次数（≤3s）
	stopWaitInterval = 100 * time.Millisecond // bash: sleep 0.1
	ctlSSHTimeout    = 5 * time.Second        // `-O check` / `-O exit` 的硬上限
	// probeTimeoutSec 是 tunnel_probe 等应用层回包的秒数（bash: FORWARD_PROBE_TIMEOUT_DEFAULT）。
	// 单独提出为一个变量，便于单测缩短 degraded 用例的等待。
	probeTimeoutSec = hfcommon.ProbeTimeoutDefault
)

var (
	reIPv6Port = regexp.MustCompile(`^(.*\[[0-9A-Fa-f:.]+\]):([0-9]+)$`)
	reIPv6Only = regexp.MustCompile(`^\[[0-9A-Fa-f:.]+\]$`)
	reHostPort = regexp.MustCompile(`^(.*):([0-9]+)$`)
	reMaster   = regexp.MustCompile(`Master running \(pid=([0-9]+)\)`)
)

// Manager 持有隧道的生命周期操作（冻结签名见 PLAN §5）。它本身无状态：所有路径都
// 由运行时环境（HERDR_PLUGIN_STATE_DIR）推导，与 bash 的每次重算一致。
type Manager struct{}

// NewManager 构造一个 Manager（冻结签名：无参数、无错误）。
func NewManager() *Manager { return &Manager{} }

// ControlDir 复刻 tunnel_control_dir：$HERDR_PLUGIN_STATE_DIR/ssh-ctl，首次使用时
// 建目录并 chmod 700（bash 只在「目录不存在」时 chmod）。
func ControlDir() (string, error) {
	dir := filepath.Join(hfcommon.StateDir(), ctlDirName)
	st, err := os.Stat(dir)
	if err != nil || !st.IsDir() {
		if err := os.MkdirAll(dir, 0o700); err != nil {
			return "", fmt.Errorf("control dir 创建失败 %s: %w", dir, err)
		}
		if err := os.Chmod(dir, 0o700); err != nil {
			return "", fmt.Errorf("control dir chmod 700 失败 %s: %w", dir, err)
		}
	}
	return dir, nil
}

// ControlPath 复刻 tunnel_control_path：<control dir>/ctl-<id>（返回的是**文件系统**
// 路径，未做 percent 转义；交给 ssh 时必须再过 SSHPathEscape）。
func ControlPath(id string) (string, error) {
	dir, err := ControlDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "ctl-"+id), nil
}

// ParseSSHTarget 复刻 tunnel_parse_ssh_target：返回 (port 字面量, destination)。
//
// 分支顺序与 bash 完全一致（顺序即语义）：
//
//  1. `^(.*\[[0-9A-Fa-f:.]+\]):([0-9]+)$`  方括号 IPv6 + 端口
//  2. `^\[[0-9A-Fa-f:.]+\]$`              方括号 IPv6（缺省 22）
//  3. `^(.*):([0-9]+)$`                   普通 host:port（`.*` 贪婪 → 取最后一个冒号）
//  4. 以 `:` 结尾                          去掉尾部冒号（畸形但容忍）
//
// port 保持**字面量**（`host:0022` -> "0022"，与 bash 把正则捕获原样传给 `-p` 一致）；
// 未显式给端口时是 "22"。
func ParseSSHTarget(target string) (port string, dest string) {
	if m := reIPv6Port.FindStringSubmatch(target); m != nil {
		return m[2], m[1]
	}
	if reIPv6Only.MatchString(target) {
		return "22", target
	}
	if m := reHostPort.FindStringSubmatch(target); m != nil {
		return m[2], m[1]
	}
	if strings.HasSuffix(target, ":") {
		return "22", strings.TrimSuffix(target, ":")
	}
	return "22", target
}

// SSHPathEscape 复刻 tunnel_ssh_path_escape：把 `%` 翻倍，让 ssh 的 percent 展开
// 还原出字面 `%`（`%%` 是 ssh 的「字面百分号」token）。
func SSHPathEscape(path string) string {
	return strings.ReplaceAll(path, "%", "%%")
}

// SSHArgs 复刻 tunnel_ssh_args：返回 ssh 的完整 argv（不含 argv[0]）。
//
// 逐 flag 顺序、取值与 lib/tunnel.sh 一致（tests/unit/test_tunnel_args.sh 的 golden）：
//
//	-N -L 127.0.0.1:<lp>:<remote> -o BatchMode=yes -o ExitOnForwardFailure=yes
//	-o ControlMaster=auto -o ControlPath=<esc> -o ControlPersist=yes
//	-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=<esc dir>/known_hosts
//	-F /dev/null -p <port> <dest>
func SSHArgs(id string, lp int, remote string, sshTarget string) ([]string, error) {
	port, dest := ParseSSHTarget(sshTarget)
	dir, err := ControlDir()
	if err != nil {
		return nil, err
	}
	ctl := SSHPathEscape(filepath.Join(dir, "ctl-"+id))
	khf := SSHPathEscape(filepath.Join(dir, "known_hosts"))
	return []string{
		"-N",
		"-L", fmt.Sprintf("127.0.0.1:%d:%s", lp, remote),
		"-o", "BatchMode=yes",
		"-o", "ExitOnForwardFailure=yes",
		"-o", "ControlMaster=auto",
		"-o", "ControlPath=" + ctl,
		"-o", "ControlPersist=yes",
		"-o", "StrictHostKeyChecking=accept-new",
		"-o", "UserKnownHostsFile=" + khf,
		"-F", "/dev/null",
		"-p", port,
		dest,
	}, nil
}
