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
#   --base <ref>       worktree base (default HEAD)
#   --model <model>    model for this crew member (default: config crewModel)
#   --thinking <lvl>   low|medium|high|xhigh|max (default: config crewThinking)
#   -- <text>          everything after this is task text
#
# Model, thinking level, folder-trust approval, and worktree isolation all fall
# back to crew-config.sh, so the captain can say "run the crew on X" once.
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
  --project)
    need_val "$@"
    PROJECT=$2
    seen_target=1
    shift 2
    ;;
  --cwd)
    need_val "$@"
    CWD=$2
    seen_target=1
    shift 2
    ;;
  --model)
    need_val "$@"
    MODEL=$2
    shift 2
    ;;
  --thinking)
    need_val "$@"
    THINKING=$2
    shift 2
    ;;
  --base)
    need_val "$@"
    BASE=$2
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
  --delivery)
    need_val "$@"
    DELIVERY=$2
    shift 2
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

# Defaults from the session config.
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
APPROVE=$(foreman_config_bool crewApprove 1)
TRUST_PATHS=$(foreman_config_bool trustPaths 1)

DIR=$(foreman_task_dir "$ID")
[ ! -e "$DIR" ] || foreman_die "crew task '$ID' already exists; archive it or pick another id"

WT=
PROJ=
if [ "$ISOLATE" = 1 ]; then
  PROJ=$(foreman_project_path "$PROJECT")
  WT=$("$FOREMAN_ROOT/bin/crew-worktree.sh" add "$PROJECT" "$ID" --base "$BASE") ||
    foreman_die "could not create an isolated worktree for '$ID' in project '$PROJECT'"
  CWD=$WT
fi
[ -d "$CWD" ] || foreman_die "working directory does not exist: $CWD"
CWD=$(cd "$CWD" && pwd -P)

mkdir -p "$DIR/inbox/handled"
printf '%s\n' "$TASK" >"$DIR/task.md"

# The crew member runs its own shell, so every command it is told to run must
# carry this session's FOREMAN_HOME explicitly rather than relying on the
# default derived from the script location.
QHOME="FOREMAN_HOME=$(printf '%q' "$FOREMAN_HOME")"
REPORT_CMD="$QHOME $(printf '%q' "$FOREMAN_ROOT/bin/crew-report.sh") $ID"
INBOX_CMD="$QHOME $(printf '%q' "$FOREMAN_ROOT/bin/crew-inbox.sh") $ID"

# How this crew member hands its work over. `auto` prefers a pull request when
# the directory is a git repo with an origin remote and gh is available;
# otherwise the work stays local, or is report-only for a non-repository.
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
4. Record it and finish:
     $REPORT_CMD review "<one-line summary>" --pr "<the pull request url>"

Do not merge it — the captain does that. Leave the worktree, the branch and the
commits exactly as they are; they are cleaned up after the merge.
EOF
)
  ;;
local)
  DELIVERY_BLOCK=$(cat <<EOF
## Finishing

Your work is on branch \`crew/$ID\`. Commit everything, then finish with:

  $REPORT_CMD done "<one-line summary>"

Do not push and do not open a pull request. Leave the branch in place.
EOF
)
  ;;
report)
  DELIVERY_BLOCK=$(cat <<EOF
## Finishing

The deliverable is the report file. Finish with:

  $REPORT_CMD done "<one-line summary>"

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

$DELIVERY_BLOCK

If you cannot proceed without a decision, run:

  $REPORT_CMD blocked "<one-line reason>"

and stop. Do not guess at a decision that is not yours to make.

## New instructions

The foreman can send more instructions at any time. They land in:

  $DIR/inbox/

Check for them between significant steps:

  $INBOX_CMD

That prints every unacknowledged instruction and marks it handled. Run it before
starting anything long, and again after finishing a step.

## Rules

- Work only inside $CWD unless the task says otherwise.
- Do not ask the captain questions in chat. Use crew-report.sh.
- A done status with no report is a failed task.
EOF

foreman_status_set "$ID" queued "brief written"

WS=$(foreman_workspace)
OUT=$(foreman_herdr tab create --workspace "$WS" --cwd "$CWD" --label "crew-$ID" --no-focus 2>/dev/null) ||
  foreman_die "herdr tab create failed in workspace $WS (session $FOREMAN_SESSION)"
TAB=$(printf '%s' "$OUT" | jq -r '.result.tab.tab_id // empty' 2>/dev/null)
PANE=$(printf '%s' "$OUT" | jq -r '.result.root_pane.pane_id // empty' 2>/dev/null)
if [ -z "$TAB" ] || [ -z "$PANE" ]; then
  foreman_die "herdr returned no tab/pane id: $OUT"
fi

{
  printf 'pane=%s:%s\n' "$FOREMAN_SESSION" "$PANE"
  printf 'tab=%s\n' "$TAB"
  printf 'workspace=%s\n' "$WS"
  printf 'session=%s\n' "$FOREMAN_SESSION"
  printf 'cwd=%s\n' "$CWD"
  printf 'harness=pi\n'
  [ -z "$PROJ" ] || printf 'project=%s\n' "$PROJ"
  [ -z "$WT" ] || printf 'worktree=%s\n' "$WT"
  [ -z "$WT" ] || printf 'branch=crew/%s\n' "$ID"
  [ -z "$MODEL" ] || printf 'model=%s\n' "$MODEL"
  [ -z "$THINKING" ] || printf 'thinking=%s\n' "$THINKING"
  printf 'delivery=%s\n' "$DELIVERY"
  printf 'created=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} >"$DIR/meta"

# Pre-register folder trust so nobody is prompted, including a human who later
# attaches to this pane. Best effort: a failure must not fail the spawn.
if [ "$TRUST_PATHS" = 1 ] && [ -d "$HOME/.pi" ]; then
  "$FOREMAN_ROOT/bin/crew-trust.sh" "$CWD" >/dev/null 2>&1 || true
fi

POINTER="Read $DIR/brief.md and follow it exactly. It describes your whole task."
CMD="${FOREMAN_PI_BIN:-pi}"
[ "$APPROVE" != 1 ] || CMD="$CMD --approve"
[ -z "$MODEL" ] || CMD="$CMD --model $(printf '%q' "$MODEL")"
[ -z "$THINKING" ] || CMD="$CMD --thinking $(printf '%q' "$THINKING")"
CMD="$CMD $(printf '%q' "$POINTER")"

if ! foreman_herdr pane run "$PANE" "$CMD" >/dev/null 2>&1; then
  foreman_herdr tab close "$TAB" >/dev/null 2>&1 || true
  foreman_status_set "$ID" failed "launch command could not be sent"
  foreman_die "pane $PANE was created but the launch command could not be sent; the tab was closed"
fi

foreman_status_set "$ID" working "spawned"
printf 'spawned %s pane=%s:%s\n' "$ID" "$FOREMAN_SESSION" "$PANE"
printf 'cwd %s\n' "$CWD"
[ -z "$WT" ] || printf 'worktree %s on branch crew/%s\n' "$WT" "$ID"
[ -z "$MODEL" ] || printf 'model %s\n' "$MODEL"
printf 'delivery %s\n' "$DELIVERY"
