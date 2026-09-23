#!/usr/bin/env bash
# house-rounds.test.sh - the rounds, and the staleness that stops rot.
#
# Rounds are a look, not a visit: they read the chart and write nothing. An area
# with no next step or a stale updated date is marked, because that is the whole
# point of taking them.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_home >/dev/null

AREA="$BIN/house-area.sh"
NEXT="$BIN/house-next.sh"
ROUNDS="$BIN/house-rounds.sh"

old_date() { # <days-ago> -> YYYY-MM-DD
  local d=$1
  date -u -v-"${d}"d +%Y-%m-%d 2>/dev/null || date -u -d "$d days ago" +%Y-%m-%d
}

backdate() { # <slug> <YYYY-MM-DD>
  local f="$FOREMAN_HOME/house/areas/$1.md" tmp
  tmp="$f.tmp"
  sed "s/^updated: .*/updated: $2/" "$f" >"$tmp" && mv "$tmp" "$f"
}

test_empty() {
  local out
  out=$("$ROUNDS")
  assert_equals "house rounds: no areas" "$out" "an empty chart has empty rounds"
  out=$("$ROUNDS" --digest)
  assert_equals "house: no areas" "$out" "an empty chart has an empty digest"
  pass "empty rounds and digest are honest"
}

test_marks_no_next_and_stale() {
  "$AREA" add atlas --kind repo >/dev/null
  "$NEXT" atlas "add --dry-run and a test" >/dev/null
  "$AREA" add harbour-app --kind chat >/dev/null
  "$NEXT" harbour-app "wire the accounts tab" >/dev/null
  "$AREA" add expo-talk --kind deck >/dev/null
  "$NEXT" expo-talk "outline the ten minutes" >/dev/null
  backdate atlas "$(old_date 30)"

  local out
  out=$("$ROUNDS")
  assert_contains "$out" "house rounds: 3 areas (1 stale, 0 no next)" "the header counts stale and no-next"
  assert_contains "$out" "atlas" "the stale area is listed"
  assert_contains "$out" "[stale" "a stale updated is marked"
  assert_contains "$out" "add --dry-run and a test" "the status/next line carries the step"
  assert_not_contains "$out" "[no next]" "an area with a next is not marked"
  pass "rounds mark a stale area and carry each next step"
}

test_no_next_is_marked() {
  "$NEXT" expo-talk --clear >/dev/null
  local out
  out=$("$ROUNDS")
  assert_contains "$out" "1 no next" "a missing next is counted"
  assert_contains "$out" "[no next]" "a missing next is marked"
  assert_contains "$out" "status: -" "an absent status reads as a dash"
  pass "an area with no next is marked, not hidden"
}

test_stale_bound_is_configurable() {
  local out
  out=$("$ROUNDS" --stale-days 1)
  assert_contains "$out" "1 stale" "a 30-day area is stale past a 1-day bound"
  out=$("$ROUNDS" --stale-days 1000)
  assert_contains "$out" "0 stale" "nothing is stale past a 1000-day bound"
  if "$ROUNDS" --stale-days nope >/dev/null 2>&1; then fail "a non-numeric bound was accepted"; fi
  pass "the stale bound is settable and checked"
}

test_digest_is_one_line() {
  local out
  out=$("$ROUNDS" --digest)
  case "$out" in
  *$'\n'*) fail "the digest is more than one line" ;;
  esac
  assert_contains "$out" "house: 3 areas" "the digest counts the areas"
  assert_contains "$out" "1 stale" "the digest counts staleness"
  assert_contains "$out" "1 no next" "the digest counts missing steps"
  pass "the digest is a single summary line"
}

test_all_includes_archived() {
  "$AREA" archive expo-talk >/dev/null
  local out active
  active=$("$ROUNDS" | head -n 1)
  assert_contains "$active" "2 areas" "a retired area leaves the active rounds"
  out=$("$ROUNDS" --all)
  assert_contains "$out" "3 areas" "--all still counts the archived area"
  assert_contains "$out" "[archived]" "the archived area is marked"
  pass "--all is the only way an archived area shows up"
}

test_empty
test_marks_no_next_and_stale
test_no_next_is_marked
test_stale_bound_is_configurable
test_digest_is_one_line
test_all_includes_archived
