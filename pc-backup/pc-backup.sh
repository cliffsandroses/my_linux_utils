#!/bin/bash
# Nightly PC backup: refresh package lists and game saves, then snapshot ~ with Kopia.
# Run by pc-backup.timer. Exclusions live in ~/.kopiaignore. See ../RESTORE.md.
set -euo pipefail

out=~/Backups/pc
mkdir -p "$out"

if command -v pacman >/dev/null; then
    pacman -Qqen > "$out/pkglist-native.txt"
    pacman -Qqem > "$out/pkglist-aur.txt"
fi
command -v flatpak >/dev/null && flatpak list --app --columns=application > "$out/flatpaks.txt"
command -v ludusavi >/dev/null && ludusavi backup --force >/dev/null

/opt/KopiaUI/resources/server/kopia snapshot create ~
