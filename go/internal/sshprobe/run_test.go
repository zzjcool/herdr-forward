// run_test.go —— ssh_probe_run / ssh_probe_plugin / kv_get 的单元测试（PLAN §8）。
//
// 手法与 tests/unit/test_ssh_probe.sh 一致：ssh / timeout 一律用 PATH 前置的**替身**
// （只记录 argv、按场景回放），**绝不真连任何主机**。
package sshprobe

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// fakeBin 造一个记录 argv + 按场景回放的假 ssh 替身，返回 (PATH 目录, argv 日志路径)。
func fakeBin(t *testing.T, scenario string) (string, string) {
	t.Helper()
	dir := t.TempDir()
	logPath := filepath.Join(dir, "argv.log")
	script := `#!/bin/sh
printf 'ARGV' >>"` + logPath + `"
for a in "$@"; do printf ' <%s>' "$a" >>"` + logPath + `"; done
printf '\n' >>"` + logPath + `"
scenario="` + scenario + `"
case "$scenario" in
present)
  case "$*" in
  *"plugin list"*) printf '1 plugin installed:\n- %s (forward) enabled\n' "${SSH_SHIM_PLUGIN_ID:-zzjcool:forward}" ;;
  *) printf 'HF_ROOT=/home/b/plugin\nHF_STATE_DIR=/home/b/state\n' ;;
  esac
  ;;
present_default_state)
  case "$*" in
  *"plugin list"*) printf -- '- zzjcool:forward\n' ;;
  *) printf 'HF_ROOT=/home/b/plugin\nHF_DEFAULT_STATE=/home/b/default-state\n' ;;
  esac
  ;;
present_no_root)
  case "$*" in
  *"plugin list"*) printf -- '- zzjcool:forward\n' ;;
  *) printf 'HF_DEFAULT_STATE=/home/b/default-state\n' ;;
  esac
  ;;
absent) printf 'No plugins installed.\n' ;;
noherdr) printf 'HF_NO_HERDR\n' ;;
unreachable) printf 'ssh: connect to host b-host port 22: Connection refused\n' >&2; exit 255 ;;
esac
exit 0
`
	if err := os.WriteFile(filepath.Join(dir, "ssh"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	// timeout 替身：记录并把余下参数原样执行（让「有 timeout 前缀」变成可断言事实）
	timeoutScript := "#!/bin/sh\nprintf 'TIMEOUT <%s>' \"${1-}\" >>\"" + logPath + "\"\nshift\nexec \"$@\"\n"
	if err := os.WriteFile(filepath.Join(dir, "timeout"), []byte(timeoutScript), 0o755); err != nil {
		t.Fatal(err)
	}
	return dir, logPath
}

// withPATH 在测试期间把 PATH 前置到 dir。
func withPATH(t *testing.T, dir string) {
	t.Helper()
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
}

func readLog(t *testing.T, path string) string {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	return string(data)
}

func TestKVGet(t *testing.T) {
	text := "HF_STATUS=present\nHF_ROOT=/a/b\nHF_REASON=\n"
	cases := map[string]string{
		"HF_STATUS":  "present",
		"HF_ROOT":    "/a/b",
		"HF_REASON":  "",
		"HF_MISSING": "",
	}
	for key, want := range cases {
		if got := KVGet(text, key); got != want {
			t.Errorf("KVGet(%q) = %q, want %q", key, got, want)
		}
	}
	// 严格行首匹配：前导空格不算键
	if got := KVGet("  HF_ROOT=/x\n", "HF_ROOT"); got != "" {
		t.Errorf("前导空格不得算作键，got %q", got)
	}
	if got := KVGet(text, ""); got != "" {
		t.Errorf("空 KEY 应返回空串，got %q", got)
	}
}

func TestSSHProbeRunArgvShape(t *testing.T) {
	dir, logPath := fakeBin(t, "present")
	withPATH(t, dir)
	t.Setenv("SSH_PROBE_TIMEOUT", "")
	t.Setenv("SSH_CONNECT_TIMEOUT", "")

	rc, merged := SSHProbeRun("user@host:2222", "REMOTE_CMD_FIXTURE")
	if rc != 0 {
		t.Fatalf("rc = %d, want 0（stderr/echo 摘要：%s）", rc, merged)
	}
	log := readLog(t, logPath)
	// argv 形状：timeout 15 ssh -n -o BatchMode=yes -o ConnectTimeout=8 -p 2222 HOST CMD
	// （`ssh` 自己是 argv[0]，替身的 "$@" 里看不到它 —— 与 tests/unit/test_ssh_probe.sh 同一口径。）
	for _, want := range []string{"TIMEOUT <15>", "ARGV <-n>", "<BatchMode=yes>", "<ConnectTimeout=8>", "<-p>", "<2222>", "<user@host>", "<REMOTE_CMD_FIXTURE>"} {
		if !strings.Contains(log, want) {
			t.Errorf("argv 缺 %s\n完整：%s", want, log)
		}
	}
}

func TestSSHProbeRunOmitsPortWhenNotExplicit(t *testing.T) {
	dir, logPath := fakeBin(t, "present")
	withPATH(t, dir)

	_, _ = SSHProbeRun("user@host", "REMOTE_CMD_FIXTURE")
	log := readLog(t, logPath)
	if strings.Contains(log, "<-p>") {
		t.Errorf("裸 host 不应传 -p（交给 ssh_config）：%s", log)
	}
	if !strings.Contains(log, "<user@host>") {
		t.Errorf("host 应原样（含 user@ 前缀）：%s", log)
	}
}

func TestSSHProbeRunStripsSchemeAndPort(t *testing.T) {
	// A 机真实形态：herdr machine add 存的是 ssh://user@host:port（Bug 3 的回归锚点）
	dir, logPath := fakeBin(t, "present")
	withPATH(t, dir)

	_, _ = SSHProbeRun("ssh://zheng@nj.rssyes.com:31415", "CMD")
	log := readLog(t, logPath)
	if strings.Contains(log, "ssh://") {
		t.Errorf("交给 ssh 的实参不得带 scheme：%s", log)
	}
	if !strings.Contains(log, "<zheng@nj.rssyes.com>") {
		t.Errorf("host 应已剥 scheme：%s", log)
	}
	if !strings.Contains(log, "<-p>") || !strings.Contains(log, "<31415>") {
		t.Errorf("显式端口应由 -p 传递：%s", log)
	}
}

func TestSSHProbeRunInvalidTargetNeverSpawnsSSH(t *testing.T) {
	dir, logPath := fakeBin(t, "present")
	withPATH(t, dir)

	rc, _ := SSHProbeRun("b@h:notaport", "CMD")
	if rc != 64 {
		t.Errorf("非法 target rc = %d, want 64", rc)
	}
	if got := readLog(t, logPath); got != "" {
		t.Errorf("非法 target 不得发起 ssh：%s", got)
	}
}

func TestSSHProbePluginStates(t *testing.T) {
	cases := []struct {
		name     string
		scenario string
		want     []string
		notWant  []string
	}{
		{
			name:     "present（含 root 与 state）",
			scenario: "present",
			want:     []string{"HF_STATUS=present", "HF_ROOT=/home/b/plugin", "HF_STATE_DIR=/home/b/state"},
		},
		{
			name:     "present 但只有默认 state",
			scenario: "present_default_state",
			want:     []string{"HF_STATUS=present", "HF_ROOT=/home/b/plugin", "HF_DEFAULT_STATE=/home/b/default-state"},
			notWant:  []string{"HF_STATE_DIR="},
		},
		{
			name:     "present 但读不到 root（不打印 HF_ROOT）",
			scenario: "present_no_root",
			want:     []string{"HF_STATUS=present", "HF_DEFAULT_STATE=/home/b/default-state"},
			notWant:  []string{"HF_ROOT="},
		},
		{
			name:     "absent",
			scenario: "absent",
			want:     []string{"HF_STATUS=absent"},
			notWant:  []string{"HF_ROOT="},
		},
		{
			name:     "no-herdr（含 PATH 提示）",
			scenario: "noherdr",
			want:     []string{"HF_STATUS=no-herdr", "PATH"},
			notWant:  []string{"absent"},
		},
		{
			name:     "unreachable（含错误摘要）",
			scenario: "unreachable",
			want:     []string{"HF_STATUS=unreachable", "Connection refused"},
			notWant:  []string{"present"},
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			dir, _ := fakeBin(t, tc.scenario)
			withPATH(t, dir)
			got := SSHProbePlugin("b@h", DefaultPluginID)
			for _, want := range tc.want {
				if !strings.Contains(got, want) {
					t.Errorf("缺 %q\n实际：%s", want, got)
				}
			}
			for _, notWant := range tc.notWant {
				if strings.Contains(got, notWant) {
					t.Errorf("不该出现 %q\n实际：%s", notWant, got)
				}
			}
		})
	}
}

func TestSSHProbePluginCallCount(t *testing.T) {
	// absent / no-herdr / unreachable = 1 次 ssh；present = 2 次（与 lib 一致）
	cases := map[string]int{
		"absent":      1,
		"noherdr":     1,
		"unreachable": 1,
		"present":     2,
	}
	for scenario, want := range cases {
		t.Run(scenario, func(t *testing.T) {
			dir, logPath := fakeBin(t, scenario)
			withPATH(t, dir)
			_ = SSHProbePlugin("b@h", DefaultPluginID)
			got := strings.Count(readLog(t, logPath), "ARGV")
			if got != want {
				t.Errorf("ssh 调用次数 = %d, want %d", got, want)
			}
		})
	}
}

func TestSSHProbePluginCustomID(t *testing.T) {
	dir, logPath := fakeBin(t, "present")
	withPATH(t, dir)
	t.Setenv("SSH_SHIM_PLUGIN_ID", "acme:other")
	_ = SSHProbePlugin("b@h", "acme:other")
	log := readLog(t, logPath)
	if !strings.Contains(log, "acme:other") {
		t.Errorf("plugin list 匹配应使用自定义 id：%s", log)
	}
	if !strings.Contains(log, "acme%3Aother") {
		t.Errorf("state 目录应按自定义 id 编码（: -> %%3A）：%s", log)
	}
}

func TestRemoteCommandsMatchBashBytes(t *testing.T) {
	// 这两段是**远端 shell** 的脚本，字节必须与 lib/ssh-probe.sh 完全一致
	// （difftest 不覆盖它们，故在这里用关键片段做静态锚点）。
	for _, needle := range []string{"HF_NO_HERDR", "plugin list", "HF_ROOT=%s", "HF_STATE_DIR=%s", "HF_DEFAULT_STATE=%s", "__HF_PLUGIN_ID__", "__HF_PLUGIN_ID_ENC__"} {
		if !strings.Contains(RemoteListCmd+RemotePathsCmd, needle) {
			t.Errorf("远端命令缺关键片段 %q（与 bash 漂移了？）", needle)
		}
	}
	// `$HOME` / `$PATH` 必须原样留给远端展开（本地不得展开成宿主的值）
	if !strings.Contains(RemoteListCmd, "$HOME/.local/bin") {
		t.Error("REMOTE_LIST_CMD 的 PATH 兜底应留给远端展开")
	}
	if strings.Contains(RemoteListCmd, os.Getenv("HOME")+"/") {
		t.Error("REMOTE_LIST_CMD 不得已经展开成宿主 HOME")
	}
}
