#!/usr/bin/env bash
# crew-decide.sh - answer a crew member's open decision.
# Usage: crew-decide.sh <id> <key> <answer...>
#        crew-decide.sh --list
#
# The answer is appended as a `resolved` event for that exact key, which closes
# the decision in the fold at answer time, and is delivered to the crew member
# through the ordinary steering inbox. Closing and answering are one act so the
# board can never show a decision that has already been answered.
set -eu

. "$(cd "$(dirname "$0")" && pwd)/foreman-lib.sh"

if [ "${1:-}" = --list ]; then
  out=$(foreman_open_decisions)
  if [ -z "$out" ]; then
    printf 'no open decisions\n'
  else
    printf '%-18s %-14s %s\n' TASK KEY QUESTION
    printf '%s\n' "$out" | awk -F'\t' '{ printf "%-18s %-14s %s\n", $1, $2, $3 }'
  fi
  exit 0
fi

ID=${1:-}
KEY=${2:-}
if [ $# -ge 2 ]; then shift 2; else set --; fi
ANSWER="${*-}"

foreman_require_task "$ID" >/dev/null
[ -n "$KEY" ] || foreman_die "usage: crew-decide.sh <id> <key> <answer...>"
[ -n "$ANSWER" ] || foreman_die "the answer is empty"

open=$(foreman_open_decisions | awk -F'\t' -v id="$ID" -v k="$KEY" '$1 == id && $2 == k')
[ -n "$open" ] || foreman_die "no open decision '$KEY' on '$ID' (see crew-decide.sh --list)"

foreman_event_append "$ID" resolved "$KEY" "$ANSWER"
foreman_status_sync "$ID"
"$FOREMAN_ROOT/bin/crew-send.sh" "$ID" \
  "Decision [$KEY] answered: $ANSWER" >/dev/null
printf 'answered %s [%s]\n' "$ID" "$KEY"
