#!/usr/bin/env bash
# house-send.sh - deliver an area's prescription to an existing session.
#
# Usage: house-send.sh <slug> [--yes]
#        house-send.sh --help
#
# Sending is opt-in and one area at a time. Without --yes it is a dry run: it
# prints exactly what would be sent and to where, and changes nothing. With
# --yes it hands the latest prescription to the crew task named by the area's
# `bind`, reusing crew-send.sh's durable inbox record plus pane doorbell. An
# area with no usable bind is refused with a pointer at --copy.
set -eu

. "$(cd "$(dirname "$0")" && pwd)/house-lib.sh"

usage() {
  cat <<'EOF'
usage: house-send.sh <slug> [--yes]

Deliver <slug>'s latest prescription to the session named by its `bind` field
(FOREMAN_HOME/house/outbox/<slug>-<ts>.md is the record). Dry run by default;
--yes actually sends. With no usable bind, prescribe with --copy and paste it.
EOF
}

case "${1:-}" in
-h | --help)
  usage
  exit 0
  ;;
esac

SLUG=${1:-}
[ -n "$SLUG" ] || house_die "usage: house-send.sh <slug> [--yes]"
shift

YES=0
while [ $# -gt 0 ]; do
  case "$1" in
  --yes)
    YES=1
    shift
    ;;
  *) house_die "unknown send option: $1 (try --help)" ;;
  esac
done

path=$(house_require_area "$SLUG")
BIND=$(house_field "$path" bind)
if [ -z "$BIND" ]; then
  # A ready prescription is more useful than telling the captain to run
  # prescribe --copy again: point at the file that already exists.
  ready=$(house_latest_outbox "$SLUG")
  if [ -n "$ready" ]; then
    house_die "area $SLUG has no bind; a prescription is ready at $ready — paste it into the session, or set a bind"
  fi
  house_die "area $SLUG has no bind; run: house-prescribe.sh $SLUG --copy  (then paste it into the session)"
fi

# A bind names a crew task, optionally with a `crew:` prefix. Anything else is
# a place House cannot deliver to, so it refuses rather than guessing.
TARGET=${BIND#crew:}
TARGET=${TARGET#task:}
case "$TARGET" in
'' | *[!abcdefghijklmnopqrstuvwxyz0123456789-]*)
  house_die "bind '$BIND' is not a crew task; run: house-prescribe.sh $SLUG --copy  (then paste it into the session)"
  ;;
esac
if [ ! -d "$FOREMAN_TASKS/$TARGET" ]; then
  house_die "bind '$BIND' names no crew task; run: house-prescribe.sh $SLUG --copy  (then paste it into the session)"
fi

outfile=$(house_latest_outbox "$SLUG")
if [ -z "$outfile" ]; then
  house_die "no prescription for $SLUG yet; run: house-prescribe.sh $SLUG"
fi

if [ "$path" -nt "$outfile" ]; then
  printf 'house: chart for %s changed since the prescription; re-run prescribe if the next step moved\n' "$SLUG" >&2
fi

PROMPT=$(cat "$outfile")

if [ "$YES" -eq 0 ]; then
  printf 'house-send: dry run (nothing sent)\n'
  printf 'area: %s\n' "$SLUG"
  printf 'to: crew %s (bind %s)\n' "$TARGET" "$BIND"
  printf 'via: %s\n' "$FOREMAN_ROOT/bin/crew-send.sh"
  printf -- '--- begin prescription ---\n'
  printf '%s\n' "$PROMPT"
  printf -- '--- end prescription ---\n'
  printf 'run with --yes to send\n'
  exit 0
fi

printf 'house: sending %s to crew %s\n' "$SLUG" "$TARGET" >&2
SEND_OUT=$("$FOREMAN_ROOT/bin/crew-send.sh" "$TARGET" "$PROMPT")
# crew-send records the durable inbox file first and rings the pane second. An
# unringable pane (no endpoint, or a dead agent) is not a failure, but it is not
# a send either: say what actually happened so the captain does not wait on a
# doorbell that was never rung.
case "$SEND_OUT" in
*pane\ doorbell:\ yes*)
  printf 'house: sent %s to crew %s\n' "$SLUG" "$TARGET"
  ;;
*)
  printf 'house: recorded for crew %s; doorbell not rung — it will be picked up when the crew is reachable\n' "$TARGET"
  ;;
esac
