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

# --- locks ------------------------------------------------------------------
#
# One writer at a time for a read-modify-write of a shared file. mkdir is atomic
# on every filesystem this runs on, and macOS has no flock. The holder's pid is
# written inside, so a waiter can tell a lock whose writer was killed from one
# that is merely busy, and break it instead of waiting on a corpse. Breaking goes
# through a second lock: two waiters that both see the same dead holder must not
# both remove it, or the second removes the lock the first has just re-taken.
# The wait is bounded (FOREMAN_LOCK_WAIT seconds) and the caller fails loudly
# when it runs out; a write is never silently dropped.
#
# There is no EXIT trap in here: a trap that removes a lock can fire in a process
# that never held it. Callers release explicitly on every path they can take.

foreman_path_age() { # <path> -> seconds since last modified (0 when unknown)
  local m
  m=$(stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || date +%s)
  printf '%s' "$(($(date +%s) - m))"
}

# A lock is stale when its recorded holder is gone. A lock with no pid yet is a
# writer caught between mkdir and writing it, which takes microseconds, so it is
# only stale once it is old.
foreman_lock_is_stale() { # <lock-dir>
  local pid=
  [ -d "$1" ] || return 1
  [ ! -f "$1/pid" ] || read -r pid <"$1/pid" 2>/dev/null || true
  case "$pid" in
  '' | *[!0-9]*) [ "$(foreman_path_age "$1")" -ge 5 ] ;;
  *) ! kill -0 "$pid" 2>/dev/null && ! ps -p "$pid" >/dev/null 2>&1 ;;
  esac
}

foreman_lock_break_stale() { # <lock-dir>
  local brk="$1.break"
  foreman_lock_is_stale "$1" || return 0
  if ! mkdir "$brk" 2>/dev/null; then
    # A breaker is killed only in the microseconds it holds this; clear an old one.
    [ "$(foreman_path_age "$brk")" -lt 10 ] || rmdir "$brk" 2>/dev/null || true
    return 0
  fi
  # Re-check under the break lock: only a dead holder or a breaker removes the
  # lock, and this is the only breaker, so what is seen now cannot change.
  if foreman_lock_is_stale "$1"; then
    rm -f "$1/pid"
    rmdir "$1" 2>/dev/null || true
  fi
  rmdir "$brk" 2>/dev/null || true
}

foreman_lock_acquire() { # <lock-dir> -> 0 held, 1 timed out
  local tries=0 max
  max=$((${FOREMAN_LOCK_WAIT:-10} * 20))
  while :; do
    if mkdir "$1" 2>/dev/null; then
      printf '%s\n' "$$" >"$1/pid"
      return 0
    fi
    foreman_lock_break_stale "$1"
    tries=$((tries + 1))
    [ "$tries" -lt "$max" ] || return 1
    sleep 0.05
  done
}

foreman_lock_release() { # <lock-dir>
  rm -f "$1/pid"
  rmdir "$1" 2>/dev/null || true
}

# Why a lock could not be taken, for the caller's die message.
foreman_lock_holder() { # <lock-dir>
  local pid=
  [ ! -f "$1/pid" ] || read -r pid <"$1/pid" 2>/dev/null || true
  printf 'held by pid %s; remove %s if that process is not a foreman writer' "${pid:-?}" "$1"
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

# --- the captain's pi packages ----------------------------------------------
#
# A crew runs pi with discovery off (`-ne`, see crew-launch.sh), and that also
# drops every package the captain installed globally - including the ones that
# provide model providers, so a crew model such as claude-bridge/... cannot
# resolve. These helpers read the packages from the captain's global pi settings
# and name each one's installed directory, so the launcher can hand them back to
# pi with `-e`. Only the global (user) list is read: project-local packages and
# extensions stay excluded, which is the point of `-ne`.
#
# An installed directory is passed rather than the `npm:` source, because pi
# treats an `-e npm:...` as a temporary package and runs an npm install for it on
# every launch. A package that is not installed is skipped, never installed here.
# Nothing in this section may fail a launch: a missing or unreadable settings
# file simply yields no packages.

foreman_pi_agent_dir() {
  local d=${PI_CODING_AGENT_DIR:-}
  if [ -z "$d" ]; then
    printf '%s/.pi/agent' "$HOME"
    return 0
  fi
  case "$d" in
  "~") d=$HOME ;;
  \~/*) d="$HOME/${d#\~/}" ;;
  esac
  printf '%s' "$d"
}

# Where pi installs a user-scope package source. Mirrors pi's package manager:
# npm under <agent>/npm/node_modules/<name>, git under <agent>/git/<host>/<path>,
# and a local path relative to the agent directory. Prints nothing for a source
# it does not recognise.
foreman_pi_package_root() { # <agent-dir> <source>
  local agent=$1 src=$2 spec rest host path
  case "$src" in
  npm:*)
    spec=${src#npm:}
    case "$spec" in
    @*/*)
      rest=${spec#*/}
      printf '%s/npm/node_modules/%s/%s' "$agent" "${spec%%/*}" "${rest%%@*}"
      ;;
    ?*) printf '%s/npm/node_modules/%s' "$agent" "${spec%%@*}" ;;
    esac
    ;;
  git:* | http:* | https:* | ssh:*)
    rest=${src#git:}
    rest=${rest#*://}
    case "$rest" in git@*:*)
      rest=${rest#git@}
      rest="${rest%%:*}/${rest#*:}"
      ;;
    esac
    rest=${rest%%#*}
    host=${rest%%/*}
    host=${host##*@}
    path=${rest#*/}
    path=${path%%@*}
    path=${path%/}
    path=${path%.git}
    [ -z "$host" ] || [ -z "$path" ] || [ "$path" = "$rest" ] ||
      printf '%s/git/%s/%s' "$agent" "$host" "$path"
    ;;
  github:* | file:*) ;;
  "~") printf '%s' "$HOME" ;;
  \~/*) printf '%s/%s' "$HOME" "${src#\~/}" ;;
  /*) printf '%s' "$src" ;;
  ?*) printf '%s/%s' "$agent" "${src#./}" ;;
  esac
}

# The extension paths of the captain's global pi packages, one per line, in the
# order the settings list them. A plain string entry loads its whole package. An
# object entry is a filtered package: `extensions: []` or `autoload: false` with
# no extension list turns its extensions off, so it is skipped; a list of plain
# paths is passed file by file; a list with glob or +/-/! patterns cannot be said
# on the command line, so the whole package is passed instead of silently losing
# a provider.
foreman_pi_package_exts() {
  local agent settings kind src rel root p seen=$'\n'
  agent=$(foreman_pi_agent_dir)
  settings="$agent/settings.json"
  [ -f "$settings" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  while IFS=$'\t' read -r kind src rel; do
    [ -n "$src" ] || continue
    root=$(foreman_pi_package_root "$agent" "$src")
    [ -n "$root" ] || continue
    case "$kind" in
    file) p="$root/${rel#./}" ;;
    *) p=$root ;;
    esac
    [ -e "$p" ] || continue
    case "$seen" in *$'\n'"$p"$'\n'*) continue ;; esac
    seen="$seen$p"$'\n'
    printf '%s\n' "$p"
  done <<EOF
$(jq -r '
    (.packages // []) | if type == "array" then .[] else empty end
    | if type == "string" then ["pkg", ., ""]
      elif type == "object" and (.source | type) == "string" then
        .source as $s
        | if has("extensions") then
            .extensions as $e
            | if ($e | type) != "array" then ["pkg", $s, ""]
              elif ($e | length) == 0 then empty
              elif all($e[]; type == "string" and (test("^[!+-]|[*?\\[{]") | not))
              then ($e[] | ["file", $s, .])
              else ["pkg", $s, ""] end
          elif .autoload == false then empty
          else ["pkg", $s, ""] end
      else empty end
    | @tsv' "$settings" 2>/dev/null)
EOF
  return 0
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

# Read-modify-write under the task's meta lock, so two fields set at once (the
# pr from a report, a pane id from a relaunch) cannot each drop the other.
foreman_meta_set() { # <id> <key> <value>
  local dir f tmp lock rc=0
  foreman_valid_key "$2" || foreman_die "bad meta key: $2"
  dir=$(foreman_require_task "$1") || return 1
  f="$dir/meta"
  tmp="$f.tmp.$$"
  lock="$dir/.meta.lock"
  foreman_lock_acquire "$lock" || foreman_die "could not lock $f: $(foreman_lock_holder "$lock")"
  {
    [ ! -f "$f" ] || grep -v "^$2=" "$f"
    printf '%s=%s\n' "$2" "$3"
  } >"$tmp" && mv "$tmp" "$f" || rc=1
  rm -f "$tmp"
  foreman_lock_release "$lock"
  return "$rc"
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

# --- merge refusals ---------------------------------------------------------
#
# `gh pr merge` can refuse for a reason GitHub itself calls temporary: the base
# branch moved between the mergeability check and the merge, so GitHub answers
# "Base branch was modified. Review and try the merge again." The crew's branch
# and its open pull request are untouched, so the merge command retries in place
# rather than waking the crew to report review again. Only this signature is
# transient; a conflict, a protected branch, a failing required check, a closed
# pull request and an auth failure all stay real failures.
foreman_merge_refusal_transient() { # <reason>
  printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | grep -q 'base branch was modified'
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

# --- todo lookup and announcements ------------------------------------------
#
# The todo list is the durable plan (bin/crew-todo.sh). A crew linked to an item
# is announced by that item's number and title, not by its own id, so a wake
# says which piece of work it is. One resolver here, so the watcher and any other
# announcer never re-read the file by hand.

foreman_todo_item_of_crew() { # <crew-id> -> "<seq>\t<title>", or nothing
  local todo="$FOREMAN_HOME/todo.tsv"
  [ -n "${1:-}" ] && [ "$1" != "-" ] || return 0
  [ -f "$todo" ] || return 0
  # The last row naming the crew wins, so a reassigned item is the current one.
  awk -F'\t' -v c="$1" '$3 == c { seq = $1; title = $4 } END {
    if (seq != "") printf "%s\t%s", seq, title
  }' "$todo"
}

# Shorten text to at most <max> characters, ending in an ellipsis, so an
# announcement stays one bounded line without dropping what identifies it.
foreman_ellipsize() { # <max> <text>
  local max=${1:-} text=${2:-}
  case "$max" in '' | *[!0-9]*) printf '%s' "$text"; return 0 ;; esac
  if [ "${#text}" -le "$max" ]; then
    printf '%s' "$text"
  else
    printf '%s…' "${text:0:$((max - 1))}"
  fi
}

# How a crew's state change is announced in a wake row. A review is a delivery,
# so it carries the work's identity — the linked todo item's number and title,
# then the pull request — instead of only the crew id. Without a linked item it
# falls back to "<id> review", exactly as it always read.
foreman_transition_payload() { # <id> <state>
  local id=$1 state=$2 info seq title pr
  if [ "$state" != review ]; then
    printf '%s %s' "$id" "$state"
    return 0
  fi
  info=$(foreman_todo_item_of_crew "$id")
  if [ -z "$info" ]; then
    printf '%s review' "$id"
    return 0
  fi
  seq=${info%%$'\t'*}
  title=${info#*$'\t'}
  pr=$(foreman_meta_get "$id" pr 2>/dev/null) || pr=
  title=$(foreman_ellipsize 80 "$title")
  if [ -n "$pr" ]; then
    printf '#%s %s — PR ready: %s' "$seq" "$title" "$pr"
  else
    printf '#%s %s — PR ready' "$seq" "$title"
  fi
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
