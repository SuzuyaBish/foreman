#!/usr/bin/env bash
# crew-stop.sh - stop one crew member.
# Usage: crew-stop.sh <id> [--interrupt|--exit|--close] [--reason <text>]
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
MODE=--interrupt
REASON=
if [ $# -ge 1 ]; then shift; fi
while [ $# -gt 0 ]; do
  case "$1" in
  --interrupt | --exit | --close)
    MODE=$1
    shift
    ;;
  --reason)
    [ $# -ge 2 ] || foreman_die "--reason requires a value"
    REASON=$2
    shift 2
    ;;
  *) foreman_die "unknown option: $1" ;;
  esac
done

DIR=$(foreman_require_task "$ID")
foreman_need_herdr

retire_busy() {
  GEN=$(cat "$DIR/busy-gen" 2>/dev/null || printf '')
  [ -z "$GEN" ] || "$FOREMAN_ROOT/bin/crew-busy-event.sh" retire "$FOREMAN_HOME" "$ID" --gen "$GEN" >/dev/null 2>&1 || true
}

# Stop what the crew left running. Its pane going away does not stop a detached
# dev server - that is orphaned to PID 1 and would hold its port for the rest of
# the session. Never on --interrupt: the agent is still running and may still be
# using what it started, so that is a pause, not a stop. Best effort: a teardown
# that cannot see the process table must not fail the stop.
sweep_processes() {
  "$FOREMAN_ROOT/bin/crew-processes.sh" kill "$ID" 2>/dev/null || true
}

PANE=$(foreman_pane_of "$ID" 2>/dev/null || true)
if [ -z "$PANE" ]; then
  foreman_event_append "$ID" stopped "" "${REASON:-stop requested but the recorded pane is gone}"
  foreman_status_sync "$ID"
  retire_busy
  sweep_processes
  # A pane can vanish while its tab survives (a crashed agent, a killed shell),
  # so a close still closes the home this foreman created for the task.
  if [ "$MODE" = --close ]; then
    case "$(foreman_close_home "$ID")" in
    workspace) printf 'stopped %s: its pane was already gone; its workspace was closed\n' "$ID" ;;
    tab) printf 'stopped %s: its pane was already gone; its tab was closed\n' "$ID" ;;
    *) printf 'stopped %s: the recorded pane is already gone\n' "$ID" ;;
    esac
    exit 0
  fi
  printf 'stopped %s: the recorded pane is already gone\n' "$ID"
  exit 0
fi

case "$MODE" in
--interrupt)
  foreman_herdr pane send-keys "$PANE" esc >/dev/null 2>&1 ||
    foreman_die "could not deliver the interrupt to $PANE"
  foreman_event_append "$ID" blocked "" "${REASON:-interrupted by the foreman; agent idle at its prompt}"
  foreman_status_sync "$ID"
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
    foreman_event_append "$ID" stopped "" "${REASON:-exited (confirmed)}"
  else
    foreman_event_append "$ID" stopped "" "${REASON:-exit sent but the agent still reads as present}"
  fi
  foreman_status_sync "$ID"
  retire_busy
  sweep_processes
  if [ "$MODE" = "--close" ]; then
    case "$(foreman_close_home "$ID")" in
    workspace) printf 'exited %s (%s) and closed its workspace\n' "$ID" "$confirmed" ;;
    tab) printf 'exited %s (%s) and closed its tab\n' "$ID" "$confirmed" ;;
    *) printf 'exited %s (%s); nothing was left to close\n' "$ID" "$confirmed" ;;
    esac
  else
    printf 'exited %s (confirmed=%s); pane, cwd and files preserved\n' "$ID" "$confirmed"
  fi
  ;;
*)
  foreman_die "unknown stop mode: $MODE (use --interrupt, --exit, or --close)"
  ;;
esac
