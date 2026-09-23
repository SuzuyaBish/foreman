#!/usr/bin/env bash
# house-contract.test.sh - the README's House tables are the contract.
#
# Documentation and code drift apart the moment they are allowed to: the crew
# settings test already reads its table out of the README, and this does the same
# for House. Every script the README names must exist, be executable, and
# document its verbs in --help; every house tool it lists must be registered in
# the extension; and the house-mode wiring the docs describe must be real.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_home >/dev/null

README="$ROOT/README.md"
EXT="$ROOT/.pi/extensions/foreman.ts"

test_the_table_is_there() {
  local rows
  rows=$(grep -E '^\| `bin/house-[a-z-]+\.sh` \|' "$README" || true)
  [ -n "$rows" ] || fail "the README no longer has a House command table"
  assert_contains "$rows" "bin/house-prescribe.sh" "the table covers prescribe"
  pass "the README documents the House commands"
}

test_every_documented_script_exists_and_documents_its_verbs() {
  local rows row script verbs v out
  rows=$(grep -E '^\| `bin/house-[a-z-]+\.sh` \|' "$README")
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    script=$(printf '%s' "$row" | sed -E 's/^\| `([^`]+)`.*/\1/')
    [ -e "$ROOT/$script" ] || fail "documented script $script does not exist"
    [ -x "$ROOT/$script" ] || fail "documented script $script is not executable"
    out=$("$ROOT/$script" --help 2>&1) || fail "$script --help failed"
    verbs=$(printf '%s' "$row" | grep -oE '`[^`]+`' | tail -n +2 | tr -d '`')
    [ -n "$verbs" ] || fail "$script is documented with no verbs"
    for v in $verbs; do
      assert_contains "$out" "$v" "$script --help documents $v"
    done
  done <<EOF
$rows
EOF
  pass "every documented script exists and documents its verbs"
}

test_every_house_script_is_documented() {
  local f b
  for f in "$ROOT"/bin/house-*.sh; do
    [ -e "$f" ] || continue
    b=$(basename "$f")
    [ "$b" = house-lib.sh ] && continue
    grep -qF "\`bin/$b\`" "$README" || fail "bin/$b is not documented in the House table"
  done
  pass "no House script escapes the README"
}

test_every_documented_tool_is_registered() {
  local tools t
  tools=$(grep -oE '`house_[a-z_]+[^`]*`' "$README" | sed -E 's/`(house_[a-z_]+).*/\1/' | sort -u)
  assert_contains "$tools" "house_areas" "the tools table covers the chart"
  assert_contains "$tools" "house_prescribe" "the tools table covers prescribing"
  for t in $tools; do
    grep -qF "name: \"$t\"" "$EXT" || fail "documented tool $t is not registered in the extension"
  done
  pass "every documented house tool is registered"
}

test_house_mode_is_wired() {
  assert_present "$ROOT/HOUSE.md" "the who-is-house doc exists"
  assert_present "$ROOT/.pi/skills/house/SKILL.md" "the house skill exists"
  assert_grep "name: house" "$ROOT/.pi/skills/house/SKILL.md" "the skill names itself"
  assert_grep "FOREMAN_MODE=house" "$ROOT/bin/house" "the launcher marks house mode"
  assert_grep "FOREMAN_MODE" "$EXT" "the extension reads the mode"
  assert_grep "house-rounds.sh" "$EXT" "a house session opens on the rounds"
  pass "house mode is entered and opens on the chart"
}

test_the_table_is_there
test_every_documented_script_exists_and_documents_its_verbs
test_every_house_script_is_documented
test_every_documented_tool_is_registered
test_house_mode_is_wired
