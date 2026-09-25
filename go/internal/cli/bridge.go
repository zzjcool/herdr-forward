// bridge.go —— `forward bridge {up,down,status,serve,run}`（← bin/forward 的 cmd_bridge /
// cmd_bridge_status / _hf_bridge_require / _hf_default_plugin_state_dir）。
//
// `serve` / `run` 是内部入口：serve 由 client 经 SSH 调起（在 B 上跑），run 是 A 侧前台
// supervisor（`bridge up` 把它 setsid 到后台）。两者都在本 phase 与 bash 一起切成 Go
// （PLAN §6 Phase 3 的硬要求：**不留 mixed-version 协议窗口**）。
package cli

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/zzjcool/herdr-forward/internal/bridge"
	"github.com/zzjcool/herdr-forward/internal/jqjson"
)

// cmdBridge 复刻 cmd_bridge。
func cmdBridge(args []string) int {
	if len(args) == 0 {
		return die(exitUsage, "缺少 bridge 子命令。用法：forward bridge up|down|status|serve|run")
	}
	sub := args[0]
	rest := args[1:]
	switch sub {
	case "serve":
		if os.Getenv("HERDR_PLUGIN_STATE_DIR") == "" {
			_ = setEnv("HERDR_PLUGIN_STATE_DIR", defaultPluginStateDir())
		}
		return bridgeServe()
	case "run":
		if len(rest) != 1 {
			return die(exitUsage, "用法：forward bridge run <machine-id>")
		}
		return bridgeRun(rest[0])
	case "up":
		if len(rest) != 1 {
			return die(exitUsage, "用法：forward bridge up <machine-id>")
		}
		out, _ := bridgeUp(rest[0])
		fmt.Println(out)
		return exitOK
	case "down":
		if len(rest) != 1 {
			return die(exitUsage, "用法：forward bridge down <machine-id|all>")
		}
		if rest[0] == "all" {
			bridgeDownAll()
			return exitOK
		}
		bridgeDown(rest[0])
		return exitOK
	case "status":
		return cmdBridgeStatus(rest)
	default:
		return die(exitUsage, "未知 bridge 子命令："+sub+"。可用：up / down / status / serve / run。")
	}
}

// bridgeServe 复刻 `bridge serve` 的入口：常驻循环直到 stdin EOF / 信号。
func bridgeServe() int {
	if err := bridge.Serve(signalContext()); err != nil {
		return die(exitError, err.Error())
	}
	return exitOK
}

// bridgeRun 复刻 `bridge run <machine>`（前台 supervisor）。
func bridgeRun(machineID string) int {
	if err := bridge.RunSupervisor(signalContext(), machineID); err != nil {
		return die(exitUsage, err.Error())
	}
	return exitOK
}

// cmdBridgeStatus 复刻 cmd_bridge_status（--json 与表格两形态）。
func cmdBridgeStatus(args []string) int {
	jsonOut := false
	if len(args) > 0 && args[0] == "--json" {
		jsonOut = true
		args = args[1:]
	}
	if len(args) > 0 {
		return die(exitUsage, "用法：forward bridge status [--json]")
	}

	clients := bridge.Clients()
	sessions := bridge.Sessions()
	if jsonOut {
		doc := jqjson.NewObject()
		doc.Set("clients", objArray(clients))
		doc.Set("sessions", objArray(sessions))
		fmt.Println(jqjson.Encode(doc, false))
		return exitOK
	}

	fmt.Print("本机作为 client（把远端端口映射到本机 localhost）：\n")
	any := false
	for _, c := range clients {
		any = true
		label := bridge.ObjStr(c, "label")
		if label == "" {
			label = bridge.ObjStr(c, "machine")
		}
		state := ""
		if v, _ := c.Get("running"); !jqjson.Truthy(v) {
			state = "未运行"
		} else {
			state = bridge.ObjStr(c, "state")
		}
		reason := bridge.ObjStr(c, "reason")
		reasonPart := ""
		if reason != "" && state != "connected" {
			reasonPart = "（" + reason + "）"
		}
		up, total := 0, 0
		if fwVal, ok := c.Get("forwards"); ok {
			if fwObj, ok := fwVal.(*jqjson.Object); ok {
				for _, id := range fwObj.Keys() {
					total++
					val, _ := fwObj.Get(id)
					if vo, ok := val.(*jqjson.Object); ok {
						if bridge.ObjStr(vo, "state") == "up" {
							up++
						}
					}
				}
			}
		}
		fmt.Printf("  %s  %s  %s%s  映射 %d/%d\n", label, bridge.ObjStr(c, "target"), state, reasonPart, up, total)
	}
	if !any {
		fmt.Print("  （无）\n")
	}

	fmt.Print("本机作为 server（client 经桥接 attach 进来）：\n")
	any = false
	for _, s := range sessions {
		any = true
		host := bridge.ObjStr(s, "client_host")
		if host == "" {
			host = "?"
		}
		live := "心跳超时"
		if v, _ := s.Get("live"); jqjson.Truthy(v) {
			live = "在线"
		}
		up := 0
		if stVal, ok := s.Get("status"); ok {
			if stObj, ok := stVal.(*jqjson.Object); ok {
				for _, id := range stObj.Keys() {
					val, _ := stObj.Get(id)
					if vo, ok := val.(*jqjson.Object); ok && bridge.ObjStr(vo, "state") == "up" {
						up++
					}
				}
			}
		}
		fmt.Printf("  client %s（%s）%s  映射 up %d\n", host, bridge.ObjStr(s, "client_label"), live, up)
	}
	if !any {
		fmt.Print("  （无）\n")
	}
	return exitOK
}

// objArray 把插入序对象列表转成 `[]any`（喂给 jqjson 编码器）。
func objArray(objs []*jqjson.Object) []any {
	out := make([]any, 0, len(objs))
	for _, o := range objs {
		out = append(out, o)
	}
	return out
}

// defaultPluginStateDir 复刻 _hf_default_plugin_state_dir：按 manifest 的 id 推导 herdr
// 给本插件分配的 state 目录。
//
// 经 SSH 调起的 `bridge serve` 不在插件上下文里；client 总会显式传 HERDR_PLUGIN_STATE_DIR，
// 这里只兜手动调用，避免落到与面板分叉的 ~/.local/state/herdr-forward。
func defaultPluginStateDir() string {
	id := "zzjcool:forward"
	manifest := filepath.Join(pluginRootOfSelf(), "herdr-plugin.toml")
	if data, err := os.ReadFile(manifest); err == nil {
		for _, line := range strings.Split(string(data), "\n") {
			trimmed := strings.TrimSpace(line)
			if !strings.HasPrefix(trimmed, "id") {
				continue
			}
			rest := strings.TrimSpace(strings.TrimPrefix(trimmed, "id"))
			if !strings.HasPrefix(rest, "=") {
				continue
			}
			value := strings.TrimSpace(strings.TrimPrefix(rest, "="))
			if len(value) >= 2 && value[0] == '"' && value[len(value)-1] == '"' {
				id = value[1 : len(value)-1]
				break
			}
		}
	}
	base := os.Getenv("XDG_STATE_HOME")
	if base == "" {
		home := os.Getenv("HOME")
		if home == "" {
			home = "/tmp"
		}
		base = filepath.Join(home, ".local", "state")
	}
	return filepath.Join(base, "herdr", "plugins", strings.ReplaceAll(id, ":", "%3A"))
}

// parsePortInt 解析一个十进制端口（失败 → ok=false）。
func parsePortInt(s string) (int, bool) {
	n, err := strconv.Atoi(s)
	if err != nil {
		return 0, false
	}
	return n, true
}
