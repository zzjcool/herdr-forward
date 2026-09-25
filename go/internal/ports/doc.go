// Package ports —— 本地监听端口枚举：Linux /proc/net/tcp{,6}，macOS exec lsof（禁 gopsutil）
//
// Bash 对位：lib/ports.sh
// 迁移阶段：Phase 1（W2）
// 冻结接口与安全边界见 docs/PLAN-GO-MIGRATION.md §5（本 phase 不实现任何逻辑）。
package ports
