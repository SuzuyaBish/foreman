#!/usr/bin/env bash
# crew-read.sh - print a crew member's report, bounded.
# Usage: crew-read.sh <id> [max-lines]
# This is the only place crew output is meant to enter the foreman's context,
# and it is deliberately explicit and truncated.
set -eu

. "$(cd "$(dirname "$0")" && pwd)/foreman-lib.sh"

ID=${1:-}
MAX=${FOREMAN_REPORT_LINES:-120}
case "$MAX" in '' | *[!0-9]*) MAX=120 ;; esac

DIR=$(foreman_require_task "$ID")
[ -f "$DIR/report.md" ] || foreman_die "crew '$ID' has not written a report yet"

total=$(wc -l <"$DIR/report.md" | tr -d ' ')
head -n "$MAX" "$DIR/report.md"
if [ "$total" -gt "$MAX" ]; then
  printf '\n…[%s of %s lines shown; full report: %s]\n' "$MAX" "$total" "$DIR/report.md"
fi
