#!/usr/bin/env bash
# Stop the laptop freezing when memory runs out (7 GB RAM). Run once: sudo bash fix-pc.sh
#  - zram: compressed swap in RAM (zstd), used before the slow disk swap -> no more multi-second stalls
#  - systemd-oomd: kills the one runaway app under memory pressure instead of the whole desktop locking up
#  - docker starts only when something uses it (socket activation) instead of sitting in RAM all day
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "Run it with sudo: sudo bash $0"; exit 1; }
pacman -S --needed --noconfirm zram-generator
cat > /etc/systemd/zram-generator.conf <<'C'
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
swap-priority = 100
C
cat > /etc/sysctl.d/99-zram.conf <<'C'
# zram is fast: swap to it early, and read one page at a time
vm.swappiness = 180
vm.watermark_boost_factor = 0
vm.watermark_scale_factor = 125
vm.page-cluster = 0
C
sysctl -q --system
systemctl daemon-reload
systemctl start systemd-zram-setup@zram0.service
systemctl enable --now systemd-oomd.service
if systemctl is-enabled -q docker.service 2>/dev/null; then
  systemctl disable --now docker.service containerd.service 2>/dev/null || true
  systemctl enable docker.socket
fi
# move what sits in the slow disk swap back to RAM/zram, if there is room
used=$(free -m | awk '/Swap/{print $3}'); avail=$(free -m | awk '/Mem/{print $7}')
[ "$avail" -gt "$((used / 2))" ] && for s in $(swapon --show=NAME --noheadings | grep -v zram); do swapoff "$s" && swapon "$s"; done
swapon --show; echo "Done. zram on, oomd on, docker on demand."
