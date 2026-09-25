package sshprobe

import (
	"strings"
	"testing"
)

// TestParseTarget 表驱动覆盖 lib/ssh-probe.sh 单测里出现的全部形态（含非法输入 → 错误）。
// 期望值对照 ssh_probe_parse_target 的 `<host> <port>` + HasPort 语义。
func TestParseTarget(t *testing.T) {
	tests := []struct {
		name    string
		in      string
		want    string // Target.String() = "<host> <port>"
		hasPort bool
		wantErr bool
	}{
		// --- 主路径：user@host[:port] ---
		{name: "user@host -> 默认 22", in: "user@host", want: "user@host 22", hasPort: false},
		{name: "user@host:2222 -> 保留 user@", in: "user@host:2222", want: "user@host 2222", hasPort: true},
		{name: "裸 host -> 默认 22", in: "db.internal", want: "db.internal 22"},
		{name: "host:22", in: "b-host:22", want: "b-host 22", hasPort: true},

		// --- ssh:// 形态（herdr machine add 真实数据；带 scheme 的串不能交给 ssh）---
		{name: "ssh://user@host:port（A 机真实形态）", in: "ssh://zheng@nj.rssyes.com:31415", want: "zheng@nj.rssyes.com 31415", hasPort: true},
		{name: "ssh://host（无 user/port）", in: "ssh://nj.rssyes.com", want: "nj.rssyes.com 22"},
		{name: "ssh://user@host（无端口）", in: "ssh://zheng@nj.rssyes.com", want: "zheng@nj.rssyes.com 22"},
		{name: "SSH:// 大写 scheme 也识别", in: "SSH://USER@HOST:22", want: "USER@HOST 22", hasPort: true},
		{name: "ssh:// + IPv6 方括号", in: "ssh://[2001:db8::1]:2222", want: "2001:db8::1 2222", hasPort: true},

		// --- IPv6 ---
		{name: "[v6]:2222 -> 去方括号", in: "[2001:db8::1]:2222", want: "2001:db8::1 2222", hasPort: true},
		{name: "[::1] 无端口 -> 22", in: "[::1]", want: "::1 22"},
		{name: "裸 IPv6 -> 整体当主机", in: "::1", want: "::1 22"},
		{name: "裸 IPv6（带 user）", in: "user@::1", want: "user@::1 22"},

		// --- 端口边界 ---
		{name: "端口 1", in: "host:1", want: "host 1", hasPort: true},
		{name: "端口 65535", in: "host:65535", want: "host 65535", hasPort: true},

		// --- 非法 ---
		{name: "空 target", in: "", wantErr: true},
		{name: "只有 scheme", in: "ssh://", wantErr: true},
		{name: "端口非数字", in: "user@host:ssh", wantErr: true},
		{name: "端口为空", in: "user@host:", wantErr: true},
		{name: "端口 0 越界", in: "host:0", wantErr: true},
		{name: "端口 65536 越界", in: "host:65536", wantErr: true},
		{name: "端口带 + 号", in: "host:+22", wantErr: true},
		{name: "方括号未闭合", in: "[::1", wantErr: true},
		{name: "方括号嵌套", in: "[[::1]]", wantErr: true},
		{name: "方括号后非法内容", in: "[::1]x", wantErr: true},
		{name: "方括号后空冒号", in: "[::1]:", wantErr: true},
		{name: "方括号空主机", in: "[]:22", wantErr: true},
		{name: "只有端口没有主机", in: ":2222", wantErr: true},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got, err := ParseTarget(tc.in)
			if tc.wantErr {
				if err == nil {
					t.Fatalf("ParseTarget(%q) = %+v, want error", tc.in, got)
				}
				if !strings.Contains(err.Error(), "ssh target") {
					t.Fatalf("错误信息应说明 ssh target 问题，got %q", err.Error())
				}
				return
			}
			if err != nil {
				t.Fatalf("ParseTarget(%q) unexpected error: %v", tc.in, err)
			}
			if got.String() != tc.want {
				t.Fatalf("ParseTarget(%q) = %q, want %q", tc.in, got.String(), tc.want)
			}
			if got.HasPort != tc.hasPort {
				t.Fatalf("ParseTarget(%q).HasPort = %v, want %v", tc.in, got.HasPort, tc.hasPort)
			}
		})
	}
}

// TestParseTargetSchemeStrippedRegression：Bug 3 回归锁 —— 任何 argv 结果里不得残留 ssh://。
func TestParseTargetSchemeStrippedRegression(t *testing.T) {
	inputs := []string{
		"ssh://zheng@nj.rssyes.com:31415",
		"ssh://nj.rssyes.com",
		"SSH://USER@HOST:22",
		"ssh://[2001:db8::1]:2222",
	}
	for _, in := range inputs {
		got, err := ParseTarget(in)
		if err != nil {
			t.Fatalf("ParseTarget(%q) error: %v", in, err)
		}
		if strings.Contains(got.Host, "ssh://") || strings.Contains(got.String(), "ssh://") {
			t.Fatalf("ParseTarget(%q) 结果仍含 scheme: %+v（ssh 会 Could not resolve）", in, got)
		}
	}
}

// TestParseTargetRealTargets：五台真实 A 机 target（tests/unit/test_machines_uri_targets.sh 语料）
// 必须「不报错 + 输出两字段 + 端口数字」。
func TestParseTargetRealTargets(t *testing.T) {
	cases := []struct{ in, want string }{
		{"ssh://zheng@nj.rssyes.com:31415", "zheng@nj.rssyes.com 31415"},
		{"ssh://root@devcloud.zzj.cool:2222", "root@devcloud.zzj.cool 2222"},
		{"ssh://zzjcool@nj.rssyes.com:31416", "zzjcool@nj.rssyes.com 31416"},
		{"ssh://chieh@nj.rssyes.com:31417", "chieh@nj.rssyes.com 31417"},
		{"ssh://root@zhijiezheng-any4.devcloud.woa.com:36000", "root@zhijiezheng-any4.devcloud.woa.com 36000"},
	}
	for _, tc := range cases {
		got, err := ParseTarget(tc.in)
		if err != nil {
			t.Fatalf("ParseTarget(%q) error: %v", tc.in, err)
		}
		if got.String() != tc.want {
			t.Fatalf("ParseTarget(%q) = %q, want %q", tc.in, got.String(), tc.want)
		}
	}
}

// TestParseTargetDoesNotMutateInput：纯函数性质（无全局状态、无副作用）。
func TestParseTargetDoesNotMutateInput(t *testing.T) {
	for _, in := range []string{"user@host", "ssh://u@h:2222", "[::1]", "::1"} {
		before := in
		_, _ = ParseTarget(in)
		if in != before {
			t.Fatalf("ParseTarget 修改了输入: %q -> %q", before, in)
		}
	}
}
