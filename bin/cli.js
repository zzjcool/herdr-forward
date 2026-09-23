#!/usr/bin/env node
// herdr-forward npm 包入口。
//
// 本包的定位（诚实声明）：herdr 插件系统不消费 npm——插件通过
// `herdr plugin install zzjcool/herdr-forward`（GitHub）或本地 `herdr plugin link`
// 安装。npm 包的用途是：
//   1. 占住 herdr-forward 包名，避免抢注
//   2. 给 npm 用户一个直达的安装指引（含真正可用的安装路径）
//   3. 版本发布渠道（npm version 作为发布节奏锚点）
//
// 此 CLI 只做指引输出，不代理插件功能——真正的 forward CLI 由 herdr
// 插件运行时注入 $HERDR_PLUGIN_ROOT/bin/forward 使用。

const { spawnSync } = require("child_process");
const path = require("path");

const HINT = `
herdr-forward — Port forwarding for herdr saved SSH machines

This npm package is a distribution pointer. The actual herdr plugin
installs from GitHub, not npm:

  herdr plugin install zzjcool/herdr-forward

Local development:

  git clone https://github.com/zzjcool/herdr-forward
  herdr plugin link ./herdr-forward

Docs: https://github.com/zzjcool/herdr-forward#readme
`.trim();

function main() {
  const args = process.argv.slice(2);

  if (args.includes("--postinstall-hint")) {
    // npm install 后轻提示（静默失败，不打扰 CI）
    console.log(HINT.split("\n").slice(0, 4).join("\n"));
    return 0;
  }

  console.log(HINT);

  // 已通过 herdr plugin link 指向本 checkout 时，把状态透出（尽力而为）
  const forwarded = path.join(__dirname, "forward");
  if (require("fs").existsSync(forwarded)) {
    console.log("\nDetected plugin checkout. Plugin CLI: ./bin/forward");
  }
  return 0;
}

process.exit(main());
