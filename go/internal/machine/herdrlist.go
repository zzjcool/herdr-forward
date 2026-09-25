// herdrlist.go —— herdr `machine list` 的**结构化**入口（← lib/machines.sh 的
// machines_herdr_list_json 的消费侧）。
//
// HerdrMachineListJSON（herdr.go，W3 交付）已经把 herdr 的输出规范化成单行紧凑 JSON；
// 本文件在它之上做一层「解码成有序条目」——视图/查找/解析都要遍历条目，逐个再调 jq
// 才是错的。因为 §1 的降级契约要求「缺/败/非 JSON 一律 [] + warn，绝不 die」，
// 这里的解码失败也只能产出空列表（warn 已由 HerdrMachineListJSON 打过）。
package machine

import (
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"strings"
	"syscall"
)

// ErrMachineNotFound 是「该 id/label 在 herdr 列表与激活记录里都不存在」的哨兵
// （对照 bash 的 die 3 语义）。
var ErrMachineNotFound = errors.New("machines: machine not found")

// HerdrMachineList 返回 `$HERDR_BIN_PATH machine list --json` 的规范化条目。
//
// 降级契约与 HerdrMachineListJSON 完全一致（binPath 缺失/失败/非 JSON → 空切片）。
// 条目的字段值用 json.Number 保留数字字面量（与 jq 透传语义一致）。
func HerdrMachineList() []map[string]any {
	raw := HerdrMachineListJSON(os.Getenv("HERDR_BIN_PATH"))
	out := []map[string]any{}
	if len(raw) == 0 {
		return out
	}
	dec := json.NewDecoder(strings.NewReader(string(raw)))
	dec.UseNumber()
	var arr []map[string]any
	if err := dec.Decode(&arr); err != nil {
		// HerdrMachineListJSON 只在输出是「对象数组」时才返回非空；真走到这里说明
		// 内存/解析异常 —— 按空列表继续（与 bash 的 jq 失败降级同形）。
		warnf("saved machines 输出不是预期的 JSON 数组（%s machine list --json），按空列表继续。请升级 herdr 或报告该输出格式。", os.Getenv("HERDR_BIN_PATH"))
		return out
	}
	if arr == nil {
		return out
	}
	return arr
}

// has 报告激活记录里是否存在该 id。
func (a Activation) has(id string) bool {
	if id == "" {
		return false
	}
	_, ok := a.Machines[id]
	return ok
}

// record 取一条激活记录（缺失返回 ok=false）。
func (a Activation) record(id string) (activationRecord, bool) {
	rec, ok := a.Machines[id]
	return rec, ok
}

// runBoundedOutput 跑一条外部命令并返回 stdout（有 timeout(1) 就限时执行，
// macOS 默认没有 timeout —— 与 lib/_bridge_bounded 同一兜底策略）。
func runBoundedOutput(secs int, name string, args ...string) (string, bool) {
	if _, err := exec.LookPath(name); err != nil {
		return "", false
	}
	cmd := exec.Command(name, args...)
	cmd.Stderr = nil
	if _, err := exec.LookPath("timeout"); err == nil {
		cmd = exec.Command("timeout", append([]string{itoa(secs), name}, args...)...)
	}
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	out, err := cmd.Output()
	if err != nil {
		return "", false
	}
	return string(out), true
}

// osHostname 返回 $HOSTNAME（bash 的 `${HOSTNAME:-}`；未设置时为空串）。
func osHostname() string { return os.Getenv("HOSTNAME") }

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	neg := n < 0
	if neg {
		n = -n
	}
	var buf [20]byte
	i := len(buf)
	for n > 0 {
		i--
		buf[i] = byte('0' + n%10)
		n /= 10
	}
	if neg {
		i--
		buf[i] = '-'
	}
	return string(buf[i:])
}
