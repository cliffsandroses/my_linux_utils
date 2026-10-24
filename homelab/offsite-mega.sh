#!/usr/bin/env bash
# Off-site copy of the homelab's backups on MEGA (20 GB free): ONE file a night, compressed (zstd) and
# encrypted (age), uploaded with MEGA's own MEGAcmd. Moosa, 2026-10-24: "I want any backup going outside to be
# one file and encrypted." Runs on the homelab VM as moosa every morning after the 03:15 backup (offsite-mega.timer).
#
#     offsite-mega.sh init     # once: make the age key (~/.config/homelab-offsite/age.key): copy it into Bitwarden
#     offsite-mega.sh          # newest backup set + git mirrors + Proxmox dumps -> one .tar.zst.age -> MEGA; keep 4
#     offsite-mega.sh check    # download the newest file, decrypt it and read the archive end to end
#
# Needs age and zstd (apt), and MEGAcmd logged in once by Moosa himself (mega-login): his MEGA password never
# passes through anyone else. Without the age key the files on MEGA can't be opened, so the key lives in
# Bitwarden too. rclone isn't used: MEGA refuses rclone's logins on some accounts (rclone forum, March 2026).
set -euo pipefail
KEY=${OFFSITE_KEY:-$HOME/.config/homelab-offsite/age.key}
DEST=${MEGA_DIR:-/homelab-offsite}
KEEP=${MEGA_KEEP:-4}
QUOTA_GB=${MEGA_QUOTA_GB:-20}
SETS=${BACKUP_SETS:-/mnt/data/Backups/homelab}
read -r -a EXTRA <<< "${OFFSITE_EXTRA:-/mnt/data/Backups/git-mirrors /mnt/data/Backups/proxmox}"
TMP=${OFFSITE_TMP:-/mnt/data/Backups/.offsite-tmp}

die() { echo "offsite-mega: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null || die "$1 is missing: $2"; }
need age "sudo apt install -y age"
need zstd "sudo apt install -y zstd"
need mega-put "install MEGAcmd: https://mega.io/cmd"
gb() { python3 -c "print(round($1/2**30,2))"; }

if [ "${1:-}" = init ]; then
  [ -s "$KEY" ] && { echo "the key already exists: $KEY"; exit 0; }
  install -d -m 700 "$(dirname "$KEY")"
  ( umask 077; age-keygen -o "$KEY" 2>/dev/null )
  age-keygen -y "$KEY" > "$KEY.pub"
  echo "made $KEY: copy it into Bitwarden now (cat it in Soma's shell); without it the copies on MEGA can't be opened"
  exit 0
fi
[ -s "$KEY.pub" ] || die "no key yet: run  offsite-mega.sh init  first"
mega-whoami >/dev/null 2>&1 || die "MEGAcmd isn't logged in: run  mega-login <your MEGA email>  on the VM"
mkdir -p "$TMP"; trap 'rm -f "$TMP"/*.part' EXIT

if [ "${1:-}" = check ]; then
  newest=$(mega-ls "$DEST" 2>/dev/null | grep -E '^homelab-.*\.tar\.zst\.age$' | sort | tail -1)
  [ -n "$newest" ] || die "nothing on MEGA in $DEST yet"
  rm -f "$TMP/$newest"; mega-get "$DEST/$newest" "$TMP/" >/dev/null
  n=$(age -d -i "$KEY" "$TMP/$newest" | zstd -dc | tar -t | wc -l)
  rm -f "$TMP/$newest"
  echo "OK: $newest downloads, decrypts and holds $n files"; exit 0
fi

set_dir=$(find "$SETS" -mindepth 1 -maxdepth 1 -type d -name '20*' | sort | tail -1)
[ -n "$set_dir" ] || die "no backup set in $SETS"
name="homelab-$(basename "$set_dir").tar.zst.age"
if mega-ls "$DEST" 2>/dev/null | grep -qx "$name"; then echo "already on MEGA: $name"; exit 0; fi
have=("$set_dir"); for p in "${EXTRA[@]}"; do [ -d "$p" ] && have+=("$p"); done
tar -cf - "${have[@]}" 2>/dev/null | zstd -q -T0 -10 | age -R "$KEY.pub" > "$TMP/$name.part"
mv "$TMP/$name.part" "$TMP/$name"
size=$(stat -c %s "$TMP/$name")
python3 -c "import sys;sys.exit(0 if $size*($KEEP) < 0.9*$QUOTA_GB*2**30 else 1)" \
  || { rm -f "$TMP/$name"; die "one copy is $(gb "$size") GB: $KEEP of them won't fit in ${QUOTA_GB} GB; keep fewer (MEGA_KEEP)"; }
mega-mkdir -p "$DEST" 2>/dev/null || true
mega-put "$TMP/$name" "$DEST/" >/dev/null
mega-ls "$DEST" | grep -qx "$name" || die "upload of $name didn't show up on MEGA"
rm -f "$TMP/$name"
mapfile -t old < <(mega-ls "$DEST" | grep -E '^homelab-.*\.tar\.zst\.age$' | sort | head -n -"$KEEP")
for f in "${old[@]}"; do mega-rm "$DEST/$f" >/dev/null && echo "removed the old copy $f"; done
echo "uploaded $name ($(gb "$size") GB) to MEGA $DEST; keeping the newest $KEEP"
mega-df -h 2>/dev/null | tail -3 || true
