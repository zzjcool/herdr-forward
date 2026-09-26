package difftest

import (
	"fmt"
	"os"

	"encoding/json"
	"strconv"
	"time"

	"github.com/zzjcool/herdr-forward/internal/panel"
	"github.com/zzjcool/herdr-forward/internal/state"
)

// cmdPhase4 exposes only pure panel/installer-adjacent probes.  It is kept
// under internal difftest so no user-facing command grows a test-only flag.
func cmdPhase4(args []string) int {
	if len(args) == 0 {
		fmt.Fprintln(os.Stderr, "difftest phase4: 用法 panel-frame|watch-fallback")
		return exitUsage
	}
	switch args[0] {
	case "panel-frame":
		return phase4PanelFrame(args[1:])
	case "watch-fallback":
		fmt.Println("watch -n 3 forward list")
		return exitOK
	default:
		fmt.Fprintln(os.Stderr, "difftest phase4: 未知子命令 "+args[0])
		return exitUsage
	}
}

func phase4PanelFrame(args []string) int {
	refresh := 3 * time.Second
	if len(args) > 0 {
		n, err := strconv.Atoi(args[0])
		if err != nil || n < 1 {
			return exitUsage
		}
		refresh = time.Duration(n) * time.Second
	}
	fw, _ := state.Load()
	// 可选第二参数：machines JSON 文件路径，用于固化 MACHINES 段渲染（列宽回归的
	// 差分护栏；无则等价于旧行为——machines 段不出现）。
	var machines []panel.MachineRow
	if len(args) > 1 {
		mf, err := os.ReadFile(args[1])
		if err != nil {
			fmt.Fprintf(os.Stderr, "difftest panel-frame: 读 machines fixture 失败：%v\n", err)
			return exitUsage
		}
		if err := json.Unmarshal(mf, &machines); err != nil {
			fmt.Fprintf(os.Stderr, "difftest panel-frame: machines fixture 非法 JSON：%v\n", err)
			return exitUsage
		}
	}
	fmt.Print(panel.RenderFrameFromState(fw, machines, nil, refresh))
	return exitOK
}
