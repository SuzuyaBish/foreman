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
case "$state" in
working | queued)
  foreman_die "crew '$ID' is still $state; stop it first (crew-stop.sh $ID --close) or leave it alone"
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

DEST="$FOREMAN_HOME/archive"
mkdir -p "$DEST"
[ ! -e "$DEST/$ID" ] || foreman_die "$DEST/$ID already exists; nothing was moved"
mv "$DIR" "$DEST/$ID"
printf 'archived %s -> %s/%s\n' "$ID" "$DEST" "$ID"
