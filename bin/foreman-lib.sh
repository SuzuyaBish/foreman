#!/usr/bin/env bash
# foreman-lib.sh - shared paths, Herdr transport, and task records.
# Sourced by every foreman script. No side effects on source.

_FOREMAN_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FOREMAN_ROOT="${FOREMAN_ROOT:-$(cd "$_FOREMAN_LIB_DIR/.." && pwd)}"
FOREMAN_HOME="${FOREMAN_HOME:-$FOREMAN_ROOT/.foreman}"
FOREMAN_TASKS="$FOREMAN_HOME/tasks"
FOREMAN_BOARD="$FOREMAN_HOME/BOARD.md"
FOREMAN_CONFIG="$FOREMAN_HOME/config.json"
FOREMAN_PROJECTS="${FOREMAN_PROJECTS:-$FOREMAN_ROOT/projects}"
FOREMAN_WORKTREES="${FOREMAN_WORKTREES:-$FOREMAN_ROOT/worktrees}"
FOREMAN_SESSION="${FOREMAN_SESSION:-default}"

foreman_die() {
  printf 'foreman: %s\n' "$*" >&2
  exit 1
}

# Point the record paths at a home handed in by a caller. A crew's shell does not
# inherit FOREMAN_HOME, so its generated extension passes the foreman home
# positionally; the derived paths are cached when this file is sourced, so
# re-pointing FOREMAN_HOME alone would leave every reader looking at the old
# home. Use this, never a bare `FOREMAN_HOME=$1`.
foreman_use_home() { # <home>
  [ -n "${1:-}" ] || foreman_die "foreman_use_home needs a home"
  FOREMAN_HOME=$1
  FOREMAN_TASKS="$FOREMAN_HOME/tasks"
  FOREMAN_BOARD="$FOREMAN_HOME/BOARD.md"
  FOREMAN_CONFIG="$FOREMAN_HOME/config.json"
  export FOREMAN_HOME FOREMAN_TASKS FOREMAN_BOARD FOREMAN_CONFIG
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
# Character classes below are spelled out rather than written as ranges: under a
# UTF-8 collation `[a-z]` also matches `A` (and `é`), which would let a bad id or
# key through on exactly the hosts the foreman runs on.
foreman_valid_id() {
  case "$1" in '' | *[!abcdefghijklmnopqrstuvwxyz0123456789-]* | [!abcdefghijklmnopqrstuvwxyz0123456789]*) return 1 ;; esac
  [ "${#1}" -le 32 ]
}

foreman_valid_state() {
  case "$1" in queued | working | blocked | review | done | failed | stopped | lost) return 0 ;; esac
  return 1
}

foreman_valid_key() {
  case "$1" in '' | *[!abcdefghijklmnopqrstuvwxyz_]*) return 1 ;; esac
}

# --- session config -------------------------------------------------------
# Personal settings live in the runtime home, not in the committed tree.

foreman_config_get() { # <key>
  [ -f "$FOREMAN_CONFIG" ] || return 0
  jq -r --arg k "$1" 'if has($k) then (.[$k] | tostring) else empty end' \
    "$FOREMAN_CONFIG" 2>/dev/null | head -1
}

foreman_config_bool() { # <key> <default-0-or-1>
  case "$(foreman_config_get "$1")" in
  true | 1 | yes | on) printf '1' ;;
  false | 0 | no | off) printf '0' ;;
  *) printf '%s' "$2" ;;
  esac
}

# --- projects and worktrees ----------------------------------------------

# A project argument is either a name under projects/ or an explicit path.
foreman_project_path() { # <name-or-path>
  case "$1" in
  */*) printf '%s' "$1" ;;
  *) printf '%s/%s' "$FOREMAN_PROJECTS" "$1" ;;
  esac
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

# --- crew presentation: one workspace per crew member --------------------
#
# Herdr has no parent/child relationship between panes or agents: `agent list`
# carries parent_pane_id/parent_agent_id/depth fields, but nothing can set them
# and no CLI or socket method exposes one. What Herdr does offer is workspace
# ordering. So a crew member reads as a child of the foreman by *being* a
# workspace, created with a child glyph in its label and moved directly after the
# foreman's own workspace. The relationship lives in our own task records; it is
# never re-derived from a label pattern.

# The control socket for this session, or nothing when it cannot be resolved.
# `herdr session list` is authoritative; the ambient variable is the fallback.
foreman_herdr_socket() {
  local sock
  sock=$(foreman_herdr session list --json 2>/dev/null |
    jq -r --arg s "$FOREMAN_SESSION" '(.sessions // .)[]? | select(.name == $s) | .socket_path' 2>/dev/null |
    head -1)
  [ -n "$sock" ] || sock=${HERDR_SOCKET_PATH:-}
  printf '%s' "$sock"
}

# Move a workspace to a position in Herdr's list. Presentation only: every
# failure is the caller's to ignore, and the crew stays where Herdr put it.
# FOREMAN_HERDR_MOVER overrides the transport so a test can watch the request.
foreman_herdr_move() { # <workspace-id> <insert-index>
  local mover=${FOREMAN_HERDR_MOVER:-$FOREMAN_ROOT/bin/herdr-workspace-move.mjs} sock
  sock=$(foreman_herdr_socket)
  [ -n "$sock" ] || return 1
  case "$mover" in
  *.mjs | *.js)
    command -v node >/dev/null 2>&1 || return 1
    node "$mover" "$sock" "$1" "$2" >/dev/null 2>&1
    ;;
  *) "$mover" "$sock" "$1" "$2" >/dev/null 2>&1 ;;
  esac
}

# Workspace ids of live tasks that name <parent> as their parent workspace, one
# per line. This is the child set ordering is computed from.
foreman_workspace_children() { # <parent-workspace-id>
  local id dir parent ws
  [ -n "${1:-}" ] || return 0
  for id in $(foreman_task_ids); do
    dir=$(foreman_task_dir "$id")
    parent=$(sed -n 's/^parent_workspace=//p' "$dir/meta" 2>/dev/null | head -1)
    ws=$(sed -n 's/^workspace=//p' "$dir/meta" 2>/dev/null | head -1)
    [ "$parent" = "$1" ] && [ -n "$ws" ] && printf '%s\n' "$ws"
  done
}

# The 0-based index a just-created workspace should occupy: immediately after its
# parent, and past every sibling already sitting in that contiguous block. Prints
# nothing and fails when the parent is not in the list.
foreman_workspace_order_index() { # <parent-workspace-id> <new-workspace-id>
  local parent=$1 new=$2 list sibs
  list=$(foreman_herdr workspace list 2>/dev/null | jq -r '.result.workspaces[]? | .workspace_id' 2>/dev/null) || return 1
  [ -n "$list" ] || return 1
  sibs=$(foreman_workspace_children "$parent" | tr '\n' ' ')
  printf '%s\n' "$list" | awk -v parent="$parent" -v new="$new" -v sibs="$sibs" '
    BEGIN { n = split(sibs, S, " "); for (i = 1; i <= n; i++) if (S[i] != "") sib[S[i]] = 1 }
    { ids[NR] = $0; if ($0 == parent) p = NR }
    END {
      if (p == 0) exit 1
      idx = p + 1
      for (i = p + 1; i <= NR; i++) {
        if (ids[i] == new || (ids[i] in sib)) idx = i + 1
        else break
      }
      print idx - 1
    }'
}

# The workspace this foreman created for a task, or nothing. A task launched into
# the foreman's own workspace -- the flat fallback, or a record written before
# crew got workspaces of their own -- does not own one, and adopting or closing
# that would touch the captain's own workspace.
foreman_own_workspace() { # <id>
  local id=$1 ws parent
  ws=$(foreman_meta_get "$id" workspace)
  parent=$(foreman_meta_get "$id" parent_workspace)
  [ -n "$ws" ] || return 0
  [ -n "$parent" ] || return 0
  [ "$ws" != "$parent" ] || return 0
  printf '%s' "$ws"
}

# Retire the place a crew lived: the workspace this foreman created for it, or
# the tab it got in the flat fallback. Prints which one it closed.
foreman_close_home() { # <id> -> workspace | tab | none
  local id=$1 ws tab
  ws=$(foreman_own_workspace "$id")
  tab=$(foreman_meta_get "$id" tab)
  if [ -n "$ws" ]; then
    if foreman_herdr workspace close "$ws" >/dev/null 2>&1; then
      printf 'workspace'
      return 0
    fi
  fi
  if [ -n "$tab" ]; then
    foreman_herdr tab close "$tab" >/dev/null 2>&1 || true
    printf 'tab'
    return 0
  fi
  printf 'none'
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

# --- events: the single source of truth for what a crew member reported ------
#
# Append-only, tab separated: <iso> <verb> <key> <note>. The point of a log
# rather than a mutable field is that a keyed decision stays open until it is
# explicitly resolved, so a later unrelated append cannot bury it.

foreman_event_append() { # <id> <verb> [key] [note]
  local dir
  dir=$(foreman_require_task "$1") || return 1
  printf '%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$2" "${3:-}" "${4:-}" >>"$dir/events"
}

# Fold the log into "<state>\t<note>". One owner, so every reader agrees.
foreman_fold_events() { # <events-file>
  [ -f "$1" ] || {
    printf 'queued\t\n'
    return 0
  }
  awk -F'\t' '
    {
      verb = $2; key = $3; note = $4
      if (verb == "needs-decision") {
        if (key != "") { if (!(key in open)) order[++n] = key; open[key] = note }
        next
      }
      if (verb == "resolved") { if (key != "") delete open[key]; next }
      if (verb == "progress") { next }
      state = verb; stnote = note
    }
    END {
      if (state == "") state = "queued"
      if (state != "done" && state != "failed" && state != "review") {
        for (i = 1; i <= n; i++) {
          k = order[i]
          if (k in open) {
            state = "blocked"
            stnote = "[" k "] " open[k]
            break
          }
        }
      }
      printf "%s\t%s\n", state, stnote
    }
  ' "$1"
}

# Refresh the derived status cache from the log, preserving the report time.
foreman_status_sync() { # <id>
  local dir folded state note tmp
  dir=$(foreman_require_task "$1") || return 1
  folded=$(foreman_fold_events "$dir/events")
  state=${folded%%$'\t'*}
  note=${folded#*$'\t'}
  tmp="$dir/status.tmp.$$"
  {
    printf 'state=%s\n' "$state"
    printf 'at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'note=%s\n' "$note"
  } >"$tmp" && mv "$tmp" "$dir/status"
}

# Open decisions across the fleet: "<id>\t<key>\t<note>".
foreman_open_decisions() {
  local dir
  for id in $(foreman_task_ids); do
    dir=$(foreman_task_dir "$id")
    [ -f "$dir/events" ] || continue
    awk -F'\t' -v id="$id" '
      $2 == "needs-decision" && $3 != "" { if (!($3 in open)) order[++n] = $3; open[$3] = $4; next }
      $2 == "resolved" && $3 != "" { delete open[$3]; next }
      END {
        for (i = 1; i <= n; i++) {
          k = order[i]
          if (k in open) printf "%s\t%s\t%s\n", id, k, open[k]
        }
      }
    ' "$dir/events"
  done
}

# --- wake queue: durable, sequenced, acknowledged by sequence ---------------

foreman_queue_path() { printf '%s/.wake-queue' "$FOREMAN_HOME"; }
foreman_queue_ack_path() { printf '%s/.wake-acked' "$FOREMAN_HOME"; }

foreman_queue_append() { # <kind> <payload> -> prints the sequence
  local kind=$1 payload=$2 path lock n last=0
  path=$(foreman_queue_path)
  mkdir -p "$FOREMAN_HOME"
  lock="$FOREMAN_HOME/.wake-queue.lock"
  local tries=0
  while ! mkdir "$lock" 2>/dev/null; do
    tries=$((tries + 1))
    [ "$tries" -lt 50 ] || return 1
    sleep 0.1
  done
  if [ -f "$path" ]; then
    last=$(tail -n 1 "$path" | cut -f1)
    case "$last" in '' | *[!0-9]*) last=0 ;; esac
  fi
  n=$((last + 1))
  printf '%s\t%s\t%s\t%s\n' "$n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$kind" "$payload" >>"$path"
  rmdir "$lock" 2>/dev/null || true
  printf '%s' "$n"
}

foreman_queue_acked() { # -> highest acknowledged sequence (0 when none)
  local a
  a=$(cat "$(foreman_queue_ack_path)" 2>/dev/null || printf '0')
  case "$a" in '' | *[!0-9]*) a=0 ;; esac
  printf '%s' "$a"
}

foreman_queue_pending() { # -> rows after the ack cursor
  local path a
  path=$(foreman_queue_path)
  [ -f "$path" ] || return 0
  a=$(foreman_queue_acked)
  awk -F'\t' -v a="$a" '$1 + 0 > a' "$path"
}

foreman_queue_count() {
  local n
  n=$(foreman_queue_pending | wc -l | tr -d ' ')
  printf '%s' "$n"
}

foreman_queue_ack() { # <sequence>
  case "$1" in '' | *[!0-9]*) return 1 ;; esac
  printf '%s\n' "$1" >"$(foreman_queue_ack_path)"
}

# --- semantic busy state ----------------------------------------------------
# Written only by the generated per-crew extension through crew-busy-event.sh.
# A record whose gen does not match the armed sidecar is a stale incarnation and
# reads unknown, never idle.

foreman_busy_record() { printf '%s/busy-state' "$(foreman_task_dir "$1")"; }
foreman_busy_gen() { printf '%s/busy-gen' "$(foreman_task_dir "$1")"; }

foreman_busy_read() { # <id> -> "state<TAB>source"
  local dir rec gen
  dir=$(foreman_require_task "$1") || return 1
  rec="$dir/busy-state"
  gen=$(cat "$dir/busy-gen" 2>/dev/null || printf '')
  if [ ! -f "$rec" ] || [ -z "$gen" ]; then
    printf 'unknown\tmissing\n'
    return 0
  fi
  # The record is a single line of key=value tokens; parse it directly.
  local line
  line=$(head -n 1 "$rec")
  local gotstate="unknown" gotsource="malformed" gotgen=""
  for tok in $line; do
    case "$tok" in
    state=*) gotstate=${tok#state=} ;;
    source=*) gotsource=${tok#source=} ;;
    gen=*) gotgen=${tok#gen=} ;;
    esac
  done
  case "$gotstate" in busy | idle | unknown) ;; *) gotstate=unknown ;; esac
  if [ "$gotgen" != "$gen" ]; then
    printf 'unknown\tstale-gen\n'
    return 0
  fi
  printf '%s\t%s\n' "$gotstate" "$gotsource"
}
