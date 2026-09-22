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

### C. Tab bar status entry (optional)

The Port Forward tab-bar entry shows the active forwards as `⇅3000⇅5173` on the
right-hand side of the tab bar. Install it with the bundled helper — it edits
`~/.config/herdr/config.toml` for you:

```sh
# preview first (writes nothing)
./scripts/install-tabbar.sh --dry-run

# install (backs up the original to config.toml.bak.<epoch>)
./scripts/install-tabbar.sh

# when installed from GitHub, run the copy inside the plugin checkout:
#   "$HERDR_PLUGIN_ROOT/scripts/install-tabbar.sh"
```

Then reload herdr's config (`reload-config`). The helper is idempotent:
re-running it detects its own entry and leaves the file untouched. To pin a
different command (e.g. an absolute path), pass `--command '...'`; to target a
non-default config, pass `--config /path/to/config.toml`. It adds roughly:

```toml
[ui]
tab_bar_right = [
  # herdr-forward: tab bar status entry (managed by scripts/install-tabbar.sh)
  { type = "command", command = "\"$HERDR_PLUGIN_ROOT/bin/forward\" list --oneline", interval_seconds = 5, timeout_seconds = 2 },
]
```

### Ctrl+click links

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
```

## Related work

- [miko-misa/herdr-portfwd](https://github.com/miko-misa/herdr-portfwd) — `--remote` era, ControlMaster based
- [go-min/herdr-fwd](https://github.com/go-min/herdr-fwd) — auto-forwards the attached remote session's loopback
- [ivorpad/herdr-tunnel](https://github.com/ivorpad/herdr-tunnel) — exposes local ports publicly

herdr-forward differs: explicit per-machine mappings over 0.9 saved SSH
machines, with a first-class panel — plus optional Cloudflare publish.

## License

Apache-2.0
