# foreman

Talk to one agent. It runs the crew. Your context stays flat.

Foreman is a small captain → foreman → crew harness for **Pi** (harness) and
**Herdr** (multiplexer). Each crew member is a separate `pi` process in its own
Herdr pane, in its own git worktree. Crew work in isolated contexts and write
reports to disk. The foreman is given pointers and one-line statuses, never
transcripts.

Read [DESIGN.md](DESIGN.md) for the context contract. It is the point.

## Requirements

- `pi` on PATH
- `herdr` on PATH, server running (`herdr status`)
- `jq`

`bin/crew-doctor.sh` checks all of this (and the optional `gh`/`lavish-axi`) and
runs at every session start; it is silent unless something is wrong.

## Run

```sh
cd foreman
pi
```

That is the whole thing. Pi loads `.pi/extensions/foreman.ts` because it is
project-local, and `AGENTS.md` as standing instructions. The first time in a
fresh clone, approve Pi's project-trust prompt: project extensions are not loaded
before the project is trusted, and approving is once per clone. `foreman/bin/foreman`
does the same thing after creating `projects/` and `worktrees/`; it does not name
the extension with `-e`, because doing that *as well* would load it twice.

The first thing you type is a message to your foreman. You never run the other
commands below by hand unless you want to.

The chrome and the crew tools belong to this directory. A pi session started
everywhere else — even after a reload — has no widget, no status line, no
`crew_*` tools and no digest. That is deliberate: installing the extension
globally would start its auto-wake watcher in every session, in every project.

Every session starts the same way: the foreman reads `foreman/HANDOFF.md` (the
standing architecture and traps) and then `crew_todo` (the durable plan), as
`AGENTS.md` instructs. It is also handed a one-line `crew digest:` and, once,
the previous session's dated handoff note — both orientation, not the plan.

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
```

## Projects

Put repositories in `projects/`. The foreman works on them there, and by default
gives each crew member its own git worktree under `worktrees/<id>` on a
`crew/<id>` branch — so two crew can touch one repo without colliding, and
nothing is discarded when the pane closes.

`projects/` is gitignored, so cloned repositories never enter this repo's
history.

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

## Delivery

Work in a project is delivered as a pull request. A crew member commits on its
`crew/<id>` branch, pushes, opens the PR, and finishes in state **`review`**.
Its pane, worktree and branch all stay in place — the instance is kept open
until the captain merges it. The watcher polls the PR and settles the task to
`done` on merge, and the auto wake tells the foreman.

A research task delivers a report instead (`done`, no PR); a project without a
forge remote delivers locally. `crewDelivery` sets which is normal, and
`crew_archive` refuses a task whose PR is still open.

## The chrome

While a session runs, a status line and a widget sit above the editor. Both are
rendered straight from the task records — no Herdr call, no model call, no
tokens. The line leads with what the captain owes and trails with the durable
queue; the widget is worst-first, shows how long ago each crew last reported, and
colours each state with its theme role:

```
1 decision · 1 failed · 1 review · 2 working · todo 3/12

c-authque        blocked  4m   [api] retry policy: fail fast or back off?
c-ingest         failed   30m  no such host: registry.internal
c-docs           review   1m   PR #12 waiting to merge
c-parser         working  7m   splitting the grammar
#11              open     -    finish the widget
```

The widget shows at most six lines: one per active crew member, then open todo
items in the slots that are left. `/crew` prints the whole board; `/crew on|off`
toggles the widget.

At session start the foreman is also handed one injected line, for example:

```
crew digest: 3 crew (1 working, 1 blocked, 1 review) · 1 decision open · todo 12 items (7 open, 0 active, 5 done)
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
uncommitted work survive, and the task keeps its identity.

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

That note is separate from `foreman/HANDOFF.md`, which is the standing
architecture and traps doc: kept and edited, never consumed.

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
reports one PASS/FAIL per file with its captured output.

It is a behaviour suite, not a mock suite: only the external server (`herdr`) and
the network tools (`gh`, `pi`, `lavish-axi`) are stubbed. Everything else — the
event fold, the todo list, the worktree mechanics, spawn/stop/recover — runs the
production code path.

Three files are deliberately live, and skip unless asked for. They exist because
stubs cannot catch a bug where every piece is individually right and the wiring
between them is not:

```sh
FOREMAN_E2E=1 bin/crew-test.sh tests/crew-e2e-live.test.sh
# a real worktree, a real Herdr pane, a real pi crew, a real steer, then stop
# and archive. Costs real model tokens; leaves nothing behind.

FOREMAN_LAVISH_E2E=1 bin/crew-test.sh tests/crew-lavish-live.test.sh
# a private lavish-axi server and browser-shaped feedback on every run.
```

The GitHub boundary has its own live file. It needs the repository name spelled
out, because it creates a private throwaway repository and deletes it again:

```sh
FOREMAN_E2E=1 FOREMAN_E2E_REPO=<owner>/<name> \
  bin/crew-test.sh tests/crew-github-live.test.sh
# a real push, a real pull request, a real merge, a real remote branch deletion.
# It refuses to run against a repository that already exists.
```

## Pieces

| Command | Does |
|---|---|
| `bin/foreman` | start the foreman session |
| `bin/crew-todo.sh` | the durable project list |
| `bin/crew-spawn.sh <id> --project <p> <task…>` | worktree + pane + fresh pi |
| `bin/crew-list.sh` | todo + crew board; regenerates `BOARD.md` |
| `bin/crew-report.sh <id> <verb> [note] [--key K] [--pr URL]` | *crew side:* record an event |
| `bin/crew-decide.sh <id> <key> <answer…>` | answer a crew decision |
| `bin/crew-busy.sh <id>` / `bin/crew-busy-event.sh` | semantic turn state |
| `bin/crew-queue.sh` | the durable wake queue |
| `bin/crew-recover.sh [--relaunch <id>]` | reconcile, or relaunch an orphan |
| `bin/crew-merge.sh <id>` | merge a crew PR on your say-so |
| `bin/crew-pr.sh` / `bin/crew-pr-check.sh` | record / poll a pull request |
| `bin/crew-projects.sh` / `bin/crew-models.sh` | resolve names |
| `bin/crew-doctor.sh [--quiet]` | check the machine before a session |
| `bin/crew-digest.sh` | the one-line session-start digest |
| `bin/crew-handoff.sh write\|read\|show` | the dated note for the next session |
| `bin/crew-config.sh` | show / set crew settings |
| `bin/crew-worktree.sh add\|remove` | the git worktree mechanics |
| `bin/crew-trust.sh <path>` | pi folder trust for a path |
| `bin/crew-lavish.sh open\|end\|export` | review boards |
| `bin/crew-peek.sh <id> [n]` | bounded tail of the pane |
| `bin/crew-send.sh <id> <text…>` | durable inbox record + doorbell |
| `bin/crew-inbox.sh <id>` | *crew side:* read and acknowledge steers |
| `bin/crew-read.sh <id>` | the crew's report, capped |
| `bin/crew-stop.sh <id> [--exit\|--close]` | interrupt / exit / close |
| `bin/crew-archive.sh <id> [--worktree]` | retire a finished task |
| `bin/crew-watch.sh` | one-shot watcher behind the auto wake |
| `bin/crew-test.sh` | the behaviour suite in `tests/` |

State lives in `.foreman/` (gitignored); `FOREMAN_HOME` relocates it and
`FOREMAN_SESSION` picks a named Herdr session (default `default`).
