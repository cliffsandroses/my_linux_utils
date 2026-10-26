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

Single-file tools live here and are linked into `~/.local/bin` (moved in 2026-10-26; the commands work as before).
Bigger tools keep their own repo; forge lists them so there is one place to look.

| Tool | Where | What |
|---|---|---|
| [automode](tools/automode/automode) | here → `~/.local/bin` | stream / dev / idle mode every 20 s: pauses OpenClaw and heavy jobs while you stream or work |
| [freellm](tools/freellm/freellm) | here | ask the homelab's FreeLLMAPI (free models, smart routing); key read at run time |
| [reel](tools/reel/reel) | here | fetch an Instagram reel's video and caption without your own account |
| [yt-history-sync](tools/yt-history-sync/yt-history-sync) | here | your YouTube watch history → Soma → Media → Watched, every 6 h |
| [openclaw-watchdog](tools/openclaw-watchdog/openclaw-watchdog) | here | restarts OpenClaw when a linked chat channel goes unhealthy |
| [chiaki-launch](tools/chiaki-launch/chiaki-launch) | here | PS5 Remote Play launcher (chiaki-ng) |
| clip, kaggle-run | `~/Projects/clipper` | stream clips (GPU transcription on Kaggle, captions, punch zooms) and the Kaggle GPU jobs |
| Deal Check | `~/Projects/deals` + Soma artifact | rates second-hand listings; searches OLX Bangalore every 3 h |
| Soma | `~/Projects/axon-dashboard` | the homelab control panel |
| Nucleus + Docket | `~/Projects/my_linux_utils/homelab/web` | the detailed status page and your asks checklist |
| asks-collect | `~/Projects/my_linux_utils/asks` | collects your asks into the Docket |
| grab-button | `~/Projects/grab-button` | the reel-matched grabbing-arm button |
| ipscrub | `~/Projects/ipscrub` | scrub client/IP details from documents |
| pcai-search | `~/Projects/pcai-search` | the PC-for-AI parts finder |
| [desk-display](tools/desk-display/PLAN.md) | planned | ESP32 + OLED on the desk |
| [album-scan](tools/album-scan/README.md) | planned | digitise the photo albums into Immich |
| [sell-it](tools/sell-it/README.md) | planned | turn things you want gone into priced OLX listings |
| [tv-tidy](tools/tv-tidy/README.md) | planned | debloat the TV over ADB, with an undo log |

## Ideas waiting for a need

Write the need first, then the tool. Candidates seen so far: a watch-later digest, a receipt/warranty keeper, a
room sensor for the desk display, a spending log fed from SMS, a one-tap "I'm streaming" switch.
