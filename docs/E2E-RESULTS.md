# E2E-RESULTS — 一期 E2E 结论与假设核实清单（T4）

> 生成者：T4 收尾 worker。日期：2026-09-23。
> 依据：ARCHITECTURE §C（E2E 方案）+ §G（假设清单）、SCOUT-FACTS §3（未证实项）。
> 本文是**结论**文件：每条假设标注「已在 E2E 验证 / 容器内降级验证 / 宿主 smoke 待办」。

## 0. 一句话结论

一期 bash 层全链路（`bin/forward add/list/remove/doctor` ↔ `lib/tunnel.sh` 真隧道）
**已在容器内闭环验证**：`bash scripts/e2e/run-docker.sh` 退出码 0，容器内 **59 断言全绿**；
宿主侧 `bash scripts/ci.sh` **6/6 通过**（严格模式）。herdr 二进制挂载（模式 A）成立，
可执行 `herdr --version`。**剩余未闭环项只有需要真实 herdr 会话/真实 saved machine 的
宿主 smoke**（见 §2 标注）。

## 1. 验证矩阵（本次实测）

| 命令 | 结果 | 说明 |
|---|---|---|
| `bash tests/run.sh all`（宿主） | 15 files, failed: 0 | unit 12 + integration 3 |
| `bash scripts/ci.sh`（宿主，严格） | **CI OK: 6/6** | shellcheck 30 目标 + shfmt + unit + integration + e2e-docker + 哨兵 |
| `HERDR_FORWARD_CI_LAX=1 bash scripts/ci.sh` | **CI OK: 6/6** | LAX 降级开关在缺工具时 WARN 不静默 |
| `bash scripts/e2e/run-docker.sh` | **退出码 0**，PASS: 59 / FAIL: 0 / SKIP: 0 | archlinux 容器；模式 A |
| `bash scripts/e2e/run-bwrap.sh` | **退出码 0**，PASS: 53 / FAIL: 0 / SKIP: 3 | 无 docker 降级路径；SKIP 均为「宿主缺 nc」显式降级 |

E2E 容器内 5 段结构（run-inside.sh）：

```
A)  用户态 sshd + echo 回环          （假设#7）
A2) machines.toml 解析 + cmd 全链路  （§C.3 步骤 3/5）
B)  shellcheck + shfmt + unit + integration（容器是权威基线）
C)  herdr 挂载模式探测 + shim        （假设#6）
D)  清理 + 无残留断言
```

## 2. 假设清单（ARCHITECTURE §G + SCOUT-FACTS §3）

| # | 假设 | 结论 | 证据 / 落点 |
|---|---|---|---|
| 1 | 插件可经 socket API 读 EndpointCatalog 拿 saved machine 的 ssh target | **不成立**（已由 SCOUT-FACTS §2.1 证实无此 API） | 一期正式路径 = `machines.toml`；E2E 内 `machine_resolve sandbox` 真解析通过 + 未声明 label → die 4 已验证。真实 `endpoints.json` 形状：**宿主 smoke 待办**（需真机 saved machine） |
| 2 | manifest `command` 里 `%{plugin_root}` 模板变量是否支持 | **不支持**（SCOUT-FACTS §2.2 已证实） | manifest 一律 `/bin/sh -c` + `$HERDR_PLUGIN_ROOT`；容器内 `herdr --version`(模式A) 可跑。**「link 后 action 真被执行」= 宿主 smoke 待办** |
| 3 | 能否复用 herdr per-attach SSH control socket | **不可复用**（预期如此） | 已按冻结方案自建 ControlMaster；E2E 全链路证明自建 socket 可用。**宿主 attach 后 `ssh -O check` = 宿主 smoke 待办** |
| 4 | link_handlers regex 对无 scheme 的 `localhost:3000` 是否命中 | **不命中**（SCOUT-FACTS §2.3） | pattern 定稿带 scheme：`^https?://(?:localhost\|127\.0\.0\.1)(?::\d{1,5})?(?:[/?#].*)?$`；bash ERE 同构 + python `re` 双引擎用例在 `tests/unit/test_link_pattern.sh` 全绿。**Ctrl+click 真命中 = 宿主 smoke 待办** |
| 5 | tab_bar_right 输出宽度/ANSI 截断行为 | **纯文本、无 ANSI**（SCOUT-FACTS §2.4）；>6 条截断 `+N` 为防御性冻结 | `tests/unit/test_oneline.sh` 四场景绿；E2E 内 `list --oneline` 输出含 `⇅<port>`。**真实 tab bar 渲染截断 = 宿主 smoke 待办** |
| 6 | docker 容器内挂载宿主 herdr 可跑（glibc 兼容）+ 假 HOME 隔离成立 | **成立（模式 A）** | E2E 实测：`herdr 0.9.1` 在 archlinux 容器内 `--version` 成功；负面断言「E2E 未创建/未污染 `~/.config/herdr`」绿。容器记录见 `test-results/e2e-mode.txt` |
| 7 | 容器内用户态 sshd + 公钥登录可行 | **成立** | 容器内 sshd 监听 127.0.0.1:22022、SSH banner、`nc -z` 握手、公钥登录执行远端命令、echo 服务回环均绿 |
| 8 | herdr `plugin link` 是否要求 TTY | 未测 | **宿主 smoke 待办**（与本轮 CI 无关；`herdr plugin link < /dev/null` 观察行为） |

SCOUT-FACTS §3 未证实项对应关系：#1=假设2、#2=假设4、#3=假设5、#4=假设3。

## 3. 「宿主 smoke 待办」清单（不进 CI，需人工在有 herdr 会话的机器跑）

这些项的共同点：**必须有一个真实运行的 herdr server + 真实 link**，容器/bwrap 沙箱里
天然没有，故一期的机器可验证部分到此为止。

- [ ] `herdr plugin link <checkout>` + `reload-config` → manifest 被接受（假设#2）
- [ ] 手动触发 `add` action → 观察 `$HERDR_PLUGIN_ROOT` 注入 + 命令执行（假设#2）
- [ ] attach 一个远端 session 后找 control socket 试 `ssh -O check`（假设#3）
- [ ] pane 内写 `http://localhost:3000` Ctrl+click 命中（假设#4）
- [ ] 装好 tab bar 条目后构造 8 个映射，观察宽度/截断行为（假设#5）
- [ ] `herdr plugin link < /dev/null` 观察是否要求 TTY（假设#8）
- [ ] 真实 saved machine 环境下 `machine list --json` 的 `endpoints.json` 形状（假设#1 补充）

## 4. 本轮 E2E 发现并修复的缺陷（红→绿，均有 commit 归因）

1. **tunnel_stop 停不住 ssh master**（实现 bug）：`atomic_write` 缺 `<tmpdir>` 参数导致
   pid 文件从未落盘；`timeout 5 _tunnel_ctl_ssh` 无法 exec shell 函数（rc=127 被 `|| true`
   吞掉）导致优雅关闭从不执行。→ 端口仍监听、ssh 进程残留。
2. **doctor 未接线隧道层**（实现 bug）：`cmd_doctor` 探测的 `doctor_run` 不存在
   （T2 命名是 `tunnel_doctor`）→ 委托分支是死代码，永不 `tunnel_reap`，stale control
   socket 残留。
3. **断言语义误用**：多处 `t_ok "…"` 写在 `if [[ -e … ]]; then … else t_ok … fi` 的 else
   分支（消费 `$?` = 1 → 恒判失败），以及 `t_ok "${out}" "msg"` 空断言。
4. **容器缺 python3** → 容器内 unit 三个文件 rc=127。
5. **`t_fail_note` 在真断言库下未定义** → 真失败退化为 `command not found`，掩盖原因。
6. **测试假设环境**：`probe_tcp 127.0.0.1 22` 只在宿主成立（容器无 22 服务）。
7. **shfmt 版本分歧**：本机 v3.10 与容器 v3.14.1 对 `((! x))` 与 heredoc-`then` 判定
   相反 → 改写为两版都稳定的等价形式。

## 5. 隔离性与红线（E2E 每次运行都断言）

- 假 HOME：容器内 `HOME=/home/fwduser`（bwrap 内 `/root`），状态/配置全落沙箱；
  E2E 结束断言「未创建/未改动隔离 HOME 下的 `~/.config/herdr`」。
- 绝不出网：容器不 `--publish`、不 `--network host`；`ci.sh` 第 6 段静态 grep 看守
  （mount 出现 `$HOME`、`-p/--publish/EXPOSE`、`--network host`、bwrap 缺 `--unshare-net`
  均判红）；`run-docker.sh` 另有运行期 `redline_check_mounts` 自检。
- 无残留：E2E D 段断言无残留 sshd/echo 进程、端口已释放、`t_no_zombie_ssh` 绿。
- 不碰真实 saved machines：`ssh_target` 只允许 `127.0.0.1`。

## 6. 复现方式

```sh
# 宿主全量（严格）
bash scripts/ci.sh

# 宿主缺 shellcheck/shfmt 时显式降级（WARN 不静默）
HERDR_FORWARD_CI_LAX=1 bash scripts/ci.sh

# E2E 主路径（docker）
bash scripts/e2e/run-docker.sh          # 退出码即结果

# E2E 降级（无 docker）
bash scripts/e2e/run-bwrap.sh
```
