# Shared by every homelab/*.sh: loads the profile and provides check mode.
#
#   --check   change nothing; report each setting as "ok" or "DIFF" against the profile.
#
# The profile is profiles/$PROFILE.env (default: moosa). When a script is piped to another
# machine by vm.sh / pve.sh, the profile arrives first and PROFILE_LOADED is set.

if [ -z "${PROFILE_LOADED:-}" ]; then
  _here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  # shellcheck source=../profiles/moosa.env
  . "$_here/profiles/${PROFILE:-moosa}.env" || { echo "No profile profiles/${PROFILE:-moosa}.env" >&2; exit 1; }
fi

CHECK=0; ARGS=()
for a in "$@"; do [ "$a" = --check ] && CHECK=1 || ARGS+=("$a"); done
set -- "${ARGS[@]+"${ARGS[@]}"}"
DIFFS=0

log()  { printf '\n== %s\n' "$*"; }
ok()   { printf '  ok    %s\n' "$*"; }
diff_() { printf '  DIFF  %s\n' "$*"; DIFFS=$((DIFFS + 1)); }
note() { printf '        %s\n' "$*"; }

# run CMD...: do it, or in check mode say what would be done.
run() { if [ "$CHECK" = 1 ]; then printf '  would %s\n' "$*"; else "$@"; fi; }

# want DESCRIPTION TEST-CMD... ; then the caller fixes it when the test fails and CHECK=0.
# Returns 0 when the setting is already right.
want() {
  local what=$1; shift
  if "$@" >/dev/null 2>&1; then ok "$what"; return 0; fi
  diff_ "$what"; return 1
}

# ensure_line FILE LINE [sudo]: the exact line is in FILE, appended if missing.
ensure_line() {
  local f=$1 line=$2 s=${3:-}
  # A trailing "# comment" on the existing line doesn't count as a difference.
  if $s sed 's/[[:space:]]*#.*$//' "$f" 2>/dev/null | grep -qxF -- "$line"; then ok "$f has: ${line:0:90}"; return; fi
  diff_ "$f is missing: ${line:0:90}"
  [ "$CHECK" = 1 ] || printf '%s\n' "$line" | $s tee -a "$f" >/dev/null
}

finish() {
  if [ "$CHECK" = 1 ]; then
    echo; [ "$DIFFS" -eq 0 ] && echo "Check: everything matches the profile." \
      || echo "Check: $DIFFS difference(s) from the profile. Run without --check to apply."
  fi
}

user_systemctl() { XDG_RUNTIME_DIR="/run/user/$(id -u)" systemctl --user "$@"; }
