// run.go —— ssh_probe_run / ssh_probe_plugin / kv_get 的执行层（← lib/ssh-probe.sh）。
//
// 契约（M1 §2.1 冻结签名 + ARCHITECTURE §A.3.2）：
//
//	SSHProbeRun(target, remoteCmd) (rc int, merged string)   -- 恒不报错，rc 由调用方判态
//	SSHProbePlugin(target, pluginID) string                  -- stdout: §2.1 的 KV 行
//	KVGet(text, key) string                                  -- 第一个 KEY= 的值
//
// argv 形状逐字对齐 bash（这一段是 A 机真实 bug 的回归锚点，见 herdrlist/view 的注释）：
//
//	[timeout 15] ssh -n -o BatchMode=yes -o ConnectTimeout=8 [-p PORT] HOST REMOTE_CMD
//
// 三个细节都是必需的：
//
//   - `-n`：`curl … | bash -s` 形态下 stdin 是脚本本体，ssh 读走它就等于吃掉剩余脚本；
//   - `-p`：只在 target 显式带端口时传（裸 host 交给 ssh_config 的 Port / 默认 22）；
//   - timeout：缺失时靠 ConnectTimeout=8 兜住建连阶段（不静默降级，行为仍可预期）。
//
// 只读保证：只跑 `herdr plugin list` 与远端路径推导（读 plugins.json / 目录 glob），
// 绝不执行 `herdr plugin install` 等写动作。
package sshprobe

import (
	"bytes"
	"context"
	"os"
	"os/exec"
	"strings"
	"time"
)

// 探测参数（lib/ssh-probe.sh 顶部常量；调用方可先设 SSH_PROBE_TIMEOUT 覆盖）。
const (
	// DefaultTimeout 是整条 ssh 命令的外层上限秒数（SSH_PROBE_TIMEOUT）。
	DefaultTimeout = 15
	// DefaultConnectTimeout 是 ssh 自己的建连上限秒数（SSH_CONNECT_TIMEOUT）。
	DefaultConnectTimeout = 8
)

// timeoutSeconds 读 SSH_PROBE_TIMEOUT（缺省 15；非正整数按缺省处理）。
func timeoutSeconds() int { return envSeconds("SSH_PROBE_TIMEOUT", DefaultTimeout) }

// connectTimeoutSeconds 读 SSH_CONNECT_TIMEOUT（缺省 8）。
func connectTimeoutSeconds() int { return envSeconds("SSH_CONNECT_TIMEOUT", DefaultConnectTimeout) }

func envSeconds(name string, def int) int {
	raw := strings.TrimSpace(os.Getenv(name))
	if raw == "" {
		return def
	}
	n := 0
	for i := 0; i < len(raw); i++ {
		if raw[i] < '0' || raw[i] > '9' {
			return def
		}
		n = n*10 + int(raw[i]-'0')
	}
	if n <= 0 {
		return def
	}
	return n
}

// KVGet 复刻 `kv_get <多行文本> <KEY>`：第一个 `KEY=` 的值（严格行首匹配，无则空串）。
func KVGet(text, key string) string {
	if key == "" {
		return ""
	}
	for _, line := range strings.Split(text, "\n") {
		if strings.HasPrefix(line, key+"=") {
			return line[len(key)+1:]
		}
	}
	return ""
}

// SSHProbeRun 复刻 ssh_probe_run：跑一条远端命令，返回 (ssh 退出码, stdout+stderr 合并)。
//
// 恒不报错（探测失败由调用方按 rc 判状态，绝不因连不上而中断安装/面板）；target 非法时
// 返回 rc=64（对照 bash 的 die 64 —— 非法 target 一个 ssh 都不发）。
func SSHProbeRun(target, remoteCmd string) (int, string) {
	parsed, err := ParseTarget(target)
	if err != nil {
		return 64, ""
	}

	argv := buildSSHArgv(parsed, remoteCmd)
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(timeoutSeconds())*time.Second)
	defer cancel()

	cmd := exec.CommandContext(ctx, argv[0], argv[1:]...)
	var out bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &out
	runErr := cmd.Run()

	rc := 0
	if runErr != nil {
		var exitErr *exec.ExitError
		switch {
		case errorsAs(runErr, &exitErr):
			rc = exitErr.ExitCode()
		case ctx.Err() == context.DeadlineExceeded:
			rc = 124 // timeout(1) 的超时退出码
		default:
			// ssh 二进制缺失 / 无法 fork：与 bash 的 `"${cmd[@]}"` 失败同档（127）。
			rc = 127
		}
	}
	return rc, out.String()
}

// buildSSHArgv 拼出 `[timeout N] ssh -n -o BatchMode=yes -o ConnectTimeout=8 [-p P] HOST CMD`。
//
// 有 timeout(1) 才加前缀（macOS 默认没有），与 lib/ssh-probe.sh 的 SSH_TIMER_BIN 检测一致。
func buildSSHArgv(t Target, remoteCmd string) []string {
	argv := make([]string, 0, 12)
	if _, err := exec.LookPath("timeout"); err == nil {
		argv = append(argv, "timeout", itoa(timeoutSeconds()))
	}
	argv = append(argv,
		"ssh", "-n",
		"-o", "BatchMode=yes",
		"-o", "ConnectTimeout="+itoa(connectTimeoutSeconds()),
	)
	if t.HasPort {
		argv = append(argv, "-p", itoa(t.Port))
	}
	argv = append(argv, t.Host, remoteCmd)
	return argv
}

// SSHEnv 是「宿主已提供 die」的对应物：Go 侧不 die，把错误交回调用方（返回 64）。
//
// SSHProbePlugin 复刻 ssh_probe_plugin：四态 KV 输出。
//
//	HF_STATUS=present|absent|no-herdr|unreachable
//	  present      -> HF_ROOT=<B 插件根>（读不到则该行缺席）+ HF_STATE_DIR（已存在）
//	                  / HF_DEFAULT_STATE（默认位置）
//	  no-herdr     -> HF_REASON=<远端找不到 herdr>
//	  unreachable  -> HF_REASON=<首 3 行错误摘要（合并 stdout+stderr）>
//
// 调用次数与 lib/ssh-probe.sh 一致：absent / no-herdr / unreachable = 1 次 ssh，
// present = 2 次。pluginID 为空时取默认 `zzjcool:forward`。
func SSHProbePlugin(target, pluginID string) string {
	if pluginID == "" {
		pluginID = DefaultPluginID
	}
	pluginIDEnc := strings.ReplaceAll(pluginID, ":", "%3A")

	rawRC, body := SSHProbeRun(target, RemoteListCmd)
	if rawRC != 0 {
		reason := firstLines(strings.TrimSpace(body), 3)
		return "HF_STATUS=unreachable\n" + "HF_REASON=" + flatten(reason) + "\n"
	}
	if strings.Contains(body, "HF_NO_HERDR") {
		return "HF_STATUS=no-herdr\n" +
			"HF_REASON=远端非交互 shell 里找不到 herdr（PATH 未含 ~/.local/bin？）\n"
	}
	if !strings.Contains(body, pluginID) {
		return "HF_STATUS=absent\n"
	}

	out := "HF_STATUS=present\n"

	pathsCmd := strings.ReplaceAll(RemotePathsCmd, "__HF_PLUGIN_ID_ENC__", pluginIDEnc)
	pathsCmd = strings.ReplaceAll(pathsCmd, "__HF_PLUGIN_ID__", pluginID)
	_, pathsRaw := SSHProbeRun(target, pathsCmd)

	root := KVGet(pathsRaw, "HF_ROOT")
	state := KVGet(pathsRaw, "HF_STATE_DIR")
	if root != "" {
		out += "HF_ROOT=" + root + "\n"
	}
	if state != "" {
		out += "HF_STATE_DIR=" + state + "\n"
	} else if def := KVGet(pathsRaw, "HF_DEFAULT_STATE"); def != "" {
		out += "HF_DEFAULT_STATE=" + def + "\n"
	}
	return out
}

// firstLines 取前 n 行（含空行，与 `head -3` 的字节语义一致）。
func firstLines(text string, n int) string {
	lines := strings.Split(text, "\n")
	if len(lines) > n {
		lines = lines[:n]
	}
	return strings.Join(lines, "\n")
}

// flatten 复刻 bash 的 `tr '\n' ' '`：换行压成空格（HF_REASON 必须单行）。
func flatten(s string) string {
	return strings.ReplaceAll(s, "\n", " ")
}

// errorsAs 是 errors.As 的本地别名，避免为一处调用引入额外 import 噪音。
func errorsAs(err error, target **exec.ExitError) bool {
	e, ok := err.(*exec.ExitError)
	if ok {
		*target = e
	}
	return ok
}

// itoa 十进制整数转字符串（小工具，避免为一处调用引入 strconv）。
func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	neg := n < 0
	if neg {
		n = -n
	}
	var buf [20]byte
	i := len(buf)
	for n > 0 {
		i--
		buf[i] = byte('0' + n%10)
		n /= 10
	}
	if neg {
		i--
		buf[i] = '-'
	}
	return string(buf[i:])
}
