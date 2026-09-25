// hfcommon_test.go — PLAN-GO-MIGRATION §8 要求的 hfcommon 单测。
//
// 覆盖：StateDir/ConfigDir 的 env 矩阵、Log（落盘/镜像 stderr/无 env 退化/轮转）、
// AtomicWrite（0600、原子覆盖、建目录、无残留）、ProbePayload 三态 + 有界超时。
//
// 全部自包含（真实 net.Listen / 真实临时目录），不依赖 jq，也不依赖 bash。
package hfcommon

import (
	"bytes"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

// --- StateDir / ConfigDir ---------------------------------------------------

func TestStateDirEnvMatrix(t *testing.T) {
	t.Run("env 优先", func(t *testing.T) {
		t.Setenv("HERDR_PLUGIN_STATE_DIR", "/x/state")
		if got := StateDir(); got != "/x/state" {
			t.Fatalf("StateDir()=%q want /x/state", got)
		}
	})
	t.Run("无 env 回退 HOME", func(t *testing.T) {
		t.Setenv("HOME", "/home/u")
		os.Unsetenv("HERDR_PLUGIN_STATE_DIR")
		want := "/home/u/.local/state/herdr-forward"
		if got := StateDir(); got != want {
			t.Fatalf("StateDir()=%q want %q", got, want)
		}
	})
	t.Run("无 env 无 HOME 回退 /tmp", func(t *testing.T) {
		os.Unsetenv("HERDR_PLUGIN_STATE_DIR")
		os.Unsetenv("HOME")
		want := "/tmp/.local/state/herdr-forward"
		if got := StateDir(); got != want {
			t.Fatalf("StateDir()=%q want %q", got, want)
		}
	})
	t.Run("env 为空串等同缺失", func(t *testing.T) {
		t.Setenv("HERDR_PLUGIN_STATE_DIR", "")
		t.Setenv("HOME", "/home/u")
		want := "/home/u/.local/state/herdr-forward"
		if got := StateDir(); got != want {
			t.Fatalf("StateDir()=%q want %q", got, want)
		}
	})
}

func TestConfigDirEnvMatrix(t *testing.T) {
	t.Run("HERDR_PLUGIN_CONFIG_DIR 优先", func(t *testing.T) {
		t.Setenv("HERDR_PLUGIN_CONFIG_DIR", "/x/cfg")
		if got := ConfigDir(); got != "/x/cfg" {
			t.Fatalf("ConfigDir()=%q want /x/cfg", got)
		}
	})
	t.Run("XDG_CONFIG_HOME 次之", func(t *testing.T) {
		os.Unsetenv("HERDR_PLUGIN_CONFIG_DIR")
		t.Setenv("XDG_CONFIG_HOME", "/xdg")
		want := "/xdg/herdr-forward"
		if got := ConfigDir(); got != want {
			t.Fatalf("ConfigDir()=%q want %q", got, want)
		}
	})
	t.Run("最后回退 HOME/.config", func(t *testing.T) {
		os.Unsetenv("HERDR_PLUGIN_CONFIG_DIR")
		os.Unsetenv("XDG_CONFIG_HOME")
		t.Setenv("HOME", "/home/u")
		want := "/home/u/.config/herdr-forward"
		if got := ConfigDir(); got != want {
			t.Fatalf("ConfigDir()=%q want %q", got, want)
		}
	})
}

// --- Log --------------------------------------------------------------------

func TestLogWritesFileWithUTCStamp(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("HERDR_PLUGIN_STATE_DIR", dir)

	Log("info", "unit-log-probe")

	content := readLog(t, dir)
	if !strings.Contains(content, "info: unit-log-probe") {
		t.Fatalf("日志缺少消息: %q", content)
	}
	// 行格式 [<UTC RFC3339秒>] <level>: <msg>
	line := strings.TrimSpace(content)
	if !strings.HasPrefix(line, "[") || !strings.HasSuffix(line, "info: unit-log-probe") {
		t.Fatalf("行格式不符: %q", line)
	}
	ts := line[1:strings.Index(line, "]")]
	if _, err := time.Parse("2006-01-02T15:04:05Z", ts); err != nil {
		t.Fatalf("时间戳不是 UTC 秒精度: %q (%v)", ts, err)
	}
}

func TestLogWarnMirrorsStderr(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("HERDR_PLUGIN_STATE_DIR", dir)

	stderr := captureStderr(t, func() { Log("warn", "mirror-probe") })

	if !strings.Contains(stderr, "warn: mirror-probe") {
		t.Fatalf("warn 未镜像 stderr: %q", stderr)
	}
	if !strings.Contains(readLog(t, dir), "warn: mirror-probe") {
		t.Fatal("warn 未落盘")
	}
}

func TestLogNoEnvOnlyStderr(t *testing.T) {
	os.Unsetenv("HERDR_PLUGIN_STATE_DIR")
	stderr := captureStderr(t, func() { Log("info", "stderr-only-probe") })
	if !strings.Contains(stderr, "info: stderr-only-probe") {
		t.Fatalf("无 env 时应写 stderr: %q", stderr)
	}
}

// 复刻验证：bash 在「无 env 且 level=warn」时会打印两次（先无 env 分支再 warn 镜像）。
// 本实现刻意保留该细节（迁移期零行为变化），此测试把该意图钉住，防未来"顺手修正"。
func TestLogNoEnvWarnMirrorsTwiceLikeBash(t *testing.T) {
	os.Unsetenv("HERDR_PLUGIN_STATE_DIR")
	stderr := captureStderr(t, func() { Log("warn", "double-probe") })
	if n := strings.Count(stderr, "double-probe"); n != 2 {
		t.Fatalf("期望 stderr 出现 2 次（复刻 bash），实际 %d 次: %q", n, stderr)
	}
}

func TestLogRotatesOver1MB(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("HERDR_PLUGIN_STATE_DIR", dir)
	logFile := filepath.Join(dir, "logs", LogFileName)
	if err := os.MkdirAll(filepath.Dir(logFile), 0o755); err != nil {
		t.Fatal(err)
	}
	// 写入 1.1MB 的 'Z'（无换行），与 bash unit 用例同构。
	if err := os.WriteFile(logFile, bytes.Repeat([]byte("Z"), 1100000), 0o644); err != nil {
		t.Fatal(err)
	}

	Log("info", "after-rotate-probe")

	st, err := os.Stat(logFile)
	if err != nil {
		t.Fatal(err)
	}
	if st.Size() >= 800000 {
		t.Fatalf("轮转后体积 %d 未下降（应保留 ~512KB）", st.Size())
	}
	content := readLog(t, dir)
	if !strings.Contains(content, "after-rotate-probe") {
		t.Fatal("轮转后新日志丢失")
	}
}

func TestLogNoRotationBelowThreshold(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("HERDR_PLUGIN_STATE_DIR", dir)
	logFile := filepath.Join(dir, "logs", LogFileName)
	if err := os.MkdirAll(filepath.Dir(logFile), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(logFile, bytes.Repeat([]byte("A"), LogMaxBytes), 0o644); err != nil {
		t.Fatal(err)
	}
	// 恰好等于阈值不轮转（bash 判定是 size > MAX）。
	Log("info", "boundary-probe")
	content := readLog(t, dir)
	if !strings.HasPrefix(content, "AAA") {
		t.Fatal("size == MAX 时不应轮转（应保留旧内容）")
	}
}

// --- AtomicWrite ------------------------------------------------------------

func TestAtomicWriteRoundTripAndMode(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "sub", "deep", "out.json")
	if err := AtomicWrite(path, []byte(`{"hello":1}`+"\n")); err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != `{"hello":1}`+"\n" {
		t.Fatalf("内容不一致: %q", got)
	}
	st, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if perm := st.Mode().Perm(); perm != 0o600 {
		t.Fatalf("权限 = %o want 600（对齐 mktemp）", perm)
	}
}

func TestAtomicWriteOverwritesNotAppends(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "over.json")
	if err := os.WriteFile(path, []byte("old\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := AtomicWrite(path, []byte("new\n")); err != nil {
		t.Fatal(err)
	}
	got, _ := os.ReadFile(path)
	if string(got) != "new\n" {
		t.Fatalf("应覆盖: %q", got)
	}
}

func TestAtomicWriteNoLeftoverTempFiles(t *testing.T) {
	dir := t.TempDir()
	if err := AtomicWrite(filepath.Join(dir, "a.json"), []byte("x")); err != nil {
		t.Fatal(err)
	}
	entries, _ := os.ReadDir(dir)
	for _, e := range entries {
		if strings.HasPrefix(e.Name(), ".atomic.") {
			t.Fatalf("残留临时文件: %s", e.Name())
		}
	}
}

func TestAtomicWriteEmptyContent(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "empty.json")
	if err := AtomicWrite(path, nil); err != nil {
		t.Fatal(err)
	}
	st, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if st.Size() != 0 {
		t.Fatalf("空内容应落空文件，实际 %d 字节", st.Size())
	}
}

// --- ProbePayload -----------------------------------------------------------

func TestProbePayloadDownOnRefused(t *testing.T) {
	// 关闭的端口（先监听再关闭，保证端口无人接）。
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := ln.Addr().(*net.TCPAddr).Port
	ln.Close()

	if got := ProbePayload("127.0.0.1", port, 1); got != HealthDown {
		t.Fatalf("拒连 -> %v want down", got)
	}
}

func TestProbePayloadDownOnEmptyArgs(t *testing.T) {
	if got := ProbePayload("", 0, 1); got != HealthDown {
		t.Fatalf("空参 -> %v want down", got)
	}
	if got := ProbePayload("127.0.0.1", 0, 1); got != HealthDown {
		t.Fatalf("port 0 -> %v want down", got)
	}
}

func TestProbePayloadUpOnReply(t *testing.T) {
	port, stop := startServer(t, "reply", 0)
	defer stop()

	if got := ProbePayload("127.0.0.1", port, 2); got != HealthUp {
		t.Fatalf("回包服务 -> %v want up", got)
	}
	// 输出契约：String() 与 bash stdout 逐字符一致
	if s := ProbePayload("127.0.0.1", port, 2).String(); s != "up" {
		t.Fatalf("String()=%q want up", s)
	}
}

func TestProbePayloadDegradedOnSilent(t *testing.T) {
	port, stop := startServer(t, "silent", 0)
	defer stop()

	start := time.Now()
	got := ProbePayload("127.0.0.1", port, 1)
	elapsed := time.Since(start)

	if got != HealthDegraded {
		t.Fatalf("可连不应答 -> %v want degraded", got)
	}
	if elapsed > 3*time.Second {
		t.Fatalf("探测未在预期内返回：%v（应有界）", elapsed)
	}
}

func TestProbePayloadDownOnConnectThenEOF(t *testing.T) {
	port, stop := startServer(t, "close", 0)
	defer stop()
	if got := ProbePayload("127.0.0.1", port, 1); got != HealthDown {
		t.Fatalf("连上即关 -> %v want down", got)
	}
}

// 有界性：timeoutSec<=0 的退化输入也不得挂住（bash 的 -t 0/-1 行为不可移植）。
func TestProbePayloadBoundedOnZeroTimeout(t *testing.T) {
	port, stop := startServer(t, "silent", 0)
	defer stop()

	done := make(chan Health, 1)
	start := time.Now()
	go func() { done <- ProbePayload("127.0.0.1", port, 0) }()
	select {
	case h := <-done:
		if h == HealthUp {
			t.Fatalf("0 超时不应 up（实际 %v）", h)
		}
		if time.Since(start) > 2*time.Second {
			t.Fatalf("未及时返回：%v", time.Since(start))
		}
	case <-time.After(3 * time.Second):
		t.Fatal("ProbePayload(0) 挂住了")
	}
}

func TestProbePayloadMarkerIsSent(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	port := ln.Addr().(*net.TCPAddr).Port

	got := make(chan string, 1)
	go func() {
		c, err := ln.Accept()
		if err != nil {
			got <- ""
			return
		}
		defer c.Close()
		buf := make([]byte, 64)
		n, _ := c.Read(buf)
		got <- string(buf[:n])
	}()

	_ = ProbePayload("127.0.0.1", port, 1)
	if m := <-got; m != ProbePayloadMarker+"\n" {
		t.Fatalf("marker = %q want %q", m, ProbePayloadMarker+"\n")
	}
}

// --- helpers ----------------------------------------------------------------

func readLog(t *testing.T, stateDir string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(stateDir, "logs", LogFileName))
	if err != nil {
		t.Fatalf("读日志失败: %v", err)
	}
	return string(b)
}

// captureStderr 把 os.Stderr 临时替换成管道，返回期间写入的内容。
func captureStderr(t *testing.T, fn func()) string {
	t.Helper()
	orig := os.Stderr
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	os.Stderr = w
	done := make(chan string, 1)
	go func() {
		var buf bytes.Buffer
		_, _ = buf.ReadFrom(r)
		done <- buf.String()
	}()
	fn()
	_ = w.Close()
	os.Stderr = orig
	return <-done
}

// startServer 启动一个 127.0.0.1 测试服务，返回端口与关闭函数。
//
// mode:
//
//	reply  — 读一行后回 "pong\n"（-> up）
//	silent — 读一行后挂住不应答（-> degraded）
//	close  — 读一行后立刻关闭（-> down，EOF）
func startServer(t *testing.T, mode string, fixedPort int) (int, func()) {
	t.Helper()
	addr := "127.0.0.1:0"
	if fixedPort > 0 {
		addr = "127.0.0.1:" + strconv.Itoa(fixedPort)
	}
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	port := ln.Addr().(*net.TCPAddr).Port

	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go func(c net.Conn) {
				defer c.Close()
				buf := make([]byte, 256)
				_, _ = c.Read(buf)
				switch mode {
				case "reply":
					_, _ = c.Write([]byte("pong\n"))
				case "silent":
					time.Sleep(3 * time.Second)
				case "close":
					// 立即关闭 -> 对端读到 EOF
				}
			}(c)
		}
	}()

	return port, func() { _ = ln.Close() }
}
