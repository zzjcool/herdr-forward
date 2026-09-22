#!/usr/bin/env bash
# lib/machine.sh — LABEL -> ssh_target resolution.
# SCOUT-FACTS §2.1/§4: herdr's socket API exposes no machine/endpoint methods, so
# $HERDR_PLUGIN_CONFIG_DIR/machines.toml is the OFFICIAL path (not a fallback).
# Frozen API (ARCHITECTURE.md A.3):
#   machine_resolve <label>  -> stdout ssh_target (always "user@host[:port]"); die 4 on any failure
#   machines_toml_path       -> stdout config path
set -Eeuo pipefail

_TUNNEL_MACHINE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${_TUNNEL_MACHINE_LIB_DIR}/common.sh" ]]; then
  # shellcheck source=/dev/null
  source "${_TUNNEL_MACHINE_LIB_DIR}/common.sh"
fi

if ! declare -F log >/dev/null 2>&1; then
  log() {
    local level="${1}"
    shift
    local ts
    ts="$(date '+%Y-%m-%dT%H:%M:%S%z')"
    printf '[%s] %s %s\n' "${ts}" "${level}" "${*}" >&2
  }
fi
if ! declare -F die >/dev/null 2>&1; then
  die() {
    local code="${1}"
    shift
    log error "${*}"
    exit "${code}"
  }
fi

# machines_toml_path -> stdout: $HERDR_PLUGIN_CONFIG_DIR/machines.toml
machines_toml_path() {
  local dir="${HERDR_PLUGIN_CONFIG_DIR:-${XDG_CONFIG_HOME:-${HOME:-/tmp}/.config}/herdr-forward}"
  printf '%s\n' "${dir}/machines.toml"
}

# machine_normalize_ssh_target <target> -> stdout: target with an explicit :port
# (default 22). Keeps bracketed IPv6 literals intact.
machine_normalize_ssh_target() {
  local target="${1}"
  if [[ ${target} =~ ^(\[[0-9A-Fa-f:.]+\]):[0-9]+$ ]]; then
    printf '%s\n' "${target}"
    return 0
  fi
  if [[ ${target} =~ ^\[[0-9A-Fa-f:.]+\]$ ]]; then
    printf '%s:22\n' "${target}"
    return 0
  fi
  if [[ ${target} =~ ^[^:]+:[0-9]+$ ]]; then
    printf '%s\n' "${target}"
    return 0
  fi
  printf '%s:22\n' "${target}"
}

# machine_list_labels <toml> -> stdout: one label per line (sorted).
machine_list_labels() {
  local toml="${1}"
  local line label
  while IFS= read -r line; do
    if [[ ${line} =~ ^\[machines\.([A-Za-z0-9_.-]+)\][[:space:]]*$ ]]; then
      label="${BASH_REMATCH[1]}"
      printf '%s\n' "${label}"
    fi
  done <"${toml}"
}

# machine_resolve <label> -> stdout: ssh_target with explicit port; die 4 on failure.
machine_resolve() {
  local label="${1:-}"
  if [[ -z ${label} ]]; then
    die 4 "machine_resolve: missing label (usage: forward add 3000:3000 --machine LABEL)"
  fi

  local toml
  toml="$(machines_toml_path)"
  if [[ ! -f "${toml}" ]]; then
    die 4 "no machine config at ${toml}; create it, e.g.: printf '[machines.gpu-box]\\nssh_target = \"user@gpu-box.example.com:22\"\\n' >> ${toml}"
  fi
  if [[ ! -r "${toml}" ]]; then
    die 4 "machine config ${toml} is not readable; check its permissions (chmod 600 ${toml})"
  fi

  local found_section=0
  local ssh_target=""
  local line key value
  while IFS= read -r line; do
    [[ ${line} =~ ^[[:space:]]*(#.*)?$ ]] && continue
    if [[ ${line} =~ ^\[machines\.([A-Za-z0-9_.-]+)\][[:space:]]*$ ]]; then
      if [[ ${BASH_REMATCH[1]} == "${label}" ]]; then
        found_section=1
      else
        found_section=0
      fi
      continue
    fi
    if [[ ${line} =~ ^\[ ]]; then
      found_section=0
      continue
    fi
    ((found_section)) || continue
    if [[ ${line} =~ ^[[:space:]]*ssh_target[[:space:]]*=([[:space:]]*)(.*)$ ]]; then
      value="${BASH_REMATCH[2]}"
      value="${value%"${value##*[![:space:]]}"}"
      ssh_target="${value}"
      break
    fi
    if [[ ${line} =~ ^[[:space:]]*([A-Za-z0-9_-]+)[[:space:]]*= ]]; then
      key="${BASH_REMATCH[1]}"
      log debug "machine_resolve: ignoring unknown key '${key}' in [machines.${label}]"
      continue
    fi
  done <"${toml}"

  if ((!found_section)); then
    local available=""
    available="$(machine_list_labels "${toml}" | paste -sd ',' -)"
    if [[ -z ${available} ]]; then
      die 4 "machine '${label}' not found in ${toml}; add a [machines.${label}] section, e.g.: printf '[machines.${label}]\\nssh_target = \"user@host:22\"\\n' >> ${toml}"
    fi
    die 4 "machine '${label}' not found in ${toml}; available labels: ${available}"
  fi

  if [[ -z ${ssh_target} ]]; then
    die 4 "machine '${label}' in ${toml} has no ssh_target; add: ssh_target = \"user@host:22\""
  fi
  if [[ ! ${ssh_target} =~ ^\".*\"$ ]]; then
    die 4 "machine '${label}': ssh_target must be a quoted string, got ${ssh_target} (example: ssh_target = \"user@host:22\")"
  fi
  ssh_target="${ssh_target#\"}"
  ssh_target="${ssh_target%\"}"
  if [[ -z ${ssh_target} ]]; then
    die 4 "machine '${label}': ssh_target must be a quoted string, got ${ssh_target} (example: ssh_target = \"user@host:22\")"
  fi
  if [[ ! ${ssh_target} =~ ^[^@[:space:]]+@ ]]; then
    die 4 "machine '${label}': ssh_target '${ssh_target}' must look like user@host[:port]"
  fi

  machine_normalize_ssh_target "${ssh_target}"
}
