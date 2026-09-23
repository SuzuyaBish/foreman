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

test_add_and_sequence() {
  local out
  out=$("$TODO" add "first item")
  assert_equals "added #1" "$out" "the first item is #1"
  assert_equals "added #2" "$("$TODO" add second item)" "the second item is #2"
  assert_equals "added #3" "$("$TODO" add --note "why it matters" third item)" "an item can carry a note"

  # A dropped row still owns its number: reusing it would rewrite history.
  "$TODO" drop 2 >/dev/null
  assert_equals "added #4" "$("$TODO" add "after a drop")" "sequence numbers never repeat"

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

test_summary() {
  local out
  out=$("$TODO" summary)
  case "$out" in
  *"items"*"open"*"active"*"done"*) : ;;
  *) fail "summary has the expected shape (got '$out')" ;;
  esac
  pass "summary is a one-line count"
}

test_add_and_sequence
test_list_rendering
test_note_updates_in_place
test_sanitize_protects_the_row_format
test_start_done_open_drop
test_sync_follows_the_crew
test_summary
