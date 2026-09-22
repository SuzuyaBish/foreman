#!/usr/bin/env bash
# crew-archive.sh - retire a finished task out of the active set.
# Usage: crew-archive.sh <id>
# The task directory (task, brief, report, inbox) is moved intact; nothing is
# deleted and nothing is discarded.
set -eu

. "$(cd "$(dirname "$0")" && pwd)/foreman-lib.sh"

ID=${1:-}
DIR=$(foreman_require_task "$ID")

state=$(foreman_status_get "$ID" state)
case "$state" in
working | queued)
  foreman_die "crew '$ID' is still $state; stop it first (crew-stop.sh $ID --close) or leave it alone"
  ;;
esac

DEST="$FOREMAN_HOME/archive"
mkdir -p "$DEST"
[ ! -e "$DEST/$ID" ] || foreman_die "$DEST/$ID already exists; nothing was moved"
mv "$DIR" "$DEST/$ID"
printf 'archived %s -> %s/%s\n' "$ID" "$DEST" "$ID"
