#!/usr/bin/env bash
# scripts/postinstall.sh — `herdr plugin install` 的 [[build]] 步骤：装好键位并让运行中的 herdr 立刻生效
#
# 为什么放在 build：startup hook 只在 herdr server 启动时跑（install / link / enable /
# reload-config 都不触发），而用户几乎总是往一台正在运行的 herdr 里装插件 —— 不在这里装，
# 装完按 prefix+f 什么都不会发生，直到下次重启 server（真 herdr TUI 实测）。
#
# 只装键位：[[keys.command]] 按 plugin_action id 解析，与插件落在哪个目录无关；而 build
# 跑在 herdr 注册插件之前，tab bar 条目里的绝对路径此时未必是最终位置，留给 startup hook。
# 键位先于注册写入并重载是安全的：按键时才解析 action（隔离 herdr 实测）。
#
# 冲突礼仪与 startup hook 一致：默认键被别的命令占用就整体跳过并说明，绝不覆盖。
# 恒 exit 0：build 失败会中止整个 install，键位装不上不值得挡住安装。
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
installer="${here}/install-keys.sh"
config="${HERDR_CONFIG_PATH:-${XDG_CONFIG_HOME:-${HOME:-/tmp}/.config}/herdr/config.toml}"
state="${XDG_STATE_HOME:-${HOME:-/tmp}/.local/state}/herdr/plugins/zzjcool%3Aforward"
logf="${state}/logs/postinstall.log"
mkdir -p "${state}/logs" 2>/dev/null || true

say() { printf 'herdr-forward: %s\n' "$*"; }
note() { printf '[%s] %s\n' "$(date -u +%FT%TZ 2>/dev/null || true)" "$*" >>"${logf}" 2>/dev/null || true; }
note "postinstall: cwd=${PWD} config=${config}"

if [[ ! -f ${installer} ]]; then
  say "缺少 ${installer}，跳过键位安装（herdr 下次启动时会自动补上）。"
  exit 0
fi

probe="$(bash "${installer}" --config "${config}" --dry-run 2>&1)"
probe_rc=$?
changed=0
if [[ ${probe_rc} -ne 0 ]]; then
  say "键位预检失败（rc=${probe_rc}），跳过；herdr 下次启动时会自动补上。"
  note "probe failed rc=${probe_rc}: ${probe}"
elif [[ ${probe} == *"already installed"* ]]; then
  note "keys already installed"
elif [[ ${probe} == *"is already bound"* ]]; then
  occupied="$(printf '%s\n' "${probe}" | sed -n "s/.*key '\([^']*\)' is already bound.*/\1/p" | sort -u | paste -sd ',' - || true)"
  say "默认键位 ${occupied:-prefix+f} 已被别的命令占用，未覆盖。换键：${here}/bootstrap.sh --add-key prefix+<你的键>"
  note "conflict: ${occupied}"
else
  if out="$(bash "${installer}" --config "${config}" 2>&1)"; then
    changed=1
    say "已装好键位：prefix+f 打开 Port Forward 面板（prefix+shift+f 列表，prefix+alt+f 探活）。"
    note "keys installed"
  else
    say "键位安装失败，跳过；herdr 下次启动时会自动补上。"
    note "install failed: ${out}"
  fi
fi

if [[ ${changed} -eq 1 ]]; then
  herdr_bin="$(command -v herdr 2>/dev/null || true)"
  reload=(server reload-config)
  if [[ -z ${herdr_bin} ]]; then
    say "找不到 herdr 命令；在 herdr 里执行 reload-config 后键位生效。"
  else
    if command -v timeout >/dev/null 2>&1; then
      timeout 10 "${herdr_bin}" "${reload[@]}" >/dev/null 2>&1
    else
      "${herdr_bin}" "${reload[@]}" >/dev/null 2>&1
    fi
    reload_rc=$?
    if [[ ${reload_rc} -eq 0 ]]; then
      say "已重载 herdr 配置：现在就可以按 prefix+f。"
      note "reloaded"
    else
      say "herdr 未在运行（或重载失败，rc=${reload_rc}）；下次启动 herdr 时键位即生效。"
      note "reload failed rc=${reload_rc}"
    fi
  fi
fi
exit 0
