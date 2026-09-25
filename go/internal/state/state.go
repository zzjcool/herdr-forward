// state.go — forwards.json 状态层（← lib/state.sh，PLAN-GO-MIGRATION §5 冻结签名）。
//
// 行为权威是 lib/state.sh 原文 + docs/ARCHITECTURE.md §A.2 数据契约（C4）。
// 迁移期红线（PLAN R1）：Save 的字节必须与 bash+jq 版逐字节一致，否则迁移期
// bash panel / E2E 的 jq 断言会静默错位。因此本文件刻意复刻 jq 的输出细节：
//
//   - `jq -S -c`：**紧凑单行**、键名字母序（递归）、结尾一个换行。
//     ⚠ 计划/任务文本里的「2 空格缩进」与 bash 实测不符（jq -c 是紧凑输出），
//     本实现以 bash 实测字节为准（见报告「未决问题」）。
//   - 顶层键序字母序：forwards 在 version 之前。
//   - publish 的键序是 pid, started_unix, url（字母序，非结构体声明序），
//     由 Publish.MarshalJSON 保证。
//   - json.Encoder 默认会把 < > & 转义成 \u003c 等（jq 不转义），故必须
//     SetEscapeHTML(false)。
package state

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"

	"github.com/zzjcool/herdr-forward/internal/hfcommon"
)

// 冻结错误（PLAN §5 只点名 ErrDuplicatePort/ErrNotFound，其余是本层的最小必要补充，
// 用于把 bash 的 die 1/die 3 语义映射到 Go error，退出码由 cli 层按 C2 表映射）。
var (
	// ErrDuplicatePort — Add 时 local_port 或派生 id 已存在（bash: die 2）。
	ErrDuplicatePort = errors.New("state: local port already in use")
	// ErrNotFound — Remove/SetStatus 的目标 id 不存在（bash: die 3）。
	ErrNotFound = errors.New("state: record not found")
	// ErrInvalidPort — local_port 不是 1..65535（bash: die 1）。
	ErrInvalidPort = errors.New("state: invalid local port")
	// ErrInvalidStatus — status 不在 starting|up|down（bash: die 1）。
	ErrInvalidStatus = errors.New("state: invalid status")
	// ErrInvalidID — id/参数为空（bash: die 1 或 die 3）。
	ErrInvalidID = errors.New("state: empty id")
)

// ValidStatuses — bash FORWARD_VALID_STATUS="starting up down"（顺序即报错文案顺序）。
var ValidStatuses = []string{"starting", "up", "down"}

// stateDoc 是磁盘文档形态 {version, forwards}。
//
// ⚠ 字段声明序 = jq -S 后的键序（字母序）：forwards < version。改动会破坏 C4。
type stateDoc struct {
	Forwards []Forward `json:"forwards"`
	Version  int       `json:"version"`
}

// FilePath 复刻 state_file：$HERDR_PLUGIN_STATE_DIR/forwards.json。
func FilePath() string {
	return hfcommon.StateDir() + "/forwards.json"
}

// Load 复刻 state_load：返回 forwards 数组。
//
// 损坏（不可解析）/ 顶层非对象 / 缺 forwards 键 / forwards 非数组 → warn + 空切片，
// 且 error 恒为 nil（bash 恒 return 0 且 stdout 为 []）。原文件保持不动（不覆盖）。
//
// 归一化（PLAN §8 要求）：缺 mode（空串）→ ModeTunnel，兼容旧记录。其余缺失字段由
// Go 的零值自然填充（""/0/nil）—— 这是冻结类型化模型的必然结果，与 bash 的「原样
// 透传」存在已知偏差，由 tests/difftest 的归一化比对 + 报告「未决问题」登记。
func Load() ([]Forward, error) {
	path := FilePath()
	raw, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			// bash: 文件不存在 -> stdout []
			return []Forward{}, nil
		}
		hfcommon.Logf("warn", "状态文件不可解析或非对象：%s，按空状态继续（原文件保留，未被覆盖）。", path)
		return []Forward{}, nil
	}

	// 第一遍：判定顶层形态，复刻 bash 的两级 jq type 检查与两种 warn 文案。
	var probe any
	if err := json.Unmarshal(raw, &probe); err != nil {
		hfcommon.Logf("warn", "状态文件不可解析或非对象：%s，按空状态继续（原文件保留，未被覆盖）。", path)
		return []Forward{}, nil
	}
	obj, ok := probe.(map[string]any)
	if !ok {
		hfcommon.Logf("warn", "状态文件不可解析或非对象：%s，按空状态继续（原文件保留，未被覆盖）。", path)
		return []Forward{}, nil
	}
	fv, ok := obj["forwards"]
	if !ok {
		hfcommon.Logf("warn", "状态文件缺少 forwards 数组：%s，按空状态继续（原文件保留，未被覆盖）。", path)
		return []Forward{}, nil
	}
	if _, ok := fv.([]any); !ok {
		hfcommon.Logf("warn", "状态文件缺少 forwards 数组：%s，按空状态继续（原文件保留，未被覆盖）。", path)
		return []Forward{}, nil
	}

	// 第二遍：类型化解码。正常数据不会失败；失败（字段类型不符等）按损坏处理。
	var doc stateDoc
	if err := json.Unmarshal(raw, &doc); err != nil {
		hfcommon.Logf("warn", "读取 forwards 数组失败：%s，按空状态继续。", path)
		return []Forward{}, nil
	}
	if doc.Forwards == nil {
		doc.Forwards = []Forward{}
	}
	for i := range doc.Forwards {
		normalize(&doc.Forwards[i])
	}
	return doc.Forwards, nil
}

// normalize 补齐旧记录的语义缺省（仅 mode：空 -> tunnel）。
// 不做 add 级别的字段填充 —— Load 的职责是「兼容读取」，不是「新建记录」。
func normalize(f *Forward) {
	if f.Mode == "" {
		f.Mode = ModeTunnel
	}
}

// Save 复刻 state_save：把 forwards 数组包成 {version:1,forwards:[...]} 并以
// jq -S -c 的字节形态原子落盘。
//
// 字节契约（difftest 逐字节校验）：紧凑、键序字母序、结尾单个 \n、文件 0600。
func Save(fw []Forward) error {
	if fw == nil {
		// bash 的 state_save 只接受数组；nil 切片 marshal 成 null 会破坏 C4。
		fw = []Forward{}
	}
	doc := stateDoc{Forwards: fw, Version: hfcommon.StateVersion}

	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false) // jq 不转义 < > &，必须关闭 Go 默认的 HTML 转义
	if err := enc.Encode(doc); err != nil {
		return fmt.Errorf("state: 组装状态文档失败: %w", err)
	}
	// json.Encoder.Encode 末尾自带 '\n'，与 bash `printf '%s\n'` 一致。
	return hfcommon.AtomicWrite(FilePath(), buf.Bytes())
}

// Add 复刻 forward_add_record：归一化后追加（local_port/id 冲突 -> ErrDuplicatePort）。
func Add(f Forward) error {
	if f.LocalPort < 1 || f.LocalPort > 65535 {
		return fmt.Errorf("%w: %d（需要 1-65535）", ErrInvalidPort, f.LocalPort)
	}

	id := fmt.Sprintf("f-%d", f.LocalPort)
	existing, err := Load()
	if err != nil {
		return err
	}
	for _, e := range existing {
		if e.ID == id || e.LocalPort == f.LocalPort {
			return fmt.Errorf("%w: 本地端口 %d 已被占用（记录 %s 已存在）", ErrDuplicatePort, f.LocalPort, id)
		}
	}

	rec := f
	rec.ID = id
	if rec.RemoteHost == "" {
		rec.RemoteHost = "127.0.0.1"
	}
	if rec.RemotePort == 0 {
		rec.RemotePort = f.LocalPort
	}
	if rec.Status == "" {
		rec.Status = "starting"
	}
	if rec.CreatedUnix == 0 {
		rec.CreatedUnix = hfcommon.NowUnix()
	}
	if rec.Mode == ModeClient {
		rec.Mode = ModeClient
	} else {
		rec.Mode = ModeTunnel
	}
	// publish 恒为占位 null（一期，A.2）。
	rec.Publish = Publish{}

	return Save(append(existing, rec))
}

// Remove 复刻 forward_remove_record：删除该 id 的所有记录（不存在 -> ErrNotFound）。
func Remove(id string) error {
	if id == "" {
		return fmt.Errorf("%w: 需要 id 参数", ErrInvalidID)
	}
	existing, err := Load()
	if err != nil {
		return err
	}
	found := false
	remaining := make([]Forward, 0, len(existing))
	for _, e := range existing {
		if e.ID == id {
			found = true
			continue
		}
		remaining = append(remaining, e)
	}
	if !found {
		return fmt.Errorf("%w: %s", ErrNotFound, id)
	}
	return Save(remaining)
}

// SetStatus 复刻 forward_set_status：校验 status、更新该 id 的所有记录。
func SetStatus(id, status string) error {
	if id == "" {
		return fmt.Errorf("%w: 需要 id 参数", ErrInvalidID)
	}
	if !IsValidStatus(status) {
		return fmt.Errorf("%w: %s（允许值：%s）", ErrInvalidStatus, status, statusList())
	}
	existing, err := Load()
	if err != nil {
		return err
	}
	found := false
	updated := make([]Forward, len(existing))
	copy(updated, existing)
	for i := range updated {
		if updated[i].ID == id {
			found = true
			updated[i].Status = status
		}
	}
	if !found {
		return fmt.Errorf("%w: %s", ErrNotFound, id)
	}
	return Save(updated)
}

// IsValidStatus 判定 status 是否属于 FORWARD_VALID_STATUS。
func IsValidStatus(status string) bool {
	for _, s := range ValidStatuses {
		if s == status {
			return true
		}
	}
	return false
}

func statusList() string {
	out := ""
	for i, s := range ValidStatuses {
		if i > 0 {
			out += ", "
		}
		out += s
	}
	return out
}
