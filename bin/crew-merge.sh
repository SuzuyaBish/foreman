#!/usr/bin/env bash
# crew-merge.sh - merge a crew member's pull request, on the captain's say-so.
# Usage: crew-merge.sh <id> [--method squash|merge|rebase] [--delete-branch]
#
# Only ever run when the captain has authorised the merge. It merges the exact
# pull request the crew member recorded, then settles the task to done. The
# branch is kept by default: the worktree may still be checked out on it, and
# the captain may want it. --delete-branch removes the worktree first.
set -eu

. "$(cd "$(dirname "$0")" && pwd)/foreman-lib.sh"

ID=${1:-}
METHOD=squash
DELETE_BRANCH=0
if [ $# -ge 1 ]; then shift; fi
while [ $# -gt 0 ]; do
  case "$1" in
  --method)
    [ $# -ge 2 ] || foreman_die "--method requires a value"
    METHOD=$2
    shift 2
    ;;
  --delete-branch)
    DELETE_BRANCH=1
    shift
    ;;
  *) foreman_die "unknown option: $1" ;;
  esac
done

case "$METHOD" in squash | merge | rebase) ;; *) foreman_die "unknown merge method: $METHOD" ;; esac

foreman_require_task "$ID" >/dev/null
STATE=$(foreman_status_get "$ID" state)
[ "$STATE" = review ] ||
  foreman_die "crew '$ID' is '$STATE', not review; there is no pull request to merge"

PR=$(foreman_meta_get "$ID" pr)
[ -n "$PR" ] || foreman_die "crew '$ID' has no recorded pull request"

command -v gh >/dev/null 2>&1 || foreman_die "gh is not on PATH"

PROJ=$(foreman_meta_get "$ID" project)
[ -n "$PROJ" ] && [ -d "$PROJ" ] || PROJ=$(foreman_meta_get "$ID" cwd)
[ -n "$PROJ" ] && [ -d "$PROJ" ] || PROJ=$PWD

if [ "$DELETE_BRANCH" = 1 ]; then
  WT=$(foreman_meta_get "$ID" worktree)
  if [ -n "$WT" ]; then
    "$FOREMAN_ROOT/bin/crew-worktree.sh" remove "$ID" ||
      foreman_die "could not remove the worktree before deleting its branch"
  fi
fi

ARGS=(pr merge "$PR" --"$METHOD")
[ "$DELETE_BRANCH" = 0 ] || ARGS+=(--delete-branch)

if ! ERR=$(cd "$PROJ" && gh "${ARGS[@]}" 2>&1); then
  # Carry gh's own reason, not just "failed": otherwise the captain has to re-run
  # gh by hand to learn whether it was a conflict, a check, or a permission. The
  # events log is tab-separated, so collapse it to one bounded line first.
  REASON=$(printf '%s' "$ERR" | tr '\n\t' '  ' | tr -s ' ' | sed -e 's/^ *//' -e 's/ *$//' | cut -c1-160)
  [ -n "$REASON" ] || REASON="gh exited nonzero"
  foreman_event_append "$ID" blocked "" "merge command failed for $PR: $REASON"
  foreman_status_sync "$ID"
  foreman_die "gh could not merge $PR: $REASON"
fi

foreman_event_append "$ID" done "" "merged by the foreman: $PR"
foreman_status_sync "$ID"
printf 'merged %s (%s)\n' "$PR" "$METHOD"
