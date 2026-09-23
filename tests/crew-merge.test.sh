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

# The exact message GitHub returns when the base branch moved between the
# mergeability check and the merge: a transient refusal it invites us to retry.
TRANSIENT_REASON='GraphQL: Base branch was modified. Review and try the merge again. (mergePullRequest)'
state_of() { sed -n 's/^state=//p' "$FOREMAN_HOME/tasks/$1/status"; }
note_of() { sed -n 's/^note=//p' "$FOREMAN_HOME/tasks/$1/status"; }

review_task() { # <id> <pr>
  fm_task "$1" working >/dev/null
  printf 'pr=%s\nproject=%s\n' "$2" "$PWD" >>"$FOREMAN_HOME/tasks/$1/meta"
  "$BIN/crew-report.sh" "$1" review "ready" --pr "$2" >/dev/null
}

# review_worktree_task <id> <project-name> <pr>: a review task with a real git
# worktree and a real commit on its branch, so a merge can be judged with git.
review_worktree_task() {
  local id=$1 proj=$2 pr=$3 wt
  fm_task "$id" working >/dev/null
  wt=$("$BIN/crew-worktree.sh" add "$proj" "$id")
  printf 'project=%s\nworktree=%s\n' "$FOREMAN_PROJECTS/$proj" "$wt" >>"$FOREMAN_HOME/tasks/$id/meta"
  printf 'work for %s\n' "$id" >"$wt/change.txt"
  git -C "$wt" add change.txt
  git -C "$wt" -c user.name=t -c user.email=t@e.test commit -qm "$id change"
  "$BIN/crew-report.sh" "$id" review "ready" --pr "$pr" >/dev/null
  printf '%s\n' "$wt"
}

test_delete_branch_refuses_a_dirty_worktree() {
  local proj wt before_calls
  proj="$FOREMAN_PROJECTS/dirtyrepo"
  fm_git_repo "$proj" --origin >/dev/null
  wt=$(review_worktree_task md dirtyrepo 52)
  printf 'uncommitted scratch\n' >"$wt/scratch.txt"
  before_calls=$(fm_gh_calls | wc -l | tr -d ' ')

  if "$MERGE" md --delete-branch >/dev/null 2>&1; then
    fail "merging with a dirty worktree was accepted"
  fi
  assert_present "$wt/scratch.txt" "the uncommitted work survives"
  assert_present "$wt/.git" "the worktree survives"
  git -C "$proj" show-ref --verify --quiet refs/heads/crew/md || fail "the branch survives"
  assert_equals "review" "$(state_of md)" "nothing was merged, so the task stays in review"
  assert_equals "$before_calls" "$(fm_gh_calls | wc -l | tr -d ' ')" "gh was never asked to merge"

  # Once the work is dealt with, the same merge goes through.
  rm -f "$wt/scratch.txt"
  "$MERGE" md --delete-branch >/dev/null
  assert_absent "$wt" "the clean worktree is removed"
  assert_equals "done" "$(state_of md)" "the retried merge settles the task"
  pass "--delete-branch will not discard uncommitted work to get the merge"
}

test_failed_merge_leaves_the_work_untouched() {
  local proj wt before
  proj="$FOREMAN_PROJECTS/conflictrepo"
  fm_git_repo "$proj" --origin >/dev/null
  wt=$(review_worktree_task mf conflictrepo 53)
  before=$(git -C "$proj" rev-parse refs/heads/crew/mf)

  # A merge gh refuses (the crude conflict path) must be visible and harmless.
  printf '1\n' >"$GH_STUB_STATE/merge-exit"
  if "$MERGE" mf >/dev/null 2>&1; then fail "a failed gh merge reported success"; fi
  assert_equals "blocked" "$(state_of mf)" "a failed merge blocks the task"
  assert_contains "$(note_of mf)" "merge command failed for 53" "the blocker names the pull request"
  assert_present "$wt/change.txt" "the crew's commit survives a failed merge"
  assert_present "$wt/.git" "the worktree survives a failed merge"
  assert_equals "$before" "$(git -C "$proj" rev-parse refs/heads/crew/mf)" \
    "the branch tip is unchanged by a failed merge"
  assert_equals "" "$(git -C "$wt" status --porcelain)" "the worktree is still clean and usable"

  # The captain resolves whatever gh needed; the task must be put back into
  # review (a failed merge blocks it), and then the merge succeeds.
  rm -f "$GH_STUB_STATE/merge-exit"
  "$BIN/crew-report.sh" mf review "conflict resolved, re-merging" >/dev/null
  "$MERGE" mf --delete-branch >/dev/null
  assert_equals "done" "$(state_of mf)" "a retried merge settles the task"
  assert_absent "$wt" "the worktree is only removed by the successful merge"
  pass "a failed merge is non-destructive and can be retried"
}

test_delete_branch_tolerates_a_missing_worktree() {
  local proj wt
  proj="$FOREMAN_PROJECTS/gonerepo"
  fm_git_repo "$proj" --origin >/dev/null
  wt=$(review_worktree_task mg gonerepo 54)
  "$BIN/crew-worktree.sh" remove mg >/dev/null
  assert_absent "$wt" "the worktree was removed before the merge"

  "$MERGE" mg --delete-branch >/dev/null
  assert_equals "done" "$(state_of mg)" "a merge with no worktree left still settles"
  assert_contains "$(fm_gh_calls)" "pr merge 54 --squash --delete-branch" "the delete flag still reaches gh"
  pass "a merge does not require the worktree to still exist"
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

test_failed_merge_keeps_gh_reason() {
  review_task m10 49
  printf '2\n' >"$GH_STUB_STATE/merge-exit"
  # gh is chatty and multi-line; the note must carry the reason, intact and on
  # one line, because the events log it lands in is tab separated.
  printf 'X Pull request is not mergeable: the base branch has conflicts\n  try resolving them first\n' \
    >"$GH_STUB_STATE/merge-reason"
  "$MERGE" m10 >/dev/null 2>&1 || true
  local note
  note=$(note_of m10)
  assert_contains "$note" "not mergeable" "the blocker carries gh's own reason"
  assert_contains "$note" "base branch has conflicts" "the whole reason survives, not just the first word"
  assert_equals "1" "$(printf '%s\n' "$note" | wc -l | tr -d ' ')" "the note is one line"
  assert_equals "4" "$(awk -F'\t' 'END { print NF }' "$FOREMAN_HOME/tasks/m10/events")" \
    "the events record still has exactly four fields"
  assert_equals "blocked" "$(state_of m10)" "the fold still reads the record"
  rm -f "$GH_STUB_STATE/merge-exit" "$GH_STUB_STATE/merge-reason"
  pass "a failed merge says why, on one line"
}

test_transient_refusal_is_retried_without_waking_the_crew() {
  local proj wt merges_before
  proj="$FOREMAN_PROJECTS/retryrepo"
  fm_git_repo "$proj" --origin >/dev/null
  wt=$(review_worktree_task mr retryrepo 60)
  merges_before=$(fm_gh_calls | grep -c 'pr merge 60' || true)

  # gh refuses the first attempt with GitHub's base-branch-moved message and
  # accepts the second.
  printf '1\n0\n' >"$GH_STUB_STATE/merge-exit-seq"
  printf '%s\n' "$TRANSIENT_REASON" >"$GH_STUB_STATE/merge-reason"

  FOREMAN_MERGE_ATTEMPTS=3 FOREMAN_MERGE_RETRY_SLEEP=0 \
    "$MERGE" mr --delete-branch >/dev/null

  assert_equals "done" "$(state_of mr)" "the retried merge settles the task"
  assert_equals "2" "$(( $(fm_gh_calls | grep -c 'pr merge 60') - merges_before ))" \
    "gh was asked to merge twice, inside one crew-free command"
  assert_equals "0" "$(awk -F'\t' '$2 == "blocked"' "$FOREMAN_HOME/tasks/mr/events" | wc -l | tr -d ' ')" \
    "the transient refusal never blocked the crew, so no wake is owed"
  assert_absent "$wt" "the successful retry removes the worktree like any merge"
  rm -f "$GH_STUB_STATE/merge-exit-seq" "$GH_STUB_STATE/merge-reason"
  pass "a transient merge refusal is retried in-command and settles merged"
}

test_stubborn_transient_refusal_stays_in_review() {
  local proj wt
  proj="$FOREMAN_PROJECTS/stubbornrepo"
  fm_git_repo "$proj" --origin >/dev/null
  wt=$(review_worktree_task mst stubbornrepo 61)

  # Every attempt is refused with the transient message.
  printf '1\n' >"$GH_STUB_STATE/merge-exit"
  printf '%s\n' "$TRANSIENT_REASON" >"$GH_STUB_STATE/merge-reason"

  if FOREMAN_MERGE_ATTEMPTS=2 FOREMAN_MERGE_RETRY_SLEEP=0 \
    "$MERGE" mst >/dev/null 2>&1; then
    fail "a stubborn transient refusal reported success"
  fi
  assert_equals "review" "$(state_of mst)" "a transient refusal leaves the task in review, not blocked"
  assert_equals "0" "$(awk -F'\t' '$2 == "blocked"' "$FOREMAN_HOME/tasks/mst/events" | wc -l | tr -d ' ')" \
    "a transient refusal does not block the crew"
  assert_contains "$(cat "$FOREMAN_HOME/tasks/mst/events")" "still in review" \
    "the record says the merge was refused transiently"
  assert_present "$wt/change.txt" "the crew's commit survives the refusal"
  assert_equals "" "$(git -C "$wt" status --porcelain)" "the worktree is still clean and usable"

  # The captain just runs the merge again; the crew is never asked to report
  # review a second time.
  rm -f "$GH_STUB_STATE/merge-exit" "$GH_STUB_STATE/merge-reason"
  "$MERGE" mst --delete-branch >/dev/null
  assert_equals "done" "$(state_of mst)" "a re-invoked merge succeeds with no crew turn"
  assert_absent "$wt" "the worktree is removed only by the successful merge"
  pass "a stubborn transient refusal stays in review and is re-invokable without the crew"
}

test_real_conflict_still_blocks() {
  local merges_before
  review_task mconf 62
  merges_before=$(fm_gh_calls | grep -c 'pr merge 62' || true)
  printf '1\n' >"$GH_STUB_STATE/merge-exit"
  printf 'X Pull request is not mergeable: the base branch has conflicts\n' \
    >"$GH_STUB_STATE/merge-reason"

  if "$MERGE" mconf >/dev/null 2>&1; then fail "a conflicting merge reported success"; fi
  assert_equals "blocked" "$(state_of mconf)" "a real conflict still blocks the crew"
  assert_contains "$(note_of mconf)" "merge command failed for 62" "the blocker names the pull request"
  assert_equals "1" "$(( $(fm_gh_calls | grep -c 'pr merge 62') - merges_before ))" \
    "a real conflict is not retried"
  rm -f "$GH_STUB_STATE/merge-exit" "$GH_STUB_STATE/merge-reason"
  pass "a real conflict is never retried and blocks as before"
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
test_failed_merge_keeps_gh_reason
test_transient_refusal_is_retried_without_waking_the_crew
test_stubborn_transient_refusal_stays_in_review
test_real_conflict_still_blocks
test_delete_branch_removes_the_worktree_first
test_delete_branch_refuses_a_dirty_worktree
test_failed_merge_leaves_the_work_untouched
test_delete_branch_tolerates_a_missing_worktree
test_missing_gh_is_refused
