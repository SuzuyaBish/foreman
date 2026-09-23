#!/usr/bin/env node
/*
 * herdr-workspace-move.mjs - one narrowly scoped `workspace.move` over Herdr's
 * control socket.
 *
 * Herdr has no CLI for reordering workspaces: `herdr workspace` can create,
 * list, rename and close, but the move lives only on the socket API. This is the
 * whole reason a helper exists at all.
 *
 *   node bin/herdr-workspace-move.mjs <socket-path> <workspace-id> <insert-index>
 *
 * Exit status:
 *   0  the server returned the matching workspace_list response
 *   2  arguments or the socket path were unusable
 *   3  the request could not be sent or its response could not be read
 *   4  the response was malformed, mismatched, or reported an error
 *
 * It sends only `workspace.move`, only for the exact id it was given, and it
 * prints nothing on success: ordering is presentation-only, and the caller must
 * be free to ignore a failure and leave the crew running where Herdr put it.
 */

import * as net from "node:net";

const REQUEST_ID = "foreman-workspace-move";
const CONNECT_TIMEOUT_MS = 5000;
const RESPONSE_TIMEOUT_MS = 5000;
const MAX_RESPONSE_BYTES = 4 * 1024 * 1024;

function die(code, message) {
	process.stderr.write(`herdr-workspace-move: ${message}\n`);
	process.exit(code);
}

const [socketPath, workspaceId, insertIndexRaw] = process.argv.slice(2);
if (!socketPath || !workspaceId || insertIndexRaw === undefined) {
	die(2, "usage: herdr-workspace-move.mjs <socket-path> <workspace-id> <insert-index>");
}
if (!/^[0-9]+$/.test(insertIndexRaw)) die(2, `insert index must be a non-negative integer: ${insertIndexRaw}`);
const insertIndex = Number(insertIndexRaw);

const request = `${JSON.stringify({
	id: REQUEST_ID,
	method: "workspace.move",
	params: { workspace_id: workspaceId, insert_index: insertIndex },
})}\n`;

const socket = net.connect({ path: socketPath });
let settled = false;
const finish = (code, message) => {
	if (settled) return;
	settled = true;
	socket.destroy();
	if (message) process.stderr.write(`herdr-workspace-move: ${message}\n`);
	process.exit(code);
};

const timer = setTimeout(() => finish(3, "timed out talking to the Herdr socket"), RESPONSE_TIMEOUT_MS);
timer.unref?.();

let buffer = "";
socket.on("connect", () => socket.write(request));
socket.on("data", (chunk) => {
	buffer += chunk.toString();
	if (buffer.length > MAX_RESPONSE_BYTES) finish(4, "response was implausibly large");
	const newline = buffer.indexOf("\n");
	if (newline === -1) return;
	const line = buffer.slice(0, newline);

	let parsed;
	try {
		parsed = JSON.parse(line);
	} catch {
		finish(4, "response was not JSON");
		return;
	}
	if (parsed.id !== REQUEST_ID) {
		finish(4, `response id did not match the request: ${String(parsed.id)}`);
		return;
	}
	if (parsed.error) {
		finish(4, `server refused the move: ${JSON.stringify(parsed.error)}`);
		return;
	}
	// The verified success shape is the reordered workspace list. Anything else
	// means we cannot claim the order changed, so we do not.
	if (!parsed.result || parsed.result.type !== "workspace_list") {
		finish(4, `unexpected response shape: ${line.slice(0, 200)}`);
		return;
	}
	clearTimeout(timer);
	finish(0);
});
socket.on("error", (error) => finish(2, `socket error: ${error.message}`));
socket.on("close", () => finish(3, "the Herdr socket closed before it answered"));
