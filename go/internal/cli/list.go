// list.go — `forward list`（← bin/forward cmd_list / _hf_list_table / _hf_oneline）。
//
// 三种输出形态（契约 C1/C5）：
//
//	list           默认表格（表头 + 按 local_port 升序的行）
//	list --oneline tab bar 单行（仅 up、端口升序、>6 截断 +N）
//	list --json    状态文档 {version, forwards}（jq -S -c 字节形态）
//
// 展示视图（本机记录 + 桥接实时状态合并）来自 view.go；表格渲染复用 W2 的纯函数
// render.Table（冻结实现），oneline 复用 render.Oneline。
//
// ⚠ 为什么表格要走「代理行」而不是直接把记录塞进 render.Table：
//
//	render.Table 的入参是冻结类型 state.Forward，它无法表达 bash 表格里的两个
//	视图字段（client 记录的 MACHINE=`client:<client>`、第 6 列=`status_reason`）。
//	冻结契约禁止改 render.Table，于是这里把视图行**投影**成 render.Table 能表达的
//	形状（client 行改用 ModeTunnel + Machine/SshTarget 承载那两个值），既不改冻结
//	接口，又能在切换瞬间保持与 bash 逐字节一致。投影规则见 rowToForward。
package cli

import (
	"fmt"
	"os"
	"sort"
	"strconv"
	"strings"

	"github.com/zzjcool/herdr-forward/internal/hfcommon"
	"github.com/zzjcool/herdr-forward/internal/jqjson"
	"github.com/zzjcool/herdr-forward/internal/render"
	"github.com/zzjcool/herdr-forward/internal/state"
)

// cmdList 复刻 cmd_list：解析 flag（--oneline / --json 互斥）后分派到三种输出。
func cmdList(args []string) int {
	mode := "table"
	for len(args) > 0 {
		arg := args[0]
		switch {
		case arg == "--oneline":
			if mode == "json" {
				return die(exitUsage, "--oneline 与 --json 互斥，请只选一个。")
			}
			mode = "oneline"
		case arg == "--json":
			if mode == "oneline" {
				return die(exitUsage, "--oneline 与 --json 互斥，请只选一个。")
			}
			mode = "json"
		case strings.HasPrefix(arg, "-"):
			return die(exitUsage, "未知参数："+arg+"。用法：forward list [--oneline] [--json]")
		default:
			return die(exitUsage, "list 不接受位置参数："+arg+"。用法：forward list [--oneline] [--json]")
		}
		args = args[1:]
	}

	v := loadView()
	switch mode {
	case "oneline":
		// bash：line 为空则**什么都不打印**（连换行都没有）。
		if line := render.Oneline(typedRows(v.rows)); line != "" {
			fmt.Println(line)
		}
	case "json":
		return listJSON(v)
	default:
		fmt.Print(render.Table(typedRows(v.rows), hfcommon.NowUnix()))
	}
	return exitOK
}

// listJSON 输出状态文档（← `jq -S -c --argjson v "${FORWARD_STATE_VERSION:-1}" '{version:$v,forwards:.}'`）。
//
// 视图形状与 bash 完全一致：合并后的数组原样作为 forwards，键递归字母序，紧凑单行 +
// 结尾换行；FORWARD_STATE_VERSION 非法时与 jq 一样以 rc 2 退出（stdout 为空）。
func listJSON(v view) int {
	if !v.mergeOK {
		// bash：merged="" -> `printf '%s' "" | jq ...` 无输出，rc 0。
		return exitOK
	}
	version, ok := stateVersionValue()
	if !ok {
		// bash 是 jq 自己报 `invalid JSON text passed to --argjson` 后 rc 2；
		// Go 给一条等价的可诊断信息（文案不同，退出码一致，difftest 只比 rc）。
		hfcommon.Logf("error", "FORWARD_STATE_VERSION 不是合法 JSON：%q（jq --argjson 兼容模式仅接受单个 JSON 值）。", os.Getenv("FORWARD_STATE_VERSION"))
		return exitStateVersionInvalid
	}
	doc := jqjson.NewObject()
	doc.Set("version", version)
	doc.Set("forwards", v.rows)
	fmt.Println(jqjson.Encode(doc, true))
	return exitOK
}

// exitStateVersionInvalid 是「FORWARD_STATE_VERSION 非法 JSON」的退出码。
// bash 里该错误由 jq 抛出，jq 的退出码是 2（与契约 C2 的「重复端口」同值，但语义不同；
// 这里保留 2 以做到「同一输入、同一退出码」）。
const exitStateVersionInvalid = 2

// stateVersionValue 解析 FORWARD_STATE_VERSION（空/未设置 -> 1），返回值模型。
//
// 兼容 jq `--argjson` 的宽松数字形态（`01` / `1.` / `.5` / `+1`）：Go 的 encoding/json
// 会拒绝这四个，而 jq 接受并规范化（实测 `01`->1、`1.`->1、`.5`->0.5、`+1`->1）。
// 其它非法输入（含尾随内容）一律失败 -> 调用方退 rc 2。
func stateVersionValue() (any, bool) {
	raw := os.Getenv("FORWARD_STATE_VERSION")
	if raw == "" {
		raw = "1"
	}
	if v, err := jqjson.Parse([]byte(raw)); err == nil {
		return v, true
	}
	if lit, ok := lenientNumberLiteral(raw); ok {
		return jqjson.NumberLiteral(lit), true
	}
	return nil, false
}

// lenientNumberLiteral 接受 jq 认可的宽松数字形态并返回规范化字面量。
func lenientNumberLiteral(raw string) (string, bool) {
	s := strings.TrimSpace(raw)
	if s == "" {
		return "", false
	}
	i := 0
	if s[i] == '+' || s[i] == '-' {
		i++
	}
	intStart := i
	for i < len(s) && s[i] >= '0' && s[i] <= '9' {
		i++
	}
	intPart := s[intStart:i]
	fracPart := ""
	if i < len(s) && s[i] == '.' {
		i++
		fracStart := i
		for i < len(s) && s[i] >= '0' && s[i] <= '9' {
			i++
		}
		fracPart = s[fracStart:i]
	}
	if intPart == "" && fracPart == "" {
		return "", false
	}
	expPart := ""
	if i < len(s) && (s[i] == 'e' || s[i] == 'E') {
		i++
		expStart := i
		if i < len(s) && (s[i] == '+' || s[i] == '-') {
			i++
		}
		digitsStart := i
		for i < len(s) && s[i] >= '0' && s[i] <= '9' {
			i++
		}
		if i == digitsStart {
			return "", false
		}
		expPart = s[expStart:i]
	}
	if i != len(s) {
		return "", false
	}
	lit := s[:intStart] + orZero(intPart) + "." + fracPart + expPart
	return jqjson.FormatNumber(lit), true
}

func orZero(s string) string {
	if s == "" {
		return "0"
	}
	return s
}

// typedRows 把视图行投影成冻结类型（供 render.Oneline / render.Table 消费）。
func typedRows(rows []any) []state.Forward {
	out := make([]state.Forward, 0, len(rows))
	for _, r := range rows {
		out = append(out, rowToForward(r))
	}
	return out
}

// rowToForward 把一行视图记录投影成 state.Forward。
//
// 投影规则（逐条对齐 bin/forward 的 jq，见 _hf_list_table / render_oneline）：
//
//	LOCAL  = .local_port
//	REMOTE = (.remote_host // "127.0.0.1") + ":" + (.remote_port|tostring)
//	MACHINE:
//	    mode=client -> "client" 或 "client:" + .client
//	                  （render.Table 对 ModeClient 恒给 "client"，故改用 ModeTunnel
//	                   承载 —— 冻结契约禁止改 render.Table）
//	    mode=bridge -> (.machine // "-") + "(桥接)"   （render.Table 原生支持）
//	    其它        -> .machine 或 "-"
//	STATUS = .status
//	PID    = .pid（null -> nil -> "-"）
//	第 6 列 = client -> .status_reason；其余 -> .ssh_target（空 -> "-"）
//
// 另外，bash 在 `@tsv` 阶段会转义字段里的 `\` `\t` `\n` `\r`，这里对进入表格的
// 字符串字段做同样处理（render.Table 只负责按列宽填充）。
//
// 已知偏差（受限于冻结类型的零值语义，W2 报告已登记，difftest 用 schema 完整的
// 夹具规避）：字段缺失/null 与显式空串/0 在 Go 侧不可区分（远端主机、remote_port、
// status、pid 非数字等）。
func rowToForward(e any) state.Forward {
	o, ok := e.(*jqjson.Object)
	if !ok {
		return state.Forward{}
	}
	mode := jqjson.Str(jqGet(o, "mode"))
	f := state.Forward{
		LocalPort:  intOrZero(jqGet(o, "local_port")),
		RemoteHost: tsvEscape(strOrEmpty(jqGet(o, "remote_host"), "127.0.0.1")),
		RemotePort: intOrZero(jqGet(o, "remote_port")),
		Status:     tsvEscape(jqjson.ToString(jqGet(o, "status"))),
		Pid:        intPtrOrNil(jqGet(o, "pid")),
	}
	if p, ok := o.Get("pid"); !ok || p == nil {
		// bash: `if .pid == null then "-"`；保持 nil（render.tablePID 输出 "-"）
		f.Pid = nil
	}
	if s, ok := o.Get("status"); !ok || s == nil {
		f.Status = "" // render.tableStatus 会渲染成 "-"
	}

	switch mode {
	case "client":
		client := jqjson.ToString(jqGet(o, "client"))
		if client == "" {
			f.Machine = "client"
		} else {
			f.Machine = tsvEscape("client:" + client)
		}
		reason := jqjson.ToString(jqGet(o, "status_reason"))
		if reason == "" {
			f.SshTarget = "-"
		} else {
			f.SshTarget = tsvEscape(reason)
		}
	case "bridge":
		f.Mode = state.Mode("bridge")
		machine := jqjson.ToString(jqGet(o, "machine"))
		if machine == "" {
			machine = "-"
		}
		f.Machine = tsvEscape(machine)
		f.SshTarget = tsvOrDash(jqjson.ToString(jqGet(o, "ssh_target")))
	default:
		f.Mode = state.ModeTunnel
		machine := jqjson.ToString(jqGet(o, "machine"))
		if machine == "" {
			machine = "-"
		}
		f.Machine = tsvEscape(machine)
		f.SshTarget = tsvOrDash(jqjson.ToString(jqGet(o, "ssh_target")))
	}
	return f
}

// tsvOrDash 复刻 `(.x // "") == "" then "-" else .x end`。
func tsvOrDash(s string) string {
	if s == "" {
		return "-"
	}
	return tsvEscape(s)
}

// tsvEscape 复刻 jq `@tsv` 的转义集（只处理 `\` `\t` `\n` `\r`；其余控制字符原样）。
func tsvEscape(s string) string {
	if !strings.ContainsAny(s, "\\\t\n\r") {
		return s
	}
	var b strings.Builder
	b.Grow(len(s) + 4)
	for i := 0; i < len(s); i++ {
		switch s[i] {
		case '\\':
			b.WriteString(`\\`)
		case '\t':
			b.WriteString(`\t`)
		case '\n':
			b.WriteString(`\n`)
		case '\r':
			b.WriteString(`\r`)
		default:
			b.WriteByte(s[i])
		}
	}
	return b.String()
}

// strOrEmpty 复刻 `(.x // "def")`：缺失/null 取默认值，其余走 jqToString。
func strOrEmpty(v any, def string) string {
	if v == nil {
		return def
	}
	return jqjson.ToString(v)
}

// intOrZero 取整数（非数字/缺失 -> 0；与 state.Forward 的零值语义一致）。
func intOrZero(v any) int {
	n, ok := v.(jqjson.Number)
	if !ok {
		return 0
	}
	i, err := strconv.Atoi(jqjson.FormatNumber(string(n)))
	if err != nil {
		f, err := strconv.ParseFloat(jqjson.FormatNumber(string(n)), 64)
		if err != nil {
			return 0
		}
		return int(f)
	}
	return i
}

// intPtrOrNil 取可空整数（非整数 -> nil，render.tablePID 输出 "-"）。
func intPtrOrNil(v any) *int {
	n, ok := v.(jqjson.Number)
	if !ok {
		return nil
	}
	lit := jqjson.FormatNumber(string(n))
	if strings.ContainsAny(lit, ".Ee") {
		return nil
	}
	i, err := strconv.Atoi(lit)
	if err != nil {
		return nil
	}
	return &i
}

// sortRowsByLocalPort 稳定按 local_port 升序（等价 render.Table 内部排序；
// 保留给内部断言与排序自测使用）。
func sortRowsByLocalPort(rows []any) {
	sort.SliceStable(rows, func(i, j int) bool {
		return intOrZero(jqGet(asObj(rows[i]), "local_port")) <
			intOrZero(jqGet(asObj(rows[j]), "local_port"))
	})
}
