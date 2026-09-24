#!/usr/bin/env bash
# tests/unit/test_ports.sh — lib/ports.sh：本机监听端口发现（面板一键映射的数据源）
# 覆盖三种数据源的解析（ss / /proc/net/tcp{,6} / lsof）与「经 localhost 可达」过滤。
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
source "${ROOT}/tests/lib/assertions.sh"
# shellcheck source=/dev/null
source "${ROOT}/lib/ports.sh"

out=""

t_describe "ports_addr_is_local"
for a in '*' 0.0.0.0 :: ::1 127.0.0.1 ::ffff:127.0.0.1; do
  run ports_addr_is_local "${a}"
  t_eq "yes" "${out}" "${a} 经 localhost 可达"
done
for a in 192.168.1.5 10.0.0.2 fe80::1 ::ffff:10.0.0.1 127.0.0.53 127.0.0.11; do
  run ports_addr_is_local "${a}"
  t_eq "" "${out}" "${a} 不可达"
done

t_describe "ports_parse_ss"
SS_FIXTURE='LISTEN 0      511        127.0.0.1:5173  0.0.0.0:* users:(("node",pid=11,fd=3))
LISTEN 0      4096       127.0.0.1:631   0.0.0.0:*
LISTEN 0      128          0.0.0.0:8080  0.0.0.0:* users:(("python3",pid=12,fd=4),("python3",pid=13,fd=4))
LISTEN 0      128      192.168.1.5:9000  0.0.0.0:* users:(("lan-only",pid=14,fd=5))
LISTEN 0      4096   127.0.0.53%lo:5355  0.0.0.0:*
LISTEN 0      128             [::]:3000     [::]:* users:(("vite",pid=15,fd=6))
LISTEN 0      128            [::1]:6006     [::]:*
LISTEN 0      128                *:4000        *:* users:(("caddy",pid=16,fd=7))'
run ports_parse_ss "${SS_FIXTURE}"
t_eq $'5173\t127.0.0.1\tnode\n8080\t0.0.0.0\tpython3\n3000\t::\tvite\n6006\t::1\t\n4000\t*\tcaddy' "${out}" \
  "loopback/通配保留；<1024、网卡地址、localhost 解析不到的 127.x（去掉 %iface 后判定）剔除；进程名取首个"

t_describe "ports_parse_proc"
PROC_FIXTURE='  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 0100007F:1435 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 1 1 0 100 0 0 10 0
   1: 0100007F:0277 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 2 1 0 100 0 0 10 0
   2: 0501A8C0:2328 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 3 1 0 100 0 0 10 0
   3: 0100007F:1F90 0100007F:D431 01 00000000:00000000 00:00000000 00000000  1000        0 4 1 0 100 0 0 10 0
  sl  local_address                         remote_address                        st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 00000000000000000000000000000000:0BB8 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000  1000 0 5 1 0 100 0 0 10 0
   1: 00000000000000000000000001000000:1776 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000  1000 0 6 1 0 100 0 0 10 0'
run ports_parse_proc "${PROC_FIXTURE}"
t_eq $'5173\t127.0.0.1\t\n3000\t::\t\n6006\t::1\t' "${out}" "只取 LISTEN(0A)；地址按 little-endian 还原"

t_describe "ports_parse_lsof（macOS）"
LSOF_FIXTURE='COMMAND   PID USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
node      101 me     23u  IPv4 0x1111111111111111      0t0  TCP 127.0.0.1:5173 (LISTEN)
rapportd  102 me      4u  IPv6 0x2222222222222222      0t0  TCP *:49152 (LISTEN)
ControlCe 103 me      8u  IPv4 0x3333333333333333      0t0  TCP 192.168.1.2:7000 (LISTEN)'
run ports_parse_lsof "${LSOF_FIXTURE}"
t_eq $'5173\t127.0.0.1\tnode\n49152\t*\trapportd' "${out}" "解析 NAME 列并过滤"

t_describe "ports_listening_json：同端口去重（优先带进程名的一行）、升序"
# shellcheck disable=SC2317 # 由 ports_listening_json 间接调用（遮蔽真 ss）
ss() { printf '%s\n' "LISTEN 0 1 [::]:3000 [::]:*" "LISTEN 0 1 0.0.0.0:3000 0.0.0.0:* users:((\"vite\",pid=1,fd=2))" "LISTEN 0 1 127.0.0.1:1500 0.0.0.0:*"; }
run ports_listening_json
t_eq '[{"port":1500,"addr":"127.0.0.1","process":""},{"port":3000,"addr":"0.0.0.0","process":"vite"}]' "${out}" "去重 + 排序"
unset -f ss

t_done
