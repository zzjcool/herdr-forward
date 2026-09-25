// doctor.go —— `forward doctor` 的隧道半边（← lib/tunnel.sh 的 tunnel_doctor）。
//
// 诚实分级（ARCHITECTURE A.3.1，review D1 的契约修正）：
//
//	up       = master 活着 **且** 经隧道发 payload 收到应用层回包
//	degraded = master 活着、远端端口**可连**但无应用层回包（status 字段只允许
//	           up|down，故 --fix 保守置 down，且**永不 prune**：master 可能还在，
//	           删记录会误伤活隧道）
//	down     = master 不活，或经隧道连不上远端
//
// --fix 只改 state 字段，绝不碰活隧道；--prune 只在「master 不活」时 reap + 删记录；
// mode=client 的记录跳过（监听在 attach 过来的 client 上，本机既无进程也探不到端口，
// 混进来会被判 down，--prune 还会误删用户登记的映射）。
//
// 与 bash 的已知形态差异（报告已登记）：
//   - status 字段缺失时 bash 的 `jq -r .status` 打印字面 "null"，Go 用 ""（只有手改
//     过的畸形记录才可能触及）；
//   - bash 通过 `require_cmd jq` 强依赖 jq（缺失 -> die 127）；Go 不需要 jq。
package tunnel

import (
	"fmt"

	"github.com/zzjcool/herdr-forward/internal/hfcommon"
	"github.com/zzjcool/herdr-forward/internal/state"
)

// Doctor 复刻 tunnel_doctor：默认只报告；fix 修正 status；prune 清理死记录。
//
// 输出逐行打到 stdout（cli 的 cmd_doctor 紧接着打印 client 映射那几行，与 bash 的
// `tunnel_doctor …; _hf_doctor_client` 顺序一致）。恒返回 nil（bash 恒 return 0 ——
// 诊断成功即 exit 0，即使有 down 记录；E2E 用 set -e，不能因 down 中断）。
func (m *Manager) Doctor(fix, prune bool) error {
	records, _ := state.Load()
	for _, rec := range records {
		if rec.Mode == state.ModeClient {
			continue
		}
		pid := 0
		if rec.Pid != nil {
			pid = *rec.Pid
		}
		alive := Alive(pid)
		probe := m.Probe(rec.LocalPort)

		// 诚实分级：master 不活一律 down（哪怕本地端口恰好被别的进程占着）。
		effective := probe
		if !alive {
			effective = hfcommon.HealthDown
		}

		switch effective {
		case hfcommon.HealthUp:
			if fix && rec.Status != "up" {
				m.setStatus(rec.ID, "up")
				fmt.Printf("%s: fixed -> up\n", rec.ID)
			} else {
				fmt.Printf("%s: up\n", rec.ID)
			}
		case hfcommon.HealthDegraded:
			if fix && rec.Status != "down" {
				m.setStatus(rec.ID, "down")
				fmt.Printf("%s: degraded (no application-layer reply) -> fixed -> down\n", rec.ID)
			} else {
				fmt.Printf("%s: degraded (no application-layer reply; status=%s)\n", rec.ID, rec.Status)
			}
		default:
			switch {
			case prune && !alive:
				_ = m.Reap(rec.ID, pid)
				if err := state.Remove(rec.ID); err != nil {
					hfcommon.Logf("warn", "doctor --prune: 删除记录 %s 失败：%v", rec.ID, err)
				}
				fmt.Printf("%s: pruned\n", rec.ID)
			case fix:
				m.setStatus(rec.ID, "down")
				fmt.Printf("%s: fixed -> down\n", rec.ID)
			default:
				fmt.Printf("%s: down\n", rec.ID)
			}
		}
	}
	return nil
}

// setStatus 包一层 state.SetStatus 的失败日志（bash 的 forward_set_status 失败会 die 1；
// doctor 路径上这属于内部错误，Go 记一条 warn 后继续处理其余记录 —— 与「doctor 恒 0」
// 的契约一致）。
func (m *Manager) setStatus(id, status string) {
	if err := state.SetStatus(id, status); err != nil {
		hfcommon.Logf("warn", "doctor: 设置 %s 的 status=%s 失败：%v", id, status, err)
	}
}
