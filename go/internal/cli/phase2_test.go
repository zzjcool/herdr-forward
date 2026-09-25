// phase2_test.go —— Phase 2 新增子命令（add / remove / doctor / publish / unpublish）
// 的 cli 层单测。
//
// 这里放「便宜」的那部分（参数校验、退出码、文案、落盘字段），真实隧道行为
// （起 ssh、-O exit、reap socket）由 tests/integration 与 E2E 裁判 —— 与 difftest
// 组 9/10 的分工一致（那条线跑的是真 Go CLI 与 staged bash 的逐字节对位）。
package cli

import (
	"fmt"
	"os"
	"strings"
	"testing"

	"github.com/zzjcool/herdr-forward/internal/state"
)

// --- add：参数/端口校验（全部零副作用） --------------------------------------

func TestAddArgErrors(t *testing.T) {
	useStateDir(t)
	cases := []struct {
		name string
		args []string
		want string
		code int
	}{
		{"缺 spec", []string{"add"}, "缺少 <local>:<remote> 参数", exitUsage},
		{"非法 spec", []string{"add", "5173:x"}, "端口格式非法：5173:x", exitUsage},
		{"多冒号", []string{"add", "1:2:3"}, "端口格式非法：1:2:3", exitUsage},
		{"本地端口 0", []string{"add", "0"}, "本地端口越界（1-65535）：0", exitUsage},
		{"远端端口越界", []string{"add", "3000:70000"}, "远端端口越界（1-65535）：70000", exitUsage},
		{"未知参数", []string{"add", "5173", "--wat"}, "未知参数：--wat", exitUsage},
		{"多余位置参数", []string{"add", "5173", "5173"}, "只接受一个 <local>:<remote> 参数", exitUsage},
		{"缺目标机器", []string{"add", "3000"}, "缺少目标机器", exitMachineResolve},
		{"machine 无法解析", []string{"add", "3000", "--machine", "nope"}, "无法解析 machine 'nope'", exitMachineResolve},
		{"--machine 缺值", []string{"add", "3000", "--machine"}, "--machine 需要一个 LABEL 值", exitUsage},
		{"--ssh-target 缺值", []string{"add", "3000", "--ssh-target"}, "--ssh-target 需要一个 TARGET 值", exitUsage},
		{"client 端口 <1024", []string{"add", "80", "--client"}, "client 映射的本地端口需 ≥ 1024", exitUsage},
		{"client 与 ssh-target 互斥", []string{"add", "6000", "--client", "--ssh-target", "u@h:22"}, "--client 与 --machine/--ssh-target 互斥", exitUsage},
	}
	for _, tc := range cases {
		rc, out, errOut := runCLI(t, tc.args...)
		if rc != tc.code {
			t.Errorf("%s: rc = %d, want %d", tc.name, rc, tc.code)
		}
		if out != "" {
			t.Errorf("%s: stdout = %q, want 空", tc.name, out)
		}
		if !strings.Contains(errOut, tc.want) {
			t.Errorf("%s: stderr = %q, want 含 %q", tc.name, errOut, tc.want)
		}
	}
}

func TestAddClientRecordsWaitingWithoutLiveClient(t *testing.T) {
	useStateDir(t)
	rc, out, errOut := runCLI(t, "add", "5173", "--client")
	if rc != exitOK {
		t.Fatalf("rc = %d（stderr=%q）", rc, errOut)
	}
	if out != "f-5173\n" {
		t.Errorf("stdout = %q, want f-5173", out)
	}
	if !strings.Contains(errOut, "已登记：client 的 localhost:5173 → 本机 localhost:5173。") {
		t.Errorf("stderr 缺登记提示：%q", errOut)
	}
	if !strings.Contains(errOut, "没有 client 连着") {
		t.Errorf("stderr 应提示连上后自动生效：%q", errOut)
	}
	recs, _ := state.Load()
	if len(recs) != 1 {
		t.Fatalf("记录数 = %d, want 1", len(recs))
	}
	rec := recs[0]
	if rec.Mode != state.ModeClient || rec.RemoteHost != "localhost" || rec.RemotePort != 5173 ||
		rec.SshTarget != "" || rec.ControlSocket != "" {
		t.Errorf("client 记录字段不符 bash：%+v", rec)
	}
}

func TestAddDuplicatePortExits2(t *testing.T) {
	dir := useStateDir(t)
	writeState(t, dir, fixtureTunnelTwo) // 含 f-3000
	rc, out, errOut := runCLI(t, "add", "3000:9443", "--ssh-target", "u@h:22")
	if rc != exitDuplicatePort {
		t.Fatalf("rc = %d, want 2", rc)
	}
	if out != "" {
		t.Errorf("stdout = %q, want 空", out)
	}
	want := "本地端口 3000 已被占用（记录 f-3000 已存在）。请先 forward list 查看，或用 forward remove f-3000 删除后再 add。"
	if !strings.Contains(errOut, want) {
		t.Errorf("stderr = %q, want 含 %q", errOut, want)
	}
}

// --- remove ----------------------------------------------------------------

func TestRemoveArgForms(t *testing.T) {
	useStateDir(t)
	cases := []struct {
		name string
		args []string
		code int
		want string
	}{
		{"缺 id", []string{"remove"}, exitUsage, "缺少 <id>。用法：forward remove f-3000"},
		{"未知参数", []string{"remove", "--wat"}, exitUsage, "未知参数：--wat。用法：forward remove <id>"},
		{"多余参数", []string{"remove", "f-3000", "extra"}, exitUsage, "remove 只接受一个 <id>（收到额外：extra）"},
		{"--pick 未实现", []string{"remove", "--pick"}, exitNotImplemented, "forward remove --pick 交互选择为一期未实现（二期）"},
		{"--all 未实现", []string{"remove", "--all"}, exitNotImplemented, "forward remove --all 为二期未实现（防误删）"},
	}
	for _, tc := range cases {
		rc, out, errOut := runCLI(t, tc.args...)
		if rc != tc.code {
			t.Errorf("%s: rc = %d, want %d", tc.name, rc, tc.code)
		}
		if out != "" {
			t.Errorf("%s: stdout = %q, want 空", tc.name, out)
		}
		if !strings.Contains(errOut, tc.want) {
			t.Errorf("%s: stderr = %q, want 含 %q", tc.name, errOut, tc.want)
		}
	}
}

func TestRemoveMissingRecordExits3(t *testing.T) {
	dir := useStateDir(t)
	writeState(t, dir, fixtureTunnelTwo)
	rc, _, errOut := runCLI(t, "remove", "f-nope")
	if rc != exitNotFound {
		t.Fatalf("rc = %d, want 3", rc)
	}
	if !strings.Contains(errOut, "记录不存在：f-nope") {
		t.Errorf("stderr = %q", errOut)
	}
}

func TestRemoveClientRecordOnly(t *testing.T) {
	dir := useStateDir(t)
	writeState(t, dir, fixtureClientWaiting) // f-5173 mode=client
	rc, out, errOut := runCLI(t, "remove", "f-5173")
	if rc != exitOK {
		t.Fatalf("rc = %d（stderr=%q）", rc, errOut)
	}
	if out != "" {
		t.Errorf("stdout = %q, want 空（bash 不打印）", out)
	}
	recs, _ := state.Load()
	if len(recs) != 0 {
		t.Errorf("client 记录应已删除：%+v", recs)
	}
}

// --- doctor ----------------------------------------------------------------

func TestDoctorArgErrors(t *testing.T) {
	useStateDir(t)
	rc, _, errOut := runCLI(t, "doctor", "--wat")
	if rc != exitUsage || !strings.Contains(errOut, "未知参数：--wat。用法：forward doctor [--fix] [--prune]") {
		t.Errorf("doctor --wat = (rc=%d, %q)", rc, errOut)
	}
	rc, _, errOut = runCLI(t, "doctor", "xyz")
	if rc != exitUsage || !strings.Contains(errOut, "doctor 不接受位置参数：xyz。") {
		t.Errorf("doctor xyz = (rc=%d, %q)", rc, errOut)
	}
}

func TestDoctorClientRecordRow(t *testing.T) {
	dir := useStateDir(t)
	writeState(t, dir, fixtureClientWaiting) // f-5173 mode=client, status=starting
	rc, out, errOut := runCLI(t, "doctor")
	if rc != exitOK {
		t.Fatalf("rc = %d（stderr=%q）", rc, errOut)
	}
	// 无 client 在线 -> waiting 行（隧道部分跳过该记录）
	want := "f-5173\t5173\tclient:waiting\t(没有 client 连着；client 连上后自动生效)\n"
	if out != want {
		t.Errorf("doctor 输出 = %q, want %q", out, want)
	}
}

func TestDoctorClientRecordPendingAndReason(t *testing.T) {
	dir := useStateDir(t)

	// client 在线但未回报 -> pending
	writeState(t, dir, fixtureClientWaiting)
	writeBridge(t, dir, fmt.Sprintf("session-%d.json", os.Getpid()),
		fmt.Sprintf(`{"client_host":"laptop","last_seen_unix":%d}`, nowUnix()))
	_, out, _ := runCLI(t, "doctor")
	if !strings.Contains(out, "client:pending\t(client 在线，等待其回报)") {
		t.Errorf("pending 行不符：%q", out)
	}

	// client 回报 status_reason -> 用 reason 渲染
	writeBridge(t, dir, fmt.Sprintf("session-%d.json", os.Getpid()),
		fmt.Sprintf(`{"client_host":"laptop","last_seen_unix":%d,"status":{"f-5173":{"state":"down","reason":"client 端口 5173 已被占用（laptop）"}}}`, nowUnix()))
	_, out, _ = runCLI(t, "doctor")
	if !strings.Contains(out, "(client 端口 5173 已被占用（laptop）)") {
		t.Errorf("reason 行不符：%q", out)
	}
}

func TestDoctorNeverPrunesClientRecords(t *testing.T) {
	dir := useStateDir(t)
	writeState(t, dir, fixtureClientWaiting)
	rc, _, _ := runCLI(t, "doctor", "--prune")
	if rc != exitOK {
		t.Fatalf("rc = %d", rc)
	}
	recs, _ := state.Load()
	if len(recs) != 1 {
		t.Errorf("--prune 不得删 client 记录：%+v", recs)
	}
}

// --- publish / unpublish ----------------------------------------------------

func TestPublishUnpublishExit9(t *testing.T) {
	useStateDir(t)
	cases := []struct {
		args []string
		want string
	}{
		{[]string{"publish", "3000"}, "forward publish 为二期（Cloudflare quick tunnel）未实现。一期请用 'forward add' 建立 ssh -L 本地转发。"},
		{[]string{"publish"}, "forward publish 为二期（Cloudflare quick tunnel）未实现。"},
		{[]string{"publish", "3000", "extra"}, "forward publish 为二期（Cloudflare quick tunnel）未实现。"},
		{[]string{"unpublish"}, "forward unpublish 为二期未实现。"},
		{[]string{"unpublish", "3000"}, "forward unpublish 为二期未实现。"},
	}
	for _, tc := range cases {
		rc, out, errOut := runCLI(t, tc.args...)
		if rc != exitNotImplemented {
			t.Errorf("%v: rc = %d, want 9", tc.args, rc)
		}
		if out != "" {
			t.Errorf("%v: stdout = %q, want 空", tc.args, out)
		}
		if !strings.Contains(errOut, tc.want) {
			t.Errorf("%v: stderr = %q, want 含 %q", tc.args, errOut, tc.want)
		}
	}
}

// --- setPid（cmd_add 的写盘顺序） ---------------------------------------------

func TestSetPidWritesAndKeepsOtherFields(t *testing.T) {
	dir := useStateDir(t)
	writeState(t, dir, fixtureTunnelTwo)
	if code := setPid("f-3000", 4242); code != exitOK {
		t.Fatalf("setPid rc = %d", code)
	}
	recs, _ := state.Load()
	for _, rec := range recs {
		if rec.ID != "f-3000" {
			continue
		}
		if rec.Pid == nil || *rec.Pid != 4242 {
			t.Errorf("pid = %v, want 4242", rec.Pid)
		}
		if rec.Status != "up" || rec.SshTarget != "user@gpu-box.example.com:22" {
			t.Errorf("其它字段不应被改动：%+v", rec)
		}
	}
	// 不存在的 id -> 3
	if code := setPid("f-nope", 1); code != exitNotFound {
		t.Errorf("setPid 不存在 = %d, want 3", code)
	}
}
