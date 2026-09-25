// Package notify —— herdr socket toast（← lib/notify.sh）。
//
// 契约（ARCHITECTURE A.3 + lib/notify.sh 顶部注释）：**best-effort** ——
//   - 绝不阻塞调用方超过 ~1s（socket 卡死时也要在 1s 内放弃）；
//   - 绝不失败（恒返回 nil，任何异常都降级成一条 log）。
//
// 与 bash 的差异（有意，已在报告登记）：
//   - bash 用 python3/socat/nc 三个外部传输并各起一个 session + watchdog 进程；
//     Go 用 net.DialTimeout("unix") + 写超时表达同一个「1s 上限」，且不会派生进程；
//   - payload 的 JSON 转义用本包内的 jq 兼容实现（与 cli 层的 encodeJQString 同规则：
//     `"` `\` `\b` `\t` `\n` `\f` `\r`，其余 <0x20 与 0x7f -> \u00xx 小写；`<` `>` `&`
//     与 U+2028/U+2029 不转义）。bash 在无 jq 时的「手写回退」只转义 `\ " \n`，
//     Go 侧恒用完整 jq 规则 —— 输出与「bash 有 jq」时逐字节一致，是更严格的一侧。
package notify

import (
	"fmt"
	"net"
	"os"
	"strings"
	"syscall"
	"time"

	"github.com/zzjcool/herdr-forward/internal/hfcommon"
)

// watchdog 是 socket 投递的硬上限（lib/notify.sh：settimeout(1) + 1s watchdog）。
const watchdog = time.Second

// Payload 复刻 notify_payload：一行 JSON（键序 type,title,body —— 与 jq -cn 的插入序一致）。
func Payload(title, body string) string {
	return `{"type":"toast","title":` + encodeJSONString(title) + `,"body":` + encodeJSONString(body) + "}"
}

// Toast 复刻 notify_toast：能投就投，投不出去就降级成 log；恒返回 nil。
//
//	bash: HERDR_SOCKET_PATH 非空 + `-S`（是 socket）+ `-w`（可写）才尝试投递；
//	成功 -> log debug "notify: toast sent via <sock>"；
//	失败 -> log debug "notify: socket <sock> unusable, degrading to log"；
//	最后（或 socket 不可用时直接）log info "notify: <title>[ — <body>]"。
func Toast(title, body string) error {
	sock := os.Getenv("HERDR_SOCKET_PATH")
	if sock != "" && socketUsable(sock) {
		payload := Payload(title, body)
		if payload != "" && Send(sock, payload) == nil {
			hfcommon.Logf("debug", "notify: toast sent via %s", sock)
			return nil
		}
		hfcommon.Logf("debug", "notify: socket %s unusable, degrading to log", sock)
	}
	msg := "notify: " + title
	if body != "" {
		msg += " — " + body
	}
	hfcommon.Logf("info", "%s", msg)
	return nil
}

// Send 复刻 notify_send：把 payload + '\n' 写进 unix socket，1s 内未完成即失败。
//
// 返回 nil 表示「已投递」（bash 的 exit 0），否则表示失败 —— 调用方一律降级。
func Send(sock, payload string) error {
	conn, err := net.DialTimeout("unix", sock, watchdog)
	if err != nil {
		return err
	}
	defer func() { _ = conn.Close() }()
	_ = conn.SetWriteDeadline(time.Now().Add(watchdog))
	if _, err := conn.Write([]byte(payload + "\n")); err != nil {
		return err
	}
	return nil
}

// socketUsable 复刻 `[[ -S ${sock} && -w ${sock} ]]`：
// 存在、是 socket、且当前用户可写（W_OK 通过 access(2)，与 bash 的 -w 同源）。
func socketUsable(path string) bool {
	st, err := os.Stat(path)
	if err != nil || st.Mode()&os.ModeSocket == 0 {
		return false
	}
	return syscall.Access(path, 2 /* W_OK */) == nil
}

// encodeJSONString 复刻 jq 的字符串转义（与 cli/jsonjq.go 的 encodeJQString 同规则，
// 本包不 import cli 以免形成「展示层反向依赖」）。
func encodeJSONString(s string) string {
	var b strings.Builder
	b.Grow(len(s) + 2)
	b.WriteByte('"')
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch c {
		case '"':
			b.WriteString(`\"`)
		case '\\':
			b.WriteString(`\\`)
		case '\b':
			b.WriteString(`\b`)
		case '\t':
			b.WriteString(`\t`)
		case '\n':
			b.WriteString(`\n`)
		case '\f':
			b.WriteString(`\f`)
		case '\r':
			b.WriteString(`\r`)
		default:
			if c < 0x20 || c == 0x7f {
				fmt.Fprintf(&b, `\u%04x`, c)
				continue
			}
			b.WriteByte(c)
		}
	}
	b.WriteByte('"')
	return b.String()
}
