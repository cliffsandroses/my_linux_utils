#!/usr/bin/env bash
# Run a homelab step on the machine it belongs to, from the laptop.
#
#   homelab/run.sh vm  vm-storage.sh --check     # on the homelab VM, as the VM user
#   homelab/run.sh pve pve-vm.sh disks           # on Proxmox, as root
#   PROFILE=moosa homelab/run.sh ...             # another profile from profiles/
#
# It copies profiles/ and homelab/ to the target (~/.local/share/my_linux_utils on the VM,
# /root/my_linux_utils on Proxmox) and runs the script there, so a fresh machine needs nothing
# but SSH. Needs key login to both (see HOMELAB-REBUILD.md).
set -euo pipefail
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
PROFILE="${PROFILE:-moosa}"
# shellcheck source=../profiles/moosa.env
. "$REPO/profiles/$PROFILE.env"
where=${1:?vm or pve}; script=${2:?script name}; shift 2
SSH="ssh -o BatchMode=yes -o ConnectTimeout=10"

case "$where" in
  vm)  target="$VM_USER@$VM_IP"; dest='$HOME/.local/share/my_linux_utils' ;;
  pve) target="root@$PVE_HOST"; dest=/root/my_linux_utils ;;
  *)   echo "first argument: vm or pve" >&2; exit 1 ;;
esac

# Files a Proxmox step needs from the VM (it has no key to reach the VM itself).
stage() {  # remote-path-on-VM name
  $SSH "$VM_USER@$VM_IP" "cat $1" | $SSH "root@$PVE_HOST" "mkdir -p /root/staged && cat > /root/staged/$2"
  echo "staged $1 on Proxmox as /root/staged/$2"
}
if [ "$where" = pve ] && [ "$script" = pve-cts.sh ]; then
  case " $* " in
    *" dns-fallback "*) stage '~/homelab/dns-fallback/create-dns-fallback.sh' create-dns-fallback.sh ;;
  esac
  case " $* " in
    *" backups "*) stage '~/homelab/storage/proxmox-backup.sh' proxmox-backup.sh ;;
  esac
  case " $* " in
    *" jellyfin "*) stage "\$(ls -1 $JELLYFIN_BACKUP_GLOB | sort | tail -1)" jellyfin-config.tar.gz ;;
  esac
fi

tar -C "$REPO" -cf - profiles homelab | $SSH "$target" "mkdir -p $dest && tar -C $dest -xf -"
$SSH "$target" "cd $dest && PROFILE=$PROFILE HS_KEY=${HS_KEY:-} bash homelab/$script $(printf '%q ' "$@")"
