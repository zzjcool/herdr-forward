// Package sshprobe —— ssh target 解析与远端 plugin 探测 argv 拼装。
//
// Bash 对位：lib/ssh-probe.sh（ssh_probe_parse_target / ssh_probe_run / ssh_probe_plugin / kv_get）。
// 冻结接口与安全边界见 docs/PLAN-GO-MIGRATION.md §5。
//
// Phase 1 范围（W3）：只做解析层 —— ParseTarget（+ 内部 scheme 剥除）。
// ssh_probe_run / ssh_probe_plugin（远端插件可用性探测）属 Phase 3；本 phase 不接线，
// 因此没有任何调用方，纯函数 + 单测。
package sshprobe

import (
	"errors"
	"fmt"
	"strconv"
	"strings"
)

// DefaultPort 是未显式给端口时的缺省端口（对照 `_SSH_PROBE_PORT=22`）。
const DefaultPort = 22

// Target 是 ParseTarget 的结果。
type Target struct {
	// Host 是给 ssh 的主机实参：**保留 `user@` 前缀**（与 bash 的
	// `_SSH_PROBE_HOST` 逐字一致 —— 切分用整串展开，故 user@ 不会丢），
	// 方括号 IPv6 也已在解析后剥掉方括号。
	Host string
	// Port 是最终端口（未显式给则为 DefaultPort）。
	Port int
	// HasPort 表示 target 显式带了端口：调用方据此决定是否给 ssh 传 `-p`
	// （裸 host 时不传，交给 ssh_config 的 Port/默认 22）。
	HasPort bool
}

// String 复刻 bash 的 stdout 契约 `"<host> <port>"`（如 `user@host 2222`）。
func (t Target) String() string {
	return fmt.Sprintf("%s %d", t.Host, t.Port)
}

// ParseTarget 解析 ssh target（对照 lib/ssh-probe.sh 的 ssh_probe_parse_target；
// 处理顺序与分支条件与 bash 版逐条一致）。
//
// 支持形态：
//
//	ssh://user@host:2222   -> 先剥 scheme（大小写不敏感），再按下面各条处理
//	host | user@host       -> host 原样 + 默认端口 22（HasPort=false）
//	user@host:2222         -> user@host 2222（user@ 保留在 Host 里，ssh 自己解析）
//	[v6]:22 / [::1]        -> 去掉方括号 + 端口；无端口则 22
//	含 ≥2 个 ':' 且无括号   -> 视作裸 IPv6 主机，端口 22
//	空 / 端口非数字 / 括号不配对或位置非法 / 缺主机名 -> 错误（对照 bash 的 die 64）
//
// 与 bash 版唯一的有意差异：端口统一校验 1-65535（bash 只查「是数字」）。
// `host:99999` / `host:0` 这种 ssh 必然失败的 target 归入用法错，与 bin/forward 的
// `_hf_require_port`（1-65535）和本 phase 的 NormalizeSshTarget 保持同一档。
func ParseTarget(raw string) (Target, error) {
	target := stripScheme(raw)
	if target == "" {
		return Target{}, errors.New("ssh target 为空（期望 user@host[:port]）")
	}

	var host, portStr string
	hasPort := false

	if strings.HasPrefix(target, "[") {
		// 方括号形态：必须是 [主机] 或 [主机]:端口，且不允许嵌套方括号。
		closeIdx := strings.Index(target, "]")
		if closeIdx < 0 {
			return Target{}, fmt.Errorf("ssh target 方括号未闭合: '%s'（期望 [ipv6]:port）", target)
		}
		host = target[1:closeIdx]
		rest := target[closeIdx+1:]
		if host == "" {
			return Target{}, fmt.Errorf("ssh target 缺少主机名: '%s'", target)
		}
		if strings.Contains(host, "[") {
			return Target{}, fmt.Errorf("ssh target 方括号嵌套: '%s'（期望 [ipv6]:port）", target)
		}
		if rest != "" {
			if !strings.HasPrefix(rest, ":") || rest == ":" {
				return Target{}, fmt.Errorf("ssh target 方括号后只能接 :端口: '%s'", target)
			}
			portStr = rest[1:]
			hasPort = true
		}
	} else if strings.Count(target, ":") >= 2 {
		// 多个 ':' 且无括号：裸 IPv6 字面量（无法从中可靠切出端口），整体当主机。
		host = target
	} else if strings.Contains(target, ":") {
		colon := strings.Index(target, ":")
		host = target[:colon]
		portStr = target[colon+1:]
		hasPort = true
	} else {
		host = target
	}

	if host == "" {
		return Target{}, fmt.Errorf("ssh target 缺少主机名: '%s'", target)
	}

	port := DefaultPort
	if hasPort {
		if !isAllDigits(portStr) {
			return Target{}, fmt.Errorf("ssh target 端口非法: '%s'（期望 user@host[:port]）", portStr)
		}
		n, err := strconv.Atoi(portStr)
		if err != nil || n < 1 || n > 65535 {
			return Target{}, fmt.Errorf("ssh target 端口越界（1-65535）: '%s'", portStr)
		}
		port = n
	}

	return Target{Host: host, Port: port, HasPort: hasPort}, nil
}

// stripScheme 剥掉 ssh:// 前缀（大小写不敏感；只剥前缀，不动 user/port/IPv6）。
//
// 为什么需要（bash 版的真实 bug 留痕）：herdr machine add 接受 `ssh://user@host:31415`
// 形态并原样存进 saved machines；带 scheme 的串交给 ssh 会 Could not resolve。
func stripScheme(target string) string {
	if len(target) >= 6 && strings.EqualFold(target[:6], "ssh://") {
		return target[6:]
	}
	return target
}

// isAllDigits 只认 ASCII 0-9（Atoi 会接受 "+22"/"-1"，这里不接受）。
func isAllDigits(s string) bool {
	if s == "" {
		return false
	}
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return true
}
