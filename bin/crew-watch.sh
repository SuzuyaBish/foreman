#!/usr/bin/env bash
# crew-watch.sh - one-shot crew watcher. The only producer of wake rows.
#
# Blocks until there is news, appends one bounded durable row per item to the
# wake queue, prints a one-line summary, and exits. The extension restarts it,
# so the foreman is woken by a push without the model ever polling.
#
# What it watches:
#   * a task changing into review / done / failed / blocked / lost;
#   * a pull request of a task in review being merged or closed;
#   * a steer that has sat unacknowledged past the grace period, re-rung on a
#     bounded ladder and then escalated;
#   * a crew that is unfinished and has made no progress past the stall bound;
#   * (once per run, at start) a task whose pane is gone while unfinished.
#
# Rows carry state and identifiers only. Crew output never reaches them.
set -eu

. "$(cd "$(dirname "$0")" && pwd)/foreman-lib.sh"

INTERVAL=${FOREMAN_WATCH_INTERVAL:-10}
case "$INTERVAL" in '' | *[!0-9]*) INTERVAL=10 ;; esac
[ "$INTERVAL" -ge 1 ] || INTERVAL=1

PR_POLL=${FOREMAN_PR_POLL_SECS:-60}
case "$PR_POLL" in '' | *[!0-9]*) PR_POLL=60 ;; esac
PR_STAMP="$FOREMAN_HOME/.last-pr-poll"

STEER_GRACE=${FOREMAN_STEER_GRACE_SECS:-90}
case "$STEER_GRACE" in '' | *[!0-9]*) STEER_GRACE=90 ;; esac
STEER_MAX=${FOREMAN_STEER_MAX_RINGS:-3}
case "$STEER_MAX" in '' | *[!0-9]*) STEER_MAX=3 ;; esac

# How long an unfinished crew may go without a single event before it is a
# stall. Generous on purpose: a legitimate long turn should not be flagged.
STALL=${FOREMAN_STALL_SECS:-1800}
case "$STALL" in '' | *[!0-9]*) STALL=1800 ;; esac

ATTENTION=" review done failed blocked lost "

snapshot() {
  for id in $(foreman_task_ids); do
    printf '%s=%s\n' "$id" "$(foreman_status_get "$id" state)"
  done
}

poll_prs() {
  local now last
  now=$(date +%s)
  last=$(cat "$PR_STAMP" 2>/dev/null || printf '0')
  case "$last" in '' | *[!0-9]*) last=0 ;; esac
  [ $((now - last)) -ge "$PR_POLL" ] || return 0
  mkdir -p "$FOREMAN_HOME"
  printf '%s\n' "$now" >"$PR_STAMP"
  local id
  for id in $(foreman_task_ids); do
    [ "$(foreman_status_get "$id" state)" = review ] || continue
    [ -n "$(foreman_meta_get "$id" pr)" ] || continue
    "$FOREMAN_ROOT/bin/crew-pr-check.sh" "$id" >/dev/null 2>&1 || true
  done
}

# Re-ring unacknowledged steers, and escalate once past the ladder.
service_steers() {
  local id dir f n count at now
  for id in $(foreman_task_ids); do
    dir=$(foreman_task_dir "$id")
    [ -d "$dir/inbox" ] || continue
    case "$(foreman_status_get "$id" state)" in done | failed | stopped) continue ;; esac
    for f in "$dir"/inbox/*.msg; do
      [ -e "$f" ] || continue
      n=$(basename "$f")
      count=0
      at=0
      if [ -f "$dir/inbox/.ring" ]; then
        read -r rmsg rcount rat <"$dir/inbox/.ring" 2>/dev/null || true
        case "${rmsg:-}" in "$n") count=${rcount:-0} ;; esac
        case "${rat:-}" in '' | *[!0-9]*) at=0 ;; *) at=$rat ;; esac
      fi
      now=$(date +%s)
      [ $((now - at)) -ge "$STEER_GRACE" ] || continue
      if [ "$count" -ge "$STEER_MAX" ]; then
        if [ ! -f "$dir/inbox/.escalated-$n" ]; then
          foreman_queue_append steer "$id steer $n unacknowledged after $count rings" >/dev/null || true
          : >"$dir/inbox/.escalated-$n"
        fi
        continue
      fi
      if "$FOREMAN_ROOT/bin/crew-send.sh" "$id" --re-ring "$f" >/dev/null 2>&1; then
        printf '%s\t%s\t%s\n' "$n" "$((count + 1))" "$now" >"$dir/inbox/.ring"
      fi
    done
  done
}

# A crew that is unfinished and quiet past the bound is stalled: idle at its
# prompt with nothing reported, or mid-turn with no progress. Escalated once per
# episode through .stall-notified, so the wake queue does not fill up with the
# same fact every interval. Progress (any event rewrites the status timestamp)
# clears the marker, so a later stall is news again.
check_stalls() {
  local id dir state busy age ago
  [ "$STALL" -gt 0 ] || return 0
  for id in $(foreman_task_ids); do
    dir=$(foreman_task_dir "$id")
    if [ "$(foreman_status_get "$id" state)" != working ]; then
      rm -f "$dir/.stall-notified"
      continue
    fi
    age=$(foreman_age_secs "$id" 2>/dev/null) || continue
    if [ "$age" -lt "$STALL" ]; then
      rm -f "$dir/.stall-notified"
      continue
    fi
    [ -f "$dir/.stall-notified" ] && continue
    # A lost endpoint is the endpoint sweep's business, not a stall.
    busy=$(foreman_busy_read "$id" | cut -f1)
    [ "$busy" = dead ] && continue
    if [ "$age" -ge 60 ]; then ago="$((age / 60))m"; else ago="${age}s"; fi
    foreman_queue_append state "$id stalled: $busy, no progress for $ago" >/dev/null || true
    : >"$dir/.stall-notified"
    printf '%s\n' "$id"
  done
}

# A pane that is gone while its task is unfinished is the one thing that must be
# caught even if nothing else changes: otherwise it reads as `working` forever.
sweep_endpoints() {
  local id state
  for id in $(foreman_task_ids); do
    state=$(foreman_status_get "$id" state)
    case "$state" in working | blocked | queued) ;; *) continue ;; esac
    [ -n "$(foreman_meta_get "$id" pane)" ] || continue
    if ! foreman_pane_of "$id" >/dev/null 2>&1; then
      foreman_event_append "$id" failed "" "endpoint gone: the recorded pane no longer exists"
      foreman_status_sync "$id"
    fi
  done
}

sweep_endpoints
poll_prs
service_steers
prev=$(snapshot)

while :; do
  sleep "$INTERVAL"
  poll_prs
  service_steers
  sweep_endpoints
  cur=$(snapshot)
  stalled=$(check_stalls)

  hits=""
  count=0
  while IFS='=' read -r id state; do
    [ -n "$id" ] || continue
    was=$(printf '%s\n' "$prev" | sed -n "s/^$id=//p" | head -1)
    [ "$was" != "$state" ] || continue
    case "$ATTENTION" in *" $state "*) ;; *) continue ;; esac
    count=$((count + 1))
    foreman_queue_append state "$id $state" >/dev/null || true
    if [ "$count" -le 3 ]; then
      hits="${hits}${hits:+, }$id $state"
    fi
  done <<EOF
$cur
EOF

  for id in $stalled; do
    count=$((count + 1))
    if [ "$count" -le 3 ]; then
      hits="${hits}${hits:+, }$id stalled"
    fi
  done

  if [ "$count" -gt 0 ]; then
    [ "$count" -le 3 ] || hits="$hits and $((count - 3)) more"
    printf 'crew wake: %s\n' "$hits"
    exit 0
  fi

  prev=$cur
done
