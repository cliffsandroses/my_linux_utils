#!/usr/bin/env bash
# The homelab VM's disks, the media pool and the NFS exports. Run on the VM.
# Never formats a disk that holds anything: only a completely blank NVMe data disk gets mkfs.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

fstab_entry() {  # mountpoint line
  local m=$1 line=$2
  if findmnt --fstab -n "$m" >/dev/null 2>&1; then ok "fstab mounts $m"; return; fi
  diff_ "fstab has no entry for $m"
  [ "$CHECK" = 1 ] || printf '%s\n' "$line" | sudo tee -a /etc/fstab >/dev/null
}

log "NVMe data disk ($NVME_MNT)"
dev=$(readlink -f /dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi2 2>/dev/null || true)
[ -n "$dev" ] || dev=$(readlink -f "/dev/disk/by-label/$NVME_LABEL" 2>/dev/null || true)
if [ -z "$dev" ] || [ ! -b "$dev" ]; then
  diff_ "no scsi2 disk in the VM: attach it on Proxmox (homelab/run.sh pve pve-vm.sh disks)"
else
  fs=$(lsblk -no FSTYPE "$dev" | head -1)
  if [ -z "$fs" ] && [ -z "$(sudo wipefs -n "$dev" 2>/dev/null | tail -n +2)" ]; then
    diff_ "$dev is blank"; run sudo mkfs.ext4 -q -L "$NVME_LABEL" "$dev"
  else
    ok "$dev has a filesystem ($fs, label $(lsblk -no LABEL "$dev"))"
  fi
fi

log "Mount table"
sudo mkdir -p "$DATA_MNT" "$MEDIA_MNT" "$NVME_MNT" "$POOL_MNT" 2>/dev/null || true
fstab_entry "$MEDIA_MNT" "UUID=$MEDIA_UUID  $MEDIA_MNT  ext4  defaults,nofail  0  2"
fstab_entry "$DATA_MNT"  "UUID=$DATA_UUID  $DATA_MNT   ext4  defaults,nofail  0  2   # homelab-data"
fstab_entry "$NVME_MNT"  "LABEL=$NVME_LABEL  $NVME_MNT   ext4  defaults,nofail  0  2   # homelab-nvme (Proxmox local-lvm)"
fstab_entry "$POOL_MNT"  "$POOL_BRANCHES  $POOL_MNT  fuse.mergerfs  $POOL_OPTS  0 0   # media pool: new files go to nvme"
want "pool options match the profile" sh -c "findmnt --fstab -no OPTIONS $POOL_MNT | grep -qF 'category.create=mfs' && findmnt --fstab -no SOURCE $POOL_MNT | grep -qxF '$POOL_BRANCHES'"
[ "$CHECK" = 1 ] || { sudo systemctl daemon-reload; sudo mount -a 2>&1 | grep -v "already mounted" || true; }
for m in "$MEDIA_MNT" "$DATA_MNT" "$NVME_MNT" "$POOL_MNT"; do want "$m mounted" mountpoint -q "$m"; done

if [ -n "${dev:-}" ] && mountpoint -q "$NVME_MNT"; then
  disk=$(sudo blockdev --getsize64 "$dev"); fsz=$(df -B1 --output=size "$NVME_MNT" | tail -1)
  want "$NVME_MNT fills its disk" test $(( (disk - fsz) / 1073741824 )) -lt 20 || run sudo resize2fs "$dev"
fi

log "Landing folders on $NVME_MNT, owned by $PUID"
# mergerfs copies a missing folder's owner from another disk; a root-owned copy made every
# write through the pool fail (2026-10-21). So they exist up front, owned by the apps' user.
for d in "${POOL_LANDING_DIRS[@]}"; do
  p="$NVME_MNT/$d"
  want "$p" test "$(stat -c %u "$p" 2>/dev/null)" = "$PUID" || run sudo install -d -o "$PUID" -g "$PGID" -m 775 "$p"
done

log "NFS waits for the pool at boot"
# After a restart nfs-server could share /mnt/pool before mergerfs mounted it, and Jellyfin's
# mounts died (2026-10-21).
want "nfs-server starts after the pool" test -f /etc/systemd/system/nfs-server.service.d/after-pool.conf || [ "$CHECK" = 1 ] || {
  sudo mkdir -p /etc/systemd/system/nfs-server.service.d
  printf '[Unit]\nRequiresMountsFor=%s %s %s %s\n' "$POOL_MNT" "$MEDIA_MNT" "$DATA_MNT" "$NVME_MNT" \
    | sudo tee /etc/systemd/system/nfs-server.service.d/after-pool.conf >/dev/null
  sudo systemctl daemon-reload; }

log "NFS exports"
before=$(md5sum /etc/exports 2>/dev/null)
for e in "${NFS_EXPORTS[@]}"; do ensure_line /etc/exports "$e" sudo; done
[ "$CHECK" = 1 ] || [ "$before" = "$(md5sum /etc/exports)" ] || { sudo mkdir -p /mnt/nvme/Media; sudo exportfs -ra && note "exports reloaded"; }

finish
