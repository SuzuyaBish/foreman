#!/usr/bin/env bash
# house-send.test.sh - delivering a prescription, dry-run first.
#
# Sending is the one act that is hard to take back, so it is opt-in, one area at
# a time, and dry by default. Delivery reuses crew-send's durable inbox record
# rather than inventing a second mechanism, and an area with no usable bind is
# refused with a pointer at --copy.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_home >/dev/null
fm_herdr_stub >/dev/null

AREA="$BIN/house-area.sh"
NEXT="$BIN/house-next.sh"
NOTE="$BIN/house-note.sh"
PRESCRIBE="$BIN/house-prescribe.sh"
SEND="$BIN/house-send.sh"
ERRF="$FOREMAN_HOME/send.err"

test_refuses_without_a_bind() {
  "$AREA" add nobind --kind repo >/dev/null
  "$NEXT" nobind "do the thing" >/dev/null
  "$PRESCRIBE" nobind >/dev/null 2>&1
  local rc
  "$SEND" nobind >/dev/null 2>"$ERRF"
  rc=$?
  [ "$rc" -ne 0 ] || fail "sending an area with no bind was accepted"
  assert_contains "$(cat "$ERRF")" "--copy" "the refusal points at the clipboard path"
  pass "an area with no bind is refused, pointing at --copy"
}

test_refuses_a_bind_that_is_not_a_task() {
  "$AREA" add badbind --kind repo --bind ghost-crew >/dev/null
  "$NEXT" badbind "do the thing" >/dev/null
  "$PRESCRIBE" badbind >/dev/null 2>&1
  if "$SEND" badbind >/dev/null 2>&1; then fail "a bind naming no task was accepted"; fi
  pass "a bind that names no crew task is refused, not guessed at"
}

test_refuses_without_a_prescription() {
  fm_task t9 working >/dev/null
  fm_attach_pane t9 >/dev/null
  "$AREA" add unprescribed --kind repo --bind t9 >/dev/null
  "$NEXT" unprescribed "do the thing" >/dev/null
  local rc
  "$SEND" unprescribed >/dev/null 2>"$ERRF"
  rc=$?
  [ "$rc" -ne 0 ] || fail "sending with no prescription was accepted"
  assert_contains "$(cat "$ERRF")" "no prescription" "the refusal says to prescribe first"
  pass "there has to be a prescription to send"
}

test_dry_run_then_send() {
  fm_task t1 working >/dev/null
  fm_attach_pane t1 >/dev/null
  "$AREA" add roboteur --title "Roboteur" --kind repo --bind t1 >/dev/null
  "$NEXT" roboteur "add --dry-run and a test" >/dev/null
  "$PRESCRIBE" roboteur >/dev/null 2>&1

  local out
  out=$("$SEND" roboteur 2>"$ERRF")
  assert_contains "$out" "dry run" "the default is a dry run"
  assert_contains "$out" "to: crew t1" "the dry run names the target"
  assert_contains "$out" "House prescription - Roboteur" "the dry run shows exactly what would go"
  assert_absent "$FOREMAN_HOME/tasks/t1/inbox/001.msg" "the dry run records nothing"

  out=$("$SEND" roboteur --yes 2>"$ERRF")
  assert_contains "$out" "sent roboteur to crew t1" "the send is reported"
  assert_present "$FOREMAN_HOME/tasks/t1/inbox/001.msg" "the delivery is a durable record"
  assert_contains "$(cat "$FOREMAN_HOME/tasks/t1/inbox/001.msg")" "House prescription - Roboteur" "the record carries the prescription"
  pass "a dry run sends nothing, and --yes delivers the durable record"
}

test_bind_accepts_a_crew_prefix() {
  "$AREA" add prefixed --title "Prefixed" --kind repo --bind "crew:t1" >/dev/null
  "$NEXT" prefixed "ship the fix" >/dev/null
  "$PRESCRIBE" prefixed >/dev/null 2>&1
  local out
  out=$("$SEND" prefixed --yes 2>/dev/null)
  assert_contains "$out" "sent prefixed to crew t1" "the crew: prefix resolves to the task"
  assert_present "$FOREMAN_HOME/tasks/t1/inbox/002.msg" "the prefixed bind delivers too"
  pass "a bind may carry a crew: prefix"
}

test_warns_when_the_chart_moved_on() {
  "$PRESCRIBE" roboteur >/dev/null 2>&1
  sleep 1
  "$NOTE" roboteur "the next step moved" >/dev/null
  "$SEND" roboteur >/dev/null 2>"$ERRF"
  assert_contains "$(cat "$ERRF")" "changed since the prescription" "a stale prescription is flagged"
  pass "a prescription that predates the chart is flagged, not hidden"
}

test_refuses_without_a_bind
test_refuses_a_bind_that_is_not_a_task
test_refuses_without_a_prescription
test_dry_run_then_send
test_bind_accepts_a_crew_prefix
test_warns_when_the_chart_moved_on
