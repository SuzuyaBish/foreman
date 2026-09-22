#!/usr/bin/env bash
# crew-projects.sh - the projects the foreman can put crew to work in.
# Usage: crew-projects.sh [name-filter]
# One line per project: name, type, and whether it has uncommitted work.
set -eu

. "$(cd "$(dirname "$0")" && pwd)/foreman-lib.sh"

FILTER=${1:-}
mkdir -p "$FOREMAN_PROJECTS"

found=0
for d in "$FOREMAN_PROJECTS"/*/; do
  [ -d "$d" ] || continue
  name=$(basename "$d")
  case "$name" in .*) continue ;; esac
  case "$name" in *"$FILTER"*) ;; *) continue ;; esac
  found=$((found + 1))
  if [ -d "$d/.git" ] || git -C "$d" rev-parse --git-dir >/dev/null 2>&1; then
    dirty=$(git -C "$d" status --porcelain 2>/dev/null | head -1)
    if [ -n "$dirty" ]; then
      printf '%-28s git   (uncommitted changes)\n' "$name"
    else
      printf '%-28s git\n' "$name"
    fi
  else
    printf '%-28s plain (not a git repository; no worktree isolation)\n' "$name"
  fi
done

if [ "$found" -eq 0 ]; then
  if [ -n "$FILTER" ]; then
    printf 'no project matching "%s"\n' "$FILTER"
  else
    printf 'no projects yet — clone one into %s\n' "$FOREMAN_PROJECTS"
  fi
fi
