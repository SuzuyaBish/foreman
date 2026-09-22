# foreman

Talk to one agent. It runs the crew. Your context stays flat.

Foreman is a small captain → foreman → crew harness for **Pi** (harness) and
**Herdr** (multiplexer). Each crew member is a separate `pi` process in its own
Herdr pane. Crew work in isolated contexts and write reports to disk. The
foreman is given pointers and one-line statuses, never transcripts.

Read [DESIGN.md](DESIGN.md) for the context contract. It is the point.

## Requirements

- `pi` on PATH
- `herdr` on PATH, server running (`herdr status`)
- `jq`

## Run

```sh
foreman/bin/foreman
```

This starts `pi` in the `foreman/` directory with the extension loaded and
`AGENTS.md` as standing instructions. Then just talk:

```
> I need three things looked at: the flaky auth test, the unused CSS, and the
  missing rate limit on /api/upload.

  [foreman spawns crew-auth-test, crew-css-audit, crew-rate-limit]

> status?

  crew-auth-test   working  4m   reproduced: session cookie not refreshed
  crew-css-audit   done     2m   report ready (312 lines)
  crew-rate-limit  blocked  1m   needs decision: 429 vs 503

> read the css one

  [foreman reads report.md, capped]

> tell rate-limit to use 429 with Retry-After

> stop the auth one, I'll take it myself
```

## Pieces

| Command | Does |
|---|---|
| `bin/crew-spawn.sh <id> <dir> <task…>` | new pane + new pi process + brief |
| `bin/crew-list.sh` | one line per crew; regenerates `BOARD.md` |
| `bin/crew-peek.sh <id> [n]` | bounded tail of the pane |
| `bin/crew-send.sh <id> <text…>` | durable inbox record + doorbell |
| `bin/crew-inbox.sh <id>` | *crew side:* read and acknowledge steers |
| `bin/crew-report.sh <id> <state> [note]` | *crew side:* update status |
| `bin/crew-read.sh <id>` | the crew's report, capped |
| `bin/crew-stop.sh <id> [--exit\|--close]` | interrupt / exit / close |
| `bin/crew-archive.sh <id>` | move a finished task out of the active set |

State lives in `.foreman/` and is gitignored. `FOREMAN_HOME` relocates it,
`FOREMAN_SESSION` picks a named Herdr session (default `default`).
