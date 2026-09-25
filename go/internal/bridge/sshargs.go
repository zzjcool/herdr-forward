// sshargs.go —— 桥接 SSH 的 argv 拼装（← lib/bridge.sh 的 bridge_ssh_destination /
// bridge_remote_serve_cmd / bridge_ssh_args / _bridge_mux / _bridge_ctl_exit）。
//
// 安全裁决（§A.3.3）：桥接 ssh 沿用用户 `~/.ssh/config`（saved machine 常是 Host 别名，
// 要靠它的 HostName / IdentityFile / ProxyJump），但把会改变**信任边界**的选项钉死：
//
//	ForwardAgent/ForwardX11 关       不把 A 的 agent / 显示暴露给 B
//	ClearAllForwardings=yes          不带上用户为 B 配的 LocalForward/RemoteForward
//	独立 ControlMaster/ControlPath   不与用户其它 ssh 会话混用 master
//	BatchMode=yes                    后台进程绝不弹密码
//
// `HERDR_FORWARD_SSH_CONFIG` 可指定 `-F`（测试与自定义部署用）。
package bridge

import (
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"
)

// SSHDestination 复刻 bridge_ssh_destination：把 herdr target 转成 ssh 认的目的地。
//
// herdr saved machine 的 target 形如 alias / user@host / ssh://user@host:port；
// 激活记录里也可能是 user@host:port。ssh **不认** host:port 形式，统一转成 ssh:// URI。
func SSHDestination(target string) string {
	if len(target) >= 6 && strings.EqualFold(target[:6], "ssh://") {
		return target
	}
	// `^([^:@/]+@)?\[[0-9A-Fa-f:.]+\]:[0-9]+$` 或 `^([^:@/]+@)?[^:@/\[]+:[0-9]+$`
	host := target
	if i := strings.LastIndex(host, "@"); i >= 0 {
		host = host[i+1:]
	}
	if isBracketedHostPort(host) || isHostPort(host) {
		return "ssh://" + target
	}
	return target
}

// isBracketedHostPort 判定 `[v6]:port` 形态。
func isBracketedHostPort(s string) bool {
	if !strings.HasPrefix(s, "[") {
		return false
	}
	end := strings.Index(s, "]")
	if end < 0 {
		return false
	}
	rest := s[end+1:]
	if !strings.HasPrefix(rest, ":") || rest == ":" {
		return false
	}
	return isDigits(rest[1:])
}

// isHostPort 判定 `host:port` 形态（恰一个冒号、后半是数字、主机名不含 `[` `/`）。
func isHostPort(s string) bool {
	if strings.Count(s, ":") != 1 || strings.ContainsAny(s, "[/") {
		return false
	}
	i := strings.Index(s, ":")
	return isDigits(s[i+1:])
}

// RemoteServeCmd 复刻 bridge_remote_serve_cmd：远端命令串。
//
// 经 SSH 跑的不是 herdr 插件上下文，**没有** HERDR_PLUGIN_STATE_DIR，必须显式带上 B 的
// 插件 state 目录 —— 否则会落到 ~/.local/state/herdr-forward，与 B 的面板分叉。
func RemoteServeCmd(remoteRoot, remoteStateDir string) string {
	return fmt.Sprintf("env %s %s bridge serve",
		shQuote("HERDR_PLUGIN_STATE_DIR="+remoteStateDir),
		shQuote(remoteRoot+"/bin/forward"))
}

// shQuote 复刻 _bridge_sq：POSIX sh 单引号字面量（值里的 ' 用 '\” 转义）。
func shQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}

// SSHArgs 复刻 bridge_ssh_args：桥接 master 的 ssh 选项（每个元素一个 argv 项）。
func SSHArgs(controlPath string) []string {
	args := []string{}
	if cfg := sshConfigPath(); cfg != "" {
		args = append(args, "-F", cfg)
	}
	args = append(args,
		"-T",
		"-o", "BatchMode=yes",
		"-o", "ConnectTimeout=10",
		"-o", "ServerAliveInterval="+strconv.Itoa(ServerAliveSeconds()),
		"-o", "ServerAliveCountMax=3",
		"-o", "ControlMaster=yes",
		"-o", "ControlPersist=no",
		"-o", "ControlPath="+SSHEscape(controlPath),
		"-o", "ClearAllForwardings=yes",
		"-o", "ExitOnForwardFailure=no",
		"-o", "ForwardAgent=no",
		"-o", "ForwardX11=no",
		"-o", "PermitLocalCommand=no",
	)
	return args
}

// sshConfigPath 读 HERDR_FORWARD_SSH_CONFIG（空串按未设置，与 bash 的 `${VAR:-}` 一致）。
func sshConfigPath() string { return strings.TrimSpace(os.Getenv("HERDR_FORWARD_SSH_CONFIG")) }

// MuxArgv 复刻 _bridge_mux 的 argv：`ssh -F /dev/null -o BatchMode=yes
// -o ControlPath=<ctl> -O forward|cancel -L localhost:<lp>:localhost:<rp> hf-bridge`。
//
// 注意 `-F /dev/null`：这一条**刻意**不走用户的 ssh_config（只用同一条 master 连接，
// 配置早已在 master 建立时生效），且目标串是占位符 `hf-bridge`。
func MuxArgv(controlPath, op string, localPort, remotePort int) []string {
	return []string{
		"ssh", "-F", "/dev/null", "-o", "BatchMode=yes",
		"-o", "ControlPath=" + SSHEscape(controlPath),
		"-O", op,
		"-L", fmt.Sprintf("localhost:%d:localhost:%d", localPort, remotePort),
		"hf-bridge",
	}
}

// CtlExitArgv 复刻 _bridge_ctl_exit 的 argv：请该 socket 上的 master 退出。
func CtlExitArgv(controlPath string) []string {
	return []string{
		"ssh", "-F", "/dev/null", "-o", "BatchMode=yes",
		"-o", "ControlPath=" + SSHEscape(controlPath),
		"-O", "exit", "hf-bridge",
	}
}

// muxTimeout 是 `-O forward/cancel` 的硬上限（bash: `_bridge_bounded 10`）。
const muxTimeout = 10 * time.Second

// ctlExitTimeout 是 `-O exit` 的硬上限（bash: `timeout 5`）。
const ctlExitTimeout = 5 * time.Second
