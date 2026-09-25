// protocol.go —— HF1 行协议的编解码与 C6 安全边界（← lib/bridge.sh 的协议半边）。
//
// 行协议（一行一条，空格分隔，首词恒为 HF1；ARCHITECTURE §A.3.3）：
//
//	B → A  HF1 HELLO <server-host>
//	       HF1 SYNC <id:lp:rp,...|->      期望集合全量（启动时 + 每次变化时）
//	       HF1 OPEN <url>                 请 A 打开浏览器
//	A → B  HF1 HELLO <client-host> <client-label...>
//	       HF1 STATUS <id> up|down [reason...]
//	       HF1 PING                       心跳
//
// **A 侧强制的安全边界**（B 越不过，C6 全量）：
//
//	id 必须 `f-<lp>`；lp ∈ [1024, 65535]、rp ∈ [1, 65535]，无前导零；至多 32 条；
//	绑定恒为 A 的 loopback，目标恒为 B 的 localhost；OPEN 只接受已生效映射端口的
//	`http(s)://localhost|127.0.0.1` URL。
//
// 因此 B 既不能让 A 连向 A 侧网络，也不能把 A 的端口暴露到 A 的局域网。
package bridge

import (
	"fmt"
	"os"
	"strconv"
	"strings"

	"github.com/zzjcool/herdr-forward/internal/hfcommon"
)

// Proto 是协议魔数前缀（BRIDGE_PROTO）。
const Proto = "HF1"

// SyncEntry 是一个期望映射（`<id>:<lp>:<rp>`）。
type SyncEntry struct {
	ID         string
	LocalPort  int
	RemotePort int
}

// Msg 是所有协议行的共同接口（String() 产出**不含换行**的一整行）。
type Msg interface{ String() string }

// Hello 是双向的 HELLO 行。
//
//	B → A: Hello{Host: <server-host>}
//	A → B: Hello{Host: <client-host>, Labels: <client-label 的空白分词>}
type Hello struct {
	Host   string
	Labels []string
}

// String 复刻 bash 的两处 printf：
//
//	B → A  `printf '%s HELLO %s\n' "${BRIDGE_PROTO}" "${srv_host}"`
//	A → B  `_bridge_send "${BRIDGE_PROTO} HELLO ${cl_host} ${cl_label}"`
func (h Hello) String() string {
	s := Proto + " HELLO " + h.Host
	if len(h.Labels) > 0 {
		s += " " + strings.Join(h.Labels, " ")
	}
	return s
}

// Sync 是期望集合的全量声明（B → A）。
type Sync struct {
	Forwards []SyncEntry
}

// String 复刻 bridge_fmt_sync：`HF1 SYNC <id:lp:rp,...|->`。
func (s Sync) String() string {
	parts := make([]string, 0, len(s.Forwards))
	for _, e := range s.Forwards {
		parts = append(parts, fmt.Sprintf("%s:%d:%d", e.ID, e.LocalPort, e.RemotePort))
	}
	body := strings.Join(parts, ",")
	if body == "" {
		body = "-"
	}
	return Proto + " SYNC " + body
}

// Open 是「请在 A 上打开这个 URL」（B → A）。
type Open struct {
	URL string
}

// String 复刻 `printf '%s OPEN %s\n' "${BRIDGE_PROTO}" "${url}"`。
func (o Open) String() string { return Proto + " OPEN " + o.URL }

// Status 是单条映射的回报（A → B）。
type Status struct {
	ID     string
	State  string // up | down
	Reason string
}

// String 复刻 `_bridge_send "${BRIDGE_PROTO} STATUS f-${k} down ${cl_reason[k]}"` /
// `"… STATUS f-${k} up"` —— Reason 为空时不留尾随空格。
func (s Status) String() string {
	line := Proto + " STATUS " + s.ID + " " + s.State
	if s.Reason != "" {
		line += " " + s.Reason
	}
	return line
}

// Ping 是心跳（A → B）。
type Ping struct{}

// String 复刻 `_bridge_send "${BRIDGE_PROTO} PING"`。
func (Ping) String() string { return Proto + " PING" }

// ParseLine 解析一整行协议（不含换行）。
//
// 解析失败返回 error —— 调用方**只记 warn 并继续**（bash 对未知协议行的行为），
// 绝不因 B 发来坏数据中断桥接。
//
// 与 bash 的分词对齐：`IFS=' ' read -r -a words` 只按**空格**切分（不含 tab），
// 且折叠连续空格、忽略首尾（见 spaceFields）。
func ParseLine(line string) (Msg, error) {
	words := spaceFields(line)
	if len(words) == 0 || words[0] != Proto {
		return nil, fmt.Errorf("bridge: 非 %s 协议行: %q", Proto, line)
	}
	verb := ""
	if len(words) > 1 {
		verb = words[1]
	}
	switch verb {
	case "HELLO":
		host := ""
		if len(words) > 2 {
			host = words[2]
		}
		var labels []string
		if len(words) > 3 {
			labels = append(labels, words[3:]...)
		}
		return Hello{Host: host, Labels: labels}, nil
	case "SYNC":
		payload := ""
		if len(words) > 2 {
			payload = afterVerb(line, "SYNC")
		}
		entries, err := ParseSync(payload)
		if err != nil {
			return nil, err
		}
		return Sync{Forwards: entries}, nil
	case "OPEN":
		url := ""
		if len(words) > 2 {
			url = afterVerb(line, "OPEN")
		}
		return Open{URL: url}, nil
	case "STATUS":
		// 宽容解析（与 bash 的 serve 分派同构）：bash 先 `IFS=' ' read -a words` 拿到
		// words[2]/words[3]，**再**用 `^f-([1-9][0-9]{0,4})$` + `up|down` 校验；因此
		// 字段不全的行仍然被识别为 STATUS（只是随后校验失败、什么都不写），并且**会刷新
		// last_seen**（bash 在 STATUS 分支里无条件 `srv_last_seen=${now}`）。
		//
		// 早先这里返回 error 会让 handleLine 走「未知协议行」分支 —— 后果是畸形 STATUS
		// 不再算心跳，与 bash 分叉。故解析与校验必须分开（校验在 Serve.handleLine 里）。
		id := ""
		if len(words) > 2 {
			id = words[2]
		}
		state := ""
		if len(words) > 3 {
			state = words[3]
		}
		return Status{ID: id, State: state, Reason: stripReasonPrefix(line, id, state)}, nil
	case "PING":
		return Ping{}, nil
	default:
		return nil, fmt.Errorf("bridge: 未知协议动作 %q: %q", verb, line)
	}
}

// afterVerb 取 `before <VERB> ` 之后的**原文**（保留余下内容里的多空格），
// 复刻 bash 的 `line#*HELLO ` / `line#"${proto} SYNC "` 语义（最短前缀匹配）。
func afterVerb(line, verb string) string {
	needle := Proto + " " + verb + " "
	idx := strings.Index(line, needle)
	if idx < 0 {
		return ""
	}
	return line[idx+len(needle):]
}

// stripReasonPrefix 复刻 bash 的 reason 提取：
//
//	rest="${line#*STATUS "${fid}" "${st}"}"; rest="${rest# }"
//
// 注意两点（都与“用 Fields 重写”不等价）：
//   - `${var#*pattern}` 取**最短前缀**，即 pattern 的**首次出现**；pattern 不在时原样返回；
//   - 末尾只吃掉**一个**空格（`${rest# }`），不是全部空白。
func stripReasonPrefix(line, id, state string) string {
	pattern := Proto + " STATUS " + id + " " + state
	rest := line
	if idx := strings.Index(line, pattern); idx >= 0 {
		rest = line[idx+len(pattern):]
	}
	if strings.HasPrefix(rest, " ") {
		rest = rest[1:]
	}
	return rest
}

// spaceFields 复刻 `IFS=' ' read -r -a`：只按空格切分，折叠连续空格并忽略首尾。
// （strings.Fields 会把 tab/换行也当分隔符 —— 在畸形输入上会与 bash 分叉。）
func spaceFields(line string) []string {
	out := []string{}
	i := 0
	for i < len(line) {
		for i < len(line) && line[i] == ' ' {
			i++
		}
		if i >= len(line) {
			break
		}
		start := i
		for i < len(line) && line[i] != ' ' {
			i++
		}
		out = append(out, line[start:i])
	}
	return out
}

// --- C6 安全边界 -----------------------------------------------------------

// MinLocalPort 是 A 侧允许的最小本地端口（BRIDGE_MIN_LOCAL_PORT）。
const MinLocalPort = 1024

// MaxForwards 是单次 SYNC 允许的最大映射条数（BRIDGE_MAX_FORWARDS）。
const MaxForwards = 32

// MaxLocalPort / MaxRemotePort 是端口上界。
const (
	MaxLocalPort  = 65535
	MaxRemotePort = 65535
)

// ValidateForward 复刻 bridge_valid_entry：C6 的全部安全边界。
//
// 注意：bash 的 bridge_valid_entry 接受的是**字符串**三元组（它在正则里挡住前导零），
// 而冻结接口给的是已解析的 SyncEntry —— 前导零在 ParseSync 里就已经被拒（见
// validEntryLiterals）。因此本函数的「无前导零」只对 ValidateForwardIface 那条字符串
// 入口有意义。
//
// 返回值是 nil（合法）或错误（非法，文案对齐 bash 的 warn 与调用方的 die 4）。
func ValidateForward(e SyncEntry) error {
	if e.LocalPort < MinLocalPort || e.LocalPort > MaxLocalPort {
		return fmt.Errorf("本地端口 %d 越界（要求 %d-%d）", e.LocalPort, minLocalPort(), MaxLocalPort)
	}
	if e.RemotePort < 1 || e.RemotePort > MaxRemotePort {
		return fmt.Errorf("远端端口 %d 越界（要求 1-%d）", e.RemotePort, MaxRemotePort)
	}
	if e.ID != fmt.Sprintf("f-%d", e.LocalPort) {
		return fmt.Errorf("id %q 与本地端口 %d 不一致（要求 f-%d）", e.ID, e.LocalPort, e.LocalPort)
	}
	if e.LocalPort < minLocalPort() {
		return fmt.Errorf("本地端口 %d 越界（要求 %d-%d）", e.LocalPort, minLocalPort(), MaxLocalPort)
	}
	return nil
}

// ValidateForwardLiterals 是 ValidateForward 的**字符串**形态：与 bash 的
// bridge_valid_entry 逐条对齐（含前导零与位宽判定）。
func ValidateForwardLiterals(id, lp, rp string) bool {
	return validEntryLiterals(id, lp, rp)
}

// validPortLiteral 复刻 bash 的 `^[1-9][0-9]{0,4}$`（无前导零、至多 5 位、非空），
// 并要求数值 ≤ 65535（minLocal 额外要求 ≥ minLocalPort()）。
func validPortLiteral(lit string, minLocal bool) bool {
	if lit == "" || len(lit) > 5 {
		return false
	}
	if lit[0] < '1' || lit[0] > '9' {
		return false
	}
	for i := 1; i < len(lit); i++ {
		if lit[i] < '0' || lit[i] > '9' {
			return false
		}
	}
	n, err := strconv.Atoi(lit)
	if err != nil || n > MaxLocalPort {
		return false
	}
	if minLocal && n < minLocalPort() {
		return false
	}
	return true
}

// ParseSync 复刻 bridge_parse_sync：解析 SYNC 负载为**已校验**的条目列表。
//
// 非法条目丢弃并 warn（绝不因 B 发来的坏数据中断桥接）；超过上限的部分截断。
// 输入 "-" 或空串 → 空集合。
func ParseSync(payload string) ([]SyncEntry, error) {
	out := []SyncEntry{}
	if payload == "" || payload == "-" {
		return out, nil
	}
	for _, item := range strings.Split(payload, ",") {
		if item == "" {
			continue
		}
		parts := strings.Split(item, ":")
		if len(parts) != 3 {
			hfcommon.Logf("warn", "bridge: 忽略非法映射请求 '%s'（要求 f-<lp>:<lp>:<rp>，本地端口 %d-65535）。", item, minLocalPort())
			continue
		}
		lp, errL := strconv.Atoi(parts[1])
		rp, errR := strconv.Atoi(parts[2])
		if errL != nil || errR != nil {
			hfcommon.Logf("warn", "bridge: 忽略非法映射请求 '%s'（要求 f-<lp>:<lp>:<rp>，本地端口 %d-65535）。", item, minLocalPort())
			continue
		}
		entry := SyncEntry{ID: parts[0], LocalPort: lp, RemotePort: rp}
		// bash 是按**字符串**做正则校验的（前导零必须被拒）；这里用同样的字面量判定，
		// 避免 strconv 把 "08080" 归一成 8080 后误放行。
		if !validEntryLiterals(parts[0], parts[1], parts[2]) {
			hfcommon.Logf("warn", "bridge: 忽略非法映射请求 '%s'（要求 f-<lp>:<lp>:<rp>，本地端口 %d-65535）。", item, minLocalPort())
			continue
		}
		if len(out) >= maxForwards() {
			hfcommon.Logf("warn", "bridge: 映射请求超过上限 %d 条，其余已忽略。", maxForwards())
			break
		}
		out = append(out, entry)
	}
	return out, nil
}

// validEntryLiterals 复刻 bridge_valid_entry 的**字面量**判定（保前导零语义）。
func validEntryLiterals(id, lp, rp string) bool {
	if !validPortLiteral(lp, true) || !validPortLiteral(rp, false) {
		return false
	}
	n, err := strconv.Atoi(lp)
	if err != nil || n < MinLocalPort || n > MaxLocalPort {
		return false
	}
	// bash：`[[ ${fid} == "f-${lp}" ]]` —— lp 是**原字符串**（前导零在这里被挡下）
	return id == "f-"+lp
}

// maxForwards 读 BRIDGE_MAX_FORWARDS（缺省 32）。
func maxForwards() int { return envInt("BRIDGE_MAX_FORWARDS", MaxForwards) }

// minLocalPort 读 BRIDGE_MIN_LOCAL_PORT（缺省 1024）。
func minLocalPort() int { return envInt("BRIDGE_MIN_LOCAL_PORT", MinLocalPort) }

// envInt 读一个正整数环境变量（缺失/非法/≤0 → 缺省值）。
func envInt(name string, def int) int {
	raw := strings.TrimSpace(os.Getenv(name))
	if raw == "" {
		return def
	}
	n, err := strconv.Atoi(raw)
	if err != nil || n <= 0 {
		return def
	}
	return n
}
