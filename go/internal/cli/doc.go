// doc.go — internal/cli 的包文档（Phase 1 W4 更新）。
//
// 本包是 bin/forward 的 Go 对位实现：子命令 dispatch、usage、参数校验与展示层。
// Phase 1（W4）已迁移：list / ports / help / version / internal（difftest 探针）。
// 其余 10 个子命令（add/remove/doctor/publish/unpublish/watch/bootstrap/machines/
// bridge/open-url）在 Main 的 dispatch 表里有显式条目，但一律走「未实现」哨兵
// （exit 9）—— 生产路径上不会到达，因为 bin/forward 只对 `list|ports` 做
// `exec bin/forward-go`。详见 cli.go 顶部说明与 docs/PLAN-GO-MIGRATION.md §5/§10。
//
// 冻结接口：func Main(args []string) int —— 返回值即进程退出码（契约 C2）。
package cli
