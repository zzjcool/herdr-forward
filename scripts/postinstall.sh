#!/bin/sh
# herdr-forward release bootstrap: download the platform binary before Go exists.
set -eu

here="$(CDPATH="" cd -- "$(dirname -- "$0")/.." && pwd)" || exit 1
bin_dir=${here}/bin
forward_go=${bin_dir}/forward-go
tmpdir=

say() {
  printf '%s\n' "$*"
}

manual_hint() {
  printf '%s\n' '手动恢复：' >&2
  printf '%s\n' '  git clone https://github.com/zzjcool/herdr-forward' >&2
  printf '%s\n' '  cd herdr-forward && make build' >&2
  printf '%s\n' '  或检查网络后重新运行 herdr plugin install zzjcool/herdr-forward' >&2
}

fail_install() {
  printf 'herdr-forward: %s\n' "$1" >&2
  manual_hint
  exit 1
}

# shellcheck disable=SC2317,SC2329 # cleanup is invoked by the EXIT/signal trap.
cleanup() {
  if [ -n "${tmpdir}" ]; then
    if [ -d "${tmpdir}" ]; then
      rm -rf "${tmpdir}"
    fi
  fi
}
trap cleanup 0 1 2 3 15

download_file() {
  download_url=$1
  download_path=$2
  if command -v curl >/dev/null 2>&1; then
    if curl -fsSL "${download_url}" -o "${download_path}"; then
      return 0
    fi
  fi
  if command -v wget >/dev/null 2>&1; then
    if wget -qO "${download_path}" "${download_url}"; then
      return 0
    fi
  fi
  return 1
}

install_release_binary() {
  version=$(sed -n 's/^[[:space:]]*version[[:space:]]*=[[:space:]]*"\([^"]*\)".*$/\1/p' "${here}/herdr-plugin.toml" | head -n 1)
  [ -n "${version}" ] || fail_install '无法从 herdr-plugin.toml 读取版本号。'

  system=$(uname -s 2>/dev/null || printf 'unknown')
  machine=$(uname -m 2>/dev/null || printf 'unknown')
  case "${system}:${machine}" in
  Linux:x86_64 | Linux:amd64) platform=linux_amd64 ;;
  Linux:aarch64 | Linux:arm64) platform=linux_arm64 ;;
  Darwin:x86_64 | Darwin:amd64) platform=darwin_amd64 ;;
  Darwin:arm64 | Darwin:aarch64) platform=darwin_arm64 ;;
  *) fail_install "不支持的平台：${system}/${machine}（需要 linux/darwin × amd64/arm64）。" ;;
  esac

  archive_name="herdr-forward_${version}_${platform}.tar.gz"
  base=${HERDR_FORWARD_BIN_BASE:-https://github.com/zzjcool/herdr-forward/releases/latest/download}
  base=${base%/}
  tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/herdr-forward-install.XXXXXX") || fail_install '无法创建下载临时目录。'
  archive_path=${tmpdir}/${archive_name}
  checksum_path=${tmpdir}/checksums.txt
  extract_dir=${tmpdir}/extract
  mkdir -p "${extract_dir}"

  say "herdr-forward: 下载 ${archive_name}"
  set +e
  download_file "${base}/${archive_name}" "${archive_path}"
  download_rc=$?
  set -e
  if [ "${download_rc}" -ne 0 ]; then
    fail_install "无法下载 ${base}/${archive_name}（需要 curl 或 wget，并检查网络/镜像）。"
  fi
  set +e
  download_file "${base}/checksums.txt" "${checksum_path}"
  download_rc=$?
  set -e
  if [ "${download_rc}" -ne 0 ]; then
    fail_install "无法下载 ${base}/checksums.txt，拒绝安装未校验的二进制。"
  fi

  expected=$(awk -v wanted="${archive_name}" '
    {
      name = $2
      sub(/^\*/, "", name)
      if (name == wanted) { print $1; exit }
    }
  ' "${checksum_path}")
  case "${expected}" in
  "" | *[!0123456789abcdefABCDEF]*) fail_install "checksums.txt 中没有 ${archive_name} 的有效 SHA-256。" ;;
  *) : ;;
  esac
  expected_length=$(printf '%s' "${expected}" | awk '{print length}')
  [ "${expected_length}" = 64 ] || fail_install "${archive_name} 的 SHA-256 长度不正确。"

  if command -v sha256sum >/dev/null 2>&1; then
    actual=$(sha256sum "${archive_path}" | awk '{print $1}')
  elif command -v shasum >/dev/null 2>&1; then
    actual=$(shasum -a 256 "${archive_path}" | awk '{print $1}')
  else
    fail_install '缺少 sha256sum 或 shasum，无法校验 Release。'
  fi
  actual=$(printf '%s' "${actual}" | tr '[:upper:]' '[:lower:]')
  expected=$(printf '%s' "${expected}" | tr '[:upper:]' '[:lower:]')
  [ "${actual}" = "${expected}" ] || fail_install "${archive_name} SHA-256 校验失败（expected=${expected}, actual=${actual}）。"

  if tar -xzf "${archive_path}" -C "${extract_dir}"; then
    :
  else
    fail_install "无法解包 ${archive_name}。"
  fi
  candidate=$(find "${extract_dir}" -type f -name forward -print | head -n 1)
  [ -n "${candidate}" ] || fail_install "${archive_name} 不含可执行文件 forward。"
  chmod 0755 "${candidate}"
  mkdir -p "${bin_dir}"
  mv -f "${candidate}" "${forward_go}" || fail_install "无法安装二进制到 ${forward_go}。"
  say "herdr-forward: 已安装 ${forward_go}（${version}/${platform}）。"
}

if [ "${HERDR_FORWARD_SKIP_DOWNLOAD:-0}" = 1 ]; then
  say 'herdr-forward: HERDR_FORWARD_SKIP_DOWNLOAD=1，跳过 Release 下载。'
  [ -x "${forward_go}" ] || fail_install "已要求跳过下载，但 ${forward_go} 不存在。"
else
  install_release_binary
fi

[ -x "${forward_go}" ] || fail_install "安装后仍缺少 ${forward_go}。"
if HERDR_PLUGIN_ROOT=${HERDR_PLUGIN_ROOT:-${here}} "${here}/bin/forward" internal install-keys "$@"; then
  :
else
  fail_install '键位安装失败。请检查 herdr config.toml 权限后重试。'
fi

if command -v herdr >/dev/null 2>&1; then
  if herdr server reload-config; then
    say 'herdr-forward: 已重载 herdr 配置；现在就可以按 prefix+f。'
  else
    say 'herdr-forward: herdr server reload-config 失败；请手动运行 reload-config。' >&2
  fi
else
  say 'herdr-forward: 找不到 herdr 命令；请在 herdr 里执行 reload-config 后键位生效。'
fi
exit 0
