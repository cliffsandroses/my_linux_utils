#!/usr/bin/env bash
# The containers on Proxmox. Run on Proxmox via homelab/run.sh, which stages the files they need
# from the VM into /root/staged first.
#
#   pve-cts.sh [--check]                    both containers vs the profile
#   pve-cts.sh dns-fallback                 CT 101 by ~/homelab/dns-fallback/create-dns-fallback.sh
#   pve-cts.sh jellyfin                     CT 200 per the QuickSync runbook, config from the backup
#   pve-cts.sh backups                      nightly Proxmox config + container backups to the data disk
#                                           (~/homelab/storage/proxmox-backup.sh --install; the VM is
#                                           deliberately not dumped: its contents are in the file backup)
set -uo pipefail
. "$(dirname "$0")/lib.sh"
cmd=${1:-check}
J=$JELLYFIN_CT
in_ct() { pct exec "$J" -- bash -c "$*"; }
ct_disk_used() { lvs --noheadings -o data_percent "pve/vm-$1-disk-0" 2>/dev/null | tr -d ' '; }

check_dns() {
  log "DNS fallback (CT $DNS_FALLBACK_CT, $DNS_FALLBACK_IP)"
  want "exists and runs" sh -c "pct status $DNS_FALLBACK_CT | grep -q running"
  want "answers DNS" sh -c "timeout 4 bash -c 'exec 3<>/dev/udp/$DNS_FALLBACK_IP/53' && ping -c1 -W2 $DNS_FALLBACK_IP"
}

check_jf() {
  log "Jellyfin (CT $J, $JELLYFIN_IP)"
  want "exists and runs" sh -c "pct status $J | grep -q running" || return
  want "memory $JELLYFIN_MEMORY MB" sh -c "pct config $J | grep -qx 'memory: $JELLYFIN_MEMORY'"
  want "MAC $JELLYFIN_MAC" sh -c "pct config $J | grep -q 'hwaddr=$JELLYFIN_MAC'"
  want "GPU passed through" sh -c "pct config $J | grep -q 'lxc.mount.entry: /dev/dri'"
  for m in "${JELLYFIN_MOUNTS[@]}"; do
    src=${m%%:*}; dst=${m##*:}
    want "$dst from $VM_IP:$src" in_ct "grep -qF '$VM_IP:$src ' /etc/fstab && mountpoint -q $dst"
  done
  want "media shares readable" in_ct "for m in /movies /tv /downloads; do timeout 5 ls \$m >/dev/null || exit 1; done"
  want "remounts dropped shares every 5 min" in_ct "systemctl is-active --quiet media-remount.timer"
  want "jellyfin running" in_ct "systemctl is-active --quiet jellyfin"
  want "VAAPI transcoding" in_ct "grep -q '<HardwareAccelerationType>vaapi<' /config/encoding.xml"
  want "waits for its media mounts" in_ct "test -f /etc/systemd/system/jellyfin.service.d/wait-for-media.conf"
}

dns_fallback() {
  if pct status "$DNS_FALLBACK_CT" >/dev/null 2>&1; then
    if [ "$(ct_disk_used "$DNS_FALLBACK_CT")" = "0.00" ]; then diff_ "CT $DNS_FALLBACK_CT exists with an empty disk"; run pct destroy "$DNS_FALLBACK_CT" --purge
    else ok "CT $DNS_FALLBACK_CT exists"; return; fi
  fi
  run bash /root/staged/create-dns-fallback.sh
}

jellyfin() {
  if pct status "$J" >/dev/null 2>&1 && [ "$(ct_disk_used "$J")" = "0.00" ]; then
    diff_ "CT $J exists with an empty disk"; run pct destroy "$J" --purge; fi
  if ! pct status "$J" >/dev/null 2>&1; then
    diff_ "no CT $J"
    if [ "$CHECK" = 0 ]; then
      pveam update >/dev/null
      T=$(pveam available --section system | awk -v t="$JELLYFIN_TEMPLATE" '$2 ~ t {print $2}' | sort -V | tail -1)
      pveam list local | grep -q "$T" || pveam download local "$T" >/dev/null
      pct create "$J" "local:vztmpl/$T" --hostname jellyfin --cores "$JELLYFIN_CORES" --memory "$JELLYFIN_MEMORY" --swap 512 \
        --rootfs "$PVE_STORAGE:$JELLYFIN_DISK" --net0 "name=eth0,bridge=vmbr0,ip=$JELLYFIN_IP/$LAN_CIDR,gw=$GATEWAY,hwaddr=$JELLYFIN_MAC" \
        --unprivileged 0 --features nesting=1,mount=nfs --onboot 1 --nameserver "$VM_IP 1.1.1.1" >/dev/null
      printf 'lxc.cgroup2.devices.allow: c 226:0 rwm\nlxc.cgroup2.devices.allow: c 226:128 rwm\nlxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir\n' >> "/etc/pve/lxc/$J.conf"
      pct start "$J"; sleep 8
    fi
  fi
  want "memory $JELLYFIN_MEMORY MB" sh -c "pct config $J | grep -qx 'memory: $JELLYFIN_MEMORY'" || run pct set "$J" --memory "$JELLYFIN_MEMORY"
  [ "$CHECK" = 1 ] && { check_jf; return; }

  log "Inside CT $J"
  in_ct "export DEBIAN_FRONTEND=noninteractive; dpkg -s nfs-common >/dev/null 2>&1 || { apt-get update -qq; apt-get install -y -qq curl gnupg nfs-common sqlite3 >/dev/null; }"
  for m in "${JELLYFIN_MOUNTS[@]}"; do
    src=${m%%:*}; dst=${m##*:}
    in_ct "mkdir -p $dst; sed -i '\\| $dst |d' /etc/fstab; echo '$VM_IP:$src $dst nfs ro,vers=4,_netdev,nofail 0 0' >> /etc/fstab"
  done
  in_ct "systemctl daemon-reload; timeout 60 mount -a; findmnt -t nfs,nfs4 -o TARGET,SOURCE | tail -n +2"
  # A homelab VM restart leaves these mounts dead (2026-10-21): check and remount every 5 minutes.
  in_ct "cat > /usr/local/sbin/media-remount <<'EOF'
#!/bin/sh
# Remount any media share from the homelab VM that has dropped or gone stale (e.g. after the VM restarts).
fixed=0
for m in /movies /tv /music /shorts /downloads; do
  if ! timeout 5 ls \"\$m\" >/dev/null 2>&1 || ! mountpoint -q \"\$m\"; then
    umount -l \"\$m\" 2>/dev/null; timeout 30 mount \"\$m\" && fixed=1
  fi
done
[ \$fixed = 1 ] && logger -t media-remount 'remounted media shares' || true
EOF
    chmod 755 /usr/local/sbin/media-remount
    printf '[Unit]\nDescription=Remount dropped media shares from the homelab VM\nAfter=network-online.target\n[Service]\nType=oneshot\nExecStart=/usr/local/sbin/media-remount\n' > /etc/systemd/system/media-remount.service
    printf '[Unit]\nDescription=Check the media shares every 5 minutes\n[Timer]\nOnBootSec=2min\nOnUnitActiveSec=5min\n[Install]\nWantedBy=timers.target\n' > /etc/systemd/system/media-remount.timer
    systemctl daemon-reload; systemctl enable --now media-remount.timer >/dev/null 2>&1"
  # Jellyfin from its own repo, held: an automatic major jump is how a working setup breaks overnight.
  in_ct "dpkg -s jellyfin-server >/dev/null 2>&1 || { curl -fsSL https://repo.jellyfin.org/install-debuntu.sh | bash >/dev/null 2>&1; apt-mark hold jellyfin jellyfin-server jellyfin-web >/dev/null; }"
  # Config from the backup into /config: library IDs derive from that path, so it must stay /config.
  if ! in_ct "test -f /config/data/data/jellyfin.db"; then
    pct push "$J" /root/staged/jellyfin-config.tar.gz /root/jellyfin-config.tar.gz
    in_ct "systemctl stop jellyfin; mkdir -p /config; tar -xzf /root/jellyfin-config.tar.gz -C /config --strip-components=1; chown -R jellyfin:jellyfin /config"
  fi
  in_ct "sed -i '/^JELLYFIN_\\(CONFIG\\|DATA\\|CACHE\\|LOG\\)_DIR=/d' /etc/default/jellyfin
    printf 'JELLYFIN_CONFIG_DIR=/config\nJELLYFIN_DATA_DIR=/config/data\nJELLYFIN_CACHE_DIR=/config/cache\nJELLYFIN_LOG_DIR=/config/log\n' >> /etc/default/jellyfin
    mkdir -p /etc/systemd/system/jellyfin.service.d
    printf '[Unit]\nRequiresMountsFor=/movies /tv /music /shorts /downloads\n' > /etc/systemd/system/jellyfin.service.d/wait-for-media.conf
    GID=\$(stat -c %g /dev/dri/renderD128); getent group \$GID >/dev/null || groupadd -g \$GID hostrender
    usermod -aG \$(getent group \$GID | cut -d: -f1) jellyfin"
  # VAAPI on the Intel UHD 630; tone mapping off (the runbook's advice).
  in_ct "F=/config/encoding.xml; [ -f \$F ] && ! grep -q '<HardwareAccelerationType>vaapi<' \$F && cp \$F \$F.bak-before-vaapi && python3 - <<'EOF'
import xml.etree.ElementTree as ET
p = '/config/encoding.xml'; t = ET.parse(p); r = t.getroot()
def s(k, v):
    e = r.find(k)
    if e is None: e = ET.SubElement(r, k)
    e.text = v
s('HardwareAccelerationType', 'vaapi'); s('VaapiDevice', '/dev/dri/renderD128'); s('EnableHardwareEncoding', 'true'); s('EnableTonemapping', 'false')
c = r.find('HardwareDecodingCodecs')
if c is None: c = ET.SubElement(r, 'HardwareDecodingCodecs')
for x in list(c): c.remove(x)
for k in ('h264', 'hevc', 'vp9'): ET.SubElement(c, 'string').text = k
t.write(p, xml_declaration=True, encoding='utf-8')
EOF
    chown jellyfin:jellyfin /config/encoding.xml 2>/dev/null; true"
  in_ct "systemctl daemon-reload; systemctl restart jellyfin"; sleep 15
  check_jf
}

check_backups() {
  log "Proxmox backups (config + CTs $JELLYFIN_CT $DNS_FALLBACK_CT, nightly 02:30, keep 3)"
  want "nightly cron" sh -c "crontab -l | grep -q proxmox-backup.sh"
  want "backup share mounted" mountpoint -q /mnt/homelab-backups
  want "a container backup from the last 26 h" sh -c "find /mnt/homelab-backups/dump -name 'vzdump-lxc-$JELLYFIN_CT-*.tar.zst' -mmin -1560 | grep -q ."
}

backups() {
  check_backups && return
  [ "$CHECK" = 1 ] || bash /root/staged/proxmox-backup.sh --install
}

case "$cmd" in
  check) check_dns; check_jf; check_backups ;;
  backups) backups ;;
  dns-fallback) dns_fallback ;;
  jellyfin) jellyfin ;;
  *) echo "pve-cts.sh [--check] | dns-fallback | jellyfin | backups"; exit 1 ;;
esac
finish
