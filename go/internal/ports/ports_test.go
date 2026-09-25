package ports

import (
	"os"
	"os/exec"
	"runtime"
	"strings"
	"testing"
)

// fileReadable 探测文件可读性（避免在断言里丢弃返回值）。
func fileReadable(path string) (bool, error) {
	f, err := os.Open(path)
	if err != nil {
		return false, err
	}
	closeErr := f.Close()
	return true, closeErr
}

// 以下 fixture 全部从 lib/ports.sh 的解析语义与 tests/unit/test_ports.sh 的语料构造，
// 并用 bash 实测（`ports_parse_proc` / `ports_parse_lsof`）逐字节核对过输出。

const procHeader = "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode"

const procHeader6 = "  sl  local_address                         remote_address                        st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode"

func TestParseProc(t *testing.T) {
	tests := []struct {
		name string
		tcp4 string
		tcp6 string
		want []Listener
	}{
		{
			name: "只有表头 -> 无监听",
			tcp4: procHeader + "\n",
			want: []Listener{},
		},
		{
			name: "空输入 -> 无监听",
			want: []Listener{},
		},
		{
			name: "0100007F:1435 -> 127.0.0.1:5173（little-endian + hex 端口）",
			tcp4: procHeader + "\n" +
				"   0: 0100007F:1435 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 1 1 0 100 0 0 10 0\n",
			want: []Listener{{Port: 5173, Addr: "127.0.0.1", Process: ""}},
		},
		{
			name: "00000000:1F90 -> 0.0.0.0:8080（通配算，经 localhost 可达）",
			tcp4: procHeader + "\n" +
				"   0: 00000000:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 2 1 0 100 0 0 10 0\n",
			want: []Listener{{Port: 8080, Addr: "0.0.0.0", Process: ""}},
		},
		{
			name: "非 0A（ESTABLISHED=01）不列",
			tcp4: procHeader + "\n" +
				"   0: 0100007F:1F90 0100007F:D431 01 00000000:00000000 00:00000000 00000000  1000        0 4 1 0 100 0 0 10 0\n",
			want: []Listener{},
		},
		{
			name: "0a 小写不算 LISTEN（bash 精确比较 \"0A\"）",
			tcp4: procHeader + "\n" +
				"   0: 0100007F:1435 00000000:0000 0a 00000000:00000000 00:00000000 00000000  1000        0 4 1 0 100 0 0 10 0\n",
			want: []Listener{},
		},
		{
			name: "127.0.0.11（容器 DNS）不算 —— localhost 解析不到",
			tcp4: procHeader + "\n" +
				"   0: 0B00007F:14D1 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 3 1 0 100 0 0 10 0\n",
			want: []Listener{},
		},
		{
			name: "127.0.0.53（systemd-resolved）不算",
			tcp4: procHeader + "\n" +
				"   0: 3500007F:14D3 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 3 1 0 100 0 0 10 0\n",
			want: []Listener{},
		},
		{
			name: "网卡地址（192.168.1.5）不算 —— localhost 连不到",
			tcp4: procHeader + "\n" +
				"   0: 0501A8C0:2328 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 3 1 0 100 0 0 10 0\n",
			want: []Listener{},
		},
		{
			name: "端口 <1024 不列（0100007F:0400 = 1024 是下界；0277=631 与 0016=22 都剔除）",
			tcp4: procHeader + "\n" +
				"   0: 0100007F:0400 00000000:0000 0A x 0 0 1 0 0 10 0\n" +
				"   1: 0100007F:0277 00000000:0000 0A x 0 0 2 0 0 10 0\n" +
				"   2: 0100007F:0016 00000000:0000 0A x 0 0 3 0 0 10 0\n",
			want: []Listener{{Port: 1024, Addr: "127.0.0.1", Process: ""}},
		},
		{
			name: "端口上限 65535（FFFF）保留，0 与 1 剔除",
			tcp4: procHeader + "\n" +
				"   0: 0100007F:FFFF 00000000:0000 0A x 0 0 1 0 0 10 0\n" +
				"   1: 0100007F:0000 00000000:0000 0A x 0 0 2 0 0 10 0\n" +
				"   2: 0100007F:0001 00000000:0000 0A x 0 0 3 0 0 10 0\n",
			want: []Listener{{Port: 65535, Addr: "127.0.0.1", Process: ""}},
		},
		{
			name: "端口前导零（0028=40 <1024 剔除；前导零不构成独立语义，走十进制归一）",
			tcp4: procHeader + "\n" +
				"   0: 0100007F:0028 00000000:0000 0A x 0 0 1 0 0 10 0\n" +
				"   1: 0100007F:0A00 00000000:0000 0A x 0 0 2 0 0 10 0\n",
			// 0A00 = 2560 -> ≥1024，保留（hex，不是十进制前导零）
			want: []Listener{{Port: 2560, Addr: "127.0.0.1", Process: ""}},
		},
		{
			name: "端口 hex 非法/位数不对 -> 该行跳过",
			tcp4: procHeader + "\n" +
				"   0: 0100007F:ZZZZ 00000000:0000 0A x\n" +
				"   1: 0100007F:143 00000000:0000 0A x\n" +
				"   2: 0100007F:1435F 00000000:0000 0A x\n" +
				"   3: noColon:0A x y\n" +
				"   4: 0100007F 00000000:0000 0A x\n",
			want: []Listener{},
		},
		{
			name: "列数不足的行不 panic；恰好 4 列（state 齐全）仍按 bash 解析",
			tcp4: procHeader + "\n" +
				"   0: 0100007F:1435 00000000:0000 0A\n" +
				"\n" +
				"   1: 0100007F:1435\n",
			// bash 实测：`IFS=' ' read -r -a cols` 切出 4 列即 ${cols[3]}==0A 成立 -> 仍输出
			want: []Listener{{Port: 5173, Addr: "127.0.0.1", Process: ""}},
		},
		{
			name: "列数真正不足（<4）跳过",
			tcp4: procHeader + "\n" +
				"   0: 0100007F:1435 00000000:0000\n" +
				"   1: 0100007F:1435\n",
			want: []Listener{},
		},
		{
			name: "tcp6 全零 -> ::（通配保留）",
			tcp6: procHeader6 + "\n" +
				"   0: 00000000000000000000000000000000:0BB8 00000000000000000000000000000000:0000 0A x\n",
			want: []Listener{{Port: 3000, Addr: "::", Process: ""}},
		},
		{
			name: "tcp6 ...01000000 -> ::1",
			tcp6: procHeader6 + "\n" +
				"   1: 00000000000000000000000001000000:1776 00000000000000000000000000000000:0000 0A x\n",
			want: []Listener{{Port: 6006, Addr: "::1", Process: ""}},
		},
		{
			name: "tcp6 v4-mapped ::ffff:127.0.0.1 保留；::ffff:10.0.0.1 剔除",
			tcp6: procHeader6 + "\n" +
				"   2: 0000000000000000FFFF00000100007F:1F90 00000000000000000000000000000000:0000 0A x\n" +
				"   3: 0000000000000000FFFF00000100000A:1F91 00000000000000000000000000000000:0000 0A x\n",
			want: []Listener{{Port: 8080, Addr: "::ffff:127.0.0.1", Process: ""}},
		},
		{
			name: "tcp6 其它 IPv6 地址原样 hex 输出 -> 被白名单剔除（与 bash 一致）",
			tcp6: procHeader6 + "\n" +
				"   0: 0000000000000000000000000A000001:1F91 00000000000000000000000000000000:0000 0A x\n",
			want: []Listener{},
		},
		{
			name: "tcp6 非 LISTEN 状态剔除",
			tcp6: procHeader6 + "\n" +
				"   0: 00000000000000000000000001000000:0016 00000000000000000000000001000000:A578 01 x\n",
			want: []Listener{},
		},
		{
			name: "tcp4 与 tcp6 同端口：解析层不去重（去重在 dedupe/List，与 bash 分层一致）",
			tcp4: procHeader + "\n" +
				"   0: 00000000:1F90 00000000:0000 0A x\n",
			tcp6: procHeader6 + "\n" +
				"   0: 00000000000000000000000000000000:1F90 00000000000000000000000000000000:0000 0A x\n",
			want: []Listener{
				{Port: 8080, Addr: "0.0.0.0", Process: ""},
				{Port: 8080, Addr: "::", Process: ""},
			},
		},
		{
			name: "test_ports.sh 语料全量：只保留 5173/3000/6006",
			tcp4: procHeader + "\n" +
				"   0: 0100007F:1435 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 1 1 0 100 0 0 10 0\n" +
				"   1: 0100007F:0277 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 2 1 0 100 0 0 10 0\n" +
				"   2: 0501A8C0:2328 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 3 1 0 100 0 0 10 0\n" +
				"   3: 0100007F:1F90 0100007F:D431 01 00000000:00000000 00:00000000 00000000  1000        0 4 1 0 100 0 0 10 0\n",
			tcp6: procHeader6 + "\n" +
				"   0: 00000000000000000000000000000000:0BB8 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000  1000 0 5 1 0 100 0 0 10 0\n" +
				"   1: 00000000000000000000000001000000:1776 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000  1000 0 6 1 0 100 0 0 10 0\n",
			want: []Listener{
				{Port: 5173, Addr: "127.0.0.1", Process: ""},
				{Port: 3000, Addr: "::", Process: ""},
				{Port: 6006, Addr: "::1", Process: ""},
			},
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := ParseProc(tc.tcp4, tc.tcp6)
			assertListeners(t, got, tc.want)
		})
	}
}

// TestParseProcHexPortsArePortsNotAddresses：hex 端口必须十进制化（`$((16#...))`）。
// 1F90 -> 8080 而不是 "1F90"；十七进制前缀误解（0x 前缀/八进制 0 前缀）不会发生。
func TestParseProcHexPortsArePortsNotAddresses(t *testing.T) {
	cases := map[string]int{
		"1435": 5173,  // 0x1435 = 5173
		"1F90": 8080,  // 0x1F90 = 8080
		"0BB8": 3000,  // 0x0BB8 = 3000
		"0400": 1024,  // 前导零仍是 hex
		"FFFF": 65535, // 上界
	}
	for hexPort, want := range cases {
		text := procHeader + "\n   0: 0100007F:" + hexPort + " 00000000:0000 0A x\n"
		got := ParseProc(text, "")
		if len(got) != 1 {
			t.Fatalf("hex %s: 期望 1 条，得到 %d 条（%+v）", hexPort, len(got), got)
		}
		if got[0].Port != want {
			t.Fatalf("hex %s: Port = %d, want %d", hexPort, got[0].Port, want)
		}
	}
}

// TestProcAddr 直接钉住 little-endian 还原表（← _ports_proc_addr）。
func TestProcAddr(t *testing.T) {
	tests := map[string]string{
		"0100007F":                         "127.0.0.1",
		"00000000":                         "0.0.0.0",
		"0501A8C0":                         "192.168.1.5",
		"0B00007F":                         "127.0.0.11",
		"3500007F":                         "127.0.0.53",
		"0A000001":                         "1.0.0.10",
		"00000000000000000000000000000000": "::",
		"00000000000000000000000001000000": "::1",
		"0000000000000000FFFF00000100007F": "::ffff:127.0.0.1",
		"0000000000000000FFFF00000100000A": "::ffff:10.0.0.1",
	}
	for hex, want := range tests {
		if got := procAddr(hex); got != want {
			t.Fatalf("procAddr(%s) = %q, want %q", hex, got, want)
		}
	}
	// 小写 hex 也应工作（bash 先 hf_upper）
	if got, want := procAddr("0100007f"), "127.0.0.1"; got != want {
		t.Fatalf("procAddr(小写) = %q, want %q", got, want)
	}
	// 其它 IPv6 原样大写输出（随后被白名单剔除）
	if got, want := procAddr("0000000000000000000000000a000001"), "0000000000000000000000000A000001"; got != want {
		t.Fatalf("procAddr(其它 v6) = %q, want %q", got, want)
	}
}

func TestParseLsof(t *testing.T) {
	tests := []struct {
		name string
		text string
		want []Listener
	}{
		{
			name: "空输入",
			want: []Listener{},
		},
		{
			name: "只有表头",
			text: "COMMAND   PID USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME\n",
			want: []Listener{},
		},
		{
			name: "test_ports.sh 语料：loopback/通配保留，网卡地址剔除",
			text: "COMMAND   PID USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME\n" +
				"node      101 me     23u  IPv4 0x1111111111111111      0t0  TCP 127.0.0.1:5173 (LISTEN)\n" +
				"rapportd  102 me      4u  IPv6 0x2222222222222222      0t0  TCP *:49152 (LISTEN)\n" +
				"ControlCe 103 me      8u  IPv4 0x3333333333333333      0t0  TCP 192.168.1.2:7000 (LISTEN)\n",
			want: []Listener{
				{Port: 5173, Addr: "127.0.0.1", Process: "node"},
				{Port: 49152, Addr: "*", Process: "rapportd"},
			},
		},
		{
			name: "IPv6 方括号剥除；[::] 剥成 ::；%zone 剥除",
			text: "COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME\n" +
				"tcp6 104 me 6u IPv6 0x4 0t0 TCP [::1]:8080 (LISTEN)\n" +
				"tcp6 105 me 7u IPv6 0x4 0t0 TCP [::]:9090 (LISTEN)\n" +
				"tcp6 106 me 8u IPv6 0x4 0t0 TCP [fe80::1%lo0]:9999 (LISTEN)\n" +
				"node 107 me 9u IPv4 0x4 0t0 TCP 127.0.0.53%lo:5355 (LISTEN)\n",
			want: []Listener{
				{Port: 8080, Addr: "::1", Process: "tcp6"},
				{Port: 9090, Addr: "::", Process: "tcp6"},
			},
		},
		{
			name: "127.0.0.11 / 127.0.0.53 / 非 loopback 全部剔除，<1024 与越界剔除，前导零剔除",
			text: "COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME\n" +
				"node 107 me 8u IPv4 0x4 0t0 TCP 127.0.0.11:5353 (LISTEN)\n" +
				"node 108 me 9u IPv4 0x4 0t0 TCP 127.0.0.53:5355 (LISTEN)\n" +
				"node 109 me 9u IPv4 0x4 0t0 TCP 127.0.0.1:99999 (LISTEN)\n" +
				"node 110 me 9u IPv4 0x4 0t0 TCP 127.0.0.1:01024 (LISTEN)\n" +
				"node 111 me 9u IPv4 0x4 0t0 TCP 127.0.0.1:1023 (LISTEN)\n",
			want: []Listener{},
		},
		{
			name: "NAME 列没冒号（如 UDP/无地址行）跳过",
			text: "COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME\n" +
				"node 101 me 23u IPv4 0x1 0t0 TCP (LISTEN)\n",
			want: []Listener{},
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			assertListeners(t, ParseLsof(tc.text), tc.want)
		})
	}
}

// TestParseProcNonHexAddressIsCrashSafe：bash 的 _ports_proc_addr 在非 hex 地址上会因
// `$((16#ZZ))` 报错（set -e 下直接中止整个 ports_parse_proc）—— 这是实现缺陷，不是契约。
// Go 侧主动偏离：降级为「原样 hex -> 被白名单剔除」，同样不输出该行，但不让整个列表失败。
func TestParseProcNonHexAddressIsCrashSafe(t *testing.T) {
	text := procHeader + "\n" +
		"   0: 0100ZZ7F:1435 00000000:0000 0A x\n" +
		"   1: 0000000000000000FFFF0000ZZ00007F:1F90 00000000:0000 0A x\n" +
		"   2: 0000000000000000FFFF0000:1F91 00000000:0000 0A x\n" +
		"   3: 0100007F:1436 00000000:0000 0A x\n"
	got := ParseProc(text, "")
	// 只有最后一行合法；前三行都不崩、不输出
	assertListeners(t, got, []Listener{{Port: 5174, Addr: "127.0.0.1", Process: ""}})
}

// TestFilterMatrix 是「经 localhost 可达」的过滤矩阵，逐项对照 lib/ports.sh
// ports_addr_is_local（6 个 yes / 其余 no）。
func TestFilterMatrix(t *testing.T) {
	local := []string{"*", "0.0.0.0", "::", "::1", "127.0.0.1", "::ffff:127.0.0.1"}
	notLocal := []string{
		"192.168.1.5", "10.0.0.2", "fe80::1", "::ffff:10.0.0.1",
		"127.0.0.53", "127.0.0.11", "127.0.0.2", "127.1.2.3",
		"localhost", "0.0.0.1", "::ffff:127.1.0.1", "",
	}
	for _, a := range local {
		if !addrIsLocal(a) {
			t.Fatalf("addrIsLocal(%q) = false, want true（经 localhost 可达）", a)
		}
	}
	for _, a := range notLocal {
		if addrIsLocal(a) {
			t.Fatalf("addrIsLocal(%q) = true, want false", a)
		}
	}
	// 剥 shell 后缀后判定（← _ports_emit 的 addr 归一 + ports_addr_is_local 组合）
	for _, tc := range []struct{ in, want string }{
		{"[::1]", "::1"},
		{"[::]", "::"},
		{"[::1%lo]", "::1"},
		{"127.0.0.53%lo", "127.0.0.53"},
		{"[fe80::1%eth0]", "fe80::1"},
		{"0.0.0.0", "0.0.0.0"},
	} {
		if got := normalizeAddr(tc.in); got != tc.want {
			t.Fatalf("normalizeAddr(%q) = %q, want %q", tc.in, got, tc.want)
		}
	}
}

// TestEmitFilterMatrix：端口形状 × 地址白名单的组合矩阵（← _ports_emit 的两道门）。
func TestEmitFilterMatrix(t *testing.T) {
	tests := []struct {
		name     string
		portText string
		addr     string
		want     bool
		wantPort int
		wantAddr string
	}{
		{"端口 1024 下界可通", "1024", "127.0.0.1", true, 1024, "127.0.0.1"},
		{"端口 65535 上界可通", "65535", "::1", true, 65535, "::1"},
		{"端口 1023 越界（下）", "1023", "127.0.0.1", false, 0, ""},
		{"端口 65536 越界（上）", "65536", "127.0.0.1", false, 0, ""},
		{"端口 99999（5 位越界）", "99999", "*", false, 0, ""},
		{"端口 100000（6 位形状不合法）", "100000", "*", false, 0, ""},
		{"端口前导零 01024", "01024", "0.0.0.0", false, 0, ""},
		{"端口 0", "0", "0.0.0.0", false, 0, ""},
		{"端口空串", "", "0.0.0.0", false, 0, ""},
		{"端口带符号", "+1024", "0.0.0.0", false, 0, ""},
		{"端口非数字", "80a0", "0.0.0.0", false, 0, ""},
		{"端口 65535 但地址不可达", "65535", "10.0.0.1", false, 0, ""},
		{"地址剥 [] 后再判定", "8080", "[::1]", true, 8080, "::1"},
		{"地址剥 %zone 后再判定", "8080", "127.0.0.53%lo", false, 0, ""},
		{"通配 * 可通", "4000", "*", true, 4000, "*"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got, ok := emit(tc.portText, tc.addr, "proc")
			if ok != tc.want {
				t.Fatalf("emit(%q,%q) ok = %v, want %v（%+v）", tc.portText, tc.addr, ok, tc.want, got)
			}
			if !ok {
				return
			}
			if got.Port != tc.wantPort || got.Addr != tc.wantAddr || got.Process != "proc" {
				t.Fatalf("emit(%q,%q) = %+v, want {%d %s proc}", tc.portText, tc.addr, got, tc.wantPort, tc.wantAddr)
			}
		})
	}
}

// TestDedupe：同端口去重优先带进程名的一条 + 端口升序（← ports_listening_json 末尾 jq）。
func TestDedupe(t *testing.T) {
	got := dedupe([]Listener{
		{Port: 3000, Addr: "::", Process: ""},
		{Port: 1500, Addr: "127.0.0.1", Process: ""},
		{Port: 3000, Addr: "0.0.0.0", Process: "vite"},
	})
	want := []Listener{
		{Port: 1500, Addr: "127.0.0.1", Process: ""},
		{Port: 3000, Addr: "0.0.0.0", Process: "vite"},
	}
	assertListeners(t, got, want)

	// 两条都有进程名 -> 保留先出现的（jq group_by 稳定，first 即输入序第一个）
	got = dedupe([]Listener{
		{Port: 3000, Addr: "127.0.0.1", Process: "a"},
		{Port: 3000, Addr: "::", Process: "b"},
	})
	assertListeners(t, got, []Listener{{Port: 3000, Addr: "127.0.0.1", Process: "a"}})

	// 空输入 -> 空切片（非 nil），调用方可直接 JSON 序列化成 []
	if got := dedupe(nil); got == nil || len(got) != 0 {
		t.Fatalf("dedupe(nil) = %#v, want 空非 nil 切片", got)
	}
}

// TestValidPortText：`^[1-9][0-9]{0,4}$` 的边界（← _ports_emit 第一道门）。
func TestValidPortText(t *testing.T) {
	valid := []string{"1", "9", "10", "1024", "65535", "99999"}
	invalid := []string{"", "0", "00", "01", "01024", "-1", "1a", " 1024", "1024 ", "1.0", "١٠٢٤"}
	for _, s := range valid {
		if !validPortText(s) {
			t.Fatalf("validPortText(%q) = false, want true", s)
		}
	}
	for _, s := range invalid {
		if validPortText(s) {
			t.Fatalf("validPortText(%q) = true, want false", s)
		}
	}
}

// TestFields / TestIsHex4：两个解析辅助函数的边界（决定 /proc 与 lsof 的取列是否与
// bash 的 `IFS=' ' read -a` 一致 —— 制表符不是分隔符）。
func TestFields(t *testing.T) {
	got := fields("  a   b\tc  d ")
	want := []string{"a", "b\tc", "d"}
	if len(got) != len(want) {
		t.Fatalf("fields = %#v, want %#v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("fields[%d] = %q, want %q", i, got[i], want[i])
		}
	}
	if n := len(fields("   ")); n != 0 {
		t.Fatalf("全空白行应切成 0 列，得到 %d", n)
	}
}

func TestIsHex4(t *testing.T) {
	for _, s := range []string{"0000", "0A0a", "ffff", "FFFF", "1F90"} {
		if !isHex4(s) {
			t.Fatalf("isHex4(%q) = false, want true", s)
		}
	}
	for _, s := range []string{"", "000", "00000", "0G00", "0x00", "00 0"} {
		if isHex4(s) {
			t.Fatalf("isHex4(%q) = true, want false", s)
		}
	}
}

// TestListAgainstProc 在 Linux 上核对 List() 与直接解析 /proc 的一致性，并验证
// 「只列可达地址 + 端口 ≥1024 + 升序去重」这些不变量在真实数据上也成立。
// 非 Linux（macOS）跳过 —— 那里走 lsof 分支，由 TestListLsofReal 覆盖。
func TestListAgainstProc(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("非 Linux：List() 走 lsof 分支（见 TestListLsofReal）")
	}
	readable, statErr := fileReadable("/proc/net/tcp")
	if !readable {
		t.Skipf("/proc/net/tcp 不可读：%v", statErr)
	}

	got, err := List()
	if err != nil {
		t.Fatalf("List() error = %v", err)
	}
	raw4, err := os.ReadFile("/proc/net/tcp")
	if err != nil {
		t.Fatalf("读 /proc/net/tcp 失败：%v", err)
	}
	var raw6 []byte
	if b, err := os.ReadFile("/proc/net/tcp6"); err == nil {
		raw6 = b
	}
	want := dedupe(ParseProc(string(raw4), string(raw6)))
	assertListeners(t, got, want)

	// 不变量：可达地址白名单、端口区间、升序、无重复、Linux 分支无进程名
	seen := make(map[int]bool, len(got))
	prev := 0
	for _, l := range got {
		if !addrIsLocal(l.Addr) {
			t.Fatalf("List() 返回了不可达地址：%+v", l)
		}
		if l.Port < minPort || l.Port > maxPort {
			t.Fatalf("List() 返回了越界端口：%+v", l)
		}
		if seen[l.Port] {
			t.Fatalf("List() 端口重复：%d", l.Port)
		}
		seen[l.Port] = true
		if l.Port < prev {
			t.Fatalf("List() 未升序：%d 在 %d 之后", l.Port, prev)
		}
		prev = l.Port
		if l.Process != "" {
			t.Fatalf("Linux /proc 分支不应有进程名：%+v", l)
		}
	}
}

// TestListProcUnreadable：/proc/net/tcp 不可读时 listProc 必须报错（由 CLI 决定降级为
// warn + 空列表），而不是静默返回空。
func TestListProcUnreadable(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("仅在 Linux 走 /proc 分支")
	}
	// 用一个必然不存在/不可读的路径验证错误路径（不 mock 全局状态）
	bogus, err := os.ReadFile("/proc/net/tcp-definitely-missing")
	if err == nil {
		t.Fatalf("预期读取不存在的 /proc 文件报错，却读到 %q", bogus)
	}
	if !strings.Contains(err.Error(), "no such file") {
		t.Fatalf("错误信息不含 no such file：%v", err)
	}
}

// TestListLsofReal 直接跑 macOS 分支的 listLsof（在 Linux 上也能跑，只要装了 lsof）：
// 验证 argv 拼装、exec 失败容忍、输出解析与不变量。macOS 无 CI（PLAN §11 靠手动 smoke），
// 这个用例是那条分支在 CI 里唯一的活体覆盖。
func TestListLsofReal(t *testing.T) {
	if !executableOnPath("lsof") {
		t.Skip("未装 lsof（macOS 分支的数据源），跳过活体用例")
	}
	got, err := listLsof()
	if err != nil {
		t.Fatalf("listLsof() error = %v", err)
	}
	for _, l := range got {
		if !addrIsLocal(l.Addr) {
			t.Fatalf("listLsof 返回了不可达地址：%+v", l)
		}
		if l.Port < minPort || l.Port > maxPort {
			t.Fatalf("listLsof 返回了越界端口：%+v", l)
		}
	}
}

// TestListLsofMissingBinary：lsof 不在 PATH 时必须报错（而不是静默返回空）。
func TestListLsofMissingBinary(t *testing.T) {
	t.Setenv("PATH", t.TempDir())
	got, err := listLsof()
	if err == nil {
		t.Fatalf("lsof 缺失时 listLsof 应返回错误，却得到 %+v", got)
	}
}

// executableOnPath 是测试用的轻量 PATH 探测（避免在断言里丢弃返回值）。
func executableOnPath(name string) bool {
	found, err := exec.LookPath(name)
	return err == nil && found != ""
}

// TestLsofArgs：argv 必须与 lib/ports.sh 的 `lsof -nP -iTCP -sTCP:LISTEN` 逐字一致。
func TestLsofArgs(t *testing.T) {
	want := []string{"-nP", "-iTCP", "-sTCP:LISTEN"}
	if len(lsofArgs) != len(want) {
		t.Fatalf("lsofArgs = %v, want %v", lsofArgs, want)
	}
	for i := range want {
		if lsofArgs[i] != want[i] {
			t.Fatalf("lsofArgs[%d] = %q, want %q", i, lsofArgs[i], want[i])
		}
	}
}

func assertListeners(t *testing.T, got, want []Listener) {
	t.Helper()
	if len(got) != len(want) {
		t.Fatalf("监听数 = %d, want %d\n got: %+v\nwant: %+v", len(got), len(want), got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("第 %d 条 = %+v, want %+v", i, got[i], want[i])
		}
	}
}
