#!/usr/bin/env bash
# crew-todo.sh - the durable project todo list.
#
# Usage: crew-todo.sh add [--note <text>] [--project <scope>] <text...>
#        crew-todo.sh note <seq> <text...>
#        crew-todo.sh list [--all|--open] [--project <scope>] [--no-notes]
#        crew-todo.sh start <seq> <crew-id>
#        crew-todo.sh done <seq>
#        crew-todo.sh open <seq>
#        crew-todo.sh drop <seq>
#        crew-todo.sh focus [<scope>|--clear]
#        crew-todo.sh sync
#        crew-todo.sh summary [--all|--project <scope>]
#
# The list outlives every session. A new foreman session reads it and knows what
# is queued, what is in flight, and what finished — rather than reconstructing
# that from memory, which is exactly what a restart destroys.
#
# Rows are tab separated: <seq> <status> <crew-id-or-dash> <text> <note> <scope>
# Status is the INTENT (open, active, done, dropped). The crew's own state is
# read live and shown beside it, so a row never silently disagrees with reality.
# `note` is optional context for one item (`-` when absent); it is kept out of
# the item text so the board stays one line per item.
#
# SCOPE is the project an item belongs to, or `foreman` for the harness itself.
# One harness serves many projects, so an unscoped list would let the harness's
# own backlog crowd out the project the captain is actually paying for. The
# board therefore reads one scope at a time: `list` shows the scope in focus,
# `--all` shows every scope grouped. The scope in focus is the one set by
# `focus`, else the project of the newest crew (the work you were last doing),
# else `foreman`. Focus is per session, so two sessions can watch two projects.
set -eu

. "$(cd "$(dirname "$0")" && pwd)/foreman-lib.sh"

TODO="$FOREMAN_HOME/todo.tsv"

todo_init() {
  mkdir -p "$FOREMAN_HOME"
  [ -f "$TODO" ] || : >"$TODO"
}

# Tab is the field separator and newlines end a row, so nothing user-supplied
# may contain either.
todo_sanitize() { printf '%s' "$1" | tr '\t\n' '  '; }

# --- scope ------------------------------------------------------------------

todo_scope_sane() { # <scope>
  case "$1" in '' | *[!A-Za-z0-9._-]*) return 1 ;; esac
  [ "$1" != "-" ]
}

todo_project_of_crew() { # <crew-id> -> scope, or nothing
  local proj
  proj=$(sed -n 's/^project=//p' "$FOREMAN_TASKS/$1/meta" 2>/dev/null | head -n 1)
  [ -n "$proj" ] || return 0
  printf '%s' "$(basename "$proj")"
}

todo_focus_file() { printf '%s' "$FOREMAN_HOME/focus.${FOREMAN_SESSION:-default}"; }

todo_scope_explicit() { # the focus the captain set, or nothing
  local f
  f=$(todo_focus_file)
  [ -f "$f" ] || return 0
  head -n 1 "$f" 2>/dev/null | tr -d ' \t\r\n'
}

todo_scope_newest() { # the project of the newest crew, or nothing
  local dir id at best='' best_at=''
  [ -d "$FOREMAN_TASKS" ] || return 0
  for dir in "$FOREMAN_TASKS"/*/; do
    [ -d "$dir" ] || continue
    id=$(basename "$dir")
    at=$(sed -n 's/^at=//p' "$dir/status" 2>/dev/null | head -n 1)
    [ -n "$at" ] || at=$(sed -n 's/^created=//p' "$dir/meta" 2>/dev/null | head -n 1)
    if [ -z "$best_at" ] || [ "$at" \> "$best_at" ]; then
      best_at=$at
      best=$id
    fi
  done
  [ -n "$best" ] || return 0
  todo_project_of_crew "$best"
}

todo_scope() { # the scope the board reads now
  local s
  s=$(todo_scope_explicit)
  if [ -z "$s" ]; then s=$(todo_scope_newest); fi
  if [ -z "$s" ]; then s=foreman; fi
  printf '%s' "$s"
}

todo_lock() {
  local lock="$FOREMAN_HOME/.todo.lock" tries=0
  while ! mkdir "$lock" 2>/dev/null; do
    tries=$((tries + 1))
    [ "$tries" -lt 50 ] || foreman_die "todo list is locked"
    sleep 0.1
  done
  printf '%s' "$lock"
}

todo_next_seq() {
  local max=0 n
  while IFS=$'\t' read -r n _rest; do
    case "$n" in '' | *[!0-9]*) continue ;; esac
    [ "$n" -gt "$max" ] && max=$n
  done <"$TODO"
  printf '%s' "$((max + 1))"
}

todo_note_of() { # <seq>
  awk -F'\t' -v s="$1" '$1 == s { print ($5 == "" ? "-" : $5) }' "$TODO"
}

todo_valid_seq() {  case "${1:-}" in '' | *[!0-9]*) return 1 ;; esac
  awk -F'\t' -v s="$1" '$1 == s { found = 1 } END { exit found ? 0 : 1 }' "$TODO"
}

todo_update() { # <seq> <status> <crew> [<scope>]
  local lock tmp
  lock=$(todo_lock)
  tmp="$TODO.tmp.$$"
  awk -F'\t' -v s="$1" -v st="$2" -v c="$3" -v sc="${4:-}" '
    BEGIN { OFS = "\t" }
    $1 == s { $2 = st; $3 = c; if (sc != "") $6 = sc }
    { print }
  ' "$TODO" >"$tmp"
  mv "$tmp" "$TODO"
  rmdir "$lock" 2>/dev/null || true
}

# Read the crew's live state for a linked row, or "-" when there is none.
todo_crew_state() { # <crew-id>
  [ -n "$1" ] && [ "$1" != "-" ] || {
    printf '-'
    return
  }
  if [ ! -d "$(foreman_task_dir "$1")" ]; then
    printf 'gone'
    return
  fi
  foreman_status_get "$1" state
}

# Did this crew ever report `done`? Its live state is folded from the events log
# and a later stop, pane death, or lost-endpoint sweep overwrites it with
# `stopped`/`failed`, which is correct for the process but wrong for the work:
# the append-only log still carries the delivery. `done` is terminal for the row
# (see the sync comment below), so a delivered item is never reopened just
# because the crew that delivered it later stopped.
todo_crew_reached_done() { # <crew-id>
  local events
  events="$(foreman_task_dir "$1")/events"
  [ -f "$events" ] || return 1
  awk -F'\t' '$2 == "done" { found = 1 } END { exit found ? 0 : 1 }' "$events"
}

ACTION=${1:-list}
case "$ACTION" in
add)
  if [ $# -ge 1 ]; then shift; fi
  NOTE=-
  SCOPE=""
  PARTS=()
  while [ $# -gt 0 ]; do
    case "$1" in
    --note)
      [ $# -ge 2 ] || foreman_die "--note requires a value"
      NOTE=$(todo_sanitize "$2")
      shift 2
      ;;
    --project)
      [ $# -ge 2 ] || foreman_die "--project requires a name"
      todo_scope_sane "$2" || foreman_die "bad project: $2 (letters, digits, . _ - only)"
      SCOPE=$2
      shift 2
      ;;
    *)
      PARTS+=("$1")
      shift
      ;;
    esac
  done
  TEXT=$(todo_sanitize "${PARTS[*]-}")
  [ -n "$TEXT" ] || foreman_die "usage: crew-todo.sh add [--note <text>] [--project <scope>] <text...>"
  todo_init
  # No explicit project means the work belongs to whatever is in focus. The
  # scope is written down at add time, so a later focus change never silently
  # moves history into another project.
  [ -n "$SCOPE" ] || SCOPE=$(todo_scope)
  lock=$(todo_lock)
  seq=$(todo_next_seq)
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$seq" open - "$TEXT" "$NOTE" "$SCOPE" >>"$TODO"
  rmdir "$lock" 2>/dev/null || true
  printf 'added #%s (%s)\n' "$seq" "$SCOPE"
  ;;
note)
  SEQ=${2:-}
  if [ $# -ge 2 ]; then shift 2; else set --; fi
  todo_init
  todo_valid_seq "$SEQ" || foreman_die "no todo item #${SEQ:-<none>}"
  NOTE=$(todo_sanitize "${*-}")
  [ -n "$NOTE" ] || foreman_die "usage: crew-todo.sh note <seq> <text...>"
  lock=$(todo_lock)
  tmp="$TODO.tmp.$$"
  awk -F'\t' -v s="$SEQ" -v n="$NOTE" '
    BEGIN { OFS = "\t" }
    { if (NF < 5) $5 = "-"; if ($1 == s) $5 = n; print }
  ' "$TODO" >"$tmp"
  mv "$tmp" "$TODO"
  rmdir "$lock" 2>/dev/null || true
  printf 'noted #%s\n' "$SEQ"
  ;;
start)
  SEQ=${2:-}
  CREW=${3:-}
  todo_init
  todo_valid_seq "$SEQ" || foreman_die "no todo item #${SEQ:-<none>}"
  [ -n "$CREW" ] || foreman_die "usage: crew-todo.sh start <seq> <crew-id>"
  # A crew is placed against a project, so linking the work to it settles the
  # scope too: project work cannot be done by a crew standing somewhere else.
  todo_update "$SEQ" active "$CREW" "$(todo_project_of_crew "$CREW")"
  printf '#%s active on crew %s\n' "$SEQ" "$CREW"
  ;;
done | open | drop)
  SEQ=${2:-}
  todo_init
  todo_valid_seq "$SEQ" || foreman_die "no todo item #${SEQ:-<none>}"
  case "$ACTION" in
  done) STATUS=done ;;
  open) STATUS=open ;;
  drop) STATUS=dropped ;;
  esac
  lock=$(todo_lock)
  tmp="$TODO.tmp.$$"
  awk -F'\t' -v s="$SEQ" -v st="$STATUS" -v c="-" '
    BEGIN { OFS = "\t" }
    { if (NF < 5) $5 = "-"; if ($1 == s) { $2 = st; $3 = (st == "done" || st == "dropped") ? "-" : c }; print }
  ' "$TODO" >"$tmp"
  mv "$tmp" "$TODO"
  rmdir "$lock" 2>/dev/null || true
  printf '#%s %s\n' "$SEQ" "$STATUS"
  ;;
focus)
  todo_init
  SCOPE=${2:-}
  case "$SCOPE" in
  '') todo_scope; printf '\n' ;;
  --clear)
    rm -f "$(todo_focus_file)"
    printf 'focus cleared (now %s)\n' "$(todo_scope)"
    ;;
  *)
    todo_scope_sane "$SCOPE" || foreman_die "bad scope: $SCOPE (letters, digits, . _ - only)"
    printf '%s\n' "$SCOPE" >"$(todo_focus_file)"
    printf 'focus %s\n' "$SCOPE"
    ;;
  esac
  ;;
sync)
  todo_init
  lock=$(todo_lock)
  tmp="$TODO.tmp.$$"
  while IFS=$'\t' read -r seq status crew text note scope; do
    [ -n "$seq" ] || continue
    [ -n "$note" ] || note=-
    # Rows written before scopes existed get theirs from the crew they are
    # linked to, so an upgrade does not silently file project work under
    # `foreman`. An explicit scope is never rewritten.
    [ -n "$scope" ] || scope=$(todo_project_of_crew "$crew")
    [ -n "$scope" ] || scope=foreman
    # Any row still linked to a crew follows that crew, whatever the captain did
    # in between: a reopen after a failed crew must still settle when a relaunch
    # succeeds, and a manual `open` of running work is not a way to detach it.
    # `done` and `dropped` are terminal for the row and are never resurrected.
    #
    # The live state alone is not enough to follow a crew. Stopping a finished
    # crew, killing its pane, or sweeping a lost endpoint appends `stopped` or
    # `failed` over a state that had already reached `done`, and a mapping that
    # read only the current state would reopen delivered work. `done` is terminal
    # in the append-only log too, so a row whose crew ever reported it stays done;
    # only a crew that never delivered reopens when its process dies.
    if [ -n "$crew" ] && [ "$crew" != "-" ] && [ "$status" != done ] && [ "$status" != dropped ]; then
      cs=$(todo_crew_state "$crew")
      case "$cs" in
      done) status=done ;;
      working | review | blocked | queued) status=active ;;
      failed | lost | stopped | gone)
        if todo_crew_reached_done "$crew"; then
          status=done
        else
          status=open
        fi
        ;;
      esac
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$seq" "$status" "$crew" "$text" "$note" "$scope"
  done <"$TODO" >"$tmp"
  mv "$tmp" "$TODO"
  rmdir "$lock" 2>/dev/null || true
  ;;
summary)
  SCOPE=""
  ALL=0
  shift || true
  while [ $# -gt 0 ]; do
    case "$1" in
    --all) ALL=1 ;;
    --project)
      [ $# -ge 2 ] || foreman_die "--project requires a name"
      todo_scope_sane "$2" || foreman_die "bad project: $2 (letters, digits, . _ - only)"
      SCOPE=$2
      shift
      ;;
    *) foreman_die "unknown summary option: $1" ;;
    esac
    shift
  done
  [ "$ALL" -eq 1 ] || [ -n "$SCOPE" ] || SCOPE=$(todo_scope)
  # No todo_init here: the digest reads this line at session start and reading
  # must not create files.
  [ -f "$TODO" ] || TODO=/dev/null
  awk -F'\t' -v scope="$SCOPE" -v all="$ALL" '
    function line(s,   id) {
      id = s ": "
      printf "%s%d item%s (%d open, %d active, %d done)", id, total[s], (total[s] == 1 ? "" : "s"), o[s], a[s], d[s]
    }
    {
      s = ($6 == "" ? "foreman" : $6)
      total[s]++
      if ($2 == "open") o[s]++
      else if ($2 == "active") a[s]++
      else if ($2 == "done") d[s]++
      if (!(s in seen)) { seen[s] = 1; gn++; names[gn] = s }
    }
    END {
      if (all == 1) {
        for (g = 1; g <= gn; g++) { n += total[names[g]]; O += o[names[g]]; A += a[names[g]]; D += d[names[g]] }
        printf "all scopes: %d items (%d open, %d active, %d done)\n", n, O, A, D
      } else {
        line(scope)
        tail = ""
        for (g = 1; g <= gn; g++) {
          s = names[g]
          if (s == scope || o[s] == 0) continue
          tail = tail sprintf("%s%s %d open", (tail == "" ? "" : ", "), s, o[s])
        }
        if (tail != "") printf " · also %s", tail
        printf "\n"
      }
    }
  ' "$TODO"
  ;;
list)
  todo_init
  FILTER=all
  NOTES=1
  SCOPE=""
  shift || true
  while [ $# -gt 0 ]; do
    case "$1" in
    --all) SCOPE="*" ;;
    --open) FILTER=open ;;
    --no-notes) NOTES=0 ;;
    --project)
      [ $# -ge 2 ] || foreman_die "--project requires a name"
      todo_scope_sane "$2" || foreman_die "bad project: $2 (letters, digits, . _ - only)"
      SCOPE=$2
      shift
      ;;
    *) foreman_die "unknown list option: $1" ;;
    esac
    shift
  done
  FOCUS=$(todo_scope)
  [ -n "$SCOPE" ] || SCOPE=$FOCUS
  awk -F'\t' -v filter="$FILTER" -v notes="$NOTES" -v tasks="$FOREMAN_TASKS" \
    -v scope="$SCOPE" -v focus="$FOCUS" '
    function crewstate(id,   f, line, st) {
      if (id == "" || id == "-") return "-"
      f = tasks "/" id "/status"
      if ((getline line < f) <= 0) return "gone"
      close(f)
      if (line ~ /^state=/) { st = line; sub(/^state=/, "", st); return st }
      return "?"
    }
    function group(s,   i, cs, label) {
      if (scope == "*") printf "\n%s\n", s
      for (i = 1; i <= n; i++) {
        if (sp[i] != s) continue
        cs = (st[i] == "active") ? crewstate(cr[i]) : "-"
        label = st[i]
        if (st[i] == "active" && cs != "-") label = "active/" cs
        printf "%-4s %-9s %-11s %s\n", sq[i], label, cr[i], tx[i]
        if (notes == 1 && nt[i] != "" && nt[i] != "-") printf "%-26s ↳ %s\n", "", nt[i]
      }
    }
    function tail_of(   g, s, t) {
      for (g = 1; g <= an; g++) {
        s = allorder[g]
        if (s == scope || open[s] == 0) continue
        t = t sprintf("%s%s %d open", (t == "" ? "" : ", "), s, open[s])
      }
      return t
    }
    BEGIN { printf "%-4s %-9s %-11s %s\n", "#", "STATUS", "CREW", "ITEM" }
    {
      s0 = ($6 == "" ? "foreman" : $6)
      if ($2 == "open") open[s0]++
      if (!(s0 in allseen)) { allseen[s0] = 1; an++; allorder[an] = s0 }
      if (scope != "*" && s0 != scope) next
      if ($2 == "dropped" && filter != "all") next
      if (filter == "open" && $2 != "open" && $2 != "active") next
      n++
      sq[n] = $1; st[n] = $2; cr[n] = $3; tx[n] = $4; nt[n] = $5; sp[n] = s0
      if (!(s0 in seen)) { seen[s0] = 1; gn++; order[gn] = s0 }
    }
    END {
      if (n) {
        if (focus != "" && focus != "*" && (focus in seen)) group(focus)
        for (g = 1; g <= gn; g++) if (order[g] != focus) group(order[g])
      } else {
        printf "  (nothing in %s)\n", (scope == "*" ? "any scope" : scope)
      }
      if (scope != "*") {
        # Scoping must never hide queued work silently: say what is elsewhere.
        t = tail_of()
        if (t != "") printf "\n  open elsewhere: %s (crew-todo.sh list --all)\n", t
      }
    }
  ' "$TODO"
  ;;
*)
  foreman_die "usage: crew-todo.sh add|note|list|start|done|open|drop|sync|summary"
  ;;
esac
