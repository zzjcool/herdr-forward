// notify_test.go —— internal/notify 的单测（PLAN §8：socket toast + 1s watchdog +
// 永不阻塞调用方）。
//
// 与 bash 版 tests/unit/test_notify.sh 的对位：
//   - payload 是一行合法 JSON、引号被转义；
//   - HERDR_SOCKET_PATH 未设 / 指向不存在的路径 / 指向普通文件 -> 降级到 log 且恒成功；
//   - 卡死的 sink（无人读的 unix socket）-> 在 ~1s 内放弃返回；
//   - 真 unix socket 有读者 -> 投递成功。
package notify

import (
	"bufio"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

func useStateDir(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	t.Setenv("HERDR_PLUGIN_STATE_DIR", dir)
	return dir
}

// readLog 读 forward.log（降级路径的可见证据）。
func readLog(t *testing.T, dir string) string {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(dir, "logs", "forward.log"))
	if err != nil {
		return ""
	}
	return string(data)
}

// mkfifo 建一个命名管道（Go stdlib 无 mkfifo 封装，用 syscall）。
func mkfifo(path string) error {
	return syscall.Mkfifo(path, 0o600)
}

// --- 1. payload --------------------------------------------------------------

func TestPayloadIsValidJSONLine(t *testing.T) {
	got := Payload("Build failed", "port 3000 down")
	var doc map[string]any
	if err := json.Unmarshal([]byte(got), &doc); err != nil {
		t.Fatalf("payload 不是合法 JSON：%v（%q）", err, got)
	}
	if doc["type"] != "toast" || doc["title"] != "Build failed" || doc["body"] != "port 3000 down" {
		t.Errorf("payload 字段不符：%v", doc)
	}
	// 键序与 jq -cn 的插入序一致：type,title,body
	if strings.Index(got, `"type"`) > strings.Index(got, `"title"`) ||
		strings.Index(got, `"title"`) > strings.Index(got, `"body"`) {
		t.Errorf("键序应为 type,title,body：%q", got)
	}
}

func TestPayloadEscaping(t *testing.T) {
	cases := map[string]string{
		`say "hi"`:       `"say \"hi\""`,
		`a\b`:            `"a\\b"`,
		"tab\there":      `"tab\there"`,
		"nl\nhere":       `"nl\nhere"`,
		"cr\rhere":       `"cr\rhere"`,
		"bs\bhere":       `"bs\bhere"`,
		"ff\fhere":       `"ff\fhere"`,
		"ctl\x01here":    `"ctl\u0001here"`,
		"del\x7fhere":    `"del\u007fhere"`,
		"html<>&here":    `"html<>&here"`, // jq 不转义 < > &
		"u2028\u2028end": "\"u2028\u2028end\"",
	}
	for in, want := range cases {
		got := Payload(in, "")
		if !strings.Contains(got, `"title":`+want) {
			t.Errorf("Payload(%q) title 部分 = %q, want 含 %q", in, got, want)
		}
	}
}

// --- 2. Toast 降级路径（恒成功、永不 panic） ---------------------------------

func TestToastDegradesWithoutSocketEnv(t *testing.T) {
	dir := useStateDir(t)
	t.Setenv("HERDR_SOCKET_PATH", "")
	if err := Toast("Title A", "Body A"); err != nil {
		t.Fatalf("Toast 必须恒返回 nil：%v", err)
	}
	log := readLog(t, dir)
	if !strings.Contains(log, "notify: Title A — Body A") {
		t.Errorf("降级应把消息写进日志：%q", log)
	}
}

func TestToastDegradesOnNonexistentPath(t *testing.T) {
	dir := useStateDir(t)
	t.Setenv("HERDR_SOCKET_PATH", filepath.Join(dir, "does-not-exist.sock"))
	if err := Toast("Title B", "Body B"); err != nil {
		t.Fatalf("Toast 必须恒返回 nil：%v", err)
	}
	if log := readLog(t, dir); !strings.Contains(log, "Title B") {
		t.Errorf("降级应把消息写进日志：%q", log)
	}
}

func TestToastDegradesOnRegularFile(t *testing.T) {
	dir := useStateDir(t)
	path := filepath.Join(dir, "regular.file")
	if err := os.WriteFile(path, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("HERDR_SOCKET_PATH", path)
	if err := Toast("Title C", "Body C"); err != nil {
		t.Fatalf("Toast 必须恒返回 nil：%v", err)
	}
	if log := readLog(t, dir); !strings.Contains(log, "Title C") {
		t.Errorf("普通文件不是 socket -> 应降级到 log：%q", log)
	}
}

func TestToastNoArgsIsSafe(t *testing.T) {
	dir := useStateDir(t)
	t.Setenv("HERDR_SOCKET_PATH", "")
	if err := Toast("", ""); err != nil {
		t.Fatalf("无参 Toast 必须恒返回 nil：%v", err)
	}
	if log := readLog(t, dir); !strings.Contains(log, "notify: \n") {
		t.Errorf("空标题也应写一条 log info：%q", log)
	}
}

// --- 3. 真 unix socket 投递 ---------------------------------------------------

func TestToastDeliversToUnixSocket(t *testing.T) {
	dir := useStateDir(t)
	sock := filepath.Join(dir, "herdr.sock")
	ln, err := net.Listen("unix", sock)
	if err != nil {
		t.Skipf("无法监听 unix socket：%v", err)
	}
	defer func() { _ = ln.Close() }()

	type result struct {
		line string
		err  error
	}
	ch := make(chan result, 1)
	go func() {
		conn, err := ln.Accept()
		if err != nil {
			ch <- result{err: err}
			return
		}
		defer func() { _ = conn.Close() }()
		line, err := bufio.NewReader(conn).ReadString('\n')
		ch <- result{line: strings.TrimRight(line, "\n"), err: err}
	}()

	t.Setenv("HERDR_SOCKET_PATH", sock)
	if err := Toast("Toast T", "Toast B"); err != nil {
		t.Fatalf("Toast 返回 %v", err)
	}

	select {
	case got := <-ch:
		if got.err != nil {
			t.Fatalf("读取投递内容失败：%v", got.err)
		}
		if got.line != Payload("Toast T", "Toast B") {
			t.Errorf("投递内容 = %q, want %q", got.line, Payload("Toast T", "Toast B"))
		}
	case <-time.After(3 * time.Second):
		t.Fatal("socket 端未收到投递（超时）")
	}

	log := readLog(t, dir)
	if !strings.Contains(log, "notify: toast sent via "+sock) {
		t.Errorf("成功投递应记 debug 行：%q", log)
	}
	if strings.Contains(log, "notify: Toast T") {
		t.Errorf("成功投递不应再降级到 log info：%q", log)
	}
}

// --- 4. 有界（卡死的 sink） ----------------------------------------------------

func TestSendBoundedOnFIFOWithNoReader(t *testing.T) {
	dir := useStateDir(t)
	fifo := filepath.Join(dir, "blocking.fifo")
	if err := mkfifo(fifo); err != nil {
		t.Skipf("无法创建 FIFO：%v", err)
	}

	start := time.Now()
	// 无人读的 FIFO：connect(2) 在 FIFO 上直接失败（ENXIO），故 Send 应当很快
	// 返回错误而不是挂住；具体上限由 DialTimeout（1s）+ 写 deadline（1s）共同保证。
	// 这里既断言有界，也断言「报错而不是假装投递成功」—— 后者才会让 Toast 错误地
	// 跳过大 log 降级。
	if err := Send(fifo, `{"type":"toast"}`); err == nil {
		t.Errorf("无人读的 FIFO 不应报投递成功")
	}
	elapsed := time.Since(start)
	if elapsed > 3*time.Second {
		t.Errorf("Send 在无人读的 FIFO 上阻塞了 %v（应 ≤ ~1s）", elapsed)
	}
}
