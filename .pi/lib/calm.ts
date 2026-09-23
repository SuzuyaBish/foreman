/**
 * calm - hide the foreman's own tool calls and assistant thinking.
 *
 * Calm is the captain's transcript quiet mode: while it is on, the tool rows and
 * assistant thinking collapse to nothing, and his own replies draw normally.
 * While it is off, everything draws exactly as pi draws it.
 *
 * Vendored from firstmate's Pi Calm and adapted to the foreman. Original:
 *   https://github.com/kunchenguid/firstmate
 *     .pi/extensions/lib/fm-calm-assistant-layout.ts   (the layout patch)
 *     .pi/extensions/lib/fm-calm-visibility.ts         (the visibility policy)
 * firstmate is MIT licensed, and that notice is reproduced here because it is a
 * condition of taking the code:
 *
 *   MIT License
 *   Copyright (c) 2026 Kun Chen
 *
 *   Permission is hereby granted, free of charge, to any person obtaining a copy
 *   of this software and associated documentation files (the "Software"), to deal
 *   in the Software without restriction, including without limitation the rights
 *   to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 *   copies of the Software, and to permit persons to whom the Software is
 *   furnished to do so, subject to the following conditions:
 *
 *   The above copyright notice and this permission notice shall be included in all
 *   copies or substantial portions of the Software.
 *
 *   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 *   IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 *   FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 *   AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 *   LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 *   OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 *   SOFTWARE.
 *
 * What we kept from firstmate, close to verbatim: the one seam that hides
 * assistant thinking - a patch on pi's exported `AssistantMessageComponent.
 * updateContent` that hands the layout a shallow presentation copy with its
 * thinking blocks removed, while keeping the real message so `invalidate()`
 * restores it; the stable `Symbol.for` registry that makes the patch idempotent
 * across reloads; the per-adapter diagnostic install; and the central
 * `calmHides(rowClass)` policy every row reads.
 *
 * What we changed: our gate is the live calm flag read at render time, not
 * firstmate's hidden-thinking label. firstmate also requires
 * `hiddenThinkingLabel === ""` and `hideThinkingBlock` before it collapses; we
 * collapse whenever calm is on, which drops visible thinking and the collapsed
 * label with one rule and lets a toggle redraw rows already on screen. The row
 * classes are named for our rows, and the tool rows keep the extension's own
 * zero-line wrapper rather than firstmate's `Box`/`Container` reconstruction:
 * we mirror pi's `Box(1, 1, bgFn)` frame in a small local component so a hidden
 * built-in row reaches pi's zero-line `renderShell: "self"` path, without the
 * `@earendil-works/pi-tui` import the test harness does not stub.
 * Dropped on purpose: firstmate's animated working ship, its mid-turn
 * "working note" collapse, its operational-user row adapter, and its `/export`
 * stock-render guard. Each is named in the task report.
 */
// A namespace import so the built-in tool factories and the exported assistant
// component can be read defensively: a pi that does not export them (or a test
// stub with only `defineTool`) simply has `undefined` here, where named imports
// would refuse to load the module.
import * as PiCodingAgent from "@earendil-works/pi-coding-agent";

/** The transcript rows calm knows about. Only the hidden ones are ever asked about. */
export type CalmRowClass =
	| "genuine-user-prompt"
	| "genuine-agent-response"
	| "assistant-thinking"
	| "assistant-tool-call"
	| "tool-result";

// firstmate keeps an allowlist of visible classes. Ours is the same shape so the
// policy reads the same, and it names what calm must never touch: the captain's
// own prompt and the genuine reply that ends a turn.
const CALM_VISIBLE_CLASSES = new Set<CalmRowClass>(["genuine-user-prompt", "genuine-agent-response"]);

let calm = false;

/** The live choice. Set at load, on `/crew calm`, and at session start. */
export function setCalm(active: boolean): void {
	calm = active;
}

export function calmIsActive(): boolean {
	return calm;
}

/**
 * Whether a row of this class should draw nothing. Read when the row renders,
 * never when the tool ran, so a toggle redraws rows already on screen. This is
 * the one place the decision lives; the tool wrappers and the assistant layout
 * both come here.
 */
export function calmHides(rowClass: CalmRowClass): boolean {
	return calm && !CALM_VISIBLE_CLASSES.has(rowClass);
}

/**
 * One presentation adapter, installed defensively. The assistant layout probes
 * an exact pi API; if a future pi removes it, this logs and skips only that
 * adapter instead of taking the whole foreman down. firstmate's shape.
 */
export function installCalmAdapter(name: string, install: () => void): void {
	try {
		install();
	} catch (error) {
		const reason = error instanceof Error ? error.message : String(error);
		console.error(`calm: ${name} adapter unavailable, skipping. ${reason}`);
	}
}

/**
 * Pi draws every assistant message - the streaming one and the settled one -
 * through the exported `AssistantMessageComponent`, and that component is
 * reachable, so one prototype patch can drop thinking content from a shallow
 * presentation copy before pi lays it out. That covers both of pi's thinking
 * paths at once: visible thinking (Markdown) and the collapsed label
 * `hideThinkingBlock` draws, which a label change alone cannot remove (pi wraps
 * the label in the theme colour, so `Text` still sees a non-empty string and
 * draws a blank line).
 *
 * The stored message, the model context and `/export` data are never touched;
 * only the copy handed to the layout is filtered. The decision is read at render
 * time, so a toggle redraws thinking already on screen, and restoring
 * `lastMessage` to the real message means turning calm off brings it back. The
 * wrapper is installed once per process; a reload only refreshes its decision,
 * so it can never be double-wrapped with a stale flag.
 */
const CALM_ASSISTANT_LAYOUT = Symbol.for("foreman:calm-assistant-layout");

interface CalmAssistantLayoutPatch {
	hidesThinking: () => boolean;
}

export function installCalmAssistantLayout(): void {
	const registry = globalThis as Record<symbol, CalmAssistantLayoutPatch | undefined>;
	const hidesThinking = (): boolean => calmHides("assistant-thinking");
	const installed = registry[CALM_ASSISTANT_LAYOUT];
	if (installed) {
		installed.hidesThinking = hidesThinking;
		return;
	}
	const component = (PiCodingAgent as unknown as Record<string, any>).AssistantMessageComponent;
	const original = component?.prototype?.updateContent;
	if (typeof component !== "function" || typeof original !== "function") {
		throw new Error("calm requires pi's AssistantMessageComponent.updateContent");
	}
	const patch: CalmAssistantLayoutPatch = { hidesThinking };
	component.prototype.updateContent = function (message: any, ...rest: any[]) {
		const state = this as { lastMessage?: unknown };
		const thinking = Array.isArray(message?.content)
			? message.content.filter((block: any) => block.type === "thinking")
			: [];
		const presentation = patch.hidesThinking() && thinking.length
			? { ...message, content: message.content.filter((block: any) => block.type !== "thinking") }
			: message;
		original.call(this, presentation, ...rest);
		// Re-render against the real message, so `invalidate()` (and a calm toggle)
		// re-evaluates the rule instead of a copy that already lost its thinking.
		if (presentation !== message) state.lastMessage = message;
	};
	registry[CALM_ASSISTANT_LAYOUT] = patch;
}

interface CalmComponent {
	render(width: number): string[];
	invalidate?(): void;
}

/**
 * A component whose lines vanish while calm mode is on. The decision is made
 * when the row renders, not when the tool ran, so toggling calm redraws the
 * calls already on screen instead of only the ones that come next.
 */
export function calmWrap(inner: CalmComponent, rowClass: CalmRowClass): CalmComponent {
	return {
		invalidate() {
			inner.invalidate?.();
		},
		render(width: number) {
			return calmHides(rowClass) ? [] : inner.render(width);
		},
	};
}

/** A double-width cell, so a path with CJK or emoji still pads to the window. */
function calmWide(code: number): boolean {
	return (
		code >= 0x1100 &&
		(code <= 0x115f ||
			code === 0x2329 ||
			code === 0x232a ||
			(code >= 0x2e80 && code <= 0xa4cf) ||
			(code >= 0xac00 && code <= 0xd7a3) ||
			(code >= 0xf900 && code <= 0xfaff) ||
			(code >= 0xfe30 && code <= 0xfe4f) ||
			(code >= 0xff00 && code <= 0xff60) ||
			(code >= 0xffe0 && code <= 0xffe6) ||
			(code >= 0x1f300 && code <= 0x1faff) ||
			(code >= 0x20000 && code <= 0x3fffd))
	);
}

/**
 * Visible width, ignoring the escapes the theme and pi's hyperlinks add. Both
 * kinds appear in a built-in tool row: SGR for the background and OSC 8 for the
 * file link, and a length that counts the escape bytes pads the background short.
 */
function calmVisible(text: string): number {
	const clean = text
		.replace(/\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)/g, "")
		.replace(/\x1b\[[0-9;?]*[ -/]*[@-~]/g, "")
		.replace(/\x1b[@-Z\\-_]/g, "");
	let width = 0;
	for (const char of clean) {
		const code = char.codePointAt(0) ?? 0;
		if (code === 0x200d || code === 0xfe0f) continue;
		width += calmWide(code) ? 2 : 1;
	}
	return width;
}

/** Split a plain line by code point when it is wider than the row. */
function wrapPlain(line: string, width: number): string[] {
	if (width <= 0) return [line];
	const chars = Array.from(line.replace(/\t/g, "   "));
	if (chars.length <= width) return [chars.join("")];
	const out: string[] = [];
	for (let i = 0; i < chars.length; i += width) out.push(chars.slice(i, i + width).join(""));
	return out;
}

function calmRole(isPartial: boolean, isError: boolean): "toolPendingBg" | "toolErrorBg" | "toolSuccessBg" {
	if (isPartial) return "toolPendingBg";
	return isError ? "toolErrorBg" : "toolSuccessBg";
}

/**
 * The padded, backgrounded block the default shell would draw for a tool. We
 * draw it ourselves because calm rows use `renderShell: "self"`, which is what
 * lets a quiet row render zero lines rather than an empty box above a blank
 * spacer - the difference between hiding a call and leaving a hole where it was.
 */
function calmBlock(
	theme: any,
	role: "toolPendingBg" | "toolErrorBg" | "toolSuccessBg",
	lines: string[],
	top: boolean,
	bottom: boolean,
	rowClass: CalmRowClass,
): CalmComponent {
	return {
		invalidate() {},
		render(width: number) {
			if (calmHides(rowClass)) return [];
			const bg = (text: string) => (typeof theme?.bg === "function" ? theme.bg(role, text) : text);
			const inner = Math.max(1, width - 2);
			const out: string[] = [];
			if (top) out.push(bg(" ".repeat(width)));
			for (const raw of lines.length ? lines : [""]) {
				for (const piece of wrapPlain(raw, inner)) {
					const line = ` ${piece}`;
					out.push(bg(line + " ".repeat(Math.max(0, width - calmVisible(line)))));
				}
			}
			if (bottom) out.push(bg(" ".repeat(width)));
			return out;
		},
	};
}

/**
 * Give one of the foreman's own tools calm-aware rendering. Calm off draws the
 * same block it always did; calm on draws nothing at all.
 */
export function calmTool(tool: any): any {
	return {
		...tool,
		renderShell: "self",
		renderCall(args: any, theme: any, ctx: any) {
			const lines = [theme.fg("toolTitle", theme.bold(tool.name))];
			const json = args === undefined ? "" : (JSON.stringify(args, null, 2) ?? "");
			if (json) lines.push("", ...json.split("\n"));
			return calmBlock(theme, calmRole(ctx.isPartial, ctx.isError), lines, true, false, "assistant-tool-call");
		},
		renderResult(result: any, _options: any, theme: any, ctx: any) {
			const text = (result.content ?? [])
				.map((c: any) => (c.type === "text" ? c.text : ""))
				.join("\n");
			return calmBlock(theme, calmRole(ctx.isPartial, ctx.isError), text ? text.split("\n") : [], false, true, "tool-result");
		},
	};
}

/**
 * The padded, backgrounded frame pi draws a tool row into, redrawn by us so the
 * whole row can take zero lines while calm is on. Pi's default shell is a
 * `Box(1, 1, bgFn)` preceded by a `Spacer(1)` that its `ToolExecutionComponent`
 * adds once in its constructor. That spacer is unconditional on the default
 * path; only the `renderShell: "self"` path drops it when the frame is empty.
 * We mirror the Box here - one padded blank row, content indented one column,
 * one padded blank row - because pi's self path leaves the framing to us and we
 * cannot import `@earendil-works/pi-tui` in the test harness.
 */
interface CalmShell extends CalmComponent {
	setBg(fn: (text: string) => string): void;
	clear(): void;
	add(child: CalmComponent): void;
}

function calmShell(): CalmShell {
	let children: CalmComponent[] = [];
	let bg: (text: string) => string = (text) => text;
	return {
		setBg(fn) {
			bg = fn;
		},
		clear() {
			children = [];
		},
		add(child) {
			children.push(child);
		},
		invalidate() {
			for (const child of children) child.invalidate?.();
		},
		render(width: number) {
			if (!children.length) return [];
			const inner = Math.max(1, width - 2);
			const lines: string[] = [];
			for (const child of children) {
				for (const line of child.render(inner)) lines.push(` ${line}`);
			}
			if (!lines.length) return [];
			const paint = (line: string) => bg(line + " ".repeat(Math.max(0, width - calmVisible(line))));
			return [paint(""), ...lines.map(paint), paint("")];
		},
	};
}

/**
 * Wrap a built-in tool's own renderers. A definition that already frames itself
 * (`renderShell: "self"`, as `edit` does) is hidden whole and keeps its own
 * shell. The rest use pi's default frame, and that frame is the bug: a hidden
 * row still draws the `Spacer(1)` pi put in front of it, one blank line per tool
 * call, stacking down a turn. Giving those definitions a self shell - and
 * redrawing pi's Box ourselves - routes a hidden row into pi's zero-line path.
 */
function calmBuiltin(def: any): any {
	if (!def.renderCall && !def.renderResult) return def;
	// The built-in renderers reuse `context.lastComponent` and call methods on it
	// for cheap streaming updates. We hand them the wrapper, not their own Text,
	// so they must build fresh - pass `lastComponent: undefined` through.
	const fresh = (ctx: any) => ({ ...ctx, lastComponent: undefined });
	// A definition that frames itself already reaches pi's zero-line path, and a
	// one-slot definition has no shared frame to build - both keep the plain
	// wrapper, which still hides the slot it wraps.
	if (def.renderShell === "self" || !def.renderCall || !def.renderResult) {
		return {
			...def,
			renderCall: def.renderCall
				? (args: any, theme: any, ctx: any) => calmWrap(def.renderCall(args, theme, fresh(ctx)), "assistant-tool-call")
				: undefined,
			renderResult: def.renderResult
				? (result: any, options: any, theme: any, ctx: any) =>
						calmWrap(def.renderResult(result, options, theme, fresh(ctx)), "tool-result")
				: undefined,
		};
	}
	// One frame per on-screen row, shared by both render slots so the call and
	// its result draw inside one box the way pi's default shell does. Pi re-runs
	// both slots on every update, so the call slot resets the frame each pass.
	const shells = new WeakMap<object, CalmShell>();
	const shellFor = (ctx: any): CalmShell => {
		const key = (ctx?.state ?? ctx) as object;
		let shell = shells.get(key);
		if (!shell) {
			shell = calmShell();
			shells.set(key, shell);
		}
		return shell;
	};
	const empty: CalmComponent = { render: () => [] };
	const paintWith = (theme: any, ctx: any) => {
		const role = calmRole(ctx?.isPartial, ctx?.isError);
		return (text: string) => (typeof theme?.bg === "function" ? theme.bg(role, text) : text);
	};
	return {
		...def,
		renderShell: "self",
		renderCall: def.renderCall
			? (args: any, theme: any, ctx: any) => {
					if (calmHides("assistant-tool-call")) return empty;
					const shell = shellFor(ctx);
					shell.setBg(paintWith(theme, ctx));
					shell.clear();
					shell.add(def.renderCall(args, theme, fresh(ctx)));
					return shell;
				}
			: undefined,
		renderResult: def.renderResult
			? (result: any, options: any, theme: any, ctx: any) => {
					if (calmHides("tool-result")) return empty;
					const shell = shellFor(ctx);
					shell.setBg(paintWith(theme, ctx));
					shell.add(def.renderResult(result, options, theme, fresh(ctx)));
					return empty;
				}
			: undefined,
	};
}

/**
 * Re-register pi's built-in tools with calm-aware renderers. They are not ours,
 * but `create*ToolDefinition` hands back the whole definition - schema, execute
 * and renderers - so the override changes only how the call is drawn. A pi that
 * does not expose the factories leaves the built-ins untouched; the extension's
 * own tools still hide.
 *
 * firstmate registers its built-in overrides only while calm is on at load, to
 * avoid contesting pi's single first-registration-wins slot with another
 * extension. Our extension is the only owner of the built-in names in this
 * session and our wrapper delegates `execute` unchanged, so we register always
 * and let the row decide at render time - which is what lets one test render a
 * built-in row both ways.
 */
export function registerCalmBuiltins(pi: any): void {
	const sdk = PiCodingAgent as unknown as Record<string, any>;
	for (const name of ["read", "bash", "edit", "write", "find", "grep", "ls"]) {
		const make = sdk[`create${name[0].toUpperCase()}${name.slice(1)}ToolDefinition`];
		if (typeof make !== "function") continue;
		try {
			pi.registerTool(calmBuiltin(make(process.cwd())));
		} catch {
			// a definition we cannot shape is left as pi built it
		}
	}
}
