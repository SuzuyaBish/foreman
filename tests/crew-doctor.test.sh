#!/usr/bin/env bash
# crew-doctor.test.sh - checking the machine before a session starts.
#
# The doctor must fail on a missing tool the session cannot run without, warn
# about the tools only some deliveries need, and stay silent when healthy so a
# session-start hook can run it every time.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_home >/dev/null
fm_herdr_stub >/dev/null
fm_gh_stub >/dev/null
fm_pi_stub
fm_lavish_stub

DOCTOR="$BIN/crew-doctor.sh"

test_healthy_machine_reports_ok() {
  local out rc
  out=$("$DOCTOR")
  rc=$?
  expect_code 0 "$rc" "a healthy machine passes"
  assert_contains "$out" "herdr server" "the server is checked, not just the CLI"
  assert_contains "$out" "running" "a running server is reported"
  assert_contains "$out" "gh auth" "authentication is checked"
  assert_contains "$out" "lavish-axi" "the optional board tool is reported"
  assert_contains "$out" "state" "the state directory is checked"
  assert_contains "$out" "crew-doctor: ok" "the verdict is ok"
  pass "a healthy machine reports every check and passes"
}

test_quiet_is_silent_when_healthy() {
  local out rc
  out=$("$DOCTOR" --quiet)
  rc=$?
  expect_code 0 "$rc" "--quiet passes on a healthy machine"
  assert_equals "crew-doctor: ok" "$out" "--quiet prints only the verdict when healthy"
  pass "--quiet is usable from a session-start hook"
}

test_a_stopped_server_fails() {
  : >"$HERDR_STUB_STATE/server-down"
  local out rc
  out=$("$DOCTOR")
  rc=$?
  expect_code 1 "$rc" "a stopped Herdr server fails the doctor"
  assert_contains "$out" "no server is running" "the failure explains itself"

  out=$("$DOCTOR" --quiet)
  assert_contains "$out" "no server is running" "--quiet still reports a failure"
  assert_contains "$out" "1 problem(s)" "--quiet still prints a verdict"
  rm -f "$HERDR_STUB_STATE/server-down"
  pass "a missing server is a hard failure"
}

test_a_stale_server_binary_warns() {
  : >"$HERDR_STUB_STATE/server-stale"
  local out rc
  out=$("$DOCTOR")
  rc=$?
  expect_code 0 "$rc" "a stale server binary does not fail the doctor"
  assert_contains "$out" "stale" "the stale binary is surfaced"
  assert_contains "$out" "1 warning(s)" "it is counted as a warning"
  rm -f "$HERDR_STUB_STATE/server-stale"
  pass "a stale server binary is a warning, not a failure"
}

test_unauthenticated_gh_warns() {
  : >"$GH_STUB_STATE/auth-fail"
  local out rc
  out=$("$DOCTOR")
  rc=$?
  expect_code 0 "$rc" "an unauthenticated gh does not stop report work"
  assert_contains "$out" "pull-request delivery will fail" "the consequence is stated"
  assert_contains "$out" "warning" "it is counted as a warning"
  rm -f "$GH_STUB_STATE/auth-fail"
  pass "gh auth is a warning, because report and local delivery still work"
}

test_optional_and_missing_tools() {
  local out rc
  out=$(PATH=$(fm_path_without gh) "$DOCTOR")
  rc=$?
  expect_code 0 "$rc" "a missing gh does not fail the doctor"
  assert_contains "$out" "pull-request delivery is unavailable" "a missing gh is a warning"

  out=$(PATH=$(fm_path_without lavish-axi) "$DOCTOR")
  rc=$?
  expect_code 0 "$rc" "a missing lavish-axi does not fail the doctor"
  assert_contains "$out" "review boards are unavailable" "a missing lavish-axi is a warning"

  out=$(PATH=$(fm_path_without pi) "$DOCTOR")
  rc=$?
  expect_code 1 "$rc" "a missing pi fails the doctor"
  assert_contains "$out" "pi" "the missing pi is named"

  out=$(PATH=$(fm_path_without herdr) "$DOCTOR")
  rc=$?
  expect_code 1 "$rc" "a missing herdr fails the doctor"
  assert_contains "$out" "herdr" "the missing herdr is named"
  assert_not_contains "$out" "herdr server" "the server check is skipped when the CLI is absent"
  pass "required tools fail and optional tools warn"
}

test_unwritable_state_fails() {
  local dir
  dir=$(fm_tmproot doctor-state)/home
  mkdir -p "$dir"
  chmod 555 "$dir"
  if [ -w "$dir" ]; then
    chmod 755 "$dir"
    pass "state directory permissions cannot be simulated on this host"
    return 0
  fi
  local out rc
  out=$(FOREMAN_HOME="$dir" "$DOCTOR")
  rc=$?
  chmod 755 "$dir"
  expect_code 1 "$rc" "an unwritable state directory fails the doctor"
  assert_contains "$out" "not writable" "the failure names the directory"
  pass "an unwritable state directory is a hard failure"
}

test_missing_projects_warns() {
  local out rc
  out=$(FOREMAN_PROJECTS="$(fm_tmproot doctor-projects)/none" "$DOCTOR")
  rc=$?
  expect_code 0 "$rc" "a missing projects directory does not fail the doctor"
  assert_contains "$out" "missing; no project work" "it is reported as a warning"
  pass "a missing projects directory is a warning"
}

test_healthy_machine_reports_ok
test_quiet_is_silent_when_healthy
test_a_stopped_server_fails
test_a_stale_server_binary_warns
test_unauthenticated_gh_warns
test_optional_and_missing_tools
test_unwritable_state_fails
test_missing_projects_warns
