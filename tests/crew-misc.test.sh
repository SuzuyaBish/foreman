#!/usr/bin/env bash
# shellcheck disable=SC1010  # "done" is a subcommand argument here, not a loop terminator.
# crew-misc.test.sh - the small read-only tools: projects, report, peek, models
# and the Lavish open/end/export halves.
#
# Each is a bounded look at the fleet, and each must degrade honestly when its
# external tool is missing rather than inventing a result.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_home >/dev/null
fm_herdr_stub >/dev/null
fm_git_isolate

test_projects_lists_type_and_dirt() {
  fm_git_repo "$FOREMAN_PROJECTS/clean" >/dev/null
  fm_git_repo "$FOREMAN_PROJECTS/dirty" >/dev/null
  printf 'scratch\n' >"$FOREMAN_PROJECTS/dirty/scratch.txt"
  mkdir -p "$FOREMAN_PROJECTS/plain"

  local out
  out=$("$BIN/crew-projects.sh")
  assert_contains "$out" "clean" "a clean repository is listed"
  assert_contains "$out" "dirty" "a dirty repository is listed"
  assert_contains "$out" "(uncommitted changes)" "uncommitted work is flagged"
  assert_contains "$out" "plain (not a git repository" "a non-git project says it cannot be isolated"

  out=$("$BIN/crew-projects.sh" cle)
  assert_contains "$out" "clean" "a filter narrows the list"
  assert_not_contains "$out" "dirty" "a filter excludes non-matching projects"

  out=$(FOREMAN_PROJECTS="$(fm_tmproot empty-projects)" "$BIN/crew-projects.sh")
  assert_contains "$out" "no projects yet" "an empty projects directory says how to fill it"
  pass "projects are listed with type and dirt"
}

test_read_is_bounded() {
  fm_task rd1 done >/dev/null
  printf 'line one\nline two\nline three\n' >"$FOREMAN_HOME/tasks/rd1/report.md"
  local out
  out=$("$BIN/crew-read.sh" rd1)
  assert_contains "$out" "line one" "the report is printed"
  assert_contains "$out" "line three" "the whole short report is printed"

  out=$(FOREMAN_REPORT_LINES=2 "$BIN/crew-read.sh" rd1)
  assert_contains "$out" "line two" "a bounded read stops where told"
  assert_not_contains "$out" "line three" "the bound is respected"
  assert_contains "$out" "2 of 3 lines shown" "the truncation is announced with the full path"

  fm_task rd2 working >/dev/null
  if "$BIN/crew-read.sh" rd2 >/dev/null 2>&1; then fail "reading a missing report was accepted"; fi
  pass "the only crew output the foreman reads is explicit and truncated"
}

test_peek_is_bounded() {
  fm_task pk1 working >/dev/null
  local pane
  pane=$(fm_attach_pane pk1)
  printf 'a\nb\nc\nd\ne\n' >"$HERDR_STUB_STATE/content-$pane"

  local out
  out=$("$BIN/crew-peek.sh" pk1 2)
  assert_equals $'d\ne' "$out" "peek returns the last N lines"
  out=$("$BIN/crew-peek.sh" pk1)
  assert_contains "$out" "a" "the default peek returns more"

  fm_herdr_kill_pane "$pane"
  if "$BIN/crew-peek.sh" pk1 >/dev/null 2>&1; then fail "peeking a lost pane was accepted"; fi
  pass "peek tails a pane without holding the turn"
}

test_models_is_bounded() {
  fm_pi_stub
  local out
  out=$("$BIN/crew-models.sh")
  assert_contains "$out" "model-alpha" "models are listed"
  assert_contains "$out" "model-gamma" "the whole short list is shown"

  out=$(FOREMAN_MODELS_MAX=2 "$BIN/crew-models.sh")
  assert_contains "$out" "model-beta" "the bound keeps the first entries"
  assert_not_contains "$out" "model-gamma" "the bound drops the rest"
  assert_contains "$out" "3 models total" "the full count is announced"

  if PATH=$(fm_path_without pi) "$BIN/crew-models.sh" >/dev/null 2>&1; then
    fail "listing models without pi was accepted"
  fi
  pass "model discovery is bounded and honest about a missing pi"
}

test_lavish_halves() {
  local artifact
  artifact=$(fm_tmproot lavish)/board.html
  # A board that declares a choice, so `open` passes its own board check. The
  # choice-less refusal is pinned in crew-board.test.sh.
  printf '<html><body><form data-lavish-question="q"><button>Queue answer</button></form><script>window.lavish.queuePrompt("x",{})</script></body></html>\n' >"$artifact"

  if PATH=$(fm_path_without lavish-axi) "$BIN/crew-lavish.sh" open "$artifact" >/dev/null 2>&1; then
    fail "opening a board without lavish-axi was accepted"
  fi

  fm_lavish_stub
  local out
  out=$("$BIN/crew-lavish.sh" open "$artifact")
  assert_contains "$out" "board opened for $artifact" "open passes the artifact to lavish-axi"
  assert_contains "$(cat "$LAVISH_STUB_STATE/calls")" "$artifact" "the artifact is the argument"

  "$BIN/crew-lavish.sh" end "$artifact" >/dev/null
  assert_contains "$(cat "$LAVISH_STUB_STATE/calls")" "end $artifact" "end is passed through"
  "$BIN/crew-lavish.sh" export "$artifact" --out /tmp/board.pdf >/dev/null
  assert_contains "$(cat "$LAVISH_STUB_STATE/calls")" "export $artifact --out /tmp/board.pdf" \
    "export passes its options through"

  if "$BIN/crew-lavish.sh" bogus "$artifact" >/dev/null 2>&1; then fail "an unknown lavish action was accepted"; fi
  if "$BIN/crew-lavish.sh" open "$artifact.missing" >/dev/null 2>&1; then fail "a missing artifact was accepted"; fi
  pass "the lavish halves pass through, and refuse to guess"
}

test_projects_lists_type_and_dirt
test_read_is_bounded
test_peek_is_bounded
test_models_is_bounded
test_lavish_halves
