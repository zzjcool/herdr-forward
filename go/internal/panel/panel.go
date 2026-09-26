// panel.go implements the watch pane without a TUI framework.
//
// The terminal protocol deliberately mirrors lib/panel.sh: one alternate-screen
// transition per invocation, one complete frame per refresh, and a timed byte
// read as the refresh clock.  The package owns no business logic; actions are
// handed back to the CLI through Options.OnAction.
package panel

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/zzjcool/herdr-forward/internal/bridge"
	"github.com/zzjcool/herdr-forward/internal/jqjson"
	"github.com/zzjcool/herdr-forward/internal/machine"
	"github.com/zzjcool/herdr-forward/internal/ports"
	"github.com/zzjcool/herdr-forward/internal/state"
	"golang.org/x/sys/unix"
	"golang.org/x/term"
)

var (
	// ErrNotTTY tells cmd_watch to use the historical watch(1) fallback.
	ErrNotTTY = errors.New("panel: stdin is not a terminal")
	// ErrInputClosed is an ordinary, successful end of a pane whose input went
	// away (for example when the herdr pane is closed).
	ErrInputClosed = errors.New("panel: input closed")
)

const (
	altOn      = "\x1b[?1049h"
	altOff     = "\x1b[?1049l"
	cursorHide = "\x1b[?25l"
	cursorShow = "\x1b[?25h"
	cursorSave = "\x1b[22;0;0t"
	cursorLoad = "\x1b[23;0;0t"
	clearHome  = "\x1b[H"
	clearAll   = "\x1b[2J"
	dim        = "\x1b[2m"
	reset      = "\x1b[0m"
)

// Action is a user action selected in the panel.  Value is a machine id or a
// port/id depending on Kind.
type Action struct {
	Kind  string
	Value string
}

const (
	ActionRefresh     = "refresh"
	ActionQuit        = "quit"
	ActionDoctor      = "doctor"
	ActionHint        = "hint"
	ActionActivate    = "activate"
	ActionDeactivate  = "deactivate"
	ActionAddClient   = "add-client"
	ActionRemove      = "remove"
	ActionPickForward = "pick-forward"
	ActionPickRemove  = "pick-remove"
)

// Options configures Run.  Zero values use stdin/stdout and a three second
// refresh period.  OnAction is called only after the panel has decoded a
// complete action; it may run a child CLI command.
type Options struct {
	Stdin    *os.File
	Stdout   io.Writer
	Refresh  time.Duration
	OnAction func(Action) error
}

// ForwardRow is the display-only shape used by the frame renderer.  Keeping a
// small display model makes golden tests independent from live bridge files.
type ForwardRow struct {
	ID        string
	Mode      string
	Local     int
	Remote    string
	Status    string
	Note      string
	Removable bool
}

// MachineRow is the display-only machine shape.
type MachineRow struct {
	ID     string
	Label  string
	Target string
	State  string
	Note   string
}

// ListenerRow is a display-only listening port.
type ListenerRow struct {
	Port    int
	Process string
}

// FrameData is the complete input to RenderFrameData.  It is intentionally
// free of terminal state: the same bytes are used for a TTY frame and for
// non-TTY/golden tests.
type FrameData struct {
	Forwards      []ForwardRow
	Machines      []MachineRow
	MachinesKnown bool
	Listening     []ListenerRow
	ClientLive    bool
	ClientHosts   []string
	Flash         string
	Refresh       time.Duration
}

// RenderFrame renders the current state directory as one complete text frame.
// It does not emit ANSI or write to stdout.
func RenderFrame(refresh time.Duration) string {
	return RenderFrameData(collectFrame(refresh))
}

// RenderFrameFromState is a deterministic helper for tests and difftest.  It
// renders typed tunnel records plus the supplied machine/listener rows without
// consulting the filesystem.
func RenderFrameFromState(fw []state.Forward, machines []MachineRow, listening []ListenerRow, refresh time.Duration) string {
	rows := make([]ForwardRow, 0, len(fw))
	for _, f := range fw {
		mode := string(f.Mode)
		if mode == "" {
			mode = string(state.ModeTunnel)
		}
		remoteHost := f.RemoteHost
		if remoteHost == "" {
			remoteHost = "127.0.0.1"
		}
		remote := remoteHost + ":" + strconv.Itoa(f.RemotePort)
		local := f.LocalPort
		if mode == string(state.ModeClient) {
			local = f.LocalPort
		}
		note := ""
		if f.Pid != nil {
			note = "pid " + strconv.Itoa(*f.Pid)
		}
		rows = append(rows, ForwardRow{ID: f.ID, Mode: mode, Local: local, Remote: remote, Status: f.Status, Note: note, Removable: mode != "bridge"})
	}
	return RenderFrameData(FrameData{Forwards: rows, Machines: machines, MachinesKnown: machines != nil, Listening: listening, Refresh: refresh})
}

// RenderFrameData emits the bash panel's frame text.  It is a pure function:
// one call produces one string and no partial line is written anywhere.
func RenderFrameData(data FrameData) string {
	refresh := refreshSeconds(data.Refresh)
	var b strings.Builder
	fmt.Fprintf(&b, "herdr-forward | Port Forward   refresh %ds - r now - x quit\n", refresh)
	b.WriteString("──────────────────────────────────────────────────────────────\n")
	if data.Flash != "" {
		b.WriteString(data.Flash)
		b.WriteByte('\n')
	}
	// CLIENT 行（A.3.3）：本机被 client 经桥接 attach 时显示是谁连着。
	// bash 版帧里没有「顶部单行 MACHINE/PORT 候选区」——Go 重写时自创的，已删。
	if data.ClientLive && len(data.ClientHosts) > 0 {
		b.WriteString("CLIENT  ")
		b.WriteString(strings.Join(data.ClientHosts, ", "))
		b.WriteString(" connected - map local ports to its localhost (remote dev)\n")
	}

	rows := append([]ForwardRow(nil), data.Forwards...)
	sort.SliceStable(rows, func(i, j int) bool { return rows[i].Local < rows[j].Local })
	removable := 0
	for _, row := range rows {
		if row.Removable && row.Mode != "bridge" {
			removable++
		}
	}
	fmt.Fprintf(&b, "FORWARDS (%d)\n", len(rows))
	if len(rows) == 0 {
		if data.ClientLive {
			b.WriteString("  (no forwards) press f+<n> to map a listening port to the client, or run forward add <port>.\n")
		} else {
			b.WriteString("  (no forwards) run 'forward add 3000:3000 --machine <label>' in a terminal.\n")
		}
	} else {
		fmt.Fprintf(&b, "  %-2s %-13s %-22s %-9s %s\n", "#", "LOCAL", "REMOTE", "STATUS", "NOTE")
		machineNumber := 0
		for _, row := range rows {
			number := "-"
			if row.Mode != "bridge" && machineNumber < 9 {
				machineNumber++
				number = strconv.Itoa(machineNumber)
			}
			local := strconv.Itoa(row.Local)
			if row.Mode == string(state.ModeClient) {
				local = "client:" + local
			}
			note := row.Note
			if row.Mode == string(state.ModeClient) && note == "" {
				switch row.Status {
				case "waiting":
					note = "waiting for client"
				case "pending":
					note = "awaiting client report"
				}
			}
			if row.Mode == "bridge" {
				note = "via bridge (registered on " + row.Remote + ")"
			}
			fmt.Fprintf(&b, "  %-2s %-13s %-22s %-9s %s\n", number, local, row.Remote, dash(row.Status), note)
		}
		if removable > 0 {
			b.WriteString(dim + "  d+<n> remove forward" + reset + "\n")
		}
	}

	if data.ClientLive {
		b.WriteString("──────────────────────────────────────────────────────────────\n")
		if len(data.Listening) == 0 {
			b.WriteString("LISTENING  (no other listening ports; start a dev server and it shows up here)\n")
		} else {
			b.WriteString("LISTENING  local ports - f+<n> maps to the client's localhost\n")
			for i, l := range data.Listening {
				if i >= 9 {
					break
				}
				proc := l.Process
				if proc == "" {
					proc = "-"
				}
				fmt.Fprintf(&b, "  f%d  %d %s\n", i+1, l.Port, proc)
			}
		}
	}

	if len(data.Machines) > 0 {
		b.WriteString("──────────────────────────────────────────────────────────────\n")
		fmt.Fprintf(&b, "MACHINES (%d)  number keys = activate / deactivate\n", len(data.Machines))
		for i, m := range data.Machines {
			if i >= 9 {
				break
			}
			label := m.Label
			if label == "" {
				label = m.ID
			}
			target := m.Target
			if target == "" {
				target = "-"
			}
			mark, desc := "[ ]", "(inactive - press "+strconv.Itoa(i+1)+" to probe & activate)"
			switch m.State {
			case "active":
				mark = "[x]"
				desc = "(active - tab bar points here)"
			case "local":
				mark = "[x]"
				desc = "(local - no probe needed)"
			case "activated":
				mark = "[-]"
				desc = "(activated - press " + strconv.Itoa(i+1) + " to switch back)"
			}
			if m.State == "active" && m.Note != "" {
				desc = "(active - " + m.Note + ")"
			}
			line := fmt.Sprintf("  %s %d. %-16s %-20s %s", mark, i+1, label, target, desc)
			if m.State != "active" && m.State != "local" {
				b.WriteString(dim)
			}
			b.WriteString(line)
			if m.State != "active" && m.State != "local" {
				b.WriteString(reset)
			}
			b.WriteByte('\n')
		}
	} else if data.MachinesKnown && !data.ClientLive {
		b.WriteString("──────────────────────────────────────────────────────────────\n")
		b.WriteString("MACHINES (0)  no saved machines yet\n")
		b.WriteString("  remote dev: run 'herdr machine add <ssh target> --label <name>' in a terminal, then activate it here.\n")
	}

	b.WriteString("──────────────────────────────────────────────────────────────\n")
	keys := "keys: 1-9 pick machine (confirm before activate)"
	if data.ClientLive && len(data.Listening) > 0 {
		keys += " - f+<n> map port"
	}
	if removable > 0 {
		keys += " - d+<n> remove forward"
	}
	b.WriteString(keys + " - r refresh - a add help - x quit\n")
	return b.String()
}

func refreshSeconds(d time.Duration) int {
	if d <= 0 {
		return 3
	}
	n := int(d / time.Second)
	if d%time.Second != 0 {
		n++
	}
	if n < 1 {
		n = 1
	}
	return n
}

func dash(s string) string {
	if s == "" {
		return "-"
	}
	return s
}

// HandleKey applies the top-level panel key semantics.  f is a refresh key in
// an ordinary pane, and becomes the historical f+number port picker when a
// client and listening ports are present.  d is the additive doctor shortcut;
// uppercase D retains the historical remove picker.
func HandleKey(key byte, data FrameData) Action {
	switch key {
	case 'r', 'R':
		return Action{Kind: ActionRefresh}
	case 'q', 'Q', 'x', 'X', 0x1b:
		return Action{Kind: ActionQuit}
	case 'a', 'A':
		return Action{Kind: ActionHint}
	case 'f', 'F':
		if data.ClientLive && len(data.Listening) > 0 {
			return Action{Kind: ActionPickForward}
		}
		return Action{Kind: ActionRefresh}
	case 'd':
		return Action{Kind: ActionDoctor}
	case 'D':
		return Action{Kind: ActionPickRemove}
	}
	if key >= '1' && key <= '9' {
		i := int(key - '1')
		if i >= 0 && i < len(data.Machines) {
			if data.Machines[i].State == "active" || data.Machines[i].State == "local" {
				return Action{Kind: ActionDeactivate, Value: data.Machines[i].ID}
			}
			return Action{Kind: ActionActivate, Value: data.Machines[i].ID}
		}
	}
	return Action{}
}

// Run starts the panel.  EOF and a cancelled context are successful exits.
// ErrNotTTY is returned before any terminal state is changed.
func Run(ctx context.Context, opts Options) error {
	in := opts.Stdin
	if in == nil {
		in = os.Stdin
	}
	out := opts.Stdout
	if out == nil {
		out = os.Stdout
	}
	if !term.IsTerminal(int(in.Fd())) {
		return ErrNotTTY
	}
	refresh := opts.Refresh
	if refresh <= 0 {
		refresh = 3 * time.Second
	}

	oldState, err := term.MakeRaw(int(in.Fd()))
	if err != nil {
		return fmt.Errorf("panel: raw mode: %w", err)
	}
	defer func() { _ = term.Restore(int(in.Fd()), oldState) }()

	stdoutTTY := writerIsTTY(out)
	if stdoutTTY {
		if _, err := io.WriteString(out, altOn+cursorSave+cursorHide); err != nil {
			return err
		}
		defer func() { _, _ = io.WriteString(out, cursorShow+cursorLoad+altOff) }()
	}

	var pending *byte
	flash := ""
	forwardArmed, removeArmed := false, false
	for {
		data := collectFrame(refresh)
		data.Flash = flash
		flash = ""
		frame := RenderFrameData(data)
		if stdoutTTY {
			_, err = io.WriteString(out, clearHome+clearAll+frame)
		} else {
			_, err = io.WriteString(out, frame)
		}
		if err != nil {
			return err
		}

		var key byte
		if pending != nil {
			key = *pending
			pending = nil
		} else {
			key, err = readByte(int(in.Fd()), refresh)
			if errors.Is(err, errReadTimeout) {
				continue
			}
			if errors.Is(err, io.EOF) || errors.Is(err, ErrInputClosed) {
				return nil
			}
			if err != nil {
				if ctx.Err() != nil {
					return nil
				}
				return err
			}
		}
		if ctx.Err() != nil {
			return nil
		}
		if key == '\r' || key == '\n' {
			// Bash read -n 1 sees Enter as an empty key.  It refreshes and
			// never treats it as EOF/quit.
			continue
		}

		data = collectFrame(refresh)
		if removeArmed || forwardArmed {
			if key >= '1' && key <= '9' {
				idx := int(key - '1')
				if removeArmed {
					if id := removeID(data, idx); id != "" {
						_ = runAction(out, opts.OnAction, Action{Kind: ActionRemove, Value: id})
					}
				} else if idx < len(data.Listening) {
					port := strconv.Itoa(data.Listening[idx].Port)
					if err := runAction(out, opts.OnAction, Action{Kind: ActionAddClient, Value: port}); err != nil {
						flash = fmt.Sprintf("  ⚠ 映射失败：%v", err)
					} else {
						flash = fmt.Sprintf("  [ok] mapped local port %s", port)
					}
				}
				removeArmed, forwardArmed = false, false
				continue
			}
			removeArmed, forwardArmed = false, false
		}
		if key == 'd' {
			if err := runAction(out, opts.OnAction, Action{Kind: ActionDoctor}); err != nil {
				fmt.Fprintf(out, "  ⚠ doctor 失败：%v\n", err)
			}
			removeArmed = hasRemovable(data)
			continue
		}
		if key == 'f' || key == 'F' {
			forwardArmed = data.ClientLive && len(data.Listening) > 0
			continue
		}
		action := HandleKey(key, data)
		switch action.Kind {
		case ActionQuit:
			return nil
		case ActionRefresh:
			continue
		case ActionHint:
			fmt.Fprintln(out, "panel: add forward: run 'forward add <port>' in a terminal (maps to its localhost when a client is attached).")
		case ActionActivate, ActionDeactivate:
			pending = doMachineAction(ctx, in, out, opts.OnAction, action, data)
		case ActionPickForward:
			forwardArmed = true
		case ActionPickRemove:
			removeArmed = true
		}
	}
}

var errReadTimeout = errors.New("panel: read timeout")

func readByte(fd int, timeout time.Duration) (byte, error) {
	ms := -1
	if timeout >= 0 {
		ms = int(timeout / time.Millisecond)
		if ms < 1 {
			ms = 1
		}
	}
	for {
		fds := []unix.PollFd{{Fd: int32(fd), Events: unix.POLLIN | unix.POLLHUP | unix.POLLERR}}
		n, err := unix.Poll(fds, ms)
		if err == unix.EINTR {
			continue
		}
		if err != nil {
			return 0, err
		}
		if n == 0 {
			return 0, errReadTimeout
		}
		var buf [1]byte
		n, err = unix.Read(fd, buf[:])
		if err != nil {
			if err == unix.EINTR {
				continue
			}
			return 0, err
		}
		if n == 0 {
			return 0, io.EOF
		}
		return buf[0], nil
	}
}

func writerIsTTY(w io.Writer) bool {
	f, ok := w.(*os.File)
	return ok && term.IsTerminal(int(f.Fd()))
}

func runAction(out io.Writer, fn func(Action) error, action Action) error {
	if fn != nil {
		return fn(action)
	}
	return nil
}

func doMachineAction(ctx context.Context, in *os.File, out io.Writer, fn func(Action) error, action Action, data FrameData) *byte {
	label := action.Value
	for _, machine := range data.Machines {
		if machine.ID == action.Value {
			if machine.Label != "" {
				label = machine.Label
			}
			break
		}
	}
	if action.Kind == ActionActivate {
		fmt.Fprintf(out, "probe %s read-only over SSH, continue? [y/N]\n", label)
		fmt.Fprintf(out, "confirm: probing %s read-only over SSH\n", label)
		key, err := readByte(int(in.Fd()), -1)
		fmt.Fprintln(out)
		if err != nil || (key != 'y' && key != 'Y') {
			fmt.Fprintln(out, "  (cancelled, no connection attempted)")
			return nil
		}
		fmt.Fprintln(out, "  probing... (read-only SSH, up to ~15s)")
	} else {
		fmt.Fprintf(out, "deactivate %s, continue? [y/N]\n", label)
		key, err := readByte(int(in.Fd()), -1)
		fmt.Fprintln(out)
		if err != nil || (key != 'y' && key != 'Y') {
			fmt.Fprintln(out, "  (cancelled)")
			return nil
		}
		fmt.Fprintln(out, "  deactivating...")
	}
	if ctx.Err() != nil {
		return nil
	}
	if err := runAction(out, fn, action); err != nil {
		fmt.Fprintf(out, "  ⚠ 命令失败：%v\n", err)
	}
	fmt.Fprintln(out, "  (press any key to return to the panel)")
	key, err := readByte(int(in.Fd()), 120*time.Second)
	if err == nil {
		return &key
	}
	return nil
}

func doPickAction(in *os.File, out io.Writer, fn func(Action) error, data FrameData, remove bool) *byte {
	if remove && !hasRemovable(data) {
		fmt.Fprintln(out, "  没有可删除的映射。")
		return nil
	}
	if !remove && len(data.Listening) == 0 {
		fmt.Fprintln(out, "  no listening ports to map (requires a client attached via bridge).")
		return nil
	}
	fmt.Fprintln(out, "  enter 1-9 (any other key cancels)")
	key, err := readByte(int(in.Fd()), 10*time.Second)
	if err != nil || key < '1' || key > '9' {
		fmt.Fprintln(out, "  (cancelled)")
		return nil
	}
	idx := int(key - '1')
	value := ""
	if remove {
		value = removeID(data, idx)
	} else if idx < len(data.Listening) {
		value = strconv.Itoa(data.Listening[idx].Port)
	}
	if value == "" {
		fmt.Fprintf(out, "  没有序号 %c。\n", key)
		return nil
	}
	kind := ActionRemove
	if !remove {
		kind = ActionAddClient
	}
	if err := runAction(out, fn, Action{Kind: kind, Value: value}); err != nil {
		fmt.Fprintf(out, "  ⚠ 失败：%v\n", err)
	} else if remove {
		fmt.Fprintf(out, "  [ok] removed %s\n", value)
	} else {
		fmt.Fprintf(out, "  [ok] mapped local port %s\n", value)
	}
	return nil
}

func hasRemovable(data FrameData) bool {
	for _, r := range data.Forwards {
		if r.Removable && r.Mode != "bridge" {
			return true
		}
	}
	return false
}

func removeID(data FrameData, idx int) string {
	rows := append([]ForwardRow(nil), data.Forwards...)
	sort.SliceStable(rows, func(i, j int) bool { return rows[i].Local < rows[j].Local })
	n := 0
	for _, r := range rows {
		if !r.Removable || r.Mode == "bridge" {
			continue
		}
		if n == idx {
			if r.ID != "" {
				return r.ID
			}
			return "f-" + strconv.Itoa(r.Local)
		}
		n++
	}
	return ""
}

func collectFrame(refresh time.Duration) FrameData {
	data := FrameData{Refresh: refresh}
	view, ok := bridge.MergeView()
	if ok {
		for _, obj := range view {
			data.Forwards = append(data.Forwards, forwardRow(obj))
		}
	}
	sessions := bridge.Sessions()
	for _, session := range sessions {
		if v, exists := session.Get("live"); !exists || !jqjson.Truthy(v) {
			continue
		}
		data.ClientLive = true
		host := jqjson.Str(objectValue(session, "client_host"))
		if host != "" {
			data.ClientHosts = append(data.ClientHosts, host)
		}
	}
	if data.ClientLive {
		done := map[int]bool{}
		if raw, all := bridge.RawForwards(); all {
			for _, obj := range raw {
				if jqjson.Str(objectValue(obj, "mode")) == string(state.ModeClient) {
					done[intValue(objectValue(obj, "remote_port"))] = true
				}
			}
		}
		if listeners, err := ports.List(); err == nil {
			processes := listeningProcesses()
			for _, listener := range listeners {
				if !done[listener.Port] && len(data.Listening) < 9 {
					if listener.Process == "" {
						listener.Process = processes[listener.Port]
					}
					data.Listening = append(data.Listening, ListenerRow{Port: listener.Port, Process: listener.Process})
				}
			}
		}
	}
	if os.Getenv("HERDR_BIN_PATH") != "" {
		data.MachinesKnown = true
	}
	bridgeNotes := bridgeMachineNotes()
	for _, m := range machine.View() {
		data.Machines = append(data.Machines, MachineRow{ID: m.ID, Label: m.Label, Target: m.Target, State: m.State, Note: bridgeNotes[m.ID]})
	}
	return data
}

func listeningProcesses() map[int]string {
	out := map[int]string{}
	cmd := exec.Command("ss", "-Htlnp")
	data, err := cmd.Output()
	if err != nil {
		return out
	}
	for _, line := range strings.Split(string(data), "\n") {
		fields := strings.Fields(line)
		if len(fields) < 4 {
			continue
		}
		addr := fields[3]
		idx := strings.LastIndex(addr, ":")
		if idx < 0 {
			continue
		}
		port, err := strconv.Atoi(strings.Trim(addr[idx+1:], "]"))
		if err != nil {
			continue
		}
		marker := `users:(("`
		start := strings.Index(line, marker)
		if start < 0 {
			continue
		}
		start += len(marker)
		end := strings.IndexByte(line[start:], '"')
		if end > 0 {
			out[port] = line[start : start+end]
		}
	}
	return out
}

func bridgeMachineNotes() map[string]string {
	out := map[string]string{}
	for _, obj := range bridge.Clients() {
		id := jqjson.Str(objectValue(obj, "machine"))
		if id == "" {
			continue
		}
		running := jqjson.Truthy(objectValue(obj, "running"))
		state := jqjson.Str(objectValue(obj, "state"))
		switch {
		case running && state == "connected":
			out[id] = "bridge connected"
		case state == "retrying":
			out[id] = "bridge reconnecting"
		case running:
			out[id] = "bridge connecting"
		default:
			out[id] = "bridge not running"
		}
	}
	return out
}

func forwardRow(obj *jqjson.Object) ForwardRow {
	mode := jqjson.Str(objectValue(obj, "mode"))
	if mode == "" {
		mode = string(state.ModeTunnel)
	}
	local := intValue(objectValue(obj, "local_port"))
	remotePort := intValue(objectValue(obj, "remote_port"))
	remoteHost := jqjson.Str(objectValue(obj, "remote_host"))
	if remoteHost == "" {
		remoteHost = "127.0.0.1"
	}
	remote := remoteHost + ":" + strconv.Itoa(remotePort)
	if mode == "bridge" {
		machineName := jqjson.Str(objectValue(obj, "machine"))
		if machineName == "" {
			machineName = "?"
		}
		remote = machineName + ":" + strconv.Itoa(remotePort)
	}
	note := ""
	if mode == string(state.ModeClient) {
		note = jqjson.Str(objectValue(obj, "status_reason"))
	} else if mode == "bridge" {
		note = "via bridge (registered on " + jqjson.Str(objectValue(obj, "machine")) + ")"
	} else if pid := objectValue(obj, "pid"); pid != nil {
		note = "pid " + jqjson.ToString(pid)
	}
	return ForwardRow{ID: jqjson.Str(objectValue(obj, "id")), Mode: mode, Local: local, Remote: remote, Status: jqjson.ToString(objectValue(obj, "status")), Note: note, Removable: mode != "bridge"}
}

func objectValue(o *jqjson.Object, key string) any {
	if o == nil {
		return nil
	}
	v, _ := o.Get(key)
	return v
}

func intValue(v any) int {
	n, ok := v.(jqjson.Number)
	if !ok {
		return 0
	}
	i, err := strconv.Atoi(string(n))
	if err != nil {
		return 0
	}
	return i
}

// commandAction is a small default for callers that do not need a custom
// callback.  cli.Main supplies a callback so the panel remains business-logic
// free; this helper is kept for package users embedding the pane.
func commandAction(bin string, action Action) error {
	args := []string{}
	switch action.Kind {
	case ActionActivate:
		args = []string{"machines", "activate", action.Value, "--install"}
	case ActionDeactivate:
		args = []string{"machines", "deactivate", action.Value}
	case ActionAddClient:
		args = []string{"add", action.Value, "--client"}
	case ActionRemove:
		args = []string{"remove", action.Value}
	case ActionDoctor:
		args = []string{"doctor"}
	default:
		return nil
	}
	cmd := exec.Command(bin, args...)
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

var _ = syscall.EINTR
