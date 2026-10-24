#!/usr/bin/env bash
# Bring OpenClaw back on the laptop: the CLI, the gateway service and the watchdog.
# Safe to run again. Steps that need you (API key, WhatsApp QR, phone pairing) are printed.
#     ./openclaw/install.sh
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
export PATH="$HOME/.npm-global/bin:$PATH"
log() { printf '\n== %s\n' "$*"; }

log "OpenClaw CLI (npm, user prefix ~/.npm-global; Node from pacman, not mise)"
command -v node >/dev/null || sudo pacman -S --needed --noconfirm nodejs npm
[ "$(npm config get prefix)" = "$HOME/.npm-global" ] || npm config set prefix "$HOME/.npm-global"
command -v openclaw >/dev/null || npm install -g openclaw@latest --allow-scripts=openclaw
grep -q 'npm-global/bin' ~/.bashrc 2>/dev/null || echo 'export PATH="$HOME/.npm-global/bin:$PATH"   # openclaw' >> ~/.bashrc
openclaw --version

log "Watchdog"
install -Dm755 "$HERE/openclaw-watchdog" ~/.local/bin/openclaw-watchdog
install -Dm644 "$HERE/openclaw-watchdog.service" "$HERE/openclaw-watchdog.timer" -t ~/.config/systemd/user/
systemctl --user daemon-reload && systemctl --user enable --now openclaw-watchdog.timer && echo "openclaw-watchdog.timer on"

log "Gateway"
if [ ! -f ~/.openclaw/openclaw.json ]; then
  cat <<'TXT'
Not set up yet. In a terminal on the laptop:
  openclaw onboard                         # pick the model provider and paste its API key
  openclaw channels login                  # WhatsApp: scan the QR with the phone
  openclaw config set gateway.bind tailnet
  openclaw config set gateway.tls.enabled true   # the Android app needs wss:// over Headscale
  openclaw gateway install                 # the systemd user service
  openclaw qr                              # pair the S25 app (single-use code, 10 minutes)
Then run this script again to check.
Keep OpenClaw's file access away from ~/Axon and ~/Projects: both sync to the homelab.
TXT
else
  systemctl --user is-active --quiet openclaw-gateway.service && echo "gateway running" \
    || echo "gateway not running: openclaw gateway install, then openclaw gateway status"
  openclaw channels status 2>/dev/null | head -n 15
fi
