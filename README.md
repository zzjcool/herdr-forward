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

- **Explicit mappings** on saved machines (0.9+), not auto-forward-everything
- **Three-layer UI**: tab bar status entry, a Port Forward pane, notifications
- **Ctrl+click** `localhost:PORT` links anywhere in herdr

## Status

Pre-alpha. See `docs/PLAN.md` (roadmap) and `docs/RESEARCH.md`
(herdr plugin-capability research).

## Install

Requires herdr ≥ 0.8.0 and `jq` (plus `ssh` for the tunnels). The plugin installs
with the `zzjcool:forward` id.

### A. From GitHub (once published)

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
So the plugin ships two idempotent installers plus one one-shot command that runs
both:

```sh
# after linking/installing the plugin — run from the plugin checkout,
# or from anywhere via the `forward` CLI (`bin/forward bootstrap`)
./scripts/bootstrap.sh          # tab bar status entry + 3 keybindings
./scripts/bootstrap.sh --dry-run  # preview first, writes nothing
```

Afterwards press `prefix+q` (or run `herdr server reload-config`) to apply it.

**What happens automatically (same machine):** if your herdr server and your
herdr client run on the same machine (the common local case), the plugin's
`[[startup]]` hook runs `scripts/startup-hook.sh` once the server is up. It
detects the missing tab-bar entry and installs it for you — no manual step, and
idempotent so it does nothing on subsequent starts. The hook writes the config
file; the running server picks it up on the next `reload-config` (the hook itself
cannot reload, and a hook failure never stops the server). The tab bar entry is
the automatic part; the optional keybindings are not installed by the hook —
run `bootstrap.sh` once if you want them.

**What still takes one step (cross-machine):** `tab_bar_right` is *presentation*
config owned by the client, even though the `command` inside it runs on the
*server*. When you attach from machine A to a server on machine B, the plugin
process on B cannot reach A's filesystem — a physical boundary, not an
oversight. In that case:

- On B (the server), the startup hook only logs a hint; nothing is written to A.
- To get the tab bar on A, run the installer **on A**, pointing it at A's config:

  ```sh
  # on machine A, with the plugin checkout available there
  <plugin-root>/scripts/bootstrap.sh --config ~/.config/herdr/config.toml
  ```

  or paste this block into A's `~/.config/herdr/config.toml` by hand (it is the
  exact block the installer writes — the `command` runs on B and renders on A):

  ```toml
  [ui]
  tab_bar_right = [
    # herdr-forward: tab bar status entry (managed by scripts/install-tabbar.sh)
    { type = "command", command = "env HERDR_PLUGIN_STATE_DIR='<server-state-dir>' \"<server-plugin-root>/bin/forward\" list --oneline", interval_seconds = 5, timeout_seconds = 2 },
  ]
  ```

  and, for the keybindings:

  ```toml
  # herdr-forward: keybindings (managed by scripts/install-keys.sh)
  [[keys.command]]
  key = "prefix+f"
  type = "plugin_action"
  command = "zzjcool:forward.add"
  description = "Port Forward: Add / open panel"

  [[keys.command]]
  key = "prefix+shift+f"
  type = "plugin_action"
  command = "zzjcool:forward.list"
  description = "Port Forward: List forwards"

  [[keys.command]]
  key = "prefix+alt+f"
  type = "plugin_action"
  command = "zzjcool:forward.doctor"
  description = "Port Forward: Doctor (probe tunnels)"
  ```

  **`<server-plugin-root>` is the path to this plugin's checkout on the *server*
  (B)** — not on A. The tab-bar `command` is executed by herdr *on the server*,
  under `/bin/sh -lc`, in an environment that does **not** contain
  `HERDR_PLUGIN_ROOT` (that variable is only injected for plugin actions, panes
  and startup commands) **nor `HERDR_PLUGIN_STATE_DIR`** (same reason). So the
  command must be a literal absolute path that exists on B, plus an explicit
  `env HERDR_PLUGIN_STATE_DIR=…` prefix pointing at **B's** plugin state
  directory — `<XDG_STATE_HOME>/herdr/plugins/zzjcool%3Aforward`
  (`~/.local/state/herdr/plugins/zzjcool%3Aforward` by default, on B). Without
  that prefix `bin/forward` falls back to `~/.local/state/herdr-forward`, so the
  tab bar reads a different `forwards.json` than the one your panel writes —
  the status bar would always be blank. Replace the placeholders by hand, or let
  the installer do it:

  ```sh
  # on A, pointing at B's plugin checkout and B's state dir
  <plugin-root>/scripts/bootstrap.sh --config ~/.config/herdr/config.toml \
    --plugin-root <server-plugin-root> \
    --state-dir <server-state-dir>
  ```

  (`--state-dir` defaults to `$HERDR_PLUGIN_STATE_DIR` when set, else to
  `${XDG_STATE_HOME:-$HOME/.local/state}/herdr/plugins/zzjcool%3Aforward`;
  cross-machine you must pass B's value, as above.)

  If it is already installed with the old `$HERDR_PLUGIN_ROOT` form, or with the
  absolute-path form that predates the state-env fix, just re-run the command
  above: the installer detects the stale entry and rewrites it in
  place (keeping your `interval_seconds`/`timeout_seconds`).

If you are already in a herdr session on the server, the same one-shot install is
available as a plugin action (useful right after `herdr plugin link`):

```sh
herdr plugin action invoke bootstrap --plugin zzjcool:forward
```

#### The installers

| Script | Adds | Notes |
|---|---|---|
| `scripts/install-tabbar.sh` | `[ui].tab_bar_right` command entry showing `⇅3000⇅5173` | `--config PATH`, `--plugin-root PATH`, `--state-dir PATH`, `--command CMD`, `--dry-run` |
| `scripts/install-keys.sh` | 3 `[[keys.command]]` plugin-action bindings | `--config PATH`, `--add-key/--list-key/--doctor-key`, `--dry-run` |
| `scripts/bootstrap.sh` | both of the above + next steps | `--config PATH`, `--plugin-root PATH`, `--state-dir PATH`, `--dry-run`, `--no-tabbar`, `--no-keys`, key overrides |
| `scripts/startup-hook.sh` | nothing directly — the `[[startup]]` hook that calls `install-tabbar.sh` | never fails the server; degrades to a log line cross-machine |

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
| `prefix+f` | open the Port Forward panel (`add`/`remove` happen there) |
| `prefix+shift+f` | list current forwards |
| `prefix+alt+f` | doctor — probe tunnels |

Override them with `--add-key/--list-key/--doctor-key`. If a key is already
bound to something else the installer warns and still installs (so a collision is
visible rather than silent), so pass a different key if the warning fires.

### D. Ctrl+click links

The plugin registers a link handler so that localhost URLs in pane output open
in your browser. herdr only recognises URLs that carry a scheme, so the link
must be written as `http://localhost:3000` — a bare `localhost:3000` will not be
clickable.

## Usage

```sh
bin/forward add 3000:3000 --machine gpu-box   # remote 3000 -> localhost:3000
bin/forward list                              # table
bin/forward list --oneline                    # ⇅3000⇅5173 (what the tab bar runs)
bin/forward remove f-3000                     # tear the tunnel down
bin/forward doctor                            # probe tunnels, report status
bin/forward bootstrap                         # (re)install the UI / print next steps
```

Run it from the plugin checkout (or as `"$HERDR_PLUGIN_ROOT/bin/forward"` in a
herdr plugin context — note that this env var is **not** set for tab-bar
commands, which is why the installer writes an absolute path there; the same
goes for `HERDR_PLUGIN_STATE_DIR`, which is why the installer also writes an
explicit `env HERDR_PLUGIN_STATE_DIR=…` prefix). A bare `bin/forward` invoked
outside a herdr plugin context has no `HERDR_PLUGIN_STATE_DIR`, so it falls back
to `~/.local/state/herdr-forward` and will look empty even while the panel shows
active forwards — pass the variable explicitly if you want to inspect the
plugin's real state:

```sh
HERDR_PLUGIN_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/herdr/plugins/zzjcool%3Aforward" \
  bin/forward list
```

In a herdr
session the same commands are reachable as plugin actions — `Port Forward:
Add…`, `List`, `Doctor`, and `Setup UI`
(`herdr plugin action invoke bootstrap --plugin zzjcool:forward`).

## Related work

- [miko-misa/herdr-portfwd](https://github.com/miko-misa/herdr-portfwd) — `--remote` era, ControlMaster based
- [go-min/herdr-fwd](https://github.com/go-min/herdr-fwd) — auto-forwards the attached remote session's loopback
- [ivorpad/herdr-tunnel](https://github.com/ivorpad/herdr-tunnel) — exposes local ports publicly

herdr-forward differs: explicit per-machine mappings over 0.9 saved SSH
machines, with a first-class panel — plus optional Cloudflare publish.

## License

Apache-2.0
