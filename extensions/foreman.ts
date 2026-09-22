/**
 * foreman - crew tools for the foreman session.
 *
 * Every tool shells out to a zero-token bash script under ../bin and returns a
 * hard-capped string. Crew output never streams into this conversation: a crew
 * member's report is only ever read by an explicit crew_read call.
 *
 * See ../DESIGN.md for the context contract this exists to enforce.
 */

import { execFile } from "node:child_process";
import * as path from "node:path";
import { fileURLToPath } from "node:url";
import { Type } from "@earendil-works/pi-ai";
import { defineTool, type ExtensionAPI } from "@earendil-works/pi-coding-agent";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const BIN = path.join(ROOT, "bin");

/** Hard ceiling on anything a tool may put into the foreman's context. */
const CAP = 4000;

function run(script: string, args: string[], cap = CAP): Promise<string> {
	return new Promise((resolve, reject) => {
		execFile(
			path.join(BIN, script),
			args,
			{
				cwd: ROOT,
				maxBuffer: 4 * 1024 * 1024,
				env: { ...process.env, FOREMAN_ROOT: ROOT },
			},
			(error, stdout, stderr) => {
				const body = `${stdout ?? ""}${stderr ?? ""}`.trim();
				const text =
					body.length > cap
						? `${body.slice(0, cap)}\n…[capped at ${cap} chars]`
						: body;
				if (error && !stdout) {
					reject(new Error(text || String(error)));
					return;
				}
				resolve(text || "(no output)");
			},
		);
	});
}

const crewSpawn = defineTool({
	name: "crew_spawn",
	label: "Spawn crew",
	description:
		"Start a new crew member: a separate pi process in its own Herdr pane with " +
		"an isolated context. It receives only the task text you pass and works in " +
		"the given directory. Its output goes to a report file, never to you. Use a " +
		"short kebab-case id that describes the work. Use a git worktree path as cwd " +
		"when two crew touch one repository.",
	parameters: Type.Object({
		id: Type.String({ description: "Short kebab-case task id, e.g. auth-flake" }),
		cwd: Type.String({ description: "Absolute working directory for the crew member" }),
		task: Type.String({
			description: "The complete requirement. It is the crew member's whole context.",
		}),
		model: Type.Optional(Type.String({ description: "Optional model override" })),
		thinking: Type.Optional(
			Type.String({ description: "Optional thinking level: low|medium|high|xhigh|max" }),
		),
	}),
	async execute(_id, params) {
		const args = [params.id, params.cwd];
		if (params.model) args.push("--model", params.model);
		if (params.thinking) args.push("--thinking", params.thinking);
		args.push(params.task);
		const text = await run("crew-spawn.sh", args);
		return { content: [{ type: "text", text }], details: undefined };
	},
});

const crewList = defineTool({
	name: "crew_list",
	label: "Crew board",
	description:
		"The whole fleet as one line per crew member: id, state, age, note. This is " +
		"your default look and your only memory of the fleet — prefer it over " +
		"recalling earlier turns. Also refreshes the pane-existence check.",
	parameters: Type.Object({}),
	async execute() {
		const text = await run("crew-list.sh", []);
		return { content: [{ type: "text", text }], details: undefined };
	},
});

const crewPeek = defineTool({
	name: "crew_peek",
	label: "Peek at crew",
	description:
		"Bounded tail of one crew member's terminal. Inspection only — use it when " +
		"the captain asks what a crew is doing right now, or to diagnose a stall. " +
		"Do not call it speculatively.",
	parameters: Type.Object({
		id: Type.String({ description: "Crew task id" }),
		lines: Type.Optional(Type.Number({ description: "Lines to show (default 40, max 200)" })),
	}),
	async execute(_id, params) {
		const text = await run("crew-peek.sh", [
			params.id,
			String(params.lines ?? 40),
		]);
		return { content: [{ type: "text", text }], details: undefined };
	},
});

const crewRead = defineTool({
	name: "crew_read",
	label: "Read crew report",
	description:
		"Read a crew member's report. This is the one place crew output enters your " +
		"context, so call it only when the captain asks for that crew's findings or " +
		"you must decide something. Output is truncated; the full path is printed.",
	parameters: Type.Object({
		id: Type.String({ description: "Crew task id" }),
	}),
	async execute(_id, params) {
		const text = await run("crew-read.sh", [params.id]);
		return { content: [{ type: "text", text }], details: undefined };
	},
});

const crewSend = defineTool({
	name: "crew_send",
	label: "Steer crew",
	description:
		"Send an instruction to a running crew member. It is written durably and a " +
		"doorbell is rung in its pane; the crew acknowledges by reading it. Use this " +
		"for direction, constraints, or answers — not for stopping a crew.",
	parameters: Type.Object({
		id: Type.String({ description: "Crew task id" }),
		text: Type.String({ description: "The instruction to deliver" }),
	}),
	async execute(_id, params) {
		const text = await run("crew-send.sh", [params.id, params.text]);
		return { content: [{ type: "text", text }], details: undefined };
	},
});

const crewStop = defineTool({
	name: "crew_stop",
	label: "Stop crew",
	description:
		"Stop a crew member. interrupt (default) cancels the current turn and leaves " +
		"the agent running; exit quits the agent but keeps its pane, directory and " +
		"files; close also closes the tab. Confirmations are reported honestly.",
	parameters: Type.Object({
		id: Type.String({ description: "Crew task id" }),
		mode: Type.Optional(
			Type.String({
				description: "interrupt | exit | close (default interrupt)",
			}),
		),
	}),
	async execute(_id, params) {
		const mode = params.mode ? `--${params.mode.replace(/^--/, "")}` : "--interrupt";
		const text = await run("crew-stop.sh", [params.id, mode]);
		return { content: [{ type: "text", text }], details: undefined };
	},
});

const crewArchive = defineTool({
	name: "crew_archive",
	label: "Archive crew",
	description:
		"Retire a finished task out of the active board once the captain has what " +
		"they need. Moves the task directory intact; deletes nothing. Refuses while " +
		"the crew is still working or queued.",
	parameters: Type.Object({
		id: Type.String({ description: "Crew task id" }),
	}),
	async execute(_id, params) {
		const text = await run("crew-archive.sh", [params.id]);
		return { content: [{ type: "text", text }], details: undefined };
	},
});

export default function foreman(pi: ExtensionAPI) {
	pi.registerTool(crewSpawn);
	pi.registerTool(crewList);
	pi.registerTool(crewPeek);
	pi.registerTool(crewRead);
	pi.registerTool(crewSend);
	pi.registerTool(crewStop);
	pi.registerTool(crewArchive);
}
