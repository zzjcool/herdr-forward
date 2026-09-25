// activation.go —— 激活状态（activated-machines.json，§A.3.2 schema）← lib/machines.sh。
//
// 本文件是 lib/machines.sh 的「状态持久化」半边；合并视图在 view.go（同包）。
//
// 行为权威是 lib/machines.sh 原文（ARCHITECTURE §A.3.2 冻结的 schema 与降级契约）。
// 迁移期铁律是「零行为变化」，因此这里逐条对齐 bash，包括：
//
//   - 落盘形态：`jq -S -c`（紧凑单行 + 键名字母序递归 + 结尾单换行）。Go 的
//     encoding/json 对 map 恰好按键名排序，配合 SetEscapeHTML(false) 与 json.Number
//     （保留数字字面量）即可逐字节复刻；
//   - 降级契约：文件缺失 → 空文档**不 warn**；不可解析/非对象/machines 非对象 →
//     空文档 + warn（原文件保留，绝不覆盖）；
//   - `herdr machine list` 缺失/失败/非 JSON → "[]" + warn，**绝不 die**。
package machine

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"

	"github.com/zzjcool/herdr-forward/internal/hfcommon"
)

// activationVersion 是 activated-machines.json 的 version 字段（MACHINES_ACTIVATION_VERSION）。
const activationVersion = 1

// ErrNoActivation 是「该 machine 没有激活记录」的哨兵（对照 bash 的 die 3 语义：
// `forward machines deactivate <id>` 在记录不存在时报 3，`activate` 走 resolve 报 3）。
var ErrNoActivation = errors.New("machines: no activation record")

// StateFile 复刻 machines_state_file：$HERDR_PLUGIN_STATE_DIR/activated-machines.json。
func StateFile() string {
	return filepath.Join(hfcommon.StateDir(), "activated-machines.json")
}

// Activation 是 activated-machines.json 的内存视图（§1 schema：{version, active, machines}）。
type Activation struct {
	// Active 是当前激活的 machine id；无激活时为空串（落盘为 null）。
	Active string
	// Machines 是 id → 记录的原始 JSON 对象（字段透传，未知键保留，见 activationRecord）。
	Machines map[string]activationRecord
}

// activationRecord 是一条激活记录：保留原始键值（未识别的键写回时不丢），
// 同时提供几个高频访问器的便利方法。
//
// 为什么不做成 struct：bash 用 jq 原样透传记录（`.machines[$id] = $rec`），
// doctor 的「记录里多一个未知键」场景写回时不能丢键。
type activationRecord struct {
	vals map[string]any
}

func (r activationRecord) get(key string) (any, bool) { return r.vals[key], r.vals[key] != nil }

// String 取字符串键（非字符串 → ""，复刻 jq 的 `// ""` 语义）。
func (r activationRecord) String(key string) string {
	s, _ := r.vals[key].(string)
	return s
}

// Bool 取布尔键（非布尔 → false）。
func (r activationRecord) Bool(key string) bool {
	b, _ := r.vals[key].(bool)
	return b
}

// emptyActivation 复刻 _machines_empty_doc：{version:1, active:null, machines:{}}。
func emptyActivation() Activation {
	return Activation{Machines: map[string]activationRecord{}}
}

// LoadActivation 复刻 machines_activation_load。
//
// 文件缺失 → 空文档（正常首次运行，不 warn）；不可解析 / 顶层非对象 / machines 非对象
// → 空文档 + warn（原文件保留，绝不覆盖）。
func LoadActivation() Activation {
	path := StateFile()
	raw, err := os.ReadFile(path)
	if err != nil {
		return emptyActivation()
	}

	probe, err := decodeAny(raw)
	if err != nil {
		hfcommon.Logf("warn", "激活状态文件不可解析或非对象：%s，按空状态继续（原文件保留，未被覆盖）。", path)
		return emptyActivation()
	}
	obj, ok := probe.(map[string]any)
	if !ok {
		hfcommon.Logf("warn", "激活状态文件不可解析或非对象：%s，按空状态继续（原文件保留，未被覆盖）。", path)
		return emptyActivation()
	}
	machinesRaw, ok := obj["machines"]
	if !ok {
		hfcommon.Logf("warn", "激活状态文件缺少 machines 对象：%s，按空状态继续（原文件保留，未被覆盖）。", path)
		return emptyActivation()
	}
	machinesObj, ok := machinesRaw.(map[string]any)
	if !ok {
		hfcommon.Logf("warn", "激活状态文件缺少 machines 对象：%s，按空状态继续（原文件保留，未被覆盖）。", path)
		return emptyActivation()
	}

	out := Activation{Machines: map[string]activationRecord{}}
	if active, ok := obj["active"].(string); ok && active != "" {
		out.Active = active // 非字符串 / 空串 → null（复刻 bash 的规范化）
	}
	for id, rec := range machinesObj {
		obj, ok := rec.(map[string]any)
		if !ok {
			// bash 原样保留（`machines: .machines`），下游用 `// {}` 兜底。
			// Go 侧记录为「无键对象」，写回时形态与 bash 的 `{}` 一致。
			obj = map[string]any{}
		}
		out.Machines[id] = activationRecord{vals: obj}
	}
	return out
}

// SaveActivation 复刻 machines_activation_save：规范化 + 原子写（jq -S -c 字节形态）。
func SaveActivation(a Activation) error {
	doc := map[string]any{
		"version":  activationVersion,
		"active":   nil,
		"machines": map[string]any{},
	}
	if a.Active != "" {
		doc["active"] = a.Active
	}
	machines := map[string]any{}
	for id, rec := range a.Machines {
		if rec.vals == nil {
			machines[id] = map[string]any{}
			continue
		}
		machines[id] = rec.vals
	}
	doc["machines"] = machines

	// encoding/json 对 map 键**按键名排序**（= jq -S）；SetEscapeHTML(false) 对齐 jq
	// 的字符串转义（jq 不转义 < > &）。
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(doc); err != nil {
		return fmt.Errorf("machines_activation_save 组装状态文档失败: %w", err)
	}
	return hfcommon.AtomicWrite(StateFile(), buf.Bytes())
}

// SetActivation 复刻 machines_activation_set：upsert 记录（覆盖同 id）并把 active 置为该 id。
//
// activated_unix 缺失时补 now（幂等重写会刷新为新的激活时间 —— 符合「重新探测 + 覆盖记录」）。
func SetActivation(id string, rec map[string]any) error {
	if rec == nil {
		rec = map[string]any{}
	}
	if _, ok := rec["activated_unix"].(json.Number); !ok {
		if _, ok := rec["activated_unix"].(float64); !ok {
			rec["activated_unix"] = json.Number(fmt.Sprintf("%d", hfcommon.NowUnix()))
		}
	}
	a := LoadActivation()
	a.Machines[id] = activationRecord{vals: rec}
	a.Active = id
	return SaveActivation(a)
}

// ClearActive 复刻 machines_activation_clear_active：active → null（记录保留）。
func ClearActive() error {
	a := LoadActivation()
	a.Active = ""
	return SaveActivation(a)
}

// ResetActivation 复刻 machines_activation_reset：清 active + 删除全部记录。
func ResetActivation() error {
	return SaveActivation(emptyActivation())
}

// RemoveActivation 复刻 machines_activation_remove：删除单条记录（若它正是 active，同时清 active）。
func RemoveActivation(id string) error {
	a := LoadActivation()
	delete(a.Machines, id)
	if a.Active == id {
		a.Active = ""
	}
	return SaveActivation(a)
}

// HasActivation 复刻 machines_activation_has：yes/no。
func HasActivation(id string) bool {
	if id == "" {
		return false
	}
	_, ok := LoadActivation().Machines[id]
	return ok
}

// GetActivation 复刻 machines_activation_get：记录 JSON（不存在 → ErrNoActivation）。
func GetActivation(id string) (activationRecord, error) {
	if id == "" {
		return activationRecord{}, fmt.Errorf("%w: 缺少 <id> 参数", ErrNoActivation)
	}
	rec, ok := LoadActivation().Machines[id]
	if !ok {
		return activationRecord{}, fmt.Errorf("%w: machine '%s'", ErrNoActivation, id)
	}
	return rec, nil
}

// ActiveID 复刻 machines_activation_active：当前 active 的 id（无则空串）。
func ActiveID() string {
	return LoadActivation().Active
}

// recordIDs 返回记录 id 的字典序列表（jq `keys` 顺序）。
func recordIDs(a Activation) []string {
	ids := make([]string, 0, len(a.Machines))
	for id := range a.Machines {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	return ids
}

// decodeAny 用 UseNumber 解析一个 JSON 值（数字字面量逐字节保留，避免 float64
// 重排破坏 jq -S -c 的落盘形态）。
func decodeAny(raw []byte) (any, error) {
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	var out any
	if err := dec.Decode(&out); err != nil {
		return nil, err
	}
	if _, err := dec.Token(); err == nil {
		return nil, fmt.Errorf("json: 尾随内容不是合法 JSON")
	}
	return out, nil
}

// EncodeRecord 把一条记录编码成 jq -S -c 的紧凑形态（键名字母序）。
func EncodeRecord(rec activationRecord) []byte {
	vals := rec.vals
	if vals == nil {
		vals = map[string]any{}
	}
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	_ = enc.Encode(vals)
	return bytes.TrimRight(buf.Bytes(), "\n")
}

// DecodeRecord 解析一条 record JSON（供 CLI 的 `--record` 之类入口使用）。
func DecodeRecord(raw []byte) (map[string]any, error) {
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	var out map[string]any
	if err := dec.Decode(&out); err != nil {
		return nil, err
	}
	if out == nil {
		return nil, fmt.Errorf("record 不是 JSON 对象")
	}
	return out, nil
}

// recordString 复刻 jq 的 `(.x // "")`：非字符串一律当空串。
func recordString(v any) string {
	s, _ := v.(string)
	return s
}

// recordBoolEnabled 复刻 view 里 `if (.enabled | type) == "boolean" then .enabled else true end`。
func recordBoolEnabled(v any) bool {
	b, ok := v.(bool)
	if !ok {
		return true
	}
	return b
}
