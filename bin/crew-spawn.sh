#!/usr/bin/env bash
# crew-spawn.sh - create one crew member: a Herdr tab running a fresh pi.
#
# Usage: crew-spawn.sh <id> <cwd> [options] <task text...>
#        crew-spawn.sh <id> --project <name> [options] <task text...>
#
# Options:
#   --project <name>   a project under projects/; isolates into a worktree by default
#   --cwd <path>       explicit working directory
#   --isolate          force a git worktree (needs --project)
#   --no-isolate       work directly in the project checkout
#   --delivery <mode>  pr | local | report | auto (default)
#   --base <ref>       worktree base (default HEAD)
#   --model <model>    model for this crew member (default: config crewModel)
#   --thinking <lvl>   low|medium|high|xhigh|max (default: config crewThinking)
#   -- <text>          everything after this is task text
set -eu

. "$(cd "$(dirname "$0")" && pwd)/foreman-lib.sh"

need_val() { [ "$#" -ge 2 ] || foreman_die "$1 requires a value"; }

ID=${1:-}
if [ $# -ge 1 ]; then shift; fi

CWD=
PROJECT=
ISOLATE=
DELIVERY=
MODEL=
THINKING=
BASE=HEAD
PARTS=()
seen_target=0
while [ $# -gt 0 ]; do
  case "$1" in
  --project | --cwd | --model | --thinking | --base | --delivery)
    need_val "$@"
    case "$1" in
    --project)
      PROJECT=$2
      seen_target=1
      ;;
    --cwd)
      CWD=$2
      seen_target=1
      ;;
    --model) MODEL=$2 ;;
    --thinking) THINKING=$2 ;;
    --base) BASE=$2 ;;
    --delivery) DELIVERY=$2 ;;
    esac
    shift 2
    ;;
  --isolate)
    ISOLATE=1
    shift
    ;;
  --no-isolate)
    ISOLATE=0
    shift
    ;;
  --)
    shift
    PARTS+=("$@")
    break
    ;;
  -*)
    foreman_die "unknown option: $1"
    ;;
  *)
    if [ "$seen_target" -eq 0 ] && [ "${#PARTS[@]}" -eq 0 ]; then
      CWD=$1
      seen_target=1
    else
      PARTS+=("$1")
    fi
    shift
    ;;
  esac
done
TASK="${PARTS[*]-}"

foreman_valid_id "$ID" || foreman_die "task id must be a kebab-case slug of 1-32 chars: '${ID}'"
[ -n "$TASK" ] || foreman_die "task text is empty"
foreman_need_herdr

if [ -n "$PROJECT" ] && [ -n "$CWD" ]; then
  foreman_die "give either a cwd or --project, not both"
fi
if [ -z "$PROJECT" ] && [ -z "$CWD" ]; then
  foreman_die "give a working directory or --project <name>; see crew-projects.sh"
fi

[ -n "$MODEL" ] || MODEL=$(foreman_config_get crewModel || true)
[ -n "$THINKING" ] || THINKING=$(foreman_config_get crewThinking || true)
if [ -z "$ISOLATE" ]; then
  if [ -n "$PROJECT" ]; then
    ISOLATE=$(foreman_config_bool crewIsolate 1)
  else
    ISOLATE=0
  fi
fi
if [ "$ISOLATE" = 1 ] && [ -z "$PROJECT" ]; then
  foreman_die "--isolate needs --project (a worktree is cut from a project checkout)"
fi

DIR=$(foreman_task_dir "$ID")
[ ! -e "$DIR" ] || foreman_die "crew task '$ID' already exists; archive it or pick another id"

WT=
PROJ=
if [ "$ISOLATE" = 1 ]; then
  PROJ=$(foreman_project_path "$PROJECT")
  WT=$("$FOREMAN_ROOT/bin/crew-worktree.sh" add "$PROJECT" "$ID" --base "$BASE") ||
    foreman_die "could not create an isolated worktree for '$ID' in project '$PROJECT'"
  CWD=$WT
elif [ -z "$CWD" ] && [ -n "$PROJECT" ]; then
  # --no-isolate (or crewIsolate=false) works directly in the project checkout.
  CWD=$(foreman_project_path "$PROJECT")
fi
[ -d "$CWD" ] || foreman_die "working directory does not exist: $CWD"
CWD=$(cd "$CWD" && pwd -P)

mkdir -p "$DIR/inbox/handled"
printf '%s\n' "$TASK" >"$DIR/task.md"

# How this crew member hands its work over. `auto` prefers a pull request when
# the directory is a git repo with an origin remote and gh is available.
[ -n "$DELIVERY" ] || DELIVERY=$(foreman_config_get crewDelivery || true)
[ -n "$DELIVERY" ] || DELIVERY=auto
if [ "$DELIVERY" = auto ]; then
  if ! git -C "$CWD" rev-parse --git-dir >/dev/null 2>&1; then
    DELIVERY=report
  elif command -v gh >/dev/null 2>&1 && git -C "$CWD" remote get-url origin >/dev/null 2>&1; then
    DELIVERY=pr
  else
    DELIVERY=local
  fi
fi
case "$DELIVERY" in pr | local | report) ;; *) foreman_die "unknown delivery mode: $DELIVERY (pr|local|report)" ;; esac

QHOME="FOREMAN_HOME=$(printf '%q' "$FOREMAN_HOME")"
INBOX_CMD="$QHOME $(printf '%q' "$FOREMAN_ROOT/bin/crew-inbox.sh") $ID"

case "$DELIVERY" in
pr)
  DELIVERY_BLOCK=$(cat <<EOF
## Finishing

The change is not delivered until the captain merges a pull request for it. It
lives on branch \`crew/$ID\` in an isolated git worktree.

1. Commit everything on the branch; leave nothing uncommitted.
2. Push it:  git push -u origin crew/$ID
3. Open a pull request:
     gh pr create --title "<short title>" --body "<what changed, why, how you verified it>"
4. Record it and finish with the \`crew_report\` tool:
     crew_report(verb="review", note="<one-line summary>", pr="<the pull request url>")

Do not merge it — the captain does that. Leave the worktree, the branch and the
commits exactly as they are; they are cleaned up after the merge.
EOF
)
  ;;
local)
  DELIVERY_BLOCK=$(cat <<EOF
## Finishing

Your work is on branch \`crew/$ID\`. Commit everything, then finish with:

  crew_report(verb="done", note="<one-line summary>")

Do not push and do not open a pull request. Leave the branch in place.
EOF
)
  ;;
report)
  DELIVERY_BLOCK=$(cat <<EOF
## Finishing

The deliverable is the report file. Finish with:

  crew_report(verb="done", note="<one-line summary>")

Do not commit, push, or open a pull request unless the task itself asks for a
change to the code.
EOF
)
  ;;
esac

cat >"$DIR/brief.md" <<EOF
# Crew task: $ID

You are a crew member. You were assigned this by the captain's foreman. Nobody
is watching your terminal; the captain reads your report file.

## Task

$TASK

## Working directory

$CWD

## Report

Write your result to:

  $DIR/report.md

Keep it tight and decision-shaped: what you did or found, the evidence, what is
still unresolved. This file is the deliverable.

Everything the foreman and the captain see from you goes through the
\`crew_report\` tool — there is no bash command to remember.

$DELIVERY_BLOCK

## Decisions

If you hit a choice that is not yours to make, ask for it instead of guessing:

  crew_report(verb="needs-decision", note="<the question>", key="<short-key>")

Then stop and wait. The captain's answer arrives in your inbox as a resolved
decision; check the inbox before resuming. Reuse the same key if you have to ask
again about the same thing.

If you simply cannot proceed, use \`blocked\` instead:

  crew_report(verb="blocked", note="<one-line reason>")

## Stop what you started

Dev servers, file watchers, test runners, emulators, browsers, anything you put
in the background: stop them before you finish. They outlive this task, they
hold ports and CPU, and once the task is archived nothing on the machine knows
they were ever yours. The \`crew_cleanup\` tool lists what is still running in
your working directory and stops it:

  crew_cleanup(action="check")     what is still up
  crew_cleanup(action="kill")      stop it

A \`review\` or \`done\` report is refused while anything is still running, so do
this before you report. A Lavish board is the one exception: it stays up while
the captain annotates it, and stops itself when that review is over.

## New instructions

The foreman can send more instructions at any time. They land in:

  $DIR/inbox/

Check for them between significant steps:

  $INBOX_CMD

That prints every unacknowledged instruction and marks it handled. Run it before
starting anything long, and again after finishing a step.

## Visual work

If your deliverable is visual — a UI mock, a plan, a comparison, a review surface
— build it as an HTML artifact and open a Lavish board with the \`lavish_open\`
tool, then call \`lavish_poll\` once and leave it running. The captain annotates
the page and the feedback comes back to you. After opening the board, record
what you need reviewed with:

  crew_report(verb="needs-decision", note="<what you need reviewed>", key="board-url")

## Rules

- Work only inside $CWD unless the task says otherwise.
- Do not ask the captain questions in chat. Use the \`crew_report\` tool.
- A done status with no report is a failed task.
- Never merge a pull request yourself.
EOF

{
  printf 'harness=pi\n'
  printf 'created=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'delivery=%s\n' "$DELIVERY"
  [ -z "$PROJ" ] || printf 'project=%s\n' "$PROJ"
  [ -z "$WT" ] || printf 'worktree=%s\n' "$WT"
  [ -z "$WT" ] || printf 'branch=crew/%s\n' "$ID"
  [ -z "$MODEL" ] || printf 'model=%s\n' "$MODEL"
  [ -z "$THINKING" ] || printf 'thinking=%s\n' "$THINKING"
} >"$DIR/meta"

# Arm the busy incarnation before the launch, so the extension the crew member
# runs with carries a token that this task alone owns.
GEN=$("$FOREMAN_ROOT/bin/crew-busy-event.sh" arm "$FOREMAN_HOME" "$ID" --state busy --source fm-spawn --event launch-brief) ||
  foreman_die "could not arm the busy record for '$ID'"
foreman_meta_set "$ID" busy_gen "$GEN"
"$FOREMAN_ROOT/bin/crew-pi-ext.sh" "$ID" "$GEN" >/dev/null ||
  foreman_die "could not write the crew extension for '$ID'"

LAUNCH_ARGS=()
[ -z "$MODEL" ] || LAUNCH_ARGS+=(--model "$MODEL")
[ -z "$THINKING" ] || LAUNCH_ARGS+=(--thinking "$THINKING")
"$FOREMAN_ROOT/bin/crew-launch.sh" "$ID" "$CWD" ${LAUNCH_ARGS[@]+"${LAUNCH_ARGS[@]}"}

printf 'cwd %s\n' "$CWD"
[ -z "$WT" ] || printf 'worktree %s on branch crew/%s\n' "$WT" "$ID"
[ -z "$MODEL" ] || printf 'model %s\n' "$MODEL"
printf 'delivery %s\n' "$DELIVERY"
