#!/usr/bin/env bash
# shellcheck disable=SC1010  # "done" is a subcommand argument here, not a loop terminator.
# crew-digest.test.sh - the one-line session-start digest.
#
# The digest is what makes a fresh session open oriented, so it must be exactly
# one line, count only what is real, and never call Herdr or the model to find
# out.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_home >/dev/null

DIGEST="$BIN/crew-digest.sh"

test_line_count() { # <haystack> <msg>
  case "$1" in
  *$'\n'*) fail "$2 (digest is more than one line)" ;;
  esac
}

test_empty_home() {
  local out
  out=$("$DIGEST")
  test_line_count "$out" "the digest is a single line"
  assert_contains "$out" "crew digest:" "the digest is labelled"
  assert_contains "$out" "no crew" "an empty fleet says so"
  assert_contains "$out" "todo 0 items (0 open, 0 active, 0 done)" "an empty todo list is counted"
  assert_not_contains "$out" "decision" "no decision is invented"
  assert_not_contains "$out" "wake" "no wake is invented"
  pass "an empty home produces one honest line"
}

test_fleet_counts() {
  fm_task w1 working >/dev/null
  fm_task w2 working >/dev/null
  fm_task b1 blocked >/dev/null
  fm_task r1 review >/dev/null
  local out fleet
  out=$("$DIGEST")
  test_line_count "$out" "the digest is a single line"
  fleet=$(printf '%s' "$out" | sed 's/ · .*//')
  assert_contains "$fleet" "4 crew (2 working, 1 blocked, 1 review)" "each state is counted"
  assert_not_contains "$fleet" "0 " "a zero count is left out"
  pass "the fleet is summarised by state, with zeroes omitted"
}

test_decisions_and_wakes() {
  fm_task d1 working >/dev/null
  "$BIN/crew-report.sh" d1 needs-decision "which one?" --key pick >/dev/null
  "$BIN/crew-report.sh" d1 needs-decision "and this?" --key other >/dev/null
  "$BIN/crew-queue.sh" append state "d1 blocked" >/dev/null

  local out
  out=$("$DIGEST")
  assert_contains "$out" "2 decisions open" "plural decisions are counted"
  assert_contains "$out" "1 wake pending" "a single wake is phrased singular"
  pass "decisions and wakes are surfaced without being invented"
}

test_todo_counts() {
  "$BIN/crew-todo.sh" add "one" >/dev/null
  "$BIN/crew-todo.sh" add "two" >/dev/null
  "$BIN/crew-todo.sh" add "three" >/dev/null
  "$BIN/crew-todo.sh" start 3 w1 >/dev/null
  "$BIN/crew-todo.sh" done 1 >/dev/null

  local out
  out=$("$DIGEST")
  test_line_count "$out" "the digest is a single line"
  assert_contains "$out" "todo 3 items (1 open, 1 active, 1 done)" "todo intent is counted from the list"
  pass "the todo list is summarised by intent"
}

test_no_herdr_needed() {
  # The digest must not shell out to Herdr: a session can start before the
  # server does, and the whole point is that it is cheap.
  local out
  out=$(PATH=$(fm_path_without herdr) "$DIGEST")
  assert_contains "$out" "crew digest:" "the digest runs with no herdr on PATH"
  pass "the digest reads records only"
}

test_empty_home
test_fleet_counts
test_decisions_and_wakes
test_todo_counts
test_no_herdr_needed
