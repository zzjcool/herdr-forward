package machine

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestNormalizeSshTarget 表驱动覆盖 PLAN §8 要求的全部形态（含非法输入）。
// 期望值对照 lib/machine.sh 的 machine_normalize_ssh_target，外加「非法 → 错误」契约。
func TestNormalizeSshTarget(t *testing.T) {
	tests := []struct {
		name    string
		in      string
		want    string
		wantErr bool
	}{
		{name: "裸 host 补 :22", in: "host", want: "host:22"},
		{name: "user@host 补 :22", in: "user@host", want: "user@host:22"},
		{name: "显式端口原样", in: "user@host:2222", want: "user@host:2222"},
		{name: "显式 :22 原样", in: "user@host:22", want: "user@host:22"},
		{name: "纯 host:port 原样", in: "10.0.0.9:2200", want: "10.0.0.9:2200"},
		{name: "IPv6 带 user 与端口原样", in: "user@[::1]:22", want: "user@[::1]:22"},
		{name: "IPv6 带 user 与非常规端口原样", in: "user@[2001:db8::1]:2222", want: "user@[2001:db8::1]:2222"},
		{name: "裸 [::1] 补 :22", in: "[::1]", want: "[::1]:22"},
		{name: "裸 [2001:db8::1] 补 :22", in: "[2001:db8::1]", want: "[2001:db8::1]:22"},
		{name: "方括号 + 端口原样", in: "[::1]:2222", want: "[::1]:2222"},
		{name: "域名", in: "gpu-box.example.com", want: "gpu-box.example.com:22"},
		{name: "含 user 的域名", in: "bob@10.0.0.9", want: "bob@10.0.0.9:22"},
		{name: "端口 1 合法", in: "host:1", want: "host:1"},
		{name: "端口 65535 合法", in: "host:65535", want: "host:65535"},

		{name: "空串", in: "", wantErr: true},
		{name: "端口非数字", in: "host:ssh", wantErr: true},
		{name: "端口为空", in: "host:", wantErr: true},
		{name: "端口前导 + 号", in: "host:+22", wantErr: true},
		{name: "端口 0 越界", in: "host:0", wantErr: true},
		{name: "端口 65536 越界", in: "host:65536", wantErr: true},
		{name: "缺主机名（只有端口）", in: ":2222", wantErr: true},
		{name: "裸 IPv6 无方括号", in: "::1", wantErr: true},
		{name: "裸 IPv6 多冒号", in: "2001:db8::1", wantErr: true},
		{name: "方括号未闭合", in: "[::1", wantErr: true},
		{name: "方括号后非法内容", in: "[::1]x", wantErr: true},
		{name: "方括号后空冒号", in: "[::1]:", wantErr: true},
		{name: "方括号空主机", in: "[]:22", wantErr: true},
		{name: "方括号出现在 user 后（非法形态）", in: "user@[::1", wantErr: true},
		{name: "方括号位置非法", in: "us[er@host", wantErr: true},
		{name: "含空白", in: "user@host :22", wantErr: true},
		{name: "含制表符", in: "user\t@host", wantErr: true},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got, err := NormalizeSshTarget(tc.in)
			if tc.wantErr {
				if err == nil {
					t.Fatalf("NormalizeSshTarget(%q) = %q, want error", tc.in, got)
				}
				return
			}
			if err != nil {
				t.Fatalf("NormalizeSshTarget(%q) unexpected error: %v", tc.in, err)
			}
			if got != tc.want {
				t.Fatalf("NormalizeSshTarget(%q) = %q, want %q", tc.in, got, tc.want)
			}
		})
	}
}

// TestNormalizeSshTargetIdempotent：归一化结果再归一化必须稳定（避免 `:22:22` 类 bug）。
func TestNormalizeSshTargetIdempotent(t *testing.T) {
	for _, in := range []string{"host:22", "user@host:2222", "[::1]:22", "user@[::1]:22"} {
		once, err := NormalizeSshTarget(in)
		if err != nil {
			t.Fatalf("NormalizeSshTarget(%q) error: %v", in, err)
		}
		twice, err := NormalizeSshTarget(once)
		if err != nil {
			t.Fatalf("NormalizeSshTarget(%q) (second pass) error: %v", once, err)
		}
		if once != twice {
			t.Fatalf("normalize 不幂等: %q -> %q -> %q", in, once, twice)
		}
	}
}

// writeToml 在临时目录里写 machines.toml 并把 HERDR_PLUGIN_CONFIG_DIR 指向它。
func writeToml(t *testing.T, content string) string {
	t.Helper()
	dir := t.TempDir()
	if content != "" {
		if err := os.WriteFile(filepath.Join(dir, "machines.toml"), []byte(content), 0o600); err != nil {
			t.Fatalf("写 fixture 失败: %v", err)
		}
	}
	t.Setenv("HERDR_PLUGIN_CONFIG_DIR", dir)
	return dir
}

// TestTomlPathResolution 覆盖 machines.toml 路径回退链（lib/machine.sh machines_toml_path）。
func TestTomlPathResolution(t *testing.T) {
	t.Run("HERDR_PLUGIN_CONFIG_DIR 优先", func(t *testing.T) {
		t.Setenv("HERDR_PLUGIN_CONFIG_DIR", "/tmp/x-cfg")
		t.Setenv("XDG_CONFIG_HOME", "/tmp/x-xdg")
		t.Setenv("HOME", "/tmp/x-home")
		if got, want := TomlPath(), "/tmp/x-cfg/machines.toml"; got != want {
			t.Fatalf("TomlPath() = %q, want %q", got, want)
		}
	})
	t.Run("退回 XDG_CONFIG_HOME", func(t *testing.T) {
		t.Setenv("HERDR_PLUGIN_CONFIG_DIR", "")
		t.Setenv("XDG_CONFIG_HOME", "/tmp/x-xdg")
		t.Setenv("HOME", "/tmp/x-home")
		if got, want := TomlPath(), "/tmp/x-xdg/herdr-forward/machines.toml"; got != want {
			t.Fatalf("TomlPath() = %q, want %q", got, want)
		}
	})
	t.Run("退回 HOME/.config", func(t *testing.T) {
		t.Setenv("HERDR_PLUGIN_CONFIG_DIR", "")
		t.Setenv("XDG_CONFIG_HOME", "")
		t.Setenv("HOME", "/tmp/x-home")
		if got, want := TomlPath(), "/tmp/x-home/.config/herdr-forward/machines.toml"; got != want {
			t.Fatalf("TomlPath() = %q, want %q", got, want)
		}
	})
	t.Run("HOME 也缺失退 /tmp", func(t *testing.T) {
		t.Setenv("HERDR_PLUGIN_CONFIG_DIR", "")
		t.Setenv("XDG_CONFIG_HOME", "")
		t.Setenv("HOME", "")
		if got, want := TomlPath(), "/tmp/.config/herdr-forward/machines.toml"; got != want {
			t.Fatalf("TomlPath() = %q, want %q", got, want)
		}
	})
}

const validToml = `# herdr-forward saved machines (fixture)
[machines.gpu-box]
ssh_target = "user@gpu-box.example.com"

[machines.lab]
ssh_target = "bob@10.0.0.9:2200"

[machines.local]
ssh_target = "alice@127.0.0.1:22"

[machines.v6]
ssh_target = "user@[::1]:2222"
`

func TestResolveFromToml(t *testing.T) {
	t.Run("正常解析并归一化", func(t *testing.T) {
		writeToml(t, validToml)
		for _, tc := range []struct{ label, want string }{
			{"gpu-box", "user@gpu-box.example.com:22"},
			{"lab", "bob@10.0.0.9:2200"},
			{"local", "alice@127.0.0.1:22"},
			{"v6", "user@[::1]:2222"},
		} {
			got, err := ResolveFromToml(tc.label)
			if err != nil {
				t.Fatalf("ResolveFromToml(%q) error: %v", tc.label, err)
			}
			if got != tc.want {
				t.Fatalf("ResolveFromToml(%q) = %q, want %q", tc.label, got, tc.want)
			}
		}
	})

	t.Run("未知 key 被忽略（对照 bash log debug）", func(t *testing.T) {
		writeToml(t, "[machines.m]\nnoise = \"x\"\nssh_target = \"u@h\"\n")
		got, err := ResolveFromToml("m")
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if got != "u@h:22" {
			t.Fatalf("got %q, want u@h:22", got)
		}
	})

	t.Run("重复 ssh_target：第一个胜出（TOML 语义下等价于 bash 的 break）", func(t *testing.T) {
		writeToml(t, "[machines.m]\nssh_target = \"u@first\"\nssh_target = \"u@second\"\n")
		// 真 TOML 解析器对同段重复键会报错；此时属「损坏」档（同为 die 4 语义）。
		got, err := ResolveFromToml("m")
		if err == nil && got != "u@first:22" {
			t.Fatalf("got %q, want u@first:22（或损坏报错）", got)
		}
		if err != nil && !isUnresolved(err) {
			t.Fatalf("err = %v, want ErrMachineUnresolved 包装", err)
		}
	})

	t.Run("嵌套段名 [machines.a.b] 与带点 label 等价（bash 正则把 a.b 当整段 label）", func(t *testing.T) {
		writeToml(t, "[machines.a.b]\nssh_target = \"u@nested\"\n")
		got, err := ResolveFromToml("a.b")
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if got != "u@nested:22" {
			t.Fatalf("got %q, want u@nested:22", got)
		}
	})

	t.Run("引号形式 [machines.\"a.b\"] 也能解析", func(t *testing.T) {
		writeToml(t, "[machines.\"a.b\"]\nssh_target = \"u@quoted\"\n")
		got, err := ResolveFromToml("a.b")
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if got != "u@quoted:22" {
			t.Fatalf("got %q, want u@quoted:22", got)
		}
	})

	t.Run("文件缺失", func(t *testing.T) {
		writeToml(t, "") // 只建目录，不写文件
		_, err := ResolveFromToml("gpu-box")
		assertUnresolved(t, err, "machines.toml")
	})

	t.Run("损坏：未闭合引号", func(t *testing.T) {
		writeToml(t, "[machines.broken]\nssh_target = \"user@host\n")
		_, err := ResolveFromToml("broken")
		assertUnresolved(t, err, "")
	})

	t.Run("损坏：非 TOML 垃圾", func(t *testing.T) {
		writeToml(t, "this is not = = toml\n")
		_, err := ResolveFromToml("broken")
		assertUnresolved(t, err, "")
	})

	t.Run("损坏：未加引号的值", func(t *testing.T) {
		writeToml(t, "[machines.broken]\nssh_target = user@host\n")
		_, err := ResolveFromToml("broken")
		assertUnresolved(t, err, "")
	})

	t.Run("ssh_target 非字符串类型", func(t *testing.T) {
		writeToml(t, "[machines.broken]\nssh_target = 22\n")
		_, err := ResolveFromToml("broken")
		assertUnresolved(t, err, "quoted string")
	})

	t.Run("ssh_target 为空串", func(t *testing.T) {
		writeToml(t, "[machines.broken]\nssh_target = \"\"\n")
		_, err := ResolveFromToml("broken")
		assertUnresolved(t, err, "quoted string")
	})

	t.Run("段存在但缺 ssh_target", func(t *testing.T) {
		writeToml(t, "[machines.broken]\nother = \"x\"\n")
		_, err := ResolveFromToml("broken")
		assertUnresolved(t, err, "has no ssh_target")
	})

	t.Run("ssh_target 不像 user@host", func(t *testing.T) {
		writeToml(t, "[machines.broken]\nssh_target = \"host.example.com\"\n")
		_, err := ResolveFromToml("broken")
		assertUnresolved(t, err, "must look like user@host")
	})

	t.Run("ssh_target 归一化失败（端口非法）", func(t *testing.T) {
		writeToml(t, "[machines.broken]\nssh_target = \"u@h:abc\"\n")
		_, err := ResolveFromToml("broken")
		assertUnresolved(t, err, "端口非法")
	})

	t.Run("label 不存在：列出可用 label（字典序）", func(t *testing.T) {
		writeToml(t, validToml)
		_, err := ResolveFromToml("nope")
		if !isUnresolved(err) {
			t.Fatalf("err = %v, want ErrMachineUnresolved", err)
		}
		msg := err.Error()
		for _, want := range []string{"nope", "gpu-box", "lab", "local", "v6", "available labels:"} {
			if !strings.Contains(msg, want) {
				t.Fatalf("错误信息缺少 %q: %s", want, msg)
			}
		}
	})

	t.Run("label 不存在且无任何 machines 段", func(t *testing.T) {
		writeToml(t, "# 空文件\n")
		_, err := ResolveFromToml("nope")
		assertUnresolved(t, err, "add a [machines.nope] section")
	})

	t.Run("空 label", func(t *testing.T) {
		writeToml(t, validToml)
		_, err := ResolveFromToml("")
		assertUnresolved(t, err, "missing label")
	})
}

// TestResolveFromTomlErrIsMachineUnresolved：所有失败路径都必须可被 errors.Is 判定
// （调用方映射 exit 4 的唯一依据）。
func TestResolveFromTomlErrIsMachineUnresolved(t *testing.T) {
	cases := []struct {
		name string
		toml string
		lbl  string
	}{
		{"缺失文件", "", "x"},
		{"损坏", "= = =\n", "x"},
		{"label 不存在", validToml, "x"},
		{"缺键", "[machines.x]\n", "x"},
		{"空 label", validToml, ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			writeToml(t, tc.toml)
			_, err := ResolveFromToml(tc.lbl)
			if !isUnresolved(err) {
				t.Fatalf("err = %v, want ErrMachineUnresolved", err)
			}
		})
	}
}

// isUnresolved 用 errors.Is 判定（调用方（internal/cli）映射 exit 4 的唯一依据）。
func isUnresolved(err error) bool {
	return errors.Is(err, ErrMachineUnresolved)
}

func assertUnresolved(t *testing.T, err error, substr string) {
	t.Helper()
	if err == nil {
		t.Fatalf("want ErrMachineUnresolved error, got nil")
	}
	if !isUnresolved(err) {
		t.Fatalf("err = %v, want ErrMachineUnresolved 包装", err)
	}
	if substr != "" && !strings.Contains(err.Error(), substr) {
		t.Fatalf("错误信息缺少 %q: %s", substr, err.Error())
	}
}
