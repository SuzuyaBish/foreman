#!/usr/bin/env bash
# shellcheck disable=SC1010  # "done" is a subcommand argument here, not a loop terminator.
# crew-recover.test.sh - reconciling the fleet after a crash or a restart.
#
# Recovery runs at session start and must never destroy anything: a scan only
# reports, and a relaunch puts a fresh agent back into the task's EXISTING
# worktree so its commits and uncommitted work survive.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_home >/dev/null
fm_herdr_stub >/dev/null

RECOVER="$BIN/crew-recover.sh"
state_of() { sed -n 's/^state=//p' "$FOREMAN_HOME/tasks/$1/status"; }
note_of() { sed -n 's/^note=//p' "$FOREMAN_HOME/tasks/$1/status"; }
meta_of() { sed -n "s/^$2=//p" "$FOREMAN_HOME/tasks/$1/meta"; }

test_an_empty_fleet_has_no_orphans() {
  local save out
  save="$FOREMAN_HOME"
  FOREMAN_HOME="$(fm_tmproot recover-empty)/home"
  export FOREMAN_HOME
  mkdir -p "$FOREMAN_HOME/tasks"
  out=$("$RECOVER")
  assert_equals "no orphaned crew" "$out" "nothing to reconcile says so"
  FOREMAN_HOME="$save"
  export FOREMAN_HOME
  pass "an empty fleet scans clean"
}

test_scan_reports_endpoints() {
  fm_task r1 working >/dev/null
  fm_attach_pane r1 >/dev/null
  local out
  out=$("$RECOVER")
  assert_contains "$out" "r1" "the task is listed"
  assert_contains "$out" "endpoint ok" "a live endpoint is healthy"

  fm_task r2 working >/dev/null
  local pane
  pane=$(fm_attach_pane r2)
  fm_herdr_kill_pane "$pane"
  out=$("$RECOVER")
  assert_contains "$out" "r2" "the orphan is listed"
  assert_contains "$out" "ORPHANED" "a lost endpoint while unfinished is an orphan"
  assert_contains "$out" "crew-recover.sh --relaunch r2" "the scan says how to fix it"
  pass "a scan separates healthy, settled and orphaned crew"
}

test_scan_classifies_settled_and_review() {
  fm_task r3 done >/dev/null
  fm_task r4 review >/dev/null
  printf 'pr=99\n' >>"$FOREMAN_HOME/tasks/r4/meta"
  "$BIN/crew-report.sh" r4 review "waiting" --pr 99 >/dev/null 2>&1 || true
  local out
  out=$("$RECOVER")
  assert_contains "$out" "endpoint gone (settled)" "a finished task with no endpoint is not an orphan"
  assert_contains "$out" "pull request 99 still open" "a review task names the pull request still holding it"
  pass "settled and review tasks are not mistaken for orphans"
}

test_scan_queue_appends_a_wake() {
  "$RECOVER" --queue >/dev/null
  assert_contains "$("$BIN/crew-queue.sh" list)" "r2 working endpoint gone" \
    "a queued scan records the orphan as a durable wake"
  pass "--queue makes an orphan visible without acting on it"
}

test_relaunch_reuses_the_existing_worktree() {
  fm_task n1 working >/dev/null
  local cwd gen_before
  cwd=$(fm_tmproot relaunch-cwd)
  printf 'seed brief\n' >"$FOREMAN_HOME/tasks/n1/brief.md"
  printf 'cwd=%s\nworktree=%s\n' "$cwd" "$cwd" >>"$FOREMAN_HOME/tasks/n1/meta"
  printf 'uncommitted work\n' >"$cwd/scratch.txt"
  "$BIN/crew-busy-event.sh" arm "$FOREMAN_HOME" n1 --state busy >/dev/null
  gen_before=$(cat "$FOREMAN_HOME/tasks/n1/busy-gen")

  local out
  out=$("$RECOVER" --relaunch n1)
  assert_contains "$out" "launched n1" "relaunch reports the launch"
  assert_contains "$(cat "$FOREMAN_HOME/tasks/n1/brief.md")" "Progress note" "the brief gains a recovery note"
  assert_contains "$(cat "$FOREMAN_HOME/tasks/n1/brief.md")" "recovery relaunch" "the note explains why"
  assert_equals "seed brief" "$(head -n 1 "$FOREMAN_HOME/tasks/n1/brief.md")" "the original brief is preserved"
  assert_equals "working" "$(state_of n1)" "a relaunched crew is working again"
  assert_equals "recovered" "$(note_of n1)" "the relaunch is recorded as a recovery"
  assert_present "$cwd/scratch.txt" "uncommitted work in the worktree survives"

  local gen_after
  gen_after=$(cat "$FOREMAN_HOME/tasks/n1/busy-gen")
  assert_not_equals "$gen_before" "$gen_after" "relaunch mints a fresh busy incarnation"
  assert_contains "$(cat "$FOREMAN_HOME/tasks/n1/busy-state")" "source=fm-recovery" "the busy record names recovery"

  local pane
  pane=$(meta_of n1 pane)
  assert_present "$HERDR_STUB_STATE/pane-${pane#*:}" "a new pane exists"
  pass "relaunch continues the same task in the same worktree"
}

test_relaunch_refuses_a_live_pane() {
  fm_task n2 working >/dev/null
  fm_attach_pane n2 >/dev/null
  local cwd
  cwd=$(fm_tmproot live-cwd)
  printf 'brief\n' >"$FOREMAN_HOME/tasks/n2/brief.md"
  printf 'cwd=%s\n' "$cwd" >>"$FOREMAN_HOME/tasks/n2/meta"

  if "$RECOVER" --relaunch n2 >/dev/null 2>&1; then
    fail "a second agent was launched into a reachable pane"
  fi
  "$RECOVER" --relaunch n2 --force >/dev/null
  assert_contains "$(cat "$FOREMAN_HOME/tasks/n2/brief.md")" "Progress note" "--force allows the override"
  pass "a reachable pane is never doubled up on without --force"
}

test_relaunch_requires_a_working_directory() {
  fm_task n3 working >/dev/null
  printf 'brief\n' >"$FOREMAN_HOME/tasks/n3/brief.md"
  printf 'cwd=%s\n' "/nonexistent-$$" >>"$FOREMAN_HOME/tasks/n3/meta"
  if "$RECOVER" --relaunch n3 >/dev/null 2>&1; then
    fail "relaunch into a missing directory was accepted"
  fi
  fm_task n4 working >/dev/null
  printf 'brief\n' >"$FOREMAN_HOME/tasks/n4/brief.md"
  if "$RECOVER" --relaunch n4 >/dev/null 2>&1; then
    fail "relaunch with no recorded directory was accepted"
  fi
  pass "a relaunch needs somewhere to work"
}

test_relaunch_continues_a_done_crew() {
  # A settled crew whose pane is gone is reused through recovery, not a fresh
  # spawn: the same task id and the same worktree, with its work intact.
  fm_task d1 done >/dev/null
  local cwd
  cwd=$(fm_tmproot done-cwd)
  printf 'original brief\n' >"$FOREMAN_HOME/tasks/d1/brief.md"
  printf 'cwd=%s\nworktree=%s\n' "$cwd" "$cwd" >>"$FOREMAN_HOME/tasks/d1/meta"
  printf 'uncommitted work\n' >"$cwd/scratch.txt"
  "$BIN/crew-busy-event.sh" arm "$FOREMAN_HOME" d1 --state busy >/dev/null

  local out
  out=$("$RECOVER" --relaunch d1)
  assert_contains "$out" "launched d1" "a done crew whose pane is gone relaunches in place"
  assert_equals "working" "$(state_of d1)" "the reused crew is working again"
  assert_equals "recovered" "$(note_of d1)" "the relaunch is recorded as a recovery"
  assert_contains "$(cat "$FOREMAN_HOME/tasks/d1/brief.md")" "Progress note" "the brief gains the recovery note"
  assert_equals "original brief" "$(head -n 1 "$FOREMAN_HOME/tasks/d1/brief.md")" "the original brief survives"
  assert_present "$cwd/scratch.txt" "uncommitted work survives reuse"
  pass "a done task is recoverable in its own worktree, under its own id"
}

test_an_empty_fleet_has_no_orphans
test_scan_reports_endpoints
test_scan_classifies_settled_and_review
test_scan_queue_appends_a_wake
test_relaunch_reuses_the_existing_worktree
test_relaunch_refuses_a_live_pane
test_relaunch_requires_a_working_directory
test_relaunch_continues_a_done_crew
