#!/usr/bin/env bash
# shellcheck disable=SC1010  # "done" is a subcommand argument here, not a loop terminator.
# crew-archive.test.sh - retiring a finished task out of the active set.
#
# Archiving never deletes: the task directory is moved intact, and the only
# destructive option (--worktree) refuses a dirty worktree unless forced.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_home >/dev/null
fm_git_isolate

ARCHIVE="$BIN/crew-archive.sh"
DEST="$FOREMAN_HOME/archive"

test_unfinished_work_is_not_archived() {
  fm_task a1 working >/dev/null
  if "$ARCHIVE" a1 >/dev/null 2>&1; then fail "a working task was archived"; fi
  assert_present "$FOREMAN_HOME/tasks/a1" "the task directory survives the refusal"
  pass "a running crew is not archived out from under itself"
}

test_review_needs_a_decision() {
  fm_task a2 review >/dev/null
  printf 'pr=5\n' >>"$FOREMAN_HOME/tasks/a2/meta"
  if "$ARCHIVE" a2 >/dev/null 2>&1; then fail "a review task was archived with its pull request open"; fi
  "$ARCHIVE" a2 --force >/dev/null
  assert_present "$DEST/a2" "an explicit force archives a review task"
  pass "an open pull request is held unless the captain forces it"
}

test_done_task_is_moved_intact() {
  fm_task a3 done >/dev/null
  printf 'the requirement\n' >"$FOREMAN_HOME/tasks/a3/task.md"
  local out
  out=$("$ARCHIVE" a3)
  assert_contains "$out" "archived a3" "archiving reports the move"
  assert_absent "$FOREMAN_HOME/tasks/a3" "the task leaves the active set"
  assert_present "$DEST/a3/task.md" "nothing is deleted"
  assert_equals "the requirement" "$(cat "$DEST/a3/task.md")" "the content is intact"
  pass "archiving moves the task, never deletes it"
}

test_an_existing_archive_entry_is_not_overwritten() {
  fm_task a4 done >/dev/null
  mkdir -p "$DEST/a4"
  if "$ARCHIVE" a4 >/dev/null 2>&1; then fail "an existing archive entry was overwritten"; fi
  assert_absent "$DEST/a4/status" "the previous archive entry is untouched"
  assert_present "$FOREMAN_HOME/tasks/a4" "the task stays put when it cannot be moved"
  pass "archiving never clobbers an earlier archive"
}

test_worktree_option_removes_the_worktree() {
  local proj wt
  proj="$FOREMAN_PROJECTS/archrepo"
  fm_git_repo "$proj" >/dev/null
  fm_task a5 done >/dev/null
  wt=$("$BIN/crew-worktree.sh" add archrepo a5)
  printf 'project=%s\nworktree=%s\n' "$proj" "$wt" >>"$FOREMAN_HOME/tasks/a5/meta"

  "$ARCHIVE" a5 --worktree >/dev/null
  assert_absent "$wt" "--worktree removes the crew's worktree"
  assert_present "$DEST/a5" "the task record is still archived"
  pass "--worktree cleans up isolation without losing the record"
}

test_busy_incarnation_is_retired() {
  fm_task a6 done >/dev/null
  "$BIN/crew-busy-event.sh" arm "$FOREMAN_HOME" a6 --state busy >/dev/null
  "$ARCHIVE" a6 >/dev/null
  assert_absent "$DEST/a6/busy-state" "the busy record is retired before archiving"
  assert_absent "$DEST/a6/busy-gen" "the incarnation token is retired too"
  pass "archiving retires the crew's busy incarnation"
}

test_todo_is_reconciled_before_the_move() {
  fm_task a7 done >/dev/null
  "$BIN/crew-todo.sh" add "archived work" >/dev/null
  "$BIN/crew-todo.sh" start 1 a7 >/dev/null
  "$ARCHIVE" a7 >/dev/null
  assert_equals "done" "$(awk -F'\t' '$1 == 1 { print $2 }' "$FOREMAN_HOME/todo.tsv")" \
    "the linked row settles while the crew record is still readable"
  pass "archiving reconciles the todo list first"
}

test_refusals() {
  if "$ARCHIVE" ghost >/dev/null 2>&1; then fail "archiving a missing task was accepted"; fi
  fm_task a8 done >/dev/null
  if "$ARCHIVE" a8 --bogus >/dev/null 2>&1; then fail "an unknown option was accepted"; fi
  pass "archiving is validated"
}

test_unfinished_work_is_not_archived
test_review_needs_a_decision
test_done_task_is_moved_intact
test_an_existing_archive_entry_is_not_overwritten
test_worktree_option_removes_the_worktree
test_busy_incarnation_is_retired
test_todo_is_reconciled_before_the_move
test_refusals
