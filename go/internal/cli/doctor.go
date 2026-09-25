// doctor.go —— `forward doctor`（← bin/forward cmd_doctor + _hf_doctor_client）。
//
// 组成（与 bash 同序）：
//
//  1. tunnel.Doctor(...)：隧道记录的报告/修正/清理（诚实分级见 internal/tunnel/doctor.go）；
//  2. _hf_doctor_client 的等价部分：client 映射的监听在 attach 过来的 client 上，
//     本机既无进程也探不到端口，故只报告桥接回报的实时状态（waiting/pending/up/down）。
//
// flag 解析（A.3 + C2）：
//
//	--fix / --prune 可同时给（prune 优先，与 bash 一致）；未知 flag -> 64；
//	位置参数 -> 64。
//
// 恒 exit 0（即使有 down 记录）—— E2E run-inside.sh 用 set -e，不能因 down 中断。
package cli

import (
	"fmt"

	"github.com/zzjcool/herdr-forward/internal/jqjson"
	"github.com/zzjcool/herdr-forward/internal/state"
	"github.com/zzjcool/herdr-forward/internal/tunnel"
)

// cmdDoctor 复刻 cmd_doctor。
func cmdDoctor(args []string) int {
	doFix := false
	doPrune := false
	for _, arg := range args {
		switch {
		case arg == "--fix":
			doFix = true
		case arg == "--prune":
			doPrune = true
		case len(arg) > 0 && arg[0] == '-':
			return die(exitUsage, "未知参数："+arg+"。用法：forward doctor [--fix] [--prune]")
		default:
			return die(exitUsage, "doctor 不接受位置参数："+arg+"。")
		}
	}

	// prune 优先于 fix（bash：`if prune; elif fix`）。
	if doPrune {
		_ = tunnel.NewManager().Doctor(false, true)
	} else if doFix {
		_ = tunnel.NewManager().Doctor(true, false)
	} else {
		_ = tunnel.NewManager().Doctor(false, false)
	}
	printClientDoctorRows()
	return exitOK
}

// printClientDoctorRows 复刻 _hf_doctor_client 的输出形态：
//
//	<id>\t<local_port>\tclient:<status>\t<reason>
//
// reason 分支（逐字对齐 bash 的 jq）：
//
//	waiting                       -> (没有 client 连着；client 连上后自动生效)
//	pending                       -> (client 在线，等待其回报)
//	status_reason 非空            -> (<status_reason>)
//	其它                          -> (client <client|?> 回报)
func printClientDoctorRows() {
	v := loadView()
	if !v.mergeOK {
		// bash：bridge_merge_live 的 jq 报错 -> merged 为空 -> 无输出。
		return
	}
	for _, row := range v.rows {
		doc, ok := row.(*jqjson.Object)
		if !ok {
			continue
		}
		if jqjson.Str(jqGet(doc, "mode")) != string(state.ModeClient) {
			continue
		}
		id := jqjson.ToString(jqGet(doc, "id"))
		localPort := intOrZero(jqGet(doc, "local_port"))
		status := jqjson.ToString(jqGet(doc, "status"))
		reason := jqjson.ToString(jqGet(doc, "status_reason"))
		client := jqjson.ToString(jqGet(doc, "client"))

		var label string
		switch {
		case status == "waiting":
			label = "(没有 client 连着；client 连上后自动生效)"
		case status == "pending":
			label = "(client 在线，等待其回报)"
		case reason != "":
			label = "(" + reason + ")"
		default:
			if client == "" {
				client = "?"
			}
			label = "(client " + client + " 回报)"
		}
		fmt.Printf("%s\t%d\tclient:%s\t%s\n", id, localPort, status, label)
	}
}
