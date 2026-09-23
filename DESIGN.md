# Foreman — design

Foreman is a captain → foreman → crew system for Pi + Herdr.

The captain talks to one agent (the **foreman**). The foreman turns requirements
into tasks and spins off **crew** members: separate `pi` processes in separate
Herdr panes, each in its own working directory. The captain can ask what is going
on, steer one crew member, merge its work, or stop it — always by talking to the
foreman.

It is deliberately not firstmate. The one problem it exists to solve is
**context cost over days of use**.

## The context contract

This is the whole design. Everything else is plumbing.

1. **Crew context is sealed.**
   A crew member's inputs are its brief file and whatever it reads itself.
   It never sees the captain's conversation, the foreman's conversation, or
   another crew member's work.

2. **Crew output never enters the foreman's context by default.**
   Crew write `.foreman/tasks/<id>/report.md`. The foreman gets a *pointer* and
   a one-line status. Reading a report is an explicit, deliberate act.

3. **No streaming, no polling in the model.**
   Nothing pipes live crew output into the foreman's transcript. State lives in
   files, refreshed by bash, read on demand.

4. **Every tool result is capped.**
   All foreman tools truncate to ~4 KB and say where the full text is. A crew
   member cannot flood the foreman by producing a long report.

5. **The durable memory is a board file, not the transcript.**
   `.foreman/BOARD.md` is regenerated from task state. Compaction cannot lose
   the fleet, because the fleet is not in the conversation. The same is true of
   decisions and wakes: they are files that survive a crash, a compaction, or a
   restart, not things the foreman is expected to remember.

6. **Fresh agent per task.**
   No crew member is kept alive for days accumulating turns. When it is done,
   its report is on disk and the process is disposable.

7. **Nothing is read "per ring".**
   There is no router that pulls a reference document into context on every
   event. Standing instructions are one short file; everything else is read once,
   deliberately, at the moment it is needed.

## Layout

```
foreman/
  AGENTS.md              standing instructions loaded into the foreman session
  HOUSE.md               who House is and how to enter house mode
  .pi/extensions/foreman.ts
                         the model-facing tools, auto wake, and crew chrome.
                         Project-local, so pi discovers it whenever it runs in
                         this directory; trust the project once per clone.
  .pi/skills/house/SKILL.md
                         the attending-physician framing for a house session
  bin/foreman            convenience: create the project dirs, then start pi
  bin/house              convenience: the same session in house mode
  bin/house-*.sh         the chart, rounds, prescribe and send mechanics
  bin/*.sh               zero-token mechanics
  bin/herdr-workspace-move.mjs  the one socket call `herdr workspace` lacks
  bin/crew-test.sh       runs the behaviour suite
  tests/<subject>.test.sh  one file per subject; fake herdr/gh/pi
  projects/              the captain's repositories (gitignored)
  worktrees/<id>         one git worktree per isolated crew member (gitignored)
  .foreman/              runtime state (gitignored)
    tasks/<id>/
      task.md            the requirement, verbatim
      brief.md           what the crew member is told
      report.md          what the crew member produced
      meta               pane= tab= workspace= cwd= project= worktree= branch=
                         pr= delivery= model= thinking= busy_gen= board=
      events             append-only, tab separated: <iso> <verb> <key> <note>
      status             derived cache: state= at= note=
      busy-state         semantic turn state: v1 gen= seq= state= source= ts=
      busy-gen           the incarnation token this crew's extension was armed with
      pi-ext.ts          the busy/report/Lavish extension this crew member runs with
      inbox/NNN.msg      steers from the foreman
      inbox/handled/     crew moves the file here to acknowledge
      inbox/.ring        re-ring ladder state
    config.json          crew settings
    .wake-queue          durable wake rows
    .wake-acked          the highest sequence the foreman has drained
    handoff.md           the dated note the previous session left
    .handoff-seen        the timestamp of the last handoff ingested
    BOARD.md             generated status board
    house/               House: the chart of ongoing areas (gitignored)
      areas/<slug>.md    one area: key: value header + an append-only dated log
      archived/<slug>.md charts retired out of the active rounds (never deleted)
      outbox/<slug>-<ts>.md  prescriptions that were written
```

## Events, decisions, and current state

`events` is the single source of truth for what a crew member reported. It is an
append-only log, not a mutable field, because the interesting question is never
"what was the last line" but "is anything still open".

```
<iso>	<verb>	<key>	<note>
```

Verbs a crew member writes: `working`, `progress`, `blocked`, `needs-decision`,
`review`, `done`, `failed`. The foreman writes `resolved`.

A crew member writes them through the `crew_report` tool its generated extension
provides, not through a hand-quoted shell command: the tool carries the call and
passes the foreman home explicitly, while `crew-report.sh` stays the single owner
of validation. A rejected call comes back to the crew as the tool's result.

`status` is a derived cache folded from `events` by one owner
(`foreman_fold_events`) so every reader agrees:

- the latest ordinary verb sets the current state;
- a `needs-decision` with a key stays open until a `resolved` for that exact key
  appears, and an open decision always shows as `blocked` — so a decision cannot
  be buried by a later unrelated append;
- an answer closes the decision at answer time, which is what lets the foreman
  reply with the answer in the same breath as closing the question.

## Wake

`bin/crew-watch.sh` is a one-shot bash watcher: it blocks, compares state, polls
pull requests, re-rings unacknowledged steers, sweeps lost endpoints, escalates
stalls, and exits with one line when there is news. It does not decide anything
durable — it appends to `.wake-queue`.

The wake queue is the crash-proof part. Rows are sequenced and appended before
anything is announced, and the foreman acknowledges them by sequence. If the
foreman's process dies, the foreman session is replaced, or the extension is
reloading, the rows are still there and are re-presented on the next session
start. The injected message carries no payload: it says how many rows are
waiting, and the foreman drains them.

The announcement is a **wake**, not context: it is sent as a user message, so it
spends a turn. That is the whole difference from the session digest, which is
injected with `triggerTurn: false` and costs nothing — a wake that did not spend
a turn would be a wake nobody reads, which is the failure this distinction
exists to prevent, and `tests/crew-wake.test.sh` pins both halves of it.

Acked means: every row at or before the sequence in `.wake-acked` is done. The
drain only *prints* the rows and the sequence to acknowledge; the ack is the
separate, explicit step that writes the cursor. That file does not exist before
the first ack, so "no ack file"
must read as "nothing acked yet" — **not** as "nothing to do". Getting that
backwards deadlocks the feature on a fresh home: nothing is announced, so nothing
is drained, so the ack file is never created. The extension keeps its own count
because it runs on the watcher's exit and at session start, and that count is
pinned to `foreman_queue_pending` by the same test.

## Busy state

Herdr can say whether a pane exists and whether an agent is registered, but not
whether that agent is mid-turn. Every crew member is therefore launched with a
generated extension that reports `agent_start` / `agent_settled` into a
generation-bound record. `crew_busy <id>` returns `busy | idle | dead | unknown`
with the source that produced it, so the foreman can tell "working" from "idle at
its prompt" from "process gone" — which is the difference between supervising and
guessing.

The extension passes the foreman home explicitly, because a crew member's shell
does not inherit `FOREMAN_HOME`. That home must be installed with
`foreman_use_home`, never by assigning `FOREMAN_HOME` alone: the derived paths are
cached when `foreman-lib.sh` is sourced, so a bare assignment leaves the writer
pointing at the ambient home. Getting this wrong costs no error — the write just
lands in the wrong place, and the crew reads as busy forever.

A crew that has produced no event for `FOREMAN_STALL_SECS` (default 1800) while
its task is unfinished and its pane is fine is a **stall**, whatever `crew_busy`
says: idle at the prompt with nothing reported, or mid-turn with no progress. The
watcher escalates it once per episode through a per-task `.stall-notified`
marker; any progress rewrites the status timestamp, clears the marker, and makes
a later stall news again. `0` disables the check.

## Steer reliability

A steer is a durable inbox record plus one constant doorbell line. Delivery is
proved by the crew moving the record into `handled/`, never by the Enter key.
Unacknowledged records are re-rung on a bounded ladder and then escalated into
the wake queue, so a swallowed doorbell becomes a visible fact rather than a
silent one.

## Delivery and the held instance

A crew member works on `crew/<id>` in its own worktree. When its change is ready
it pushes the branch, opens a pull request, and reports `review` with the URL.
The instance is deliberately held open past completion: the captain may want to
read the diff, comment, or push the crew further. Only a merge, a close, or an
explicit captain instruction releases it. Nothing is discarded on the way: the
branch always survives, and archiving a task never deletes commits.

The foreman merges with `crew_merge` **only when the captain has said to**. That
guard is the tool's whole reason for existing separately from `gh`.

**Breadth is the default.** The foreman exists to keep work out of its own
context, and an isolated worktree, branch and pane make that cheap: a second
independent piece costs another crew, not another turn of the foreman's
transcript. So a request that decomposes into independent pieces becomes one
crew per piece, running concurrently, rather than the foreman working through
them in sequence or doing them by hand; its context is the scarce resource, and
several pieces whose output it would otherwise have to read should be in flight
together. The one thing that cannot be parallelised is the file. Two crews
editing the same file cannot merge cleanly — the second branch is a conflicted
merge, and the truth lives split across two branches until someone reconciles
it. Pieces that touch the same file are therefore sequenced: one crew lands its
change and the next is cut from the result. Only genuinely disjoint pieces run
at once.

## Recovery

A foreman session can die with crew still running, and a Herdr pane can be
destroyed out from under a live task. `bin/crew-recover.sh` reconciles both:

- a pane that is gone while its task is unfinished becomes `lost` and queues a
  wake, rather than reading as `working` forever;
- a crew member whose endpoint was destroyed is relaunched in its **existing**
  worktree with a progress note appended to its instructions, so its commits and
  uncommitted work survive and the task keeps its identity;
- crew still running from a previous session are simply adopted, because their
  records are on disk and their panes are still there.

Recovery runs at session start and never destroys anything.

## Handoff

The durable memory is the board and the todo list; the *narrative* memory is one
dated note. `.foreman/handoff.md` is written at the end of a session through the
`crew_handoff` tool and is deliberately kept: nothing is wiped.

What bounds its relevance is its date. The note carries a machine-readable
`<!-- handoff at=... -->` marker, and `read` prints it only when it is newer than
`.handoff-seen`, the timestamp of the last note a session ingested. So the note
from the session that just ended is delivered once at the next start; a note the
next session never replaces falls behind the marker and is skipped rather than
replayed into every future session. `show` always reads it back on demand.

This is why there are two documents and not one: `HANDOFF.md` is the standing
doc that must survive being read, while `.foreman/handoff.md` is the dated,
single-use narrative. One file would keep trying to wipe the part that is still
useful.

The standing doc belongs to the **installation**, not to this repo, so it is
gitignored: what a crew operation learns about a particular project is not
something a clone of the harness should inherit. The tracked
`HANDOFF.example.md` is its shape; the first session in a clone seeds
`HANDOFF.md` from it (`crew-handoff.sh standing`). The harness's own sharp edges
and traps are in this file, where they are versioned with the code that has to
obey them.

## Lavish review boards

`lavish-axi` turns an HTML artifact into a board the captain can annotate, and
long-polls for the feedback. Its own contract forbids a fire-and-forget poll: the
poll must be a tracked background job that resumes the agent that started it.

Both the foreman and every crew member get `lavish_open` and `lavish_poll`, where
the poll is a tracked child of that session — exactly the shape the tool
requires, and the reason a blocking poll never holds a turn. A crew member
building a visual deliverable uses a board by default and reports
`needs-decision [key=board-url]` with the URL when the captain owes a review.

Poll output is not forwarded whole. `lavish-axi` appends a full DOM serialization
of the artifact, which is the largest part of the response and is not the
feedback, so both tools replace the `dom_snapshot:` line with a marker and cap
the remainder at the same ~4 KB ceiling every other result obeys. The live round
trip is covered by an opt-in test rather than the hermetic suite, because it needs
a real server.

## How a crew member appears

Herdr has no parent/child relationship for panes or agents: `agent list` carries
`parent_pane_id`, `parent_agent_id` and `depth`, but nothing can set them and no
CLI or socket method exposes one. So the hierarchy is built from the two things
Herdr does model:

- **A workspace per crew member.** The launch runs
  `herdr workspace create --cwd <worktree> --label "└ <id>" --no-focus` and
  renames the seeded tab to `crew-<id>`. The child glyph in the label is the
  whole visual claim.
- **Position.** The workspace is then moved directly after the foreman's own,
  past any sibling already in that block, so a crew's workspaces read as a
  contiguous child block. `workspace.move` exists only on Herdr's control
  socket, which is the entire reason `bin/herdr-workspace-move.mjs` exists: one
  narrowly scoped request, nothing else.

The relationship itself is ours, not Herdr's. Each task records `workspace` and
`parent_workspace`, and the position is computed from those records — never from
label patterns, which would be a second source of truth for the same fact.

It is presentation only, and it always degrades. If the parent cannot be
identified, the mover is missing, or Herdr refuses the move, the launch warns on
stderr and the crew stays where Herdr put it — running. A Herdr that cannot
create a workspace at all gets the crew a plain tab in the foreman's workspace.

A relaunch adopts the workspace the task already owns rather than creating a
second one. And a task whose record predates this — it names the foreman's own
workspace and has no parent — owns nothing: closing it closes its tab, never the
captain's workspace.

## Teardown

A crew member starts things: a dev server, a file watcher, a test runner, an
emulator. When it finishes, they keep running. That is not a tidiness problem —
the process holds a port and its CPU for the rest of the session, and once the
task is archived nothing on the machine remembers it belonged to a crew at all.

So a `review` or a `done` report is **refused** while anything this crew started
is still up, and the refusal lists it and says how to stop it (`crew_cleanup`,
the crew-side tool). `blocked`, `needs-decision` and `failed` are never gated: a
crew must always be able to report an obstacle or ask for a decision. Stopping a
crew sweeps too, so a crew that dies without reporting leaves nothing behind —
except on `--interrupt`, which is a pause rather than a stop.

Finding those processes is the whole difficulty, and it is solved by
**attribution, not by guessing at names**. The obvious signals all fail. The
shell that started a background job exits and the job is reparented to PID 1, so
its process tree link is gone; its environment cannot be read back afterwards
(`ps -E` reports nothing for a reparented process on macOS — checked); its
process group is the transient one of the tool call; and
`herdr pane process-info` only ever lists the pane's own foreground group (also
checked: a reparented `sleep` was invisible to it).

What does survive is the **working directory**. `lsof -d cwd` reports the cwd of
every process on the machine in about 60ms, so a process whose cwd is inside the
crew's worktree is attributable to that crew, and one that is not, is not. The
anchor is the worktree when the task has one, else the crew's cwd. That second
case is the risk: a `--no-isolate` crew works inside the captain's own checkout,
where the captain's own dev server also lives. So the launch records the pids
already in the directory (`processes-at-launch`) and those are excluded — first
launch only, because re-snapshotting on a relaunch would launder exactly the
strays the next teardown has to find.

Protection is by identity rather than by pattern: the crew's agent, everything
still descended from it (MCP servers, a tool call in flight), its ancestors, and
two kinds of exception. `lavish-axi`, whose own contract is to stay up while the
captain annotates a board and to stop itself when the last session ends; and a
machine-wide daemon the crew merely triggered — the `adb` server owns a fixed
port other tools are already talking to, so stopping it is collateral damage.
Ancestors and descendants are computed separately on purpose — expanding one
from the other would protect the whole multiplexer's worth of sibling processes.

Two rules keep the probe honest about itself. It reads the process table and the
cwd scan with its working directory *outside* the anchor, because its own `lsof`
and `awk` would otherwise carry the crew's cwd and the run that is looking for
strays would report one — which is not hypothetical: it refused a real crew's
`done` report before the fix. And a pid the process table cannot name is never
blamed: it is either the scan itself (born after the table was read) or
something that has already exited.

When the probe itself is broken (no `lsof`, no anchor to attribute to) it exits
3 and every caller fails **open**. A teardown that guessed would be worse than
one that did nothing, and a probe that cannot see must not hold a crew's work
hostage.

Archiving is the other half of teardown. A retired task must not leave its
terminal behind: a pane whose crew has finished or merged is indistinguishable
from one that is still working, so `crew-archive` closes the home the foreman
created for the crew — its workspace, else its tab — before the record moves. It
has to be before, because `foreman_close_home` reads the workspace and tab from
the task's own `meta`. The close is best effort: Herdr down, the socket gone, or
the endpoint already dead is reported in the archive line and the record is moved
regardless, so the record always survives. `--keep-home` opts out, for a task
whose terminal the captain still wants.

## Scopes

One harness serves many projects, and the todo list is where that would
otherwise go wrong: the harness's own backlog would read as the project's, and a
project you opened would show the previous one's finished work as its own.

So every item carries a **scope** — a project name, or `foreman` for the harness
itself — and the board reads one scope at a time. The scope in focus is set
explicitly with `focus`, else derived from the newest crew's project (placing a
crew for a project *is* working on that project, which is why `crew-launch` sets
it there), else `foreman`. Focus is per session, so two sessions can watch two
projects.

Nothing is hidden silently: a list reports queued work in other scopes as an
`open elsewhere: foreman 1 open` line, and the digest, summary and status line
all name the scope they are counting. `--all` shows every scope, grouped under
its own heading.

The scope is written down when the item is added, so a later focus change cannot
file old history under a new project. A row that predates scopes takes its own
from the crew it is linked to at the next `sync`; an explicit scope is never
rewritten, because that is the captain's word. Linking an item to a crew
(`start`) settles its scope to that crew's project, since project work cannot be
done by a crew standing somewhere else.

The derivation lives in `crew-todo.sh` for the tools and again in the extension
for the chrome — the chrome renders every 15 seconds and must not fork a shell to
find out which project it is looking at. `tests/crew-chrome.test.sh` asserts both
resolve the same scope on one fixture, so the two cannot drift apart.

## House

Foreman runs the crew. House is its sibling: it keeps a chart of the captain's
**areas** and writes prescriptions. It is entered from the same repo (`bin/house`,
or `FOREMAN_MODE=house pi`) and reuses the same extension, but it is a *mode*, not
a second foreman — the crew machinery stays underneath and house does not use it.

**Why it does nothing.** A know-it-all registrar is only useful if it is
incapable of acting. The moment House can spawn, merge or run, it becomes a
second, worse foreman with its own notion of what is in flight, and the captain
has two places to look for the same truth. So the tools it is given cannot spawn,
merge, archive, edit or execute; the skill states the same discipline; and the
only write House performs on the world is a *prompt* — a prescription — which the
captain pastes, or tells House to deliver. The prescription is self-contained on
purpose: a fresh chat has none of this conversation, so the chart has to carry
enough to rebuild the context. The send path reuses `crew-send.sh`'s durable
inbox record and doorbell rather than inventing a second delivery mechanism, so a
sent prescription is exactly as reliable as a crew steer — and it is opt-in, one
area at a time, because sending is the one act that is hard to take back.

**Why areas are not projects.** The todo list and the crew are about work that
*finishes*: an item is opened, a crew member runs in a worktree, a pull request
lands, the task is archived. An area is a thread that *stays open* — a repo, a
project that lives in its own chat, a deck, a craft like branding. It has no
task id, no worktree and often no repository at all, and its truth cannot be
derived from git. Forcing it into the todo list would give it a lifecycle it does
not have and would file threads the captain thinks about under a project scope
that does not exist. So areas live in their own chart, under
`$FOREMAN_HOME/house/`, plain text and greppable, and the only thing shared with
the crew machinery is the inbox a prescription is delivered through.

**The chart.** One file per area, `house/areas/<slug>.md`: `key: value` header
lines (`slug`, `title`, `kind`, `where`, `bind`, `opened`, `updated`, `status`,
`next`) and then an append-only dated log. Plain text because it must be
editable by hand and readable by `sed`; append-only because the interesting
question is what changed, not only what is current. `kind` drives delivery —
`repo` means a branch and a pull request, everything else means a report — which
is the one place an area's shape changes what House prescribes. `updated` is
bumped by every note and every diagnosis, and `rounds` marks an area that has not
moved or has no `next`, so a thread cannot rot silently. Archiving retires a
chart from the active rounds but never deletes it; a thread that comes back keeps
its history.

**House is additive.** No existing script was changed to make room for it. The
scripts are new files, the state is a new directory, the tools are new
registrations, and the session-start rounds are injected only when
`FOREMAN_MODE=house`, so foreman's digest is untroubled.

## The chrome

The status line and the crew widget are rendered from the task records on a
local timer and after every tool call. They make no model call and no Herdr call,
so fleet visibility costs nothing.

The chrome is ordered worst-first. The line leads with the decisions the captain
owes — `blocked` rows whose note opens with `[key]`, the prefix the fold itself
writes — then the crew states in the same order the widget uses (`blocked`,
`failed`, `lost`, `review`, `working`, `queued`), and trails with the todo count,
which is a different axis. Reading the `[key]` prefix back instead of folding the
event log a second time is deliberate: a second fold is how two views of one
board start to disagree.

The widget shows at most six lines, one row per crew. A crew row carries the
number and title of the todo item linked back to it, the crew's own state as the
single status column, the report age, and the crew's last note as a short
description of what it is actually doing. An item no active crew is linked to
keeps its own row with its todo state. Folding the item into the crew's row is
what keeps one piece of work from wearing two words: `working` and `active` are
the same moment seen from the crew and from the board, and the row says it once.
A crew settled at its prompt is shown as `idle`, read from the same
`busy-state`/`busy-gen` records `crew_busy` reads; an unknown record falls back
to the report state, and the status line's counts stay report states. Each state
is coloured by its theme role (`warning`, `error`, `accent`, `success`, `dim`),
so the chrome reads correctly in a light and a dark terminal, and the same role
mapping colours the status bits while the todo count stays muted. Every column
has a fixed share and is clipped, so a row cannot wrap; the crew id stays whole
as the description's prefix, because it is how a crew is addressed. Ages follow
the same rule as `foreman_age_human` in `bin/foreman-lib.sh`, so the widget and
`/crew` never disagree about how old a report is. `/crew`'s argument completions
read the same grammar table its handler dispatches, so the palette and the
command cannot drift.

Session start also injects one line of context — `crew digest: <fleet> ·
<decisions> · <wakes> · <todo counts>` — built by `crew-digest.sh` from the same
records. It is sent with `triggerTurn: false` and `display: false`: the model
opens oriented without spending a turn, and the captain's transcript stays
clean. Nothing here reads a pane or a report.

### Calm mode

Calm mode (`crewCalm`, `/crew calm on|off`) hides the foreman's own tool calls —
the call line, its arguments and its output — and the assistant's thinking, so
the captain reads only the responses. It is a display preference, not a context
change: the tools still run and their results still reach the model. The status
line, the widget, the wake message and the assistant responses are deliberately
untouched.

Thinking has two paths, and calm quiets both by dropping thinking blocks before
pi lays a message out. Pi draws every assistant message through the exported
`AssistantMessageComponent`, so the extension patches that prototype's
`updateContent` once: while calm is on it hands the original a shallow copy whose
content omits `thinking` blocks. That covers visible thinking (Markdown) and the
collapsed `Text` label `hideThinkingBlock` draws with one rule, which a label
change alone cannot: pi wraps the label in the theme colour, so `Text` still sees
a non-empty string and leaves a blank line. The stored message, the model
context and export rendering are untouched. The decision is read at render time
through a shared patch object, so toggling calm redraws thinking already on
screen, and the wrapper restores `lastMessage` to the real message so turning
calm off brings thinking back on the same row. A reload only refreshes the
decision, never double-wraps. This mirrors the `collapsed-thinking` adapter in
firstmate's Pi Calm, which does the same against the exported component.

Tool calls ride on the other rendering hook pi exposes: `renderCall`,
`renderResult` and `renderShell` on a tool definition. There is no global
"hide tool calls" switch, so an extension can quiet only tools it defines.
Calm wraps the extension's own tools directly, and re-registers pi's built-in
tools (`create*ToolDefinition` returns the whole definition — schema, execute
and renderers — so only the drawing changes). A row's renderers consult the live
`calmEnabled` flag at render time, so toggling redraws the calls already on
screen. The extension's own rows use `renderShell: "self"` and draw the padded,
backgrounded block themselves: that is what lets a quiet row render *zero*
lines, where the default shell would still leave a blank spacer behind an empty
box. A hidden built-in keeps its own shell, so it leaves one blank spacer line
rather than nothing — the mechanism pi exposes draws a tool's *content*, not the
row that holds it.

## Tests

The suite (`bin/crew-test.sh`, `tests/`) is the regression check for the
zero-token mechanics. Its shape follows from the design:

- **Real scripts, isolated state.** Every test runs the production script with
  `FOREMAN_HOME`, `FOREMAN_PROJECTS` and `FOREMAN_WORKTREES` pointed at a
  throwaway directory, so a test can never read or write the captain's fleet.
- **Stub only the outside world.** `herdr` is an external server, and `gh`,
  `pi` and `lavish-axi` are external tools, so `tests/lib.sh` installs fakes for
  them first on `PATH`. The stub Herdr is per-pane files, which lets a test
  destroy a pane while keeping the tab — the churn recovery has to tell apart.
  The exceptions are the live files: `tests/crew-lavish-live.test.sh`
  (`FOREMAN_LAVISH_E2E=1`, a private `lavish-axi` server and browser-shaped
  feedback), `tests/crew-e2e-live.test.sh` (`FOREMAN_E2E=1`, a real Herdr pane, a
  real pi crew, a real steer) and `tests/crew-github-live.test.sh` (also
  `FOREMAN_E2E=1`, plus `FOREMAN_E2E_REPO=<owner>/<name>`: it creates a private
  throwaway repository and refuses to run if that name already exists, so it can
  never touch a real one). All skip by default so the suite stays hermetic. The
  live wire file exists because stubs cannot see the class of bug where every
  piece is individually correct and the wiring between them is not — it found
  exactly one (`foreman_use_home`, see the busy state above) the first time it ran.
- **One file, one subject.** A test file stops at the first failed assertion and
  the runner reports one PASS/FAIL per file with its output, so a failure names
  the contract that broke rather than one assertion out of hundreds.
- **The suite is part of the contract.** A change to a mechanic is expected to
  come with its test, and `AGENTS.md` tells the foreman to run the suite after
  touching `bin/`.

## What is deliberately absent

- No second mates, no remote hosts, no quota routing, no PR pipeline validator.
- No budget accounting.
- No skill router and no per-event reference loading.

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

- **A crew session must never carry the captain's extension.** A project that is
  itself a checkout of this harness ships `.pi/extensions/foreman.ts` in every
  worktree, so a self-hosted crew had pi discover that extension beside the one
  the launcher names with `-e`. Both register `lavish_open` and `lavish_poll`, pi
  refuses the second, and the crew lost the tools it was given while the file meant
  to provide them sat inert. Crew launches therefore pass `-ne` (discovery off;
  explicit `-e` paths still load) and set `FOREMAN_CREW=<id>`; the extension
  returns early when that marker is set, which covers every pi the crew starts
  afterwards because the marker is inherited. `tests/crew-foreman-ext.test.sh`
  pins both halves — including that the captain still gets everything, since a
  guard that makes the extension inert for everyone would be a worse bug.
  The consequence for users: a crew never loads a project's own pi extensions.
