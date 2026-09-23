#!/usr/bin/env bash
# crew-foreman-ext.test.sh - the captain's extension inside a crew session.
#
# The harness extension is the captain's: chrome, wake watcher, and the tools
# that spawn, steer and merge crew. A crew session must never have it. This was
# not theoretical: the first self-hosted crew (the project being this repo) had
# its worktree ship .pi/extensions/foreman.ts, pi discovered it next to the
# crew's own extension, both registered lavish_open and lavish_poll, and the
# refusal of the project one left the crew without the tools it needed.
#
# crew-launch.sh starts crew members with `-ne` and FOREMAN_CREW set. The flag is
# what stops the collision at launch; this file pins the guard, which covers every
# pi a crew starts afterwards because they inherit the marker. Driven under node
# with a fake pi API, so it is the real extension being asked.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if ! command -v node >/dev/null 2>&1; then
  pass "the crew guard check skipped (no node)"
  exit 0
fi

ROOTDIR=$(fm_tmproot crew-guard)
mkdir -p "$ROOTDIR/node_modules/@earendil-works/pi-ai" \
  "$ROOTDIR/node_modules/@earendil-works/pi-coding-agent"
fm_pi_tree "$ROOTDIR"
# The extension resolves its install root at import time by looking for
# bin/foreman-lib.sh above itself, so the temp copy needs one.
mkdir -p "$ROOTDIR/bin"
cp "$ROOT/bin/foreman-lib.sh" "$ROOTDIR/bin/foreman-lib.sh"
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

# The harness reports what the extension did when it was loaded: the tools it
# registered, the commands, and the events it subscribed to. An extension that
# returns early does all three silently.
HARNESS="$ROOTDIR/guard.mjs"
cat >"$HARNESS" <<'JS'
const [, , extPath, home] = process.argv;
process.env.FOREMAN_HOME = home;
const mod = await import(extPath);

const tools = [];
const commands = [];
const events = [];
const pi = {
	on: (event) => { events.push(event); },
	registerTool: (tool) => { tools.push(tool.name ?? "?"); },
	registerCommand: (name) => { commands.push(name); },
	sendMessage: () => {},
	sendUserMessage: () => {},
};
mod.default(pi);
process.stdout.write("TOOLS:" + JSON.stringify(tools) + "\n");
process.stdout.write("COMMANDS:" + JSON.stringify(commands) + "\n");
process.stdout.write("EVENTS:" + JSON.stringify(events) + "\n");
process.exit(0);
JS

load() { # <home> [crew-id] -> what the extension registered
  if [ -n "${2:-}" ]; then
    FOREMAN_CREW="$2" node "$HARNESS" "$ROOTDIR/.pi/extensions/foreman.ts" "$1"
  else
    node "$HARNESS" "$ROOTDIR/.pi/extensions/foreman.ts" "$1"
  fi
}

test_a_crew_session_gets_none_of_it() {
  local out
  fm_home >/dev/null
  out=$(load "$FOREMAN_HOME" house)

  assert_contains "$out" 'TOOLS:[]' "a crew session registers no captain tool"
  assert_contains "$out" 'COMMANDS:[]' "a crew session registers no captain command"
  assert_contains "$out" 'EVENTS:[]' "a crew session subscribes to nothing, so no wake watcher is armed"
  assert_not_contains "$out" "crew_spawn" "the crew cannot spawn crew"
  assert_not_contains "$out" "lavish_poll" "the crew does not get a second copy of the tools it is given"
  pass "a crew session is left to its own extension"
}

# Without this, the guard could be satisfied by an extension that never loads for
# anyone - which would be a worse bug than the one it fixes.
test_the_captain_still_gets_all_of_it() {
  local out
  fm_home >/dev/null
  out=$(load "$FOREMAN_HOME")

  assert_contains "$out" "crew_spawn" "the captain still gets the crew tools"
  assert_contains "$out" "lavish_poll" "the captain still gets the Lavish pair"
  assert_contains "$out" '"session_start"' "the captain's session is still the one that starts the watcher"
  assert_not_contains "$out" 'TOOLS:[]' "the captain's extension is not silently inert"
  pass "the guard is exact: it is the marker, not the extension, that decides"
}

test_a_crew_session_gets_none_of_it
test_the_captain_still_gets_all_of_it
