#!/usr/bin/env bash
# Fingerprint on Mak (Goodix 27c6:639c, libfprint goodixmoc driver).
# Lock screen: KDE's kde-fingerprint PAM profile already uses pam_fprintd, so enrolling is enough.
# sudo and KDE password pop-ups (polkit): one "sufficient" line each, so the password still
# works if the finger isn't read. The first login after boot stays password-only: it unlocks
# KWallet, which a fingerprint can't do.
#     bash fingerprint.sh                       # enrolls right index finger
#     FINGER=left-index-finger bash fingerprint.sh
set -euo pipefail
FINGER="${FINGER:-right-index-finger}"
LINE='auth       sufficient   pam_fprintd.so'
sudo -v

echo "== Installing fprintd"
sudo pacman -S --needed --noconfirm fprintd usbutils >/dev/null
lsusb | grep -i 27c6 || { echo "Fingerprint reader not found on USB"; exit 1; }

echo "== Enrolling $FINGER: touch the sensor (top-right of the keyboard) each time it asks"
sudo fprintd-delete moosa >/dev/null 2>&1 || true
sudo fprintd-enroll -f "$FINGER" moosa
echo "== Check: touch the sensor once more"
sudo fprintd-verify -f "$FINGER" moosa

echo "== sudo"
grep -q pam_fprintd /etc/pam.d/sudo || {
  sudo cp -a /etc/pam.d/sudo /etc/pam.d/sudo.bak-before-fingerprint
  sudo sed -i "0,/^auth/s//$LINE\n&/" /etc/pam.d/sudo
}
echo "== KDE password pop-ups (polkit)"
[ -f /etc/pam.d/polkit-1 ] || sudo cp /usr/lib/pam.d/polkit-1 /etc/pam.d/polkit-1
grep -q pam_fprintd /etc/pam.d/polkit-1 || {
  sudo cp -a /etc/pam.d/polkit-1 /etc/pam.d/polkit-1.bak-before-fingerprint
  sudo sed -i "0,/^auth/s//$LINE\n&/" /etc/pam.d/polkit-1
}
grep -n "auth" /etc/pam.d/sudo /etc/pam.d/polkit-1 | head -6
echo "Done. Lock the screen (Meta+L) and touch the sensor to test."
