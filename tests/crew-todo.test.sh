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
propose_item() { "$TODO" propose "$@" | sed -n 's/^proposed #\([0-9][0-9]*\).*/\1/p'; }

# A project is a directory under projects/; the write path refuses a scope that
# names none, so a fixture that scopes work creates the project first.
project_dir() { mkdir -p "$FOREMAN_PROJECTS/$1"; }

# The scope written on one row.
scope_of() { awk -F'\t' -v s="$1" '$1 == s { print $6 }' "$FOREMAN_HOME/todo.tsv"; }

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

test_item_lookup() {
  local seq out
  fm_task linked-crew working >/dev/null
  fm_task unlinked-crew working >/dev/null
  seq=$(add_item "the work this crew is doing")
  "$TODO" start "$seq" linked-crew >/dev/null

  out=$("$TODO" item linked-crew)
  assert_equals "$(printf '%s\tthe work this crew is doing' "$seq")" "$out" \
    "item resolves a crew to its linked item's number and title"
  assert_equals "" "$("$TODO" item unlinked-crew)" "an unlinked crew resolves to nothing"
  assert_equals "" "$("$TODO" item -)" "the empty crew resolves to nothing"
  assert_equals "" "$("$TODO" item missing-crew)" "an unknown crew resolves to nothing"
  pass "a crew resolves to the item linked to it"
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

# --- proposals --------------------------------------------------------------
#
# The board belongs to the captain, so a suggestion the foreman files on its own
# initiative is a separate tier: it reads as `proposed`, it is shown as a table
# with its reason, and it never appears on the board. Only the captain's
# `approve` promotes it, and it keeps the number they already saw.
test_proposals_wait_for_the_captain() {
  local out seq row other
  "$TODO" focus foreman >/dev/null

  out=$("$TODO" propose --note "spotted while reviewing #1" "add a flake check to CI")
  case "$out" in
  "proposed #"*"(foreman)") : ;;
  *) fail "a proposal is filed and says so (got '$out')" ;;
  esac
  seq=$(printf '%s' "$out" | sed -n 's/^proposed #\([0-9][0-9]*\).*/\1/p')

  assert_equals "proposed" "$(awk -F'\t' -v s="$seq" '$1 == s { print $2 }' "$FOREMAN_HOME/todo.tsv")" \
    "a proposal is stored as proposed, not open"
  assert_equals "spotted while reviewing #1" "$(awk -F'\t' -v s="$seq" '$1 == s { print $5 }' "$FOREMAN_HOME/todo.tsv")" \
    "the one-line reason lives in the note field"

  # The board never mixes in the foreman's suggestion, not even with --all.
  assert_not_contains "$("$TODO" list)" "add a flake check to CI" "the captain's board does not show a proposal"
  assert_not_contains "$("$TODO" list --all)" "add a flake check to CI" "even --all keeps a proposal off the board"

  out=$("$TODO" proposals)
  assert_contains "$out" "PROPOSED" "the proposals view prints a table"
  assert_contains "$out" "REASON" "the table has a reason column"
  row=$(printf '%s\n' "$out" | awk -v s="$seq" '$1 == s')
  assert_contains "$row" "add a flake check to CI" "the table row carries the proposal text"
  assert_contains "$row" "spotted while reviewing #1" "the table row carries the reason"

  assert_contains "$("$TODO" summary)" "1 proposed" "summary counts proposals separately"

  # A proposal has no crew to follow, so sync must not touch it.
  "$TODO" sync >/dev/null
  assert_equals "proposed" "$(awk -F'\t' -v s="$seq" '$1 == s { print $2 }' "$FOREMAN_HOME/todo.tsv")" \
    "sync leaves a proposal alone"

  # Approve promotes in place and keeps the number the captain read.
  "$TODO" approve "$seq" >/dev/null
  assert_equals "open" "$(awk -F'\t' -v s="$seq" '$1 == s { print $2 }' "$FOREMAN_HOME/todo.tsv")" \
    "approval promotes a proposal to open"
  out=$("$TODO" list)
  assert_contains "$out" "add a flake check to CI" "an approved proposal joins the board"
  row=$(printf '%s\n' "$out" | grep -F "add a flake check to CI" | head -1)
  assert_equals "$seq" "$(printf '%s\n' "$row" | awk '{ print $1 }')" \
    "approval keeps the proposal's number"
  if "$TODO" approve "$seq" >/dev/null 2>&1; then fail "approving a row that is not proposed was accepted"; fi

  # Decline behaves exactly like dropping any row.
  other=$(propose_item --note "not worth it" "rename the widget")
  "$TODO" drop "$other" >/dev/null
  assert_equals "dropped" "$(awk -F'\t' -v s="$other" '$1 == s { print $2 }' "$FOREMAN_HOME/todo.tsv")" \
    "a declined proposal is dropped"
  assert_not_contains "$("$TODO" proposals)" "rename the widget" "a declined proposal leaves the table"

  # The table reads one scope, like the board.
  "$TODO" propose --project Example_App --note "another project" "sheet idea" >/dev/null
  assert_not_contains "$("$TODO" proposals)" "sheet idea" "the proposals table reads the scope in focus"
  assert_contains "$("$TODO" proposals --all)" "sheet idea" "--all shows proposals from every scope"

  if "$TODO" propose >/dev/null 2>&1; then fail "an empty proposal was accepted"; fi
  if "$TODO" propose --project "bad name" nope >/dev/null 2>&1; then fail "a bad project name was accepted by propose"; fi
  pass "proposals are held for the captain's approval, off their board"
}

# --- scope ------------------------------------------------------------------

# One harness serves many projects, so an item belongs to a project and the
# board reads one project at a time. Without that, the harness's own backlog
# reads as the project's.
test_scopes_keep_projects_apart() {
  local out
  project_dir Example_App
  "$TODO" add --project Example_App "sheet background" >/dev/null
  "$TODO" add --project foreman "tidy the chrome" >/dev/null
  "$TODO" focus Example_App >/dev/null

  out=$("$TODO" list)
  assert_contains "$out" "sheet background" "the focused project's item is listed"
  assert_not_contains "$out" "tidy the chrome" "another project's item is not"

  # The tail must count work in flight, not only work queued: an `active` item
  # in another scope is a crew mid-flight, and a project with one used to
  # contribute 0 to the count. The label names each status, so the word `open`
  # is never silently bent to cover `active`.
  printf '950\tactive\t-\tland the parser\t-\tforeman\n' >>"$FOREMAN_HOME/todo.tsv"
  out=$("$TODO" list)
  assert_contains "$out" "elsewhere: foreman" "other-scope work is named, never hidden"
  local elsewhere active
  elsewhere=$(printf '%s\n' "$out" | sed -n 's/.*elsewhere: foreman \([0-9][0-9]*\) open.*/\1/p')
  [ -n "$elsewhere" ] && [ "$elsewhere" -ge 1 ] || fail "queued work in another scope is reported with a count (got '$out')"
  active=$(printf '%s\n' "$out" | sed -n 's/.*elsewhere: foreman .*\([0-9][0-9]*\) active.*/\1/p')
  [ -n "$active" ] && [ "$active" -ge 1 ] || fail "a crew mid-flight elsewhere is counted as active (got '$out')"

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
  assert_contains "$(printf '%s\n' "$out" | sed -n 's/.*also //p')" "active" \
    "summary counts a crew mid-flight elsewhere too"
  assert_contains "$("$TODO" summary --all)" "all scopes:" "summary --all counts every scope"

  if "$TODO" add --project "bad name" nope >/dev/null 2>&1; then fail "a project name with a space was accepted"; fi
  if "$TODO" list --project "bad name" >/dev/null 2>&1; then fail "a bad project name was accepted by list"; fi
  pass "an item belongs to one project and the board reads one project at a time"
}

test_focus_follows_the_newest_crew() {
  local out
  project_dir Example_App
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

# The class the write path cannot reach: a row filed before that path existed
# still carries a variant spelling, and that one project then renders as two
# groups. sync folds any *present* scope that resolves to a registered project
# into that project's canonical name. A scope that names no registered project
# is not ours to rewrite: the fold must leave it, and every row under it, alone.
test_sync_folds_a_legacy_scope() {
  local out
  project_dir habit-tracker
  # Two spellings the resolver folds (case; separators), and one stranger that
  # names no project at all.
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' 940 open - "legacy case variant" - Habit_Tracker >>"$FOREMAN_HOME/todo.tsv"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' 941 open - "legacy separator variant" - habit_tracker >>"$FOREMAN_HOME/todo.tsv"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' 942 open - "stranger scope" - Legacy_Thing >>"$FOREMAN_HOME/todo.tsv"

  "$TODO" sync >/dev/null

  assert_equals "habit-tracker" "$(scope_of 940)" "a case variant folds to the registered project"
  assert_equals "habit-tracker" "$(scope_of 941)" "a separator variant folds too"
  assert_equals "Legacy_Thing" "$(scope_of 942)" "a scope that names no project is left exactly as it is"

  # Exactly one group: the legacy spellings must not survive as group headers.
  out=$("$TODO" list --all)
  assert_equals "1" "$(printf '%s\n' "$out" | grep -cx "habit-tracker")" \
    "the project renders as exactly one group"
  assert_not_contains "$out" "Habit_Tracker" "no legacy spelling survives on the board"
  assert_equals "1" "$(printf '%s\n' "$out" | grep -cx "Legacy_Thing")" \
    "an unknown scope still renders as its own group"
  pass "sync folds a legacy scope into its project and never invents one"
}

# --- scope write path -------------------------------------------------------
#
# A scope is free text in the row, so a misspelt project used to become a
# project of its own: the work was then invisible from the real project's board
# and surfaced only as an `elsewhere` count under a name nobody chose. The write
# path resolves a name to a project that exists (ignoring case and separators)
# or refuses it, naming the projects there are.
test_an_unknown_scope_resolves_or_is_refused() {
  local seq out before
  project_dir habit-tracker

  # A variant of a real project lands on the project that exists...
  seq=$(add_item --project Habit_Tracker "bottom sheet from the more button")
  assert_equals "habit-tracker" "$(scope_of "$seq")" "a case-and-separator variant resolves to the project that exists"
  seq=$(add_item --project "habit tracker" "the same project, spaced")
  assert_equals "habit-tracker" "$(scope_of "$seq")" "...and so does a spaced spelling"
  seq=$(add_item --project habit_tracker "the same project, underscored")
  assert_equals "habit-tracker" "$(scope_of "$seq")" "...and an underscored one"

  # ...and never becomes a scope of its own.
  assert_equals "" "$(awk -F'\t' '$6 == "Habit_Tracker" || $6 == "habit tracker" || $6 == "habit_tracker" { print $6 }' "$FOREMAN_HOME/todo.tsv")" \
    "no spelling variant is written down as a scope"
  assert_not_contains "$("$TODO" list --all)" "Habit_Tracker" "the board never names the misspelling"

  # A real typo is refused, names the projects, and writes nothing.
  before=$(cat "$FOREMAN_HOME/todo.tsv")
  if out=$("$TODO" add --project habbit "a real typo" 2>&1); then fail "a typo was filed as a scope"; fi
  assert_contains "$out" "habbit" "the refusal names the argument"
  assert_contains "$out" "habit-tracker" "the refusal names the known projects"
  assert_contains "$out" "foreman" "...including the harness itself"
  assert_equals "$before" "$(cat "$FOREMAN_HOME/todo.tsv")" "a refused add writes nothing"

  # A proposal is invisible by nature, so a misspelt scope would bury it twice.
  seq=$(propose_item --project Habit_Tracker --note "spotted while reading" "resolve it on propose too")
  assert_equals "habit-tracker" "$(scope_of "$seq")" "a proposal's scope resolves the same way"
  before=$(cat "$FOREMAN_HOME/todo.tsv")
  if "$TODO" propose --project habbit "typo proposal" >/dev/null 2>&1; then fail "a typo in a proposal was accepted"; fi
  assert_equals "$before" "$(cat "$FOREMAN_HOME/todo.tsv")" "a refused proposal writes nothing"

  # `focus` is the same lie on another surface: a bogus focus shows an empty
  # board and reads as if the project has no work.
  "$TODO" focus foreman >/dev/null
  "$TODO" focus Habit_Tracker >/dev/null
  assert_equals "habit-tracker" "$("$TODO" focus)" "focus resolves the same variants"
  if "$TODO" focus habbit >/dev/null 2>&1; then fail "a bogus focus was accepted"; fi
  assert_equals "habit-tracker" "$("$TODO" focus)" "a refused focus leaves the focus unchanged"

  # Reads resolve too: a misspelt filter must not read as an empty board.
  assert_contains "$("$TODO" list --project Habit_Tracker)" "bottom sheet from the more button" \
    "list resolves a misspelt project filter"

  "$TODO" focus foreman >/dev/null
  pass "a scope resolves to a project that exists or is refused; a typo never becomes one"
}

# The other half of the same write path: an unscoped add used to take whatever
# was in focus - on a fresh install the harness scope, in a busy session the last
# crew's project. A set focus is a choice and a single project cannot be guessed
# wrong; anything else is a guess and is refused with the projects to choose.
test_an_unscoped_add_is_not_guessed() {
  local out before want
  project_dir Example_App
  project_dir habit-tracker
  "$TODO" focus --clear >/dev/null

  # Several projects, no set focus: the fallback would be a guess.
  before=$(cat "$FOREMAN_HOME/todo.tsv")
  if out=$("$TODO" add "which project is this?" 2>&1); then fail "an unscoped add was guessed with several projects and no focus"; fi
  assert_contains "$out" "Example_App" "the refusal names a project to choose"
  assert_contains "$out" "habit-tracker" "...and the other one"
  assert_equals "$before" "$(cat "$FOREMAN_HOME/todo.tsv")" "a refused unscoped add writes nothing"

  # An explicit project always wins, focus or not.
  "$TODO" add --project Example_App "explicit always wins" >/dev/null
  assert_equals "Example_App" "$(awk -F'\t' '$4 == "explicit always wins" { print $6 }' "$FOREMAN_HOME/todo.tsv")" \
    "an explicit --project is used with no focus set"

  # A focus set by the captain is a choice, not a guess: the documented default.
  "$TODO" focus habit-tracker >/dev/null
  "$TODO" add "focused item" >/dev/null
  assert_equals "habit-tracker" "$(awk -F'\t' '$4 == "focused item" { print $6 }' "$FOREMAN_HOME/todo.tsv")" \
    "a set focus still defaults an unscoped add"

  # A home with one project has nothing to guess between: the default stands.
  "$TODO" focus --clear >/dev/null
  mv "$FOREMAN_PROJECTS/Example_App" "$FOREMAN_HOME/Example_App.away"
  "$TODO" add "lone project item" >/dev/null || fail "an unscoped add was refused with one project registered"
  mv "$FOREMAN_HOME/Example_App.away" "$FOREMAN_PROJECTS/Example_App"
  want=$("$TODO" focus)
  assert_equals "$want" "$(awk -F'\t' '$4 == "lone project item" { print $6 }' "$FOREMAN_HOME/todo.tsv")" \
    "with one project the documented focus default applies unchanged"

  "$TODO" focus foreman >/dev/null
  pass "an unscoped add is refused rather than guessed when several projects could be meant"
}

test_add_and_sequence
test_list_rendering
test_note_updates_in_place
test_sanitize_protects_the_row_format
test_start_done_open_drop
test_item_lookup
test_sync_follows_the_crew
test_sync_keeps_a_delivered_crew_done
test_summary
test_scopes_keep_projects_apart
test_focus_follows_the_newest_crew
test_start_adopts_the_crews_project
test_sync_backfills_scope_from_the_crew
test_sync_folds_a_legacy_scope
test_an_unknown_scope_resolves_or_is_refused
test_an_unscoped_add_is_not_guessed
test_proposals_wait_for_the_captain
