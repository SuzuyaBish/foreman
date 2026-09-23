#!/usr/bin/env bash
# crew-busy.test.sh - semantic turn state, and the generation that bounds it.
#
# Herdr can say a pane exists; it cannot say whether the agent in it is
# mid-turn. The record that answers that question must be owned by exactly one
# incarnation, so a stale extension can never write state for the wrong
# process, and "unknown" must never be presented as "idle".
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_home >/dev/null
fm_herdr_stub >/dev/null

EVENT="$BIN/crew-busy-event.sh"
BUSY="$BIN/crew-busy.sh"

test_arm_mints_an_incarnation() {
  fm_task t1 >/dev/null
  local gen
  gen=$("$EVENT" arm "$FOREMAN_HOME" t1 --state busy --source fm-spawn --event launch-brief)
  [ -n "$gen" ] || fail "arm printed no token"
  assert_equals "$gen" "$(cat "$FOREMAN_HOME/tasks/t1/busy-gen")" "the token is the task's generation"
  local rec
  rec=$(cat "$FOREMAN_HOME/tasks/t1/busy-state")
  assert_contains "$rec" "gen=$gen" "the record is bound to the token"
  assert_contains "$rec" "seq=1" "arming seeds the first sequence"
  assert_contains "$rec" "state=busy" "arming defaults to busy"
  assert_contains "$rec" "source=fm-spawn" "arming records who claimed it"
  assert_absent "$FOREMAN_HOME/tasks/t1/.busy.lock" "arming releases its lock"
  pass "arming mints a token and seeds the record"
}

test_apply_requires_the_current_generation() {
  local gen
  gen=$(cat "$FOREMAN_HOME/tasks/t1/busy-gen")
  if "$EVENT" apply "$FOREMAN_HOME" t1 idle --gen "not-$gen" --source crew-ext --event agent-settled >/dev/null 2>&1; then
    fail "a stale generation was allowed to write state"
  fi
  assert_contains "$(cat "$FOREMAN_HOME/tasks/t1/busy-state")" "state=busy" "a refused write leaves the record untouched"

  "$EVENT" apply "$FOREMAN_HOME" t1 idle --current-gen --source crew-ext --event agent-settled >/dev/null
  local rec
  rec=$(cat "$FOREMAN_HOME/tasks/t1/busy-state")
  assert_contains "$rec" "state=idle" "a current-generation write lands"
  assert_contains "$rec" "seq=2" "each event advances the sequence"
  assert_contains "$rec" "source=crew-ext" "the writer is recorded"

  if "$EVENT" apply "$FOREMAN_HOME" t1 nonsense --current-gen --source crew-ext --event x >/dev/null 2>&1; then
    fail "an invalid busy state was accepted"
  fi
  if "$EVENT" apply "$FOREMAN_HOME" t1 idle --source crew-ext --event x >/dev/null 2>&1; then
    fail "apply without a generation was accepted"
  fi
  if "$EVENT" bogus "$FOREMAN_HOME" t1 >/dev/null 2>&1; then fail "an unknown action was accepted"; fi
  pass "only the current incarnation can write, and sequences advance"
}

test_retire() {
  local gen
  gen=$(cat "$FOREMAN_HOME/tasks/t1/busy-gen")
  if "$EVENT" retire "$FOREMAN_HOME" t1 --gen "not-$gen" >/dev/null 2>&1; then
    fail "a stale generation could retire the record"
  fi
  assert_present "$FOREMAN_HOME/tasks/t1/busy-gen" "a refused retire leaves the record in place"

  "$EVENT" retire "$FOREMAN_HOME" t1 --current-gen >/dev/null
  assert_absent "$FOREMAN_HOME/tasks/t1/busy-state" "retire removes the record"
  assert_absent "$FOREMAN_HOME/tasks/t1/busy-gen" "retire removes the token"
  pass "retiring is generation-guarded and cleans both files"
}

test_busy_verdicts() {
  fm_task b1 >/dev/null
  local pane
  pane=$(fm_attach_pane b1)

  # A live pane with no record is unknown, and says why.
  local out
  out=$("$BUSY" b1)
  assert_contains "$out" "unknown" "no record reads unknown"
  assert_contains "$out" "no-record" "the reason distinguishes 'no record yet'"

  # An agent that exited while the pane survived is registered differently.
  fm_task b2 >/dev/null
  local pane2
  pane2=$(fm_attach_pane b2)
  fm_herdr_agent_exit "$pane2"
  out=$("$BUSY" b2)
  assert_contains "$out" "unknown" "an unregistered agent reads unknown"
  assert_contains "$out" "no-agent-registration" "the reason distinguishes a dead agent"

  # A missing endpoint is dead, never idle.
  fm_task b3 >/dev/null
  local pane3
  pane3=$(fm_attach_pane b3)
  fm_herdr_kill_pane "$pane3"
  out=$("$BUSY" b3)
  assert_contains "$out" "dead" "a lost pane reads dead"
  assert_contains "$out" "endpoint-gone" "the reason names the lost endpoint"

  # A real record reads its state.
  fm_task b4 >/dev/null
  fm_attach_pane b4 >/dev/null
  "$EVENT" arm "$FOREMAN_HOME" b4 --state busy --source fm-spawn >/dev/null
  out=$("$BUSY" b4)
  assert_contains "$out" "busy" "an armed crew reads busy"
  assert_contains "$out" "fm-spawn" "the source is reported"

  "$EVENT" apply "$FOREMAN_HOME" b4 idle --current-gen --source crew-ext --event agent-settled >/dev/null
  out=$("$BUSY" b4)
  assert_contains "$out" "idle" "a settled crew reads idle"

  # A record from a previous incarnation is unknown, not idle.
  fm_herdr_kill_pane "$pane" >/dev/null 2>&1 || true
  local gen
  gen=$(cat "$FOREMAN_HOME/tasks/b4/busy-gen")
  printf 'v1 gen=%s seq=1 state=idle source=crew-ext event=agent-settled ts=1\n' "$gen" >"$FOREMAN_HOME/tasks/b4/busy-state"
  printf 'newer-gen\n' >"$FOREMAN_HOME/tasks/b4/busy-gen"
  out=$("$BUSY" b4)
  assert_contains "$out" "unknown" "a stale generation reads unknown"
  assert_contains "$out" "stale-gen" "the reason names the stale incarnation"
  pass "busy is busy, idle, dead or unknown -- never a guess"
}

test_an_explicit_home_is_honoured() {
  # A crew's shell does not inherit FOREMAN_HOME, so its generated extension
  # passes the foreman home positionally. The record paths are cached when the
  # lib is sourced, so a script that re-points only FOREMAN_HOME writes to the
  # wrong home. This was a real bug: every agent_start/agent_settled write from a
  # crew whose home was not the ambient one went missing, and the busy record sat
  # at its spawn value forever.
  local other
  other="$(fm_tmproot busy-other)/home"
  mkdir -p "$other"
  "$EVENT" arm "$other" b5 --state busy --source fm-spawn >/dev/null ||
    fail "arming a task in a named home failed"
  "$EVENT" apply "$other" b5 idle --current-gen --source crew-ext --event agent-settled >/dev/null ||
    fail "applying to a task in a named home failed"
  assert_contains "$(cat "$other/tasks/b5/busy-state")" "state=idle" \
    "the write lands in the home the caller named"
  assert_contains "$(cat "$other/tasks/b5/busy-state")" "source=crew-ext" \
    "the crew's own source is recorded"
  assert_absent "$FOREMAN_HOME/tasks/b5" "the ambient home is left alone"
  pass "an explicitly passed home is honoured, not the ambient one"
}

test_arm_mints_an_incarnation
test_apply_requires_the_current_generation
test_an_explicit_home_is_honoured
test_retire
test_busy_verdicts
