// machines.go —— `forward machines {list,activate,deactivate,doctor}`（← bin/forward 的
// cmd_machines* 段）。
//
// 退出码（与 bash 逐条对齐，A.3 冻结表 + 「激活半成品」的 1）：
//
//	0  ok（含「同机短路」「无需检查」等正常路径）
//	1  激活记录已写入但 tab bar 安装器失败（半成品，用 deactivate 回滚）
//	3  未知 id/label（列可用机器）
//	4  探测失败（absent / no-herdr / unreachable / 缺插件根）
//	64 用法错误
//
// 用户可见文案是契约：tests/unit/test_machines_cmd.sh 与
// tests/integration/test_machines_probe.sh 对着它们逐条断言；这里逐字复刻 bash 的 printf。
package cli

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/zzjcool/herdr-forward/internal/hfcommon"
	"github.com/zzjcool/herdr-forward/internal/machine"
	"github.com/zzjcool/herdr-forward/internal/sshprobe"
)

// exitPartialActivation 是「探测通过但写记录/装 UI 失败」的退出码（冻结表未覆盖，
// bash 用 1 显式失败，见 cmd_machines_activate 的注释）。
const exitPartialActivation = 1

// cmdMachines 复刻 cmd_machines 的子命令分派。
func cmdMachines(args []string) int {
	if len(args) == 0 {
		return die(exitUsage, "缺少 machines 子命令。用法：forward machines list|activate|deactivate|doctor（'forward --help' 查看）")
	}
	sub := args[0]
	rest := args[1:]
	switch sub {
	case "list":
		return cmdMachinesList(rest)
	case "activate":
		return cmdMachinesActivate(rest)
	case "deactivate":
		return cmdMachinesDeactivate(rest)
	case "doctor":
		return cmdMachinesDoctor(rest)
	case "help", "--help", "-h":
		fmt.Print("用法：forward machines <list|activate|deactivate|doctor>\n" +
			"  list [--json] [--short]      列出 saved machines 与激活状态\n" +
			"  activate <id|label> [--install]  激活（远端先只读 SSH 探测；未装插件可代装）并启动桥接\n" +
			"  deactivate <id|all>         停用并把 tab bar 恢复本机路径\n" +
			"  doctor                      重探测 active 机器（stale 路径检测）\n")
		return exitOK
	}
	if strings.HasPrefix(sub, "-") {
		return die(exitUsage, "未知参数："+sub+"。用法：forward machines list|activate|deactivate|doctor")
	}
	return die(exitUsage, "未知 machines 子命令："+sub+"。可用：list / activate / deactivate / doctor。")
}

// machinesView 是合并视图（复用 machine.View 的冻结形状）。
func machinesView() []machine.MachineView { return machine.View() }

// machinesShortRow 复刻 `--short` 的 TSV 行格式（marker <TAB> id <TAB> label <TAB>
// target <TAB> state <TAB> orphan-note）。
func machinesShortRow(v machine.MachineView) string {
	marker := "[ ]"
	switch v.State {
	case "active":
		marker = "[✓]"
	case "activated":
		marker = "[·]"
	case "local":
		marker = "[✓ local]"
	}
	note := ""
	if v.Orphan {
		note = "saved machine 已删除（记录残留）"
	}
	return strings.Join([]string{marker, v.ID, v.Label, v.Target, v.State, note}, "\t")
}

// cmdMachinesList 复刻 cmd_machines_list（表格 / --json / --short 三形态）。
func cmdMachinesList(args []string) int {
	mode := "table"
	for len(args) > 0 {
		arg := args[0]
		switch {
		case arg == "--json":
			mode = "json"
		case arg == "--short":
			mode = "short"
		case strings.HasPrefix(arg, "-"):
			return die(exitUsage, "未知参数："+arg+"。用法：forward machines list [--json] [--short]")
		default:
			return die(exitUsage, "list 不接受位置参数："+arg+"。用法：forward machines list [--json] [--short]")
		}
		args = args[1:]
	}

	view := machinesView()
	switch mode {
	case "json":
		// bash: `printf '%s\n' "${view}" | jq -c '.'` —— 空数组也输出 `[]`
		fmt.Print(string(machine.ViewJSON()))
		return exitOK
	case "short":
		for _, v := range view {
			fmt.Println(machinesShortRow(v))
		}
		return exitOK
	}

	if len(view) == 0 {
		fmt.Print("没有可用的 saved machines。\n")
		fmt.Print("  可能原因：herdr 里还没保存 machine（herdr machine add）；或本命令不是从 herdr 插件上下文调起的（HERDR_BIN_PATH 未注入，非插件运行时属正常）。\n")
		return exitOK
	}
	fmt.Printf("%-10s %-20s %-24s %-16s %s\n", "STATE", "ID", "LABEL", "TARGET", "NOTE")
	for _, v := range view {
		target := v.Target
		if target == "" {
			target = "-"
		}
		note := ""
		if v.Orphan {
			note = "saved machine 已删除（记录残留）"
		}
		// 复刻 bash 的 `printf '%-10s %-20s %-24s %-16s %s\n'`（列宽按字符填充）
		fmt.Printf("%-10s %-20s %-24s %-16s %s\n", machinesShortMarker(v), v.ID, v.Label, target, note)
	}
	fmt.Print("\n[✓] 当前激活  [·] 曾激活（可重新激活）  [ ] 未激活  [✓ local] 本机\n")
	fmt.Print("激活：forward machines activate <id|label>    停用：forward machines deactivate <id|all>\n")
	return exitOK
}

// machinesShortMarker 复刻表格首列的标记（与 --short 同源，避免双份判定）。
func machinesShortMarker(v machine.MachineView) string {
	switch v.State {
	case "active":
		return "[✓]"
	case "activated":
		return "[·]"
	case "local":
		return "[✓ local]"
	default:
		return "[ ]"
	}
}

// resolveMachineIDOrDie 复刻 machines_resolve_id 的失败路径（die 3 + 可用列表）。
func resolveMachineIDOrDie(arg string) (string, int) {
	id, err := machine.ResolveID(arg)
	if err == nil {
		return id, exitOK
	}
	if available := machine.AvailableIDs(); available != "" {
		return "", die(exitNotFound, fmt.Sprintf("machine '%s' 不存在。可用的 saved machines：%s。请用 'forward machines list' 查看。", arg, available))
	}
	return "", die(exitNotFound, fmt.Sprintf("machine '%s' 不存在，且 herdr 当前没有返回任何 saved machines（HERDR_BIN_PATH 未设置 / herdr 未运行？）。请用 'forward machines list' 查看。", arg))
}

// installTabbar 复刻 _hf_install_tabbar：调 scripts/install-tabbar.sh（保持 stdout 干净）。
//
// pluginRoot / stateDir 为空表示「恢复本机路径」（脚本自动解析自身所在的插件根）。
func installTabbar(pluginRoot, stateDir string) int {
	script := filepath.Join(pluginRootOfSelf(), "scripts", "install-tabbar.sh")
	if _, err := os.Stat(script); err != nil {
		hfcommon.Logf("warn", "缺少 %s，跳过 tab bar 更新。请手动运行：bash %s", script, script)
		return 0
	}
	argv := []string{"bash", script, "--config", herdrConfigPath()}
	if pluginRoot != "" {
		argv = append(argv, "--plugin-root", pluginRoot)
	}
	if stateDir != "" {
		argv = append(argv, "--state-dir", stateDir)
	}
	return runForwardingStderr(argv)
}

// installKeys 复刻 _hf_install_keys（同样保持 stdout 干净）。
func installKeys() int {
	script := filepath.Join(pluginRootOfSelf(), "scripts", "install-keys.sh")
	if _, err := os.Stat(script); err != nil {
		hfcommon.Logf("warn", "缺少 %s，跳过键位安装。请手动运行：bash %s", script, script)
		return 0
	}
	return runForwardingStderr([]string{"bash", script, "--config", herdrConfigPath()})
}

// runForwardingStderr 跑一条外部命令，把它的 stdout/stderr 都接到**本进程的 stderr**
// （复刻 bash 的 `bash "${args[@]}" >&2`：安装器的输出不能污染本命令的 stdout）。
func runForwardingStderr(argv []string) int {
	cmd := exec.Command(argv[0], argv[1:]...)
	cmd.Stdout = os.Stderr
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok {
			return exitErr.ExitCode()
		}
		return 1
	}
	return 0
}

// pluginRootOfSelf 解析本 CLI 所属的插件根。
//
// Go 二进制位于 <plugin_root>/bin/forward-go，由 <plugin_root>/bin/forward 条件 exec；
// 因此可执行文件的父目录的父目录就是插件根。HERDR_PLUGIN_ROOT 优先（herdr 注入）。
func pluginRootOfSelf() string {
	if root := os.Getenv("HERDR_PLUGIN_ROOT"); root != "" {
		return root
	}
	exe, err := os.Executable()
	if err != nil {
		return ""
	}
	if resolved, err := filepath.EvalSymlinks(exe); err == nil {
		exe = resolved
	}
	return filepath.Dir(filepath.Dir(exe))
}

// herdrConfigPath 复刻 _hf_config_path：$HERDR_CONFIG_PATH 优先，否则 ~/.config/herdr/config.toml。
func herdrConfigPath() string {
	if p := os.Getenv("HERDR_CONFIG_PATH"); p != "" {
		return p
	}
	base := os.Getenv("XDG_CONFIG_HOME")
	if base == "" {
		home := os.Getenv("HOME")
		if home == "" {
			home = "/tmp"
		}
		base = filepath.Join(home, ".config")
	}
	return filepath.Join(base, "herdr", "config.toml")
}

// reloadHerdr 复刻 _hf_reload_herdr：只在以 herdr 插件身份运行时重载（手敲命令不碰真 server）。
func reloadHerdr() bool {
	if os.Getenv("HERDR_PLUGIN_ID") == "" || os.Getenv("HERDR_BIN_PATH") == "" {
		return false
	}
	argv := []string{os.Getenv("HERDR_BIN_PATH"), "server", "reload-config"}
	_, ok := runBoundedArgv(15, argv)
	return ok
}

// machinesReloadHint 复刻 _hf_machines_reload_hint：能自动重载就静默，否则给下一步。
func machinesReloadHint(target string) {
	label := target
	if label == "" {
		label = "该机器"
	}
	if reloadHerdr() {
		fmt.Printf("\n已自动重载 herdr 配置：tab bar 已切换（它由 herdr server 执行，查看 %s 时读的是那台机器上的状态）。\n", label)
	} else {
		fmt.Print("\n下一步：在 herdr 里执行 reload-config（或重启 herdr）使 tab bar 生效。\n")
		fmt.Printf("  tab bar command 由 herdr server 执行；跨机时它读的是 %s 上的插件与状态。\n", label)
	}
	fmt.Print("  回滚：forward machines deactivate all\n")
}

// probeFields 是 §2.1 KV 契约的解析结果（复刻 _hf_machines_probe_fields 的 PROBE_* 全局）。
type probeFields struct {
	Status string
	Root   string
	State  string
	Reason string
}

// parseProbeFields 复刻 _hf_machines_probe_fields（HF_STATE_DIR 优先，退回 HF_DEFAULT_STATE）。
func parseProbeFields(kv string) probeFields {
	f := probeFields{
		Status: sshprobe.KVGet(kv, "HF_STATUS"),
		Root:   sshprobe.KVGet(kv, "HF_ROOT"),
		State:  sshprobe.KVGet(kv, "HF_STATE_DIR"),
		Reason: sshprobe.KVGet(kv, "HF_REASON"),
	}
	if f.State == "" {
		f.State = sshprobe.KVGet(kv, "HF_DEFAULT_STATE")
	}
	return f
}

// probePlugin 跑一次远端插件可用性探测（只读、BatchMode）。
func probePlugin(target string) probeFields {
	return parseProbeFields(sshprobe.SSHProbePlugin(target, sshprobe.DefaultPluginID))
}

// remoteHer ddCmd 复刻 _hf_remote_herdr_cmd：远端命令里的 herdr 调用（补 ~/.local/bin）。
func remoteHerdrCmd(rest string) string {
	// shellcheck 的对位注释（bash 同源）：$HOME/$PATH 必须由**远端** shell 展开。
	return fmt.Sprintf("if command -v herdr >/dev/null 2>&1; then herdr %s; else PATH=\"$HOME/.local/bin:$PATH\" herdr %s; fi\n", rest, rest)
}

// remoteRun 复刻 _hf_remote_run：非交互 ssh（BatchMode，沿用用户 ssh 配置），返回 ssh 退出码。
func remoteRun(target string, secs int, remote string) int {
	dest := bridgeSSHDestination(target)
	argv := []string{"ssh", "-n", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10"}
	if cfg := os.Getenv("HERDR_FORWARD_SSH_CONFIG"); cfg != "" {
		argv = append([]string{"ssh", "-F", cfg, "-n", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10"}, dest, remote)
	} else {
		argv = append(argv, dest, remote)
	}
	_, ok := runBoundedArgvSecs(secs, argv)
	if ok {
		return 0
	}
	return 1
}

// remoteInstall 复刻 _hf_remote_install：在远端执行 herdr plugin install（仅在用户同意后调用）。
func remoteInstall(target string) int {
	src := os.Getenv("HERDR_FORWARD_INSTALL_SOURCE")
	if src == "" {
		src = "zzjcool/herdr-forward"
	}
	remote := remoteHerdrCmd("plugin install " + shellQuote(src) + " --yes")
	fmt.Printf("正在 %s 上安装插件（herdr plugin install %s --yes；首次需要 git clone，约半分钟）…\n", target, src)
	return remoteRun(target, 300, remote)
}

// remoteSetupUI 复刻 _hf_remote_setup_ui：让远端的键位立即可用（代跑 startup hook + reload）。
func remoteSetupUI(target, root, stateDir string) {
	qRoot := "HERDR_PLUGIN_ROOT=" + shellQuoteValue(root)
	qState := "HERDR_PLUGIN_STATE_DIR=" + shellQuoteValue(stateDir)
	qHook := shellQuote(root + "/scripts/startup-hook.sh")
	remote := fmt.Sprintf("env %s %s bash %s", shellQuote(qRoot), shellQuote(qState), qHook)
	out, ok := runBoundedArgvOut(60, []string{"ssh", "-n", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", bridgeSSHDestination(target), remote})
	if !ok {
		fmt.Printf("  ⚠ 远端键位配置未完成；可在 %s 上手动运行 %s/scripts/bootstrap.sh。\n", target, root)
		return
	}
	switch {
	case strings.Contains(out, "键位已就绪"):
		if remoteRun(target, 30, remoteHerdrCmd("server reload-config")) == 0 {
			fmt.Printf("  远端键位已装好并已重载：查看 %s 时按 prefix+f 打开 Port Forward 面板。\n", target)
		} else {
			fmt.Printf("  远端键位已写入；查看 %s 时按 prefix+q（reload config）后即可用 prefix+f。\n", target)
		}
	case strings.Contains(out, "已被其它命令占用"):
		fmt.Printf("  ⚠ 远端默认键位 prefix+f 已被占用，未覆盖；请在 %s 上运行 %s/scripts/bootstrap.sh --add-key prefix+<键>。\n", target, root)
	default:
		fmt.Printf("  远端键位已就绪：查看 %s 时按 prefix+f 打开 Port Forward 面板。\n", target)
	}
}

// bridgeStart 复刻 _hf_bridge_start：启动到该机器的桥接，并停掉指向其它机器的桥接（单 active）。
func bridgeStart(id, target string) {
	// 单 active 语义：先把别的机器的桥接停掉（与 bash 的 `others` 循环一致）。
	for _, other := range bridgeMachines() {
		if other != id {
			bridgeDown(other)
		}
	}
	out, ok := bridgeUp(id)
	if !ok {
		fmt.Printf("  ⚠ 桥接未能启动：%s\n", out)
		return
	}
	fmt.Printf("  %s 在 %s 上登记的端口映射会出现在本机 localhost（forward bridge status 查看）。\n", out, target)
}

// confirmYes 复刻 _hf_confirm：非交互恒 no（安全默认），TTY 下读单键。
func confirmYes(prompt string) bool {
	if !isTerminal(os.Stdin) {
		return false
	}
	fmt.Fprint(os.Stderr, prompt+" ")
	buf := make([]byte, 1)
	n, err := os.Stdin.Read(buf)
	fmt.Fprintln(os.Stderr)
	if err != nil || n == 0 {
		return false
	}
	c := strings.ToLower(strings.TrimSpace(string(buf[:n])))
	return c == "y" || c == "yes"
}
