#!/usr/bin/env bash
# crew-list.sh - the whole fleet as one line per crew member.
# This is the foreman's default look: cheap, bounded, and always current.
# Regenerates .foreman/BOARD.md as a side effect.
set -eu

. "$(cd "$(dirname "$0")" && pwd)/foreman-lib.sh"

foreman_need_herdr
mkdir -p "$FOREMAN_HOME"

# Bounded liveness refresh: only pane existence is checked, and only once per
# FOREMAN_REFRESH_SECS for the whole home, so listing stays cheap no matter how
# many crew exist. Herdr's `idle` is never read as a state here: a crew member
# between turns is idle and still working.
REFRESH=${FOREMAN_REFRESH_SECS:-15}
case "$REFRESH" in '' | *[!0-9]*) REFRESH=15 ;; esac
GRACE=${FOREMAN_LOST_GRACE_SECS:-60}
case "$GRACE" in '' | *[!0-9]*) GRACE=60 ;; esac
STAMP="$FOREMAN_HOME/.last-refresh"
NOW=$(date +%s)
LAST=$(cat "$STAMP" 2>/dev/null || printf '0')
case "$LAST" in '' | *[!0-9]*) LAST=0 ;; esac

if [ $((NOW - LAST)) -ge "$REFRESH" ]; then
  checked=0
  for id in $(foreman_task_ids); do
    [ "$checked" -lt 25 ] || break
    state=$(foreman_status_get "$id" state)
    case "$state" in working | blocked | queued) ;; *) continue ;; esac
    [ -n "$(foreman_meta_get "$id" pane)" ] || continue
    checked=$((checked + 1))
    if ! foreman_pane_of "$id" >/dev/null 2>&1; then
      foreman_status_set "$id" lost "recorded pane is gone"
      continue
    fi
    # A pane outlives a crashed agent. Only downgrade a `working` task after a
    # grace period, so a normal Pi startup (trust dialog, model init) is never
    # mistaken for a dead crew.
    if [ "$state" = working ]; then
      age=$(foreman_age_secs "$id" 2>/dev/null) || age=
      if [ -n "$age" ] && [ "$age" -ge "$GRACE" ]; then
        panetarget=$(foreman_meta_get "$id" pane)
        if [ -n "$panetarget" ] && ! foreman_herdr agent get "${panetarget#*:}" >/dev/null 2>&1; then
          foreman_status_set "$id" lost "no agent in the pane (exited or crashed)"
        fi
      fi
    fi
  done
  printf '%s\n' "$NOW" >"$STAMP"
fi

render() {
  for id in $(foreman_task_ids); do
    state=$(foreman_status_get "$id" state)
    note=$(foreman_status_get "$id" note)
    age=$(foreman_age_human "$id")
    msgs=0
    if [ -d "$(foreman_task_dir "$id")/inbox" ]; then
      for _ in "$(foreman_task_dir "$id")"/inbox/*.msg; do
        [ -e "$_" ] || continue
        msgs=$((msgs + 1))
      done
    fi
    [ "$msgs" -eq 0 ] || note="$note [${msgs} unread steer]"
    printf '%-18s %-8s %-5s %s\n' "$id" "${state:-unknown}" "$age" "$note"
  done
}

LINES=$(render)
if [ -z "$LINES" ]; then
  printf 'no crew\n'
else
  printf '%-18s %-8s %-5s %s\n' ID STATE AGE NOTE
  printf '%s\n' "$LINES"
fi

mkdir -p "$FOREMAN_HOME"
{
  printf '# Crew board\n\n'
  printf 'Generated %s (session %s)\n\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$FOREMAN_SESSION"
  if [ -z "$LINES" ]; then
    printf 'No crew.\n'
  else
    printf '```\n'
    printf '%-18s %-8s %-5s %s\n' ID STATE AGE NOTE
    printf '%s\n' "$LINES"
    printf '```\n'
  fi
} >"$FOREMAN_BOARD"
