#!/bin/sh
set -u
here="$(CDPATH="" cd -- "$(dirname -- "$0")/.." && pwd)"
src="${HERDR_FORWARD_SOURCE_ROOT:-${here}}"
[ -f "${src}/go/go.mod" ] || src="${PWD:-.}"
bin="${HERDR_FORWARD_BIN:-${here}/bin/forward-go}"
if [ -x "${bin}" ]; then HERDR_PLUGIN_ROOT="${HERDR_PLUGIN_ROOT:-${here}}" exec "${bin}" internal install-tabbar "$@"; fi
if command -v go >/dev/null 2>&1 && [ -f "${src}/go/go.mod" ]; then
  (cd "${src}/go" && HERDR_PLUGIN_ROOT="${HERDR_PLUGIN_ROOT:-${here}}" GOFLAGS=-mod=vendor exec go run ./cmd/forward internal install-tabbar "$@")
  exit $?
fi
printf '%s\n' 'herdr-forward: forward-go 缺失；请先在插件根目录运行 make build。' >&2
exit 1
