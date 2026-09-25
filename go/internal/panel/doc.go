// Package panel —— watch 交互面板（备用屏、双缓冲、read 超时刷新、非 TTY 退化）。
//
// Bash 对位：lib/panel.sh
// 迁移阶段：Phase 4
// 冻结接口与安全边界见 docs/PLAN-GO-MIGRATION.md §5（本 phase 不实现任何逻辑）。
package panel

// 依赖固定（Phase 0）：golang.org/x/term 是本包在 Phase 4 进入/退出 raw mode
// 的唯一终端库（见 PLAN §4 依赖纪律，禁 gopsutil/其他重依赖）。
// Phase 0 尚无实现代码引用它，但 `go mod vendor` 只收被 main module 引用的包，
// 因此用空导入把依赖钉进模块图，保证提交进仓库的 vendor/ 完整、容器离线可构建。
import _ "golang.org/x/term"
