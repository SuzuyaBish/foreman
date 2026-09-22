#!/usr/bin/env bash
# crew-archive.sh - retire a finished task out of the active set.
# Usage: crew-archive.sh <id> [--worktree] [--force]
#
# The task directory (task, brief, report, inbox) is moved intact; nothing is
# deleted. --worktree also removes the crew's git worktree, and refuses while it
# has uncommitted changes unless --force is given.
set -eu

. "$(cd "$(dirname "$0")" && pwd)/foreman-lib.sh"

ID=${1:-}
DIR=$(foreman_task_dir "$ID")
[ -d "$DIR" ] || foreman_die "no such crew task: $ID"
shift || true

DROP_WT=0
FORCE=0
for a in "$@"; do
  case "$a" in
  --worktree) DROP_WT=1 ;;
  --force) FORCE=1 ;;
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
mv "$DIR" "$DEST/$ID"
printf 'archived %s -> %s/%s\n' "$ID" "$DEST" "$ID"
