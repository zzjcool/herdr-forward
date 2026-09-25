// publish.go —— 二期占位子命令 `forward publish` / `forward unpublish`（契约 C9）。
//
// 一期行为**冻结**为 exit 9 + 精确文案（bash 的 cmd_publish / cmd_unpublish 完全忽略
// 参数，哪怕位置参数/未知 flag 也是 9 而不是 64 —— 保持同一形态）。
package cli

// cmdPublish 复刻 cmd_publish：恒 die 9（忽略全部参数）。
func cmdPublish(_ []string) int {
	return die(exitNotImplemented, "forward publish 为二期（Cloudflare quick tunnel）未实现。一期请用 'forward add' 建立 ssh -L 本地转发。")
}

// cmdUnpublish 复刻 cmd_unpublish：恒 die 9（忽略全部参数）。
func cmdUnpublish(_ []string) int {
	return die(exitNotImplemented, "forward unpublish 为二期未实现。")
}
