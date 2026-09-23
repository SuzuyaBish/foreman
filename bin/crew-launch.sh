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

# --- where the crew appears -------------------------------------------------
#
# One workspace per crew member. That is what makes a crew read as a subordinate
# of the foreman in Herdr's sidebar: Herdr has no parent/child relationship for
# panes or agents, so the only levers are the workspace's label (a child glyph)
# and its position (directly after the foreman's own workspace, past any sibling
# already there). The relationship itself lives in our task records.
#
# A relaunch adopts the workspace the task already owns instead of creating a
# second one, so recovery does not multiply workspaces.
PARENT_WS=$(foreman_workspace)
WS=$(foreman_own_workspace "$ID")
NEW_WS=0
OUT=

if [ -n "$WS" ] && foreman_herdr workspace get "$WS" >/dev/null 2>&1; then
  OUT=$(foreman_herdr tab create --workspace "$WS" --cwd "$CWD" --label "crew-$ID" --no-focus 2>/dev/null) ||
    foreman_die "herdr could not add a tab to the crew's workspace $WS (session $FOREMAN_SESSION)"
  TAB=$(printf '%s' "$OUT" | jq -r '.result.tab.tab_id // empty' 2>/dev/null)
  PANE=$(printf '%s' "$OUT" | jq -r '.result.root_pane.pane_id // empty' 2>/dev/null)
else
  OUT=$(foreman_herdr workspace create --cwd "$CWD" --label "└ $ID" --no-focus 2>/dev/null) || OUT=
  WS=$(printf '%s' "$OUT" | jq -r '.result.workspace.workspace_id // empty' 2>/dev/null)
  TAB=$(printf '%s' "$OUT" | jq -r '.result.tab.tab_id // empty' 2>/dev/null)
  PANE=$(printf '%s' "$OUT" | jq -r '.result.root_pane.pane_id // empty' 2>/dev/null)
  if [ -n "$WS" ] && [ -n "$TAB" ]; then
    NEW_WS=1
    # The seeded tab is called "1"; inside its own workspace it should still say
    # whose it is.
    foreman_herdr tab rename "$TAB" "crew-$ID" >/dev/null 2>&1 || true
  else
    # A Herdr that cannot give the crew its own workspace still gets the crew:
    # fall back to the flat layout rather than losing the launch.
    WS=$PARENT_WS
    OUT=$(foreman_herdr tab create --workspace "$WS" --cwd "$CWD" --label "crew-$ID" --no-focus 2>/dev/null) ||
      foreman_die "herdr could not give the crew a workspace or a tab (session $FOREMAN_SESSION)"
    TAB=$(printf '%s' "$OUT" | jq -r '.result.tab.tab_id // empty' 2>/dev/null)
    PANE=$(printf '%s' "$OUT" | jq -r '.result.root_pane.pane_id // empty' 2>/dev/null)
  fi
fi
if [ -z "$TAB" ] || [ -z "$PANE" ]; then
  foreman_die "herdr returned no tab/pane id: $OUT"
fi

foreman_meta_set "$ID" pane "$FOREMAN_SESSION:$PANE"
foreman_meta_set "$ID" tab "$TAB"
foreman_meta_set "$ID" workspace "$WS"
foreman_meta_set "$ID" parent_workspace "$PARENT_WS"
foreman_meta_set "$ID" session "$FOREMAN_SESSION"
foreman_meta_set "$ID" cwd "$CWD"

# Learn what was already running in the crew's directory before the crew
# existed. An isolated crew owns its worktree, but a --no-isolate crew works
# inside the captain's own checkout: without this, the captain's own dev server
# would read as the crew's stray and be stopped when the crew finished. First
# launch only - a relaunch keeps the original list, because the strays from the
# run that just died are exactly what the next teardown has to find.
"$FOREMAN_ROOT/bin/crew-processes.sh" snapshot "$ID" >/dev/null 2>&1 || true

# Placing a crew for a project puts that project in focus, so the todo board
# follows the work rather than the captain having to say so twice. Best effort:
# a board that cannot be told is not a reason to fail a launch.
PROJ=$(foreman_meta_get "$ID" project)
if [ -n "$PROJ" ]; then
  "$FOREMAN_ROOT/bin/crew-todo.sh" focus "$(basename "$PROJ")" >/dev/null 2>&1 || true
fi

# Presentation only, and best effort: if the position cannot be worked out, the
# mover is absent, or Herdr refuses the move, the crew stays where Herdr put it
# and the launch is still good.
if [ "$NEW_WS" = 1 ] && [ -n "$PARENT_WS" ] && [ "$PARENT_WS" != "$WS" ]; then
  if IDX=$(foreman_workspace_order_index "$PARENT_WS" "$WS"); then
    foreman_herdr_move "$WS" "$IDX" ||
      printf 'warning: %s stays where Herdr put it; the workspace could not be moved after %s\n' "$WS" "$PARENT_WS" >&2
  else
    printf 'warning: %s stays where Herdr put it; the workspace could not be placed after %s\n' "$WS" "$PARENT_WS" >&2
  fi
fi

# Pre-register folder trust so neither the crew nor a human who attaches later
# is prompted. Best effort: never fail a launch over it.
if [ "$(foreman_config_bool trustPaths 1)" = 1 ] && [ -d "$HOME/.pi" ]; then
  "$FOREMAN_ROOT/bin/crew-trust.sh" "$CWD" >/dev/null 2>&1 || true
fi

POINTER="Read $DIR/brief.md and follow it exactly. It describes your whole task."
# A crew session is not a foreman session, and the two must never load together.
# When the project being worked on is a checkout of this harness (self-hosting),
# its worktree ships .pi/extensions/foreman.ts: pi would discover it next to the
# crew's own extension, both register lavish_*, and the project one is refused -
# taking the crew's tools down with the error. So discovery is off (`-ne`) and the
# crew's extension is named explicitly, which still loads. FOREMAN_CREW marks the
# session for anything the crew starts later (see the guard in the extension).
CMD="env FOREMAN_CREW=$(printf '%q' "$ID") ${FOREMAN_PI_BIN:-pi} -ne"
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
