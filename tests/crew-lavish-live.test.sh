#!/usr/bin/env bash
# crew-lavish-live.test.sh - the real Lavish round trip (opt-in).
#
# The rest of the suite stubs lavish-axi. This file does not: it starts a real
# server on a private port and state directory, posts feedback the way the
# browser does, and reads it back through `poll`. It is gated behind
# FOREMAN_LAVISH_E2E=1 so the default suite stays hermetic -- no ports, no
# external service, no browser window.
#
# What it cannot verify: the browser's own rendering and selection UI. That is
# Lavish's surface, not ours; this pins the plumbing our scripts and tools own.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ "${FOREMAN_LAVISH_E2E:-0}" != 1 ]; then
  echo "skip: set FOREMAN_LAVISH_E2E=1 to run the live Lavish round trip"
  exit 0
fi
if ! command -v lavish-axi >/dev/null 2>&1; then
  echo "skip: lavish-axi is not on PATH"
  exit 0
fi
if ! command -v curl >/dev/null 2>&1; then
  echo "skip: curl is not on PATH"
  exit 0
fi

ROOTDIR=$(fm_tmproot lavish-live)
ART="$ROOTDIR/board.html"
# A private server: its own port and state, so the captain's Lavish server and
# sessions are never touched, and stopping it stops only ours.
LAVISH_AXI_PORT=$((4700 + (RANDOM % 200)))
LAVISH_AXI_STATE_DIR="$ROOTDIR/state"
LAVISH_AXI_NO_OPEN=1
export LAVISH_AXI_PORT LAVISH_AXI_STATE_DIR LAVISH_AXI_NO_OPEN
BASE="http://127.0.0.1:$LAVISH_AXI_PORT"

cleanup() {
  lavish-axi stop >/dev/null 2>&1 || true
  fm_test_cleanup
}
trap cleanup EXIT

test_the_round_trip() {
  cat >"$ART" <<'HTML'
<!doctype html>
<html><head><meta charset="utf-8"><title>live</title></head>
<body><h1 id="title">Live round trip</h1><p>Feedback should come back.</p></body></html>
HTML

  # open (through our script, the same path a crew tool takes)
  local open_out url key
  open_out=$("$BIN/crew-lavish.sh" open "$ART" 2>&1)
  url=$(printf '%s\n' "$open_out" | sed -n 's/^ *url: "\(.*\)"$/\1/p' | head -1)
  [ -n "$url" ] || fail "crew-lavish.sh open printed no session url:
$open_out"
  key=${url##*/}
  assert_contains "$url" "$BASE/session/" "the session is on the private server"
  assert_contains "$(curl -s "$BASE/health")" '"ok":true' "the private server answers health"
  assert_contains "$open_out" "status: opened" "the session opened"

  # annotate: the browser posts to /api/<key>/prompts; do the same, same-origin.
  local resp
  resp=$(curl -s -X POST "$BASE/api/$key/prompts" \
    -H 'Content-Type: application/json' \
    -H "Origin: $BASE" \
    -d '{"prompts":[{"uid":"e2e-1","prompt":"live round trip works","selector":"#title","tag":"message","text":"live round trip works"}]}')
  assert_contains "$resp" '"status":"queued"' "the browser-shaped feedback was queued"

  # poll returns it
  local poll_out
  poll_out=$(lavish-axi poll "$ART" --timeout-ms 20000 2>/dev/null)
  assert_contains "$poll_out" "status: feedback" "poll returns feedback, not a timeout"
  assert_contains "$poll_out" "live round trip works" "the feedback text survives the round trip"
  assert_contains "$poll_out" "#title" "the annotation target survives the round trip"

  # end through our script, and confirm the private server is gone
  "$BIN/crew-lavish.sh" end "$ART" >/dev/null 2>&1 || true
  lavish-axi stop >/dev/null 2>&1 || true
  if curl -s --max-time 2 "$BASE/health" >/dev/null 2>&1; then
    fail "the private server outlived the test"
  fi
  pass "a real Lavish board completes open -> annotate -> poll -> feedback"
}

test_the_round_trip
