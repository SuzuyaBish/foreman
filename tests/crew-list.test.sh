#!/usr/bin/env bash
# shellcheck disable=SC1010  # "done" is a subcommand argument here, not a loop terminator.
# crew-list.test.sh - the foreman's default look at the fleet, and the board.
#
# This is the one view the captain actually reads, so it must be current without
# costing a model call: liveness is refreshed from Herdr, decisions and unread
# steers are surfaced, and the durable todo list is reconciled before it is
# rendered.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_home >/dev/null
fm_herdr_stub >/dev/null

LIST="$BIN/crew-list.sh"
state_of() { sed -n 's/^state=//p' "$FOREMAN_HOME/tasks/$1/status"; }
note_of() { sed -n 's/^note=//p' "$FOREMAN_HOME/tasks/$1/status"; }

test_empty_fleet() {
  local out
  out=$("$LIST")
  assert_contains "$out" "no crew" "an empty fleet says so"
  assert_present "$FOREMAN_HOME/BOARD.md" "the board file is written"
  assert_contains "$(cat "$FOREMAN_HOME/BOARD.md")" "# Crew board" "the board has a title"
  assert_contains "$(cat "$FOREMAN_HOME/BOARD.md")" "No crew." "the board records the empty fleet"
  pass "an empty fleet renders a board"
}

test_rows_carry_live_state() {
  fm_task w1 working >/dev/null
  fm_attach_pane w1 >/dev/null
  "$BIN/crew-busy-event.sh" arm "$FOREMAN_HOME" w1 --state busy >/dev/null

  local out
  out=$("$LIST")
  assert_contains "$out" "w1" "the crew is listed"
  assert_contains "$out" "working" "the folded state is shown"
  assert_contains "$out" "busy" "the live turn state is shown"
  assert_contains "$out" "STATE" "the header names the state column"
  assert_contains "$out" "BUSY" "the header names the busy column"
  pass "a row carries the folded state and the live turn state"
}

test_unread_steers_and_decisions_are_surfaced() {
  mkdir -p "$FOREMAN_HOME/tasks/w1/inbox"
  printf 'at=x\n--\nkeep going\n' >"$FOREMAN_HOME/tasks/w1/inbox/001.msg"
  "$BIN/crew-report.sh" w1 needs-decision "which port?" --key port >/dev/null

  local out
  out=$("$LIST")
  assert_contains "$out" "[1 unread steer]" "an unread steer is counted in the note"
  assert_contains "$out" "open decisions" "open decisions get their own section"
  assert_contains "$out" "w1 [port] which port?" "the decision names its task, key and question"
  pass "unread steers and open decisions cannot hide"
}

test_endpoint_sweep_downgrades_a_lost_pane() {
  export FOREMAN_REFRESH_SECS=0
  fm_task s1 working >/dev/null
  local pane
  pane=$(fm_attach_pane s1)
  fm_herdr_kill_pane "$pane"

  "$LIST" >/dev/null
  assert_equals "failed" "$(state_of s1)" "a task whose pane vanished is no longer working"
  assert_contains "$(note_of s1)" "endpoint gone" "the note names the lost endpoint"
  pass "liveness is refreshed from Herdr, not remembered"
}

test_agent_gone_downgrade_needs_a_grace_period() {
  export FOREMAN_REFRESH_SECS=0 FOREMAN_LOST_GRACE_SECS=0
  fm_task s2 working >/dev/null
  local pane
  pane=$(fm_attach_pane s2)
  fm_herdr_agent_exit "$pane"

  "$LIST" >/dev/null
  assert_equals "failed" "$(state_of s2)" "a pane outliving its agent is not read as working"
  assert_contains "$(note_of s2)" "no agent in the pane" "the note distinguishes a crashed agent"

  # A task that just spawned must not be downgraded before the grace period.
  export FOREMAN_LOST_GRACE_SECS=600
  fm_task s3 working >/dev/null
  local pane3
  pane3=$(fm_attach_pane s3)
  fm_herdr_agent_exit "$pane3"
  "$LIST" >/dev/null
  assert_equals "working" "$(state_of s3)" "a startup within the grace period is left alone"
  unset FOREMAN_REFRESH_SECS FOREMAN_LOST_GRACE_SECS
  pass "the grace period protects a normal pi startup"
}

test_board_reconciles_the_todo_list() {
  fm_task d1 done >/dev/null
  "$BIN/crew-todo.sh" add "linked work" >/dev/null
  "$BIN/crew-todo.sh" start 1 d1 >/dev/null

  "$LIST" >/dev/null
  assert_equals "done" "$(awk -F'\t' '$1 == 1 { print $2 }' "$FOREMAN_HOME/todo.tsv")" \
    "a row linked to a finished crew is settled on the board"
  local board
  board=$(cat "$FOREMAN_HOME/BOARD.md")
  assert_contains "$board" "## Todo" "the board carries the todo list"
  assert_contains "$board" "linked work" "the board shows the item"
  pass "the board is generated from durable state, not from the transcript"
}

test_empty_fleet
test_rows_carry_live_state
test_unread_steers_and_decisions_are_surfaced
test_endpoint_sweep_downgrades_a_lost_pane
test_agent_gone_downgrade_needs_a_grace_period
test_board_reconciles_the_todo_list
