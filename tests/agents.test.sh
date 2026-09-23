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

# The delivery section is where the captain is asked to accept work, so the
# naming rule has to live there: a report that gives only the PR title, or only a
# crew id, leaves the captain unsure which todo item they are accepting. The
# number and the title are the two halves of that name, the PR url is what the
# captain clicks, and an unlinked crew needs a stated fallback instead of a
# silent one - so each is pinned as content, not trusted to prose.
test_the_delivery_section_names_the_work() {
  local delivery
  delivery=$(sed -n '/^## Delivery, merges, and waiting$/,/^## /p' "$AGENTS")
  assert_contains "$delivery" "todo item" "the delivery section ties a report to its linked todo item"
  assert_contains "$delivery" "number" "the delivery section requires the item's number"
  assert_contains "$delivery" "title" "the delivery section requires the item's title"
  assert_contains "$delivery" "PR url" "the delivery section names the PR url"
  # The crew id alone is explicitly not the name the captain is shown; if this
  # line goes, the id can quietly become what they are asked to accept.
  assert_contains "$delivery" "crew id" "the delivery section rules out the crew id alone"
  assert_contains "$delivery" "no linked todo item" "the delivery section states the fallback for an unlinked crew"
  pass "the delivery section names the work by todo number and title"
}

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

# The Work section is where a session is told what to do with a request, so the
# parallelism default has to live there and has to stay there. A piece that can
# run on its own gets its own crew, in its own worktree, at the same time as the
# others; the exception is pieces that must touch one file, which are sequenced
# because two crews editing one file cannot merge. Each of those ideas is one
# edit away from vanishing, so they are pinned as content, not as prose.
# The todo list is the captain's board, so the standing instructions must say
# who may put things on it. Without the rule a fresh session's first instinct -
# "I noticed a problem, let me file it" - takes control away from the captain,
# which is the exact failure this feature exists to prevent. The rule is only
# real if each of its parts is stated: the foreman never adds on its own, a
# suggestion becomes a proposal with a one-line reason shown as a table, an
# explicit request goes straight on the board, and approval is never assumed.
test_the_todo_section_holds_suggestions_for_approval() {
  local todo
  todo=$(sed -n '/^## The todo list is the work$/,/^## /p' "$AGENTS")
  assert_contains "$todo" "never add" "the todo section forbids adding to the board on the foreman's own initiative"
  assert_contains "$todo" "proposal" "a suggestion the foreman files becomes a proposal"
  assert_contains "$todo" "reason" "a proposal carries a one-line reason"
  assert_contains "$todo" "table" "proposals are shown to the captain as a table"
  assert_contains "$todo" "explicit request" "an explicit request from the captain goes straight on the board"
  assert_contains "$todo" "never assumed" "approval is the captain's and is never assumed"
  # A proposal that is only described to the captain does not exist: the tool
  # call is the act that files it, and claiming otherwise is the failure this
  # rule prevents. If these lines go, "I filed it" can mean prose while the
  # queue stays empty - the proposal is invisible and lost. Pin the tool name,
  # the same-turn requirement, and that prose alone files nothing.
  assert_contains "$todo" "exists only once" "the todo section says a proposal exists only once it is filed"
  assert_contains "$todo" "crew_todo propose" "the todo section names the tool call that files a proposal"
  assert_contains "$todo" "files nothing" "describing a proposal in prose files nothing"
  assert_contains "$todo" "same turn" "the filing call must be made in the same turn as the intent"
  pass "the todo section holds the foreman's suggestions for the captain's approval"
}

test_the_work_section_defaults_to_parallel_crews() {
  local work
  work=$(sed -n '/^## Work$/,/^## /p' "$AGENTS")
  assert_contains "$work" "parallel" "the Work section states the parallelism default"
  assert_contains "$work" "same files" "the Work section names the shared-file exception"
  assert_contains "$work" "sequence" "the shared-file exception sequences pieces instead of running them at once"
  # The section points at the regression suite, and the rationale for the rule
  # is in DESIGN.md; a pointer that dangles is worse than none, so both must
  # exist.
  assert_present "$ROOT/bin/crew-test.sh" "the regression suite the Work section points at exists"
  assert_present "$ROOT/DESIGN.md" "the design rationale the Work section points at exists"
  pass "the Work section defaults to concurrent crews and sequences shared-file work"
}

# A crew's worktree is cut from the project checkout's HEAD, so a checkout that
# has not been synced before the spawn hands the crew an older base silently. The
# sync has to be its own completed step - batched with the spawn it races, and
# the crew is cut from whatever HEAD was. Pin each part so the rule cannot be
# softened to a general "keep things current" and lose its teeth.
test_the_work_section_syncs_before_spawning() {
  local work
  work=$(sed -n '/^## Work$/,/^## /p' "$AGENTS")
  assert_contains "$work" "its own completed step" "the sync is a completed step of its own"
  assert_contains "$work" "Never batch" "the sync is never batched with the spawn"
  assert_contains "$work" "race" "the section says why batching the two fails"
  assert_contains "$work" "stale" "the section names the stale base a crew would start from"
  pass "the Work section syncs the checkout in its own step before spawning"
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
test_the_todo_section_holds_suggestions_for_approval
test_the_work_section_defaults_to_parallel_crews
test_the_work_section_syncs_before_spawning
test_the_delivery_section_names_the_work
test_the_contents_maps_every_section
