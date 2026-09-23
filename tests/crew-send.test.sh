#!/usr/bin/env bash
# crew-send.test.sh - steering a crew member, and the inbox that proves delivery.
#
# Delivery is proved by the crew moving the record into handled/, never by the
# Enter key. The durable record is written before the doorbell is rung, so a
# swallowed or duplicated ring is harmless.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_home >/dev/null
fm_herdr_stub >/dev/null

SEND="$BIN/crew-send.sh"
INBOX="$BIN/crew-inbox.sh"

test_send_reaches_a_settled_crew() {
  # The incident's case: a crew reported `done` and its pane is idle at the
  # prompt. Reuse is a single send, with no ceremony and no new crew.
  fm_task t-done done >/dev/null
  fm_attach_pane t-done >/dev/null
  local out
  out=$("$SEND" t-done "the lines were too on-the-nose; use these instead")
  assert_contains "$out" "recorded" "send records against a settled crew"
  assert_contains "$out" "pane doorbell: yes" "the settled crew's pane takes the doorbell"
  assert_present "$FOREMAN_HOME/tasks/t-done/inbox/001.msg" "the instruction is durable for a done crew"
  assert_contains "$(cat "$FOREMAN_HOME/tasks/t-done/inbox/001.msg")" "on-the-nose" \
    "the follow-up requirement is carried"
  # The state is the agent's to change, not the sender's: a steer must not fake
  # a working crew, or a watcher would read a settled task as live again.
  assert_equals "done" "$(sed -n 's/^state=//p' "$FOREMAN_HOME/tasks/t-done/status")" \
    "a send does not rewrite the crew's own state"
  pass "a crew in done takes a send without ceremony"
}

test_send_writes_durable_record_and_rings() {
  fm_task t1 working >/dev/null
  fm_attach_pane t1 >/dev/null

  local out
  out=$("$SEND" t1 "please also check the error path")
  assert_contains "$out" "recorded" "send reports the record"
  assert_contains "$out" "pane doorbell: yes" "send reports the ring succeeded"

  local rec="$FOREMAN_HOME/tasks/t1/inbox/001.msg"
  assert_present "$rec" "the record is on disk"
  assert_contains "$(cat "$rec")" "please also check the error path" "the record carries the instruction"
  assert_contains "$(cat "$rec")" "at=" "the record is timestamped"
  assert_present "$FOREMAN_HOME/tasks/t1/inbox/.ring" "the ring state is recorded"
  assert_contains "$(fm_herdr_pane_runs)" "crew-inbox.sh t1" "the pane got one short doorbell"

  "$SEND" t1 "and a second one" >/dev/null
  assert_present "$FOREMAN_HOME/tasks/t1/inbox/002.msg" "a second steer gets the next number"
  pass "a steer is a durable record plus one doorbell"
}

test_inbox_reads_and_acknowledges() {
  local out
  out=$("$INBOX" t1)
  assert_contains "$out" "--- 001.msg" "the inbox labels each record"
  assert_contains "$out" "please also check the error path" "the inbox prints the instruction"
  assert_contains "$out" "--- 002.msg" "the second record is printed too"
  assert_contains "$out" "acknowledged 2 instruction(s)" "reading acknowledges"
  assert_present "$FOREMAN_HOME/tasks/t1/inbox/handled/001.msg" "the record moved to handled/"
  assert_absent "$FOREMAN_HOME/tasks/t1/inbox/001.msg" "the unread record is gone"

  out=$("$INBOX" t1)
  assert_equals "no new instructions" "$out" "a second read finds nothing to redeliver"
  pass "reading is acknowledging, and delivery is proved by handled/"
}

test_peek_does_not_acknowledge() {
  fm_task t2 working >/dev/null
  fm_attach_pane t2 >/dev/null
  "$SEND" t2 "look at this" >/dev/null
  local out
  out=$("$INBOX" t2 --peek)
  assert_contains "$out" "look at this" "peek prints the record"
  assert_not_contains "$out" "acknowledged" "peek does not acknowledge"
  assert_present "$FOREMAN_HOME/tasks/t2/inbox/001.msg" "peek leaves the record unread"
  pass "--peek inspects without consuming"
}

test_send_without_a_pane_still_records() {
  fm_task t3 working >/dev/null
  local out rc
  out=$("$SEND" t3 "no pane here" 2>/dev/null)
  rc=$?
  expect_code 0 "$rc" "an unreachable pane is not an error"
  assert_contains "$out" "pane doorbell: no" "send reports the ring did not land"
  assert_present "$FOREMAN_HOME/tasks/t3/inbox/001.msg" "the record is durable anyway"
  pass "an unreachable crew still gets a durable record"
}

test_re_ring_ladder() {
  fm_task r1 working >/dev/null
  fm_attach_pane r1 >/dev/null
  "$SEND" r1 "ring me again" >/dev/null
  "$SEND" r1 --re-ring "$FOREMAN_HOME/tasks/r1/inbox/001.msg" >/dev/null
  expect_code 0 "$?" "re-ringing a live pane and a real record succeeds"

  if "$SEND" r1 --re-ring "$FOREMAN_HOME/tasks/r1/inbox/nope.msg" >/dev/null 2>&1; then
    fail "re-ringing a missing record was accepted"
  fi

  fm_task r2 working >/dev/null
  "$SEND" r2 "durable but undeliverable" >/dev/null 2>&1
  if "$SEND" r2 --re-ring "$FOREMAN_HOME/tasks/r2/inbox/001.msg" >/dev/null 2>&1; then
    fail "re-ringing a lost pane reported success"
  fi
  pass "the re-ring path fails when the doorbell cannot land"
}

test_refusals() {
  if "$SEND" ghost "hi" >/dev/null 2>&1; then fail "sending to a missing task was accepted"; fi
  fm_task t6 working >/dev/null
  fm_attach_pane t6 >/dev/null
  if "$SEND" t6 >/dev/null 2>&1; then fail "an empty steer was accepted"; fi
  pass "sends are validated"
}

test_send_reaches_a_settled_crew
test_send_writes_durable_record_and_rings
test_inbox_reads_and_acknowledges
test_peek_does_not_acknowledge
test_send_without_a_pane_still_records
test_re_ring_ladder
test_refusals
