#!/usr/bin/env bash
# Off-site copy of the homelab's backups on MEGA (20 GB free), compressed and encrypted by restic, through rclone.
# Runs on the homelab VM as moosa, every morning after the 03:15 backup (offsite-mega.timer).
#
#     offsite-mega.sh init     # once: make the repository on MEGA and its password file
#     offsite-mega.sh          # back up, keep 7 daily / 4 weekly / 3 monthly, report the size
#     offsite-mega.sh check    # read back 5% of the data to prove it restores
#
# Needs: restic and rclone (apt), and an rclone remote called "mega" that Moosa makes himself with `rclone config`
# (his MEGA login never passes through anyone else). The repository password is ~/.config/restic/mega.pass:
# without it the copy on MEGA can't be read, so it also belongs in Bitwarden.
set -euo pipefail
REMOTE=${MEGA_REMOTE:-mega}
export RESTIC_REPOSITORY=${RESTIC_REPOSITORY:-rclone:$REMOTE:homelab-restic}
export RESTIC_PASSWORD_FILE=${RESTIC_PASSWORD_FILE:-$HOME/.config/restic/mega.pass}
export RESTIC_COMPRESSION=max
read -r -a PATHS <<< "${MEGA_PATHS:-/mnt/data/Backups/homelab /mnt/data/Backups/git-mirrors /mnt/data/Backups/proxmox}"
QUOTA_GB=${MEGA_QUOTA_GB:-20}

die() { echo "offsite-mega: $*" >&2; exit 1; }
command -v restic >/dev/null || die "restic is missing: sudo apt install -y restic"
command -v rclone >/dev/null || die "rclone is missing: sudo apt install -y rclone"
rclone listremotes 2>/dev/null | grep -qx "$REMOTE:" || die "no rclone remote \"$REMOTE\": run  rclone config  and add your MEGA login as \"$REMOTE\""

case "${1:-backup}" in
  init)
    if [ ! -s "$RESTIC_PASSWORD_FILE" ]; then
      install -d -m 700 "$(dirname "$RESTIC_PASSWORD_FILE")"
      ( umask 077; head -c 32 /dev/urandom | base64 > "$RESTIC_PASSWORD_FILE" )
      echo "made $RESTIC_PASSWORD_FILE: copy it into Bitwarden (cat it in Soma's shell); without it the MEGA copy can't be read"
    fi
    restic cat config >/dev/null 2>&1 && { echo "the repository on MEGA already exists"; exit 0; }
    restic init
    ;;
  check)
    restic check --read-data-subset=5%
    ;;
  backup)
    [ -s "$RESTIC_PASSWORD_FILE" ] || die "no password file: run  offsite-mega.sh init  first"
    have=(); for p in "${PATHS[@]}"; do [ -d "$p" ] && have+=("$p"); done
    [ ${#have[@]} -gt 0 ] || die "none of ${PATHS[*]} exist"
    restic backup --tag homelab --one-file-system "${have[@]}"
    restic forget --tag homelab --keep-daily 7 --keep-weekly 4 --keep-monthly 3 --prune
    used=$(restic stats --mode raw-data --json | python3 -c 'import json,sys;print(json.load(sys.stdin)["total_size"])')
    gb=$(python3 -c "print(round($used/2**30,2))")
    echo "MEGA holds ${gb} GB of the ${QUOTA_GB} GB"
    python3 -c "import sys;sys.exit(0 if $used < 0.9*$QUOTA_GB*2**30 else 1)" || die "MEGA is over 90% full (${gb} GB of ${QUOTA_GB} GB): keep fewer copies or leave a folder out"
    ;;
  *) die "usage: offsite-mega.sh [init|check]" ;;
esac
