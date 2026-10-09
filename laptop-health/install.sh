#!/usr/bin/env bash
# Installs (or updates) the laptop health check as a systemd *user* timer. No sudo.
#   ./install.sh               install, or update after changing the script or conf
#   ./install.sh --uninstall   stop and remove the timer and the installed copy
# The running copy lives in ~/.local/lib/laptop-health, not in this Syncthing'd folder,
# so nothing that syncs in can change what runs until you run this again.
set -euo pipefail
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
LIB="$HOME/.local/lib/laptop-health"
UNITS="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"

if [ "${1:-}" = "--uninstall" ]; then
  systemctl --user disable --now laptop-health.timer 2>/dev/null || true
  rm -f "$UNITS/laptop-health.service" "$UNITS/laptop-health.timer"
  rm -rf "$LIB"
  systemctl --user daemon-reload
  echo "removed (state kept in ~/.local/state/laptop-health)"; exit 0
fi

mkdir -p "$LIB" "$UNITS"
install -m 755 "$HERE/laptop-health.sh" "$LIB/"
[ -f "$HERE/laptop-health.conf" ] || cp "$HERE/laptop-health.conf.example" "$HERE/laptop-health.conf"   # first install: set NTFY_URL in it
install -m 644 "$HERE/laptop-health.conf" "$LIB/"
install -m 644 "$HERE/laptop-health.service" "$HERE/laptop-health.timer" "$UNITS/"
systemctl --user daemon-reload
systemctl --user enable --now laptop-health.timer
[ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null)" = yes ] \
  || echo "note: lingering is off, so checks stop when you log out (sudo loginctl enable-linger $USER)"
echo; "$LIB/laptop-health.sh" --report
