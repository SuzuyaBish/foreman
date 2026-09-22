#!/usr/bin/env bash
# crew-busy.sh - what is a crew member's process actually doing?
# Usage: crew-busy.sh <id>
#
# Prints "<state> · <source>" where state is:
#   busy     mid-turn (an adapter-verified lifecycle event says so)
#   idle     settled and waiting for input
#   dead     the recorded pane is gone, so no agent can be running in it
#   unknown  no trustworthy record, or one from a stale incarnation
#
# `idle` is deliberately NOT a claim that the work is done, and `unknown` is
# never treated as idle.
set -eu

. "$(cd "$(dirname "$0")" && pwd)/foreman-lib.sh"

ID=${1:-}
foreman_require_task "$ID" >/dev/null

if ! foreman_pane_of "$ID" >/dev/null 2>&1; then
  printf 'dead · endpoint-gone\n'
  exit 0
fi

read -r STATE SOURCE < <(foreman_busy_read "$ID")
if [ "$STATE" = unknown ] && [ "$SOURCE" = missing ]; then
  # No record: fall back to Herdr's own registration, which is weaker (it can
  # outlive the process) but better than nothing.
  PANE=$(foreman_pane_of "$ID" 2>/dev/null || true)
  if [ -n "$PANE" ] && ! foreman_herdr agent get "$PANE" >/dev/null 2>&1; then
    printf 'unknown · no-agent-registration\n'
    exit 0
  fi
  printf 'unknown · no-record\n'
  exit 0
fi

printf '%s · %s\n' "$STATE" "$SOURCE"
