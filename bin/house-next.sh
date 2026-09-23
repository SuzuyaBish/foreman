#!/usr/bin/env bash
# house-next.sh - set, replace or clear an area's diagnosed next step.
#
# Usage: house-next.sh <slug> <text...>
#        house-next.sh <slug> --clear
#        house-next.sh --help
#
# `next` is the one line a prescription is built around, so setting it bumps
# `updated`: a stale next is the signal that the area has not been visited.
set -eu

. "$(cd "$(dirname "$0")" && pwd)/house-lib.sh"

usage() {
  cat <<'EOF'
usage: house-next.sh <slug> <text...>
       house-next.sh <slug> --clear

Set the diagnosed next step for <slug>, or clear it with --clear. One line:
what to do next, specific enough to paste into a fresh chat.
EOF
}

case "${1:-}" in
-h | --help)
  usage
  exit 0
  ;;
esac

SLUG=${1:-}
[ -n "$SLUG" ] || house_die "usage: house-next.sh <slug> <text...> | --clear"
shift

if [ "${1:-}" = --clear ]; then
  [ $# -eq 1 ] || house_die "--clear takes no text"
  path=$(house_require_area "$SLUG")
  house_edit "$path" --set next "" --set updated "$(house_today)"
  printf 'house: cleared next for %s\n' "$SLUG"
  exit 0
fi

TEXT=${*-}
[ -n "$TEXT" ] || house_die "usage: house-next.sh <slug> <text...> | --clear"
path=$(house_require_area "$SLUG")
house_edit "$path" --set next "$TEXT" --set updated "$(house_today)"
printf 'house: next for %s: %s\n' "$SLUG" "$TEXT"
