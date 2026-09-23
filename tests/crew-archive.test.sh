#!/usr/bin/env bash
# shellcheck disable=SC1010  # "done" is a subcommand argument here, not a loop terminator.
# crew-archive.test.sh - retiring a finished task out of the active set.
#
# Archiving never deletes: the task directory is moved intact, and the only
# destructive option (--worktree) refuses a dirty worktree unless forced.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_home >/dev/null
fm_herdr_stub >/dev/null
fm_git_isolate

ARCHIVE="$BIN/crew-archive.sh"
DEST="$FOREMAN_HOME/archive"

# attach_own_workspace <id> [state]: a task whose endpoint is a workspace this
# foreman created for it, with its pane registered in that workspace, exactly as
# a launch leaves it. Prints the pane id.
attach_own_workspace() {
  local id=$1 state=${2:-done} out ws tab pane
  fm_task "$id" "$state" >/dev/null
  fm_herdr_seed_workspace ws-parent skills
  out=$(herdr --session "${FOREMAN_SESSION:-default}" workspace create \
    --label "└ $id" --cwd /tmp --no-focus)
  ws=$(printf '%s' "$out" | jq -r '.result.workspace.workspace_id')
  tab=$(printf '%s' "$out" | jq -r '.result.tab.tab_id')
  pane=$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id')
  {
    printf 'workspace=%s\nparent_workspace=ws-parent\n' "$ws"
    printf 'tab=%s\npane=%s:%s\n' "$tab" "${FOREMAN_SESSION:-default}" "$pane"
  } >>"$FOREMAN_HOME/tasks/$id/meta"
  printf '%s\n' "$pane"
}

workspace_of() { sed -n 's/^workspace=//p' "$FOREMAN_HOME/tasks/$1/meta" | head -1; }

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

test_archiving_closes_the_crews_workspace() {
  local pane ws out
  pane=$(attach_own_workspace a9)
  ws=$(workspace_of a9)
  out=$("$ARCHIVE" a9)
  assert_contains "$out" "archived a9" "archiving still reports the move"
  assert_contains "$out" "closed its workspace" "archiving reports the close"
  assert_contains "$(fm_herdr_calls)" "workspace close $ws" "the crew's workspace was the target"
  assert_absent "$HERDR_STUB_STATE/pane-$pane" "the pane goes with the workspace"
  assert_present "$DEST/a9" "the task record is still archived"
  pass "archiving retires the terminal the crew lived in"
}

test_a_task_with_no_endpoint_reports_nothing_to_close() {
  local out
  fm_task a10 done >/dev/null
  out=$("$ARCHIVE" a10)
  assert_contains "$out" "archived a10" "the move is reported"
  assert_contains "$out" "nothing was left to close" "no endpoint is reported plainly"
  assert_present "$DEST/a10" "the record is still archived"
  pass "a task with no endpoint archives without inventing a close"
}

test_an_unreachable_herdr_never_blocks_the_archive() {
  local pane out
  pane=$(attach_own_workspace a11)
  out=$(PATH=$(fm_path_without herdr) "$ARCHIVE" a11)
  assert_contains "$out" "archived a11" "the archive still happens"
  assert_contains "$out" "could not close its terminal" "the failed close is reported, not invented"
  assert_present "$DEST/a11" "the record is moved despite the close"
  assert_present "$HERDR_STUB_STATE/pane-$pane" "nothing was invented as closed"
  pass "a Herdr that cannot be reached never blocks the archive"
}

test_force_archiving_a_review_task_closes_its_home() {
  local pane out
  pane=$(attach_own_workspace a12 review)
  printf 'pr=5\n' >>"$FOREMAN_HOME/tasks/a12/meta"
  out=$("$ARCHIVE" a12 --force)
  assert_contains "$out" "closed its workspace" "an explicitly retired review task closes too"
  assert_absent "$HERDR_STUB_STATE/pane-$pane" "its pane is gone"
  assert_present "$DEST/a12" "the record is archived"
  pass "force-retiring a review task retires its terminal"
}

test_keep_home_archives_without_closing() {
  local pane ws out
  pane=$(attach_own_workspace a13)
  ws=$(workspace_of a13)
  out=$("$ARCHIVE" a13 --keep-home)
  assert_contains "$out" "kept its terminal" "the escape hatch is reported"
  assert_present "$HERDR_STUB_STATE/pane-$pane" "the pane survives"
  assert_not_contains "$(fm_herdr_calls)" "workspace close $ws" "no close was attempted"
  assert_present "$DEST/a13" "the task is still archived"
  pass "--keep-home archives while leaving the terminal alone"
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
test_archiving_closes_the_crews_workspace
test_a_task_with_no_endpoint_reports_nothing_to_close
test_an_unreachable_herdr_never_blocks_the_archive
test_force_archiving_a_review_task_closes_its_home
test_keep_home_archives_without_closing
test_refusals
