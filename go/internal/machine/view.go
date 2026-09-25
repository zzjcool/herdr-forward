// view.go —— herdr saved machines 的合并视图（← lib/machines.sh 的 machines_view_json /
// machines_lookup_json / machines_resolve_id / machines_is_local_target）。
//
// 视图是「面板 + CLI」的单一权威数据源（§A.3.2）：state ∈ active|activated|local|inactive
// （优先级 active > activated > local > inactive），外加 herdr 里已不存在、但激活记录里
// 还留着的 orphan 条目（saved machine 被删的场景，用户需要入口看到/停用它们）。
//
// 字段与键序是**冻结契约**（`machines list --json` 的输出形状，C5）：
//
//	{id, label, target, enabled, state, local, orphan}
//
// 输出编码用 internal/jqjson（jq 兼容的转义 + 插入序），与 bash 的 `jq -c '.'` 逐字节一致。
package machine

import (
	"strings"

	"github.com/zzjcool/herdr-forward/internal/hfcommon"
	"github.com/zzjcool/herdr-forward/internal/jqjson"
)

// MachineView 是合并视图里的一行（`machines list --json` 的元素）。
type MachineView struct {
	ID      string
	Label   string
	Target  string
	Enabled bool
	State   string // active | activated | local | inactive
	Local   bool
	Orphan  bool
}

// View 复刻 machines_view_json：herdr 列表 × 激活记录 → 合并视图数组。
//
// 条目顺序 = herdr `machine list` 的原始顺序，之后按 id 字典序追加以 orphan 形态出现的
// 激活记录（bash 用 `jq -r '.machines | keys[]'`，jq 的 keys 是排好序的）。
func View() []MachineView {
	activation := LoadActivation()
	list := HerdrMachineList()

	entries := make([]MachineView, 0, len(list)+len(activation.Machines))
	seen := make(map[string]bool, len(list))

	for _, item := range list {
		id := valueToString(item["id"])
		label := viewLabel(item, id)
		target := recordString(item["target"])
		enabled := recordBoolEnabled(item["enabled"])

		hasRec := activation.has(id)
		isLocal := IsLocalTarget(target)
		if hasRec {
			if rec, _ := activation.record(id); rec.Bool("local") {
				isLocal = true
			}
		}

		state := "inactive"
		switch {
		case activation.Active == id:
			state = "active"
		case hasRec:
			state = "activated"
		case isLocal:
			state = "local"
		}

		seen[id] = true
		entries = append(entries, MachineView{
			ID: id, Label: label, Target: target, Enabled: enabled,
			State: state, Local: isLocal, Orphan: false,
		})
	}

	// orphan：激活记录里有、herdr 列表里没有的 id（saved machine 已被删除）。
	for _, id := range recordIDs(activation) {
		if seen[id] {
			continue
		}
		rec, _ := activation.record(id)
		label := rec.String("label")
		if label == "" {
			label = id
		}
		target := rec.String("ssh_target")
		isLocal := IsLocalTarget(target)
		if rec.Bool("local") {
			isLocal = true
		}
		state := "activated"
		if activation.Active == id {
			state = "active"
		}
		entries = append(entries, MachineView{
			ID: id, Label: label, Target: target, Enabled: true,
			State: state, Local: isLocal, Orphan: true,
		})
	}
	return entries
}

// ViewJSON 把视图编码成 `machines list --json` 的 stdout（紧凑单行 + 结尾换行）。
//
// 逐字段与 bash 的 `jq -c -n --arg ... '{id:$id, label:$label, target:$target,
// enabled:($enabled == "true"), state:$state, local:($local == "yes"), orphan:...}'`
// 对齐；`jq -c -s '.'` 的重编码在本实现里是恒等变换，故直接一次编码。
func ViewJSON() []byte {
	entries := View()
	arr := make([]any, 0, len(entries))
	for _, e := range entries {
		obj := jqjson.NewObject()
		obj.Set("id", e.ID)
		obj.Set("label", e.Label)
		obj.Set("target", e.Target)
		obj.Set("enabled", e.Enabled)
		obj.Set("state", e.State)
		obj.Set("local", e.Local)
		obj.Set("orphan", e.Orphan)
		arr = append(arr, obj)
	}
	return []byte(jqjson.Encode(arr, false) + "\n")
}

// Lookup 复刻 machines_lookup_json：先查 herdr 列表，查不到退回激活记录（orphan）；
// 都查不到 → ErrMachineNotFound（调用方按 die 3 处理）。
func Lookup(id string) (MachineView, error) {
	if id == "" {
		return MachineView{}, ErrMachineNotFound
	}
	for _, item := range HerdrMachineList() {
		if valueToString(item["id"]) != id {
			continue
		}
		return MachineView{
			ID:      id,
			Label:   viewLabel(item, id),
			Target:  recordString(item["target"]),
			Enabled: recordBoolEnabled(item["enabled"]),
		}, nil
	}
	activation := LoadActivation()
	if rec, ok := activation.record(id); ok {
		label := rec.String("label")
		if label == "" {
			label = id
		}
		return MachineView{
			ID:      id,
			Label:   label,
			Target:  rec.String("ssh_target"),
			Enabled: true,
		}, nil
	}
	return MachineView{}, ErrMachineNotFound
}

// ResolveID 复刻 machines_resolve_id：接受 id 或 label，返回 id。
//
// 匹配顺序（与 bash 的 jq 逐条对齐）：
//  1. herdr 列表：id 精确 → label 精确 → label 大小写不敏感
//  2. 激活记录：key 精确 → label 精确 → label 大小写不敏感
//
// 都匹配不到 → ErrMachineNotFound（调用方 die 3，并把可用列表写进提示）。
func ResolveID(arg string) (string, error) {
	if arg == "" {
		return "", ErrMachineNotFound
	}
	list := HerdrMachineList()
	for _, item := range list {
		if valueToString(item["id"]) == arg {
			return arg, nil
		}
	}
	for _, item := range list {
		if recordString(item["label"]) == arg {
			return valueToString(item["id"]), nil
		}
	}
	for _, item := range list {
		if strings.EqualFold(recordString(item["label"]), arg) {
			return valueToString(item["id"]), nil
		}
	}

	activation := LoadActivation()
	if _, ok := activation.record(arg); ok {
		return arg, nil
	}
	ids := recordIDs(activation)
	for _, id := range ids {
		rec, _ := activation.record(id)
		if rec.String("label") == arg {
			return id, nil
		}
	}
	for _, id := range ids {
		rec, _ := activation.record(id)
		if strings.EqualFold(rec.String("label"), arg) {
			return id, nil
		}
	}
	return "", ErrMachineNotFound
}

// AvailableIDs 复刻 machines_resolve_id 失败提示里的「可用的 saved machines」列表
// （`id(label), id2` 形态；label 缺失时只给 id）。
func AvailableIDs() string {
	list := HerdrMachineList()
	parts := make([]string, 0, len(list))
	for _, item := range list {
		id := valueToString(item["id"])
		if label := recordString(item["label"]); label != "" {
			parts = append(parts, id+"("+label+")")
			continue
		}
		parts = append(parts, id)
	}
	return strings.Join(parts, ", ")
}

// IsLocalTarget 复刻 machines_is_local_target：只认强信号，拿不准一律走 ssh 探测。
//
// 强信号：localhost / localhost.localdomain / 127.0.0.1 / ::1 / 0:0:0:0:0:0:0:1
// （含 `ssh://` scheme、`user@` 前缀、`:port` 后缀与 `[v6]` 方括号），以及
// `hostname` / `hostname -s` / `hostname -f` 的精确等值（大小写不敏感）。
//
// 刻意**不**做 DNS 解析、不读 /etc/hosts —— 误判为远程只是多跑一次 ssh 探测，
// 误判为本机才会写错路径（tab bar 指向本机 = 跨机场景彻底失效）。
func IsLocalTarget(raw string) bool {
	host := stripScheme(raw)
	if host == "" {
		return false
	}
	if i := strings.LastIndex(host, "@"); i >= 0 {
		host = host[i+1:]
	}
	switch {
	case strings.HasPrefix(host, "["):
		if end := strings.Index(host, "]"); end >= 0 {
			host = host[1:end]
		}
	case strings.Count(host, ":") == 1:
		// 恰好一个冒号且后半是数字端口 -> 剥掉；`::1` 因以 ':' 开头也走 default 分支。
		if parts := strings.SplitN(host, ":", 2); isDigits(parts[1]) {
			host = parts[0]
		}
	}

	switch strings.ToLower(host) {
	case "localhost", "localhost.localdomain", "127.0.0.1", "::1", "0:0:0:0:0:0:0:1":
		return true
	}
	lowered := strings.ToLower(host)
	for _, name := range hostNames() {
		if name == "" {
			continue
		}
		if strings.ToLower(name) == lowered {
			return true
		}
	}
	return false
}

// hostNames 复刻 _machines_host_names：hostname / -s / -f，全空时退回 uname -n 与 $HOSTNAME。
func hostNames() []string {
	names := make([]string, 0, 4)
	nonEmpty := false
	for _, args := range [][]string{{"hostname"}, {"hostname", "-s"}, {"hostname", "-f"}} {
		out, ok := runBoundedOutput(2, args[0], args[1:]...)
		if !ok {
			names = append(names, "")
			continue
		}
		names = append(names, strings.TrimRight(out, "\n"))
		if strings.TrimRight(out, "\n") != "" {
			nonEmpty = true
		}
	}
	if nonEmpty {
		return names
	}
	// 容器等精简环境可能没有 hostname 可执行文件：退回内核信号（uname -n）与 $HOSTNAME。
	fallback := make([]string, 0, 2)
	if out, ok := runBoundedOutput(2, "uname", "-n"); ok {
		fallback = append(fallback, strings.TrimRight(out, "\n"))
	} else {
		fallback = append(fallback, "")
	}
	fallback = append(fallback, osHostname())
	return fallback
}

// stripScheme 复刻 _ssh_probe_strip_scheme：剥掉大小写不敏感的 `ssh://` 前缀。
// 为什么需要：herdr `machine add` 接受 `ssh://user@host:31415` 并把整串存进 target；
// 不剥的话 `ssh://localhost` 会被当成主机名 "ssh://localhost" 而误判为远程。
func stripScheme(target string) string {
	if len(target) >= 6 && strings.EqualFold(target[:6], "ssh://") {
		return target[6:]
	}
	return target
}

// viewLabel 复刻 view 里的 label 兜底：非字符串/空串 → id 的字符串形态。
func viewLabel(item map[string]any, id string) string {
	if s, ok := item["label"].(string); ok && s != "" {
		return s
	}
	return id
}

// valueToString 复刻 jq 的 `tostring`（数字保留字面量、字符串原样、null → "null"）。
func valueToString(v any) string {
	return jqjson.ToString(v)
}

// warnf 是包内 warn 的短别名（统一走 hfcommon 的日志实现）。
func warnf(format string, args ...any) { hfcommon.Logf("warn", format, args...) }

// isDigits 判定纯 ASCII 数字串（复刻 bash 的 `[[ ${x} =~ ^[0-9]+$ ]]`）。
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
