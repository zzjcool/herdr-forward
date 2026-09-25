package cli

import "testing"

// Phase 0 空转不变量：任何 argv 都不得 panic，退出码恒 0（真实 dispatch 的退出码
// 契约 C2 由后续 phase 逐子命令接管）。
func TestMainScaffoldInvariants(t *testing.T) {
	cases := [][]string{
		nil,
		{"--version"},
		{"-v"},
		{"version"},
		{"help"},
		{"list", "--oneline"},
		{"no-such-subcommand"},
	}
	for _, args := range cases {
		if got := Main(args); got != 0 {
			t.Errorf("Main(%q) = %d, want 0（Phase 0 空转）", args, got)
		}
	}
}
