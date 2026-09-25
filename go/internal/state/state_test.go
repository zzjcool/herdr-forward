// state_test.go — PLAN-GO-MIGRATION §8 要求的 state 单测。
//
// 覆盖：4 个现有 fixture 的 Load 矩阵、Save 的 **逐字节** golden（jq -S -c 形态）、
// 旧记录缺 mode → tunnel、损坏 → 空+warn、Add/重复端口、Remove/不存在、
// SetStatus/非法 status。
//
// golden 字符串是直接照抄 bash+jq 的实测输出（命令见 tests/difftest/README.md），
// 不依赖 jq 二进制，因此本测试在无 jq 的机器上也能跑。
package state

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/zzjcool/herdr-forward/internal/hfcommon"
)

// fixtureDir 指向仓库的 tests/fixtures（只读复用，PLAN §8 明确要求）。
func fixtureDir(t *testing.T) string {
	t.Helper()
	// go/internal/state -> ../../../tests/fixtures
	dir, err := filepath.Abs("../../../tests/fixtures")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(dir); err != nil {
		t.Fatalf("fixtures 目录不可达: %v", err)
	}
	return dir
}

// useStateDir 把状态目录指到临时目录，返回该目录。
func useStateDir(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	t.Setenv("HERDR_PLUGIN_STATE_DIR", dir)
	return dir
}

// installFixture 把某个 fixture 拷成状态文件。
func installFixture(t *testing.T, name string) {
	t.Helper()
	src := filepath.Join(fixtureDir(t), name)
	data, err := os.ReadFile(src)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(FilePath(), data, 0o644); err != nil {
		t.Fatal(err)
	}
}

func readStateFile(t *testing.T) []byte {
	t.Helper()
	b, err := os.ReadFile(FilePath())
	if err != nil {
		t.Fatal(err)
	}
	return b
}

// --- Load 矩阵（4 个 fixture） ----------------------------------------------

func TestLoadMissingFileIsEmpty(t *testing.T) {
	useStateDir(t)
	fw, err := Load()
	if err != nil {
		t.Fatalf("err=%v want nil", err)
	}
	if len(fw) != 0 {
		t.Fatalf("want 空切片，得到 %d 条", len(fw))
	}
}

func TestLoadValidFixture(t *testing.T) {
	useStateDir(t)
	installFixture(t, "forwards.valid.json")

	fw, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if len(fw) != 1 {
		t.Fatalf("want 1 条，得到 %d", len(fw))
	}
	f := fw[0]
	if f.ID != "f-3000" || f.LocalPort != 3000 || f.Status != "up" || f.Machine != "gpu-box" {
		t.Fatalf("字段不符: %+v", f)
	}
	if f.Mode != ModeTunnel {
		t.Fatalf("缺 mode 应归一为 tunnel，得到 %q", f.Mode)
	}
	if f.Pid == nil || *f.Pid != 12345 {
		t.Fatalf("pid 应可解，得到 %v", f.Pid)
	}
}

func TestLoadMultiFixture(t *testing.T) {
	useStateDir(t)
	installFixture(t, "forwards.multi.json")

	fw, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if len(fw) != 2 {
		t.Fatalf("want 2 条，得到 %d", len(fw))
	}
	if fw[0].ID != "f-5173" || fw[1].ID != "f-3000" {
		t.Fatalf("顺序/ID 不符: %s %s", fw[0].ID, fw[1].ID)
	}
	for _, f := range fw {
		if f.Mode != ModeTunnel {
			t.Fatalf("缺 mode 应归一为 tunnel: %s -> %q", f.ID, f.Mode)
		}
	}
}

func TestLoadEmptyFixture(t *testing.T) {
	useStateDir(t)
	installFixture(t, "forwards.empty.json")

	fw, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if len(fw) != 0 {
		t.Fatalf("want 0 条，得到 %d", len(fw))
	}
}

// 缺字段 fixture：缺 mode 归一为 tunnel，其余字段取零值。
func TestLoadMissingFieldsFixture(t *testing.T) {
	useStateDir(t)
	installFixture(t, "forwards.missing_fields.json")

	fw, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if len(fw) != 2 {
		t.Fatalf("want 2 条，得到 %d", len(fw))
	}
	if fw[0].ID != "f-8080" || fw[0].Status != "up" || fw[0].LocalPort != 8080 {
		t.Fatalf("第一条不符: %+v", fw[0])
	}
	if fw[0].Mode != ModeTunnel {
		t.Fatalf("mode 应归一 tunnel: %q", fw[0].Mode)
	}
	// 第二条无 id/status -> 零值
	if fw[1].ID != "" || fw[1].Status != "" || fw[1].LocalPort != 9090 {
		t.Fatalf("第二条不符: %+v", fw[1])
	}
}

// 损坏 fixture：warn + 空切片 + nil error，且原文件不被覆盖。
func TestLoadCorruptFixture(t *testing.T) {
	useStateDir(t)
	installFixture(t, "forwards.corrupt.json")
	before, _ := os.ReadFile(FilePath())

	fw, err := Load()
	if err != nil {
		t.Fatalf("损坏应不报错，得到 %v", err)
	}
	if len(fw) != 0 {
		t.Fatalf("want 空，得到 %d", len(fw))
	}
	after, _ := os.ReadFile(FilePath())
	if !bytes.Equal(before, after) {
		t.Fatal("Load 不应改动原文件")
	}
}

// 顶层非对象 / 缺 forwards 键 / forwards 非数组 —— 三种都要降级空 + 不报错。
func TestLoadDegradesOnBadShapes(t *testing.T) {
	cases := map[string]string{
		"顶层是标量":        `123`,
		"顶层是数组":        `[]`,
		"缺 forwards 键": `{"version":1}`,
		"forwards 非数组": `{"version":1,"forwards":{"a":1}}`,
		"空文件":          ``,
	}
	for name, body := range cases {
		t.Run(name, func(t *testing.T) {
			useStateDir(t)
			if err := os.WriteFile(FilePath(), []byte(body), 0o644); err != nil {
				t.Fatal(err)
			}
			fw, err := Load()
			if err != nil {
				t.Fatalf("err=%v want nil", err)
			}
			if len(fw) != 0 {
				t.Fatalf("want 空，得到 %d", len(fw))
			}
		})
	}
}

// --- Save 逐字节 golden ------------------------------------------------------

// 这四条 golden 是 bash+jq 的实测输出（jq -S -c --argjson v 1 '{version:$v,forwards:.}'）。
const (
	goldenEmpty = `{"forwards":[],"version":1}` + "\n"

	goldenSingle = `{"forwards":[{"control_socket":"/home/u/.local/state/herdr-forward/ssh-ctl/ctl-f-3000","created_unix":1790000000,"id":"f-3000","local_port":3000,"machine":"gpu-box","mode":"tunnel","pid":12345,"publish":{"pid":null,"started_unix":null,"url":null},"remote_host":"127.0.0.1","remote_port":3000,"ssh_target":"user@gpu-box.example.com:22","status":"up"}],"version":1}` + "\n"

	goldenMulti = `{"forwards":[{"control_socket":"/home/u/.local/state/herdr-forward/ssh-ctl/ctl-f-5173","created_unix":1790000100,"id":"f-5173","local_port":5173,"machine":"web-box","mode":"tunnel","pid":23456,"publish":{"pid":null,"started_unix":null,"url":null},"remote_host":"127.0.0.1","remote_port":5173,"ssh_target":"deploy@web-box.example.com:22","status":"up"},{"control_socket":"/home/u/.local/state/herdr-forward/ssh-ctl/ctl-f-3000","created_unix":1790000000,"id":"f-3000","local_port":3000,"machine":"gpu-box","mode":"tunnel","pid":12345,"publish":{"pid":null,"started_unix":null,"url":null},"remote_host":"127.0.0.1","remote_port":9443,"ssh_target":"user@gpu-box.example.com:22","status":"down"}],"version":1}` + "\n"
)

// Save(Load(fixture)) 必须逐字节等于 jq 形态（round-trip 契约，PLAN §8）。
func TestSaveRoundTripByteEqualsJQ(t *testing.T) {
	cases := []struct {
		fixture string
		golden  string
	}{
		{"forwards.empty.json", goldenEmpty},
		{"forwards.valid.json", goldenSingle},
		{"forwards.multi.json", goldenMulti},
	}
	for _, tc := range cases {
		t.Run(tc.fixture, func(t *testing.T) {
			useStateDir(t)
			installFixture(t, tc.fixture)

			fw, err := Load()
			if err != nil {
				t.Fatal(err)
			}
			if err := Save(fw); err != nil {
				t.Fatal(err)
			}
			got := readStateFile(t)
			if string(got) != tc.golden {
				t.Fatalf("字节不符\n got: %s\nwant: %s", got, tc.golden)
			}
		})
	}
}

// Save 必须紧凑（单行）、结尾一个换行、无 HTML 转义。
func TestSaveCompactSingleLineNoHTMLEscape(t *testing.T) {
	useStateDir(t)
	url := "https://a.example.com/?x=1&y=2"
	if err := Save([]Forward{{
		ID: "f-9000", LocalPort: 9000, Status: "up",
		RemoteHost: "127.0.0.1", RemotePort: 9000,
		Publish: Publish{URL: &url},
	}}); err != nil {
		t.Fatal(err)
	}
	got := string(readStateFile(t))
	if n := strings.Count(got, "\n"); n != 1 || !strings.HasSuffix(got, "\n") {
		t.Fatalf("应为单行 + 单个结尾换行，实际换行数 %d: %q", n, got)
	}
	if strings.Contains(got, `\u0026`) || strings.Contains(got, `\u003c`) {
		t.Fatalf("不应 HTML 转义（jq 不转义）: %s", got)
	}
	if !strings.Contains(got, "https://a.example.com/?x=1&y=2") {
		t.Fatalf("URL 应按原样输出: %s", got)
	}
	// publish 键序必须是 pid, started_unix, url
	if !strings.Contains(got, `"publish":{"pid":null,"started_unix":null,"url":"https://a.example.com/?x=1&y=2"}`) {
		t.Fatalf("publish 键序不符（应 pid/started_unix/url）: %s", got)
	}
}

func TestSaveEmptySliceNotNil(t *testing.T) {
	useStateDir(t)
	if err := Save(nil); err != nil {
		t.Fatal(err)
	}
	if got := string(readStateFile(t)); got != goldenEmpty {
		t.Fatalf("nil 切片应写空数组: %q", got)
	}
}

// --- Add / Remove / SetStatus ----------------------------------------------

func TestAddNormalizesLikeBash(t *testing.T) {
	useStateDir(t)
	// 固定 created_unix 以得到确定字节（bash 用 now_unix，此处显式给）。
	rec := Forward{
		LocalPort:     3000,
		RemotePort:    9443,
		Machine:       "m",
		SshTarget:     "u@h:22",
		ControlSocket: "/tmp/ctl",
		Status:        "starting",
		CreatedUnix:   1790000000,
		Pid:           ptrInt(12345),
	}
	if err := Add(rec); err != nil {
		t.Fatal(err)
	}
	fw, _ := Load()
	if len(fw) != 1 {
		t.Fatalf("want 1 条，得到 %d", len(fw))
	}
	f := fw[0]
	if f.ID != "f-3000" {
		t.Fatalf("id 应为 f-3000: %q", f.ID)
	}
	if f.RemoteHost != "127.0.0.1" {
		t.Fatalf("remote_host 默认应为 127.0.0.1: %q", f.RemoteHost)
	}
	if f.Mode != ModeTunnel {
		t.Fatalf("mode 默认应为 tunnel: %q", f.Mode)
	}
	if f.Publish.Pid != nil || f.Publish.URL != nil || f.Publish.StartedUnix != nil {
		t.Fatalf("publish 应为占位 null: %+v", f.Publish)
	}
	want := `{"forwards":[{"control_socket":"/tmp/ctl","created_unix":1790000000,"id":"f-3000","local_port":3000,"machine":"m","mode":"tunnel","pid":12345,"publish":{"pid":null,"started_unix":null,"url":null},"remote_host":"127.0.0.1","remote_port":9443,"ssh_target":"u@h:22","status":"starting"}],"version":1}` + "\n"
	if got := string(readStateFile(t)); got != want {
		t.Fatalf("Add 落盘字节不符\n got: %s\nwant: %s", got, want)
	}
}

func TestAddDefaultsRemotePortAndStatus(t *testing.T) {
	useStateDir(t)
	if err := Add(Forward{LocalPort: 8080}); err != nil {
		t.Fatal(err)
	}
	fw, _ := Load()
	if fw[0].RemotePort != 8080 {
		t.Fatalf("remote_port 应默认 = local_port: %d", fw[0].RemotePort)
	}
	if fw[0].Status != "starting" {
		t.Fatalf("status 应默认 starting: %q", fw[0].Status)
	}
	if fw[0].CreatedUnix == 0 {
		t.Fatal("created_unix 应补 now")
	}
}

func TestAddClientModePreserved(t *testing.T) {
	useStateDir(t)
	if err := Add(Forward{LocalPort: 13000, RemotePort: 9443, RemoteHost: "localhost", Mode: ModeClient, Status: "starting"}); err != nil {
		t.Fatal(err)
	}
	fw, _ := Load()
	if fw[0].Mode != ModeClient {
		t.Fatalf("client 模式应保留: %q", fw[0].Mode)
	}
}

func TestAddDuplicatePort(t *testing.T) {
	useStateDir(t)
	if err := Add(Forward{LocalPort: 3000}); err != nil {
		t.Fatal(err)
	}
	err := Add(Forward{LocalPort: 3000})
	if !errors.Is(err, ErrDuplicatePort) {
		t.Fatalf("重复端口应 ErrDuplicatePort，得到 %v", err)
	}
	// 不覆盖：仍只有 1 条
	fw, _ := Load()
	if len(fw) != 1 {
		t.Fatalf("重复 add 不应写入，现有 %d 条", len(fw))
	}
}

func TestAddDuplicateIDWithoutSamePort(t *testing.T) {
	useStateDir(t)
	// 手工造一条 id=f-3000 但 local_port=4000 的记录（bash 判据是 id 或 port）。
	if err := Save([]Forward{{ID: "f-3000", LocalPort: 4000, Status: "up", Mode: ModeTunnel}}); err != nil {
		t.Fatal(err)
	}
	err := Add(Forward{LocalPort: 3000})
	if !errors.Is(err, ErrDuplicatePort) {
		t.Fatalf("id 冲突应 ErrDuplicatePort，得到 %v", err)
	}
}

func TestAddInvalidPort(t *testing.T) {
	useStateDir(t)
	for _, p := range []int{0, -1, 65536, 70000} {
		if err := Add(Forward{LocalPort: p}); !errors.Is(err, ErrInvalidPort) {
			t.Fatalf("port %d 应 ErrInvalidPort，得到 %v", p, err)
		}
	}
}

func TestRemove(t *testing.T) {
	useStateDir(t)
	installFixture(t, "forwards.multi.json")

	if err := Remove("f-5173"); err != nil {
		t.Fatal(err)
	}
	fw, _ := Load()
	if len(fw) != 1 || fw[0].ID != "f-3000" {
		t.Fatalf("删除后应只剩 f-3000: %+v", fw)
	}
	// 落盘也应是版本化文档
	if got := string(readStateFile(t)); !strings.HasPrefix(got, `{"forwards":[{"control_socket":"/home/u/`) {
		t.Fatalf("落盘形态不符: %s", got)
	}
}

func TestRemoveNotFound(t *testing.T) {
	useStateDir(t)
	installFixture(t, "forwards.valid.json")
	if err := Remove("f-nope"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("应 ErrNotFound，得到 %v", err)
	}
}

func TestRemoveEmptyID(t *testing.T) {
	useStateDir(t)
	if err := Remove(""); !errors.Is(err, ErrInvalidID) {
		t.Fatalf("应 ErrInvalidID，得到 %v", err)
	}
}

func TestSetStatus(t *testing.T) {
	useStateDir(t)
	installFixture(t, "forwards.valid.json")

	if err := SetStatus("f-3000", "down"); err != nil {
		t.Fatal(err)
	}
	fw, _ := Load()
	if fw[0].Status != "down" {
		t.Fatalf("status 应更新为 down: %q", fw[0].Status)
	}
	if fw[0].Mode != ModeTunnel {
		t.Fatalf("其他字段不应变: %+v", fw[0])
	}
	// 换成 up 也要能回来
	if err := SetStatus("f-3000", "up"); err != nil {
		t.Fatal(err)
	}
	fw, _ = Load()
	if fw[0].Status != "up" {
		t.Fatalf("status 应更新为 up: %q", fw[0].Status)
	}
}

func TestSetStatusInvalid(t *testing.T) {
	useStateDir(t)
	installFixture(t, "forwards.valid.json")
	for _, s := range []string{"", "ok", "UP", "degraded"} {
		if err := SetStatus("f-3000", s); !errors.Is(err, ErrInvalidStatus) {
			t.Fatalf("status %q 应 ErrInvalidStatus，得到 %v", s, err)
		}
	}
}

func TestSetStatusNotFound(t *testing.T) {
	useStateDir(t)
	installFixture(t, "forwards.valid.json")
	if err := SetStatus("f-nope", "up"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("应 ErrNotFound，得到 %v", err)
	}
}

func TestSetStatusEmptyID(t *testing.T) {
	useStateDir(t)
	if err := SetStatus("", "up"); !errors.Is(err, ErrInvalidID) {
		t.Fatalf("应 ErrInvalidID，得到 %v", err)
	}
}

// 文件权限：原子写的落盘文件必须是 0600（对齐 bash mktemp）。
func TestSaveFileMode0600(t *testing.T) {
	useStateDir(t)
	if err := Save([]Forward{}); err != nil {
		t.Fatal(err)
	}
	st, err := os.Stat(FilePath())
	if err != nil {
		t.Fatal(err)
	}
	if perm := st.Mode().Perm(); perm != 0o600 {
		t.Fatalf("权限 = %o want 600", perm)
	}
}

// --- Publish 键序（jq 字母序） ----------------------------------------------

func TestPublishMarshalKeyOrder(t *testing.T) {
	p := Publish{Pid: ptrInt(1), StartedUnix: ptrInt64(2), URL: ptrStr("u")}
	got, err := json.Marshal(p)
	if err != nil {
		t.Fatal(err)
	}
	want := `{"pid":1,"started_unix":2,"url":"u"}`
	if string(got) != want {
		t.Fatalf("键序不符\n got: %s\nwant: %s", got, want)
	}
}

func TestPublishUnmarshal(t *testing.T) {
	var p Publish
	if err := json.Unmarshal([]byte(`{"pid":7,"started_unix":8,"url":"z"}`), &p); err != nil {
		t.Fatal(err)
	}
	if p.Pid == nil || *p.Pid != 7 || p.StartedUnix == nil || *p.StartedUnix != 8 || p.URL == nil || *p.URL != "z" {
		t.Fatalf("反序列化不符: %+v", p)
	}
}

func TestFilePathUsesStateDir(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("HERDR_PLUGIN_STATE_DIR", dir)
	if got := FilePath(); got != dir+"/forwards.json" {
		t.Fatalf("FilePath()=%q", got)
	}
}

// 逻辑 warn 断言：损坏状态下 Load 会调 hfcommon.Log("warn", ...) ——
// 无 HERDR_PLUGIN_STATE_DIR 时该 warn 落 stderr；有 env 时落 log 文件。
// 这里断言「有 env 时确实写了 warn 行」，避免「静默降级」。
func TestLoadCorruptEmitsWarnLog(t *testing.T) {
	dir := useStateDir(t)
	if err := os.WriteFile(FilePath(), []byte("{not json"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := Load(); err != nil {
		t.Fatal(err)
	}
	logFile := filepath.Join(dir, "logs", hfcommon.LogFileName)
	b, err := os.ReadFile(logFile)
	if err != nil {
		t.Fatalf("应写 warn 日志: %v", err)
	}
	if !strings.Contains(string(b), "warn: 状态文件不可解析或非对象") {
		t.Fatalf("warn 文案不符: %s", b)
	}
}

func ptrInt(v int) *int       { return &v }
func ptrInt64(v int64) *int64 { return &v }
func ptrStr(v string) *string { return &v }
