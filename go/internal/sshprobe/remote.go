// remote.go —— 远端探测命令的**逐字搬运**（← lib/ssh-probe.sh 的 REMOTE_LIST_CMD /
// REMOTE_PATHS_CMD）。
//
// 为什么逐字搬运而不是"重写得更 Go 一点"：这两段是**远端 shell** 的脚本，其语义完全由
// 远端决定（`command -v herdr` 的 PATH 行为、`$HOME`/`$XDG_*` 的展开时机、plugins.json
// 的容错读取）。任何"现代化"都会改变远端行为，而 A 机真实 bug 的回归锚点
// （tests/unit/test_ssh_probe.sh、tests/integration/test_machines_probe.sh、
// scripts/e2e/run-inside.sh 的 A3 段）正是对着这些字节写的。
//
// 单引号字符串在此处是**故意的**：`$HOME` / `$PATH` / `$cfg` 必须由远端 shell 展开，
// 本进程一个字都不能动（bash 版用 `# shellcheck disable=SC2016` 表达同一件事）。
package sshprobe

// DefaultPluginID 是本插件的 herdr plugin id（lib/ssh-probe.sh 的 `zzjcool:forward` 默认值）。
const DefaultPluginID = "zzjcool:forward"

// RemoteListCmd 复刻 REMOTE_LIST_CMD：判远端有没有 herdr、装没装本插件。
//
// 判据（bash 相同）：
//
//	rc != 0                      -> unreachable（由调用方处理）
//	输出含 HF_NO_HERDR 字面量     -> no-herdr
//	输出不含 plugin id           -> absent
//	否则                         -> present
const RemoteListCmd = `if command -v herdr >/dev/null 2>&1; then herdr plugin list; else PATH="$HOME/.local/bin:$PATH" herdr plugin list 2>/dev/null || echo HF_NO_HERDR; fi`

// RemotePathsCmd 复刻 REMOTE_PATHS_CMD：推导 B 的插件根与 state 目录。
//
// plugins.json 的 plugin_root → 退回 plugins/github/*forward* glob →
// state 目录按远端 HOME/XDG 推导（HF_STATE_DIR=已存在 / HF_DEFAULT_STATE=默认位置）。
//
// 文本里的 __HF_PLUGIN_ID__ / __HF_PLUGIN_ID_ENC__ 由 SSHProbePlugin 代入（远端文本里
// 本来就有 %s 与 \" ，故不能整段当 printf 模板用）。
const RemotePathsCmd = `
cfg="${XDG_CONFIG_HOME:-$HOME/.config}/herdr"
root=""
if [ -f "$cfg/plugins.json" ] && command -v python3 >/dev/null 2>&1; then
  root=$(python3 -c "import json,sys
try:
    d=json.load(open(sys.argv[1], encoding=\"utf-8\"))
except Exception:
    raise SystemExit(0)
for e in (d if isinstance(d, list) else []):
    if isinstance(e, dict) and e.get(\"plugin_id\") == sys.argv[2]:
        print(e.get(\"plugin_root\", \"\"))
        break" "$cfg/plugins.json" __HF_PLUGIN_ID__ 2>/dev/null) || root=""
fi
if [ -z "$root" ]; then
  for d in "$cfg"/plugins/github/*forward*; do
    if [ -d "$d" ]; then root="$d"; fi
  done
fi
if [ -n "$root" ]; then printf "HF_ROOT=%s\n" "$root"; fi
enc="__HF_PLUGIN_ID_ENC__"
if [ -n "$root" ] && [ -f "$root/herdr-plugin.toml" ]; then
  id=$(sed -n "s/^[[:space:]]*id[[:space:]]*=[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$root/herdr-plugin.toml" | head -1)
  if [ -n "$id" ]; then enc=$(printf "%s" "$id" | sed "s/:/%3A/g"); fi
fi
state="${XDG_STATE_HOME:-$HOME/.local/state}/herdr/plugins/$enc"
if [ -d "$state" ]; then printf "HF_STATE_DIR=%s\n" "$state"; else printf "HF_DEFAULT_STATE=%s\n" "$state"; fi
`
