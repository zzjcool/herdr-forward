// protocol_test.go —— HF1 协议编解码 + C6 安全边界的单元测试（PLAN §8 要求）。
//
// 这些用例是 difftest 组 11/13 的**本机前置门**：difftest 需要 go+docker 之外的环境
// （真 lib/*.sh、jq），单测保证「改坏了立刻知道」，不必等差分跑完。
package bridge

import (
	"fmt"
	"strings"
	"testing"
)

func TestHelloString(t *testing.T) {
	cases := []struct {
		name string
		msg  Hello
		want string
	}{
		{"仅 host（B → A）", Hello{Host: "devbox"}, "HF1 HELLO devbox"},
		{"带标签（A → B）", Hello{Host: "laptop", Labels: []string{"my", "laptop"}}, "HF1 HELLO laptop my laptop"},
	}
	for _, tc := range cases {
		if got := tc.msg.String(); got != tc.want {
			t.Errorf("%s: String() = %q, want %q", tc.name, got, tc.want)
		}
	}
}

func TestSyncString(t *testing.T) {
	cases := []struct {
		name string
		msg  Sync
		want string
	}{
		{"空集合编码为 -", Sync{}, "HF1 SYNC -"},
		{
			"两条按序",
			Sync{Forwards: []SyncEntry{
				{ID: "f-3000", LocalPort: 3000, RemotePort: 3000},
				{ID: "f-15173", LocalPort: 15173, RemotePort: 5173},
			}},
			"HF1 SYNC f-3000:3000:3000,f-15173:15173:5173",
		},
	}
	for _, tc := range cases {
		if got := tc.msg.String(); got != tc.want {
			t.Errorf("%s: String() = %q, want %q", tc.name, got, tc.want)
		}
	}
}

func TestStatusStringOmitsEmptyReason(t *testing.T) {
	up := Status{ID: "f-5173", State: "up"}
	if got, want := up.String(), "HF1 STATUS f-5173 up"; got != want {
		t.Errorf("无 reason 时不得留尾随空格: got %q want %q", got, want)
	}
	down := Status{ID: "f-5173", State: "down", Reason: "client 端口 5173 已被占用"}
	if got, want := down.String(), "HF1 STATUS f-5173 down client 端口 5173 已被占用"; got != want {
		t.Errorf("带 reason: got %q want %q", got, want)
	}
}

func TestParseLineRoundTrip(t *testing.T) {
	// 编码 -> 解析 -> 再编码：只要是合法消息，两次编码必须逐字节相等。
	msgs := []Msg{
		Hello{Host: "devbox"},
		Hello{Host: "laptop", Labels: []string{"my", "laptop"}},
		Sync{},
		Sync{Forwards: []SyncEntry{{ID: "f-3000", LocalPort: 3000, RemotePort: 9443}}},
		Open{URL: "http://localhost:6006/x"},
		Status{ID: "f-5173", State: "up"},
		Status{ID: "f-5173", State: "down", Reason: "client 端口 5173 已被占用（laptop）"},
		Ping{},
	}
	for _, want := range msgs {
		line := want.String()
		parsed, err := ParseLine(line)
		if err != nil {
			t.Errorf("ParseLine(%q) 报错: %v", line, err)
			continue
		}
		if got := parsed.String(); got != line {
			t.Errorf("round-trip 不一致: in=%q out=%q", line, got)
		}
	}
}

func TestParseLineRejectsMalformed(t *testing.T) {
	// 非法行必须被拒（调用方只 warn 后继续，绝不因 B 的坏数据中断桥接）。
	bad := []string{
		"",
		"HF1",
		"XX1 HELLO devbox",
		"HF1 NOPE x",
		"garbage line",
	}
	for _, line := range bad {
		if _, err := ParseLine(line); err == nil {
			t.Errorf("ParseLine(%q) 应报错", line)
		}
	}
}

func TestParseLineStatusIsLenientAboutFields(t *testing.T) {
	// bash 的 serve 先分词再校验：字段不全的 STATUS **仍算一条 STATUS**（并刷新心跳）。
	// 这是「畸形行不再算心跳」的回归锚点（difftest 组 11 抓到过这个分叉）。
	msg, err := ParseLine("HF1 STATUS f-5173")
	if err != nil {
		t.Fatalf("字段不全的 STATUS 应被识别（由调用方校验），却报错: %v", err)
	}
	st, ok := msg.(Status)
	if !ok {
		t.Fatalf("解析结果类型 = %T, want Status", msg)
	}
	if st.ID != "f-5173" || st.State != "" {
		t.Errorf("宽容解析结果 = %+v, want ID=f-5173 State=\"\"", st)
	}
	// 越界 id 也必须能被**解析**（校验发生在 Serve.handleLine），否则 serve 会把它
	// 当未知行、不再刷新 last_seen。
	if _, err := ParseLine("HF1 STATUS ../../etc bogus"); err != nil {
		t.Errorf("越界 id 的 STATUS 也应可解析（校验交给调用方）: %v", err)
	}
}

func TestParseLineIgnoresTabsForSplit(t *testing.T) {
	// bash 是 `IFS=' ' read -r -a` —— **只**按空格切分，tab 不是分隔符。因此
	// `HF1 HELLO<TAB>laptop` 的 verb 是整段 `HELLO<TAB>laptop`（未知动作），bash 的
	// serve case 落到 `*)` 只 warn 一条「忽略未知协议行」。
	//
	// 这是「用 strings.Fields 重写分词」的回归锚点：Fields 会把 tab 当分隔符，于是
	// 同一行会被解析成 HELLO/Host=laptop（**与 bash 分叉**：多刷一次 last_seen、
	// 多写一次会话文件）。
	if _, err := ParseLine("HF1 HELLO\tlaptop"); err == nil {
		t.Error("tab 不是分隔符：该行应被当作未知动作拒绝（与 bash 的 warn 分支一致）")
	}

	// 反例：空格分隔的正常行必须解析成功（确认上面的失败不是“解析器坏了”）。
	msg, err := ParseLine("HF1 HELLO laptop")
	if err != nil {
		t.Fatalf("空格分隔的 HELLO 应解析成功: %v", err)
	}
	h, ok := msg.(Hello)
	if !ok {
		t.Fatalf("解析结果类型 = %T, want Hello", msg)
	}
	if h.Host != "laptop" {
		t.Errorf("Host = %q, want %q", h.Host, "laptop")
	}
}

func TestValidateForward(t *testing.T) {
	ok := []SyncEntry{
		{ID: "f-1024", LocalPort: 1024, RemotePort: 1024},
		{ID: "f-5173", LocalPort: 5173, RemotePort: 5173},
		{ID: "f-15432", LocalPort: 15432, RemotePort: 5432},
		{ID: "f-1080", LocalPort: 1080, RemotePort: 80}, // 远端端口可以 < 1024
		{ID: "f-65535", LocalPort: 65535, RemotePort: 65535},
	}
	for _, e := range ok {
		if err := ValidateForward(e); err != nil {
			t.Errorf("ValidateForward(%+v) = %v, want nil", e, err)
		}
	}

	bad := []SyncEntry{
		{ID: "f-80", LocalPort: 80, RemotePort: 80},        // 本地端口 < 1024
		{ID: "f-3000", LocalPort: 3001, RemotePort: 3000},  // id 与端口不一致
		{ID: "f-70000", LocalPort: 70000, RemotePort: 80},  // 本地端口越界
		{ID: "f-3000", LocalPort: 3000, RemotePort: 99999}, // 远端端口越界
		{ID: "../etc", LocalPort: 3000, RemotePort: 3000},  // 路径穿越 id
		{ID: "f-3000", LocalPort: 3000, RemotePort: 0},     // 远端端口 0
	}
	for _, e := range bad {
		if err := ValidateForward(e); err == nil {
			t.Errorf("ValidateForward(%+v) = nil, want 错误", e)
		}
	}
}

func TestValidateForwardLiterals(t *testing.T) {
	// 逐条对齐 bash 的 bridge_valid_entry（前导零 / 位宽只有字面量形态能表达）。
	valid := [][3]string{
		{"f-5173", "5173", "5173"},
		{"f-1080", "1080", "80"},
		{"f-65535", "65535", "65535"},
	}
	for _, c := range valid {
		if !ValidateForwardLiterals(c[0], c[1], c[2]) {
			t.Errorf("ValidateForwardLiterals(%q,%q,%q) = false, want true", c[0], c[1], c[2])
		}
	}
	invalid := [][3]string{
		{"f-08080", "08080", "80"},       // 前导零
		{"f-3000", "3001", "3000"},       // id 与端口不一致
		{"f-70000", "70000", "80"},       // 越界
		{"f-3000", "3000", "99999"},      // 远端端口越界
		{"f-3000", "3000", "x"},          // 非数字
		{"f-3000", "3000", "0"},          // 0
		{"f-100000", "100000", "100000"}, // 六位
		{"../../etc", "3000", "3000"},    // 路径穿越
		{"f-05173", "05173", "5173"},     // 前导零
	}
	for _, c := range invalid {
		if ValidateForwardLiterals(c[0], c[1], c[2]) {
			t.Errorf("ValidateForwardLiterals(%q,%q,%q) = true, want false", c[0], c[1], c[2])
		}
	}
}

func TestParseSyncDropsInvalidAndCaps(t *testing.T) {
	// 非法条目丢弃、合法保留（含注入尝试）
	entries, err := ParseSync("f-3000:3000:3000,f-22:22:22,f-4000:4000:4000;touch /tmp/pwn,f-5000:5000:5000:9,bogus,f-6000:6000:6000")
	if err != nil {
		t.Fatal(err)
	}
	want := []SyncEntry{
		{ID: "f-3000", LocalPort: 3000, RemotePort: 3000},
		{ID: "f-6000", LocalPort: 6000, RemotePort: 6000},
	}
	if len(entries) != len(want) {
		t.Fatalf("entries = %+v, want %d 条", entries, len(want))
	}
	for i := range want {
		if entries[i] != want[i] {
			t.Errorf("entries[%d] = %+v, want %+v", i, entries[i], want[i])
		}
	}

	// 空 / "-" 都是空集合
	for _, payload := range []string{"", "-"} {
		got, err := ParseSync(payload)
		if err != nil || len(got) != 0 {
			t.Errorf("ParseSync(%q) = %+v, %v; want 空集合", payload, got, err)
		}
	}

	// 超过上限截断到 MaxForwards
	var sb strings.Builder
	for p := 20001; p <= 20040; p++ {
		if sb.Len() > 0 {
			sb.WriteByte(',')
		}
		sb.WriteString(fmt.Sprintf("f-%d:%d:%d", p, p, p))
	}
	capped, err := ParseSync(sb.String())
	if err != nil {
		t.Fatal(err)
	}
	if len(capped) != MaxForwards {
		t.Errorf("超上限应截断到 %d 条，实际 %d", MaxForwards, len(capped))
	}
}
