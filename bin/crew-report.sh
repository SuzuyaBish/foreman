#!/usr/bin/env bash
# crew-report.sh - CREW SIDE. Update this task's status.
# Usage: crew-report.sh <id> <working|blocked|review|done|failed|stopped> [note] [--pr <url>]
#
# `review` with --pr is the normal ending for change work: the pull request is
# recorded and the task waits for the captain's merge instead of being closed.
set -eu

. "$(cd "$(dirname "$0")" && pwd)/foreman-lib.sh"

ID=${1:-}
STATE=${2:-}
if [ $# -ge 2 ]; then shift 2; else set --; fi

PR=
PARTS=()
while [ $# -gt 0 ]; do
  case "$1" in
  --pr)
    [ $# -ge 2 ] || foreman_die "--pr requires a url"
    PR=$2
    shift 2
    ;;
  *)
    PARTS+=("$1")
    shift
    ;;
  esac
done
NOTE="${PARTS[*]-}"

[ -n "$STATE" ] || foreman_die "usage: crew-report.sh <id> <state> [note] [--pr <url>]"
DIR=$(foreman_require_task "$ID")

if [ -n "$PR" ]; then
  [ "$STATE" = review ] ||
    foreman_die "--pr is only valid with the review state (got '$STATE')"
  exec "$FOREMAN_ROOT/bin/crew-pr.sh" "$ID" "$PR" "$NOTE"
fi

foreman_status_set "$ID" "$STATE" "$NOTE"
printf '%s  %s  %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$STATE" "$NOTE" >>"$DIR/events"
printf 'reported %s %s\n' "$ID" "$STATE"
