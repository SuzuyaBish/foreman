#!/usr/bin/env bash
# crew-handoff.test.sh - the dated note one session leaves for the next.
#
# The rule is "dated, not wiped": the note stays on disk, and what makes it
# relevant is that it is the previous session's. These tests pin the dating, the
# single ingestion, the skip when a note is stale, and that `show` never lies.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_home >/dev/null

HANDOFF="$BIN/crew-handoff.sh"
NOTE="$FOREMAN_HOME/handoff.md"
SEEN="$FOREMAN_HOME/.handoff-seen"

test_no_herdr_needed() {
  # The note is read at session start, which can be before the server is up, so
  # it must never call Herdr.
  local out
  out=$(PATH=$(fm_path_without herdr) "$HANDOFF" show)
  assert_contains "$out" "Session handoff" "the note can be read with no herdr on PATH"
  pass "the handoff reads records only"
}

test_write_dates_the_note() {
  local out
  out=$("$HANDOFF" write "crew auth-flake is in review; the migration is not started")
  assert_equals "$NOTE" "$out" "write reports the note path"
  assert_present "$NOTE" "the note is written"
  assert_grep "<!-- handoff at=" "$NOTE" "the note carries a machine-readable date"
  assert_grep "session=default" "$NOTE" "the note names the session"
  assert_grep "# Session handoff — " "$NOTE" "the note reads as dated prose"
  assert_grep "migration is not started" "$NOTE" "the body is preserved"
  pass "a handoff is written with a date and a session"
}

test_read_ingests_it_once() {
  local out
  out=$("$HANDOFF" read)
  assert_contains "$out" "migration is not started" "the first read returns the note"
  assert_present "$SEEN" "ingesting stamps the seen marker"
  assert_equals "" "$("$HANDOFF" read)" "the same note is not ingested twice"
  assert_present "$NOTE" "reading never removes the note"
  pass "the previous session's note is ingested exactly once"
}

test_show_ignores_the_marker() {
  local out
  out=$("$HANDOFF" show)
  assert_contains "$out" "migration is not started" "show reads the note back after ingestion"
  pass "the note can always be read back on demand"
}

test_a_new_note_is_ingested_again() {
  sleep 1 # the date has one-second resolution
  "$HANDOFF" write "auth-flake merged; rate-limit still blocked on the decision" >/dev/null
  local out
  out=$("$HANDOFF" read)
  assert_contains "$out" "auth-flake merged" "the newest note is ingested"
  assert_not_contains "$out" "migration is not started" "only the previous session's note is returned"
  pass "a note written after the last ingestion is news again"
}

test_a_stale_note_is_skipped() {
  # A note nobody replaced: the seen marker is past it, so it is not replayed.
  printf '%s\n' "$(($(date +%s) + 3600))" >"$SEEN"
  assert_equals "" "$("$HANDOFF" read)" "a note older than the marker is skipped"
  assert_contains "$("$HANDOFF" show)" "auth-flake merged" "show still returns it"
  pass "an un-replaced note expires instead of replaying forever"
}

test_refusals_and_empty_state() {
  local home note
  if "$HANDOFF" write >/dev/null 2>&1; then fail "an empty handoff was accepted"; fi
  if "$HANDOFF" bogus >/dev/null 2>&1; then fail "an unknown action was accepted"; fi

  home=$(fm_tmproot empty-handoff)/home
  mkdir -p "$home"
  assert_equals "" "$(FOREMAN_HOME="$home" "$HANDOFF" read)" "no note reads empty"
  assert_contains "$(FOREMAN_HOME="$home" "$HANDOFF" show)" "no handoff note" "show says there is none"

  # stdin is the other way to write one.
  FOREMAN_HOME="$home" "$HANDOFF" write <<'EOF' >/dev/null
first line
second line
EOF
  note="$home/handoff.md"
  assert_grep "first line" "$note" "the first stdin line is kept"
  assert_grep "second line" "$note" "the second stdin line is kept"
  pass "bad input and an empty home are handled honestly"
}

test_write_dates_the_note
test_read_ingests_it_once
test_show_ignores_the_marker
test_a_new_note_is_ingested_again
test_a_stale_note_is_skipped
test_no_herdr_needed
test_refusals_and_empty_state
