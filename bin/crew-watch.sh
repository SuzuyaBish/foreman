#!/usr/bin/env bash
# crew-watch.sh - one-shot crew watcher for the auto wake.
#
# Blocks until a crew member changes into a state the captain needs to know
# about (review, done, failed, blocked, lost), prints one bounded line
# describing the transitions, and exits. The extension in the foreman session
# restarts it, so the foreman is woken by a push without the model ever polling.
#
# It also polls the pull request of every task waiting in `review`, on a slow
# stamp-gated cadence, so a merge settles the task and wakes the foreman without
# anyone asking.
#
# The line carries state only. It never carries crew output: the foreman reads
# the board (crew_list) on waking, and a report only when it decides to.
set -eu

. "$(cd "$(dirname "$0")" && pwd)/foreman-lib.sh"

INTERVAL=${FOREMAN_WATCH_INTERVAL:-10}
case "$INTERVAL" in '' | *[!0-9]*) INTERVAL=10 ;; esac
[ "$INTERVAL" -ge 1 ] || INTERVAL=1

PR_POLL=${FOREMAN_PR_POLL_SECS:-60}
case "$PR_POLL" in '' | *[!0-9]*) PR_POLL=60 ;; esac
PR_STAMP="$FOREMAN_HOME/.last-pr-poll"

ATTENTION=" review done failed blocked lost "

snapshot() {
  for id in $(foreman_task_ids); do
    printf '%s=%s\n' "$id" "$(foreman_status_get "$id" state)"
  done
}

# Merge state for everything awaiting review, at most once per PR_POLL seconds.
# A merge flips the task to `done`, which the snapshot below then reports.
poll_prs() {
  now=$(date +%s)
  last=$(cat "$PR_STAMP" 2>/dev/null || printf '0')
  case "$last" in '' | *[!0-9]*) last=0 ;; esac
  [ $((now - last)) -ge "$PR_POLL" ] || return 0
  mkdir -p "$FOREMAN_HOME"
  printf '%s\n' "$now" >"$PR_STAMP"
  for id in $(foreman_task_ids); do
    [ "$(foreman_status_get "$id" state)" = review ] || continue
    [ -n "$(foreman_meta_get "$id" pr)" ] || continue
    "$FOREMAN_ROOT/bin/crew-pr-check.sh" "$id" >/dev/null 2>&1 || true
  done
}

poll_prs
prev=$(snapshot)
while :; do
  sleep "$INTERVAL"
  poll_prs
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
