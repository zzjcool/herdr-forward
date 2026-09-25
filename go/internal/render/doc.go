// Package render —— 展示层纯函数：tab bar oneline（契约 C3）与 `forward list` 表格
//
// Bash 对位：
//   - Oneline ← lib/render.sh（render_oneline，逐行复刻）；
//   - Table   ← bin/forward 的 `_hf_list_table`（lib/render.sh 只有 oneline，
//     表格实现在 CLI 层，故以 CLI 为行为权威）。
//
// 迁移阶段：Phase 1（W2，已实现）。冻结接口见 docs/PLAN-GO-MIGRATION.md §5。
// 本包无副作用、无网络、无进程，输出恒为纯文本（无 ANSI）—— tab bar 由 herdr 经
// /bin/sh -lc 执行并取 stdout 最后一行，颜色不会被渲染（docs/SCOUT-FACTS.md §2.4）。
//
// 调用方：Phase 1 的 internal/cli 把 `forward list` / `list --oneline` 接到
// Oneline/Table；差分测试（tests/difftest）在 fixture 上比对 bash 与 Go 的逐字节输出。
package render
