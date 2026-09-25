// serve.go —— B 侧 `forward bridge serve`：常驻循环（← lib/bridge.sh 的 bridge_serve）。
//
// stdout **只写协议行**（日志一律走 hfcommon.Log → forward.log / stderr）；由 A 经 SSH 启动，
// stdin/stdout 即协议通道。生命周期：
//
//  1. 建会话文件（session-<serve pid>.json），写 HELLO；
//  2. 每轮：把期望集合（mode=client 记录）编码成 SYNC，集合变化才发；
//  3. 读一行（带超时），分发 HELLO / STATUS / PING；未知行 warn 后忽略；
//  4. 刷新打开请求队列（只发「端口已在最近一次 SYNC 里」的请求，30s 过期）；
//  5. client 断开（EOF）→ 删会话文件并退出。
//
// 读超时用 hf_read_timed_out 的语义：bash 3.2 把「超时」与「EOF」都返回 1，只能按耗时猜；
// Go 的 bufio + SetReadDeadline 天然区分，但**半行拼接**必须保留 —— 超时读到的半行要留到
// 下一轮拼上（bash 版在 ≥4 上是这么做的，测试对着这个行为写）。
package bridge

import (
	"bufio"
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/zzjcool/herdr-forward/internal/hfcommon"
)

// serveState 是 serve 循环的可变状态。
type serveState struct {
	sessionPath string
	host        string
	started     int64
	lastSeen    int64
	clientHost  string
	clientLabel string
	status      map[int]forwardState
	lastWrite   int64
	dirty       bool
	lastSync    string
	pid         string
}

// Serve 复刻 bridge_serve（ctx 取消 = 收到 TERM/HUP/INT/PIPE，等价 bash 的 trap 'exit 0'）。
//
// 循环结构对齐 bash 的「每 BRIDGE_POLL_S 一拍」：
//
//	① 期望集合变化 -> 发 SYNC（并清掉已不在集合里的旧状态）
//	② 刷新打开请求队列
//	③ 处理这一拍里到达的协议行（0..N 条）
//	④ dirty 或到心跳间隔 -> 刷新会话文件
//
// 读用**一条常驻 goroutine**（不是每次读开一条）：每次读开 goroutine 的写法在
// 「心跳间隔 1s、serve 常驻数天」下会按秒泄漏协程。常驻 reader 与 bash 的
// `read -t` 在语义上的唯一差异是「超时那一刻的半行」：bash 把半行留在变量里下一轮拼，
// Go 的 ReadString 会一直等到换行才交付 —— 结果都是**这一行被完整交给协议分发**，
// 只是交付时刻晚；而 EOF 时未闭合的半行两边都丢弃（bash：`read` 返回非 0 且
// hf_read_timed_out 判为 EOF → break，line 里的残余不再使用）。
func Serve(ctx context.Context) error {
	st := &serveState{
		pid:    strconv.Itoa(os.Getpid()),
		host:   Hostname(),
		status: map[int]forwardState{},
	}
	st.sessionPath = SessionFile(st.pid)
	defer func() { _ = os.Remove(st.sessionPath) }()

	st.started = hfcommon.NowUnix()
	st.lastSeen = st.started
	st.writeSession()

	// bash: `printf '%s HELLO %s\n' "${BRIDGE_PROTO}" "${srv_host}"`
	fmt.Println(Hello{Host: st.host}.String())
	hfcommon.Logf("info", "bridge serve: 会话开始（pid=%s）。", st.pid)

	lines := streamLines()
	ticker := time.NewTicker(time.Duration(PollSeconds()) * time.Second)
	defer ticker.Stop()
	lastWrite := st.started

	stopped := false
	for !stopped {
		select {
		case <-ctx.Done():
			stopped = true
		case line, ok := <-lines:
			if !ok {
				stopped = true // EOF：client 断开
				break
			}
			st.handleLine(line)
		case <-ticker.C:
		}

		// ① 期望集合（B 侧自己也可能写 forwards.json：CLI/面板）
		sync := DesiredSync()
		if line := sync.String(); line != st.lastSync {
			fmt.Println(line)
			st.lastSync = line
			dropStaleStatus(st, sync)
		}
		// ② 打开请求队列
		flushOpens(st)
		// ④ 会话文件刷新（dirty 或到心跳间隔）
		st.maybeWrite(lastWrite)
		lastWrite = st.lastWrite
	}

	hfcommon.Logf("info", "bridge serve: client 断开，会话结束（pid=%s）。", st.pid)
	return nil
}

// streamLines 起一条常驻 reader，把 stdin 的完整行送进通道；EOF 时关通道。
// 未闭合的末行（EOF 前没有换行）按 bash 丢弃。
func streamLines() <-chan string {
	ch := make(chan string, 16)
	go func() {
		defer close(ch)
		r := bufio.NewReaderSize(os.Stdin, 64*1024)
		for {
			raw, err := r.ReadString('\n')
			switch {
			case strings.HasSuffix(raw, "\n"):
				ch <- strings.TrimSuffix(strings.TrimSuffix(raw, "\n"), "\r")
			case err != nil:
				return // EOF / 读错误：未闭合的半行丢弃（与 bash 一致）
			}
			if err != nil {
				return
			}
		}
	}()
	return ch
}

// handleLine 复刻 serve 循环对一行协议的分发（含 bash 的容错：未知行只 warn）。
func (st *serveState) handleLine(line string) {
	msg, err := ParseLine(line)
	if err != nil {
		hfcommon.Logf("warn", "bridge serve: 忽略未知协议行：%s", clip(line, 120))
		return
	}
	now := hfcommon.NowUnix()
	switch m := msg.(type) {
	case Hello:
		st.clientHost = m.Host
		st.clientLabel = strings.Join(m.Labels, " ")
		st.lastSeen = now
		st.dirty = true
		hfcommon.Logf("info", "bridge serve: client %s（%s）已连接。", st.clientHost, st.clientLabel)
	case Status:
		// bash: `^f-([1-9][0-9]{0,4})$` + state ∈ {up,down} + 端口 ≤ 65535
		if port, ok := statusPort(m.ID); ok && (m.State == "up" || m.State == "down") {
			st.status[port] = forwardState{State: m.State, Reason: clip(m.Reason, 200)}
			st.dirty = true
		}
		st.lastSeen = now
	case Ping:
		st.lastSeen = now
	case Sync, Open:
		hfcommon.Logf("warn", "bridge serve: 忽略未知协议行：%s", clip(line, 120))
	}
}

// statusPort 复刻 serve 对 STATUS id 的判定：`^f-([1-9][0-9]{0,4})$` 且端口 ≤ 65535。
func statusPort(id string) (int, bool) {
	if !strings.HasPrefix(id, "f-") {
		return 0, false
	}
	lit := id[2:]
	if !validPortLiteral(lit, false) {
		return 0, false
	}
	n, err := strconv.Atoi(lit)
	if err != nil || n > 65535 {
		return 0, false
	}
	return n, true
}

// dropStaleStatus 复刻「已不在期望集合里的映射，其旧状态没有意义」的清理
// （否则会话文件里会残留一条过期的 up）。
func dropStaleStatus(st *serveState, sync Sync) {
	inSync := map[int]bool{}
	for _, e := range sync.Forwards {
		inSync[e.LocalPort] = true
	}
	for port := range st.status {
		if !inSync[port] {
			delete(st.status, port)
			st.dirty = true
		}
	}
}

// maybeWrite 复刻「dirty 或距上次写盘 ≥ BRIDGE_PING_S 就刷新会话文件」。
func (st *serveState) maybeWrite(lastWrite int64) {
	now := hfcommon.NowUnix()
	if st.dirty || now-lastWrite >= int64(PingSeconds()) {
		st.writeSession()
		st.lastWrite = now
		st.dirty = false
	}
}

func (st *serveState) writeSession() {
	writeSessionFile(st.sessionPath, sessionDoc{
		ClientHost:   st.clientHost,
		ClientLabel:  st.clientLabel,
		ServerHost:   st.host,
		StartedUnix:  st.started,
		LastSeenUnix: st.lastSeen,
		Status:       st.status,
	})
}

// flushOpens 复刻 _bridge_serve_flush_opens：把排队的打开请求转给 client。
//
// 三重约束（每一条都是安全边界，不是优化）：
//  1. client 还没连上（没收到 HELLO）→ 什么都不发；
//  2. 请求的端口必须已出现在**最近一次发出的 SYNC** 里 —— 否则 client 会先收到 OPEN、
//     后收到含该端口的 SYNC，而 client 只肯打开已生效映射的端口；
//  3. 30 秒没轮上的请求作废（用户已经忘了这件事）。
//
// 出队用 `rm` 的成功与否做独占（多 serve 共存时不重发）。
func flushOpens(st *serveState) {
	if st.clientHost == "" {
		return
	}
	dir := OpenDir()
	entries, err := os.ReadDir(dir)
	if err != nil {
		return
	}
	now := hfcommon.NowUnix()
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".url") {
			continue
		}
		path := filepath.Join(dir, e.Name())
		data, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		url := strings.TrimRight(string(data), "\n")
		stampText := e.Name()
		if i := strings.Index(stampText, "-"); i >= 0 {
			stampText = stampText[:i]
		}
		stamp, err := strconv.ParseInt(stampText, 10, 64)
		if err != nil || now-stamp > 30 {
			_ = os.Remove(path)
			continue
		}
		port, ok := localhostOpenPort(url)
		if !ok {
			_ = os.Remove(path)
			continue
		}
		// 复刻 bash：port 是**字符串**（正则允许前导零；带零的串天然匹配不上 SYNC 的 id）。
		if !strings.Contains(st.lastSync, "f-"+port+":") {
			continue
		}
		if err := os.Remove(path); err != nil {
			continue
		}
		fmt.Println(Open{URL: url}.String())
	}
}

// localhostOpenPort 复刻 `^https?://localhost:([0-9]{1,5})([/?#][^[:space:]]*)?$` 的取端口。
func localhostOpenPort(url string) (string, bool) {
	rest := ""
	switch {
	case strings.HasPrefix(url, "http://localhost:"):
		rest = url[len("http://localhost:"):]
	case strings.HasPrefix(url, "https://localhost:"):
		rest = url[len("https://localhost:"):]
	default:
		return "", false
	}
	i := 0
	for i < len(rest) && i <= 5 && rest[i] >= '0' && rest[i] <= '9' {
		i++
	}
	if i == 0 || i > 5 {
		return "", false
	}
	port := rest[:i]
	after := rest[i:]
	if after != "" && !strings.ContainsRune("/?#", rune(after[0])) {
		return "", false
	}
	if strings.ContainsAny(after, " \t\n\r\v\f") {
		return "", false
	}
	return port, true
}

// clip 复刻 bash 的 `${x:0:N}`（按**字符**截断，避免把多字节字符切碎）。
func clip(s string, n int) string {
	runes := []rune(s)
	if len(runes) <= n {
		return s
	}
	return string(runes[:n])
}
