#!/usr/bin/env bash
# house-area.test.sh - the chart: add, list, show, note, next and archive.
#
# An area is a thread, not a task: its truth is a plain-text chart under
# FOREMAN_HOME, and every verb is a file operation a human could do by hand.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_home >/dev/null

AREA="$BIN/house-area.sh"
NOTE="$BIN/house-note.sh"
NEXT="$BIN/house-next.sh"
AREAS="$FOREMAN_HOME/house/areas"
ARCHIVED="$FOREMAN_HOME/house/archived"
CHART="$AREAS/roboteur.md"
TODAY=$(date +%Y-%m-%d)

field() { # <path> <key>
  sed -n "s/^$2: //p" "$1" 2>/dev/null | head -n 1
}

test_empty_list() {
  local out
  out=$("$AREA" list)
  assert_equals "house: no areas" "$out" "an empty chart says so in one line"
  pass "a fresh home has no areas"
}

test_add_creates_a_chart() {
  local out
  out=$("$AREA" add roboteur --title "Roboteur" --kind repo \
    --where "~/code/roboteur" --bind roboteur-crew)
  assert_contains "$out" "added area roboteur" "add reports the area"
  assert_present "$CHART" "the chart exists"
  assert_equals "roboteur" "$(field "$CHART" slug)" "the slug is filed"
  assert_equals "Roboteur" "$(field "$CHART" title)" "the title is filed"
  assert_equals "repo" "$(field "$CHART" kind)" "the kind is filed"
  assert_equals "~/code/roboteur" "$(field "$CHART" where)" "where is filed"
  assert_equals "roboteur-crew" "$(field "$CHART" bind)" "the bind is filed"
  assert_equals "$TODAY" "$(field "$CHART" opened)" "opened is today"
  assert_equals "$TODAY" "$(field "$CHART" updated)" "updated starts at opened"
  assert_equals "" "$(field "$CHART" status)" "status starts empty"
  assert_equals "" "$(field "$CHART" next)" "next starts empty"
  assert_grep "## Log" "$CHART" "the chart has a log section"
  pass "add writes a complete, greppable chart"
}

test_list_and_show() {
  local out
  out=$("$AREA" list)
  assert_contains "$out" "roboteur" "list names the area"
  assert_contains "$out" "repo" "list shows the kind"
  assert_contains "$out" "$TODAY" "list shows when it was touched"

  out=$("$AREA" show roboteur)
  assert_contains "$out" "slug: roboteur" "show prints the header"
  assert_contains "$out" "## Log" "show prints the log"
  pass "list is one line per area and show is the whole chart"
}

test_refusals() {
  if "$AREA" add roboteur >/dev/null 2>&1; then fail "a duplicate area was accepted"; fi
  if "$AREA" add "Bad Slug" >/dev/null 2>&1; then fail "a bad slug was accepted"; fi
  if "$AREA" add plain --kind nonsense >/dev/null 2>&1; then fail "a bad kind was accepted"; fi
  if "$AREA" show ghost >/dev/null 2>&1; then fail "showing a missing area was accepted"; fi
  if "$AREA" wat >/dev/null 2>&1; then fail "an unknown action was accepted"; fi
  if "$AREA" add >/dev/null 2>&1; then fail "add with no slug was accepted"; fi
  pass "only valid slugs, kinds and actions are accepted"
}

test_note_and_next() {
  local out
  out=$("$NOTE" roboteur --status "parser merged; flags half done" \
    --next "add --dry-run and a test" "closed the parser PR")
  assert_contains "$out" "noted roboteur" "note reports the area"
  assert_grep "- $TODAY - closed the parser PR" "$CHART" "the note is dated and logged"
  assert_equals "parser merged; flags half done" "$(field "$CHART" status)" "--status set the field"
  assert_equals "add --dry-run and a test" "$(field "$CHART" next)" "--next set the field"

  out=$("$NEXT" roboteur "write the changelog")
  assert_contains "$out" "next for roboteur" "next reports the step"
  assert_equals "write the changelog" "$(field "$CHART" next)" "next replaced the step"

  "$NEXT" roboteur --clear >/dev/null
  assert_equals "" "$(field "$CHART" next)" "clear empties the step"

  if "$NOTE" roboteur >/dev/null 2>&1; then fail "an empty note was accepted"; fi
  if "$NEXT" ghost "x" >/dev/null 2>&1; then fail "next on a missing area was accepted"; fi
  pass "a note is dated, and one note can carry status and next"
}

test_archive_retires_but_keeps() {
  local out
  out=$("$AREA" archive roboteur)
  assert_contains "$out" "archived area roboteur" "archive reports the area"
  assert_absent "$CHART" "the area left the active list"
  assert_present "$ARCHIVED/roboteur.md" "the chart was moved, not deleted"
  assert_grep "slug: roboteur" "$ARCHIVED/roboteur.md" "the whole chart survives"

  assert_equals "house: no areas" "$("$AREA" list)" "an archived area is not listed"
  assert_contains "$("$AREA" show roboteur)" "slug: roboteur" "an archived chart is still readable"

  if "$AREA" archive roboteur >/dev/null 2>&1; then fail "archiving an already-archived area was accepted"; fi
  pass "archiving retires an area and keeps its chart"
}

test_empty_list
test_add_creates_a_chart
test_list_and_show
test_refusals
test_note_and_next
test_archive_retires_but_keeps
