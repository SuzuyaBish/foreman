#!/usr/bin/env bash
# foreman-lib.sh - shared paths, Herdr transport, and task records.
# Sourced by every foreman script. No side effects on source.

_FOREMAN_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FOREMAN_ROOT="${FOREMAN_ROOT:-$(cd "$_FOREMAN_LIB_DIR/.." && pwd)}"
FOREMAN_HOME="${FOREMAN_HOME:-$FOREMAN_ROOT/.foreman}"
FOREMAN_TASKS="$FOREMAN_HOME/tasks"
FOREMAN_BOARD="$FOREMAN_HOME/BOARD.md"
FOREMAN_SESSION="${FOREMAN_SESSION:-default}"

foreman_die() {
  printf 'foreman: %s\n' "$*" >&2
  exit 1
}

foreman_session() { printf '%s' "$FOREMAN_SESSION"; }

# Every Herdr call names its session. Ambient selection can silently address a
# different running server, so it is never relied on.
foreman_herdr() { herdr --session "$FOREMAN_SESSION" "$@"; }

foreman_need_herdr() {
  command -v herdr >/dev/null 2>&1 || foreman_die "herdr is not on PATH"
  command -v jq >/dev/null 2>&1 || foreman_die "jq is not on PATH"
}

# Task ids become tab labels, directory names, and CLI arguments. Allow only a
# bare kebab-case slug so nothing downstream has to quote for safety.
foreman_valid_id() {
  case "$1" in '' | *[!a-z0-9-]* | [!a-z0-9]*) return 1 ;; esac
  [ "${#1}" -le 32 ]
}

foreman_valid_state() {
  case "$1" in queued | working | blocked | done | failed | stopped | lost) return 0 ;; esac
  return 1
}

foreman_valid_key() {
  case "$1" in '' | *[!a-z_]*) return 1 ;; esac
}

foreman_task_dir() { printf '%s/%s' "$FOREMAN_TASKS" "$1"; }

foreman_require_task() {
  local dir
  [ -n "${1:-}" ] || foreman_die "no task id given"
  dir=$(foreman_task_dir "$1")
  [ -d "$dir" ] || foreman_die "no such crew task: $1"
  printf '%s' "$dir"
}

foreman_meta_get() { # <id> <key>
  local dir
  foreman_valid_key "$2" || foreman_die "bad meta key: $2"
  dir=$(foreman_require_task "$1") || return 1
  sed -n "s/^$2=//p" "$dir/meta" 2>/dev/null | head -1
}

foreman_meta_set() { # <id> <key> <value>
  local dir f tmp
  foreman_valid_key "$2" || foreman_die "bad meta key: $2"
  dir=$(foreman_require_task "$1") || return 1
  f="$dir/meta"
  tmp="$f.tmp.$$"
  {
    [ ! -f "$f" ] || grep -v "^$2=" "$f"
    printf '%s=%s\n' "$2" "$3"
  } >"$tmp" && mv "$tmp" "$f"
}

foreman_status_get() { # <id> <key>
  local dir
  foreman_valid_key "$2" || foreman_die "bad status key: $2"
  dir=$(foreman_require_task "$1") || return 1
  sed -n "s/^$2=//p" "$dir/status" 2>/dev/null | head -1
}

# The only writer of the status record. One line per field, atomically replaced
# so a reader never sees half a status.
foreman_status_set() { # <id> <state> [note]
  local dir tmp
  foreman_valid_state "$2" || foreman_die "bad state: $2"
  dir=$(foreman_require_task "$1") || return 1
  tmp="$dir/status.tmp.$$"
  {
    printf 'state=%s\n' "$2"
    printf 'at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'note=%s\n' "${3:-}"
  } >"$tmp" && mv "$tmp" "$dir/status"
}

# ISO-8601 UTC to epoch, GNU or BSD date.
foreman_epoch_of() { # <iso>
  date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null ||
    date -u -d "$1" +%s 2>/dev/null || printf ''
}

foreman_age_human() { # <id> -> "4m" | "?"
  local d
  d=$(foreman_age_secs "$1") || d=
  if [ -z "$d" ]; then
    printf '?'
    return
  fi
  if [ "$d" -lt 60 ]; then printf '%ss' "$d"
  elif [ "$d" -lt 3600 ]; then printf '%sm' "$((d / 60))"
  elif [ "$d" -lt 86400 ]; then printf '%sh' "$((d / 3600))"
  else printf '%sd' "$((d / 86400))"
  fi
}

# Seconds since the status was last written, or empty when unreadable.
foreman_age_secs() { # <id>
  local at then now
  at=$(foreman_status_get "$1" at)
  [ -n "$at" ] || return 1
  then=$(foreman_epoch_of "$at")
  [ -n "$then" ] || return 1
  now=$(date +%s)
  local d=$((now - then))
  [ "$d" -ge 0 ] || d=0
  printf '%s' "$d"
}

# Every task id on the board, one per line, newest first.
foreman_task_ids() {
  [ -d "$FOREMAN_TASKS" ] || return 0
  for d in "$FOREMAN_TASKS"/*/; do
    [ -d "$d" ] || continue
    basename "$d"
  done | sort
}

# The workspace new crew land in: the one this foreman is running in, so panes
# appear beside the captain. Outside Herdr, a dedicated labeled workspace is
# used and created on first need.
foreman_workspace() {
  # The ambient workspace is only inherited when we are addressing the session
  # we are actually running in. A workspace id from another session does not
  # exist there.
  if [ -n "${HERDR_WORKSPACE_ID:-}" ] && [ "${HERDR_SESSION:-default}" = "$FOREMAN_SESSION" ]; then
    printf '%s' "$HERDR_WORKSPACE_ID"
    return 0
  fi
  local ws
  ws=$(foreman_herdr workspace list 2>/dev/null |
    jq -r '.result.workspaces[]? | select(.label == "foreman") | .workspace_id' 2>/dev/null | head -1)
  if [ -z "$ws" ]; then
    mkdir -p "$FOREMAN_HOME"
    ws=$(foreman_herdr workspace create --cwd "$FOREMAN_HOME" --label foreman --no-focus 2>/dev/null |
      jq -r '.result.workspace.workspace_id // empty' 2>/dev/null)
  fi
  [ -n "$ws" ] || foreman_die "could not resolve or create a Herdr workspace in session '$FOREMAN_SESSION'"
  printf '%s' "$ws"
}

# Resolve "<session>:<pane>" back to its pane id, and confirm the pane still
# exists. Prints nothing and fails when it is gone.
foreman_pane_of() { # <id>
  local target
  target=$(foreman_meta_get "$1" pane)
  [ -n "$target" ] || return 1
  foreman_herdr pane get "${target#*:}" >/dev/null 2>&1 || return 1
  printf '%s' "${target#*:}"
}
