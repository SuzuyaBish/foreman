# Foreman — design

Foreman is a captain → foreman → crew system for Pi + Herdr.

The captain talks to one agent (the **foreman**). The foreman turns requirements
into tasks and spins off **crew** members: separate `pi` processes in separate
Herdr panes, each in its own working directory. The captain can ask what is
going on, steer one crew member, or stop it — always by talking to the foreman.

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
   the fleet, because the fleet is not in the conversation.

6. **Fresh agent per task.**
   No crew member is kept alive for days accumulating turns. When it is done,
   its report is on disk and the process is disposable.

Measured consequence: a fleet of ten long-running crew costs the foreman one
line of context each, plus whatever it deliberately reads. Firstmate's cost comes
from wake payloads, pane captures, and status logs crossing into the main
conversation; none of those paths exist here.

## Layout

```
foreman/
  AGENTS.md              standing instructions loaded into the foreman session
  extensions/foreman.ts  the model-facing tools
  bin/foreman            launcher: pi -e extensions/foreman.ts
  bin/*.sh               zero-token mechanics: spawn, read, steer, stop
  .foreman/              runtime state (gitignored)
    tasks/<id>/
      task.md            the requirement, verbatim
      brief.md           what the crew member is told
      report.md          what the crew member produced
      status             state= at= note=
      meta               pane= tab= workspace= cwd= session= harness=
      inbox/NNN.msg      steers from the foreman
      inbox/handled/     crew moves the file here to acknowledge
    BOARD.md             generated status board
```

## Transport

Herdr owns topology and lifecycle truth (`idle/working/blocked/done`). Foreman
owns meaning and durability. Every Herdr call is explicit:

```
herdr --session <session> <group> <command> …
```

Never ambient selection, never label-as-authority: a pane id recorded at spawn is
the endpoint, and labels are display only.

- **Spawn**: `workspace create` / resolve → `tab create --no-focus` → read
  `tab_id` and `pane_id` from the JSON response → `pane run` the launch command.
- **Read**: `pane read --source recent-unwrapped --lines N`, trimmed locally.
- **Steer**: durable inbox record + one self-describing doorbell line typed into
  the pane. Delivery is proved by the crew moving the record to `handled/`, not
  by the Enter key.
- **Stop**: `pane send-keys <pane> esc` (interrupt), `pane run <pane> /quit`
  (exit), `tab close <tab>` (close). Only endpoints we recorded are touched.

## Status model

`queued → working → (blocked ↔ working) → done | failed | stopped | lost`

- `working/blocked/done/failed/stopped` are written by the crew through
  `crew-report.sh`.
- `lost` is derived by bash when the recorded pane no longer exists.
- `idle` from Herdr is **never** treated as "done": a crew member between turns
  is idle and still working.

## What is deliberately absent

- No automatic wake injection into the foreman. The captain asks; the foreman
  calls `crew_list`. (An opt-in one-line watcher ping is a later decision, and it
  must never carry payload.)
- No worktree manager. Crew run in the directory they are given; git worktrees
  are the caller's choice.
- No supervision branch, no second mates, no quota routing, no PR pipeline.
