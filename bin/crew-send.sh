#!/usr/bin/env bash
# crew-send.sh - steer one crew member.
# Usage: crew-send.sh <id> <text...>
#
# The durable record is the delivery. The terminal receives only one short
# self-describing doorbell line, so a swallowed or duplicated ring is harmless:
# the crew finds the inbox empty or already handled. The crew's `mv` into
# handled/ is the acknowledgement, and crew-list surfaces unread counts.
set -eu

. "$(cd "$(dirname "$0")" && pwd)/foreman-lib.sh"

ID=${1:-}
if [ $# -ge 1 ]; then shift; fi
TEXT="${*-}"

[ -n "$TEXT" ] || foreman_die "usage: crew-send.sh <id> <text...>"
DIR=$(foreman_require_task "$ID")
foreman_need_herdr

mkdir -p "$DIR/inbox/handled"
LOCK="$DIR/inbox/.lock"
acquired=0
for _ in $(seq 1 50); do
  if mkdir "$LOCK" 2>/dev/null; then
    acquired=1
    break
  fi
  sleep 0.1
done
[ "$acquired" -eq 1 ] || foreman_die "could not lock $DIR/inbox"
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT

max=0
for f in "$DIR"/inbox/*.msg "$DIR"/inbox/handled/*.msg; do
  [ -e "$f" ] || continue
  n=$(basename "$f" .msg)
  case "$n" in '' | *[!0-9]*) continue ;; esac
  n=$((10#$n))
  [ "$n" -gt "$max" ] && max=$n
done
SEQ=$(printf '%03d' "$((max + 1))")
REC="$DIR/inbox/$SEQ.msg"
TMP=$(mktemp "$DIR/inbox/.staging.XXXXXX")
{
  printf 'at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf -- '--\n'
  printf '%s\n' "$TEXT"
} >"$TMP"
mv "$TMP" "$REC"

rmdir "$LOCK" 2>/dev/null || true
trap - EXIT

PANE=$(foreman_pane_of "$ID" 2>/dev/null || true)
RANG=no
if [ -n "$PANE" ]; then
  # Leading ": " is a shell no-op, so this line does nothing if the crew's
  # agent has exited into a bare shell.
  LINE=": new crew instruction for $ID — run $FOREMAN_ROOT/bin/crew-inbox.sh $ID"
  if foreman_herdr pane run "$PANE" "$LINE" >/dev/null 2>&1; then
    RANG=yes
  fi
fi

printf 'recorded %s (pane doorbell: %s)\n' "$REC" "$RANG"
[ "$RANG" = yes ] || printf 'the recorded pane was not reachable; the record is durable and the crew will not see it until reachable\n' >&2
