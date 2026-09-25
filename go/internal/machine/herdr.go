package machine

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// HerdrTimeout 是 `machine list --json` 的探测超时（秒），对照 lib/machines.sh 的
// MACHINES_HERDR_TIMEOUT=5：面板/CLI 都不能被一个卡住的 herdr 挂死。
const HerdrTimeout = 5 * time.Second

// HerdrMachineListJSON 执行 `$binPath machine list --json` 并返回规范化后的 machine 数组
// （对照 lib/machines.sh 的 machines_herdr_list_json）。
//
// 降级契约（§1 硬要求，与 bash 版逐条对齐）：binPath 为空 / 非可执行 / 命令失败 /
// 输出为空 / 输出非期望 JSON —— 一律 `"[]"` + warn，**绝不返回错误、绝不 panic**。
// 理由：插件在没配 machines 的机器（B 侧）上也必须能打开面板。
//
// 包裹层容错（herdr 各子命令 --json 的包裹层不统一）：
//
//	[...]                                   -> 原样
//	{"machines":[...]}                      -> .machines
//	{"result":{"machines":[...]}}           -> .result.machines
//	{"result":[...]}                        -> .result
//
// 过滤：只保留 JSON 对象且 `id` 非 null 的条目（其余原样透传，事实 #1 schema 不动）。
// 返回值是单行紧凑 JSON + 结尾换行（与 bash 的 `printf '%s\n'` 逐字节一致）。
func HerdrMachineListJSON(binPath string) []byte {
	const empty = "[]\n"

	if binPath == "" {
		warn("未设置 HERDR_BIN_PATH（herdr 插件运行时注入），saved machines 列表按空处理。既非错误也无需处理：在 herdr 里通过插件打开面板时该变量会自动存在。")
		return []byte(empty)
	}
	if !executableAvailable(binPath) {
		warn(fmt.Sprintf("HERDR_BIN_PATH=%s 不可执行，saved machines 列表按空处理。请在 herdr 内运行（herdr 注入的路径才有效），或检查 herdr 安装。", binPath))
		return []byte(empty)
	}

	ctx, cancel := context.WithTimeout(context.Background(), HerdrTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, binPath, "machine", "list", "--json")
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	runErr := cmd.Run()

	raw := strings.TrimRight(stdout.String(), "\n")
	if runErr != nil || raw == "" {
		// herdr 的 stderr 是本函数唯一的排障线索（bash 版 Bug 2 的教训），摘要进 warn。
		if runErr != nil && errors.Is(ctx.Err(), context.DeadlineExceeded) {
			runErr = fmt.Errorf("超时（%s）", HerdrTimeout)
		}
		warn(fmt.Sprintf("获取 saved machines 失败（%s machine list --json，rc=%s），按空列表继续。可手动执行该命令排查（herdr 未启动 / 未登录时也会如此）。%s",
			binPath, exitDesc(runErr), stderrSummary(stderr.String())))
		return []byte(empty)
	}

	arr, ok := machineArray(json.RawMessage(raw))
	if !ok {
		warn(fmt.Sprintf("saved machines 输出不是预期的 JSON 数组（%s machine list --json），按空列表继续。请升级 herdr 或报告该输出格式。", binPath))
		return []byte(empty)
	}
	return append(arr, '\n')
}

// machineArray 从 raw JSON 里取出 machine 数组并序列化成紧凑 JSON（第二个返回值 false =
// 「不是预期的 JSON 数组」，调用方按空列表 + warn 处理）。语义对照 bash 里的 jq 表达式。
func machineArray(raw json.RawMessage) ([]byte, bool) {
	var top any
	if err := json.Unmarshal(raw, &top); err != nil {
		return nil, false
	}

	items, ok := unwrapMachineList(top)
	if !ok {
		return nil, false
	}

	kept := make([]json.RawMessage, 0, len(items))
	for _, item := range items {
		obj, ok := item.(map[string]any)
		if !ok {
			continue // select(type == "object")
		}
		if id, present := obj["id"]; !present || id == nil {
			continue // select(.id != null)
		}
		itemRaw, err := json.Marshal(item)
		if err != nil {
			continue // 不可重编码：丢弃该条而不是让整个列表降级
		}
		kept = append(kept, itemRaw)
	}
	out, err := json.Marshal(kept) // 空切片 marshal 成 "[]"（不是 null）
	if err != nil {
		return nil, false
	}
	return out, true
}

// unwrapMachineList 剥掉可能存在的包裹层，返回 machine 条目切片。
func unwrapMachineList(top any) ([]any, bool) {
	if arr, ok := top.([]any); ok {
		return arr, true
	}
	obj, ok := top.(map[string]any)
	if !ok {
		return nil, false
	}
	if arr, ok := obj["machines"].([]any); ok {
		return arr, true
	}
	if result, ok := obj["result"].(map[string]any); ok {
		if arr, ok := result["machines"].([]any); ok {
			return arr, true
		}
	}
	if arr, ok := obj["result"].([]any); ok {
		return arr, true
	}
	return nil, false
}

// executableAvailable 复刻 bash 的 `[[ ! -x ${bin} ]] && ! command -v "${bin}"`：
// 含路径分隔符按文件判断（存在且可执行），否则按 PATH 查找。
func executableAvailable(bin string) bool {
	if strings.ContainsRune(bin, os.PathSeparator) {
		info, err := os.Stat(bin)
		return err == nil && info.Mode()&0o111 != 0
	}
	_, err := exec.LookPath(bin)
	return err == nil
}

// exitDesc 把 exec 的错误转成 bash `rc=$?` 风格的可读摘要。
func exitDesc(runErr error) string {
	if runErr == nil {
		return "0"
	}
	var exitErr *exec.ExitError
	if errors.As(runErr, &exitErr) {
		return fmt.Sprintf("%d", exitErr.ExitCode())
	}
	return runErr.Error()
}

// stderrSummary 压平换行 + 截断 300 字符（与 bash 的 errsum 处理一致），空则返回空串。
func stderrSummary(s string) string {
	s = strings.TrimSpace(s)
	if s == "" {
		return ""
	}
	s = strings.Join(strings.Fields(s), " ")
	if len(s) > 300 {
		s = s[:300]
	}
	return "herdr stderr: " + s
}

// warn 输出一条 warn 级日志：恒镜像 stderr，并在 HERDR_PLUGIN_STATE_DIR 存在时追加进
// logs/forward.log（格式对齐 lib/common.sh 的 `[<UTC ISO8601>] warn: <msg>`）。
//
// 备注：唯一的 log 实现属于 internal/hfcommon（PLAN §5 的 Log，W1 拥有，本 phase 尚未落地）；
// 为避免与未落地的符号耦合，这里就地实现「warn 必达用户」这一被 §1 降级契约要求的最小行为。
// Phase 2 起可改为 hfcommon.Log("warn", ...)（轮转逻辑同时收口，本函数不实现轮转）。
func warn(msg string) {
	line := fmt.Sprintf("[%s] warn: %s", time.Now().UTC().Format("2006-01-02T15:04:05Z"), msg)
	if dir := os.Getenv("HERDR_PLUGIN_STATE_DIR"); dir != "" {
		logDir := filepath.Join(dir, "logs")
		if err := os.MkdirAll(logDir, 0o755); err == nil {
			f, err := os.OpenFile(filepath.Join(logDir, "forward.log"), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
			if err == nil {
				_, _ = f.WriteString(line + "\n")
				_ = f.Close()
			}
		}
	}
	fmt.Fprintln(os.Stderr, line)
}
