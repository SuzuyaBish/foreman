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
  foreman_status_set "$ID" done "PR merged: $PR"
  printf '%s  done  PR merged: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$PR" >>"$DIR/events"
  printf 'merged\n'
  ;;
CLOSED)
  foreman_status_set "$ID" done "PR closed without merge: $PR"
  printf '%s  done  PR closed without merge: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$PR" >>"$DIR/events"
  printf 'closed\n'
  ;;
OPEN)
  if [ "$DRAFT" = true ]; then printf 'draft\n'; else printf 'open\n'; fi
  ;;
*)
  printf 'unknown (unrecognized state: %s)\n' "${STATE:-none}"
  ;;
esac
