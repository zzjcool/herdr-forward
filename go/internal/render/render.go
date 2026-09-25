// render.go — 展示层纯函数：C3 tab bar oneline 与 `forward list` 表格（list 表）
//
// 行为权威：
//   - Oneline ← lib/render.sh render_oneline（唯一权威，逐行复刻）
//   - Table   ← bin/forward `_hf_list_table`（lib/render.sh 只有 oneline，表格实现在
//     CLI 层；冻结签名见 docs/PLAN-GO-MIGRATION.md §5）
//
// 本包无副作用、无网络、无进程；输出恒为纯文本（无 ANSI，herdr tab_bar_right 不渲染
// 颜色，见 docs/SCOUT-FACTS.md §2.4）。
package render

import (
	"fmt"
	"sort"
	"strconv"
	"strings"

	"github.com/zzjcool/herdr-forward/internal/state"
)

// onelineMaxPorts 是 tab bar 单行最多渲染的端口数（← lib/render.sh RENDER_ONELINE_MAX，
// ARCHITECTURE 假设#5 的防御性上限，行为已冻结）。
const onelineMaxPorts = 6

// onelinePrefix 是 oneline 里每个端口的前缀。多字节字符：Go 的 string 是 UTF-8 字节序列，
// 拼接按原样写字节即可；对外按字符（rune）计数时 ⇅ 占 1 个 rune / 3 个字节，
// 与 bash 的 `${#out}`（locale 下按字符）一致。
const onelinePrefix = "⇅"

// statusUp：oneline 只渲染 status == "up" 的记录（lib/render.sh：select(.status == "up")）。
const statusUp = "up"

// modeBridge：bin/forward 的 `_hf_list_table` 对 mode=bridge 的特殊显示
// （「<machine>(桥接)」）。state.Mode 的冻结常量只有 tunnel/client —— bridge 形态由
// 桥接实时视图（Phase 3）产生，此处按字面量复刻 bash 分支，避免表格在合并视图下失真。
const modeBridge state.Mode = "bridge"

// Oneline 渲染 tab bar 单行（契约 C3）：
//
//	`⇅3000⇅5173` —— 仅 status=up、端口升序；>6 条取前 6 个再追加 `+N`；
//	无 up 记录 / 空切片 / nil -> 空串；恒纯文本（无 ANSI），恒不 panic。
//
// 与 lib/render.sh 的逐点对齐：
//   - jq `select(.status == "up")`：大小写敏感的精确匹配；
//   - jq `| numbers`：只有数值型 local_port 参与渲染。Go 的 int 无法区分「字段缺失/null」
//     与「显式 0」（两者都解码成 0），而 local_port 的合法区间是 1..65535（add 路径强校验），
//     故把 <= 0 视作「无效/缺失」丢弃 —— 这既覆盖了 jq 排除 null 的真实损坏场景，
//     也不会误杀任何合法数据；
//   - 不去重：重复端口按 bash 一样逐个渲染，`total` 也按重复计数；
//   - 🌐 后缀（二期 publish 标记）只在 bin/forward 的内置降级实现里，lib/render.sh 无此
//     逻辑，故本函数不输出（C3 亦未包含）。
func Oneline(fw []state.Forward) string {
	ports := make([]int, 0, len(fw))
	for _, f := range fw {
		if f.Status != statusUp {
			continue
		}
		if f.LocalPort <= 0 {
			continue // jq `numbers` 语义：null/缺失不进列表（见上方说明）
		}
		ports = append(ports, f.LocalPort)
	}
	if len(ports) == 0 {
		return ""
	}
	sort.Ints(ports)

	shown := ports
	if len(shown) > onelineMaxPorts {
		shown = shown[:onelineMaxPorts]
	}

	var b strings.Builder
	for _, p := range shown {
		b.WriteString(onelinePrefix)
		b.WriteString(strconv.Itoa(p))
	}
	if len(ports) > onelineMaxPorts {
		b.WriteString("+")
		b.WriteString(strconv.Itoa(len(ports) - onelineMaxPorts))
	}
	return b.String()
}

// tableFormat 是 `forward list` 表格的列格式（← bin/forward `_hf_list_table` 的 printf：
// `%-10s %-14s %-12s %-10s %-8s %s\n`）。列宽按 rune 计（Go 的 fmt 对字符串按字符宽度
// 填充，与 bash 表格实际做填充的 gawk 在 UTF-8 locale 下一致；中文 machine 名不会错位）。
// 表头与数据行共用同一格式 —— bash 也是同一个格式串分别喂表头与 awk 数据行。
const tableFormat = "%-10s %-14s %-12s %-10s %-8s %s\n"

// Table 渲染 `forward list` 表格（默认输出，无 flag 时）：
//
//	LOCAL      REMOTE         MACHINE      STATUS     PID      SSH_TARGET
//	3000       127.0.0.1:9443 gpu-box      up         12345    user@gpu-box:22
//
// 行为权威是 bin/forward `_hf_list_table` + `_hf_view_json`：按 local_port 升序；列语义
// 逐条复刻（remote_host 缺省 127.0.0.1、machine 空 -> "-"、pid null -> "-"、
// ssh_target 空 -> "-"、mode=client -> "client"、mode=bridge -> "<machine>(桥接)"）。
// 输出以换行结尾（与 bash 的 printf/awk 输出逐字节同形，便于调用方直接写 stdout）。
//
// nowUnix 是 §5 冻结签名的一部分，但 bash 的 `forward list` 表格没有任何时间列
// （`_hf_list_table` 不读 created_unix），因此当前不参与渲染 —— 保留该参数是为了不破坏
// 冻结签名，并给后续（panel/AGE 列）留位置；已在本 worker 报告中标注为待裁决项。
//
// 已知偏差（受限于 state.Forward 冻结字段，报告「未决问题」有完整清单）：
//   - mode=client 的第 6 列 bash 显示 status_reason、MACHINE 列可显示 "client:<A>"
//     （两者都来自 _hf_view_json/bridge_merge_live 注入的 status_reason/client 字段，
//     而 state.Forward 无此字段）-> 本函数固定给 "client" 与 "-"；
//   - 字段为 null 的各种情形：jq 的 `//` 只替换 null（不替换 ""），Go 的 string/int 零值
//     无法区分两者，统一取「null 行为」（remote_host -> 127.0.0.1、machine -> "-"、
//     status -> "-"、remote_port -> 0）。这些只可能在手改/损坏记录里出现。
//
// 上面这些偏差全部被 TestTableKnownDeviations 显式钉住，改动它们必须同步改契约说明。
func Table(fw []state.Forward, nowUnix int64) string {
	_ = nowUnix // 冻结签名参数：bash 表格无时间列（见上方说明）

	rows := make([]state.Forward, len(fw))
	copy(rows, fw)
	sort.SliceStable(rows, func(i, j int) bool { return rows[i].LocalPort < rows[j].LocalPort })

	var b strings.Builder
	fmt.Fprintf(&b, tableFormat, "LOCAL", "REMOTE", "MACHINE", "STATUS", "PID", "SSH_TARGET")
	for _, f := range rows {
		fmt.Fprintf(
			&b,
			tableFormat,
			strconv.Itoa(f.LocalPort),
			tableRemote(f),
			tableMachine(f),
			tableStatus(f),
			tablePID(f),
			tableSSHTarget(f),
		)
	}
	return b.String()
}

// tableRemote：`(.remote_host // "127.0.0.1") + ":" + (.remote_port | tostring)`。
func tableRemote(f state.Forward) string {
	host := f.RemoteHost
	if host == "" {
		host = "127.0.0.1"
	}
	return host + ":" + strconv.Itoa(f.RemotePort)
}

// tableMachine：client -> "client"（缺 client 字段，见 Table 已知偏差）；
// bridge -> "<machine 或 ->(桥接)"；machine 空 -> "-"；否则 machine 原文。
func tableMachine(f state.Forward) string {
	switch f.Mode {
	case state.ModeClient:
		return "client"
	case modeBridge:
		machine := f.Machine
		if machine == "" {
			machine = "-"
		}
		return machine + "(桥接)"
	}
	if f.Machine == "" {
		return "-"
	}
	return f.Machine
}

// tableStatus：`(.status // "-")`。
func tableStatus(f state.Forward) string {
	if f.Status == "" {
		return "-"
	}
	return f.Status
}

// tablePID：`if .pid == null then "-" else (.pid | tostring) end`。
func tablePID(f state.Forward) string {
	if f.Pid == nil {
		return "-"
	}
	return strconv.Itoa(*f.Pid)
}

// tableSSHTarget：client 记录显示 status_reason（缺字段 -> "-"，见 Table 已知偏差）；
// 其余记录：ssh_target 空 -> "-"，否则原文。
func tableSSHTarget(f state.Forward) string {
	if f.Mode == state.ModeClient {
		return "-"
	}
	if f.SshTarget == "" {
		return "-"
	}
	return f.SshTarget
}
