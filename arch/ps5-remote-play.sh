#!/usr/bin/env bash
# PS5 Remote Play on this Arch laptop: chiaki-ng, hardware video decoding, the DualSense,
# finding the PS5, the firewall, and keeping the pairing safe.
# Each step checks first and skips what is already done, so it is safe to run again.
# A step that fails is reported with its fix and the other steps still run; the summary at the
# end lists everything that needs a hand. A full log goes to ~/.local/state/ps5-remote-play/.
#
#     ./ps5-remote-play.sh                     # set everything up
#     ./ps5-remote-play.sh --check             # only report, change nothing
#     ./ps5-remote-play.sh --ps5-ip 192.168.10.119
#     ./ps5-remote-play.sh --restore FILE      # put back a saved pairing (a Chiaki.conf copy)
#     ./ps5-remote-play.sh --flatpak           # the Flathub build instead of the AUR one
#     ./ps5-remote-play.sh --yes               # answer yes to every question
#
# Pairing needs the PIN shown on the TV, so it happens in chiaki-ng's window: the script says
# when and how, opens chiaki-ng, and backs the pairing up once it exists.
#
# Lessons built in:
# - The pairing keys live only in ~/.config/Chiaki/Chiaki.conf. A wipe loses them unless they
#   are copied somewhere, so the script keeps dated copies in ~/.config/Chiaki/backups (and ~ is
#   in the nightly Kopia snapshot).
# - The PS5 answers chiaki's search from its own address to ports 9303-9319, which UFW drops
#   because the search went out as a broadcast. Without a rule chiaki-ng never lists the PS5.
# - Tailscale with --accept-routes pulls LAN traffic into the tunnel (post-install.sh).
# - chiaki-ng is AUR only (chiaki-ng-bin, as in arch-apps.sh); Flathub is the fallback.
set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"; REPO="$(dirname "$HERE")"
# shellcheck source=../profiles/moosa.env
[ -f "$REPO/profiles/${PROFILE:-moosa}.env" ] && . "$REPO/profiles/${PROFILE:-moosa}.env"

FLATPAK_ID=io.github.streetpea.Chiaki4deck
UFW_COMMENT=ps5-remote-play
RULES_FILE=/etc/udev/rules.d/70-ps5-controller.rules

CHECK=0 YES=0 FORCE_FLATPAK=0 RESTORE="" PS5_IP_ARG=""
usage() { sed -n '2,/^set -uo/p' "$0" | sed '$d; s/^# \{0,1\}//'; }
while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK=1 ;;
    -y|--yes) YES=1 ;;
    --flatpak) FORCE_FLATPAK=1 ;;
    --ps5-ip) PS5_IP_ARG="${2:-}"; shift ;;
    --ps5-ip=*) PS5_IP_ARG="${1#*=}" ;;
    --restore) RESTORE="${2:-}"; shift ;;
    --restore=*) RESTORE="${1#*=}" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1 (see --help)" >&2; exit 2 ;;
  esac
  shift
done

is_ipv4() { [[ $1 =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  local o; for o in "${BASH_REMATCH[@]:1}"; do ((10#$o <= 255)) || return 1; done; }
if [ -n "$PS5_IP_ARG" ] && ! is_ipv4 "$PS5_IP_ARG"; then echo "--ps5-ip: '$PS5_IP_ARG' is not an IPv4 address" >&2; exit 2; fi
if [ -n "$RESTORE" ] && [ ! -f "$RESTORE" ]; then echo "--restore: no such file: $RESTORE" >&2; exit 2; fi
PS5_IP="${PS5_IP_ARG:-${PS5_IP:-}}"
if [ -n "$PS5_IP" ] && ! is_ipv4 "$PS5_IP"; then echo "PS5_IP in the profile is not an IPv4 address: $PS5_IP" >&2; PS5_IP=""; fi

if [ "$(id -u)" -eq 0 ]; then
  echo "Run this as your normal user, not as root or with sudo: it asks for sudo itself when it needs it," >&2
  echo "and chiaki-ng's settings, the AUR build and the pairing all belong to your user." >&2
  exit 1
fi

# ---------------------------------------------------------------- output, log, results
LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/ps5-remote-play"
if mkdir -p "$LOG_DIR" 2>/dev/null; then
  LOG="$LOG_DIR/$(date +%Y-%m-%d-%H%M%S)$( ((CHECK)) && echo -check).log"
  exec > >(tee -a "$LOG") 2>&1
  TEE_PID=$!
else
  LOG=""
fi
CUR="" WARNS=() FAILS=() TODO=()
step() { CUR="$1"; printf '\n== %s\n' "$*"; }
ok()   { printf '   ok: %s\n' "$*"; }
note() { printf '   %s\n' "$*"; }
warn() { printf '   WARNING: %s\n' "$*"; WARNS+=("$CUR: $*"); }
fail() { printf '   FAILED: %s\n' "$*"; FAILS+=("$CUR: $*"); }
todo() { TODO+=("$*"); }
show() { sed 's/^/   | /'; }
ask() {                                   # ask "question": yes with --yes; no when there is no terminal
  ((YES)) && { note "$1 yes (--yes)"; return 0; }
  [ -t 0 ] || [ -r /dev/tty ] || { note "$1 no (no terminal to ask on; --yes answers yes)"; return 1; }
  local a; read -r -p "   $1 [y/N] " a </dev/tty 2>/dev/tty || return 1
  [[ $a == [yY]* ]]
}

summary() {
  printf '\n== Summary\n'
  if [ ${#FAILS[@]} -eq 0 ] && [ ${#WARNS[@]} -eq 0 ]; then
    note "Everything checked out."
  fi
  local x
  for x in "${FAILS[@]}"; do note "FAILED   $x"; done
  for x in "${WARNS[@]}"; do note "WARNING  $x"; done
  if [ ${#TODO[@]} -gt 0 ]; then
    printf '\n   Still by hand:\n'
    for x in "${TODO[@]}"; do printf '%s\n' "$x" | sed '1s/^/   - /; 2,$s/^/     /'; done
  fi
  [ -n "$LOG" ] && note "" && note "Log: $LOG"
  ((CHECK)) && note "(--check: nothing was changed)"
}
finish() {                                # let the log catch up before the shell prompt comes back
  kill "${SUDO_KEEPALIVE:-0}" 2>/dev/null
  exec 1>&- 2>&-
  [ -n "${TEE_PID:-}" ] && wait "$TEE_PID" 2>/dev/null
  exit "$1"
}
on_interrupt() { printf '\n   Stopped (Ctrl-C).\n'; summary; finish 130; }
trap on_interrupt INT TERM

# ---------------------------------------------------------------- 1. basics
step "Basics"
if [ ! -f /etc/arch-release ] && ! command -v pacman >/dev/null; then
  fail "this is not Arch Linux (no pacman): this script only knows Arch"; summary; finish 1
fi
[ -f /etc/arch-release ] || note "pacman found but no /etc/arch-release: an Arch-based distro; carrying on"
grep -q $'\r' "$0" && warn "this script has Windows line endings: run  dos2unix $0  if anything looks odd"

SUDO=0
if ((CHECK)); then
  sudo -n true 2>/dev/null && SUDO=1 || note "--check: not asking for sudo, so firewall rules that need it are not read"
elif sudo -n true 2>/dev/null || sudo -v; then   # -n first: works over SSH with passwordless sudo
  SUDO=1
  # its own output goes nowhere: holding the log pipe open would stop the script from ever ending
  while true; do sudo -n true; sleep 50; kill -0 "$$" 2>/dev/null || exit; done >/dev/null 2>&1 &
  SUDO_KEEPALIVE=$!
  trap 'kill "${SUDO_KEEPALIVE:-0}" 2>/dev/null' EXIT
else
  fail "sudo did not work: installing packages, the controller rule and the firewall rule are skipped (is $USER in the wheel group?)"
fi
((SUDO)) && ok "sudo"

NET=0
if curl -fsS -m 10 -o /dev/null https://archlinux.org 2>/dev/null || curl -fsS -m 10 -o /dev/null https://aur.archlinux.org 2>/dev/null; then
  NET=1; ok "internet"
else
  warn "no internet (archlinux.org did not answer): nothing new can be installed; the LAN checks still run"
fi

GUI=0
if [ -n "${WAYLAND_DISPLAY:-}${DISPLAY:-}" ]; then GUI=1; ok "desktop session (${XDG_SESSION_TYPE:-unknown})"; else note "no desktop session here (SSH or a TTY): chiaki-ng is not opened"; fi

# ---------------------------------------------------------------- package helpers
# Exact name only: `pacman -Qq chiaki` answers "chiaki-ng-bin", because that package provides chiaki.
pkg_installed() { [ "$(pacman -Qq "$1" 2>/dev/null)" = "$1" ]; }

wait_pacman_lock() {                      # wait for another pacman, or clear a lock left by a crash
  local lock=/var/lib/pacman/db.lck waited=0
  while [ -e "$lock" ]; do
    if ! pgrep -x 'pacman|yay|paru|pamac|pamac-daemon|packagekitd|pacman-key|makepkg' >/dev/null 2>&1; then
      warn "pacman's lock ($lock) is left over from a crash or a cut-off update, and nothing is using it"
      if ask "Remove the stale lock?"; then sudo rm -f "$lock" && return 0; fi
      fail "pacman is locked: remove $lock once you are sure no update is running"; return 1
    fi
    ((waited == 0)) && note "another package manager is busy (Discover or an update?): waiting up to 10 minutes"
    sleep 5; waited=$((waited + 5))
    ((waited >= 600)) && { fail "pacman stayed locked for 10 minutes: finish or close the other update, then run this again"; return 1; }
  done
  return 0
}

UPGRADED=0
system_upgrade() {                        # a full pacman -Syu: Arch only supports installing on an up-to-date system
  ((UPGRADED)) && return 0
  ask "The package database is out of date for this. Upgrade the whole system now (sudo pacman -Syu)?" || {
    fail "skipped the system upgrade: run  sudo pacman -Syu  and then this script again"; return 1; }
  pac_run -Syu && UPGRADED=1
}

pac_run() {                               # run pacman, fixing the failures that have a known fix
  local out rc try
  for try in 1 2 3; do
    wait_pacman_lock || return 1
    out=$(sudo pacman --noconfirm "$@" 2>&1); rc=$?
    printf '%s\n' "$out" | grep -v '^\s*$' | tail -n 12 | show
    ((rc == 0)) && return 0
    case "$out" in
      *"Could not resolve host"*|*"Couldn't resolve"*|*"Resolving timed out"*)
        NET=0; fail "no internet (DNS failed) while downloading packages"; return 1 ;;
      *"unable to lock database"*) continue ;;
      *"PGP signature"*|*"unknown trust"*|*"signature from"*|*"invalid or corrupted package"*|*"keyring is not writable"*|*"could not be looked up remotely"*)
        note "package signatures failed: refreshing the Arch keyring (the fix from the Arch wiki)"
        sudo pacman-key --init >/dev/null 2>&1; sudo pacman-key --populate archlinux >/dev/null 2>&1
        sudo pacman -Sy --noconfirm --needed archlinux-keyring 2>&1 | tail -n 3 | show
        [[ " $* " == *" -Syu "* ]] || { UPGRADED=0; system_upgrade || return 1; } ;;
      *"exists in filesystem"*)
        fail "files already on disk clash with a package (listed above). Move them away and run this again; the script does not overwrite them"
        return 1 ;;
      *"not enough free disk space"*|*"No space left on device"*)
        fail "not enough disk space for packages: free some (sudo pacman -Sc empties the package cache), then run again"; return 1 ;;
      *"are in conflict"*)
        fail "package conflict (above): remove the conflicting package, then run again"; return 1 ;;
      *"failed retrieving file"*|*"failed to retrieve some files"*|*"failed to synchronize"*)
        if ((UPGRADED)) || [[ " $* " == *" -Syu "* ]]; then
          if command -v reflector >/dev/null && ask "Mirrors are failing. Pick fresh fast mirrors with reflector?"; then
            sudo cp /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.bak-ps5-remote-play
            sudo reflector --latest 20 --protocol https --sort rate --number 10 --save /etc/pacman.d/mirrorlist 2>&1 | tail -n 3 | show
            continue
          fi
          fail "downloads keep failing (mirrors): try again later or run  sudo reflector --latest 20 --protocol https --sort rate --save /etc/pacman.d/mirrorlist"
          return 1
        fi
        system_upgrade || return 1 ;;
      *"target not found"*|*"could not satisfy dependencies"*|*"unable to satisfy dependency"*)
        # an out-of-date database only explains this when installing (-S), never when removing
        [[ $1 == -S* ]] || return 1
        ((UPGRADED)) && return 1
        system_upgrade || return 1 ;;
      *) return 1 ;;
    esac
  done
  return 1
}

pac_install() {                           # install whatever of these (or what provides them) is missing
  local missing
  missing=$(pacman -T "$@" 2>/dev/null | tr '\n' ' '); missing=${missing% }
  [ -z "$missing" ] && return 0
  ((CHECK)) && { note "would install: $missing"; return 0; }
  ((NET)) || { fail "no internet, so cannot install: $missing"; return 1; }
  ((SUDO)) || { fail "no sudo, so cannot install: $missing"; return 1; }
  note "installing: $missing"
  # shellcheck disable=SC2086
  pac_run -S --needed $missing
}

aur_helper() { command -v paru || command -v yay; }

install_yay() {
  ((CHECK)) && { note "would install yay (AUR helper)"; return 0; }
  ask "No AUR helper (yay or paru) is installed. Install yay?" || return 1
  pac_install base-devel git || return 1
  local tmp out rc; tmp=$(mktemp -d) || return 1
  out=$(git clone -q https://aur.archlinux.org/yay-bin.git "$tmp/yay-bin" 2>&1 \
        && cd "$tmp/yay-bin" && makepkg -si --noconfirm --needed 2>&1); rc=$?
  printf '%s\n' "$out" | grep -v '^\s*$' | tail -n 8 | show
  rm -rf "$tmp"
  ((rc == 0)) && command -v yay >/dev/null && { ok "yay installed"; return 0; }
  fail "could not build yay (above)"; return 1
}

aur_install() {                           # aur_install <package>
  local helper out rc try key args
  if ((CHECK)); then
    helper=$(aur_helper) && note "would install $1 from the AUR with $(basename "$helper")" \
      || note "would install yay, then $1 from the AUR"
    return 0
  fi
  helper=$(aur_helper) || { install_yay && helper=$(aur_helper); } || return 1
  ((NET)) || { fail "no internet, so cannot install $1"; return 1; }
  args=(-S --needed --noconfirm)
  case "$helper" in
    *yay)  args+=(--answerdiff None --answerclean None --answeredit None --removemake) ;;
    *paru) args+=(--skipreview --removemake) ;;
  esac
  for try in 1 2; do
    wait_pacman_lock || return 1
    note "building $1 with $(basename "$helper") (a -bin package only unpacks upstream's build)"
    out=$("$helper" "${args[@]}" "$1" 2>&1); rc=$?
    printf '%s\n' "$out" | grep -v '^\s*$' | tail -n 12 | show
    ((rc == 0)) && return 0
    case "$out" in
      *"unknown public key"*)
        key=$(grep -oE 'unknown public key [0-9A-F]+' <<<"$out" | awk '{print $4}' | head -n 1)
        [ -n "$key" ] && note "importing the packager's signing key $key" && gpg --recv-keys "$key" 2>&1 | tail -n 2 | show ;;
      *"Could not resolve host"*|*"Couldn't resolve"*) NET=0; fail "no internet while building $1"; return 1 ;;
      *"target not found"*|*"could not satisfy"*|*"unable to satisfy"*|*"failed retrieving"*|*"404"*)
        ((UPGRADED)) && return 1
        system_upgrade || return 1 ;;
      *"are in conflict"*) fail "$1 conflicts with an installed package (above)"; return 1 ;;
      *) return 1 ;;
    esac
  done
  return 1
}

# ---------------------------------------------------------------- 2. chiaki-ng
step "chiaki-ng (the Remote Play app)"
CHIAKI_KIND="" CHIAKI_PKG="" CHIAKI_CMD=() CHIAKI_CLI=()
find_chiaki() {
  local p
  CHIAKI_KIND="" CHIAKI_PKG="" CHIAKI_CMD=() CHIAKI_CLI=()
  if ! ((FORCE_FLATPAK)); then
    for p in chiaki-ng-bin chiaki-ng chiaki-ng-git; do
      if pkg_installed "$p"; then
        CHIAKI_KIND=native CHIAKI_PKG=$p
        CHIAKI_CMD=("$(command -v chiaki || command -v chiaki-ng || echo chiaki)")
        command -v chiaki-cli >/dev/null && CHIAKI_CLI=(chiaki-cli)
        return 0
      fi
    done
  fi
  if command -v flatpak >/dev/null && flatpak info "$FLATPAK_ID" >/dev/null 2>&1; then
    CHIAKI_KIND=flatpak CHIAKI_CMD=(flatpak run "$FLATPAK_ID")
    return 0
  fi
  return 1
}

install_flatpak_chiaki() {
  ((CHECK)) && { note "would install chiaki-ng from Flathub ($FLATPAK_ID)"; return 0; }
  pac_install flatpak || return 1
  ((NET)) || { fail "no internet, so cannot install from Flathub"; return 1; }
  flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo 2>&1 | show
  flatpak install --user -y --noninteractive flathub "$FLATPAK_ID" 2>&1 | tail -n 5 | show
  flatpak info "$FLATPAK_ID" >/dev/null 2>&1 || { fail "Flathub install of chiaki-ng failed (above)"; return 1; }
  note "Flatpak apps show in the app menu after the next login"
}

elf_files() { local f; for f in "$@"; do [ -f "$f" ] && [ "$(head -c 4 "$f" 2>/dev/null | od -An -tx1 | tr -d ' \n')" = 7f454c46 ] && echo "$f"; done; }

check_native_chiaki() {                   # the binary must find all its libraries
  local bins missing
  # shellcheck disable=SC2046  # one path per word is what pacman prints
  mapfile -t bins < <(elf_files $(pacman -Qlq "$CHIAKI_PKG" 2>/dev/null | grep -E '/bin/chiaki(-ng|-cli)?$'))
  [ ${#bins[@]} -eq 0 ] && { warn "could not find chiaki's program files in $CHIAKI_PKG"; return 0; }
  missing=$(for b in "${bins[@]}"; do ldd "$b" 2>/dev/null | awk '/not found/{print $1}'; done | sort -u | tr '\n' ' ')
  [ -z "$missing" ] && return 0
  warn "chiaki-ng is missing libraries: $missing (usually a half-done system upgrade)"
  return 1
}

for old in chiaki chiaki-git; do
  if pkg_installed "$old" && ! ((FORCE_FLATPAK)); then
    warn "the old, unmaintained '$old' package is installed; chiaki-ng replaces it and they conflict (settings and pairing are kept: same folder)"
    if ! ((CHECK)) && ask "Remove $old?"; then pac_run -Rns "$old" || true; fi
  fi
done

if find_chiaki; then
  ok "installed: ${CHIAKI_PKG:-$FLATPAK_ID} ($CHIAKI_KIND)"
else
  if ((FORCE_FLATPAK)); then
    install_flatpak_chiaki
  elif aur_install chiaki-ng-bin; then
    :
  else
    warn "the AUR install did not work: falling back to the Flathub build"
    install_flatpak_chiaki
  fi
  ((CHECK)) || { find_chiaki && ok "installed: ${CHIAKI_PKG:-$FLATPAK_ID} ($CHIAKI_KIND)"; }
fi

if [ "$CHIAKI_KIND" = native ] && ! check_native_chiaki; then
  if ! ((CHECK)); then
    if system_upgrade && check_native_chiaki; then
      ok "libraries found after the upgrade"
    elif ask "Reinstall chiaki-ng from Flathub instead?"; then
      install_flatpak_chiaki && FORCE_FLATPAK=1 && find_chiaki
    fi
  fi
fi
if [ ${#CHIAKI_CLI[@]} -gt 0 ]; then
  if timeout 10 "${CHIAKI_CLI[@]}" --help >/dev/null 2>&1; then ok "chiaki-cli runs"; else warn "chiaki-cli does not start: $(timeout 10 "${CHIAKI_CLI[@]}" --help 2>&1 | head -n 2 | tr '\n' ' ')"; fi
fi
[ -z "$CHIAKI_KIND" ] && ! ((CHECK)) && fail "chiaki-ng is not installed: see the errors above"

# ---------------------------------------------------------------- 3. video decoding
step "Hardware video decoding (smooth 1080p/4K with little CPU)"
declare -A VENDORS=()
for d in /sys/class/drm/card[0-9]*/device; do
  [ -r "$d/vendor" ] && VENDORS[$(<"$d/vendor")]=1
done
DRIVERS=() GPU_NAMES=()
for v in "${!VENDORS[@]}"; do
  case "$v" in
    0x1002) GPU_NAMES+=("AMD"); DRIVERS+=(mesa) ;;
    0x8086) GPU_NAMES+=("Intel"); DRIVERS+=(intel-media-driver) ;;
    0x10de)
      if grep -q '^nvidia ' /proc/modules 2>/dev/null; then GPU_NAMES+=("NVIDIA"); DRIVERS+=(libva-nvidia-driver)
      else GPU_NAMES+=("NVIDIA (nouveau)"); DRIVERS+=(mesa); fi ;;
    *) GPU_NAMES+=("unknown GPU $v") ;;
  esac
done
if [ ${#GPU_NAMES[@]} -eq 0 ]; then
  warn "no GPU found under /sys/class/drm: chiaki-ng will decode on the CPU"
else
  note "GPU: ${GPU_NAMES[*]}"
  pac_install libva-utils "${DRIVERS[@]}" || warn "video drivers not installed: chiaki-ng falls back to CPU decoding"
fi

HEVC=0 H264=0
probe_vaapi() {                           # probe_vaapi [LIBVA_DRIVER_NAME]
  local node out
  for node in /dev/dri/renderD*; do
    [ -e "$node" ] || continue
    if [ -n "${1:-}" ]; then out=$(LIBVA_DRIVER_NAME="$1" timeout 15 vainfo --display drm --device "$node" 2>&1)
    else out=$(timeout 15 vainfo --display drm --device "$node" 2>&1); fi
    if grep -q 'VAEntrypointVLD' <<<"$out"; then
      grep -qE 'VAProfileH264(Main|High)\s*:\s*VAEntrypointVLD' <<<"$out" && H264=1
      grep -qE 'VAProfileHEVCMain\s*:\s*VAEntrypointVLD' <<<"$out" && HEVC=1
      VAAPI_DRIVER=$(grep -oE 'Driver version: .*' <<<"$out" | head -n 1)
      return 0
    fi
    VAAPI_ERR=$(grep -iE 'error|fail|denied' <<<"$out" | head -n 2 | tr '\n' ' ')
  done
  return 1
}
VAAPI_DRIVER="" VAAPI_ERR=""
if ! command -v vainfo >/dev/null; then
  ((CHECK)) && note "vainfo is not installed yet: decoding is checked on a real run" || warn "vainfo missing: cannot check decoding"
elif probe_vaapi; then
  ok "VA-API works (${VAAPI_DRIVER#Driver version: }): H.264 $( ((H264)) && echo yes || echo no), H.265/HEVC $( ((HEVC)) && echo yes || echo no)"
elif [ -n "${VENDORS[0x8086]:-}" ] && ! ((CHECK)) && pac_install libva-intel-driver && probe_vaapi i965; then
  ok "VA-API works with the older Intel driver (i965): H.264 $( ((H264)) && echo yes || echo no), HEVC $( ((HEVC)) && echo yes || echo no)"
  todo "Older Intel GPU: start chiaki-ng with  LIBVA_DRIVER_NAME=i965  (add it to ~/.config/environment.d/ps5.conf to make it stick)"
elif [[ $VAAPI_ERR == *denied* ]]; then
  warn "no permission for the GPU (${VAAPI_ERR}): run this from the desktop session, not over SSH"
else
  warn "VA-API does not work (${VAAPI_ERR:-no decoder}): chiaki-ng decodes on the CPU (more heat, more delay)"
fi
if ((HEVC)); then
  todo "In chiaki-ng's Settings > Video, set Codec to H265 (your GPU decodes it) and leave the hardware decoder on Auto."
elif ((H264)); then
  todo "In chiaki-ng's Settings > Video, keep Codec on H264: your GPU has no H.265 decoder."
fi

# ---------------------------------------------------------------- 4. controller
step "DualSense (USB and Bluetooth)"
RULES_WANT='# PS5 controllers for chiaki-ng: raw HID access gives haptics, adaptive triggers, the
# touchpad and the motion sensors. Written by my_linux_utils/arch/ps5-remote-play.sh.
# DualSense 054c:0ce6, DualSense Edge 054c:0df2; USB, then Bluetooth.
KERNEL=="hidraw*", ATTRS{idVendor}=="054c", ATTRS{idProduct}=="0ce6", MODE="0660", TAG+="uaccess"
KERNEL=="hidraw*", ATTRS{idVendor}=="054c", ATTRS{idProduct}=="0df2", MODE="0660", TAG+="uaccess"
KERNEL=="hidraw*", KERNELS=="*054C:0CE6*", MODE="0660", TAG+="uaccess"
KERNEL=="hidraw*", KERNELS=="*054C:0DF2*", MODE="0660", TAG+="uaccess"'
if [ -f "$RULES_FILE" ] && [ "$(cat "$RULES_FILE")" = "$RULES_WANT" ]; then
  ok "controller rule in place ($RULES_FILE)"
elif ((CHECK)); then
  note "would write $RULES_FILE"
elif ((SUDO)); then
  if printf '%s\n' "$RULES_WANT" | sudo tee "$RULES_FILE" >/dev/null; then
    ok "controller rule written ($RULES_FILE)"
    if sudo udevadm control --reload-rules 2>/dev/null && sudo udevadm trigger --subsystem-match=hidraw --action=change 2>/dev/null; then
      ok "udev reloaded"
    else
      warn "udev did not reload: the rule applies after a reboot"
    fi
  else
    fail "could not write $RULES_FILE"
  fi
else
  fail "no sudo, so the controller rule was not written"
fi

PAD=""
for u in /sys/class/hidraw/hidraw*/device/uevent; do
  [ -r "$u" ] || continue
  if grep -qiE '^HID_ID=.*054C.*0000(0CE6|0DF2)$' "$u"; then
    PAD="/dev/$(basename "$(dirname "$(dirname "$u")")")"
    name=$(grep -oP '^HID_NAME=\K.*' "$u")
    if [ -r "$PAD" ] && [ -w "$PAD" ]; then ok "controller connected and usable: ${name:-DualSense} ($PAD)"
    else warn "${name:-DualSense} is connected but $PAD is not yours yet: unplug it and plug it back in (or turn it off and on)"; fi
  fi
done

if [ -n "$(ls -A /sys/class/bluetooth 2>/dev/null)" ]; then
  pac_install bluez bluez-utils || true
  if command -v systemctl >/dev/null && ! systemctl is-active --quiet bluetooth 2>/dev/null; then
    if ((CHECK)); then note "would enable and start bluetooth.service"
    elif ((SUDO)) && { sudo systemctl enable --now bluetooth 2>&1 | show; systemctl is-active --quiet bluetooth; }; then ok "Bluetooth service started"
    else warn "Bluetooth service did not start (systemctl status bluetooth)"; fi
  else
    ok "Bluetooth is running"
  fi
  if command -v rfkill >/dev/null && rfkill list bluetooth 2>/dev/null | grep -q 'Soft blocked: yes'; then
    if ((CHECK)); then note "would unblock Bluetooth (rfkill)"; else rfkill unblock bluetooth 2>/dev/null || sudo rfkill unblock bluetooth; ok "Bluetooth unblocked"; fi
  fi
  rfkill list bluetooth 2>/dev/null | grep -q 'Hard blocked: yes' && warn "Bluetooth is switched off in hardware (a key or BIOS switch)"

  if command -v bluetoothctl >/dev/null && systemctl is-active --quiet bluetooth 2>/dev/null; then
    paired=$(bluetoothctl devices Paired 2>/dev/null | grep -iE 'DualSense|Wireless Controller' | head -n 1)
    if [ -n "$paired" ]; then
      ok "paired over Bluetooth: ${paired#Device }"
    elif [ -z "$PAD" ] && ! ((CHECK)) && ask "No DualSense paired. Pair one over Bluetooth now?"; then
      note "Hold the controller's Create button and PS button together until the light bar flashes fast, then press Enter."
      read -r _ </dev/tty 2>/dev/null || true
      bluetoothctl power on >/dev/null 2>&1
      mac=""
      for _ in 1 2 3; do
        mac=$(bluetoothctl --timeout 15 scan on 2>/dev/null | grep -iE 'DualSense|Wireless Controller' | grep -oE '([0-9A-F]{2}:){5}[0-9A-F]{2}' | head -n 1)
        [ -n "$mac" ] && break
        note "not seen yet: keep the light bar flashing"
      done
      if [ -n "$mac" ]; then
        bluetoothctl pair "$mac" 2>&1 | tail -n 2 | show
        bluetoothctl trust "$mac" >/dev/null 2>&1
        bluetoothctl connect "$mac" 2>&1 | tail -n 1 | show
      fi
      if [ -n "$mac" ] && bluetoothctl info "$mac" 2>/dev/null | grep -q 'Paired: yes'; then
        ok "DualSense paired ($mac)"
      else
        warn "pairing did not finish: try again, or pair it in KDE's Bluetooth settings, or just use a USB-C cable"
      fi
    elif [ -z "$PAD" ]; then
      todo "Controller: plug the DualSense in with USB-C, or pair it once (hold Create + PS until the light bar flashes, then pair in KDE's Bluetooth settings or run this script again)."
    fi
  fi
else
  note "no Bluetooth adapter: use the controller over USB-C"
fi

# ---------------------------------------------------------------- 5. sound
step "Sound"
if command -v pactl >/dev/null && srv=$(pactl info 2>/dev/null | grep -oP '^Server Name: \K.*'); then
  ok "sound server: $srv"
elif command -v wpctl >/dev/null && wpctl status >/dev/null 2>&1; then
  ok "PipeWire is running"
else
  warn "no sound server answered (PipeWire): the stream will have no sound. On KDE: pipewire, pipewire-pulse and wireplumber, then log out and in"
fi

# ---------------------------------------------------------------- 6. find the PS5
step "Finding the PS5 on the network"
# PS5 search packet (chiaki-ng lib/src/discovery.c): UDP to port 9302, answered with
# "HTTP/1.1 200 Ok" when on and "620 Server Standby" in rest mode. Prints one line per PS5:
# ip state host-name host-id system-version running-app
discover() {                              # discover broadcast|hosts|sweep TARGET...
  python3 - "$@" <<'PY'
import socket, sys, time, ipaddress
mode, targets = sys.argv[1], sys.argv[2:]
REQ = b"SRCH * HTTP/1.1\ndevice-discovery-protocol-version:00030010\n"
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
for port in list(range(9303, 9320)) + [0]:     # chiaki's own reply ports first: the firewall rule covers them
    try:
        s.bind(("", port)); break
    except OSError:
        continue
if mode == "sweep":
    hosts = []
    for net in targets:
        n = ipaddress.ip_network(net, strict=False)
        if n.num_addresses <= 1024:
            hosts += [str(h) for h in n.hosts()]
else:
    hosts = targets
found = {}
def listen(until):
    while True:
        left = until - time.time()
        if left <= 0:
            return
        s.settimeout(left)
        try:
            data, (ip, _) = s.recvfrom(4096)
        except socket.timeout:
            return
        except OSError:
            continue
        lines = data.decode("utf-8", "replace").replace("\r", "").split("\n")
        parts = lines[0].split(" ", 2)
        if len(parts) < 2 or not parts[0].startswith("HTTP/"):
            continue
        h = {}
        for l in lines[1:]:
            if ":" in l:
                k, v = l.split(":", 1); h[k.strip().lower()] = v.strip()
        if h.get("host-type", "PS5").upper() != "PS5":
            continue
        state = {"200": "on", "620": "standby"}.get(parts[1], "unknown")
        found[ip] = "\t".join([ip, state, h.get("host-name", "?"), h.get("host-id", "?"),
                               h.get("system-version", "?"), h.get("running-app-name", "-")])
for rnd in range(2 if mode == "sweep" else 3):
    for t in hosts:
        if t in found:
            continue
        try:
            s.sendto(REQ, (t, 9302))
        except OSError:
            pass
    listen(time.time() + (2.5 if mode == "sweep" else 1.2))
    if found and mode == "hosts":
        break
for line in found.values():
    print(line)
PY
}

LAN_NETS=() LAN_BCASTS=()
while read -r _ ifc _ cidr rest; do
  case "$ifc" in lo|tailscale*|docker*|br-*|veth*|virbr*|wg*|tun*|tap*|zt*) continue ;; esac
  LAN_NETS+=("$cidr")
  b=$(grep -oP 'brd \K[0-9.]+' <<<"$rest") && LAN_BCASTS+=("$b")
done < <(ip -4 -o addr show scope global 2>/dev/null)
[ ${#LAN_NETS[@]} -eq 0 ] && warn "this laptop has no LAN address: connect to the home network first"

FOUND=""
if ! command -v python3 >/dev/null; then
  pac_install python || true
fi
if ! command -v python3 >/dev/null; then
  ((CHECK)) && note "python is not installed yet: the PS5 search runs on a real run" || fail "python is needed to search for the PS5 (sudo pacman -S python)"
else
  if [ -n "$PS5_IP" ]; then
    FOUND=$(discover hosts "$PS5_IP")
    [ -z "$FOUND" ] && note "no answer from $PS5_IP (the address in the profile): searching the whole network"
  fi
  if [ -z "$FOUND" ] && [ ${#LAN_BCASTS[@]} -gt 0 ]; then
    FOUND=$(discover broadcast 255.255.255.255 "${LAN_BCASTS[@]}")
  fi
  if [ -z "$FOUND" ] && [ ${#LAN_NETS[@]} -gt 0 ]; then
    note "no answer to the broadcast (normal when a firewall is on): asking every address on ${LAN_NETS[*]}"
    FOUND=$(discover sweep "${LAN_NETS[@]}")
  fi
fi

PS5_STATE="" PS5_NAME=""
if [ -n "$FOUND" ]; then
  mapfile -t ROWS <<<"$FOUND"
  for r in "${ROWS[@]}"; do IFS=$'\t' read -r ip st nm id ver app <<<"$r"; note "found $nm at $ip: $st (system $ver${app:+, running $app})"; done
  pick="${ROWS[0]}"
  if [ ${#ROWS[@]} -gt 1 ]; then
    for r in "${ROWS[@]}"; do [ "${r%%$'\t'*}" = "$PS5_IP" ] && pick=$r; done
    [ "${pick%%$'\t'*}" = "$PS5_IP" ] || warn "more than one PS5 answered: using ${pick%%$'\t'*} (pick another with --ps5-ip)"
  fi
  IFS=$'\t' read -r ip PS5_STATE PS5_NAME _ _ _ <<<"$pick"
  if [ -n "$PS5_IP" ] && [ "$ip" != "$PS5_IP" ]; then
    warn "the PS5 moved from $PS5_IP to $ip: reserve $ip for it in the router's DHCP settings, and set PS5_IP=$ip in profiles/${PROFILE:-moosa}.env"
  fi
  PS5_IP=$ip
  ok "PS5: $PS5_NAME at $PS5_IP ($PS5_STATE)"
  [ "$PS5_STATE" = standby ] && note "it is in rest mode: chiaki-ng wakes it up once paired"
elif command -v python3 >/dev/null; then
  warn "no PS5 answered${PS5_IP:+ (tried $PS5_IP first; using that address for the rest)}"
  todo "PS5 not found. Check: (1) the PS5 is on or in rest mode, on the same network as this laptop (PS5 Settings > Network > Connection Status shows its IP address); (2) Settings > System > Power Saving > Features Available in Rest Mode: 'Stay Connected to the Internet' and 'Enable Turning On PS5 from Network' are on; (3) the router's Wi-Fi 'client/AP isolation' is off. Then run this again, or with --ps5-ip ADDRESS."
fi

# ---------------------------------------------------------------- 7. the path to the PS5
if [ -n "$PS5_IP" ]; then
  step "The connection to the PS5"
  route=$(ip -4 route get "$PS5_IP" 2>/dev/null | head -n 1)
  dev=$(grep -oP ' dev \K\S+' <<<"$route"); via=$(grep -oP ' via \K\S+' <<<"$route")
  case "$dev" in
    tailscale*|wg*|tun*|zt*)
      warn "traffic to the PS5 goes into $dev (a VPN), not the LAN"
      if [[ $dev == tailscale* ]] && ! ((CHECK)) && ask "Stop Tailscale from taking LAN routes (tailscale set --accept-routes=false)?"; then
        sudo tailscale set --accept-routes=false && ok "Tailscale no longer takes LAN routes"
        dev=$(ip -4 route get "$PS5_IP" 2>/dev/null | grep -oP ' dev \K\S+')
      else
        todo "Route to the PS5 goes through $dev: for Tailscale run  sudo tailscale set --accept-routes=false"
      fi ;;
    "") warn "no route to $PS5_IP" ;;
  esac
  if [ -n "$via" ]; then
    warn "the PS5 is on another subnet (reached through $via): chiaki-ng will not list it by itself; add it by address with the + button"
  elif [ -n "$dev" ]; then
    if [ -d "/sys/class/net/$dev/wireless" ]; then
      warn "this laptop reaches the PS5 over Wi-Fi ($dev): Ethernet is much smoother (no stutter, less delay)"
    else
      ok "same network, over $dev (wired)"
    fi
  fi
  if p=$(ping -c 5 -i 0.3 -W 1 -q "$PS5_IP" 2>/dev/null); then
    loss=$(grep -oP '[0-9.]+(?=% packet loss)' <<<"$p"); avg=$(grep -oP 'rtt [^=]+= [0-9.]+/\K[0-9.]+' <<<"$p")
    if [ "${loss%.*}" != 0 ]; then warn "${loss}% of pings to the PS5 were lost: expect stutter"
    elif [ -n "$avg" ] && awk -v a="$avg" 'BEGIN{exit !(a > 10)}'; then warn "ping to the PS5 is ${avg} ms (more than 10 ms on a LAN): Wi-Fi or a busy network"
    else ok "ping ${avg:-?} ms, no loss"; fi
  else
    [ "$PS5_STATE" = standby ] && note "no ping reply (normal in rest mode)" || warn "the PS5 does not answer ping"
  fi
  if [ "$PS5_STATE" = on ]; then
    if timeout 4 bash -c "exec 3<>/dev/tcp/$PS5_IP/9295" 2>/dev/null; then ok "Remote Play port 9295 is open"
    else warn "the PS5 is on but its Remote Play port (9295) is closed: turn on Settings > System > Remote Play > Enable Remote Play"; fi
  fi
fi

# ---------------------------------------------------------------- 8. firewall
step "Firewall"
fw_done=0
if command -v ufw >/dev/null; then
  if ! ((SUDO)); then
    note "UFW is installed; its rules need sudo to read"
  elif ! sudo ufw status 2>/dev/null | head -n 1 | grep -q 'Status: active'; then
    note "UFW is installed but off (run this again if you turn it on)"
  elif [ -z "$PS5_IP" ]; then
    warn "UFW is on and the PS5's address is unknown, so no rule was added: run this again once it is found"; fw_done=1
  else
    st=$(sudo ufw status numbered 2>/dev/null)
    # remove this script's rules for an old PS5 address, newest number first so the rest keep theirs
    mapfile -t stale < <(grep -F "# $UFW_COMMENT" <<<"$st" | grep -vF " $PS5_IP " | grep -oP '^\[\s*\K[0-9]+' | sort -rn)
    for n in "${stale[@]}"; do
      if ((CHECK)); then note "would delete old rule $n: $(grep -E "^\[ *$n\]" <<<"$st")"
      else sudo ufw --force delete "$n" >/dev/null && note "deleted the rule for the PS5's old address (rule $n)"; fi
    done
    if sudo ufw status 2>/dev/null | awk -v ip="$PS5_IP" '$1=="Anywhere" && $2=="ALLOW" && $3==ip {f=1} END {exit !f}'; then
      ok "UFW lets the PS5 ($PS5_IP) in"
    elif ((CHECK)); then
      note "would run: sudo ufw allow from $PS5_IP comment $UFW_COMMENT"
    elif out=$(sudo ufw allow from "$PS5_IP" comment "$UFW_COMMENT" 2>&1); then
      show <<<"$out"; ok "UFW now lets the PS5 ($PS5_IP) in (its search replies come back to ports 9303-9319)"
    else
      show <<<"$out"; fail "could not add the UFW rule: sudo ufw allow from $PS5_IP"
    fi
    fw_done=1
  fi
fi
if ! ((fw_done)) && command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
  if [ -z "$PS5_IP" ]; then warn "firewalld is on and the PS5's address is unknown: run this again once it is found"
  elif [ "$(firewall-cmd --get-zone-of-source="$PS5_IP" 2>/dev/null)" = trusted ]; then ok "firewalld trusts the PS5"
  elif ((CHECK)); then note "would add $PS5_IP to firewalld's trusted zone"
  elif sudo firewall-cmd --permanent --zone=trusted --add-source="$PS5_IP" >/dev/null && sudo firewall-cmd --reload >/dev/null; then ok "firewalld now trusts the PS5 ($PS5_IP)"
  else fail "could not add the PS5 to firewalld's trusted zone"; fi
  fw_done=1
fi
if ! ((fw_done)); then
  rules=$( ((SUDO)) && sudo nft list ruleset 2>/dev/null)
  if grep -qE 'hook input.*policy drop' <<<"$rules"; then
    warn "an nftables firewall drops incoming traffic: let the PS5 in yourself, e.g.  sudo nft insert rule inet filter input ip saddr ${PS5_IP:-PS5_ADDRESS} accept  (and save it in /etc/nftables.conf)"
  elif ((SUDO)) || ! command -v nft >/dev/null; then
    ok "no firewall is blocking the PS5"
  fi
fi

# check the way chiaki-ng itself looks: a broadcast, answered to ports 9303-9319
if [ -n "$PS5_IP" ] && [ ${#LAN_BCASTS[@]} -gt 0 ] && command -v python3 >/dev/null && ! ((CHECK)) && [ "$PS5_STATE" != "" ]; then
  if discover broadcast 255.255.255.255 "${LAN_BCASTS[@]}" | grep -qF "$PS5_IP"; then
    ok "chiaki-ng's search finds the PS5 by itself"
  else
    warn "the PS5 answers when asked directly but not to chiaki-ng's broadcast search: add it by address in chiaki-ng (the + button, $PS5_IP)"
  fi
fi

# ---------------------------------------------------------------- 9. pairing
step "Pairing (the keys that let this laptop control the PS5)"
if [ "$CHIAKI_KIND" = flatpak ]; then CONF_DIR="$HOME/.var/app/$FLATPAK_ID/config/Chiaki"
else CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/Chiaki"; fi
CONF="$CONF_DIR/Chiaki.conf" BACKUPS="$CONF_DIR/backups"

paired_names() {                          # the consoles a Chiaki.conf is paired with
  awk '/^\[/{s=($0=="[registered_hosts]")} s && /^[0-9]+\\server_nickname=/{sub(/^[^=]*=/,""); print}' "$1" 2>/dev/null
}
chiaki_running() { pgrep -x chiaki >/dev/null 2>&1 || pgrep -f "$FLATPAK_ID" >/dev/null 2>&1; }

if [ -n "$RESTORE" ]; then
  if ! grep -q '^\[registered_hosts\]' "$RESTORE" || [ -z "$(paired_names "$RESTORE")" ]; then
    fail "$RESTORE holds no pairing (no [registered_hosts] with a console in it), so it was not restored"
  elif ((CHECK)); then
    note "would restore the pairing with $(paired_names "$RESTORE" | paste -sd, -) from $RESTORE"
  else
    if chiaki_running; then
      ask "chiaki-ng is open and would overwrite the restored file when it closes. Close it now?" && { pkill -x chiaki; pkill -f "$FLATPAK_ID"; sleep 2; }
    fi
    if chiaki_running; then
      fail "chiaki-ng is still open: close it and run this again with --restore"
    else
      mkdir -p "$CONF_DIR"
      [ -f "$CONF" ] && cp -p "$CONF" "$CONF.before-restore-$(date +%Y%m%d-%H%M%S)"
      install -m 600 "$RESTORE" "$CONF" && ok "restored the pairing with $(paired_names "$CONF" | paste -sd, -) from $RESTORE"
    fi
  fi
fi

names=$(paired_names "$CONF")
if [ -n "$names" ]; then
  ok "paired with: $(paste -sd, - <<<"$names")"
  if [ -n "$PS5_NAME" ] && ! grep -qxF "$PS5_NAME" <<<"$names"; then
    warn "the PS5 on the network is '$PS5_NAME', not one this laptop is paired with: pair again (steps below) if it is a different console or was reset"
  fi
  # keep a dated copy; ~ is in the nightly Kopia snapshot, so the copy leaves the laptop too
  latest=$(ls -1t "$BACKUPS"/Chiaki.conf.* 2>/dev/null | head -n 1)
  if [ -n "$latest" ] && cmp -s "$CONF" "$latest"; then
    ok "pairing backed up: $latest"
  elif ((CHECK)); then
    note "would back the pairing up to $BACKUPS"
  else
    mkdir -p "$BACKUPS" && chmod 700 "$BACKUPS"
    dest="$BACKUPS/Chiaki.conf.$(date +%Y-%m-%d-%H%M%S)"
    install -m 600 "$CONF" "$dest" && ok "pairing backed up: $dest"
    ls -1t "$BACKUPS"/Chiaki.conf.* 2>/dev/null | tail -n +11 | xargs -r rm -f       # keep the last 10
  fi
  if systemctl --user is-enabled --quiet pc-backup.timer 2>/dev/null; then
    ok "the nightly pc-backup (Kopia snapshot of ~) includes it"
  else
    warn "pc-backup.timer is not on, so the pairing copy stays on this laptop only (post-install.sh turns it on)"
  fi
else
  older=$(ls -1t "$BACKUPS"/Chiaki.conf.* "$CONF_DIR"/Chiaki.conf.paired-* "$HOME"/Chiaki.conf* 2>/dev/null | head -n 1)
  [ -n "$older" ] && [ -n "$(paired_names "$older")" ] \
    && note "a saved pairing exists: $older (put it back with: $0 --restore $older)"
  warn "not paired with a PS5 yet"
  todo "Pair once (5 minutes):
1. PS5: Settings > System > Remote Play > turn on Enable Remote Play.
2. PS5: Settings > System > Power Saving > Features Available in Rest Mode > turn on 'Stay Connected to the Internet' and 'Enable Turning On PS5 from Network' (so chiaki-ng can wake it).
3. PS5: Settings > System > Remote Play > Link Device. An 8-digit PIN shows (valid for about 5 minutes).
4. chiaki-ng: click ${PS5_NAME:-the PS5}${PS5_IP:+ ($PS5_IP)} (or + and type the address), then Register. Console: PS5. PSN Account-ID: press 'PSN Login' (or 'Public Lookup' with your PSN name). Remote Play PIN: the 8 digits.
5. Run this script again: it backs the pairing up."
  if ((GUI)) && [ ${#CHIAKI_CMD[@]} -gt 0 ] && ! ((CHECK)) && ! chiaki_running && ask "Open chiaki-ng now to pair?"; then
    setsid -f "${CHIAKI_CMD[@]}" >/dev/null 2>&1 && ok "chiaki-ng opened"
  fi
fi

summary
[ ${#FAILS[@]} -eq 0 ] && finish 0 || finish 1
