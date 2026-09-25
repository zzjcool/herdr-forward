// installers.go contains the Go implementations behind the small POSIX
// wrappers in scripts/.  Keeping the text manipulation here means the build
// and startup paths use the same code as `forward bootstrap` and do not need a
// shell/Python runtime.
package cli

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"time"

	"github.com/BurntSushi/toml"
	"github.com/zzjcool/herdr-forward/internal/hfcommon"
	"github.com/zzjcool/herdr-forward/internal/machine"
	"github.com/zzjcool/herdr-forward/internal/panel"
)

const (
	tabbarMarker = "# herdr-forward: tab bar status entry (managed by scripts/install-tabbar.sh)"
	keysMarker   = "# herdr-forward: keybindings (managed by scripts/install-keys.sh)"
	pluginID     = "zzjcool:forward"
)

type installerOptions struct {
	ConfigPath string
	PluginRoot string
	StateDir   string
	Command    string
	AddKey     string
	ListKey    string
	DoctorKey  string
	DryRun     bool
}

type installerResult struct {
	Changed     bool
	Already     bool
	Content     string
	Conflicts   []string
	ConflictMap map[string]string
}

func defaultConfigPath() string {
	if p := os.Getenv("HERDR_CONFIG_PATH"); p != "" {
		return p
	}
	base := os.Getenv("XDG_CONFIG_HOME")
	if base == "" {
		home := os.Getenv("HOME")
		if home == "" {
			home = "/nonexistent"
		}
		base = filepath.Join(home, ".config")
	}
	return filepath.Join(base, "herdr", "config.toml")
}

func parseInstallerArgs(args []string, keys bool) (installerOptions, bool, int) {
	opts := installerOptions{ConfigPath: defaultConfigPath()}
	for len(args) > 0 {
		arg := args[0]
		switch arg {
		case "--config":
			if len(args) < 2 {
				return opts, false, die(exitError, "--config 需要参数值")
			}
			opts.ConfigPath = args[1]
			args = args[2:]
		case "--plugin-root":
			if len(args) < 2 {
				return opts, false, die(exitError, "--plugin-root 需要参数值")
			}
			opts.PluginRoot = args[1]
			args = args[2:]
		case "--state-dir":
			if len(args) < 2 {
				return opts, false, die(exitError, "--state-dir 需要参数值")
			}
			opts.StateDir = args[1]
			args = args[2:]
		case "--command":
			if len(args) < 2 {
				return opts, false, die(exitError, "--command 需要参数值")
			}
			opts.Command = args[1]
			args = args[2:]
		case "--add-key":
			if len(args) < 2 || !keys {
				return opts, false, die(exitError, "--add-key 需要参数值（如 prefix+f）")
			}
			opts.AddKey = args[1]
			args = args[2:]
		case "--list-key":
			if len(args) < 2 || !keys {
				return opts, false, die(exitError, "--list-key 需要参数值（如 prefix+shift+f）")
			}
			opts.ListKey = args[1]
			args = args[2:]
		case "--doctor-key":
			if len(args) < 2 || !keys {
				return opts, false, die(exitError, "--doctor-key 需要参数值（如 prefix+alt+f）")
			}
			opts.DoctorKey = args[1]
			args = args[2:]
		case "--dry-run":
			opts.DryRun = true
			args = args[1:]
		case "--help", "-h":
			return opts, true, exitOK
		default:
			return opts, false, die(exitError, "未知参数: "+arg+"（用 --help 查看用法）")
		}
	}
	if opts.PluginRoot == "" {
		opts.PluginRoot = pluginRootOfSelf()
	}
	if opts.PluginRoot == "" {
		opts.PluginRoot = "."
	}
	if !filepath.IsAbs(opts.PluginRoot) {
		return opts, false, die(exitError, fmt.Sprintf("--plugin-root 必须是绝对路径（收到 '%s'）", opts.PluginRoot))
	}
	opts.PluginRoot = strings.TrimRight(opts.PluginRoot, string(filepath.Separator))
	if opts.PluginRoot == "" {
		opts.PluginRoot = string(filepath.Separator)
	}
	if opts.StateDir == "" {
		opts.StateDir = os.Getenv("HERDR_PLUGIN_STATE_DIR")
	}
	if opts.StateDir == "" {
		opts.StateDir = defaultPluginStateDir()
	}
	if !filepath.IsAbs(opts.StateDir) {
		return opts, false, die(exitError, fmt.Sprintf("state 目录必须是绝对路径（收到 '%s'）", opts.StateDir))
	}
	return opts, false, exitOK
}

func tabbarUsage() {
	fmt.Print("用法: forward internal install-tabbar [--config PATH] [--plugin-root PATH] [--state-dir PATH] [--command CMD] [--dry-run]\n")
}

func keysUsage() {
	fmt.Print("用法: forward internal install-keys [--config PATH] [--add-key KEY] [--list-key KEY] [--doctor-key KEY] [--dry-run]\n")
}

func internalInstallTabbar(args []string) int {
	opts, help, code := parseInstallerArgs(args, false)
	if help {
		tabbarUsage()
		return exitOK
	}
	if code != exitOK {
		return code
	}
	res, err := performInstallTabbar(opts)
	if err != nil {
		return die(exitError, err.Error())
	}
	if res.Already {
		fmt.Printf("install-tabbar: already installed（%s 已含 herdr-forward 条目，未做修改）\n", opts.ConfigPath)
		return exitOK
	}
	if opts.DryRun {
		fmt.Printf("[dry-run] 将写入 %s：\n---\n%s---\n", opts.ConfigPath, res.Content)
		return exitOK
	}
	if err := writeInstallerFile(opts.ConfigPath, []byte(res.Content)); err != nil {
		return die(exitError, err.Error())
	}
	fmt.Printf("install-tabbar: 已写入 %s\n", opts.ConfigPath)
	fmt.Fprintln(os.Stdout, "提示：执行 reload-config（或重启 herdr）后，tab bar 右侧会显示 ⇅<port> 状态条。")
	return exitOK
}

func internalInstallKeys(args []string) int {
	opts, help, code := parseInstallerArgs(args, true)
	if help {
		keysUsage()
		return exitOK
	}
	if code != exitOK {
		return code
	}
	if opts.AddKey == "" {
		opts.AddKey = "prefix+f"
	}
	if opts.ListKey == "" {
		opts.ListKey = "prefix+shift+f"
	}
	if opts.DoctorKey == "" {
		opts.DoctorKey = "prefix+alt+f"
	}
	res, err := performInstallKeys(opts)
	if err != nil {
		return die(exitError, err.Error())
	}
	printConflictWarnings(opts.ConfigPath, res)
	if res.Already {
		fmt.Printf("install-keys: already installed（%s 已含 herdr-forward 键位，未做修改）\n", opts.ConfigPath)
		return exitOK
	}
	if opts.DryRun {
		fmt.Printf("[dry-run] 将写入 %s：\n---\n%s---\n", opts.ConfigPath, res.Content)
		return exitOK
	}
	if err := writeInstallerFile(opts.ConfigPath, []byte(res.Content)); err != nil {
		return die(exitError, err.Error())
	}
	fmt.Printf("install-keys: 已写入 %s\n", opts.ConfigPath)
	fmt.Printf("提示：执行 reload-config（或重启 herdr）后，%s / %s / %s 即可用。\n", opts.AddKey, opts.ListKey, opts.DoctorKey)
	return exitOK
}

func performInstallTabbar(opts installerOptions) (installerResult, error) {
	if opts.ConfigPath == "" {
		opts.ConfigPath = defaultConfigPath()
	}
	command := opts.Command
	if command == "" {
		command = "env HERDR_PLUGIN_STATE_DIR=" + shellQuote(opts.StateDir) + " \"" + opts.PluginRoot + "/bin/forward\" list --oneline"
	}
	raw, err := os.ReadFile(opts.ConfigPath)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return installerResult{}, fmt.Errorf("install-tabbar: 无法读取 %s：%w", opts.ConfigPath, err)
	}
	text := string(raw)
	if err := validateTOML(text); err != nil {
		return installerResult{}, fmt.Errorf("install-tabbar: 处理 %s 失败：非法 TOML（原文件未修改）: %w", opts.ConfigPath, err)
	}
	if !strings.Contains(text, tabbarMarker) {
		out, err := insertTabbar(text, renderTabbarEntry(command, 5, 2))
		if err != nil {
			return installerResult{}, err
		}
		if err := validateTOML(out); err != nil {
			return installerResult{}, fmt.Errorf("install-tabbar: 生成内容不是合法 TOML：%w", err)
		}
		return installerResult{Changed: true, Content: out}, nil
	}
	open, close, ok := locateArray(text, "tab_bar_right")
	if !ok {
		return installerResult{}, fmt.Errorf("install-tabbar: marker present but tab_bar_right array not located")
	}
	inner := text[open+1 : close]
	parts := splitTopLevel(inner)
	chunks := make([]string, 0, len(parts))
	replaced := 0
	for _, part := range parts {
		chunk := strings.TrimSpace(part)
		if chunk == "" {
			continue
		}
		if !strings.Contains(chunk, tabbarMarker) {
			chunks = append(chunks, chunk)
			continue
		}
		entry, ok := parseInlineEntry(chunk)
		if !ok {
			return installerResult{Already: true}, nil
		}
		oldCommand := stringValue(entry["command"])
		if oldCommand == command {
			return installerResult{Already: true}, nil
		}
		interval := saneInt(entry["interval_seconds"], 5, 1, 31536000)
		timeout := saneInt(entry["timeout_seconds"], 2, 1, 3600)
		chunks = append(chunks, tabbarMarker+"\n"+renderTabbarEntry(command, interval, timeout))
		replaced++
	}
	if replaced != 1 {
		return installerResult{Already: true}, nil
	}
	rebuilt := "[\n"
	for _, chunk := range chunks {
		rebuilt += indentBlock(chunk) + ",\n"
	}
	rebuilt += "]"
	out := text[:open] + rebuilt + text[close+1:]
	if !strings.HasSuffix(out, "\n") {
		out += "\n"
	}
	if err := validateTOML(out); err != nil {
		return installerResult{}, fmt.Errorf("install-tabbar: 生成内容不是合法 TOML：%w", err)
	}
	return installerResult{Changed: true, Content: out}, nil
}

func performInstallKeys(opts installerOptions) (installerResult, error) {
	if opts.AddKey == "" {
		opts.AddKey = "prefix+f"
	}
	if opts.ListKey == "" {
		opts.ListKey = "prefix+shift+f"
	}
	if opts.DoctorKey == "" {
		opts.DoctorKey = "prefix+alt+f"
	}
	raw, err := os.ReadFile(opts.ConfigPath)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return installerResult{}, fmt.Errorf("install-keys: 无法读取 %s：%w", opts.ConfigPath, err)
	}
	text := string(raw)
	doc, err := decodeTOML(text)
	if err != nil {
		return installerResult{}, fmt.Errorf("install-keys: 处理 %s 失败：非法 TOML（原文件未修改）: %w", opts.ConfigPath, err)
	}
	if strings.Contains(text, keysMarker) {
		return installerResult{Already: true}, nil
	}
	conflicts, conflictMap := keyConflicts(doc, []keySpec{
		{Key: opts.AddKey, Action: "add"},
		{Key: opts.ListKey, Action: "list"},
		{Key: opts.DoctorKey, Action: "doctor"},
	})
	lines := splitLinesNoTrailing(text)
	if len(lines) > 0 && strings.TrimSpace(lines[len(lines)-1]) != "" {
		lines = append(lines, "")
	}
	lines = append(lines, keysMarker,
		"[[keys.command]]", "key = "+tomlString(opts.AddKey), `type = "plugin_action"`, "command = "+tomlString(pluginID+".add"), `description = "Port Forward: Add / open panel"`, "",
		"[[keys.command]]", "key = "+tomlString(opts.ListKey), `type = "plugin_action"`, "command = "+tomlString(pluginID+".list"), `description = "Port Forward: List forwards"`, "",
		"[[keys.command]]", "key = "+tomlString(opts.DoctorKey), `type = "plugin_action"`, "command = "+tomlString(pluginID+".doctor"), `description = "Port Forward: Doctor (probe tunnels)"`, "")
	out := strings.Join(lines, "\n") + "\n"
	if err := validateTOML(out); err != nil {
		return installerResult{}, fmt.Errorf("install-keys: 生成内容不是合法 TOML：%w", err)
	}
	return installerResult{Changed: true, Content: out, Conflicts: conflicts, ConflictMap: conflictMap}, nil
}

type keySpec struct {
	Key    string
	Action string
}

func keyConflicts(doc map[string]any, specs []keySpec) ([]string, map[string]string) {
	wanted := map[string]bool{pluginID + ".add": true, pluginID + ".list": true, pluginID + ".doctor": true}
	occupied := map[string]string{}
	keys, _ := nestedMap(doc, "keys")
	entries := anySlice(keys["command"])
	for _, raw := range entries {
		entry, ok := raw.(map[string]any)
		if !ok {
			continue
		}
		command := stringValue(entry["command"])
		if wanted[command] {
			continue
		}
		key := stringValue(entry["key"])
		if key != "" {
			occupied[key] = command
		}
	}
	conflicts := []string{}
	for _, spec := range specs {
		if _, ok := occupied[spec.Key]; ok {
			conflicts = append(conflicts, spec.Key)
		}
	}
	return conflicts, occupied
}

func printConflictWarnings(path string, res installerResult) {
	keys := append([]string(nil), res.Conflicts...)
	sort.Strings(keys)
	for _, key := range keys {
		fmt.Fprintf(os.Stderr, "warning: key '%s' is already bound to '%s' in %s; install anyway (pass --add-key/--list-key/--doctor-key to pick another key)\n", key, res.ConflictMap[key], path)
	}
}

func writeInstallerFile(path string, content []byte) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return fmt.Errorf("无法创建目录 %s: %w", dir, err)
	}
	if _, err := os.Stat(path); err == nil {
		epoch := time.Now().Unix()
		backup := fmt.Sprintf("%s.bak.%d", path, epoch)
		for n := int64(1); ; n++ {
			if _, existsErr := os.Stat(backup); os.IsNotExist(existsErr) {
				break
			}
			backup = fmt.Sprintf("%s.bak.%d.%d", path, epoch, n)
		}
		if err := copyFile(path, backup); err != nil {
			return fmt.Errorf("备份失败: %s: %w", backup, err)
		}
		fmt.Fprintf(os.Stdout, "备份原文件 -> %s\n", backup)
	}
	return hfcommon.AtomicWrite(path, content)
}

func copyFile(src, dst string) error {
	data, err := os.ReadFile(src)
	if err != nil {
		return err
	}
	mode := os.FileMode(0o600)
	if st, err := os.Stat(src); err == nil {
		mode = st.Mode().Perm()
	}
	return os.WriteFile(dst, data, mode)
}

func validateTOML(text string) error {
	if strings.TrimSpace(text) == "" {
		return nil
	}
	_, err := decodeTOML(text)
	return err
}

func decodeTOML(text string) (map[string]any, error) {
	doc := map[string]any{}
	_, err := toml.Decode(text, &doc)
	return doc, err
}

func nestedMap(doc map[string]any, key string) (map[string]any, bool) {
	v, ok := doc[key]
	if !ok {
		return nil, false
	}
	m, ok := v.(map[string]any)
	return m, ok
}

func anySlice(v any) []any {
	if v == nil {
		return nil
	}
	if out, ok := v.([]any); ok {
		return out
	}
	rv := reflect.ValueOf(v)
	if rv.Kind() != reflect.Slice && rv.Kind() != reflect.Array {
		return nil
	}
	out := make([]any, rv.Len())
	for i := range out {
		out[i] = rv.Index(i).Interface()
	}
	return out
}

func stringValue(v any) string {
	s, _ := v.(string)
	return s
}

func saneInt(v any, def, lo, hi int) int {
	var n int64
	switch x := v.(type) {
	case int:
		n = int64(x)
	case int64:
		n = x
	case int32:
		n = int64(x)
	case uint64:
		n = int64(x)
	case float64:
		n = int64(x)
	default:
		return def
	}
	if n < int64(lo) || n > int64(hi) {
		return def
	}
	return int(n)
}

func tomlString(value string) string {
	return `"` + strings.NewReplacer(`\`, `\\`, `"`, `\"`, "\n", `\n`, "\t", `\t`).Replace(value) + `"`
}

func renderTabbarEntry(command string, interval, timeout int) string {
	return fmt.Sprintf(`{ type = "command", command = %s, interval_seconds = %d, timeout_seconds = %d }`, tomlString(command), interval, timeout)
}

func splitLinesNoTrailing(text string) []string {
	if text == "" {
		return []string{}
	}
	return strings.Split(strings.TrimSuffix(text, "\n"), "\n")
}

func indentBlock(text string) string {
	lines := strings.Split(text, "\n")
	for i := range lines {
		if strings.TrimSpace(lines[i]) != "" {
			lines[i] = "  " + lines[i]
		}
	}
	return strings.Join(lines, "\n")
}

func locateArray(src, keyword string) (int, int, bool) {
	keyAt := strings.Index(src, keyword)
	if keyAt < 0 {
		return 0, 0, false
	}
	eq := strings.Index(src[keyAt:], "=")
	if eq < 0 {
		return 0, 0, false
	}
	eq += keyAt
	open := strings.Index(src[eq+1:], "[")
	if open < 0 {
		return 0, 0, false
	}
	open += eq + 1
	depth := 0
	inString, escape := false, false
	for i := open; i < len(src); i++ {
		ch := src[i]
		if inString {
			if escape {
				escape = false
			} else if ch == '\\' {
				escape = true
			} else if ch == '"' {
				inString = false
			}
			continue
		}
		if ch == '"' {
			inString = true
			continue
		}
		switch ch {
		case '[':
			depth++
		case ']':
			depth--
			if depth == 0 {
				return open, i, true
			}
		}
	}
	return 0, 0, false
}

func splitTopLevel(inner string) []string {
	parts := []string{}
	start, depth := 0, 0
	inString, escape := false, false
	for i, ch := range inner {
		if inString {
			if escape {
				escape = false
			} else if ch == '\\' {
				escape = true
			} else if ch == '"' {
				inString = false
			}
			continue
		}
		if ch == '"' {
			inString = true
			continue
		}
		switch ch {
		case '[', '{':
			depth++
		case ']', '}':
			depth--
		case ',':
			if depth == 0 {
				parts = append(parts, inner[start:i])
				start = i + 1
			}
		}
	}
	parts = append(parts, inner[start:])
	return parts
}

func parseInlineEntry(chunk string) (map[string]any, bool) {
	bodyLines := []string{}
	for _, line := range strings.Split(chunk, "\n") {
		if strings.TrimSpace(line) == "" || strings.HasPrefix(strings.TrimSpace(line), "#") {
			continue
		}
		bodyLines = append(bodyLines, line)
	}
	if len(bodyLines) == 0 {
		return nil, false
	}
	var wrapper map[string]any
	if _, err := toml.Decode("x = "+strings.TrimSpace(strings.Join(bodyLines, "\n")), &wrapper); err != nil {
		return nil, false
	}
	entry, ok := wrapper["x"].(map[string]any)
	return entry, ok
}

func insertTabbar(text, entry string) (string, error) {
	block := "tab_bar_right = [\n  " + tabbarMarker + "\n  " + entry + ",\n]"
	lines := splitLinesNoTrailing(text)
	uiStart, uiEnd := -1, len(lines)
	for i, line := range lines {
		trim := strings.TrimSpace(line)
		if trim == "[ui]" {
			uiStart = i
			continue
		}
		if uiStart >= 0 && strings.HasPrefix(trim, "[") && strings.HasSuffix(trim, "]") {
			uiEnd = i
			break
		}
	}
	if uiStart < 0 {
		if len(lines) > 0 && strings.TrimSpace(lines[len(lines)-1]) != "" {
			lines = append(lines, "")
		}
		lines = append(lines, append([]string{"[ui]"}, strings.Split(block, "\n")...)...)
		return strings.Join(lines, "\n") + "\n", nil
	}
	arrayLine := -1
	for i := uiStart + 1; i < uiEnd; i++ {
		if strings.HasPrefix(strings.TrimSpace(lines[i]), "tab_bar_right") {
			arrayLine = i
			break
		}
	}
	if arrayLine < 0 {
		at := uiEnd
		for at-1 > uiStart && strings.TrimSpace(lines[at-1]) == "" {
			at--
		}
		insert := strings.Split(block, "\n")
		lines = append(lines[:at], append(insert, lines[at:]...)...)
		return strings.Join(lines, "\n") + "\n", nil
	}
	joined := strings.Join(lines, "\n")
	open, close, ok := locateArray(joined, "tab_bar_right")
	if !ok {
		return "", fmt.Errorf("install-tabbar: cannot locate tab_bar_right array")
	}
	inner := joined[open+1 : close]
	chunks := []string{}
	for _, part := range splitTopLevel(inner) {
		if s := strings.TrimSpace(part); s != "" {
			chunks = append(chunks, s)
		}
	}
	chunks = append(chunks, tabbarMarker+"\n"+entry)
	rebuilt := "[\n"
	for _, chunk := range chunks {
		rebuilt += indentBlock(chunk) + ",\n"
	}
	rebuilt += "]"
	out := joined[:open] + rebuilt + joined[close+1:]
	if !strings.HasSuffix(out, "\n") {
		out += "\n"
	}
	return out, nil
}

// internalStartupHook is the Go replacement for scripts/startup-hook.sh.  It
// intentionally keeps the startup contract forgiving: every operational error
// is reported and returns zero so a herdr server is never blocked by UI setup.
func internalStartupHook(args []string) int {
	opts := installerOptions{ConfigPath: defaultConfigPath()}
	dry := false
	for len(args) > 0 {
		switch args[0] {
		case "--config":
			if len(args) < 2 {
				fmt.Fprintln(os.Stderr, "startup-hook: --config 缺少参数值")
				return exitOK
			}
			opts.ConfigPath = args[1]
			args = args[2:]
		case "--state-dir":
			if len(args) < 2 {
				fmt.Fprintln(os.Stderr, "startup-hook: --state-dir 缺少参数值")
				return exitOK
			}
			opts.StateDir = args[1]
			args = args[2:]
		case "--dry-run":
			dry = true
			args = args[1:]
		case "--help", "-h":
			fmt.Print("用法: startup-hook.sh [--config PATH] [--state-dir PATH] [--dry-run]\n恒 exit 0；失败只记录提示，不阻塞 herdr server。\n默认键位：prefix+f / prefix+shift+f / prefix+alt+f；安装器：install-tabbar / install-keys。\n")
			return exitOK
		default:
			fmt.Fprintf(os.Stderr, "startup-hook: warn: 未知参数 '%s'（忽略）\n", args[0])
			args = args[1:]
		}
	}
	if opts.ConfigPath == "" {
		fmt.Fprintln(os.Stderr, "startup-hook: warn: 无法确定 herdr config 路径，跳过 UI 安装。")
		return exitOK
	}
	if opts.PluginRoot == "" {
		opts.PluginRoot = pluginRootOfSelf()
	}
	stateOverride := opts.StateDir != ""
	if opts.StateDir == "" {
		opts.StateDir = os.Getenv("HERDR_PLUGIN_STATE_DIR")
	}
	active, root, activeState, remote := startupActivation()
	if remote {
		opts.PluginRoot = root
		if !stateOverride {
			opts.StateDir = activeState
		}
	}
	if opts.StateDir == "" {
		opts.StateDir = defaultPluginStateDir()
	}
	hfcommon.Logf("info", "startup: 检查 tab bar 条目（config=%s）", opts.ConfigPath)
	opts.DryRun = dry
	changed := false
	if res, err := performInstallTabbar(opts); err != nil {
		fmt.Fprintf(os.Stderr, "startup-hook: warn: tab bar 自动安装失败：%v\n", err)
	} else if res.Already {
		fmt.Fprintln(os.Stdout, "startup: tab bar 条目已存在，跳过（幂等）")
	} else if dry {
		fmt.Printf("[dry-run] 将写入 %s：\n---\n%s---\n", opts.ConfigPath, res.Content)
	} else if err := writeInstallerFile(opts.ConfigPath, []byte(res.Content)); err != nil {
		fmt.Fprintf(os.Stderr, "startup-hook: warn: tab bar 写入失败：%v\n", err)
	} else {
		changed = true
		fmt.Fprintf(os.Stdout, "提示：tab bar 条目已就绪（config=%s）。\n", opts.ConfigPath)
	}
	fmt.Fprintln(os.Stdout, "提示：若 herdr client 跑在另一台机器（跨机 attach），请在 client 机器运行 scripts/bootstrap.sh --config <A 的 config> --plugin-root <server B 的插件根> --state-dir <server B 的插件 state 目录>。")

	keyOpts := opts
	keyOpts.PluginRoot = ""
	skipKeys := os.Getenv("HERDR_FORWARD_SKIP_KEYS") == "1"
	if root := pluginRootOfSelf(); root != "" {
		if _, err := os.Stat(filepath.Join(root, "scripts", "install-keys.sh")); err != nil {
			skipKeys = true
		}
	}
	if skipKeys {
		fmt.Fprintln(os.Stderr, "startup-hook: warn: 缺少 install-keys.sh；跳过键位自动安装。")
	} else {
		probeOpts := keyOpts
		probeOpts.DryRun = true
		probe, err := performInstallKeys(probeOpts)
		if err != nil {
			fmt.Fprintf(os.Stderr, "startup-hook: warn: 键位自动安装前探测失败：%v\n", err)
		} else if probe.Already {
			fmt.Fprintln(os.Stdout, "startup: 键位已存在，跳过（幂等）")
		} else if len(probe.Conflicts) > 0 {
			printConflictWarnings(opts.ConfigPath, probe)
			fmt.Fprintf(os.Stdout, "提示：默认键位 %s 已被其它命令占用，本次跳过自动安装；请用 bootstrap.sh --add-key prefix+<你的键> 换键。\n", strings.Join(probe.Conflicts, ", "))
		} else if dry {
			fmt.Fprintln(os.Stdout, "startup: [dry-run] 将写入键位（prefix+f / prefix+shift+f / prefix+alt+f），未落盘")
		} else {
			keyOpts.DryRun = false
			keys, keyErr := performInstallKeys(keyOpts)
			if keyErr != nil {
				fmt.Fprintf(os.Stderr, "startup-hook: warn: 键位自动安装失败：%v\n", keyErr)
			} else if keys.Changed {
				if err := writeInstallerFile(opts.ConfigPath, []byte(keys.Content)); err != nil {
					fmt.Fprintf(os.Stderr, "startup-hook: warn: 键位写入失败：%v\n", err)
				} else {
					changed = true
					fmt.Fprintln(os.Stdout, "提示：herdr-forward 键位已就绪：prefix+f 打开 Port Forward 面板；prefix+shift+f 列出转发；prefix+alt+f 探活检查。换键：bootstrap.sh --add-key prefix+<你的键>；执行 reload-config 后生效。")
				}
			}
		}
	}
	if !dry && changed && os.Getenv("HERDR_PLUGIN_ID") != "" && os.Getenv("HERDR_BIN_PATH") != "" {
		if output, ok := runBoundedArgvOut(15, []string{os.Getenv("HERDR_BIN_PATH"), "server", "reload-config"}); ok {
			_ = output
			fmt.Fprintln(os.Stdout, "提示：已自动重载 herdr 配置 —— 现在就可以按 prefix+f。")
		} else {
			fmt.Fprintln(os.Stderr, "startup-hook: warn: 自动 reload-config 失败；请在 herdr 里执行 reload-config。")
		}
	}
	if !dry && remote && active != "" {
		fwd := binForwardPath()
		if _, err := os.Stat(fwd); err == nil {
			if out, ok := runBoundedArgvOut(15, []string{fwd, "bridge", "up", active}); ok {
				message := fmt.Sprintf("startup: 桥接 → %s：%s", active, strings.TrimSpace(out))
				fmt.Fprintln(os.Stdout, message)
				hfcommon.Log("info", message)
			} else {
				fmt.Fprintf(os.Stderr, "startup-hook: warn: 到 %s 的桥接未能启动；稍后运行 forward machines doctor 重试。\n", active)
			}
		}
	}
	return exitOK
}

func startupActivation() (active, root, stateDir string, remote bool) {
	if os.Getenv("HERDR_FORWARD_SKIP_MACHINE_ACTIVATION") == "1" {
		return "", pluginRootOfSelf(), "", false
	}
	if root := pluginRootOfSelf(); root != "" {
		if _, err := os.Stat(filepath.Join(root, "lib", "machines.sh")); err != nil {
			return "", root, "", false
		}
	}
	active = machine.ActiveID()
	root = pluginRootOfSelf()
	if active == "" {
		return
	}
	rec, err := machine.GetActivation(active)
	if err != nil {
		return "", root, "", false
	}
	target := rec.String("ssh_target")
	if machine.IsLocalTarget(target) {
		return active, root, "", false
	}
	root = rec.String("server_root")
	stateDir = rec.String("state_dir")
	if root == "" || stateDir == "" {
		fmt.Fprintf(os.Stderr, "startup-hook: warn: active machine '%s' 的激活记录不完整，按本机路径处理。\n", active)
		return active, pluginRootOfSelf(), "", false
	}
	return active, root, stateDir, true
}

// internalPostinstall keeps the [[build]] path non-blocking.  Phase 5 will add
// release download/checksum handling at the wrapper's marked hook; this phase
// deliberately performs no network access.
func internalPostinstall(args []string) int {
	opts := installerOptions{ConfigPath: defaultConfigPath()}
	for len(args) > 0 {
		if args[0] == "--config" && len(args) > 1 {
			opts.ConfigPath = args[1]
			args = args[2:]
			continue
		}
		args = args[1:]
	}
	probe := opts
	probe.DryRun = true
	res, err := performInstallKeys(probe)
	if err != nil {
		fmt.Fprintf(os.Stdout, "herdr-forward: 键位预检失败，跳过；herdr 下次启动时会自动补上。\n")
		hfcommon.Logf("warn", "postinstall keys probe: %v", err)
		return exitOK
	}
	if res.Already {
		return exitOK
	}
	if len(res.Conflicts) > 0 {
		printConflictWarnings(opts.ConfigPath, res)
		fmt.Fprintf(os.Stdout, "herdr-forward: 默认键位 %s 已被别的命令占用，未覆盖。换键：%s/scripts/bootstrap.sh --add-key prefix+<你的键>\n", strings.Join(res.Conflicts, ", "), pluginRootOfSelf())
		return exitOK
	}
	res, err = performInstallKeys(opts)
	if err != nil {
		fmt.Fprintf(os.Stdout, "herdr-forward: 键位安装失败，跳过；herdr 下次启动时会自动补上。\n")
		hfcommon.Logf("warn", "postinstall keys install: %v", err)
		return exitOK
	}
	if err := writeInstallerFile(opts.ConfigPath, []byte(res.Content)); err != nil {
		fmt.Fprintf(os.Stdout, "herdr-forward: 键位安装失败，跳过；herdr 下次启动时会自动补上。\n")
		hfcommon.Logf("warn", "postinstall keys write: %v", err)
		return exitOK
	}
	fmt.Fprintln(os.Stdout, "herdr-forward: 已装好键位：prefix+f 打开 Port Forward 面板（prefix+shift+f 列表，prefix+alt+f 探活）。")
	herdr, err := exec.LookPath("herdr")
	if err != nil {
		fmt.Fprintln(os.Stdout, "herdr-forward: 找不到 herdr 命令；在 herdr 里执行 reload-config 后键位生效。")
		return exitOK
	}
	if _, ok := runBoundedArgvOut(10, []string{herdr, "server", "reload-config"}); ok {
		fmt.Fprintln(os.Stdout, "herdr-forward: 已重载 herdr 配置：现在就可以按 prefix+f。")
	} else {
		fmt.Fprintln(os.Stdout, "herdr-forward: herdr 未在运行（或重载失败）；下次启动 herdr 时键位即生效。")
	}
	return exitOK
}

func internalBootstrap(args []string) int {
	opts := installerOptions{ConfigPath: defaultConfigPath()}
	doTabbar, doKeys := true, true
	keyArgs := []string{}
	for len(args) > 0 {
		switch args[0] {
		case "--config":
			if len(args) < 2 {
				return die(exitUsage, "--config 需要参数值")
			}
			opts.ConfigPath, args = args[1], args[2:]
		case "--plugin-root":
			if len(args) < 2 {
				return die(exitUsage, "--plugin-root 需要参数值")
			}
			opts.PluginRoot, args = args[1], args[2:]
		case "--state-dir":
			if len(args) < 2 {
				return die(exitUsage, "--state-dir 需要参数值")
			}
			opts.StateDir, args = args[1], args[2:]
		case "--dry-run":
			opts.DryRun = true
			args = args[1:]
		case "--no-tabbar":
			doTabbar = false
			args = args[1:]
		case "--no-keys":
			doKeys = false
			args = args[1:]
		case "--add-key", "--list-key", "--doctor-key":
			if len(args) < 2 {
				return die(exitUsage, args[0]+" 需要参数值")
			}
			keyArgs = append(keyArgs, args[0], args[1])
			args = args[2:]
		case "--help", "-h":
			fmt.Print("用法: forward bootstrap [--config PATH] [--plugin-root PATH] [--state-dir PATH] [--dry-run] [--no-tabbar] [--no-keys]\n")
			return exitOK
		default:
			return die(exitUsage, "未知参数: "+args[0]+"（用 --help 查看用法）")
		}
	}
	if !doTabbar && !doKeys {
		return die(exitUsage, "--no-tabbar 与 --no-keys 同时指定：没有可执行的安装步骤，请去掉其一。")
	}
	if opts.PluginRoot == "" {
		opts.PluginRoot = pluginRootOfSelf()
	}
	if !filepath.IsAbs(opts.PluginRoot) {
		return die(exitUsage, fmt.Sprintf("--plugin-root 必须是绝对路径（收到 '%s'）", opts.PluginRoot))
	}
	if opts.StateDir == "" {
		opts.StateDir = os.Getenv("HERDR_PLUGIN_STATE_DIR")
	}
	if opts.StateDir == "" {
		opts.StateDir = defaultPluginStateDir()
	}
	if !filepath.IsAbs(opts.StateDir) {
		return die(exitUsage, fmt.Sprintf("state 目录必须是绝对路径（收到 '%s'）", opts.StateDir))
	}
	fmt.Printf("bootstrap: herdr-forward OOTB 安装（config=%s）\n", opts.ConfigPath)
	if doTabbar {
		res, err := performInstallTabbar(opts)
		if err != nil {
			return die(exitError, err.Error())
		}
		if res.Already {
			fmt.Fprintln(os.Stdout, "install-tabbar: already installed（幂等）")
		} else if opts.DryRun {
			fmt.Printf("[dry-run] 将写入 %s：\n---\n%s---\n", opts.ConfigPath, res.Content)
		} else if err := writeInstallerFile(opts.ConfigPath, []byte(res.Content)); err != nil {
			return die(exitError, err.Error())
		} else {
			fmt.Printf("install-tabbar: 已写入 %s\n", opts.ConfigPath)
		}
	}
	if doKeys {
		keyOpts := opts
		keyOpts.AddKey, keyOpts.ListKey, keyOpts.DoctorKey = "prefix+f", "prefix+shift+f", "prefix+alt+f"
		for i := 0; i+1 < len(keyArgs); i += 2 {
			switch keyArgs[i] {
			case "--add-key":
				keyOpts.AddKey = keyArgs[i+1]
			case "--list-key":
				keyOpts.ListKey = keyArgs[i+1]
			case "--doctor-key":
				keyOpts.DoctorKey = keyArgs[i+1]
			}
		}
		res, err := performInstallKeys(keyOpts)
		if err != nil {
			return die(exitError, err.Error())
		}
		printConflictWarnings(opts.ConfigPath, res)
		if res.Already {
			fmt.Fprintln(os.Stdout, "install-keys: already installed（幂等）")
		} else if opts.DryRun {
			fmt.Printf("[dry-run] 将写入 %s：\n---\n%s---\n", opts.ConfigPath, res.Content)
		} else if err := writeInstallerFile(opts.ConfigPath, []byte(res.Content)); err != nil {
			return die(exitError, err.Error())
		} else {
			fmt.Fprintln(os.Stdout, "install-keys: 已写入键位（prefix+f / prefix+shift+f / prefix+alt+f）")
		}
	}
	fmt.Fprintln(os.Stdout, "下一步：运行 herdr server reload-config（或重启 herdr）使 tab bar 与键位生效。")
	fmt.Fprintln(os.Stdout, "跨机：client A 与 server B 不共享 config，请在 client 上用 --plugin-root/--state-dir 指向 B。")
	return exitOK
}

func internalDiagnosePanel(args []string) int {
	jsonMode := false
	for _, arg := range args {
		switch arg {
		case "--json":
			jsonMode = true
		case "--help", "-h":
			fmt.Println("用法: forward internal diagnose-panel [--json]")
			return exitOK
		default:
			return die(exitUsage, "未知参数："+arg)
		}
	}
	machines := machine.View()
	frame := panel.RenderFrame(3 * time.Second)
	if jsonMode {
		fmt.Printf("{\"machine_count\":%d,\"panel_contains_machines\":%t}\n", len(machines), strings.Contains(frame, "MACHINES"))
		return exitOK
	}
	fmt.Println("=== herdr-forward 面板诊断（只读） ===")
	fmt.Printf("HERDR_BIN_PATH: %s\n", os.Getenv("HERDR_BIN_PATH"))
	fmt.Printf("saved machines: %d\n", len(machines))
	fmt.Println("--- panel frame ---")
	fmt.Print(frame)
	return exitOK
}
