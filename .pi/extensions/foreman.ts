/**
 * foreman - crew tools, todo list, auto wake, and the zero-token chrome.
 *
 * Every tool shells out to a zero-token bash script under ../bin and returns a
 * hard-capped string. Crew output never streams into this conversation: a crew
 * member's report is only ever read by an explicit crew_read call.
 *
 * The same extension owns:
 *   * the auto wake — a one-shot bash watcher kept as a child, whose durable
 *     rows are drained by the foreman rather than injected as payload;
 *   * the status line and widget, rendered from the task and todo records
 *     directly, so fleet visibility costs no tokens.
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

const HERE = path.dirname(fileURLToPath(import.meta.url));

/**
 * The install root: the nearest ancestor carrying the mechanics in `bin/`. The
 * extension lives in `<root>/.pi/extensions/`, where pi discovers it, so the
 * root is two directories up — but counting directories up would break the first
 * time this file moves, and a wrong answer here means writing state to the wrong
 * place. Ask for the thing itself and fail loudly instead.
 */
function installRoot(start: string): string {
	let dir = start;
	for (;;) {
		if (fs.existsSync(path.join(dir, "bin", "foreman-lib.sh"))) return dir;
		const up = path.dirname(dir);
		if (up === dir) {
			throw new Error(`foreman: no install root above ${start} (bin/foreman-lib.sh not found)`);
		}
		dir = up;
	}
}

const ROOT = process.env.FOREMAN_ROOT ?? installRoot(HERE);
const BIN = path.join(ROOT, "bin");
const HOME = process.env.FOREMAN_HOME ?? path.join(ROOT, ".foreman");
const TASKS = path.join(HOME, "tasks");
const TODO = path.join(HOME, "todo.tsv");

/** Hard ceiling on anything a tool may put into the foreman's context. */
const CAP = 4000;

/**
 * `lavish-axi` results end with a full DOM serialization of the artifact. It is
 * the largest part of the response and it is not the feedback, so trim that line
 * and cap the rest, the same way every other tool result is capped.
 */
function boundLavish(raw: string): string {
	const trimmed = raw.trim().replace(/^dom_snapshot: .*$/m, "dom_snapshot: …[trimmed]");
	return trimmed.length > CAP ? `${trimmed.slice(0, CAP)}\n…[capped at ${CAP} chars]` : trimmed;
}

function run(script: string, args: string[], cap = CAP): Promise<string> {
	return new Promise((resolve, reject) => {
		execFile(
			path.join(BIN, script),
			args,
			{ cwd: ROOT, maxBuffer: 4 * 1024 * 1024, env: { ...process.env, FOREMAN_ROOT: ROOT } },
			(error, stdout, stderr) => {
				const body = `${stdout ?? ""}${stderr ?? ""}`.trim();
				const text =
					body.length > cap ? `${body.slice(0, cap)}\n…[capped at ${cap} chars]` : body;
				if (error && !stdout) {
					reject(new Error(text || String(error)));
					return;
				}
				resolve(text || "(no output)");
			},
		);
	});
}

function one(name: string, label: string, description: string, parameters: any, script: string, args: (p: any) => string[]) {
	return defineTool({
		name,
		label,
		description,
		parameters,
		async execute(_id: string, params: any) {
			const text = await run(script, args(params ?? {}));
			return { content: [{ type: "text", text }], details: undefined };
		},
	});
}

// --- todo list -------------------------------------------------------------

const crewTodo = defineTool({
	name: "crew_todo",
	label: "Todo list",
	description:
		"The durable project todo list. It outlives this session: a new session reads " +
		"it and knows what is queued, in flight, and finished. Use `action: add` to " +
		"capture requirements as items, `list` to answer what is left, `start` to link " +
		"an item to the crew member working on it, and `done`/`open`/`drop` to settle " +
		"one by hand. Rows linked to crew are reconciled automatically. " +
		"Items are scoped by project: one harness serves many projects, and `list` " +
		"shows the scope in focus (the project of the newest crew, unless set), so " +
		"work for one project never reads as another's. Pass `project` on add to " +
		"file an item elsewhere, and `show: all` to see every scope grouped.",
	parameters: Type.Object({
		action: Type.String({
			description: "add | list | start | done | open | drop",
		}),
		items: Type.Optional(
			Type.Array(Type.String(), {
				description: "For add: one or more item texts, in order",
			}),
		),
		id: Type.Optional(Type.Number({ description: "Item number, for start/done/open/drop" })),
		crew: Type.Optional(
			Type.String({ description: "For start: the crew task id doing the work" }),
		),
		project: Type.Optional(
			Type.String({
				description:
					"For add: the project this work belongs to, e.g. the project name a crew was " +
					"spawned into. Defaults to the scope in focus.",
			}),
		),
		show: Type.Optional(
			Type.String({ description: "For list: open, or all (every scope grouped)" }),
		),
	}),
	async execute(_id, params) {
		const action = params.action;
		if (action === "add") {
			const items: string[] = params.items?.length ? params.items : [];
			if (items.length === 0) throw new Error("add needs one or more items");
			const out: string[] = [];
			for (const item of items) {
				const args = params.project ? ["add", "--project", params.project, item] : ["add", item];
				out.push(await run("crew-todo.sh", args, 500));
			}
			return { content: [{ type: "text", text: out.join("\n") }], details: undefined };
		}
		if (action === "list") {
			// No `--all` by default: the board reads the scope in focus, which is the
			// whole point of scoping. `show: all` is how you ask for every project.
			const args = ["list"];
			if (params.show === "open") args.push("--open");
			else if (params.show === "all") args.push("--all");
			if (params.project) args.push("--project", params.project);
			const text = await run("crew-todo.sh", args);
			return { content: [{ type: "text", text }], details: undefined };
		}
		if (action === "start") {
			if (params.id === undefined || !params.crew) throw new Error("start needs id and crew");
			const text = await run("crew-todo.sh", ["start", String(params.id), params.crew], 500);
			return { content: [{ type: "text", text }], details: undefined };
		}
		if (["done", "open", "drop"].includes(action)) {
			if (params.id === undefined) throw new Error(`${action} needs id`);
			const text = await run("crew-todo.sh", [action, String(params.id)], 500);
			return { content: [{ type: "text", text }], details: undefined };
		}
		throw new Error(`unknown todo action: ${action}`);
	},
});

// --- crew ------------------------------------------------------------------

const crewSpawn = defineTool({
	name: "crew_spawn",
	label: "Spawn crew",
	description:
		"Start a new crew member: a separate pi process in its own Herdr pane with an " +
		"isolated context. It receives only the task text you pass. Its output goes to " +
		"a report file, never to you. Give it a project (preferred) or an explicit " +
		"cwd, and pass `todo` to link the item it is working on.",
	parameters: Type.Object({
		id: Type.String({ description: "Short kebab-case task id, e.g. auth-flake" }),
		task: Type.String({
			description: "The complete requirement. It is the crew member's whole context.",
		}),
		project: Type.Optional(Type.String({ description: "Project name under projects/ (see crew_projects)" })),
		cwd: Type.Optional(Type.String({ description: "Explicit working directory" })),
		isolate: Type.Optional(Type.Boolean({ description: "Create a dedicated git worktree and crew/<id> branch" })),
		delivery: Type.Optional(Type.String({ description: "pr | local | report (default: auto)" })),
		model: Type.Optional(Type.String({ description: "Model for this crew member" })),
		thinking: Type.Optional(Type.String({ description: "low|medium|high|xhigh|max" })),
		todo: Type.Optional(Type.Number({ description: "Todo item number this work fulfils" })),
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
		let text = await run("crew-spawn.sh", args);
		if (params.todo !== undefined) {
			try {
				const linked = await run("crew-todo.sh", ["start", String(params.todo), params.id], 300);
				text += `\n${linked}`;
			} catch (error) {
				text += `\nwarning: could not link todo #${params.todo}: ${String(error)}`;
			}
		}
		return { content: [{ type: "text", text }], details: undefined };
	},
});

const crewList = defineTool({
	name: "crew_list",
	label: "Crew board",
	description:
		"The todo list plus the whole fleet as one line per crew member: id, state, " +
		"age, busy, note. This is your default look and your only memory of the fleet " +
		"— prefer it over recalling earlier turns. Also refreshes endpoint checks.",
	parameters: Type.Object({}),
	async execute() {
		const text = await run("crew-list.sh", []);
		return { content: [{ type: "text", text }], details: undefined };
	},
});

const crewProjects = one(
	"crew_projects",
	"Projects",
	"The projects available to put crew to work in, one line each.",
	Type.Object({ filter: Type.Optional(Type.String()) }),
	"crew-projects.sh",
	(p) => (p.filter ? [p.filter] : []),
);

const crewModels = one(
	"crew_models",
	"Available models",
	"The models pi can run. Use it to resolve a model the captain names.",
	Type.Object({ search: Type.Optional(Type.String()) }),
	"crew-models.sh",
	(p) => (p.search ? [p.search] : []),
);

const crewConfig = defineTool({
	name: "crew_config",
	label: "Crew settings",
	description:
		"The crew session settings: crewModel, crewThinking, crewDelivery, crewIsolate, " +
		"crewApprove, trustPaths, crewWake, crewWidget. Call with no arguments to show " +
		"them. When the captain says which model to run crew on, set crewModel.",
	parameters: Type.Object({
		key: Type.Optional(Type.String()),
		value: Type.Optional(Type.String()),
	}),
	async execute(_id, params) {
		if (!params.key) return { content: [{ type: "text", text: await run("crew-config.sh", ["show"], 1500) }], details: undefined };
		if (params.value === undefined)
			return { content: [{ type: "text", text: await run("crew-config.sh", ["get", params.key], 1500) }], details: undefined };
		return { content: [{ type: "text", text: await run("crew-config.sh", ["set", params.key, params.value], 1500) }], details: undefined };
	},
});

const crewPeek = one(
	"crew_peek",
	"Peek at crew",
	"Bounded tail of one crew member's terminal. Inspection only — use it when the captain asks what a crew is doing, or to diagnose a stall.",
	Type.Object({ id: Type.String(), lines: Type.Optional(Type.Number()) }),
	"crew-peek.sh",
	(p) => [p.id, String(p.lines ?? 40)],
);

const crewRead = one(
	"crew_read",
	"Read crew report",
	"Read a crew member's report. The one place crew output enters your context; call it only when the captain asks or you must decide something.",
	Type.Object({ id: Type.String() }),
	"crew-read.sh",
	(p) => [p.id],
);

const crewBusy = one(
	"crew_busy",
	"Ask what a crew is doing",
	"Whether a crew member is mid-turn (busy), settled and waiting (idle), gone (dead), or unknown — with the source that produced it. Use it to tell a working crew from one that has stalled at its prompt.",
	Type.Object({ id: Type.String() }),
	"crew-busy.sh",
	(p) => [p.id],
);

const crewPrCheck = one(
	"crew_pr_check",
	"Check crew PR",
	"Ask the forge whether a crew member's pull request has been merged or closed.",
	Type.Object({ id: Type.String() }),
	"crew-pr-check.sh",
	(p) => [p.id],
);

const crewSend = one(
	"crew_send",
	"Steer crew",
	"Send an instruction to a running crew member. It is written durably and a doorbell is rung; the crew acknowledges by reading it.",
	Type.Object({ id: Type.String(), text: Type.String() }),
	"crew-send.sh",
	(p) => [p.id, p.text],
);

const crewDecide = defineTool({
	name: "crew_decide",
	label: "Answer a crew decision",
	description:
		"Answer a question a crew member asked. The decision closes with the answer and " +
		"the crew receives it in its inbox — one act, so the board can never show a " +
		"decision that has already been answered. `crew_decide` with no id lists every " +
		"open decision across the fleet.",
	parameters: Type.Object({
		list: Type.Optional(Type.Boolean({ description: "List open decisions instead" })),
		id: Type.Optional(Type.String({ description: "Crew task id" })),
		key: Type.Optional(Type.String({ description: "The decision key the crew used" })),
		answer: Type.Optional(Type.String({ description: "The answer to deliver" })),
	}),
	async execute(_id, params) {
		if (params.list || !params.id) {
			return { content: [{ type: "text", text: await run("crew-decide.sh", ["--list"]) }], details: undefined };
		}
		if (!params.key || !params.answer) throw new Error("crew_decide needs key and answer");
		const text = await run("crew-decide.sh", [params.id, params.key, params.answer], 800);
		return { content: [{ type: "text", text }], details: undefined };
	},
});

const crewMerge = defineTool({
	name: "crew_merge",
	label: "Merge crew PR",
	description:
		"Merge a crew member's pull request and settle the task. ONLY call this when " +
		"the captain has explicitly authorised the merge — merging is their decision, " +
		"not yours. The branch is kept unless they ask for it to be deleted.",
	parameters: Type.Object({
		id: Type.String({ description: "Crew task id" }),
		method: Type.Optional(Type.String({ description: "squash (default) | merge | rebase" })),
		delete_branch: Type.Optional(Type.Boolean({ description: "Also delete the branch (removes the worktree first)" })),
	}),
	async execute(_id, params) {
		const args = [params.id];
		if (params.method) args.push("--method", params.method);
		if (params.delete_branch) args.push("--delete-branch");
		const text = await run("crew-merge.sh", args, 2000);
		return { content: [{ type: "text", text }], details: undefined };
	},
});

const crewStop = defineTool({
	name: "crew_stop",
	label: "Stop crew",
	description:
		"Stop a crew member. interrupt (default) cancels the current turn; exit quits " +
		"the agent but keeps its pane, directory and files; close also closes the tab.",
	parameters: Type.Object({
		id: Type.String(),
		mode: Type.Optional(Type.String({ description: "interrupt | exit | close" })),
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
		"Retire a finished task out of the active board. Moves the task directory " +
		"intact; deletes nothing. Pass worktree to also remove its git worktree. " +
		"Refused while working or waiting on an unmerged pull request unless force.",
	parameters: Type.Object({
		id: Type.String(),
		worktree: Type.Optional(Type.Boolean()),
		force: Type.Optional(Type.Boolean()),
	}),
	async execute(_id, params) {
		const args = [params.id];
		if (params.worktree) args.push("--worktree");
		if (params.force) args.push("--force");
		const text = await run("crew-archive.sh", args);
		return { content: [{ type: "text", text }], details: undefined };
	},
});

const crewRecover = defineTool({
	name: "crew_recover",
	label: "Recover crew",
	description:
		"Reconcile the fleet after a crash or a lost terminal: report which tasks have " +
		"no endpoint, or relaunch one in its existing worktree with a progress note so " +
		"its commits and uncommitted work survive.",
	parameters: Type.Object({
		id: Type.Optional(Type.String({ description: "Relaunch this crew task; omit to scan" })),
		force: Type.Optional(Type.Boolean({ description: "Relaunch even if a pane is still reachable" })),
	}),
	async execute(_id, params) {
		const args: string[] = [];
		if (params.id) args.push("--relaunch", params.id);
		if (params.force) args.push("--force");
		const text = await run("crew-recover.sh", args, 2000);
		return { content: [{ type: "text", text }], details: undefined };
	},
});

const crewWakeDrain = one(
	"crew_wake_drain",
	"Drain wakes",
	"Show the wake rows waiting for you and the sequence to acknowledge. Rows are durable and re-present until acknowledged, so a crash cannot lose them.",
	Type.Object({ ack: Type.Optional(Type.Number({ description: "Acknowledge through this sequence" })) }),
	"crew-queue.sh",
	(p) => (p.ack === undefined ? ["list"] : ["ack", String(p.ack)]),
);

// --- machine check ---------------------------------------------------------

const crewDoctor = one(
	"crew_doctor",
	"Check the machine",
	"Check this machine before work starts: the Herdr server, jq, git, pi, gh auth, " +
		"and the optional tools. Run it when launches or deliveries fail unexpectedly, " +
		"or when the captain asks whether the setup is healthy.",
	Type.Object({}),
	"crew-doctor.sh",
	() => [],
);

const crewHandoff = one(
	"crew_handoff",
	"Session handoff",
	"The dated note one session leaves for the next: what is in flight, what was decided, " +
		"and what a fresh session would otherwise have to rediscover. Call with text to write " +
		"it — do that before the session ends — or with no text to read back the note on " +
		"disk. It is never wiped; the next session ingests it once, and only while it is the " +
		"previous session's.",
	Type.Object({
		text: Type.Optional(
			Type.String({ description: "The handoff body; omit it to read the note back" }),
		),
	}),
	"crew-handoff.sh",
	(p) => (p.text ? ["write", p.text] : ["show"]),
);

// --- Lavish ----------------------------------------------------------------

const lavishOpen = one(
	"lavish_open",
	"Open Lavish board",
	"Open or resume a Lavish review board for an HTML artifact, so the captain can annotate it and send structured feedback back. Use it whenever a report or decision is easier to review visually than in prose.",
	Type.Object({ file: Type.String({ description: "Path to the HTML artifact" }) }),
	"crew-lavish.sh",
	(p) => ["open", p.file],
);

const lavishPoll = defineTool({
	name: "lavish_poll",
	label: "Wait for board feedback",
	description:
		"Wait for the captain's feedback on a Lavish board. This is a tracked wait: it " +
		"resumes you with whatever arrived, so it never holds the session. Call it once " +
		"after opening a board and leave it running.",
	parameters: Type.Object({ file: Type.String({ description: "Path to the HTML artifact" }) }),
	async execute(_id, params) {
		if (lavishChild) {
			return { content: [{ type: "text", text: "already polling — feedback is on its way" }], details: undefined };
		}
		return await new Promise<any>((resolve) => {
			let child: ChildProcess;
			try {
				child = spawn("lavish-axi", ["poll", params.file], {
					cwd: ROOT,
					stdio: ["ignore", "pipe", "pipe"],
				});
			} catch (error) {
				resolve({ content: [{ type: "text", text: String(error) }], details: undefined });
				return;
			}
			lavishChild = child;
			let out = "";
			child.stdout?.on("data", (d: Buffer) => {
				if (out.length < 65536) out += d.toString();
			});
			child.stderr?.on("data", (d: Buffer) => {
				if (out.length < 65536) out += d.toString();
			});
			child.on("exit", () => {
				lavishChild = null;
				resolve({
					content: [{ type: "text", text: boundLavish(out) || "board closed" }],
					details: undefined,
				});
			});
		});
	},
});

// --- crew chrome -----------------------------------------------------------

interface CrewRow {
	id: string;
	state: string;
	at: string;
	note: string;
}

const ACTIVE_STATES = new Set(["queued", "working", "review", "blocked", "failed", "lost"]);

/**
 * Worst first. A state the captain has to act on leads the status line and the
 * widget; a state that is merely alive trails it. Anything unrecognised sorts
 * last rather than vanishing.
 */
const STATE_ORDER = ["blocked", "failed", "lost", "review", "working", "queued"];
const STATE_RANK = new Map(STATE_ORDER.map((state, i) => [state, i]));

/** Theme roles, so the chrome reads correctly in a light and a dark terminal. */
const STATE_COLOR: Record<string, "warning" | "error" | "accent" | "success" | "dim"> = {
	blocked: "warning",
	failed: "error",
	lost: "error",
	review: "accent",
	working: "success",
	queued: "dim",
};

/**
 * Mirrors foreman_age_human in bin/foreman-lib.sh, so the chrome and `crew`
 * never disagree about how old a report is. `?` means unreadable, never zero.
 */
function ageOf(at: string): string {
	const then = Date.parse(at);
	if (!at || !Number.isFinite(then)) return "?";
	const secs = Math.max(0, Math.floor((Date.now() - then) / 1000));
	if (secs < 60) return `${secs}s`;
	if (secs < 3600) return `${Math.floor(secs / 60)}m`;
	if (secs < 86400) return `${Math.floor(secs / 3600)}h`;
	return `${Math.floor(secs / 86400)}d`;
}

function rankOf(row: CrewRow): number {
	return STATE_RANK.get(row.state) ?? STATE_ORDER.length;
}

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
				at: /^at=(.*)$/m.exec(raw)?.[1] ?? "",
				note: /^note=(.*)$/m.exec(raw)?.[1] ?? "",
			});
		} catch {
			/* a task without a status yet is not worth rendering */
		}
	}
	return rows;
}

interface TodoRow {
	seq: string;
	status: string;
	crew: string;
	text: string;
	scope: string;
}

function readTodo(): TodoRow[] {
	let raw: string;
	try {
		raw = fs.readFileSync(TODO, "utf8");
	} catch {
		return [];
	}
	const rows: TodoRow[] = [];
	for (const line of raw.split("\n")) {
		const parts = line.split("\t");
		if (parts.length < 4) continue;
		rows.push({
			seq: parts[0],
			status: parts[1],
			crew: parts[2],
			text: parts[3],
			scope: parts[5] ?? "",
		});
	}
	return rows;
}

/**
 * The scope the board reads: the focus the captain set for this session, else
 * the project of the newest crew (the work last done), else `foreman` for the
 * harness itself. This mirrors `crew-todo.sh focus` line for line — the chrome
 * renders every 15s and must not fork a shell to find out, so the rule lives in
 * two places and `tests/crew-chrome.test.sh` pins them together on one fixture.
 */
function todoScope(): string {
	const session = process.env.FOREMAN_SESSION ?? "default";
	try {
		const focus = fs.readFileSync(path.join(HOME, `focus.${session}`), "utf8").trim();
		if (focus) return focus;
	} catch {
		// no explicit focus: fall through to the newest crew
	}
	let best = "";
	let bestAt = "";
	let ids: string[];
	try {
		ids = fs.readdirSync(TASKS);
	} catch {
		return "foreman";
	}
	for (const id of ids) {
		let at = "";
		try {
			at = (fs.readFileSync(path.join(TASKS, id, "status"), "utf8").match(/^at=(.*)$/m) ?? ["", ""])[1];
		} catch {
			/* a task with no status is not the newest anything */
		}
		if (bestAt === "" || at > bestAt) {
			bestAt = at;
			best = id;
		}
	}
	if (!best) return "foreman";
	try {
		const meta = fs.readFileSync(path.join(TASKS, best, "meta"), "utf8");
		const proj = (meta.match(/^project=(.*)$/m) ?? ["", ""])[1];
		if (proj) return path.basename(proj);
	} catch {
		/* a task without meta belongs to no project */
	}
	return "foreman";
}

function configFlag(key: string, fallback: boolean): boolean {
	try {
		const cfg = JSON.parse(fs.readFileSync(path.join(HOME, "config.json"), "utf8")) as Record<string, unknown>;
		return typeof cfg[key] === "boolean" ? (cfg[key] as boolean) : fallback;
	} catch {
		return fallback;
	}
}

function updateChrome(ctx: ExtensionContext) {
	if (!ctx.hasUI) return;
	const rows = readBoard();
	const allTodo = readTodo().filter((t) => t.status !== "dropped");
	// Scoped: one harness serves many projects, so the board reads the project in
	// focus. Queued work in another scope is counted, never silently dropped.
	const scope = todoScope();
	const todo = allTodo.filter((t) => (t.scope || "foreman") === scope);
	const done = todo.filter((t) => t.status === "done").length;
	const elsewhere = allTodo.filter((t) => t.status === "open" && (t.scope || "foreman") !== scope).length;

	if (rows.length === 0 && todo.length === 0 && elsewhere === 0) {
		ctx.ui.setStatus("foreman", undefined);
		ctx.ui.setWidget("foreman", undefined);
		return;
	}

	const theme = ctx.ui.theme;
	const fg = (color: "warning" | "error" | "accent" | "success" | "dim" | "muted", text: string): string =>
		typeof theme?.fg === "function" ? theme.fg(color, text) : text;

	const counts = new Map<string, number>();
	for (const row of rows) counts.set(row.state, (counts.get(row.state) ?? 0) + 1);
	// A blocked row whose note opens with `[key]` is a decision the captain owes:
	// that prefix is what the fold writes for an open keyed decision. Reading it
	// back avoids folding the event log a second time here, which is how the
	// chrome and `/crew` would otherwise start disagreeing.
	const decisions = rows.filter((r) => r.state === "blocked" && r.note.startsWith("[")).length;
	const otherBlocked = (counts.get("blocked") ?? 0) - decisions;
	const bits: string[] = [];
	if (decisions) bits.push(fg("warning", `${decisions} decision${decisions === 1 ? "" : "s"}`));
	if (otherBlocked) bits.push(fg("warning", `${otherBlocked} blocked`));
	for (const state of STATE_ORDER) {
		if (state === "blocked") continue;
		const n = counts.get(state);
		if (n) bits.push(fg(STATE_COLOR[state] ?? "muted", `${n} ${state}`));
	}
	// The todo list is a different axis from the crew, so it trails the line.
	if (todo.length || elsewhere) {
		const label = scope === "foreman" ? `todo ${done}/${todo.length}` : `todo ${done}/${todo.length} ${scope}`;
		const tail = elsewhere ? ` · +${elsewhere} open elsewhere` : "";
		bits.push(fg("muted", `${label}${tail}`));
	}
	ctx.ui.setStatus("foreman", bits.join(" · "));

	if (!configFlag("crewWidget", true)) {
		ctx.ui.setWidget("foreman", undefined);
		return;
	}
	const lines = rows
		.filter((r) => ACTIVE_STATES.has(r.state))
		.sort((a, b) => rankOf(a) - rankOf(b) || a.id.localeCompare(b.id))
		.slice(0, 6)
		.map((r) => {
			const state = fg(STATE_COLOR[r.state] ?? "muted", r.state.padEnd(8));
			const tail = `${ageOf(r.at).padEnd(4)} ${r.note}`.trimEnd();
			return `${r.id.padEnd(16)} ${state} ${fg("muted", tail)}`.trimEnd();
		});
	for (const item of todo.filter((t) => t.status !== "done").slice(0, Math.max(0, 6 - lines.length))) {
		const state = fg(item.status === "active" ? "accent" : "dim", item.status.padEnd(8));
		// `-` in the age column keeps a todo row aligned under the crew rows.
		lines.push(`${`#${item.seq}`.padEnd(16)} ${state} ${fg("muted", `${"-".padEnd(4)} ${item.text}`)}`.trimEnd());
	}
	ctx.ui.setWidget("foreman", lines.length ? lines : undefined);
}

// --- auto wake -------------------------------------------------------------

let watcher: ChildProcess | null = null;
let lavishChild: ChildProcess | null = null;
let stopping = false;
let backoffMs = 1000;
let chromeTimer: ReturnType<typeof setInterval> | null = null;

function wakeEnabled(): boolean {
	if (process.env.FOREMAN_WAKE === "0") return false;
	return configFlag("crewWake", true);
}

const WAKE_PROMPT = (n: string) => `crew wake: ${n} new (call crew_wake_drain)`;

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
	child.stdout?.resume();

	let settled = false;
	const restart = () => {
		if (settled) return;
		settled = true;
		watcher = null;
		if (stopping) return;
		// The queue is authoritative: whatever the watcher printed, the durable
		// rows are what the foreman acts on.
		const pending = countPending();
		if (pending > 0) {
			backoffMs = 1000;
			try {
				pi.sendUserMessage(WAKE_PROMPT(String(pending)), { deliverAs: "followUp" });
			} catch {
				/* no live session to deliver into */
			}
		}
		setTimeout(() => startWatcher(pi), backoffMs);
		backoffMs = Math.min(backoffMs * 2, 30_000);
	};

	child.on("error", restart);
	child.on("exit", restart);
}

/**
 * How many acked rows the queue has already given up: the sequence in
 * `.wake-acked`, or 0 when there is none. The file only exists after a first
 * drain, so a missing one means "nothing acked yet", never "nothing to do".
 */
function ackedSequence(): number {
	try {
		const raw = fs.readFileSync(path.join(HOME, ".wake-acked"), "utf8").trim();
		const n = Number.parseInt(raw || "0", 10);
		return Number.isFinite(n) ? n : 0;
	} catch {
		return 0;
	}
}

/**
 * Rows waiting for the foreman, mirroring `foreman_queue_pending` in
 * foreman-lib.sh. The two must agree: this number is the reason the foreman
 * takes a turn at all. They did not agree once, and it cost every wake on a
 * fresh home - both file reads sat in one try, so the ENOENT from a
 * not-yet-existing `.wake-acked` answered "no wakes". Nothing was announced, so
 * nothing was drained, so the ack file was never created, so no wake was ever
 * announced. `tests/crew-wake.test.sh` pins the two together on one fixture.
 */
function countPending(): number {
	const acked = ackedSequence();
	let raw: string;
	try {
		raw = fs.readFileSync(path.join(HOME, ".wake-queue"), "utf8");
	} catch {
		return 0;
	}
	let n = 0;
	for (const line of raw.split("\n")) {
		const seq = Number.parseInt((line.split("\t")[0] ?? "").trim(), 10);
		if (Number.isFinite(seq) && seq > acked) n++;
	}
	return n;
}

export default function foreman(pi: ExtensionAPI) {
	for (const tool of [
		crewTodo,
		crewSpawn,
		crewList,
		crewProjects,
		crewModels,
		crewConfig,
		crewPeek,
		crewRead,
		crewBusy,
		crewPrCheck,
		crewDecide,
		crewMerge,
		crewSend,
		crewStop,
		crewArchive,
		crewRecover,
		crewWakeDrain,
		crewDoctor,
		crewHandoff,
		lavishOpen,
		lavishPoll,
	]) {
		pi.registerTool(tool);
	}

	pi.registerCommand("crew", {
		description: "Show the crew board and todo list; /crew on|off toggles the widget",
		handler: async (args, ctx) => {
			const arg = (args ?? "").trim().toLowerCase();
			if (arg === "on" || arg === "off") {
				await run("crew-config.sh", ["set", "crewWidget", arg === "on" ? "true" : "false"], 500);
				updateChrome(ctx);
				ctx.ui.notify(`crew widget ${arg}`, "info");
				return;
			}
			ctx.ui.notify(await run("crew-list.sh", [], 6000), "info");
		},
	});

	pi.on("session_start", async (_event, ctx) => {
		stopping = false;
		updateChrome(ctx);
		// Reconcile orphaned crew before anything else reads the board, so a
		// session that starts after a crash sees the truth immediately.
		try {
			await run("crew-recover.sh", ["--queue"], 2000);
			await run("crew-todo.sh", ["sync"], 200);
		} catch {
			/* recovery is best effort; the board still renders */
		}
		// Say once, briefly, if the machine is missing something the session needs;
		// the doctor is silent when it is healthy.
		try {
			const report = await run("crew-doctor.sh", ["--quiet"], 2000);
			if (!report.startsWith("crew-doctor: ok")) ctx.ui.notify(report, "warning");
		} catch (error) {
			ctx.ui.notify(`crew-doctor: ${String(error)}`, "warning");
		}
		// The note the previous session left, if this is the next one: dated, ingested
		// once, never wiped. `read` is quiet when the note is old. (The runner turns
		// empty output into this sentinel, which is how "nothing to ingest" looks.)
		try {
			const note = await run("crew-handoff.sh", ["read"], 4000);
			if (note && note !== "(no output)") {
				pi.sendMessage(
					{ customType: "crew-handoff", content: note, display: false },
					{ triggerTurn: false },
				);
			}
		} catch {
			/* no note to ingest */
		}
		// The standing doc belongs to this installation and is gitignored, so a fresh
		// clone has only the tracked example. Seed it once, quietly, before the ritual
		// in AGENTS.md goes looking for it; `--seed` prints nothing on purpose.
		try {
			await run("crew-handoff.sh", ["standing", "--seed"], 200);
		} catch {
			/* a missing example is no reason to fail a session */
		}
		// Open the session oriented: one line of fleet and todo state, injected
		// into context without spending a turn or cluttering the transcript.
		try {
			const digest = (await run("crew-digest.sh", [], 500)).trim();
			if (digest) {
				pi.sendMessage(
					{ customType: "crew-digest", content: digest, display: false },
					{ triggerTurn: false },
				);
			}
		} catch {
			/* the board still renders */
		}
		updateChrome(ctx);
		startWatcher(pi);
		const pending = countPending();
		if (wakeEnabled() && pending > 0) {
			// A crash, a restart, or a session replacement left rows behind. Say so
			// once, briefly, without payload. `wakeEnabled` guards the announcement
			// as well as the watcher: FOREMAN_WAKE=0 means "do not interrupt me",
			// and rows still wait for the session that does want them.
			setTimeout(() => {
				try {
					pi.sendUserMessage(WAKE_PROMPT(String(pending)), { deliverAs: "followUp" });
				} catch {
					/* session went away */
				}
			}, 1500);
		}
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
		try {
			lavishChild?.kill("SIGTERM");
		} catch {
			/* already gone */
		}
		lavishChild = null;
	});
}
