#!/usr/bin/env bash
# crew-spawn.sh - create one crew member: a Herdr tab running a fresh pi.
# Usage: crew-spawn.sh <id> <cwd> [--model M] [--thinking L] <task text...>
set -eu

. "$(cd "$(dirname "$0")" && pwd)/foreman-lib.sh"

ID=${1:-}
CWD=${2:-}
if [ $# -ge 2 ]; then shift 2; else set --; fi

MODEL=
THINKING=
PARTS=()
while [ $# -gt 0 ]; do
  case "$1" in
  --model)
    MODEL=${2:-}
    shift 2 || shift 1
    ;;
  --thinking)
    THINKING=${2:-}
    shift 2 || shift 1
    ;;
  *)
    PARTS+=("$1")
    shift
    ;;
  esac
done
TASK="${PARTS[*]-}"

foreman_valid_id "$ID" || foreman_die "task id must be a kebab-case slug of 1-32 chars: '${ID}'"
[ -n "$CWD" ] || foreman_die "usage: crew-spawn.sh <id> <cwd> [--model M] [--thinking L] <task text...>"
[ -d "$CWD" ] || foreman_die "working directory does not exist: $CWD"
[ -n "$TASK" ] || foreman_die "task text is empty"
foreman_need_herdr

DIR=$(foreman_task_dir "$ID")
[ ! -e "$DIR" ] || foreman_die "crew task '$ID' already exists; archive it or pick another id"

mkdir -p "$DIR/inbox/handled"
printf '%s\n' "$TASK" >"$DIR/task.md"

# The crew member runs its own shell, so every command it is told to run must
# carry this session's FOREMAN_HOME explicitly rather than relying on the
# default derived from the script location.
QHOME="FOREMAN_HOME=$(printf '%q' "$FOREMAN_HOME")"
REPORT_CMD="$QHOME $(printf '%q' "$FOREMAN_ROOT/bin/crew-report.sh") $ID"
INBOX_CMD="$QHOME $(printf '%q' "$FOREMAN_ROOT/bin/crew-inbox.sh") $ID"

cat >"$DIR/brief.md" <<EOF
# Crew task: $ID

You are a crew member. You were assigned this by the captain's foreman. Nobody
is watching your terminal; the captain reads your report file.

## Task

$TASK

## Working directory

$CWD

## Report

Write your result to:

  $DIR/report.md

Keep it tight and decision-shaped: what you did or found, the evidence, what is
still unresolved. This file is the deliverable.

## When you finish

Run exactly this:

  $REPORT_CMD done "<one-line summary>"

If you cannot proceed without a decision, run:

  $REPORT_CMD blocked "<one-line reason>"

and stop. Do not guess at a decision that is not yours to make.

## New instructions

The foreman can send more instructions at any time. They land in:

  $DIR/inbox/

Check for them between significant steps:

  $INBOX_CMD

That prints every unacknowledged instruction and marks it handled. Run it before
starting anything long, and again after finishing a step.

## Rules

- Work only inside $CWD unless the task says otherwise.
- Do not ask the captain questions in chat. Use crew-report.sh.
- A done status with no report is a failed task.
EOF

foreman_status_set "$ID" queued "brief written"

WS=$(foreman_workspace)
OUT=$(foreman_herdr tab create --workspace "$WS" --cwd "$CWD" --label "crew-$ID" --no-focus 2>/dev/null) ||
  foreman_die "herdr tab create failed in workspace $WS (session $FOREMAN_SESSION)"
TAB=$(printf '%s' "$OUT" | jq -r '.result.tab.tab_id // empty' 2>/dev/null)
PANE=$(printf '%s' "$OUT" | jq -r '.result.root_pane.pane_id // empty' 2>/dev/null)
if [ -z "$TAB" ] || [ -z "$PANE" ]; then
  foreman_die "herdr returned no tab/pane id: $OUT"
fi

{
  printf 'pane=%s:%s\n' "$FOREMAN_SESSION" "$PANE"
  printf 'tab=%s\n' "$TAB"
  printf 'workspace=%s\n' "$WS"
  printf 'session=%s\n' "$FOREMAN_SESSION"
  printf 'cwd=%s\n' "$CWD"
  printf 'harness=pi\n'
  printf 'created=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} >"$DIR/meta"

POINTER="Read $DIR/brief.md and follow it exactly. It describes your whole task."
CMD="${FOREMAN_PI_BIN:-pi}"
[ -z "$MODEL" ] || CMD="$CMD --model $(printf '%q' "$MODEL")"
[ -z "$THINKING" ] || CMD="$CMD --thinking $(printf '%q' "$THINKING")"
CMD="$CMD $(printf '%q' "$POINTER")"

if ! foreman_herdr pane run "$PANE" "$CMD" >/dev/null 2>&1; then
  foreman_herdr tab close "$TAB" >/dev/null 2>&1 || true
  foreman_status_set "$ID" failed "launch command could not be sent"
  foreman_die "pane $PANE was created but the launch command could not be sent; the tab was closed"
fi

foreman_status_set "$ID" working "spawned"
printf 'spawned %s pane=%s:%s\n' "$ID" "$FOREMAN_SESSION" "$PANE"
