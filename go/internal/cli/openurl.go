// openurl.go —— `forward open-url [URL]`（← bin/forward 的 cmd_open_url / _hf_open_locally）。
//
// Ctrl+click localhost 链接的落点（manifest 的 link_handler）。语义：
//
//	有 client 经桥接在线  = 用户是从另一台机器 attach 进来的 → 本机浏览器对他没有意义
//	                        于是确保该端口已映射到 client，再请 client 在自己的浏览器里打开；
//	否则                   = 本机开发 → 用本机浏览器打开。
package cli

import (
	"fmt"
	"os"
	"os/exec"
	"regexp"
	"strconv"
	"syscall"

	"github.com/zzjcool/herdr-forward/internal/bridge"
	"github.com/zzjcool/herdr-forward/internal/notify"
	"github.com/zzjcool/herdr-forward/internal/state"
)

// reOpenURL 复刻 `^(https?)://(localhost|127\.0\.0\.1)(:([0-9]{1,5}))?(.*)$`。
var reOpenURL = regexp.MustCompile(`^(https?)://(localhost|127\.0\.0\.1)(:([0-9]{1,5}))?(.*)$`)

// openLocally 复刻 _hf_open_locally：用本机浏览器打开（xdg-open / open）。
func openLocally(url string) int {
	for _, cand := range []string{"xdg-open", "open"} {
		if _, err := exec.LookPath(cand); err != nil {
			continue
		}
		cmd := exec.Command(cand, url)
		cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
		devNull, _ := os.OpenFile(os.DevNull, os.O_RDWR, 0)
		if devNull != nil {
			cmd.Stdin, cmd.Stdout, cmd.Stderr = devNull, devNull, devNull
		}
		if err := cmd.Start(); err != nil {
			break
		}
		go func() { _ = cmd.Wait() }()
		if devNull != nil {
			_ = devNull.Close()
		}
		return exitOK
	}
	return die(exitMissingDep, "本机没有 xdg-open/open，无法打开 "+url+"。")
}

// cmdOpenURL 复刻 cmd_open_url。
func cmdOpenURL(args []string) int {
	url := ""
	if len(args) > 0 {
		url = args[0]
	} else {
		url = os.Getenv("HERDR_PLUGIN_CLICKED_URL")
	}
	if url == "" {
		return die(exitUsage, "缺少 URL。用法：forward open-url http://localhost:3000")
	}

	live := bridge.AnyLive(bridge.Sessions())
	m := reOpenURL.FindStringSubmatch(url)
	if !live || m == nil {
		return openLocally(url)
	}
	scheme := m[1]
	portText := m[4]
	rest := m[5]
	port := 80
	if portText == "" {
		if scheme == "https" {
			port = 443
		}
	} else if n, err := strconv.Atoi(portText); err == nil {
		port = n
	}

	records, _ := state.Load()
	localPort := 0
	for _, r := range records {
		if r.Mode == state.ModeClient && r.RemotePort == port {
			localPort = r.LocalPort
			break
		}
	}
	if localPort == 0 {
		localPort = port
		if localPort < 1024 {
			localPort = port + 10000
		}
		for _, r := range records {
			if r.LocalPort == localPort {
				return die(exitDuplicatePort, fmt.Sprintf("本机映射表里端口 %d 已被另一条记录占用，无法自动映射 %s。请用 forward add <空闲端口>:%d --client 后再点击。", localPort, url, port))
			}
		}
		if code := addClient(localPort, port); code != exitOK {
			return code
		}
	}

	targetURL := fmt.Sprintf("%s://localhost:%d%s", scheme, localPort, rest)
	bridge.EnqueueOpen(targetURL)
	_ = notify.Toast("Port Forward", "在 client 上打开 "+targetURL)
	fmt.Printf("已请 client 打开 %s\n", targetURL)
	return exitOK
}
