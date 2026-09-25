// cli_test.go — internal/cli 的单测（Phase 1 W4）。
//
// 覆盖四类不变量：
//
//  1. dispatch 与退出码契约 C2（未迁移子命令 -> 9，未知子命令/缺子命令 -> 64，
//     version/help -> 0），以及「usage 文本与 bash 逐字节一致」。
//  2. list 三形态（表格 / --json / --oneline）在多种状态夹具上的输出 —— 与 bash
//     实测 golden 逐字节比对（golden 字符串来自本仓库 bin/forward 的实测输出，
//     见 tests/difftest 的差分测试；这里放"便宜"的那部分，防止单测层漏网）。
//  3. 桥接实时合并（session 文件、pending/waiting、client 文件产生的 bridge 行）。
//  4. jq 兼容编码器的细节（数字规范化、字符串转义、键序、--json 的键序）。
package cli

import (
	"bytes"
	"encoding/json"
	"fmt"
	"github.com/zzjcool/herdr-forward/internal/jqjson"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// --- 测试脚手架 -------------------------------------------------------------

// useStateDir 把状态目录指到临时目录，并返回其路径（含 bridge 子目录）。
func useStateDir(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	t.Setenv("HERDR_PLUGIN_STATE_DIR", dir)
	// 清掉可能影响判定的环境变量
	t.Setenv("BRIDGE_LIVE_WINDOW_S", "")
	t.Setenv("FORWARD_STATE_VERSION", "")
	return dir
}

// runCLI 捕获 Main 的 stdout/stderr，返回 (rc, stdout, stderr)。
//
// 为什么不用 os.Pipe：Main 用 fmt.Print 直写 os.Stdout，重定向需要换掉 fd；
// 这里用临时文件交换 —— 简单、可重复。
func runCLI(t *testing.T, args ...string) (int, string, string) {
	t.Helper()
	outF, err := os.CreateTemp(t.TempDir(), "stdout")
	if err != nil {
		t.Fatalf("create stdout temp: %v", err)
	}
	errF, err := os.CreateTemp(t.TempDir(), "stderr")
	if err != nil {
		t.Fatalf("create stderr temp: %v", err)
	}
	oldOut, oldErr := os.Stdout, os.Stderr
	os.Stdout, os.Stderr = outF, errF
	rc := Main(args)
	os.Stdout, os.Stderr = oldOut, oldErr
	_ = outF.Close()
	_ = errF.Close()
	return rc, readFile(t, outF.Name()), readFile(t, errF.Name())
}

func readFile(t *testing.T, path string) string {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	return string(data)
}

// writeState 写 forwards.json（参数是完整文档 JSON）。
func writeState(t *testing.T, stateDir, doc string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(stateDir, "forwards.json"), []byte(doc), 0o600); err != nil {
		t.Fatalf("write state: %v", err)
	}
}

// writeBridge 写 bridge 目录下的文件（0600，目录 0700）。
func writeBridge(t *testing.T, stateDir, name, content string) {
	t.Helper()
	dir := filepath.Join(stateDir, "bridge")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatalf("mkdir bridge: %v", err)
	}
	if err := os.WriteFile(filepath.Join(dir, name), []byte(content), 0o600); err != nil {
		t.Fatalf("write bridge file: %v", err)
	}
}

const (
	fixtureTunnelTwo = `{"version":1,"forwards":[` +
		`{"control_socket":"/x/ctl-f-3000","created_unix":1790000000,"id":"f-3000","local_port":3000,` +
		`"machine":"gpu-box","mode":"tunnel","pid":12345,"publish":{"pid":null,"url":null,"started_unix":null},` +
		`"remote_host":"127.0.0.1","remote_port":9443,"ssh_target":"user@gpu-box.example.com:22","status":"up"},` +
		`{"control_socket":"/x/ctl-f-5173","created_unix":1790000100,"id":"f-5173","local_port":5173,` +
		`"machine":"web-box","mode":"tunnel","pid":23456,"publish":{"pid":null,"url":null,"started_unix":null},` +
		`"remote_host":"127.0.0.1","remote_port":5173,"ssh_target":"deploy@web-box.example.com:22","status":"up"}]}`

	fixtureClientWaiting = `{"version":1,"forwards":[` +
		`{"control_socket":"","created_unix":1,"id":"f-5173","local_port":5173,"machine":"","mode":"client",` +
		`"pid":null,"publish":{"pid":null,"url":null,"started_unix":null},"remote_host":"localhost",` +
		`"remote_port":5173,"ssh_target":"","status":"starting"}]}`

	fixtureEmpty = `{"version":1,"forwards":[]}`
)

// --- 1. dispatch / 退出码 ---------------------------------------------------

func TestDispatchExitCodes(t *testing.T) {
	useStateDir(t)

	cases := []struct {
		name string
		args []string
		want int
	}{
		{"help", []string{"help"}, exitOK},
		{"help flag", []string{"--help"}, exitOK},
		{"help short", []string{"-h"}, exitOK},
		{"version", []string{"version"}, exitOK},
		{"version flag", []string{"--version"}, exitOK},
		{"version short", []string{"-v"}, exitOK},
		{"list", []string{"list"}, exitOK},
		{"list json", []string{"list", "--json"}, exitOK},
		{"ports", []string{"ports"}, exitOK},
		{"internal selftest", []string{"internal", "difftest", "selftest"}, exitOK},
		{"no args", nil, exitUsage},
		{"unknown subcommand", []string{"nope"}, exitUsage},
		{"missing-dash flag", []string{"--nope"}, exitUsage},
	}
	for _, tc := range cases {
		rc, _, _ := runCLI(t, tc.args...)
		if rc != tc.want {
			t.Errorf("Main(%q) = %d, want %d", tc.args, rc, tc.want)
		}
	}

	// 未迁移子命令：一律哨兵 9（绝不静默成功、也不误报用法错误）
	for sub := range unmigrated {
		rc, out, errOut := runCLI(t, sub)
		if rc != exitNotImplemented {
			t.Errorf("Main([%q]) = %d, want %d（未迁移哨兵）", sub, rc, exitNotImplemented)
		}
		if out != "" {
			t.Errorf("Main([%q]) stdout = %q, want 空（哨兵只写 stderr）", sub, out)
		}
		if !strings.Contains(errOut, "尚未迁移") {
			t.Errorf("Main([%q]) stderr = %q, want 含「尚未迁移」", sub, errOut)
		}
	}
}

func TestUnmigratedCoverage(t *testing.T) {
	// 契约 C1 的 15 个子命令：Phase 2 之后 10 个已迁移/内建（add/list/remove/doctor/
	// publish/unpublish/ports/help/version + internal 探针），5 个未迁移
	// （watch/bootstrap 属 Phase 4；machines/bridge/open-url 属 Phase 3）。
	// 这条断言防「漏登记」导致某子命令静默落到 default 分支。
	want := map[string]bool{
		"add": true, "list": true, "remove": true, "doctor": true, "publish": true,
		"unpublish": true, "watch": true, "bootstrap": true, "machines": true,
		"bridge": true, "ports": true, "open-url": true, "help": true, "version": true,
	}
	migrated := map[string]bool{
		"add": true, "list": true, "remove": true, "doctor": true, "publish": true,
		"unpublish": true, "ports": true, "help": true, "version": true,
	}
	for sub := range want {
		if unmigrated[sub] {
			continue
		}
		if !migrated[sub] {
			t.Errorf("子命令 %q 既未迁移也未登记为未迁移", sub)
		}
	}
	if got := len(want); got != 14 {
		t.Fatalf("契约清单长度 = %d, want 14（+internal 探针 = 15）", got)
	}
	if got := len(unmigrated); got != 5 {
		t.Fatalf("未迁移子命令数 = %d, want 5（Phase 2 后）", got)
	}
}

func TestInternalSelftest(t *testing.T) {
	useStateDir(t)
	rc, out, _ := runCLI(t, "internal", "difftest", "selftest")
	if rc != exitOK {
		t.Fatalf("internal difftest selftest rc = %d, want 0", rc)
	}
	if out != "difftest-ok\n" {
		t.Errorf("stdout = %q, want %q", out, "difftest-ok\n")
	}
}

// TestUsageMatchesBash 把 usageText 与 `bash bin/forward help` 的 stdout 逐字节对比。
//
// 这是「help 输出是用户可见契约」的守门测试：usage.go 里的文本必须永远是 bin/forward
// usage() heredoc 的逐字节副本。环境缺 bash/bin/forward 时显式 Skip（不静默通过）。
func TestUsageMatchesBash(t *testing.T) {
	root := repoRoot(t)
	if root == "" {
		t.Skip("找不到仓库根（bin/forward 不在预期位置），跳过与 bash 的字节比对")
	}
	binForward := filepath.Join(root, "bin", "forward")
	if _, err := os.Stat(binForward); err != nil {
		t.Skipf("bin/forward 不存在：%v", err)
	}
	out, err := runCommand("bash", binForward, "help")
	if err != nil {
		t.Skipf("无法执行 bash bin/forward help：%v", err)
	}
	if out != usageText {
		t.Fatalf("usageText 与 bash 输出不一致：go=%q bash=%q（长度 %d vs %d）",
			usageText, out, len(usageText), len(out))
	}
}

func repoRoot(t *testing.T) string {
	t.Helper()
	dir, err := os.Getwd()
	if err != nil {
		return ""
	}
	for i := 0; i < 6; i++ {
		if _, err := os.Stat(filepath.Join(dir, "bin", "forward")); err == nil {
			return dir
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			break
		}
		dir = parent
	}
	return ""
}

// runCommand 跑一条命令并返回 stdout（测试内小工具，避免额外依赖）。
func runCommand(name string, args ...string) (string, error) {
	cmd := exec.Command(name, args...)
	var out bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = io.Discard
	err := cmd.Run()
	return out.String(), err
}

// --- 2. list 三形态 ---------------------------------------------------------

func TestListTableTunnelFixture(t *testing.T) {
	dir := useStateDir(t)
	writeState(t, dir, fixtureTunnelTwo)
	rc, out, errOut := runCLI(t, "list")
	if rc != exitOK {
		t.Fatalf("rc = %d, want 0（stderr=%q）", rc, errOut)
	}
	want := "LOCAL      REMOTE         MACHINE      STATUS     PID      SSH_TARGET\n" +
		"3000       127.0.0.1:9443 gpu-box      up         12345    user@gpu-box.example.com:22\n" +
		"5173       127.0.0.1:5173 web-box      up         23456    deploy@web-box.example.com:22\n"
	if out != want {
		t.Errorf("表格与 bash golden 不一致：\n got: %q\nwant: %q", out, want)
	}
}

func TestListTableEmptyIsHeaderOnly(t *testing.T) {
	dir := useStateDir(t)
	writeState(t, dir, fixtureEmpty)
	rc, out, _ := runCLI(t, "list")
	if rc != exitOK {
		t.Fatalf("rc = %d, want 0", rc)
	}
	want := "LOCAL      REMOTE         MACHINE      STATUS     PID      SSH_TARGET\n"
	if out != want {
		t.Errorf("空状态表格 = %q, want 仅表头", out)
	}
}

func TestListJSONMergesClientState(t *testing.T) {
	dir := useStateDir(t)
	writeState(t, dir, fixtureClientWaiting)
	writeBridge(t, dir, fmt.Sprintf("session-%d.json", os.Getpid()),
		fmt.Sprintf(`{"client_host":"laptop","client_label":"b-box","last_seen_unix":%d,`+
			`"status":{"f-5173":{"state":"up","reason":""}}}`, nowUnix()))

	rc, out, errOut := runCLI(t, "list", "--json")
	if rc != exitOK {
		t.Fatalf("rc = %d, want 0（stderr=%q）", rc, errOut)
	}
	if !strings.HasSuffix(out, "\n") {
		t.Errorf("--json 输出必须以单个换行结尾：%q", out)
	}
	var doc map[string]any
	if err := json.Unmarshal([]byte(out), &doc); err != nil {
		t.Fatalf("--json 不是合法 JSON：%v（%q）", err, out)
	}
	if v, ok := doc["version"].(float64); !ok || v != 1 {
		t.Errorf("version = %v, want 1", doc["version"])
	}
	fw := doc["forwards"].([]any)
	if len(fw) != 1 {
		t.Fatalf("forwards 长度 = %d, want 1", len(fw))
	}
	row := fw[0].(map[string]any)
	if row["status"] != "up" {
		t.Errorf("status = %v, want up（client 实时上报）", row["status"])
	}
	if row["client"] != "laptop" {
		t.Errorf("client = %v, want laptop", row["client"])
	}
	if row["status_reason"] != "" {
		t.Errorf("status_reason = %v, want \"\"", row["status_reason"])
	}
	// 键序：jq -S 的字母序（forwards 在 version 之前）
	if idx := strings.Index(out, `"forwards"`); idx < 0 || idx > strings.Index(out, `"version"`) {
		t.Errorf("--json 顶层键序应字母序（forwards 在 version 前）：%q", out)
	}
}

func TestListJSONWaitingAndPending(t *testing.T) {
	// 无会话 -> waiting
	dir := useStateDir(t)
	writeState(t, dir, fixtureClientWaiting)
	_, out, _ := runCLI(t, "list", "--json")
	if !strings.Contains(out, `"status":"waiting"`) {
		t.Errorf("无 client 在线应 waiting：%q", out)
	}

	// 有 live 会话但该映射未上报 -> pending
	writeBridge(t, dir, fmt.Sprintf("session-%d.json", os.Getpid()),
		fmt.Sprintf(`{"client_host":"laptop","last_seen_unix":%d}`, nowUnix()))
	_, out, _ = runCLI(t, "list", "--json")
	if !strings.Contains(out, `"status":"pending"`) {
		t.Errorf("client 在线但未上报应 pending：%q", out)
	}
}

func TestListOneline(t *testing.T) {
	dir := useStateDir(t)
	writeState(t, dir, fixtureTunnelTwo)
	rc, out, _ := runCLI(t, "list", "--oneline")
	if rc != exitOK {
		t.Fatalf("rc = %d, want 0", rc)
	}
	if out != "⇅3000⇅5173\n" {
		t.Errorf("oneline = %q, want %q", out, "⇅3000⇅5173\n")
	}

	// 全部 down -> 什么都不输出（连换行都没有）
	writeState(t, dir, `{"version":1,"forwards":[{"id":"f-1","local_port":1,"status":"down","mode":"tunnel"}]}`)
	_, out, _ = runCLI(t, "list", "--oneline")
	if out != "" {
		t.Errorf("无 up 记录时 oneline = %q, want 空串（无换行）", out)
	}
}

func TestListOnelineTruncatesAtSix(t *testing.T) {
	dir := useStateDir(t)
	rows := make([]string, 0, 8)
	for i := 1; i <= 8; i++ {
		rows = append(rows, fmt.Sprintf(`{"id":"f-%d","local_port":%d,"status":"up","mode":"tunnel"}`, i, i))
	}
	writeState(t, dir, `{"version":1,"forwards":[`+strings.Join(rows, ",")+`]}`)
	_, out, _ := runCLI(t, "list", "--oneline")
	if out != "⇅1⇅2⇅3⇅4⇅5⇅6+2\n" {
		t.Errorf("oneline 截断 = %q, want ⇅1⇅2⇅3⇅4⇅5⇅6+2", out)
	}
}

func TestListFlagErrors(t *testing.T) {
	useStateDir(t)
	cases := []struct {
		name string
		args []string
		want string
	}{
		{"互斥", []string{"list", "--oneline", "--json"}, "--oneline 与 --json 互斥，请只选一个。"},
		{"互斥反向", []string{"list", "--json", "--oneline"}, "--oneline 与 --json 互斥，请只选一个。"},
		{"未知参数", []string{"list", "--wat"}, "未知参数：--wat。用法：forward list [--oneline] [--json]"},
		{"位置参数", []string{"list", "foo"}, "list 不接受位置参数：foo。用法：forward list [--oneline] [--json]"},
	}
	for _, tc := range cases {
		rc, out, errOut := runCLI(t, tc.args...)
		if rc != exitUsage {
			t.Errorf("%s: rc = %d, want 64", tc.name, rc)
		}
		if out != "" {
			t.Errorf("%s: stdout = %q, want 空", tc.name, out)
		}
		if !strings.Contains(errOut, tc.want) {
			t.Errorf("%s: stderr = %q, want 含 %q", tc.name, errOut, tc.want)
		}
	}
}

func TestListStateVersion(t *testing.T) {
	dir := useStateDir(t)
	writeState(t, dir, fixtureEmpty)

	t.Setenv("FORWARD_STATE_VERSION", "2")
	_, out, _ := runCLI(t, "list", "--json")
	if !strings.Contains(out, `"version":2`) {
		t.Errorf("FORWARD_STATE_VERSION=2 应写入 version:2：%q", out)
	}

	// 非法 JSON：与 jq 一样 rc 2 且 stdout 为空
	t.Setenv("FORWARD_STATE_VERSION", "abc")
	rc, out, errOut := runCLI(t, "list", "--json")
	if rc != exitStateVersionInvalid {
		t.Errorf("非法 FORWARD_STATE_VERSION rc = %d, want %d", rc, exitStateVersionInvalid)
	}
	if out != "" {
		t.Errorf("非法 FORWARD_STATE_VERSION stdout = %q, want 空", out)
	}
	if !strings.Contains(errOut, "FORWARD_STATE_VERSION") {
		t.Errorf("非法 FORWARD_STATE_VERSION 应有可诊断信息：%q", errOut)
	}

	// jq --argjson 的宽松数字形态（Go encoding/json 会拒绝，这里必须接受）
	lenient := map[string]string{"01": "1", "1.": "1", ".5": "0.5", "+1": "1"}
	for in, want := range lenient {
		t.Setenv("FORWARD_STATE_VERSION", in)
		rc, out, _ := runCLI(t, "list", "--json")
		if rc != exitOK {
			t.Errorf("FORWARD_STATE_VERSION=%q rc = %d, want 0", in, rc)
			continue
		}
		if !strings.Contains(out, `"version":`+want) {
			t.Errorf("FORWARD_STATE_VERSION=%q 应规范化成 %s：%q", in, want, out)
		}
	}
}

func TestListCorruptState(t *testing.T) {
	// 非对象元素：bash 的 jq 报错 -> list --json 空 stdout + rc 0；表格只剩表头
	dir := useStateDir(t)
	writeState(t, dir, `{"version":1,"forwards":[1]}`)
	rc, out, _ := runCLI(t, "list", "--json")
	if rc != exitOK || out != "" {
		t.Errorf("非对象记录 list --json = (rc=%d, %q), want (0, 空)", rc, out)
	}
	rc, out, _ = runCLI(t, "list")
	if rc != exitOK || out != "LOCAL      REMOTE         MACHINE      STATUS     PID      SSH_TARGET\n" {
		t.Errorf("非对象记录表格 = (rc=%d, %q), want 仅表头", rc, out)
	}

	// 完全不可解析：warn + 空数组（rc 0）
	writeState(t, dir, `{not json`)
	rc, out, errOut := runCLI(t, "list", "--json")
	if rc != exitOK {
		t.Errorf("损坏状态 rc = %d, want 0", rc)
	}
	if !strings.Contains(out, `"forwards":[]`) {
		t.Errorf("损坏状态应退化为空数组：%q", out)
	}
	if !strings.Contains(errOut, "状态文件不可解析或非对象") {
		t.Errorf("损坏状态应有 warn：%q", errOut)
	}

	// 缺 forwards 键
	writeState(t, dir, `{"version":1}`)
	_, out, errOut = runCLI(t, "list", "--json")
	if !strings.Contains(out, `"forwards":[]`) {
		t.Errorf("缺 forwards 应退化为空数组：%q", out)
	}
	if !strings.Contains(errOut, "状态文件缺少 forwards 数组") {
		t.Errorf("缺 forwards 应有对应 warn：%q", errOut)
	}
}

// --- 3. 桥接实时合并 --------------------------------------------------------

func TestBridgeSelfRows(t *testing.T) {
	dir := useStateDir(t)
	writeState(t, dir, fixtureEmpty)
	pid := os.Getpid()
	writeBridge(t, dir, "client-web-box.json", fmt.Sprintf(
		`{"pid":%d,"machine":"web-box","label":"web-box-label","target":"u@web:22",`+
			`"state":"connected","forwards":{"f-8080":{"spec":"8080 80","state":"up","reason":""},`+
			`"f-9090":{"spec":"9090 90","state":"down","reason":"remote busy"}}}`, pid))
	lock := filepath.Join(dir, "bridge", "client-web-box.lock")
	if err := os.MkdirAll(lock, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(lock, "pid"), []byte(fmt.Sprintf("%d\n", pid)), 0o600); err != nil {
		t.Fatal(err)
	}

	rc, out, errOut := runCLI(t, "list", "--json")
	if rc != exitOK {
		t.Fatalf("rc = %d（stderr=%q）", rc, errOut)
	}
	for _, want := range []string{
		`"id":"f-8080"`, `"local_port":8080`, `"remote_host":"localhost"`, `"remote_port":80`,
		`"machine":"web-box-label"`, `"ssh_target":"u@web:22"`, `"status":"up"`, `"mode":"bridge"`,
		`"id":"f-9090"`, `"remote_port":90`, `"status":"down"`, `"status_reason":"remote busy"`,
	} {
		if !strings.Contains(out, want) {
			t.Errorf("bridge 行缺 %s：%q", want, out)
		}
	}

	// 表格：bridge 行的 MACHINE 列 = "<label>(桥接)"
	_, table, _ := runCLI(t, "list")
	if !strings.Contains(table, "web-box-label(桥接)") {
		t.Errorf("表格缺 bridge 标记：%q", table)
	}
	// oneline 只取 up 的 bridge 行
	_, line, _ := runCLI(t, "list", "--oneline")
	if line != "⇅8080\n" {
		t.Errorf("oneline = %q, want ⇅8080", line)
	}
}

func TestBridgeClientRowNotRunningWhenLockDead(t *testing.T) {
	dir := useStateDir(t)
	writeState(t, dir, fixtureEmpty)
	writeBridge(t, dir, "client-web-box.json", fmt.Sprintf(
		`{"pid":%d,"machine":"web-box","label":"web-box-label","target":"u@web:22",`+
			`"state":"connected","forwards":{"f-8080":{"spec":"8080 80","state":"up","reason":""}}}`, os.Getpid()))
	// 无 .lock/pid -> running=false -> 不产生 bridge 行
	rc, out, _ := runCLI(t, "list", "--json")
	if rc != exitOK {
		t.Fatalf("rc = %d", rc)
	}
	if strings.Contains(out, "f-8080") {
		t.Errorf("supervisor 未运行不应产生 bridge 行：%q", out)
	}
}

func TestBridgeSessionDeadPidRemoved(t *testing.T) {
	dir := useStateDir(t)
	writeState(t, dir, fixtureClientWaiting)
	// pid 999999 几乎不可能是活进程 -> bridge_sessions_json 会删掉该文件
	path := filepath.Join(dir, "bridge", "session-999999.json")
	writeBridge(t, dir, "session-999999.json",
		fmt.Sprintf(`{"client_host":"laptop","last_seen_unix":%d,"status":{"f-5173":{"state":"up"}}}`, nowUnix()))
	_, _, _ = runCLI(t, "list", "--json")
	if _, err := os.Stat(path); err == nil {
		t.Errorf("死 pid 的会话文件应被删除（bash 也这么做）：%s", path)
	}
}

func TestBridgeStaleSessionIsNotLive(t *testing.T) {
	dir := useStateDir(t)
	writeState(t, dir, fixtureClientWaiting)
	writeBridge(t, dir, fmt.Sprintf("session-%d.json", os.Getpid()),
		fmt.Sprintf(`{"client_host":"laptop","last_seen_unix":%d,"status":{"f-5173":{"state":"up"}}}`, nowUnix()-9999))
	_, out, _ := runCLI(t, "list", "--json")
	if !strings.Contains(out, `"status":"waiting"`) {
		t.Errorf("心跳过期应 waiting：%q", out)
	}
}

func TestBridgeLiveWindowEnvOverride(t *testing.T) {
	dir := useStateDir(t)
	writeState(t, dir, fixtureClientWaiting)
	writeBridge(t, dir, fmt.Sprintf("session-%d.json", os.Getpid()),
		fmt.Sprintf(`{"client_host":"laptop","last_seen_unix":%d,"status":{"f-5173":{"state":"up"}}}`, nowUnix()-100))

	t.Setenv("BRIDGE_LIVE_WINDOW_S", "3600")
	_, out, _ := runCLI(t, "list", "--json")
	if !strings.Contains(out, `"status":"up"`) {
		t.Errorf("BRIDGE_LIVE_WINDOW_S=3600 应把 100 秒前的会话视为 live：%q", out)
	}

	t.Setenv("BRIDGE_LIVE_WINDOW_S", "20")
	_, out, _ = runCLI(t, "list", "--json")
	if !strings.Contains(out, `"status":"waiting"`) {
		t.Errorf("窗口 20s 时应 waiting：%q", out)
	}
}

func TestBridgeUpWinsWithinSameId(t *testing.T) {
	dir := useStateDir(t)
	writeState(t, dir, fixtureClientWaiting)

	// 会话文件按 PID 判定存活（且 EPERM 也算死），所以必须用自己起得活的子进程。
	pids := startSleeperProcs(t, 2)
	// 两个会话上报同一 id：一个 down、一个 up -> up 优先（不受会话顺序影响）
	writeBridge(t, dir, fmt.Sprintf("session-%d.json", pids[0]),
		fmt.Sprintf(`{"client_host":"a","last_seen_unix":%d,"status":{"f-5173":{"state":"down","reason":"first"}}}`, nowUnix()+500))
	writeBridge(t, dir, fmt.Sprintf("session-%d.json", pids[1]),
		fmt.Sprintf(`{"client_host":"b","last_seen_unix":%d,"status":{"f-5173":{"state":"up","reason":"second"}}}`, nowUnix()+1000))

	_, out, _ := runCLI(t, "list", "--json")
	if !strings.Contains(out, `"status":"up"`) || !strings.Contains(out, `"status_reason":"second"`) {
		t.Errorf("同 id 多会话时应 up 优先：%q", out)
	}
	if !strings.Contains(out, `"client":"b"`) {
		t.Errorf("应取上报 up 的那个 client：%q", out)
	}
}

// startSleeperProcs 起 n 个必定存活到测试结束的子进程，返回它们的 PID（供会话文件用）。
//
// 为什么需要：bridge_sessions_json 用 `kill -0` 判定会话是否活着，而 EPERM（比如 pid 1
// 属于 root）在 bash 里返回非 0 -> 视为已死并**删掉文件**（见 view.go 的说明）。
func startSleeperProcs(t *testing.T, n int) []int {
	t.Helper()
	pids := make([]int, 0, n)
	for i := 0; i < n; i++ {
		cmd := exec.Command("sleep", "60")
		if err := cmd.Start(); err != nil {
			t.Skipf("无法起 sleep 进程构造 live 会话：%v", err)
		}
		t.Cleanup(func() {
			_ = cmd.Process.Kill()
			_, _ = cmd.Process.Wait()
		})
		pids = append(pids, cmd.Process.Pid)
	}
	return pids
}

// --- 4. ports ---------------------------------------------------------------

func TestPortsExtraArgs(t *testing.T) {
	useStateDir(t)
	// `ports extra` -> 64
	rc, out, errOut := runCLI(t, "ports", "extra")
	if rc != exitUsage {
		t.Errorf("ports extra rc = %d, want 64", rc)
	}
	if out != "" {
		t.Errorf("ports extra stdout = %q, want 空（表头在参数校验之前不打印）", out)
	}
	if !strings.Contains(errOut, "用法：forward ports [--json]") {
		t.Errorf("ports extra stderr = %q", errOut)
	}

	// `ports --json extra` -> rc 0（bash 在多余参数检查之前就返回）
	rc, out, _ = runCLI(t, "ports", "--json", "extra")
	if rc != exitOK {
		t.Errorf("ports --json extra rc = %d, want 0", rc)
	}
	var arr []map[string]any
	if err := json.Unmarshal([]byte(out), &arr); err != nil {
		t.Fatalf("ports --json 不是合法 JSON：%v（%q）", err, out)
	}
}

func TestPortsJSONKeyOrder(t *testing.T) {
	useStateDir(t)
	rc, out, _ := runCLI(t, "ports", "--json")
	if rc != exitOK {
		t.Fatalf("rc = %d", rc)
	}
	// bash 侧没有 -S，键序必须是 port,addr,process（插入顺序）
	if len(strings.TrimSpace(out)) == 0 {
		t.Skip("环境中没有可枚举的监听端口")
	}
	if !strings.HasPrefix(strings.TrimSpace(out), `[{"port":`) {
		t.Errorf("ports --json 键序应以 port 开头：%q", out)
	}
	for _, row := range strings.Split(strings.TrimSpace(out), "},{") {
		for _, key := range []string{`"port":`, `"addr":`, `"process":`} {
			if !strings.Contains(row, key) {
				t.Errorf("ports --json 缺键 %s：%q", key, row)
			}
		}
	}
}

func TestPortsForwardedColumn(t *testing.T) {
	dir := useStateDir(t)
	// 造一条 client 映射：remote_port 9443 -> local_port 5173
	writeState(t, dir, `{"version":1,"forwards":[{"id":"f-5173","local_port":5173,`+
		`"remote_host":"localhost","remote_port":9443,"machine":"","mode":"client",`+
		`"pid":null,"publish":{"pid":null,"url":null,"started_unix":null},"ssh_target":"","status":"up"}]}`)
	m := forwardedMap()
	if got := m["9443"]; got != "5173" {
		t.Errorf("forwardedMap[9443] = %q, want 5173（client:5173）", got)
	}
}

// --- 5. jq 兼容编码器 -------------------------------------------------------

func TestFormatJQNumber(t *testing.T) {
	// golden 全部来自本机 jq 1.8.2 的实测输出（`printf '{"a":N}' | jq -c .`）
	cases := map[string]string{
		"1": "1", "0": "0", "00": "0", "-0": "-0", "0.0": "0.0", "-0.0": "-0.0",
		"2.50": "2.50", "3.0": "3.0", "1.00": "1.00", "0.30000000000000004": "0.30000000000000004",
		"1e3": "1E+3", "1E3": "1E+3", "1e+3": "1E+3", "1.5e3": "1.5E+3",
		"1e-7": "1E-7", "1e-6": "0.000001", "1e-5": "0.00001", "5e-7": "5E-7",
		"10e5": "1.0E+6", "150e-1": "15.0", "0.0000000": "0E-7", "0.000000e0": "0.000000",
		"0.0e5": "0E+4", "1e400": "1E+400", "000.500": "0.500", "12e3": "1.2E+4",
		"100e3": "1.00E+5", "1200e3": "1.200E+6", "0e5": "0E+5", "1e0": "1", "1e2": "1E+2",
		"1000000e-6": "1.000000", "1.0e0": "1.0", "9.999999e-1": "0.9999999",
		"20e-7": "0.0000020", "200e-8": "0.00000200", "10e-8": "1.0E-7", "100e-9": "1.00E-7",
		"1000000e-13": "1.000000E-7", "-1.50": "-1.50", "1234567890123456789012345678901234567890e-40": "0.1234567890123456789012345678901234567890",
	}
	for in, want := range cases {
		if got := jqjson.FormatNumber(in); got != want {
			t.Errorf("jqjson.FormatNumber(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestEncodeJQString(t *testing.T) {
	// golden 来自 jq 的 od 逐字节实测
	cases := map[string]string{
		"plain":    `"plain"`,
		`a"b`:      `"a\"b"`,
		`a\b`:      `"a\\b"`,
		"a\tb":     `"a\tb"`,
		"a\nb":     `"a\nb"`,
		"a\rb":     `"a\rb"`,
		"a\bb":     `"a\bb"`,
		"a\fb":     `"a\fb"`,
		"a\x01b":   `"a\u0001b"`,
		"a\x1fb":   `"a\u001fb"`,
		"a\x7fb":   `"a\u007fb"`,           // DEL 也要转义（Go 的 encoding/json 不转）
		"a<b>&":    `"a<b>&"`,              // jq 不转 < > &
		"a\u2028b": `"a` + "\u2028" + `b"`, // U+2028 原样（Go 会转成 \u2028）
		"中文":       `"中文"`,
		"é":        `"é"`,
	}
	for in, want := range cases {
		if got := jqjson.EncodeString(in); got != want {
			t.Errorf("jqjson.EncodeString(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestEncodeJVOrderAndSorting(t *testing.T) {
	v, err := jqjson.Parse([]byte(`{"b":1,"a":{"d":1,"c":2},"n":1e3,"s":"x"}`))
	if err != nil {
		t.Fatal(err)
	}
	if got, want := jqjson.Encode(v, false), `{"b":1,"a":{"d":1,"c":2},"n":1E+3,"s":"x"}`; got != want {
		t.Errorf("插入顺序编码 = %q, want %q", got, want)
	}
	if got, want := jqjson.Encode(v, true), `{"a":{"c":2,"d":1},"b":1,"n":1E+3,"s":"x"}`; got != want {
		t.Errorf("字母序编码 = %q, want %q", got, want)
	}
}

func TestParseJVRejectsTrailingContent(t *testing.T) {
	if _, err := jqjson.Parse([]byte(`{} {}`)); err == nil {
		t.Error("尾随内容应报错")
	}
	if _, err := jqjson.Parse([]byte(`{`)); err == nil {
		t.Error("截断的 JSON 应报错")
	}
}

func TestJQTruthy(t *testing.T) {
	cases := []struct {
		in   any
		want bool
	}{
		{nil, false}, {false, false}, {true, true}, {jqjson.NumberLiteral("0"), true},
		{"", true}, {[]any{}, true},
	}
	for _, tc := range cases {
		if got := jqjson.Truthy(tc.in); got != tc.want {
			t.Errorf("jqjson.Truthy(%v) = %v, want %v", tc.in, got, tc.want)
		}
	}
}

func nowUnix() int64 {
	return time.Now().Unix()
}
