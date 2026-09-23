#!/usr/bin/env bash
# crew-archive.sh - retire a finished task out of the active set.
# Usage: crew-archive.sh <id> [--worktree] [--force] [--keep-home]
#
# The task directory (task, brief, report, inbox) is moved intact; nothing is
# deleted. --worktree also removes the crew's git worktree, and refuses while it
# has uncommitted changes unless --force is given. Archiving also closes the
# terminal this foreman created for the crew (its workspace, else its tab), so a
# retired task cannot sit in the fleet as a pane that reads as a working crew;
# --keep-home leaves that terminal open. Closing is best effort: an unreachable
# Herdr is reported but never blocks the move.
set -eu

. "$(cd "$(dirname "$0")" && pwd)/foreman-lib.sh"

ID=${1:-}
DIR=$(foreman_task_dir "$ID")
[ -d "$DIR" ] || foreman_die "no such crew task: $ID"
shift || true

DROP_WT=0
FORCE=0
KEEP_HOME=0
for a in "$@"; do
  case "$a" in
  --worktree) DROP_WT=1 ;;
  --force) FORCE=1 ;;
  --keep-home) KEEP_HOME=1 ;;
  *) foreman_die "unknown option: $a" ;;
  esac
done

state=$(foreman_status_get "$ID" state)
PR=$(foreman_meta_get "$ID" pr)
case "$state" in
working | queued)
  foreman_die "crew '$ID' is still $state; stop it first (crew-stop.sh $ID --close) or leave it alone"
  ;;
review)
  if [ "$FORCE" != 1 ]; then
    foreman_die "crew '$ID' is waiting on its pull request${PR:+ ($PR)}; merge or close it, or pass --force to archive anyway (the branch and commits survive)"
  fi
  ;;
esac

if [ "$DROP_WT" = 1 ]; then
  WT=$(foreman_meta_get "$ID" worktree)
  if [ -n "$WT" ]; then
    if [ "$FORCE" = 1 ]; then
      "$FOREMAN_ROOT/bin/crew-worktree.sh" remove "$ID" --force
    else
      "$FOREMAN_ROOT/bin/crew-worktree.sh" remove "$ID"
    fi
  fi
fi

# Reconcile the todo list while the crew's own record is still readable, so no
# row is left pointing at a task that has been moved away.
"$FOREMAN_ROOT/bin/crew-todo.sh" sync >/dev/null 2>&1 || true

DEST="$FOREMAN_HOME/archive"
mkdir -p "$DEST"
[ ! -e "$DEST/$ID" ] || foreman_die "$DEST/$ID already exists; nothing was moved"
GEN=$(cat "$DIR/busy-gen" 2>/dev/null || printf '')
[ -z "$GEN" ] || "$FOREMAN_ROOT/bin/crew-busy-event.sh" retire "$FOREMAN_HOME" "$ID" --gen "$GEN" >/dev/null 2>&1 || true

# Retire the place the crew lived, before the record moves out from under
# foreman_close_home, which reads the task's workspace and tab from its meta. A
# pane left behind is indistinguishable from a crew that is still working, so
# retiring the task retires its terminal. Best effort throughout: a close that
# cannot happen (Herdr down or absent, endpoint already gone) is reported as a
# note and the record is moved regardless, because the archive is the part that
# must survive.
close_note="nothing was left to close"
if [ -n "$(foreman_own_workspace "$ID")" ] || [ -n "$(foreman_meta_get "$ID" tab)" ] || [ -n "$(foreman_meta_get "$ID" pane)" ]; then
  if [ "$KEEP_HOME" = 1 ]; then
    close_note="kept its terminal"
  elif command -v herdr >/dev/null 2>&1; then
    case "$(foreman_close_home "$ID")" in
    workspace) close_note="closed its workspace" ;;
    tab) close_note="closed its tab" ;;
    *) close_note="nothing was left to close" ;;
    esac
  else
    close_note="could not close its terminal (herdr is not on PATH)"
  fi
fi

mv "$DIR" "$DEST/$ID"
printf 'archived %s -> %s/%s; %s\n' "$ID" "$DEST" "$ID" "$close_note"
