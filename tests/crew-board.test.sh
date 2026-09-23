#!/usr/bin/env bash
# crew-board.test.sh - the board template and the pre-open check.
#
# The board that reached the captain rendered with stray grid lines and no pick
# blocks. The lines were our own safe-margin overlay escaping its frame; the
# missing picks were a board that declared no choices. This file pins both: our
# own template passes our own check, and a deliberately choice-less board is
# refused before it can be opened.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TEMPLATE="$ROOT/assets/board-template.html"
BOARD="$BIN/crew-board.sh"

test_the_template_declares_both_shapes() {
  # A single choice (radios + Queue answer) and a multi-pick (checkbox rows +
  # a bottom dispatch bar) must both be present and wired to queuePrompt.
  assert_grep 'data-lavish-question=' "$TEMPLATE" "the template declares a question"
  assert_grep 'Queue answer' "$TEMPLATE" "the template has a Queue answer button"
  assert_grep 'class="bd-pick"' "$TEMPLATE" "the template has multi-pick checkboxes"
  assert_grep 'Queue dispatch order' "$TEMPLATE" "the template has a dispatch-order button"
  assert_grep 'window.lavish.queuePrompt' "$TEMPLATE" "the template queues through lavish"
  assert_grep 'queueKey:' "$TEMPLATE" "the dispatch button carries a queueKey"
  assert_grep 'addEventListener("submit"' "$TEMPLATE" "the single choice queues on submit"
  assert_grep 'addEventListener("change", refresh)' "$TEMPLATE" "the picker's change only refreshes state"

  # The safe-margin contract, both halves: the frame clips, and the small-frame
  # override is on the frame (never two classes compounded on an ancestor).
  assert_grep 'overflow: hidden' "$TEMPLATE" "the frame clips its overlay"
  assert_grep 'safe-on .frame.sm::before' "$TEMPLATE" "the small-frame override is on the frame"
  if grep -F '.sm.safe-on .frame::before' "$TEMPLATE" >/dev/null 2>&1; then
    fail "the broken ancestor-compound selector is back in the template"
  fi
  pass "the template declares both pick shapes and the safe-margin contract"
}

test_the_check_passes_the_template() {
  local out
  out=$("$BOARD" check "$TEMPLATE" 2>&1)
  assert_contains "$out" "board-check: ok" "our own template passes our own check"
  assert_contains "$out" "1 declared question" "the template's single choice is counted"
  pass "the check passes the vendored template"
}

test_new_scaffolds_the_template() {
  local out dir
  dir=$(fm_tmproot crew-board-new)
  "$BOARD" new "$dir/board.html" >/dev/null
  if ! diff -q "$TEMPLATE" "$dir/board.html" >/dev/null; then
    fail "crew-board.sh new did not copy the template verbatim"
  fi
  out=$("$BOARD" check "$dir/board.html" 2>&1)
  assert_contains "$out" "board-check: ok" "the scaffolded board passes the check"
  if "$BOARD" new "$dir/board.html" >/dev/null 2>&1; then
    fail "crew-board.sh new overwrote an existing file"
  fi
  pass "crew-board.sh new scaffolds a board that already passes"
}

test_the_check_refuses_a_choice_less_board() {
  local dir board out code
  dir=$(fm_tmproot crew-board-empty)
  board="$dir/empty.html"
  printf '<!doctype html><html><body><h1>Just prose</h1></body></html>\n' >"$board"

  out=$("$BOARD" check "$board" 2>&1)
  code=$?
  expect_code 1 "$code" "a choice-less board is refused"
  assert_contains "$out" "declares no choices" "the refusal names the reason"
  assert_contains "$out" "--text-only" "the refusal names the escape hatch"
  pass "the check refuses a board that declares no choices"
}

test_text_only_is_the_escape() {
  local dir board out code
  dir=$(fm_tmproot crew-board-text)
  board="$dir/empty.html"
  printf '<!doctype html><html><body><h1>Just prose</h1></body></html>\n' >"$board"

  out=$("$BOARD" check "$board" --text-only 2>&1)
  code=$?
  expect_code 0 "$code" "a deliberately text-only board may open"
  assert_contains "$out" "text-only board" "the check says it treated the board as text-only"
  pass "a deliberate text-only board passes with --text-only"
}

test_overlay_bleed_warns_but_does_not_refuse() {
  local dir board out code
  dir=$(fm_tmproot crew-board-bleed)
  board="$dir/bleed.html"
  # An absolutely positioned overlay with no clip anywhere, plus a declaring
  # board so the choices check is not what fires.
  cat >"$board" <<'HTML'
<!doctype html><html><head><style>
.frame::before { content: ""; position: absolute; width: 640px; height: 640px; }
</style></head><body>
<form data-lavish-question="q"></form>
<script>window.lavish.queuePrompt("x", {})</script>
</body></html>
HTML

  out=$("$BOARD" check "$board" 2>&1)
  code=$?
  expect_code 0 "$code" "a bleed warning must not hold the review hostage"
  assert_contains "$out" "board-check: warn" "the overlay is warned about"
  assert_contains "$out" "overflow: hidden" "the warning names the fix"
  pass "a bleedable overlay warns without refusing"
}

test_open_runs_the_check_before_lavish() {
  fm_lavish_stub
  local dir board out
  dir=$(fm_tmproot crew-board-open)
  board="$dir/empty.html"
  printf '<!doctype html><html><body><h1>Just prose</h1></body></html>\n' >"$board"

  # The default open is refused, and lavish-axi is never reached.
  if "$BIN/crew-lavish.sh" open "$board" >/dev/null 2>&1; then
    fail "crew-lavish.sh open accepted a choice-less board"
  fi
  if [ -n "$(cat "$LAVISH_STUB_STATE/calls")" ]; then
    fail "crew-lavish.sh open reached lavish-axi with a choice-less board"
  fi

  # --text-only is passed through the check and the board opens.
  out=$("$BIN/crew-lavish.sh" open --text-only "$board")
  assert_contains "$out" "board opened for" "the text-only board opens through lavish-axi"
  assert_contains "$(cat "$LAVISH_STUB_STATE/calls")" "$board" "lavish-axi received the artifact, not the flag"
  pass "crew-lavish.sh open runs the check first, and --text-only escapes it"
}

test_the_template_declares_both_shapes
test_the_check_passes_the_template
test_new_scaffolds_the_template
test_the_check_refuses_a_choice_less_board
test_text_only_is_the_escape
test_overlay_bleed_warns_but_does_not_refuse
test_open_runs_the_check_before_lavish
