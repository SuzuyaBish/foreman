#!/usr/bin/env bash
# crew-recover.sh - reconcile the fleet after a crash, a restart, or Herdr churn.
#
# Usage: crew-recover.sh                 scan and report (never mutates a pane)
#        crew-recover.sh --relaunch <id> [--force]
#
# A foreman session can die with crew still running, and a Herdr pane can be
# destroyed out from under a live task. A scan reports which tasks have no
# endpoint; a relaunch puts a fresh agent back into the task's EXISTING worktree,
# with a progress note appended to its instructions, so commits and uncommitted
# work survive and the task keeps its identity.
set -eu

. "$(cd "$(dirname "$0")" && pwd)/foreman-lib.sh"

ACTION=scan
ID=
FORCE=0
QUEUE=0
while [ $# -gt 0 ]; do
  case "$1" in
  --relaunch)
    ACTION=relaunch
    ID=${2:-}
    [ -n "$ID" ] || foreman_die "--relaunch needs a task id"
    shift 2
    ;;
  --queue)
    QUEUE=1
    shift
    ;;
  --force)
    FORCE=1
    shift
    ;;
  *) foreman_die "unknown option: $1" ;;
  esac
done

case "$ACTION" in
scan)
  any=0
  for id in $(foreman_task_ids); do
    state=$(foreman_status_get "$id" state)
    if foreman_pane_of "$id" >/dev/null 2>&1; then
      printf '%-18s %-8s endpoint ok\n' "$id" "$state"
      continue
    fi
    case "$state" in
    done | failed | stopped)
      printf '%-18s %-8s endpoint gone (settled)\n' "$id" "$state"
      ;;
    review)
      printf '%-18s %-8s endpoint gone, pull request %s still open\n' \
        "$id" "$state" "$(foreman_meta_get "$id" pr)"
      ;;
    *)
      any=1
      if [ "$QUEUE" = 1 ]; then
        foreman_queue_append recover "$id $state endpoint gone" >/dev/null || true
      fi
      printf '%-18s %-8s ORPHANED — relaunch with: crew-recover.sh --relaunch %s\n' \
        "$id" "$state" "$id"
      ;;
    esac
  done
  if [ "$any" -eq 0 ]; then
    printf 'no orphaned crew\n'
  fi
  ;;
relaunch)
  DIR=$(foreman_require_task "$ID")
  STATE=$(foreman_status_get "$ID" state)

  if foreman_pane_of "$ID" >/dev/null 2>&1 && [ "$FORCE" != 1 ]; then
    foreman_die "crew '$ID' still has a reachable pane; refusing to launch a second agent into the same worktree (--force to override)"
  fi

  CWD=$(foreman_meta_get "$ID" cwd)
  [ -z "$CWD" ] || [ -d "$CWD" ] ||
    foreman_die "crew '$ID' was working in '$CWD', which no longer exists; nothing to relaunch into"
  if [ -z "$CWD" ]; then
    CWD=$(foreman_meta_get "$ID" worktree)
  fi
  [ -n "$CWD" ] && [ -d "$CWD" ] ||
    foreman_die "crew '$ID' has no recorded working directory that still exists"

  NOTE=$(foreman_status_get "$ID" note)
  {
    printf '\n## Progress note (%s)\n\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'This is a recovery relaunch: the previous agent lost its terminal.\n\n'
    printf 'Last recorded state: `%s` — %s\n\n' "$STATE" "$NOTE"
    [ ! -f "$DIR/report.md" ] || printf 'A report from the earlier attempt is at `%s/report.md`.\n\n' "$DIR"
    printf 'Your worktree is exactly as it was left. Check `git status` and `git log`\n'
    printf 'before doing anything, and continue from there. Do not redo finished work.\n'
  } >>"$DIR/brief.md"

  GEN=$("$FOREMAN_ROOT/bin/crew-busy-event.sh" arm "$FOREMAN_HOME" "$ID" --state busy --source fm-recovery --event relaunch) ||
    foreman_die "could not arm the busy record for '$ID'"
  foreman_meta_set "$ID" busy_gen "$GEN"
  "$FOREMAN_ROOT/bin/crew-pi-ext.sh" "$ID" "$GEN" >/dev/null ||
    foreman_die "could not write the crew extension for '$ID'"

  # The task's own record first; a task that never recorded one (spawned before
  # crewModel was set, or by an older spawn) takes the current config, exactly as
  # a fresh spawn would, and records it so the next relaunch is the same.
  MODEL=$(foreman_meta_get "$ID" model)
  THINKING=$(foreman_meta_get "$ID" thinking)
  if [ -z "$MODEL" ]; then
    MODEL=$(foreman_config_get crewModel || true)
    [ -z "$MODEL" ] || foreman_meta_set "$ID" model "$MODEL"
  fi
  if [ -z "$THINKING" ]; then
    THINKING=$(foreman_config_get crewThinking || true)
    [ -z "$THINKING" ] || foreman_meta_set "$ID" thinking "$THINKING"
  fi
  ARGS=()
  [ -z "$MODEL" ] || ARGS+=(--model "$MODEL")
  [ -z "$THINKING" ] || ARGS+=(--thinking "$THINKING")
  ARGS+=(--note "recovered")

  "$FOREMAN_ROOT/bin/crew-launch.sh" "$ID" "$CWD" ${ARGS[@]+"${ARGS[@]}"}
  ;;
esac
