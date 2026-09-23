#!/usr/bin/env bash
# crew-chrome.test.sh - the zero-token chrome: the status line and the widget.
#
# The chrome is TypeScript inside the extension, so this imports the real file
# under node with a fake UI and a fake theme and asserts the exact lines it
# renders. The pi packages the extension imports are stubbed, which keeps this
# hermetic: no model, no Herdr, no captain state.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if ! command -v node >/dev/null 2>&1; then
  pass "chrome check skipped (no node)"
  exit 0
fi

ROOTDIR=$(fm_tmproot chrome)
# The layout pi discovers: <root>/.pi/extensions/, with the mechanics in
# <root>/bin so the extension can find its install root the way it does in place.
EXTDIR="$ROOTDIR/.pi/extensions"
mkdir -p "$EXTDIR" "$ROOTDIR/node_modules/@earendil-works/pi-ai" \
  "$ROOTDIR/node_modules/@earendil-works/pi-coding-agent"
ln -s "$ROOT/bin" "$ROOTDIR/bin"
# The extension and its vendored calm sibling, exactly as pi discovers them.
cp "$ROOT/.pi/extensions/"*.ts "$EXTDIR/"

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
// The assistant-message component pi exports and lays thinking out through. The
// extension patches its prototype to drop thinking while calm is on, so the stub
// keeps the same contract: updateContent records the content types, and
// invalidate() re-renders the last real message the way pi's own does.
export class AssistantMessageComponent {
  static instances = [];
  constructor(message, hideThinkingBlock = false) {
    this.hideThinkingBlock = hideThinkingBlock;
    this.content = [];
    AssistantMessageComponent.instances.push(this);
    if (message) this.updateContent(message);
  }
  updateContent(message) {
    this.lastMessage = message;
    this.content = (message.content ?? []).map((block) => block.type);
  }
  invalidate() {
    if (this.lastMessage) this.updateContent(this.lastMessage);
  }
}
// The built-in tool definitions the extension re-registers to hide their calls.
// Each carries its own renderers, and like the real ones they reuse
// `context.lastComponent` for streaming updates - calling setText on it. That is
// exactly the contract the calm wrapper has to respect.
const builtin = (name) => () => ({
  name,
  label: name,
  description: name,
  parameters: {},
  async execute() {
    return { content: [{ type: "text", text: name + " out" }], details: undefined };
  },
  renderCall(_args, _theme, context) {
    const text = context.lastComponent ?? { render: () => [name + " call"], setText() {}, invalidate() {} };
    text.setText(name + " call");
    return text;
  },
  renderResult(_result, _options, _theme, context) {
    const text = context.lastComponent ?? { render: () => [name + " result"], setText() {}, invalidate() {} };
    text.setText(name + " result");
    return text;
  },
});
export const createReadToolDefinition = builtin("read");
export const createBashToolDefinition = builtin("bash");
export const createEditToolDefinition = builtin("edit");
export const createWriteToolDefinition = builtin("write");
export const createFindToolDefinition = builtin("find");
export const createGrepToolDefinition = builtin("grep");
export const createLsToolDefinition = builtin("ls");
JS

HARNESS="$ROOTDIR/chrome.mjs"
cat >"$HARNESS" <<'JS'
import * as fs from "node:fs";
import * as path from "node:path";
import { AssistantMessageComponent } from "@earendil-works/pi-coding-agent";

const [, , extPath, home] = process.argv;
process.env.FOREMAN_HOME = home;

const status = [];
const widget = [];
// What the toggle asked pi to redraw. Pi re-runs every assistant row's layout
// when its hidden-thinking label is set, so this records both that the request
// happened and that the fake rows actually re-laid out from it.
const redraws = [];
// A fake theme tags what it was asked to colour, so a test can assert the role.
const theme = {
	fg: (color, text) => `[[${color}]]${text}[[/${color}]]`,
	bg: (color, text) => `[[${color}]]${text}[[/${color}]]`,
	bold: (text) => `[[bold]]${text}[[/bold]]`,
	italic: (text) => text,
	underline: (text) => text,
	inverse: (text) => text,
	strikethrough: (text) => text,
};
const ui = {
	setStatus: (_key, text) => status.push(text),
	setWidget: (_key, content) => widget.push(content),
	setHiddenThinkingLabel: (label) => {
		redraws.push(label === "" ? "calm-on" : label === undefined ? "calm-off" : "labelled");
		for (const component of AssistantMessageComponent.instances) component.invalidate();
	},
	notify: () => {},
	theme,
};
const ctx = { hasUI: true, ui, mode: "tui" };
const last = (list) => list[list.length - 1];

function load(ext) {
	const handlers = {};
	const tools = {};
	const commands = {};
	const pi = {
		on: (event, handler) => {
			handlers[event] = handler;
		},
		registerTool: (tool) => {
			tools[tool.name] = tool;
		},
		registerCommand: (name, options) => {
			commands[name] = options;
		},
		sendMessage: () => {},
		sendUserMessage: () => {},
	};
	return import(ext).then(async (mod) => {
		await mod.default(pi);
		return { handlers, tools, commands, pi };
	});
}

const first = await load(extPath);
const { handlers, tools, commands } = first;

// A finished tool result is the cheap, script-free path that refreshes the
// chrome; session_start would also start the watcher and a timer.
await handlers.tool_execution_end({}, ctx);
process.stdout.write(`STATUS|${last(status) ?? ""}\n`);
const shown = last(widget);
if (shown === undefined) process.stdout.write("WIDGET|(none)\n");
else for (const line of shown) process.stdout.write(`WIDGET|${line}\n`);

// --- /crew argument completions -------------------------------------------
// The grammar the handler accepts must be the grammar the palette offers, so
// both are read from one table. `calm`'s description is state-aware.
const completeValues = (prefix) => {
	const items = commands.crew.getArgumentCompletions(prefix);
	return items ? items.map((i) => i.value).join(",") : "(none)";
};
const completeDescs = (prefix) => {
	const items = commands.crew.getArgumentCompletions(prefix);
	return items ? items.map((i) => `${i.value}:${i.description ?? ""}`).join(" | ") : "(none)";
};
process.stdout.write(`COMPLETE_EMPTY|${completeValues("")}\n`);
process.stdout.write(`COMPLETE_C|${completeValues("c")}\n`);
process.stdout.write(`COMPLETE_CALM|${completeValues("calm")}\n`);
process.stdout.write(`COMPLETE_CALM_SPACE|${completeValues("calm ")}\n`);
process.stdout.write(`COMPLETE_ON|${completeValues("on")}\n`);
process.stdout.write(`COMPLETE_OFF|${completeValues("off")}\n`);
process.stdout.write(`COMPLETE_MISS|${completeValues("zzz")}\n`);
process.stdout.write(`COMPLETE_CALM_OFF_DESC|${completeDescs("calm")}\n`);

// --- calm mode and assistant thinking -------------------------------------
// Pi lays a message out through the exported AssistantMessageComponent, whose
// content the extension patches while calm is on. This drives the real patch:
// the block types that survive are what would be drawn.
const thinkingMessage = {
	role: "assistant",
	content: [
		{ type: "thinking", thinking: "secret reasoning" },
		{ type: "text", text: "a reply" },
	],
	stopReason: "end",
};
const blocksOf = (component) => component.content.join(",");
let calmComponent;
process.stdout.write(`ASSISTANT_OFF|${blocksOf(new AssistantMessageComponent(thinkingMessage))}\n`);

// --- calm mode -------------------------------------------------------------
// The call renderer is synchronous; renderCall returns a component and the
// count of lines it draws is what "hidden" means. 0 is hidden.
const rctx = { isPartial: false, isError: false, state: {} };
const callLines = (tool, args) => {
	const component = tool.renderCall(args, theme, rctx);
	return component ? component.render(80).length : -1;
};
const resultLines = (tool) => {
	const component = tool.renderResult(
		{ content: [{ type: "text", text: "hello\nworld" }], details: undefined },
		{ expanded: false, isPartial: false },
		theme,
		rctx,
	);
	return component ? component.render(80).length : -1;
};

const statusBefore = last(status);
const widgetBefore = last(widget);
process.stdout.write(`CALM_CUSTOM_OFF|${callLines(tools.crew_list, { action: "list" })}\n`);
process.stdout.write(`CALM_RESULT_OFF|${resultLines(tools.crew_list)}\n`);
process.stdout.write(`CALM_BUILTIN_OFF|${callLines(tools.read, { path: "x" })}\n`);
// The real ToolExecutionComponent hands the component renderCall returned back in
// as `lastComponent` on the next render. The built-in renderers call setText on
// it, so the calm wrapper must not forward its own component as their Text.
const reuse = () => {
	const first = tools.read.renderCall({ path: "x" }, theme, { ...rctx, lastComponent: undefined });
	const second = tools.read.renderCall({ path: "x" }, theme, { ...rctx, lastComponent: first });
	return second.render(80).length;
};
process.stdout.write(`CALM_BUILTIN_REUSE|${reuse()}\n`);

await commands.crew.handler("calm on", ctx);
process.stdout.write(`COMPLETE_CALM_ON_DESC|${completeDescs("calm")}\n`);
calmComponent = new AssistantMessageComponent(thinkingMessage);
process.stdout.write(`ASSISTANT_ON|${blocksOf(calmComponent)}\n`);
// The toggle must ask pi to re-lay out the rows already on screen, not just the
// next ones; pi does it by re-setting the hidden-thinking label.
process.stdout.write(`CALM_REDRAW_ON|${redraws[redraws.length - 1]}\n`);
process.stdout.write(`CONFIG|${fs.readFileSync(path.join(home, "config.json"), "utf8")}\n`);
process.stdout.write(`CALM_CUSTOM_ON|${callLines(tools.crew_list, { action: "list" })}\n`);
process.stdout.write(`CALM_RESULT_ON|${resultLines(tools.crew_list)}\n`);
process.stdout.write(`CALM_BUILTIN_ON|${callLines(tools.read, { path: "x" })}\n`);
const same = last(status) === statusBefore && JSON.stringify(last(widget)) === JSON.stringify(widgetBefore);
process.stdout.write(`CALM_CHROME|${same ? "same" : "changed"}\n`);

// A second look at the same row proves the toggle is live, not baked in at run time.
await commands.crew.handler("calm off", ctx);
process.stdout.write(`CALM_CUSTOM_AGAIN|${callLines(tools.crew_list, { action: "list" })}\n`);
process.stdout.write(`CALM_REDRAW_OFF|${redraws[redraws.length - 1]}\n`);
// No invalidate() by hand here: the toggle's own redraw request must re-lay out
// the same row, so thinking returns because calm went off, not because the test
// asked the component to look again.
process.stdout.write(`ASSISTANT_AGAIN|${blocksOf(calmComponent)}\n`);

// Reload: a fresh module instance reads the persisted setting off disk. This is
// how the choice survives a restart, and it is the whole point of the config key.
await commands.crew.handler("calm on", ctx);
const second = await load(extPath + "?reload=1");
process.stdout.write(`CALM_RELOAD|${callLines(second.tools.crew_list, { action: "list" })}\n`);

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

# pi loads this extension through jiti, while this file loads it through node's
# own type stripping. The vendored calm module is a relative `.ts` import, and
# the two loaders resolve it by different machinery, so when a pi install is on
# this machine load the real extension through that jiti too. The node path
# above is the one this suite can always exercise; this skips when there is no
# pi install rather than pretending to cover it.
JITI_MJS=""
for dir in $(ls -d "${HOME:-/nonexistent}"/.pi/agent/install/releases/*/node_modules/jiti 2>/dev/null | sort -V); do
  [ -f "$dir/lib/jiti.mjs" ] && JITI_MJS="$dir/lib/jiti.mjs"
done
JITI_LOAD="(skipped)"
if [ -n "$JITI_MJS" ]; then
  JITI_HARNESS="$ROOTDIR/jiti.mjs"
  cat >"$JITI_HARNESS" <<JS
import { createJiti } from "$JITI_MJS";
const jiti = createJiti(import.meta.url);
process.env.FOREMAN_HOME = "$FOREMAN_HOME";
delete process.env.FOREMAN_CREW;
const mod = await jiti.import("$EXTDIR/foreman.ts");
const tools = {}, commands = {};
const pi = { on(){}, registerTool(t){ tools[t.name]=t; }, registerCommand(n,o){ commands[n]=o; }, sendMessage(){}, sendUserMessage(){} };
await mod.default(pi);
process.stdout.write("JITI|" + Object.keys(tools).length + "|" + (typeof commands.crew) + "\n");
JS
  JITI_LOAD=$(node "$JITI_HARNESS" 2>&1) || JITI_LOAD="(failed)"
fi

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
  assert_contains "$WIDGET" "[[dim]]open" "a queued item is dim"
  # A crew and its linked item are one row: five crew rows carry the items they
  # are linked to, and only #11 (no crew) is a todo row of its own. `active` is
  # never rendered, because it was the second word for `working`.
  assert_contains "$WIDGET" "#12" "the linked item's number rides the crew row"
  assert_contains "$WIDGET" "land the parser" "the linked item's title rides the crew row"
  assert_not_contains "$WIDGET" "[[accent]]active" "an in-flight item is not a second row"
  assert_not_contains "$WIDGET" "active" "one item never wears two words for one moment"
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

# One harness serves many projects, so a project's chrome must not count another
# project's backlog. The chrome derives its scope in TypeScript (it renders every
# 15s and must not fork a shell), while the tools derive it in crew-todo.sh; this
# asserts both agree on one fixture, which is what keeps them from drifting.
test_the_chrome_is_scoped_to_the_project_in_focus() {
  local h out status widget
  h=$(fm_tmproot chrome-scoped)/home
  mkdir -p "$h/tasks/c-proj"
  printf 'project=%s\n' "/tmp/projects/Example_App" >"$h/tasks/c-proj/meta"
  printf 'state=working\nat=%s\nnote=\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$h/tasks/c-proj/status"
  printf '1\topen\t-\tsheet background\t-\tExample_App\n2\topen\t-\ttidy the chrome\t-\tforeman\n' >"$h/todo.tsv"

  out=$(node "$HARNESS" "$EXTDIR/foreman.ts" "$h") || fail "the extension would not render: $out"
  status=$(printf '%s\n' "$out" | sed -n 's/^STATUS|//p')
  widget=$(printf '%s\n' "$out" | sed -n 's/^WIDGET|//p')

  assert_contains "$status" "todo 0/1 Example_App" "the status line counts the project in focus"
  assert_contains "$status" "+1 open elsewhere" "queued work in another scope is counted, never hidden"
  assert_not_contains "$status" "proposed" "a board with no suggestions shows no proposal count"
  assert_contains "$widget" "sheet background" "the widget shows the project's item"
  assert_not_contains "$widget" "tidy the chrome" "the widget does not show another scope's item"

  assert_equals "Example_App" "$(FOREMAN_HOME="$h" "$BIN/crew-todo.sh" focus)" \
    "the shell and the chrome resolve the scope the same way"
  pass "the chrome reads the project in focus and never another project's backlog"
}

test_calm_mode_hides_the_foremans_tool_calls() {
  local off again
  off=$(field CALM_CUSTOM_OFF)
  again=$(field CALM_CUSTOM_AGAIN)

  # The setting is first-class and persisted, the same way crewWidget is.
  assert_contains "$OUT" '"crewCalm": true' "/crew calm on writes the crewCalm setting"

  # Calm off, a call and its result draw the block they always did.
  assert_not_contains "$OUT" "CALM_CUSTOM_OFF|0" "a custom tool call draws when calm is off"
  assert_not_contains "$OUT" "CALM_RESULT_OFF|0" "a tool result draws when calm is off"
  [ "$off" = "$again" ] || fail "turning calm off must restore the tool's normal rendering ($off vs $again)"

  # Calm on, the same rows render zero lines: hidden, not an empty box.
  assert_contains "$OUT" "CALM_CUSTOM_ON|0" "a custom tool call is hidden when calm is on"
  assert_contains "$OUT" "CALM_RESULT_ON|0" "a tool result is hidden when calm is on"

  # pi's built-in tools are re-registered from their own definitions, so their
  # calls calm too, without changing what they do.
  assert_not_contains "$OUT" "CALM_BUILTIN_OFF|0" "a built-in tool call draws when calm is off"
  assert_contains "$OUT" "CALM_BUILTIN_ON|0" "a built-in tool call is hidden when calm is on"
  # The built-in renderers reuse lastComponent; the wrapper must survive that.
  assert_not_contains "$OUT" "CALM_BUILTIN_REUSE|0" "a built-in call re-renders when its component is reused"

  # The renderers read the live flag, so the toggle redraws rows already on screen.
  assert_not_contains "$OUT" "CALM_CUSTOM_AGAIN|0" "the toggle is live, not baked in at run time"
  # And it does not wait for the next row: the toggle asks pi to re-lay out the
  # rows already on screen (its hidden-thinking label round-trip), both ways.
  assert_equals "calm-on" "$(field CALM_REDRAW_ON)" "turning calm on redraws rows already on screen"
  assert_equals "calm-off" "$(field CALM_REDRAW_OFF)" "turning calm off redraws them again"

  # And it survives a reload because the choice lives in config.json.
  assert_contains "$OUT" "CALM_RELOAD|0" "the calm choice survives a reload"

  # It quiets the tool call chrome and nothing else: no status, no widget change.
  assert_contains "$OUT" "CALM_CHROME|same" "calm mode leaves the status line and the widget alone"
  pass "calm mode hides the foreman's tool calls, is live and persists"
}

# Calm mode must quiet thinking too: the captain saw `thinking` lines for a whole
# turn, and his setting collapses thinking to a label. Pi lays every assistant
# message out through the exported AssistantMessageComponent, so the extension
# drops thinking blocks from the presentation copy while calm is on. This drives
# that patch: which block types survive is exactly what pi would draw.
test_calm_mode_also_hides_assistant_thinking() {
  assert_equals "thinking,text" "$(field ASSISTANT_OFF)" "thinking is drawn while calm is off"
  assert_equals "text" "$(field ASSISTANT_ON)" "thinking blocks are dropped while calm is on"
  # The reply is a different block and is never touched. The restoration below is
  # not the test calling invalidate(): the calm-off toggle's own redraw request is
  # what re-lays out the row, which is the live behaviour the captain asked for.
  assert_equals "thinking,text" "$(field ASSISTANT_AGAIN)" "the toggle brings thinking back on the same row"
  pass "calm mode collapses assistant thinking, live and reversible"
}

# The sibling import is the one thing that can take the whole extension down, so
# it is pinned under both loaders: node above, pi's jiti here.
test_the_vendored_calm_module_loads_under_pis_jiti() {
  if [ -z "$JITI_MJS" ]; then
    pass "jiti load check skipped (no pi install found)"
    return 0
  fi
  assert_contains "$JITI_LOAD" "JITI|" "pi's jiti loads the extension and its vendored calm sibling"
  assert_not_contains "$JITI_LOAD" "JITI|0|" "the extension registers its tools through jiti"
  assert_contains "$JITI_LOAD" "|object" "the /crew command registers through jiti too"
  pass "the vendored calm sibling resolves under pi's jiti as well as node"
}

line_of() { # <text> <needle> -> 1-based line number
  printf '%s\n' "$1" | grep -n -F -e "$2" | head -1 | cut -d: -f1
}

field() { # <NAME> -> the value printed as `NAME|value`
  printf '%s\n' "$OUT" | sed -n "s/^$1|//p" | head -1
}

# `/crew` accepts a small grammar (on, off, calm, calm on, calm off) but
# registered no argument completions, so the subcommands were invisible in the
# palette. The handler and the completion list now read one table; this pins the
# grammar, the prefix filtering, and that a calm description is state-aware.
test_the_crew_command_completes_its_arguments() {
  assert_equals "on,off,calm,calm on,calm off" "$(field COMPLETE_EMPTY)" "an empty prefix offers every argument"
  assert_equals "calm,calm on,calm off" "$(field COMPLETE_C)" "c filters to the calm family"
  assert_equals "calm,calm on,calm off" "$(field COMPLETE_CALM)" "calm offers its on/off refinements"
  assert_equals "calm on,calm off" "$(field COMPLETE_CALM_SPACE)" "a trailing space offers on and off"
  assert_equals "on" "$(field COMPLETE_ON)" "on offers itself"
  assert_equals "off" "$(field COMPLETE_OFF)" "off offers itself"
  assert_equals "(none)" "$(field COMPLETE_MISS)" "a prefix that matches nothing returns null"

  # Honest, state-aware descriptions: the entry says what it will do from here.
  assert_contains "$(field COMPLETE_CALM_OFF_DESC)" "calm:turn calm mode on" "calm says it will turn calm on while it is off"
  assert_contains "$(field COMPLETE_CALM_ON_DESC)" "calm:turn calm mode off" "calm says it will turn calm off once it is on"
  pass "/crew completes its real argument grammar, state-aware"
}

# One row per crew. A crew and the item that links back to it used to render as
# two rows with two words for one moment (`working` above, `active` below).
# They now fold into the crew's row: the item's number and title ride along,
# the crew's own state is the only status, and the item never renders twice.
test_a_linked_item_folds_into_its_crews_row_and_the_budget_holds() {
  local h out widget now old lines linked
  h=$(fm_tmproot chrome-relevance)/home
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  old=$(fm_iso_ago 3600)
  mkdir -p "$h/tasks/c-alpha" "$h/tasks/c-beta"
  printf 'state=working\nat=%s\nnote=building the parser\n' "$old" >"$h/tasks/c-alpha/status"
  printf 'state=working\nat=%s\nnote=landing the parser\n' "$now" >"$h/tasks/c-beta/status"
  # The linked item is last in file order, behind five unclaimed ones, and two
  # crew rows plus five queued rows is seven - one past the budget. It survives
  # because it is part of c-beta's row, which worst-first never drops; the
  # unclaimed rows are the ones that give up their lines.
  printf '17\topen\t-\tolder queued one\n18\topen\t-\tolder queued two\n19\topen\t-\tolder queued three\n20\topen\t-\tolder queued four\n22\topen\t-\tolder queued five\n21\tactive\tc-beta\tland the parser\n' \
    >"$h/todo.tsv"

  out=$(node "$HARNESS" "$EXTDIR/foreman.ts" "$h") || fail "the extension would not render: $out"
  widget=$(printf '%s\n' "$out" | sed -n 's/^WIDGET|//p')

  assert_contains "$widget" "c-alpha" "the first working crew renders"
  assert_contains "$widget" "c-beta" "the second working crew renders"
  assert_contains "$widget" "land the parser" "the linked item's title rides its crew row"
  assert_not_contains "$widget" "[[accent]]active" "the linked item is not a separate todo row"
  linked=$(printf '%s\n' "$widget" | grep -c "#21")
  assert_equals "1" "$linked" "the linked item renders exactly once"
  assert_contains "$widget" "[[dim]]open" "an unclaimed item carries the dim role"
  assert_not_contains "$widget" "older queued five" "the last unclaimed row gives up its slot"

  lines=$(printf '%s\n' "$widget" | grep -c .)
  [ "$lines" -le 6 ] || fail "the widget grew past its budget ($lines lines)"
  pass "a linked item folds into its crew's row and the budget still holds"
}

# The captain's exact complaint, in one fixture: the status line counts one
# working crew and the board has one active item, and they are the same work.
# The widget must show one row, four-to-six columns, and the crew id the captain
# addresses, and must not say the state twice.
test_a_crew_and_its_item_render_as_one_row() {
  local h out widget rows
  h=$(fm_tmproot chrome-merge)/home
  mkdir -p "$h/tasks/social-preview"
  printf 'state=working\nat=%s\nnote=rendering the og image\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$h/tasks/social-preview/status"
  printf '35\tactive\tsocial-preview\tForeman repo: social preview image\t-\tforeman\n' >"$h/todo.tsv"

  out=$(node "$HARNESS" "$EXTDIR/foreman.ts" "$h") || fail "the extension would not render: $out"
  widget=$(printf '%s\n' "$out" | sed -n 's/^WIDGET|//p')

  rows=$(printf '%s\n' "$widget" | grep -c .)
  assert_equals "1" "$rows" "a crew and its linked item are one row"
  assert_contains "$widget" "#35" "the todo number is on the row"
  assert_contains "$widget" "Foreman repo" "the todo title is on the row"
  assert_contains "$widget" "[[success]]working" "the crew's own state is the single status column"
  assert_not_contains "$widget" "[[accent]]active" "the linked item is not a second row"
  assert_not_contains "$widget" "active" "one item never wears two words for one moment"
  assert_contains "$widget" "social-preview" "the crew id the captain addresses stays visible"
  assert_contains "$widget" "rendering the og" "the row says what the crew is actually doing"
  pass "a crew and its linked todo item render as one row"
}

# A crew's report state is a claim; its own semantic busy record is sharper. A
# crew settled at its prompt is `idle`, not `working`. Unknown - no record, or
# one from a stale incarnation - falls back to the report state, never to idle.
# The status line's counts are report states and are deliberately untouched.
test_the_status_column_honours_the_crews_own_busy_record() {
  local h out status widget now busy idle stale none
  h=$(fm_tmproot chrome-busy)/home
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  mkdir -p "$h/tasks/c-busy" "$h/tasks/c-idle" "$h/tasks/c-stale" "$h/tasks/c-none"
  for id in c-busy c-idle c-stale c-none; do
    printf 'state=working\nat=%s\nnote=x\n' "$now" >"$h/tasks/$id/status"
  done
  printf 'g1\n' >"$h/tasks/c-busy/busy-gen"
  printf 'v1 gen=g1 seq=1 state=busy source=crew-ext event=agent-start ts=0\n' >"$h/tasks/c-busy/busy-state"
  printf 'g2\n' >"$h/tasks/c-idle/busy-gen"
  printf 'v1 gen=g2 seq=2 state=idle source=crew-ext event=agent-settled ts=0\n' >"$h/tasks/c-idle/busy-state"
  # A stale incarnation: the token does not match the armed sidecar.
  printf 'g3\n' >"$h/tasks/c-stale/busy-gen"
  printf 'v1 gen=old seq=2 state=idle source=crew-ext event=agent-settled ts=0\n' >"$h/tasks/c-stale/busy-state"
  printf '1\topen\t-\twork\n' >"$h/todo.tsv"

  out=$(node "$HARNESS" "$EXTDIR/foreman.ts" "$h") || fail "the extension would not render: $out"
  status=$(printf '%s\n' "$out" | sed -n 's/^STATUS|//p')
  widget=$(printf '%s\n' "$out" | sed -n 's/^WIDGET|//p')

  busy=$(printf '%s\n' "$widget" | grep -F "c-busy")
  idle=$(printf '%s\n' "$widget" | grep -F "c-idle")
  stale=$(printf '%s\n' "$widget" | grep -F "c-stale")
  none=$(printf '%s\n' "$widget" | grep -F "c-none")
  assert_contains "$busy" "[[success]]working" "a mid-turn crew is working"
  assert_contains "$idle" "[[dim]]idle" "a crew settled at its prompt is idle"
  assert_not_contains "$idle" "working" "a settled crew is not working"
  assert_contains "$stale" "[[success]]working" "a stale busy record leaves the report state alone"
  assert_contains "$none" "[[success]]working" "no busy record leaves the report state alone"

  # The report state is still what the status line counts; the row is sharper,
  # the count is not changed by the display.
  assert_contains "$status" "4 working" "the status line still counts the report states"
  pass "the row's status is honest about busy vs settled, unknown falls back"
}

# The two leftovers the merge creates, both stated rather than silent: a crew
# with no linked item, and an item no crew is working.
test_the_two_leftovers_each_keep_a_stated_row() {
  local h out widget solo
  h=$(fm_tmproot chrome-leftovers)/home
  mkdir -p "$h/tasks/c-solo"
  printf 'state=working\nat=%s\nnote=on its own\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$h/tasks/c-solo/status"
  printf '7\topen\t-\tnobody is on this\n' >"$h/todo.tsv"

  out=$(node "$HARNESS" "$EXTDIR/foreman.ts" "$h") || fail "the extension would not render: $out"
  widget=$(printf '%s\n' "$out" | sed -n 's/^WIDGET|//p')

  solo=$(printf '%s\n' "$widget" | grep -F "c-solo")
  assert_contains "$solo" "(no todo item)" "a crew with no item says so"
  assert_contains "$solo" "on its own" "the crew's own description still renders"
  assert_contains "$widget" "#7" "an unclaimed item keeps its number"
  assert_contains "$widget" "nobody is on this" "an unclaimed item keeps its title"
  assert_contains "$widget" "(no crew yet)" "an unclaimed item says no crew is on it"
  assert_contains "$widget" "[[dim]]open" "an unclaimed item shows its own todo state"
  pass "both leftovers render a stated row"
}

# No row may wrap, at any width. The number, title and description have fixed
# shares and are clipped; a 200-character title and a 200-character note still
# render one line each, bounded to the chrome's conservative width, with both
# clipped columns marked and the status and age columns surviving the cut.
test_a_row_never_wraps_at_the_narrow_bound() {
  local h out widget now longest ellipses
  h=$(fm_tmproot chrome-narrow)/home
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  mkdir -p "$h/tasks/c-long"
  printf 'state=working\nat=%s\nnote=%s\n' "$now" "$(printf 'n%.0s' {1..200})" >"$h/tasks/c-long/status"
  printf '41\tactive\tc-long\t%s\n' "$(printf 't%.0s' {1..200})" >"$h/todo.tsv"

  out=$(node "$HARNESS" "$EXTDIR/foreman.ts" "$h") || fail "the extension would not render: $out"
  widget=$(printf '%s\n' "$out" | sed -n 's/^WIDGET|//p')

  # Visible columns, not string length: strip the fake theme's role tags and
  # fold the multibyte ellipsis to one byte first.
  longest=$(printf '%s\n' "$widget" | sed 's/\[\[[^]]*\]\]//g; s/…/./g' | awk '{ if (length($0) > m) m = length($0) } END { print m + 0 }')
  [ "$longest" -le 80 ] || fail "a widget row wraps past its bound ($longest columns)"

  ellipses=$(printf '%s\n' "$widget" | grep -o "…" | wc -l | tr -d ' ')
  [ "$ellipses" -ge 2 ] || fail "the title and the description are both clipped ($ellipses ellipses)"
  assert_contains "$widget" "[[success]]working" "the status column survives the clipping"
  assert_contains "$widget" "c-long" "the crew id survives the clipping"
  pass "a row with a huge title and note stays one bounded line"
}

# A requirement typed as one long sentence used to wrap into several terminal
# lines and eat the six-line budget. Each row is now bounded to a conservative
# width and clipped with an ellipsis; the full text stays in crew_todo.
test_an_enormous_item_is_truncated_and_keeps_the_budget() {
  local h out widget huge longest lines
  h=$(fm_tmproot chrome-long)/home
  mkdir -p "$h/tasks/c-alpha"
  printf 'state=working\nat=%s\nnote=busy\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$h/tasks/c-alpha/status"
  huge=$(printf 'x%.0s' {1..400})
  printf '31\topen\t-\t%s\n32\topen\t-\tshort after the huge one\n' "$huge" >"$h/todo.tsv"

  out=$(node "$HARNESS" "$EXTDIR/foreman.ts" "$h") || fail "the extension would not render: $out"
  widget=$(printf '%s\n' "$out" | sed -n 's/^WIDGET|//p')

  assert_contains "$widget" "…" "the long row is marked as truncated"
  assert_not_contains "$widget" "$huge" "the full item text is not printed"
  assert_contains "$widget" "#32" "a row after the long one still renders"
  assert_contains "$widget" "short after the huge one" "the following item is intact"

  # Measure visible columns, not string length: strip the fake theme's role
  # tags and fold the multibyte ellipsis to one byte first, then take the
  # longest row.
  longest=$(printf '%s\n' "$widget" | sed 's/\[\[[^]]*\]\]//g; s/…/./g' | awk '{ if (length($0) > m) m = length($0) } END { print m + 0 }')
  [ "$longest" -le 80 ] || fail "a widget row wraps past its bound ($longest columns)"

  lines=$(printf '%s\n' "$widget" | grep -c .)
  [ "$lines" -le 6 ] || fail "the widget grew past its budget ($lines lines)"
  pass "a long item row is truncated to one line and the rows after it survive"
}

# The board is the captain's, so the foreman's own suggestions are held apart:
# counted on the status line, never mixed into the captain's rows. The count has
# to appear when proposals exist and stay absent when they do not, and the
# widget's six-line budget and relevance ordering must survive them untouched.
test_a_proposal_is_counted_apart_and_never_a_captain_row() {
  local h out status widget bits todo proposed lines
  h=$(fm_tmproot chrome-proposals)/home
  mkdir -p "$h/tasks/c-alpha"
  printf 'state=working\nat=%s\nnote=busy\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$h/tasks/c-alpha/status"
  printf '1\topen\t-\tfinish the widget\t-\tforeman\n2\tproposed\t-\tadd a metrics tab\twe may need numbers\tforeman\n3\tproposed\t-\tprefetch the index\tit is slow\tforeman\n' \
    >"$h/todo.tsv"

  out=$(node "$HARNESS" "$EXTDIR/foreman.ts" "$h") || fail "the extension would not render: $out"
  status=$(printf '%s\n' "$out" | sed -n 's/^STATUS|//p')
  widget=$(printf '%s\n' "$out" | sed -n 's/^WIDGET|//p')
  bits=$(printf '%s\n' "$status" | awk -F' · ' '{ for (i = 1; i <= NF; i++) print $i }')

  # The count is there, muted, and the captain's own total is unchanged by it.
  assert_contains "$status" "[[muted]]2 proposed" "the proposal count is muted and separate"
  assert_contains "$status" "todo 0/1" "the captain's board counts only their items"

  # It trails the todo count: the board first, then the suggestions held apart.
  todo=$(line_of "$bits" "todo 0/1")
  proposed=$(line_of "$bits" "2 proposed")
  [ -n "$todo" ] && [ -n "$proposed" ] || fail "the status line lost a count: $status"
  [ "$todo" -lt "$proposed" ] || fail "the proposal count must trail the todo count: $status"

  # A proposal is not the captain's work and never renders as one of their rows.
  assert_contains "$widget" "finish the widget" "the captain's item still renders"
  assert_not_contains "$widget" "add a metrics tab" "a proposal never renders as a captain row"
  assert_not_contains "$widget" "#2" "a proposal number is not a captain row either"

  lines=$(printf '%s\n' "$widget" | grep -c .)
  [ "$lines" -le 6 ] || fail "the widget grew past its budget ($lines lines)"
  pass "a proposal is counted apart and never takes a captain's row"
}

test_the_status_line_leads_with_what_is_owed
test_the_widget_ranks_and_tiers_the_crew
test_the_widget_can_be_turned_off
test_calm_mode_hides_the_foremans_tool_calls
test_calm_mode_also_hides_assistant_thinking
test_the_vendored_calm_module_loads_under_pis_jiti
test_the_crew_command_completes_its_arguments
test_the_chrome_is_scoped_to_the_project_in_focus
test_a_linked_item_folds_into_its_crews_row_and_the_budget_holds
test_a_crew_and_its_item_render_as_one_row
test_the_status_column_honours_the_crews_own_busy_record
test_the_two_leftovers_each_keep_a_stated_row
test_a_row_never_wraps_at_the_narrow_bound
test_an_enormous_item_is_truncated_and_keeps_the_budget
test_a_proposal_is_counted_apart_and_never_a_captain_row
