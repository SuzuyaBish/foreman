#!/usr/bin/env bash
# crew-report.sh - CREW SIDE. Record what this crew member just did.
#
# Usage: crew-report.sh <id> <verb> [note] [--key K] [--pr URL]
#
# Verbs:
#   working            a phase started; clears a bare blocked
#   progress <note>    a milestone worth recording (never changes the state)
#   needs-decision <question> --key K
#                      a decision the captain owes; stays open until answered
#   blocked <note>     an obstacle, no decision owed
#   review <note> --pr URL
#                      the change is ready; a pull request is waiting to merge
#   done <note>        finished (a report task, or work already merged)
#   failed <note>      cannot be completed
#
# The event log is the source of truth; `status` is folded from it, so a keyed
# decision cannot be buried by a later append.
set -eu

. "$(cd "$(dirname "$0")" && pwd)/foreman-lib.sh"

ID=${1:-}
VERB=${2:-}
if [ $# -ge 2 ]; then shift 2; else set --; fi

KEY=
PR=
PARTS=()
while [ $# -gt 0 ]; do
  case "$1" in
  --key | --pr)
    [ $# -ge 2 ] || foreman_die "$1 requires a value"
    if [ "$1" = --key ]; then KEY=$2; else PR=$2; fi
    shift 2
    ;;
  *)
    PARTS+=("$1")
    shift
    ;;
  esac
done
NOTE="${PARTS[*]-}"

case "$VERB" in
working | progress | blocked | needs-decision | review | done | failed | stopped) ;;
*) foreman_die "unknown verb: ${VERB:-<none>}" ;;
esac

DIR=$(foreman_require_task "$ID")
if [ -n "$KEY" ]; then
  case "$KEY" in *[!A-Za-z0-9._-]*) foreman_die "decision key must be a bare token: $KEY" ;; esac
fi
[ "$VERB" = needs-decision ] || [ -z "$KEY" ] || foreman_die "--key is only valid with needs-decision"
[ "$VERB" = needs-decision ] && [ -z "$KEY" ] && foreman_die "needs-decision requires --key"

if [ -n "$PR" ]; then
  [ "$VERB" = review ] || foreman_die "--pr is only valid with the review verb"
  NUMBER=
  case "$PR" in */pull/*) NUMBER=${PR##*/pull/} ;; esac
  case "$NUMBER" in '' | *[!0-9]*) NUMBER= ;; esac
  foreman_meta_set "$ID" pr "$PR"
  [ -z "$NUMBER" ] || foreman_meta_set "$ID" pr_number "$NUMBER"
  # The url is what makes a review actionable, so it belongs in the note the
  # board shows rather than only in meta.
  if [ -z "$NOTE" ]; then NOTE="PR $PR"; else NOTE="$NOTE — PR $PR"; fi
fi

foreman_event_append "$ID" "$VERB" "$KEY" "$NOTE"
foreman_status_sync "$ID"
printf 'reported %s %s\n' "$ID" "$VERB"
