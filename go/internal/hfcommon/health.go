// Package hfcommon — 基础设施原语（← lib/common.sh，Phase 1 由 W1 实现）。
//
// 本文件是 PLAN-GO-MIGRATION §5 冻结的共享类型桩：tunnel/render 等包依赖 Health
// 编译，W1 是本包（含本文件）的唯一 owner。
package hfcommon

// Health — 探活三级（C7 / A.3.1：本地可连 ≠ 远端可达）。
type Health int

const (
	HealthUp        Health = iota // 本地可连且远端有回包
	HealthDegraded               // 本地可连但无回包（隧道半开）
	HealthDown                   // 连接被拒/超时
)
