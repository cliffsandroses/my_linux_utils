#!/usr/bin/env bash
# VM 100 as Proxmox sees it. Run on Proxmox (homelab/run.sh pve pve-vm.sh ...).
#
#   pve-vm.sh [--check]              settings vs the profile (also: RAM promised vs RAM the host has)
#   pve-vm.sh disks                  SATA + USB passthrough, NVMe data disk at $VM_NVME_DATA_SIZE
#   pve-vm.sh create [--force]       fresh Debian cloud image on the system disk, cloud-init set up.
#                                    Refuses if that disk holds data, unless --force.
#   pve-vm.sh web-token              read-only API user for the Homelab Web page; prints the token.
#                                    Pipe it to the VM:
#     homelab/run.sh pve pve-vm.sh web-token | ssh moosa@<vm> 'umask 077; mkdir -p ~/.config/homelab-web; cat > ~/.config/homelab-web/pve-token'
set -uo pipefail
. "$(dirname "$0")/lib.sh"
cmd=${1:-check}; FORCE=0; [ "${2:-}" = --force ] && FORCE=1
cfg() { qm config "$VM_ID" 2>/dev/null | sed -n "s/^$1: //p"; }

check() {
  log "VM $VM_ID ($VM_NAME)"
  want "exists" qm status "$VM_ID" || return
  want "running" sh -c "qm status $VM_ID | grep -q running"
  want "$VM_CORES cores" test "$(cfg cores)" = "$VM_CORES"
  want "$VM_MEMORY MB memory" test "$(cfg memory)" = "$VM_MEMORY"
  want "starts at boot" test "$(cfg onboot)" = 1
  want "guest agent enabled" sh -c "qm config $VM_ID | grep -q '^agent: .*enabled=1\|^agent: 1'"
  want "IP $VM_IP via cloud-init" sh -c "qm config $VM_ID | grep -q 'ip=$VM_IP/'"
  want "boots from scsi0" sh -c "qm config $VM_ID | grep -q '^boot: order=scsi0'"
  want "scsi1 = $VM_SATA_DISK" sh -c "qm config $VM_ID | grep -qF 'scsi1: $VM_SATA_DISK'"
  want "usb0 = $VM_USB_DEVICE" test "$(cfg usb0)" = "host=$VM_USB_DEVICE"
  want "scsi2 is $VM_NVME_DATA_SIZE" sh -c "qm config $VM_ID | grep -q '^scsi2: .*size=$VM_NVME_DATA_SIZE'"
  log "Host memory"
  total=$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024 ))
  cts=$(for c in $(pct list | awk 'NR>1 && $2=="running"{print $1}'); do pct config "$c" | sed -n 's/^memory: //p'; done | awk '{s+=$1} END{print s+0}')
  promised=$(( $(cfg memory) + cts ))
  want "running guests promised ${promised} MB of ${total} MB" test "$promised" -le "$((total + 64))"
  log "Storage"
  want "partition 3 fills the boot disk" sh -c "[ \$(( \$(blockdev --getsize64 /dev/nvme0n1) - \$(blockdev --getsize64 /dev/nvme0n1p3) )) -lt 2000000000 ]"
  pvesm status | awk -v s="$PVE_STORAGE" '$1==s{printf "        %s: %.0f GB, %.1f%% used\n", s, $4/1048576, $7}'
}

disks() {
  log "Disks for VM $VM_ID"
  want "scsi1 = $VM_SATA_DISK" sh -c "qm config $VM_ID | grep -qF 'scsi1: $VM_SATA_DISK'" || run qm set "$VM_ID" --scsi1 "$VM_SATA_DISK,backup=0"
  want "usb0 = $VM_USB_DEVICE" test "$(cfg usb0)" = "host=$VM_USB_DEVICE" || run qm set "$VM_ID" --usb0 "host=$VM_USB_DEVICE"
  if [ -z "$(cfg scsi2)" ]; then diff_ "no scsi2"; run qm set "$VM_ID" --scsi2 "$PVE_STORAGE:${VM_NVME_DATA_SIZE%G},discard=on,iothread=1"
  else want "scsi2 is $VM_NVME_DATA_SIZE" sh -c "qm config $VM_ID | grep -q '^scsi2: .*size=$VM_NVME_DATA_SIZE'" || run qm resize "$VM_ID" scsi2 "$VM_NVME_DATA_SIZE"; fi
  note "inside the VM: homelab/run.sh vm vm-storage.sh (formats a blank disk, grows the filesystem)"
}

create() {
  log "VM $VM_ID from the Debian cloud image"
  if qm status "$VM_ID" >/dev/null 2>&1; then
    lv="$(cfg scsi0 | sed -E 's/^[^:]+:([^,]+).*/\1/')"
    used=$(lvs --noheadings -o data_percent "pve/$lv" 2>/dev/null | tr -d ' ')
    if [ "${used%%.*}" -gt 0 ] 2>/dev/null && [ "$FORCE" = 0 ]; then
      echo "STOP: the system disk ($lv) is ${used}% used. This would overwrite it. Add --force only if it is meant to go."; exit 1; fi
    run qm stop "$VM_ID"
    [ "$CHECK" = 1 ] || qm config "$VM_ID" > "/root/vm$VM_ID.conf.before-rebuild-$(date +%Y%m%d-%H%M)"
  else
    run qm create "$VM_ID" --name "$VM_NAME" --cores "$VM_CORES" --memory "$VM_MEMORY" --balloon 0 --cpu host \
      --net0 virtio,bridge=vmbr0,firewall=1 --scsihw virtio-scsi-single --serial0 socket --ostype l26 --onboot 1 \
      --scsi0 "$PVE_STORAGE:${VM_ROOT_SIZE%G},iothread=1"
  fi
  img=/var/lib/vz/images/cloud/$(basename "$VM_CLOUD_IMAGE")
  [ -f "$img" ] || { run mkdir -p "$(dirname "$img")"; run curl -fsSL -o "$img" "$VM_CLOUD_IMAGE"; }
  lv="$(cfg scsi0 | sed -E 's/^[^:]+:([^,]+).*/\1/')"
  run lvchange -ay "pve/$lv"
  run qemu-img convert -n -O raw "$img" "/dev/pve/$lv"
  keys=/root/.ssh/authorized_keys
  run qm set "$VM_ID" --delete ide2 >/dev/null 2>&1
  run qm set "$VM_ID" --ide2 "$PVE_STORAGE:cloudinit" --ciuser "$VM_USER" --sshkeys "$keys" \
    --ipconfig0 "ip=$VM_IP/$LAN_CIDR,gw=$GATEWAY" --nameserver "1.1.1.1 8.8.8.8" --searchdomain homelab.local \
    --boot order=scsi0 --agent enabled=1
  disks
  run qm start "$VM_ID"
  note "then, from the laptop: run.sh vm vm-base.sh, vm-storage.sh, vm-restore.sh, vm-apps.sh, vm-media-pool.sh, vm-schedules.sh"
}

web_token() {
  pveum user list --output-format json | grep -q "\"$PVE_WEB_USER\"" || pveum user add "$PVE_WEB_USER" --comment "homelab /web page, read-only" >&2
  pveum acl modify / --users "$PVE_WEB_USER" --roles PVEAuditor >&2
  pveum user token remove "$PVE_WEB_USER" collector >/dev/null 2>&1 || true
  pveum user token add "$PVE_WEB_USER" collector --privsep 0 --output-format json \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["full-tokenid"] + "=" + d["value"])'
}

case "$cmd" in
  check) check ;;
  disks) disks ;;
  create) create ;;
  web-token) web_token; exit ;;
  *) echo "pve-vm.sh [--check] | disks | create [--force] | web-token"; exit 1 ;;
esac
finish
