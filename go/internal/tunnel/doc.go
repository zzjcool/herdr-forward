// Package tunnel —— exec ssh ControlMaster 生命周期（Start/Stop/Reap/Doctor，退出码 5 语义）
//
// Bash 对位：lib/tunnel.sh
// 迁移阶段：Phase 2
// 冻结接口与安全边界见 docs/PLAN-GO-MIGRATION.md §5（本 phase 不实现任何逻辑）。
package tunnel
