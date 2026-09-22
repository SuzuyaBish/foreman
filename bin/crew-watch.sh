#!/usr/bin/env bash
# crew-watch.sh - one-shot crew watcher for the auto wake.
#
# Blocks until a crew member changes into a state the captain needs to know
# about (done, failed, blocked, lost), prints one bounded line describing the
# transitions, and exits. The extension in the foreman session restarts it, so
# the foreman is woken by a push without the model ever polling.
#
# The line carries state only. It never carries crew output: the foreman reads
# the board (crew_list) on waking, and a report only when it decides to.
set -eu

. "$(cd "$(dirname "$0")" && pwd)/foreman-lib.sh"

INTERVAL=${FOREMAN_WATCH_INTERVAL:-10}
case "$INTERVAL" in '' | *[!0-9]*) INTERVAL=10 ;; esac
[ "$INTERVAL" -ge 1 ] || INTERVAL=1

ATTENTION=" done failed blocked lost "

snapshot() {
  for id in $(foreman_task_ids); do
    printf '%s=%s\n' "$id" "$(foreman_status_get "$id" state)"
  done
}

prev=$(snapshot)
while :; do
  sleep "$INTERVAL"
  cur=$(snapshot)

  hits=""
  count=0
  while IFS='=' read -r id state; do
    [ -n "$id" ] || continue
    was=$(printf '%s\n' "$prev" | sed -n "s/^$id=//p" | head -1)
    [ "$was" != "$state" ] || continue
    case "$ATTENTION" in *" $state "*) ;; *) continue ;; esac
    count=$((count + 1))
    if [ "$count" -le 3 ]; then
      hits="${hits}${hits:+, }$id $state"
    fi
  done <<EOF
$cur
EOF

  if [ "$count" -gt 0 ]; then
    [ "$count" -le 3 ] || hits="$hits and $((count - 3)) more"
    printf 'crew wake: %s\n' "$hits"
    exit 0
  fi

  prev=$cur
done
