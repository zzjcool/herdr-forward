// Package state — forwards.json 状态层（← lib/state.sh，Phase 1 由 W1 实现）。
//
// 本文件是 PLAN-GO-MIGRATION §5 冻结的共享类型桩：W2(render)/W3(machine) 依赖这些
// 类型编译，W1 是本文件的唯一 owner（可重构实现，但不得破坏冻结签名）。
package state

// Mode — forward 的来源模式。
// "tunnel" 是缺省（旧记录无 mode 字段时按 tunnel 兼容）；"client" 为桥接客户端记录。
type Mode string

const (
	ModeTunnel Mode = "tunnel"
	ModeClient Mode = "client"
)

// Publish — 二期 cloudflared 发布状态（当前恒为零值/nil 形态，见 C4）。
// json tag 顺序即字段字母序（control_socket < pid < url 之外，本结构体为 pid/url/started_unix）。
type Publish struct {
	Pid         *int    `json:"pid"`
	URL         *string `json:"url"`
	StartedUnix *int64  `json:"started_unix"`
}

// Forward — 一条端口转发记录（A.2 数据契约）。
// 字段声明顺序 = jq 输出的键名字母序（C4：control_socket, created_unix, id,
// local_port, machine, mode, pid, publish, remote_host, remote_port, ssh_target, status）。
// 序列化格式必须与 bash+jq 版逐字节一致（2 空格缩进、键序、null 形态），由 W1 的
// difftest 保障。
type Forward struct {
	ControlSocket string  `json:"control_socket"`
	CreatedUnix   int64   `json:"created_unix"`
	ID            string  `json:"id"`
	LocalPort     int     `json:"local_port"`
	Machine       string  `json:"machine"`
	Mode          Mode    `json:"mode"`
	Pid           *int    `json:"pid"`
	Publish       Publish `json:"publish"`
	RemoteHost    string  `json:"remote_host"`
	RemotePort    int     `json:"remote_port"`
	SshTarget     string  `json:"ssh_target"`
	Status        string  `json:"status"`
}
