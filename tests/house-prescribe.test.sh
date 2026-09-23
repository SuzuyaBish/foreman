#!/usr/bin/env bash
# house-prescribe.test.sh - the prescription: paste-ready, outboxed, copyable.
#
# A prescription is the whole point: a prompt built from the chart that a fresh
# chat can act on with none of this conversation. stdout is exactly the prompt
# (so it can be piped or pasted); the outbox path and clipboard news go to
# stderr. --copy must never fail when there is no clipboard.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_home >/dev/null

AREA="$BIN/house-area.sh"
NOTE="$BIN/house-note.sh"
NEXT="$BIN/house-next.sh"
PRESCRIBE="$BIN/house-prescribe.sh"
OUTBOX="$FOREMAN_HOME/house/outbox"
ERRF="$FOREMAN_HOME/prescribe.err"

test_copy_reports_a_failing_clipboard() {
  fm_fakebin
  cat >"$FM_FAKEBIN/pbcopy" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
exit 1
SH
  chmod +x "$FM_FAKEBIN/pbcopy"
  local rc
  "$PRESCRIBE" atlas --stdout --copy >/dev/null 2>"$ERRF"
  rc=$?
  expect_code 0 "$rc" "a failing clipboard tool is not an error"
  assert_contains "$(cat "$ERRF")" "failed" "a tool that exists but failed is distinguished"
  assert_not_contains "$(cat "$ERRF")" "no clipboard tool" "a failure is not reported as a missing tool"
  pass "--copy tells a missing clipboard from a failing one"
}

test_latest_outbox_reads_the_numeric_suffix() {
  rm -rf "$OUTBOX"
  mkdir -p "$OUTBOX"
  : >"$OUTBOX/atlas-20260101T000000Z.md"
  : >"$OUTBOX/atlas-20260101T000000Z-2.md"
  local got
  got=$(. "$BIN/house-lib.sh" && house_latest_outbox atlas)
  assert_equals "$OUTBOX/atlas-20260101T000000Z-2.md" "$got" "the numbered suffix is the newest, not '.<ts>'"
  : >"$OUTBOX/atlas-20260102T000000Z.md"
  got=$(. "$BIN/house-lib.sh" && house_latest_outbox atlas)
  assert_equals "$OUTBOX/atlas-20260102T000000Z.md" "$got" "a later timestamp beats an earlier suffixed file"
  pass "latest outbox is newest by timestamp, then by numeric suffix"
}

test_reports_an_archived_area() {
  "$AREA" archive atlas >/dev/null
  local rc
  "$PRESCRIBE" atlas >/dev/null 2>"$ERRF"
  rc=$?
  [ "$rc" -ne 0 ] || fail "prescribing an archived area was accepted"
  assert_contains "$(cat "$ERRF")" "archived" "the refusal says the area is archived"
  assert_contains "$(cat "$ERRF")" "unarchive" "the refusal points at unarchive"
  pass "prescribe names an archived area instead of 'no such area'"
}

test_refuses_without_a_next() {
  "$AREA" add blank --kind repo >/dev/null
  local rc
  "$PRESCRIBE" blank >/dev/null 2>"$ERRF"
  rc=$?
  [ "$rc" -ne 0 ] || fail "prescribing an area with no next step was accepted"
  assert_contains "$(cat "$ERRF")" "no diagnosed next step" "the refusal says why"
  assert_contains "$(cat "$ERRF")" "house-next.sh" "the refusal points at the fix"
  pass "a prescription needs a diagnosed next step"
}

test_refuses_a_whitespace_only_next() {
  "$AREA" add blankish --kind repo >/dev/null
  "$NEXT" blankish '   ' >/dev/null
  local rc
  "$PRESCRIBE" blankish >/dev/null 2>"$ERRF"
  rc=$?
  [ "$rc" -ne 0 ] || fail "a whitespace-only next was prescribed"
  assert_contains "$(cat "$ERRF")" "no diagnosed next step" "whitespace is refused like no next"
  pass "a whitespace-only next cannot diagnose an empty step"
}

test_stdout_is_paste_ready() {
  "$AREA" add atlas --title "Atlas" --kind repo --where "~/code/atlas" >/dev/null
  "$NOTE" atlas --status "parser merged; flags half done" "closed the parser PR" >/dev/null
  "$NEXT" atlas "add --dry-run and a test for it" >/dev/null

  local out err
  out=$("$PRESCRIBE" atlas 2>"$ERRF")
  err=$(cat "$ERRF")
  assert_contains "$out" "House prescription - Atlas" "the prompt names the area"
  assert_contains "$out" "Where it stands:" "the prompt carries the status"
  assert_contains "$out" "parser merged; flags half done" "the status is the chart's"
  assert_contains "$out" "Diagnosed next step:" "the prompt labels the step"
  assert_contains "$out" "add --dry-run and a test for it" "the step is the chart's"
  assert_contains "$out" "Standing conventions:" "the conventions are included"
  assert_contains "$out" "pull request" "a repo area is delivered as a PR"
  assert_contains "$err" "wrote" "the outbox path is reported on stderr"
  assert_present "$OUTBOX/atlas-"*.md "the prompt landed in the outbox"
  assert_contains "$(cat "$OUTBOX"/atlas-*.md)" "House prescription - Atlas" "the outbox holds the prompt"
  pass "prescribe prints a self-contained prompt and outboxes it"
}

test_stdout_skips_the_outbox() {
  rm -rf "$OUTBOX"
  local out
  out=$("$PRESCRIBE" atlas --stdout 2>/dev/null)
  assert_contains "$out" "House prescription - Atlas" "the prompt is still printed"
  assert_absent "$OUTBOX" "--stdout writes no outbox"
  pass "--stdout is the pure pipe"
}

test_delivery_follows_the_kind() {
  "$AREA" add harbour-chat --title "Harbour app" --kind chat --where "the app chat" >/dev/null
  "$NEXT" harbour-chat "wire the accounts tab to the new API" >/dev/null
  local out
  out=$("$PRESCRIBE" harbour-chat --stdout 2>/dev/null)
  assert_contains "$out" "report file" "a chat area is delivered as a report"
  assert_contains "$out" "not a repository" "the prompt says why there is no PR"
  assert_not_contains "$out" "Commit on a branch" "a chat area does not get PR instructions"
  pass "repo areas get a PR, every other kind gets a report"
}

test_context_is_appended() {
  printf 'the API key lives in 1Password\n' >"$FOREMAN_HOME/ctx.md"
  local out
  out=$("$PRESCRIBE" atlas --stdout --context "$FOREMAN_HOME/ctx.md" 2>/dev/null)
  assert_contains "$out" "Extra context" "the context is labelled"
  assert_contains "$out" "the API key lives in 1Password" "the context body is included"
  if "$PRESCRIBE" atlas --stdout --context "$FOREMAN_HOME/nope.md" >/dev/null 2>&1; then
    fail "a missing context file was accepted"
  fi
  pass "--context appends a file and refuses a missing one"
}

test_copy_uses_a_clipboard_when_present() {
  fm_fakebin
  cat >"$FM_FAKEBIN/pbcopy" <<'SH'
#!/usr/bin/env bash
cat >"${PBCLIP:?}"
SH
  chmod +x "$FM_FAKEBIN/pbcopy"
  local rc
  PBCLIP="$FOREMAN_HOME/clip.txt" "$PRESCRIBE" atlas --stdout --copy >/dev/null 2>"$ERRF"
  rc=$?
  expect_code 0 "$rc" "copy with a clipboard tool succeeds"
  assert_present "$FOREMAN_HOME/clip.txt" "the clipboard tool received the prompt"
  assert_contains "$(cat "$FOREMAN_HOME/clip.txt")" "House prescription - Atlas" "what was copied is the prompt"
  assert_contains "$(cat "$ERRF")" "copied to clipboard" "copy is reported"
  pass "--copy puts the prescription on the clipboard"
}

test_copy_degrades_without_a_clipboard() {
  local sans rc
  sans=$(fm_path_without pbcopy xclip wl-copy)
  PATH="$sans" "$PRESCRIBE" atlas --stdout --copy >/dev/null 2>"$ERRF"
  rc=$?
  expect_code 0 "$rc" "no clipboard tool is not an error"
  assert_contains "$(cat "$ERRF")" "no clipboard tool" "the degradation is explained"
  pass "--copy degrades with a message instead of failing"
}

test_outbox_collisions_do_not_overwrite() {
  rm -rf "$OUTBOX"
  "$PRESCRIBE" atlas >/dev/null 2>&1
  "$PRESCRIBE" atlas >/dev/null 2>&1
  local n
  n=$(find "$OUTBOX" -name 'atlas-*.md' | wc -l | tr -d ' ')
  assert_equals "2" "$n" "two prescriptions in the same second do not overwrite"
  pass "the outbox keeps every prescription"
}

test_refuses_without_a_next
test_refuses_a_whitespace_only_next
test_stdout_is_paste_ready
test_stdout_skips_the_outbox
test_delivery_follows_the_kind
test_context_is_appended
test_copy_uses_a_clipboard_when_present
test_copy_degrades_without_a_clipboard
test_copy_reports_a_failing_clipboard
test_outbox_collisions_do_not_overwrite
test_latest_outbox_reads_the_numeric_suffix
test_reports_an_archived_area
