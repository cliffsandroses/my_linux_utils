#!/usr/bin/env bash
# Put the homelab's files back from a nightly backup set. Run on the VM.
#
#   vm-restore.sh [--check] [--force] [SET]     SET = a folder in $BACKUP_DIR (default: newest)
#
# Fills in only what is missing. --force also replaces what exists (old copies are moved aside,
# never deleted). Restores the arr apps from their own backup zips, as restore-test.md says.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
FORCE=0; [ "${1:-}" = --force ] && { FORCE=1; shift; }
SET="${1:-$(ls -1d "$BACKUP_DIR"/20* 2>/dev/null | sort | tail -1)}"
[ -d "$SET" ] || SET="$BACKUP_DIR/$SET"
[ -d "$SET" ] || { echo "No backup set at $SET"; exit 1; }
H=$HOME

log "Backup set $(basename "$SET")"
want "every file matches SHA256SUMS" sh -c "cd '$SET' && sha256sum -c --quiet SHA256SUMS" || { echo "Stopping: the set is damaged."; exit 1; }

missing_or_force() { [ "$FORCE" = 1 ] || [ ! -e "$1" ]; }

log "Home folder (~/homelab, ~/Axon, user services, dashboard data)"
if [ "$FORCE" = 1 ] || [ ! -d "$H/homelab/adguard" ]; then
  diff_ "~/homelab not restored yet"
  [ -d "$H/homelab" ] && run mv "$H/homelab" "$H/homelab.pre-restore-$(date +%Y%m%d-%H%M)"
  run tar -xzf "$SET/homelab-config.tar.gz" -C "$H"
  run tar -xzf "$SET/arr-native-backups.tar.gz" -C "$H"
else ok "~/homelab present"; fi
want "~/homelab/backup scripts (from git: not in the tarball)" test -x "$H/homelab/backup/backup-homelab.sh" \
  || run git -C "$H/homelab" checkout -- backup/

log "qBittorrent config ($QBT_CONFIG)"
if missing_or_force "$QBT_CONFIG/config/qBittorrent.conf"; then
  diff_ "qBittorrent config missing"
  run sudo mkdir -p "$QBT_CONFIG"; run sudo tar -xzf "$SET/qbittorrent-config.tar.gz" -C "$QBT_CONFIG"
  run sudo chown -R "$PUID:$PGID" "$(dirname "$(dirname "$QBT_CONFIG")")"
else ok "qBittorrent config present"; fi

log "Docker volumes"
for f in "$SET"/vol-*.tar.gz; do
  v=$(basename "$f" .tar.gz); v=${v#vol-}
  if docker volume inspect "$v" >/dev/null 2>&1 && [ "$(docker run --rm -v "$v":/v alpine:3 sh -c 'ls -A /v | wc -l')" -gt 0 ] && [ "$FORCE" = 0 ]; then
    ok "volume $v has data"
  else
    diff_ "volume $v empty or missing"
    run docker volume create "$v"
    [ "$CHECK" = 1 ] || docker run --rm -i -v "$v":/v alpine:3 tar -xzf - -C /v < "$f"
  fi
done

log "Single files"
want "AdGuard config" test -s "$H/homelab/adguard/conf/AdGuardHome.yaml" || {
  run mkdir -p "$H/homelab/adguard/conf" "$H/homelab/adguard/work"; run cp "$SET/AdGuardHome.yaml" "$H/homelab/adguard/conf/"; }
want "Nextcloud config.php" test -s "$H/homelab/nextcloud/html/config/config.php" || {
  run mkdir -p "$H/homelab/nextcloud/html/config"; run cp "$SET/nextcloud-config.php" "$H/homelab/nextcloud/html/config/config.php"; }

log "Sonarr, Radarr, Prowlarr from their own backup zips"
for a in sonarr radarr prowlarr; do
  d="$H/homelab/arr/config/$a"
  if [ -d "$d/.pre-restore" ] && [ "$FORCE" = 0 ]; then ok "$a already restored from a zip"; continue; fi
  z=$(ls -t "$d"/Backups/manual/${a}_backup_*.zip "$d"/Backups/scheduled/${a}_backup_*.zip 2>/dev/null | head -1)
  [ -n "$z" ] || { diff_ "$a: no backup zip found"; continue; }
  diff_ "$a not yet restored from $(basename "$z")"
  if [ "$CHECK" = 0 ]; then
    mkdir -p "$d/.pre-restore"; mv "$d/$a".db* "$d/config.xml" "$d/.pre-restore/" 2>/dev/null; rm -f "$d/$a.pid"
    unzip -o -q "$z" -d "$d"
  fi
done

log "~/Projects from the git mirrors"
mkdir -p "$H/Projects"
for g in "$GIT_MIRRORS"/*.git; do
  n=$(basename "$g" .git)
  want "~/Projects/$n" test -d "$H/Projects/$n/.git" || run git clone -q "$g" "$H/Projects/$n"
done
[ -d "$H/Projects/$SOMA_REPO" ] && { want "$SOMA_REPO on $SOMA_BRANCH" test "$(git -C "$H/Projects/$SOMA_REPO" branch --show-current)" = "$SOMA_BRANCH" \
  || run git -C "$H/Projects/$SOMA_REPO" checkout -q "$SOMA_BRANCH"; }

note "Databases (Immich, Nextcloud) are loaded by vm-apps.sh, after their containers exist."
finish
