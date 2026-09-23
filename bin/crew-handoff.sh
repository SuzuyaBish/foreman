#!/usr/bin/env bash
# crew-handoff.sh - the dated note one session leaves for the next.
#
# Usage: crew-handoff.sh write [text...]   (reads stdin when no text is given)
#        crew-handoff.sh read              print it once, if it is the previous session's
#        crew-handoff.sh show              print it whatever its age
#        crew-handoff.sh standing [--seed]  print the installation's standing doc
#
# The standing doc is the installation's own and is gitignored, so the first
# session in a clone seeds it from the tracked HANDOFF.example.md. `--seed` does
# only the seeding, quietly, which is what a session start wants; the bare verb
# prints the doc (seeding first if it is missing).
#
# The note is not wiped. What bounds it is the date it carries: `read` prints it
# only when it was written after the last note a session ingested, and stamps
# .handoff-seen with that note's own timestamp. So the note from the session that
# just ended is ingested once at the next session start, a note left over from
# several sessions ago is skipped rather than replayed forever, and `show` always
# reads it back on demand.
set -eu

. "$(cd "$(dirname "$0")" && pwd)/foreman-lib.sh"

NOTE="$FOREMAN_HOME/handoff.md"
SEEN_FILE="$FOREMAN_HOME/.handoff-seen"
# Seams, so a test never seeds or reads a real installation's standing doc.
STANDING=${FOREMAN_STANDING:-"$FOREMAN_ROOT/HANDOFF.md"}
STANDING_EXAMPLE=${FOREMAN_STANDING_EXAMPLE:-"$FOREMAN_ROOT/HANDOFF.example.md"}

# seed_standing: give the installation its own copy of the tracked example.
seed_standing() {
  [ -f "$STANDING" ] && return 0
  [ -f "$STANDING_EXAMPLE" ] || return 0
  cp "$STANDING_EXAMPLE" "$STANDING" 2>/dev/null || return 0
}

# The machine-readable date lives in a comment, so the note still reads as prose.
handoff_at() {
  [ -f "$NOTE" ] || return 0
  sed -n 's/^<!-- handoff at=\([^ ]*\).*/\1/p' "$NOTE" | head -1
}

ACTION=${1:-read}
case "$ACTION" in
write)
  shift || true
  if [ "$#" -gt 0 ]; then BODY="${*}"; else BODY=$(cat); fi
  [ -n "$BODY" ] || foreman_die "the handoff is empty; say what the next session needs"

  AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  mkdir -p "$FOREMAN_HOME"
  {
    printf '<!-- handoff at=%s session=%s -->\n' "$AT" "$FOREMAN_SESSION"
    printf '# Session handoff — %s\n\n' "${AT%%T*}"
    printf '%s\n' "$BODY"
  } >"$NOTE"
  printf '%s\n' "$NOTE"
  ;;
standing)
  seed_standing
  case "${2:-}" in --seed) exit 0 ;; esac
  [ -f "$STANDING" ] || exit 0
  cat "$STANDING"
  ;;
read)
  AT=$(handoff_at)
  [ -n "$AT" ] || exit 0
  AT_EPOCH=$(foreman_epoch_of "$AT")
  [ -n "$AT_EPOCH" ] || exit 0

  SEEN_EPOCH=0
  if [ -f "$SEEN_FILE" ]; then
    SEEN_EPOCH=$(cat "$SEEN_FILE" 2>/dev/null || printf '0')
    case "$SEEN_EPOCH" in '' | *[!0-9]*) SEEN_EPOCH=0 ;; esac
  fi
  # Not newer than what was already ingested: it is either this note again or a
  # note a session has already read. Stay quiet.
  [ "$AT_EPOCH" -gt "$SEEN_EPOCH" ] || exit 0

  cat "$NOTE"
  printf '%s\n' "$AT_EPOCH" >"$SEEN_FILE"
  ;;
show)
  if [ ! -f "$NOTE" ]; then
    printf 'no handoff note\n'
    exit 0
  fi
  cat "$NOTE"
  ;;
*)
  foreman_die "usage: crew-handoff.sh write [text...] | read | show | standing [--seed]"
  ;;
esac
