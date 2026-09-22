#!/usr/bin/env bash
# crew-pr-check.sh - has this crew member's pull request landed?
# Usage: crew-pr-check.sh <id>
#
# Prints one verdict: merged | closed | open | draft | unknown | no-pr.
# merged/closed settle the task to `done`; everything else leaves it in review,
# because an open pull request still owns the worktree.
set -eu

. "$(cd "$(dirname "$0")" && pwd)/foreman-lib.sh"

ID=${1:-}
DIR=$(foreman_require_task "$ID")
PR=$(foreman_meta_get "$ID" pr)
if [ -z "$PR" ]; then
  printf 'no-pr\n'
  exit 0
fi

PROJ=$(foreman_meta_get "$ID" project)
[ -n "$PROJ" ] && [ -d "$PROJ" ] || PROJ=$(foreman_meta_get "$ID" cwd)
[ -n "$PROJ" ] && [ -d "$PROJ" ] || PROJ=$PWD

command -v gh >/dev/null 2>&1 || {
  printf 'unknown (gh is not on PATH)\n'
  exit 0
}

JSON=$(cd "$PROJ" && gh pr view "$PR" --json state,isDraft,mergedAt,url 2>/dev/null) || {
  printf 'unknown (gh could not read %s)\n' "$PR"
  exit 0
}

STATE=$(printf '%s' "$JSON" | jq -r '.state // ""')
DRAFT=$(printf '%s' "$JSON" | jq -r '.isDraft // false')

case "$STATE" in
MERGED)
  foreman_event_append "$ID" done "" "PR merged: $PR"
  foreman_status_sync "$ID"
  printf 'merged\n'
  ;;
CLOSED)
  foreman_event_append "$ID" done "" "PR closed without merge: $PR"
  foreman_status_sync "$ID"
  printf 'closed\n'
  ;;
OPEN)
  if [ "$DRAFT" = true ]; then printf 'draft\n'; else printf 'open\n'; fi
  ;;
*)
  printf 'unknown (unrecognized state: %s)\n' "${STATE:-none}"
  ;;
esac
