// machinesdoctor.go —— `forward machines doctor`（← bin/forward 的 cmd_machines_doctor）。
//
// 契约（§2.3「doctor 契约」，tests/unit/test_machines_cmd.sh 逐条断言）：
//
//   - 没有 active → 报告「无需检查」，exit 0（不是错误）；
//   - 同机记录 → 不 ssh，只比对记录路径与当前检出（漂移则就地重写记录）；
//   - 远端 present + 路径一致 → 「无需修复」，config 字节不变；
//   - 远端 present + 路径漂移 → 重写记录 + 重写 tab bar（**唯一**的破坏性修复路径）；
//   - absent → 报告并 die 4，**记录与 config 保持原样**（远端卸载是可恢复的，不能自动删）；
//   - no-herdr / unreachable → 报告并 die 4，**不动任何文件**（stale 报告，不误删）。
//
// 最后一条是安全关键：网络抖动时自动「修复」= 把用户的激活配置删掉，
// 用户下次连上还要重新激活。
package cli

import (
	"fmt"
	"strings"

	"github.com/zzjcool/herdr-forward/internal/bridge"
	"github.com/zzjcool/herdr-forward/internal/hfcommon"
	"github.com/zzjcool/herdr-forward/internal/machine"
)

// cmdMachinesDoctor 复刻 cmd_machines_doctor。
func cmdMachinesDoctor(args []string) int {
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
			return die(exitUsage, "未知参数："+a+"。用法：forward machines doctor")
		default:
			return die(exitUsage, "doctor 不接受位置参数："+a+"。")
		}
	}
	if configOverride != "" {
		_ = setEnv("HERDR_CONFIG_PATH", configOverride)
	}

	active := machine.ActiveID()
	if active == "" {
		fmt.Print("没有处于激活状态的 machine（tab bar 指向本机路径），无需检查。\n")
		fmt.Print("  列出可用机器：forward machines list\n")
		return exitOK
	}

	rec, err := machine.GetActivation(active)
	if err != nil {
		return die(exitNotFound, fmt.Sprintf("machine '%s' 没有激活记录。请用 'forward machines list' 查看。", active))
	}
	label := rec.String("label")
	target := rec.String("ssh_target")
	savedRoot := rec.String("server_root")
	savedState := rec.String("state_dir")
	recLocal := rec.Bool("local")

	fmt.Printf("当前 active：%s（%s）\n", active, label)
	fmt.Printf("  ssh_target  : %s\n", target)
	fmt.Printf("  server_root : %s\n", orPlaceholder(savedRoot, "<未记录>"))
	fmt.Printf("  state_dir   : %s\n", orPlaceholder(savedState, "<未记录>"))

	// 同机记录：无需 ssh，只检查记录路径是否与本机一致（路径漂移 = 本机重装/移动检出）
	if recLocal {
		fmt.Print("  类型        : 同机（local）\n")
		if savedRoot != pluginRootOfSelf() {
			fmt.Printf("发现路径漂移：记录的插件根 %s 与当前检出 %s 不一致。\n", savedRoot, pluginRootOfSelf())
			updated := rec.Map()
			updated["server_root"] = pluginRootOfSelf()
			updated["state_dir"] = hfcommon.StateDir()
			if err := machine.SetActivation(active, updated); err != nil {
				return die(exitPartialActivation, "更新激活记录失败："+err.Error())
			}
			fmt.Print("已更新记录为当前检出（tab bar 本就指向本机，无需改动）。\n")
			return exitOK
		}
		fmt.Print("记录与当前检出一致，无需修复。\n")
		return exitOK
	}

	// 桥接：远端 active 机器应当有一条在跑的桥接；没跑就拉起来（supervisor 自带断线重连）
	if bridge.Running(active) {
		state := "?"
		for _, c := range bridge.Clients() {
			if bridgeStr(c, "machine") == active {
				state = bridgeStr(c, "state")
				if reason := bridgeStr(c, "reason"); reason != "" && state != "connected" {
					state += "（" + reason + "）"
				}
				break
			}
		}
		fmt.Printf("  bridge      : 运行中，%s\n", state)
	} else {
		fmt.Print("  bridge      : 未运行，正在启动…\n")
		bridgeStart(active, target)
	}

	// 远端记录：重探测（只读）。stale 路径 → 重写记录 + 重写 tab bar；连不上 → 只报告。
	fmt.Printf("\n正在重新探测 %s（只读，最多约 15 秒）…\n", target)
	probe := probePlugin(target)

	switch probe.Status {
	case "present":
		if probe.Root == "" {
			fmt.Print("记录 stale：探测到插件但没读到插件根，无法自动修复。\n")
			fmt.Printf("  下一步：ssh %s \"herdr plugin list --json\"\n", target)
			return die(exitMachineResolve, fmt.Sprintf("active machine %s 的插件根无法确认（HF_ROOT 为空）。记录保持原样，未改动 config。", active))
		}
		fmt.Printf("  重探测插件根: %s\n", probe.Root)
		fmt.Printf("  重探测 state: %s\n", orPlaceholder(probe.State, "<未报告>"))
		if probe.Root == savedRoot && probe.State == savedState {
			fmt.Print("记录与远端一致，无需修复。\n")
			return exitOK
		}
		fmt.Printf("发现 stale 路径（远端已漂移）：记录 %s / 实测 %s\n", savedRoot, probe.Root)
		updated := rec.Map()
		updated["server_root"] = probe.Root
		updated["state_dir"] = probe.State
		if err := machine.SetActivation(active, updated); err != nil {
			return die(exitPartialActivation, "更新激活记录失败："+err.Error())
		}
		fmt.Print("已更新激活记录。\n")
		if rc := installTabbar(probe.Root, probe.State); rc != 0 {
			return die(exitPartialActivation, fmt.Sprintf("记录已更新，但 tab bar 重写失败（rc=%d）。请手动运行 'bash %s/scripts/install-tabbar.sh --plugin-root %s --state-dir %s'。", rc, pluginRootOfSelf(), probe.Root, probe.State))
		}
		fmt.Print("tab bar 已按新路径重写。\n")
		machinesReloadHint(target)
	case "absent":
		fmt.Printf("远端 %s 上已找不到该插件（可能被卸载）。\n", target)
		fmt.Printf("  下一步：在 %s 上重装（ssh %s 'herdr plugin install zzjcool/herdr-forward --yes'）\n", target, target)
		fmt.Printf("  或停用：forward machines deactivate %s\n", active)
		return die(exitMachineResolve, fmt.Sprintf("active machine %s 的远端已卸载插件（absent）。记录与 config 保持原样，未改动。", active))
	default:
		// 关键：连不上时**不动** config 与记录（stale 报告，不误删）
		fmt.Printf("远端暂不可达/无法判定（%s）：%s\n", probe.Status, orPlaceholder(probe.Reason, "无更多信息"))
		fmt.Print("记录与 config 均保持原样（不做任何破坏性修复）。\n")
		fmt.Printf("  排查：ssh -o BatchMode=yes %s true\n", target)
		fmt.Print("  网络恢复后重跑：forward machines doctor\n")
		return die(exitMachineResolve, fmt.Sprintf("active machine %s 暂不可达（%s），已按 stale 报告（未改动任何文件）。", active, probe.Status))
	}
	return exitOK
}

// bridgeStr 读一个 client 文档的字符串字段。
func bridgeStr(o any, key string) string { return bridge.ObjStr(o, key) }
