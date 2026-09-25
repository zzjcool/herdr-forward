// phase3.go —— Phase 3 的差分探针（HF1 编解码 / 安全边界 / bridge 目的地与 ssh argv /
// 激活状态 schema）。
//
// 这些子命令**不是**用户可见 CLI，而是给 tests/difftest/run.sh 做「bash ↔ Go 逐字节」
// 对照的调试入口。因此它们只打印纯结果（一行一条），退出码只表达「参数错误」。
//
// 为什么值得单独做：Phase 3 的新增逻辑（HF1 行协议、C6 边界、bridge ssh argv）是
// **跨机器**的协议面，一旦与 bash 分叉，E2E 里的表现是「连不上/映射不生效」这种
// 难以定位的远端现象。把它拉回本机做逐字节差分，是最便宜的防线。
package difftest

import (
	"fmt"
	"os"
	"strings"

	"github.com/zzjcool/herdr-forward/internal/bridge"
	"github.com/zzjcool/herdr-forward/internal/machine"
	"github.com/zzjcool/herdr-forward/internal/sshprobe"
)

// cmdHFParse <line>：解析一行 HF1 协议并按冻结形状打印。
//
// 输出（合法）：
//
//	OK <kind>
//	HELLO host=<host> labels=<label1|label2>
//	SYNC n=<n> entries=<id:lp:rp,...>
//	OPEN url=<url>
//	STATUS id=<id> state=<state> reason=<reason>
//	PING
//
// 非法行：`ERR`（bash 侧同样只判「能识别 / 不能识别」）。
func cmdHFParse(args []string) int {
	if len(args) != 1 {
		fmt.Fprintln(os.Stderr, "difftest hf-parse: 用法 hf-parse <line>")
		return exitUsage
	}
	msg, err := bridge.ParseLine(args[0])
	if err != nil {
		fmt.Println("ERR")
		return exitOK
	}
	switch m := msg.(type) {
	case bridge.Hello:
		fmt.Println("OK HELLO")
		fmt.Printf("HELLO host=%s labels=%s\n", m.Host, strings.Join(m.Labels, "|"))
	case bridge.Sync:
		parts := make([]string, 0, len(m.Forwards))
		for _, e := range m.Forwards {
			parts = append(parts, fmt.Sprintf("%s:%d:%d", e.ID, e.LocalPort, e.RemotePort))
		}
		fmt.Println("OK SYNC")
		fmt.Printf("SYNC n=%d entries=%s\n", len(m.Forwards), strings.Join(parts, ","))
	case bridge.Open:
		fmt.Println("OK OPEN")
		fmt.Printf("OPEN url=%s\n", m.URL)
	case bridge.Status:
		fmt.Println("OK STATUS")
		fmt.Printf("STATUS id=%s state=%s reason=%s\n", m.ID, m.State, m.Reason)
	case bridge.Ping:
		fmt.Println("OK PING")
	}
	return exitOK
}

// cmdHFFmt <kind> <args...>：按冻结形状编码一行协议。
//
//	hf-fmt hello <host> [label...]
//	hf-fmt sync <id:lp:rp,...|->
//	hf-fmt open <url>
//	hf-fmt status <id> <up|down> [reason...]
//	hf-fmt ping
func cmdHFFmt(args []string) int {
	if len(args) == 0 {
		fmt.Fprintln(os.Stderr, "difftest hf-fmt: 用法 hf-fmt <hello|sync|open|status|ping> …")
		return exitUsage
	}
	switch args[0] {
	case "hello":
		host := ""
		labels := []string{}
		if len(args) > 1 {
			host = args[1]
		}
		if len(args) > 2 {
			labels = args[2:]
		}
		fmt.Println(bridge.Hello{Host: host, Labels: labels}.String())
	case "sync":
		payload := ""
		if len(args) > 1 {
			payload = args[1]
		}
		entries, err := bridge.ParseSync(payload)
		if err != nil {
			fmt.Fprintln(os.Stderr, "difftest hf-fmt sync: 解析失败")
			return exitInvalidArg
		}
		fmt.Println(bridge.Sync{Forwards: entries}.String())
	case "open":
		url := ""
		if len(args) > 1 {
			url = args[1]
		}
		fmt.Println(bridge.Open{URL: url}.String())
	case "status":
		id, state, reason := "", "", ""
		if len(args) > 1 {
			id = args[1]
		}
		if len(args) > 2 {
			state = args[2]
		}
		if len(args) > 3 {
			reason = strings.Join(args[3:], " ")
		}
		fmt.Println(bridge.Status{ID: id, State: state, Reason: reason}.String())
	case "ping":
		fmt.Println(bridge.Ping{}.String())
	default:
		fmt.Fprintf(os.Stderr, "difftest hf-fmt: 未知种类 %q\n", args[0])
		return exitUsage
	}
	return exitOK
}

// cmdHFValid <id> <lp> <rp>：C6 安全边界判定（`yes` / 空）。
//
// 走**字面量**版本（bridge.ValidateForwardLiterals），因为 bash 的 bridge_valid_entry
// 拿的就是三个字符串 —— 前导零、位宽这些细节只有字面量形态能对上。
func cmdHFValid(args []string) int {
	if len(args) != 3 {
		fmt.Fprintln(os.Stderr, "difftest hf-valid: 用法 hf-valid <id> <lp> <rp>")
		return exitUsage
	}
	if bridge.ValidateForwardLiterals(args[0], args[1], args[2]) {
		fmt.Println("yes")
	}
	return exitOK
}

// cmdSSHDest <target>：bridge_ssh_destination 的结果。
func cmdSSHDest(args []string) int {
	if len(args) != 1 {
		fmt.Fprintln(os.Stderr, "difftest ssh-dest: 用法 ssh-dest <target>")
		return exitUsage
	}
	fmt.Println(bridge.SSHDestination(args[0]))
	return exitOK
}

// cmdRemoteCmd <root> <state-dir>：bridge_remote_serve_cmd 的结果。
func cmdRemoteCmd(args []string) int {
	if len(args) != 2 {
		fmt.Fprintln(os.Stderr, "difftest remote-cmd: 用法 remote-cmd <remote_root> <remote_state_dir>")
		return exitUsage
	}
	fmt.Println(bridge.RemoteServeCmd(args[0], args[1]))
	return exitOK
}

// cmdBridgeSSHArgs <control-path>：bridge_ssh_args 的结果（一行一个 argv 元素）。
func cmdBridgeSSHArgs(args []string) int {
	if len(args) != 1 {
		fmt.Fprintln(os.Stderr, "difftest bridge-ssh-args: 用法 bridge-ssh-args <control-path>")
		return exitUsage
	}
	for _, a := range bridge.SSHArgs(args[0]) {
		fmt.Println(a)
	}
	return exitOK
}

// cmdBridgeActive <sub>：激活状态文件的读写（schema 对照）。
//
//	bridge-active active                 -> 当前 active（无则空行）
//	bridge-active has <id>               -> yes | no
//	bridge-active view-json              -> machines_view_json 的 stdout（紧凑数组）
//	bridge-active resolve <id|label>     -> 解析出的 id（失败 -> ERR）
func cmdBridgeActive(args []string) int {
	if len(args) == 0 {
		fmt.Fprintln(os.Stderr, "difftest bridge-active: 用法 bridge-active <active|has|view-json|resolve> …")
		return exitUsage
	}
	switch args[0] {
	case "active":
		fmt.Println(machine.ActiveID())
	case "has":
		if len(args) != 2 {
			fmt.Fprintln(os.Stderr, "difftest bridge-active has: 用法 has <id>")
			return exitUsage
		}
		if machine.HasActivation(args[1]) {
			fmt.Println("yes")
		} else {
			fmt.Println("no")
		}
	case "view-json":
		os.Stdout.Write(machine.ViewJSON())
	case "resolve":
		if len(args) != 2 {
			fmt.Fprintln(os.Stderr, "difftest bridge-active resolve: 用法 resolve <id|label>")
			return exitUsage
		}
		id, err := machine.ResolveID(args[1])
		if err != nil {
			fmt.Println("ERR")
			return exitOK
		}
		fmt.Println(id)
	default:
		fmt.Fprintf(os.Stderr, "difftest bridge-active: 未知子命令 %q\n", args[0])
		return exitUsage
	}
	return exitOK
}

// cmdProbeKV <target> <plugin-id> <kv-text>：ssh_probe KV 解析（不联网）。
//
// 只做**解析层**对照：bash 侧把同一段 KV 文本喂给 kv_get / _hf_machines_probe_fields。
// 真正的 ssh argv 对照由 cmdSSHProbeArgv 覆盖。
func cmdProbeKV(args []string) int {
	if len(args) != 2 {
		fmt.Fprintln(os.Stderr, "difftest probe-kv: 用法 probe-kv <kv-text> <KEY>")
		return exitUsage
	}
	fmt.Println(sshprobe.KVGet(args[0], args[1]))
	return exitOK
}
