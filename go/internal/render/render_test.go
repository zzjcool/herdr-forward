package render

import (
	"strings"
	"testing"
	"unicode/utf8"

	"github.com/zzjcool/herdr-forward/internal/state"
)

// fw 构造一条最小记录：status + local_port 是 oneline 唯一关心的两个字段。
func fw(localPort int, status string) state.Forward {
	return state.Forward{ID: "f-" + itoa(localPort), LocalPort: localPort, Status: status}
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	neg := n < 0
	if neg {
		n = -n
	}
	var b [20]byte
	i := len(b)
	for n > 0 {
		i--
		b[i] = byte('0' + n%10)
		n /= 10
	}
	if neg {
		i--
		b[i] = '-'
	}
	return string(b[i:])
}

// TestOneline 覆盖 §8 要求的全场景矩阵。测试里的 "up"/"down" 是刻意的字面量：
// C3 冻结的是字面量 "up"（不是本包的常量），写成字面量才能捕获「实现改了常量值」的错误。
func TestOneline(t *testing.T) {
	tests := []struct {
		name string
		in   []state.Forward
		want string
	}{
		{"nil 切片 -> 空串", nil, ""},
		{"空切片 -> 空串", []state.Forward{}, ""},
		{"单条 up", []state.Forward{fw(3000, "up")}, "⇅3000"},
		{
			"多条：仅 up、端口升序",
			[]state.Forward{fw(5173, "up"), fw(3000, "up")},
			"⇅3000⇅5173",
		},
		{
			"混合：down/starting/空 status 全被过滤",
			[]state.Forward{fw(8080, "down"), fw(5173, "up"), fw(9000, "starting"), fw(3000, "up"), fw(4000, "")},
			"⇅3000⇅5173",
		},
		{
			"全 down -> 空串",
			[]state.Forward{fw(3000, "down"), fw(4000, "down")},
			"",
		},
		{
			"全 starting -> 空串（add 后隧道未起）",
			[]state.Forward{fw(3000, "starting")},
			"",
		},
		{
			"大小写敏感：UP/Up 不算 up（jq 精确比较）",
			[]state.Forward{fw(3000, "UP"), fw(4000, "Up")},
			"",
		},
		{
			"合法边界端口：1024 / 65535（bash 实测 golden）",
			[]state.Forward{fw(65535, "up"), fw(1024, "up")},
			"⇅1024⇅65535",
		},
		{
			"端口 0 被丢弃（jq `numbers` 的 null 语义，bash 差异见 Oneline 注释）",
			[]state.Forward{fw(0, "up"), fw(3000, "up")},
			"⇅3000",
		},
		{
			"重复端口不去重（bash 实测 golden，total 亦按重复计数）",
			[]state.Forward{fw(3000, "up"), fw(3000, "up")},
			"⇅3000⇅3000",
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := Oneline(tc.in); got != tc.want {
				t.Fatalf("Oneline() = %q, want %q", got, tc.want)
			}
		})
	}
}

// TestOnelineTruncation 覆盖 §8 的「>6 截断 +N」。期望值全部取自 bash 实测
// （HERDR_PLUGIN_STATE_DIR=<tmp> bin/forward list --oneline）。
func TestOnelineTruncation(t *testing.T) {
	tests := []struct {
		name string
		in   []state.Forward
		want string
	}{
		{
			"恰好 6 条：不出现 +N",
			[]state.Forward{fw(3000, "up"), fw(4000, "up"), fw(5000, "up"), fw(6000, "up"), fw(7000, "up"), fw(8000, "up")},
			"⇅3000⇅4000⇅5000⇅6000⇅7000⇅8000",
		},
		{
			"7 条：前 6 + +1",
			[]state.Forward{fw(8000, "up"), fw(7000, "up"), fw(6000, "up"), fw(5000, "up"), fw(4000, "up"), fw(3000, "up"), fw(9000, "up")},
			"⇅3000⇅4000⇅5000⇅6000⇅7000⇅8000+1",
		},
		{
			"8 条（test_oneline.sh 场景）：前 6 + +2",
			[]state.Forward{fw(8000, "up"), fw(7000, "up"), fw(6000, "up"), fw(5000, "up"), fw(4000, "up"), fw(3000, "up"), fw(9000, "up"), fw(10000, "up")},
			"⇅3000⇅4000⇅5000⇅6000⇅7000⇅8000+2",
		},
		{
			"11 条里只有 10 条 up：+N 只数 up",
			[]state.Forward{
				fw(1000, "up"), fw(2000, "up"), fw(3000, "up"), fw(4000, "up"), fw(5000, "up"),
				fw(6000, "up"), fw(7000, "up"), fw(8000, "up"), fw(9000, "up"), fw(10000, "up"), fw(11000, "down"),
			},
			"⇅1000⇅2000⇅3000⇅4000⇅5000⇅6000+4",
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := Oneline(tc.in); got != tc.want {
				t.Fatalf("Oneline() = %q, want %q", got, tc.want)
			}
		})
	}
}

// TestOnelineMultiByteRunes：⇅（U+21C5）是 1 字符 3 字节。字符计数必须按 rune
// （bash 在 UTF-8 locale 下 `${#out}` 也按字符），同时验证输出无 ANSI ESC（C3 纯文本）。
func TestOnelineMultiByteRunes(t *testing.T) {
	out := Oneline([]state.Forward{fw(3000, "up"), fw(5173, "up")})

	if want := "⇅3000⇅5173"; out != want {
		t.Fatalf("Oneline() = %q, want %q", out, want)
	}
	// 2 个 ⇅ + "3000" + "5173" = 10 rune
	if got, want := utf8.RuneCountInString(out), 2+4+4; got != want {
		t.Fatalf("rune count = %d, want %d", got, want)
	}
	// 2*3 字节 + 8 字节 = 14 字节 —— 若按字节截断/拼接会在这里露馅
	if got, want := len(out), 14; got != want {
		t.Fatalf("byte length = %d, want %d", got, want)
	}
	if got, want := strings.Count(out, "⇅"), 2; got != want {
		t.Fatalf("⇅ 出现 %d 次, want %d", got, want)
	}
	if strings.ContainsRune(out, '\x1b') {
		t.Fatalf("输出含 ANSI ESC 序列: %q", out)
	}

	// 截断场景的 rune 计数：6 个 ⇅ + 6*4 位数字 + "+1" = 31
	trunc := Oneline([]state.Forward{
		fw(1000, "up"), fw(2000, "up"), fw(3000, "up"),
		fw(4000, "up"), fw(5000, "up"), fw(6000, "up"), fw(7000, "up"),
	})
	if got, want := utf8.RuneCountInString(trunc), 6+24+2; got != want {
		t.Fatalf("截断输出 rune count = %d, want %d（%q）", got, want, trunc)
	}
	// 前缀必须是 ⇅ 的 3 字节 UTF-8 编码 e2 87 85
	if !strings.HasPrefix(trunc, "\xe2\x87\x85") {
		t.Fatalf("输出前缀不是 ⇅ 的 UTF-8 编码: %q", trunc)
	}
}

// TestOnelineIsPureAndBounded：C3「坏输入 -> 空串，恒不失败」的 Go 侧等价语义 ——
// 无副作用、不 panic、可重复调用、不修改入参（排序走副本）。
func TestOnelineIsPureAndBounded(t *testing.T) {
	in := []state.Forward{fw(3000, "up"), fw(0, ""), fw(70000, "up")}
	first := Oneline(in)
	for i := 0; i < 3; i++ {
		if got := Oneline(in); got != first {
			t.Fatalf("重复调用结果不一致：%q != %q", got, first)
		}
	}
	// 端口越界在 bash 的 oneline 里不过滤（只过滤 status/non-number），Go 保持一致
	if first != "⇅3000⇅70000" {
		t.Fatalf("Oneline() = %q, want %q", first, "⇅3000⇅70000")
	}
	if in[0].LocalPort != 3000 || in[1].LocalPort != 0 || in[2].LocalPort != 70000 {
		t.Fatalf("Oneline 修改了入参切片：%+v", in)
	}
}

const tableWantHeader = "LOCAL      REMOTE         MACHINE      STATUS     PID      SSH_TARGET\n"

// TestTableGolden 的每个 golden 都先经 bash 实测核对过：
//
//	HERDR_PLUGIN_STATE_DIR=<tmp with forwards.json> bin/forward list 的逐字节输出。
//
// 语料刻意只用「语义无歧义」的字段值：Go 的 string 无法区分 jq 的 null 与 ""，
// 含混情形集中在 TestTableKnownDeviations 单独钉住。
func TestTableGolden(t *testing.T) {
	pid12345 := 12345
	pid23456 := 23456
	pid1 := 1
	pid9 := 9
	pid2 := 2

	tests := []struct {
		name string
		in   []state.Forward
		want string
	}{
		{
			"空切片：只有表头",
			nil,
			"",
		},
		{
			"单条 tunnel（pid 非空）",
			[]state.Forward{{
				ID: "f-3000", LocalPort: 3000, RemoteHost: "127.0.0.1", RemotePort: 9443,
				Machine: "gpu-box", SshTarget: "user@gpu-box.example.com:22",
				Pid: &pid12345, Status: "up", Mode: state.ModeTunnel,
			}},
			"3000       127.0.0.1:9443 gpu-box      up         12345    user@gpu-box.example.com:22\n",
		},
		{
			"多条：按 local_port 升序",
			[]state.Forward{
				{
					ID: "f-5173", LocalPort: 5173, RemoteHost: "127.0.0.1", RemotePort: 5173,
					Machine: "web-box", SshTarget: "deploy@web-box.example.com:22",
					Pid: &pid23456, Status: "up", Mode: state.ModeTunnel,
				},
				{
					ID: "f-3000", LocalPort: 3000, RemoteHost: "127.0.0.1", RemotePort: 9443,
					Machine: "gpu-box", SshTarget: "user@gpu-box.example.com:22",
					Pid: &pid12345, Status: "down", Mode: state.ModeTunnel,
				},
			},
			"3000       127.0.0.1:9443 gpu-box      down       12345    user@gpu-box.example.com:22\n" +
				"5173       127.0.0.1:5173 web-box      up         23456    deploy@web-box.example.com:22\n",
		},
		{
			"中文 machine：列宽按 rune（与 gawk UTF-8 一致，不错位）",
			[]state.Forward{{
				ID: "f-6006", LocalPort: 6006, RemoteHost: "127.0.0.1", RemotePort: 6006,
				Machine: "测试机", SshTarget: "", Pid: nil, Status: "down",
			}},
			// 期望值用 \u 转义写死：CJK 列宽差异只差 1 个空格，肉眼易错（goldens 从 bash 实测取）
			"6006       127.0.0.1:6006 \u6d4b\u8bd5\u673a          down       -        -\n",
		},
		{
			"pid null -> -（down 记录）",
			[]state.Forward{{
				ID: "f-3000", LocalPort: 3000, RemoteHost: "127.0.0.1", RemotePort: 3000,
				Machine: "gpu", SshTarget: "u@g:22", Pid: nil, Status: "starting",
			}},
			"3000       127.0.0.1:3000 gpu          starting   -        u@g:22\n",
		},
		{
			"pid=1 是真 pid（与 null 区分）",
			[]state.Forward{{
				ID: "f-3000", LocalPort: 3000, RemoteHost: "127.0.0.1", RemotePort: 3000,
				Machine: "gpu", SshTarget: "u@g:22", Pid: &pid1, Status: "up",
			}},
			"3000       127.0.0.1:3000 gpu          up         1        u@g:22\n",
		},
		{
			"mode=client（渲染原始记录；view 层的 status 改写见 TestTableKnownDeviations）",
			[]state.Forward{{
				ID: "f-3000", LocalPort: 3000, RemoteHost: "127.0.0.1", RemotePort: 3000,
				Machine: "", SshTarget: "", Pid: nil, Status: "up", Mode: state.ModeClient,
			}},
			"3000       127.0.0.1:3000 client       up         -        -\n",
		},
		{
			"mode=bridge（machine 非空）：MACHINE 列 = <machine>(\u6865\u63a5)",
			[]state.Forward{{
				ID: "f-5000", LocalPort: 5000, RemoteHost: "127.0.0.1", RemotePort: 5000,
				Machine: "web-box", SshTarget: "", Pid: nil, Status: "up", Mode: modeBridge,
			}},
			"5000       127.0.0.1:5000 web-box(\u6865\u63a5)  up         -        -\n",
		},
		{
			"超长 remote_host（不被列宽截断，第六列同理）",
			[]state.Forward{{
				ID: "f-3000", LocalPort: 3000, RemoteHost: "a-very-long-host.internal", RemotePort: 3000,
				Machine: "gpu", SshTarget: "u@g:22", Pid: &pid9, Status: "up",
			}},
			"3000       a-very-long-host.internal:3000 gpu          up         9        u@g:22\n",
		},
		{
			"升序排在最前的是最小合法端口 1024",
			[]state.Forward{
				{ID: "f-9000", LocalPort: 9000, RemoteHost: "127.0.0.1", RemotePort: 1, Machine: "z", SshTarget: "z@z:22", Pid: &pid1, Status: "up"},
				{ID: "f-1024", LocalPort: 1024, RemoteHost: "127.0.0.1", RemotePort: 2, Machine: "a", SshTarget: "a@a:22", Pid: &pid2, Status: "starting"},
			},
			"1024       127.0.0.1:2    a            starting   2        a@a:22\n" +
				"9000       127.0.0.1:1    z            up         1        z@z:22\n",
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := Table(tc.in, 1790000500)
			want := tableWantHeader + tc.want
			if got != want {
				t.Fatalf("Table() mismatch\n got: %q\nwant: %q", got, want)
			}
		})
	}
}

// TestTableKnownDeviations 把「受限于 state.Forward 冻结字段」的差异显式钉住。
// 它们都是**有意的**（契约允许，且真实数据不会触发）：改这里必须同时更新本包注释/
// docs 里的契约说明，避免未来当作 bug「顺手修掉」。
func TestTableKnownDeviations(t *testing.T) {
	pid := 7
	t.Run("remote_host 空串在 Go 里按缺省 127.0.0.1（jq 只对 null 做 // 替换）", func(t *testing.T) {
		// bash（显式 ""）：`3000       :3000 ...`；Go 无法区分 ""/null，取 [null 行为]
		// 即 `127.0.0.1:3000` —— 真实数据里 remote_host 恒有值（add 路径必写），
		// 空串只可能来自手改文件。
		got := Table([]state.Forward{{
			ID: "f-3000", LocalPort: 3000, RemoteHost: "", RemotePort: 3000,
			Machine: "gpu", SshTarget: "u@g:22", Pid: &pid, Status: "up",
		}}, 0)
		want := "3000       127.0.0.1:3000 gpu          up         7        u@g:22\n"
		if !strings.HasSuffix(got, want) {
			t.Fatalf("got %q, want suffix %q", got, want)
		}
	})

	t.Run("remote_port 缺失/null 在 Go 里是 0（bash 显示 null）", func(t *testing.T) {
		// bash：`8080       127.0.0.1:null ...`（(.remote_port | tostring) 对 null 给 "null"）；
		// Go 的 int 零值只能是 0。A.2 要求 remote_port 必填，缺失只在损坏记录里出现。
		got := Table([]state.Forward{{
			ID: "f-8080", LocalPort: 8080, RemoteHost: "127.0.0.1",
			Machine: "gpu", SshTarget: "u@g:22", Status: "up",
		}}, 0)
		want := "8080       127.0.0.1:0    gpu          up         -        u@g:22\n"
		if !strings.HasSuffix(got, want) {
			t.Fatalf("got %q, want suffix %q", got, want)
		}
	})

	t.Run("status 空串 -> -（jq 只对 null 做 // 替换）", func(t *testing.T) {
		// bash（显式 ""）：STATUS 列为空；Go 取 [null 行为] 显示 "-"。
		// status "" 不是合法 status（A.2: starting|up|down），只可能来自手改文件。
		got := Table([]state.Forward{{
			ID: "f-3000", LocalPort: 3000, RemoteHost: "127.0.0.1", RemotePort: 3000,
			Machine: "gpu", SshTarget: "u@g:22", Status: "",
		}}, 0)
		want := "3000       127.0.0.1:3000 gpu          -          -        u@g:22\n"
		if !strings.HasSuffix(got, want) {
			t.Fatalf("got %q, want suffix %q", got, want)
		}
	})

	t.Run("mode=bridge 的 machine 空 -> -(桥接)（jq 只对 null 做 // 替换）", func(t *testing.T) {
		// bash（显式 ""）：`5000 ... (桥接) ...`（替换不生效，得到空 machine + "(桥接)"）；
		// bash（null/缺失）：`5000 ... -(桥接) ...`。Go 的 string 零值含混，统一取 [null 行为]
		// 即 "-" —— 与 remote_host/status 的取值规则一致；真实 bridge 数据恒有 label。
		got := Table([]state.Forward{{
			ID: "f-5000", LocalPort: 5000, RemoteHost: "127.0.0.1", RemotePort: 5000,
			Machine: "", SshTarget: "", Pid: nil, Status: "up", Mode: modeBridge,
		}}, 0)
		want := "5000       127.0.0.1:5000 -(\u6865\u63a5)        up         -        -\n"
		if !strings.HasSuffix(got, want) {
			t.Fatalf("got %q, want suffix %q", got, want)
		}
	})

	t.Run("mode=client：纯渲染不改写 status（view 层才注入 waiting/status_reason）", func(t *testing.T) {
		// bash 的 `forward list` 走 _hf_view_json → bridge_merge_live，会给 client 记录
		// 注入 status/status_reason/client（无 client 在线时 status 被改写为 waiting，
		// 第 6 列显示 status_reason）。冻结的 state.Forward 没有 status_reason/client 字段，
		// 且 render.Table 只对传入记录做纯渲染 —— 那层合并视图归 Phase 3 的 bridge/machine
		// view（PLAN §5）。因此直读本地文件时 client 记录的 status 不会被改写。
		got := Table([]state.Forward{{
			ID: "f-3000", LocalPort: 3000, RemoteHost: "127.0.0.1", RemotePort: 3000,
			Machine: "", SshTarget: "", Pid: nil, Status: "up", Mode: state.ModeClient,
		}}, 0)
		want := "3000       127.0.0.1:3000 client       up         -        -\n"
		if !strings.HasSuffix(got, want) {
			t.Fatalf("got %q, want suffix %q", got, want)
		}
	})

	t.Run("mode=client：status_reason 列恒为 -（state.Forward 无该字段）", func(t *testing.T) {
		// bash 的 _hf_view_json/bridge_merge_live 会给 client 记录注入 status/status_reason/client
		// （无 client 在线时 status 被改写为 waiting，第 6 列显示 status_reason）。冻结的
		// state.Forward 没有 status_reason/client 字段，且 render.Table 是对"单条记录"的纯渲染
		// —— 这层合并视图归 Phase 3 的 bridge/machine view（PLAN §5 bridge 段）。
		got := Table([]state.Forward{{
			ID: "f-3000", LocalPort: 3000, RemoteHost: "localhost", RemotePort: 3000,
			Machine: "gpu", SshTarget: "u@g:22", Status: "waiting", Mode: state.ModeClient,
		}}, 0)
		want := "3000       localhost:3000 client       waiting    -        -\n"
		if !strings.HasSuffix(got, want) {
			t.Fatalf("got %q, want suffix %q", got, want)
		}
	})
}

// TestTableNowUnixIsInert：Table 接受 nowUnix 以保持 §5 冻结签名；bash 的 `forward list`
// 表格没有任何时间列，故不同 nowUnix 必须给出完全相同的输出（防止未来误加「当前时间」）。
func TestTableNowUnixIsInert(t *testing.T) {
	in := []state.Forward{{
		ID: "f-3000", LocalPort: 3000, RemoteHost: "127.0.0.1", RemotePort: 3000,
		Machine: "gpu", SshTarget: "u@g:22", Status: "up", CreatedUnix: 1790000000,
	}}
	a, b := Table(in, 0), Table(in, 1790009999)
	if a != b {
		t.Fatalf("nowUnix 影响了输出：\n%q\n%q", a, b)
	}
	if strings.Contains(a, "1790000000") {
		// created_unix 不应出现在表格里（bash 也不显示）
		t.Fatalf("表格泄漏了 created_unix：%q", a)
	}
}

func TestTableIsPureAndNoANSI(t *testing.T) {
	in := []state.Forward{
		{ID: "b", LocalPort: 9000, RemoteHost: "127.0.0.1", RemotePort: 1, Status: "up"},
		{ID: "a", LocalPort: 1024, RemoteHost: "127.0.0.1", RemotePort: 2, Status: "starting"},
	}
	orig := append([]state.Forward(nil), in...)
	out := Table(in, 1)
	for i := range in {
		if in[i] != orig[i] {
			t.Fatalf("Table 修改了入参：%+v != %+v", in[i], orig[i])
		}
	}
	if !strings.HasSuffix(out, "\n") {
		t.Fatalf("输出未以换行结尾：%q", out)
	}
	if strings.ContainsRune(out, '\x1b') {
		t.Fatalf("输出含 ANSI ESC：%q", out)
	}
	lines := strings.Split(strings.TrimSuffix(out, "\n"), "\n")
	if len(lines) != 3 {
		t.Fatalf("行数 = %d, want 3（表头 + 2 行）", len(lines))
	}
	if lines[0] != strings.TrimSuffix(tableWantHeader, "\n") {
		t.Fatalf("表头 = %q", lines[0])
	}
	if !strings.HasPrefix(lines[1], "1024") || !strings.HasPrefix(lines[2], "9000") {
		t.Fatalf("未按 local_port 升序：%q / %q", lines[1], lines[2])
	}
}

func TestTableEmptyIsHeaderOnly(t *testing.T) {
	if got, want := Table(nil, 0), tableWantHeader; got != want {
		t.Fatalf("空表 = %q, want %q", got, want)
	}
	if got, want := Table([]state.Forward{}, 0), tableWantHeader; got != want {
		t.Fatalf("空表 = %q, want %q", got, want)
	}
	// bash 同形：`bin/forward list` 在空状态下只打印表头 + 换行，exit 0
	if strings.Count(tableWantHeader, "\n") != 1 {
		t.Fatalf("表头应当只有 1 个换行：%q", tableWantHeader)
	}
}
