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
  assert_contains "$(cat "$ERRF")" "prescription is ready" "the refusal points at the ready prescription"
  assert_contains "$(cat "$ERRF")" "nobind-" "the refusal names the outbox file"

  "$AREA" add nobind2 --kind repo >/dev/null
  "$NEXT" nobind2 "do the thing" >/dev/null
  "$SEND" nobind2 >/dev/null 2>"$ERRF"
  rc=$?
  [ "$rc" -ne 0 ] || fail "sending with no bind and no prescription was accepted"
  assert_contains "$(cat "$ERRF")" "--copy" "with no prescription it points at --copy"
  pass "an area with no bind points at its prescription, or at --copy when there is none"
}

test_reports_a_doorbell_that_was_not_rung() {
  fm_task t2 working >/dev/null
  "$AREA" add unringable --kind repo --bind t2 >/dev/null
  "$NEXT" unringable "do the thing" >/dev/null
  "$PRESCRIBE" unringable >/dev/null 2>&1
  local out
  out=$("$SEND" unringable --yes 2>/dev/null)
  assert_contains "$out" "doorbell not rung" "an unringable pane is reported, not called sent"
  assert_not_contains "$out" "house: sent" "it is not claimed as sent"
  assert_present "$FOREMAN_HOME/tasks/t2/inbox/001.msg" "the durable record still landed"
  pass "house-send does not say sent when the doorbell was not rung"
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
  "$AREA" add atlas --title "Atlas" --kind repo --bind t1 >/dev/null
  "$NEXT" atlas "add --dry-run and a test" >/dev/null
  "$PRESCRIBE" atlas >/dev/null 2>&1

  local out
  out=$("$SEND" atlas 2>"$ERRF")
  assert_contains "$out" "dry run" "the default is a dry run"
  assert_contains "$out" "to: crew t1" "the dry run names the target"
  assert_contains "$out" "House prescription - Atlas" "the dry run shows exactly what would go"
  assert_absent "$FOREMAN_HOME/tasks/t1/inbox/001.msg" "the dry run records nothing"

  out=$("$SEND" atlas --yes 2>"$ERRF")
  assert_contains "$out" "sent atlas to crew t1" "the send is reported"
  assert_present "$FOREMAN_HOME/tasks/t1/inbox/001.msg" "the delivery is a durable record"
  assert_contains "$(cat "$FOREMAN_HOME/tasks/t1/inbox/001.msg")" "House prescription - Atlas" "the record carries the prescription"
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
  "$PRESCRIBE" atlas >/dev/null 2>&1
  sleep 1
  "$NOTE" atlas "the next step moved" >/dev/null
  "$SEND" atlas >/dev/null 2>"$ERRF"
  assert_contains "$(cat "$ERRF")" "changed since the prescription" "a stale prescription is flagged"
  pass "a prescription that predates the chart is flagged, not hidden"
}

test_refuses_without_a_bind
test_reports_a_doorbell_that_was_not_rung
test_refuses_a_bind_that_is_not_a_task
test_refuses_without_a_prescription
test_dry_run_then_send
test_bind_accepts_a_crew_prefix
test_warns_when_the_chart_moved_on
