#!/usr/bin/env bash
# crew-pr.sh - record the pull request a crew member opened.
# Usage: crew-pr.sh <id> <url|number> [note]
#
# Moves the task to `review`: the work is finished but not delivered, so the
# pane, the worktree and the branch all stay in place until it is merged. The
# foreman re-checks merge state with crew-pr-check.sh.
set -eu

. "$(cd "$(dirname "$0")" && pwd)/foreman-lib.sh"

ID=${1:-}
REF=${2:-}
if [ $# -ge 2 ]; then shift 2; else set --; fi
NOTE="${*-}"

DIR=$(foreman_require_task "$ID")
[ -n "$REF" ] || foreman_die "usage: crew-pr.sh <id> <url|number> [note]"

case "$REF" in
http://* | https://*) URL=$REF ;;
*[!0-9]*) foreman_die "pull request reference must be a URL or a number: $REF" ;;
*) URL=$REF ;;
esac

NUMBER=
case "$URL" in
*/pull/*) NUMBER=${URL##*/pull/} ;;
esac
case "$NUMBER" in '' | *[!0-9]*) NUMBER= ;; esac

foreman_meta_set "$ID" pr "$URL"
[ -z "$NUMBER" ] || foreman_meta_set "$ID" pr_number "$NUMBER"

[ -n "$NOTE" ] || NOTE="PR open: $URL"
foreman_event_append "$ID" review "" "$NOTE"
foreman_status_sync "$ID"
printf 'recorded PR %s for %s (awaiting merge)\n' "$URL" "$ID"
