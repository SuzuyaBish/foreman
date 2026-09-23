#!/usr/bin/env bash
# house-note.sh - append a dated note to an area's chart.
#
# Usage: house-note.sh <slug> [--status S] [--next N] <text...>
#        house-note.sh --help
#
# The note is the chart's log: what the captain said changed. Appending bumps
# `updated`. `--status` and `--next` let one note also set a field, so the
# captain can say "X is now staged, next is Y" in one breath.
set -eu

. "$(cd "$(dirname "$0")" && pwd)/house-lib.sh"

usage() {
  cat <<'EOF'
usage: house-note.sh <slug> [--status S] [--next N] <text...>

Append a dated note to <slug>'s log and bump its updated date. --status and
--next also set those header fields in the same act. Notes and fields are one
line each: that is what keeps the chart readable and the rounds honest.
EOF
}

case "${1:-}" in
-h | --help)
  usage
  exit 0
  ;;
esac

SLUG=${1:-}
[ -n "$SLUG" ] || house_die "usage: house-note.sh <slug> [--status S] [--next N] <text...>"
shift

STATUS=
NEXT=
PARTS=()
while [ $# -gt 0 ]; do
  case "$1" in
  --status)
    [ $# -ge 2 ] || house_die "--status requires a value"
    STATUS=$2
    shift 2
    ;;
  --next)
    [ $# -ge 2 ] || house_die "--next requires a value"
    NEXT=$2
    shift 2
    ;;
  *)
    PARTS+=("$1")
    shift
    ;;
  esac
done

TEXT=${PARTS[*]-}
[ -n "$TEXT" ] || house_die "usage: house-note.sh <slug> [--status S] [--next N] <text...>"

path=$(house_require_area "$SLUG")
# One atomic rewrite: the note, the field sets and the bumped `updated` land
# together, or none of them do. A bad --status is refused by house_edit before
# the chart is touched, so there is no note left behind and no temp file.
args=(--log "$(house_today)" "$TEXT" --set updated "$(house_today)")
[ -z "$STATUS" ] || args+=(--set status "$STATUS")
[ -z "$NEXT" ] || args+=(--set next "$NEXT")
house_edit "$path" "${args[@]}"
printf 'house: noted %s\n' "$SLUG"
