#!/usr/bin/env bash
# crew-report.sh - CREW SIDE. Update this task's status.
# Usage: crew-report.sh <id> <working|blocked|done|failed|stopped> [note]
set -eu

. "$(cd "$(dirname "$0")" && pwd)/foreman-lib.sh"

ID=${1:-}
STATE=${2:-}
if [ $# -ge 2 ]; then shift 2; else set --; fi
NOTE="${*-}"

[ -n "$STATE" ] || foreman_die "usage: crew-report.sh <id> <state> [note]"
DIR=$(foreman_require_task "$ID")
foreman_status_set "$ID" "$STATE" "$NOTE"
printf '%s  %s  %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$STATE" "$NOTE" >>"$DIR/events"
printf 'reported %s %s\n' "$ID" "$STATE"
