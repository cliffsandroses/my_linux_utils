#!/usr/bin/env bash
# Save a copy of every LUKS header on this machine, off the machine.
#
# Why: on 2026-10-21 a disk clone zeroed the first MiB of the laptop's LUKS partition. The data
# behind it was intact, but the header holds the only copy of the master key, so the whole
# disk became unreadable. With a header backup, `cryptsetup luksHeaderRestore` brings it back.
#
# Run after installing, and again after any `cryptsetup luksChangeKey/luksAddKey` (the backup
# holds the keyslots as they were). The header file only opens with a passphrase that was valid
# when it was taken, but treat it like the disk itself: never put it anywhere public.
#
#     ./luks-header-backup.sh                 # every LUKS device found
#     COPY_TO= ./luks-header-backup.sh        # keep it local only
set -euo pipefail
DEST="${LUKS_HEADER_DIR:-$HOME/Backups/pc/luks}"
COPY_TO="${COPY_TO-moosa@192.168.10.20:/mnt/data/Backups/laptop-pc/luks/}"

mapfile -t devs < <(lsblk -nrpo NAME,FSTYPE | awk '$2=="crypto_LUKS"{print $1}')
[ ${#devs[@]} -gt 0 ] || { echo "No LUKS devices on this machine: nothing to back up."; exit 0; }

mkdir -p "$DEST"; chmod 700 "$DEST"
for dev in "${devs[@]}"; do
    f="$DEST/$(basename "$dev").header.img"
    sudo rm -f "$f.new"
    sudo cryptsetup luksHeaderBackup "$dev" --header-backup-file "$f.new"
    sudo chown "$USER:" "$f.new"; chmod 600 "$f.new"; mv "$f.new" "$f"
    sudo cryptsetup luksDump "$dev" > "$f.dump.txt"; chmod 600 "$f.dump.txt"
    echo "$dev -> $f ($(du -h "$f" | cut -f1), UUID $(sudo cryptsetup luksUUID "$dev"))"
done

if [ -n "$COPY_TO" ]; then
    rsync -a -e "ssh -o BatchMode=yes -o ConnectTimeout=10" "$DEST/" "$COPY_TO" \
        && echo "Copied to $COPY_TO" || echo "warning: could not copy to $COPY_TO" >&2
fi
cat <<'EOF'

To restore a damaged header (the data must be intact; check with `cryptsetup luksDump` first):
    sudo cryptsetup luksHeaderRestore /dev/<partition> --header-backup-file <name>.header.img
EOF
