#!/usr/bin/env bash
# shellcheck disable=SC1010  # "done" is a subcommand argument here, not a loop terminator.
# crew-watch-stall.test.sh - stall escalation.
#
# A crew that is unfinished and quiet past a bound must raise a wake rather than
# sit silent. The watcher is the only wake producer, so the escalation lives
# there; this file pins the bound, the once-per-episode rule, and the "progress
# makes a later stall news again" behaviour.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_home >/dev/null
fm_herdr_stub >/dev/null

WATCH="$BIN/crew-watch.sh"
export FOREMAN_WATCH_INTERVAL=1
export FOREMAN_PR_POLL_SECS=9999
export FOREMAN_STEER_GRACE_SECS=9999

OUT=$(fm_tmproot watch-stall-out)/log

wait_for_exit() { # <pid> <seconds>
  local pid=$1 limit=$2 i=0
  local ticks=$((limit * 4))
  while kill -0 "$pid" 2>/dev/null; do
    i=$((i + 1))
    [ "$i" -lt "$ticks" ] || return 1
    sleep 0.25
  done
  return 0
}

# wake_on_stall <bound>: run the watcher until it prints a wake, or fail.
wake_on_stall() {
  local stall=$1 pid
  : >"$OUT"
  FOREMAN_STALL_SECS="$stall" "$WATCH" >"$OUT" 2>&1 &
  pid=$!
  wait_for_exit "$pid" 20 || {
    kill "$pid" 2>/dev/null
    fail "the watcher did not wake (stall bound ${stall}s)"
  }
  wait "$pid"
  expect_code 0 "$?" "the watcher exits cleanly after a stall wake"
}

# run_briefly <seconds> <stall-bound>: run the watcher with no expected news,
# then stop it. Used to prove that nothing wakes.
run_briefly() {
  local secs=$1 stall=$2 pid
  : >"$OUT"
  FOREMAN_STALL_SECS="$stall" "$WATCH" >"$OUT" 2>&1 &
  pid=$!
  sleep "$secs"
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
}

queue_count() { "$BIN/crew-queue.sh" count; }

# idle_working_crew <id> <age-seconds>: an unfinished crew, settled at its
# prompt, whose last recorded progress was <age> seconds ago. The working event
# matters: the status cache is folded from the log, so a hand-written status
# would be replaced by the first real event.
idle_working_crew() {
  fm_task "$1" queued >/dev/null
  "$BIN/crew-report.sh" "$1" working "started" >/dev/null
  "$BIN/crew-busy-event.sh" arm "$FOREMAN_HOME" "$1" --state busy >/dev/null
  "$BIN/crew-busy-event.sh" apply "$FOREMAN_HOME" "$1" idle --current-gen \
    --source crew-ext --event agent-settled >/dev/null
  fm_age_task "$1" "$2"
}

test_an_idle_quiet_crew_is_escalated() {
  idle_working_crew s1 90
  wake_on_stall 60
  assert_contains "$(cat "$OUT")" "crew wake: s1 stalled" "the wake line names the stall"
  assert_contains "$("$BIN/crew-queue.sh" list)" "s1 stalled: idle, no progress for 1m" \
    "the durable row carries the busy state and the quiet time"
  assert_present "$FOREMAN_HOME/tasks/s1/.stall-notified" "the episode is marked"
  pass "an idle crew that stopped reporting is escalated, not left silent"
}

test_a_mid_turn_crew_is_escalated_too() {
  fm_task s2 queued >/dev/null
  "$BIN/crew-report.sh" s2 working "started" >/dev/null
  "$BIN/crew-busy-event.sh" arm "$FOREMAN_HOME" s2 --state busy >/dev/null
  fm_age_task s2 90
  wake_on_stall 60
  assert_contains "$("$BIN/crew-queue.sh" list)" "s2 stalled: busy, no progress for 1m" \
    "a mid-turn crew with no progress is reported as busy, not idle"
  pass "a busily-marked crew that makes no progress is still surfaced"
}

test_a_stall_is_reported_once_per_episode() {
  local before
  before=$(queue_count)
  run_briefly 3 60
  assert_equals "$before" "$(queue_count)" "the same stall is not queued twice"
  assert_not_contains "$(cat "$OUT")" "crew wake" "the suppressed stall prints nothing"
  pass "an episode is reported once, not every interval"
}

test_progress_makes_a_later_stall_news_again() {
  # The watcher clears the marker on its next pass once progress lands; the
  # progress report itself only rewrites the status timestamp.
  "$BIN/crew-report.sh" s1 progress "back at it" >/dev/null
  run_briefly 2 60
  assert_absent "$FOREMAN_HOME/tasks/s1/.stall-notified" "progress clears the stall marker"

  local before
  before=$(queue_count)
  fm_age_task s1 90
  wake_on_stall 60
  assert_equals "$((before + 1))" "$(queue_count)" "a new stall after progress is news again"
  pass "the marker is per episode, not per task"
}

test_a_fresh_crew_is_not_stalled() {
  fm_task s3 queued >/dev/null
  "$BIN/crew-report.sh" s3 working "started" >/dev/null
  fm_attach_pane s3 >/dev/null
  local before
  before=$(queue_count)
  run_briefly 3 60
  assert_equals "$before" "$(queue_count)" "a crew that just reported is not escalated"
  assert_absent "$FOREMAN_HOME/tasks/s3/.stall-notified" "a fresh crew is not marked"
  pass "a fresh crew is left alone"
}

test_a_settled_crew_is_not_stalled() {
  fm_task s4 done >/dev/null
  fm_age_task s4 9000
  local before
  before=$(queue_count)
  run_briefly 3 60
  assert_equals "$before" "$(queue_count)" "a finished crew is never a stall"
  pass "only unfinished work can stall"
}

test_the_bound_can_be_disabled() {
  fm_task s5 working >/dev/null
  fm_age_task s5 9000
  local before
  before=$(queue_count)
  run_briefly 3 0
  assert_equals "$before" "$(queue_count)" "FOREMAN_STALL_SECS=0 disables escalation"
  assert_absent "$FOREMAN_HOME/tasks/s5/.stall-notified" "a disabled bound marks nothing"
  pass "the stall bound can be turned off"
}

test_an_idle_quiet_crew_is_escalated
test_a_mid_turn_crew_is_escalated_too
test_a_stall_is_reported_once_per_episode
test_progress_makes_a_later_stall_news_again
test_a_fresh_crew_is_not_stalled
test_a_settled_crew_is_not_stalled
test_the_bound_can_be_disabled
