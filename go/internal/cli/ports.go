// ports.go — `forward ports`（← bin/forward cmd_ports + lib/ports.sh）。
//
// 数据源由 W3 的冻结实现 internal/ports 提供（Linux 走 /proc/net/tcp{,6}，macOS 走
// lsof），本文件只做三件事：
//
//  1. `--json`：`[{port,addr,process}]` —— **保留插入顺序**（bash 在此处没有 -S），
//     紧凑单行 + 结尾换行；且按 bash 的顺序语义在「多余参数检查」之前就打印返回
//     （`forward ports --json extra` 实测 rc 0）。
//  2. 默认：表头 `PORT ADDR PROCESS FORWARDED` + 数据行（列宽 7/16/20/rest）。
//  3. FORWARDED 列：用**状态文件的原始记录**（未合并桥接视图）里 mode=client 的
//     `.remote_port -> .local_port` 映射；命中则 `client:<local_port>`，否则 `-`。
//     映射的构造复刻 bash 的 jq：`map(select(.mode=="client") | {key:(.remote_port|tostring),
//     value:.local_port}) | from_entries`（重复键取最后一条）。
//
// 已知偏离（有意，报告已登记）：process 列。bash 优先用 `ss`（带进程名），Go 侧按 W3
// 冻结实现读 /proc（拿不到进程名）-> Linux 上 PROCESS 列恒为空（显示 `-`）。
// difftest / E2E 在 bash 侧屏蔽 ss（symlink 农场）以保证两侧同源，细节见
// tests/difftest/README.md。
package cli

import (
	"fmt"
	"strconv"
	"strings"

	"github.com/zzjcool/herdr-forward/internal/bridge"
	"github.com/zzjcool/herdr-forward/internal/hfcommon"
	"github.com/zzjcool/herdr-forward/internal/jqjson"
	"github.com/zzjcool/herdr-forward/internal/ports"
)

const portsUsage = "用法：forward ports [--json]"

// cmdPorts 复刻 cmd_ports：--json 优先（且在多余参数检查之前返回），否则有参数即 64。
func cmdPorts(args []string) int {
	listeners, err := ports.List()
	if err != nil {
		// bash：无 /proc 且无 ss/lsof 时 ports_listening_json 输出 []（不报错）。
		// Go 侧把「数据源不可用」显式降级为 warn + 空列表（与 bash 的最终可见输出一致，
		// 但多一条可诊断的 warn；报告中登记）。
		hfcommon.Logf("warn", "端口枚举数据源不可用：%v（按空列表继续）。", err)
		listeners = []ports.Listener{}
	}

	if len(args) > 0 && args[0] == "--json" {
		fmt.Println(jqjson.Encode(portsJSONModel(listeners), false))
		return exitOK
	}
	if len(args) > 0 {
		return die(exitUsage, portsUsage)
	}

	forwards := forwardedMap()
	var b strings.Builder
	fmt.Fprintf(&b, "%-7s %-16s %-20s %s\n", "PORT", "ADDR", "PROCESS", "FORWARDED")
	for _, l := range listeners {
		proc := l.Process
		if proc == "" {
			proc = "-"
		}
		target := "-"
		if lp, ok := forwards[strconv.Itoa(l.Port)]; ok {
			target = "client:" + lp
		}
		fmt.Fprintf(&b, "%-7s %-16s %-20s %s\n", strconv.Itoa(l.Port), l.Addr, proc, target)
	}
	fmt.Print(b.String())
	return exitOK
}

// portsJSONModel 构造 `[{port,addr,process}]`（键序必须是 port,addr,process）。
func portsJSONModel(listeners []ports.Listener) any {
	arr := make([]any, 0, len(listeners))
	for _, l := range listeners {
		row := jqjson.NewObject()
		row.Set("port", jqjson.NumberLiteral(strconv.Itoa(l.Port)))
		row.Set("addr", l.Addr)
		row.Set("process", l.Process)
		arr = append(arr, row)
	}
	return arr
}

// forwardedMap 复刻 cmd_ports 里的 FORWARDED 映射构造（键 = `tostring(remote_port)`，
// 值 = `local_port` 的 tostring；只有 null/false 是「假」，故 0 / "" 也会成为键/值）。
//
// 取值来自**原始**状态视图（loadView().raw），不做桥接合并 —— bash 这里调的是
// forward_list_json 而不是 _hf_view_json。
func forwardedMap() map[string]string {
	out := map[string]string{}
	raw, _ := bridge.RawForwards()
	for _, o := range raw {
		if jqjson.Str(jqGet(o, "mode")) != "client" {
			continue
		}
		key := jqjson.ToString(jqGet(o, "remote_port"))
		out[key] = jqjson.ToString(jqGet(o, "local_port"))
	}
	return out
}
