package machine

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// fakeHerdr 在临时目录里写一个假 herdr 可执行文件（shell 脚本），返回其路径。
// 脚本行为由 body 决定；三态（正常 JSON / 非 JSON / exit 非 0）都用它模拟，绝不依赖真 herdr。
func fakeHerdr(t *testing.T, body string) string {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "herdr")
	script := "#!/bin/sh\n" + body + "\n"
	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		t.Fatalf("写假 herdr 失败: %v", err)
	}
	return path
}

// captureStderr 在测试期间截获 os.Stderr（warn 必须镜像 stderr）。
func captureStderr(t *testing.T, fn func()) string {
	t.Helper()
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatalf("os.Pipe: %v", err)
	}
	orig := os.Stderr
	os.Stderr = w
	defer func() { os.Stderr = orig }()

	done := make(chan string, 1)
	go func() {
		buf := make([]byte, 0, 4096)
		tmp := make([]byte, 1024)
		for {
			n, err := r.Read(tmp)
			buf = append(buf, tmp[:n]...)
			if err != nil {
				break
			}
		}
		done <- string(buf)
	}()

	fn()
	_ = w.Close()
	got := <-done
	_ = r.Close()
	return got
}

// normalizeJSON 把输出按 JSON 解码再压缩比较（避免依赖键序/空白）。
func normalizeJSON(t *testing.T, raw []byte) any {
	t.Helper()
	var v any
	if err := json.Unmarshal(raw, &v); err != nil {
		t.Fatalf("输出不是合法 JSON: %v (%q)", err, string(raw))
	}
	return v
}

func TestHerdrMachineListJSONPassthrough(t *testing.T) {
	cases := []struct {
		name string
		body string
		want string // 期望的紧凑 JSON（按值比较）
	}{
		{
			name: "裸数组原样透传（含 enabled/label 等事实字段）",
			body: `printf '%s\n' '[{"id":"m1","label":"gpu","target":"user@h:22","enabled":true},{"id":2,"target":"ssh://u@h2:2222"}]'`,
			want: `[{"id":"m1","label":"gpu","target":"user@h:22","enabled":true},{"id":2,"target":"ssh://u@h2:2222"}]`,
		},
		{
			name: "包裹层 .machines",
			body: `printf '%s\n' '{"machines":[{"id":"m1"}]}'`,
			want: `[{"id":"m1"}]`,
		},
		{
			name: "包裹层 .result.machines",
			body: `printf '%s\n' '{"result":{"machines":[{"id":"m1"},{"id":"m2"}]}}'`,
			want: `[{"id":"m1"},{"id":"m2"}]`,
		},
		{
			name: "包裹层 .result 数组",
			body: `printf '%s\n' '{"result":[{"id":"m1"}]}'`,
			want: `[{"id":"m1"}]`,
		},
		{
			name: "过滤非对象条目与 id 缺失/null 的条目",
			body: `printf '%s\n' '[{"id":"keep"},"string",42,{"label":"no-id"},{"id":null},{"id":"keep2"}]'`,
			want: `[{"id":"keep"},{"id":"keep2"}]`,
		},
		{
			name: "空数组保持 []",
			body: `printf '[]\n'`,
			want: `[]`,
		},
		{
			name: "空对象 .machines 数组",
			body: `printf '%s\n' '{"machines":[]}'`,
			want: `[]`,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			bin := fakeHerdr(t, tc.body)
			t.Setenv("HERDR_PLUGIN_STATE_DIR", t.TempDir())
			var got []byte
			stderr := captureStderr(t, func() { got = HerdrMachineListJSON(bin) })

			if stderr != "" {
				t.Fatalf("正常路径不应有 warn，stderr=%q", stderr)
			}
			if !strings.HasSuffix(string(got), "\n") {
				t.Fatalf("输出必须以换行结尾（与 bash printf 一致）: %q", got)
			}
			want := normalizeJSON(t, []byte(tc.want))
			have := normalizeJSON(t, got)
			if !jsonEqual(want, have) {
				t.Fatalf("输出 = %s, want %s", strings.TrimSpace(string(got)), tc.want)
			}
		})
	}
}

// TestHerdrMachineListJSONDegraded 三态降级：非 JSON / exit 非 0 / 二进制缺失 → "[]" + warn，不 panic。
func TestHerdrMachineListJSONDegraded(t *testing.T) {
	t.Run("输出非 JSON", func(t *testing.T) {
		bin := fakeHerdr(t, `printf 'not json at all\n'`)
		t.Setenv("HERDR_PLUGIN_STATE_DIR", t.TempDir())
		var got []byte
		stderr := captureStderr(t, func() { got = HerdrMachineListJSON(bin) })
		if string(got) != "[]\n" {
			t.Fatalf("got %q, want %q", got, "[]\n")
		}
		if !strings.Contains(stderr, "warn") || !strings.Contains(stderr, "不是预期的 JSON 数组") {
			t.Fatalf("缺少 warn: %q", stderr)
		}
	})

	t.Run("JSON 但不含 machine 数组（对象缺字段）", func(t *testing.T) {
		bin := fakeHerdr(t, `printf '%s\n' '{"foo":1}'`)
		t.Setenv("HERDR_PLUGIN_STATE_DIR", t.TempDir())
		var got []byte
		stderr := captureStderr(t, func() { got = HerdrMachineListJSON(bin) })
		if string(got) != "[]\n" {
			t.Fatalf("got %q, want %q", got, "[]\n")
		}
		if !strings.Contains(stderr, "不是预期的 JSON 数组") {
			t.Fatalf("缺少 warn: %q", stderr)
		}
	})

	t.Run("exit 非 0：stderr 摘要进 warn", func(t *testing.T) {
		bin := fakeHerdr(t, `printf 'herdr: daemon not running\n' >&2; exit 3`)
		t.Setenv("HERDR_PLUGIN_STATE_DIR", t.TempDir())
		var got []byte
		stderr := captureStderr(t, func() { got = HerdrMachineListJSON(bin) })
		if string(got) != "[]\n" {
			t.Fatalf("got %q, want %q", got, "[]\n")
		}
		for _, want := range []string{"rc=3", "herdr stderr: herdr: daemon not running"} {
			if !strings.Contains(stderr, want) {
				t.Fatalf("warn 缺少 %q: %q", want, stderr)
			}
		}
	})

	t.Run("exit 0 但输出为空", func(t *testing.T) {
		bin := fakeHerdr(t, `exit 0`)
		t.Setenv("HERDR_PLUGIN_STATE_DIR", t.TempDir())
		var got []byte
		stderr := captureStderr(t, func() { got = HerdrMachineListJSON(bin) })
		if string(got) != "[]\n" {
			t.Fatalf("got %q, want %q", got, "[]\n")
		}
		if !strings.Contains(stderr, "rc=0") {
			t.Fatalf("warn 缺少 rc=0: %q", stderr)
		}
	})

	t.Run("binPath 为空", func(t *testing.T) {
		t.Setenv("HERDR_PLUGIN_STATE_DIR", t.TempDir())
		var got []byte
		stderr := captureStderr(t, func() { got = HerdrMachineListJSON("") })
		if string(got) != "[]\n" {
			t.Fatalf("got %q, want %q", got, "[]\n")
		}
		if !strings.Contains(stderr, "未设置 HERDR_BIN_PATH") {
			t.Fatalf("缺少 warn: %q", stderr)
		}
	})

	t.Run("binPath 不存在", func(t *testing.T) {
		t.Setenv("HERDR_PLUGIN_STATE_DIR", t.TempDir())
		var got []byte
		stderr := captureStderr(t, func() { got = HerdrMachineListJSON(filepath.Join(t.TempDir(), "nope")) })
		if string(got) != "[]\n" {
			t.Fatalf("got %q, want %q", got, "[]\n")
		}
		if !strings.Contains(stderr, "不可执行") {
			t.Fatalf("缺少 warn: %q", stderr)
		}
	})

	t.Run("binPath 存在但不可执行", func(t *testing.T) {
		path := filepath.Join(t.TempDir(), "herdr")
		if err := os.WriteFile(path, []byte("#!/bin/sh\nexit 0\n"), 0o644); err != nil {
			t.Fatalf("写文件失败: %v", err)
		}
		t.Setenv("HERDR_PLUGIN_STATE_DIR", t.TempDir())
		var got []byte
		stderr := captureStderr(t, func() { got = HerdrMachineListJSON(path) })
		if string(got) != "[]\n" {
			t.Fatalf("got %q, want %q", got, "[]\n")
		}
		if !strings.Contains(stderr, "不可执行") {
			t.Fatalf("缺少 warn: %q", stderr)
		}
	})
}

// TestHerdrMachineListJSONWarnGoesToLog：warn 除 stderr 外必须落 logs/forward.log（排障线索）。
func TestHerdrMachineListJSONWarnGoesToLog(t *testing.T) {
	stateDir := t.TempDir()
	t.Setenv("HERDR_PLUGIN_STATE_DIR", stateDir)
	bin := fakeHerdr(t, `printf 'not json\n'`)
	captureStderr(t, func() { _ = HerdrMachineListJSON(bin) })

	data, err := os.ReadFile(filepath.Join(stateDir, "logs", "forward.log"))
	if err != nil {
		t.Fatalf("读 forward.log 失败: %v", err)
	}
	if !strings.Contains(string(data), "warn:") || !strings.Contains(string(data), "不是预期的 JSON 数组") {
		t.Fatalf("日志缺少 warn 行: %q", data)
	}
}

// TestHerdrMachineListJSONArgv 断言真实 argv 形状：`<bin> machine list --json`。
func TestHerdrMachineListJSONArgv(t *testing.T) {
	argvFile := filepath.Join(t.TempDir(), "argv")
	bin := fakeHerdr(t, `printf '%s\n' "$@" > `+argvFile+`; printf '[]\n'`)
	t.Setenv("HERDR_PLUGIN_STATE_DIR", t.TempDir())
	captureStderr(t, func() { _ = HerdrMachineListJSON(bin) })

	data, err := os.ReadFile(argvFile)
	if err != nil {
		t.Fatalf("读 argv 记录失败: %v", err)
	}
	if got := strings.TrimSpace(string(data)); got != "machine\nlist\n--json" {
		t.Fatalf("argv = %q, want %q", got, "machine\nlist\n--json")
	}
}

// jsonEqual 比较两个解码后的 JSON 值（map/slice/标量递归）。
func jsonEqual(a, b any) bool {
	ab, err1 := json.Marshal(a)
	bb, err2 := json.Marshal(b)
	if err1 != nil || err2 != nil {
		return false
	}
	return string(ab) == string(bb)
}
