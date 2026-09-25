// Package cli 是 bin/forward 的 cmd_* 层：子命令 dispatch、usage、参数校验。
//
// Bash 对位：bin/forward 的 dispatch 与各 cmd_* 函数。
// 迁移阶段：Phase 0 只落地入口骨架（--version 空转）；Phase 1 起切 list/ports；
// Phase 2 起切 add/remove/doctor/publish/unpublish；Phase 3 切 machines/bridge 等。
// 冻结接口：func Main(args []string) int —— 返回值即进程退出码（契约 C2）。
// 详见 docs/PLAN-GO-MIGRATION.md §5。
package cli
