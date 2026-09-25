// Package sshprobe —— ssh target 解析与远端 plugin 探测 argv 拼装
//
// Bash 对位：lib/ssh-probe.sh
// 迁移阶段：Phase 1 parse_target / Phase 3 探测
// 冻结接口与安全边界见 docs/PLAN-GO-MIGRATION.md §5（本 phase 不实现任何逻辑）。
package sshprobe
