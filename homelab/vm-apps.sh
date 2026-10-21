#!/usr/bin/env bash
# Start the homelab's apps in order and load what a restore leaves empty. Run on the VM,
# after vm-base.sh, vm-storage.sh and vm-restore.sh.
#
#   vm-apps.sh [--check]                 HS_KEY=hskey-... vm-apps.sh   # also join the tailnet
#
# Databases are only loaded when they are empty, so running it on a working homelab changes nothing.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
HERE="$(cd "$(dirname "$0")" && pwd)"; HL="$HOME/homelab"

log "Compose files that lived in CasaOS's folder (not in the backup)"
for s in caddy homeassistant; do
  want "~/homelab/$s/docker-compose.yml" test -f "$HL/$s/docker-compose.yml" || {
    run mkdir -p "$HL/$s"; run cp "$HERE/compose/$s.yml" "$HL/$s/docker-compose.yml"; }
done

stack_up() {  # stack folder: all its containers running?
  local all run_
  all=$(cd "$HL/$1" && docker compose ps -a -q 2>/dev/null | wc -l)
  run_=$(cd "$HL/$1" && docker compose ps --status running -q 2>/dev/null | wc -l)
  [ "$all" -gt 0 ] && [ "$all" = "$run_" ]
}

log "Apps, in order"
for s in $STACKS; do
  [ -d "$HL/$s" ] || { diff_ "~/homelab/$s does not exist"; continue; }
  want "$s running" stack_up "$s" || { [ "$CHECK" = 1 ] || (cd "$HL/$s" && docker compose up -d --quiet-pull 2>&1 | grep -iE "error|fail" || true); }
done

log "Immich database"
has_assets() { docker exec immich_postgres psql -U immich -d immich -tAc "select 1 from asset limit 1" 2>/dev/null | grep -q 1; }
if want "Immich database holds photos" has_assets; then
  note "$(docker exec immich_postgres psql -U immich -d immich -tAc 'select count(*) from asset') assets"
elif [ "$CHECK" = 0 ]; then
  # Immich's own dumps are single-database dumps: they go into "immich", not "postgres"
  # (the docs' --dbname=postgres is for pg_dumpall files). 512 MB is too little for the load.
  dump=$(ls -1 "$DATA_MNT"/immich/library/backups/immich-db-backup-*.sql.gz | sort | tail -1)
  echo "  loading $(basename "$dump")"
  docker stop immich_server immich_machine_learning >/dev/null
  docker update --memory 2g --memory-swap 2g immich_postgres >/dev/null
  until docker exec immich_postgres pg_isready -U immich -d postgres >/dev/null 2>&1; do sleep 2; done
  docker exec immich_postgres psql -q -U immich -d postgres -c "DROP DATABASE IF EXISTS immich WITH (FORCE);" -c "CREATE DATABASE immich OWNER immich;"
  gunzip --stdout "$dump" | sed "s/SELECT pg_catalog.set_config('search_path', '', false);/SELECT pg_catalog.set_config('search_path', 'public, pg_catalog', true);/g" \
    | docker exec -i immich_postgres psql -q --dbname=immich --username=immich 2>&1 | grep -iE "error|fatal" | sort | uniq -c
  (cd "$HL/immich" && docker compose up -d >/dev/null 2>&1)
  note "$(docker exec immich_postgres psql -U immich -d immich -tAc 'select count(*) from asset') assets loaded; the DB keeps 2 GB until its next restart (first start imports map data)"
fi

log "Nextcloud database and files"
nc_db() { docker exec nextcloud-db psql -U nextcloud -d nextcloud -tAc "select 1 from oc_filecache limit 1" 2>/dev/null | grep -q 1; }
if want "Nextcloud database holds files" nc_db; then :
elif [ "$CHECK" = 0 ]; then
  cfg="$HL/nextcloud/html/config/config.php"
  u=$(grep -oP "(?<='dbuser' => ')[^']+" "$cfg"); p=$(grep -oP "(?<='dbpassword' => ')[^']+" "$cfg")
  ncdata=$(grep -oP '(?<=^NC_DATA=).*' "$HL/nextcloud/.env")
  if [ ! -f "$ncdata/.ocdata" ]; then   # its data dir lived on the VM's own disk; the copy on the data disk is the source
    sudo mkdir -p "$ncdata"; sudo rsync -a "$DATA_MNT/Nextcloud-files/" "$ncdata/"; sudo touch "$ncdata/.ocdata"
    sudo chown -R 33:33 "$ncdata" "$HL/nextcloud/html"; sudo chmod 770 "$ncdata"
  fi
  (cd "$HL/nextcloud" && docker compose up -d nextcloud-db >/dev/null 2>&1)
  until docker exec nextcloud-db pg_isready -U nextcloud -d nextcloud >/dev/null 2>&1; do sleep 2; done; sleep 3
  # pg_dump carries no roles: the dump's owner must exist before the load (restore-test.md).
  docker exec nextcloud-db psql -q -U nextcloud -d nextcloud -c "CREATE ROLE $u LOGIN PASSWORD '$p' CREATEDB;" \
    -c "ALTER DATABASE nextcloud OWNER TO $u;" -c "ALTER SCHEMA public OWNER TO $u;" 2>/dev/null
  dump=$(ls -1d "$BACKUP_DIR"/20* | sort | tail -1)/nextcloud-db.sql.gz
  gunzip -c "$dump" | docker exec -i nextcloud-db psql -q -U "$u" -d nextcloud 2>&1 | grep -iE "error|fatal" | sort | uniq -c
  (cd "$HL/nextcloud" && docker compose up -d >/dev/null 2>&1)
  for i in $(seq 1 60); do docker logs nextcloud 2>&1 | grep -q "resuming normal operations\|apache2 -D FOREGROUND" && break; sleep 5; done
  docker exec -u 33 nextcloud php occ upgrade 2>&1 | tail -1
  docker exec -u 33 nextcloud php occ files:scan --all 2>&1 | tail -3
fi

log "Apps that need more memory on their first start"
for pair in $FIRST_START_MEMORY; do
  c=${pair%%=*}; m=${pair#*=}
  st=$(docker inspect -f '{{.State.Status}} {{.State.OOMKilled}} {{.RestartCount}}' "$c" 2>/dev/null) || continue
  if echo "$st" | grep -qE "^restarting|true|^running false [1-9]"; then
    diff_ "$c is struggling ($st)"; run docker update --memory "$m" --memory-swap "$m" "$c"; run docker restart "$c"
  else ok "$c fine ($st)"; fi
done

log "Soma (from the $SOMA_REPO mirror, branch $SOMA_BRANCH)"
if want "~/soma/test points at a release" test -f "$HOME/soma/test/next/serve.py"; then :
elif [ "$CHECK" = 0 ]; then
  rel="$HOME/soma/releases/restored-$SOMA_BRANCH-$(git -C "$HOME/Projects/$SOMA_REPO" log -1 --format=%cs "$SOMA_BRANCH")"
  mkdir -p "$rel"; git -C "$HOME/Projects/$SOMA_REPO" archive "$SOMA_BRANCH" | tar -x -C "$rel"; ln -sfn "$rel" "$HOME/soma/test"
fi
envf="$HOME/.config/soma/media-pool.env"
# A plain Environment= line strips the JSON's quotes and Soma crashes: it must be a single-quoted EnvironmentFile.
want "Soma's Jellyfin path map ($envf)" grep -qF "SOMA_JF_ROOTS='$SOMA_JF_ROOTS'" "$envf" || {
  run mkdir -p "$(dirname "$envf")" "$HOME/.config/systemd/user/soma-next.service.d"
  [ "$CHECK" = 1 ] || {
    printf '# Jellyfin (CT 200) mounts the media pool, so its paths map to /mnt/pool.\nSOMA_JF_ROOTS=%s\n' "'$SOMA_JF_ROOTS'" > "$envf"
    printf '[Service]\nEnvironmentFile=%%h/.config/soma/media-pool.env\n' > "$HOME/.config/systemd/user/soma-next.service.d/media-pool.conf"
    user_systemctl daemon-reload; user_systemctl restart soma-next.service; }; }

log "Homelab Web (http://$VM_IP:8090/web/)"
want "collector installed" cmp -s "$HERE/web/collect.py" "$HL/web/collect.py" || { run mkdir -p "$HL/web"; run cp "$HERE/web/collect.py" "$HL/web/collect.py"; }
want "page installed" cmp -s "$HERE/web/index.html" "$HL/dashboard/www/web/index.html" || { run mkdir -p "$HL/dashboard/www/web"; run cp "$HERE/web/index.html" "$HL/dashboard/www/web/index.html"; }
for u in homelab-web.service homelab-web.timer; do
  want "$u installed" test -f "$HOME/.config/systemd/user/$u" || run cp "$HERE/web/$u" "$HOME/.config/systemd/user/$u"
done
want "Proxmox read-only token present" test -s "$HOME/.config/homelab-web/pve-token" || note "make it: homelab/run.sh pve pve-vm.sh web-token (from the laptop)"

log "Tailscale"
if want "on the tailnet" tailscale status; then :
elif [ -n "${HS_KEY:-}" ]; then
  run sudo tailscale up --login-server "$HEADSCALE_URL" --authkey "$HS_KEY" --hostname "$VM_HOSTNAME" --accept-dns=false
else note "join with: HS_KEY=<key> homelab/run.sh vm vm-apps.sh  (key: docker exec headscale headscale preauthkeys create --user $HEADSCALE_USER_ID --expiration 1h)"; fi

finish
