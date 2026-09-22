/**
 * foreman - crew tools, auto wake, and the zero-token crew chrome.
 *
 * Every tool shells out to a zero-token bash script under ../bin and returns a
 * hard-capped string. Crew output never streams into this conversation: a crew
 * member's report is only ever read by an explicit crew_read call.
 *
 * The same extension owns the auto wake (a one-shot bash watcher kept as a
 * child, whose single line is injected) and the status line/widget, which are
 * rendered from the task records directly and cost no tokens at all.
 *
 * See ../DESIGN.md for the context contract this exists to enforce.
 */

import { execFile, spawn, type ChildProcess } from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";
import { fileURLToPath } from "node:url";
import { Type } from "@earendil-works/pi-ai";
import {
	defineTool,
	type ExtensionAPI,
	type ExtensionContext,
} from "@earendil-works/pi-coding-agent";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const BIN = path.join(ROOT, "bin");
const HOME = process.env.FOREMAN_HOME ?? path.join(ROOT, ".foreman");
const TASKS = path.join(HOME, "tasks");

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

// --- tools -----------------------------------------------------------------

const crewSpawn = defineTool({
	name: "crew_spawn",
	label: "Spawn crew",
	description:
		"Start a new crew member: a separate pi process in its own Herdr pane with " +
		"an isolated context. It receives only the task text you pass. Its output " +
		"goes to a report file, never to you. Give it a project (preferred) or an " +
		"explicit cwd. Use a short kebab-case id that describes the work.",
	parameters: Type.Object({
		id: Type.String({ description: "Short kebab-case task id, e.g. auth-flake" }),
		task: Type.String({
			description: "The complete requirement. It is the crew member's whole context.",
		}),
		project: Type.Optional(
			Type.String({
				description:
					"Project name under projects/ (see crew_projects). Isolated in a git worktree by default.",
			}),
		),
		cwd: Type.Optional(
			Type.String({ description: "Explicit working directory, when the work is not in a project" }),
		),
		isolate: Type.Optional(
			Type.Boolean({
				description:
					"Create a dedicated git worktree and crew/<id> branch. Defaults to the session config for project work.",
			}),
		),
		delivery: Type.Optional(
			Type.String({
				description:
					"How the work is handed over: pr (push and open a pull request), local (commit only), or report (no code change). Defaults to auto.",
			}),
		),
		model: Type.Optional(
			Type.String({
				description: "Model for this crew member. Defaults to the session crew model.",
			}),
		),
		thinking: Type.Optional(
			Type.String({
				description: "low|medium|high|xhigh|max. Defaults to the session crew thinking level.",
			}),
		),
	}),
	async execute(_id, params) {
		const args = [params.id];
		if (params.project) args.push("--project", params.project);
		else if (params.cwd) args.push("--cwd", params.cwd);
		if (params.isolate === true) args.push("--isolate");
		if (params.isolate === false) args.push("--no-isolate");
		if (params.delivery) args.push("--delivery", params.delivery);
		if (params.model) args.push("--model", params.model);
		if (params.thinking) args.push("--thinking", params.thinking);
		args.push("--", params.task);
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

const crewProjects = defineTool({
	name: "crew_projects",
	label: "Projects",
	description:
		"The projects available to put crew to work in, one line each. Call this " +
		"before spawning when you are not certain of the project name.",
	parameters: Type.Object({
		filter: Type.Optional(Type.String({ description: "Only names containing this text" })),
	}),
	async execute(_id, params) {
		const text = await run("crew-projects.sh", params.filter ? [params.filter] : []);
		return { content: [{ type: "text", text }], details: undefined };
	},
});

const crewModels = defineTool({
	name: "crew_models",
	label: "Available models",
	description:
		"The models pi can run. Use it to resolve a model the captain names before " +
		"setting it with crew_config, or before passing one to crew_spawn.",
	parameters: Type.Object({
		search: Type.Optional(Type.String({ description: "Substring filter" })),
	}),
	async execute(_id, params) {
		const text = await run("crew-models.sh", params.search ? [params.search] : [], 2500);
		return { content: [{ type: "text", text }], details: undefined };
	},
});

const crewConfig = defineTool({
	name: "crew_config",
	label: "Crew settings",
	description:
		"The crew session settings: crewModel, crewThinking, crewDelivery, " +
		"crewIsolate, crewApprove, trustPaths, crewWake and crewWidget. Call it " +
		"with no arguments to show them. When the captain says which model to run " +
		"crew on, set crewModel (and crewThinking if they say how hard it should " +
		"think). Thereafter every spawn uses it.",
	parameters: Type.Object({
		key: Type.Optional(Type.String({ description: "Setting to change; omit to show all" })),
		value: Type.Optional(Type.String({ description: "New value" })),
	}),
	async execute(_id, params) {
		if (!params.key) {
			const text = await run("crew-config.sh", ["show"], 1500);
			return { content: [{ type: "text", text }], details: undefined };
		}
		if (params.value === undefined) {
			const text = await run("crew-config.sh", ["get", params.key], 1500);
			return { content: [{ type: "text", text }], details: undefined };
		}
		const text = await run("crew-config.sh", ["set", params.key, params.value], 1500);
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
		const text = await run("crew-peek.sh", [params.id, String(params.lines ?? 40)]);
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

const crewPrCheck = defineTool({
	name: "crew_pr_check",
	label: "Check crew PR",
	description:
		"Ask the forge whether a crew member's pull request has been merged or " +
		"closed. Use it when the captain asks about a task in review. A merge settles " +
		"the task and frees its pane and worktree; merging is the captain's act, not " +
		"yours.",
	parameters: Type.Object({
		id: Type.String({ description: "Crew task id" }),
	}),
	async execute(_id, params) {
		const text = await run("crew-pr-check.sh", [params.id]);
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
			Type.String({ description: "interrupt | exit | close (default interrupt)" }),
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
		"they need. Moves the task directory intact; deletes nothing. Pass worktree " +
		"to also remove the crew's git worktree. Refused while the task is working or " +
		"waiting on an unmerged pull request, unless force is set.",
	parameters: Type.Object({
		id: Type.String({ description: "Crew task id" }),
		worktree: Type.Optional(Type.Boolean({ description: "Also remove the git worktree" })),
		force: Type.Optional(Type.Boolean({ description: "Archive anyway (dirty or unmerged)" })),
	}),
	async execute(_id, params) {
		const args = [params.id];
		if (params.worktree) args.push("--worktree");
		if (params.force) args.push("--force");
		const text = await run("crew-archive.sh", args);
		return { content: [{ type: "text", text }], details: undefined };
	},
});

// --- crew chrome (status line + widget) ------------------------------------
//
// Rendered straight from the task records: no Herdr call, no model call, no
// tokens. The pane-existence refresh stays with crew_list, which is the only
// reader that needs it.

interface CrewRow {
	id: string;
	state: string;
	note: string;
}

const ACTIVE_STATES = new Set(["queued", "working", "review", "blocked", "failed", "lost"]);

function readBoard(): CrewRow[] {
	let names: string[];
	try {
		names = fs.readdirSync(TASKS);
	} catch {
		return [];
	}
	const rows: CrewRow[] = [];
	for (const id of names) {
		try {
			const raw = fs.readFileSync(path.join(TASKS, id, "status"), "utf8");
			rows.push({
				id,
				state: /^state=(.*)$/m.exec(raw)?.[1] ?? "unknown",
				note: /^note=(.*)$/m.exec(raw)?.[1] ?? "",
			});
		} catch {
			/* a task without a status yet is not worth rendering */
		}
	}
	return rows;
}

function configFlag(key: string, fallback: boolean): boolean {
	try {
		const cfg = JSON.parse(fs.readFileSync(path.join(HOME, "config.json"), "utf8")) as Record<
			string,
			unknown
		>;
		return typeof cfg[key] === "boolean" ? (cfg[key] as boolean) : fallback;
	} catch {
		return fallback;
	}
}

function updateChrome(ctx: ExtensionContext) {
	if (!ctx.hasUI) return;
	const rows = readBoard();

	if (rows.length === 0) {
		ctx.ui.setStatus("foreman", undefined);
		ctx.ui.setWidget("foreman", undefined);
		return;
	}

	const counts = new Map<string, number>();
	for (const row of rows) counts.set(row.state, (counts.get(row.state) ?? 0) + 1);
	const order = ["working", "review", "blocked", "queued", "failed", "lost"];
	const bits: string[] = [];
	for (const state of order) {
		const n = counts.get(state);
		if (n) bits.push(state === "working" ? `${n} working` : `${n} ${state}`);
	}
	ctx.ui.setStatus("foreman", `crew ${rows.length}${bits.length ? ` · ${bits.join(" · ")}` : ""}`);

	if (!configFlag("crewWidget", true)) {
		ctx.ui.setWidget("foreman", undefined);
		return;
	}
	const active = rows
		.filter((r) => ACTIVE_STATES.has(r.state))
		.sort((a, b) => (a.state === b.state ? a.id.localeCompare(b.id) : a.state.localeCompare(b.state)))
		.slice(0, 6)
		.map((r) => `${r.id.padEnd(16)} ${r.state.padEnd(8)} ${r.note}`.trimEnd());
	ctx.ui.setWidget("foreman", active.length ? active : undefined);
}

// --- auto wake -------------------------------------------------------------

let watcher: ChildProcess | null = null;
let stopping = false;
let backoffMs = 1000;
let chromeTimer: ReturnType<typeof setInterval> | null = null;

function wakeEnabled(): boolean {
	if (process.env.FOREMAN_WAKE === "0") return false;
	return configFlag("crewWake", true);
}

function startWatcher(pi: ExtensionAPI) {
	if (stopping || watcher || !wakeEnabled()) return;
	let child: ChildProcess;
	try {
		child = spawn(path.join(BIN, "crew-watch.sh"), [], {
			cwd: ROOT,
			env: { ...process.env, FOREMAN_ROOT: ROOT },
			stdio: ["ignore", "pipe", "ignore"],
		});
	} catch {
		return;
	}
	watcher = child;

	let out = "";
	child.stdout?.on("data", (chunk: Buffer) => {
		if (out.length < 512) out += chunk.toString();
	});

	let settled = false;
	const restart = () => {
		if (settled) return;
		settled = true;
		watcher = null;
		if (stopping) return;
		const line = out.trim().slice(0, 400);
		if (line) {
			backoffMs = 1000;
			try {
				// One line, state only. The foreman reads the board itself.
				pi.sendUserMessage(line, { deliverAs: "followUp" });
			} catch {
				/* no live session to deliver into */
			}
		}
		const delay = line ? 0 : backoffMs;
		backoffMs = Math.min(backoffMs * 2, 30_000);
		setTimeout(() => startWatcher(pi), delay);
	};

	child.on("error", restart);
	child.on("exit", restart);
}

export default function foreman(pi: ExtensionAPI) {
	pi.registerTool(crewSpawn);
	pi.registerTool(crewList);
	pi.registerTool(crewProjects);
	pi.registerTool(crewModels);
	pi.registerTool(crewConfig);
	pi.registerTool(crewPeek);
	pi.registerTool(crewRead);
	pi.registerTool(crewPrCheck);
	pi.registerTool(crewSend);
	pi.registerTool(crewStop);
	pi.registerTool(crewArchive);

	pi.registerCommand("crew", {
		description: "Show the crew board; /crew on|off toggles the crew widget",
		handler: async (args, ctx) => {
			const arg = (args ?? "").trim().toLowerCase();
			if (arg === "on" || arg === "off") {
				await run("crew-config.sh", ["set", "crewWidget", arg === "on" ? "true" : "false"], 500);
				updateChrome(ctx);
				ctx.ui.notify(`crew widget ${arg}`, "info");
				return;
			}
			const board = await run("crew-list.sh", [], 4000);
			ctx.ui.notify(board, "info");
		},
	});

	pi.on("session_start", async (_event, ctx) => {
		stopping = false;
		updateChrome(ctx);
		startWatcher(pi);
		if (!chromeTimer) {
			chromeTimer = setInterval(() => updateChrome(ctx), 15_000);
		}
	});

	pi.on("tool_execution_end", async (_event, ctx) => {
		updateChrome(ctx);
	});

	pi.on("session_shutdown", async () => {
		stopping = true;
		if (chromeTimer) {
			clearInterval(chromeTimer);
			chromeTimer = null;
		}
		try {
			watcher?.kill("SIGTERM");
		} catch {
			/* already gone */
		}
		watcher = null;
	});
}
