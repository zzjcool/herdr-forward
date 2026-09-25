package cli

import (
	"errors"
	"io"
	"os"
	"os/exec"
	"strings"
	"time"

	"github.com/zzjcool/herdr-forward/internal/difftest"
	"github.com/zzjcool/herdr-forward/internal/panel"
)

// cmdWatch preserves the historical non-TTY watch(1) fallback while routing
// the interactive pane itself through Go.  The fallback intentionally invokes
// bin/forward rather than duplicating list rendering; its dispatch selects the
// Go binary when installed and remains usable during a staged rollback.
func cmdWatch(args []string) int {
	if len(args) != 0 {
		return die(exitUsage, "watch 不接受参数。用法：forward watch")
	}
	ctx := signalContext()
	err := panel.Run(ctx, panel.Options{
		Stdin:   os.Stdin,
		Stdout:  os.Stdout,
		Refresh: 3 * time.Second,
		OnAction: func(action panel.Action) error {
			return runPanelAction(action, os.Stdout)
		},
	})
	if err == nil {
		return exitOK
	}
	if !errors.Is(err, panel.ErrNotTTY) {
		if errors.Is(err, panel.ErrInputClosed) {
			return exitOK
		}
		return die(exitError, err.Error())
	}

	watch, err := exec.LookPath("watch")
	if err != nil {
		return die(exitMissingDep, "watch 命令缺失。请安装 procps/util-linux，或直接运行 'forward list'。")
	}
	cmd := exec.Command(watch, "-n", "3", binForwardPath(), "list")
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		if ee, ok := err.(*exec.ExitError); ok {
			return ee.ExitCode()
		}
		return exitError
	}
	return exitOK
}

type panelCRLFWriter struct{ io.Writer }

func (w *panelCRLFWriter) Write(p []byte) (int, error) {
	text := strings.ReplaceAll(string(p), "\n", "\r\n")
	if _, err := io.WriteString(w.Writer, text); err != nil {
		return 0, err
	}
	return len(p), nil
}

func runPanelAction(action panel.Action, out io.Writer) error {
	var args []string
	switch action.Kind {
	case panel.ActionActivate:
		args = []string{"machines", "activate", action.Value}
	case panel.ActionDeactivate:
		args = []string{"machines", "deactivate", action.Value}
	case panel.ActionDoctor:
		args = []string{"doctor"}
	case panel.ActionAddClient:
		args = []string{"add", action.Value, "--client"}
	case panel.ActionRemove:
		args = []string{"remove", action.Value}
	default:
		return nil
	}
	cmd := exec.Command(binForwardPath(), args...)
	cmd.Stdin = os.Stdin
	cmd.Stdout = &panelCRLFWriter{Writer: out}
	cmd.Stderr = &panelCRLFWriter{Writer: out}
	return cmd.Run()
}

// cmdInternal is deliberately not advertised in usage.  It is the stable
// argv surface used by the POSIX manifest wrappers and by the difftest driver.
func cmdInternal(args []string) int {
	if len(args) == 0 {
		return die(exitUsage, "缺少 internal 子命令")
	}
	switch args[0] {
	case "install-tabbar":
		return internalInstallTabbar(args[1:])
	case "install-keys":
		return internalInstallKeys(args[1:])
	case "startup-hook":
		return internalStartupHook(args[1:])
	case "postinstall":
		return internalPostinstall(args[1:])
	case "bootstrap":
		return internalBootstrap(args[1:])
	case "diagnose-panel":
		return internalDiagnosePanel(args[1:])
	case "difftest":
		return difftest.Main(args[1:])
	default:
		return die(exitUsage, "未知 internal 子命令："+args[0])
	}
}
