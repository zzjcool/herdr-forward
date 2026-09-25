// tunnel_test.go —— internal/tunnel 的单测（PLAN §8「tunnel 参数拼装 golden argv」+
// A.3.1 诚实分级 + Stop/Reap 的文件语义）。
//
// 所有用例都在 t.TempDir() 的隔离 state 目录里跑，绝不 spawn 真 ssh（除 Start 的失败
// 路径 —— 那条会 exec 一个目标不可达的 ssh，且重试旋钮被缩到 ~0 以避免真实等待）。
package tunnel

import (
	"bytes"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/zzjcool/herdr-forward/internal/hfcommon"
	"github.com/zzjcool/herdr-forward/internal/state"
)

func useStateDir(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	t.Setenv("HERDR_PLUGIN_STATE_DIR", dir)
	return dir
}

// captureStdout 捕获 fn 期间的 os.Stdout（Doctor 的输出是用户可见契约）。
func captureStdout(t *testing.T, fn func()) string {
	t.Helper()
	old := os.Stdout
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatalf("pipe: %v", err)
	}
	os.Stdout = w
	done := make(chan string, 1)
	go func() {
		var buf bytes.Buffer
		_, _ = io.Copy(&buf, r)
		done <- buf.String()
	}()
	fn()
	os.Stdout = old
	_ = w.Close()
	return <-done
}

// --- 1. argv 拼装（对标 tests/unit/test_tunnel_args.sh 的 golden） --------------

func TestSSHArgsGolden(t *testing.T) {
	dir := useStateDir(t)
	argv, err := SSHArgs("f-3000", 3000, "127.0.0.1:8080", "user@host.example:2222")
	if err != nil {
		t.Fatalf("SSHArgs: %v", err)
	}
	want := []string{
		"-N",
		"-L", "127.0.0.1:3000:127.0.0.1:8080",
		"-o", "BatchMode=yes",
		"-o", "ExitOnForwardFailure=yes",
		"-o", "ControlMaster=auto",
		"-o", "ControlPath=" + dir + "/ssh-ctl/ctl-f-3000",
		"-o", "ControlPersist=yes",
		"-o", "StrictHostKeyChecking=accept-new",
		"-o", "UserKnownHostsFile=" + dir + "/ssh-ctl/known_hosts",
		"-F", "/dev/null",
		"-p", "2222",
		"user@host.example",
	}
	if len(argv) != len(want) {
		t.Fatalf("argv 长度 = %d, want %d\n got: %q\nwant: %q", len(argv), len(want), argv, want)
	}
	for i := range want {
		if argv[i] != want[i] {
			t.Errorf("argv[%d] = %q, want %q", i, argv[i], want[i])
		}
	}
}

func TestSSHArgsDefaultPortAndTargetLiteral(t *testing.T) {
	useStateDir(t)

	// 无端口 -> -p 22，destination 原样
	argv, err := SSHArgs("f-22", 22, "localhost:8000", "user@host")
	if err != nil {
		t.Fatal(err)
	}
	joined := strings.Join(argv, "|")
	if !strings.Contains(joined, "|-p|22|") {
		t.Errorf("缺省端口应为 22：%q", joined)
	}
	if argv[len(argv)-1] != "user@host" {
		t.Errorf("destination = %q, want user@host", argv[len(argv)-1])
	}

	// 方括号 IPv6 + 端口：destination 保留方括号，端口剥离
	argv, err = SSHArgs("f-9000", 9000, "127.0.0.1:8080", "user@[::1]:2222")
	if err != nil {
		t.Fatal(err)
	}
	if argv[len(argv)-1] != "user@[::1]" {
		t.Errorf("destination = %q, want user@[::1]", argv[len(argv)-1])
	}
	if got := flagVal(t, argv, "-p"); got != "2222" {
		t.Errorf("-p = %q, want 2222", got)
	}
}

func TestSSHArgsPercentEscape(t *testing.T) {
	// herdr 的真实 state 目录名是 URL 编码的 zzjcool%3Aforward；ssh 会做 percent 展开，
	// 故交给 ssh 的路径值必须把 % 翻倍（文件系统路径保持原样）。
	dir := filepath.Join(t.TempDir(), "zzjcool%3Aforward")
	t.Setenv("HERDR_PLUGIN_STATE_DIR", dir)

	argv, err := SSHArgs("f-9000", 9000, "127.0.0.1:8080", "user@host")
	if err != nil {
		t.Fatal(err)
	}
	esc := filepath.Join(dir, "ssh-ctl") // % 已在 dir 里
	esc = strings.ReplaceAll(esc, "%", "%%")
	if got := optVal(t, argv, "-o", "ControlPath"); got != esc+"/ctl-f-9000" {
		t.Errorf("ControlPath = %q, want %q", got, esc+"/ctl-f-9000")
	}
	if got := optVal(t, argv, "-o", "UserKnownHostsFile"); got != esc+"/known_hosts" {
		t.Errorf("UserKnownHostsFile = %q, want %q", got, esc+"/known_hosts")
	}

	// 文件系统路径（ControlPath()）**不**转义
	ctl, err := ControlPath("f-9000")
	if err != nil {
		t.Fatal(err)
	}
	if want := filepath.Join(dir, "ssh-ctl", "ctl-f-9000"); ctl != want {
		t.Errorf("ControlPath() = %q, want %q（文件系统路径不应转义）", ctl, want)
	}
}

func TestParseSSHTargetTable(t *testing.T) {
	cases := []struct{ in, port, dest string }{
		{"user@host", "22", "user@host"},
		{"user@host:2222", "2222", "user@host"},
		{"user@gpu-box.example.com:22022", "22022", "user@gpu-box.example.com"},
		{"user@[::1]:2222", "2222", "user@[::1]"},
		{"[::1]", "22", "[::1]"},
		{"host.local", "22", "host.local"},
		{"user@host:", "22", "user@host"},
		{"user@host:abc", "22", "user@host:abc"},
		{"a:b:2222", "2222", "a:b"}, // 贪婪匹配 -> 取最后一个冒号
		{"", "22", ""},
	}
	for _, c := range cases {
		port, dest := ParseSSHTarget(c.in)
		if port != c.port || dest != c.dest {
			t.Errorf("ParseSSHTarget(%q) = (%q, %q), want (%q, %q)", c.in, port, dest, c.port, c.dest)
		}
	}
}

func TestControlDirPerms(t *testing.T) {
	dir := useStateDir(t)
	ctlDir, err := ControlDir()
	if err != nil {
		t.Fatal(err)
	}
	if want := filepath.Join(dir, "ssh-ctl"); ctlDir != want {
		t.Errorf("ControlDir() = %q, want %q", ctlDir, want)
	}
	st, err := os.Stat(ctlDir)
	if err != nil {
		t.Fatal(err)
	}
	if st.Mode().Perm() != 0o700 {
		t.Errorf("control dir 权限 = %o, want 700", st.Mode().Perm())
	}
}

// optVal 取 argv 里 `-o <key>=...` 的值（key == "" = 取第一个 -o 后的裸值）。
func optVal(t *testing.T, argv []string, args ...string) string {
	t.Helper()
	key := ""
	if len(args) == 2 {
		key = args[1] + "="
	}
	for i := 0; i < len(argv)-1; i++ {
		if argv[i] != "-o" {
			continue
		}
		if key == "" {
			return argv[i+1]
		}
		if strings.HasPrefix(argv[i+1], key) {
			return strings.TrimPrefix(argv[i+1], key)
		}
	}
	t.Fatalf("argv 里没有 %v：%q", args, argv)
	return ""
}

// flagVal 取 argv 里 `-p <value>` 这类「单字符 flag + 值」形态的值。
func flagVal(t *testing.T, argv []string, flag string) string {
	t.Helper()
	for i := 0; i < len(argv)-1; i++ {
		if argv[i] == flag {
			return argv[i+1]
		}
	}
	t.Fatalf("argv 里没有 %s：%q", flag, argv)
	return ""
}

// --- 2. Alive（含僵尸进程） ---------------------------------------------------

func TestAlive(t *testing.T) {
	if !Alive(os.Getpid()) {
		t.Errorf("自己的 pid 应判活")
	}
	if Alive(2147483000) {
		t.Errorf("不存在的 pid 应判死")
	}
	if Alive(0) || Alive(-1) {
		t.Errorf("pid<=0 应判死（bash 的正则拒绝非数字/负值）")
	}
}

func TestAliveRejectsZombie(t *testing.T) {
	if _, err := os.Stat("/proc/self/stat"); err != nil {
		t.Skip("/proc 不可用（非 Linux），跳过僵尸判定")
	}
	// 起一个立即退出的子进程且**不** Wait -> 它变成僵尸（state=Z）。
	cmd := exec.Command("true")
	if err := cmd.Start(); err != nil {
		t.Skipf("无法起测试子进程：%v", err)
	}
	pid := cmd.Process.Pid
	defer func() { _, _ = cmd.Process.Wait() }()

	deadline := time.Now().Add(2 * time.Second)
	for {
		state, err := os.ReadFile(fmt.Sprintf("/proc/%d/stat", pid))
		if err == nil && strings.Contains(string(state), ") Z") {
			break
		}
		if time.Now().After(deadline) {
			t.Skipf("子进程未进入僵尸态（pid=%d）：%q", pid, state)
		}
		time.Sleep(20 * time.Millisecond)
	}
	if Alive(pid) {
		t.Errorf("僵尸进程 pid=%d 必须判死（bash: /proc/<pid>/stat 状态 Z）", pid)
	}
}

// --- 3. Probe / Health -------------------------------------------------------

// startServer 起一个 127.0.0.1 测试服务，返回端口与关闭函数。
//
// reply=true  -> 读到请求后立刻回 "pong"（probe 应为 up）
// reply=false -> 读到请求后**保持连接 3s 不回包**（probe 超时 -> degraded；
//
//	若立刻关连接，对端读到的是 EOF -> down，那是另一种语义）
func startServer(t *testing.T, reply bool) (int, func()) {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Skipf("无法监听回环端口：%v", err)
	}
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			go func(c net.Conn) {
				defer func() { _ = c.Close() }()
				buf := make([]byte, 64)
				_, _ = c.Read(buf)
				if reply {
					_, _ = c.Write([]byte("pong\n"))
					return
				}
				time.Sleep(3 * time.Second)
			}(conn)
		}
	}()
	return ln.Addr().(*net.TCPAddr).Port, func() { _ = ln.Close() }
}

func TestProbeAndHealth(t *testing.T) {
	useStateDir(t)
	m := NewManager()

	replyPort, closeReply := startServer(t, true)
	defer closeReply()
	if got := m.Probe(replyPort); got != hfcommon.HealthUp {
		t.Errorf("有回包 -> %s, want up", got)
	}
	// master 不活一律 down（即使端口可连）
	if got := m.Health("f-1", 2147483000, replyPort); got != hfcommon.HealthDown {
		t.Errorf("master 不活 -> %s, want down", got)
	}
	// master 活着 + 有回包 -> up
	if got := m.Health("f-1", os.Getpid(), replyPort); got != hfcommon.HealthUp {
		t.Errorf("master 活 + 回包 -> %s, want up", got)
	}

	// 无人监听 -> down
	deadPort := freePort(t)
	if got := m.Probe(deadPort); got != hfcommon.HealthDown {
		t.Errorf("拒连 -> %s, want down", got)
	}
}

func TestProbeDegraded(t *testing.T) {
	useStateDir(t)
	old := probeTimeoutSec
	probeTimeoutSec = 1 // degraded 用例需等满一个 timeout（默认 2s）
	defer func() { probeTimeoutSec = old }()

	port, closeFn := startServer(t, false) // 连上但不回包
	defer closeFn()
	if got := NewManager().Probe(port); got != hfcommon.HealthDegraded {
		t.Errorf("连上但无回包 -> %s, want degraded（诚实分级：不得报 up）", got)
	}
}

// freePort 找一个当前无人监听的端口（关闭后立刻返回，仅测试用）。
func freePort(t *testing.T) int {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Skipf("无法找空闲端口：%v", err)
	}
	port := ln.Addr().(*net.TCPAddr).Port
	_ = ln.Close()
	return port
}

// --- 4. Stop / Reap 的文件语义 ------------------------------------------------

func TestStopRemovesFilesKeepsKnownHosts(t *testing.T) {
	dir := useStateDir(t)
	ctlDir, err := ControlDir()
	if err != nil {
		t.Fatal(err)
	}
	id := "f-4242"
	for _, name := range []string{"ctl-" + id, "pid-" + id, "target-" + id, "log-" + id, "known_hosts"} {
		if err := os.WriteFile(filepath.Join(ctlDir, name), []byte("x"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	// pid 文件里放一个不存在的 pid -> 只走 rm 分支，零进程操作
	if err := os.WriteFile(filepath.Join(ctlDir, "pid-"+id), []byte("2147483000\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	if err := NewManager().Stop(id); err != nil {
		t.Fatalf("Stop: %v", err)
	}
	for _, name := range []string{"ctl-" + id, "pid-" + id, "target-" + id, "log-" + id} {
		if _, err := os.Stat(filepath.Join(ctlDir, name)); err == nil {
			t.Errorf("%s 应在 Stop 后删除", name)
		}
	}
	if _, err := os.Stat(filepath.Join(ctlDir, "known_hosts")); err != nil {
		t.Errorf("known_hosts 必须跨 Stop 保留（一次性 host key 缓存）：%v", err)
	}
	_ = dir
}

func TestStopTerminatesRecordedPid(t *testing.T) {
	useStateDir(t)
	ctlDir, err := ControlDir()
	if err != nil {
		t.Fatal(err)
	}
	// 起一个 sleep 当「master」，写进 pid 文件；Stop 必须 TERM 掉它。
	cmd := exec.Command("sleep", "30")
	if err := cmd.Start(); err != nil {
		t.Skipf("无法起 sleep：%v", err)
	}
	defer func() {
		_ = cmd.Process.Kill()
		_, _ = cmd.Process.Wait()
	}()
	id := "f-4243"
	if err := os.WriteFile(filepath.Join(ctlDir, "pid-"+id),
		[]byte(strconv.Itoa(cmd.Process.Pid)+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := NewManager().Stop(id); err != nil {
		t.Fatalf("Stop: %v", err)
	}
	// TERM 后 ≤3s 内应退出（Stop 内部已轮询），此处再等一点点确认不可达。
	deadline := time.Now().Add(2 * time.Second)
	for Alive(cmd.Process.Pid) && time.Now().Before(deadline) {
		time.Sleep(50 * time.Millisecond)
	}
	if Alive(cmd.Process.Pid) {
		t.Errorf("Stop 后 pid %d 仍活着", cmd.Process.Pid)
	}
}

func TestReapIsIdempotent(t *testing.T) {
	useStateDir(t)
	m := NewManager()
	if err := m.Reap("f-nope", 0); err != nil {
		t.Fatalf("Reap（无文件）应幂等成功：%v", err)
	}
	if err := m.Reap("f-nope", 0); err != nil {
		t.Fatalf("Reap 二次调用应幂等成功：%v", err)
	}
}

// --- 5. Start 失败路径 --------------------------------------------------------

func TestStartFailurePath(t *testing.T) {
	useStateDir(t)
	// 缩短重试旋钮：默认 50×0.1s = 5s；测试只跑 3×1ms。
	oldAttempts, oldInterval, oldTimeout := checkAttempts, checkInterval, ctlSSHTimeout
	checkAttempts, checkInterval, ctlSSHTimeout = 3, time.Millisecond, 500*time.Millisecond
	defer func() { checkAttempts, checkInterval, ctlSSHTimeout = oldAttempts, oldInterval, oldTimeout }()

	// 目标不可达（127.0.0.1 上一个几乎不可能监听的端口，立即 connection refused）。
	port := freePort(t)
	_, err := NewManager().Start("f-45999", 45999, "127.0.0.1", port, fmt.Sprintf("nobody@127.0.0.1:%d", port))
	if err == nil {
		t.Fatal("目标不可达时 Start 必须失败（die 5 语义）")
	}
	msg := err.Error()
	if !strings.HasPrefix(msg, "tunnel start failed: f-45999 -> 127.0.0.1:45999 via ") {
		t.Errorf("错误文案前缀不符 bash：%q", msg)
	}
	if !strings.Contains(msg, "nobody@127.0.0.1:") {
		t.Errorf("错误文案应含 ssh_target：%q", msg)
	}

	ctlDir, err := ControlDir()
	if err != nil {
		t.Fatal(err)
	}
	// target 文件已写（bash 亦然：先写 target 再拉 ssh）
	if _, err := os.Stat(filepath.Join(ctlDir, "target-f-45999")); err != nil {
		t.Errorf("target-<id> 应已写入：%v", err)
	}
	// 失败路径不写 pid 文件（只有拿到 master 才写）
	if _, err := os.Stat(filepath.Join(ctlDir, "pid-f-45999")); err == nil {
		t.Errorf("失败时不该有 pid-<id>")
	}
}

// --- 6. Doctor（诚实分级 + --fix/--prune） ------------------------------------

// writeState 写 forwards.json（created_unix=1 以保持确定性）。
func writeState(t *testing.T, records ...state.Forward) {
	t.Helper()
	for i := range records {
		if records[i].CreatedUnix == 0 {
			records[i].CreatedUnix = 1
		}
	}
	if err := state.Save(records); err != nil {
		t.Fatalf("state.Save: %v", err)
	}
}

func ptr(v int) *int { return &v }

func TestDoctorReportsDownForDeadMaster(t *testing.T) {
	useStateDir(t)
	writeState(t, state.Forward{ID: "f-45811", LocalPort: 45811, RemotePort: 45811,
		RemoteHost: "127.0.0.1", SshTarget: "u@h:22", Status: "up", Pid: ptr(999998), Mode: state.ModeTunnel})

	out := captureStdout(t, func() { _ = NewManager().Doctor(false, false) })
	if out != "f-45811: down\n" {
		t.Errorf("doctor 报告 = %q, want %q", out, "f-45811: down\n")
	}
	// 报告不改状态
	recs, _ := state.Load()
	if recs[0].Status != "up" {
		t.Errorf("默认报告不得改状态：status=%q", recs[0].Status)
	}
}

func TestDoctorFixSetsDownWithoutPrune(t *testing.T) {
	useStateDir(t)
	writeState(t, state.Forward{ID: "f-45811", LocalPort: 45811, RemotePort: 45811,
		RemoteHost: "127.0.0.1", SshTarget: "u@h:22", Status: "up", Pid: ptr(999998), Mode: state.ModeTunnel})

	out := captureStdout(t, func() { _ = NewManager().Doctor(true, false) })
	if out != "f-45811: fixed -> down\n" {
		t.Errorf("doctor --fix 报告 = %q, want %q", out, "f-45811: fixed -> down\n")
	}
	recs, _ := state.Load()
	if len(recs) != 1 || recs[0].Status != "down" {
		t.Fatalf("--fix 应把 status 置 down 且保留记录：%+v", recs)
	}
}

func TestDoctorPruneRemovesRecordAndFiles(t *testing.T) {
	useStateDir(t)
	ctlDir, err := ControlDir()
	if err != nil {
		t.Fatal(err)
	}
	id := "f-45812"
	// 死进程 + stale socket/pid/target/log（模拟 -9 杀掉 master）
	for _, name := range []string{"ctl-" + id, "target-" + id, "log-" + id} {
		if err := os.WriteFile(filepath.Join(ctlDir, name), []byte("x"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(ctlDir, "pid-"+id), []byte("999999\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	writeState(t, state.Forward{ID: id, LocalPort: 45812, RemotePort: 45812,
		RemoteHost: "127.0.0.1", SshTarget: "u@h:22", Status: "up", Pid: ptr(999999), Mode: state.ModeTunnel})

	out := captureStdout(t, func() { _ = NewManager().Doctor(false, true) })
	if out != id+": pruned\n" {
		t.Errorf("doctor --prune 报告 = %q, want %q", out, id+": pruned\n")
	}
	recs, _ := state.Load()
	if len(recs) != 0 {
		t.Errorf("--prune 应删掉死记录：%+v", recs)
	}
	for _, name := range []string{"ctl-" + id, "pid-" + id, "target-" + id, "log-" + id} {
		if _, err := os.Stat(filepath.Join(ctlDir, name)); err == nil {
			t.Errorf("--prune 应 reap 掉 %s", name)
		}
	}
}

func TestDoctorFixPrunePrefersPrune(t *testing.T) {
	useStateDir(t)
	writeState(t, state.Forward{ID: "f-45813", LocalPort: 45813, RemotePort: 45813,
		RemoteHost: "127.0.0.1", SshTarget: "u@h:22", Status: "up", Pid: ptr(999997), Mode: state.ModeTunnel})
	out := captureStdout(t, func() { _ = NewManager().Doctor(true, true) })
	if out != "f-45813: pruned\n" {
		t.Errorf("fix+prune 时应 prune 优先：%q", out)
	}
}

func TestDoctorSkipsClientRecords(t *testing.T) {
	useStateDir(t)
	writeState(t, state.Forward{ID: "f-5173", LocalPort: 5173, RemotePort: 5173,
		RemoteHost: "localhost", Status: "starting", Mode: state.ModeClient})

	for _, flags := range [][2]bool{{false, false}, {true, false}, {false, true}, {true, true}} {
		out := captureStdout(t, func() { _ = NewManager().Doctor(flags[0], flags[1]) })
		if out != "" {
			t.Errorf("client 记录不该出现在隧道 doctor 输出里（fix=%v prune=%v）：%q", flags[0], flags[1], out)
		}
		recs, _ := state.Load()
		if len(recs) != 1 || recs[0].Status != "starting" {
			t.Errorf("client 记录必须原样保留（fix=%v prune=%v）：%+v", flags[0], flags[1], recs)
		}
	}
}

func TestDoctorUpAndFixFromStaleDown(t *testing.T) {
	useStateDir(t)
	port, closeFn := startServer(t, true)
	defer closeFn()
	writeState(t, state.Forward{ID: fmt.Sprintf("f-%d", port), LocalPort: port, RemotePort: port,
		RemoteHost: "127.0.0.1", SshTarget: "u@h:22", Status: "down", Pid: ptr(os.Getpid()), Mode: state.ModeTunnel})

	out := captureStdout(t, func() { _ = NewManager().Doctor(false, false) })
	if out != fmt.Sprintf("f-%d: up\n", port) {
		t.Errorf("master 活 + 有回包应报 up：%q", out)
	}
	out = captureStdout(t, func() { _ = NewManager().Doctor(true, false) })
	if out != fmt.Sprintf("f-%d: fixed -> up\n", port) {
		t.Errorf("--fix 应把 stale=down 修回 up：%q", out)
	}
	recs, _ := state.Load()
	if recs[0].Status != "up" {
		t.Errorf("--fix 后 status = %q, want up", recs[0].Status)
	}
	// --prune 绝不删活隧道
	out = captureStdout(t, func() { _ = NewManager().Doctor(false, true) })
	if out != fmt.Sprintf("f-%d: up\n", port) {
		t.Errorf("--prune 不得误删活隧道：%q", out)
	}
	recs, _ = state.Load()
	if len(recs) != 1 {
		t.Errorf("活记录必须保留：%+v", recs)
	}
}

func TestDoctorDegradedNeverReportsUp(t *testing.T) {
	useStateDir(t)
	old := probeTimeoutSec
	probeTimeoutSec = 1
	defer func() { probeTimeoutSec = old }()

	port, closeFn := startServer(t, false) // 连上但不回包
	defer closeFn()
	writeState(t, state.Forward{ID: fmt.Sprintf("f-%d", port), LocalPort: port, RemotePort: port,
		RemoteHost: "127.0.0.1", SshTarget: "u@h:22", Status: "up", Pid: ptr(os.Getpid()), Mode: state.ModeTunnel})

	out := captureStdout(t, func() { _ = NewManager().Doctor(false, false) })
	want := fmt.Sprintf("f-%d: degraded (no application-layer reply; status=up)\n", port)
	if out != want {
		t.Errorf("degraded 报告 = %q, want %q", out, want)
	}
	// --fix 保守置 down（status 只允许 up|down），且绝不 prune
	out = captureStdout(t, func() { _ = NewManager().Doctor(true, false) })
	want = fmt.Sprintf("f-%d: degraded (no application-layer reply) -> fixed -> down\n", port)
	if out != want {
		t.Errorf("degraded --fix 报告 = %q, want %q", out, want)
	}
	recs, _ := state.Load()
	if len(recs) != 1 || recs[0].Status != "down" {
		t.Errorf("degraded --fix 应置 down 且保留记录：%+v", recs)
	}
	// --prune 不得删 degraded 记录（master 可能还活着）
	out = captureStdout(t, func() { _ = NewManager().Doctor(false, true) })
	if !strings.Contains(out, "degraded") {
		t.Errorf("--prune 对 degraded 应只报告：%q", out)
	}
	recs, _ = state.Load()
	if len(recs) != 1 {
		t.Errorf("degraded 记录不得被 prune：%+v", recs)
	}
}
