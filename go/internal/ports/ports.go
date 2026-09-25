// ports.go — 本机 TCP 监听端口发现（面板 LISTENING 段 / `forward ports` 的数据源）
//
// 行为权威：lib/ports.sh（逐行复刻其过滤语义与地址还原）。冻结接口见
// docs/PLAN-GO-MIGRATION.md §5：`type Listener struct{ Port int; Addr, Process string }`、
// `func List() ([]Listener, error)`。
//
// 只列经 localhost 可达的监听（loopback / 通配）：桥接的目标恒为对端 localhost，
// 绑在具体网卡地址上的服务用 localhost 连不到，列出来只会误导；端口 < 1024 不列
// （sshd 等系统服务）。
//
// 数据源（PLAN-GO-MIGRATION §4 依赖映射）：
//   - Linux：纯 Go 读 /proc/net/tcp{,6}（hex 端口、state 0A=LISTEN、little-endian 地址还原）
//     —— 不 exec ss，也不依赖 gopsutil；代价是拿不到进程名（Process 恒为空，与 bash 的
//     /proc 分支同形）；
//   - 其他平台（macOS）：exec `lsof -nP -iTCP -sTCP:LISTEN`（跑得起即可，macOS 无 CI）。
package ports

import (
	"os"
	"os/exec"
	"runtime"
	"sort"
	"strconv"
	"strings"
)

// Listener 是一条监听记录（← ports_listening_json 的元素形状）。
//
//   - Port：监听端口（1024..65535，已过滤）；
//   - Addr：经 localhost 可达的地址，已剥掉 [] 方括号与 %iface zone 后缀；
//   - Process：进程名；Linux /proc 数据源拿不到，为空串（CLI 显示为 "-"）。
type Listener struct {
	Port    int
	Addr    string
	Process string
}

// 端口下限/上限（← lib/ports.sh _ports_emit：`((port >= 1024 && port <= 65535))`）。
const (
	minPort = 1024
	maxPort = 65535
)

// lsofArgs 是 macOS 分支的冻结 argv（← lib/ports.sh `lsof -nP -iTCP -sTCP:LISTEN`）。
var lsofArgs = []string{"-nP", "-iTCP", "-sTCP:LISTEN"}

// List 枚举本机监听端口：按端口升序、同端口去重（优先保留带进程名的一条，
// 与 bash 末尾 jq 的 `group_by(.port) | map((map(select(.process != "")) | first) // first)
// | sort_by(.port)` 同语义）。
//
// 数据源不可用时返回错误（bash 在无任何数据源时降级为 `[]`；Go 侧把「读不到 /proc」
// 或「lsof 缺失」这种环境问题显式报出，由 CLI 决定是否降级为 warn + 空列表）。
// 成功时恒返回非 nil 切片（无监听 -> 空切片）。
func List() ([]Listener, error) {
	if runtime.GOOS == "linux" {
		return listProc()
	}
	return listLsof()
}

// listProc 是 Linux 路径：/proc/net/tcp（必需）+ /proc/net/tcp6（可选）。
func listProc() ([]Listener, error) {
	raw4, err := os.ReadFile("/proc/net/tcp")
	if err != nil {
		return nil, err
	}
	// tcp6 不存在/不可读 -> 只解析 tcp4（← bash `if [[ -r /proc/net/tcp6 ]]`）
	raw6, err := os.ReadFile("/proc/net/tcp6")
	if err != nil {
		raw6 = nil
	}
	return dedupe(ParseProc(string(raw4), string(raw6))), nil
}

// listLsof 是 macOS 路径：exec `lsof -nP -iTCP -sTCP:LISTEN` 并解析其输出。
//
// 退出码非 0（lsof 在「没有匹配」时也会 exit 1）不算失败，只要拿到了 stdout 就照常解析
// —— 与 bash 的 `lsof ... 2>/dev/null || true` 一致；二进制不存在才返回错误。
func listLsof() ([]Listener, error) {
	path, err := exec.LookPath("lsof")
	if err != nil {
		return nil, err
	}
	out, err := exec.Command(path, lsofArgs...).Output()
	if err != nil {
		if _, ok := err.(*exec.ExitError); !ok {
			return nil, err
		}
	}
	return dedupe(ParseLsof(string(out))), nil
}

// ParseProc 解析 /proc/net/tcp 与 /proc/net/tcp6 的内容（← ports_parse_proc）。
//
// 逐行复刻 bash 的取列与判定：
//   - `IFS=' ' read -a cols`：只按空格切分、折叠连续空格、忽略前导空格
//     （见本文件 fields 函数的实现说明：制表符不是分隔符）；
//   - cols[1] = local_address，cols[3] = st；只有 st == "0A"（LISTEN）、含 ":"
//     且列数 ≥ 4 才继续；
//   - 端口 hex 必须恰好 4 位十六进制（大小写均可）；
//   - 地址是 little-endian hex，经 procAddr 还原成人可读形式；
//   - 最后统一走 emit 的「可达性 + 端口区间」过滤（与 bash 一样，解析函数只吐过滤后的行）。
//
// 已知偏离（有意）：bash 的 _ports_proc_addr 在非 hex 地址上会因 `$((16#ZZ))` 报错中止整个
// 解析（set -e），Go 侧降级为跳过该行（见 hexToIPv4 与 procAddr 注释）。
//
// 两个入参分别对应两个文件，内部按 /proc 的真实顺序（tcp4 在前）拼接。注意本函数**不做**
// 跨文件去重（bash 的 ports_parse_proc 也不做；去重在 ports_listening_json 末端的 jq 里，
// Go 侧对应 dedupe/List）。
func ParseProc(tcp4, tcp6 string) []Listener {
	text := tcp4 + "\n" + tcp6
	out := []Listener{}
	for _, line := range strings.Split(text, "\n") {
		cols := fields(line)
		if len(cols) < 4 {
			continue
		}
		localHex, st := cols[1], cols[3]
		first := strings.Index(localHex, ":")
		last := strings.LastIndex(localHex, ":")
		if st != "0A" || first < 0 || last < 0 {
			continue
		}
		portHex := localHex[last+1:]
		if !isHex4(portHex) {
			continue
		}
		port, err := strconv.ParseUint(portHex, 16, 32)
		if err != nil {
			continue
		}
		// 十进制化后交给 emit 重新校验形状/区间（← bash 先 `$((16#...))` 再 _ports_emit）
		if l, ok := emit(strconv.FormatUint(port, 10), procAddr(localHex[:first]), ""); ok {
			out = append(out, l)
		}
	}
	return out
}

// ParseLsof 解析 `lsof -nP -iTCP -sTCP:LISTEN` 的输出（← ports_parse_lsof）。
//
// 逐行复刻 bash：
//   - 跳过表头（cols[0] == "COMMAND"）；
//   - 进程名 = cols[0]；NAME = cols[8]，必须含 ":"；
//   - 端口 = NAME 最后一个 ":" 之后；地址 = 最后一个 ":" 之前（含 [] 与 %zone，后面统一剥）；
//   - 再走 emit 过滤。
func ParseLsof(text string) []Listener {
	out := []Listener{}
	for _, line := range strings.Split(text, "\n") {
		cols := fields(line)
		if len(cols) <= 8 || cols[0] == "COMMAND" {
			continue
		}
		proc, name := cols[0], cols[8]
		idx := strings.LastIndex(name, ":")
		if idx < 0 {
			continue
		}
		if l, ok := emit(name[idx+1:], name[:idx], proc); ok {
			out = append(out, l)
		}
	}
	return out
}

// fields 复刻 bash `IFS=' ' read -r -a cols` 的取列语义：只按空格切分、连续空格折叠、
// 忽略前导空格 —— 制表符**不是**分隔符（IFS 被显式设成单个空格），故不能用 strings.Fields。
func fields(line string) []string {
	parts := strings.Split(line, " ")
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		if p != "" {
			out = append(out, p)
		}
	}
	return out
}

// emit 是唯一的「出站过滤」出口（← lib/ports.sh _ports_emit），三条判定全在这里：
//
//  1. 端口形状必须匹配 `^[1-9][0-9]{0,4}$`（无前导零、1..5 位、非 0）；
//  2. 端口区间 1024..65535；
//  3. 地址剥掉 [] 与 %iface 后必须是「经 localhost 可达」的六种之一。
//
// 任一条不满足即丢弃（ok=false）。
func emit(portText, addr, proc string) (Listener, bool) {
	if !validPortText(portText) {
		return Listener{}, false
	}
	port, err := strconv.Atoi(portText)
	if err != nil || port < minPort || port > maxPort {
		return Listener{}, false
	}
	normalized := normalizeAddr(addr)
	if !addrIsLocal(normalized) {
		return Listener{}, false
	}
	return Listener{Port: port, Addr: normalized, Process: proc}, true
}

// validPortText：`^[1-9][0-9]{0,4}$`（← bash `[[ ${port} =~ ^[1-9][0-9]{0,4}$ ]]`）。
func validPortText(s string) bool {
	if len(s) == 0 || len(s) > 5 {
		return false
	}
	if s[0] < '1' || s[0] > '9' {
		return false
	}
	for i := 1; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return true
}

// normalizeAddr 剥掉方括号与 %iface 后缀（← bash 的三次参数展开，顺序也一致：
// 先 `${addr#\[}`、再 `${addr%\]}`、最后 `${addr%%\%*}`）。
// 例：`[::1%lo]` -> `::1`；`127.0.0.53%lo` -> `127.0.0.53`；`[::]` -> `::`。
func normalizeAddr(addr string) string {
	addr = strings.TrimPrefix(addr, "[")
	addr = strings.TrimSuffix(addr, "]")
	if i := strings.Index(addr, "%"); i >= 0 {
		addr = addr[:i]
	}
	return addr
}

// addrIsLocal 判定地址是否「经 localhost 可达」（← ports_addr_is_local）。
//
// localhost 只解析到 127.0.0.1 / ::1：绑在其它 127.x 上的（systemd-resolved 的
// 127.0.0.53、容器 DNS 的 127.0.0.11）经桥接连不到，一律不算。
func addrIsLocal(addr string) bool {
	switch addr {
	case "*", "0.0.0.0", "::", "::1", "127.0.0.1", "::ffff:127.0.0.1":
		return true
	default:
		return false
	}
}

// procAddr 把 /proc 的 little-endian 地址 hex 还原成人可读形式（← _ports_proc_addr）。
//
//   - 8 位 hex：IPv4，字节序反转（`0100007F` -> `127.0.0.1`、`00000000` -> `0.0.0.0`）；
//   - 32 位 hex：`00000000000000000000000000000000` -> `::`；
//     `00000000000000000000000001000000` -> `::1`；
//     `0000000000000000FFFF0000` 前缀 -> `::ffff:<反转后的 IPv4>`；
//   - 其余（含非 hex 垃圾）原样返回大写 hex —— 与 bash 的 `*) printf '%s\n' "${hex}"` 一致，
//     这些地址随后会被 addrIsLocal 过滤掉（bash 里同样的 hex 无法通过白名单）。
func procAddr(hex string) string {
	up := strings.ToUpper(hex)
	if len(up) == 8 {
		if v4, ok := hexToIPv4(up); ok {
			return v4
		}
		return up
	}
	switch {
	case up == "00000000000000000000000000000000":
		return "::"
	case up == "00000000000000000000000001000000":
		return "::1"
	case strings.HasPrefix(up, "0000000000000000FFFF0000"):
		if len(up) >= 32 {
			if v4, ok := hexToIPv4(up[24:32]); ok {
				return "::ffff:" + v4
			}
		}
		return up
	default:
		return up
	}
}

// hexToIPv4 把 8 位 little-endian hex 转成点分十进制（← bash 的
// `%d.%d.%d.%d` + `${hex:6:2} ${hex:4:2} ${hex:2:2} ${hex:0:2}`）。
//
// 已知偏离（有意）：bash 在这种输入上会因 `$((16#ZZ))` 报 "value too great for base" 并在
// set -e 下中止整个 ports_parse_proc；Go 侧返回 ok=false，调用方（procAddr）退化为原样 hex，
// 再被地址白名单剔除 —— 结果同样是「不输出该行」，但不会拖垮整份列表（拒绝服务面更小）。
func hexToIPv4(s string) (string, bool) {
	if len(s) != 8 {
		return "", false
	}
	var b [4]byte
	for i := 0; i < 4; i++ {
		v, err := strconv.ParseUint(s[i*2:i*2+2], 16, 8)
		if err != nil {
			return "", false
		}
		// s[0:2] 是最低位字节 -> 落在点分十进制的最后一节
		b[3-i] = byte(v)
	}
	return strconv.Itoa(int(b[0])) + "." +
		strconv.Itoa(int(b[1])) + "." +
		strconv.Itoa(int(b[2])) + "." +
		strconv.Itoa(int(b[3])), true
}

// isHex4：端口 hex 必须恰好 4 位十六进制（← bash `[[ ${port_hex} =~ ^[0-9A-Fa-f]{4}$ ]]`）。
func isHex4(s string) bool {
	if len(s) != 4 {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c >= '0' && c <= '9':
		case c >= 'a' && c <= 'f':
		case c >= 'A' && c <= 'F':
		default:
			return false
		}
	}
	return true
}

// dedupe 按端口去重并升序排序：同端口优先保留带进程名的一条，否则保留先出现的一条
// （← bash 末尾 jq `group_by(.port) | map((map(select(.process != "")) | first) // first)
// | sort_by(.port)`；group_by 内部排序保证组内相对顺序 = 输入顺序，故「先出现」可复刻）。
func dedupe(rows []Listener) []Listener {
	indexOf := make(map[int]int, len(rows))
	out := make([]Listener, 0, len(rows))
	for _, r := range rows {
		if i, seen := indexOf[r.Port]; seen {
			if out[i].Process == "" && r.Process != "" {
				out[i] = r
			}
			continue
		}
		indexOf[r.Port] = len(out)
		out = append(out, r)
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].Port < out[j].Port })
	return out
}
