#!/usr/bin/env bash
# crew-trust.test.sh - pi's folder-trust decisions for the paths crew work in.
#
# Crew launches pass --approve for their own run; this pre-registers the path so
# a human attaching to a crew pane is never prompted either.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_home >/dev/null
fm_git_isolate

TRUST="$BIN/crew-trust.sh"
FILE="$PI_TRUST_FILE"

test_trust_and_list() {
  local dir
  dir=$(fm_tmproot trust-target)
  local out
  out=$("$TRUST" "$dir")
  assert_contains "$out" "trusted" "trusting reports the path"
  assert_equals "true" "$(jq -r --arg p "$dir" '.[$p]' "$FILE")" "the path is recorded as trusted"
  assert_contains "$("$TRUST" --list)" "$dir" "--list prints trusted paths"
  pass "a path can be trusted and listed"
}

test_trust_is_idempotent_and_normalises() {
  local dir
  dir=$(fm_tmproot trust-normal)
  "$TRUST" "$dir" >/dev/null
  "$TRUST" "$dir" >/dev/null
  assert_equals "1" "$(grep -o -F "$dir" "$FILE" | wc -l | tr -d ' ')" \
    "trusting twice leaves one entry"
  # A trailing slash resolves to the same real path.
  "$TRUST" "$dir/" >/dev/null
  assert_equals "1" "$(grep -o -F "$dir" "$FILE" | wc -l | tr -d ' ')" \
    "a trailing slash does not create a second entry"
  pass "trusting is idempotent on real paths"
}

test_untrust() {
  local dir
  dir=$(fm_tmproot trust-remove)
  "$TRUST" "$dir" >/dev/null
  local out
  out=$("$TRUST" --remove "$dir")
  assert_contains "$out" "untrusted" "removal reports the path"
  assert_equals "null" "$(jq -r --arg p "$dir" '.[$p]' "$FILE")" "the entry is gone"
  if "$TRUST" --remove >/dev/null 2>&1; then fail "--remove with no path was accepted"; fi
  pass "a trusted path can be untrusted"
}

test_refusals_and_empty_state() {
  local file2
  if "$TRUST" >/dev/null 2>&1; then fail "trust with no arguments was accepted"; fi
  if "$TRUST" "$(fm_tmproot trust-file)/not-a-dir" >/dev/null 2>&1; then
    fail "a non-directory was trusted"
  fi

  # A home that has never been trusted says so rather than implying a decision.
  file2="$PI_TRUST_FILE"
  PI_TRUST_FILE="$(fm_tmproot trust-empty)/trust.json"
  local out
  out=$(PI_TRUST_FILE="$PI_TRUST_FILE" "$TRUST" --list)
  assert_contains "$out" "no trust file" "an absent trust file is reported"
  PI_TRUST_FILE="$file2"
  pass "bad input and an empty trust file are handled honestly"
}

test_trust_and_list
test_trust_is_idempotent_and_normalises
test_untrust
test_refusals_and_empty_state
