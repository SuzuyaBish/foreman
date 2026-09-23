# house

The attending physician beside the foreman.

Foreman runs the crew. **House keeps the chart and writes prescriptions.** It
knows every area you work on — the repos, the projects that live in their own
chats, the decks and talks, the crafts like branding and the design skill — and
it does nothing to any of them. It examines, diagnoses, prescribes and, only
when you say so, sends a prompt to the session already working there.

## What an area is

An area is not a git project and not a crew task. It is any ongoing thread you
keep in your head: *the four Harbour chats*, *the Lighthouse deck*, *Atlas*,
*the brand skill*. You name them. Their truth lives in House's chart under
`$FOREMAN_HOME/house/areas/<slug>.md` — plain text, greppable, yours to edit —
not in git.

Each chart is a handful of one-line fields (`kind`, `where`, `bind`, `status`,
`next`) and an append-only dated log. `bin/house-rounds.sh` reads them all and
tells you where everything stands and what is rotting.

`updated` is **last-write, not last-verified**: it moves when the chart is
written to (`note` or `next`), never when a claim is re-checked. A status — a
commit sha, a branch, a PR — can read fresh while being wrong, and rounds age
the chart you last touched, not the state you last confirmed.

## Entering house mode

```sh
bin/house          # same repo, same extension, house discipline
```

Equivalently, from this directory: `FOREMAN_MODE=house pi`. House is a *mode
beside foreman*, not a second foreman: the crew machinery stays underneath,
untouched, and house simply does not use it. A house session opens on the
rounds, so it starts knowing the areas instead of asking.

Once in, the `house` skill frames the work. You do not call the scripts; you say
what you want and House picks the tool:

| You say | House does |
|---|---|
| "track the lighthouse as a deck" | opens a chart (`house_areas`) |
| "the deck is out for review, next is to tighten the ask" | charts it (`house_note`) |
| "rounds" / "status?" | one line per area, staleness marked (`house_rounds`) |
| "what's next for atlas?" | visits the chart, diagnoses, sets `next`, prescribes (`house_prescribe`) |
| "send that to atlas" | delivers the latest prescription to its `bind` (`house_send`) |

## What House will not do

House never spawns a crew, never merges, archives, edits or runs an area's work,
and never touches the crew machinery. When two areas conflict, or a next step is
really a decision, House asks; it does not invent one. When work should happen,
House writes the prescription, hands it over, and stops.

The four verbs are the whole job: **examine, diagnose, prescribe, send on
command.**
