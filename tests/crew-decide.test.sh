#!/usr/bin/env bash
# crew-decide.test.sh - answering a crew member's open decision.
#
# Closing the question and delivering the answer are one act: the board can
# never show a decision that has already been answered, and the crew finds the
# answer in its ordinary steering inbox.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_home >/dev/null
fm_herdr_stub >/dev/null

DECIDE="$BIN/crew-decide.sh"

test_no_open_decisions() {
  local out
  out=$("$DECIDE" --list)
  assert_equals "no open decisions" "$out" "an empty fleet lists nothing"
  pass "the list view is honest when there is nothing to answer"
}

test_answer_closes_and_delivers() {
  fm_task t1 queued >/dev/null
  fm_attach_pane t1 >/dev/null
  "$BIN/crew-report.sh" t1 working "starting the work" >/dev/null
  "$BIN/crew-report.sh" t1 needs-decision "left or right?" --key side >/dev/null

  local out
  out=$("$DECIDE" --list)
  assert_contains "$out" "TASK" "the list prints a header"
  assert_contains "$out" "t1" "the list names the task"
  assert_contains "$out" "side" "the list names the key"
  assert_contains "$out" "left or right?" "the list carries the question"

  out=$("$DECIDE" t1 side "take the left path")
  assert_equals "answered t1 [side]" "$out" "answering reports the task and key"

  assert_equals "working" "$(sed -n 's/^state=//p' "$FOREMAN_HOME/tasks/t1/status")" \
    "the decision closes at answer time"
  assert_equals "no open decisions" "$("$DECIDE" --list)" "the answered decision leaves the list"

  # Delivery: the answer is a normal inbox record, and the pane was rung.
  local msg
  msg=$(cat "$FOREMAN_HOME/tasks/t1"/inbox/*.msg)
  assert_contains "$msg" "Decision [side] answered: take the left path" "the answer lands in the inbox"
  assert_contains "$(fm_herdr_pane_runs)" "crew-inbox.sh t1" "the crew's pane was rung"
  pass "answering closes the question and delivers the answer in one act"
}

test_refusals() {
  fm_task t2 working >/dev/null
  fm_attach_pane t2 >/dev/null
  "$BIN/crew-report.sh" t2 needs-decision "pick one" --key pick >/dev/null

  if "$DECIDE" t2 "not_the_key" "x" >/dev/null 2>&1; then
    fail "answering a key that is not open was accepted"
  fi
  if "$DECIDE" t2 pick >/dev/null 2>&1; then fail "an empty answer was accepted"; fi
  if "$DECIDE" ghost pick "x" >/dev/null 2>&1; then fail "answering a missing task was accepted"; fi
  if "$DECIDE" t2 >/dev/null 2>&1; then fail "answering with no key was accepted"; fi

  "$DECIDE" t2 pick "the first one" >/dev/null
  if "$DECIDE" t2 pick "answer it twice" >/dev/null 2>&1; then
    fail "answering an already-answered decision was accepted"
  fi
  pass "only genuinely open decisions can be answered, once"
}

test_no_open_decisions
test_answer_closes_and_delivers
test_refusals
