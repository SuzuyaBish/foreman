#!/usr/bin/env bash
# house-demo.test.sh - the scratch cast, and the marker that makes it safe.
#
# The demo fixture exists so house can be exercised end to end with no real
# areas to hand. The one rule that keeps it safe is the `demo fixture` marker in
# a chart's log: a chart is the fixture's own only if its log says so, so clear
# can remove exactly the cast and seed can refuse to clobber a real area.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_home >/dev/null

DEMO="$BIN/house-demo.sh"
ROUNDS="$BIN/house-rounds.sh"
PRESCRIBE="$BIN/house-prescribe.sh"
SEND="$BIN/house-send.sh"
AREAS="$FOREMAN_HOME/house/areas"
OUTBOX="$FOREMAN_HOME/house/outbox"
ERRF="$FOREMAN_HOME/demo.err"

# One header field from a chart, the way house-lib reads it.
field() { # <slug> <key>
  sed -n "s/^$2: //p" "$AREAS/$1.md" 2>/dev/null | head -n 1
}

# A clean chart for one test; each case owns its own state.
reset_house() { rm -rf "$FOREMAN_HOME/house"; }

# A hand-written real chart, deliberately carrying no marker.
plant_real() { # <slug> <status>
  mkdir -p "$AREAS"
  {
    printf '# house area: %s\n\n' "$1"
    printf 'slug: %s\n' "$1"
    printf 'kind: repo\n'
    printf 'updated: 2020-01-01\n'
    printf 'status: %s\n' "$2"
    printf 'next: keep being real\n'
    printf '\n## Log\n\n'
    printf -- '- 2020-01-01 - planted by a test, not the fixture\n'
  } >"$AREAS/$1.md"
}

# A stable fingerprint of a tree, or "absent". Used to prove the fixture never
# writes outside its throwaway home.
tree_fingerprint() { # <dir>
  if [ ! -d "$1" ]; then
    printf 'absent\n'
    return 0
  fi
  (
    cd "$1" || exit 1
    find . -type f | sort | while IFS= read -r f; do
      printf '%s\t%s\n' "$f" "$(cksum <"$f" 2>/dev/null)"
    done
  )
}

test_seed_writes_the_cast_and_rounds_see_it() {
  reset_house
  local out
  out=$("$DEMO" seed)
  assert_contains "$out" "seeded atlas" "the repo area is seeded"
  assert_contains "$out" "seeded harbour" "the chat area is seeded"
  assert_contains "$out" "seeded lighthouse" "the deck area is seeded"
  assert_contains "$out" "seeded palette" "the craft area is seeded"

  local slug
  for slug in atlas harbour lighthouse palette; do
    assert_present "$AREAS/$slug.md" "$slug has a chart"
    assert_grep "demo fixture" "$AREAS/$slug.md" "$slug's chart carries the marker"
  done
  assert_equals "repo" "$(field atlas kind)" "atlas is a repo"
  assert_equals "chat" "$(field harbour kind)" "harbour is a chat"
  assert_equals "deck" "$(field lighthouse kind)" "lighthouse is a deck"
  assert_equals "craft" "$(field palette kind)" "palette is a craft"
  assert_equals "demo-crew" "$(field harbour bind)" "the chat gets a placeholder bind by default"
  assert_equals "" "$(field palette next)" "the craft has no next step"

  out=$("$ROUNDS")
  assert_contains "$out" "house rounds: 4 areas (1 stale, 1 no next)" "rounds count the cast"
  assert_contains "$out" "[stale" "the craft is marked stale"
  assert_contains "$out" "[no next]" "the craft is marked no-next"
  assert_contains "$out" "add --dry-run to the CLI" "the repo's next step is carried"
  pass "seed writes one area per kind and rounds report the stale and no-next marks"
}

test_reseed_is_a_safe_noop() {
  reset_house
  "$DEMO" seed >/dev/null
  local before after out
  before=$(cat "$AREAS/palette.md")
  out=$("$DEMO" seed)
  after=$(cat "$AREAS/palette.md")
  assert_contains "$out" "already a demo fixture" "a re-seed reports the no-op"
  assert_equals "$before" "$after" "a re-seed does not rewrite the chart"
  assert_contains "$("$ROUNDS")" "4 areas" "a re-seed does not duplicate the cast"
  pass "re-seeding is a no-op that succeeds"
}

test_clear_removes_exactly_the_cast() {
  reset_house
  "$DEMO" seed >/dev/null
  plant_real widget "a real area that is not the fixture"
  mkdir -p "$OUTBOX"
  : >"$OUTBOX/widget-20200101T000000Z.md"

  local out
  out=$("$DEMO" clear)
  assert_contains "$out" "removed demo area atlas" "clear names what it removed"
  local slug
  for slug in atlas harbour lighthouse palette; do
    assert_absent "$AREAS/$slug.md" "clear removed the $slug chart"
  done
  assert_present "$AREAS/widget.md" "a planted non-demo chart survives"
  assert_contains "$(cat "$AREAS/widget.md")" "a real area that is not the fixture" "the non-demo chart is untouched"
  assert_present "$OUTBOX/widget-20200101T000000Z.md" "a non-demo prescription survives"
  local rounds
  rounds=$("$ROUNDS")
  assert_contains "$rounds" "widget" "the non-demo area still shows in rounds"
  assert_not_contains "$rounds" "atlas" "no demo area remains"
  pass "clear removes the four demo charts and nothing else"
}

test_clear_keeps_a_non_demo_chart_at_a_demo_slug() {
  reset_house
  plant_real atlas "a real area that happens to use the demo slug"
  local out
  out=$("$DEMO" clear)
  assert_contains "$out" "kept atlas (not a demo fixture)" "clear names the chart it left alone"
  assert_present "$AREAS/atlas.md" "a non-demo chart at a demo slug survives"
  assert_contains "$(cat "$AREAS/atlas.md")" "happens to use the demo slug" "the real chart is untouched"
  pass "clear leaves a real chart whose slug matches a demo slug"
}

test_clear_keeps_a_real_prescription_at_a_demo_slug() {
  reset_house
  plant_real atlas "a real area that happens to use the demo slug"
  mkdir -p "$OUTBOX"
  : >"$OUTBOX/atlas-20200101T000000Z.md"
  local out
  out=$("$DEMO" clear)
  assert_contains "$out" "kept atlas (not a demo fixture)" "clear names the chart it left alone"
  assert_contains "$out" "kept prescription atlas-20200101T000000Z.md" "clear names the prescription it left alone"
  assert_present "$AREAS/atlas.md" "the real chart survives"
  assert_present "$OUTBOX/atlas-20200101T000000Z.md" "the real prescription survives"
  pass "clear never deletes a real prescription at a demo slug"
}

test_seed_refuses_to_clobber_a_real_area() {
  reset_house
  plant_real atlas "the captain's real atlas work"
  local out rc
  out=$("$DEMO" seed 2>"$ERRF")
  rc=$?
  [ "$rc" -ne 0 ] || fail "seed overwrote a chart without the marker"
  assert_contains "$(cat "$ERRF")" "atlas" "the refusal names the slug it refused"
  assert_contains "$(cat "$ERRF")" "refusing" "the refusal says what it is doing"
  assert_contains "$(cat "$AREAS/atlas.md")" "the captain's real atlas work" "the real chart is untouched"
  assert_absent "$AREAS/harbour.md" "a refused seed writes none of the cast"
  pass "seed refuses to clobber a real area, and writes nothing"
}

test_clear_removes_the_demo_outbox() {
  reset_house
  "$DEMO" seed >/dev/null
  "$PRESCRIBE" atlas >/dev/null 2>&1
  "$PRESCRIBE" harbour >/dev/null 2>&1
  mkdir -p "$OUTBOX"
  : >"$OUTBOX/widget-20200101T000000Z.md"

  "$DEMO" clear >/dev/null
  local n
  n=$(find "$OUTBOX" -name 'atlas-*.md' 2>/dev/null | wc -l | tr -d ' ')
  assert_equals "0" "$n" "clear removed the atlas prescriptions"
  n=$(find "$OUTBOX" -name 'harbour-*.md' 2>/dev/null | wc -l | tr -d ' ')
  assert_equals "0" "$n" "clear removed the harbour prescriptions"
  assert_present "$OUTBOX/widget-20200101T000000Z.md" "a non-demo prescription survives"
  pass "clear removes the demo outbox prescriptions and no others"
}

test_default_bind_refuses_and_points_at_copy() {
  reset_house
  "$DEMO" seed >/dev/null
  local rc
  "$SEND" harbour >/dev/null 2>"$ERRF"
  rc=$?
  [ "$rc" -ne 0 ] || fail "the placeholder bind resolved"
  assert_contains "$(cat "$ERRF")" "--copy" "the refusal points at the clipboard path"
  pass "the default bind is a non-resolving placeholder that sends nothing"
}

test_bind_makes_the_dry_run_resolve() {
  reset_house
  fm_task live-crew working >/dev/null
  "$DEMO" seed --bind live-crew >/dev/null
  "$PRESCRIBE" harbour >/dev/null 2>&1
  local out
  out=$("$SEND" harbour 2>/dev/null)
  assert_contains "$out" "dry run" "a live bind turns the send into a dry run"
  assert_contains "$out" "to: crew live-crew" "the dry run names the real crew"
  assert_contains "$out" "House prescription - Harbour" "the dry run shows the prescription"
  pass "--bind to a live crew id makes the dry run resolve"
}

test_never_writes_outside_the_throwaway_home() {
  # fm_home points FOREMAN_HOME at a throwaway root. The home a script would
  # fall back to with FOREMAN_HOME unset is this checkout's "$ROOT/.foreman";
  # fingerprint it so a leak would be visible. Everything the fixture writes
  # must be under the temp home and nowhere else.
  case "$FOREMAN_HOME" in
  "$ROOT" | "$ROOT"/*) fail "the test home is inside the repo: $FOREMAN_HOME" ;;
  esac
  reset_house
  local fallback="$ROOT/.foreman" before after
  before=$(tree_fingerprint "$fallback")
  "$DEMO" seed >/dev/null
  "$DEMO" clear >/dev/null
  after=$(tree_fingerprint "$fallback")
  assert_equals "$before" "$after" "the default foreman home was not written to"
  assert_absent "$FOREMAN_HOME/house/areas/atlas.md" "clear left the temp chart gone too"
  pass "the fixture writes only inside the throwaway home"
}

test_seed_writes_the_cast_and_rounds_see_it
test_reseed_is_a_safe_noop
test_clear_removes_exactly_the_cast
test_clear_keeps_a_non_demo_chart_at_a_demo_slug
test_clear_keeps_a_real_prescription_at_a_demo_slug
test_seed_refuses_to_clobber_a_real_area
test_clear_removes_the_demo_outbox
test_default_bind_refuses_and_points_at_copy
test_bind_makes_the_dry_run_resolve
test_never_writes_outside_the_throwaway_home
