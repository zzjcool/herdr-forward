// view_test.go —— machines 合并视图 / 激活状态 / 同机判定 / 解析的单元测试
// （PLAN §8 要求 + §A.3.2 冻结 schema）。
package machine

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// useStateDir 把状态目录指向 t.TempDir()（绝不碰真实 ~/.local/state）。
func useStateDir(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	t.Setenv("HERDR_PLUGIN_STATE_DIR", dir)
	return dir
}

// fakeMachineList 造一个假 herdr：`machine list --json` 回放 payload，其余子命令 127。
//
// 复用同包 herdr_test.go 的 fakeHerdr（它接受 shell body），避免第二份实现。
func fakeMachineList(t *testing.T, payload string) string {
	t.Helper()
	body := "if [ \"${1-}\" = machine ] && [ \"${2-}\" = list ]; then\n" +
		"  printf '%s\\n' '" + payload + "'\n" +
		"  exit 0\n" +
		"fi\n" +
		"exit 127"
	return fakeHerdr(t, body)
}

const stdMachines = `[{"id":"m-probe","label":"test-probe","target":"user@b-host:22","session":"default","enabled":true,"selected":false},` +
	`{"id":"m-local","label":"this-host","target":"127.0.0.1","session":"default","enabled":true,"selected":false},` +
	`{"id":"m-uri","label":"uri-box","target":"ssh://dev@b-host:2222","session":"default","enabled":true,"selected":false},` +
	`{"id":"m-gpu","label":"gpu-box","target":"ubuntu@gpu.example.com:2222","session":"default","enabled":false,"selected":false}]`

func TestViewStatesAndOrphan(t *testing.T) {
	useStateDir(t)
	t.Setenv("HERDR_BIN_PATH", fakeMachineList(t, stdMachines))

	// 激活 m-uri（远端）与 m-ghost（herdr 列表里不存在 -> orphan）
	mustSet(t, "m-uri", map[string]any{"label": "uri-box", "ssh_target": "ssh://dev@b-host:2222",
		"server_root": "/home/b/plugin", "state_dir": "/home/b/state", "local": false})
	mustSet(t, "m-ghost", map[string]any{"label": "gone-box", "ssh_target": "u@gone:22",
		"server_root": "/home/g/plugin", "state_dir": "/home/g/state", "local": false})

	view := View()
	if len(view) != 5 {
		t.Fatalf("view 长度 = %d, want 5（4 台 herdr + 1 台 orphan）", len(view))
	}
	byID := map[string]MachineView{}
	for _, v := range view {
		byID[v.ID] = v
	}
	if got := byID["m-probe"].State; got != "inactive" {
		t.Errorf("m-probe state = %q, want inactive", got)
	}
	if got := byID["m-local"].State; got != "local" {
		t.Errorf("m-local state = %q, want local（127.0.0.1 是强信号）", got)
	}
	// active 是**最后一次 set** 的 id（m-ghost）—— 单 active 语义（A.3.2）。
	// m-uri 已有记录但非当前 active -> "activated"。
	if got := byID["m-uri"].State; got != "activated" {
		t.Errorf("m-uri state = %q, want activated（记录存在但非当前 active）", got)
	}
	if got := byID["m-ghost"]; got.State != "active" || !got.Orphan {
		t.Errorf("m-ghost = %+v, want state=active orphan=true", got)
	}
	if got := byID["m-gpu"].Enabled; got {
		t.Error("m-gpu enabled = true, want false（herdr 说 enabled=false）")
	}
	// target 必须原样保留（不归一化、不截断）
	if got := byID["m-uri"].Target; got != "ssh://dev@b-host:2222" {
		t.Errorf("m-uri target = %q, want ssh:// 原文", got)
	}
}

func TestViewJSONKeyOrder(t *testing.T) {
	useStateDir(t)
	t.Setenv("HERDR_BIN_PATH", fakeMachineList(t, stdMachines))

	raw := ViewJSON()
	var arr []map[string]json.RawMessage
	if err := json.Unmarshal(raw, &arr); err != nil {
		t.Fatalf("ViewJSON 不是合法 JSON 数组: %v（%s）", err, raw)
	}
	if len(arr) == 0 {
		t.Fatal("ViewJSON 为空")
	}
	// 键序是冻结契约（C5）：id,label,target,enabled,state,local,orphan
	want := []string{"id", "label", "target", "enabled", "state", "local", "orphan"}
	got := rawKeyOrder(t, string(raw))
	if len(got) != len(want) {
		t.Fatalf("键数 = %d, want %d（%v）", len(got), len(want), got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("键序[%d] = %q, want %q（冻结形状）", i, got[i], want[i])
		}
	}
	if raw[len(raw)-1] != '\n' {
		t.Error("ViewJSON 应以单个换行结尾")
	}
}

func TestViewJSONEmptyIsArray(t *testing.T) {
	useStateDir(t)
	t.Setenv("HERDR_BIN_PATH", "")
	// 无 HERDR_BIN_PATH 时 herdr 列表为空；无激活记录 -> 空视图应是 `[]` 而不是 `null`
	if got := string(ViewJSON()); got != "[]\n" {
		t.Errorf("空视图 = %q, want %q", got, "[]\n")
	}
}

func TestResolveIDOrder(t *testing.T) {
	useStateDir(t)
	t.Setenv("HERDR_BIN_PATH", fakeMachineList(t, stdMachines))
	mustSet(t, "m-orphan", map[string]any{"label": "Orphan-Box", "ssh_target": "u@o:22",
		"server_root": "/r", "state_dir": "/s", "local": false})

	cases := []struct {
		arg  string
		want string
	}{
		{"m-probe", "m-probe"},     // id 精确
		{"test-probe", "m-probe"},  // label 精确
		{"TEST-PROBE", "m-probe"},  // label 大小写不敏感
		{"orphan-box", "m-orphan"}, // 激活记录 label 大小写不敏感
		{"m-orphan", "m-orphan"},   // 激活记录 key
	}
	for _, tc := range cases {
		got, err := ResolveID(tc.arg)
		if err != nil || got != tc.want {
			t.Errorf("ResolveID(%q) = %q, %v; want %q", tc.arg, got, err, tc.want)
		}
	}
	if _, err := ResolveID("definitely-nope"); err == nil {
		t.Error("不存在的 id/label 应返回 ErrMachineNotFound")
	}
}

func TestLookupFallsBackToActivation(t *testing.T) {
	useStateDir(t)
	t.Setenv("HERDR_BIN_PATH", fakeMachineList(t, stdMachines))
	mustSet(t, "m-ghost", map[string]any{"label": "gone-box", "ssh_target": "u@gone:22",
		"server_root": "/r", "state_dir": "/s", "local": false})

	if v, err := Lookup("m-probe"); err != nil || v.Label != "test-probe" {
		t.Errorf("Lookup(herdr 命中) = %+v, %v", v, err)
	}
	if v, err := Lookup("m-ghost"); err != nil || v.Label != "gone-box" {
		t.Errorf("Lookup(退回激活记录) = %+v, %v", v, err)
	}
	if _, err := Lookup("nope"); err == nil {
		t.Error("Lookup 不存在的 id 应报错")
	}
}

func TestIsLocalTarget(t *testing.T) {
	useStateDir(t)
	yes := []string{
		"localhost", "localhost:22", "user@localhost", "user@localhost:2222",
		"127.0.0.1", "127.0.0.1:2222", "user@127.0.0.1:22",
		"::1", "[::1]", "[::1]:22", "user@[::1]:22",
		"ssh://localhost", "ssh://user@localhost:2222", "ssh://127.0.0.1:2222",
		"LOCALHOST", "localhost.localdomain",
	}
	for _, target := range yes {
		if !IsLocalTarget(target) {
			t.Errorf("IsLocalTarget(%q) = false, want true", target)
		}
	}
	no := []string{
		"", "b-host", "user@b-host:22", "127.0.0.2", "ssh://dev@b-host:2222",
		"fe80::1", "192.168.1.10", "10.0.0.1:22",
	}
	for _, target := range no {
		if IsLocalTarget(target) {
			t.Errorf("IsLocalTarget(%q) = true, want false（拿不准必须走 ssh 探测）", target)
		}
	}
}

func TestActivationRoundTrip(t *testing.T) {
	dir := useStateDir(t)

	// 文件缺失 -> 空文档（不 warn，不报错）
	if a := LoadActivation(); a.Active != "" || len(a.Machines) != 0 {
		t.Fatalf("缺失文件应得到空文档，实际 %+v", a)
	}

	mustSet(t, "m-a", map[string]any{"label": "box-a", "ssh_target": "u@a:22"})
	mustSet(t, "m-b", map[string]any{"label": "box-b", "ssh_target": "u@b:22"})

	if got := ActiveID(); got != "m-b" {
		t.Errorf("ActiveID = %q, want m-b（最后一次 set）", got)
	}
	if !HasActivation("m-a") || HasActivation("nope") {
		t.Error("HasActivation 判定错误")
	}
	if _, err := GetActivation("m-a"); err != nil {
		t.Errorf("GetActivation(m-a) 报错: %v", err)
	}
	if _, err := GetActivation("nope"); err == nil {
		t.Error("GetActivation 不存在应报错")
	}

	// 落盘形态：jq -S -c（紧凑单行 + 键名字母序 + 结尾单换行）
	raw, err := os.ReadFile(filepath.Join(dir, "activated-machines.json"))
	if err != nil {
		t.Fatal(err)
	}
	if raw[len(raw)-1] != '\n' {
		t.Error("状态文件应以单换行结尾")
	}
	if !json.Valid(raw) {
		t.Fatalf("状态文件不是合法 JSON: %s", raw)
	}
	got := rawKeyOrder(t, string(raw))
	want := []string{"active", "machines", "version"}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("顶层键序[%d] = %q, want %q（jq -S 字母序）", i, got[i], want[i])
		}
	}

	// ClearActive 保留记录；RemoveActivation 删记录并顺带清 active；Reset 全清
	if err := ClearActive(); err != nil {
		t.Fatal(err)
	}
	if ActiveID() != "" || len(LoadActivation().Machines) != 2 {
		t.Error("ClearActive 应只清 active、保留记录")
	}
	if err := RemoveActivation("m-b"); err != nil {
		t.Fatal(err)
	}
	if len(LoadActivation().Machines) != 1 {
		t.Error("RemoveActivation 应删掉一条记录")
	}
	if err := ResetActivation(); err != nil {
		t.Fatal(err)
	}
	if a := LoadActivation(); a.Active != "" || len(a.Machines) != 0 {
		t.Error("ResetActivation 应清空 active 与全部记录")
	}
}

func TestActivationCorruptFileKeepsContent(t *testing.T) {
	dir := useStateDir(t)
	path := filepath.Join(dir, "activated-machines.json")
	corrupt := `{"version":1,"machines":"not-an-object"}`
	if err := os.WriteFile(path, []byte(corrupt), 0o600); err != nil {
		t.Fatal(err)
	}
	// 损坏 -> 空文档（warn），但**原文件保持不动**（绝不覆盖）
	if a := LoadActivation(); len(a.Machines) != 0 {
		t.Errorf("损坏文件应得到空文档，实际 %+v", a)
	}
	if raw, err := os.ReadFile(path); err != nil || string(raw) != corrupt {
		t.Error("损坏文件不得被覆盖")
	}
}

// --- 小工具 ---------------------------------------------------------------

func mustSet(t *testing.T, id string, rec map[string]any) {
	t.Helper()
	if err := SetActivation(id, rec); err != nil {
		t.Fatalf("SetActivation(%q) 报错: %v", id, err)
	}
}

// rawKeyOrder 从紧凑 JSON 文本里取**顶层对象**的键出现顺序（用于断言冻结键序）。
//
// 手写 token 遍历而不是用 map：Go 的 map 会丢掉顺序，而顺序正是这里要断言的东西。
func rawKeyOrder(t *testing.T, raw string) []string {
	t.Helper()
	dec := json.NewDecoder(strings.NewReader(raw))
	tok, err := dec.Token()
	if err != nil {
		t.Fatalf("解析失败: %v（%s）", err, raw)
	}
	delim, ok := tok.(json.Delim)
	if !ok {
		t.Fatalf("顶层不是容器: %q", raw)
	}
	if delim == '[' {
		// 数组：取第一个元素对象的键序（`machines list --json` 的形状）
		if !dec.More() {
			t.Fatalf("数组为空: %q", raw)
		}
		inner, err := dec.Token()
		if err != nil {
			t.Fatalf("读数组首元素失败: %v", err)
		}
		if d, ok := inner.(json.Delim); !ok || d != '{' {
			t.Fatalf("数组首元素不是对象: %q", raw)
		}
		return readObjectKeys(t, dec)
	}
	if delim != '{' {
		t.Fatalf("顶层不是对象: %q", raw)
	}
	return readObjectKeys(t, dec)
}

// readObjectKeys 读一个**已进入**的对象（开括号已消费）的键序，并把值整体跳过。
func readObjectKeys(t *testing.T, dec *json.Decoder) []string {
	t.Helper()
	keys := []string{}
	for dec.More() {
		kt, err := dec.Token()
		if err != nil {
			t.Fatalf("读键失败: %v", err)
		}
		key, ok := kt.(string)
		if !ok {
			t.Fatalf("对象键不是字符串: %v", kt)
		}
		keys = append(keys, key)
		skipValue(t, dec)
	}
	if _, err := dec.Token(); err != nil { // 消费 '}'
		t.Fatalf("读对象结束失败: %v", err)
	}
	return keys
}

// skipValue 丢开一个完整的 JSON 值（标量直接丢，容器递归丢）。
func skipValue(t *testing.T, dec *json.Decoder) {
	t.Helper()
	tok, err := dec.Token()
	if err != nil {
		t.Fatalf("读值失败: %v", err)
	}
	delim, ok := tok.(json.Delim)
	if !ok {
		return // 标量
	}
	switch delim {
	case '{':
		for dec.More() {
			if _, err := dec.Token(); err != nil { // 键
				t.Fatalf("跳过对象键失败: %v", err)
			}
			skipValue(t, dec)
		}
		_, _ = dec.Token() // '}'
	case '[':
		for dec.More() {
			skipValue(t, dec)
		}
		_, _ = dec.Token() // ']'
	}
}

// firstArrayElement 取数组文本的第一个对象元素（用于 ViewJSON 的键序断言）。
func firstArrayElement(raw string) string {
	start := strings.Index(raw, "{")
	if start < 0 {
		return "{}"
	}
	depth := 0
	for i := start; i < len(raw); i++ {
		switch raw[i] {
		case '{':
			depth++
		case '}':
			depth--
			if depth == 0 {
				return raw[start : i+1]
			}
		}
	}
	return "{}"
}
