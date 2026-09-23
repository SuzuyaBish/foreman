#!/usr/bin/env bash
# crew-pr.test.sh - recording a pull request, and reading whether it landed.
#
# A crew member's work is not delivered until its pull request is merged, so the
# task is held in `review` and only a merge or close settles it. Everything here
# runs against a stubbed gh, never a real repository.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_home >/dev/null
fm_gh_stub >/dev/null
fm_git_isolate

PR="$BIN/crew-pr.sh"
CHECK="$BIN/crew-pr-check.sh"
meta_of() { sed -n "s/^$2=//p" "$FOREMAN_HOME/tasks/$1/meta"; }
state_of() { sed -n 's/^state=//p' "$FOREMAN_HOME/tasks/$1/status"; }
note_of() { sed -n 's/^note=//p' "$FOREMAN_HOME/tasks/$1/status"; }

test_record_a_number() {
  fm_task p1 working >/dev/null
  local out
  out=$("$PR" p1 42)
  assert_contains "$out" "recorded PR 42" "recording reports the reference"
  assert_equals "42" "$(meta_of p1 pr)" "the reference is stored"
  assert_equals "review" "$(state_of p1)" "recording a pull request moves the task to review"
  assert_equals "PR open: 42" "$(note_of p1)" "the default note names the pull request"
  pass "a bare pull request number is recorded"
}

test_record_a_url() {
  fm_task p2 working >/dev/null
  "$PR" p2 "https://example.test/o/r/pull/9" >/dev/null
  assert_equals "https://example.test/o/r/pull/9" "$(meta_of p2 pr)" "the url is stored"
  assert_equals "9" "$(meta_of p2 pr_number)" "the number is extracted from the url"

  fm_task p3 working >/dev/null
  "$PR" p3 7 "handles the empty case" >/dev/null
  assert_equals "handles the empty case" "$(note_of p3)" "an explicit note is kept"
  pass "a pull request url or note is recorded as given"
}

test_record_refusals() {
  fm_task p4 working >/dev/null
  if "$PR" p4 not-a-reference >/dev/null 2>&1; then fail "a non-url, non-number reference was accepted"; fi
  if "$PR" p4 >/dev/null 2>&1; then fail "an empty reference was accepted"; fi
  if "$PR" ghost 1 >/dev/null 2>&1; then fail "recording against a missing task was accepted"; fi
  pass "references are validated"
}

test_check_no_pull_request() {
  fm_task c1 working >/dev/null
  assert_equals "no-pr" "$("$CHECK" c1)" "a task with no pull request says so"
  pass "a task without a pull request is not invented one"
}

test_check_settles_on_merge_or_close() {
  local proj
  proj=$(fm_tmproot pr-proj)
  fm_task c2 review >/dev/null
  printf 'pr=42\nproject=%s\n' "$proj" >>"$FOREMAN_HOME/tasks/c2/meta"

  fm_gh_pr_state MERGED
  assert_equals "merged" "$("$CHECK" c2)" "a merged pull request reads merged"
  assert_equals "done" "$(state_of c2)" "a merge settles the task to done"
  assert_contains "$(note_of c2)" "PR merged: 42" "the settlement records the merge"

  fm_task c3 review >/dev/null
  printf 'pr=43\nproject=%s\n' "$proj" >>"$FOREMAN_HOME/tasks/c3/meta"
  fm_gh_pr_state CLOSED
  assert_equals "closed" "$("$CHECK" c3)" "a closed pull request reads closed"
  assert_equals "done" "$(state_of c3)" "a close without a merge still releases the task"
  pass "merge and close are the only ways out of review"
}

test_check_leaves_open_work_in_review() {
  local proj
  proj=$(fm_tmproot pr-proj2)
  fm_task c4 review >/dev/null
  printf 'pr=44\nproject=%s\n' "$proj" >>"$FOREMAN_HOME/tasks/c4/meta"
  fm_gh_pr_state OPEN
  assert_equals "open" "$("$CHECK" c4)" "an open pull request reads open"
  assert_equals "review" "$(state_of c4)" "an open pull request still owns the worktree"

  fm_gh_pr_state OPEN true
  assert_equals "draft" "$("$CHECK" c4)" "a draft is distinguished from a ready pull request"
  assert_equals "review" "$(state_of c4)" "a draft does not settle the task"
  pass "open work stays in review"
}

test_check_degrades_honestly() {
  local proj
  proj=$(fm_tmproot pr-proj3)
  fm_task c5 review >/dev/null
  printf 'pr=45\nproject=%s\n' "$proj" >>"$FOREMAN_HOME/tasks/c5/meta"

  # gh cannot read the pull request: say so rather than guess.
  rm -f "$GH_STUB_STATE/pr.json"
  assert_contains "$("$CHECK" c5)" "unknown (gh could not read 45)" "an unreadable pull request reads unknown"

  printf '{"state":"WEIRD","isDraft":false}\n' >"$GH_STUB_STATE/pr.json"
  assert_contains "$("$CHECK" c5)" "unrecognized state: WEIRD" "an unknown state is surfaced verbatim"

  # With no gh at all, the verdict is unknown, never a false settled state.
  assert_contains "$(PATH=$(fm_path_without gh) "$CHECK" c5)" "gh is not on PATH" "a missing gh reads unknown"
  assert_equals "review" "$(state_of c5)" "a missing gh cannot settle the task"
  pass "an unreadable pull request is reported as unknown"
}

test_record_a_number
test_record_a_url
test_record_refusals
test_check_no_pull_request
test_check_settles_on_merge_or_close
test_check_leaves_open_work_in_review
test_check_degrades_honestly
