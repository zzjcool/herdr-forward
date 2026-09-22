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

## Install (once published)

```
herdr plugin install zzjcool/herdr-forward
```

Local development:

```
herdr plugin link ~/code/herdr-forward
```

## Related work

- [miko-misa/herdr-portfwd](https://github.com/miko-misa/herdr-portfwd) — `--remote` era, ControlMaster based
- [go-min/herdr-fwd](https://github.com/go-min/herdr-fwd) — auto-forwards the attached remote session's loopback
- [ivorpad/herdr-tunnel](https://github.com/ivorpad/herdr-tunnel) — exposes local ports publicly

herdr-forward differs: explicit per-machine mappings over 0.9 saved SSH
machines, with a first-class panel — plus optional Cloudflare publish.

## License

Apache-2.0
