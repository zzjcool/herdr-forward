// Command difftest — 差分测试 harness 的开发驱动器（dev driver）。
//
// 它不是用户可见 CLI，也不参与 release（.goreleaser.yml 只构建 ./cmd/forward）。
// 存在理由：tests/difftest/run.sh 需要一个能跑 Go 侧探针的可执行文件，而
// go/cmd/ 与 go/internal/cli/ 是 W4 的 writer 范围（PLAN-GO-MIGRATION §10 的写冲突
// 规则）。把驱动器放在 go/internal/difftest/ 目录内部，就完全落在 W1 的唯一 writer
// 范围内，且不碰 W4 的任何文件。
//
// harness 的接线策略（tests/difftest/run.sh）：
//  1. 若 bin/forward-go 已支持 `internal difftest selftest`（W4 接线后），优先用它；
//  2. 否则回退到本驱动器：go build -o <tmp> ./internal/difftest/cmd
//
// 两条路径跑的是同一个 difftest.Main，结果等价。
package main

import (
	"os"

	"github.com/zzjcool/herdr-forward/internal/difftest"
)

func main() { os.Exit(difftest.Main(os.Args[1:])) }
