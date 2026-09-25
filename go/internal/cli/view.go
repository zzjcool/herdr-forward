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
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"syscall"

	"github.com/zzjcool/herdr-forward/internal/hfcommon"
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

// loadView 复刻 _hf_view_json：
//
//	forwards = forward_list_json          （= state_load）
//	bridge.sh 缺失          -> 原样返回
//	merged = bridge_merge_live(forwards)
//	remote = bridge_client_forwards_json()
//	remote == "[]"          -> merged
//	否则                     -> merged ++ remote
func loadView() view {
	raw := readRawForwards()
	if !allObjects(raw) {
		// bash：bridge_merge_live 的 jq 对非对象元素报 `Cannot index number with
		// string ("mode")`，该赋值失败 -> merged 空串 -> 视图整体为空。
		// 下游表现（实测）：`list --json`/`--oneline` 空 stdout 且 rc 0；表格只剩表头。
		return view{raw: raw, mergeOK: false}
	}
	sessions := bridgeSessions()
	merged := mergeLive(raw, sessions)
	remote := bridgeClientForwards()
	return view{raw: raw, rows: append(merged, remote...), mergeOK: true}
}

// allObjects 报告数组里是否每个元素都是 JSON 对象（空数组为真）。
func allObjects(arr []any) bool {
	for _, e := range arr {
		if _, ok := e.(*jobj); !ok {
			return false
		}
	}
	return true
}

// readRawForwards 复刻 state_load 的 stdout（不含 `[]` 打印形态，直接给数组），
// 并把 bash 的 warn 文案按同一格式写日志/stderr。
//
// 降级规则（与 bash 一一对应）：文件不存在/读不到、不可解析、顶层非对象 -> warn 1；
// 缺 forwards 键、forwards 非数组 -> warn 2；一律返回空数组且不报错（绝不 crash）。
func readRawForwards() []any {
	path := stateFilePath()
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			// bash：`[[ ! -f ${file} ]]` -> 直接 `printf '[]\n'`，无 warn
			return []any{}
		}
		hfcommon.Logf("warn", stateWarnUnparsable, path)
		return []any{}
	}
	parsed, err := parseJV(data)
	if err != nil {
		hfcommon.Logf("warn", stateWarnUnparsable, path)
		return []any{}
	}
	obj, ok := parsed.(*jobj)
	if !ok {
		hfcommon.Logf("warn", stateWarnUnparsable, path)
		return []any{}
	}
	fv, ok := obj.get("forwards")
	if !ok {
		hfcommon.Logf("warn", stateWarnNoForwards, path)
		return []any{}
	}
	arr, ok := fv.([]any)
	if !ok {
		hfcommon.Logf("warn", stateWarnNoForwards, path)
		return []any{}
	}
	return arr
}

// --- 桥接会话（B 侧只读） ---------------------------------------------------

// bridgeDir 复刻 bridge_dir：首次使用时建 700 目录。
func bridgeDir() string {
	dir := filepath.Join(hfcommon.StateDir(), "bridge")
	if st, err := os.Stat(dir); err != nil || !st.IsDir() {
		_ = os.MkdirAll(dir, 0o700)
		_ = os.Chmod(dir, 0o700)
	}
	return dir
}

// safeID 复刻 _bridge_safe_id：非 [A-Za-z0-9_.-] 一律换成下划线。
func safeID(raw string) string {
	return strings.Map(func(r rune) rune {
		switch {
		case r >= 'A' && r <= 'Z', r >= 'a' && r <= 'z', r >= '0' && r <= '9':
			return r
		case r == '_' || r == '.' || r == '-':
			return r
		default:
			return '_'
		}
	}, raw)
}

// pidAlive 复刻 bash 的 `kill -0 <pid>` 判定。
//
// ⚠ 关键细节（实测）：bash 的 `kill -0` 对「存在但无权发信号的进程」返回 1（EPERM），
// 于是 bridge_sessions_json 会把这类会话文件当**已死**并删除。Go 必须一致：任何错误
// 都视作已死（只有 err == nil 才活着）。
func pidAlive(pidText string) bool {
	pid, err := strconv.Atoi(pidText)
	if err != nil {
		return false
	}
	return syscall.Kill(pid, 0) == nil
}

// killZeroErrnoHint 仅用于文档化：syscall.Kill 在 EPERM/ESRCH 下都返回非 nil，
// 与 bash `kill -0` 的「非 0 即死」语义一致（保留函数以免误改判定）。
func killZeroErrnoHint() string { return "EPERM 与 ESRCH 一律视为已死（bash kill -0 语义）" }

var _ = killZeroErrnoHint

// bridgeLiveWindow 读 BRIDGE_LIVE_WINDOW_S：
//
//	bash: 未设置/空 -> 20；设了非数字 -> 算术展开报错，`((...))` 为假 -> 永不 live。
//	Go 用 -1 表达「永不 live」，与 bash 的失败分支同效果。
func bridgeLiveWindow() int64 {
	raw := os.Getenv("BRIDGE_LIVE_WINDOW_S")
	if raw == "" {
		return bridgeLiveWindowDefault
	}
	n, err := strconv.ParseInt(raw, 10, 64)
	if err != nil {
		return -1
	}
	return n
}

// bridgeSessions 复刻 bridge_sessions_json：
//
//	$(state_dir)/bridge/session-*.json -> [{..., pid, live}]
//	  * 文件名里的 pid 非数字 -> 跳过；
//	  * pid 已死 -> **删掉文件** 后跳过；
//	  * 内容不是对象 / 不可解析 -> 跳过；
//	  * live = now - floor(.last_seen_unix // 0) <= BRIDGE_LIVE_WINDOW_S；
//	结果按 .last_seen_unix 稳定升序后整体 reverse()（等值项随之倒序，与 jq 一致）。
func bridgeSessions() []any {
	dir := bridgeDir()
	now := hfcommon.NowUnix()
	window := bridgeLiveWindow()

	matches, _ := filepath.Glob(filepath.Join(dir, "session-*.json"))
	docs := []any{}
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
		parsed, err := parseJV(data)
		if err != nil {
			continue
		}
		doc, ok := parsed.(*jobj)
		if !ok {
			continue
		}
		seen, _ := doc.get("last_seen_unix")
		seenDigits := floorDigits(seen)
		live := false
		if n, err := strconv.ParseInt(seenDigits, 10, 64); err == nil {
			live = now-n <= window
		}
		doc.set("pid", jsonNumber(pidText))
		doc.set("live", live)
		docs = append(docs, doc)
	}
	if len(docs) == 0 {
		return docs
	}
	sortByKeyStable(docs, "last_seen_unix")
	reverseAny(docs)
	return docs
}

// bridgeLiveStatus 复刻 bridge_live_status_json：
//
//	只统计 live 会话；同一 id 被多个 client 汇报时 up 优先（否则取会话顺序里的第一条）。
//	返回「按 id 分组顺序」排列的结果（jq from_entries 保留 group_by 的顺序）。
func bridgeLiveStatus(sessions []any) []liveStatus {
	type entry struct {
		id     string
		state  string
		reason string
		client string
		order  int
	}
	entries := []entry{}
	for _, s := range sessions {
		doc, ok := s.(*jobj)
		if !ok {
			continue
		}
		if v, _ := doc.get("live"); !jqTruthy(v) {
			continue
		}
		client := jqStr(mustGet(doc, "client_host"))
		statusVal, _ := doc.get("status")
		statusObj, ok := statusVal.(*jobj)
		if !ok {
			// jq 在此处对非对象 .status 会报错（现实中不会出现）；Go 退化为「无汇报」。
			continue
		}
		for _, k := range statusObj.keys {
			val, _ := statusObj.get(k)
			vo, _ := val.(*jobj)
			state := "down"
			reason := ""
			if vo != nil {
				if v, ok := vo.get("state"); ok && v != nil {
					state = jqToString(v)
				}
				if v, ok := vo.get("reason"); ok && v != nil {
					reason = jqToString(v)
				}
			}
			entries = append(entries, entry{id: k, state: state, reason: reason, client: client})
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

// liveStatus 是一个 id 的实时状态（← bridge_live_status_json 的 value）。
type liveStatus struct {
	ID     string
	State  string
	Reason string
	Client string
}

// mergeLive 复刻 bridge_merge_live：client 映射注入实时状态；其余记录原样。
//
//	pending = 有 client 在线但尚未汇报该映射；waiting = 没有 client 连着。
//	status_reason / client 恒为字符串（"up/down/waiting/pending" 分支都赋值）。
func mergeLive(raw []any, sessions []any) []any {
	lives := bridgeLiveStatus(sessions)
	byID := map[string]liveStatus{}
	for _, l := range lives {
		byID[l.ID] = l
	}
	anyLive := false
	for _, s := range sessions {
		if doc, ok := s.(*jobj); ok {
			if v, _ := doc.get("live"); jqTruthy(v) {
				anyLive = true
				break
			}
		}
	}
	out := make([]any, 0, len(raw))
	for _, e := range raw {
		doc, ok := e.(*jobj)
		if !ok {
			// 调用方已用 allObjects 拦掉；保底不变形。
			out = append(out, e)
			continue
		}
		mode := jqStr(mustGet(doc, "mode"))
		if mode != "client" {
			out = append(out, doc)
			continue
		}
		l, has := byID[jqToString(mustGet(doc, "id"))]
		switch {
		case has:
			doc.set("status", l.State)
			doc.set("status_reason", l.Reason)
			doc.set("client", l.Client)
		case anyLive:
			doc.set("status", "pending")
			doc.set("status_reason", "")
			doc.set("client", "")
		default:
			doc.set("status", "waiting")
			doc.set("status_reason", "")
			doc.set("client", "")
		}
		out = append(out, doc)
	}
	return out
}

// bridgeClientForwards 复刻 bridge_client_forwards_json（A 侧生效中的映射）。
//
// 只有 running（supervisor 活）且 state=connected 的 client 文件参与；
// 行字段与键序与 bash 完全一致（id, local_port, remote_host, remote_port, machine,
// ssh_target, pid, status, status_reason, mode），最后按 local_port 稳定升序。
func bridgeClientForwards() []any {
	clients := bridgeClients()
	rows := []any{}
	for _, c := range clients {
		doc, ok := c.(*jobj)
		if !ok {
			continue
		}
		if v, _ := doc.get("running"); !jqTruthy(v) {
			continue
		}
		if jqStr(mustGet(doc, "state")) != "connected" {
			continue
		}
		fwVal, _ := doc.get("forwards")
		fwObj, ok := fwVal.(*jobj)
		if !ok {
			continue
		}
		for _, id := range fwObj.keys {
			val, _ := fwObj.get(id)
			vo, _ := val.(*jobj)
			if vo == nil {
				continue
			}
			spec := jqStr(mustGet(vo, "spec"))
			parts := strings.Split(spec, " ")
			if len(parts) < 2 {
				continue // `split(" ")` 后取 $p[1] 会得到 null，tonumber 报错（bash 整体失败）
			}
			lp, ok1 := atoiOK(parts[0])
			rp, ok2 := atoiOK(parts[1])
			if !ok1 || !ok2 {
				continue
			}
			row := newJObj()
			row.set("id", id)
			row.set("local_port", jsonNumber(strconv.Itoa(lp)))
			row.set("remote_host", "localhost")
			row.set("remote_port", jsonNumber(strconv.Itoa(rp)))
			label, hasLabel := doc.get("label")
			if !hasLabel || label == nil {
				row.set("machine", mustGet(doc, "machine"))
			} else {
				row.set("machine", label)
			}
			target, hasTarget := doc.get("target")
			if !hasTarget || target == nil {
				row.set("ssh_target", "")
			} else {
				row.set("ssh_target", target)
			}
			row.set("pid", mustGet(doc, "pid"))
			row.set("status", mustGet(vo, "state"))
			row.set("status_reason", mustGet(vo, "reason"))
			row.set("mode", "bridge")
			rows = append(rows, row)
		}
	}
	sortByKeyStable(rows, "local_port")
	return rows
}

// bridgeClients 复刻 bridge_clients_json：client-*.json + running 标记（顺序 = glob 顺序）。
func bridgeClients() []any {
	dir := bridgeDir()
	matches, _ := filepath.Glob(filepath.Join(dir, "client-*.json"))
	docs := []any{}
	for _, path := range matches {
		st, err := os.Stat(path)
		if err != nil || st.IsDir() {
			continue
		}
		data, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		parsed, err := parseJV(data)
		if err != nil {
			continue
		}
		doc, ok := parsed.(*jobj)
		if !ok {
			continue
		}
		mid := jqStr(mustGet(doc, "machine"))
		doc.set("running", bridgeLockHolder(mid) != "")
		docs = append(docs, doc)
	}
	return docs
}

// bridgeLockHolder 复刻 _bridge_lock_holder：client-<safe(mid)>.lock/pid 里活着的 pid。
func bridgeLockHolder(machine string) string {
	lock := filepath.Join(bridgeDir(), "client-"+safeID(machine)+".lock")
	data, err := os.ReadFile(filepath.Join(lock, "pid"))
	if err != nil {
		return ""
	}
	pid := strings.TrimSpace(string(data))
	// bash：`pid="$(<file)"` 保留尾部换行，但 `=~ ^[0-9]+$` 对含换行的串不匹配 -> 视为无锁。
	if !isDigits(pid) {
		return ""
	}
	if !pidAlive(pid) {
		return ""
	}
	return pid
}

// --- 小工具 ---------------------------------------------------------------

func mustGet(o *jobj, key string) any {
	if o == nil {
		return nil
	}
	v, _ := o.get(key)
	return v
}

func jsonNumber(lit string) any { return jsonNumberLiteral(lit) }

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
	n, ok := v.(jsonNumberType)
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
		return jvCompare(mustGet(asObj(rows[i]), key), mustGet(asObj(rows[j]), key)) < 0
	})
}

func asObj(v any) *jobj {
	o, _ := v.(*jobj)
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
	case jsonNumberType:
		return 3
	case string:
		return 4
	case []any:
		return 5
	case *jobj:
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
		af, _ := strconv.ParseFloat(formatJQNumber(string(a.(jsonNumberType))), 64)
		bf, _ := strconv.ParseFloat(formatJQNumber(string(b.(jsonNumberType))), 64)
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
		return strings.Compare(encodeJV(a, false), encodeJV(b, false))
	}
}

// jvCompareString 是给「已经确定是字符串」的键用的快捷比较（group_by(.id)）。
func jvCompareString(a, b string) int { return strings.Compare(a, b) }
