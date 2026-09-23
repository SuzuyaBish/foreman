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

  "$CONFIG" set crewCalm on >/dev/null
  assert_equals "true" "$("$CONFIG" get crewCalm)" "crewCalm is a boolean, as /crew calm writes it"
  assert_equals "true" "$(jq -r '.crewCalm | tostring' "$FOREMAN_HOME/config.json")" "the calm choice lands in the config the extension reads"
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

# Every setting the README documents must be writable here, and this script is the
# only writer. It drifted once: `crewWake` and `crewWidget` were read by the chrome
# and written by `/crew on|off`, promised in the README's settings table, and
# refused by this script - so the toggle wrote nothing and said why. The
# documented table is read below rather than restated, so the promise and the
# writer cannot disagree again.
test_every_documented_key_is_writable() {
  local keys key
  keys=$(grep -oE '^\| `[a-zA-Z]+`' "$ROOT/README.md" | tr -d '|` ')
  [ -n "$keys" ] || fail "the README no longer documents any crew settings"
  assert_contains "$keys" "crewWake" "the settings table covers the wake"
  assert_contains "$keys" "trustPaths" "the settings table covers the non-crew-prefixed key"
  for key in $keys; do
    "$CONFIG" set "$key" true >/dev/null 2>&1 || fail "documented key $key was refused"
  done
  assert_equals "crewWidget=false" "$("$CONFIG" set crewWidget false)" "crewWidget is a boolean, as /crew on|off writes it"
  assert_equals "false" "$(jq -r '.crewWidget | tostring' "$FOREMAN_HOME/config.json")" "the widget toggle lands in the config the chrome reads"
  assert_equals "crewWake=false" "$("$CONFIG" set crewWake false)" "crewWake is a boolean, as the wake reads it"
  assert_equals "false" "$(jq -r '.crewWake | tostring' "$FOREMAN_HOME/config.json")" "the wake setting lands in the config the extension reads"
  pass "every documented setting is writable through the one script that owns them"
}

# The foreman fires `set crewModel` and `set crewThinking` as parallel tool calls.
# Unlocked, both read the old file and the last mv won: crewModel vanished and the
# next crew ran silently on the wrong model. Every key in KEYS is written at once,
# three rounds over (27 concurrent writers), and every write must survive.
test_concurrent_sets_all_survive() {
  local round key val i pids
  for round in 1 2 3; do
    pids=()
    for key in crewModel crewThinking crewDelivery; do
      "$CONFIG" set "$key" "$key-r$round" >/dev/null 2>&1 &
      pids+=($!)
    done
    for key in crewApprove crewIsolate trustPaths crewWake crewWidget crewCalm; do
      val=true
      [ $((round % 2)) -eq 0 ] && val=false
      "$CONFIG" set "$key" "$val" >/dev/null 2>&1 &
      pids+=($!)
    done
    for i in "${pids[@]}"; do
      wait "$i" || fail "a concurrent set failed in round $round"
    done
    jq -e . "$FOREMAN_HOME/config.json" >/dev/null 2>&1 || fail "config.json is not valid JSON after round $round"
    for key in crewModel crewThinking crewDelivery; do
      assert_equals "$key-r$round" "$(jq -r --arg k "$key" '.[$k]' "$FOREMAN_HOME/config.json")" \
        "round $round: $key survived its concurrent siblings"
    done
    val=true
    [ $((round % 2)) -eq 0 ] && val=false
    for key in crewApprove crewIsolate trustPaths crewWake crewWidget crewCalm; do
      assert_equals "$val" "$(jq -r --arg k "$key" '.[$k] | tostring' "$FOREMAN_HOME/config.json")" \
        "round $round: $key survived its concurrent siblings"
    done
  done

  # Concurrent unsets and sets on disjoint keys: each lands.
  pids=()
  for key in crewModel crewThinking crewDelivery; do
    "$CONFIG" unset "$key" >/dev/null 2>&1 &
    pids+=($!)
  done
  for key in crewApprove crewIsolate trustPaths crewWake crewWidget crewCalm; do
    "$CONFIG" set "$key" on >/dev/null 2>&1 &
    pids+=($!)
  done
  for i in "${pids[@]}"; do
    wait "$i" || fail "a concurrent set or unset failed"
  done
  assert_equals "6" "$(jq 'length' "$FOREMAN_HOME/config.json")" "the unsets and sets all landed"
  assert_equals "true" "$(jq -r '[.[]] | all | tostring' "$FOREMAN_HOME/config.json")" "every set boolean is true"

  assert_absent "$FOREMAN_HOME/config.json.lock" "the lock is released"
  assert_equals "" "$(find "$FOREMAN_HOME" -maxdepth 1 -name 'config.json.tmp.*')" "no temp file is left behind"
  pass "concurrent sets and unsets on different keys never lose a write"
}

# A writer killed while it held the lock must not wedge every later write, and a
# writer that is alive and busy must not have its lock broken from under it.
test_stale_lock_is_broken_live_lock_is_not() {
  local lock="$FOREMAN_HOME/config.json.lock" out rc start

  # A real killed holder: it takes the lock, records itself, and is SIGKILLed.
  # (A child sh, not a subshell: bash 3.2, the macOS default, has no BASHPID.)
  { sh -c 'mkdir "$1" && echo $$ >"$1/pid" && kill -9 $$' sh "$lock"; } 2>/dev/null
  [ -s "$lock/pid" ] || fail "the killed writer did not record itself"
  assert_present "$lock" "the killed writer left its lock behind"
  start=$SECONDS
  out=$(FOREMAN_LOCK_WAIT=5 "$CONFIG" set crewModel after-kill 2>&1) || fail "set behind a dead holder failed: $out"
  [ $((SECONDS - start)) -lt 3 ] || fail "breaking a dead holder's lock took the whole wait"
  assert_equals "after-kill" "$("$CONFIG" get crewModel)" "the write behind a stale lock landed"
  assert_absent "$lock" "the stale lock is gone"

  # A lock with no pid (a writer killed between mkdir and recording itself) is
  # stale once it is old, not before.
  mkdir "$lock"
  touch -t 200001010000 "$lock"
  out=$(FOREMAN_LOCK_WAIT=5 "$CONFIG" set crewThinking after-old 2>&1) || fail "set behind an old pid-less lock failed: $out"
  assert_equals "after-old" "$("$CONFIG" get crewThinking)" "an old pid-less lock is broken"
  assert_absent "$lock" "the old pid-less lock is gone"

  # A live holder: the wait is bounded and the failure is loud, not a silent drop.
  mkdir "$lock"
  printf '%s\n' "$$" >"$lock/pid"
  rc=0
  out=$(FOREMAN_LOCK_WAIT=1 "$CONFIG" set crewModel while-held 2>&1) || rc=$?
  assert_not_equals "0" "$rc" "set behind a live holder fails instead of writing"
  assert_contains "$out" "could not lock" "the failure says why"
  assert_contains "$out" "$$" "the failure names the holder"
  assert_equals "after-kill" "$("$CONFIG" get crewModel)" "nothing was written while the lock was held"
  assert_present "$lock/pid" "a live holder's lock is never broken"
  rm -rf "$lock"
  pass "a dead writer's lock is broken; a live writer's lock is waited on, then refused loudly"
}

test_show_starts_empty
test_string_keys_round_trip
test_booleans_are_json_booleans
test_every_documented_key_is_writable
test_refusals
test_concurrent_sets_all_survive
test_stale_lock_is_broken_live_lock_is_not
