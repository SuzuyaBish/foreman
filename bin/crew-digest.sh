#!/usr/bin/env bash
# crew-digest.sh - one line describing where things stand, for session start.
#
# Usage: crew-digest.sh
#
# Reads only what is on disk (task records, the todo list, the wake queue, the
# decision log): no Herdr call, no model call, no side effect. One line, so a
# fresh session opens oriented instead of spending a turn to find out.
set -eu

. "$(cd "$(dirname "$0")" && pwd)/foreman-lib.sh"

PARTS=
add_part() { PARTS="${PARTS:+$PARTS · }$1"; }

# --- fleet ------------------------------------------------------------------

total=0
working=0
blocked=0
review=0
queued=0
failed=0
stopped=0
done=0
lost=0
other=0
for id in $(foreman_task_ids); do
  state=$(foreman_status_get "$id" state)
  total=$((total + 1))
  case "$state" in
  working) working=$((working + 1)) ;;
  blocked) blocked=$((blocked + 1)) ;;
  review) review=$((review + 1)) ;;
  queued) queued=$((queued + 1)) ;;
  failed) failed=$((failed + 1)) ;;
  stopped) stopped=$((stopped + 1)) ;;
  done) done=$((done + 1)) ;;
  lost) lost=$((lost + 1)) ;;
  *) other=$((other + 1)) ;;
  esac
done

if [ "$total" -eq 0 ]; then
  add_part "no crew"
else
  states=
  for pair in "working:$working" "blocked:$blocked" "review:$review" "queued:$queued" \
    "failed:$failed" "stopped:$stopped" "done:$done" "lost:$lost" "unknown:$other"; do
    n=${pair#*:}
    [ "$n" -gt 0 ] || continue
    states="${states:+$states, }$n ${pair%%:*}"
  done
  add_part "$total crew ($states)"
fi

# --- decisions and wakes ----------------------------------------------------

decisions=$(foreman_open_decisions | wc -l | tr -d ' ')
[ "$decisions" -eq 0 ] || add_part "$decisions decision$([ "$decisions" -eq 1 ] || printf 's') open"

wakes=$(foreman_queue_count)
[ "$wakes" -eq 0 ] || add_part "$wakes wake$([ "$wakes" -eq 1 ] || printf 's') pending"

# --- todo -------------------------------------------------------------------

if [ -f "$FOREMAN_HOME/todo.tsv" ] || [ -n "$(foreman_task_ids)" ]; then
  # Scoped: the project in focus, plus a note when queued work sits elsewhere.
  # `summary` does not create files, so reading the digest stays side-effect free.
  todo=$("$FOREMAN_ROOT/bin/crew-todo.sh" summary 2>/dev/null || true)
  [ -n "$todo" ] || todo="0 items (0 open, 0 active, 0 done)"
else
  todo="0 items (0 open, 0 active, 0 done)"
fi
add_part "todo $todo"

printf 'crew digest: %s\n' "$PARTS"
