#!/usr/bin/env bash
# One library per type: every app reads and writes the media pool. Run on the VM after
# vm-storage.sh (the pool is mounted) and vm-apps.sh (the apps run).
#
# Moves no files: everything already sits at its pool path. Old Sonarr/Radarr root folders are
# removed only when the file count is unchanged after a rescan.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")" && pwd)"; HL="$HOME/homelab"

log "Pool mounted in the apps' compose files"
changed=""
for s in $POOL_MOUNT_STACKS; do
  f="$HL/$s/docker-compose.yml"; [ -f "$HL/$s/docker-compose.override.yml" ] && grep -q "/mnt/nvme:/mnt/nvme" "$HL/$s/docker-compose.override.yml" && f="$HL/$s/docker-compose.override.yml"
  want "$s mounts $POOL_MNT" grep -q "$POOL_MNT:$POOL_MNT" "$f" || {
    run cp -n "$f" "$f.bak-before-pool"
    run sed -i -E "s|^(\s*)- /mnt/nvme:/mnt/nvme(.*)$|&\n\1- $POOL_MNT:$POOL_MNT:rslave   # media pool (mergerfs)|" "$f"; changed="$changed $s"; }
done
for s in $POOL_MOUNT_RO_STACKS; do
  f="$HL/$s/docker-compose.yml"
  want "$s mounts $POOL_MNT/Media read-only" grep -q "$POOL_MNT/Media:$POOL_MNT/Media" "$f" || {
    run cp -n "$f" "$f.bak-before-pool"
    run sed -i -E "s|^(\s*)- /mnt/nvme/Media:/mnt/nvme/Media:ro(.*)$|&\n\1- $POOL_MNT/Media:$POOL_MNT/Media:ro,rslave   # media pool|" "$f"; changed="$changed $s"; }
done

log "qBittorrent saves into the pool"
Q="$QBT_CONFIG/config"
qbt_ok() { sudo grep -qxF "Session\\DefaultSavePath=$DOWNLOADS" "$Q/qBittorrent.conf" && ! sudo grep -q '"/mnt/nvme/Downloads' "$Q/categories.json"; }
want "default path, temp path and categories under $DOWNLOADS" qbt_ok || [ "$CHECK" = 1 ] || {
  # qBittorrent rewrites its config on shutdown, so it is edited while stopped.
  (cd "$HL/qbittorrent" && docker compose stop -t 30 >/dev/null 2>&1)
  sudo cp -n "$Q/qBittorrent.conf" "$Q/qBittorrent.conf.bak-before-pool"; sudo cp -n "$Q/categories.json" "$Q/categories.json.bak-before-pool"
  sudo sed -i -E "s|^(Session\\\\DefaultSavePath)=.*|\1=$DOWNLOADS|; s|^(Session\\\\TempPath)=.*|\1=$DOWNLOADS/incomplete|" "$Q/qBittorrent.conf"
  sudo sed -i "s|\"/mnt/nvme/Downloads/|\"$DOWNLOADS/|g" "$Q/categories.json"
  changed="$changed qbittorrent"; }

[ "$CHECK" = 1 ] || for s in $(echo "$changed" | tr ' ' '\n' | sort -u); do (cd "$HL/$s" && docker compose up -d >/dev/null 2>&1) && note "recreated $s"; done

log "Sonarr and Radarr: one root folder each"
arr_root() {  # app port kind idfield rootpath countexpr
  local n=$1 p=$2 e=$3 idf=$4 R=$5 cnt=$6 k A before after
  k=$(grep -oP "(?<=<ApiKey>)[^<]+" "$HL/arr/config/$n/config.xml")
  A="curl -s -H X-Api-Key:$k -H Content-Type:application/json http://127.0.0.1:$p/api/v3"
  if [ "$($A/rootfolder | jq -r '.[].path')" = "$R" ] && [ -z "$($A/$e | jq -r --arg r "$R/" '.[] | select(.path|startswith($r)|not) | .path')" ]; then
    ok "$n: only $R, every item under it"; return; fi
  diff_ "$n: not everything under $R"; [ "$CHECK" = 1 ] && return
  before=$($A/$e | jq "$cnt")
  $A/rootfolder | jq -e --arg r "$R" 'any(.[]; .path==$r)' >/dev/null || $A/rootfolder -X POST -d "{\"path\":\"$R\"}" >/dev/null
  $A/$e/editor -X PUT -d "{\"$idf\":$($A/$e | jq -c '[.[].id]'),\"rootFolderPath\":\"$R\",\"moveFiles\":false}" >/dev/null
  local cmd; cmd=$([ "$e" = series ] && echo RescanSeries || echo RescanMovie)
  local cid; cid=$($A/command -X POST -d "{\"name\":\"$cmd\"}" | jq .id)
  for _ in $(seq 1 120); do [ "$($A/command/$cid | jq -r .status)" = completed ] && break; sleep 5; done
  after=$($A/$e | jq "$cnt")
  if [ "$after" -ge "$before" ]; then
    for id in $($A/rootfolder | jq -r --arg r "$R" '.[] | select(.path!=$r) | .id'); do $A/rootfolder/$id -X DELETE >/dev/null; done
    note "$n: $after files (before $before), old root folders removed"
  else
    note "$n: $after files after the rescan, $before before: old root folders KEPT. Check what dropped (history: MissingFromDisk) before removing them by hand."
  fi
}
arr_root sonarr 8989 series seriesIds "$LIB_TV" '[.[].statistics.episodeFileCount] | add'
arr_root radarr 7878 movie movieIds "$LIB_MOVIES" '[.[] | select(.hasFile)] | length'

k=$(grep -oP "(?<=<ApiKey>)[^<]+" "$HL/arr/config/radarr/config.xml"); A="curl -s -H X-Api-Key:$k -H Content-Type:application/json http://127.0.0.1:7878/api/v3"
want "Radarr collections add into $LIB_MOVIES" test "$($A/collection | jq --arg r "$LIB_MOVIES" '[.[] | select(.rootFolderPath != $r)] | length')" = 0 \
  || run sh -c "$A/collection -X PUT -d '{\"collectionIds\": $($A/collection | jq -c '[.[].id]'), \"rootFolderPath\": \"$LIB_MOVIES\"}' >/dev/null"

log "Seerr sends requests into the pool"
S="$HL/seerr/config/settings.json"
want "Seerr target folders" sh -c "jq -e '([.radarr[].activeDirectory] | all(. == \"$LIB_MOVIES\")) and ([.sonarr[].activeDirectory] | all(. == \"$LIB_TV\"))' '$S'" || [ "$CHECK" = 1 ] || {
  (cd "$HL/seerr" && docker compose stop -t 20 >/dev/null 2>&1); cp -n "$S" "$S.bak-before-pool"
  jq --arg m "$LIB_MOVIES" --arg t "$LIB_TV" '.radarr |= map(.activeDirectory=$m) | .sonarr |= map(.activeDirectory=$t | (if .activeAnimeDirectory then .activeAnimeDirectory=$t else . end))' "$S" > "$S.tmp" && mv "$S.tmp" "$S"
  (cd "$HL/seerr" && docker compose up -d >/dev/null 2>&1); }

log "Plex: one folder per library"
plex_ok() { python3 - <<'EOF'
import json, re, urllib.request
from pathlib import Path
t = re.search(r'PlexOnlineToken="([^"]+)"', (Path.home() / "homelab/plex/config/Library/Application Support/Plex Media Server/Preferences.xml").read_text()).group(1)
r = urllib.request.Request("http://127.0.0.1:32400/library/sections", headers={"X-Plex-Token": t, "Accept": "application/json"})
d = json.loads(urllib.request.urlopen(r).read())["MediaContainer"]["Directory"]
bad = [s["title"] for s in d if not all(l["path"].startswith("/mnt/pool/Media/") for l in s.get("Location", []))]
print(" ".join(bad)); raise SystemExit(1 if bad else 0)
EOF
}
want "every Plex library on $POOL_MNT/Media" plex_ok || run python3 -u "$HERE/plex_pool.py"
note "Plex home-video libraries (Shorts) match by path: a path change shows duplicates until the old folder is gone."

log "Jellyfin and Soma"
note "Jellyfin reads the pool over NFS: homelab/run.sh pve pve-cts.sh jellyfin (its mounts); Soma's map: vm-apps.sh."
finish
