#!/usr/bin/env bash
# crew-spawn-tool.test.sh - the crew_spawn TOOL, not the script.
#
# The script path is covered by crew-spawn.test.sh and crew-workspace.test.sh:
# they run crew-spawn.sh with --todo and see the number in the label. The tool is
# a separate caller and it was the gap. It used to run crew-spawn.sh with no
# --todo and only afterwards link the item, so the launch built the label as
# `└ <id>` and the number reached the board too late to ever be drawn. This
# drives the real extension under node with a fake pi API and the real scripts
# behind a stub Herdr, and asserts the launcher receives the number and the item
# is linked exactly once.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if ! command -v node >/dev/null 2>&1; then
  pass "crew_spawn tool check skipped (no node)"
  exit 0
fi

fm_home >/dev/null
fm_herdr_stub >/dev/null
fm_pi_stub >/dev/null

# The pi-visible layout the extension is discovered in: the extension and its
# sibling lib, with bin reachable so it resolves its install root, and the pi
# packages stubbed so no model is needed.
ROOTDIR=$(fm_tmproot spawn-tool)
mkdir -p "$ROOTDIR/node_modules/@earendil-works/pi-ai" \
  "$ROOTDIR/node_modules/@earendil-works/pi-coding-agent"
ln -s "$ROOT/bin" "$ROOTDIR/bin"
fm_pi_tree "$ROOTDIR"

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
// calm patches this prototype to drop thinking; the stub keeps its contract.
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
// calm re-registers the built-in tools through these factories. A pi without
// them is tolerated, but providing them keeps the extension on the real path.
const builtin = (name) => () => ({
  name,
  label: name,
  description: name,
  parameters: {},
  async execute() {
    return { content: [{ type: "text", text: name + " out" }], details: undefined };
  },
  renderCall(_args, _theme, context) {
    const text = context.lastComponent ?? { render: () => [], setText() {}, invalidate() {} };
    text.setText(name + " call");
    return text;
  },
  renderResult(_result, _options, _theme, context) {
    const text = context.lastComponent ?? { render: () => [], setText() {}, invalidate() {} };
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

HARNESS="$ROOTDIR/spawn-tool.mjs"
cat >"$HARNESS" <<'JS'
const [, , extPath, home, paramsJson] = process.argv;
process.env.FOREMAN_HOME = home;
const mod = await import(extPath);
const tools = {};
const pi = {
	on: () => {},
	registerTool: (tool) => { tools[tool.name] = tool; },
	registerCommand: () => {},
	sendMessage: () => {},
	sendUserMessage: () => {},
};
await mod.default(pi);
const res = await tools.crew_spawn.execute("call-1", JSON.parse(paramsJson));
process.stdout.write("RESULT:" + (res.content?.[0]?.text ?? "") + "\n");
JS

crew_spawn_tool() { # <params-json> -> what the tool returned
  node "$HARNESS" "$ROOTDIR/.pi/extensions/foreman.ts" "$FOREMAN_HOME" "$1" 2>&1
}

test_the_tool_numbers_the_workspace_and_links_once() {
  local dir out seq relink
  dir=$(fm_tmproot spawn-tool-cwd)

  "$BIN/crew-todo.sh" add --project proj "label from the tool" >/dev/null
  seq=$(cut -f1 "$FOREMAN_HOME/todo.tsv" | tail -1)
  [ -n "$seq" ] || fail "the fixture item was not created"

  out=$(crew_spawn_tool "{\"id\":\"tool-crew\",\"cwd\":\"$dir\",\"todo\":$seq,\"task\":\"number the workspace\"}")
  assert_contains "$out" "launched tool-crew" "the tool drove a real spawn"

  # The number must reach the launcher before the label is written: the label is
  # created once, at launch, and never rewritten.
  assert_contains "$(fm_herdr_calls)" "--label └ #$seq tool-crew" \
    "the workspace label leads with the item number"

  # Linked exactly once: the item is active on this crew and no other crew claims
  # it. A second writer (the tool's later crew-todo.sh start) would show here as
  # a divergence or a double write.
  assert_equals "active" "$(awk -F'\t' -v s="$seq" '$1 == s { print $2 }' "$FOREMAN_HOME/todo.tsv")" \
    "the item is active"
  assert_equals "tool-crew" "$(awk -F'\t' -v s="$seq" '$1 == s { print $3 }' "$FOREMAN_HOME/todo.tsv")" \
    "the item is linked to the spawned crew"
  relink=$(awk -F'\t' '$3 == "tool-crew"' "$FOREMAN_HOME/todo.tsv" | wc -l | tr -d ' ')
  assert_equals "1" "$relink" "the crew is linked to exactly one item"

  assert_contains "$out" "#$seq active on crew tool-crew" "the tool reports the link it made"
  pass "the crew_spawn tool forwards the item number and links the item exactly once"
}

test_the_tool_spawn_without_an_item_keeps_the_plain_label() {
  local dir out
  dir=$(fm_tmproot spawn-tool-plain)
  out=$(crew_spawn_tool "{\"id\":\"plain-tool\",\"cwd\":\"$dir\",\"task\":\"no item here\"}")
  assert_contains "$out" "launched plain-tool" "a spawn without a todo still launches"
  assert_contains "$(fm_herdr_calls)" "--label └ plain-tool" \
    "a spawn that names no item keeps the id-only label"
  pass "the tool's label is unchanged when no item is named"
}

test_the_tool_numbers_the_workspace_and_links_once
test_the_tool_spawn_without_an_item_keeps_the_plain_label
