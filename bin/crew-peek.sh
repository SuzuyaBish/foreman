#!/usr/bin/env bash
# crew-peek.sh - bounded tail of one crew member's pane.
# Usage: crew-peek.sh <id> [lines]
# This is inspection, not supervision. It is bounded and never auto-read.
set -eu

. "$(cd "$(dirname "$0")" && pwd)/foreman-lib.sh"

ID=${1:-}
N=${2:-40}
case "$N" in '' | *[!0-9]*) N=40 ;; esac
[ "$N" -ge 1 ] || N=40
[ "$N" -le 200 ] || N=200

foreman_need_herdr
PANE=$(foreman_pane_of "$ID") ||
  foreman_die "the recorded pane for '$ID' is not reachable in session '$FOREMAN_SESSION' (it may have exited or been closed)"

# Herdr returns nothing for a --lines value below the viewport height, so a
# generous read is requested and trimmed locally.
foreman_herdr pane read "$PANE" --source recent-unwrapped --lines 200 2>/dev/null | tail -n "$N"
