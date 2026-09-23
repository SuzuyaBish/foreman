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
# Rows carry state and identifiers only. Crew output never reaches them; a
# review row adds the linked todo item's number and title so the wake says which
# piece of work is ready, not only which crew.
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

# Is the terminal a finished crew was given still there? Something may have
# closed it already -- a merge closes the home of the crew it settles -- and a
# home that is gone must be marked settled, never closed or announced again.
home_live() { # <id> <own-workspace> <pane>
  local id=$1 ws=$2 pane=$3
  if [ -n "$ws" ] && foreman_herdr workspace get "$ws" >/dev/null 2>&1; then
    return 0
  fi
  if [ -n "$pane" ] && foreman_pane_of "$id" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

# A crew that has reached done or failed owes nothing further, so its terminal
# must not sit idle until somebody archives it. Close the home the foreman made
# for it -- workspace, else tab -- exactly as a successful merge does, and print
# one "<id>\t<note>" per release for the wake line. Only the terminal goes: the
# record, the branch and the worktree all survive. Best effort throughout, like
# merge and archive: Herdr absent is a warning, never a failure, and a home that
# is already gone is a silent no-op. The .home-closed marker is what makes it
# once: a settled task is not retried and not announced again.
sweep_finished_homes() {
  local id dir state ws tab pane marker note
  for id in $(foreman_task_ids); do
    state=$(foreman_status_get "$id" state)
    case "$state" in done | failed) ;; *) continue ;; esac
    dir=$(foreman_task_dir "$id")
    marker="$dir/.home-closed"
    [ -f "$marker" ] && continue
    ws=$(foreman_own_workspace "$id")
    tab=$(foreman_meta_get "$id" tab 2>/dev/null || printf '')
    pane=$(foreman_meta_get "$id" pane 2>/dev/null || printf '')
    if [ -z "$ws" ] && [ -z "$tab" ] && [ -z "$pane" ]; then
      # Nothing was ever recorded as a home; settle it silently.
      : >"$marker"
      continue
    fi
    if ! command -v herdr >/dev/null 2>&1; then
      printf '%s\t%s\n' "$id" "could not close its terminal (herdr is not on PATH)"
      continue
    fi
    if ! home_live "$id" "$ws" "$pane"; then
      # A merge, or an earlier watch run, already closed it: settle without a
      # second close or a second announcement.
      : >"$marker"
      continue
    fi
    case "$(foreman_close_home "$id")" in
    workspace) note="closed its workspace" ;;
    tab) note="closed its tab" ;;
    *) note="nothing was left to close" ;;
    esac
    : >"$marker"
    printf '%s\t%s\n' "$id" "$note"
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
  finished=$(sweep_finished_homes)

  hits=""
  count=0
  settled=" "
  while IFS='=' read -r id state; do
    [ -n "$id" ] || continue
    was=$(printf '%s\n' "$prev" | sed -n "s/^$id=//p" | head -1)
    [ "$was" != "$state" ] || continue
    case "$ATTENTION" in *" $state "*) ;; *) continue ;; esac
    count=$((count + 1))
    # A review carries the work's identity (todo number and title, then the PR),
    # not just the crew id; every other transition is unchanged.
    payload=$(foreman_transition_payload "$id" "$state")
    # A crew that has just finished released its terminal too, and that note
    # rides the same row, so one line says both what happened and what it left.
    fnote=$(printf '%s\n' "$finished" | awk -F'\t' -v i="$id" '$1 == i { print $2; exit }')
    if [ -n "$fnote" ]; then
      payload="$payload — $fnote"
      settled="$settled$id "
    fi
    foreman_queue_append state "$payload" >/dev/null || true
    if [ "$count" -le 3 ]; then
      hits="${hits}${hits:+, }$payload"
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

  # A finished crew the watcher meets already settled -- it restarted after the
  # crew reported, or a merge closed the home before this run -- still gets its
  # release announced, once, on a row of its own.
  while IFS=$'\t' read -r id fnote; do
    [ -n "$id" ] || continue
    case "$settled" in *" $id "*) continue ;; esac
    count=$((count + 1))
    entry="$id finished — $fnote"
    foreman_queue_append state "$entry" >/dev/null || true
    if [ "$count" -le 3 ]; then
      hits="${hits}${hits:+, }$entry"
    fi
  done <<EOF
$finished
EOF

  if [ "$count" -gt 0 ]; then
    [ "$count" -le 3 ] || hits="$hits and $((count - 3)) more"
    printf 'crew wake: %s\n' "$hits"
    exit 0
  fi

  prev=$cur
done
