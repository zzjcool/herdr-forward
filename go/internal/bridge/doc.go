// Package bridge —— HF1 行协议编解码（契约 C6）+ serve/run 监督者与退避重连
//
// Bash 对位：lib/bridge.sh
// 迁移阶段：Phase 3（serve/run 同 phase 一起切）
// 冻结接口与安全边界见 docs/PLAN-GO-MIGRATION.md §5（本 phase 不实现任何逻辑）。
package bridge
