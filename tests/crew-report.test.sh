#!/usr/bin/env bash
# shellcheck disable=SC1010  # "done" is a subcommand argument here, not a loop terminator.
# crew-report.test.sh - CREW SIDE. What a crew member can claim, and how the
# status cache is folded from those claims.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_home >/dev/null

REPORT="$BIN/crew-report.sh"
STATE=status
state_of() { sed -n 's/^state=//p' "$FOREMAN_HOME/tasks/$1/$STATE"; }
note_of() { sed -n 's/^note=//p' "$FOREMAN_HOME/tasks/$1/$STATE"; }
meta_of() { sed -n "s/^$2=//p" "$FOREMAN_HOME/tasks/$1/meta"; }

test_working_and_progress() {
  fm_task t1 queued >/dev/null
  "$REPORT" t1 working "picking up the task" >/dev/null
  assert_equals "working" "$(state_of t1)" "working sets the state"
  assert_equals "picking up the task" "$(note_of t1)" "working records its note"

  "$REPORT" t1 progress "half done" >/dev/null
  assert_equals "working" "$(state_of t1)" "progress never changes the state"
  assert_equals "picking up the task" "$(note_of t1)" "progress never overwrites the note"
  pass "working and progress are recorded without lying about state"
}

test_needs_decision_is_answered_by_key() {
  fm_task t2 working >/dev/null
  "$REPORT" t2 needs-decision "which database?" --key db_choice >/dev/null
  assert_equals "blocked" "$(state_of t2)" "an open decision blocks the task"
  assert_equals "[db_choice] which database?" "$(note_of t2)" "the board shows the key and the question"

  # The whole point of the key: a later unrelated append cannot bury it.
  "$REPORT" t2 working "kept going" >/dev/null
  assert_equals "blocked" "$(state_of t2)" "an unrelated append does not bury the decision"

  if "$REPORT" t2 needs-decision "no key here" >/dev/null 2>&1; then
    fail "needs-decision without a key was accepted"
  fi
  if "$REPORT" t2 working "x" --key stray_key >/dev/null 2>&1; then
    fail "--key outside needs-decision was accepted"
  fi
  if "$REPORT" t2 needs-decision "q" --key "bad key" >/dev/null 2>&1; then
    fail "a decision key with a space was accepted"
  fi
  # Keys end up in a tab-separated log; keep them bare. A UTF-8 collation range
  # would otherwise admit an accented character.
  if "$REPORT" t2 needs-decision "q" --key "café" >/dev/null 2>&1; then
    fail "a non-ASCII decision key was accepted"
  fi
  "$REPORT" t2 needs-decision "digits ok?" --key b1 >/dev/null
  assert_equals "blocked" "$(state_of t2)" "a key with digits is accepted"

  if "$REPORT" t2 nonsense "x" >/dev/null 2>&1; then fail "an unknown verb was accepted"; fi
  pass "a keyed decision stays open across unrelated appends"
}

test_review_carries_the_pull_request() {
  fm_task t3 working >/dev/null
  "$REPORT" t3 review "ready for the captain" --pr "https://example.test/o/r/pull/42" >/dev/null
  assert_equals "review" "$(state_of t3)" "review is a distinct state"
  assert_equals "https://example.test/o/r/pull/42" "$(meta_of t3 pr)" "the pull request url is recorded"
  assert_equals "42" "$(meta_of t3 pr_number)" "the pull request number is extracted"
  assert_equals "ready for the captain — PR https://example.test/o/r/pull/42" "$(note_of t3)" \
    "the url lands in the note the board shows"

  fm_task t4 working >/dev/null
  "$REPORT" t4 review --pr 7 >/dev/null
  assert_equals "PR 7" "$(note_of t4)" "without a summary the url is the whole note"
  assert_equals "7" "$(meta_of t4 pr)" "a bare number is stored as the reference"

  if "$REPORT" t4 working "x" --pr 7 >/dev/null 2>&1; then
    fail "--pr outside the review verb was accepted"
  fi
  pass "review records the exact pull request it is waiting on"
}

test_blocked_done_failed_stopped() {
  fm_task t5 working >/dev/null
  "$REPORT" t5 blocked "cannot reach the registry" >/dev/null
  assert_equals "blocked" "$(state_of t5)" "blocked records an obstacle"
  assert_equals "cannot reach the registry" "$(note_of t5)" "blocked keeps its reason"

  "$REPORT" t5 working "retrying" >/dev/null
  assert_equals "working" "$(state_of t5)" "a bare blocked is cleared by working"

  "$REPORT" t5 done "finished and merged" >/dev/null
  assert_equals "done" "$(state_of t5)" "done is terminal"

  fm_task t6 working >/dev/null
  "$REPORT" t6 failed "the build is broken" >/dev/null
  assert_equals "failed" "$(state_of t6)" "failed is recorded"

  fm_task t7 working >/dev/null
  "$REPORT" t7 stopped "paused by the captain" >/dev/null
  assert_equals "stopped" "$(state_of t7)" "stopped is a valid crew claim"
  pass "every ordinary verb folds into the status cache"
}

test_working_and_progress
test_needs_decision_is_answered_by_key
test_review_carries_the_pull_request
test_blocked_done_failed_stopped

# A crew that is finished stops what it started. This is the last moment the
# machine knows those processes are its: once the task is archived, a stray dev
# server is just an anonymous port.
test_finishing_verbs_need_a_clean_directory() {
  local root dir pid out
  root=$(fm_tmproot report-teardown)
  dir="$root/proj"
  mkdir -p "$dir"
  fm_task t9 working >/dev/null
  fm_task_field t9 cwd "$dir"

  pid=$(fm_stray "$dir" sleep 300)
  if out=$("$REPORT" t9 review "ready" 2>&1); then
    fail "a review was accepted while a process was still running"
  fi
  assert_contains "$out" "cannot report review yet" "the refusal names the report it refused"
  assert_contains "$out" "sleep 300" "and shows what is still running"
  assert_contains "$out" "crew_cleanup" "and how to stop it"
  assert_equals "working" "$(state_of t9)" "the refused report recorded nothing"

  # A crew must always be able to report an obstacle, whatever is running.
  "$REPORT" t9 blocked "waiting on CI" >/dev/null
  assert_equals "blocked" "$(state_of t9)" "blocked is never gated"

  "$BIN/crew-processes.sh" kill t9 >/dev/null
  out=$("$REPORT" t9 review "ready now")
  assert_contains "$out" "reported t9 review" "the report goes through once the directory is clean"
  if kill -0 "$pid" 2>/dev/null; then fail "the stray outlived the teardown"; fi
  pass "a review or done waits until the crew has stopped what it started"
}
