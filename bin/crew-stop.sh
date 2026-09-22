#!/usr/bin/env bash
# crew-stop.sh - stop one crew member.
# Usage: crew-stop.sh <id> [--interrupt|--exit|--close]
#
#   --interrupt  (default) cancel the current turn; the agent keeps running
#   --exit       quit the agent; the pane, its cwd, and its files survive
#   --close      exit, then close the tab this foreman created
#
# Postconditions are reported, never invented: an exit that could not be
# confirmed says so.
set -eu

. "$(cd "$(dirname "$0")" && pwd)/foreman-lib.sh"

ID=${1:-}
MODE=${2:---interrupt}
foreman_require_task "$ID" >/dev/null
foreman_need_herdr

PANE=$(foreman_pane_of "$ID" 2>/dev/null || true)
if [ -z "$PANE" ]; then
  foreman_status_set "$ID" lost "stop requested but the recorded pane is gone"
  printf 'stopped %s: the recorded pane is already gone\n' "$ID"
  exit 0
fi

case "$MODE" in
--interrupt)
  foreman_herdr pane send-keys "$PANE" esc >/dev/null 2>&1 ||
    foreman_die "could not deliver the interrupt to $PANE"
  foreman_status_set "$ID" stopped "interrupted by the foreman"
  printf 'interrupted %s (agent still running)\n' "$ID"
  ;;
--exit | --close)
  foreman_herdr pane run "$PANE" "/quit" >/dev/null 2>&1 ||
    foreman_die "could not deliver the exit command to $PANE"
  confirmed=no
  for _ in $(seq 1 16); do
    if ! foreman_herdr agent get "$PANE" >/dev/null 2>&1; then
      confirmed=yes
      break
    fi
    sleep 0.5
  done
  if [ "$confirmed" = yes ]; then
    foreman_status_set "$ID" stopped "exited (confirmed)"
  else
    foreman_status_set "$ID" stopped "exit sent but the agent still reads as present"
  fi
  if [ "$MODE" = "--close" ]; then
    TAB=$(foreman_meta_get "$ID" tab)
    [ -z "$TAB" ] || foreman_herdr tab close "$TAB" >/dev/null 2>&1 || true
    printf 'exited %s (%s) and closed its tab\n' "$ID" "$confirmed"
  else
    printf 'exited %s (confirmed=%s); pane, cwd and files preserved\n' "$ID" "$confirmed"
  fi
  ;;
*)
  foreman_die "unknown stop mode: $MODE (use --interrupt, --exit, or --close)"
  ;;
esac
