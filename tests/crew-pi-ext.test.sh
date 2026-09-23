#!/usr/bin/env bash
# crew-pi-ext.test.sh - the extension a crew member runs with.
#
# The generated extension is how a crew member gets semantic turn state, the
# `crew_report` tool, and the Lavish loop. It is generated per launch and is
# never hand-edited, so every placeholder must be substituted and the result
# must still parse — a broken file breaks every crew launch at once.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_home >/dev/null

EXT="$BIN/crew-pi-ext.sh"

test_the_report_tool_drives_the_script() {
  # Drive the generated tool itself under node (which strips the TS types), with
  # a fake `pi`: this is the closest thing to a crew member calling crew_report.
  if ! command -v node >/dev/null 2>&1; then
    pass "crew_report tool wiring check skipped (no node)"
    return 0
  fi
  local harness out events
  harness=$(fm_tmproot crew-tool-harness)/harness.mjs
  cat >"$harness" <<'JS'
const [, , file, argsJson] = process.argv;
const mod = await import(file);
const tools = {};
const pi = { on: () => {}, registerTool: (t) => { tools[t.name] = t; }, sendUserMessage: () => {} };
mod.default(pi);
const res = await tools.crew_report.execute("call-1", JSON.parse(argsJson));
process.stdout.write("RESULT:" + (res.content?.[0]?.text ?? "") + "\n");
JS
  run_tool() { node "$harness" "$FOREMAN_HOME/tasks/e1/pi-ext.ts" "$1" 2>&1; }
  events="$FOREMAN_HOME/tasks/e1/events"

  # A plain progress report reaches the event log with its note.
  out=$(run_tool '{"verb":"progress","note":"via the tool"}')
  assert_contains "$out" "reported e1 progress" "the tool returns the script's result"
  assert_grep "via the tool" "$events" "the note reached the event log"

  # needs-decision carries the key, which is what keeps the question open.
  out=$(run_tool '{"verb":"needs-decision","note":"left or right?","key":"side"}')
  assert_contains "$out" "reported e1 needs-decision" "the decision was recorded"
  assert_grep "$(printf 'needs-decision\tside\tleft or right?')" "$events" "the key and question reached the log"
  assert_equals "blocked" "$(sed -n 's/^state=//p' "$FOREMAN_HOME/tasks/e1/status")" \
    "a keyed decision blocks the task"

  # review carries the pull request through to meta.
  out=$(run_tool '{"verb":"review","note":"ready","pr":"https://example.test/o/r/pull/9"}')
  assert_contains "$out" "reported e1 review" "the review was recorded"
  assert_equals "https://example.test/o/r/pull/9" "$(sed -n 's/^pr=//p' "$FOREMAN_HOME/tasks/e1/meta")" \
    "the pull request reached meta"
  assert_equals "9" "$(sed -n 's/^pr_number=//p' "$FOREMAN_HOME/tasks/e1/meta")" \
    "the pull request number was extracted"

  # Validation stays in the script, and its message comes back to the crew.
  out=$(run_tool '{"verb":"needs-decision","note":"q","key":"bad key"}')
  assert_contains "$out" "bare token" "a rejected call explains itself to the crew"
  pass "the crew_report tool drives the report script end to end"
}

test_generates_a_bound_extension() {
  fm_task e1 queued >/dev/null
  local gen file body
  gen=$("$BIN/crew-busy-event.sh" arm "$FOREMAN_HOME" e1 --state busy)
  file=$("$EXT" e1 "$gen")
  assert_equals "$FOREMAN_HOME/tasks/e1/pi-ext.ts" "$file" "the extension path is reported"
  assert_present "$file" "the extension is written"

  body=$(cat "$file")
  assert_not_contains "$body" "__ID__" "no task-id placeholder survives"
  assert_not_contains "$body" "__GEN__" "no generation placeholder survives"
  assert_not_contains "$body" "__HOME__" "no home placeholder survives"
  assert_not_contains "$body" "__BUSY_EVENT__" "no busy-script placeholder survives"
  assert_not_contains "$body" "__REPORT__" "no report-script placeholder survives"
  assert_not_contains "$body" "__" "no placeholder of any kind survives"

  # Bound to this task and this incarnation, with absolute paths.
  assert_contains "$body" "\"e1\"" "the task id is bound"
  assert_contains "$body" "$gen" "the busy generation is bound"
  assert_contains "$body" "$FOREMAN_HOME" "the foreman home is bound"
  assert_contains "$body" "$BIN/crew-busy-event.sh" "the busy writer is addressed directly"
  assert_contains "$body" "$BIN/crew-report.sh" "the report script is addressed directly"
  pass "the extension is generated and every placeholder is substituted"
}

test_exposes_the_expected_tools() {
  local body
  body=$(cat "$FOREMAN_HOME/tasks/e1/pi-ext.ts")
  assert_contains "$body" 'name: "crew_report"' "the reporting tool exists"
  assert_contains "$body" 'name: "lavish_open"' "the Lavish open tool exists"
  assert_contains "$body" 'name: "lavish_poll"' "the Lavish poll tool exists"

  # The report tool carries the whole CLI surface, and the home explicitly so a
  # crew shell that does not inherit FOREMAN_HOME still reports correctly.
  assert_contains "$body" "FOREMAN_HOME: HOME" "the tool passes the foreman home"
  assert_contains "$body" '"--key"' "the key flag is forwarded"
  assert_contains "$body" '"--pr"' "the pull request flag is forwarded"
  assert_contains "$body" '"needs-decision"' "the decision verb is offered"
  assert_contains "$body" '"review"' "the review verb is offered"

  # The turn state is bound to the adapter lifecycle.
  assert_contains "$body" '"agent_start"' "turn start is reported"
  assert_contains "$body" '"agent_settled"' "turn settle is reported"
  pass "the extension exposes reporting, Lavish and turn state"
}

test_generation_is_validated() {
  local gen
  gen=$(cat "$FOREMAN_HOME/tasks/e1/busy-gen")
  if "$EXT" e1 >/dev/null 2>&1; then fail "generating without a generation token was accepted"; fi
  if "$EXT" ghost "$gen" >/dev/null 2>&1; then fail "generating for a missing task was accepted"; fi
  pass "generation is refused without a task and a token"
}

test_the_generated_file_parses() {
  local file errs
  file="$FOREMAN_HOME/tasks/e1/pi-ext.ts"
  if ! command -v tsc >/dev/null 2>&1; then
    pass "generated extension syntax check skipped (no tsc)"
    return 0
  fi
  errs=$(tsc --noEmit --skipLibCheck --module esnext --moduleResolution bundler \
    --target esnext "$file" 2>&1 || true)
  # Missing ambient types (node/pi) are expected without a project tsconfig;
  # TS1xxx is the syntax/parse family, which would break every launch.
  if printf '%s\n' "$errs" | grep -qE 'error TS1[0-9]{3}'; then
    fail "the generated extension does not parse:
$errs"
  fi
  pass "the generated extension parses"
}

test_generates_a_bound_extension
test_exposes_the_expected_tools
test_generation_is_validated
test_the_generated_file_parses
test_the_report_tool_drives_the_script
