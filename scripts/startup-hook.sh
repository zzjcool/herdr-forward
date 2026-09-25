#!/bin/sh
here="$(CDPATH="" cd -- "$(dirname -- "$0")/.." && pwd)"
src="${HERDR_FORWARD_SOURCE_ROOT:-${here}}"
[ -f "${src}/go/go.mod" ] || src="${PWD:-.}"
bin="${HERDR_FORWARD_BIN:-${here}/bin/forward-go}"
if [ -x "${bin}" ]; then
  HERDR_PLUGIN_ROOT="${HERDR_PLUGIN_ROOT:-${here}}" "${bin}" internal startup-hook "$@" || printf '%s\n' 'herdr-forward: startup-hook failed; server continues.' >&2
  exit 0
fi
if command -v go >/dev/null 2>&1 && [ -f "${src}/go/go.mod" ]; then
  (cd "${src}/go" && HERDR_PLUGIN_ROOT="${HERDR_PLUGIN_ROOT:-${here}}" GOFLAGS=-mod=vendor go run ./cmd/forward internal startup-hook "$@") || true
  exit 0
fi
printf '%s\n' 'herdr-forward: forward-go 缺失；请先在插件根目录运行 make build。' >&2
exit 0
