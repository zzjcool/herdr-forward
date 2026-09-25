// json.go — state 层的 JSON 序列化细节（复刻 jq 的键序与 null 形态）。
//
// 为什么需要单独一个文件：encoding/json 对结构体按**声明序**输出，而 jq -S 按
// **键名字母序**输出。Forward 的字段声明序已按字母序排好（types.go），但
// Publish 的三个键如果按声明序输出是 pid,url,started_unix，与 jq 的
// pid,started_unix,url 不一致（url 在 started_unix 之后）—— 这会让 Save 的字节
// 与 bash 不同，直接踩 PLAN R1（C4 消费者静默错位）。故给 Publish 手写
// MarshalJSON，把键序钉死为字母序，而不是改动冻结的结构体声明序。
package state

import (
	"bytes"
	"encoding/json"
)

// publishJSON 是 Publish 的字母序序列化镜像（pid < started_unix < url）。
type publishJSON struct {
	Pid         *int    `json:"pid"`
	StartedUnix *int64  `json:"started_unix"`
	URL         *string `json:"url"`
}

// MarshalJSON 输出 jq -S 等价的键序：pid, started_unix, url。
// nil 指针输出 null（与 jq 的 null 形态一致）。
//
// 注意：外层 Encoder 的 SetEscapeHTML(false) **不会**传递到自定义 MarshalJSON 内部
// 的 json.Marshal（后者总是转义 < > &，会与 jq 输出差一个 \u0026），因此这里必须
// 自带一个关闭 HTML 转义的编码器。
func (p Publish) MarshalJSON() ([]byte, error) {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(publishJSON{Pid: p.Pid, StartedUnix: p.StartedUnix, URL: p.URL}); err != nil {
		return nil, err
	}
	// Encoder.Encode 会补一个 '\n'；内嵌到父对象的 JSON 里必须去掉。
	return bytes.TrimRight(buf.Bytes(), "\n"), nil
}

// UnmarshalJSON 让 Publish 可从 jq 产出的字母序对象读回（键序无关，仅为对称性
// 与「自定义 MarshalJSON 后仍需可解析」的清晰性而显式实现）。
func (p *Publish) UnmarshalJSON(data []byte) error {
	var tmp publishJSON
	if err := json.Unmarshal(data, &tmp); err != nil {
		return err
	}
	p.Pid = tmp.Pid
	p.StartedUnix = tmp.StartedUnix
	p.URL = tmp.URL
	return nil
}
