// add.go —— `forward add`（← bin/forward cmd_add / _hf_resolve_target / _hf_add_client）。
//
// 参数形态与错误文案逐字对齐 bash（A.3 + C2 退出码表）：
//
//	add <local>:<remote> [--machine LABEL] [--ssh-target TARGET]
//	add <port>|<local>:<remote> [--client]
//	未知参数 / 缺 spec / 端口越界 / 重复 <local>:<remote> 参数 -> 64
//	--client 与 --machine/--ssh-target 互斥 -> 64；client 映射 lp < 1024 -> 64
//	端口冲突 -> 2（state.Add）；缺目标 -> 4（未给 --client 时）
//	隧道起不来 -> 5（记录保留并标记 down）
//
// 迁移期的一个关键约束（PLAN §6 Phase 2 + 本 phase 的 dispatch 规则）：
// `add --client` 与「无目标 + 有 client 在线」的隐式 client 分支**仍由 bash 处理**
// （bridge 写侧属 Phase 3）。因此这里的 client 分支在迁移期实际不可达，但仍完整实现
// —— 它保证 Phase 3 把 bridge 写侧迁完后，cmd_add 不需要再补一遍语义（双实现同形）。
package cli

import (
	"errors"
	"fmt"
	"os"
	"regexp"
	"strconv"
	"strings"

	"github.com/zzjcool/herdr-forward/internal/bridge"
	"github.com/zzjcool/herdr-forward/internal/hfcommon"
	"github.com/zzjcool/herdr-forward/internal/machine"
	"github.com/zzjcool/herdr-forward/internal/state"
	"github.com/zzjcool/herdr-forward/internal/tunnel"
)

var (
	reLocalRemote = regexp.MustCompile(`^([0-9]+):([0-9]+)$`)
	reBarePort    = regexp.MustCompile(`^([0-9]+)$`)
)

// cmdAdd 复刻 cmd_add。
func cmdAdd(args []string) int {
	spec := ""
	machineLabel := ""
	sshTarget := ""
	client := false

	for len(args) > 0 {
		arg := args[0]
		switch {
		case arg == "--client":
			client = true
			args = args[1:]
		case arg == "--machine":
			if len(args) < 2 {
				return die(exitUsage, "--machine 需要一个 LABEL 值。用法：forward add <local>:<remote> --machine LABEL")
			}
			machineLabel = args[1]
			args = args[2:]
		case strings.HasPrefix(arg, "--machine="):
			machineLabel = arg[len("--machine="):]
			args = args[1:]
		case arg == "--ssh-target":
			if len(args) < 2 {
				return die(exitUsage, "--ssh-target 需要一个 TARGET 值（如 user@host:22）。")
			}
			sshTarget = args[1]
			args = args[2:]
		case strings.HasPrefix(arg, "--ssh-target="):
			sshTarget = arg[len("--ssh-target="):]
			args = args[1:]
		case strings.HasPrefix(arg, "-"):
			return die(exitUsage, "未知参数："+arg+"。请运行 'forward --help' 查看用法。")
		default:
			if spec != "" {
				return die(exitUsage, "只接受一个 <local>:<remote> 参数（收到额外："+arg+"）。请运行 'forward --help' 查看用法。")
			}
			spec = arg
			args = args[1:]
		}
	}

	if spec == "" {
		return die(exitUsage, "缺少 <local>:<remote> 参数。用法：forward add 3000:9443 --ssh-target user@host:22")
	}

	localPort := 0
	remotePort := 0
	if m := reLocalRemote.FindStringSubmatch(spec); m != nil {
		localPort = atoiClamped(m[1])
		remotePort = atoiClamped(m[2])
	} else if m := reBarePort.FindStringSubmatch(spec); m != nil {
		localPort = atoiClamped(m[1])
		remotePort = localPort
	} else {
		return die(exitUsage, "端口格式非法："+spec+"。应为 <port> 或 <local>:<remote>（如 5173 或 3000:9443）。")
	}

	if code := requirePort(localPort, "本地端口"); code != exitOK {
		return code
	}
	if code := requirePort(remotePort, "远端端口"); code != exitOK {
		return code
	}

	// 没给目标时：本机有 client 在线就默认映射到 client（远程开发的常态）。
	if !client && machineLabel == "" && sshTarget == "" {
		client = anyClientLive()
	}
	if client {
		if machineLabel != "" || sshTarget != "" {
			return die(exitUsage, "--client 与 --machine/--ssh-target 互斥：client 映射的目标恒为本机 localhost。")
		}
		return addClient(localPort, remotePort)
	}

	target, code := resolveTarget(machineLabel, sshTarget)
	if code != exitOK {
		return code
	}

	id := fmt.Sprintf("f-%d", localPort)
	record := state.Forward{
		LocalPort:     localPort,
		RemoteHost:    "127.0.0.1",
		RemotePort:    remotePort,
		Machine:       machineLabel,
		SshTarget:     target,
		ControlSocket: fmt.Sprintf("%s/ssh-ctl/ctl-%s", hfcommon.StateDir(), id),
		Status:        "starting",
		Mode:          state.ModeTunnel,
	}
	if err := state.Add(record); err != nil {
		return stateErrCode(err, id, localPort)
	}

	pid, err := tunnel.NewManager().Start(id, localPort, "127.0.0.1", remotePort, target)
	if err != nil {
		// bash：先置 down（失败也要保留记录，供 doctor/remove 处理），再 die 5。
		_ = state.SetStatus(id, "down")
		return die(exitTunnelFailed, "隧道启动失败（"+id+"）："+err.Error()+"。记录已保留并标记 down；请检查 ssh 连通性后用 'forward doctor --fix' 或 'forward remove "+id+"' 处理。")
	}

	// bash 顺序：先 set_pid 再 set_status up（两次落盘，这里保持一致）。
	if code := setPid(id, pid); code != exitOK {
		return code
	}
	if err := state.SetStatus(id, "up"); err != nil {
		return stateErrCode(err, id, localPort)
	}
	fmt.Println(id)
	return exitOK
}

// addClient 复刻 _hf_add_client：登记一条 client 映射（client 侧监听，本机只写期望集合）。
func addClient(localPort, remotePort int) int {
	if localPort < 1024 {
		return die(exitUsage, fmt.Sprintf("client 映射的本地端口需 ≥ 1024（client 侧以普通用户监听）：%d。请换一个，如 forward add %d:%d --client。",
			localPort, localPort+10000, remotePort))
	}
	record := state.Forward{
		LocalPort:  localPort,
		RemoteHost: "localhost",
		RemotePort: remotePort,
		Mode:       state.ModeClient,
		Status:     "starting",
	}
	if err := state.Add(record); err != nil {
		return stateErrCode(err, fmt.Sprintf("f-%d", localPort), localPort)
	}

	if anyClientLive() {
		fmt.Fprintf(os.Stderr, "已登记：client 的 localhost:%d → 本机 localhost:%d（client 在线，约 1 秒内生效）。\n", localPort, remotePort)
	} else {
		fmt.Fprintf(os.Stderr, "已登记：client 的 localhost:%d → 本机 localhost:%d。\n", localPort, remotePort)
		fmt.Fprint(os.Stderr, "当前没有 client 连着本机；在 client 上激活本机（Port Forward 面板选中本机，或 forward machines activate <本机>）后自动生效。\n")
	}
	fmt.Printf("f-%d\n", localPort)
	return exitOK
}

// anyClientLive 复刻 `bridge_any_live` 的 yes/no（Phase 3 之前桥接写侧仍在 bash，
// 这里复用 cli 层的**只读**会话扫描，与 `list` 的在线判定同源）。
//
// 已知形态差异（与 bash 的 if-ladder 不同，报告登记）：bash 的 `bridge_any_live` 会
// 把内核分配的 state 目录**权限位**算进探测（`any(.[]; .live)` 之外还有一层 os.Stat
// 级别的目录可读性前置），Go 侧只看会话文件的 pid 存活 + 心跳窗口，两者在正常环境
// （目录 700、会话文件可读）下完全一致。
func anyClientLive() bool {
	return bridge.AnyLive(bridge.Sessions())
}

// resolveTarget 复刻 _hf_resolve_target：ssh_target 直连优先，否则走 machines.toml。
func resolveTarget(machineLabel, sshTarget string) (string, int) {
	if sshTarget != "" {
		return sshTarget, exitOK
	}
	if machineLabel == "" {
		return "", die(exitMachineResolve, "缺少目标机器：请传 --machine LABEL（走 machines.toml 解析）或 --ssh-target user@host:22；若要把本机端口映射到 attach 过来的 client，加 --client。")
	}
	resolved, err := machine.ResolveFromToml(machineLabel)
	if err != nil {
		return "", die(exitMachineResolve, fmt.Sprintf("无法解析 machine '%s'。请检查 $HERDR_PLUGIN_CONFIG_DIR/machines.toml 中是否存在 [machines.%s]，或用 --ssh-target user@host:22 直连。", machineLabel, machineLabel))
	}
	return resolved, exitOK
}

// requirePort 复刻 _hf_require_port：1-65535 整数校验，失败 -> 64。
func requirePort(port int, label string) int {
	if port < 1 || port > 65535 {
		return die(exitUsage, fmt.Sprintf("%s越界（1-65535）：%d。请修正端口后重试。", label, port))
	}
	return exitOK
}

// setPid 复刻 forward_set_pid：state 层冻结 API 没有 SetPid，故在 cli 层用
// Load + 就地改 Pid + Save 表达（与 bash 的 jq 更新同构），随后按 bash 顺序再
// SetStatus。两次写入是**有意**的：与 bash 的落盘序列一致。
func setPid(id string, pid int) int {
	records, err := state.Load()
	if err != nil {
		return stateErrCode(err, id, 0)
	}
	value := pid
	found := false
	for i := range records {
		if records[i].ID == id {
			records[i].Pid = &value
			found = true
		}
	}
	if !found {
		return die(exitNotFound, "记录不存在："+id+"。请用 forward list 查看现有 id 后重试。")
	}
	if err := state.Save(records); err != nil {
		return die(exitError, "forward_set_pid 写入 pid 失败："+err.Error())
	}
	return exitOK
}

// stateErrCode 把 state 层的哨兵错误映射为 C2 的退出码，并对最常见的
// ErrDuplicatePort 复刻 bash 的完整用户可见文案（
// `本地端口 <lp> 已被占用（记录 <id> 已存在）。请先 forward list 查看，或用
// forward remove <id> 删除后再 add。`）。
func stateErrCode(err error, id string, localPort int) int {
	switch {
	case err == nil:
		return exitOK
	case errors.Is(err, state.ErrDuplicatePort):
		return die(exitDuplicatePort, fmt.Sprintf(
			"本地端口 %d 已被占用（记录 %s 已存在）。请先 forward list 查看，或用 forward remove %s 删除后再 add。",
			localPort, id, id))
	case errors.Is(err, state.ErrNotFound):
		return die(exitNotFound, "记录不存在："+id+"。请用 forward list 查看现有 id 后重试。")
	default:
		return die(exitError, err.Error())
	}
}

// atoiClamped 把一个纯数字串转 int；超长/溢出时截到 int 上限（bash 的 `((port > 65535))`
// 在 64 位整数域里比较，超长数字串同样判越界 —— 这里截到上限后 requirePort 必然拒绝）。
func atoiClamped(digits string) int {
	n, err := strconv.Atoi(digits)
	if err != nil {
		return int(^uint(0) >> 1)
	}
	return n
}
