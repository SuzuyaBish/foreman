#!/usr/bin/env bash
# shellcheck disable=SC1010  # "done" is a subcommand argument here, not a loop terminator.
# crew-watch.test.sh - the one-shot watcher, and the wake rows it produces.
#
# The watcher is the only producer of wake rows. It blocks until there is news,
# appends a bounded durable row, prints one line, and exits; the foreman is
# never asked to poll. Timings here are compressed to one second.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_home >/dev/null
fm_herdr_stub >/dev/null

WATCH="$BIN/crew-watch.sh"
export FOREMAN_WATCH_INTERVAL=1
export FOREMAN_STEER_GRACE_SECS=1
export FOREMAN_STEER_MAX_RINGS=3
export FOREMAN_PR_POLL_SECS=9999

OUT=$(fm_tmproot watch-out)/log

# wait_for_exit <pid> <seconds>: 0 if the process exited in time.
wait_for_exit() {
  local pid=$1 limit=$2 i=0
  local ticks=$((limit * 4))
  while kill -0 "$pid" 2>/dev/null; do
    i=$((i + 1))
    [ "$i" -lt "$ticks" ] || return 1
    sleep 0.25
  done
  return 0
}

# Add a todo item and print its sequence, so a test never hard-codes a number an
# earlier test has already advanced.
add_item() { "$BIN/crew-todo.sh" add "$@" | sed -n 's/^added #\([0-9][0-9]*\).*/\1/p'; }

# item_status <seq>: the linked item's status, read straight from the board file.
item_status() { awk -F'\t' -v s="$1" '$1 == s { print $2 }' "$FOREMAN_HOME/todo.tsv"; }

# attach_home <id>: record the workspace and tab this foreman created for a crew,
# with its pane registered there, exactly as a launch leaves it. Prints the pane.
attach_home() { # <id>
  local id=$1 out ws tab pane
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

# attach_home_lost_pane <id>: a home whose pane the crew already lost, so the
# endpoint sweep leaves the task alone and the finished-home sweep is exercised
# on its own. Prints the workspace id.
attach_home_lost_pane() { # <id>
  local id=$1 out ws tab
  fm_herdr_seed_workspace ws-parent skills
  out=$(herdr --session "${FOREMAN_SESSION:-default}" workspace create \
    --label "└ $id" --cwd /tmp --no-focus)
  ws=$(printf '%s' "$out" | jq -r '.result.workspace.workspace_id')
  tab=$(printf '%s' "$out" | jq -r '.result.tab.tab_id')
  {
    printf 'workspace=%s\nparent_workspace=ws-parent\n' "$ws"
    printf 'tab=%s\n' "$tab"
  } >>"$FOREMAN_HOME/tasks/$id/meta"
  printf '%s\n' "$ws"
}

workspace_of() { sed -n 's/^workspace=//p' "$FOREMAN_HOME/tasks/$1/meta" | head -1; }

test_a_state_change_wakes_the_foreman() {
  fm_task w1 working >/dev/null
  fm_attach_pane w1 >/dev/null

  : >"$OUT"
  "$WATCH" >"$OUT" 2>&1 &
  local pid=$!
  sleep 1.5
  "$BIN/crew-report.sh" w1 review "ready for review" >/dev/null

  wait_for_exit "$pid" 20 || {
    kill "$pid" 2>/dev/null
    fail "the watcher did not wake on a state change"
  }
  wait "$pid"
  expect_code 0 "$?" "the watcher exits cleanly after a wake"
  assert_contains "$(cat "$OUT")" "crew wake: w1 review" "the wake line names the task and new state"
  assert_contains "$("$BIN/crew-queue.sh" list)" "w1 review" "a durable wake row was appended"
  pass "a state change produces one durable wake row and one line"
}

test_a_review_names_the_linked_item_and_pr() {
  local seq out
  fm_task w3 working >/dev/null
  fm_attach_pane w3 >/dev/null
  seq=$(add_item "Crew board: the status line and the widget disagree")
  "$BIN/crew-todo.sh" start "$seq" w3 >/dev/null

  : >"$OUT"
  "$WATCH" >"$OUT" 2>&1 &
  local pid=$!
  sleep 1.5
  "$BIN/crew-report.sh" w3 review "ready for review" --pr "https://example.test/o/r/pull/7" >/dev/null

  wait_for_exit "$pid" 20 || {
    kill "$pid" 2>/dev/null
    fail "the watcher did not wake on a linked review"
  }
  wait "$pid"

  out=$("$BIN/crew-queue.sh" list)
  assert_contains "$out" \
    "#$seq Crew board: the status line and the widget disagree — PR ready: https://example.test/o/r/pull/7" \
    "the durable wake row names the linked item's number and title, and the PR"
  assert_contains "$(cat "$OUT")" \
    "crew wake: #$seq Crew board: the status line and the widget disagree — PR ready: https://example.test/o/r/pull/7" \
    "the one-line wake names the work too"
  pass "a review transition announces the linked work, not just the crew id"
}

test_a_review_without_a_linked_item_names_the_crew() {
  fm_task w4 working >/dev/null
  fm_attach_pane w4 >/dev/null

  : >"$OUT"
  "$WATCH" >"$OUT" 2>&1 &
  local pid=$!
  sleep 1.5
  "$BIN/crew-report.sh" w4 review "ready" --pr "https://example.test/o/r/pull/8" >/dev/null

  wait_for_exit "$pid" 20 || {
    kill "$pid" 2>/dev/null
    fail "the watcher did not wake on an unlinked review"
  }
  wait "$pid"

  assert_contains "$("$BIN/crew-queue.sh" list)" "w4 review" \
    "an unlinked crew keeps today's wake row, PR or not"
  pass "a crew with no linked item still names the crew"
}

test_an_overlong_title_stays_one_line() {
  local seq long row payload
  fm_task w5 working >/dev/null
  fm_attach_pane w5 >/dev/null
  long=$(printf 'a long todo title %.0s' {1..30})
  seq=$(add_item "$long")
  "$BIN/crew-todo.sh" start "$seq" w5 >/dev/null

  : >"$OUT"
  "$WATCH" >"$OUT" 2>&1 &
  local pid=$!
  sleep 1.5
  "$BIN/crew-report.sh" w5 review "ready" --pr "https://example.test/o/r/pull/9" >/dev/null

  wait_for_exit "$pid" 20 || {
    kill "$pid" 2>/dev/null
    fail "the watcher did not wake on an overlong-title review"
  }
  wait "$pid"

  # A row is one physical TSV line of four fields; the payload can neither smuggle
  # in a tab nor push the announcement onto a second line.
  row=$(awk -F'\t' -v s="$seq" '$4 ~ ("^#" s " ") { print }' "$FOREMAN_HOME/.wake-queue")
  [ -n "$row" ] || fail "no review row for #$seq"
  assert_equals "4" "$(printf '%s\n' "$row" | awk -F'\t' '{ print NF }')" \
    "the wake row is exactly four fields with no embedded tab"
  assert_equals "1" "$(wc -l <"$OUT" | tr -d ' ')" "the wake is one line"
  payload=$(printf '%s\n' "$row" | cut -f4)
  assert_contains "$payload" "#$seq " "the number survives ellipsizing"
  assert_contains "$payload" "https://example.test/o/r/pull/9" "the URL survives ellipsizing"
  assert_contains "$payload" "…" "an overlong title is ellipsized"
  pass "an overlong title is ellipsized, never dropped for the number or URL"
}

test_a_lost_endpoint_wakes_the_foreman() {
  fm_task w2 working >/dev/null
  local pane
  pane=$(fm_attach_pane w2)
  : >"$OUT"
  "$WATCH" >"$OUT" 2>&1 &
  local pid=$!
  sleep 1.5
  fm_herdr_kill_pane "$pane"

  wait_for_exit "$pid" 20 || {
    kill "$pid" 2>/dev/null
    fail "the watcher did not wake on a lost endpoint"
  }
  wait "$pid"
  assert_contains "$(cat "$OUT")" "crew wake: w2 failed" "a lost endpoint wakes as failed"
  assert_equals "failed" "$(sed -n 's/^state=//p' "$FOREMAN_HOME/tasks/w2/status")" \
    "the task is no longer read as working"
  pass "a pane that vanishes mid-flight cannot sit silent"
}

test_an_unacknowledged_steer_escalates() {
  fm_task e1 working >/dev/null
  mkdir -p "$FOREMAN_HOME/tasks/e1/inbox"
  printf 'at=x\n--\nplease do the thing\n' >"$FOREMAN_HOME/tasks/e1/inbox/001.msg"
  printf '001.msg\t5\t%s\n' "$(($(date +%s) - 3600))" >"$FOREMAN_HOME/tasks/e1/inbox/.ring"

  : >"$OUT"
  "$WATCH" >"$OUT" 2>&1 &
  local pid=$!
  sleep 3
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null

  assert_contains "$("$BIN/crew-queue.sh" list)" "e1 steer 001.msg unacknowledged after 5 rings" \
    "a steer past its ring ladder is escalated into the wake queue"
  assert_present "$FOREMAN_HOME/tasks/e1/inbox/.escalated-001.msg" \
    "escalation is recorded once, not on every pass"
  pass "a swallowed doorbell becomes a visible fact"
}

# test_a_finished_crew_releases_its_home_once: a crew that reports done owes
# nothing more, so its terminal closes -- exactly as a merge closes one -- and
# the close shows up in the wake line. The record, branch and worktree stay.
test_a_finished_crew_releases_its_home_once() {
  local pane ws pid rows_before rows_after
  fm_task d1 working >/dev/null
  pane=$(attach_home d1)
  ws=$(workspace_of d1)

  : >"$OUT"
  "$WATCH" >"$OUT" 2>&1 &
  pid=$!
  sleep 1.5
  "$BIN/crew-report.sh" d1 done "report delivered" >/dev/null
  wait_for_exit "$pid" 20 || {
    kill "$pid" 2>/dev/null
    fail "the watcher did not wake when a crew reported done"
  }
  wait "$pid"

  assert_contains "$(cat "$OUT")" "closed its workspace" "the wake line reports the release"
  assert_absent "$HERDR_STUB_STATE/pane-$pane" "the idle terminal is gone"
  assert_equals "1" "$(grep -c "workspace close $ws" "$HERDR_STUB_STATE/calls")" \
    "the home is closed exactly once"
  assert_present "$FOREMAN_HOME/tasks/d1" "the record survives the release"
  assert_absent "$FOREMAN_HOME/archive/d1" "a finished crew is never archived"
  assert_contains "$("$BIN/crew-queue.sh" list)" "d1 done" "the finish is on the durable board"
  assert_contains "$("$BIN/crew-queue.sh" list)" "closed its workspace" "the release is visible too"

  # Meeting the same settled task again must not re-close or re-announce it.
  rows_before=$("$BIN/crew-queue.sh" count)
  : >"$OUT"
  "$WATCH" >"$OUT" 2>&1 &
  pid=$!
  sleep 2.5
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  rows_after=$("$BIN/crew-queue.sh" count)
  assert_equals "$rows_before" "$rows_after" "a settled release is not announced again"
  assert_equals "1" "$(grep -c "workspace close $ws" "$HERDR_STUB_STATE/calls")" \
    "the home is not closed twice"
  pass "a finished crew releases its terminal once, and only its terminal"
}

# test_a_failed_crew_releases_its_home: failed is the other half of "nothing is
# owed", so its terminal closes too.
test_a_failed_crew_releases_its_home() {
  local pane ws pid
  fm_task f1 working >/dev/null
  pane=$(attach_home f1)
  ws=$(workspace_of f1)

  : >"$OUT"
  "$WATCH" >"$OUT" 2>&1 &
  pid=$!
  sleep 1.5
  "$BIN/crew-report.sh" f1 failed "cannot be completed" >/dev/null
  wait_for_exit "$pid" 20 || {
    kill "$pid" 2>/dev/null
    fail "the watcher did not wake when a crew failed"
  }
  wait "$pid"

  assert_contains "$(cat "$OUT")" "closed its workspace" "a failed crew's terminal is released too"
  assert_absent "$HERDR_STUB_STATE/pane-$pane" "the failed crew's pane is gone"
  assert_contains "$(fm_herdr_calls)" "workspace close $ws" "the failed crew's home was closed"
  assert_present "$FOREMAN_HOME/tasks/f1" "the failed record survives"
  pass "a failed crew does not hold a terminal either"
}

# test_a_blocked_crew_keeps_its_home: a decision is still owed, so the pane it
# is waiting in must stay.
test_a_blocked_crew_keeps_its_home() {
  local pane pid
  fm_task b1 working >/dev/null
  pane=$(attach_home b1)

  : >"$OUT"
  "$WATCH" >"$OUT" 2>&1 &
  pid=$!
  sleep 1.5
  "$BIN/crew-report.sh" b1 blocked "waiting on the captain" >/dev/null
  wait_for_exit "$pid" 20 || {
    kill "$pid" 2>/dev/null
    fail "the watcher did not wake when a crew blocked"
  }
  wait "$pid"

  assert_contains "$(cat "$OUT")" "b1 blocked" "a blocked crew still wakes the foreman"
  assert_present "$HERDR_STUB_STATE/pane-$pane" "the pane a blocked crew needs survives"
  pass "a crew waiting on a decision holds its terminal"
}

# test_a_review_crew_keeps_its_home: a merge is owed, so the pane stays too.
test_a_review_crew_keeps_its_home() {
  local pane pid
  fm_task r1 working >/dev/null
  pane=$(attach_home r1)

  : >"$OUT"
  "$WATCH" >"$OUT" 2>&1 &
  pid=$!
  sleep 1.5
  "$BIN/crew-report.sh" r1 review "ready" --pr "https://example.test/o/r/pull/11" >/dev/null
  wait_for_exit "$pid" 20 || {
    kill "$pid" 2>/dev/null
    fail "the watcher did not wake on a review"
  }
  wait "$pid"

  assert_contains "$(cat "$OUT")" "r1 review" "a review still wakes the foreman"
  assert_present "$HERDR_STUB_STATE/pane-$pane" "the pane a review crew waits in survives"
  pass "a crew waiting on a merge holds its terminal"
}

# test_a_working_crew_is_left_alone: nothing is owed yet, so the watcher neither
# closes nor announces anything.
test_a_working_crew_is_left_alone() {
  local pane pid rows_before rows_after
  fm_task g1 working >/dev/null
  pane=$(attach_home g1)

  rows_before=$("$BIN/crew-queue.sh" count)
  : >"$OUT"
  "$WATCH" >"$OUT" 2>&1 &
  pid=$!
  sleep 2.5
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null

  rows_after=$("$BIN/crew-queue.sh" count)
  assert_present "$HERDR_STUB_STATE/pane-$pane" "a working crew keeps its terminal"
  assert_equals "$rows_before" "$rows_after" "a working crew produces no release wake"
  pass "a crew still on the job is untouched"
}

# test_an_unreachable_herdr_warns_and_changes_nothing: the release is best
# effort, like merge and archive. A Herdr that is not there is a warning; the
# task stays done and the home is not invented as closed. The crew here has lost
# its pane, so the endpoint sweep leaves it and the release sweep is isolated.
test_an_unreachable_herdr_warns_and_changes_nothing() {
  local ws pid sans_herdr
  fm_task h1 working >/dev/null
  ws=$(attach_home_lost_pane h1)

  # Build the herdr-less PATH before launching, so the watcher reaches its loop
  # before the report and the transition is what it observes.
  sans_herdr=$(fm_path_without herdr)
  : >"$OUT"
  PATH="$sans_herdr" "$WATCH" >"$OUT" 2>&1 &
  pid=$!
  sleep 1.5
  "$BIN/crew-report.sh" h1 done "finished" >/dev/null
  wait_for_exit "$pid" 20 || {
    kill "$pid" 2>/dev/null
    fail "the watcher did not wake with Herdr unreachable"
  }
  wait "$pid"

  assert_contains "$(cat "$OUT")" "could not close its terminal" "the failed release is a warning"
  assert_equals "done" "$(sed -n 's/^state=//p' "$FOREMAN_HOME/tasks/h1/status")" "the task stays done"
  assert_contains "$(cat "$HERDR_STUB_STATE/workspaces")" "$ws" "the home is left untouched"
  # Settle it by hand so no later watcher run trips over this landmine.
  : >"$FOREMAN_HOME/tasks/h1/.home-closed"
  pass "an unreachable Herdr leaves the finish standing"
}

# test_a_state_change_settles_the_linked_item: the general case. A merge is not
# the only way a crew's state changes: a crew that reports `done` for a report
# task, or goes `failed` before delivering, leaves the same stale row, and the
# chrome cannot reconcile it. The watcher observes those transitions, so it
# settles the derived row there.
test_a_state_change_settles_the_linked_item() {
  local seq_done seq_fail pid
  fm_task wd working >/dev/null
  seq_done=$(add_item "delivered by a report, not a merge")
  "$BIN/crew-todo.sh" start "$seq_done" wd >/dev/null

  : >"$OUT"
  "$WATCH" >"$OUT" 2>&1 &
  pid=$!
  sleep 1.5
  "$BIN/crew-report.sh" wd done "report delivered" >/dev/null
  wait_for_exit "$pid" 20 || {
    kill "$pid" 2>/dev/null
    fail "the watcher did not wake when a linked crew reported done"
  }
  wait "$pid"
  assert_equals "done" "$(item_status "$seq_done")" \
    "a crew that reports done settles its linked item without a list call"

  fm_task wf working >/dev/null
  seq_fail=$(add_item "its crew died before delivering")
  "$BIN/crew-todo.sh" start "$seq_fail" wf >/dev/null

  : >"$OUT"
  "$WATCH" >"$OUT" 2>&1 &
  pid=$!
  sleep 1.5
  "$BIN/crew-report.sh" wf failed "cannot be completed" >/dev/null
  wait_for_exit "$pid" 20 || {
    kill "$pid" 2>/dev/null
    fail "the watcher did not wake when a linked crew failed"
  }
  wait "$pid"
  assert_equals "open" "$(item_status "$seq_fail")" \
    "a crew that fails before delivering reopens its linked item"
  pass "the watcher settles a linked item wherever its crew's state changes"
}

test_an_unreachable_herdr_warns_and_changes_nothing
test_a_state_change_settles_the_linked_item
test_a_finished_crew_releases_its_home_once
test_a_failed_crew_releases_its_home
test_a_blocked_crew_keeps_its_home
test_a_review_crew_keeps_its_home
test_a_working_crew_is_left_alone
test_a_state_change_wakes_the_foreman
test_a_review_names_the_linked_item_and_pr
test_a_review_without_a_linked_item_names_the_crew
test_an_overlong_title_stays_one_line
test_a_lost_endpoint_wakes_the_foreman
test_an_unacknowledged_steer_escalates
