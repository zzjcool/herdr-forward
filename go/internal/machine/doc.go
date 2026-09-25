// Package machine —— machines.toml 解析、ssh target 归一化、herdr machine list 视图。
//
// Bash 对位：lib/machine.sh + lib/machines.sh
// 迁移阶段：Phase 1 解析 / Phase 3 激活与视图
// 冻结接口与安全边界见 docs/PLAN-GO-MIGRATION.md §5（本 phase 不实现任何逻辑）。
package machine

// 依赖固定（Phase 0）：BurntSushi/toml 是本包在 Phase 1/3 解析 machines.toml 与
// 编辑 herdr config.toml 的唯一 TOML 库（见 PLAN §4 依赖纪律）。
// Phase 0 尚无实现代码引用它，但 `go mod vendor` 只收被 main module 引用的包，
// 因此用空导入把依赖钉进模块图，保证提交进仓库的 vendor/ 完整、容器离线可构建。
import _ "github.com/BurntSushi/toml"
