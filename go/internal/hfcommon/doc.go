// Package hfcommon —— env 解析、log（1MB 轮转保 512KB）、原子写、退出码常量、探活 marker（契约 C7）
//
// Bash 对位：lib/common.sh
// 迁移阶段：Phase 1（W1）
// 冻结接口与安全边界见 docs/PLAN-GO-MIGRATION.md §5（本 phase 不实现任何逻辑）。
package hfcommon
