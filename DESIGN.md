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
  extensions/foreman.ts  the model-facing tools, auto wake, and crew chrome
  bin/foreman            launcher: pi -e extensions/foreman.ts
  bin/*.sh               zero-token mechanics
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

This is why there are two documents and not one: `foreman/HANDOFF.md` is the
standing architecture/traps doc that must survive being read, while
`.foreman/handoff.md` is the dated, single-use narrative. One file would keep
trying to wipe the part that is still useful.

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

The widget shows at most six lines: a row per active crew member with its report
age, then open todo items in any slots left. Each state is coloured by its theme
role (`warning`, `error`, `accent`, `success`, `dim`), so the chrome reads
correctly in a light and a dark terminal, and a todo row carries `-` in the age
column so it stays aligned under the crew. The same role mapping colours the
status bits; the todo count stays muted. Ages follow the same rule as
`foreman_age_human` in `bin/foreman-lib.sh`, so the widget and `/crew` never
disagree about how old a report is.

Session start also injects one line of context — `crew digest: <fleet> ·
<decisions> · <wakes> · <todo counts>` — built by `crew-digest.sh` from the same
records. It is sent with `triggerTurn: false` and `display: false`: the model
opens oriented without spending a turn, and the captain's transcript stays
clean. Nothing here reads a pane or a report.

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
