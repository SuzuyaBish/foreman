#!/usr/bin/env bash
# crew-stop.test.sh - stopping one crew member.
#
# The three stop modes have different postconditions, and the report of what
# happened is not allowed to invent one: an exit that could not be confirmed
# says so, and a close always closes the tab this foreman created even when the
# pane already vanished.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_home >/dev/null
fm_herdr_stub >/dev/null

STOP="$BIN/crew-stop.sh"
state_of() { sed -n 's/^state=//p' "$FOREMAN_HOME/tasks/$1/status"; }
note_of() { sed -n 's/^note=//p' "$FOREMAN_HOME/tasks/$1/status"; }

test_interrupt_leaves_the_agent_running() {
  fm_task t1 working >/dev/null
  "$BIN/crew-busy-event.sh" arm "$FOREMAN_HOME" t1 --state busy >/dev/null
  local pane
  pane=$(fm_attach_pane t1)

  local out
  out=$("$STOP" t1)
  assert_equals "interrupted t1 (agent still running)" "$out" "interrupt reports that the agent survives"
  assert_equals "blocked" "$(state_of t1)" "an interrupted crew reads blocked"
  assert_contains "$(note_of t1)" "interrupted by the foreman" "the note explains the state"
  assert_contains "$(fm_herdr_pane_runs)" "keys	$pane	esc" "an escape key was delivered"
  assert_present "$HERDR_STUB_STATE/pane-$pane" "the pane is untouched"
  pass "interrupting cancels the turn but keeps the crew"
}

test_exit_quits_the_agent_and_retires_busy() {
  fm_task t2 working >/dev/null
  "$BIN/crew-busy-event.sh" arm "$FOREMAN_HOME" t2 --state busy >/dev/null
  fm_attach_pane t2 >/dev/null

  local out
  out=$("$STOP" t2 --exit)
  assert_contains "$out" "confirmed=yes" "a confirmed exit is reported as confirmed"
  assert_equals "stopped" "$(state_of t2)" "an exited crew reads stopped"
  assert_contains "$(note_of t2)" "exited (confirmed)" "the note records the confirmation"
  assert_absent "$FOREMAN_HOME/tasks/t2/busy-state" "the busy record is retired on exit"
  assert_absent "$FOREMAN_HOME/tasks/t2/busy-gen" "the incarnation token is retired"
  pass "exiting quits the agent and retires its busy incarnation"
}

test_close_closes_the_tab() {
  fm_task t3 working >/dev/null
  local pane
  pane=$(fm_attach_pane t3)

  local out
  out=$("$STOP" t3 --close)
  assert_contains "$out" "closed its tab" "close reports the tab"
  assert_absent "$HERDR_STUB_STATE/pane-$pane" "the tab (and its pane) is gone"
  pass "closing removes the tab this foreman created"
}

test_stop_closes_a_tab_when_the_pane_is_already_gone() {
  fm_task t4 working >/dev/null
  local pane
  pane=$(fm_attach_pane t4)
  fm_herdr_kill_pane "$pane"

  local out
  out=$("$STOP" t4 --close)
  assert_contains "$out" "pane was already gone" "stop reports the missing pane"
  assert_contains "$out" "tab was closed" "the surviving tab is still closed"
  assert_equals "stopped" "$(state_of t4)" "a crew whose pane vanished is stopped"
  pass "a leaked tab is closed even after its pane disappears"
}

test_reason_is_recorded() {
  fm_task t5 working >/dev/null
  fm_attach_pane t5 >/dev/null
  "$STOP" t5 --interrupt --reason "captain is taking over" >/dev/null
  assert_equals "captain is taking over" "$(note_of t5)" "the reason replaces the default note"
  if "$STOP" t5 --nonsense >/dev/null 2>&1; then fail "an unknown stop mode was accepted"; fi
  if "$STOP" ghost >/dev/null 2>&1; then fail "stopping a missing task was accepted"; fi
  pass "the reason is recorded and modes are validated"
}

test_interrupt_leaves_the_agent_running
test_exit_quits_the_agent_and_retires_busy
test_close_closes_the_tab
test_stop_closes_a_tab_when_the_pane_is_already_gone
test_reason_is_recorded
