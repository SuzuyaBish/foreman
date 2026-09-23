#!/usr/bin/env bash
# crew-e2e-live.test.sh - the whole wire, for real (opt-in).
#
# The rest of the suite stubs herdr, pi and gh. This file stubs nothing: it cuts
# a real worktree, opens a real Herdr pane, launches a real pi crew member, waits
# for it to work, reads its report back through the real tools, steers it with a
# real inbox record and waits for the ack. It is the answer to "does the wire
# work", which no amount of stubbing can give you.
#
#   FOREMAN_E2E=1 bin/crew-test.sh tests/crew-e2e-live.test.sh
#
# Knobs: FOREMAN_E2E_TIMEOUT (seconds per wait stage, default 300),
#        FOREMAN_E2E_MODEL (passed to the crew; default is the pi default).
#
# Cost and side effects, all deliberate:
#   * it spends real model tokens on a trivial task (two short turns);
#   * it opens a real Herdr tab and closes it again in the trap, even on failure;
#   * it registers folder trust for a throwaway worktree, because an unattended
#     pane cannot answer a trust prompt. PI_TRUST_FILE is unset here on purpose:
#     the pane's own pi reads the real trust file, not this shell's.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ "${FOREMAN_E2E:-0}" != 1 ]; then
  echo "skip: set FOREMAN_E2E=1 to run the live wire (costs real model tokens)"
  exit 0
fi
for tool in herdr pi git jq; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "skip: $tool is not on PATH"
    exit 0
  }
done
if ! herdr --session "${FOREMAN_SESSION:-default}" workspace list >/dev/null 2>&1; then
  echo "skip: no Herdr server on session ${FOREMAN_SESSION:-default}"
  exit 0
fi

TIMEOUT=${FOREMAN_E2E_TIMEOUT:-300}
case "$TIMEOUT" in '' | *[!0-9]*) TIMEOUT=300 ;; esac

AMBIENT_WS=${HERDR_WORKSPACE_ID:-}
fm_home >/dev/null
# A live run is most realistic beside the captain: when this shell is already in
# a Herdr workspace, the crew's tab belongs there, exactly as a foreman session
# would place it. fm_home clears the var for isolation, so put it back.
[ -z "$AMBIENT_WS" ] || export HERDR_WORKSPACE_ID="$AMBIENT_WS"
# The pane starts pi with the real environment; a temp trust file would not be
# read there, so trust has to be registered for real or the pane would sit on a
# prompt. See the header.
unset PI_TRUST_FILE

ID=e2e-live-$$
BRANCH="crew/$ID"
PROJ="$FOREMAN_PROJECTS/e2e-sandbox"
WT="$FOREMAN_WORKTREES/$ID"
TAB=
WS=

cleanup() {
  # The pane is the only thing here that outlives the test, so it is closed
  # first and unconditionally.
  "$BIN/crew-stop.sh" "$ID" --close --reason "e2e cleanup" >/dev/null 2>&1 || true
  if [ -n "${TAB:-}" ]; then
    herdr --session "${FOREMAN_SESSION:-default}" tab close "$TAB" >/dev/null 2>&1 || true
  fi
  # Only close a workspace this test created; never one the captain was in.
  if [ -z "$AMBIENT_WS" ] && [ -n "${WS:-}" ] && [ "$WS" != "$AMBIENT_WS" ]; then
    herdr --session "${FOREMAN_SESSION:-default}" workspace close "$WS" >/dev/null 2>&1 || true
  fi
  fm_test_cleanup
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

state_of() { sed -n 's/^state=//p' "$FOREMAN_HOME/tasks/$ID/status" 2>/dev/null; }
events_n() { wc -l <"$FOREMAN_HOME/tasks/$ID/events" 2>/dev/null | tr -d ' '; }
events_grew() { [ "$(events_n)" -gt "$BEFORE_N" ]; }
busy_settled() { grep -q 'state=idle' "$FOREMAN_HOME/tasks/$ID/busy-state" 2>/dev/null; }
tab_exists() { herdr --session "${FOREMAN_SESSION:-default}" tab list 2>/dev/null | grep -q "$TAB"; }

# wait_for <description> <predicate...>: poll until the predicate holds.
wait_for() {
  local what=$1
  shift
  local waited=0
  while [ "$waited" -lt "$TIMEOUT" ]; do
    if "$@"; then return 0; fi
    sleep 5
    waited=$((waited + 5))
  done
  fail "$what did not happen within ${TIMEOUT}s (state=$(state_of) note=$(sed -n 's/^note=//p' "$FOREMAN_HOME/tasks/$ID/status" 2>/dev/null))"
}
settled() { # a state the crew cannot still be working out of
  case "$(state_of)" in
  done | review | failed | blocked | stopped) return 0 ;;
  *) return 1 ;;
  esac
}

# --- a real project ---------------------------------------------------------

mkdir -p "$PROJ"
git -C "$PROJ" init -q -b main
git -C "$PROJ" config user.name "E2E Captain"
git -C "$PROJ" config user.email "e2e@example.test"
printf 'seed\n' >"$PROJ/seed.txt"
git -C "$PROJ" add seed.txt
git -C "$PROJ" commit -qm "seed"
BASE_N=$(git -C "$PROJ" rev-list --count HEAD)

BEFORE_N=0
test_a_real_crew_does_the_whole_trip() {
  local out
  local -a model_args=()
  [ -z "${FOREMAN_E2E_MODEL:-}" ] || model_args=(--model "$FOREMAN_E2E_MODEL")
  out=$("$BIN/crew-spawn.sh" "$ID" --project e2e-sandbox --delivery local \
    ${model_args[@]+"${model_args[@]}"} -- \
    "Add a file GREETING.md whose only content is this line: hello from the crew. Commit it on the current branch. Then report done with a one-line summary.") ||
    fail "spawn failed: $out"
  assert_contains "$out" "worktree" "the crew got an isolated worktree"
  TAB=$(sed -n 's/^tab=//p' "$FOREMAN_HOME/tasks/$ID/meta")
  WS=$(sed -n 's/^workspace=//p' "$FOREMAN_HOME/tasks/$ID/meta")
  [ -n "$TAB" ] || fail "no Herdr tab was recorded"
  pass "a real crew spawns into a real Herdr pane and worktree"

  # It has to be alive in a pane a human could attach to, not just a directory.
  wait_for "the Herdr tab to exist" tab_exists

  wait_for "the crew reaching a terminal state" settled
  assert_equals "done" "$(state_of)" "the crew reports done"

  # The work must be real git work, not a sentence claiming work happened.
  assert_present "$WT/GREETING.md" "the crew wrote its file"
  assert_equals "hello from the crew" "$(head -1 "$WT/GREETING.md")" "the file has the asked-for line"
  assert_equals "$((BASE_N + 1))" "$(git -C "$WT" rev-list --count HEAD)" "there is exactly one new commit"
  assert_equals "GREETING.md" "$(git -C "$WT" show --pretty=format: --name-only HEAD | head -1)" \
    "the new commit is the crew's file"
  assert_equals "" "$(git -C "$WT" status --porcelain)" "the crew left nothing uncommitted"
  assert_equals "$BRANCH" "$(git -C "$WT" rev-parse --abbrev-ref HEAD)" "the work is on $BRANCH"

  # A done status with no report is a failed task; the report is the deliverable.
  [ -s "$FOREMAN_HOME/tasks/$ID/report.md" ] || fail "the crew reported done without a report"
  assert_contains "$(cat "$FOREMAN_HOME/tasks/$ID/report.md")" "GREETING.md" "the report describes the work"

  # The foreman-side readers see the same thing the files say.
  assert_contains "$("$BIN/crew-read.sh" "$ID")" "hello from the crew" "crew_read returns the report"
  assert_contains "$("$BIN/crew-digest.sh")" "1 crew (1 done)" "the digest counts the finished crew"
  # `done` is reported mid-turn, so the turn end — and with it the busy record's
  # rewrite — arrives slightly later. Waiting for it is the live proof that the
  # generated extension's agent start/settle handlers really are wired in.
  wait_for "the crew's extension to report the turn ended" busy_settled
  assert_contains "$(cat "$FOREMAN_HOME/tasks/$ID/busy-state")" "source=crew-ext" \
    "the busy record came from the crew's own extension"
  pass "the spawn -> work -> commit -> report -> read chain is real"
}

test_a_real_steer_is_delivered_and_acked() {
  local before_hash
  before_hash=$(git -C "$WT" rev-parse HEAD)
  BEFORE_N=$(events_n)

  "$BIN/crew-send.sh" "$ID" \
    "Steer check: append a second line containing exactly the word: steered. Amend your existing commit, then report done again." \
    >/dev/null || fail "the steer could not be recorded"

  # Delivery is proved by the crew moving the record into handled/, never by the
  # doorbell landing in the pane.
  wait_for "the crew acknowledging the steer" test -f "$FOREMAN_HOME/tasks/$ID/inbox/handled/001.msg"
  pass "a real steer reaches the crew and comes back acknowledged"

  wait_for "the crew reporting again" events_grew
  assert_equals "done" "$(state_of)" "the steered crew is done again"
  assert_equals "steered" "$(tail -1 "$WT/GREETING.md")" "the steer changed the work"
  assert_equals "$((BASE_N + 1))" "$(git -C "$WT" rev-list --count HEAD)" "the steer amended rather than added"
  [ "$(git -C "$WT" rev-parse HEAD)" != "$before_hash" ] || fail "the amend produced no new commit"
  pass "the steered change is committed and the crew re-reported"
}

test_the_task_retires_cleanly() {
  local tab=$TAB
  "$BIN/crew-stop.sh" "$ID" --close --reason "e2e complete" >/dev/null ||
    fail "the crew could not be stopped"
  TAB=
  "$BIN/crew-archive.sh" "$ID" --worktree >/dev/null || fail "the task could not be archived"
  assert_absent "$WT" "archiving removed the worktree"
  assert_present "$FOREMAN_HOME/archive/$ID/report.md" "archiving kept the task intact"
  assert_absent "$FOREMAN_HOME/tasks/$ID" "archiving retired the task from the active set"
  if herdr --session "${FOREMAN_SESSION:-default}" tab list 2>/dev/null | grep -q "$tab"; then
    fail "the crew's tab outlived the stop"
  fi
  pass "stop closes the pane and archive retires the task without deleting anything"
}

test_a_real_crew_does_the_whole_trip
test_a_real_steer_is_delivered_and_acked
test_the_task_retires_cleanly
