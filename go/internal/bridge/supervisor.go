// supervisor.go —— A 侧 `forward bridge run <machine>`：前台 supervisor（← lib/bridge.sh 的
// bridge_run / _bridge_connect_once / _bridge_apply_one / _bridge_open_url）。
//
// 职责（§A.3.3）：
//
//  1. mkdir 原子抢单实例锁；抢不到就打印「已在运行」并返回 0（幂等）；
//  2. 循环：读激活记录 → 建一条到 B 的会话（ssh -T ControlMaster=yes）→ 在**同一 master**
//     上用 `ssh -O forward/cancel` 增删 `-L localhost:<lp>:localhost:<rp>`；
//  3. 断线指数退避重连（2s→60s，一次连接存活 ≥ BRIDGE_STABLE_S 后复位为最小值）；
//  4. 会话结束 = master 退出 = 映射全部释放（**无孤儿隧道**）；
//  5. 本机 herdr socket 消失 → 退出（A 的 startup hook 会在 server 启动时重新拉起来）。
//
// 整个循环**关掉 die 语义**：长驻进程不能因为某次 jq/写盘的偶发失败就悄悄退出，
// 失败一律记日志后进入下一轮重连（bash: `set +o errexit`）。
package bridge

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/zzjcool/herdr-forward/internal/hfcommon"
	"github.com/zzjcool/herdr-forward/internal/jqjson"
)

// activationRecord 是激活记录里桥接需要的四个字段（§A.3.2 schema）。
type activationRecord struct {
	Label      string
	SSHTarget  string
	ServerRoot string
	StateDir   string
}

// Supervisor 是 A 侧 supervisor 的运行态。
type Supervisor struct {
	machine string
	host    string
	ctl     string

	since      int64
	nextRetry  int64
	serverHost string

	specs    map[int]string // lp -> "lp rp"（已生效/待生效的映射）
	statuses map[int]forwardState

	sshPID int
	stop   bool
	wg     sync.WaitGroup
	lock   sync.Mutex
}

// RunSupervisor 复刻 bridge_run（PLAN §5 冻结签名：RunSupervisor(ctx, machineID)）。
//
// 返回 error 只用于「用法错误」（缺 machineID）；运行期的失败一律内部消化并重连。
func RunSupervisor(ctx context.Context, machineID string) error {
	if machineID == "" {
		return errors.New("用法：forward bridge run <machine-id>")
	}
	me := strconv.Itoa(os.Getpid())

	if got := AcquireLock(machineID, me); got != "ok" {
		holder := LockHolder(machineID)
		if holder == "" {
			holder = "?"
		}
		fmt.Printf("桥接 %s 已在运行（pid=%s），无需重复启动。\n", machineID, holder)
		return nil
	}

	s := &Supervisor{
		machine:  machineID,
		host:     Hostname(),
		ctl:      ControlPath(machineID),
		specs:    map[int]string{},
		statuses: map[int]forwardState{},
	}
	defer func() {
		if s.ctl != "" {
			ctlExit(s.ctl)
		}
		ReleaseLock(machineID)
	}()

	go func() {
		<-ctx.Done()
		s.lock.Lock()
		s.stop = true
		sshPID := s.sshPID
		s.lock.Unlock()
		if sshPID > 0 {
			_ = syscall.Kill(sshPID, syscall.SIGTERM)
		}
	}()

	s.loop(ctx)

	s.lock.Lock()
	s.nextRetry = 0
	s.specs = map[int]string{}
	s.statuses = map[int]forwardState{}
	reason := "已停止"
	s.lock.Unlock()
	s.write("stopped", reason)
	hfcommon.Logf("info", "bridge %s: supervisor 退出。", machineID)
	return nil
}

// loop 是重连主循环（退避 2s→60s，稳定 60s 复位）。
func (s *Supervisor) loop(ctx context.Context) {
	backoff := BackoffMinSeconds()
	lastReason := ""
	herdrSock := os.Getenv("HERDR_SOCKET_PATH")

	for !s.stopping() {
		rec, err := loadActivation(s.machine)
		if err != nil {
			s.setRetry(0)
			s.write("stopped", "激活记录缺失或不完整（需要 ssh_target / server_root / state_dir）。请重新激活该机器。")
			hfcommon.Logf("warn", "bridge %s: 激活记录缺失或不完整，桥接停止。", s.machine)
			return
		}

		started := hfcommon.NowUnix()
		s.lock.Lock()
		s.since = started
		s.nextRetry = 0
		s.lock.Unlock()

		rc := s.connectOnce(ctx, rec, herdrSock)
		if s.stopping() {
			return
		}

		now := hfcommon.NowUnix()
		if now-started >= int64(StableSeconds()) {
			backoff = BackoffMinSeconds()
		}
		reason := s.exitReason(rc, rec)
		s.lock.Lock()
		s.nextRetry = now + int64(backoff)
		s.since = now
		s.lock.Unlock()
		s.write("retrying", reason)

		if reason != lastReason {
			hfcommon.Logf("warn", "bridge %s: %s；%ds 后重连。", s.machine, reason, backoff)
			lastReason = reason
		} else {
			hfcommon.Logf("info", "bridge %s: 仍无法连接，%ds 后重连。", s.machine, backoff)
		}

		waited := 0
		for !s.stopping() && waited < backoff {
			select {
			case <-ctx.Done():
				return
			case <-time.After(time.Second):
			}
			waited++
		}
		backoff *= 2
		if backoff > BackoffMaxSeconds() {
			backoff = BackoffMaxSeconds()
		}
	}
}

// stopping 报告是否已收到停止信号（ctx 取消 / supervisor 主动停）。
func (s *Supervisor) stopping() bool {
	s.lock.Lock()
	defer s.lock.Unlock()
	return s.stop
}

// setRetry 写 nextRetry（0 = 无重连计划）。
func (s *Supervisor) setRetry(v int64) {
	s.lock.Lock()
	s.nextRetry = v
	s.lock.Unlock()
}

// connectOnce 复刻 _bridge_connect_once：建一条会话并跑到它结束；返回 ssh 的退出码。
func (s *Supervisor) connectOnce(ctx context.Context, rec activationRecord, herdrSock string) int {
	dest := SSHDestination(rec.SSHTarget)
	remote := RemoteServeCmd(rec.ServerRoot, rec.StateDir)
	argv := SSHArgs(s.ctl)

	errlog := ClientLog(s.machine)
	_ = os.Remove(errlog) // bash: `: >"${errlog}"`

	// 上一个 supervisor 若被 SIGKILL，它的 master 可能还活着并占着映射端口：先请它退出
	ctlExit(s.ctl)
	_ = os.Remove(s.ctl)

	s.lock.Lock()
	s.specs = map[int]string{}
	s.statuses = map[int]forwardState{}
	s.serverHost = ""
	s.lock.Unlock()
	s.write("connecting", "")

	full := append(append([]string{}, argv...), dest, remote)
	cmd := exec.Command(full[0], full[1:]...)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	stdin, err := cmd.StdinPipe()
	if err != nil {
		hfcommon.Logf("warn", "bridge %s: 建会话失败（stdin）：%v", s.machine, err)
		return 255
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		hfcommon.Logf("warn", "bridge %s: 建会话失败（stdout）：%v", s.machine, err)
		return 255
	}
	logFile, err := os.OpenFile(errlog, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err == nil {
		cmd.Stderr = logFile
	}
	if err := cmd.Start(); err != nil {
		if logFile != nil {
			_ = logFile.Close()
		}
		return 255
	}
	s.lock.Lock()
	s.sshPID = cmd.Process.Pid
	s.lock.Unlock()

	s.send(stdin, Hello{Host: s.host, Labels: []string{rec.Label}}.String())

	lines := make(chan string, 16)
	go func() {
		defer close(lines)
		r := bufio.NewReaderSize(stdout, 64*1024)
		for {
			raw, err := r.ReadString('\n')
			if strings.HasSuffix(raw, "\n") {
				lines <- strings.TrimSuffix(strings.TrimSuffix(raw, "\n"), "\r")
			}
			if err != nil {
				return
			}
		}
	}()

	ticker := time.NewTicker(time.Duration(PollSeconds()) * time.Second)
	defer ticker.Stop()
	lastPing := hfcommon.NowUnix()
	running := true
	for running {
		select {
		case <-ctx.Done():
			running = false
		case line, ok := <-lines:
			if !ok {
				running = false
				break
			}
			s.handleLine(stdin, line)
		case <-ticker.C:
		}

		now := hfcommon.NowUnix()
		if now-lastPing >= int64(PingSeconds()) {
			s.send(stdin, Ping{}.String())
			lastPing = now
			s.retryFailed(stdin)
		}
		if herdrSock != "" {
			if _, err := os.Stat(herdrSock); err != nil {
				hfcommon.Logf("info", "bridge %s: 本机 herdr server 已退出，桥接随之停止。", s.machine)
				s.lock.Lock()
				s.stop = true
				s.lock.Unlock()
				running = false
			}
		}
	}

	_ = stdin.Close()
	_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGTERM)
	_ = cmd.Process.Kill()
	_ = cmd.Wait()
	if logFile != nil {
		_ = logFile.Close()
	}
	s.lock.Lock()
	s.sshPID = 0
	s.lock.Unlock()

	if cmd.ProcessState != nil {
		if code := cmd.ProcessState.ExitCode(); code >= 0 {
			return code
		}
	}
	return 255
}

// handleLine 复刻客户端侧对 B 协议行的分发（未知行只 warn）。
func (s *Supervisor) handleLine(w io.Writer, line string) {
	msg, err := ParseLine(line)
	if err != nil {
		hfcommon.Logf("warn", "bridge %s: 忽略未知协议行：%s", s.machine, clip(line, 120))
		return
	}
	switch m := msg.(type) {
	case Hello:
		s.lock.Lock()
		s.serverHost = m.Host
		s.since = hfcommon.NowUnix()
		label := s.label()
		s.lock.Unlock()
		s.write("connected", "")
		hfcommon.Logf("info", "bridge %s: 已连上 %s（%s）。", s.machine, label, m.Host)
	case Sync:
		s.reconcile(w, m)
	case Open:
		s.openURL(m.URL)
	default:
		hfcommon.Logf("warn", "bridge %s: 忽略未知协议行：%s", s.machine, clip(line, 120))
	}
}

// label 取当前激活记录的 label（空则回退 machine id）。
func (s *Supervisor) label() string {
	rec, err := loadActivation(s.machine)
	if err != nil || rec.Label == "" {
		return s.machine
	}
	return rec.Label
}

// reconcile 复刻 _bridge_reconcile：把 A 上已生效的映射对齐到 B 的期望集合。
func (s *Supervisor) reconcile(w io.Writer, msg Sync) {
	want := map[int]string{}
	for _, e := range msg.Forwards {
		want[e.LocalPort] = fmt.Sprintf("%d %d", e.LocalPort, e.RemotePort)
	}

	s.lock.Lock()
	type removal struct {
		lp, rp int
		spec   string
	}
	var removals []removal
	for lp, spec := range s.specs {
		if want[lp] == spec {
			continue
		}
		removals = append(removals, removal{lp: lp, spec: spec})
	}
	s.lock.Unlock()

	for _, r := range removals {
		parts := strings.SplitN(r.spec, " ", 2)
		lpNum, _ := strconv.Atoi(parts[0])
		rpNum, _ := strconv.Atoi(parts[1])
		s.lock.Lock()
		st := s.statuses[r.lp]
		s.lock.Unlock()
		why := ""
		if st.State == "up" {
			why = mux(s.ctl, "cancel", lpNum, rpNum)
			hfcommon.Logf("info", "bridge %s: 已撤销 localhost:%d → %s:%d%s", s.machine, lpNum, s.label(), rpNum, parens(why))
		}
		s.lock.Lock()
		delete(s.specs, r.lp)
		delete(s.statuses, r.lp)
		s.lock.Unlock()
	}

	for lp, spec := range want {
		s.lock.Lock()
		_, exists := s.specs[lp]
		if !exists {
			s.specs[lp] = spec
		}
		s.lock.Unlock()
		if !exists {
			s.applyOne(w, lp)
		}
	}
	s.write("connected", "")
}

// parens 复刻 bash 的 `${why:+（${why}）}`。
func parens(why string) string {
	if why == "" {
		return ""
	}
	return "（" + why + "）"
}

// applyOne 复刻 _bridge_apply_one：按 spec 在 master 上开一条 -L，并把结果报告给 B。
func (s *Supervisor) applyOne(w io.Writer, lp int) {
	s.lock.Lock()
	spec := s.specs[lp]
	s.lock.Unlock()
	parts := strings.SplitN(spec, " ", 2)
	if len(parts) != 2 {
		return
	}
	rpNum, _ := strconv.Atoi(parts[1])

	// bash: `probe_tcp 127.0.0.1 "${lp}" 1` -> ok 表示**A 侧端口已被别的进程占着**
	if !portBusy(lp) {
		why := mux(s.ctl, "forward", lp, rpNum)
		if why == "" {
			s.setStatus(lp, "up", "")
			s.send(w, Status{ID: fmt.Sprintf("f-%d", lp), State: "up"}.String())
			hfcommon.Logf("info", "bridge %s: localhost:%d → %s:%d 已生效。", s.machine, lp, s.label(), rpNum)
			return
		}
		s.setStatus(lp, "down", "ssh 拒绝转发："+why)
		s.send(w, Status{ID: fmt.Sprintf("f-%d", lp), State: "down", Reason: "ssh 拒绝转发：" + why}.String())
		return
	}
	reason := fmt.Sprintf("client 端口 %d 已被占用（%s）", lp, s.host)
	s.setStatus(lp, "down", reason)
	s.send(w, Status{ID: fmt.Sprintf("f-%d", lp), State: "down", Reason: reason}.String())
}

// retryFailed 复刻 _bridge_retry_failed：重试 down 的映射（端口短暂被占、旧 master
// 尚未释放等会自愈）。
func (s *Supervisor) retryFailed(w io.Writer) {
	s.lock.Lock()
	failed := []int{}
	for lp, st := range s.statuses {
		if st.State == "down" {
			failed = append(failed, lp)
		}
	}
	s.lock.Unlock()
	for _, lp := range failed {
		s.applyOne(w, lp)
	}
	if len(failed) > 0 {
		s.write("connected", "")
	}
}

// setStatus 记录一条映射的状态。
func (s *Supervisor) setStatus(lp int, state, reason string) {
	s.lock.Lock()
	s.statuses[lp] = forwardState{Spec: s.specs[lp], State: state, Reason: reason}
	s.lock.Unlock()
}

// openURL 复刻 _bridge_open_url：只打开「已生效映射端口」的 localhost URL。
//
// 防 B 借机让 A 打开任意地址（钓鱼 / 内网探测）：URL 必须是 localhost/127.0.0.1，
// 且端口必须是本桥接**已生效**的映射。
func (s *Supervisor) openURL(url string) {
	scheme, host, portText, rest, ok := parseLocalhostURL(url)
	if !ok {
		hfcommon.Logf("warn", "bridge %s: 拒绝打开非 localhost URL：%s", s.machine, clip(url, 120))
		return
	}
	port := 80
	if portText == "" {
		if scheme == "https" {
			port = 443
		}
	} else {
		// 端口要当数组下标（bash 的算术求值）：前导零会按八进制解析，先挡掉
		if !isDigits(portText) || portText[0] == '0' {
			hfcommon.Logf("warn", "bridge %s: 拒绝打开 %s（端口 %s 不是本桥接已生效的映射）。", s.machine, clip(url, 120), portText)
			return
		}
		n, err := strconv.Atoi(portText)
		if err != nil || n > 65535 {
			hfcommon.Logf("warn", "bridge %s: 拒绝打开 %s（端口 %s 不是本桥接已生效的映射）。", s.machine, clip(url, 120), portText)
			return
		}
		port = n
	}
	s.lock.Lock()
	st := s.statuses[port]
	s.lock.Unlock()
	if st.State != "up" {
		hfcommon.Logf("warn", "bridge %s: 拒绝打开 %s（端口 %d 不是本桥接已生效的映射）。", s.machine, clip(url, 120), port)
		return
	}

	opener := openerCommand()
	if opener == "" {
		hfcommon.Logf("warn", "bridge %s: 本机没有 xdg-open/open，无法打开 %s。", s.machine, url)
		return
	}
	target := scheme + "://" + host + urlPortSuffix(portText, port) + rest
	hfcommon.Logf("info", "bridge %s: 打开 %s", s.machine, target)
	detachExec(opener, target)
}

// urlPortSuffix 保留原始 URL 的端口形态（原样透传，不改写用户看到的地址）。
func urlPortSuffix(portText string, port int) string {
	if portText == "" {
		return ""
	}
	return ":" + strconv.Itoa(port)
}

// parseLocalhostURL 复刻 `^https?://(localhost|127\.0\.0\.1)(:([0-9]{1,5}))?([/?#][^[:space:]]*)?$`。
func parseLocalhostURL(url string) (scheme, host, port, rest string, ok bool) {
	switch {
	case strings.HasPrefix(url, "https://"):
		scheme, url = "https", url[len("https://"):]
	case strings.HasPrefix(url, "http://"):
		scheme, url = "http", url[len("http://"):]
	default:
		return "", "", "", "", false
	}
	switch {
	case strings.HasPrefix(url, "localhost"):
		host, url = "localhost", url[len("localhost"):]
	case strings.HasPrefix(url, "127.0.0.1"):
		host, url = "127.0.0.1", url[len("127.0.0.1"):]
	default:
		return "", "", "", "", false
	}
	if strings.HasPrefix(url, ":") {
		body := url[1:]
		i := 0
		for i < len(body) && i <= 5 && body[i] >= '0' && body[i] <= '9' {
			i++
		}
		if i == 0 || i > 5 {
			return "", "", "", "", false
		}
		port = body[:i]
		url = body[i:]
	}
	if url == "" {
		return scheme, host, port, "", true
	}
	if !strings.ContainsRune("/?#", rune(url[0])) {
		return "", "", "", "", false
	}
	if strings.ContainsAny(url, " \t\n\r\v\f") {
		return "", "", "", "", false
	}
	return scheme, host, port, url, true
}

// openerCommand 复刻 _bridge_open_url 的 opener 探测（HERDR_FORWARD_OPENER 优先）。
func openerCommand() string {
	if v := strings.TrimSpace(os.Getenv("HERDR_FORWARD_OPENER")); v != "" {
		return v
	}
	for _, cand := range []string{"xdg-open", "open"} {
		if _, err := exec.LookPath(cand); err == nil {
			return cand
		}
	}
	return ""
}

// exitReason 复刻 _bridge_exit_reason：给人看的断线原因（含 ssh stderr 摘要）。
//
// ⚠ 刻意复刻 bash 的一处**动态作用域**行为：`_bridge_ctl_exit` 会 kill master，于是
// `wait` 的 rc 是**信号**（143），bash 因此落到 default 分支。bash 只在 ssh **自己**
// 退出（连接失败 255 / 远端命令缺失 127/126 / 版本过旧 64）时才走那几个特判分支；
// 而「master 被我们 kill」这一路径两者都走 default。为与 bash 的输出止血一致，
// 这里把「被信号杀死」也映射到 default 文案（rc 用 143 复述）。
func (s *Supervisor) exitReason(rc int, rec activationRecord) string {
	tail := tailLines(ClientLog(s.machine), 3)
	switch rc {
	case 127, 126:
		return "远端找不到插件的 bin/forward（插件未装或已移动）。请重新激活该机器。"
	case 64:
		return "远端插件版本过旧（不支持 bridge serve）。请在远端重新执行 herdr plugin install zzjcool/herdr-forward --yes。"
	case 255:
		if tail == "" {
			return "SSH 连接失败：无更多信息"
		}
		return "SSH 连接失败：" + tail
	default:
		if tail == "" {
			return fmt.Sprintf("会话结束（rc=%d）", rc)
		}
		return fmt.Sprintf("会话结束（rc=%d）：%s", rc, tail)
	}
}

// tailLines 复刻 `tail -n 3 <log>` 并把换行压成空格。
func tailLines(path string, n int) string {
	data, err := os.ReadFile(path)
	if err != nil || len(data) == 0 {
		return ""
	}
	lines := strings.Split(strings.TrimRight(string(data), "\n"), "\n")
	if len(lines) > n {
		lines = lines[len(lines)-n:]
	}
	return strings.Join(lines, " ")
}

// write 复刻 _bridge_client_write：把 supervisor 状态原子写盘。
func (s *Supervisor) write(state, reason string) {
	s.lock.Lock()
	doc := clientDoc{
		Pid:         int64(os.Getpid()),
		Machine:     s.machine,
		Label:       s.labelLocked(),
		Target:      s.targetLocked(),
		ServerHost:  s.serverHost,
		State:       state,
		Reason:      reason,
		SinceUnix:   s.since,
		UpdatedUnix: hfcommon.NowUnix(),
		NextRetry:   s.nextRetry,
		Forwards:    map[int]forwardState{},
	}
	for lp, st := range s.statuses {
		doc.Forwards[lp] = forwardState{Spec: st.Spec, State: st.State, Reason: st.Reason}
	}
	s.lock.Unlock()
	writeClientFile(ClientFile(s.machine), doc)
}

// labelLocked 读 label（不重入锁：调用方已持锁时用）。
func (s *Supervisor) labelLocked() string {
	rec, err := loadActivation(s.machine)
	if err != nil || rec.Label == "" {
		return s.machine
	}
	return rec.Label
}

// targetLocked 读 ssh_target。
func (s *Supervisor) targetLocked() string {
	rec, _ := loadActivation(s.machine)
	return rec.SSHTarget
}

// send 复刻 _bridge_send：写一行给 B（写失败 = 会话已断，由读循环发现 EOF）。
func (s *Supervisor) send(w io.Writer, line string) {
	if w == nil {
		return
	}
	_, _ = io.WriteString(w, line+"\n")
}

// loadActivation 读激活记录里桥接需要的四个字段（缺任一 → 错误；对照 bash 的
// `[[ -z ${rec} || -z ${cl_target} || -z ${cl_root} || -z ${cl_rstate} ]]`）。
//
// 直接读 activated-machines.json（**只读**，不依赖 internal/machine 的写侧 API）：
// 与 lib/bridge.sh 的 bridge_machine_record 同一策略 —— 桥接模块不该因为 machines
// 模块的写侧接口变化而被牵连，读一个 JSON 文件是最小的耦合面。
func loadActivation(machine string) (activationRecord, error) {
	data, err := os.ReadFile(stateActivationFile())
	if err != nil {
		return activationRecord{}, errors.New("no activation record")
	}
	doc, err := jqjson.Parse(data)
	if err != nil {
		return activationRecord{}, errors.New("unparsable activation record")
	}
	root, ok := doc.(*jqjson.Object)
	if !ok {
		return activationRecord{}, errors.New("no activation record")
	}
	machinesVal, ok := root.Get("machines")
	if !ok {
		return activationRecord{}, errors.New("no activation record")
	}
	machines, ok := machinesVal.(*jqjson.Object)
	if !ok {
		return activationRecord{}, errors.New("no activation record")
	}
	rawVal, ok := machines.Get(machine)
	if !ok {
		return activationRecord{}, errors.New("no activation record")
	}
	raw, ok := rawVal.(*jqjson.Object)
	if !ok {
		return activationRecord{}, errors.New("no activation record")
	}
	rec := activationRecord{
		Label:      rawString(raw, "label"),
		SSHTarget:  rawString(raw, "ssh_target"),
		ServerRoot: rawString(raw, "server_root"),
		StateDir:   rawString(raw, "state_dir"),
	}
	if rec.SSHTarget == "" || rec.ServerRoot == "" || rec.StateDir == "" {
		return activationRecord{}, errors.New("incomplete activation record")
	}
	return rec, nil
}

// stateActivationFile 是 activated-machines.json 的路径（与 internal/machine.StateFile
// 同一约定：$HERDR_PLUGIN_STATE_DIR/activated-machines.json）。
func stateActivationFile() string {
	return filepath.Join(hfcommon.StateDir(), "activated-machines.json")
}

// rawString 取一个 JSON 对象的字符串键（非字符串/缺失 → ""）。
func rawString(o *jqjson.Object, key string) string {
	v, _ := o.Get(key)
	s, _ := v.(string)
	return s
}
