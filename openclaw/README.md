# OpenClaw on the laptop

The chat gateway (WhatsApp and the S25 app) runs on the laptop, not the homelab VM: the VM
has no RAM to spare for it. Background, decisions and gotchas: `~/Axon/Workstation/openclaw-on-omarchy.md`.

```bash
./openclaw/install.sh      # CLI, watchdog timer, and the setup steps that need you
```

- `openclaw-watchdog` (user timer, every 5 min) restarts the gateway when a linked channel is
  unhealthy, at most once per 30 minutes, and nags to relink a logged-out one. It exists because
  a dead channel never recovers on its own (openclaw/openclaw#146999).
  `journalctl --user -t openclaw-watchdog` shows what it did.
- `laptop-health` alerts the phone about a stopped gateway, a dead or logged-out channel and
  every watchdog restart.
- `~/.openclaw` (API key, WhatsApp session, TLS pin) is only on the laptop. It is in the nightly
  Kopia snapshot of `~` once Kopia is connected (RESTORE.md 1.6); before that, a wipe loses it.
