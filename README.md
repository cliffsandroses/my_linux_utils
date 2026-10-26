# forge

Moosa's own tools, made when he wants to use something (2026-10-26). Instead of installing an ad-filled store app or
signing up for a service, the need gets written down here and a small tool gets built: free, open source, local-first,
reachable from Soma.

## How a tool gets made

1. **Ask.** `bin/new-tool <name>` copies `TEMPLATE.md` to `tools/<name>/README.md`. Fill in four lines: what you want
   to do, where you'll use it (laptop, phone, homelab, desk), what "done" looks like, and anything it must never do.
2. **Look first.** Before building, check for an existing FOSS tool (F-Droid, GitHub, awesome-selfhosted). If one fits,
   the tool is a thin wrapper or a config, not a new app. Write what was found in the README.
3. **Build small.** One folder per tool. Pick the lightest shape that works:
   | Shape | When | Lives |
   |---|---|---|
   | CLI script | laptop or homelab, no screen needed | `~/.local/bin` via `bin/install` |
   | Soma page / artifact | you want to see or tap it | Soma → Vault → Artifacts |
   | Homelab service | it runs on its own (timers, watchers) | the VM, a systemd user unit, shown in Soma → Services |
   | PWA | on the S25 | served by Soma, add to home screen |
   | Firmware | a gadget on the desk | ESP32, flashed from the laptop |
4. **Ship.** It's done when the README's "done when" line is true, it shows up in Soma (a link, a tile or a service),
   and the Docket in Nucleus has its proof.

## Rules

- FOSS only; every dependency linked to its source.
- Local-first: data stays on the laptop or the homelab; no accounts unless unavoidable.
- No secrets in the repo: tokens live in `~/.config/<tool>/` and are read at run time.
- Each tool can be deleted without breaking another.

## Tools

| Tool | Status | What |
|---|---|---|
| [desk-display](tools/desk-display/PLAN.md) | planned | ESP32 + OLED on the desk: homelab health, downloads, now playing, an approve button |

Older tools that fit this pattern and could move here: Deal Check (`~/Projects/deals`), `reel` (no-account Instagram
fetch), the clipper (`~/Projects/clipper`), phone-approve.

## Ideas waiting for a need

Write the need first, then the tool. Candidates seen so far: a watch-later digest, a receipt/warranty keeper, a
room sensor for the desk display, a spending log fed from SMS, a one-tap "I'm streaming" switch.
