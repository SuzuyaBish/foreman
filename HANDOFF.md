# Handoff

The standing doc: the architecture as built, what the suite covers, the sharp
edges, and the traps already paid for. It is kept and edited, never consumed.

The other kind of handoff is the dated note one session leaves for the next
(`crew_handoff`, or `bin/crew-handoff.sh write "..."`). That one is delivered
once, by date, from the state directory. See DESIGN, "Handoff", for why there are
two documents and not one.

`README.md` says what this is. `DESIGN.md` is the shape and the context contract.
`AGENTS.md` is what the foreman itself reads.

## How to start

```sh
cd <this directory> && pi
```

Pi discovers `.pi/extensions/foreman.ts` because it is project-local, so the crew
tools, the chrome and the digest all load from this directory. Approve Pi's
project-trust prompt once per clone. `bin/foreman` does the same after creating
`projects/` and `worktrees/`.

The first thing typed is addressed to the foreman. Projects live in `projects/`;
state lives in `.foreman/`; both are gitignored.

To check a change to the mechanics:

```sh
bin/crew-test.sh
```

## What the suite covers

One subject file per mechanic, run against stubbed `herdr`, `gh` and `pi` in an
isolated home. Four files are worth knowing about because they test more than
mechanics:

- `tests/crew-e2e-live.test.sh` (`FOREMAN_E2E=1`) runs the whole wire with nothing
  stubbed: it cuts a real worktree, opens a real Herdr pane, launches a real pi
  crew, waits for it to commit and report, reads the report back through
  `crew_read`, steers it with a real inbox record, waits for the ack, then stops
  the pane and archives the task, leaving no tab, workspace or process behind.
- `tests/crew-github-live.test.sh` (`FOREMAN_E2E=1 FOREMAN_E2E_REPO=<owner>/<name>`)
  creates a private throwaway repository, has a real crew push a branch and open a
  real pull request, merges it with `crew_merge --delete-branch`, and checks that
  the merge landed on the default branch and the remote branch is gone. It refuses
  a repository that already exists, so it can never touch a real one.
- `tests/crew-lavish-live.test.sh` (`FOREMAN_LAVISH_E2E=1`) drives a real Lavish
  server and posts browser-shaped feedback.
- `tests/crew-chrome.test.sh` drives the real extension under a fake UI and a fake
  theme, so the worst-first order, the colour tiers, the ages, the `-` alignment
  of todo rows, the six-line budget and the `/crew off` toggle are asserted rather
  than eyeballed.

The gated files exist because a stubbed suite cannot see the bug where every piece
is individually correct and the wiring is not. Two of the traps below were found
that way.

Not covered: a real browser driving Lavish's own UI, and the rendered TUI itself —
the lines the chrome draws are asserted exactly, the drawing is not.

## Sharp edges

- **A crew's teardown is enforced, not requested.** `review` and `done` are
  refused while anything the crew started is still running under its working
  directory, and stopping a crew sweeps the rest. Attribution is by cwd, because a
  background job is orphaned to PID 1 and keeps no readable link to the shell that
  started it — see DESIGN, "Teardown", for why every other signal fails. The probe
  fails **open**: no `lsof`, or no anchor to attribute to, means the gate stands
  aside rather than holding work hostage.
- **A failed `gh pr merge` is just a blocker.** It appends `blocked` with gh's own
  reason, on one line, and exits nonzero. There is no automatic retry and no
  conflict resolution.
- **Only `gh`/GitHub** is supported for delivery.
- **Stall detection is age-based.** A crew that produces no event for
  `FOREMAN_STALL_SECS` (default 30m) is escalated once per episode. A genuinely
  long turn with no progress report will trip it; the wake is informational, so the
  cost of a false positive is one line, not an action.
- **Worktrees are cut from `HEAD`** of the project checkout; uncommitted work in
  that checkout is not carried into the crew's worktree. `crew-worktree.sh add`
  warns with a count of what will be left behind, and spawn surfaces it, but it is
  still a warning — nothing stops a crew being launched from a dirty source.
- **Lavish's `poll` is bounded, not raw.** `lavish-axi poll` appends a full DOM
  serialization of the artifact — up to tens of KB. Both the extension and the
  crew-side tool replace the `dom_snapshot:` line and cap what they forward.

## Traps already found (do not re-introduce)

- `printf '--- %s'` breaks on macOS bash 3.2: it reads `---` as options.
- Rewriting this repo's history: `git filter-branch --tree-filter` runs the filter
  with `eval` in the shell that owns the commit loop, so an `exit` inside it
  (including `exit 0`) ends the whole rewrite *silently* after one commit, leaving
  the ref untouched and no error printed. End the filter with `:` and never `exit`.
  Check the count of filter invocations, not the exit status.
- `awk` has no `continue` outside a loop; use `next`.
- A `mkdir`-based lock removed with `rm -f` is never released. Always `rmdir`.
- Herdr `pane read --lines N` returns **empty** when N is below the viewport
  height. Always ask for 200 and trim locally.
- Herdr `pane get`'s `cwd` is frozen at creation; only `foreground_cwd` moves.
- `crew-spawn` briefs must carry `FOREMAN_HOME=` explicitly, because the crew
  member's shell does not inherit it.
- The derived paths (`FOREMAN_TASKS`, `FOREMAN_BOARD`, `FOREMAN_CONFIG`) are cached
  when `foreman-lib.sh` is sourced. A script that takes a home as an argument and
  then does `FOREMAN_HOME=$arg` keeps writing to the **ambient** home. Use
  `foreman_use_home`. This broke every `agent_start`/`agent_settled` write from a
  crew whose foreman home was not the repo default: the busy record stayed at its
  spawn value and the crew read as permanently busy. The unit test only ever passed
  the ambient home, so nothing caught it until the live wire file did.
- The foreman extension is project-local: `.pi/extensions/foreman.ts`, which pi
  discovers whenever it runs in this directory. Approve pi's project-trust prompt
  once per clone — project extensions do not load before the project is trusted.
  Never name it with `-e` as well: a project extension plus an explicit one loads
  twice, giving two wake watchers and duplicated tools. Do not `pi install` it:
  installed globally would start its auto-wake watcher in every session, in every
  project.
- Herdr has **no** parent/child relationship for panes or agents. `herdr agent
  list` returns `parent_pane_id`, `parent_agent_id` and `depth`, but nothing can set
  them: no CLI flag, no socket method, and firstmate does not either. A crew reads
  as a subordinate by being its own workspace, labelled `└ <id>` and moved after
  the foreman's — see DESIGN, "How a crew member appears".
- `workspace.move` exists only on Herdr's control socket; `herdr workspace` has no
  move subcommand. `bin/herdr-workspace-move.mjs` is the transport, and
  `FOREMAN_HERDR_MOVER` overrides it, which is how the tests watch the request
  without opening a socket.
- `crew-stop --close` must close the recorded **tab** even when the pane is already
  gone, or tabs leak.
- A stray process cannot be found by environment, process group or pane: the shell
  that started it exits, the job is reparented to PID 1, and `ps -E` reports
  **nothing** for a reparented process on macOS while `herdr pane process-info`
  only lists the pane's own foreground group. `crew-processes.sh` therefore
  attributes by **cwd** via `lsof -d cwd`, and its two test seams
  (`FOREMAN_PROC_PS_FILE`, `FOREMAN_PROC_LSOF_FILE`) exist so a test can be exact
  instead of lucky.
- The anchor is the worktree when there is one, else the crew's cwd, and
  `processes-at-launch` excludes what predated the crew. That file is written on
  the **first** launch only: re-snapshotting on a relaunch would file the strays
  from the run that just died as "already there" and nothing would ever stop them.
- Ancestors and descendants of the agent are computed as two separate sets in
  `proc_protected`. Expanding ancestors and then descendants protects every sibling
  in the session, which is the entire multiplexer's worth of processes — the
  teardown silently stops finding anything.
- The process-name exemption list is short and deliberate: `pi`, `agent-device mcp`,
  `lavish-axi` (whose own contract is to stay up while the captain annotates and to
  stop itself afterwards), and the `adb` `fork-server` — a machine-wide daemon on a
  fixed port that other tools are already talking to, which a crew starts only as a
  side effect of using it. Add to it only with that same kind of reason.
- The probe must not report itself, and it did. `crew-processes.sh` runs from
  inside the crew's directory, so its own `lsof` and `awk` had the anchor as their
  cwd; `lsof` also lists itself, so a scan taken before the process table named it
  returned "one stray", which refused a real crew's `done` report. Two fixes, both
  kept: the tables are read with the cwd moved to `/`, and a pid the table cannot
  name is never reported. `tests/crew-processes.test.sh` runs the probe from inside
  the anchor with nothing running and requires silence.
- `fm_stray` (tests/lib.sh) writes its pid file **outside** the anchor on purpose:
  a stray that changed the worktree would make it dirty, and archiving refuses a
  dirty worktree.
- The teardown gate fails **open** (exit 3) when it cannot tell, and `--interrupt`
  never sweeps: a pause is not a stop, and the agent may still be using what it
  started.
- The todo scope rule lives in **two owners on purpose**: `crew-todo.sh` for the
  tools and the digest, and `todoScope()` in the extension for the chrome, which
  renders every 15s and must not fork a shell to find out which project it is
  looking at. `tests/crew-chrome.test.sh` asserts both resolve the same scope on one
  fixture; if you change the rule, change both and keep that test.
- Scoping must never *hide* queued work: `list` prints the `open elsewhere:` line
  and `summary` the `also <scope> N open` tail for exactly that reason. Dropping
  them would make the board lie by omission.
- The todo scope field is appended as **field 6** (`<seq> <status> <crew> <text>
  <note> <scope>`), so every awk that rewrites a row keeps it automatically and rows
  written before scopes existed stay parseable. `sync` is the one place that
  backfills a missing scope, from the crew the row is linked to.
- The wake count has **two owners that must agree**: `foreman_queue_pending` in
  `foreman-lib.sh` and `countPending()` in the extension (which cannot fork a shell
  to ask, since it runs on the watcher's exit). `tests/crew-wake.test.sh` pins them
  on one fixture. They disagreed once, expensively: the extension read `.wake-queue`
  and `.wake-acked` inside **one** `try`, and the ack file only exists after a first
  drain, so on a fresh home the ENOENT answered "no wakes". Nothing was announced,
  nothing was drained, the file was never created, and the foreman could sit idle
  while a crew finished and opened a pull request. A missing ack file means "nothing
  acked yet" (0) — never "no wakes".
- A wake must spend a turn (`sendUserMessage`, i.e. a user message) and the session
  digest must not (`sendMessage` with `triggerTurn: false`). Both halves are asserted
  in `tests/crew-wake.test.sh`; a wake delivered as quiet context is a wake nobody
  reads.
- The extension a whole session runs is the code loaded at its start. Editing
  `.pi/extensions/foreman.ts` changes nothing for a session already open: restart pi
  (or `--continue`) for a fix to take effect, and until then the durable wake rows
  simply wait.
- Type-checking the extension needs a *sibling* `node_modules`: the global `tsc`
  rejects `baseUrl` and any non-relative `paths`, so copy `.pi/extensions/foreman.ts`
  into a temp dir next to a symlink to
  `$HOME/.pi/agent/install/releases/<v>/node_modules`, add `{"type":"module"}` and a
  tsconfig with `types: ["node"]`, and run `tsc` there.
  `node --experimental-strip-types` runs the file directly for the chrome test, so a
  type error only shows up in this check.
