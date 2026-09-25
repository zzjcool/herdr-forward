// readside.go —— 桥接状态文件的**只读**半边（← lib/bridge.sh 的 bridge_sessions_json /
// bridge_live_status_json / bridge_merge_live / bridge_any_live / bridge_clients_json /
// bridge_client_forwards_json）。
//
// 这些函数被 `forward list` / `forward bridge status` / 面板消费，输出形状是冻结契约
// （C5/C6）。Phase 1 时它们在 internal/cli/view.go 里就地复刻，本 phase 迁到本包，
// cli/view.go 退化为薄包装（§13.7 的预定动作）。
//
// 迁移期铁律是零行为变化，因此这里逐条保留看起来多余的细节：
//   - 会话文件对应的 pid 已死 → **顺手删掉该文件**（bash 也这么干）；
//   - 同一映射被多个 client 汇报时「up 优先」，否则取会话顺序里的第一条；
//   - 等值 last_seen_unix 的会话按 reverse() 倒序（jq 的 sort_by 稳定 + reverse）；
//   - client 行按 glob 顺序（不是排序后）。
//
// jqjson 的「插入序对象」在这里是**必需**的：jq 的 to_entries / 对象迭代按插入顺序，
// 而 status 对象的迭代序决定 tie-break 结果。输出若要求 `-S`（list --json）由编码器排序。
package bridge

import (
	"math"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/zzjcool/herdr-forward/internal/hfcommon"
	"github.com/zzjcool/herdr-forward/internal/jqjson"
	"github.com/zzjcool/herdr-forward/internal/state"
)

// liveStatus 是一个映射 id 的实时状态（← bridge_live_status_json 的 value）。
type liveStatus struct {
	ID     string
	State  string
	Reason string
	Client string
}

// LiveWindow 读 BRIDGE_LIVE_WINDOW_S：
//
//	bash: 未设置/空 → 20；设了非数字 → 算术展开报错，`((...))` 为假 → 永不 live。
//	Go 用 -1 表达「永不 live」，与 bash 的失败分支同效果。
func LiveWindow() int64 {
	raw := os.Getenv("BRIDGE_LIVE_WINDOW_S")
	if raw == "" {
		return int64(LiveWindowSeconds())
	}
	n, err := strconv.ParseInt(raw, 10, 64)
	if err != nil {
		return -1
	}
	return n
}

// Sessions 复刻 bridge_sessions_json：
//
//		$(state_dir)/bridge/session-*.json -> [{..., pid, live}]（last_seen_unix 降序）
//
//	  - 文件名里的 pid 非数字 → 跳过；
//	  - pid 已死 → **删掉文件** 后跳过；
//	  - 内容不是对象 / 不可解析 → 跳过；
//	  - live = now - floor(.last_seen_unix // 0) <= BRIDGE_LIVE_WINDOW_S。
func Sessions() []*jqjson.Object {
	dir := Dir()
	now := hfcommon.NowUnix()
	window := LiveWindow()

	matches, _ := filepath.Glob(filepath.Join(dir, "session-*.json"))
	docs := []*jqjson.Object{}
	for _, path := range matches {
		st, err := os.Stat(path)
		if err != nil || st.IsDir() {
			continue // bash: `[[ -f ${f} ]] || continue`
		}
		name := filepath.Base(path)
		pidText := strings.TrimSuffix(strings.TrimPrefix(name, "session-"), ".json")
		if !isDigits(pidText) {
			continue
		}
		if !pidAlive(pidText) {
			_ = os.Remove(path) // 复刻 bash：SIGKILL 留下的会话文件顺手清掉
			continue
		}
		data, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		parsed, err := jqjson.Parse(data)
		if err != nil {
			continue
		}
		doc, ok := parsed.(*jqjson.Object)
		if !ok {
			continue
		}
		seen, _ := doc.Get("last_seen_unix")
		seenDigits := floorDigits(seen)
		live := false
		if n, err := strconv.ParseInt(seenDigits, 10, 64); err == nil {
			live = now-n <= window
		}
		doc.Set("pid", jqjson.NumberLiteral(pidText))
		doc.Set("live", live)
		docs = append(docs, doc)
	}
	if len(docs) == 0 {
		return docs
	}
	sortByKeyStable(docs, "last_seen_unix")
	reverse(docs)
	return docs
}

// LiveStatus 复刻 bridge_live_status_json：
//
//	只统计 live 会话；同一 id 被多个 client 汇报时 up 优先（否则取会话顺序里的第一条）。
//	返回顺序 = jq group_by(.id) 的顺序（按 id 排序后的分组序）。
func LiveStatus(sessions []*jqjson.Object) []liveStatus {
	type entry struct {
		id     string
		state  string
		reason string
		client string
	}
	entries := []entry{}
	for _, doc := range sessions {
		if v, _ := doc.Get("live"); !jqjson.Truthy(v) {
			continue
		}
		client := jqjson.Str(valOf(doc, "client_host"))
		statusVal, _ := doc.Get("status")
		statusObj, ok := statusVal.(*jqjson.Object)
		if !ok {
			// jq 在此处对非对象 .status 会报错（现实中不会出现）；Go 退化为「无汇报」。
			continue
		}
		for _, k := range statusObj.Keys() {
			val, _ := statusObj.Get(k)
			vo, _ := val.(*jqjson.Object)
			st := "down"
			reason := ""
			if vo != nil {
				if v, ok := vo.Get("state"); ok && v != nil {
					st = jqjson.ToString(v)
				}
				if v, ok := vo.Get("reason"); ok && v != nil {
					reason = jqjson.ToString(v)
				}
			}
			entries = append(entries, entry{id: k, state: st, reason: reason, client: client})
		}
	}
	// group_by(.id)：先稳定按 id 排序（jq 的 group_by 先排序再分组）
	sort.SliceStable(entries, func(i, j int) bool { return entries[i].id < entries[j].id })

	out := []liveStatus{}
	for i := 0; i < len(entries); {
		j := i
		for j < len(entries) && entries[j].id == entries[i].id {
			j++
		}
		pick := entries[i]
		for k := i; k < j; k++ {
			if entries[k].state == "up" {
				pick = entries[k]
				break
			}
		}
		out = append(out, liveStatus{ID: pick.id, State: pick.state, Reason: pick.reason, Client: pick.client})
		i = j
	}
	return out
}

// AnyLive 复刻 bridge_any_live：至少一个 client 在线。
func AnyLive(sessions []*jqjson.Object) bool {
	for _, doc := range sessions {
		if v, _ := doc.Get("live"); jqjson.Truthy(v) {
			return true
		}
	}
	return false
}

// MergeLive 复刻 bridge_merge_live：把实时状态注入 client 映射（就地改视图对象）。
//
//	pending = 有 client 在线但尚未汇报该映射；waiting = 没有 client 连着。
//	`status_reason` / `client` 恒为字符串（四个分支都赋值，与 bash 的 jq 一致）。
func MergeLive(raw []*jqjson.Object, sessions []*jqjson.Object) []*jqjson.Object {
	lives := LiveStatus(sessions)
	byID := map[string]liveStatus{}
	for _, l := range lives {
		byID[l.ID] = l
	}
	anyLive := AnyLive(sessions)
	out := make([]*jqjson.Object, 0, len(raw))
	for _, doc := range raw {
		if jqjson.Str(valOf(doc, "mode")) != "client" {
			out = append(out, doc)
			continue
		}
		l, has := byID[jqjson.ToString(valOf(doc, "id"))]
		switch {
		case has:
			doc.Set("status", l.State)
			doc.Set("status_reason", l.Reason)
			doc.Set("client", l.Client)
		case anyLive:
			doc.Set("status", "pending")
			doc.Set("status_reason", "")
			doc.Set("client", "")
		default:
			doc.Set("status", "waiting")
			doc.Set("status_reason", "")
			doc.Set("client", "")
		}
		out = append(out, doc)
	}
	return out
}

// Clients 复刻 bridge_clients_json：client-*.json + running 标记（顺序 = glob 顺序）。
func Clients() []*jqjson.Object {
	dir := Dir()
	matches, _ := filepath.Glob(filepath.Join(dir, "client-*.json"))
	docs := []*jqjson.Object{}
	for _, path := range matches {
		st, err := os.Stat(path)
		if err != nil || st.IsDir() {
			continue
		}
		data, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		parsed, err := jqjson.Parse(data)
		if err != nil {
			continue
		}
		doc, ok := parsed.(*jqjson.Object)
		if !ok {
			continue
		}
		mid := jqjson.Str(valOf(doc, "machine"))
		doc.Set("running", LockHolder(mid) != "")
		docs = append(docs, doc)
	}
	return docs
}

// ClientForwards 复刻 bridge_client_forwards_json（A 侧生效中的映射，供 list / tab bar 合并）。
//
// 只有 running（supervisor 活）且 state=connected 的 client 文件参与；行字段与键序与
// bash 完全一致（id, local_port, remote_host, remote_port, machine, ssh_target, pid,
// status, status_reason, mode），最后按 local_port 稳定升序。
func ClientForwards() []*jqjson.Object {
	rows := []*jqjson.Object{}
	for _, c := range Clients() {
		if v, _ := c.Get("running"); !jqjson.Truthy(v) {
			continue
		}
		if jqjson.Str(valOf(c, "state")) != "connected" {
			continue
		}
		fwVal, _ := c.Get("forwards")
		fwObj, ok := fwVal.(*jqjson.Object)
		if !ok {
			continue
		}
		for _, id := range fwObj.Keys() {
			val, _ := fwObj.Get(id)
			vo, _ := val.(*jqjson.Object)
			if vo == nil {
				continue
			}
			parts := strings.Split(jqjson.Str(valOf(vo, "spec")), " ")
			if len(parts) < 2 {
				continue // `split(" ")` 后取 $p[1] 会得到 null，tonumber 报错（bash 整体失败）
			}
			lp, ok1 := atoiOK(parts[0])
			rp, ok2 := atoiOK(parts[1])
			if !ok1 || !ok2 {
				continue
			}
			row := jqjson.NewObject()
			row.Set("id", id)
			row.Set("local_port", jqjson.NumberLiteral(strconv.Itoa(lp)))
			row.Set("remote_host", "localhost")
			row.Set("remote_port", jqjson.NumberLiteral(strconv.Itoa(rp)))
			label, hasLabel := c.Get("label")
			if !hasLabel || label == nil {
				row.Set("machine", valOf(c, "machine"))
			} else {
				row.Set("machine", label)
			}
			target, hasTarget := c.Get("target")
			if !hasTarget || target == nil {
				row.Set("ssh_target", "")
			} else {
				row.Set("ssh_target", target)
			}
			row.Set("pid", valOf(c, "pid"))
			row.Set("status", valOf(vo, "state"))
			row.Set("status_reason", valOf(vo, "reason"))
			row.Set("mode", "bridge")
			rows = append(rows, row)
		}
	}
	sortByKeyStable(rows, "local_port")
	return rows
}

// RawForwards 读状态文件里的原始 forwards 数组（顺序保留对象 + 保留数字字面量）。
//
// 返回 (数组, 是否全部是对象)。第二个值为 false 时调用方按 bash 的 jq 报错路径处理
// （视图整体为空）：`bridge_merge_live` 的 jq 对非对象元素会 `Cannot index number …`，
// 该赋值失败 → merged 空串。
func RawForwards() ([]*jqjson.Object, bool) {
	path := filepath.Join(hfcommon.StateDir(), "forwards.json")
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return []*jqjson.Object{}, true
		}
		hfcommon.Logf("warn", stateWarnUnparsable, path)
		return []*jqjson.Object{}, true
	}
	parsed, err := jqjson.Parse(data)
	if err != nil {
		hfcommon.Logf("warn", stateWarnUnparsable, path)
		return []*jqjson.Object{}, true
	}
	root, ok := parsed.(*jqjson.Object)
	if !ok {
		hfcommon.Logf("warn", stateWarnUnparsable, path)
		return []*jqjson.Object{}, true
	}
	fv, ok := root.Get("forwards")
	if !ok {
		hfcommon.Logf("warn", stateWarnNoForwards, path)
		return []*jqjson.Object{}, true
	}
	arr, ok := fv.([]any)
	if !ok {
		hfcommon.Logf("warn", stateWarnNoForwards, path)
		return []*jqjson.Object{}, true
	}
	out := make([]*jqjson.Object, 0, len(arr))
	for _, e := range arr {
		obj, ok := e.(*jqjson.Object)
		if !ok {
			return out, false
		}
		out = append(out, obj)
	}
	return out, true
}

// stateWarnUnparsable / stateWarnNoForwards 是 lib/state.sh 的两条 warn 文案（逐字复刻）。
const (
	stateWarnUnparsable = "状态文件不可解析或非对象：%s，按空状态继续（原文件保留，未被覆盖）。"
	stateWarnNoForwards = "状态文件缺少 forwards 数组：%s，按空状态继续（原文件保留，未被覆盖）。"
)

// --- 小工具 ---------------------------------------------------------------

// valOf 取对象键值（缺失返回 nil）。
func valOf(o *jqjson.Object, key string) any {
	if o == nil {
		return nil
	}
	v, _ := o.Get(key)
	return v
}

// floorDigits 复刻 `.last_seen_unix // 0 | floor` 的**字符串**形态（用于 `^[0-9]+$` 判定）。
//
//   - 非数字（含 null/字符串/布尔）→ jq 的 floor 报错 → 判定失败 → "0"；
//   - 纯数字字面量 → 原样（含超长整数，jq 的 decNumber 不会重排整数）；
//   - 无指数的小数 → 向下取整（jq floor）；负数 → 负号使正则不匹配 → "0"；
//   - 带指数/超大值 → jq 打印成科学计数/E 记法 → 正则不匹配 → "0"。
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
	if err != nil || math.IsNaN(f) || math.IsInf(f, 0) {
		return "0"
	}
	fl := math.Floor(f)
	if fl < 0 || fl >= 1e15 {
		return "0"
	}
	return strconv.FormatInt(int64(fl), 10)
}

// atoiOK 解析十进制整数（失败 → ok=false）。
func atoiOK(s string) (int, bool) {
	n, err := strconv.Atoi(s)
	if err != nil {
		return 0, false
	}
	return n, true
}

// sortByKeyStable 复刻 jq 的 `sort_by(.key)`：稳定排序，键缺失按 null 参与比较
// （jq 的类型序：null < false < true < number < string < array < object）。
func sortByKeyStable(rows []*jqjson.Object, key string) {
	sort.SliceStable(rows, func(i, j int) bool {
		return jvCompare(valOf(rows[i], key), valOf(rows[j], key)) < 0
	})
}

// reverse 原地倒序（复刻 jq 的 `reverse`）。
func reverse(rows []*jqjson.Object) {
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

// DesiredJSON 复刻 bridge_desired_json 的 stdout（`[{id,local_port,remote_port}]`）。
//
// 供差分测试与面板使用（B 侧 serve 内部走 DesiredSync 的结构化形态）。
func DesiredJSON() []byte {
	sync := DesiredSync()
	arr := make([]any, 0, len(sync.Forwards))
	for _, e := range sync.Forwards {
		obj := jqjson.NewObject()
		obj.Set("id", e.ID)
		obj.Set("local_port", jqjson.NumberLiteral(strconv.Itoa(e.LocalPort)))
		obj.Set("remote_port", jqjson.NumberLiteral(strconv.Itoa(e.RemotePort)))
		arr = append(arr, obj)
	}
	return []byte(jqjson.Encode(arr, false) + "\n")
}

// MergeView 复刻 `_hf_view_json`：本机记录（合入实时状态）+ 桥接生效中的远端映射。
//
// 第二个返回值为 false 表示 bash 的 jq 报错路径（视图整体为空，见 RawForwards）。
func MergeView() ([]*jqjson.Object, bool) {
	raw, allObjects := RawForwards()
	if !allObjects {
		return nil, false
	}
	sessions := Sessions()
	merged := MergeLive(raw, sessions)
	return append(merged, ClientForwards()...), true
}

// StatusOf 读当前 supervisor 状态（供 `bridge status` 的非 JSON 形态与测试使用）。
func StatusOf(machine string) string {
	path := ClientFile(machine)
	data, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	parsed, err := jqjson.Parse(data)
	if err != nil {
		return ""
	}
	obj, ok := parsed.(*jqjson.Object)
	if !ok {
		return ""
	}
	return jqjson.Str(valOf(obj, "state"))
}

// StartedAt 是 state.Load 的轻量再导出（供 CLI 侧避免重复 import）。
//
// 保留函数是为了让 CLI 的 `bridge status` 与 `list` 使用同一份记录解析（typed）。
func StartedAt(rec state.Forward) time.Time { return time.Unix(rec.CreatedUnix, 0) }
