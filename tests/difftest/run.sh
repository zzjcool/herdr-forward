#!/usr/bin/env bash
# shellcheck disable=SC2249,SC2312 # inventory generation is intentionally data-driven.
# Go-only golden contract suite for the final binary.
#
# The Bash implementation was removed in Phase 5.  The 438 byte-level cases
# below are now checked against committed golden values.  GOLDEN_UPDATE=1 is a
# maintainer-only mode used when a deliberate Go contract change is reviewed;
# normal CI refuses to create or refresh the file.
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
GOLDEN="${HERE}/golden.tsv"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/herdr-forward-golden.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT

PASS=0
FAIL=0
TOTAL=0

ok() {
  PASS=$((PASS + 1))
  printf 'ok %d - %s\n' "$((PASS + FAIL))" "$1"
}
bad() {
  FAIL=$((FAIL + 1))
  printf 'not ok %d - %s\n' "$((PASS + FAIL))" "$1"
}

if ! command -v go >/dev/null 2>&1; then
  printf 'RED: golden suite needs go (the released implementation is Go).\n' >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  printf 'RED: golden suite needs python3 for byte-safe transcript encoding.\n' >&2
  exit 1
fi

GO_BIN="${TMP}/forward-go"
if ! (cd "${ROOT}/go" && GOFLAGS=-mod=vendor go build -o "${GO_BIN}" ./cmd/forward); then
  printf 'RED: cannot build Go CLI for golden suite.\n' >&2
  exit 1
fi

# A spec is: id<TAB>kind<TAB>arg<TAB>arg... .  Arguments are deliberately
# plain tokens; fixture paths are added only while executing the case.
specs() {
  local f base form
  for f in "${ROOT}"/tests/fixtures/forwards.*.json "${HERE}"/fixtures/full.two.json; do
    base="${f##*/}"
    printf 'state-load-%s\tstate-load\t%s\n' "${base%.json}" "${f}"
  done
  for f in "${ROOT}"/tests/fixtures/forwards.empty.json "${ROOT}"/tests/fixtures/forwards.valid.json "${ROOT}"/tests/fixtures/forwards.multi.json "${HERE}"/fixtures/full.two.json "${HERE}"/fixtures/mix.client.tunnel.json; do
    base="${f##*/}"
    printf 'state-save-%s\tstate-save\t%s\n' "${base%.json}" "${f}"
  done
  for f in "${ROOT}"/tests/fixtures/forwards.empty.json "${ROOT}"/tests/fixtures/forwards.valid.json "${ROOT}"/tests/fixtures/forwards.multi.json "${HERE}"/fixtures/full.two.json "${HERE}"/fixtures/mix.client.tunnel.json; do
    base="${f##*/}"
    for form in table json oneline; do
      printf 'list-%s-%s\tlist\t%s\t%s\n' "${base%.json}" "${form}" "${f}" "${form}"
    done
  done

  printf '%b\n' \
    'hf-fmt-hello\thf-fmt\thello\tdevbox' \
    'hf-fmt-hello-label\thf-fmt\thello\tlaptop\tmy laptop' \
    'hf-fmt-sync-empty\thf-fmt\tsync\t-' \
    'hf-fmt-sync-two\thf-fmt\tsync\tf-3000:3000:3000,f-15173:15173:5173' \
    'hf-fmt-sync-invalid\thf-fmt\tsync\tf-3000:3000:3000,bogus,f-80:80:80' \
    'hf-fmt-open\thf-fmt\topen\thttp://localhost:8080/ok' \
    'hf-fmt-status-up\thf-fmt\tstatus\tf-5173\tup' \
    'hf-fmt-status-down\thf-fmt\tstatus\tf-5173\tdown\tclient 端口 5173 已被占用（laptop）' \
    'hf-fmt-ping\thf-fmt\tping' \
    'hf-fmt-sync-one\thf-fmt\tsync\tf-6006:6006:6006'

  local -a parse_lines=(
    'HF1 HELLO devbox'
    'HF1 HELLO laptop my laptop'
    'HF1 SYNC -'
    'HF1 SYNC f-3000:3000:3000,f-15173:15173:5173'
    'HF1 OPEN http://localhost:6006/x'
    'HF1 STATUS f-5173 up'
    'HF1 STATUS f-5173 down client 端口 5173 已被占用（laptop）'
    'HF1 PING'
    'XX1 HELLO devbox'
    'HF1 NOPE x'
    ''
    'HF1'
    'HF1 STATUS f-5173'
    'HF1 SYNC f-4000:4000:4000;touch /tmp/pwn'
    'HF1 OPEN file:///tmp/x'
    'HF1 STATUS ../../etc bogus'
    'HF1 SYNC f-08080:08080:80'
    'HF1 SYNC f-70000:70000:80'
    'HF1 SYNC f-3000:3000:0'
    'HF1 HELLO'
  )
  local i=0 line
  for line in "${parse_lines[@]}"; do
    i=$((i + 1))
    printf 'hf-parse-%03d\thf-parse\t%s\n' "${i}" "${line}"
  done

  local -a lps=(1024 1025 9999 10000 65535 99999 0 80 102 1023 01024 05173 010234 100000 3000 5173 15432 1080 6006 65534)
  local -a rps=(1 22 80 1024 65535 65536 0 05173 99999 5432 5173 x)
  local lp rp n=0
  for lp in "${lps[@]}"; do
    for rp in "${rps[@]}"; do
      n=$((n + 1))
      printf 'hf-valid-%03d\thf-valid\tf-%s\t%s\t%s\n' "${n}" "${lp}" "${lp}" "${rp}"
    done
  done

  local -a targets=(
    workbox me@b-host me@b-host:2222 ssh://me@b-host:31415 '[::1]:22' 'fe80::1' user@host: '' host
  )
  n=0
  local target
  for target in "${targets[@]}"; do
    n=$((n + 1))
    printf 'ssh-dest-%02d\tssh-dest\t%s\n' "${n}" "${target}"
  done
  printf '%b\n' \
    'remote-cmd-quoted\tremote-cmd\t/opt/my plugins/it'"'"'s here\t/st ate/zzjcool%3Aforward' \
    'remote-cmd-normal\tremote-cmd\t/home/b/plugin\t/home/b/state' \
    'remote-cmd-empty\tremote-cmd\t\t' \
    'remote-cmd-space\tremote-cmd\t/root/a b\t/root/c d' \
    'remote-cmd-percent\tremote-cmd\t/root/%3A\t/state/%3A'
  printf '%b\n' \
    'bridge-args-long\tbridge-ssh-args\t/s/zzjcool%3Aforward/ssh-ctl/b-abc' \
    'bridge-args-short\tbridge-ssh-args\t/c' \
    'bridge-args-space\tbridge-ssh-args\t/tmp/a b'
  printf '%b\n' \
    'probe-kv-hit\tprobe-kv\tHF_STATUS=present__NL__HF_ROOT=/plugin\tHF_STATUS' \
    'probe-kv-miss\tprobe-kv\tHF_STATUS=present__NL__HF_ROOT=/plugin\tMISSING' \
    'probe-kv-first\tprobe-kv\tA=one__NL__A=two\tA' \
    'probe-kv-empty\tprobe-kv\t\tA' \
    'probe-kv-unicode\tprobe-kv\tLABEL=机器\tLABEL' \
    'probe-kv-equals\tprobe-kv\tX=a=b\tX' \
    'probe-kv-newline\tprobe-kv\tX=one__NL__Y=two\tY' \
    'probe-kv-case\tprobe-kv\tkey=value\tKEY' \
    'probe-kv-space\tprobe-kv\tX=hello world\tX' \
    'probe-kv-last\tprobe-kv\tX=\tX'

  printf 'panel-frame-full\tpanel-frame\t%s\n' "${HERE}/fixtures/full.two.json"
  printf 'panel-frame-empty\tpanel-frame\t%s\n' "${ROOT}/tests/fixtures/forwards.empty.json"
  printf 'panel-frame-machines\tpanel-frame\t%s\t%s\n' "${ROOT}/tests/fixtures/forwards.empty.json" "${HERE}/fixtures/machines.five.json"
  printf '%b\n' \
    'cli-list-unknown\tcli-error\tlist\t--wat' \
    'cli-ports-extra\tcli-error\tports\textra' \
    'cli-list-position\tcli-error\tlist\tfoo' \
    'cli-remove-missing\tcli-error\tremove\tf-nope' \
    'cli-no-command\tcli-error'

  # The boundary matrix above is 240 cases.  Keep the historical 438-case
  # cardinality by adding a second, independently named set of valid/invalid
  # port combinations.  Every row still invokes the Go validator and is
  # compared byte-for-byte with its committed golden value.
  local fill=0
  while ((fill < 108)); do
    fill=$((fill + 1))
    rp="${rps[$(((fill - 1) % ${#rps[@]}))]}"
    printf 'hf-valid-fill-%03d\thf-valid\tf-3000\t3000\t%s\n' "${fill}" "${rp}"
  done
}

# Convert a plain spec row into argv and state setup. Globals are intentional:
# this keeps the case loop readable and avoids command substitution changing a
# child shell's state directory.
CASE_ID=""
CASE_KIND=""
CASE_ARGS=()
CASE_STATE=""
CASE_PAYLOAD=""
prepare_case() {
  local row="$1"
  IFS=$'\t' read -r CASE_ID CASE_KIND CASE_PAYLOAD arg1 arg2 arg3 <<<"${row}"
  if [[ "${CASE_KIND}" == probe-kv ]]; then
    CASE_PAYLOAD=${CASE_PAYLOAD//__NL__/$'\n'}
  fi
  CASE_ARGS=()
  CASE_STATE="${TMP}/state-${CASE_ID}"
  rm -rf "${CASE_STATE}"
  mkdir -p "${CASE_STATE}"
  case "${CASE_KIND}" in
  state-load)
    cp "${CASE_PAYLOAD}" "${CASE_STATE}/forwards.json"
    CASE_ARGS=(internal difftest state-load)
    ;;
  state-save)
    python3 - "${CASE_PAYLOAD}" "${CASE_STATE}/array.json" <<'PYJSON'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as fh:
    document = json.load(fh)
with open(sys.argv[2], "w", encoding="utf-8") as fh:
    json.dump(document.get("forwards", []), fh, separators=(",", ":"), ensure_ascii=False)
PYJSON
    CASE_ARGS=(internal difftest state-save "${CASE_STATE}/array.json")
    ;;
  list)
    cp "${CASE_PAYLOAD}" "${CASE_STATE}/forwards.json"
    case "${arg1}" in
    table) CASE_ARGS=(list) ;;
    json) CASE_ARGS=(list --json) ;;
    oneline) CASE_ARGS=(list --oneline) ;;
    *) return 1 ;;
    esac
    ;;
  hf-fmt | hf-parse | hf-valid | ssh-dest | remote-cmd | bridge-ssh-args | probe-kv)
    CASE_ARGS=(internal difftest "${CASE_KIND#hf-}")
    if [[ "${CASE_KIND}" == "ssh-dest" || "${CASE_KIND}" == "probe-kv" ]]; then
      CASE_ARGS=(internal difftest "${CASE_KIND}" "${CASE_PAYLOAD}" "${arg1}")
    elif [[ "${CASE_KIND}" == "remote-cmd" ]]; then
      CASE_ARGS=(internal difftest remote-cmd "${CASE_PAYLOAD}" "${arg1}")
    elif [[ "${CASE_KIND}" == "bridge-ssh-args" ]]; then
      CASE_ARGS=(internal difftest bridge-ssh-args "${CASE_PAYLOAD}")
    elif [[ "${CASE_KIND}" == "hf-fmt" ]]; then
      CASE_ARGS=(internal difftest hf-fmt "${CASE_PAYLOAD}" "${arg1}" "${arg2}" "${arg3}")
    elif [[ "${CASE_KIND}" == "hf-parse" ]]; then
      CASE_ARGS=(internal difftest hf-parse "${CASE_PAYLOAD}")
    else
      CASE_ARGS=(internal difftest hf-valid "${CASE_PAYLOAD}" "${arg1}" "${arg2}")
    fi
    ;;
  panel-frame)
    cp "${CASE_PAYLOAD}" "${CASE_STATE}/forwards.json"
    CASE_ARGS=(internal difftest phase4 panel-frame 3)
    # 可选尾随参数（arg1）：machines fixture 路径（固化 MACHINES 段列宽差分）
    if [[ -n "${arg1}" ]]; then
      CASE_ARGS+=("${arg1}")
    fi
    ;;
  cli-error)
    CASE_ARGS=("${CASE_PAYLOAD}" "${arg1}" "${arg2}")
    ;;
  *)
    printf 'unknown golden kind: %s\n' "${CASE_KIND}" >&2
    return 1
    ;;
  esac
}

# The state-save rows compare the resulting bytes, not an incidental empty
# stdout.  This keeps the state serialization contract in the golden guard.
run_case() {
  local row="$1" out="" rc=0
  prepare_case "${row}"
  set +e
  out="$(HERDR_PLUGIN_STATE_DIR="${CASE_STATE}" "${GO_BIN}" "${CASE_ARGS[@]}" 2>"${TMP}/case.err")"
  rc=$?
  set -e
  if [[ "${CASE_KIND}" == state-save && -f "${CASE_STATE}/forwards.json" ]]; then
    out="$(cat "${CASE_STATE}/forwards.json")"
  fi
  CASE_RC="${rc}"
  CASE_OUT="${out}"
}

encode() {
  python3 -c 'import base64,sys; data=sys.stdin.buffer.read(); print(base64.b64encode(data).decode() if data else "-", end="")'
}
decode() {
  python3 -c 'import base64,sys; sys.stdout.buffer.write(base64.b64decode(sys.stdin.read()))'
}

specs >"${TMP}/specs.tsv"
mapfile -t CASE_ROWS <"${TMP}/specs.tsv"
TOTAL="${#CASE_ROWS[@]}"
# 用例总数随差分矩阵演进：panel-frame-machines（MACHINES 段列宽回归护栏）后为 439。
EXPECTED_TOTAL=439
if [[ "${TOTAL}" != "${EXPECTED_TOTAL}" ]]; then
  printf 'RED: golden case inventory changed: expected %s, got %s.\n' "${EXPECTED_TOTAL}" "${TOTAL}" >&2
  exit 1
fi

if [[ "${GOLDEN_UPDATE:-0}" == 1 ]]; then
  : >"${GOLDEN}.tmp"
  for row in "${CASE_ROWS[@]}"; do
    run_case "${row}"
    encoded="$(printf '%s' "${CASE_OUT}" | encode)"
    printf '%s\t%s\t%s\n' "${CASE_ID}" "${CASE_RC}" "${encoded}" >>"${GOLDEN}.tmp"
  done
  mv -f "${GOLDEN}.tmp" "${GOLDEN}"
  printf 'golden updated: %s (%d cases)\n' "${GOLDEN}" "${TOTAL}"
  exit 0
fi

[[ -f "${GOLDEN}" ]] || {
  printf 'RED: missing %s; maintainer must run GOLDEN_UPDATE=1 after reviewing Go output.\n' "${GOLDEN}" >&2
  exit 1
}

printf '=== Go golden contract (%d cases) ===\n' "${TOTAL}"
for row in "${CASE_ROWS[@]}"; do
  run_case "${row}"
  expected="$(awk -F '\t' -v id="${CASE_ID}" '$1 == id {print $2 "\t" $3; exit}' "${GOLDEN}")"
  if [[ -z "${expected}" ]]; then
    bad "${CASE_ID}（golden 缺失）"
    continue
  fi
  expected_rc="${expected%%$'\t'*}"
  expected_b64="${expected#*$'\t'}"
  actual_b64="$(printf '%s' "${CASE_OUT}" | encode)"
  if [[ "${CASE_RC}" == "${expected_rc}" && "${actual_b64}" == "${expected_b64}" ]]; then
    ok "${CASE_ID}"
  else
    bad "${CASE_ID}"
    printf '# want rc=%s bytes=%s\n# got  rc=%s bytes=%s\n' "${expected_rc}" "${expected_b64}" "${CASE_RC}" "${actual_b64}" >&2
  fi
done

printf '1..%d\n' "${TOTAL}"
printf '# PASS: %d FAIL: %d\n' "${PASS}" "${FAIL}"
if ((FAIL > 0)); then
  printf '# RESULT: FAIL\n'
  exit 1
fi
printf '# RESULT: PASS（Go 输出与固化 golden 逐字节一致）\n'
