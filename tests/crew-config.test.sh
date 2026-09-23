#!/usr/bin/env bash
# crew-config.test.sh - per-home crew settings.
#
# Settings are stored as JSON so a reader never parses "yes", booleans are
# coerced at the boundary, and an unknown key is refused rather than silently
# written where nobody reads it.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_home >/dev/null

CONFIG="$BIN/crew-config.sh"

test_show_starts_empty() {
  assert_equals "{}" "$("$CONFIG" show)" "an unconfigured home shows an empty object"
  assert_equals "" "$("$CONFIG" get crewModel)" "a missing key reads empty"
  pass "config starts empty"
}

test_string_keys_round_trip() {
  local out
  out=$("$CONFIG" set crewModel "anthropic/claude-sonnet")
  assert_equals "crewModel=anthropic/claude-sonnet" "$out" "set echoes the write"
  assert_equals "anthropic/claude-sonnet" "$("$CONFIG" get crewModel)" "get returns the value"
  assert_equals "anthropic/claude-sonnet" "$(jq -r .crewModel "$FOREMAN_HOME/config.json")" "the value is real JSON"

  "$CONFIG" set crewThinking high >/dev/null
  assert_equals "high" "$("$CONFIG" get crewThinking)" "a second key is added without dropping the first"
  assert_equals "anthropic/claude-sonnet" "$("$CONFIG" get crewModel)" "the earlier key survives"

  "$CONFIG" unset crewThinking >/dev/null
  assert_equals "" "$("$CONFIG" get crewThinking)" "unset removes the key"
  assert_present "$FOREMAN_HOME/config.json" "the config file remains"
  pass "string settings round-trip through JSON"
}

test_booleans_are_json_booleans() {
  local out
  out=$("$CONFIG" set crewApprove yes)
  assert_equals "crewApprove=true" "$out" "yes is normalised to true"
  assert_equals "true" "$(jq -r '.crewApprove | tostring' "$FOREMAN_HOME/config.json")" "the stored value is a JSON boolean"

  "$CONFIG" set crewApprove off >/dev/null
  assert_equals "false" "$("$CONFIG" get crewApprove)" "off is normalised to false"

  "$CONFIG" set crewIsolate 1 >/dev/null
  assert_equals "true" "$("$CONFIG" get crewIsolate)" "1 is accepted as true"
  pass "booleans are coerced at the boundary"
}

test_refusals() {
  if "$CONFIG" get nonsuch >/dev/null 2>&1; then fail "an unknown key was read"; fi
  if "$CONFIG" set nonsuch value >/dev/null 2>&1; then fail "an unknown key was written"; fi
  if "$CONFIG" unset nonsuch >/dev/null 2>&1; then fail "an unknown key was unset"; fi
  if "$CONFIG" set crewApprove maybe >/dev/null 2>&1; then fail "a bad boolean was accepted"; fi
  if "$CONFIG" set crewModel >/dev/null 2>&1; then fail "set with no value was accepted"; fi
  pass "only known keys with well-typed values are accepted"
}

test_show_starts_empty
test_string_keys_round_trip
test_booleans_are_json_booleans
test_refusals
