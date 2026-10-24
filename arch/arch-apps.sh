#!/usr/bin/env bash
# Mak's apps on Arch (KDE Plasma), when there is no saved package list to restore from.
# Prefer RESTORE.md 1.5 (~/Backups/pc/pkglist-*.txt) when those lists exist: they are exact.
# This list was rebuilt on 2026-10-21, after the NVMe swap lost the lists, from
# Linux_SetupScript.sh, the Axon notes, and the swap plan's "reinstall by hand" list.
# Safe to run again: everything uses --needed.
#
# Lessons built in:
# - AUR packages use their prebuilt -bin versions. voxtype and ludusavi compile Rust from
#   source otherwise: 30+ minutes and every byte of RAM on this 7 GB laptop.
# - Renamed packages: p7zip is 7zip, libva-mesa-driver is part of mesa, syncthingtray is in
#   the official repos (not the AUR).
set -uo pipefail
sudo -n true 2>/dev/null || sudo -v || exit 1   # -n first: works over SSH with passwordless sudo
while true; do sudo -n true; sleep 50; kill -0 "$$" 2>/dev/null || exit; done 2>/dev/null &

log() { printf '\n== %s\n' "$*"; }
failed=()

# --- official repos ------------------------------------------------------------------------
NATIVE=(
  # basics (Linux_SetupScript.sh: essentials)
  base-devel vim nano htop fastfetch git jq rsync 7zip unzip tmux wget curl reflector flatpak
  # dev (Linux_SetupScript.sh: dev tools; Cairn and the Android extension need adb + JDK)
  docker docker-buildx docker-compose jdk-openjdk python python-pip android-tools nodejs npm
  # apps (Linux_SetupScript.sh: media apps)
  bluez bluez-utils blueman wezterm obsidian flameshot libreoffice-fresh
  # password manager: talks to your Vaultwarden at https://vaultwarden.meldev.duckdns.org
  bitwarden
  # browsers
  chromium torbrowser-launcher
  # media
  mpv vlc
  # fonts (swap plan: ttf-jetbrains-mono-nerd)
  ttf-jetbrains-mono-nerd ttf-liberation-mono-nerd noto-fonts noto-fonts-emoji
  # sync + network (already installed: syncthing tailscale)
  syncthing tailscale syncthingtray syncthingtray-dolphin
  # AMD graphics, Ryzen 5 5500U (Linux_SetupScript.sh: hardware drivers)
  mesa vulkan-radeon
)
log "Official packages (${#NATIVE[@]})"
sudo pacman -Syu --needed --noconfirm "${NATIVE[@]}" || failed+=("some official packages")

# --- AUR helper -------------------------------------------------------------------------------
if ! command -v yay >/dev/null; then
  log "Installing yay (AUR helper)"
  tmp=$(mktemp -d) && git clone -q https://aur.archlinux.org/yay-bin.git "$tmp/yay-bin" \
    && (cd "$tmp/yay-bin" && makepkg -si --noconfirm) || failed+=("yay")
  rm -rf "$tmp"
fi

# --- AUR (swap plan: Brave, Zen, chiaki, VSCodium...; Axon notes: Heroic, LocalSend, Voxtype, Kopia) ---
AUR=(
  brave-bin zen-browser-bin vscodium-bin chiaki-ng-bin heroic-games-launcher-bin
  localsend-bin voxtype-bin kopia-ui-bin ludusavi-bin
)
if command -v yay >/dev/null; then
  for p in "${AUR[@]}"; do
    log "AUR: $p"
    yay -S --needed --noconfirm --answerdiff None --answerclean None "$p" || failed+=("$p")
  done
fi

# --- quiet shells: gpm's profile script runs `tty`, which prints "ttyname error" in shells
# without a terminal (Claude's ! commands). It only matters for mouse paste on a text console.
log "Silencing the ttyname message"
sudo rm -f /etc/profile.d/gpm.sh
grep -q '^NoExtract.*etc/profile.d/gpm.sh' /etc/pacman.conf \
  || sudo sed -i '/^\[options\]/a NoExtract = etc/profile.d/gpm.sh' /etc/pacman.conf

# --- services ---------------------------------------------------------------------------------
log "Services"
sudo systemctl enable --now bluetooth docker >/dev/null 2>&1 || failed+=("bluetooth/docker service")
sudo usermod -aG docker "$USER"
ln -sf /opt/KopiaUI/resources/server/kopia "$HOME/.local/bin/kopia" 2>/dev/null || true

log "Done"
if [ ${#failed[@]} -gt 0 ]; then printf 'These did not install: %s\n' "${failed[*]}"; else echo "Everything installed."; fi
echo "Log out and back in once so the docker group applies."
