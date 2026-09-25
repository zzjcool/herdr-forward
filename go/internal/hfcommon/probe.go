// probe.go — probe_payload 的 Go 对位（lib/common.sh probe_payload / PLAN §5 ✕ C7）。
//
// 语义权威 = A.3.1 的 probe_payload 契约 + lib/common.sh 实现：
//
//	连上后发一行 marker 并等待**任意**应用层回包，用「是否有回包」把
//	「本地可连」与「远端可达」区分开（ssh -L 的本地监听器在 master 活着时
//	永远接受本地连接，因此 TCP-only 探活会把远端已死误报为 up）。
//
//	bash rc -> Health 映射（lib/common.sh）：
//	  0       读回 >=1 字节            -> up
//	  >=128   读超时（无回包）          -> degraded
//	  其他     connect/write 失败、EOF  -> down
//
// Go 对位（PLAN §4「/dev/tcp/nc→net.Dial」）用 net.DialTimeout +
// SetReadDeadline 表达同一个三段分类，并删除 bash 3.2 的 `read -t` 半行
// rc=142 hack（那是 bash 3.2 把「超时」与「EOF」都返回 1 的补偿；Go 的
// i/o timeout 与 io.EOF 天然可区分，不需要按耗时猜）。
package hfcommon

import (
	"errors"
	"io"
	"net"
	"strconv"
	"time"
)

// ProbePayloadMarker — 应用层探测 payload（FORWARD_PROBE_PAYLOAD_MARKER）。
const ProbePayloadMarker = "herdr-forward-probe"

// String 把三级探活映射回 bash 的 stdout 契约（up|degraded|down），
// 便于 CLI/日志直接打印且与 bash 逐字符一致。未知值退化为 "down"
// （与 bash 的 else 分支同义：非 0 且 <128 一律 down）。
func (h Health) String() string {
	switch h {
	case HealthUp:
		return "up"
	case HealthDegraded:
		return "degraded"
	default:
		return "down"
	}
}

// ProbePayload 复刻 probe_payload <host> <port> [timeout_s=2]。
//
// 恒返回一个 Health（不 panic、不阻塞超过 timeoutSec+ε），与 bash「恒 return 0
// 且 stdout 恒单行」等价：调用方拿到 stdout 契约里的那一个词。
//
// timeoutSec 语义：连接与读回包各自使用该上限（bash 亦然 —— read -t 用 timeout_s，
// 外层 timeout 用 timeout_s+2 兜底）。timeoutSec <= 0 是退化输入（bash 在 -t 0/-1
// 下的行为本身不可用也不可移植），这里统一取 1ms 保证「有界、绝不挂住」。
func ProbePayload(host string, port, timeoutSec int) Health {
	if host == "" || port <= 0 {
		// 参数为空 -> down（bash 的空参分支）。
		return HealthDown
	}

	d := time.Duration(timeoutSec) * time.Second
	if d <= 0 {
		d = time.Millisecond
	}

	conn, err := net.DialTimeout("tcp", net.JoinHostPort(host, strconv.Itoa(port)), d)
	if err != nil {
		// 连接被拒/重置/解析失败/连接超时 -> down（bash rc=2 / 外层 timeout）。
		return HealthDown
	}
	defer func() { _ = conn.Close() }()

	_ = conn.SetWriteDeadline(time.Now().Add(d))
	if _, err := io.WriteString(conn, ProbePayloadMarker+"\n"); err != nil {
		// 写失败 -> down（bash exit 3）。
		return HealthDown
	}

	_ = conn.SetReadDeadline(time.Now().Add(d))
	buf := make([]byte, 1)
	switch _, err := conn.Read(buf); {
	case err == nil:
		return HealthUp // 读到 >=1 字节回包
	default:
		var ne net.Error
		if errors.As(err, &ne) && ne.Timeout() {
			return HealthDegraded // 连上但 timeout 内无回包
		}
		return HealthDown // EOF / RST 等
	}
}
