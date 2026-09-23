#!/usr/bin/env bash
# crew-lavish.sh - open a Lavish review board.
# Usage: crew-lavish.sh open <artifact.html>
#        crew-lavish.sh end <artifact.html>
#        crew-lavish.sh export <artifact.html> [--out <path>]
#
# Only the open/end/export halves live here. `lavish-axi poll` must be a tracked
# background child of the session that asked for it — never a shell command — so
# the poll is owned by the session extension in .pi/extensions/foreman.ts and by the
# generated per-crew extension, not by this script.
set -eu

. "$(cd "$(dirname "$0")" && pwd)/foreman-lib.sh"

ACTION=${1:-}
FILE=${2:-}
[ -n "$ACTION" ] || foreman_die "usage: crew-lavish.sh open|end|export <artifact.html>"

command -v lavish-axi >/dev/null 2>&1 ||
  foreman_die "lavish-axi is not on PATH; use a plain report instead of a review board"

case "$ACTION" in
open)
  [ -n "$FILE" ] || foreman_die "usage: crew-lavish.sh open <artifact.html>"
  [ -f "$FILE" ] || foreman_die "no such artifact: $FILE"
  exec lavish-axi "$FILE"
  ;;
end)
  [ -n "$FILE" ] || foreman_die "usage: crew-lavish.sh end <artifact.html>"
  exec lavish-axi end "$FILE"
  ;;
export)
  shift 2 || true
  [ -n "$FILE" ] || foreman_die "usage: crew-lavish.sh export <artifact.html> [--out <path>]"
  exec lavish-axi export "$FILE" "$@"
  ;;
*)
  foreman_die "unknown lavish action: $ACTION (open|end|export)"
  ;;
esac
