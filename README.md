# herdr-forward

> Port forwarding for [herdr](https://herdr.dev) saved SSH machines — the missing
> "Ports panel" from VS Code Remote.

Forward a saved SSH machine's TCP port to your localhost (`ssh -L`), and
optionally publish a localhost port to the public internet via a Cloudflare
quick tunnel (`cloudflared tunnel --url`).

One plugin, one forwarding table:

```
local port  ⇄  remote machine (ssh -L)        ⇅ 3000  ⇅ 5173   ← tab bar
local port  →  public URL (Cloudflare)        🌐 https://x.trycloudflare.com
```

- **Remote development**: working on a saved machine B from your laptop A? Map
  B's dev-server ports to A's `localhost` from B's own Port Forward panel — see
  [Remote development](#remote-development-bs-ports-on-as-localhost)
- **Explicit mappings** on saved machines (0.9+), not auto-forward-everything
- **Three-layer UI**: tab bar status entry, a Port Forward pane, notifications
- **Saved machines in the panel**: activate a machine and the tab bar follows it
  (read-only SSH probe, one keystroke, directly reversible)
- **Ctrl+click** `localhost:PORT` links anywhere in herdr

## Status

Pre-alpha. See `docs/PLAN.md` (roadmap) and `docs/RESEARCH.md`
(herdr plugin-capability research).

## Install

Requires herdr ≥ 0.8.0 and `jq` (plus `ssh` for the tunnels). The plugin installs
with the `zzjcool:forward` id.

### A. From GitHub

```sh
herdr plugin install zzjcool/herdr-forward
herdr plugin enable zzjcool:forward   # if the plugin starts out disabled
```

herdr clones the repo into its managed checkout, so updating means re-running
the same command with a new `--ref`.

### B. Local development (symlink your checkout)
```sh
herdr plugin link ~/code/herdr-forward
```

`herdr plugin link` symlinks the working tree instead of cloning, so edits are
picked up on the next `reload-config`. Use `herdr plugin unlink zzjcool:forward`
to remove the link.

### C. Out-of-the-box UI (tab bar + keybindings)

Plugin v1 manifests cannot declare keybindings or tab-bar entries — those live in
herdr's own `config.toml`, and no plugin API can register them at install time.
The plugin's `[[startup]]` hook installs both automatically on first start, so
for the common case there is nothing to run. `bootstrap.sh` is the manual
installer, kept for re-installing, choosing different keys, and cross-machine
setups:

```sh
# optional — the startup hook already does this on first start
./scripts/bootstrap.sh          # tab bar status entry + 3 keybindings
./scripts/bootstrap.sh --dry-run  # preview first, writes nothing
```

**A. `herdr plugin install` → done (the common case).** Plugin install is the
only install step, and you do not need to restart herdr: the plugin's `[[build]]`
step (`scripts/postinstall.sh`, listed in the install preview) writes the three
keybindings and runs `herdr server reload-config`, so `prefix+f` works in the
herdr you already have open. (`[[startup]]` hooks only run when a herdr server
starts — not on install, link, enable or reload — so without this step a fresh
install would have no keys until the next restart.) If your herdr server and
your herdr client run on the same machine (the common local case), the plugin's
`[[startup]]` hook then runs `scripts/startup-hook.sh` whenever the server starts
and **automatically** installs both UI pieces:

- the **tab bar status entry**, and
- the **three keybindings** — `prefix+f` (Port Forward panel), `prefix+shift+f`
  (list forwards), `prefix+alt+f` (doctor).

Both are idempotent (a marker comment identifies our entries, so subsequent
starts change nothing) and the hook **tells you what it did**: it prints the
three keys it installed and how to pick different ones. The server has already
read its config by the time the hook runs, so after writing anything the hook
runs `herdr server reload-config` itself — that makes the new keys work in open
clients and pushes the tab bar to them, so `prefix+f` works right away without
a manual reload. A hook failure never stops the server.

**Conflict etiquette:** if one of the default keys is already bound to something
else, the hook does **not** overwrite your binding. It skips the automatic
install and prints exactly which key was occupied plus the command to install on
a different key:

```sh
<plugin-root>/scripts/bootstrap.sh --config ~/.config/herdr/config.toml \
  --add-key prefix+<your key>          # --list-key / --doctor-key work the same
```

(Keys live in the config of the machine whose panes you are viewing: herdr does
not send a client's custom-command keybindings to a remote server, so while you
view a saved machine B, `prefix+f` is resolved from **B's** config. Activating B
from the panel sets up B's keys for you — see
[Remote development](#remote-development-bs-ports-on-as-localhost).)

**B. Cross-machine activation.**  The final Go binary owns the remote-machine
workflow.  On A, activate a saved machine from the Port Forward panel or run
`forward machines activate <id>`.  The command performs a bounded read-only SSH
probe, records the remote plugin/state paths, installs the remote UI when
consented, and starts the HF1 bridge.  If the remote plugin is absent, use the
printed command on B and retry; activation never silently installs software.

For a local checkout, build the binary first:

```sh
make build
HERDR_FORWARD_SKIP_DOWNLOAD=1 ./bin/forward internal install-keys
```

The skip flag is intended for offline E2E and local development only.  A normal
release installation downloads the matching static binary from GitHub Releases
and verifies `checksums.txt` before any keybinding is changed.

#### The installers

| Script | Adds | Notes |
|---|---|---|
| `scripts/install-tabbar.sh` | `[ui].tab_bar_right` command entry showing `⇅3000⇅5173` | `--config PATH`, `--plugin-root PATH`, `--state-dir PATH`, `--command CMD`, `--dry-run` |
| `scripts/install-keys.sh` | 3 `[[keys.command]]` plugin-action bindings | `--config PATH`, `--add-key/--list-key/--doctor-key`, `--dry-run` |
| `scripts/bootstrap.sh` | both of the above + next steps | `--config PATH`, `--plugin-root PATH`, `--state-dir PATH`, `--dry-run`, `--no-tabbar`, `--no-keys`, key overrides |
| `scripts/startup-hook.sh` | the `[[startup]]` hook: calls `install-tabbar.sh` **and** `install-keys.sh` (the automatic tab bar + keybindings; notifies what it installed, skips on key conflict) | never fails the server; degrades to a log line cross-machine; points the tab bar at the **active machine** when one is activated (see below) |

All of them are idempotent (a marker comment identifies our entries) and back up
the original to `config.toml.bak.<epoch>` before any real change. Re-running
`install-tabbar.sh` rewrites a stale entry — one whose `command` still contains
the unexpandable `$HERDR_PLUGIN_ROOT` literal, or that lacks/outdates the
`env HERDR_PLUGIN_STATE_DIR=…` prefix — to the current form, keeping your
`interval_seconds`/`timeout_seconds`.
When installed from GitHub, use the copy inside the managed checkout:
`"$HERDR_PLUGIN_ROOT/scripts/bootstrap.sh"`.

#### Default keys

| Key | Action |
|---|---|
| `prefix+f` | open the Port Forward panel (forwards table + saved machines; `add`/`remove`/activate happen there) |
| `prefix+shift+f` | list current forwards |
| `prefix+alt+f` | doctor — probe tunnels |

Override them with `--add-key/--list-key/--doctor-key`. The startup hook installs
these three automatically on first start; if one is already bound to something
else it skips the automatic install and tells you which key collided (so a
collision is visible rather than silent, and your existing binding is never
overwritten). Run `bootstrap.sh --add-key <key>` to install on a different key,
or let `install-keys.sh` warn-and-install anyway if you are fine with the overlap.

### D. Ctrl+click links

The plugin registers a link handler so that localhost URLs in pane output open
in your browser. herdr only recognises URLs that carry a scheme, so the link
must be written as `http://localhost:3000` — a bare `localhost:3000` will not be
clickable.

## Troubleshooting

**The panel shows no machines** (the `MACHINES` section is missing or empty)
while `forward machines list` works in a plain terminal — run the read-only
field diagnostic and paste its `--json` output into your issue:

```sh
bash scripts/diagnose-panel.sh          # human-readable report
bash scripts/diagnose-panel.sh --json   # machine-readable verdict
```

It prints, without changing anything: `HERDR_BIN_PATH` and the herdr version,
the raw `machine list --json` output with its exit code, the plugin state dir and
activation record, `machines_view_json`, the non-interactive panel render, and
the plugin log tail. Run it **from inside a herdr pane** — the variables herdr
injects there (`HERDR_PANE_ID`, `HERDR_SOCKET_PATH`, `HERDR_BIN_PATH`) are
exactly what a plain terminal lacks, and that difference is the usual cause.

Saved-machine targets **may be `ssh://user@host:port` URIs** (what `herdr machine
add` stores), not bare `user@host`. Older builds passed the scheme straight to
`ssh`, which then failed to resolve the host; the A-machine fixture for that
shape lives in `tests/difftest/run.sh` and the container-side
`A3` stage of `scripts/e2e/run-inside.sh`.

## Release installation and offline development

`herdr plugin install zzjcool/herdr-forward` runs `scripts/postinstall.sh` before
`forward-go` exists.  The POSIX installer maps `uname -s`/`uname -m` to one of
`linux_amd64`, `linux_arm64`, `darwin_amd64`, or `darwin_arm64`, downloads
`herdr-forward_<version>_<os>_<arch>.tar.gz` and `checksums.txt`, verifies the
SHA-256 with `sha256sum` or `shasum -a 256`, and atomically installs
`bin/forward-go`.  It then runs `forward internal install-keys` and attempts
`herdr server reload-config`.

Useful controls:

- `HERDR_FORWARD_BIN_BASE=<mirror>/...` overrides the Release download base;
- `HERDR_FORWARD_SKIP_DOWNLOAD=1` skips the network for offline E2E/local builds
  (an existing executable `bin/forward-go` is still required);
- missing fetch tools, unsupported platforms, bad checksums, and malformed
  archives fail with exit 1 and print the `git clone … && make build` recovery.

For local development:

```sh
make build
HERDR_FORWARD_SKIP_DOWNLOAD=1 ./scripts/postinstall.sh
./bin/forward list
```

Release smoke is intentionally separate from CI: after publishing a tagged
release, run `HERDR_E2E_ONLINE=1 bash scripts/e2e/run-real-install.sh` and follow
the [release checklist](docs/RELEASE-CHECKLIST.md), including the macOS smoke
checklist from PLAN-GO-MIGRATION §11.

## Usage

```sh
bin/forward add 3000:3000 --machine gpu-box   # remote 3000 -> localhost:3000
bin/forward list                              # table
bin/forward list --oneline                    # ⇅3000⇅5173 (what the tab bar runs)
bin/forward remove f-3000                     # tear the tunnel down
bin/forward doctor                            # probe tunnels, report status
bin/forward watch                             # the Port Forward panel (see below)
bin/forward bootstrap                         # (re)install the UI / print next steps
```

The `bin/forward` path is a small POSIX shim; all commands execute in the
release Go binary next to it. A normal install supplies the plugin state directory
through herdr. For a manual invocation, set `HERDR_PLUGIN_STATE_DIR` explicitly
if you want to inspect a non-default state directory:

```sh
HERDR_PLUGIN_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/herdr/plugins/zzjcool%3Aforward" \
  bin/forward list
```

In a herdr
session the same commands are reachable as plugin actions — `Port Forward:
Add…`, `List`, `Doctor`, and `Setup UI`
(`herdr plugin action invoke bootstrap --plugin zzjcool:forward`).

## The Port Forward panel

`prefix+f` opens the **Port Forward** pane, which runs `forward watch`. In an
interactive terminal that is a live panel, refreshed every 3 seconds:

```text
herdr-forward · Port Forward   刷新 3s · r 立即刷新 · x 退出
──────────────────────────────────────────────────────────────
FORWARDS (1)
  LOCAL  REMOTE                 STATUS    PID
  3000   127.0.0.1:9443         up        -
──────────────────────────────────────────────────────────────
MACHINES (2)  数字键 = 激活 / 停用
  [✓] 1. test-probe       user@b-host:22      （当前活动 · tab bar 指向该机）
  [·] 2. gpu-box          user@g-host:22      （已激活, 非当前 · 按 2 切回）
  [ ] 3. lab-pc           user@l-host:22      （未激活 · 按 3 探测并激活）
──────────────────────────────────────────────────────────────
按键: 1-9 选择机器（激活前会确认） · r 刷新 · a 添加转发用法 · x 退出
```

The top half is your forwarding table (the same `forwards.json` the tab bar
reads). The bottom half lists your **saved herdr machines**, three states deep:
`[✓]` is the machine the tab bar currently points at, `[·]` was activated before
but is not the current one (press its number to switch back), `[ ]` has never
been activated and is shown dimmed. Machines whose `ssh_target` is this very
host are marked local (no probe needed).

Pressing a number for a non-active machine asks for confirmation first —
`将通过 SSH 只读探测 <machine>，约 15 秒，继续? [y/N]` — and only then runs
`forward machines activate <id>`. The probe is read-only and bounded
(`timeout 15`, `BatchMode`), so it can never prompt for a password and never
hangs the panel: the `探测中…` placeholder appears before the probe starts.
`y`/`Enter` semantics are one keypress, not a line editor — the panel does not
wait for you to press Enter.

Non-interactive stdin (pipes, CI, scripts) is **not** the panel: `forward watch`
then degrades to the original `watch -n 3 forward list`, so nothing scripted
against it changes behaviour.

The panel is only a wrapper around the CLI — every action it performs is a
command you can type yourself (and should, if the panel ever misbehaves):

```sh
forward machines list                  # ID / LABEL / TARGET / STATE
forward machines list --json
forward machines activate gpu-box      # probe (read-only) + point the tab bar at it
forward machines deactivate gpu-box    # back to the local tab bar (idempotent)
forward machines doctor                # re-probe the active machine, rewrite if its paths moved
```

Activation is a single-machine switch: activating another machine keeps the
historical records but moves the tab bar, and `deactivate` restores the local
paths. The `[[startup]]` hook follows the same record — on every server start it
reads `activated-machines.json` and, if the active machine is a *remote* one,
points the tab bar at that machine's plugin root and state dir (no SSH probe on
the startup path: it must be instant, so it trusts what activation recorded).
Anything unexpected — no active machine, an active one that is this host,
a truncated record, a corrupt JSON file, a missing machine record — degrades
to the plain local behaviour, and the hook always exits 0.

## Remote development: B's ports on A's localhost

The VS Code Remote workflow: herdr runs on your laptop **A**, you have saved a
machine **B** (`herdr machine add`) and do your work in B's workspaces. A dev
server started on B (`npm run dev` → `:5173`) should open in **A's** browser at
`http://localhost:5173`.

1. **Install the plugin on A** (`herdr plugin install zzjcool/herdr-forward`).
2. **Activate B** from A's Port Forward panel (`prefix+f` while viewing Local,
   press B's number) or with `forward machines activate <B>`. The plugin probes B
   over SSH (read-only, `BatchMode`):
   - B has no plugin → it **asks** `现在在 B 上安装吗？[y/N]` and, on `y`, runs
     `herdr plugin install zzjcool/herdr-forward --yes` on B for you
     (`--install` answers yes non-interactively; without consent it only prints
     the command).
   - It then sets up **B's** keybindings and reloads B's server — herdr resolves
     `prefix+f` from the config of the machine you are viewing, not from A's.
   - Finally it starts the **bridge**: one SSH session from A to B, supervised in
     the background (reconnects with backoff, restarted by A's startup hook).
3. **Map ports while viewing B.** `prefix+f` on B opens B's panel. It shows
   `CLIENT  <A> 已连接` and a `LISTENING` list of B's open ports; press `f` then
   the port's number and A starts listening on `localhost:<port>`, forwarding to
   B's `localhost:<port>`. The mapping appears in B's tab bar (`⇅5173`) once A
   reports it up. From a B shell, the same is `forward add 5173` (or
   `forward add 15173:5173` for a different local port on A).
4. **Ctrl+click** `http://localhost:5173` in a B pane: the port is mapped if it
   wasn't already, and the URL opens in **A's** browser.

```text
A (laptop)                                   B (saved machine)
 herdr client ── herdr's own SSH ─────────▶  herdr server, your panes
 forward bridge run ── SSH session ───────▶  forward bridge serve
   listens 127.0.0.1:5173 / [::1]:5173  ◀──  forwards.json: f-5173 mode=client
   (ssh -O forward on that session)          dev server on localhost:5173
```

Mappings are declared on B and survive disconnects: when A goes away they show
`waiting`, and they come back by themselves when the bridge reconnects. A busy
port on A is reported as `down` with the reason and retried every few seconds.

```sh
# on B
forward add 5173                # map B:5173 → A's localhost:5173
forward list                    # MACHINE column: client:<A>, live status
forward ports                   # B's listening ports, and which are mapped
forward remove f-5173
forward bridge status           # which clients are attached right now

# on A
forward bridge status           # bridges to your machines and their mappings
forward machines doctor         # re-probe the active machine, restart its bridge
forward machines deactivate <B> # stops the bridge; A's listeners go away with it
```

`scripts/e2e/run-two-machines.sh` walks through all of this the way a person
would, with nobody at the keyboard: two containers on a private network, A and
B each running a real herdr and sshd (different users and plugin paths), and
A's **real herdr TUI** running inside tmux, which types the keys and reads the
screen back. It runs `herdr machine add`, opens herdr, presses `prefix+f` / `1` /
`y` to activate B, switches to B with `prefix+w`, presses `prefix+f` / `f` / `1`
in B's panel, reads `⇅5173` off the tab bar, Ctrl+clicks a URL in B's pane, drops
A's network, restarts A's herdr server, and deactivates B from the panel —
checking the screen and, independently, what A's `localhost` actually serves.
`scripts/ci.sh` runs it after the docker E2E when the host's herdr can run inside
the container.

**Trust boundary.** A enforces what B may ask for: A-side ports ≥ 1024, bound to
A's loopback only, targets fixed to B's `localhost`, at most 32 mappings, and
Ctrl+click opens only `http(s)://localhost` URLs of ports the bridge has mapped.
The bridge session runs with your `~/.ssh/config` (aliases, `ProxyJump`, keys)
but forces `ForwardAgent=no`, `ForwardX11=no` and `ClearAllForwardings=yes`.
What B *can* do is listen on a free loopback port of A — the same trust you give
VS Code Remote's port forwarding; do not activate machines you do not trust.

## Related work

- [miko-misa/herdr-portfwd](https://github.com/miko-misa/herdr-portfwd) — `--remote` era, ControlMaster based
- [go-min/herdr-fwd](https://github.com/go-min/herdr-fwd) — auto-forwards the attached remote session's loopback
- [ivorpad/herdr-tunnel](https://github.com/ivorpad/herdr-tunnel) — exposes local ports publicly

herdr-forward differs: explicit per-machine mappings over 0.9 saved SSH
machines, with a first-class panel — plus optional Cloudflare publish.

## License

Apache-2.0
