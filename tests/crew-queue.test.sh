#!/usr/bin/env bash
# crew-queue.test.sh - the durable wake queue.
#
# The queue is the crash-proof part of the wake path: rows are appended (and
# sequenced) before anything is announced, and drained by acknowledging a
# sequence, so a foreman that dies mid-notification loses nothing.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_home >/dev/null

QUEUE="$BIN/crew-queue.sh"

test_append_and_list() {
  local out
  out=$("$QUEUE" append state "t1 review")
  assert_equals "queued 1 state" "$out" "append reports the sequence and kind"
  assert_equals "queued 2 state" "$("$QUEUE" append state "t2 done")" "sequences increase"
  assert_equals "queued 3 steer" "$("$QUEUE" append steer "t1 steer 001")" "the kind is recorded"

  out=$("$QUEUE" list)
  assert_contains "$out" "SEQ" "list prints a header"
  assert_contains "$out" "KIND" "the header names the kind column"
  assert_contains "$out" "state" "list shows the kind"
  assert_contains "$out" "t1 review" "list shows the detail"
  assert_contains "$out" "ack-through 3" "list tells the foreman what to ack"

  assert_equals "3" "$("$QUEUE" count)" "count reports pending rows"

  out=$("$QUEUE" list --after 2)
  assert_not_contains "$out" "t1 review" "list --after hides rows at or below the cursor"
  assert_contains "$out" "t1 steer 001" "list --after shows later rows"
  pass "wake rows are sequenced, listed and counted"
}

test_kind_and_payload_validation() {
  if "$QUEUE" append nonsense "x" >/dev/null 2>&1; then fail "an unknown wake kind was accepted"; fi
  if "$QUEUE" append state >/dev/null 2>&1; then fail "an empty payload was accepted"; fi
  if "$QUEUE" list --after nope >/dev/null 2>&1; then fail "a non-numeric --after was accepted"; fi
  if "$QUEUE" ack >/dev/null 2>&1; then fail "ack with no sequence was accepted"; fi
  if "$QUEUE" ack nope >/dev/null 2>&1; then fail "a non-numeric ack was accepted"; fi
  pass "kinds, payloads and cursors are validated"
}

test_ack_and_clear() {
  local out
  out=$("$QUEUE" ack 2)
  assert_equals "acked through 2" "$out" "ack reports the cursor"
  assert_equals "1" "$("$QUEUE" count)" "the cursor drains acknowledged rows"
  out=$("$QUEUE" list)
  assert_not_contains "$out" "t1 review" "an acked row is no longer offered"
  assert_contains "$out" "t1 steer 001" "an unacked row survives"

  out=$("$QUEUE" clear)
  assert_equals "wake queue cleared" "$out" "clear reports"
  assert_equals "0" "$("$QUEUE" count)" "clear empties the queue"
  assert_equals "no pending wakes" "$("$QUEUE" list)" "an empty queue says so"
  pass "acknowledging and clearing are explicit"
}

test_append_and_list
test_kind_and_payload_validation
test_ack_and_clear
