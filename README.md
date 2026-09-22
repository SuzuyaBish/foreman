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

## Run

```sh
foreman/bin/foreman
```

Starts `pi` in this directory with the crew tools loaded. The first thing you
type is a message to your foreman. You never run the other commands below by
hand unless you want to.

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

## Crew settings

Told conversationally ("run the crew on X, thinking high"), persisted in
`.foreman/config.json`:

| Setting | Default | Meaning |
|---|---|---|
| `crewModel` | pi's default | model every crew member runs on |
| `crewThinking` | pi's default | `low`…`max` |
| `crewIsolate` | `true` | worktree per crew member for project work |
| `crewApprove` | `true` | pass `--approve`, so pi never shows a trust dialog |
| `trustPaths` | `true` | pre-register worktree paths in pi's trust file |
| `crewWake` | `true` | wake the foreman when crew state changes |

## Pieces

| Command | Does |
|---|---|
| `bin/foreman` | start the foreman session |
| `bin/crew-spawn.sh <id> --project <p> <task…>` | worktree + pane + fresh pi |
| `bin/crew-list.sh` | one line per crew; regenerates `BOARD.md` |
| `bin/crew-projects.sh` | what is in `projects/` |
| `bin/crew-models.sh [search]` | models pi can run |
| `bin/crew-config.sh` | show / set crew settings |
| `bin/crew-worktree.sh add\|remove` | the git worktree mechanics |
| `bin/crew-trust.sh <path>` | pi folder-trust for a path |
| `bin/crew-peek.sh <id> [n]` | bounded tail of the pane |
| `bin/crew-send.sh <id> <text…>` | durable inbox record + doorbell |
| `bin/crew-inbox.sh <id>` | *crew side:* read and acknowledge steers |
| `bin/crew-report.sh <id> <state> [note]` | *crew side:* update status |
| `bin/crew-read.sh <id>` | the crew's report, capped |
| `bin/crew-stop.sh <id> [--exit\|--close]` | interrupt / exit / close |
| `bin/crew-archive.sh <id> [--worktree]` | retire a finished task |
| `bin/crew-watch.sh` | one-shot state watcher behind the auto wake |

State lives in `.foreman/` (gitignored); `FOREMAN_HOME` relocates it and
`FOREMAN_SESSION` picks a named Herdr session (default `default`).
