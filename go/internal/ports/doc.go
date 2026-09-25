// Package ports —— 本机 TCP 监听端口枚举（面板 LISTENING 段 / `forward ports` 的数据源）
//
// Bash 对位：lib/ports.sh（过滤语义与地址还原的行为权威）。
// 迁移阶段：Phase 1（W2，已实现）。冻结接口见 docs/PLAN-GO-MIGRATION.md §5：
// `type Listener struct{ Port int; Addr, Process string }`、`func List() ([]Listener, error)`。
//
// 数据源按平台分派（不引入 gopsutil，见 PLAN §4 依赖纪律）：
//   - Linux：纯 Go 读 /proc/net/tcp{,6}（hex 端口、state 0A=LISTEN、little-endian 地址还原）；
//     拿不到进程名，Process 恒为空串（与 bash 的 /proc 分支同形）；
//   - 其他平台（macOS）：exec `lsof -nP -iTCP -sTCP:LISTEN`（CI 不覆盖，靠 PLAN §11 手动 smoke）。
package ports
