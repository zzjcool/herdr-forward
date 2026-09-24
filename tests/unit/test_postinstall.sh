#!/usr/bin/env bash
# tests/unit/test_postinstall.sh — scripts/postinstall.sh（herdr plugin install 的 [[build]] 步骤）
#
# 场景来源：用户往**正在运行**的 herdr 里装插件后按 prefix+f 没反应 —— startup hook 只在
# server 启动时跑。build 步骤负责当场装键位并重载 server。
# 覆盖：首次安装装键位 + 重载 / 重装幂等不重载 / 键位冲突不覆盖 / herdr 缺失或未运行 /
#   恒 exit 0（build 失败会中止 install）/ manifest 声明了该 build 步骤。
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
source "${ROOT}/tests/lib/assertions.sh"

unset HERDR_SOCKET_PATH HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_BIN_PATH HERDR_ENV HERDR_CONFIG_PATH

WORK="$(mktemp -d "${TMPDIR:-/tmp}/postinstall.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT
CONFIG="${WORK}/home/.config/herdr/config.toml"
CALLS="${WORK}/herdr-calls"
mkdir -p "${WORK}/home/.config/herdr" "${WORK}/bin"

# 假 herdr：记录调用；HF_RELOAD_RC 控制 reload 的退出码
cat >"${WORK}/bin/herdr" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"${CALLS}"
exit "\${HF_RELOAD_RC:-0}"
EOF
chmod +x "${WORK}/bin/herdr"

out=""
rc=0

# postinstall [PATH]：像 herdr 跑 build 那样在插件根目录下执行（无任何 HERDR_* 运行时变量）
postinstall() {
  local path="${1:-${WORK}/bin:/usr/bin:/bin}"
  : >"${CALLS}"
  # shellcheck disable=SC2016 # $1 由内层 bash 展开（插件根作为参数传入）
  run env -u HERDR_PLUGIN_ID HOME="${WORK}/home" XDG_CONFIG_HOME="${WORK}/home/.config" \
    XDG_STATE_HOME="${WORK}/home/.local/state" PATH="${path}" \
    bash -c 'cd "$1" && bash scripts/postinstall.sh' _ "${ROOT}"
}
key_count() {
  grep -c '^command = "zzjcool:forward\.' "${CONFIG}" 2>/dev/null || true
}
reloads() {
  grep -c '^server reload-config$' "${CALLS}" 2>/dev/null || true
}

t_describe "manifest 声明了 build 步骤"
t_it "herdr-plugin.toml 的 [[build]] 运行 scripts/postinstall.sh"
build_cmd="$(python3 -c 'import sys, tomllib; d = tomllib.load(open(sys.argv[1], "rb")); print(" ".join(b["command"] for b in d.get("build", []) for b in [b] if False) or " ".join(d["build"][0]["command"]))' "${ROOT}/herdr-plugin.toml")"
t_eq "bash scripts/postinstall.sh" "${build_cmd}" "build 命令"

t_describe "首次安装：装键位并重载运行中的 herdr"
printf 'theme = "dark"\n' >"${CONFIG}"
postinstall
t_exit_ok 0 "${rc}" "exit 0"
n="$(key_count)"
t_eq "3" "${n}" "写入 3 条本插件键位"
n="$(reloads)"
t_eq "1" "${n}" "调用 herdr server reload-config 一次"
t_contains "现在就可以按 prefix+f" "${out}" "告诉用户可以直接用"

t_describe "重装（更新插件）：键位已在，不重复写、不重载"
before="$(md5sum "${CONFIG}" | cut -d' ' -f1)"
postinstall
t_exit_ok 0 "${rc}" "exit 0"
after="$(md5sum "${CONFIG}" | cut -d' ' -f1)"
t_eq "${before}" "${after}" "config 未改动"
n="$(reloads)"
t_eq "0" "${n}" "未重载"

t_describe "默认键被别的命令占用：不覆盖，说明换键方法"
printf '[[keys.command]]\nkey = "prefix+f"\ntype = "shell"\ncommand = "echo mine"\n' >"${CONFIG}"
before="$(md5sum "${CONFIG}" | cut -d' ' -f1)"
postinstall
t_exit_ok 0 "${rc}" "exit 0"
after="$(md5sum "${CONFIG}" | cut -d' ' -f1)"
t_eq "${before}" "${after}" "用户的绑定原样保留"
t_contains "已被别的命令占用" "${out}" "说明冲突"
t_contains "bootstrap.sh --add-key" "${out}" "给出换键命令"

t_describe "herdr 不在 PATH / 未运行：键位照装，提示稍后生效，仍 exit 0"
printf 'theme = "dark"\n' >"${CONFIG}"
# 除 herdr 以外的全部 /usr/bin 工具（Arch 的 /bin 就是 /usr/bin，不能靠去掉目录来藏 herdr）
mkdir -p "${WORK}/noherdr"
ln -s /usr/bin/* "${WORK}/noherdr/" 2>/dev/null || true
rm -f "${WORK}/noherdr/herdr"
postinstall "${WORK}/noherdr"
t_exit_ok 0 "${rc}" "exit 0"
t_contains "找不到 herdr 命令" "${out}" "提示需要手动 reload"
n="$(key_count)"
t_eq "3" "${n}" "键位照装"
printf 'theme = "dark"\n' >"${CONFIG}"
HF_RELOAD_RC=1 postinstall
t_exit_ok 0 "${rc}" "reload 失败也 exit 0（不能挡住 install）"
n="$(key_count)"
t_eq "3" "${n}" "键位仍已写入"
t_contains "下次启动 herdr 时键位即生效" "${out}" "说明何时生效"

t_done
