#!/usr/bin/env bash
# The homelab VM's base system: everything below the apps. Run on the VM (homelab/run.sh vm vm-base.sh).
# Safe to run again; --check reports differences without changing anything.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
export DEBIAN_FRONTEND=noninteractive
PKGS="ca-certificates curl gnupg linux-image-amd64 qemu-guest-agent nfs-kernel-server syncthing cron rsync git python3 jq sqlite3 unzip mergerfs"
DOCKER_PKGS="docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"

log "Time zone and name"
want "time zone $TIMEZONE" test "$(timedatectl show -p Timezone --value)" = "$TIMEZONE" || run sudo timedatectl set-timezone "$TIMEZONE"
want "hostname $VM_HOSTNAME" test "$(hostname)" = "$VM_HOSTNAME" || run sudo hostnamectl set-hostname "$VM_HOSTNAME"

log "First boot finished"
# cloud-init holds the apt lock on a fresh image, and exits 2 for "done with warnings".
[ "$CHECK" = 1 ] || { sudo cloud-init status --wait >/dev/null 2>&1 || true; }
ok "cloud-init done"

log "Packages"
missing=$(for p in $PKGS; do dpkg -s "$p" >/dev/null 2>&1 || echo "$p"; done | tr '\n' ' ')
want "Debian packages: $PKGS" test -z "$missing" || { note "missing: $missing"; run sudo apt-get update -qq; run sudo -E apt-get install -y -qq $missing; }

want "Docker's apt repo" test -f /etc/apt/sources.list.d/docker.list || {
  if [ "$CHECK" = 0 ]; then
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
    echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian trixie stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  fi; }
want "Tailscale's apt repo" test -f /etc/apt/sources.list.d/tailscale.list || {
  if [ "$CHECK" = 0 ]; then
    curl -fsSL https://pkgs.tailscale.com/stable/debian/trixie.noarmor.gpg | sudo tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
    curl -fsSL https://pkgs.tailscale.com/stable/debian/trixie.tailscale-keyring.list | sudo tee /etc/apt/sources.list.d/tailscale.list >/dev/null
  fi; }
missing=$(for p in $DOCKER_PKGS tailscale; do dpkg -s "$p" >/dev/null 2>&1 || echo "$p"; done | tr '\n' ' ')
want "Docker and Tailscale installed" test -z "$missing" || { run sudo apt-get update -qq; run sudo -E apt-get install -y -qq $missing; }

log "Kernel"
# The cloud kernel has no USB storage driver: the USB media disk never appears with it.
# Both kernels share a version number and GRUB picks the cloud one, so it has to go.
cloud=$(dpkg -l 'linux-image-*cloud*' 2>/dev/null | awk '/^ii/{print $2}' | tr '\n' ' ')
want "no cloud kernel installed" test -z "$cloud" || { run sudo -E apt-get purge -y -qq $cloud; run sudo update-grub; note "reboot to use the full kernel"; }
want "running the full kernel" sh -c "! uname -r | grep -q cloud" || note "reboot needed"

log "DNS port 53 free for AdGuard"
want "systemd-resolved stub listener off" test -f /etc/systemd/resolved.conf.d/no-stub.conf || {
  if [ "$CHECK" = 0 ]; then
    sudo mkdir -p /etc/systemd/resolved.conf.d
    printf '[Resolve]\nDNSStubListener=no\nDNS=1.1.1.1 8.8.8.8\n' | sudo tee /etc/systemd/resolved.conf.d/no-stub.conf >/dev/null
    sudo ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
    sudo systemctl restart systemd-resolved
  fi; }

log "Swap (without it the VM froze when RAM ran out, 2026-10-21)"
want "swap file $VM_SWAP_SIZE at /swapfile" test -f /swapfile || {
  run sudo fallocate -l "$VM_SWAP_SIZE" /swapfile; run sudo chmod 600 /swapfile; run sudo mkswap -q /swapfile; run sudo /usr/sbin/swapon /swapfile; }
ensure_line /etc/fstab "/swapfile none swap sw 0 0" sudo
want "swappiness $VM_SWAPPINESS" test "$(cat /proc/sys/vm/swappiness)" = "$VM_SWAPPINESS" || {
  run sh -c "echo vm.swappiness=$VM_SWAPPINESS | sudo tee /etc/sysctl.d/90-homelab-swap.conf >/dev/null"; run sudo sysctl -q -w vm.swappiness="$VM_SWAPPINESS"; }

log "Services and user"
want "$VM_USER in the docker group" sh -c "id -nG $VM_USER | grep -qw docker" || run sudo usermod -aG docker "$VM_USER"
for s in docker qemu-guest-agent nfs-server; do
  want "$s running" systemctl is-active --quiet "$s" || run sudo systemctl enable --now "$s"
done
want "user services run without a login (linger)" test -f "/var/lib/systemd/linger/$VM_USER" || run sudo loginctl enable-linger "$VM_USER"

finish
