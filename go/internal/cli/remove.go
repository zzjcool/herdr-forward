// remove.go —— `forward remove`（← bin/forward cmd_remove）。
//
// 语义（A.3 + C2）：
//
//	remove <id>      先 forward_get 确认存在（不存在 -> 3，且**不动**隧道）；
//	                 mode=client 只删记录（client 侧监听由桥接 1 秒内撤掉）；
//	                 其余先 tunnel_stop（失败只 warn，继续删记录）再删记录。
//	remove --pick    一期未实现 -> 9（精确文案）
//	remove --all     一期未实现 -> 9（精确文案，防误删）
//	无参数            -> 64；未知 flag -> 64；多余位置参数 -> 64
package cli

import (
	"github.com/zzjcool/herdr-forward/internal/hfcommon"
	"github.com/zzjcool/herdr-forward/internal/state"
	"github.com/zzjcool/herdr-forward/internal/tunnel"
)

// cmdRemove 复刻 cmd_remove。
func cmdRemove(args []string) int {
	if len(args) == 0 {
		return die(exitUsage, "缺少 <id>。用法：forward remove f-3000（用 'forward list' 查看 id）。")
	}

	id := ""
	switch arg := args[0]; {
	case arg == "--pick":
		return die(exitNotImplemented, "forward remove --pick 交互选择为一期未实现（二期）。请用 'forward list' 查看 id 后执行 forward remove <id>。")
	case arg == "--all":
		return die(exitNotImplemented, "forward remove --all 为二期未实现（防误删）。请用 'forward list' 查看 id 后逐个 forward remove <id>。")
	case len(arg) > 0 && arg[0] == '-':
		return die(exitUsage, "未知参数："+arg+"。用法：forward remove <id>")
	default:
		id = arg
		args = args[1:]
	}
	if len(args) > 0 {
		return die(exitUsage, "remove 只接受一个 <id>（收到额外："+args[0]+"）。")
	}

	records, loadErr := state.Load()
	if loadErr != nil {
		return stateErrCode(loadErr, id, 0)
	}
	rec, ok := findForward(records, id)
	if !ok {
		return die(exitNotFound, "记录不存在："+id+"。请用 forward list 查看现有 id 后重试。")
	}

	// client 映射在本机没有进程：删记录即可（桥接会话 1 秒内把 client 侧监听撤掉）。
	if rec.Mode == state.ModeClient {
		if err := state.Remove(id); err != nil {
			return stateErrCode(err, id, rec.LocalPort)
		}
		return exitOK
	}

	// bash: tunnel_stop 的失败只 warn，**绝不**阻断删记录（历史行为：残留 ssh 由用户 ps 处理）。
	if err := tunnel.NewManager().Stop(id); err != nil {
		hfcommon.Logf("warn", "停隧道 %s 返回 %v，已继续删除状态记录。请用 'ps' 检查是否有残留 ssh 进程。", id, err)
	}
	if err := state.Remove(id); err != nil {
		return stateErrCode(err, id, rec.LocalPort)
	}
	return exitOK
}

// findForward 复刻 forward_get 的存在性检查（无 jq 依赖的等价实现）。
func findForward(records []state.Forward, id string) (state.Forward, bool) {
	for _, rec := range records {
		if rec.ID == id {
			return rec, true
		}
	}
	return state.Forward{}, false
}
