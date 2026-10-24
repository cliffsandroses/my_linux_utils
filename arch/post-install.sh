#!/usr/bin/env bash
# After arch-apps.sh: the machine-level fixes the 2026-10-21 rebuild needed, in one place.
# Each step checks first and skips what is already done, so it is safe to run again.
#
#     ./post-install.sh                 # everything
#     HS_KEY=hskey-auth-... ./post-install.sh   # also join the tailnet (key from Headscale)
#
# Make a Headscale join key on the homelab VM:
#     docker exec headscale headscale preauthkeys create --user 2 --expiration 1h
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"; REPO="$(dirname "$HERE")"
# shellcheck source=../profiles/moosa.env
[ -f "$REPO/profiles/${PROFILE:-moosa}.env" ] && . "$REPO/profiles/${PROFILE:-moosa}.env"
IFACE="${LAPTOP_IFACE:-enp2s0}"; IP="${LAPTOP_IP:-192.168.10.30}/${LAN_CIDR:-24}"; GW="${GATEWAY:-192.168.10.1}"
DNS="${LAPTOP_DNS:-192.168.10.20 192.168.10.10}"     # AdGuard on the VM, then the DNS fallback CT
HS_URL="${HEADSCALE_URL:-https://hs.meldev.duckdns.org}"
log() { printf '\n== %s\n' "$*"; }
sudo -v || exit 1

log "Quiet shells: no 'ttyname error' in terminal-less shells"
# gpm's profile script runs `tty`, which complains in any shell without a terminal (Claude Code's
# ! commands, cron). It only disables paste for the text-console mouse. gpm itself must stay: vim needs it.
sudo rm -f /etc/profile.d/gpm.sh
grep -q '^NoExtract.*etc/profile.d/gpm.sh' /etc/pacman.conf \
  || sudo sed -i '/^\[options\]/a NoExtract = etc/profile.d/gpm.sh' /etc/pacman.conf

log "Ethernet: static $IP"
# The homelab pushes its nightly offsite copy to moosa@192.168.10.30 (~/homelab/backup). A DHCP
# address breaks that silently. Wi-Fi stays on DHCP as the fallback.
con=$(nmcli -t -f NAME,DEVICE con show | awk -F: -v d="$IFACE" '$2==d{print $1; exit}')
if [ -n "$con" ]; then
  nmcli con modify "$con" ipv4.method manual ipv4.addresses "$IP" ipv4.gateway "$GW" ipv4.dns "$DNS" \
    && nmcli con up "$con" >/dev/null && ip -br -4 addr show "$IFACE"
else
  echo "No active connection on $IFACE: plug in Ethernet and run this again."
fi

log "Tailscale (Headscale)"
sudo systemctl enable --now tailscaled >/dev/null 2>&1
if tailscale status >/dev/null 2>&1; then
  echo "Already on the tailnet: $(tailscale ip -4)"
elif [ -n "${HS_KEY:-}" ]; then
  # --accept-routes=false: with routes on, Proxmox's advertised 192.168.10.0/24 pulls LAN replies
  # into the tunnel and the laptop stops answering on the LAN (found 2026-09-20).
  sudo tailscale up --login-server "$HS_URL" --authkey "$HS_KEY" --hostname "$(hostname | tr A-Z a-z)" \
    --accept-routes=false --accept-dns=false && tailscale ip -4
else
  echo "Not joined. Make a key on the VM (see the top of this script), then: HS_KEY=... $0"
fi

log "Syncthing"
systemctl --user enable --now syncthing.service >/dev/null 2>&1 && echo "running"
# .stignore is per-device and never syncs, so a fresh machine has none. Projects keeps .git on
# purpose (code needs its history); Axon's own .stignore travels inside the vault's backups.
if [ -d ~/Projects ] && [ ! -f ~/Projects/.stignore ]; then
  cp "$REPO/syncthing/projects.stignore" ~/Projects/.stignore && echo "~/Projects/.stignore installed"
fi

log "KDE file search: keep backups and code out of the index"
# Baloo indexed 118,854 files on the first day, most of them the homelab's offsite copy.
B=$(command -v balooctl6 || command -v balooctl || true)
if [ -n "$B" ]; then
  for d in ~/homelab-offsite ~/rescue ~/Projects; do
    $B config list excludeFolders 2>/dev/null | grep -q "$d/" || $B config add excludeFolders "$d" 2>/dev/null
  done
  $B config list excludeFolders 2>/dev/null
fi

log "Lid: ${LAPTOP_LID:-suspend}"
if [ "${LAPTOP_LID:-suspend}" = ignore ]; then
  # Two layers: KDE's power settings while logged in, systemd-logind at the login screen.
  K=$(command -v kwriteconfig6 || command -v kwriteconfig5 || true)
  if [ -n "$K" ]; then
    for g in AC Battery LowBattery; do
      $K --file powerdevilrc --group $g --group SuspendAndShutdown --key LidAction 0
      $K --file powerdevilrc --group $g --group SuspendAndShutdown --key AutoSuspendAction 0
    done
    echo "KDE: lid closed does nothing, no automatic sleep"
  fi
  sudo mkdir -p /etc/systemd/logind.conf.d
  printf '[Login]\nHandleLidSwitch=ignore\nHandleLidSwitchExternalPower=ignore\nHandleLidSwitchDocked=ignore\n' \
    | sudo tee /etc/systemd/logind.conf.d/lid-ignore.conf >/dev/null
  echo "logind: lid ignored (applies after the next reboot, or: sudo systemctl kill -s HUP systemd-logind)"
fi

log "My services: health check and nightly backup"
[ -f "$REPO/laptop-health/laptop-health.conf" ] || echo "Copy laptop-health.conf.example to laptop-health.conf and set NTFY_URL first."
"$REPO/laptop-health/install.sh" >/dev/null 2>&1 && echo "laptop-health installed"
systemctl --user link "$REPO"/pc-backup/pc-backup.{service,timer} >/dev/null 2>&1
systemctl --user enable --now pc-backup.timer >/dev/null 2>&1 && echo "pc-backup.timer on"

log "Still by hand"
cat <<'EOF'
- Fingerprint:        ./arch/fingerprint.sh
- PS5 Remote Play:    ./arch/ps5-remote-play.sh  (pairing needs the PIN from the TV)
- LUKS header copy:   ./luks-header-backup.sh  (only if the disk is encrypted)
- Kopia:              RESTORE.md 1.6, then `systemctl --user start pc-backup.service`
                      and check it ends with "Kopia snapshot of ~ taken at ..."
EOF
