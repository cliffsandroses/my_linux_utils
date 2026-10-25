#!/bin/bash
# Install: sudo bash install.sh   (undo: sudo bash install.sh --undo)
set -euo pipefail
H=$(dirname "$(readlink -f "$0")")
for f in polkit-1 sudo; do
  P=/etc/pam.d/$f; [ -f "$P" ] || continue
  if [ "${1:-}" = --undo ]; then sed -i '/phone-approve/d; s/pam_fprintd.so timeout=8/pam_fprintd.so/' "$P"; continue; fi
  grep -q phone-approve "$P" && continue
  cp "$P" "$P.before-phone-approve"
  sed -i 's/^auth\s\+sufficient\s\+pam_fprintd.so.*/auth       sufficient   pam_fprintd.so timeout=8\nauth       sufficient   pam_exec.so quiet \/usr\/local\/bin\/phone-approve/' "$P"
  grep -q phone-approve "$P" || sed -i '0,/^auth/s//auth       sufficient   pam_exec.so quiet \/usr\/local\/bin\/phone-approve\nauth/' "$P"
done
[ "${1:-}" = --undo ] && { rm -f /usr/local/bin/phone-approve; echo undone; exit; }
install -m 755 "$H/phone-approve" /usr/local/bin/phone-approve
install -m 755 "$H/phone-approve-ok" /usr/local/bin/phone-approve-ok
grep -n "fprintd\|phone-approve" /etc/pam.d/polkit-1 /etc/pam.d/sudo
echo "installed"
