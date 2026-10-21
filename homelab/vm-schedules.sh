#!/usr/bin/env bash
# Everything on the homelab VM that runs on a clock. Run on the VM.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
HL="$HOME/homelab"

log "Crontab ($VM_USER)"
cur=$(crontab -l 2>/dev/null)
for l in "${CRONTAB_LINES[@]}"; do
  if printf '%s\n' "$cur" | grep -qxF -- "$l"; then ok "${l:0:90}"
  else diff_ "missing: ${l:0:90}"; cur=$(printf '%s\n%s\n' "$cur" "$l"); [ "$CHECK" = 1 ] || printf '%s\n' "$cur" | crontab -; fi
done

log "Root cron jobs"
want "/etc/cron.d/qbt-guard" sudo grep -qxF -- "$CRON_D_QBT_GUARD" /etc/cron.d/qbt-guard || \
  run sh -c "echo '$CRON_D_QBT_GUARD' | sudo tee /etc/cron.d/qbt-guard >/dev/null"

log "User services and timers (they run without a login: linger)"
want "linger" test -f "/var/lib/systemd/linger/$VM_USER" || run sudo loginctl enable-linger "$VM_USER"
[ "$CHECK" = 1 ] || user_systemctl daemon-reload
for u in $USER_SERVICES $USER_TIMERS; do
  if ! user_systemctl cat "$u" >/dev/null 2>&1; then diff_ "$u is not installed (vm-restore.sh / vm-apps.sh put it back)"; continue; fi
  want "$u on" user_systemctl is-active --quiet "$u" || run user_systemctl enable --now "$u"
done
for u in $USER_TIMERS_OFF; do
  user_systemctl cat "$u" >/dev/null 2>&1 || continue
  want "$u off (what it needs isn't back yet)" sh -c "! XDG_RUNTIME_DIR=/run/user/$(id -u) systemctl --user is-active --quiet $u" \
    || run user_systemctl disable --now "$u"
done

log "Health check (system timer, alerts to ntfy on change)"
want "homelab-health.timer on" systemctl is-active --quiet homelab-health.timer || run sudo "$HL/health/install.sh"

finish
