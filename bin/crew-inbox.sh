#!/usr/bin/env bash
# crew-inbox.sh - CREW SIDE. Print unacknowledged instructions, then acknowledge.
# Usage: crew-inbox.sh <id> [--peek]
#
# Reading is acknowledging: the record is moved into handled/ so it is delivered
# at most once per crew member. --peek prints without acknowledging.
set -eu

. "$(cd "$(dirname "$0")" && pwd)/foreman-lib.sh"

ID=${1:-}
PEEK=${2:-}
DIR=$(foreman_require_task "$ID")

shopt -s nullglob
files=("$DIR"/inbox/*.msg)
if [ "${#files[@]}" -eq 0 ]; then
  printf 'no new instructions\n'
  exit 0
fi

for f in "${files[@]}"; do
  printf -- '--- %s\n' "$(basename "$f")"
  cat "$f"
  printf '\n'
done

if [ "$PEEK" != "--peek" ]; then
  mkdir -p "$DIR/inbox/handled"
  for f in "${files[@]}"; do
    mv "$f" "$DIR/inbox/handled/" 2>/dev/null || true
  done
  printf 'acknowledged %s instruction(s)\n' "${#files[@]}"
fi
