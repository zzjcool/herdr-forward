// state.go —— 桥接状态文档的读写（← lib/bridge.sh 的 _bridge_serve_write /
// _bridge_client_write / 队列与锁）。
//
// **键序是契约**：bash 用 `jq -c`（不是 `-S`）构造这些文档，键序 = jq 程序里的书写序，
// 而不是字母序。因此这里不能用 Go 的 map（encoding/json 会排序键），必须走
// internal/jqjson 的插入序对象 —— 否则 `bridge status --json` 的逐字节差分立刻红。
//
// 同理，`forwards` / `status` 子对象的键序 = bash 数组下标顺序（端口升序），因为
// `${!arr[@]}` 对稀疏索引数组返回**数值升序**的键。
package bridge

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/zzjcool/herdr-forward/internal/hfcommon"
	"github.com/zzjcool/herdr-forward/internal/jqjson"
	"github.com/zzjcool/herdr-forward/internal/state"
)

// PingSeconds 是 A → B 的心跳间隔（BRIDGE_PING_S）。
func PingSeconds() int { return envInt("BRIDGE_PING_S", 5) }

// PollSeconds 是检查期望集合 / 停止信号的间隔（BRIDGE_POLL_S）。
func PollSeconds() int { return envInt("BRIDGE_POLL_S", 1) }

// LiveWindowSeconds 是 client 心跳的在线窗口（BRIDGE_LIVE_WINDOW_S）。
func LiveWindowSeconds() int { return envInt("BRIDGE_LIVE_WINDOW_S", 20) }

// BackoffMinSeconds / BackoffMaxSeconds 是退避区间的下上界。
func BackoffMinSeconds() int { return envInt("BRIDGE_BACKOFF_MIN_S", 2) }
func BackoffMaxSeconds() int { return envInt("BRIDGE_BACKOFF_MAX_S", 60) }

// StableSeconds 是「一次连接存活超过该秒数才把退避重置为最小值」的阈值（BRIDGE_STABLE_S）。
func StableSeconds() int { return envInt("BRIDGE_STABLE_S", 60) }

// ServerAliveSeconds 是桥接 ssh 的 ServerAliveInterval（BRIDGE_SERVER_ALIVE_S）。
func ServerAliveSeconds() int { return envInt("BRIDGE_SERVER_ALIVE_S", 15) }

// forwardState 是一条映射在会话/客户端文档里的状态。
type forwardState struct {
	Spec   string // "lp rp"（仅 client 文档）
	State  string // up | down
	Reason string
}

// sessionDoc 是 B 侧会话文档（A.3.3 schema，键序见文件头注释）。
type sessionDoc struct {
	ClientHost   string
	ClientLabel  string
	ServerHost   string
	StartedUnix  int64
	LastSeenUnix int64
	Status       map[int]forwardState // 下标 = 本地端口（bash 用端口当数组下标）
}

// clientDoc 是 A 侧 supervisor 文档（A.3.3 schema）。
type clientDoc struct {
	Pid         int64
	Machine     string
	Label       string
	Target      string
	ServerHost  string
	State       string
	Reason      string
	SinceUnix   int64
	UpdatedUnix int64
	NextRetry   int64 // 0 → null
	Forwards    map[int]forwardState
}

// encodeSession 复刻 _bridge_serve_write 的 `jq -R -s -c` 产物（插入序 + 端口升序子对象）。
func encodeSession(d sessionDoc) []byte {
	obj := jqjson.NewObject()
	obj.Set("client_host", d.ClientHost)
	obj.Set("client_label", d.ClientLabel)
	obj.Set("server_host", d.ServerHost)
	obj.Set("started_unix", jqjson.NumberLiteral(strconv.FormatInt(d.StartedUnix, 10)))
	obj.Set("last_seen_unix", jqjson.NumberLiteral(strconv.FormatInt(d.LastSeenUnix, 10)))
	status := jqjson.NewObject()
	for _, port := range sortedPorts(d.Status) {
		st := d.Status[port]
		reason := st.Reason
		if len(reason) > 200 {
			reason = reason[:200] // bash: `${reason:0:200}`
		}
		entry := jqjson.NewObject()
		entry.Set("state", st.State)
		entry.Set("reason", reason)
		status.Set(fmt.Sprintf("f-%d", port), entry)
	}
	obj.Set("status", status)
	return []byte(jqjson.Encode(obj, false) + "\n")
}

// encodeClient 复刻 _bridge_client_write 的 `jq -R -s -c` 产物。
func encodeClient(d clientDoc) []byte {
	obj := jqjson.NewObject()
	obj.Set("pid", jqjson.NumberLiteral(strconv.FormatInt(d.Pid, 10)))
	obj.Set("machine", d.Machine)
	obj.Set("label", d.Label)
	obj.Set("target", d.Target)
	obj.Set("server_host", d.ServerHost)
	obj.Set("state", d.State)
	obj.Set("reason", d.Reason)
	obj.Set("since_unix", jqjson.NumberLiteral(strconv.FormatInt(d.SinceUnix, 10)))
	obj.Set("updated_unix", jqjson.NumberLiteral(strconv.FormatInt(d.UpdatedUnix, 10)))
	if d.NextRetry > 0 {
		obj.Set("next_retry_unix", jqjson.NumberLiteral(strconv.FormatInt(d.NextRetry, 10)))
	} else {
		obj.Set("next_retry_unix", nil)
	}
	forwards := jqjson.NewObject()
	for _, port := range sortedPorts(d.Forwards) {
		fw := d.Forwards[port]
		entry := jqjson.NewObject()
		entry.Set("spec", fw.Spec)
		entry.Set("state", fw.State)
		entry.Set("reason", fw.Reason)
		forwards.Set(fmt.Sprintf("f-%d", port), entry)
	}
	obj.Set("forwards", forwards)
	return []byte(jqjson.Encode(obj, false) + "\n")
}

// sortedPorts 复刻 bash 的 `${!arr[@]}` 顺序（稀疏索引数组 → 数值升序）。
func sortedPorts(m map[int]forwardState) []int {
	ports := make([]int, 0, len(m))
	for p := range m {
		ports = append(ports, p)
	}
	sort.Ints(ports)
	return ports
}

// writeSessionFile 原子写会话文档（B 侧，每条 serve 一份）。
func writeSessionFile(path string, d sessionDoc) {
	_ = hfcommon.AtomicWrite(path, encodeSession(d))
}

// writeClientFile 原子写 supervisor 文档（A 侧）。
func writeClientFile(path string, d clientDoc) {
	_ = hfcommon.AtomicWrite(path, encodeClient(d))
}

// --- 单实例锁（A 侧） -------------------------------------------------------

// LockHolder 复刻 _bridge_lock_holder：持锁 supervisor 的 pid（活着才返回非空）。
//
// bash 的 `=~ ^[0-9]+$` 对含尾部换行的串**不匹配** —— 这里显式 TrimSpace 后再判定，
// 语义等价（文件是我们自己 `printf '%s\n'` 写的）。
func LockHolder(machine string) string {
	data, err := os.ReadFile(filepath.Join(ClientLock(machine), "pid"))
	if err != nil {
		return ""
	}
	pid := strings.TrimSpace(string(data))
	if !isDigits(pid) || !pidAlive(pid) {
		return ""
	}
	return pid
}

// Running 复刻 bridge_running：yes/no（supervisor 活着）。
func Running(machine string) bool { return LockHolder(machine) != "" }

// AcquireLock 复刻 _bridge_lock_acquire：mkdir 原子抢锁。
//
//	返回 "ok"   = 抢到（并写入自己的 pid）
//	返回 "busy" = 别的活着的 supervisor 持锁
//
// 持锁进程已死则回收（最多重试 3 次，与 bash 相同）。
func AcquireLock(machine string, pid string) string {
	lock := ClientLock(machine)
	for tries := 0; tries < 3; tries++ {
		if err := os.Mkdir(lock, 0o700); err == nil {
			_ = os.WriteFile(filepath.Join(lock, "pid"), []byte(pid+"\n"), 0o600)
			return "ok"
		}
		holder := LockHolder(machine)
		if holder != "" && holder != pid {
			return "busy"
		}
		_ = os.RemoveAll(lock)
	}
	return "busy"
}

// ReleaseLock 复刻 `rm -rf "${lock}"`。
func ReleaseLock(machine string) { _ = os.RemoveAll(ClientLock(machine)) }

// --- 打开请求队列（B 侧） ---------------------------------------------------

// EnqueueOpen 复刻 bridge_enqueue_open：把打开请求落进 `bridge/open/` 队列。
//
// 文件名 `<epoch>-<rand><rand>.url` —— 时间戳是**过期判定**（30s）的依据，
// 随机后缀防同秒并发覆盖。
func EnqueueOpen(url string) {
	dir := OpenDir()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return
	}
	name := fmt.Sprintf("%d-%d%d.url", hfcommon.NowUnix(), os.Getpid(), randInt())
	_ = hfcommon.AtomicWrite(filepath.Join(dir, name), []byte(url+"\n"))
}

// randInt 提供一个进程内唯一的后缀（替代 bash 的 $RANDOM$RANDOM）：同一 serve 进程内
// 多个 open 请求可能落在同一秒，光靠时间戳会互相覆盖，故叠加纳秒低位。
func randInt() int {
	return int(time.Now().UnixNano() % 1000000)
}

// --- 期望集合（B 侧） -------------------------------------------------------

// DesiredSync 复刻 bridge_desired_json：mode=client 的记录，按 local_port 升序。
//
// 用 state.Forward 的冻结类型化模型（bridge_desired_json 的 jq 只取三个字段），
// 与 bash 的 `select(.mode == "client") | {id, local_port, remote_port} | sort_by(.local_port)`
// 语义一致；`sort_by` 在 jq 里是稳定排序，这里用 SliceStable。
func DesiredSync() Sync {
	records, _ := state.Load()
	entries := make([]SyncEntry, 0, len(records))
	for _, r := range records {
		if r.Mode != "client" {
			continue
		}
		entries = append(entries, SyncEntry{
			ID:         fmt.Sprintf("f-%d", r.LocalPort),
			LocalPort:  r.LocalPort,
			RemotePort: r.RemotePort,
		})
	}
	sort.SliceStable(entries, func(i, j int) bool { return entries[i].LocalPort < entries[j].LocalPort })
	return Sync{Forwards: entries}
}

// readJSONObject 读一个 JSON 对象文件（缺失/损坏 → nil）。
func readJSONObject(path string) *jqjson.Object {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	v, err := jqjson.Parse(data)
	if err != nil {
		return nil
	}
	obj, ok := v.(*jqjson.Object)
	if !ok {
		return nil
	}
	return obj
}

// isDigits 判定纯 ASCII 数字串。
func isDigits(s string) bool {
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

// pidAlive 复刻 bash 的 `kill -0`：任何错误（含 EPERM）都算「已死」。
func pidAlive(pidText string) bool {
	pid, err := strconv.Atoi(pidText)
	if err != nil {
		return false
	}
	return syscall.Kill(pid, 0) == nil
}
