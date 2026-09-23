# foreman

Talk to one agent. It runs the crew. Your context stays flat.

Foreman is a small captain → foreman → crew harness for **Pi** (harness) and
**Herdr** (multiplexer). You are the captain: you talk to one foreman, and it
runs a crew of parallel coding agents. Each crew member is a separate `pi`
process in its own Herdr pane, in its own git worktree. Crew work in isolated
contexts and write reports to disk. The foreman is given pointers and one-line
statuses, never transcripts.

Read [DESIGN.md](DESIGN.md) for the context contract. It is the point.

## Contents

- [The loop](#the-loop)
- [Who is who](#who-is-who)
- [Requirements](#requirements)
- [Run](#run)
- [Projects](#projects)
- [Crew settings](#crew-settings)
- [Delivery](#delivery)
- [Talking to a crew](#talking-to-a-crew)
- [How a crew member appears](#how-a-crew-member-appears)
- [The chrome](#the-chrome)
- [The todo list](#the-todo-list)
- [Decisions](#decisions)
- [Merges](#merges)
- [Recovery](#recovery)
- [Handoff](#handoff)
- [Busy state](#busy-state)
- [Teardown](#teardown)
- [Lavish review boards](#lavish-review-boards)
- [House](#house)
- [What you can ask the foreman for](#what-you-can-ask-the-foreman-for)
- [Pieces](#pieces)
- [Tests](#tests)
- [License](#license)

## The loop

You have one conversation, and it looks like this:

```
> clone the repos I work on into projects/ for me, using gh

> I need three things looked at: the flaky auth test, the unused CSS, and the
  missing rate limit on /api/upload. Run the crew on deepseek-v4-pro.

> status?

  auth-flake    working  4m   reproduced: session cookie not refreshed
  css-audit     done     2m   report ready
  rate-limit    blocked  1m   needs decision: 429 vs 503

> read the css one
> tell rate-limit to use 429 with Retry-After
> stop the auth one, I'll take it myself
> merge css-audit
```

Behind it:

1. Each request becomes a **todo item**, scoped to its project.
2. Each item becomes a **crew member**: a fresh `pi`, its own git worktree, its
   own workspace in Herdr's sidebar. The foreman keeps working — it is never
   blocked waiting inside a crew's transcript.
3. Crew members *write reports to disk*. The one-line state you see is read from
   those records; the foreman gets a pointer and a status, never the transcript.
4. When one needs a decision, or finishes, the foreman is **woken** and tells
   you. Nothing polls you, and nothing is lost if a session dies.
5. Work is delivered as a pull request. The foreman merges **only when you say
   so**.
6. Before you stop, it writes a dated note for the next session. Tomorrow, ask
   "status?" and the plan is already on the board.

## Who is who

| Word | Means |
|---|---|
| **captain** | you. You decide; the foreman asks rather than guesses |
| **foreman** | the one agent you talk to. Owns the plan, the crew and the merges |
| **crew member** | one `pi` process on one task, in its own worktree and its own Herdr workspace |
| **task** / **crew id** | the short name a crew member is addressed by, e.g. `parser-fix` |
| **project** | a repository under `projects/`; also the *scope* a todo item belongs to |
| **report** | what a crew member writes when it has news: `working`, `blocked`, `needs-decision`, `review`, `done`, `failed`, `lost` |
| **steer** | a message to a running crew, through a durable inbox plus a doorbell |
| **wake** | how the foreman learns a crew changed state, without you polling |

## Requirements

- `pi` on PATH
- `herdr` on PATH, server running (`herdr status`)
- `jq`
- `git`

Pi and Herdr are separate projects; this repo assumes both are already
installed. `gh` and `lavish-axi` are optional — without `gh` there is no
pull-request delivery, without `lavish-axi` there are no review boards.

`bin/crew-doctor.sh` checks all of this and runs at every session start; it is
silent unless something is wrong. It says which checks are hard requirements and
which merely cost you a feature.

A crew member is a real agent session, so a fleet costs real model tokens. The
settings below are where you keep that reasonable: run the crew on a cheaper
model than yourself, or on `report` delivery when you want the thinking and not
the pull request.

## Run

```sh
cd foreman   # or whatever you cloned it as
pi
```

That is the whole thing. Pi loads `.pi/extensions/foreman.ts` because it is
project-local, and `AGENTS.md` as standing instructions. The first time in a
fresh clone, approve Pi's project-trust prompt: project extensions are not loaded
before the project is trusted, and approving is once per clone. `bin/foreman`
does the same thing after creating `projects/` and `worktrees/`; it does not name
the extension with `-e`, because doing that *as well* would load it twice.

The first thing you type is a message to your foreman. You never run the other
commands below by hand unless you want to.

The chrome and the crew tools belong to this directory. A pi session started
everywhere else — even after a reload — has no widget, no status line, no
`crew_*` tools and no digest. That is deliberate: installing the extension
globally would start its auto-wake watcher in every session, in every project.

Every session starts the same way. The foreman reads `HANDOFF.md` — your
installation's standing notes, seeded on the first session from
`HANDOFF.example.md`, and gitignored, because the harness's own sharp edges and
traps live in `DESIGN.md` with the code that has to obey them — and then
`crew_todo`, the durable plan. It is also handed a one-line `crew digest:` and,
once, the previous session's dated handoff note. Both are orientation, not the
plan.

## Projects

Put repositories in `projects/`. The foreman works on them there, and by default
gives each crew member its own git worktree under `worktrees/<id>` on a
`crew/<id>` branch — so two crew can touch one repo without colliding, and
nothing is discarded when the pane closes.

`projects/` is gitignored, so cloned repositories never enter this repo's
history.

Crew sessions are started with extension discovery off, so a project's own pi
extensions never load inside a crew: a crew gets exactly the tools it was
generated with, and can never inherit the captain's.

A worktree is cut from the project's `HEAD`, so uncommitted work in that
checkout is not carried into it. Spawning warns when that would happen, naming
the count of modified/staged and untracked files, and goes ahead anyway.

## Crew settings

Told conversationally ("run the crew on X, thinking high"), persisted in
`.foreman/config.json`:

| Setting | Default | Meaning |
|---|---|---|
| `crewModel` | pi's default | model every crew member runs on |
| `crewThinking` | pi's default | `low`…`max` |
| `crewDelivery` | `auto` | `pr`, `local`, or `report` |
| `crewIsolate` | `true` | worktree per crew member for project work |
| `crewApprove` | `true` | pass `--approve`, so pi never shows a trust dialog |
| `trustPaths` | `true` | pre-register worktree paths in pi's trust file |
| `crewWake` | `true` | wake the foreman when crew state changes |
| `crewWidget` | `true` | the crew list above the editor |
| `crewCalm` | `false` | hide the foreman's own tool calls; show only responses |

Settings are per-foreman-home, never committed, and settable by hand:
`bin/crew-config.sh set crewModel <model>`.

## Delivery

Work in a project is delivered as a pull request. A crew member commits on its
`crew/<id>` branch, pushes, opens the PR, and finishes in state **`review`**.
Its pane, worktree and branch all stay in place — the instance is kept open
until the captain merges it. The watcher polls the PR and settles the task to
`done` on merge, and the auto wake tells the foreman.

A research task delivers a report instead (`done`, no PR); a project without a
forge remote delivers locally. `crewDelivery` sets which is normal, and
`crew_archive` refuses a task whose PR is still open.

Because the instance is held, follow-up work on that item goes back to it: a
sharpened requirement, a correction, or a second pass is a `crew_send` to the
same crew, which still holds its context and its worktree, rather than a fresh
crew that starts blind. A genuinely different piece of work is a new item and a
new crew. When that crew's pane is gone, `crew_recover` brings the same task
back in its existing worktree instead of a respawn.

## Talking to a crew

You do not have to talk to a crew member directly — ask the foreman and it
steers. "tell rate-limit to use 429 with Retry-After" appends to that crew's
inbox and rings its doorbell; the crew reads it at its next turn and
acknowledges, so a steer survives a crew that is mid-command, and a session that
restarts. `crew_send` does the same thing from the foreman's side.

For a look without interrupting anything:

- `crew_peek <id> [n]` — the last lines of that crew's pane, bounded.
- `crew_read <id>` — the report it has written so far.
- `crew_busy <id>` — `busy`, `idle`, `dead`, or `unknown`, and what said so.

A crew member is a full pi session in a real pane, so you can also open its
workspace and type at it yourself — the report on disk is still what the foreman
reads, so ask it to write one if you change the plan.

## How a crew member appears

Each crew member gets its own Herdr **workspace**, labelled `└ <id>` and placed
directly after the foreman's own workspace, with its seeded tab renamed
`crew-<id>`. Herdr has no parent/child relationship between agents, so that
glyph and that position *are* the hierarchy: the sidebar reads

```
1 foreman
2 └ parser-fix
3 └ sheet-render
4 design-system
```

It is presentation only, so it can never cost you a crew: if Herdr refuses the
move the crew still runs, just left where Herdr created it. `crew_stop --close`
retires the crew's own workspace and never yours.

## The chrome

While a session runs, a status line and a widget sit above the editor. Both are
rendered straight from the task records — no Herdr call, no model call, no
tokens. The line leads with what the captain owes and trails with the durable
queue; the widget is worst-first, shows how long ago each crew last reported, and
colours each state with its theme role:

```
1 decision · 1 failed · 1 review · 2 working · todo 3/12 notes-app

c-authque        blocked  4m   [api] retry policy: fail fast or back off?
c-ingest         failed   30m  no such host: registry.internal
c-docs           review   1m   PR #12 waiting to merge
c-parser         working  7m   splitting the grammar
#11              open     -    finish the widget
```

The widget shows at most six lines: one per active crew member, then open todo
items in the slots that are left. `/crew` prints the whole board; `/crew on|off`
toggles the widget. `/crew calm on|off` toggles **calm mode**, which hides the
foreman's own tool calls — the call line, its arguments and its output — so the
captain reads only the responses. It never touches the responses, the status
line, the widget or the wake message. The choice lives in `crewCalm` and
survives a restart; `/crew calm` with no argument flips it.

At session start the foreman is also handed one injected line, for example:

```
crew digest: 3 crew (1 working, 1 blocked, 1 review) · 1 decision open · todo notes-app: 12 items (7 open, 0 active, 5 done)
```

It is read from the same records, injected into context without triggering a
turn and without cluttering the transcript, so a fresh session opens oriented.

## The todo list

`crew_todo` is the durable project queue, and it outlives every session. Ask
for ten things and ten items exist — five done and five open is a fact on disk,
not something the foreman has to remember. Items link to the crew member working
them, and settle themselves: crew `done` closes the item, crew `failed` or
`lost` reopens it. A new session reads the list and knows exactly where the work
stands.

```
#    STATUS       CREW         ITEM
1    done         auth-flake   fix the flaky auth test
2    active/review css-audit   audit unused CSS
3    open         -            rate limit /api/upload
```

Items are scoped by project, because one harness serves many projects: the board
reads the project you are working on — the newest crew's project, or the one you
set — so the queue in front of you is never another project's, and the harness's
own backlog lives under `foreman` instead of crowding it out.

```
#    STATUS       CREW         ITEM
2    active/review css-audit   audit unused CSS
3    open         -            rate limit /api/upload

  open elsewhere: foreman 1 open (crew-todo.sh list --all)
```

Queued work in another scope is counted rather than hidden, `show: all` groups
every scope under its own heading, and adding an item without a project files it
in the scope in focus. Placing a crew for a project puts that project in focus,
so the board follows the work without you saying so twice.

The board is yours. Ask for something and it goes straight on. The foreman never
puts anything there on its own initiative: an idea it notices while working
becomes a **proposal** instead, filed apart with a one-line reason and shown to
you as a table.

```
#    PROPOSED                             REASON
4    add a metrics tab                    we may need numbers
5    prefetch the index                   it is slow
```

A proposal is a suggestion, not your work, so it never appears among your items
— not on the board and not in the widget. The status line counts proposals
separately and only when there are some (`… · todo 3/12 · 2 proposed`), and
`crew_todo proposals` is where the whole table is read. Approving one promotes
it to the board and keeps the number you already saw; declining it drops it.
Both are yours to call: `approve 4` keeps it, `drop 4` lets it go.

## Decisions

A crew member that hits a choice it should not make for itself asks for it
instead, through its `crew_report` tool:

```
crew_report(verb="needs-decision", note="429 or 503?", key="status-code")
```

It stays open until someone answers, and a later unrelated report cannot bury
it. `crew_decide <id> <key> <answer>` closes it and delivers the answer to the
crew's inbox in one act. Open decisions are listed on the board.

## Merges

Crew deliver a pull request and stop in `review`; their pane, worktree and
branch are held until it lands. The foreman merges with `crew_merge` **only when
you have said to** — merging is your decision, and the tool exists separately
from `gh` for that reason. Branches are kept unless you ask for them to go.

## Recovery

A foreman session can die with crew still running, and a Herdr pane can be
destroyed out from under live work. Session start reconciles both. `crew_recover`
reports which tasks have no endpoint, and `crew_recover <id>` puts a fresh agent
back into that task's **existing** worktree with a progress note — commits and
uncommitted work survive, and the task keeps its identity. The same path reuses
a settled crew: a task that reached `done` and lost its pane comes back under
its own id, never as a respawn.

Wakes are durable too: rows are appended before anything is announced and
acknowledged by sequence, so a crash, a restart, or a session replacement cannot
lose them. A new session re-presents whatever is still unacknowledged.

## Handoff

Memory across sessions is a note, not the transcript. Before a session ends the
foreman writes a short dated handoff with `crew_handoff`: what is in flight, what
was decided, what is waiting. The next session is handed it once, at start —
nothing is wiped, and a note the next session never replaces is skipped rather
than replayed forever. `crew_handoff` with no text reads the current note back on
demand.

That note is separate from `HANDOFF.md`, your installation's standing doc:
gitignored, kept and edited, never consumed.

## Busy state

Herdr knows whether a pane exists, not whether the agent in it is mid-turn.
Every crew member is launched with a generated extension that reports its own
turn lifecycle, so `crew_busy` answers `busy`, `idle`, `dead`, or `unknown` with
the source that produced it — the difference between supervising and guessing.

The watcher also escalates a **stall**: an unfinished crew that has produced no
event for `FOREMAN_STALL_SECS` (default `1800`) while its pane is still fine.
Idle at its prompt with nothing reported, or mid-turn with no progress — either
way it raises one wake per episode, so a crew that quietly stopped cannot sit
silent. Progress clears the episode; `0` disables the check.

## Teardown

A crew member starts things — a dev server, a file watcher, a test runner, an
emulator — and when it finishes they keep running, holding ports and CPU long
after the task is done. So a `review` or `done` report is **refused** while
anything the crew started is still up, and the refusal names it:

```
cannot report review yet: this crew still has work running.

41234	npm run dev
41235	node ./node_modules/.bin/vite

Stop it first - crew_cleanup(action="kill"), or:
  .../bin/crew-processes.sh kill parser-fix
```

The crew has a `crew_cleanup` tool for exactly this (`check`, then `kill`), and
stopping a crew sweeps whatever it left — so a crew that dies without reporting
still leaves nothing behind. `blocked`, `needs-decision` and `failed` are never
gated: a crew must always be able to report an obstacle or ask a question.

Finding those processes is not by name. The shell that started a background job
exits, and the job is reparented to PID 1, so it keeps no readable link to the
crew. The one thing that survives is its **working directory**, so anything
running inside the crew's worktree is its own — and with `--no-isolate`, where
that directory is your own checkout, whatever was already running there when the
crew launched is excluded. A Lavish board is deliberately left up for you to
annotate.

## Lavish review boards

`lavish-axi` turns an HTML artifact into a board you can annotate in the browser.
Both the foreman and every crew member get `lavish_open` and `lavish_poll`, where
the poll is a tracked background child of that session — the shape `lavish-axi`
requires, and the reason a long poll never holds a turn. Crew are told to use a
board by default for visual work.

Poll output ends with a full DOM serialization of the artifact, so both tools
trim that line and cap the rest at ~4 KB before it reaches a model. The live
path is opt-in tested: `FOREMAN_LAVISH_E2E=1 bin/crew-test.sh tests/crew-lavish-live.test.sh`
starts a private `lavish-axi` server and runs the round trip.

## House

House is a notebook of everything you are working on, kept by an assistant that
only ever writes prompts — it never does the work itself. (The physician beside
the foreman: it keeps the chart and writes the prescription; the crew operates.)

### What an area is

An area is any ongoing thread you keep in your head: a repo, a project that lives
in its own chat, a deck or a talk, a craft like branding. It is **not** a git
project and **not** a crew task — those start and finish, while an area is a
thread that stays open. You name your areas; house remembers them. Each one is
written to a plain text file you can open and edit yourself,
`$FOREMAN_HOME/house/areas/<slug>.md`.

### The two lines you keep current

Two lines on each area are the ones that matter:

- `status` — where it stands, in one line.
- `next` — what happens next, in one line.

Everything else in the file is a dated log of what changed. Keeping those two
lines honest is the whole job of the chart.

### The loop, step by step

House only ever does four things, and never any of them on its own:

- **Rounds** — read every area and show one line each. Anything with no next
  step, or not touched in a while, is flagged.
- **Diagnose** — for one area, work out the next step and write it down.
- **Prescribe** — turn the chart into a *prescription*: a short prompt you can
  paste straight into a fresh chat to do that next step.
- **Send** — if the area names a session to reach, hand the prescription there.
  Only when you say so.

Nothing is automatic. House never scans your machine and never notices a change
by itself. If a `status` or `next` changed, somebody wrote it: you, by saying it,
or the foreman, by charting what happened.

### What house will not do

House never spawns, merges, archives, edits or runs anything, in any area. It
writes prompts and hands them over; the session you paste them into does the
work.

### Using house day to day

Enter house mode from the same checkout:

```sh
bin/house           # or: FOREMAN_MODE=house pi
```

It opens on the rounds, so it starts knowing your areas. Then you just talk to
it:

```
> rounds
  atlas           repo   2d   status: parser merged, flags half done  next: add --dry-run
  lighthouse      deck   1d   status: out for review                  next: tighten the ask
  expo-talk       deck   9d   status: slides started                  next: -  [no next]

> track the lighthouse as a deck
> the deck is out for review, next is to tighten the ask
> what's next for expo-talk?
  ... diagnoses the chart, sets the step, and prints a prompt ready to paste
> send that to expo-talk
```

A chart is a few `key: value` lines and an append-only dated log:

```
  slug: atlas
  title: Atlas
  kind: repo
  where: ~/code/atlas
  bind: atlas-crew
  opened: 2026-06-01
  updated: 2026-06-03
  status: parser merged; CLI flags half done
  next: add --dry-run and a test for it

  ## Log

  - 2026-06-03 - closed the parser PR
```

### House commands

Each is a small script, and each takes `--help`. Normally you say what you want
and house picks the tool.

| Command | Verbs | Does |
|---|---|---|
| `bin/house-area.sh` | `add` `list` `show` `archive` | the chart: open an area, see them all, read one, retire one |
| `bin/house-note.sh` | `--status` `--next` | append a dated note and bump `updated` |
| `bin/house-next.sh` | `--clear` | set or clear the diagnosed next step |
| `bin/house-rounds.sh` | `--all` `--stale-days` `--digest` | one line per area; mark stale or no-next |
| `bin/house-prescribe.sh` | `--copy` `--stdout` `--context` | write the paste-ready prompt to the outbox |
| `bin/house-send.sh` | `--yes` | dry-run, or deliver the latest prescription to `bind` |
| `bin/house-demo.sh` | `seed` `clear` | install or remove a scratch demo cast for exercising house |

A prescription lands in `.foreman/house/outbox/<slug>-<ts>.md`. `--copy` also puts
it on the clipboard (`pbcopy`, `xclip` or `wl-copy`, degrading with a message),
and `house-send.sh --yes` delivers it through the same durable inbox a crew steer
uses, when the area's `bind` names a crew task. `house-demo.sh` is a scratch
fixture, not your real work.

## What you can ask the foreman for

These are the foreman's hands. You never call one yourself: you say what you
want ("put that on the list", "stop the auth one") and it picks the tool. In
house mode the same session answers with the `house_*` tools further down.

| Tool | What it does |
|---|---|
| `crew_todo` | the durable list: add your items, propose and approve suggestions, list, start, settle, focus a scope |
| `crew_projects` / `crew_models` | what there is to work on / run on |
| `crew_spawn <id>` | start a crew member on a task |
| `crew_list` | the board: crew states and the todo list |
| `crew_peek <id>` / `crew_read <id>` | that crew's pane / the report it wrote |
| `crew_busy <id>` | working, idle, dead, or unknown — and what said so |
| `crew_send <id> <text>` | steer a running crew |
| `crew_pr_check <id>` | poll a delivered pull request |
| `crew_decide <id> <key> <answer>` | answer the decision a crew is waiting on |
| `crew_merge <id>` | merge a delivered PR, on your say-so only |
| `crew_stop <id>` | interrupt, exit, or close a crew |
| `crew_archive <id>` | retire a finished task; refuses while its PR is open |
| `crew_recover [id]` | find tasks with no endpoint, or relaunch one in place |
| `crew_cleanup <id>` | what that crew still has running, and the teardown |
| `crew_config` | show or set the settings above |
| `crew_handoff` | read or write the dated note for the next session |
| `crew_wake_drain` | read the state changes the foreman was woken for |
| `crew_doctor` | check this machine, before or during a session |
| `lavish_open` / `lavish_poll` | put up a review board / read your annotations |

In house mode, the same conversation is answered with the physician's tools.
None of them spawn, merge, archive, edit or run anything:

| Tool | What it does |
|---|---|
| `house_areas` | the chart: `list`, `add` an area, or `archive` one |
| `house_visit <slug>` | read one area's whole chart |
| `house_note <slug>` | chart a change; may set status and next |
| `house_next <slug>` | set (or clear) the diagnosed next step |
| `house_rounds` | one line per area, staleness and no-next marked |
| `house_prescribe <slug>` | assemble the paste-ready prompt, and outbox it |
| `house_send <slug>` | dry-run, or send the latest prescription to `bind` |

A crew member gets its own tools: `crew_report` (its state, its decision, its
PR) and `crew_cleanup` (stop what it started, so nothing is left holding a
port), plus the `lavish_*` pair below. `/crew` prints the board, `/crew on|off`
toggles the widget.

## Pieces

| Command | Does |
|---|---|
| `bin/foreman` | start the foreman session |
| `bin/house` | start a session in house mode |
| `bin/crew-todo.sh` | the durable project list |
| `bin/crew-spawn.sh <id> --project <p> [--todo <n>] <task…>` | worktree + pane + fresh pi; `--todo` warns when that item already has a live crew |
| `bin/crew-list.sh` | todo + crew board; regenerates `BOARD.md` |
| `bin/crew-report.sh <id> <verb> [note] [--key K] [--pr URL]` | *crew side:* record an event |
| `bin/crew-processes.sh list\|count\|kill\|snapshot <id>` | *crew side:* what this crew still has running, and the teardown |
| `bin/crew-decide.sh <id> <key> <answer…>` | answer a crew decision |
| `bin/crew-busy.sh <id>` / `bin/crew-busy-event.sh` | semantic turn state |
| `bin/crew-queue.sh` | the durable wake queue |
| `bin/crew-recover.sh [--relaunch <id>]` | reconcile, or relaunch an orphan |
| `bin/crew-merge.sh <id>` | merge a crew PR on your say-so |
| `bin/crew-pr.sh` / `bin/crew-pr-check.sh` | record / poll a pull request |
| `bin/crew-projects.sh` / `bin/crew-models.sh` | resolve names |
| `bin/crew-doctor.sh [--quiet]` | check the machine before a session |
| `bin/crew-digest.sh` | the one-line session-start digest |
| `bin/crew-handoff.sh write\|read\|show\|standing` | the dated note, and the standing doc |
| `bin/crew-config.sh` | show / set crew settings |
| `bin/crew-worktree.sh add\|remove` | the git worktree mechanics |
| `bin/crew-trust.sh <path>` | pi folder trust for a path |
| `bin/crew-lavish.sh open\|end\|export` | review boards |
| `bin/crew-peek.sh <id> [n]` | bounded tail of the pane |
| `bin/crew-send.sh <id> <text…>` | durable inbox record + doorbell |
| `bin/crew-inbox.sh <id>` | *crew side:* read and acknowledge steers |
| `bin/crew-read.sh <id>` | the crew's report, capped |
| `bin/crew-stop.sh <id> [--exit\|--close]` | interrupt / exit / close |
| `bin/crew-archive.sh <id> [--worktree] [--force] [--keep-home]` | retire a finished task, closing its terminal |
| `bin/crew-watch.sh` | one-shot watcher behind the auto wake |
| `bin/crew-test.sh` | the behaviour suite in `tests/` |

Internals, for reading rather than running: `bin/crew-launch.sh` (pane, worktree
and fresh agent), `bin/crew-pi-ext.sh` (generates the crew's own tools),
`bin/foreman-lib.sh` (paths, queue and Herdr helpers), and
`bin/herdr-workspace-move.mjs` (the one socket call Herdr's CLI lacks).

State lives in `.foreman/` (gitignored); `FOREMAN_HOME` relocates it and
`FOREMAN_SESSION` picks a named Herdr session (default `default`).

## Tests

```sh
bin/crew-test.sh                            # every test file
bin/crew-test.sh tests/crew-todo.test.sh    # one subject
bin/crew-test.sh --list
```

`tests/<subject>.test.sh` drives the real scripts in `bin/` inside an isolated
`FOREMAN_HOME`, with fake `herdr`, `gh`, `pi` and `lavish-axi` first on `PATH`.
The suite never touches a live Herdr session, a real pull request, or `~/.pi`.
One file is one subject and stops at the first bad assertion; `crew-test.sh`
reports one PASS/FAIL per file with its captured output. It is a behaviour suite
rather than a mock suite — only the external server and the network tools are
stubbed, and `DESIGN.md` explains why it is shaped that way.

Three files are deliberately live and skip unless asked for, because stubs
cannot catch a bug where every piece is individually right and the wiring
between them is not:

```sh
FOREMAN_E2E=1 bin/crew-test.sh tests/crew-e2e-live.test.sh
# a real worktree, a real Herdr pane, a real pi crew, a real steer, then stop
# and archive. Costs real model tokens; leaves nothing behind.

FOREMAN_LAVISH_E2E=1 bin/crew-test.sh tests/crew-lavish-live.test.sh
# a private lavish-axi server and browser-shaped feedback on every run.

FOREMAN_E2E=1 FOREMAN_E2E_REPO=<owner>/<name> \
  bin/crew-test.sh tests/crew-github-live.test.sh
# a real push, a real pull request, a real merge, a real remote branch
# deletion. It needs the repository named, because it creates a private
# throwaway repository and deletes it again, and it refuses to run against one
# that already exists.
```

## License

[MIT](LICENSE).
