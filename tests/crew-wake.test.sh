#!/usr/bin/env bash
# crew-wake.test.sh - does a finished crew actually reach the foreman?
#
# The watcher only enqueues a durable row; the *delivery* is the extension's job,
# and it happens when the watcher exits and again at session start. This drives
# the real extension under node with the watcher stubbed to exit immediately, so
# that path runs without a Herdr session, and it pins the extension's idea of
# "rows waiting" to the shell's own count - the two disagreed once, and the whole
# wake feature was dead on a fresh home because of it.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if ! command -v node >/dev/null 2>&1; then
  pass "wake delivery check skipped (no node)"
  exit 0
fi

ROOTDIR=$(fm_tmproot wake)
EXTDIR="$ROOTDIR/.pi/extensions"
BINDIR="$ROOTDIR/bin"
mkdir -p "$EXTDIR" "$BINDIR/node_modules" "$ROOTDIR/node_modules/@earendil-works/pi-ai" \
  "$ROOTDIR/node_modules/@earendil-works/pi-coding-agent"
# bin is copied rather than symlinked, because the watcher is stubbed here.
cp -R "$ROOT/bin" "$ROOTDIR/bin.real"
rm -rf "$BINDIR" && mv "$ROOTDIR/bin.real" "$BINDIR"
cp "$ROOT/.pi/extensions/foreman.ts" "$EXTDIR/foreman.ts"

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

# The real watcher loops until something changes. This one reports a hit and
# exits at once, which is exactly what the real one does when a crew finishes.
cat >"$BINDIR/crew-watch.sh" <<'SH'
#!/usr/bin/env bash
printf 'crew wake: stub\n'
exit 0
SH
chmod +x "$BINDIR/crew-watch.sh"

HARNESS="$ROOTDIR/wake.mjs"
cat >"$HARNESS" <<'JS'
const [, , extPath, home] = process.argv;
process.env.FOREMAN_HOME = home;
const mod = await import(extPath);

const calls = [];
const handlers = {};
const ui = {
	setStatus: () => {},
	setWidget: () => {},
	notify: () => {},
	theme: { fg: (_c, t) => t },
};
const pi = {
	on: (event, handler) => { handlers[event] = handler; },
	registerTool: () => {},
	registerCommand: () => {},
	sendMessage: (message, options) => calls.push({ kind: "message", content: message?.content, options }),
	sendUserMessage: (content, options) => calls.push({ kind: "user", content, options }),
};

mod.default(pi);
await handlers.session_start({}, { hasUI: false, ui });
// The stub watcher exits immediately, which is what triggers delivery.
await new Promise((resolve) => setTimeout(resolve, 2000));
process.stdout.write("CALLS:" + JSON.stringify(calls) + "\n");
process.exit(0);
JS

# shell_count <home>: the shell's own answer, the owner the extension must match.
shell_count() {
  FOREMAN_HOME="$1" bash -c '. "$1/bin/foreman-lib.sh"; foreman_queue_count' _ "$ROOT"
}

wake_calls() { # <home> -> the calls the extension made, as JSON
  node "$HARNESS" "$EXTDIR/foreman.ts" "$1" 2>/dev/null | sed -n 's/^CALLS://p'
}

new_home() { # <name> -> a fresh home path
  local root
  root=$(fm_tmproot "wake-$1")
  mkdir -p "$root/home"
  printf '%s' "$root/home"
}

two_rows() { # <home>: a queue with rows 1 and 2, and no ack file at all
  printf '1\t2026-01-01T00:00:00Z\tstate\tcrew-a review\n2\t2026-01-01T00:00:05Z\tstate\tcrew-b failed\n' \
    >"$1/.wake-queue"
}

# The bug this file exists for: `.wake-acked` is only created by a drain, and the
# extension's count read both files in one try - so on a home that had never
# drained, the ENOENT answered "no wakes", nothing was announced, nothing could
# be drained, and the file was never created. Every wake on a fresh home was
# silently dropped, and the foreman sat idle while a crew finished.
test_a_home_that_never_drained_can_still_be_woken() {
  local home calls
  home=$(new_home fresh)
  two_rows "$home"
  calls=$(wake_calls "$home")
  assert_contains "$calls" "crew wake: 2 new (call crew_wake_drain)" \
    "two pending rows are announced with no ack file present"
  assert_contains "$calls" '"kind":"user"' "the wake is a real user turn, not quiet context"
  assert_equals "2" "$(shell_count "$home")" "and the shell agrees there are two"
  pass "a queue that was never drained still wakes the foreman"
}

test_the_count_follows_the_ack_cursor() {
  local home calls
  home=$(new_home acked)
  two_rows "$home"
  printf '1\n' >"$home/.wake-acked"
  calls=$(wake_calls "$home")
  assert_contains "$calls" "crew wake: 1 new" "an acked row is not announced again"
  assert_equals "1" "$(shell_count "$home")" "the shell agrees on the remainder"

  printf '2\n' >"$home/.wake-acked"
  calls=$(wake_calls "$home")
  assert_not_contains "$calls" "crew wake:" "a fully drained queue wakes nobody"
  assert_equals "0" "$(shell_count "$home")" "the shell agrees it is empty"
  pass "the announced count follows the ack cursor exactly as the shell does"
}

test_an_empty_queue_wakes_nobody() {
  local home calls
  home=$(new_home empty)
  : >"$home/.wake-queue"
  calls=$(wake_calls "$home")
  assert_not_contains "$calls" "crew wake:" "an empty queue is not a wake"
  pass "an idle queue stays silent"
}

test_the_digest_stays_free() {
  local home calls
  home=$(new_home digest)
  two_rows "$home"
  calls=$(wake_calls "$home")
  # The distinction is the whole design: context is injected without spending a
  # turn, and a wake spends one. Getting these two confused is how a wake becomes
  # something the captain has to dig for.
  assert_contains "$calls" '"triggerTurn":false' "the session digest still costs no turn"
  assert_contains "$calls" '"kind":"user"' "the wake does cost a turn"
  pass "the digest stays free and the wake costs a turn"
}

test_a_home_that_never_drained_can_still_be_woken
test_the_count_follows_the_ack_cursor
test_an_empty_queue_wakes_nobody
test_the_digest_stays_free
