#!/usr/bin/env bash
# crew-worktree.test.sh - one isolated git worktree per crew member.
#
# Two crew members touching one repository is the collision this exists to
# prevent, so the branch and worktree must be created exactly once, and removal
# must never silently discard uncommitted work.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_home >/dev/null
fm_git_isolate

WT="$BIN/crew-worktree.sh"

test_add_creates_worktree_and_branch() {
  local proj out wt
  proj="$FOREMAN_PROJECTS/app"
  fm_git_repo "$proj" >/dev/null
  out=$("$WT" add app wt-1)
  wt="$FOREMAN_WORKTREES/wt-1"
  assert_equals "$wt" "$out" "add prints the worktree path"
  assert_present "$wt/.git" "the worktree exists"
  assert_equals "crew/wt-1" "$(git -C "$wt" rev-parse --abbrev-ref HEAD)" "the worktree is on the crew branch"
  assert_equals "$(git -C "$proj" rev-parse HEAD)" "$(git -C "$wt" rev-parse HEAD)" "the branch starts at the base"
  git -C "$proj" worktree list | grep -q "$wt" || fail "the project knows about the worktree"
  pass "add cuts a worktree on a dedicated branch"
}

test_add_can_start_from_another_base() {
  local proj out wt
  proj="$FOREMAN_PROJECTS/base"
  fm_git_repo "$proj" >/dev/null
  printf 'second\n' >"$proj/second.txt"
  git -C "$proj" add second.txt
  git -C "$proj" -c user.name=t -c user.email=t@e.test commit -qm second
  local first
  first=$(git -C "$proj" rev-parse HEAD~1)
  out=$("$WT" add base base-1 --base "$first")
  wt="$FOREMAN_WORKTREES/base-1"
  assert_equals "$first" "$(git -C "$wt" rev-parse HEAD)" "--base starts the worktree at the given commit"
  pass "--base is honoured"
}

test_add_is_single_use() {
  local proj
  proj="$FOREMAN_PROJECTS/once"
  fm_git_repo "$proj" >/dev/null
  "$WT" add once once-1 >/dev/null
  if "$WT" add once once-1 >/dev/null 2>&1; then fail "the same worktree was created twice"; fi

  # A leftover branch (from a removed worktree) is refused too: reusing the
  # task id would mix two tasks' commits.
  "$WT" remove once-1 >/dev/null
  if "$WT" add once once-1 >/dev/null 2>&1; then fail "a stale crew branch was reused"; fi
  pass "one id, one worktree, one branch"
}

test_add_refuses_bad_input() {
  local proj plain
  proj="$FOREMAN_PROJECTS/bad"
  fm_git_repo "$proj" >/dev/null
  if "$WT" add bad "Bad-Id" >/dev/null 2>&1; then fail "an invalid task id was accepted"; fi
  if "$WT" add nosuch some-id >/dev/null 2>&1; then fail "a missing project was accepted"; fi
  if "$WT" add bad some-id --base deadbeef >/dev/null 2>&1; then fail "an unresolvable base was accepted"; fi

  plain="$FOREMAN_PROJECTS/notgit"
  mkdir -p "$plain"
  if "$WT" add notgit plain-1 >/dev/null 2>&1; then
    fail "a non-git directory was accepted"
  fi
  pass "bad projects, ids and bases are refused"
}

test_add_warns_about_uncommitted_project_work() {
  local proj out err
  proj="$FOREMAN_PROJECTS/warnrepo"
  fm_git_repo "$proj" >/dev/null

  # A clean checkout has nothing the worktree would miss.
  err=$("$WT" add warnrepo clean-1 2>&1 >/dev/null)
  assert_equals "" "$err" "a clean checkout is not warned about"

  printf 'edited\n' >>"$proj/seed.txt"
  printf 'staged\n' >"$proj/staged.txt"
  git -C "$proj" add staged.txt
  printf 'new\n' >"$proj/untracked.txt"

  err=$("$WT" add warnrepo dirty-1 2>&1 >/dev/null)
  assert_contains "$err" "uncommitted work" "the warning names the problem"
  assert_contains "$err" "2 modified/staged, 1 untracked" "the warning counts what will be left behind"
  assert_contains "$err" "$proj" "the warning names the checkout"

  # The warning must not corrupt the machine-readable path on stdout.
  out=$("$WT" add warnrepo dirty-2 2>/dev/null)
  assert_equals "$FOREMAN_WORKTREES/dirty-2" "$out" "the warning stays on stderr"

  # And it is telling the truth: the worktree is cut from the commit.
  assert_absent "$FOREMAN_WORKTREES/dirty-1/untracked.txt" "untracked work is not carried"
  assert_absent "$FOREMAN_WORKTREES/dirty-1/staged.txt" "staged work is not carried"
  assert_equals "seed" "$(cat "$FOREMAN_WORKTREES/dirty-1/seed.txt")" "a modified file is at its committed content"

  # Untracked-only is called out without pretending files were edited.
  local proj2
  proj2="$FOREMAN_PROJECTS/untrackedrepo"
  fm_git_repo "$proj2" >/dev/null
  printf 'new\n' >"$proj2/untracked.txt"
  err=$("$WT" add untrackedrepo u-1 2>&1 >/dev/null)
  assert_contains "$err" "1 untracked" "an untracked-only checkout is reported"
  assert_not_contains "$err" "modified/staged" "no tracked edits are invented"
  pass "a worktree warns when it is cut from a checkout with uncommitted work"
}

test_add_warns_about_a_stale_base() {
  local proj err
  proj="$FOREMAN_PROJECTS/stale"
  fm_git_behind "$proj" "first missing" "second missing" >/dev/null

  err=$("$WT" add stale stale-1 2>&1 >/dev/null)
  assert_contains "$err" "2 commits behind" "the warning counts the missing commits"
  assert_contains "$err" "origin/" "the warning names the upstream"
  assert_contains "$err" "first missing" "the warning names one missing subject"
  assert_contains "$err" "second missing" "the warning names the other missing subject"
  assert_contains "$err" "sync the checkout before spawning" "the warning says what to do"
  # It warns, it does not refuse: a checkout that is behind on purpose still
  # hands the crew a worktree on the branch.
  assert_present "$FOREMAN_WORKTREES/stale-1/.git" "a stale base still gets a worktree"
  pass "a worktree cut from a base behind its upstream warns and names the commits"
}

test_add_stays_silent_when_the_base_is_not_stale() {
  local proj err plain base
  # No upstream at all: no remote, no tracking branch.
  proj="$FOREMAN_PROJECTS/quiet"
  fm_git_repo "$proj" >/dev/null
  err=$("$WT" add quiet quiet-1 2>&1 >/dev/null)
  assert_not_contains "$err" "older base" "a checkout with no upstream is not warned about"

  # A detached HEAD has no upstream to compare with, even in a repo that has one.
  proj="$FOREMAN_PROJECTS/detached"
  fm_git_behind "$proj" "missing work" >/dev/null
  git -C "$proj" checkout -q --detach
  err=$("$WT" add detached detached-1 2>&1 >/dev/null)
  assert_not_contains "$err" "older base" "a detached HEAD is not warned about"

  # An explicit --base opts out: the caller chose that base deliberately.
  proj="$FOREMAN_PROJECTS/pinned"
  fm_git_behind "$proj" "missing work" >/dev/null
  base=$(git -C "$proj" rev-parse HEAD)
  err=$("$WT" add pinned pinned-1 --base "$base" 2>&1 >/dev/null)
  assert_not_contains "$err" "older base" "an explicit --base is not second-guessed"

  # A plain non-git directory is refused before any base is considered.
  plain="$FOREMAN_PROJECTS/plain"
  mkdir -p "$plain"
  err=$("$WT" add plain plain-1 2>&1 >/dev/null || true)
  assert_not_contains "$err" "older base" "a non-git directory is not called stale"
  pass "no upstream, a detached HEAD, --base and a non-git dir all stay silent"
}

test_a_current_checkout_warns_only_about_dirty_work() {
  local proj err
  proj="$FOREMAN_PROJECTS/current"
  fm_git_behind "$proj" >/dev/null # tracks an upstream, but none is missing
  printf 'edited\n' >>"$proj/seed.txt"
  err=$("$WT" add current current-1 2>&1 >/dev/null)
  assert_contains "$err" "uncommitted work" "a dirty, current checkout still warns"
  assert_not_contains "$err" "older base" "a dirty, current checkout is not called stale"
  pass "a current checkout with uncommitted work gets only the dirty warning"
}

test_remove_protects_uncommitted_work() {
  local proj wt
  proj="$FOREMAN_PROJECTS/remove"
  fm_git_repo "$proj" >/dev/null
  wt=$("$WT" add remove rm-1)
  printf 'work in progress\n' >"$wt/wip.txt"

  if "$WT" remove rm-1 >/dev/null 2>&1; then fail "a dirty worktree was removed without --force"; fi
  assert_present "$wt/wip.txt" "the uncommitted file survives a refused removal"

  "$WT" remove rm-1 --force >/dev/null
  assert_absent "$wt" "the worktree is gone"
  assert_present "$proj/.git" "the project survives"
  pass "removal refuses dirty work unless forced"
}

test_remove_uses_recorded_metadata() {
  local proj wt
  proj="$FOREMAN_PROJECTS/meta"
  fm_git_repo "$proj" >/dev/null
  wt=$("$WT" add meta meta-1)
  # Remove the default path so only the task record can locate the worktree.
  fm_task meta-1 working >/dev/null
  printf 'worktree=%s\nproject=%s\n' "$wt" "$proj" >>"$FOREMAN_HOME/tasks/meta-1/meta"

  "$WT" remove meta-1 >/dev/null
  assert_absent "$wt" "the recorded worktree was found and removed"

  "$WT" remove meta-1 >/dev/null
  pass "removal locates the worktree from the task record and tolerates a missing one"
}

test_add_creates_worktree_and_branch
test_add_can_start_from_another_base
test_add_is_single_use
test_add_refuses_bad_input
test_add_warns_about_uncommitted_project_work
test_add_warns_about_a_stale_base
test_add_stays_silent_when_the_base_is_not_stale
test_a_current_checkout_warns_only_about_dirty_work
test_remove_protects_uncommitted_work
test_remove_uses_recorded_metadata
