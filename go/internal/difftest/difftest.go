// Package difftest — 差分测试 harness 的 Go 侧（PLAN-GO-MIGRATION §6 Phase 1 /
// §10 W1：tests/difftest/run.sh 的对照程序）。
//
// 用途：把 Go 实现的行为以「纯结果」形式输出到 stdout，供 tests/difftest/run.sh
// 与 bash 对位实现逐字节比对。它**不是**用户可见 CLI —— 是给测试用的调试探针，
// 因此刻意不依赖 internal/cli（W4 的范围），而自带一个极小的 dispatch。
//
// 调试子命令（与任务约定 `forward-go internal difftest <case>` 对齐）：
//
//	difftest selftest                     打印 "difftest-ok"（供 harness 探测接线）
//	difftest state-load                   读 $HERDR_PLUGIN_STATE_DIR/forwards.json，
//	                                      stdout 打印标准化的 forwards 数组
//	difftest state-save <array.json>      读数组文件 -> state.Save -> 落盘
//	difftest add <record.json>            state.Add
//	difftest remove <id>                  state.Remove
//	difftest set-status <id> <status>     state.SetStatus
//	difftest probe <host> <port> <secs>   hfcommon.ProbePayload，stdout: up|degraded|down
//	difftest serve <reply|silent|close>   起 127.0.0.1 测试服务并打印监听端口，前台运行
//	difftest tunnel-args <id> <lp> <remote_host:rp> <target>   tunnel.SSHArgs 一行一个 argv
//	                                      （与 lib/tunnel.sh 的 tunnel_ssh_args 逐行比对）
//
// Phase 3 新增（见 phase3.go）：
//
//	difftest hf-parse <line>              HF1 行解析（OK/ERR + 归一化字段）
//	difftest hf-fmt <kind> …              HF1 行编码（与 lib/bridge.sh 的 printf 对照）
//	difftest hf-valid <id> <lp> <rp>      C6 安全边界（yes / 空）
//	difftest ssh-dest <target>            bridge_ssh_destination
//	difftest remote-cmd <root> <state>    bridge_remote_serve_cmd
//	difftest bridge-ssh-args <ctl>        bridge_ssh_args（一行一个 argv）
//	difftest bridge-active <sub> …        激活状态 schema（active/has/view-json/resolve）
//	difftest probe-kv <text> <KEY>        kv_get 对照
//
// 兼容形式：Main 会跳过前导的 "internal"/"difftest" 词元，因此
// `forward-go internal difftest state-load` 也能工作（W4 接线后零改动复用本包）。
package difftest

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"strconv"
	"time"

	"github.com/zzjcool/herdr-forward/internal/hfcommon"
	"github.com/zzjcool/herdr-forward/internal/state"
	"github.com/zzjcool/herdr-forward/internal/tunnel"
)

// 退出码（对齐 ARCHITECTURE §A.3 冻结退出码表里本层会用到的子集）。
const (
	exitOK         = 0
	exitUsage      = 64
	exitInternal   = 1
	exitDupPort    = 2
	exitNotFound   = 3
	exitInvalidArg = 1
)

// Main 是调试入口，返回值即进程退出码。
func Main(args []string) int {
	// 跳过 W4 可能加上的 "internal difftest" 前缀，保持两种调用形态等价。
	for len(args) > 0 && (args[0] == "internal" || args[0] == "difftest") {
		args = args[1:]
	}
	if len(args) == 0 {
		fmt.Fprintln(os.Stderr, "difftest: 缺少子命令（见 go/internal/difftest/difftest.go 顶部注释）")
		return exitUsage
	}

	switch args[0] {
	case "selftest":
		fmt.Println("difftest-ok")
		return exitOK
	case "state-load":
		return cmdStateLoad()
	case "state-save":
		return cmdStateSave(args[1:])
	case "add":
		return cmdAdd(args[1:])
	case "remove":
		return cmdRemove(args[1:])
	case "set-status":
		return cmdSetStatus(args[1:])
	case "probe":
		return cmdProbe(args[1:])
	case "tunnel-args":
		return cmdTunnelArgs(args[1:])
	case "serve":
		return cmdServe(args[1:])
	case "hf-parse":
		return cmdHFParse(args[1:])
	case "hf-fmt":
		return cmdHFFmt(args[1:])
	case "hf-valid":
		return cmdHFValid(args[1:])
	case "ssh-dest":
		return cmdSSHDest(args[1:])
	case "remote-cmd":
		return cmdRemoteCmd(args[1:])
	case "bridge-ssh-args":
		return cmdBridgeSSHArgs(args[1:])
	case "bridge-active":
		return cmdBridgeActive(args[1:])
	case "probe-kv":
		return cmdProbeKV(args[1:])
	default:
		fmt.Fprintf(os.Stderr, "difftest: 未知子命令 %q\n", args[0])
		return exitUsage
	}
}

// canonicalForwards 把记录序列化为与 jq -S -c 等价的规范数组（键名按字母序、紧凑）。
// Forward 的字段声明序已是字母序，Publish 自定义 MarshalJSON 也是字母序，
// 因此这里直接用 encoding/json 即可。
func canonicalForwards(fw []state.Forward) ([]byte, error) {
	if fw == nil {
		fw = []state.Forward{}
	}
	return json.Marshal(fw)
}

func cmdStateLoad() int {
	fw, err := state.Load()
	if err != nil {
		fmt.Fprintf(os.Stderr, "difftest state-load: %v\n", err)
		return exitInternal
	}
	out, err := canonicalForwards(fw)
	if err != nil {
		fmt.Fprintf(os.Stderr, "difftest state-load: %v\n", err)
		return exitInternal
	}
	fmt.Println(string(out))
	return exitOK
}

func cmdStateSave(args []string) int {
	if len(args) != 1 {
		fmt.Fprintln(os.Stderr, "difftest state-save: 用法 state-save <array.json>")
		return exitUsage
	}
	fw, err := decodeArrayFile(args[0])
	if err != nil {
		fmt.Fprintf(os.Stderr, "difftest state-save: %v\n", err)
		return exitInvalidArg
	}
	if err := state.Save(fw); err != nil {
		fmt.Fprintf(os.Stderr, "difftest state-save: %v\n", err)
		return exitInternal
	}
	return exitOK
}

func cmdAdd(args []string) int {
	if len(args) != 1 {
		fmt.Fprintln(os.Stderr, "difftest add: 用法 add <record.json>")
		return exitUsage
	}
	raw, err := os.ReadFile(args[0])
	if err != nil {
		fmt.Fprintf(os.Stderr, "difftest add: %v\n", err)
		return exitInvalidArg
	}
	var rec state.Forward
	if err := json.Unmarshal(raw, &rec); err != nil {
		fmt.Fprintf(os.Stderr, "difftest add: 非法 record JSON: %v\n", err)
		return exitInvalidArg
	}
	return mapErr(state.Add(rec))
}

func cmdRemove(args []string) int {
	if len(args) != 1 {
		fmt.Fprintln(os.Stderr, "difftest remove: 用法 remove <id>")
		return exitUsage
	}
	return mapErr(state.Remove(args[0]))
}

func cmdSetStatus(args []string) int {
	if len(args) != 2 {
		fmt.Fprintln(os.Stderr, "difftest set-status: 用法 set-status <id> <status>")
		return exitUsage
	}
	return mapErr(state.SetStatus(args[0], args[1]))
}

func cmdProbe(args []string) int {
	if len(args) != 3 {
		fmt.Fprintln(os.Stderr, "difftest probe: 用法 probe <host> <port> <timeout_sec>")
		return exitUsage
	}
	port, err := strconv.Atoi(args[1])
	if err != nil {
		fmt.Fprintf(os.Stderr, "difftest probe: 非法端口 %q\n", args[1])
		return exitInvalidArg
	}
	timeout, err := strconv.Atoi(args[2])
	if err != nil {
		fmt.Fprintf(os.Stderr, "difftest probe: 非法 timeout %q\n", args[2])
		return exitInvalidArg
	}
	fmt.Println(hfcommon.ProbePayload(args[0], port, timeout).String())
	return exitOK
}

// cmdTunnelArgs 输出 tunnel.SSHArgs 的 argv，一行一个元素，供 harness 与 bash 的
// tunnel_ssh_args（lib/tunnel.sh）逐行比对。这是「ssh argv 逐 flag 复刻」的实测门。
func cmdTunnelArgs(args []string) int {
	if len(args) != 4 {
		fmt.Fprintln(os.Stderr, "difftest tunnel-args: 用法 tunnel-args <id> <lp> <remote_host:rp> <target>")
		return exitUsage
	}
	lp, err := strconv.Atoi(args[1])
	if err != nil {
		fmt.Fprintf(os.Stderr, "difftest tunnel-args: 非法 lp %q\n", args[1])
		return exitInvalidArg
	}
	argv, err := tunnel.SSHArgs(args[0], lp, args[2], args[3])
	if err != nil {
		fmt.Fprintf(os.Stderr, "difftest tunnel-args: %v\n", err)
		return exitInternal
	}
	for _, a := range argv {
		fmt.Println(a)
	}
	return exitOK
}

// cmdServe 起一个 127.0.0.1 测试服务并打印实际监听端口（关闭竞态：用 :0 让内核分配）。
// 供 harness 在同一服务上跑 bash probe_payload 与 go probe，做真正的差分对照。
func cmdServe(args []string) int {
	if len(args) != 1 {
		fmt.Fprintln(os.Stderr, "difftest serve: 用法 serve <reply|silent|close>")
		return exitUsage
	}
	mode := args[0]
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		fmt.Fprintf(os.Stderr, "difftest serve: listen 失败: %v\n", err)
		return exitInternal
	}
	fmt.Println(ln.Addr().(*net.TCPAddr).Port)

	for {
		c, err := ln.Accept()
		if err != nil {
			return exitOK
		}
		go handleTestConn(c, mode)
	}
}

func handleTestConn(c net.Conn, mode string) {
	defer c.Close()
	_ = c.SetReadDeadline(time.Now().Add(5 * time.Second))
	buf := make([]byte, 256)
	_, _ = c.Read(buf)
	switch mode {
	case "reply":
		_, _ = c.Write([]byte("pong\n"))
	case "silent":
		time.Sleep(3 * time.Second)
	case "close":
		// 立刻关闭 -> 对端读到 EOF
	}
}

func decodeArrayFile(path string) ([]state.Forward, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	raw, err := io.ReadAll(f)
	if err != nil {
		return nil, err
	}
	var fw []state.Forward
	if err := json.Unmarshal(raw, &fw); err != nil {
		return nil, fmt.Errorf("非法数组 JSON: %w", err)
	}
	if fw == nil {
		fw = []state.Forward{}
	}
	return fw, nil
}

// mapErr 把 state 层哨兵错误映射为 bash die 的退出码语义。
func mapErr(err error) int {
	switch {
	case err == nil:
		return exitOK
	case errors.Is(err, state.ErrDuplicatePort):
		fmt.Fprintf(os.Stderr, "difftest: %v\n", err)
		return exitDupPort
	case errors.Is(err, state.ErrNotFound):
		fmt.Fprintf(os.Stderr, "difftest: %v\n", err)
		return exitNotFound
	case errors.Is(err, state.ErrInvalidPort),
		errors.Is(err, state.ErrInvalidStatus),
		errors.Is(err, state.ErrInvalidID):
		fmt.Fprintf(os.Stderr, "difftest: %v\n", err)
		return exitInvalidArg
	default:
		fmt.Fprintf(os.Stderr, "difftest: %v\n", err)
		return exitInternal
	}
}
