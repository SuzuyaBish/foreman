#!/usr/bin/env bash
# crew-workspace.test.sh - how a crew member appears in Herdr.
#
# Herdr has no parent/child relationship between panes or agents: `agent list`
# carries parent_pane_id/parent_agent_id/depth, but nothing can set them and no
# CLI or socket method exposes one. What Herdr does offer is workspace ordering.
# So a crew member reads as a subordinate of the foreman by *being* a workspace,
# labelled with a child glyph and moved directly after the foreman's own. This
# file pins that: the label, the recorded parent, the exact insert index, the
# adoption of an existing workspace on relaunch, and the fact that ordering is
# presentation only -- a refused move must still leave the crew running.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_home >/dev/null
fm_herdr_stub >/dev/null
fm_pi_stub >/dev/null
fm_git_isolate

SPAWN="$BIN/crew-spawn.sh"
LAUNCH="$BIN/crew-launch.sh"
STOP="$BIN/crew-stop.sh"
TASKDIR="$FOREMAN_HOME/tasks"

meta_of() { sed -n "s/^$2=//p" "$TASKDIR/$1/meta" 2>/dev/null | head -1; }
move_index() { # <workspace-id> -> the index the launch asked for
  awk -F'\t' -v w="$1" '$2 == w { print $3 }' <<<"$(fm_herdr_moves)"
}
workspace_creates() { fm_herdr_calls | grep -c "workspace create" || true; }

# fresh_herdr: a Herdr of this test's own. Every test below needs a clean
# workspace list, a clean call log, and no leftover failure flags.
fresh_herdr() { fm_herdr_stub >/dev/null; }

# attach <id>: a task record that names a workspace as a child of another, the
# way a live crew's meta does. Ordering is computed from these records, never
# from label patterns.
attach() { # <id> <workspace> <parent>
  fm_task "$1" working >/dev/null
  printf 'workspace=%s\nparent_workspace=%s\n' "$2" "$3" >>"$TASKDIR/$1/meta"
}

test_a_crew_gets_its_own_workspace_after_its_parent() {
  local dir ws idx
  dir=$(fm_tmproot ws-order)
  fresh_herdr
  HERDR_WORKSPACE_ID=ws-parent HERDR_SESSION=default
  export HERDR_WORKSPACE_ID HERDR_SESSION
  fm_herdr_seed_workspace ws-parent skills
  # Two existing siblings already sit directly under the parent; the third
  # workspace belongs to somebody else and must not be crossed.
  fm_herdr_seed_workspace ws-child-a "└ a"
  fm_herdr_seed_workspace ws-child-b "└ b"
  fm_herdr_seed_workspace ws-unrelated other
  attach rec-a ws-child-a ws-parent
  attach rec-b ws-child-b ws-parent

  "$SPAWN" ordered-crew "$dir" task >/dev/null
  ws=$(meta_of ordered-crew workspace)
  [ -n "$ws" ] || fail "the launch recorded no workspace"
  [ "$ws" != "ws-parent" ] || fail "the crew landed in the foreman's own workspace"
  assert_equals "ws-parent" "$(meta_of ordered-crew parent_workspace)" "the parent is recorded"
  assert_contains "$(fm_herdr_calls)" "--label └ ordered-crew" "the workspace label reads as a child"
  assert_contains "$(fm_herdr_calls)" "tab rename" "the seeded tab is named for the crew"

  # parent(0) child-a(1) child-b(2) unrelated(3) new(4) -> insert at 3, which is
  # immediately after the parent's contiguous child block and before `other`.
  idx=$(move_index "$ws")
  [ -n "$idx" ] || fail "the launch never asked for a move (moves: $(fm_herdr_moves))"
  assert_equals "3" "$idx" "the workspace is moved past the parent's existing children"
  pass "a crew workspace is labelled as a child and moved after its parent's block"
}

test_a_refused_move_is_only_presentation() {
  local dir ws
  dir=$(fm_tmproot ws-nomove)
  fresh_herdr
  HERDR_WORKSPACE_ID=ws-parent2 HERDR_SESSION=default
  export HERDR_WORKSPACE_ID HERDR_SESSION
  fm_herdr_seed_workspace ws-parent2 skills
  fm_herdr_mover_fail

  if ! out=$("$SPAWN" stuck-order "$dir" task 2>&1); then
    fail "a refused move failed the launch: $out"
  fi
  assert_contains "$out" "stays where Herdr put it" "the refusal is reported, not hidden"
  ws=$(meta_of stuck-order workspace)
  assert_contains "$(fm_herdr_calls)" "workspace create" "the crew still got its own workspace"
  assert_equals "working" "$(sed -n 's/^state=//p' "$TASKDIR/stuck-order/status")" \
    "the crew is running despite the refused move"
  assert_contains "$(fm_herdr_pane_runs)" "$(meta_of stuck-order pane | sed 's/^[^:]*://')" \
    "the launch command still reached the pane"
  pass "ordering is presentation only: a refused move leaves the crew running"
}

test_a_relaunch_adopts_the_existing_workspace() {
  local dir before ws
  dir=$(fm_tmproot ws-adopt)
  fresh_herdr
  HERDR_WORKSPACE_ID=ws-parent3 HERDR_SESSION=default
  export HERDR_WORKSPACE_ID HERDR_SESSION
  fm_herdr_seed_workspace ws-parent3 skills

  "$SPAWN" adopted "$dir" task >/dev/null
  ws=$(meta_of adopted workspace)
  before=$(workspace_creates)
  assert_equals "1" "$before" "the first launch created one workspace"

  # Recovery relaunches the same task. It must return to its own workspace, not
  # litter a second one beside it.
  "$LAUNCH" adopted "$dir" --note "relaunched after a lost endpoint" >/dev/null
  assert_equals "$before" "$(workspace_creates)" "the relaunch created no second workspace"
  assert_equals "$ws" "$(meta_of adopted workspace)" "the task kept its workspace"
  assert_contains "$(fm_herdr_calls)" "tab create --workspace $ws" "the relaunch added a tab to it"
  pass "a relaunch adopts the task's existing workspace"
}

test_the_label_leads_with_the_item_number() {
  local dir seq
  dir=$(fm_tmproot ws-number)
  fresh_herdr
  HERDR_WORKSPACE_ID=ws-parent7 HERDR_SESSION=default
  export HERDR_WORKSPACE_ID HERDR_SESSION
  fm_herdr_seed_workspace ws-parent7 skills
  "$BIN/crew-todo.sh" add --project proj "label the crew" >/dev/null
  seq=$(cut -f1 "$FOREMAN_HOME/todo.tsv" | tail -1)

  "$SPAWN" numbered-crew "$dir" --todo "$seq" task >/dev/null
  assert_contains "$(fm_herdr_calls)" "--label └ #$seq numbered-crew" \
    "the workspace label leads with the item number"
  pass "a linked crew's workspace label starts with its todo number"
}

test_the_board_supplies_the_number_without_a_flag() {
  # No spawn flag: the number is read from the board, which is how a recovery
  # relaunch - it passes no flag either - still gets the number.
  local dir seq
  dir=$(fm_tmproot ws-board)
  fresh_herdr
  HERDR_WORKSPACE_ID=ws-parent9 HERDR_SESSION=default
  export HERDR_WORKSPACE_ID HERDR_SESSION
  fm_herdr_seed_workspace ws-parent9 skills
  "$BIN/crew-todo.sh" add --project proj "board supplies the number" >/dev/null
  seq=$(cut -f1 "$FOREMAN_HOME/todo.tsv" | tail -1)
  "$BIN/crew-todo.sh" start "$seq" board-crew >/dev/null

  "$SPAWN" board-crew "$dir" task >/dev/null
  assert_contains "$(fm_herdr_calls)" "--label └ #$seq board-crew" \
    "a launch with no flag reads the number from the board"
  pass "the board supplies the number when no spawn flag is passed"
}

test_an_unlinked_crew_keeps_the_plain_label() {
  local dir
  dir=$(fm_tmproot ws-plain)
  fresh_herdr
  HERDR_WORKSPACE_ID=ws-parent10 HERDR_SESSION=default
  export HERDR_WORKSPACE_ID HERDR_SESSION
  fm_herdr_seed_workspace ws-parent10 skills

  "$SPAWN" plain-crew "$dir" task >/dev/null
  assert_contains "$(fm_herdr_calls)" "--label └ plain-crew" \
    "no linked item keeps today's id-only label"
  pass "an unlinked crew's workspace label is unchanged"
}

test_close_retires_the_workspace_not_the_parent() {
  local dir ws
  dir=$(fm_tmproot ws-close)
  fresh_herdr
  HERDR_WORKSPACE_ID=ws-parent4 HERDR_SESSION=default
  export HERDR_WORKSPACE_ID HERDR_SESSION
  fm_herdr_seed_workspace ws-parent4 skills

  "$SPAWN" retiring "$dir" task >/dev/null
  ws=$(meta_of retiring workspace)
  assert_equals "1" "$(fm_herdr_workspace_panes "$ws" | grep -c . | tr -d ' ')" "the crew pane lives in its workspace"

  local out
  out=$("$STOP" retiring --close --reason "done" 2>&1)
  assert_contains "$out" "closed its workspace" "the stop says what it closed"
  assert_equals "" "$(fm_herdr_workspace_panes "$ws")" "its workspace is emptied"
  if fm_herdr_calls | grep -q "^workspace close ws-parent4"; then
    fail "the foreman's own workspace was closed"
  fi
  # The parent workspace survives, which is what makes this safe to run.
  assert_equals "0" "$(fm_herdr_calls | grep -c '^workspace close ws-parent4' || true)" \
    "the foreman's workspace is never the one closed"
  pass "closing a crew retires its own workspace and never the foreman's"
}

test_an_older_record_never_closes_the_foremans_workspace() {
  # Records written before crew got workspaces of their own name the foreman's
  # own workspace and no parent. Closing "its workspace" would close the
  # captain's.
  local dir out
  dir=$(fm_tmproot ws-legacy)
  fresh_herdr
  HERDR_WORKSPACE_ID=ws-parent6 HERDR_SESSION=default
  export HERDR_WORKSPACE_ID HERDR_SESSION
  fm_herdr_seed_workspace ws-parent6 skills
  fm_task legacy-crew working >/dev/null
  printf 'workspace=ws-parent6\ntab=tab-old\npane=default:pane-old\n' >>"$TASKDIR/legacy-crew/meta"
  printf 'tab=tab-old\ncwd=/\nlabel=crew-legacy-crew\n' >"$HERDR_STUB_STATE/pane-pane-old"

  out=$("$STOP" legacy-crew --close --reason "done" 2>&1)
  assert_contains "$out" "closed its tab" "an older record closes its tab, not a workspace"
  assert_equals "0" "$(fm_herdr_calls | grep -c 'workspace close ws-parent6' || true)" \
    "the foreman's own workspace was never a close target"
  pass "a record from before crew workspaces cannot close the foreman's own workspace"
}

test_a_herdr_without_workspace_create_falls_back() {
  local dir out
  dir=$(fm_tmproot ws-flat)
  fresh_herdr
  HERDR_WORKSPACE_ID=ws-parent5 HERDR_SESSION=default
  export HERDR_WORKSPACE_ID HERDR_SESSION
  fm_herdr_seed_workspace ws-parent5 skills
  fm_herdr_workspace_create_fail

  out=$("$SPAWN" flat-crew "$dir" task 2>&1) || fail "the fallback launch failed: $out"
  assert_contains "$out" "launched flat-crew" "the crew is launched anyway"
  assert_equals "ws-parent5" "$(meta_of flat-crew workspace)" "it falls back to the foreman's workspace"
  assert_contains "$(fm_herdr_calls)" "tab create --workspace ws-parent5" "it gets a plain tab instead"

  out=$("$STOP" flat-crew --close --reason "done" 2>&1)
  assert_contains "$out" "closed its tab" "the flat layout still closes cleanly"
  pass "a Herdr that cannot create a workspace still gets the crew, in a tab"
}

test_a_crew_gets_its_own_workspace_after_its_parent
test_a_refused_move_is_only_presentation
test_a_relaunch_adopts_the_existing_workspace
test_the_label_leads_with_the_item_number
test_the_board_supplies_the_number_without_a_flag
test_an_unlinked_crew_keeps_the_plain_label
test_close_retires_the_workspace_not_the_parent
test_an_older_record_never_closes_the_foremans_workspace
test_a_herdr_without_workspace_create_falls_back
