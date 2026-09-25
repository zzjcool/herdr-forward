// machinesactivate.go —— `forward machines activate` / `deactivate`（← bin/forward 的
// cmd_machines_activate / cmd_machines_deactivate）。
//
// 用户可见文案是契约（tests/unit/test_machines_cmd.sh 逐条断言），因此这里的 printf
// 与 bash 逐字对齐，包括：
//
//   - present 时「探测命中」两行 + 记录 + tab bar/键位安装器 + reload 提示；
//   - present 但 HF_ROOT 为空 → die 4（**不写记录**，避免写入指向 A 的假路径）；
//   - absent → die 4 + 可复制的安装命令（「递命令不代装」原则，除非显式 --install）；
//   - no-herdr / unreachable → die 4 + 各自的排查清单；
//   - 安装器失败 → die 1（记录已写 = 半成品，用 deactivate 回滚）。
package cli

import (
	"fmt"
	"strings"

	"github.com/zzjcool/herdr-forward/internal/bridge"
	"github.com/zzjcool/herdr-forward/internal/hfcommon"
	"github.com/zzjcool/herdr-forward/internal/machine"
)

// cmdMachinesActivate 复刻 cmd_machines_activate。
func cmdMachinesActivate(args []string) int {
	arg := ""
	configOverride := ""
	install := "" // "" = 未表态（交互询问）/ "yes" / "no"

	for len(args) > 0 {
		a := args[0]
		switch {
		case a == "--install" || a == "--yes":
			install = "yes"
			args = args[1:]
		case a == "--no-install":
			install = "no"
			args = args[1:]
		case a == "--config":
			if len(args) < 2 {
				return die(exitUsage, "--config 需要一个路径值。")
			}
			configOverride = args[1]
			args = args[2:]
		case strings.HasPrefix(a, "--config="):
			configOverride = a[len("--config="):]
			args = args[1:]
		case strings.HasPrefix(a, "-"):
			return die(exitUsage, "未知参数："+a+"。用法：forward machines activate <id|label>")
		default:
			if arg != "" {
				return die(exitUsage, "activate 只接受一个 <id|label>（收到额外："+a+"）。")
			}
			arg = a
			args = args[1:]
		}
	}

	if arg == "" {
		return die(exitUsage, "缺少 <id|label>。用法：forward machines activate <id|label>（用 'forward machines list' 查看）")
	}
	if configOverride != "" {
		_ = setEnv("HERDR_CONFIG_PATH", configOverride)
	}

	id, code := resolveMachineIDOrDie(arg)
	if code != exitOK {
		return code
	}
	info, err := machine.Lookup(id)
	if err != nil {
		return die(exitNotFound, fmt.Sprintf("machine '%s' 不存在。请用 'forward machines list' 查看。", id))
	}

	isLocal := machine.IsLocalTarget(info.Target)

	// ① 同机短路：不走 ssh，直接写记录（本机路径已正确，tab bar 无需改）
	if isLocal {
		localState := hfcommon.StateDir()
		sock := getEnv("HERDR_SOCKET_PATH")
		fmt.Printf("machine %s（%s）与当前主机同机，直接标记激活（不发起 SSH 探测）。\n", id, info.Target)
		rec := map[string]any{
			"label":          info.Label,
			"ssh_target":     info.Target,
			"server_root":    pluginRootOfSelf(),
			"state_dir":      localState,
			"local":          true,
			"socket_path":    nullableString(sock),
			"activated_unix": hfcommon.NowUnix(),
		}
		if err := machine.SetActivation(id, rec); err != nil {
			return die(exitPartialActivation, "写入激活记录失败："+err.Error())
		}
		fmt.Printf("已激活（同机）：%s → 本机插件根 %s\n", id, pluginRootOfSelf())
		fmt.Print("tab bar 仍指向本机路径，无需改动；本机路径漂移时重跑本命令即刷新记录。\n")
		return exitOK
	}

	// ② 远端：先明示再探测（15s 级耗时必须让用户有预期）
	fmt.Printf("将只读 SSH 探测 %s（BatchMode，最多约 15 秒）以定位其插件根与 state 目录…\n", info.Target)
	probe := probePlugin(info.Target)

	// ③' absent + 用户同意 → 代装后重新探测
	if probe.Status == "absent" && install != "no" {
		if install == "" {
			fmt.Fprintf(stderr(), "SSH 连上了 %s，但该机器上还没有安装 herdr-forward 插件。\n", info.Target)
			if confirmYes(fmt.Sprintf("现在在 %s 上安装吗？（herdr plugin install zzjcool/herdr-forward）[y/N]", info.Target)) {
				install = "yes"
			} else {
				install = "no"
			}
		}
		if install == "yes" {
			if rc := remoteInstall(info.Target); rc != 0 {
				return die(exitMachineResolve, fmt.Sprintf("在 %s 上安装插件失败（rc=%d）。可手动执行：ssh %s 'herdr plugin install zzjcool/herdr-forward --yes'，装好后重跑 forward machines activate %s。", info.Target, rc, info.Target, arg))
			}
			fmt.Print("安装完成，重新探测…\n")
			probe = probePlugin(info.Target)
		}
	}

	switch probe.Status {
	case "present":
		fmt.Printf("探测命中：插件根 %s\n", orPlaceholder(probe.Root, "<未报告>"))
		fmt.Printf("            state 目录 %s\n", orPlaceholder(probe.State, "<未报告>"))
		if probe.Root == "" {
			return die(exitMachineResolve, fmt.Sprintf("探测到 %s 已装插件，但没读到它的插件根（HF_ROOT 为空）：远端 plugins.json / 目录结构异常。请在 %s 上执行 'herdr plugin list --json' 核对，或改用 scripts/setup-client.sh --server-host %s --server-root <B 的插件根>。", info.Target, info.Target, info.Target))
		}
	case "absent":
		fmt.Fprintf(stderr(), "SSH 连上了 %s，但该机器上**没有**安装 herdr-forward 插件。\n", info.Target)
		fmt.Fprintf(stderr(), "请在 %s 上执行（本命令不会替你装）：\n", info.Target)
		fmt.Fprintf(stderr(), "  ssh %s 'herdr plugin install zzjcool/herdr-forward --yes'\n", info.Target)
		fmt.Fprintf(stderr(), "装完后回到本机重跑：forward machines activate %s（或直接 forward machines activate %s --install 让本命令代装）\n", arg, arg)
		return die(exitMachineResolve, fmt.Sprintf("目标机器未安装 herdr-forward 插件（absent）：%s。已给出安装命令，装好后重试。", info.Target))
	case "no-herdr":
		fmt.Fprintf(stderr(), "SSH 连上了 %s，但远端非交互 shell 里找不到 herdr。\n", info.Target)
		fmt.Fprint(stderr(), "排查清单：\n")
		fmt.Fprintf(stderr(), "  1) ssh -o BatchMode=yes %s true        # 确认免密与主机名\n", info.Target)
		fmt.Fprintf(stderr(), "  2) ssh %s \"command -v herdr || ls ~/.local/bin/herdr\"   # 确认 herdr 位置\n", info.Target)
		fmt.Fprint(stderr(), "  3) 若 herdr 不在默认 PATH，请在 B 的 ~/.bashrc / profile 里补 PATH 后重试。\n")
		return die(exitMachineResolve, fmt.Sprintf("远端找不到 herdr 命令（no-herdr）：%s。%s", info.Target, reasonSuffix(probe.Reason)))
	default:
		fmt.Fprintf(stderr(), "SSH 探测失败，无法确认 %s 上的插件状态。\n", info.Target)
		fmt.Fprint(stderr(), "排查清单：\n")
		fmt.Fprintf(stderr(), "  1) ssh -o BatchMode=yes %s true        # 免密/主机名/端口\n", info.Target)
		fmt.Fprint(stderr(), "  2) 检查 ~/.ssh/config 里的该主机别名与 IdentityFile。\n")
		fmt.Fprint(stderr(), "  3) 内网机请确认已连上 VPN。\n")
		return die(exitMachineResolve, fmt.Sprintf("无法通过 SSH 到达 %s（unreachable）。%s", info.Target, reasonSuffix(probe.Reason)))
	}

	// ④ present：写记录 → 装 UI（幂等）→ reload 提示
	rec := map[string]any{
		"label":          info.Label,
		"ssh_target":     info.Target,
		"server_root":    probe.Root,
		"state_dir":      probe.State,
		"local":          false,
		"activated_unix": hfcommon.NowUnix(),
	}
	if err := machine.SetActivation(id, rec); err != nil {
		return die(exitPartialActivation, "写入激活记录失败："+err.Error())
	}

	tbRC := installTabbar(probe.Root, probe.State)
	keysRC := installKeys()

	if tbRC != 0 {
		// 冻结退出码表没有「安装器失败」这一档；记录已写、tab bar 未切 = 半成品状态，
		// 用 1（通用失败）显式失败，避免用户以为已生效。可用 deactivate 回滚。
		return die(exitPartialActivation, fmt.Sprintf("激活记录已写入，但 tab bar 安装器失败（rc=%d）。请手动运行 'bash %s/scripts/install-tabbar.sh --plugin-root %s --state-dir %s' 后重试；或用 'forward machines deactivate all' 回滚。", tbRC, pluginRootOfSelf(), probe.Root, probe.State))
	}
	if keysRC != 0 {
		hfcommon.Logf("warn", "键位安装器返回 %d（tab bar 已切换成功）。可手动运行：bash %s/scripts/install-keys.sh", keysRC, pluginRootOfSelf())
	}

	fmt.Printf("已激活：%s（%s）\n", id, info.Target)
	fmt.Printf("  tab bar 已指向该机器：%s\n", probe.Root)
	remoteSetupUI(info.Target, probe.Root, probe.State)
	bridgeStart(id, info.Target)
	fmt.Printf("  远程开发：在 %s 上按 prefix+f，选中监听端口即映射到本机 localhost（或在那边运行 forward add <端口>）。\n", info.Target)
	machinesReloadHint(info.Target)
	return exitOK
}

// cmdMachinesDeactivate 复刻 cmd_machines_deactivate。
func cmdMachinesDeactivate(args []string) int {
	arg := ""
	configOverride := ""
	for len(args) > 0 {
		a := args[0]
		switch {
		case a == "--config":
			if len(args) < 2 {
				return die(exitUsage, "--config 需要一个路径值。")
			}
			configOverride = args[1]
			args = args[2:]
		case strings.HasPrefix(a, "--config="):
			configOverride = a[len("--config="):]
			args = args[1:]
		case strings.HasPrefix(a, "-"):
			return die(exitUsage, "未知参数："+a+"。用法：forward machines deactivate <id|all>")
		default:
			if arg != "" {
				return die(exitUsage, "deactivate 只接受一个 <id|all>（收到额外："+a+"）。")
			}
			arg = a
			args = args[1:]
		}
	}
	if arg == "" {
		return die(exitUsage, "缺少 <id|all>。用法：forward machines deactivate <id|all>（用 'forward machines list' 查看）")
	}
	if configOverride != "" {
		_ = setEnv("HERDR_CONFIG_PATH", configOverride)
	}

	active := machine.ActiveID()

	if arg == "all" {
		// all：清 active + 删全部记录 → 回到初始态
		if err := machine.ResetActivation(); err != nil {
			return die(exitPartialActivation, "重置激活状态失败："+err.Error())
		}
		bridgeDownAll()
		fmt.Print("已停用全部 machine 并清空激活记录。\n")
	} else {
		id, code := resolveMachineIDOrDie(arg)
		if code != exitOK {
			return code
		}
		// 记录必须存在，否则用户打错 id 会静默「成功」
		if _, err := machine.GetActivation(id); err != nil {
			return die(exitNotFound, fmt.Sprintf("machine '%s' 没有激活记录。请用 'forward machines list' 查看，或先 'forward machines activate %s'。", id, id))
		}
		bridge.Down(id)

		if active != id {
			// 非当前 active：只想清掉这台的历史记录（tab bar 不动）
			if err := machine.RemoveActivation(id); err != nil {
				return die(exitPartialActivation, "删除激活记录失败："+err.Error())
			}
			fmt.Printf("已删除 %s 的激活记录（它本就不是当前 active）。\n", id)
			if active != "" {
				fmt.Printf("当前 active 仍是 %s，tab bar 保持指向它。\n", active)
				fmt.Printf("如需停用它：forward machines deactivate %s\n", active)
			}
			return exitOK
		}
		// 当前 active：只清 active，记录保留为 [·] 历史
		if err := machine.ClearActive(); err != nil {
			return die(exitPartialActivation, "清空 active 失败："+err.Error())
		}
		fmt.Printf("已停用 %s（记录保留，可用 forward machines activate %s 重新激活）。\n", id, arg)
	}

	// 恢复本机路径：不传 --plugin-root，install-tabbar 自动解析本脚本所在插件根
	if rc := installTabbar("", ""); rc != 0 {
		return die(exitPartialActivation, fmt.Sprintf("激活状态已清空，但 tab bar 恢复本机路径失败（rc=%d）。请手动运行 'bash %s/scripts/install-tabbar.sh' 恢复；tab bar 为空时不影响其他功能。", rc, pluginRootOfSelf()))
	}
	fmt.Printf("tab bar 已恢复为本机路径：%s\n", pluginRootOfSelf())
	machinesReloadHint("本机")
	return exitOK
}

// bridgeDownAll 复刻 `_hf_bridge_stop all`：停掉所有 client 记录的桥接。
func bridgeDownAll() {
	for _, mid := range bridge.Machines() {
		bridge.Down(mid)
	}
}

// --- 小工具 ---------------------------------------------------------------

// orPlaceholder 复刻 `${var:-<未报告>}`。
func orPlaceholder(v, fallback string) string {
	if v == "" {
		return fallback
	}
	return v
}

// reasonSuffix 复刻 `${PROBE_REASON:+原因：${PROBE_REASON}}`。
func reasonSuffix(reason string) string {
	if reason == "" {
		return ""
	}
	return "原因：" + reason
}

// nullableString 复刻 `(if $sock == "" then null else $sock end)`。
func nullableString(s string) any {
	if s == "" {
		return nil
	}
	return s
}
