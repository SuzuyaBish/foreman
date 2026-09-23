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

# --- merge-conflict recovery -----------------------------------------------
#
# A refusal that is neither transient nor a success is not automatically a
# conflict: a failing required check and a permission error are real refusals
# too, and neither is the crew's to fix by rebasing. The forge, not gh's
# wording, is the authority on which it is. `mergeable: CONFLICTING` (or a
# `mergeStateStatus` of `DIRTY`) is the conflict signature; anything else falls
# through to the plain blocker. Prints the `gh pr view` JSON, or nothing when
# the forge cannot be asked -- itself a fall-through, never a hard failure.
merge_conflict_json() { # <project> <pr>
  local proj=$1 pr=$2
  command -v jq >/dev/null 2>&1 || return 1
  (cd "$proj" && gh pr view "$pr" --json mergeable,mergeStateStatus,files,url 2>/dev/null) || return 1
}

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

# A refusal GitHub calls temporary -- the base branch moved -- is retried here,
# not handed back to the crew. Nothing about the crew's work changed and its
# branch is untouched, so a wake would be a whole crew turn for a merge GitHub
# invites us to simply try again. Only the transient signature is retried; a
# real failure falls straight through to the blocker below.
ATTEMPTS=${FOREMAN_MERGE_ATTEMPTS:-3}
case "$ATTEMPTS" in '' | *[!0-9]*) ATTEMPTS=3 ;; esac
[ "$ATTEMPTS" -ge 1 ] || ATTEMPTS=1
RETRY_SLEEP=${FOREMAN_MERGE_RETRY_SLEEP:-2}
case "$RETRY_SLEEP" in '' | *[!0-9]*) RETRY_SLEEP=2 ;; esac

ATTEMPT=0
MERGED=0
ERR=
REASON=
while [ "$ATTEMPT" -lt "$ATTEMPTS" ]; do
  ATTEMPT=$((ATTEMPT + 1))
  if ERR=$(cd "$PROJ" && gh "${ARGS[@]}" 2>&1); then
    MERGED=1
    break
  fi
  # Carry gh's own reason, not just "failed": otherwise the captain has to re-run
  # gh by hand to learn whether it was a conflict, a check, or a permission. The
  # events log is tab-separated, so collapse it to one bounded line first. The
  # transient test reads the full output, so a long prefix cannot hide it.
  REASON=$(printf '%s' "$ERR" | tr '\n\t' '  ' | tr -s ' ' | sed -e 's/^ *//' -e 's/ *$//' | cut -c1-160)
  [ -n "$REASON" ] || REASON="gh exited nonzero"
  if [ "$ATTEMPT" -lt "$ATTEMPTS" ] && foreman_merge_refusal_transient "$ERR"; then
    foreman_event_append "$ID" progress "" \
      "merge refused transiently for $PR (attempt $ATTEMPT/$ATTEMPTS), retrying: $REASON"
    [ "$RETRY_SLEEP" -eq 0 ] || sleep "$RETRY_SLEEP"
    continue
  fi
  break
done

if [ "$MERGED" = 1 ]; then
  # A merged crew is finished: its record and branch survive for the captain,
  # but the idle pane must not sit in the fleet reading as work still running.
  # Close the home the foreman created for it -- workspace, else tab -- the same
  # best-effort close crew-archive performs. Like archive this reads the
  # workspace and tab from the task's own meta, so it runs before the record is
  # touched; a Herdr that cannot be reached is reported, never fatal, because
  # the merge already happened and stands on its own.
  close_note="nothing was left to close"
  if [ -n "$(foreman_own_workspace "$ID")" ] || [ -n "$(foreman_meta_get "$ID" tab)" ] || [ -n "$(foreman_meta_get "$ID" pane)" ]; then
    if command -v herdr >/dev/null 2>&1; then
      case "$(foreman_close_home "$ID")" in
      workspace) close_note="closed its workspace" ;;
      tab) close_note="closed its tab" ;;
      *) close_note="nothing was left to close" ;;
      esac
    else
      close_note="could not close its terminal (herdr is not on PATH)"
    fi
  fi
  foreman_event_append "$ID" done "" "merged by the foreman: $PR"
  foreman_status_sync "$ID"
  printf 'merged %s (%s); %s\n' "$PR" "$METHOD" "$close_note"
  exit 0
fi

if foreman_merge_refusal_transient "$ERR"; then
  # GitHub kept asking, but the refusal is still only "try again": the pull
  # request is open and mergeable and nothing is wrong with the crew's branch.
  # So the task stays in review and the captain, whenever they like, re-runs the
  # merge -- no crew wake, no re-report. The record keeps a line saying so.
  foreman_event_append "$ID" progress "" \
    "merge refused transiently for $PR after $ATTEMPTS attempts, still in review: $REASON"
  foreman_status_sync "$ID"
  foreman_die "gh could not merge $PR yet (transient refusal; task stays in review): $REASON"
fi

# A real refusal. If the forge says the pull request is in conflict, hand the
# resolution to the crew that owns it. Recovery is automatic; merging is not:
# this only asks, blocks, and stops. The crew's re-report is what makes a retry
# possible again, and the captain's go-ahead is still what authorises it.
CONFLICT_JSON=$(merge_conflict_json "$PROJ" "$PR" 2>/dev/null || true)
if [ -n "$CONFLICT_JSON" ] &&
  printf '%s' "$CONFLICT_JSON" |
  jq -e '(.mergeable == "CONFLICTING") or (.mergeStateStatus == "DIRTY")' >/dev/null 2>&1; then
  CONFLICT_URL=$(printf '%s' "$CONFLICT_JSON" | jq -r '.url // empty' 2>/dev/null || true)
  [ -n "$CONFLICT_URL" ] || CONFLICT_URL=$PR
  CONFLICT_FILES=$(printf '%s' "$CONFLICT_JSON" | jq -r '.files[]?.path // empty' 2>/dev/null || true)
  FILES_ONELINE=$(printf '%s' "$CONFLICT_FILES" | awk 'NF { if (n++) printf ", "; printf "%s", $0 }')
  [ -n "$FILES_ONELINE" ] || FILES_ONELINE="the forge listed none"

  # Self-contained and short: a competent peer who cannot see this conversation
  # gets the pull request, the files, and exactly what to do.
  MSG="Merge conflict on $CONFLICT_URL: GitHub refused the merge because this branch conflicts with the base branch."
  MSG="$MSG"$'\n'"Conflicting files:"
  if [ -n "$CONFLICT_FILES" ]; then
    while IFS= read -r f; do
      if [ -n "$f" ]; then MSG="$MSG"$'\n'"  - $f"; fi
    done <<<"$CONFLICT_FILES"
  else
    MSG="$MSG"$'\n'"  (the forge listed none)"
  fi
  MSG="$MSG"$'\n'"Rebase onto the current origin/main, resolve the conflicts so both changes survive, run the full suite (bin/crew-test.sh), push the branch, and report review again."

  # The durable inbox record is the delivery; the doorbell is best-effort. If
  # the crew cannot be reached at all we still block, with the files and gh's
  # reason, so the captain can act -- never fail to block, never lose the reason.
  if "$FOREMAN_ROOT/bin/crew-send.sh" "$ID" "$MSG" >/dev/null 2>&1; then
    foreman_event_append "$ID" progress "" \
      "conflict recovery: asked crew $ID to rebase $CONFLICT_URL; conflicting files: $FILES_ONELINE"
    foreman_event_append "$ID" blocked "" \
      "merge conflict on $CONFLICT_URL; recovery in flight: crew $ID asked to rebase (files: $FILES_ONELINE); gh: $REASON"
    foreman_status_sync "$ID"
    foreman_die "merge conflict on $CONFLICT_URL; crew $ID asked to rebase (files: $FILES_ONELINE); task blocked"
  fi
  foreman_event_append "$ID" blocked "" \
    "merge conflict on $CONFLICT_URL; could not ask crew $ID to rebase (files: $FILES_ONELINE); gh: $REASON"
  foreman_status_sync "$ID"
  foreman_die "merge conflict on $CONFLICT_URL; could not ask crew $ID to rebase (files: $FILES_ONELINE); gh: $REASON"
fi

foreman_event_append "$ID" blocked "" "merge command failed for $PR: $REASON"
foreman_status_sync "$ID"
foreman_die "gh could not merge $PR: $REASON"
