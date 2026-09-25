package difftest

import (
	"fmt"
	"os"
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
	fmt.Print(panel.RenderFrameFromState(fw, nil, nil, refresh))
	return exitOK
}
