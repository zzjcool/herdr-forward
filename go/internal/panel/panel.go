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
	// Cursor 是 LISTENING 段当前高亮行（全局序号，跨页）；-1 = 无高亮。
	Cursor int
	// Page 是 LISTENING 分页页号（0 起，每页 9 行）。
	Page int
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
	return RenderFrameData(FrameData{Forwards: rows, Machines: machines, MachinesKnown: machines != nil, Listening: listening, Refresh: refresh, Cursor: -1})
}

// navItem 是统一光标模型里的一条可选中行（FORWARDS/LISTENING/MACHINES 三段）。
type navItem struct {
	kind string // "forward" | "listening" | "machine"
	idx  int    // 段内索引（forward=sorted 序、listening=全局序、machine=序）
}

// navItems 构建可选中行的总表：FORWARDS（可删除的）→ LISTENING → MACHINES。
func navItems(data FrameData) []navItem {
	items := []navItem{}
	rows := sortedForwards(data)
	for i, row := range rows {
		if row.Removable && row.Mode != "bridge" {
			items = append(items, navItem{kind: "forward", idx: i})
		}
	}
	for i := range data.Listening {
		items = append(items, navItem{kind: "listening", idx: i})
	}
	for i := range data.Machines {
		items = append(items, navItem{kind: "machine", idx: i})
	}
	return items
}

func sortedForwards(data FrameData) []ForwardRow {
	rows := append([]ForwardRow(nil), data.Forwards...)
	sort.SliceStable(rows, func(i, j int) bool { return rows[i].Local < rows[j].Local })
	return rows
}

// RenderFrameData emits the bash panel's frame text.  It is a pure function:
// one call produces one string and no partial line is written anywhere.
func RenderFrameData(data FrameData) string {
	refresh := refreshSeconds(data.Refresh)
	var b strings.Builder
	fmt.Fprintf(&b, "Port Forward   refresh %ds\n", refresh)
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

	rows := sortedForwards(data)
	items := navItems(data)
	cur := navItem{}
	if data.Cursor >= 0 && data.Cursor < len(items) {
		cur = items[data.Cursor]
	}
	fmt.Fprintf(&b, "FORWARDS (%d)\n", len(rows))
	if len(rows) == 0 {
		if data.ClientLive {
			b.WriteString("  (no forwards) pick a listening port below and press Enter\n")
		} else {
			b.WriteString("  (no forwards) run 'forward add 3000:3000 --machine <label>' in a terminal\n")
		}
	} else {
		fmt.Fprintf(&b, "  %-2s %-13s %-22s %-9s %s\n", "#", "LOCAL", "REMOTE", "STATUS", "NOTE")
		for i, row := range rows {
			number := "-"
			if row.Mode != "bridge" {
				number = strconv.Itoa(i + 1)
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
			mark := " "
			if cur.kind == "forward" && cur.idx == i {
				mark = ">"
			}
			fmt.Fprintf(&b, "%s %-2s %-13s %-22s %-9s %s\n", mark, number, local, row.Remote, dash(row.Status), note)
		}
	}

	if data.ClientLive {
		b.WriteString("──────────────────────────────────────────────────────────────\n")
		if len(data.Listening) == 0 {
			b.WriteString("LISTENING  (no other listening ports; start a dev server and it shows up here)\n")
		} else {
			fmt.Fprintf(&b, "LISTENING  local ports (%d)  -  Enter maps to the client's localhost\n", len(data.Listening))
			// 滚动窗口：以 LISTENING 光标为中心 ±8 行（去页概念，光标到哪滚到哪）。
			li := -1
			if cur.kind == "listening" {
				li = cur.idx
			}
			start, end := scrollWindow(li, len(data.Listening))
			for i := start; i < end; i++ {
				l := data.Listening[i]
				proc := l.Process
				if proc == "" {
					proc = "-"
				}
				mark := " "
				if i == li {
					mark = ">"
				}
				fmt.Fprintf(&b, "%s %-6d %s\n", mark, l.Port, proc)
			}
			if start > 0 || end < len(data.Listening) {
				fmt.Fprintf(&b, "  (%d of %d shown; keep moving to scroll)\n", end-start, len(data.Listening))
			}
		}
	}

	if len(data.Machines) > 0 {
		b.WriteString("──────────────────────────────────────────────────────────────\n")
		fmt.Fprintf(&b, "MACHINES (%d)  -  Enter activates / deactivates\n", len(data.Machines))
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
			mark, desc := "[ ]", "(inactive)"
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
			cmark := " "
			if cur.kind == "machine" && cur.idx == i {
				cmark = ">"
			}
			line := fmt.Sprintf("%s %s %d. %-16s %-20s %s", cmark, mark, i+1, label, target, desc)
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
	b.WriteString("up/down move - Enter confirm - 1-9 machine - r refresh - x quit\n")
	return b.String()
}

// scrollWindow 返回 LISTENING 段的滚动窗口 [start,end)：光标行居中，上下各留 8 行。
func scrollWindow(cursor, total int) (int, int) {
	const span = 17 // 每屏 17 行（光标居中 ±8）
	if total <= span {
		return 0, total
	}
	if cursor < 0 {
		return 0, span
	}
	start := cursor - span/2
	if start < 0 {
		start = 0
	}
	if start+span > total {
		start = total - span
	}
	return start, start + span
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
	cursor := -1
	for {
		data := collectFrame(refresh)
		data.Flash = flash
		data.Cursor = cursor
		flash = ""
		frame := RenderFrameData(data)
		if stdoutTTY {
			// stdin 的 PTY 已 MakeRaw（OPOST 关）：\n 不再由内核补 \r。
			// herdr pane（stdout 与 stdin 同一 PTY）的 VT 解析把纯 LF 当
			// 「换行不回列」（打字机行为）→ 逐行累积右移（=「界面错乱」
			// 根因）。手动补 \r 恢复列归零。
			_, err = io.WriteString(out, clearHome+clearAll+strings.ReplaceAll(frame, "\n", "\r\n"))
		} else {
			// 非 TTY stdout（herdr pane）：
			// stdin 的 PTY 已被 MakeRaw（OPOST 关）——若 herdr 从该 PTY
			// 侧收集输出，纯 \n 只换行不回列 0（打字机行为），造成
			// 「每行右移上一行长度」的逐行漂移。补 \r 恢复列归零；
			// \f 让每帧从干净视口开始（herdr pane 当空行）。
			_, err = io.WriteString(out, "\f"+strings.ReplaceAll(frame, "\n", "\r\n"))
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
		// ---- 统一光标模型：up/down 在 FORWARDS→LISTENING→MACHINES 全表移动 ----
		move := func(delta int) {
			items := navItems(data)
			if len(items) == 0 {
				return
			}
			if cursor < 0 {
				if delta > 0 {
					cursor = 0
				} else {
					cursor = len(items) - 1
				}
				return
			}
			cursor = (cursor + delta + len(items)) % len(items)
		}

		switch key {
		case '\r', '\n':
			// Enter 的分段语义（按光标所在区块）：
			//   forward 行 → remove（带确认）；listening 行 → 映射到 client；
			//   machine 行 → 激活/停用；无光标 → 仅刷新。
			items := navItems(data)
			if cursor >= 0 && cursor < len(items) {
				switch it := items[cursor]; it.kind {
				case "forward":
					rows := sortedForwards(data)
					if it.idx < len(rows) {
						id := rows[it.idx].ID
						if keyYN(out, in, "remove forward "+strconv.Itoa(rows[it.idx].Local)) {
							if err := runAction(out, opts.OnAction, Action{Kind: ActionRemove, Value: id}); err != nil {
								flash = fmt.Sprintf("  [err] remove failed: %v", err)
							} else {
								flash = fmt.Sprintf("  [ok] removed %d", rows[it.idx].Local)
							}
						}
					}
				case "listening":
					if it.idx < len(data.Listening) {
						port := strconv.Itoa(data.Listening[it.idx].Port)
						if err := runAction(out, opts.OnAction, Action{Kind: ActionAddClient, Value: port}); err != nil {
							flash = fmt.Sprintf("  [err] map failed: %v", err)
						} else {
							flash = fmt.Sprintf("  [ok] mapped local port %s", port)
						}
					}
				case "machine":
					if it.idx < len(data.Machines) {
						m := data.Machines[it.idx]
						if m.State == "active" || m.State == "local" {
							pending = doMachineAction(ctx, in, out, opts.OnAction, Action{Kind: ActionDeactivate, Value: m.ID}, data)
						} else {
							pending = doMachineAction(ctx, in, out, opts.OnAction, Action{Kind: ActionActivate, Value: m.ID}, data)
						}
					}
				}
			}
			continue
		case 0x1b:
			// ESC 可能是方向键序列（ESC[A/B）。50ms 窥探：无后续 = 单独 ESC = 退出。
			nxt, nerr := readByte(int(in.Fd()), 50*time.Millisecond)
			if nerr != nil {
				return nil
			}
			if nxt != '[' {
				continue
			}
			dir, derr := readByte(int(in.Fd()), 50*time.Millisecond)
			if derr != nil {
				continue
			}
			switch dir {
			case 'A':
				move(-1)
			case 'B':
				move(1)
			}
			continue
		case 'j':
			move(1)
			continue
		case 'k':
			move(-1)
			continue
		}

		action := HandleKey(key, data)
		switch action.Kind {
		case ActionQuit:
			return nil
		case ActionRefresh:
			continue
		case ActionActivate, ActionDeactivate:
			pending = doMachineAction(ctx, in, out, opts.OnAction, action, data)
		}
	}
}

// keyYN 在面板上问一个 y/N 问题（raw 模式下读单键）。返回是否确认。
func keyYN(out io.Writer, in *os.File, question string) bool {
	fmt.Fprintf(out, "\r\n  %s? [y/N] ", question)
	key, err := readByte(int(in.Fd()), 30*time.Second)
	if err != nil {
		return false
	}
	return key == 'y' || key == 'Y'
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
				// 全量采集：分页在渲染层做（每页 9 行对齐 f1..f9 键位），
				// 这里截断会让「n 翻页」永远无页可翻（用户实测抓到）。
				if !done[listener.Port] {
					if listener.Process == "" {
						listener.Process = processes[listener.Port]
					}
					data.Listening = append(data.Listening, ListenerRow{Port: listener.Port, Process: listener.Process})
				}
			}
			// 排序：用户最可能要映射的排最前（/proc 无启动时间，用进程名启发式）。
			//   组 0：典型 dev server 进程（node/python/go/vite/next/deno/ruby/php/java…）
			//   组 1：其它具名进程（cloudflared 等基础设施往后）
			//   组 2：无进程名（/proc 直读拿不到 —— 保守放最后）
			// 组内端口升序（稳定排序，同端口不跳）。
			sort.SliceStable(data.Listening, func(i, j int) bool {
				gi, gj := listenRank(data.Listening[i]), listenRank(data.Listening[j])
				if gi != gj {
					return gi < gj
				}
				return data.Listening[i].Port < data.Listening[j].Port
			})
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

// listenRank 返回 LISTENING 行的展示优先级组（0 最优先）。
// /proc/net/tcp 拿不到监听启动时间，「最近添加优先」退化为进程名启发式：
// 典型 dev server（node/vite/python/go 等）是用户映射的真实目标，
// 基础设施（cloudflared/sshd 已被过滤/代理）与无名进程靠后。
func listenRank(l ListenerRow) int {
	if l.Process == "" || l.Process == "-" {
		return 2
	}
	name := strings.ToLower(l.Process)
	// 进程名可能带后缀（node-MainThread / python3.11），匹配前缀/子串。
	devPrefixes := []string{"node", "python", "go", "vite", "next", "deno", "bun",
		"ruby", "rails", "puma", "php", "java", "gradle", "cargo", "rustc",
		"webpack", "esbuild", "tsx", "tsx", "uvicorn", "gunicorn", "flask",
		"java", "dotnet", "swift", "air", "reflex", "streamlit", "jupyter"}
	for _, pre := range devPrefixes {
		if strings.HasPrefix(name, pre) {
			return 0
		}
	}
	return 1
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
