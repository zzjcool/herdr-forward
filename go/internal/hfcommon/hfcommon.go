// hfcommon.go — lib/common.sh 的 Go 对位实现（PLAN-GO-MIGRATION §5 冻结签名）。
//
// 本文件覆盖：StateDir / ConfigDir / Log（含轮转）/ AtomicWrite / NowUnix。
// 行为权威是 lib/common.sh 原文（state_dir / log / _log_rotate / atomic_write /
// now_unix），迁移期原则是「零行为变化」，因此这里刻意复刻 bash 的细节（含少数
// 看起来多余的行为，见各处「复刻」注释），而不是顺手"修正"。
//
// 已知/刻意的偏差（无冻结接口变化，仅在报告「未决问题」登记）：
//   - bash log 的时间戳在 bash>=4.2 用 printf %()T（EPOCHSECONDS），<4.2 用 date fork；
//     两者都是 UTC 秒精度，Go 用 time.Now().UTC().Format 等价。
//   - bash _log_rotate 的字节切片在 LC_ALL=C 下按字节；Go 天然按字节。
//   - bash 的 `${data: -N}` 与 Go 的「读末尾 N 字节」在文件被并发追加时可能差一行，
//     迁移期不引入额外锁（与 bash 同等竞态）。
package hfcommon

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"time"
)

// lib/common.sh 顶部冻结常量（FORWARD_LOG_MAX_BYTES / FORWARD_LOG_KEEP_BYTES /
// FORWARD_TCP_TIMEOUT_DEFAULT / FORWARD_PROBE_TIMEOUT_DEFAULT）。
const (
	// LogMaxBytes — 日志超过此字节数即轮转（>1MB，严格大于）。
	LogMaxBytes = 1048576
	// LogKeepBytes — 轮转后保留的尾部字节数（512KB）。
	LogKeepBytes = 524288
	// TCPTimeoutDefault — probe_tcp 默认秒数。
	TCPTimeoutDefault = 2
	// ProbeTimeoutDefault — probe_payload 等待应用层回包的默认秒数。
	ProbeTimeoutDefault = 2
)

const (
	// StateVersion — forwards.json 的 version 字段（FORWARD_STATE_VERSION）。
	StateVersion = 1
	// StateDirSuffix — state_dir 的环境变量缺失时的回退相对路径。
	StateDirSuffix = ".local/state/herdr-forward"
	// ConfigDirSuffix — config dir 的环境变量缺失时的回退相对路径。
	ConfigDirSuffix = ".config/herdr-forward"
	// LogFileName — 日志文件名（state_dir/logs/<此名>）。
	LogFileName = "forward.log"
	// tmpFallback — $HOME 缺失时的兜底前缀（bash: ${HOME:-/tmp}）。
	tmpFallback = "/tmp"
)

// StateDir 复刻 state_dir：
//
//	HERDR_PLUGIN_STATE_DIR 优先，缺失回退 ${HOME:-/tmp}/.local/state/herdr-forward
//
// 返回值不做绝对化/清理（bash 也不做），保证与 bash 打印的路径逐字符一致。
func StateDir() string {
	if dir := os.Getenv("HERDR_PLUGIN_STATE_DIR"); dir != "" {
		return dir
	}
	return filepath.Join(homeOrTmp(), StateDirSuffix)
}

// ConfigDir 复刻 lib/machine.sh:19 的 machines_toml_path 目录解析：
//
//	HERDR_PLUGIN_CONFIG_DIR 优先，其次 ${XDG_CONFIG_HOME:-${HOME:-/tmp}/.config}/herdr-forward
func ConfigDir() string {
	if dir := os.Getenv("HERDR_PLUGIN_CONFIG_DIR"); dir != "" {
		return dir
	}
	base := os.Getenv("XDG_CONFIG_HOME")
	if base == "" {
		base = filepath.Join(homeOrTmp(), ".config")
	}
	return filepath.Join(base, "herdr-forward")
}

// homeOrTmp 返回 $HOME，缺失/为空时返回 /tmp（bash: ${HOME:-/tmp}）。
func homeOrTmp() string {
	if home := os.Getenv("HOME"); home != "" {
		return home
	}
	return tmpFallback
}

// NowUnix 复刻 now_unix：epoch 秒。
func NowUnix() int64 { return time.Now().Unix() }

// Log 复刻 log <level> <msg...>：
//
//	$HERDR_PLUGIN_STATE_DIR/logs/forward.log；env 缺失退 /dev/stderr。
//	行格式：[<UTC RFC3339秒>] <level>: <msg>
//	写前先轮转（>1MB → 保尾部 512KB）。
//	warn/error 额外镜像到 stderr（用户/CI 可见）。
//	永不因日志失败而中断调用方（所有错误静默吞掉，与 bash 的 `|| true` 等价）。
//
// 复刻说明（刻意保留的 bash 细节）：env 缺失且 level 为 warn/error 时 bash 会
// **打印两次**到 stderr（先走「无 env」分支，再走末尾的 warn/error 镜像分支）。
// 这里保持一致 —— 迁移期零行为变化优先，是否收敛留给后续 phase 单独裁决。
func Log(level, msg string) {
	line := fmt.Sprintf("[%s] %s: %s", time.Now().UTC().Format("2006-01-02T15:04:05Z"), level, msg)

	stateDir := os.Getenv("HERDR_PLUGIN_STATE_DIR")
	if stateDir != "" {
		logDir := filepath.Join(stateDir, "logs")
		logFile := filepath.Join(logDir, LogFileName)
		written := false
		if err := os.MkdirAll(logDir, 0o755); err == nil {
			rotateLog(logFile)
			if err := appendLine(logFile, line); err == nil {
				written = true
			}
		}
		if !written {
			// 目录被外部删掉/权限异常：重建一次再重试，仍失败则退 stderr。
			_ = os.MkdirAll(logDir, 0o755)
			if err := appendLine(logFile, line); err != nil {
				fmt.Fprintln(os.Stderr, line)
			}
		}
	} else {
		fmt.Fprintln(os.Stderr, line)
	}

	if level == "warn" || level == "error" {
		fmt.Fprintln(os.Stderr, line)
	}
}

// Logf 是 Log 的格式化便利包装（不改变落盘格式）。
func Logf(level, format string, args ...any) { Log(level, fmt.Sprintf(format, args...)) }

func appendLine(path, line string) error {
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	defer f.Close()
	if _, err := io.WriteString(f, line+"\n"); err != nil {
		return err
	}
	return nil
}

// rotateLog 复刻 _log_rotate：>LogMaxBytes 时保留最后 LogKeepBytes 字节 + 一个换行。
//
// bash 用 `read -N MAX+1` 判定「>MAX」，因此判定是「文件大小 ≥ MAX+1」，即 size > MAX。
func rotateLog(path string) {
	st, err := os.Stat(path)
	if err != nil || !st.Mode().IsRegular() {
		return
	}
	if st.Size() <= LogMaxBytes {
		return
	}

	kept, err := tailBytes(path, LogKeepBytes)
	if err != nil {
		return
	}
	// bash: printf '%s\n' "${data: -KEEP}" >"${logfile}"（截断覆盖，保留原权限）。
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_TRUNC, 0o644)
	if err != nil {
		return
	}
	defer f.Close()
	_, _ = f.Write(append(kept, '\n'))
}

// tailBytes 读取文件末尾 n 字节（不足 n 则返回全文）。
func tailBytes(path string, n int) ([]byte, error) {
	if n < 0 {
		n = 0
	}
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		return nil, err
	}
	size := st.Size()
	if size <= int64(n) {
		return io.ReadAll(f)
	}
	if _, err := f.Seek(size-int64(n), io.SeekStart); err != nil {
		return nil, err
	}
	return io.ReadAll(f)
}

// AtomicWrite 复刻 atomic_write：写入同目录临时文件（0600）后 rename 替换。
//
// bash 原版签名是 atomic_write <file> <tmpdir>，把临时文件放在调用方指定的同分区
// 目录；Go 冻结签名 AtomicWrite(path, content) 没有 tmpdir 参数，故临时文件落在
// path 所在目录 —— 同分区保证 rename 是原子的，且对调用方更省心。
//
// 与 bash 一致：自动创建目标目录；失败时清理临时文件；失败返回 error（bash 是 die 1，
// 退出码由调用方决定，C2 冻结的 exitcode 表由 cli 层映射）。
func AtomicWrite(path string, content []byte) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return fmt.Errorf("atomic_write 无法创建目标目录 %s: %w", dir, err)
	}

	tmp, err := os.CreateTemp(dir, ".atomic.*")
	if err != nil {
		return fmt.Errorf("atomic_write 无法在 %s 创建临时文件: %w", dir, err)
	}
	tmpName := tmp.Name()
	cleanup := func() { _ = os.Remove(tmpName) }

	// CreateTemp 已是 0600（对齐 mktemp）；显式再设一次以防 umask 意外。
	if err := tmp.Chmod(0o600); err != nil {
		_ = tmp.Close()
		cleanup()
		return fmt.Errorf("atomic_write 设置临时文件权限失败 %s: %w", tmpName, err)
	}
	if _, err := tmp.Write(content); err != nil {
		_ = tmp.Close()
		cleanup()
		return fmt.Errorf("atomic_write 写入临时文件失败 %s: %w", tmpName, err)
	}
	if err := tmp.Close(); err != nil {
		cleanup()
		return fmt.Errorf("atomic_write 关闭临时文件失败 %s: %w", tmpName, err)
	}
	if err := os.Rename(tmpName, path); err != nil {
		cleanup()
		return fmt.Errorf("atomic_write 落盘失败 %s: %w", path, err)
	}
	return nil
}
