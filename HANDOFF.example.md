# Handoff

Your installation's standing doc. It is kept and edited across sessions — the
durable half of what a session knows about *this* setup, as opposed to the tool.

It is **gitignored on purpose**: what you learn about your projects, your
conventions and your own traps is not something a clone of the harness should
inherit. This file is the tracked example; `HANDOFF.md` is seeded from it on the
first session in a clone, and you then make it yours.

The harness's own sharp edges and traps are in `DESIGN.md` — that is where a
gotcha that belongs to the tool goes, so the next person to clone it gets the
lesson with the code.

This is not the dated note. That one is `crew_handoff` (or
`bin/crew-handoff.sh write "..."`), it lives in the state directory, it is
delivered once to the next session, and `DESIGN.md` ("Handoff") explains why
there are two documents and not one.

## What this setup is

One short paragraph: which projects live in `projects/`, what the crew are
usually asked for, anything a fresh session would get wrong.

## Conventions

How work is delivered here, what a report has to contain, what you always want to
see before a merge.

## Traps you have paid for

The gotchas specific to *your* projects, machines or habits — the ones that cost
you an afternoon once and should never cost it again.

## Where things stand

Optional, and short. The git log and `crew_todo` are the real record; anything
written here is stale the moment it is true.
