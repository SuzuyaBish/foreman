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
CHART="$AREAS/atlas.md"
TODAY=$(date -u +%Y-%m-%d)

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
  out=$("$AREA" add atlas --title "Atlas" --kind repo \
    --where "~/code/atlas" --bind atlas-crew)
  assert_contains "$out" "added area atlas" "add reports the area"
  assert_present "$CHART" "the chart exists"
  assert_equals "atlas" "$(field "$CHART" slug)" "the slug is filed"
  assert_equals "Atlas" "$(field "$CHART" title)" "the title is filed"
  assert_equals "repo" "$(field "$CHART" kind)" "the kind is filed"
  assert_equals "~/code/atlas" "$(field "$CHART" where)" "where is filed"
  assert_equals "atlas-crew" "$(field "$CHART" bind)" "the bind is filed"
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
  assert_contains "$out" "atlas" "list names the area"
  assert_contains "$out" "repo" "list shows the kind"
  assert_contains "$out" "$TODAY" "list shows when it was touched"

  out=$("$AREA" show atlas)
  assert_contains "$out" "slug: atlas" "show prints the header"
  assert_contains "$out" "## Log" "show prints the log"
  pass "list is one line per area and show is the whole chart"
}

test_refusals() {
  if "$AREA" add atlas >/dev/null 2>&1; then fail "a duplicate area was accepted"; fi
  if "$AREA" add "Bad Slug" >/dev/null 2>&1; then fail "a bad slug was accepted"; fi
  if "$AREA" add plain --kind nonsense >/dev/null 2>&1; then fail "a bad kind was accepted"; fi
  if "$AREA" show ghost >/dev/null 2>&1; then fail "showing a missing area was accepted"; fi
  if "$AREA" wat >/dev/null 2>&1; then fail "an unknown action was accepted"; fi
  if "$AREA" add >/dev/null 2>&1; then fail "add with no slug was accepted"; fi
  pass "only valid slugs, kinds and actions are accepted"
}

test_note_and_next() {
  local out
  out=$("$NOTE" atlas --status "parser merged; flags half done" \
    --next "add --dry-run and a test" "closed the parser PR")
  assert_contains "$out" "noted atlas" "note reports the area"
  assert_grep "- $TODAY - closed the parser PR" "$CHART" "the note is dated and logged"
  assert_equals "parser merged; flags half done" "$(field "$CHART" status)" "--status set the field"
  assert_equals "add --dry-run and a test" "$(field "$CHART" next)" "--next set the field"

  out=$("$NEXT" atlas "write the changelog")
  assert_contains "$out" "next for atlas" "next reports the step"
  assert_equals "write the changelog" "$(field "$CHART" next)" "next replaced the step"

  "$NEXT" atlas --clear >/dev/null
  assert_equals "" "$(field "$CHART" next)" "clear empties the step"

  if "$NOTE" atlas >/dev/null 2>&1; then fail "an empty note was accepted"; fi
  if "$NEXT" ghost "x" >/dev/null 2>&1; then fail "next on a missing area was accepted"; fi
  pass "a note is dated, and one note can carry status and next"
}

test_backslash_is_literal() {
  "$AREA" add esc --kind repo >/dev/null
  "$NEXT" esc 'C:\new\table' >/dev/null
  assert_equals 'C:\new\table' "$(field "$AREAS/esc.md" next)" "a backslash value is stored literally"
  pass "a backslash is a backslash, not an escape"
}

test_newline_cannot_inject_a_field() {
  local rc
  "$AREA" add inject --kind repo --title "$(printf 'Innocent\nnext: pwned')" >/dev/null 2>&1
  rc=$?
  [ "$rc" -ne 0 ] || fail "a title with a newline was accepted"
  assert_absent "$AREAS/inject.md" "a rejected add writes no chart"
  "$NEXT" esc "ok" >/dev/null
  "$NOTE" esc --status "$(printf 'fine\nnext: pwned')" "a note" >/dev/null 2>&1
  rc=$?
  [ "$rc" -ne 0 ] || fail "a status with a newline was accepted"
  assert_not_contains "$(cat "$AREAS/esc.md")" "pwned" "the injected field never landed"
  rm -f "$AREAS/esc.md"
  pass "a newline in a field value is refused, not written"
}

test_a_rejected_note_writes_nothing() {
  "$AREA" add atomic --kind repo >/dev/null
  local before rc n
  before=$(cat "$AREAS/atomic.md")
  "$NOTE" atomic --status "$(printf 'bad\nstatus: x')" "the note text" >/dev/null 2>&1
  rc=$?
  [ "$rc" -ne 0 ] || fail "a newline status was accepted"
  assert_equals "$before" "$(cat "$AREAS/atomic.md")" "a rejected note leaves the chart untouched"
  assert_not_contains "$(cat "$AREAS/atomic.md")" "the note text" "the note text was not half-written"
  n=$(find "$AREAS" -name 'atomic.md.tmp.*' | wc -l | tr -d ' ')
  assert_equals "0" "$n" "no temp file is left behind"
  rm -f "$AREAS/atomic.md"
  pass "a rejected note is all-or-nothing, with no temp left"
}

test_duplicate_fields_heal_on_write() {
  "$AREA" add dup --kind repo >/dev/null
  printf 'status: first\nstatus: second\n' >>"$AREAS/dup.md"
  "$NOTE" dup --status 'the one' 'a note' >/dev/null
  local n
  n=$(grep -c '^status:' "$AREAS/dup.md")
  assert_equals "1" "$n" "a duplicate field is dropped on the next write"
  assert_equals "the one" "$(field "$AREAS/dup.md" status)" "the surviving field is the new value"
  rm -f "$AREAS/dup.md"
  pass "a hand-edited duplicate field heals on the next write"
}

test_concurrent_notes_do_not_lose_appends() {
  "$AREA" add race --kind repo >/dev/null
  local i n
  for i in $(seq 1 40); do
    "$NOTE" race "n$i" >/dev/null 2>&1 &
  done
  wait
  n=$(grep -c '^- ' "$AREAS/race.md")
  assert_equals "40" "$n" "all concurrent appends survive the single writer"
  rm -f "$AREAS/race.md"
  pass "concurrent notes cannot lose each other's log line"
}

test_note_creates_the_log_header() {
  mkdir -p "$AREAS"
  {
    printf 'slug: hand\nkind: repo\nupdated: 2020-01-01\nstatus: ok\nnext: x\n\n'
    printf -- '- 2020-01-01 - an existing log line\n'
  } >"$AREAS/hand.md"
  "$NOTE" hand 'a new note' >/dev/null
  local content first new
  content=$(cat "$AREAS/hand.md")
  assert_contains "$content" "## Log" "a chart without a log header gets one"
  assert_contains "$content" "- 2020-01-01 - an existing log line" "the existing log line survives"
  assert_contains "$content" "a new note" "the new note is logged"
  first=$(printf '%s\n' "$content" | grep -n 'an existing log line' | cut -d: -f1)
  new=$(printf '%s\n' "$content" | grep -n 'a new note' | cut -d: -f1)
  [ -n "$first" ] && [ -n "$new" ] && [ "$new" -gt "$first" ] || fail "the new note must follow the existing log line"
  rm -f "$AREAS/hand.md"
  pass "a chart with no ## Log gets a header before its log, not a field after it"
}

test_note_appends_a_log_to_a_headerless_chart() {
  printf 'slug: bare\nkind: repo\nupdated: 2020-01-01\nstatus: ok\nnext: x\n' >"$AREAS/bare.md"
  "$NOTE" bare 'first note' >/dev/null
  local content
  content=$(cat "$AREAS/bare.md")
  assert_contains "$content" "## Log" "the log header is created"
  assert_contains "$content" "- $(date -u +%Y-%m-%d) - first note" "the note is logged"
  rm -f "$AREAS/bare.md"
  pass "a headerless chart gets a log rather than a stray field after the log lines"
}

test_show_refuses_a_traversal_slug() {
  printf 'TOP SECRET\n' >"$FOREMAN_HOME/house/secret.md"
  local out rc
  out=$("$AREA" show '../secret' 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "a traversal slug was accepted by show"
  assert_not_contains "$out" "TOP SECRET" "show did not cat a file outside the chart"
  if "$AREA" show '../../../../tmp/secret' >/dev/null 2>&1; then fail "an absolute-ish traversal was accepted"; fi
  pass "show refuses a slug that could reach outside the chart"
}

test_archive_retires_but_keeps() {
  local out
  out=$("$AREA" archive atlas)
  assert_contains "$out" "archived area atlas" "archive reports the area"
  assert_absent "$CHART" "the area left the active list"
  assert_present "$ARCHIVED/atlas.md" "the chart was moved, not deleted"
  assert_grep "slug: atlas" "$ARCHIVED/atlas.md" "the whole chart survives"

  assert_equals "house: no areas" "$("$AREA" list)" "an archived area is not listed"
  assert_contains "$("$AREA" show atlas)" "slug: atlas" "an archived chart is still readable"

  if "$AREA" archive atlas >/dev/null 2>&1; then fail "archiving an already-archived area was accepted"; fi
  pass "archiving retires an area and keeps its chart"
}

test_empty_list
test_add_creates_a_chart
test_list_and_show
test_refusals
test_show_refuses_a_traversal_slug
test_note_and_next
test_backslash_is_literal
test_newline_cannot_inject_a_field
test_a_rejected_note_writes_nothing
test_duplicate_fields_heal_on_write
test_note_creates_the_log_header
test_note_appends_a_log_to_a_headerless_chart
test_concurrent_notes_do_not_lose_appends
test_archive_retires_but_keeps
