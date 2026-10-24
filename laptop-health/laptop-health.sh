#!/usr/bin/env bash
# Laptop health check. laptop-health.timer (a systemd *user* timer) runs it every 5 minutes.
#
# Same idea as the homelab VM's ~/homelab/health: check, fix what is safe to fix, and message
# the phone (ntfy) only when something CHANGES — a new problem, a fix, or a recovery. A healthy
# laptop sends nothing. While the laptop is asleep nothing runs, so a closed lid is silent.
#
#   laptop-health.sh            check, fix, alert — what the timer runs
#   laptop-health.sh --report   check only: no fixes, no alerts, just a table
#
# A problem must show up on CONFIRM_RUNS runs in a row before it is sent, so the Wi-Fi coming
# back after a resume does not page you. Settings: laptop-health.conf next to this script.
set -uo pipefail
umask 022
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=laptop-health.conf
. "${LAPTOP_HEALTH_CONF:-$HERE/laptop-health.conf}"

REPORT=0; [ "${1:-}" = "--report" ] && REPORT=1
CAN_FIX=$(( 1 - REPORT ))
STATE_DIR="${STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/laptop-health}"
NOW=$(date +%s)
export PATH="$HOME/.npm-global/bin:$HOME/.local/bin:$HOME/.local/share/mise/shims:/usr/local/bin:/usr/bin:$PATH"

names=(); states=(); details=()
record() { names+=("$1"); states+=("$2"); details+=("$3"); }   # name, ok|fixed|warn|fail|event, detail
# event = a one-off that already happened (an OOM kill): sent at once, no "back to normal".

# DNS-over-HTTPS first, so alerts still get out when local DNS is what broke.
send() {  # url [curl args...]
  local url=$1; shift
  curl --doh-url https://1.1.1.1/dns-query -sf -m 15 "$@" "$url" >/dev/null 2>&1 \
    || curl -sf -m 15 "$@" "$url" >/dev/null 2>&1
}

mkdir -p "$STATE_DIR"
declare -A P_REP P_RAW P_N P_SINCE P_ALERT P_EXTRA
if [ -f "$STATE_DIR/state.tsv" ]; then
  while IFS=$'\t' read -r n rep raw cnt since la extra; do
    P_REP[$n]=$rep; P_RAW[$n]=$raw; P_N[$n]=$cnt; P_SINCE[$n]=$since; P_ALERT[$n]=$la; P_EXTRA[$n]=${extra:-}
  done < "$STATE_DIR/state.tsv"
fi
declare -A EXTRA   # per-check memory carried to the next run (e.g. the gateway's start time)

OC_UNIT="${OPENCLAW_UNIT:-openclaw-gateway.service}"
OC_BIN="${OPENCLAW_BIN:-$(command -v openclaw 2>/dev/null)}"

# ---- OpenClaw gateway service ------------------------------------------------------------
GW_UP=0
if systemctl --user cat "$OC_UNIT" >/dev/null 2>&1; then
  gw=$(systemctl --user is-active "$OC_UNIT" 2>/dev/null)
  case "$gw" in
    active) GW_UP=1; record openclaw-gateway ok "running" ;;
    activating|reloading) GW_UP=1; record openclaw-gateway ok "starting" ;;
    failed)
      # Crashed (not stopped by you): restart it once.
      if [ $CAN_FIX -eq 1 ] && systemctl --user restart "$OC_UNIT" 2>/dev/null && sleep 20 \
         && systemctl --user is-active --quiet "$OC_UNIT"; then
        GW_UP=1; record openclaw-gateway fixed "the gateway had crashed; restarted it"
      else
        record openclaw-gateway fail "the gateway has crashed — journalctl --user -u $OC_UNIT -n 50"
      fi ;;
    *) record openclaw-gateway fail "the gateway is $gw (stopped) — WhatsApp and the assistant are offline" ;;
  esac

  # Restarts nobody was told about: the watchdog acting, or a crash systemd recovered from.
  # Skipped for the first 3 minutes after boot, when every start is expected.
  boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
  mono=$(systemctl --user show "$OC_UNIT" -p ActiveEnterTimestampMonotonic --value 2>/dev/null)
  prev=${P_EXTRA[openclaw-restarts]:-}
  EXTRA[openclaw-restarts]="$boot:$mono"
  if [ -n "$prev" ] && [ "${prev%%:*}" = "$boot" ] && [ "${prev#*:}" != "$mono" ] \
     && [ "${mono:-0}" -gt 180000000 ] && [ "${states[${#states[@]}-1]}" != fixed ]; then
    at=$(systemctl --user show "$OC_UNIT" -p ActiveEnterTimestamp --value 2>/dev/null | awk '{print $3}')
    record openclaw-restarts fixed "the gateway restarted at ${at:-?} (the watchdog, or a crash systemd recovered) — journalctl --user -t openclaw-watchdog"
  else
    record openclaw-restarts ok "no unexpected restarts"
  fi
else
  record openclaw-gateway fail "$OC_UNIT is not installed — openclaw gateway install"
fi

# ---- OpenClaw channels (WhatsApp etc.): the state the gateway itself reports --------------------
# Reads the same `healthState` the gateway's own health monitor uses. An unhealthy linked
# channel is the watchdog's job to restart; this makes sure you hear about it either way.
if [ $GW_UP -eq 1 ]; then
  if [ -z "$OC_BIN" ]; then
    record openclaw-channels fail "cannot find the openclaw command — set OPENCLAW_BIN in laptop-health.conf"
  else
    js=$(timeout 40 "$OC_BIN" channels status --json 2>/dev/null)
    ch=$(printf '%s' "$js" | python3 -c '
import json, sys
BAD = {"terminal-disconnect", "ingress-unavailable", "blocked", "not-running",
       "disconnected", "stale-socket", "stuck"}
try:
    d = json.load(sys.stdin)
except Exception:
    print("fail|the gateway is running but does not answer `openclaw channels status`"); sys.exit()
bad, relink, good = [], [], []
for chan, accounts in (d.get("channelAccounts") or {}).items():
    for a in accounts or []:
        name = chan if a.get("accountId") in (None, "default") else f"{chan}/{a.get('accountId')}"
        if a.get("enabled") is False or a.get("configured") is False:
            continue
        if a.get("linked") is False:
            relink.append(name); continue
        hs = a.get("healthState")
        if hs in BAD:
            err = a.get("lastError") or ""
            err = err if isinstance(err, str) else json.dumps(err)
            bad.append(f"{name} {hs}" + (f" ({err[:80]})" if err else ""))
        else:
            good.append(name)
if bad:
    print("fail|unhealthy: " + "; ".join(bad))
elif relink:
    print("fail|logged out, needs relinking: " + ", ".join(relink) + " — openclaw channels login")
elif good:
    print("ok|" + ", ".join(good) + " healthy")
else:
    print("warn|no linked channels at all")')
    record openclaw-channels "${ch%%|*}" "${ch#*|}"
  fi
fi

# ---- the watchdog timer itself ---------------------------------------------------------------
if [ -n "${OPENCLAW_WATCHDOG_TIMER:-}" ] && systemctl --user cat "$OPENCLAW_WATCHDOG_TIMER" >/dev/null 2>&1; then
  if systemctl --user is-active --quiet "$OPENCLAW_WATCHDOG_TIMER"; then
    record openclaw-watchdog ok "timer running"
  else
    record openclaw-watchdog fail "$OPENCLAW_WATCHDOG_TIMER is not running, so a dead channel will stay dead"
  fi
fi

# ---- services that must be running --------------------------------------------------------------
unit_check() {  # --user|--system unit
  local scope=$1 u=$2 st
  systemctl "$scope" cat "$u" >/dev/null 2>&1 || return 0   # not installed here: nothing to check
  st=$(systemctl "$scope" is-active "$u" 2>/dev/null)
  case "$st" in active|activating|reloading) record "${u%.service}" ok "$st" ;;
    *) record "${u%.service}" fail "$u is $st" ;; esac
}
for u in ${REQUIRED_USER_UNITS:-}; do unit_check --user "$u"; done
for u in ${REQUIRED_SYSTEM_UNITS:-}; do unit_check --system "$u"; done
# Programs that must be running however they were started (Syncthing can be a user or system unit).
for p in ${REQUIRED_PROCESSES:-}; do
  if pgrep -x "$p" >/dev/null 2>&1; then record "$p" ok "running"
  else record "$p" fail "$p is not running"; fi
done

# ---- anything else systemd says has failed ----------------------------------------------------
failed=$( { systemctl --failed --plain --no-legend 2>/dev/null | awk '{print $1}'
            systemctl --user --failed --plain --no-legend 2>/dev/null | awk '{print "user:"$1}'; } \
          | grep -vxF -f <(printf '%s\n' ${IGNORE_FAILED_UNITS:-} ${REQUIRED_SYSTEM_UNITS:-} "user:$OC_UNIT" _
                          for u in ${REQUIRED_USER_UNITS:-} ${OPENCLAW_WATCHDOG_TIMER:-}; do echo "user:$u"; done) | tr '\n' ' ')
if [ -n "${failed// }" ]; then record failed-units fail "failed: ${failed% }"
else record failed-units ok "none"; fi

# ---- Tailscale (the laptop reaches the lab through it) ------------------------------------------
if command -v tailscale >/dev/null 2>&1; then
  backend=$(tailscale status --json 2>/dev/null | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("BackendState","?"))
except Exception: print("down")')
  if [ "$backend" = Running ]; then record tailscale ok "connected"
  else record tailscale fail "the laptop is off the tailnet ($backend)"; fi
fi

# ---- disk space --------------------------------------------------------------------------------
for m in ${DISK_MOUNTS:-/}; do
  mountpoint -q "$m" || continue
  pct=$(df --output=pcent "$m" 2>/dev/null | tail -1 | tr -dc 0-9)
  [ -z "$pct" ] && continue
  key="disk${m//\//-}"; [ "$m" = / ] && key=disk-root
  if [ "$pct" -ge "${DISK_WARN_PCT:-90}" ]; then record "$key" warn "$m is ${pct}% full"
  else record "$key" ok "${pct}% used"; fi
done

# ---- the home backup actually exists (2026-10-21: Kopia ran for weeks without one snapshot) ------
KOPIA="${KOPIA_BIN:-$(command -v kopia 2>/dev/null || echo /opt/KopiaUI/resources/server/kopia)}"
if [ "${KOPIA_MAX_AGE_HOURS:-26}" -gt 0 ]; then
  if [ ! -x "$KOPIA" ]; then
    record home-backup fail "Kopia is not installed, so ~ is not backed up — RESTORE.md 1.6"
  elif ! "$KOPIA" repository status >/dev/null 2>&1; then
    record home-backup fail "Kopia is not connected to its repository, so ~ is not backed up — RESTORE.md 1.6"
  else
    newest=$("$KOPIA" snapshot list "$HOME" --json 2>/dev/null | python3 -c '
import json, sys
try: s = json.load(sys.stdin)
except Exception: s = []
print(max(x["startTime"] for x in s) if s else "")')
    if [ -z "$newest" ]; then record home-backup fail "Kopia has no snapshot of ~ at all"
    else
      h=$(( (NOW - $(date -d "$newest" +%s)) / 3600 ))
      if [ "$h" -ge "${KOPIA_MAX_AGE_HOURS:-26}" ]; then record home-backup fail "the newest Kopia snapshot of ~ is ${h} h old"
      else record home-backup ok "last snapshot ${h} h ago"; fi
    fi
  fi
fi

# ---- the disk's LUKS header has a copy (without it, a wiped header loses the whole disk) ----------
luks=$(lsblk -nrpo NAME,FSTYPE 2>/dev/null | awk '$2=="crypto_LUKS"{print $1}')
if [ -n "$luks" ]; then
  hdir="${LUKS_HEADER_DIR:-$HOME/Backups/pc/luks}"
  for dev in $luks; do
    f="$hdir/$(basename "$dev").header.img"
    if [ ! -s "$f" ]; then record "luks-$(basename "$dev")" fail "$dev has no header backup — run luks-header-backup.sh"
    else record "luks-$(basename "$dev")" ok "header backup $(date -r "$f" +%F)"; fi
  done
fi

# ---- out-of-memory kills (needs the journal to be readable: wheel/adm/systemd-journal) ----------
if journalctl -k -n 1 -q --no-pager >/dev/null 2>&1; then
  oom=$(journalctl -k --since "-6min" --no-pager -q 2>/dev/null \
        | grep -oE 'Killed process [0-9]+ \([^)]+\)' | sed -E 's/.*\((.*)\)/\1/' | sort -u | tr '\n' ' ')
  if [ -n "$oom" ]; then record memory event "out of memory — the kernel killed: ${oom% }"
  else record memory ok "no out-of-memory kills"; fi
fi

# ---- RAM: little left, or the system stalling on memory (a 7 GB laptop) -------------------------
read -r avail total swapfree swaptotal < <(awk '/^MemAvailable:/{a=$2} /^MemTotal:/{t=$2}
  /^SwapFree:/{sf=$2} /^SwapTotal:/{st=$2} END{print a+0, t+0, sf+0, st+0}' /proc/meminfo)
if [ "${total:-0}" -gt 0 ]; then
  pct=$(( avail * 100 / total )); swap_mb=$(( (swaptotal - swapfree) / 1024 ))
  stall=$(awk '/^full/{for(i=1;i<=NF;i++) if($i ~ /^avg60=/){sub(/avg60=/,"",$i); print $i}}' /proc/pressure/memory 2>/dev/null)
  top=$(ps -eo rss=,comm= --sort=-rss 2>/dev/null | head -n 3 | awk '{printf "%s %d MB, ", $2, $1/1024}')
  if [ "$pct" -lt "${MEM_WARN_PCT:-10}" ]; then
    record ram warn "only ${pct}% of RAM free ($((avail / 1024)) MB, swap used ${swap_mb} MB); biggest: ${top%, }"
  elif awk -v s="${stall:-0}" -v m="${MEM_STALL_PCT:-10}" 'BEGIN{exit !(s >= m)}'; then
    record ram warn "the system is stalling on memory (${stall}% of the last minute); biggest: ${top%, }"
  else
    record ram ok "${pct}% free ($((avail / 1024)) of $((total / 1024)) MB), swap used ${swap_mb} MB"
  fi
fi

# ---- the table -----------------------------------------------------------------------------------
for i in "${!names[@]}"; do printf '%-18s %-6s %s\n' "${names[$i]}" "${states[$i]}" "${details[$i]}"; done
[ $REPORT -eq 1 ] && exit 0

# ---- alerts: only on change, and only once a problem has held for CONFIRM_RUNS runs --------------
CONFIRM=${CONFIRM_RUNS:-2}
problems=(); reminders=(); fixes=(); recovered=(); new_state=""
for i in "${!names[@]}"; do
  n=${names[$i]}; s=${states[$i]}; d=${details[$i]}
  rep=${P_REP[$n]:-ok}; raw=${P_RAW[$n]:-ok}; cnt=${P_N[$n]:-0}; since=${P_SINCE[$n]:-$NOW}; la=${P_ALERT[$n]:-0}
  case "$s" in
    fixed) fixes+=("$n — $d"); rep=ok; raw=ok; cnt=0; since=$NOW ;;
    event) problems+=("$n — $d"); rep=ok; raw=ok; cnt=0; la=$NOW ;;
    fail|warn)
      if [ "$raw" = "$s" ]; then cnt=$((cnt + 1)); else cnt=1; since=$NOW; fi
      raw=$s
      if [ "$rep" != "$s" ] && [ "$cnt" -ge "$CONFIRM" ]; then
        problems+=("$n — $d"); rep=$s; la=$NOW
      elif [ "$rep" = "$s" ] && [ "${REMIND_HOURS:-0}" -gt 0 ] && [ $((NOW - la)) -ge $((REMIND_HOURS * 3600)) ]; then
        reminders+=("$n — $d (since $(date -d "@$since" '+%d %b %H:%M'))"); la=$NOW
      fi ;;
    ok)
      if [ "$rep" = fail ] || [ "$rep" = warn ]; then recovered+=("$n"); fi
      rep=ok; raw=ok; cnt=0 ;;
  esac
  new_state+="$n"$'\t'"$rep"$'\t'"$raw"$'\t'"$cnt"$'\t'"$since"$'\t'"$la"$'\t'"${EXTRA[$n]:-}"$'\n'
done

sent=1
if [ -n "${NTFY_URL:-}" ] && [ $(( ${#problems[@]} + ${#reminders[@]} + ${#fixes[@]} + ${#recovered[@]} )) -gt 0 ]; then
  parts=()
  [ ${#problems[@]} -gt 0 ] && parts+=("${#problems[@]} problem(s)")
  [ ${#reminders[@]} -gt 0 ] && parts+=("${#reminders[@]} still broken")
  [ ${#fixes[@]} -gt 0 ] && parts+=("${#fixes[@]} fixed itself")
  [ ${#recovered[@]} -gt 0 ] && parts+=("${#recovered[@]} back to normal")
  title="${ALERT_PREFIX:-laptop}: $(printf '%s, ' "${parts[@]}")"; title=${title%, }
  prio=default; [ $(( ${#problems[@]} + ${#reminders[@]} )) -gt 0 ] && prio=high
  body=$(
    for x in "${problems[@]}";  do echo "PROBLEM: $x"; done
    for x in "${reminders[@]}"; do echo "STILL BROKEN: $x"; done
    for x in "${fixes[@]}";     do echo "FIXED: $x"; done
    for x in "${recovered[@]}"; do echo "OK AGAIN: $x"; done
  )
  send "$NTFY_URL" -H "Title: $title" -H "Priority: $prio" -H "Tags: computer" -d "$body" || sent=0
fi
# Offline (no Wi-Fi yet after a resume)? Keep the old state, so the same message goes out next run.
[ $sent -eq 1 ] && printf '%s' "$new_state" > "$STATE_DIR/state.tsv"
exit 0
