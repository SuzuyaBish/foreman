#!/usr/bin/env bash
# shellcheck disable=SC1010  # "done" is a subcommand argument here, not a loop terminator.
# crew-todo.test.sh - the durable todo list that outlives every session.
#
# The list is the foreman's memory across a restart, so what matters is that
# sequence numbers never collide, a row's intent is independent of the crew's
# live state, sync reconciles the two, and user text can never break the
# tab-separated row format.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_home >/dev/null

TODO="$BIN/crew-todo.sh"

# Add an item and print its sequence, so a test never hard-codes a number an
# earlier test has already advanced.
add_item() { "$TODO" add "$@" | sed -n 's/^added #\([0-9][0-9]*\).*/\1/p'; }

test_add_and_sequence() {
  local out
  out=$("$TODO" add "first item")
  assert_equals "added #1 (foreman)" "$out" "the first item is #1"
  assert_equals "added #2 (foreman)" "$("$TODO" add second item)" "the second item is #2"
  assert_equals "added #3 (foreman)" "$("$TODO" add --note "why it matters" third item)" "an item can carry a note"

  # A dropped row still owns its number: reusing it would rewrite history.
  "$TODO" drop 2 >/dev/null
  assert_equals "added #4 (foreman)" "$("$TODO" add "after a drop")" "sequence numbers never repeat"

  if "$TODO" add >/dev/null 2>&1; then fail "an empty item was accepted"; fi
  pass "items are numbered monotonically and never reused"
}

test_list_rendering() {
  local out
  out=$("$TODO" list)
  assert_contains "$out" "#    STATUS    CREW        ITEM" "list prints a header"
  assert_contains "$out" "first item" "list shows item text"
  assert_contains "$out" "third item" "list shows a second item"
  assert_contains "$out" "↳ why it matters" "a note renders on its own indented line"

  out=$("$TODO" list --no-notes)
  assert_not_contains "$out" "why it matters" "--no-notes hides notes"

  out=$("$TODO" list --all)
  assert_contains "$out" "second item" "list --all shows dropped rows"
  out=$("$TODO" list --open)
  assert_not_contains "$out" "second item" "list --open hides dropped rows"

  if "$TODO" list --bogus >/dev/null 2>&1; then fail "an unknown list option was accepted"; fi
  pass "the board view filters and renders notes"
}

test_note_updates_in_place() {
  "$TODO" note 3 "now it is explained" >/dev/null
  local out
  out=$("$TODO" list)
  assert_contains "$out" "↳ now it is explained" "note replaces the row's note"
  assert_not_contains "$out" "↳ why it matters" "the old note is gone"
  if "$TODO" note 99 "nope" >/dev/null 2>&1; then fail "a note on a missing item was accepted"; fi
  if "$TODO" note 1 >/dev/null 2>&1; then fail "an empty note was accepted"; fi
  pass "notes update one row without touching its text"
}

test_sanitize_protects_the_row_format() {
  "$TODO" add "$(printf 'tab\there and\nnewline')" >/dev/null
  local seq last
  seq=$("$TODO" list | awk '$4 == "tab" { print $1 }')
  [ -n "$seq" ] || fail "a tab/newline item did not land as one row"
  last=$("$TODO" list | awk -v s="$seq" '$1 == s')
  assert_contains "$last" "tab here and newline" "embedded whitespace is folded to spaces"
  assert_equals "1" "$(awk -F'\t' -v s="$seq" '$1 == s { n++ } END { print n + 0 }' "$FOREMAN_HOME/todo.tsv")" \
    "the row is a single physical line"
  pass "user text cannot forge a new row"
}

test_start_done_open_drop() {
  local out
  fm_task crew1 working >/dev/null
  "$TODO" start 1 crew1 >/dev/null
  out=$("$TODO" list)
  assert_contains "$out" "active/working" "a started row shows the crew's live state"

  "$TODO" done 1 >/dev/null
  out=$("$TODO" list)
  assert_contains "$out" "done" "a done row reads done"
  assert_equals "1" "$(printf '%s\n' "$out" | awk '$1 == 1 && $2 == "done" && $3 == "-" { n++ } END { print n + 0 }')" \
    "the crew link is cleared when the row settles"

  "$TODO" open 1 >/dev/null
  out=$("$TODO" list)
  assert_contains "$out" "open" "a row can be reopened"
  assert_not_contains "$out" "active/working" "reopening detaches the crew"

  "$TODO" drop 1 >/dev/null
  out=$("$TODO" list --open)
  assert_not_contains "$out" "first item" "a dropped row leaves the open view"

  if "$TODO" start 99 nobody >/dev/null 2>&1; then fail "starting a missing item was accepted"; fi
  if "$TODO" done 99 >/dev/null 2>&1; then fail "completing a missing item was accepted"; fi
  if "$TODO" start 2 >/dev/null 2>&1; then fail "starting without a crew id was accepted"; fi
  pass "intent transitions are explicit and validated"
}

test_sync_follows_the_crew() {
  # Fresh home-local list: use real ids so the linked crew state is read live.
  fm_task wok done >/dev/null
  fm_task fai failed >/dev/null
  fm_task gon queued >/dev/null
  rm -rf "$FOREMAN_HOME/tasks/gon"

  "$TODO" add "crew did it" >/dev/null
  "$TODO" add "crew died" >/dev/null
  "$TODO" add "crew vanished" >/dev/null
  "$TODO" add "manual row" >/dev/null
  "$TODO" start 2 wok >/dev/null
  "$TODO" start 3 fai >/dev/null
  "$TODO" start 4 gon >/dev/null

  "$TODO" sync >/dev/null
  local out
  out=$("$TODO" list --all)
  assert_contains "$out" "2    done" "a crew that finished settles its row to done"
  assert_contains "$out" "3    open" "a failed crew reopens its row"
  assert_contains "$out" "4    open" "a vanished crew reopens its row"
  assert_contains "$out" "5    open" "an unlinked row is left alone"

  # A terminal row is never resurrected by a later sync.
  "$TODO" sync >/dev/null
  out=$("$TODO" list --all)
  assert_contains "$out" "2    done" "a done row stays done across syncs"
  assert_contains "$out" "3    open" "an open row stays open across syncs"
  pass "sync reconciles intent against live crew state without resurrecting terminal rows"
}

# The bug: stopping a finished crew reopened its delivered item. The crew's
# live state records the pane death, but the append-only log still carries the
# `done`, and `done` is terminal for the row.
test_sync_keeps_a_delivered_crew_done() {
  local s_stop s_lost s_work s_relaunch out
  fm_task delivered-stop stopped >/dev/null
  printf 'x\tdone\t\tmerged by the foreman: https://example.test/o/r/pull/2\n' \
    >>"$FOREMAN_HOME/tasks/delivered-stop/events"
  fm_task delivered-lost failed >/dev/null
  printf 'x\tdone\t\tfinished\nx\tfailed\t\tendpoint gone: the recorded pane no longer exists\n' \
    >>"$FOREMAN_HOME/tasks/delivered-lost/events"
  fm_task unfinished-stop stopped >/dev/null
  fm_task relaunched done >/dev/null
  printf 'x\tfailed\t\tfirst attempt\nx\tworking\t\trelaunched\nx\tdone\t\tfinished on the second try\n' \
    >>"$FOREMAN_HOME/tasks/relaunched/events"

  s_stop=$(add_item "delivered then stopped")
  s_lost=$(add_item "delivered then lost")
  s_work=$(add_item "unfinished then stopped")
  s_relaunch=$(add_item "failed then relaunched")

  "$TODO" start "$s_stop" delivered-stop >/dev/null
  "$TODO" start "$s_lost" delivered-lost >/dev/null
  "$TODO" start "$s_work" unfinished-stop >/dev/null
  "$TODO" start "$s_relaunch" relaunched >/dev/null

  row_state() { printf '%s\n' "$1" | awk -v s="$2" '$1 == s { print $2 }'; }
  "$TODO" sync >/dev/null
  out=$("$TODO" list --all)
  assert_equals "done" "$(row_state "$out" "$s_stop")" "a stopped crew that had reported done keeps its item done"
  assert_equals "done" "$(row_state "$out" "$s_lost")" "a crew that lost its pane after done keeps its item done"
  assert_equals "open" "$(row_state "$out" "$s_work")" "a stopped crew that never delivered reopens its item"
  assert_equals "done" "$(row_state "$out" "$s_relaunch")" "a failed crew that relaunches to done settles its item"

  # Sticky across a second sync, exactly as the captain saw it: the crew is
  # still stopped, and the item must still be done.
  "$TODO" sync >/dev/null
  out=$("$TODO" list --all)
  assert_equals "done" "$(row_state "$out" "$s_stop")" "a delivered item stays done across syncs"
  pass "a delivered item is never reopened by the crew's later process death"
}

test_summary() {
  local out
  out=$("$TODO" summary)
  case "$out" in
  *"items"*"open"*"active"*"done"*) : ;;
  *) fail "summary has the expected shape (got '$out')" ;;
  esac
  pass "summary is a one-line count"
}

# --- scope ------------------------------------------------------------------

# One harness serves many projects, so an item belongs to a project and the
# board reads one project at a time. Without that, the harness's own backlog
# reads as the project's.
test_scopes_keep_projects_apart() {
  local out
  "$TODO" add --project Example_App "sheet background" >/dev/null
  "$TODO" add --project foreman "tidy the chrome" >/dev/null
  "$TODO" focus Example_App >/dev/null

  out=$("$TODO" list)
  assert_contains "$out" "sheet background" "the focused project's item is listed"
  assert_not_contains "$out" "tidy the chrome" "another project's item is not"
  local elsewhere
  elsewhere=$(printf '%s\n' "$out" | sed -n 's/.*open elsewhere: foreman \([0-9][0-9]*\) open.*/\1/p')
  [ -n "$elsewhere" ] && [ "$elsewhere" -ge 1 ] || fail "queued work in another scope is reported with a count (got '$out')"

  out=$("$TODO" list --all)
  assert_contains "$out" "tidy the chrome" "--all shows every scope"
  assert_contains "$out" "Example_App" "--all names the scope it is showing"
  assert_contains "$out" "foreman" "--all names the other scope too"

  out=$("$TODO" list --project foreman)
  assert_contains "$out" "tidy the chrome" "--project reads one named scope"
  assert_not_contains "$out" "sheet background" "...and only that one"

  out=$("$TODO" summary)
  assert_contains "$out" "Example_App: 1 item (1 open, 0 active, 0 done)" "summary leads with the scope in focus"
  assert_contains "$out" "also foreman" "summary points at queued work elsewhere"
  assert_contains "$("$TODO" summary --all)" "all scopes:" "summary --all counts every scope"

  if "$TODO" add --project "bad name" nope >/dev/null 2>&1; then fail "a project name with a space was accepted"; fi
  if "$TODO" list --project "bad name" >/dev/null 2>&1; then fail "a bad project name was accepted by list"; fi
  pass "an item belongs to one project and the board reads one project at a time"
}

test_focus_follows_the_newest_crew() {
  local out
  "$TODO" focus --clear >/dev/null
  assert_equals "foreman" "$("$TODO" focus)" "with no focus and no crew the scope is the harness"

  # `sleep 1` keeps this task strictly newer: the board picks the newest by
  # timestamp, and a whole test file can otherwise land in one second.
  sleep 1
  fm_task proj-crew working >/dev/null
  fm_task_project proj-crew /tmp/projects/Sample-Project
  assert_equals "Sample-Project" "$("$TODO" focus)" "the scope follows the project of the newest crew"

  # Per session: another session's focus is not this one's.
  FOREMAN_SESSION=other "$TODO" focus Example_App >/dev/null
  assert_equals "Sample-Project" "$("$TODO" focus)" "a second session's focus does not move this one"
  assert_equals "Example_App" "$(FOREMAN_SESSION=other "$TODO" focus)" "...and its own focus is its own"

  "$TODO" focus foreman >/dev/null
  assert_equals "foreman" "$("$TODO" focus)" "an explicit focus wins over the newest crew"
  out=$("$TODO" add "unscoped item")
  assert_contains "$out" "(foreman)" "an item added with no project lands in the scope in focus"
  pass "the board follows the project you were last working on, per session"
}

test_start_adopts_the_crews_project() {
  local n
  "$TODO" add --project foreman "wrongly filed" >/dev/null
  n=$(awk -F'\t' '$4 == "wrongly filed" { print $1 }' "$FOREMAN_HOME/todo.tsv")
  "$TODO" start "$n" proj-crew >/dev/null
  assert_equals "Sample-Project" "$(awk -F'\t' -v s="$n" '$1 == s { print $6 }' "$FOREMAN_HOME/todo.tsv")" \
    "linking work to a crew files it under that crew's project"
  pass "a crew's project settles the scope of the work it is given"
}

test_sync_backfills_scope_from_the_crew() {
  local out
  fm_task backfill-crew working >/dev/null
  fm_task_project backfill-crew /tmp/projects/Example_App
  # Rows written before scopes existed: five fields, no scope.
  printf '%s\t%s\t%s\t%s\t%s\n' 900 open backfill-crew "legacy row" - >>"$FOREMAN_HOME/todo.tsv"
  printf '%s\t%s\t%s\t%s\t%s\n' 901 open - "legacy harness row" - >>"$FOREMAN_HOME/todo.tsv"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' 902 open backfill-crew "chosen row" - foreman >>"$FOREMAN_HOME/todo.tsv"
  "$TODO" sync >/dev/null

  out=$(awk -F'\t' '$1 == 900 { print $6 }' "$FOREMAN_HOME/todo.tsv")
  assert_equals "Example_App" "$out" "a legacy row takes the scope of the crew it is linked to"
  assert_equals "foreman" "$(awk -F'\t' '$1 == 901 { print $6 }' "$FOREMAN_HOME/todo.tsv")" \
    "a legacy row with no crew is harness work"
  assert_equals "foreman" "$(awk -F'\t' '$1 == 902 { print $6 }' "$FOREMAN_HOME/todo.tsv")" \
    "sync never overrules a scope the captain chose"
  pass "rows from before scopes are filed correctly, and explicit scopes are respected"
}

test_add_and_sequence
test_list_rendering
test_note_updates_in_place
test_sanitize_protects_the_row_format
test_start_done_open_drop
test_sync_follows_the_crew
test_sync_keeps_a_delivered_crew_done
test_summary
test_scopes_keep_projects_apart
test_focus_follows_the_newest_crew
test_start_adopts_the_crews_project
test_sync_backfills_scope_from_the_crew
