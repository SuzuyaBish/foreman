#!/usr/bin/env bash
# crew-list.sh - the whole fleet as one line per crew member.
# This is the foreman's default look: cheap, bounded, and always current.
# Regenerates .foreman/BOARD.md as a side effect.
set -eu

. "$(cd "$(dirname "$0")" && pwd)/foreman-lib.sh"

foreman_need_herdr
mkdir -p "$FOREMAN_HOME"

# Bounded liveness refresh: only pane existence is checked, and only once per
# FOREMAN_REFRESH_SECS for the whole home. Herdr's `idle` is never read as a
# state here: a crew member between turns is idle and still working.
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
      foreman_event_append "$id" failed "" "endpoint gone: the recorded pane no longer exists"
      foreman_status_sync "$id"
      continue
    fi
    # A pane outlives a crashed agent. Only downgrade a `working` task after a
    # grace period, so a normal Pi startup is never mistaken for a dead crew.
    if [ "$state" = working ]; then
      age=$(foreman_age_secs "$id" 2>/dev/null) || age=
      if [ -n "$age" ] && [ "$age" -ge "$GRACE" ]; then
        busy=$(foreman_busy_read "$id" | cut -f1)
        if [ "$busy" = unknown ]; then
          panetarget=$(foreman_meta_get "$id" pane)
          if [ -n "$panetarget" ] && ! foreman_herdr agent get "${panetarget#*:}" >/dev/null 2>&1; then
            foreman_event_append "$id" failed "" "no agent in the pane (exited or crashed)"
            foreman_status_sync "$id"
          fi
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
    busy=$(foreman_busy_read "$id" | cut -f1)
    case "$busy" in busy | idle) ;; *) busy=- ;; esac
    msgs=0
    if [ -d "$(foreman_task_dir "$id")/inbox" ]; then
      for _ in "$(foreman_task_dir "$id")"/inbox/*.msg; do
        [ -e "$_" ] || continue
        msgs=$((msgs + 1))
      done
    fi
    [ "$msgs" -eq 0 ] || note="$note [${msgs} unread steer]"
    printf '%-18s %-8s %-5s %-5s %s\n' "$id" "${state:-unknown}" "$age" "$busy" "$note"
  done
}

LINES=$(render)
DECISIONS=$(foreman_open_decisions)

# The todo list is the durable queue: reconcile it against crew reality before
# anyone reads it, so a row can never silently disagree with what happened.
"$FOREMAN_ROOT/bin/crew-todo.sh" sync >/dev/null 2>&1 || true
TODO=$("$FOREMAN_ROOT/bin/crew-todo.sh" list 2>/dev/null || true)
TODO_SUMMARY=$("$FOREMAN_ROOT/bin/crew-todo.sh" summary 2>/dev/null || true)

{
  if [ -n "$TODO_SUMMARY" ]; then
    printf 'todo %s\n' "$TODO_SUMMARY"
    printf '%s\n' "$TODO"
    printf '\n'
  fi
  if [ -z "$LINES" ]; then
    printf 'no crew\n'
  else
    printf '%-18s %-8s %-5s %-5s %s\n' ID STATE AGE BUSY NOTE
    printf '%s\n' "$LINES"
  fi
  if [ -n "$DECISIONS" ]; then
    printf '\nopen decisions\n'
    printf '%s\n' "$DECISIONS" | awk -F'\t' '{ printf "  %s [%s] %s\n", $1, $2, $3 }'
  fi
}

{
  printf '# Crew board\n\n'
  printf 'Generated %s (session %s)\n\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$FOREMAN_SESSION"
  if [ -n "$TODO_SUMMARY" ]; then
    printf '## Todo\n\n'
    printf '%s\n\n' "$TODO_SUMMARY"
    printf '```\n'
    printf '%s\n' "$TODO"
    printf '```\n\n'
  fi
  printf '## Crew\n\n'
  if [ -z "$LINES" ]; then
    printf 'No crew.\n'
  else
    printf '```\n'
    printf '%-18s %-8s %-5s %-5s %s\n' ID STATE AGE BUSY NOTE
    printf '%s\n' "$LINES"
    printf '```\n'
  fi
  if [ -n "$DECISIONS" ]; then
    printf '\n## Open decisions\n\n'
    printf '%s\n' "$DECISIONS" | awk -F'\t' '{ printf "- **%s** [%s] %s\n", $1, $2, $3 }'
  fi
} >"$FOREMAN_BOARD"
