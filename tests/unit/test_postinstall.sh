#!/usr/bin/env bash
# Release postinstall tests: download, checksum failure, missing fetcher and offline mode.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${ROOT}/tests/assertions.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/postinstall-release.XXXXXX")"
PLUGIN="${WORK}/plugin"
mkdir -p "${PLUGIN}/bin" "${PLUGIN}/scripts" "${WORK}/home/.config/herdr" "${WORK}/release"
cp "${ROOT}/bin/forward" "${PLUGIN}/bin/forward"
cp "${ROOT}/scripts/postinstall.sh" "${PLUGIN}/scripts/postinstall.sh"
cp "${ROOT}/herdr-plugin.toml" "${PLUGIN}/herdr-plugin.toml"
chmod 0755 "${PLUGIN}/bin/forward" "${PLUGIN}/scripts/postinstall.sh"

# Build/use a real Go CLI for an archive with the same shape as GoReleaser.
GO_ARCHIVE_BIN="${WORK}/release/forward"
if [[ -x "${ROOT}/bin/forward-go" ]]; then
  cp "${ROOT}/bin/forward-go" "${GO_ARCHIVE_BIN}"
else
  (cd "${ROOT}/go" && GOFLAGS=-mod=vendor go build -o "${GO_ARCHIVE_BIN}" ./cmd/forward)
fi
chmod 0755 "${GO_ARCHIVE_BIN}"
ARCHIVE="herdr-forward_0.2.0_linux_amd64.tar.gz"
tar -czf "${WORK}/release/${ARCHIVE}" -C "${WORK}/release" forward
HASH="$(sha256sum "${WORK}/release/${ARCHIVE}" | awk '{print $1}')"
printf '%s  %s\n' "${HASH}" "${ARCHIVE}" >"${WORK}/release/checksums.txt"

PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
(cd "${WORK}/release" && python3 -m http.server "${PORT}" --bind 127.0.0.1 >/dev/null 2>&1) &
HTTP_PID=$!
CALLS="${WORK}/herdr-calls"
trap 'kill "${HTTP_PID}" 2>/dev/null || true; rm -rf "${WORK}"' EXIT
BASE="http://127.0.0.1:${PORT}"
for _ in {1..50}; do
  if python3 - "${PORT}" <<'PY'; then
import socket
import sys
s = socket.socket()
s.settimeout(0.1)
try:
    s.connect(("127.0.0.1", int(sys.argv[1])))
except OSError:
    raise SystemExit(1)
finally:
    s.close()
PY
    break
  fi
  sleep 0.1
done

cat >"${WORK}/herdr" <<EOF
#!/bin/sh
printf '%s\\n' "\$*" >>"${CALLS}"
exit "\${HF_RELOAD_RC:-0}"
EOF
chmod 0755 "${WORK}/herdr"

run_postinstall() {
  out=""
  err=""
  rc=0
  out="$(env -u HERDR_PLUGIN_ROOT -u HERDR_PLUGIN_STATE_DIR \
    HOME="${WORK}/home" XDG_CONFIG_HOME="${WORK}/home/.config" \
    HERDR_FORWARD_BIN_BASE="${BASE}" PATH="${WORK}:${PATH}" \
    sh "${PLUGIN}/scripts/postinstall.sh" 2>"${WORK}/stderr")" || rc=$?
  err="$(cat "${WORK}/stderr")"
}

t_describe "Release 下载与校验"
t_it "下载 archive + checksums，安装 forward-go，装键位并 reload"
rm -f "${PLUGIN}/bin/forward-go" "${CALLS}" "${WORK}/home/.config/herdr/config.toml"
printf 'theme = "dark"\n' >"${WORK}/home/.config/herdr/config.toml"
run_postinstall
t_exit_ok 0 "${rc}" "正常安装 exit 0"
t_file_exists "${PLUGIN}/bin/forward-go" "下载的二进制存在"
if [[ -x "${PLUGIN}/bin/forward-go" ]]; then
  t_pass "下载的二进制可执行"
else
  t_fail "下载的二进制不可执行"
fi
key_count="$(grep -c '^command = "zzjcool:forward\.' "${WORK}/home/.config/herdr/config.toml" || true)"
t_eq 3 "${key_count}" "安装器写入 3 条键位"
call_log="$(cat "${CALLS}")"
t_match 'server reload-config' "${call_log}" "继续 reload-config"

t_describe "失败路径"
t_it "checksum 不符 exit 1 + 手动恢复指引"
printf '%064d  %s\n' 0 "${ARCHIVE}" >"${WORK}/release/checksums.txt"
rm -f "${PLUGIN}/bin/forward-go"
run_postinstall
t_exit_ok 1 "${rc}" "checksum 失败 exit 1"
t_contains "SHA-256 校验失败" "${err}" "明确指出校验失败"
t_contains "git clone" "${err}" "给出手动恢复路径"
t_file_absent "${PLUGIN}/bin/forward-go" "校验失败不落盘二进制"

t_it "curl/wget 都不存在 exit 1 + 依赖指引"
printf '%s  %s\n' "${HASH}" "${ARCHIVE}" >"${WORK}/release/checksums.txt"
rm -f "${PLUGIN}/bin/forward-go"
NO_FETCH="${WORK}/no-fetch"
mkdir -p "${NO_FETCH}"
for tool in sh sed head uname mktemp mkdir awk sha256sum tar find chmod mv rm tr cat dirname; do
  tool_path=""
  if tool_path="$(command -v "${tool}")"; then
    ln -sf "${tool_path}" "${NO_FETCH}/${tool}"
  fi
done
rc=0
out=""
err=""
env -u HERDR_PLUGIN_ROOT -u HERDR_PLUGIN_STATE_DIR HOME="${WORK}/home" \
  XDG_CONFIG_HOME="${WORK}/home/.config" HERDR_FORWARD_BIN_BASE="${BASE}" \
  PATH="${NO_FETCH}" sh "${PLUGIN}/scripts/postinstall.sh" >"${WORK}/no-fetch.out" 2>"${WORK}/no-fetch.err" || rc=$?
out="$(cat "${WORK}/no-fetch.out")"
err="$(cat "${WORK}/no-fetch.err")"
t_exit_ok 1 "${rc}" "无下载器 exit 1"
t_contains "curl 或 wget" "${err}" "指出需要 curl/wget"
t_contains "make build" "${err}" "无下载器也给恢复指引"

t_describe "离线开发"
t_it "HERDR_FORWARD_SKIP_DOWNLOAD=1 不访问镜像并继续安装键位"
cp "${GO_ARCHIVE_BIN}" "${PLUGIN}/bin/forward-go"
chmod 0755 "${PLUGIN}/bin/forward-go"
rm -f "${CALLS}"
printf 'theme = "dark"\n' >"${WORK}/home/.config/herdr/config.toml"
rc=0
out=""
err=""
out="$(env HERDR_FORWARD_SKIP_DOWNLOAD=1 HERDR_FORWARD_BIN_BASE="${WORK}/does-not-exist" \
  HERDR_PLUGIN_ROOT="${PLUGIN}" HOME="${WORK}/home" XDG_CONFIG_HOME="${WORK}/home/.config" \
  PATH="${WORK}:${PATH}" sh "${PLUGIN}/scripts/postinstall.sh" 2>"${WORK}/skip.err")" || rc=$?
err="$(cat "${WORK}/skip.err")"
t_exit_ok 0 "${rc}" "SKIP_DOWNLOAD exit 0"
t_contains "SKIP_DOWNLOAD=1" "${out}" "明确报告跳过下载"
t_file_exists "${PLUGIN}/bin/forward-go" "离线使用已有二进制"
call_log="$(cat "${CALLS}")"
t_match 'server reload-config' "${call_log}" "离线路径仍 reload-config"

t_done
