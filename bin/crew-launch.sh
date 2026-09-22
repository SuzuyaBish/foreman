#!/usr/bin/env bash
# crew-launch.sh - put a crew member in a pane. The one launch owner.
#
# Usage: crew-launch.sh <id> <cwd> [--model M] [--thinking T] [--note <text>]
#
# Assumes the task directory and brief.md already exist. Creates the tab, records
# the endpoint, launches pi with this task's extension, and marks the task
# working. Used for a fresh spawn and for a recovery relaunch, so both produce
# byte-identical launch behaviour.
set -eu

. "$(cd "$(dirname "$0")" && pwd)/foreman-lib.sh"

ID=${1:-}
CWD=${2:-}
if [ $# -ge 2 ]; then shift 2; else set --; fi

MODEL=
THINKING=
NOTE=
while [ $# -gt 0 ]; do
  case "$1" in
  --model | --thinking | --note)
    [ $# -ge 2 ] || foreman_die "$1 requires a value"
    case "$1" in
    --model) MODEL=$2 ;;
    --thinking) THINKING=$2 ;;
    --note) NOTE=$2 ;;
    esac
    shift 2
    ;;
  *) foreman_die "unknown option: $1" ;;
  esac
done

DIR=$(foreman_require_task "$ID")
[ -d "$CWD" ] || foreman_die "working directory does not exist: $CWD"
[ -f "$DIR/brief.md" ] || foreman_die "no brief for '$ID'; the task was never prepared"
foreman_need_herdr

CWD=$(cd "$CWD" && pwd -P)
EXT="$DIR/pi-ext.ts"
[ -f "$EXT" ] || foreman_die "no generated extension for '$ID'; re-run the spawn"

APPROVE=$(foreman_config_bool crewApprove 1)

WS=$(foreman_workspace)
OUT=$(foreman_herdr tab create --workspace "$WS" --cwd "$CWD" --label "crew-$ID" --no-focus 2>/dev/null) ||
  foreman_die "herdr tab create failed in workspace $WS (session $FOREMAN_SESSION)"
TAB=$(printf '%s' "$OUT" | jq -r '.result.tab.tab_id // empty' 2>/dev/null)
PANE=$(printf '%s' "$OUT" | jq -r '.result.root_pane.pane_id // empty' 2>/dev/null)
if [ -z "$TAB" ] || [ -z "$PANE" ]; then
  foreman_die "herdr returned no tab/pane id: $OUT"
fi

foreman_meta_set "$ID" pane "$FOREMAN_SESSION:$PANE"
foreman_meta_set "$ID" tab "$TAB"
foreman_meta_set "$ID" workspace "$WS"
foreman_meta_set "$ID" session "$FOREMAN_SESSION"
foreman_meta_set "$ID" cwd "$CWD"

# Pre-register folder trust so neither the crew nor a human who attaches later
# is prompted. Best effort: never fail a launch over it.
if [ "$(foreman_config_bool trustPaths 1)" = 1 ] && [ -d "$HOME/.pi" ]; then
  "$FOREMAN_ROOT/bin/crew-trust.sh" "$CWD" >/dev/null 2>&1 || true
fi

POINTER="Read $DIR/brief.md and follow it exactly. It describes your whole task."
CMD="${FOREMAN_PI_BIN:-pi}"
[ "$APPROVE" != 1 ] || CMD="$CMD --approve"
CMD="$CMD -e $(printf '%q' "$EXT")"
[ -z "$MODEL" ] || CMD="$CMD --model $(printf '%q' "$MODEL")"
[ -z "$THINKING" ] || CMD="$CMD --thinking $(printf '%q' "$THINKING")"
CMD="$CMD $(printf '%q' "$POINTER")"

if ! foreman_herdr pane run "$PANE" "$CMD" >/dev/null 2>&1; then
  foreman_herdr tab close "$TAB" >/dev/null 2>&1 || true
  foreman_event_append "$ID" failed "" "launch command could not be sent to the pane"
  foreman_status_sync "$ID"
  foreman_die "pane $PANE was created but the launch command could not be sent; the tab was closed"
fi

foreman_event_append "$ID" working "" "${NOTE:-launched}"
foreman_status_sync "$ID"
printf 'launched %s pane=%s:%s\n' "$ID" "$FOREMAN_SESSION" "$PANE"
