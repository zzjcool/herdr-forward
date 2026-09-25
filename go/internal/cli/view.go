// view.go — `list` 的展示视图（← bin/forward `_hf_view_json` + lib/bridge.sh 只读半边）。
//
// 为什么要在 Go 侧实现「桥接实时状态合并」：
//
//	`forward list`（表格/--json/--oneline）展示的不只是状态文件里的记录，还有两类运行时
//	信息（PLAN-GO-MIGRATION §5 契约 C5/C6）：
//	  1. client 映射（mode=client）的**实时**状态：由 B 侧会话文件（session-<pid>.json）
//	     汇报，合并出 up/down/pending/waiting 与 status_reason / client；
//	  2. 本机作为 client（A 侧）经桥接生效中的映射（mode=bridge，client-<mid>.json）。
//	Phase 1 的 W4 只迁移 `list`，因此这一段必须在 Go 里复刻，否则 tab bar / 面板会在
//	切换瞬间丢状态。Phase 3 迁移 bridge 写侧时，本文件退化为「薄包装」。
//
// 行为权威是 lib/bridge.sh 的**只读**函数（bridge_sessions_json /
// bridge_live_status_json / bridge_merge_live / bridge_clients_json /
// bridge_client_forwards_json）与 lib/state.sh 的 state_load。迁移期铁律是零行为变化，
// 因此这里逐条对齐它们，包括看起来多余的细节：
//   - 会话文件对应的 pid 已死 -> **顺手删掉该文件**（bash 也是这么干的，原样复刻）；
//   - BRIDGE_LIVE_WINDOW_S 环境变量可覆盖在线判定窗口；
//   - 同一映射被多个 client 汇报时「up 优先」，否则取会话列表里的第一条；
//   - `status_reason` / `machine` 这类字段在 bash 里可能是 jq 的 null，这里保持 null
//     （而不是空串）以便 --json 逐字节一致。
//
// 与本文件相关、但**不属于**本层职责的偏离（已在 W1/W2 报告登记，difftest 用
// schema 完整的夹具规避）：类型化模型 state.Forward 无法表达「字段缺失/null」，
// 故 render.Table 的输入由本文件用**代理行**构造（见 list.go 的 tableRows）。
package cli

import (
	"math"
	"sort"
	"strconv"
	"strings"

	"github.com/zzjcool/herdr-forward/internal/bridge"
	"github.com/zzjcool/herdr-forward/internal/hfcommon"
	"github.com/zzjcool/herdr-forward/internal/jqjson"
)

// lib/state.sh 的三条 warn 文案（逐字复刻；`log warn` 会同时镜像到 stderr）。
const (
	stateWarnUnparsable = "状态文件不可解析或非对象：%s，按空状态继续（原文件保留，未被覆盖）。"
	stateWarnNoForwards = "状态文件缺少 forwards 数组：%s，按空状态继续（原文件保留，未被覆盖）。"
	// stateWarnForwardsRead 是第三条文案。Go 侧**不可达**：bash 只在「type 检查通过、
	// 随后 jq -c '.forwards' 失败」时打印（现实里需要 I/O 中途出错），而 Go 的 parseJV
	// 一次性完成解析。保留常量是为了让后来者一眼看到对齐关系，不构造假调用点。
	stateWarnForwardsRead = "读取 forwards 数组失败：%s，按空状态继续。"
)

// bridgeLiveWindowDefault 是 client 心跳在线窗口的缺省秒数（← BRIDGE_LIVE_WINDOW_S）。
const bridgeLiveWindowDefault = 20

// stateFilePath 复刻 state_file（lib/state.sh：`${state_dir}/forwards.json`）。
// state.FilePath() 是同一语义的冻结实现；本文件的「原始视图」读的是同一路径。
func stateFilePath() string { return hfcommon.StateDir() + "/forwards.json" }

// view 是 `list` 的展示视图（← `_hf_view_json` 的 stdout）。
type view struct {
	raw     []any // 状态文件里的原始 forwards 数组（合并前；`ports` 的 FORWARDED 用它）
	rows    []any // 展示数组：合并后的本机记录 + 桥接生效中的远端映射（mode=bridge）
	mergeOK bool  // false = bash 侧 bridge_merge_live 的 jq 报错，视图退化为空串
}

// anyObjects 把 bridge 包的「插入序对象」列表转成本包内部使用的 any 切片。
func anyObjects(objs []*jqjson.Object) []any {
	out := make([]any, 0, len(objs))
	for _, o := range objs {
		out = append(out, o)
	}
	return out
}

// objList 把 any 切片里的对象挑出来（非对象元素由调用方另行处理）。
func objList(rows []any) []*jqjson.Object {
	out := make([]*jqjson.Object, 0, len(rows))
	for _, r := range rows {
		if o, ok := r.(*jqjson.Object); ok {
			out = append(out, o)
		}
	}
	return out
}

// loadView 复刻 _hf_view_json：
//
//	forwards = forward_list_json          （= state_load）
//	bridge.sh 缺失          -> 原样返回
//	merged = bridge_merge_live(forwards)
//	remote = bridge_client_forwards_json()
//	remote == "[]"          -> merged
//	否则                     -> merged ++ remote
func loadView() view {
	raw, allObjects := bridge.RawForwards()
	if !allObjects {
		// bash：bridge_merge_live 的 jq 对非对象元素报 `Cannot index number with
		// string ("mode")`，该赋值失败 -> merged 空串 -> 视图整体为空。
		// 下游表现（实测）：`list --json`/`--oneline` 空 stdout 且 rc 0；表格只剩表头。
		return view{raw: anyObjects(raw), mergeOK: false}
	}
	rows, _ := bridge.MergeView()
	return view{raw: anyObjects(raw), rows: anyObjects(rows), mergeOK: true}
}

// allObjects 报告数组里是否每个元素都是 JSON 对象（空数组为真）。
func allObjects(arr []any) bool {
	for _, e := range arr {
		if _, ok := e.(*jqjson.Object); !ok {
			return false
		}
	}
	return true
}

// RawForwards 的两个 warn 文案与 bridge 包同源，本包不再重复定义。

// --- 小工具 ---------------------------------------------------------------

func jqGet(o *jqjson.Object, key string) any {
	if o == nil {
		return nil
	}
	v, _ := o.Get(key)
	return v
}

func jsonNumber(lit string) any { return jqjson.NumberLiteral(lit) }

// isDigits 判定纯 ASCII 数字串（复刻 bash `[[ ${x} =~ ^[0-9]+$ ]]`）。
func isDigits(s string) bool {
	if s == "" {
		return false
	}
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return true
}

func atoiOK(s string) (int, bool) {
	n, err := strconv.Atoi(s)
	if err != nil {
		return 0, false
	}
	return n, true
}

// floorDigits 复刻 `.last_seen_unix // 0 | floor` 的**字符串**形态（用于 `^[0-9]+$` 判定）：
//
//   - 非数字（含 null/字符串/布尔）-> jq 的 floor 会报错 -> 判定失败 -> "0"；
//   - 纯数字字面量 -> 原样（含超长整数，jq 的 decNumber 不会重排整数）；
//   - 无指数的小数 -> 向下取整（jq floor）；负数 -> 负号使正则不匹配 -> "0"；
//   - 带指数/超大值 -> jq 打印成科学计数/E 记法 -> 正则不匹配 -> "0"。
func floorDigits(v any) string {
	n, ok := v.(jqjson.Number)
	if !ok {
		return "0"
	}
	lit := string(n)
	if isDigits(lit) {
		return lit
	}
	if strings.ContainsAny(lit, "eE") {
		return "0"
	}
	f, err := strconv.ParseFloat(lit, 64)
	if err != nil || math.IsInf(f, 0) || math.IsNaN(f) {
		return "0"
	}
	fl := math.Floor(f)
	if fl < 0 || fl >= 1e15 {
		return "0"
	}
	return strconv.FormatInt(int64(fl), 10)
}

// sortByKeyStable 复刻 jq 的 `sort_by(.key)`：稳定排序，键缺失按 null 参与比较
// （jq 的类型序：null < false < true < number < string < array < object）。
func sortByKeyStable(rows []any, key string) {
	sort.SliceStable(rows, func(i, j int) bool {
		return jvCompare(jqGet(asObj(rows[i]), key), jqGet(asObj(rows[j]), key)) < 0
	})
}

func asObj(v any) *jqjson.Object {
	o, _ := v.(*jqjson.Object)
	return o
}

func reverseAny(rows []any) {
	for i, j := 0, len(rows)-1; i < j; i, j = i+1, j-1 {
		rows[i], rows[j] = rows[j], rows[i]
	}
}

// jvTypeRank 给出 jq 的跨类型排序序位（null < false < true < number < string < array < object）。
func jvTypeRank(v any) int {
	switch t := v.(type) {
	case nil:
		return 0
	case bool:
		if t {
			return 2
		}
		return 1
	case jqjson.Number:
		return 3
	case string:
		return 4
	case []any:
		return 5
	case *jqjson.Object:
		return 6
	default:
		return 7
	}
}

// jvCompare 复刻 jq 的 `sort` 比较（同类型内按值；number 用数值比较）。
func jvCompare(a, b any) int {
	ra, rb := jvTypeRank(a), jvTypeRank(b)
	if ra != rb {
		return ra - rb
	}
	switch ra {
	case 0, 1, 2:
		return 0
	case 3:
		af, _ := strconv.ParseFloat(jqjson.FormatNumber(string(a.(jqjson.Number))), 64)
		bf, _ := strconv.ParseFloat(jqjson.FormatNumber(string(b.(jqjson.Number))), 64)
		switch {
		case af < bf:
			return -1
		case af > bf:
			return 1
		default:
			return 0
		}
	case 4:
		return strings.Compare(a.(string), b.(string))
	default:
		return strings.Compare(jqjson.Encode(a, false), jqjson.Encode(b, false))
	}
}

// jvCompareString 是给「已经确定是字符串」的键用的快捷比较（group_by(.id)）。
func jvCompareString(a, b string) int { return strings.Compare(a, b) }
