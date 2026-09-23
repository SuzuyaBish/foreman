#!/usr/bin/env bash
# shellcheck disable=SC1010  # "done" is a subcommand argument here, not a loop terminator.
# foreman-lib.test.sh - the shared library every script stands on.
#
# Covers the pieces whose correctness the whole harness depends on: id/state/key
# validation, task records, the event fold (the one owner of "what state is this
# crew in"), open decisions, the durable wake queue, and the generation-bound
# busy record.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_home >/dev/null
. "$BIN/foreman-lib.sh"

test_id_state_key_validation() {
  local id
  # A trailing dash is accepted today (only the first character must be
  # alphanumeric). Pinned here so tightening it is a deliberate change.
  for id in a ab crew-1 a1-b2-c3 x-; do
    foreman_valid_id "$id" || fail "expected valid id: $id"
  done
  for id in "" "-x" "Upper" "under_score" "dot.dot" "space here" \
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"; do
    if foreman_valid_id "$id"; then fail "expected invalid id: '$id'"; fi
  done
  foreman_valid_id "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ||
    fail "32-char slug should be valid"

  local state
  for state in queued working blocked review done failed stopped lost; do
    foreman_valid_state "$state" || fail "expected valid state: $state"
  done
  if foreman_valid_state bogus; then fail "bogus state accepted"; fi
  if foreman_valid_state ""; then fail "empty state accepted"; fi

  # Meta/status keys are letters and underscore only (decision keys, which do
  # allow digits, are validated separately by crew-report.sh).
  for k in a a_b alpha; do
    foreman_valid_key "$k" || fail "expected valid key: $k"
  done
  for k in "" "A" "a-b" "a.b" "a b" "abc_123"; do
    if foreman_valid_key "$k"; then fail "expected invalid key: '$k'"; fi
  done
  pass "ids, states and meta keys are validated at the boundary"
}

test_config() {
  assert_equals "" "$(foreman_config_get crewModel)" "missing config reads empty"
  assert_equals "1" "$(foreman_config_bool crewIsolate 1)" "missing bool falls back to default"
  assert_equals "0" "$(foreman_config_bool crewIsolate 0)" "missing bool honours a 0 default"

  printf '{"crewModel":"m1","crewIsolate":true,"crewApprove":false}\n' >"$FOREMAN_CONFIG"
  assert_equals "m1" "$(foreman_config_get crewModel)" "string config round-trips"
  assert_equals "true" "$(foreman_config_get crewIsolate)" "boolean config renders as true"
  assert_equals "1" "$(foreman_config_bool crewIsolate 0)" "json true is truthy"
  assert_equals "0" "$(foreman_config_bool crewApprove 1)" "json false is falsy"

  # A scalar is coerced to text so an int or bool never poisons a shell compare.
  printf '1\n' >"$FOREMAN_CONFIG"
  assert_equals "" "$(foreman_config_get crewModel)" "non-object config is tolerated"
  pass "session config reads with type coercion and a default"
}

test_project_and_paths() {
  assert_equals "$FOREMAN_PROJECTS/app" "$(foreman_project_path app)" "bare name resolves under projects/"
  assert_equals "/tmp/elsewhere" "$(foreman_project_path /tmp/elsewhere)" "explicit path passes through"
  assert_equals "$FOREMAN_HOME/tasks/t1" "$(foreman_task_dir t1)" "task dir"
  assert_equals "$FOREMAN_HOME/tasks/t1/busy-state" "$(foreman_busy_record t1)" "busy record path"
  assert_equals "$FOREMAN_HOME/tasks/t1/busy-gen" "$(foreman_busy_gen t1)" "busy gen path"
  assert_equals "$FOREMAN_SESSION" "$(foreman_session)" "session name"
  assert_equals "$FOREMAN_HOME/.wake-queue" "$(foreman_queue_path)" "wake queue path"
  assert_equals "$FOREMAN_HOME/.wake-acked" "$(foreman_queue_ack_path)" "wake ack path"
  pass "path helpers are single owners"
}

test_meta_and_status() {
  fm_task t1 >/dev/null
  assert_equals "" "$(foreman_meta_get t1 pane)" "missing meta key reads empty"
  foreman_meta_set t1 pane "default:p1"
  foreman_meta_set t1 tab "tab-9"
  assert_equals "default:p1" "$(foreman_meta_get t1 pane)" "meta set/get"
  foreman_meta_set t1 pane "default:p2"
  assert_equals "default:p2" "$(foreman_meta_get t1 pane)" "meta set overwrites"
  assert_equals 1 "$(grep -c '^pane=' "$FOREMAN_HOME/tasks/t1/meta")" "meta set leaves one line per key"

  assert_equals "working" "$(foreman_status_get t1 state)" "fixture status reads"
  foreman_status_set t1 blocked "waiting on x"
  assert_equals "blocked" "$(foreman_status_get t1 state)" "status set state"
  assert_equals "waiting on x" "$(foreman_status_get t1 note)" "status set note"

  # foreman_die calls exit, so a death check on a library function runs in a
  # subshell; a real script is a process and needs no wrapping.
  if (foreman_meta_get t1 "bad-key") >/dev/null 2>&1; then fail "bad meta key accepted"; fi
  if (foreman_meta_get nonexistent pane) >/dev/null 2>&1; then fail "meta on a missing task accepted"; fi
  if (foreman_status_set t1 nonsense) >/dev/null 2>&1; then fail "bad status state accepted"; fi

  foreman_status_set t1 working
  assert_equals "working" "$(foreman_status_get t1 state)" "status reset"
  pass "task records are read, written and validated"
}

test_fold_events() {
  local f="$FOREMAN_HOME/events.test"
  fold() { foreman_fold_events "$f"; }

  rm -f "$f"
  assert_equals $'queued\t' "$(fold)" "a task with no events is queued"

  printf 'x\tworking\t\tstarted\n' >"$f"
  assert_equals $'working\tstarted' "$(fold)" "working sets state and note"

  printf 'x\tprogress\t\tstep 1\nx\tprogress\t\tstep 2\n' >>"$f"
  assert_equals $'working\tstarted' "$(fold)" "progress never changes the state or note"

  printf 'x\tneeds-decision\tq1\twhich way?\n' >>"$f"
  assert_equals $'blocked\t[q1] which way?' "$(fold)" "an open decision shows as blocked"

  printf 'x\tworking\t\tstill going\n' >>"$f"
  assert_equals $'blocked\t[q1] which way?' "$(fold)" "a later unrelated append cannot bury a decision"

  printf 'x\tresolved\tq1\tyou pick\n' >>"$f"
  assert_equals $'working\tstill going' "$(fold)" "resolving restores the latest ordinary state"

  printf 'x\tneeds-decision\tq2\tsecond?\n' >>"$f"
  printf 'x\tneeds-decision\tq3\tthird?\n' >>"$f"
  assert_equals $'blocked\t[q2] second?' "$(fold)" "the earliest open decision is surfaced first"

  printf 'x\tresolved\tq2\ta\n' >>"$f"
  assert_equals $'blocked\t[q3] third?' "$(fold)" "resolving the first surfaces the next"

  printf 'x\treview\t\tready\n' >>"$f"
  assert_equals $'review\tready' "$(fold)" "review is terminal for the fold and is not buried by an open decision"

  printf 'x\tdone\t\tshipped\n' >>"$f"
  assert_equals $'done\tshipped' "$(fold)" "done is terminal"

  # crew-report.sh makes --key mandatory, so a keyless needs-decision can only
  # arrive by hand; the fold ignores it rather than opening an unanswerable one.
  printf 'y\tneeds-decision\t\tno key here\n' >"$f"
  assert_equals $'queued\t' "$(fold)" "a keyless needs-decision does not block"
  pass "the event fold is the one owner of crew state"
}

test_open_decisions() {
  fm_task a >/dev/null
  fm_task b >/dev/null
  printf 'x\tneeds-decision\tk1\tfirst?\n' >>"$FOREMAN_HOME/tasks/a/events"
  printf 'x\tneeds-decision\tk2\tsecond?\nx\tresolved\tk2\tdone\n' >>"$FOREMAN_HOME/tasks/b/events"
  local out
  out=$(foreman_open_decisions)
  assert_equals "a	k1	first?" "$out" "only genuinely open decisions are listed"
  printf 'x\tresolved\tk1\tanswered\n' >>"$FOREMAN_HOME/tasks/a/events"
  assert_equals "" "$(foreman_open_decisions)" "a resolved key drops off the list"
  pass "open decisions survive an unrelated append and close on resolve"
}

test_status_sync() {
  fm_task t1 working >/dev/null
  printf 'x\tneeds-decision\tq\tdecide this\n' >>"$FOREMAN_HOME/tasks/t1/events"
  foreman_status_sync t1
  assert_equals "blocked" "$(foreman_status_get t1 state)" "sync folds the log into the cache"
  assert_equals "[q] decide this" "$(foreman_status_get t1 note)" "sync carries the folded note"
  pass "the derived status cache agrees with the log"
}

test_wake_queue() {
  assert_equals "0" "$(foreman_queue_acked)" "an untouched queue is acked at 0"
  assert_equals "0" "$(foreman_queue_count)" "an untouched queue is empty"

  local s1 s2
  s1=$(foreman_queue_append state "t1 review")
  s2=$(foreman_queue_append steer "t2 steer 001")
  assert_equals "1" "$s1" "first wake is sequence 1"
  assert_equals "2" "$s2" "second wake is sequence 2"
  assert_equals "2" "$(foreman_queue_count)" "both wakes are pending"
  assert_equals "state" "$(foreman_queue_pending | head -1 | cut -f3)" "rows carry their kind"

  foreman_queue_ack 1
  assert_equals "1" "$(foreman_queue_acked)" "ack moves the cursor"
  assert_equals "1" "$(foreman_queue_count)" "count respects the cursor"
  assert_equals "1" "$(foreman_queue_pending | wc -l | tr -d ' ')" "one row remains pending"
  assert_equals "2" "$(foreman_queue_pending | cut -f1)" "the remaining row is the newer one"

  printf 'garbage\n' >"$(foreman_queue_ack_path)"
  assert_equals "0" "$(foreman_queue_acked)" "a corrupt ack cursor fails closed to 0"
  if foreman_queue_ack notanumber >/dev/null 2>&1; then fail "a bad ack argument was accepted"; fi

  # The lock is released, so a second append from a fresh process still works.
  assert_equals "3" "$(foreman_queue_append state "t3 done")" "the append lock is released"
  assert_absent "$FOREMAN_HOME/.wake-queue.lock" "no lock is left behind"
  pass "the wake queue is durable, sequenced and acked by sequence"
}

test_busy_read() {
  fm_task t1 >/dev/null
  assert_equals $'unknown\tmissing' "$(foreman_busy_read t1)" "no record reads unknown/missing"

  printf 'gen-1\n' >"$FOREMAN_HOME/tasks/t1/busy-gen"
  assert_equals $'unknown\tmissing' "$(foreman_busy_read t1)" "a gen with no record is still missing"
  printf 'v1 gen=gen-1 seq=1 state=busy source=crew-ext event=agent-start ts=1\n' \
    >"$FOREMAN_HOME/tasks/t1/busy-state"
  assert_equals $'busy\tcrew-ext' "$(foreman_busy_read t1)" "a matching incarnation reads its state"

  printf 'gen-2\n' >"$FOREMAN_HOME/tasks/t1/busy-gen"
  assert_equals $'unknown\tstale-gen' "$(foreman_busy_read t1)" "a stale incarnation reads unknown, never idle"

  printf 'gen-2\n' >"$FOREMAN_HOME/tasks/t1/busy-gen"
  printf 'v1 gen=gen-2 seq=2 state=idle source=crew-ext event=agent-settled ts=1\n' \
    >"$FOREMAN_HOME/tasks/t1/busy-state"
  assert_equals $'idle\tcrew-ext' "$(foreman_busy_read t1)" "idle at the prompt reads idle"
  printf 'v1 gen=gen-2 nonsense-no-state-or-source\n' >"$FOREMAN_HOME/tasks/t1/busy-state"
  assert_equals $'unknown\tmalformed' "$(foreman_busy_read t1)" "a malformed record reads unknown"
  pass "busy state is generation-bound and fails closed"
}

test_epoch_and_age() {
  local iso epoch
  iso="2020-01-02T03:04:05Z"
  epoch=$(foreman_epoch_of "$iso")
  assert_equals "1577934245" "$epoch" "ISO-8601 UTC parses to an epoch"
  assert_equals "" "$(foreman_epoch_of not-a-date)" "an unparseable timestamp yields empty"

  fm_task t1 >/dev/null
  foreman_status_set t1 working
  local age
  age=$(foreman_age_secs t1)
  case "$age" in '' | *[!0-9]*) fail "a just-written status has a readable age (got '$age')" ;; esac
  [ "$age" -le 5 ] || fail "a just-written status is young (got ${age}s)"
  assert_equals "?" "$(foreman_age_human unknown-task 2>/dev/null)" "an unreadable status ages as '?'"
  pass "ages are computed from the status timestamp"
}

test_task_ids_are_sorted() {
  fm_task zeta >/dev/null
  fm_task alpha >/dev/null
  fm_task mid >/dev/null
  assert_equals $'a\nalpha\nb\nmid\nt1\nzeta' "$(foreman_task_ids)" "task ids are listed in sorted order"
  pass "the fleet listing order is deterministic"
}

test_id_state_key_validation
test_config
test_project_and_paths
test_meta_and_status
test_fold_events
test_open_decisions
test_status_sync
test_wake_queue
test_busy_read
test_epoch_and_age
test_task_ids_are_sorted
