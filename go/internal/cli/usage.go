// usage.go — bin/forward 的 usage() 文本（字节级冻结的搬运，禁止"顺手润色"）。
//
// 为什么单独一个文件：`forward help` 的输出是用户可见契约（C1 子命令清单即在其中），
// 且迁移期铁律是「零行为变化」——故这里是从 bin/forward 的 usage() 里**逐字节**取出的
// 同一份文本（含全角标点与缩进），由 TestUsageMatchesBash 直接对 `bin/forward help`
// 的 stdout 做逐字节断言。任何手工编辑都会在该测试上红。
//
// 不要在此文件里做任何格式化（gofmt 只动 Go 代码，raw string 内部不受影响）。
package cli

// usageText 是 usage() 的完整文本（含结尾换行）。
const usageText = `forward — herdr 端口转发管理（一期：ssh -L）

用法：
  forward add <local>:<remote> [--machine LABEL] [--ssh-target TARGET]
      新增映射并把远端端口拉到本地 localhost:<local>。
      --ssh-target 优先（跳过 machine 解析）；否则用 --machine 经 machines.toml 解析。

  forward add <port>|<client>:<here> [--client]
      远程开发：把**本机**端口映射到 attach 过来的 client 的 localhost（client 侧由桥接
      代为监听）。没给 --machine/--ssh-target 且有 client 在线时默认就是这种；
      --client 可在 client 还没连上时预先登记，连上后自动生效。

  forward list [--oneline] [--json]
      默认表格；--oneline 给 tab bar（仅 up，⇅端口）；--json 输出状态文档。

  forward remove <id>
      删除映射（id 形如 f-3000），存在隧道模块时会一并停隧道。

  forward bootstrap [--config PATH] [--dry-run] [--no-tabbar] [--no-keys]
      OOTB 一键安装 UI：tab bar 状态条 + 键绑定（两个安装器都幂等）。

  forward machines list [--json] [--short]
      列出 herdr saved machines 与激活状态（[✓] 当前 / [·] 曾激活 / [ ] 未激活）。
      --json 输出合并视图（数组）；--short 每机器一行 TSV（供面板渲染）。

  forward machines activate <id|label> [--install]
      激活一台 saved machine：同机直接标记；远端先只读 SSH 探测其插件根与 state 目录，
      探测到已装插件则写激活记录 + 配好该机器的键位 + 启动桥接（该机器上登记的端口
      映射随即出现在本机 localhost）。
      未装插件时：交互终端里询问是否代装，--install 直接代装；否则打印可复制的命令。

  forward machines deactivate <id|all>
      停用：清 active 并把 tab bar 恢复为本机路径；all 同时删除全部激活记录。

  forward machines doctor
      对当前 active 的机器重新探测：路径漂移则重写记录与 tab bar；连不上则只报告。

  forward bridge up|down <machine-id|all>
  forward bridge status [--json]
      client 侧：启停到某台机器的桥接（通常由 machines activate/deactivate 自动完成）。
      server 侧：status 显示当前连着的 client 与各 client 映射的实时状态。
  forward bridge serve | run <machine-id>
      内部入口：serve 由 client 经 SSH 调起；run 是 client 侧前台 supervisor。

  forward ports [--json]
      列出本机经 localhost 可达的 TCP 监听端口（面板一键映射用）。

  forward open-url [URL]
      Ctrl+click localhost 链接的落点：有 client 在线时映射端口并在 client 上打开，
      否则用本机浏览器打开。

  forward doctor [--fix] [--prune]
      探活并报告；--fix 按探活结果修正 status；--prune 清理死进程记录。

  forward publish <port>    # 二期（Cloudflare quick tunnel），当前 exit 9
  forward unpublish         # 二期，当前 exit 9
  forward watch             # pane 入口：TTY 下开交互面板（数字键激活机器），
                            # 非 TTY（脚本/CI）退化为 watch -n 3 forward list

退出码：0 成功 / 2 端口重复 / 3 记录不存在 / 4 machine 无法解析 /
        5 隧道启动失败 / 9 未实现 / 64 用法错误 / 127 依赖缺失
`
