#!/usr/bin/env bash
# agents.test.sh - the standing instructions the foreman always loads.
#
# AGENTS.md is the only thing a foreman session is guaranteed to have in context,
# so the session-start ritual has to live there and has to stay true. If the
# pointer at the standing doc, the todo step, or the explanation of the injected
# messages falls out, nothing else catches it. This pins that contract.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

AGENTS="$ROOT/AGENTS.md"
STANDING_EXAMPLE="$ROOT/HANDOFF.example.md"

section_line() { grep -n "^## $1\$" "$AGENTS" 2>/dev/null | head -1 | cut -d: -f1; }

test_the_ritual_comes_first() {
  assert_present "$AGENTS" "the standing instructions exist"
  local start rule
  start=$(section_line "Start here")
  rule=$(section_line "The one rule")
  [ -n "$start" ] || fail "AGENTS.md has no Start here section"
  [ -n "$rule" ] || fail "AGENTS.md has no The one rule section"
  [ "$start" -lt "$rule" ] || fail "the start-here ritual must come before the rules"
  pass "the session-start ritual is the first thing in the standing instructions"
}

test_the_ritual_names_the_two_steps() {
  local body
  body=$(cat "$AGENTS")
  # The session's working directory is the foreman directory itself, because the
  # extension is discovered from `.pi/extensions/`. A path written as
  # `foreman/HANDOFF.md` therefore resolves to `foreman/foreman/HANDOFF.md` and
  # the first thing a session does is fail to find the standing doc. Keep the
  # pointer relative, and keep this assertion to catch the doubled path returning.
  assert_contains "$body" '`HANDOFF.md`' "the ritual points at the standing doc"
  assert_no_grep "foreman/HANDOFF.md" "$AGENTS" "the ritual must not double the path"
  assert_contains "$body" "crew_todo" "the ritual names the durable plan"
  # The standing doc belongs to the installation, so a clone ships the example it
  # is seeded from and nothing else. An instance's notes must never be publishable
  # by accident - that is the whole reason it is gitignored, and it is asserted
  # here rather than trusted, because "we remembered to ignore it" is exactly the
  # kind of thing a later commit adds a file past.
  assert_present "$STANDING_EXAMPLE" "the example a first session is seeded from exists"
  assert_grep "HANDOFF.md" "$ROOT/.gitignore" "the standing doc is gitignored"
  # The harness's own traps are not standing notes: they live with the code that
  # has to obey them, in DESIGN.md.
  assert_grep "## Traps" "$ROOT/DESIGN.md" "the harness traps live in DESIGN.md"
  pass "the ritual names both steps, and the doc it points at is the installation's own"
}

test_the_injected_messages_are_explained() {
  # A fresh session sees strings it did not ask for; the standing instructions
  # must say what they are, or they read as noise.
  local body
  body=$(cat "$AGENTS")
  assert_contains "$body" "crew digest:" "the injected digest line is explained"
  assert_contains "$body" "crew_handoff" "the handoff note is explained"
  pass "the injected session-start messages are accounted for"
}

# The contents list is the reader's map, so it has to be the map: every entry in
# it resolves to a section, and every section is reachable from it. Written by
# hand it drifted immediately - "How a crew member appears" was missing, and the
# grouped lines it was written on made the gap hard to see. Both directions are
# asserted here, because a list that only has to be a subset is not a map.
test_the_contents_maps_every_section() {
  local headings links
  headings=$(grep -oE '^## .+' "$ROOT/README.md" | sed 's/^## //' | grep -vx 'Contents' |
    tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9 -]//g; s/ /-/g' | sort)
  links=$(sed -n '/^## Contents$/,/^## /p' "$ROOT/README.md" | grep -oE '\]\(#[^)]+\)' |
    sed 's/](#//; s/)$//' | sort)
  assert_equals "$headings" "$links" "the contents list and the sections agree"
  pass "the contents list is the map of the document"
}

test_the_ritual_comes_first
test_the_ritual_names_the_two_steps
test_the_injected_messages_are_explained
test_the_contents_maps_every_section
