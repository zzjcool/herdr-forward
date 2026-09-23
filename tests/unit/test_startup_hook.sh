#!/usr/bin/env bash
# tests/unit/test_startup_hook.sh — OOTB：scripts/startup-hook.sh（[[startup]] 钩子）
#
# 职责（任务 §3）：server 侧 link/enable 后自动把 tab bar 条目装上（同机用户零操作）；
# 跨机（server 与 client 不同机）时物理上够不到 client 的 config → 诚实降级为日志提示，
# 绝不报错、绝不阻塞 server。
#
# 覆盖：同机自动安装 / 幂等（跑两次只装一次）/ 已装则跳过 / dry-run 不落盘 /
#       降级路径（无法确定 config 或写失败 → exit 0 + 提示）/ 显式 --config 覆盖。
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="${ROOT}/scripts/startup-hook.sh"

if [[ -f "${ROOT}/tests/lib/assertions.sh" ]]; then
  # shellcheck source=/dev/null
  source "${ROOT}/tests/lib/assertions.sh"
fi
if ! declare -F t_fail_note >/dev/null 2>&1; then
  t_fail_note() { t_fail "$@"; }
fi

if [[ ! -x "${HOOK}" ]]; then
  echo "RED: ${HOOK} 不存在或不可执行（startup hook 尚未实现）" >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

rc=0
out=""
err=""

# run_hook [args...] —— 在干净的 env 下跑 hook（默认隔离 HOME，绝不碰真实 ~/.config）
# env -u HERDR_CONFIG_PATH：宿主若设了它，会盖过 XDG/HOME 默认，破坏「默认路径」用例
run_hook() {
  rc=0
  out="$(env -u HERDR_CONFIG_PATH \
    HOME="${WORK}/home" XDG_CONFIG_HOME="${WORK}/home/.config" \
    HERDR_PLUGIN_ROOT="${ROOT}" HERDR_PLUGIN_STATE_DIR="${WORK}/state" \
    HERDR_PLUGIN_EVENT=startup \
    bash "${HOOK}" "$@" 2>"${WORK}/stderr")" || rc=$?
  err="$(cat "${WORK}/stderr")"
}

md5() { md5sum "$1" | awk '{print $1}'; }

tabbar_count() {
  python3 - "$1" <<'PY'
import sys, tomllib, os
if not os.path.exists(sys.argv[1]):
    print(0)
    raise SystemExit(0)
try:
    with open(sys.argv[1], "rb") as fh:
        doc = tomllib.load(fh)
except Exception:
    print(0)
    raise SystemExit(0)
print(sum(1 for e in ((doc.get("ui") or {}).get("tab_bar_right") or [])
          if isinstance(e, dict) and "bin/forward" in str(e.get("command", ""))))
PY
}

mkdir -p "${WORK}/home/.config/herdr"
DEFAULT_CONFIG="${WORK}/home/.config/herdr/config.toml"

t_describe "startup-hook.sh（同机自动安装 tab bar）"

t_it "裸跑：在 XDG_CONFIG_HOME/herdr/config.toml 自动装 tab bar 条目"
printf 'theme = "dark"\n' >"${DEFAULT_CONFIG}"
run_hook
t_exit_ok 0 "${rc}" "退出 0（startup 失败不得阻塞 server）"
tb="$(tabbar_count "${DEFAULT_CONFIG}")"
t_eq "1" "${tb}" "自动装好 tab bar 条目"
t_file_exists "${WORK}/state/logs/forward.log"

t_it "幂等：再跑两次仍只有 1 条，内容不变"
before="$(md5 "${DEFAULT_CONFIG}")"
run_hook
run_hook
t_exit_ok 0 "${rc}" "重复运行退出 0"
after="$(md5 "${DEFAULT_CONFIG}")"
t_eq "${before}" "${after}" "重复运行未改文件"
tb2="$(tabbar_count "${DEFAULT_CONFIG}")"
t_eq "1" "${tb2}" "仍只有 1 条"

t_it "已有条目（用户手装）→ 不重复插入、不备份、退出 0"
config2="${WORK}/preinstalled.toml"
cat >"${config2}" <<'EOF'
theme = "dark"

[ui]
tab_bar_right = [
  # herdr-forward: tab bar status entry (managed by scripts/install-tabbar.sh)
  { type = "command", command = "\"$HERDR_PLUGIN_ROOT/bin/forward\" list --oneline", interval_seconds = 5, timeout_seconds = 2 },
]
EOF
before2="$(md5 "${config2}")"
run_hook --config "${config2}"
t_exit_ok 0 "${rc}" "退出 0"
after2="$(md5 "${config2}")"
t_eq "${before2}" "${after2}" "内容未变"
bak2="$(find "${WORK}" -maxdepth 1 -name 'preinstalled.toml.bak.*' -print -quit)"
t_eq "" "${bak2}" "未产生备份"

t_it "config 不存在 → 创建目录与文件（同机首次 link 场景）"
fresh="${WORK}/fresh/.config/herdr/config.toml"
run_hook --config "${fresh}"
t_exit_ok 0 "${rc}" "退出 0"
t_file_exists "${fresh}"
tb_fresh="$(tabbar_count "${fresh}")"
t_eq "1" "${tb_fresh}" "新文件里装好 1 条"

t_it "--dry-run：不落盘、不建备份、exit 0"
config3="${WORK}/dry.toml"
printf 'theme = "dark"\n' >"${config3}"
before3="$(md5 "${config3}")"
run_hook --config "${config3}" --dry-run
t_exit_ok 0 "${rc}" "退出 0"
after3="$(md5 "${config3}")"
t_eq "${before3}" "${after3}" "未改文件"
bak3="$(find "${WORK}" -maxdepth 1 -name 'dry.toml.bak.*' -print -quit)"
t_eq "" "${bak3}" "未建备份"

t_describe "startup-hook.sh（跨机降级路径：诚实提示，不报错）"

t_it "非法 TOML → 降级：exit 0（不阻塞 server）+ 日志提示，原文件不破坏"
config4="${WORK}/broken.toml"
printf 'this is = = not toml\n' >"${config4}"
before4="$(cat "${config4}")"
run_hook --config "${config4}"
t_exit_ok 0 "${rc}" "非法 TOML 下仍 exit 0（startup 不得打断 server）"
after4="$(cat "${config4}")"
t_eq "${before4}" "${after4}" "原文件未被破坏"
t_match "skip|跳过|失败|degrade|降级|warn" "${err}" "stderr/log 有降级提示"

t_it "config 目录不可写 → 降级 exit 0 + 提示（不报错）"
if [[ "${EUID}" -eq 0 ]]; then
  t_skip "以 root 运行，chmod 000 无法构造不可写场景"
else
  ro_dir="${WORK}/ro"
  mkdir -p "${ro_dir}"
  chmod 500 "${ro_dir}"
  run_hook --config "${ro_dir}/config.toml"
  chmod 700 "${ro_dir}"
  t_exit_ok 0 "${rc}" "不可写时仍 exit 0"
  t_match "无法|失败|cannot|降级|skip" "${err}" "提示无法写入"
fi

t_it "无法确定 config 路径（HOME 未设且无 XDG）→ 降级 exit 0 + 说明"
rc=0
out="$(env -u HOME -u XDG_CONFIG_HOME -u HERDR_CONFIG_PATH HERDR_PLUGIN_ROOT="${ROOT}" \
  HERDR_PLUGIN_STATE_DIR="${WORK}/state2" HERDR_PLUGIN_EVENT=startup \
  bash "${HOOK}" 2>"${WORK}/stderr")" || rc=$?
err="$(cat "${WORK}/stderr")"
t_exit_ok 0 "${rc}" "无 HOME 时 exit 0"
t_match "HOME|config|路径" "${err}" "说明为何跳过"

t_describe "startup-hook.sh（跨机场景：不误改本机无关文件）"

t_it "跨机（client config 在别处）只有显式 --config 才会写；默认只碰本机 config"
# 模拟：HERDR_PLUGIN_STATE_DIR 指向 server 状态目录，client config 完全不在本机可达范围。
# hook 的行为契约 = 只处理能解析到的本机 config；跨机时需要用户/脚本在 A 上显式指定。
config5="${WORK}/cross-local.toml"
printf 'theme = "dark"\n' >"${config5}"
run_hook --config "${config5}"
t_exit_ok 0 "${rc}" "退出 0"
tb5="$(tabbar_count "${config5}")"
t_eq "1" "${tb5}" "写的是被显式指定的文件"
tb_def="$(tabbar_count "${DEFAULT_CONFIG}")"
t_eq "1" "${tb_def}" "默认 config 未被再次改动（仍 1 条）"

t_it "HERDR_CONFIG_PATH 优先于 XDG/HOME 默认（herdr 注入路径）"
cfg_env="${WORK}/from-env.toml"
printf 'theme = "dark"\n' >"${cfg_env}"
rc=0
out="$(env HOME="${WORK}/home" XDG_CONFIG_HOME="${WORK}/home/.config" \
  HERDR_CONFIG_PATH="${cfg_env}" HERDR_PLUGIN_ROOT="${ROOT}" \
  HERDR_PLUGIN_STATE_DIR="${WORK}/state3" HERDR_PLUGIN_EVENT=startup \
  bash "${HOOK}" 2>"${WORK}/stderr")" || rc=$?
err="$(cat "${WORK}/stderr")"
t_exit_ok 0 "${rc}" "退出 0"
tb_env="$(tabbar_count "${cfg_env}")"
t_eq "1" "${tb_env}" "写的是 HERDR_CONFIG_PATH 指定的文件"

t_it "--config 显式参数优先于 HERDR_CONFIG_PATH"
cfg_env2="${WORK}/env2.toml"
cfg_exp="${WORK}/explicit2.toml"
printf 'theme = "dark"\n' >"${cfg_env2}"
printf 'theme = "dark"\n' >"${cfg_exp}"
rc=0
out="$(env HOME="${WORK}/home" XDG_CONFIG_HOME="${WORK}/home/.config" \
  HERDR_CONFIG_PATH="${cfg_env2}" HERDR_PLUGIN_ROOT="${ROOT}" \
  HERDR_PLUGIN_STATE_DIR="${WORK}/state3" HERDR_PLUGIN_EVENT=startup \
  bash "${HOOK}" --config "${cfg_exp}" 2>/dev/null)" || rc=$?
t_exit_ok 0 "${rc}" "退出 0"
explicit_tb="$(tabbar_count "${cfg_exp}")"
env2_tb="$(tabbar_count "${cfg_env2}")"
t_eq "1" "${explicit_tb}" "--config 指定的文件被写入"
t_eq "0" "${env2_tb}" "HERDR_CONFIG_PATH 的文件未被触碰"

t_it "输出含跨机说明（提醒 client 侧需自行 bootstrap）"
run_hook --config "${config5}"
t_match "bootstrap|client|跨机|另一台|remote" "${out}" "有跨机指引提示"

t_it "--help 可用且 exit 0"
rc=0
out="$(bash "${HOOK}" --help 2>/dev/null)" || rc=$?
t_exit_ok 0 "${rc}" "--help 退出 0"
t_match "config" "${out}" "--help 提到 --config"

t_it "未知参数 → 不致命（startup 上下文里丢日志比 abort 好）"
run_hook --bogus-flag
t_exit_ok 0 "${rc}" "未知参数下仍 exit 0（startup 容错）"

t_done
