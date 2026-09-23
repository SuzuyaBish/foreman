#!/usr/bin/env bash
# crew-chrome.test.sh - the zero-token chrome: the status line and the widget.
#
# The chrome is TypeScript inside the extension, so this imports the real file
# under node with a fake UI and a fake theme and asserts the exact lines it
# renders. The two pi packages the extension imports are stubbed, which keeps
# this hermetic: no model, no Herdr, no captain state.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if ! command -v node >/dev/null 2>&1; then
  pass "chrome check skipped (no node)"
  exit 0
fi

ROOTDIR=$(fm_tmproot chrome)
EXTDIR="$ROOTDIR/ext"
mkdir -p "$EXTDIR" "$ROOTDIR/node_modules/@earendil-works/pi-ai" \
  "$ROOTDIR/node_modules/@earendil-works/pi-coding-agent"
cp "$ROOT/extensions/foreman.ts" "$EXTDIR/foreman.ts"

cat >"$ROOTDIR/node_modules/@earendil-works/pi-ai/package.json" <<'JSON'
{ "name": "@earendil-works/pi-ai", "type": "module", "exports": "./index.js" }
JSON
cat >"$ROOTDIR/node_modules/@earendil-works/pi-ai/index.js" <<'JS'
export const Type = new Proxy({}, { get: () => () => ({}) });
JS
cat >"$ROOTDIR/node_modules/@earendil-works/pi-coding-agent/package.json" <<'JSON'
{ "name": "@earendil-works/pi-coding-agent", "type": "module", "exports": "./index.js" }
JSON
cat >"$ROOTDIR/node_modules/@earendil-works/pi-coding-agent/index.js" <<'JS'
export const defineTool = (tool) => tool;
JS

HARNESS="$ROOTDIR/chrome.mjs"
cat >"$HARNESS" <<'JS'
import * as fs from "node:fs";
import * as path from "node:path";

const [, , extPath, home] = process.argv;
process.env.FOREMAN_HOME = home;
const mod = await import(extPath);

const status = [];
const widget = [];
// A fake theme tags what it was asked to colour, so a test can assert the role.
const theme = {
	fg: (color, text) => `[[${color}]]${text}[[/${color}]]`,
	bold: (text) => `[[bold]]${text}[[/bold]]`,
	italic: (text) => text,
	underline: (text) => text,
	inverse: (text) => text,
	strikethrough: (text) => text,
};
const ui = {
	setStatus: (_key, text) => status.push(text),
	setWidget: (_key, content) => widget.push(content),
	notify: () => {},
	theme,
};
const ctx = { hasUI: true, ui };
const handlers = {};
mod.default({
	on: (event, handler) => {
		handlers[event] = handler;
	},
	registerTool: () => {},
	registerCommand: () => {},
	sendMessage: () => {},
	sendUserMessage: () => {},
});

// A finished tool result is the cheap, script-free path that refreshes the
// chrome; session_start would also start the watcher and a timer.
await handlers.tool_execution_end({}, ctx);
const last = (list) => list[list.length - 1];
process.stdout.write(`STATUS|${last(status) ?? ""}\n`);
const shown = last(widget);
if (shown === undefined) process.stdout.write("WIDGET|(none)\n");
else for (const line of shown) process.stdout.write(`WIDGET|${line}\n`);

// The captain can turn the widget off; the status line stays.
fs.writeFileSync(path.join(home, "config.json"), '{"crewWidget":false}');
await handlers.tool_execution_end({}, ctx);
process.stdout.write(`OFF|${last(widget) === undefined ? "(none)" : "still-shown"}\n`);
JS

fm_home >/dev/null
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
HOUR=$(fm_iso_ago 3600)
row() { # id state note at
  mkdir -p "$FOREMAN_HOME/tasks/$1"
  printf 'state=%s\nat=%s\nnote=%s\n' "$2" "$4" "$3" >"$FOREMAN_HOME/tasks/$1/status"
}
row c-alpha working "building the parser" "$HOUR"
row c-beta blocked "[api] pick a retry policy" "$NOW"
row c-epsilon blocked "waiting on CI" "$NOW"
row c-gamma failed "no such host" "$NOW"
row c-delta review "PR #12 waiting" "$NOW"
printf '11\topen\t-\tfinish the widget\n12\tactive\tc-beta\tland the parser\n13\tdone\t-\tship the suite\n' \
  >"$FOREMAN_HOME/todo.tsv"

OUT=$(node "$HARNESS" "$EXTDIR/foreman.ts" "$FOREMAN_HOME") || fail "the extension would not render: $OUT"
STATUS=$(printf '%s\n' "$OUT" | sed -n 's/^STATUS|//p')
# The status line is one line of ` · `-separated bits; split it so the order of
# the bits can be asserted the same way as the order of the widget lines.
STATUS_BITS=$(printf '%s\n' "$STATUS" | awk -F' · ' '{ for (i = 1; i <= NF; i++) print $i }')
WIDGET=$(printf '%s\n' "$OUT" | sed -n 's/^WIDGET|//p')

test_the_status_line_leads_with_what_is_owed() {
  assert_contains "$STATUS" "1 decision" "a keyed block reads as a decision"
  assert_contains "$STATUS" "1 blocked" "an unkeyed block reads as blocked"
  assert_contains "$STATUS" "todo 1/3" "the todo count is shown"
  assert_contains "$STATUS" "1 failed" "failed is counted"
  assert_contains "$STATUS" "1 review" "review is counted"
  assert_contains "$STATUS" "1 working" "working is counted"
  # The footer gets the same tiering as the widget, via a documented pi pattern.
  assert_contains "$STATUS" "[[warning]]1 decision" "a decision is a warning"
  assert_contains "$STATUS" "[[error]]1 failed" "a failure is an error"
  assert_contains "$STATUS" "[[accent]]1 review" "a waiting PR is accent"
  assert_contains "$STATUS" "[[muted]]todo 1/3" "the todo count stays quiet"

  # What the captain owes comes before what is merely in flight, and the todo
  # list — a different axis — trails the crew states.
  local dec failed review work todo
  dec=$(line_of "$STATUS_BITS" "1 decision")
  failed=$(line_of "$STATUS_BITS" "1 failed")
  review=$(line_of "$STATUS_BITS" "1 review")
  work=$(line_of "$STATUS_BITS" "1 working")
  todo=$(line_of "$STATUS_BITS" "todo 1/3")
  [ -n "$dec" ] && [ -n "$failed" ] && [ -n "$review" ] && [ -n "$work" ] && [ -n "$todo" ] ||
    fail "the status line lost a count: $STATUS"
  [ "$dec" -lt "$failed" ] || fail "a decision must outrank a failure: $STATUS"
  [ "$failed" -lt "$review" ] || fail "a failure must outrank a review: $STATUS"
  [ "$review" -lt "$work" ] || fail "working must trail review: $STATUS"
  [ "$work" -lt "$todo" ] || fail "the todo count must trail the crew: $STATUS"
  pass "the status line leads with the decision and trails with the todo count"
}

test_the_widget_ranks_and_tiers_the_crew() {
  assert_contains "$WIDGET" "[[warning]]blocked" "a block is a warning"
  assert_contains "$WIDGET" "[[error]]failed" "a failure is an error"
  assert_contains "$WIDGET" "[[accent]]review" "a waiting PR is accent"
  assert_contains "$WIDGET" "[[success]]working" "a live crew is success"
  assert_contains "$WIDGET" "[[dim]]open" "a todo in the queue is dim"
  assert_contains "$WIDGET" "1h " "the age of a report is shown"

  # Worst first, so the top of the widget is what needs the captain.
  local b f r w
  b=$(line_of "$WIDGET" "blocked")
  f=$(line_of "$WIDGET" "failed")
  r=$(line_of "$WIDGET" "review")
  w=$(line_of "$WIDGET" "working")
  [ -n "$b" ] && [ -n "$f" ] && [ -n "$r" ] && [ -n "$w" ] || fail "a crew row is missing: $WIDGET"
  [ "$b" -lt "$f" ] && [ "$f" -lt "$r" ] && [ "$r" -lt "$w" ] ||
    fail "the widget is not worst-first: $WIDGET"

  local lines
  lines=$(printf '%s\n' "$WIDGET" | grep -c .)
  [ "$lines" -le 6 ] || fail "the widget grew past its budget ($lines lines)"
  pass "the widget ranks worst-first, coloured by theme role"
}

test_the_widget_can_be_turned_off() {
  assert_contains "$OUT" "OFF|(none)" "/crew off clears the widget"
  pass "the widget honours the config toggle"
}

line_of() { # <text> <needle> -> 1-based line number
  printf '%s\n' "$1" | grep -n -F -e "$2" | head -1 | cut -d: -f1
}

test_the_status_line_leads_with_what_is_owed
test_the_widget_ranks_and_tiers_the_crew
test_the_widget_can_be_turned_off
