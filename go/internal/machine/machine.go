// Package machine —— machines.toml 解析、ssh target 归一化、herdr machine list 视图。
//
// Bash 对位：lib/machine.sh（单数：LABEL -> ssh_target）+ lib/machines.sh（复数：herdr
// saved machines 列表）。
// 冻结接口与安全边界见 docs/PLAN-GO-MIGRATION.md §5；行为权威是上述两个 shell 库的原文。
//
// Phase 1 范围（W3）：解析层只读部分 —— NormalizeSshTarget / ResolveFromToml /
// HerdrMachineListJSON。激活记录（activated-machines.json）与合并视图（machines_view_json）
// 属 Phase 3。
package machine

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"

	"github.com/BurntSushi/toml"
)

// ErrMachineUnresolved 是 machine 解析失败的哨兵错误（对照 bash 的 die 4 语义：
// bin/forward 的 _hf_resolve_target 把任何解析失败统一映射为 exit 4）。
// 所有 ResolveFromToml 的失败都用 %w 包住它，调用方 errors.Is(err, ErrMachineUnresolved)
// 即可判定「machine 无法解析」。
var ErrMachineUnresolved = errors.New("machine unresolved")

// TomlPath 返回 machines.toml 的绝对路径（对照 lib/machine.sh 的 machines_toml_path）。
//
// 回退链（与 bash 的 `${HERDR_PLUGIN_CONFIG_DIR:-${XDG_CONFIG_HOME:-${HOME:-/tmp}/.config}/herdr-forward}`
// 逐字符等价；空串按未设置处理，即 bash 的 `:-` 语义）：
//
//	$HERDR_PLUGIN_CONFIG_DIR
//	→ ${XDG_CONFIG_HOME:-${HOME:-/tmp}/.config}/herdr-forward
//
// 备注：PLAN §5 把 ConfigDir() 冻结在 internal/hfcommon（W1 拥有，本 phase 尚未落地）；
// 为避免与未落地的函数耦合而就地实现同一回退链，Phase 2 起可改为委托 hfcommon.ConfigDir()。
func TomlPath() string {
	return filepath.Join(configDir(), "machines.toml")
}

// configDir 见 TomlPath 的注释（回退链的唯一实现点）。
func configDir() string {
	if dir := os.Getenv("HERDR_PLUGIN_CONFIG_DIR"); dir != "" {
		return dir
	}
	base := os.Getenv("XDG_CONFIG_HOME")
	if base == "" {
		home := os.Getenv("HOME")
		if home == "" {
			home = "/tmp" // 与 bash 的 ${HOME:-/tmp} 一致（HERDR_PLUGIN_CONFIG_DIR 未设且 HOME 缺失时）
		}
		base = filepath.Join(home, ".config")
	}
	return filepath.Join(base, "herdr-forward")
}

// NormalizeSshTarget 给 ssh target 补上显式端口（缺省 22），并保留 IPv6 字面量的方括号。
//
// 对照 lib/machine.sh 的 machine_normalize_ssh_target，接受形态：
//
//	host                  -> host:22
//	user@host             -> user@host:22
//	user@host:2222        -> 原样
//	[v6]                  -> [v6]:22
//	[v6]:2222 / user@[v6]:2222 -> 原样
//
// **有意的偏差**：bash 版对任何输入都会追加 `:22`（非法输入静默产出垃圾 target），
// Go 版按 PLAN §5/§8「非法 → 64」把非法输入判为用法错，由调用方映射 exit 64。
// 非法 = 空 / 含空白 / 未加方括号的多冒号（裸 IPv6，无法与端口区分）/ 方括号未闭合或
// 位置非法 / 缺主机名 / 端口非纯数字或越界（1-65535）。
func NormalizeSshTarget(t string) (string, error) {
	if t == "" {
		return "", errors.New("ssh target 为空（期望 user@host[:port]）")
	}
	if strings.ContainsAny(t, " \t\n\r\v\f") {
		return "", fmt.Errorf("ssh target 含空白字符: '%s'（期望 user@host[:port]）", t)
	}

	// 方括号形态：`[v6]` / `[v6]:port`，可带 `user@` 前缀（前缀必须在 `[` 前结束）。
	if open := strings.Index(t, "["); open >= 0 {
		prefix := t[:open]
		if prefix != "" && !strings.HasSuffix(prefix, "@") {
			return "", fmt.Errorf("ssh target 方括号只能用于主机部分: '%s'（期望 [ipv6]:port）", t)
		}
		closeRel := strings.Index(t[open:], "]")
		if closeRel < 0 {
			return "", fmt.Errorf("ssh target 方括号未闭合: '%s'（期望 [ipv6]:port）", t)
		}
		closeIdx := open + closeRel
		host := t[open+1 : closeIdx]
		after := t[closeIdx+1:]
		if host == "" {
			return "", fmt.Errorf("ssh target 缺少主机名: '%s'", t)
		}
		if strings.Contains(host, "[") {
			return "", fmt.Errorf("ssh target 方括号嵌套: '%s'（期望 [ipv6]:port）", t)
		}
		if after == "" {
			return t + ":22", nil
		}
		if !strings.HasPrefix(after, ":") || after == ":" {
			return "", fmt.Errorf("ssh target 方括号后只能接 :端口: '%s'", t)
		}
		if err := checkPort(after[1:], t); err != nil {
			return "", err
		}
		return t, nil
	}

	switch colons := strings.Count(t, ":"); {
	case colons == 0:
		return t + ":22", nil
	case colons == 1:
		i := strings.Index(t, ":")
		host := t[:i]
		if host == "" {
			return "", fmt.Errorf("ssh target 缺少主机名: '%s'", t)
		}
		if err := checkPort(t[i+1:], t); err != nil {
			return "", err
		}
		return t, nil
	default:
		return "", fmt.Errorf("ssh target 含多个 ':' 且未加方括号（IPv6 字面量必须写成 [addr]:port）: '%s'", t)
	}
}

// checkPort 校验端口串：纯 ASCII 数字且落在 1-65535。
// bash 版不做范围校验（`:99999` 也能过），这里按 PLAN §8 的「非法 → 64」收紧；
// 与 bin/forward 的 _hf_require_port（1-65535）保持一致。
func checkPort(port, target string) error {
	if port == "" {
		return fmt.Errorf("ssh target 端口为空: '%s'（期望 user@host[:port]）", target)
	}
	if !isAllDigits(port) {
		return fmt.Errorf("ssh target 端口非法: '%s'（期望 user@host[:port]）", port)
	}
	n, err := strconv.Atoi(port)
	if err != nil || n < 1 || n > 65535 {
		return fmt.Errorf("ssh target 端口越界（1-65535）: '%s'", port)
	}
	return nil
}

// isAllDigits 只认 ASCII 0-9（strconv.Atoi 会接受 "+22"，这里不接受）。
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

// ResolveFromToml 把 machines.toml 里的 LABEL 解析成带显式端口的 ssh_target
// （对照 lib/machine.sh 的 machine_resolve；失败一律返回包住 ErrMachineUnresolved 的错误，
// 即 bash 的 die 4）。
//
// 文件格式（与 bash 解析器一致的部分，用真 TOML 解析器实现）：
//
//	[machines.gpu-box]
//	ssh_target = "user@gpu-box.example.com:22"
//
// 与 bash 解析器的差异（都是「更严格但可预期」方向，不影响既有 fixture）：
//   - 值是**真正的 TOML**：未加引号的 `ssh_target = user@host`、未闭合引号、非字符串类型
//     （`ssh_target = 22`）都在 bash 里靠字符串嗅探报错，这里由解析器/类型断言报错（同为 die 4 语义）；
//   - 可用 label 列表按字典序输出（bash 按文件顺序；Go 的 map 迭代无序，必须显式排序）。
func ResolveFromToml(label string) (string, error) {
	if label == "" {
		return "", fmt.Errorf("%w: machine_resolve: missing label (usage: forward add 3000:3000 --machine LABEL)", ErrMachineUnresolved)
	}

	path := TomlPath()
	data, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return "", fmt.Errorf("%w: no machine config at %s; create it, e.g.: printf '[machines.gpu-box]\\nssh_target = \"user@gpu-box.example.com:22\"\\n' >> %s",
				ErrMachineUnresolved, path, path)
		}
		return "", fmt.Errorf("%w: machine config %s is not readable (%v); check its permissions (chmod 600 %s)",
			ErrMachineUnresolved, path, err, path)
	}

	var doc struct {
		Machines map[string]any `toml:"machines"`
	}
	if _, err := toml.Decode(string(data), &doc); err != nil {
		return "", fmt.Errorf("%w: machine config %s is not valid TOML (%v); expected: [machines.%s]\\nssh_target = \"user@host:22\"",
			ErrMachineUnresolved, path, err, label)
	}

	table, ok := lookupMachine(doc.Machines, label)
	if !ok {
		labels := availableLabels(doc.Machines)
		if len(labels) == 0 {
			return "", fmt.Errorf("%w: machine '%s' not found in %s; add a [machines.%s] section, e.g.: printf '[machines.%s]\\nssh_target = \"user@host:22\"\\n' >> %s",
				ErrMachineUnresolved, label, path, label, label, path)
		}
		return "", fmt.Errorf("%w: machine '%s' not found in %s; available labels: %s",
			ErrMachineUnresolved, label, path, strings.Join(labels, ","))
	}

	// bash 只在 [machines.<label>] 段内找 ssh_target，其余未知键只 log debug 忽略。
	raw, ok := table["ssh_target"]
	if !ok || raw == nil {
		return "", fmt.Errorf("%w: machine '%s' in %s has no ssh_target; add: ssh_target = \"user@host:22\"",
			ErrMachineUnresolved, label, path)
	}
	target, ok := raw.(string)
	if !ok {
		return "", fmt.Errorf("%w: machine '%s': ssh_target must be a quoted string, got %v (example: ssh_target = \"user@host:22\")",
			ErrMachineUnresolved, label, raw)
	}
	if target == "" {
		return "", fmt.Errorf("%w: machine '%s': ssh_target must be a quoted string, got %s (example: ssh_target = \"user@host:22\")",
			ErrMachineUnresolved, label, target)
	}
	if !strings.Contains(target, "@") || strings.HasPrefix(target, "@") || strings.ContainsAny(strings.SplitN(target, "@", 2)[0], " \t\n\r\v\f") {
		return "", fmt.Errorf("%w: machine '%s': ssh_target '%s' must look like user@host[:port]",
			ErrMachineUnresolved, label, target)
	}

	normalized, err := NormalizeSshTarget(target)
	if err != nil {
		return "", fmt.Errorf("%w: machine '%s' in %s: %v", ErrMachineUnresolved, label, path, err)
	}
	return normalized, nil
}

// lookupMachine 找到 label 对应的机器表。查找顺序：
//  1. 精确键（`[machines."a.b"]` 引号键 / 普通单层键）；
//  2. 按 '.' 逐层下钻（`[machines.a.b]` 在 TOML 里是嵌套表，而 bash 的正则把 `a.b`
//     当整段 label，两种写法都必须能解析）。
//
// 非表值（`[machines.x]` 位置写成了 `machines = {x = 1}` 之类）视作不存在，
// 与 bash 的「找不到 section」同档（错误信息里的 [machines.<label>] 示例给出正确写法）。
func lookupMachine(machines map[string]any, label string) (map[string]any, bool) {
	if v, ok := machines[label]; ok {
		if table, isTable := v.(map[string]any); isTable {
			return table, true
		}
	}
	if !strings.Contains(label, ".") {
		return nil, false
	}
	current := machines
	for _, part := range strings.Split(label, ".") {
		v, ok := current[part]
		if !ok {
			return nil, false
		}
		next, isTable := v.(map[string]any)
		if !isTable {
			return nil, false
		}
		current = next
	}
	return current, true
}

// availableLabels 列出 [machines.*] 的 label（字典序，供 "available labels:" 提示用）。
// 嵌套表（`[machines.a.b]`）按 bash 的段名列出 `a.b`。
func availableLabels(machines map[string]any) []string {
	labels := make([]string, 0, len(machines))
	collectLabels(machines, "", &labels)
	sort.Strings(labels)
	return labels
}

func collectLabels(machines map[string]any, prefix string, out *[]string) {
	for key, value := range machines {
		path := key
		if prefix != "" {
			path = prefix + "." + key
		}
		table, isTable := value.(map[string]any)
		if isTable && len(table) > 0 && allTables(table) {
			collectLabels(table, path, out) // 中间层：只有段名有意义（bash 只认 [machines.<label>] 行）
			continue
		}
		*out = append(*out, path)
	}
}

// allTables 判断 map 的所有值是否都是表（即该层是嵌套中间层，而非真正的机器段）。
func allTables(m map[string]any) bool {
	for _, v := range m {
		if _, ok := v.(map[string]any); !ok {
			return false
		}
	}
	return true
}
