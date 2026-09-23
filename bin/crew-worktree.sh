#!/usr/bin/env bash
# crew-worktree.sh - an isolated git worktree per crew task.
# Usage: crew-worktree.sh add <project> <task-id> [--base <ref>]
#        crew-worktree.sh remove <task-id> [--force]
#
# <project> is a name under projects/ or an explicit path. The worktree lands in
# worktrees/<task-id> on a new branch crew/<task-id>, so two crew can touch one
# repository without colliding. Nothing is ever discarded: removal refuses a
# dirty worktree unless --force is passed.
set -eu

. "$(cd "$(dirname "$0")" && pwd)/foreman-lib.sh"

# A worktree is cut from a commit ($BASE, HEAD by default). Anything the project
# checkout has not committed is not in that commit, so the crew cannot see it.
# Say so before the launch reads as if the crew inherited the captain's desk.
worktree_warn_source_dirty() { # <project> <base>
  local proj=$1 base=$2 status tracked untracked note
  status=$(git -C "$proj" status --porcelain 2>/dev/null) || return 0
  [ -n "$status" ] || return 0
  tracked=$(printf '%s\n' "$status" | awk '$0 !~ /^\?\?/' | wc -l | tr -d ' ')
  untracked=$(printf '%s\n' "$status" | awk '$0 ~ /^\?\?/' | wc -l | tr -d ' ')
  note=
  [ "$tracked" -gt 0 ] && note="$tracked modified/staged"
  [ "$untracked" -gt 0 ] && note="${note:+$note, }$untracked untracked"
  printf 'warning: %s has uncommitted work (%s); the worktree cut from %s will not carry it\n' \
    "$proj" "$note" "$base" >&2
}

# The base a worktree is cut from is the project checkout's HEAD by default, and
# a checkout that is behind its upstream hands the crew an older commit without
# saying so. Refusing would break a checkout that is deliberately behind, so this
# warns; a base chosen with --base opts out, because the caller picked it on
# purpose. No upstream (no remote, no tracking branch, detached HEAD) is silent.
worktree_warn_source_stale() { # <project> <explicit-base-0-or-1>
  local proj=$1 upstream behind subjects
  [ "${2:-0}" = 0 ] || return 0
  upstream=$(git -C "$proj" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null) || return 0
  [ -n "$upstream" ] || return 0
  behind=$(git -C "$proj" rev-list --count "HEAD..$upstream" 2>/dev/null) || return 0
  case "$behind" in '' | *[!0-9]*) return 0 ;; esac
  [ "$behind" -gt 0 ] || return 0
  subjects=$(git -C "$proj" log --format=%s "HEAD..$upstream" 2>/dev/null | head -3 |
    awk 'NR > 1 { printf ", " } { printf "%s", $0 }')
  [ "$behind" -le 3 ] || subjects="$subjects, ..."
  printf 'warning: base HEAD in %s is %s commits behind %s: %s\n' \
    "$proj" "$behind" "$upstream" "$subjects" >&2
  printf 'warning: the crew would start from an older base; sync the checkout before spawning\n' >&2
}

ACTION=${1:-}
case "$ACTION" in
add)
  NAME=${2:-}
  ID=${3:-}
  BASE=HEAD
  EXPLICIT_BASE=0
  shift 3 || foreman_die "usage: crew-worktree.sh add <project> <task-id> [--base <ref>]"
  while [ $# -gt 0 ]; do
    case "$1" in
    --base)
      BASE=${2:-}
      EXPLICIT_BASE=1
      shift 2
      ;;
    *) foreman_die "unknown option: $1" ;;
    esac
  done

  foreman_valid_id "$ID" || foreman_die "task id must be a kebab-case slug: '${ID}'"
  PROJ=$(foreman_project_path "$NAME")
  [ -d "$PROJ" ] || foreman_die "no such project: $NAME (looked in $PROJ)"
  git -C "$PROJ" rev-parse --git-dir >/dev/null 2>&1 || foreman_die "not a git repository: $PROJ"
  git -C "$PROJ" rev-parse --verify --quiet "$BASE^{commit}" >/dev/null ||
    foreman_die "base '$BASE' does not resolve to a commit in $PROJ"

  WT="$FOREMAN_WORKTREES/$ID"
  [ ! -e "$WT" ] || foreman_die "worktree already exists: $WT"
  BRANCH="crew/$ID"
  if git -C "$PROJ" show-ref --verify --quiet "refs/heads/$BRANCH"; then
    foreman_die "branch $BRANCH already exists in $PROJ; pick another task id or delete the branch"
  fi

  worktree_warn_source_stale "$PROJ" "$EXPLICIT_BASE"

  mkdir -p "$FOREMAN_WORKTREES"
  git -C "$PROJ" worktree add -b "$BRANCH" "$WT" "$BASE" >/dev/null 2>&1 ||
    foreman_die "git worktree add failed for $PROJ"
  worktree_warn_source_dirty "$PROJ" "$BASE"
  printf '%s\n' "$WT"
  ;;
remove)
  ID=${2:-}
  FORCE=0
  shift 2 || foreman_die "usage: crew-worktree.sh remove <task-id> [--force]"
  [ "${1:-}" = "--force" ] && FORCE=1

  WT=""
  if [ -d "$(foreman_task_dir "$ID")" ]; then
    WT=$(foreman_meta_get "$ID" worktree)
  fi
  [ -n "$WT" ] || WT="$FOREMAN_WORKTREES/$ID"

  if [ ! -d "$WT" ]; then
    printf 'worktree %s is already gone\n' "$WT"
    exit 0
  fi

  PROJ=$(foreman_meta_get "$ID" project 2>/dev/null || true)
  if [ -z "$PROJ" ] || [ ! -d "$PROJ" ]; then
    PROJ=$(git -C "$WT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
    PROJ=${PROJ%/.git}
  fi
  [ -n "$PROJ" ] && [ -d "$PROJ" ] || foreman_die "cannot locate the owning repository for $WT"

  dirty=$(git -C "$WT" status --porcelain 2>/dev/null | head -1)
  if [ -n "$dirty" ] && [ "$FORCE" != 1 ]; then
    foreman_die "$WT has uncommitted changes; commit or discard them, or pass --force to remove it anyway"
  fi

  if [ "$FORCE" = 1 ]; then
    git -C "$PROJ" worktree remove --force "$WT" >/dev/null || foreman_die "git worktree remove failed"
  else
    git -C "$PROJ" worktree remove "$WT" >/dev/null || foreman_die "git worktree remove failed"
  fi
  printf 'removed %s\n' "$WT"
  ;;
*)
  foreman_die "usage: crew-worktree.sh add <project> <task-id> [--base <ref>] | remove <task-id> [--force]"
  ;;
esac
