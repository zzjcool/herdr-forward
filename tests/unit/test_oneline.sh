#!/usr/bin/env bash
# tests/unit/test_oneline.sh — T3 展示层：render_oneline（A.3 tab bar 契约）
# 场景：空 / 单条 / 多条（含过滤与排序）/ >6 截断 + 防御性坏输入
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# --- 断言库：B.1 契约接口；T0 的 tests/lib/assertions.sh 合并前用最小占位子集 ---
if [[ -f "${ROOT}/tests/lib/assertions.sh" ]]; then
  # shellcheck source=/dev/null
  source "${ROOT}/tests/lib/assertions.sh"
else
  echo "WARN: tests/lib/assertions.sh 未就绪（T0 未合并），使用 B.1 契约最小占位子集" >&2
  PASS=0
  FAIL=0
  t_describe() { printf '\n== %s\n' "$*"; }
  t_it() { printf '  - %s\n' "$*"; }
  t_pass() {
    PASS=$((PASS + 1))
    printf '    ok   %s\n' "${1:-}"
  }
  t_fail_note() {
    FAIL=$((FAIL + 1))
    printf '    FAIL %s\n' "${1:-}"
  }
  t_ok() {
    if [[ -n "${1-}" ]]; then t_pass "${2:-ok}"; else t_fail_note "${2:-expected true}"; fi
  }
  t_eq() {
    if [[ "${1-}" == "${2-}" ]]; then
      t_pass "${3:-eq}"
    else
      t_fail_note "${3:-eq}: expected [$1] got [$2]"
    fi
  }
  t_done() {
    printf '\n%d passed, %d failed\n' "${PASS}" "${FAIL}"
    [[ "${FAIL}" -eq 0 ]]
  }
fi

if [[ ! -f "${ROOT}/lib/render.sh" ]]; then
  echo "RED: lib/render.sh 不存在（render_oneline 尚未实现）" >&2
  exit 1
fi
# shellcheck source=/dev/null
source "${ROOT}/lib/render.sh"

t_describe "render_oneline（A.3 oneline 契约）"

# 统一抓取，避免命令替换退出码被 t_eq 调用掩盖（shellcheck SC2312）
got=""
oneline() {
  got="$(render_oneline "$1")"
}

t_it "空 forwards 数组 -> 空串"
oneline '[]'
t_eq "" "${got}" "空数组输出空串"

t_it "单条 up -> ⇅<port>"
oneline '[{"id":"f-3000","local_port":3000,"status":"up"}]'
t_eq "⇅3000" "${got}" "单条渲染"

t_it "多条：仅 up、端口升序、忽略 down/starting/坏记录"
oneline '[
  {"id":"f-5173","local_port":5173,"status":"up"},
  {"id":"f-3000","local_port":3000,"status":"up"},
  {"id":"f-8080","local_port":8080,"status":"down"},
  {"id":"f-9000","local_port":9000,"status":"starting"},
  {"id":"f-bad","local_port":null,"status":"up"}
]'
t_eq "⇅3000⇅5173" "${got}" "多条过滤 + 升序"

t_it ">6 条：前 6 个 + +N（假设#5 防御性截断）"
oneline '[
  {"local_port":8000,"status":"up"},
  {"local_port":7000,"status":"up"},
  {"local_port":6000,"status":"up"},
  {"local_port":5000,"status":"up"},
  {"local_port":4000,"status":"up"},
  {"local_port":3000,"status":"up"},
  {"local_port":9000,"status":"up"},
  {"local_port":10000,"status":"up"}
]'
t_eq "⇅3000⇅4000⇅5000⇅6000⇅7000⇅8000+2" "${got}" "截断为前 6 + +2"

t_it "恰好 6 条：不出现 +N"
oneline '[
  {"local_port":3000,"status":"up"},
  {"local_port":4000,"status":"up"},
  {"local_port":5000,"status":"up"},
  {"local_port":6000,"status":"up"},
  {"local_port":7000,"status":"up"},
  {"local_port":8000,"status":"up"}
]'
t_eq "⇅3000⇅4000⇅5000⇅6000⇅7000⇅8000" "${got}" "6 条不截断"

t_it "防御：损坏 JSON -> 空串且不报错"
oneline '{'
t_eq "" "${got}" "损坏 JSON 输出空串"

t_it "防御：非数组（对象信封）-> 空串（契约只接受 forwards 数组）"
oneline '{"version":1,"forwards":[{"local_port":3000,"status":"up"}]}'
t_eq "" "${got}" "对象输入输出空串"

t_it "防御：空参数 -> 空串"
oneline ''
t_eq "" "${got}" "空参数输出空串"

t_it "无 ANSI 转义（tab_bar_right 不渲染颜色，SCOUT-FACTS §2.4）"
oneline '[{"local_port":3000,"status":"up"}]'
has_ansi="no"
[[ "${got}" == *$'\033'* ]] && has_ansi="yes"
t_eq "no" "${has_ansi}" "输出无 ESC 序列"
t_eq "⇅3000" "${got}" "纯文本输出"

t_done
