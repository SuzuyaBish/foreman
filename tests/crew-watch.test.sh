#!/usr/bin/env bash
# crew-watch.test.sh - the one-shot watcher, and the wake rows it produces.
#
# The watcher is the only producer of wake rows. It blocks until there is news,
# appends a bounded durable row, prints one line, and exits; the foreman is
# never asked to poll. Timings here are compressed to one second.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_home >/dev/null
fm_herdr_stub >/dev/null

WATCH="$BIN/crew-watch.sh"
export FOREMAN_WATCH_INTERVAL=1
export FOREMAN_STEER_GRACE_SECS=1
export FOREMAN_STEER_MAX_RINGS=3
export FOREMAN_PR_POLL_SECS=9999

OUT=$(fm_tmproot watch-out)/log

# wait_for_exit <pid> <seconds>: 0 if the process exited in time.
wait_for_exit() {
  local pid=$1 limit=$2 i=0
  local ticks=$((limit * 4))
  while kill -0 "$pid" 2>/dev/null; do
    i=$((i + 1))
    [ "$i" -lt "$ticks" ] || return 1
    sleep 0.25
  done
  return 0
}

test_a_state_change_wakes_the_foreman() {
  fm_task w1 working >/dev/null
  fm_attach_pane w1 >/dev/null

  : >"$OUT"
  "$WATCH" >"$OUT" 2>&1 &
  local pid=$!
  sleep 1.5
  "$BIN/crew-report.sh" w1 review "ready for review" >/dev/null

  wait_for_exit "$pid" 20 || {
    kill "$pid" 2>/dev/null
    fail "the watcher did not wake on a state change"
  }
  wait "$pid"
  expect_code 0 "$?" "the watcher exits cleanly after a wake"
  assert_contains "$(cat "$OUT")" "crew wake: w1 review" "the wake line names the task and new state"
  assert_contains "$("$BIN/crew-queue.sh" list)" "w1 review" "a durable wake row was appended"
  pass "a state change produces one durable wake row and one line"
}

test_a_lost_endpoint_wakes_the_foreman() {
  fm_task w2 working >/dev/null
  local pane
  pane=$(fm_attach_pane w2)
  : >"$OUT"
  "$WATCH" >"$OUT" 2>&1 &
  local pid=$!
  sleep 1.5
  fm_herdr_kill_pane "$pane"

  wait_for_exit "$pid" 20 || {
    kill "$pid" 2>/dev/null
    fail "the watcher did not wake on a lost endpoint"
  }
  wait "$pid"
  assert_contains "$(cat "$OUT")" "crew wake: w2 failed" "a lost endpoint wakes as failed"
  assert_equals "failed" "$(sed -n 's/^state=//p' "$FOREMAN_HOME/tasks/w2/status")" \
    "the task is no longer read as working"
  pass "a pane that vanishes mid-flight cannot sit silent"
}

test_an_unacknowledged_steer_escalates() {
  fm_task e1 working >/dev/null
  mkdir -p "$FOREMAN_HOME/tasks/e1/inbox"
  printf 'at=x\n--\nplease do the thing\n' >"$FOREMAN_HOME/tasks/e1/inbox/001.msg"
  printf '001.msg\t5\t%s\n' "$(($(date +%s) - 3600))" >"$FOREMAN_HOME/tasks/e1/inbox/.ring"

  : >"$OUT"
  "$WATCH" >"$OUT" 2>&1 &
  local pid=$!
  sleep 3
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null

  assert_contains "$("$BIN/crew-queue.sh" list)" "e1 steer 001.msg unacknowledged after 5 rings" \
    "a steer past its ring ladder is escalated into the wake queue"
  assert_present "$FOREMAN_HOME/tasks/e1/inbox/.escalated-001.msg" \
    "escalation is recorded once, not on every pass"
  pass "a swallowed doorbell becomes a visible fact"
}

test_a_state_change_wakes_the_foreman
test_a_lost_endpoint_wakes_the_foreman
test_an_unacknowledged_steer_escalates
