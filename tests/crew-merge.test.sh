#!/usr/bin/env bash
# crew-merge.test.sh - merging a crew member's pull request, on the captain's
# say-so.
#
# This tool exists separately from gh because it refuses everything except a
# task the captain has decided to merge: the state must be review, the pull
# request must be recorded, and the merge method must be one of three.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_home >/dev/null
fm_gh_stub >/dev/null
fm_git_isolate

MERGE="$BIN/crew-merge.sh"
state_of() { sed -n 's/^state=//p' "$FOREMAN_HOME/tasks/$1/status"; }
note_of() { sed -n 's/^note=//p' "$FOREMAN_HOME/tasks/$1/status"; }

review_task() { # <id> <pr>
  fm_task "$1" working >/dev/null
  printf 'pr=%s\nproject=%s\n' "$2" "$PWD" >>"$FOREMAN_HOME/tasks/$1/meta"
  "$BIN/crew-report.sh" "$1" review "ready" --pr "$2" >/dev/null
}

test_merge_requires_review() {
  fm_task m1 working >/dev/null
  if "$MERGE" m1 >/dev/null 2>&1; then fail "merging a task that is not in review was accepted"; fi
  fm_task m2 review >/dev/null
  if "$MERGE" m2 >/dev/null 2>&1; then fail "merging a review task with no pull request was accepted"; fi
  pass "only a review task with a recorded pull request can be merged"
}

test_merge_settles_the_task() {
  review_task m3 42
  local out
  out=$("$MERGE" m3)
  assert_equals "merged 42 (squash)" "$out" "the default method is squash"
  assert_equals "done" "$(state_of m3)" "a merged task is done"
  assert_contains "$(note_of m3)" "merged by the foreman: 42" "the settlement names the merge"
  assert_contains "$(fm_gh_calls)" "pr merge 42 --squash" "gh was asked for a squash merge"
  pass "a merge settles the task and uses the requested method"
}

test_methods() {
  review_task m4 43
  "$MERGE" m4 --method merge >/dev/null
  assert_contains "$(fm_gh_calls)" "pr merge 43 --merge" "a merge commit method is passed through"

  review_task m5 44
  "$MERGE" m5 --method rebase >/dev/null
  assert_contains "$(fm_gh_calls)" "pr merge 44 --rebase" "a rebase method is passed through"

  review_task m6 45
  if "$MERGE" m6 --method fast-forward >/dev/null 2>&1; then fail "an unknown merge method was accepted"; fi
  if "$MERGE" m6 --bogus >/dev/null 2>&1; then fail "an unknown option was accepted"; fi
  if "$MERGE" m6 --method >/dev/null 2>&1; then fail "--method with no value was accepted"; fi
  pass "the merge method is one of three"
}

test_failed_merge_is_visible() {
  review_task m7 46
  printf '1\n' >"$GH_STUB_STATE/merge-exit"
  if "$MERGE" m7 >/dev/null 2>&1; then fail "a failed gh merge reported success"; fi
  assert_equals "blocked" "$(state_of m7)" "a failed merge blocks the task"
  assert_contains "$(note_of m7)" "merge command failed for 46" "the blocker names the pull request"
  rm -f "$GH_STUB_STATE/merge-exit"
  pass "a failed merge becomes a visible blocker, never a silent success"
}

test_delete_branch_removes_the_worktree_first() {
  local proj
  proj="$FOREMAN_PROJECTS/mergerepo"
  fm_git_repo "$proj" --origin >/dev/null
  fm_task m8 working >/dev/null
  local wt
  wt=$("$BIN/crew-worktree.sh" add mergerepo m8)
  printf 'pr=47\nproject=%s\nworktree=%s\n' "$proj" "$wt" >>"$FOREMAN_HOME/tasks/m8/meta"
  "$BIN/crew-report.sh" m8 review "ready" --pr 47 >/dev/null

  "$MERGE" m8 --delete-branch >/dev/null
  assert_contains "$(fm_gh_calls)" "pr merge 47 --squash --delete-branch" "the delete flag reaches gh"
  assert_absent "$wt" "the worktree is removed before the branch is deleted"
  pass "--delete-branch removes the worktree before asking gh to delete the branch"
}

test_missing_gh_is_refused() {
  review_task m9 48
  if PATH=$(fm_path_without gh) "$MERGE" m9 >/dev/null 2>&1; then
    fail "a merge without gh was accepted"
  fi
  pass "a missing gh refuses the merge instead of pretending"
}

test_merge_requires_review
test_merge_settles_the_task
test_methods
test_failed_merge_is_visible
test_delete_branch_removes_the_worktree_first
test_missing_gh_is_refused
