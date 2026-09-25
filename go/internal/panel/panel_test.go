package panel

import (
	"strings"
	"testing"
	"time"

	"github.com/zzjcool/herdr-forward/internal/state"
)

func TestRenderFrameGolden(t *testing.T) {
	got := RenderFrameData(FrameData{
		Refresh: 3 * time.Second,
		Forwards: []ForwardRow{
			{ID: "f-5173", Mode: "tunnel", Local: 5173, Remote: "127.0.0.1:5173", Status: "up", Note: "pid 4242", Removable: true},
		},
		Machines: []MachineRow{
			{ID: "m1", Label: "devbox", Target: "bob@devbox:22", State: "active"},
			{ID: "m2", Label: "待激活", Target: "user@remote:22", State: "inactive"},
		},
	})
	want := "herdr-forward · Port Forward   刷新 3s · r 立即刷新 · x 退出\n" +
		"──────────────────────────────────────────────────────────────\n" +
		"MACHINE [✓] 1. devbox\n" +
		"MACHINE [ ] 2. 待激活\n" +
		"FORWARDS (1)\n" +
		"  #  LOCAL         REMOTE                 STATUS    NOTE\n" +
		"  1  5173          127.0.0.1:5173         up        pid 4242\n" +
		"\x1b[2m  d+序号 删除映射\x1b[0m\n" +
		"──────────────────────────────────────────────────────────────\n" +
		"MACHINES (2)  数字键 = 激活 / 停用\n" +
		"  [✓] 1. devbox   bob@devbox:22 （当前活动 · tab bar 指向该机）\n" +
		"\x1b[2m  [ ] 2. 待激活      user@remote:22 （未激活 · 按 2 探测并激活）\x1b[0m\n" +
		"──────────────────────────────────────────────────────────────\n" +
		"按键: 1-9 选择机器（激活前会确认） · d+序号 删除映射 · r 刷新 · a 添加转发用法 · x 退出\n"
	if got != want {
		t.Fatalf("frame mismatch:\n got %q\nwant %q", got, want)
	}
}

func TestRenderFrameClientListeningGolden(t *testing.T) {
	got := RenderFrameData(FrameData{
		Refresh:     3 * time.Second,
		ClientLive:  true,
		ClientHosts: []string{"laptop"},
		Forwards:    []ForwardRow{{ID: "f-5173", Mode: "client", Local: 5173, Remote: "localhost:5173", Status: "waiting", Removable: true}},
		Listening:   []ListenerRow{{Port: 8080, Process: "python3"}},
	})
	for _, want := range []string{
		"CLIENT  laptop 已连接",
		"FORWARDS (1)",
		"client:5173",
		"LISTENING  本机监听端口",
		"f1  8080 python3",
		"f+序号 映射端口",
	} {
		if !strings.Contains(got, want) {
			t.Errorf("frame missing %q: %q", want, got)
		}
	}
	if strings.Contains(got, "MACHINES") {
		t.Errorf("client frame should omit machines section: %q", got)
	}
}

func TestRenderFrameFromStateUsesFrozenTypes(t *testing.T) {
	pid := 123
	got := RenderFrameFromState([]state.Forward{{ID: "f-3000", LocalPort: 3000, RemoteHost: "127.0.0.1", RemotePort: 9443, Status: "up", Pid: &pid}}, nil, nil, 3*time.Second)
	if !strings.Contains(got, "3000") || !strings.Contains(got, "127.0.0.1:9443") || !strings.Contains(got, "pid 123") {
		t.Fatalf("state projection missing fields: %q", got)
	}
}

func TestHandleKeySemantics(t *testing.T) {
	data := FrameData{
		Machines:   []MachineRow{{ID: "m1", State: "inactive"}, {ID: "m2", State: "active"}},
		ClientLive: true,
		Listening:  []ListenerRow{{Port: 5173}},
	}
	cases := []struct {
		key  byte
		kind string
		val  string
	}{
		{'1', ActionActivate, "m1"},
		{'2', ActionDeactivate, "m2"},
		{'f', ActionPickForward, ""},
		{'r', ActionRefresh, ""},
		{'d', ActionDoctor, ""},
		{'q', ActionQuit, ""},
		{0x1b, ActionQuit, ""},
	}
	for _, tc := range cases {
		got := HandleKey(tc.key, data)
		if got.Kind != tc.kind || got.Value != tc.val {
			t.Errorf("key %q = %#v, want kind=%q value=%q", tc.key, got, tc.kind, tc.val)
		}
	}
	if got := HandleKey('\r', data); got.Kind != "" {
		t.Errorf("Enter must be ignored by caller, got %#v", got)
	}
}
