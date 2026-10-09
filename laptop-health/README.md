# Laptop health check

Runs every 5 minutes as a systemd **user** timer on the Omarchy laptop. Messages the phone
through ntfy (same topic as the homelab VM, titles start with `laptop:`) **only when something
changes** — a new problem, a fix, or a recovery. A healthy laptop sends nothing, and a closed
lid sends nothing, because nothing runs while it sleeps.

A problem has to be there on 2 runs in a row (`CONFIRM_RUNS`) before it is sent, so Wi-Fi
reconnecting after a resume does not page you. If the laptop is offline when an alert is due,
it is sent on the next run that has internet.

| Check | Fixes it itself? |
|---|---|
| OpenClaw gateway service running | Restarts it once if it **crashed** — never if you stopped it |
| OpenClaw channels (WhatsApp…) healthy, using the gateway's own `healthState` | No — the `openclaw-watchdog` timer restarts; this tells you |
| A linked channel logged out | No — relink: `openclaw channels login` |
| The gateway restarted unexpectedly (the watchdog acting, or a crash) | Reported as "fixed itself" |
| `openclaw-watchdog.timer` running | No |
| Syncthing running, `tailscaled` running, laptop on the tailnet | No |
| Any failed systemd unit, system or user | No |
| `/` and `/home` below 90% | No |
| Out-of-memory kills | No (needs a readable journal) |

A problem that is still there gets one reminder every 12 h (`REMIND_HOURS`).

## Install / update / remove (on the laptop)
```
~/Projects/my_linux_utils/laptop-health/install.sh              # install, or update after an edit
~/Projects/my_linux_utils/laptop-health/install.sh --uninstall
```
The running copy is in `~/.local/lib/laptop-health/`, not in this synced folder, so an edit
that syncs in does nothing until you run `install.sh` again.

## Use
```
~/.local/lib/laptop-health/laptop-health.sh --report   # look, don't touch
journalctl --user -u laptop-health -n 30              # what the timer did
```
