#!/usr/bin/env bash
# crew-todo.sh - the durable project todo list.
#
# Usage: crew-todo.sh add [--note <text>] <text...>
#        crew-todo.sh note <seq> <text...>
#        crew-todo.sh list [--all|--open] [--no-notes]
#        crew-todo.sh start <seq> <crew-id>
#        crew-todo.sh done <seq>
#        crew-todo.sh open <seq>
#        crew-todo.sh drop <seq>
#        crew-todo.sh sync
#        crew-todo.sh summary
#
# The list outlives every session. A new foreman session reads it and knows what
# is queued, what is in flight, and what finished — rather than reconstructing
# that from memory, which is exactly what a restart destroys.
#
# Rows are tab separated: <seq> <status> <crew-id-or-dash> <text> <note>
# Status is the INTENT (open, active, done, dropped). The crew's own state is
# read live and shown beside it, so a row never silently disagrees with reality.
# `note` is optional context for one item (`-` when absent); it is kept out of
# the item text so the board stays one line per item.
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

todo_update() { # <seq> <status> <crew>
  local lock tmp
  lock=$(todo_lock)
  tmp="$TODO.tmp.$$"
  awk -F'\t' -v s="$1" -v st="$2" -v c="$3" '
    BEGIN { OFS = "\t" }
    $1 == s { $2 = st; $3 = c }
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

ACTION=${1:-list}
case "$ACTION" in
add)
  if [ $# -ge 1 ]; then shift; fi
  NOTE=-
  PARTS=()
  while [ $# -gt 0 ]; do
    case "$1" in
    --note)
      [ $# -ge 2 ] || foreman_die "--note requires a value"
      NOTE=$(todo_sanitize "$2")
      shift 2
      ;;
    *)
      PARTS+=("$1")
      shift
      ;;
    esac
  done
  TEXT=$(todo_sanitize "${PARTS[*]-}")
  [ -n "$TEXT" ] || foreman_die "usage: crew-todo.sh add [--note <text>] <text...>"
  todo_init
  lock=$(todo_lock)
  seq=$(todo_next_seq)
  printf '%s\t%s\t%s\t%s\t%s\n' "$seq" open - "$TEXT" "$NOTE" >>"$TODO"
  rmdir "$lock" 2>/dev/null || true
  printf 'added #%s\n' "$seq"
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
  todo_update "$SEQ" active "$CREW"
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
sync)
  todo_init
  lock=$(todo_lock)
  tmp="$TODO.tmp.$$"
  while IFS=$'\t' read -r seq status crew text note; do
    [ -n "$seq" ] || continue
    [ -n "$note" ] || note=-
    # Any row still linked to a crew follows that crew, whatever the captain did
    # in between: a reopen after a failed crew must still settle when a relaunch
    # succeeds, and a manual `open` of running work is not a way to detach it.
    # `done` and `dropped` are terminal for the row and are never resurrected.
    if [ -n "$crew" ] && [ "$crew" != "-" ] && [ "$status" != done ] && [ "$status" != dropped ]; then
      cs=$(todo_crew_state "$crew")
      case "$cs" in
      done) status=done ;;
      working | review | blocked | queued) status=active ;;
      failed | lost | stopped | gone) status=open ;;
      esac
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$seq" "$status" "$crew" "$text" "$note"
  done <"$TODO" >"$tmp"
  mv "$tmp" "$TODO"
  rmdir "$lock" 2>/dev/null || true
  ;;
summary)
  todo_init
  awk -F'\t' '
    { n++
      if ($2 == "open") o++
      else if ($2 == "active") a++
      else if ($2 == "done") d++
    }
    END { printf "%d items · %d open · %d active · %d done\n", n, o, a, d }
  ' "$TODO"
  ;;
list)
  todo_init
  FILTER=all
  NOTES=1
  shift || true
  while [ $# -gt 0 ]; do
    case "$1" in
    --open) FILTER=open ;;
    --no-notes) NOTES=0 ;;
    *) foreman_die "unknown list option: $1" ;;
    esac
    shift
  done
  awk -F'\t' -v filter="$FILTER" -v notes="$NOTES" -v tasks="$FOREMAN_TASKS" '
    function crewstate(id,   f, line, st) {
      if (id == "" || id == "-") return "-"
      f = tasks "/" id "/status"
      if ((getline line < f) <= 0) return "gone"
      close(f)
      if (line ~ /^state=/) { st = line; sub(/^state=/, "", st); return st }
      return "?"
    }
    BEGIN { printf "%-4s %-9s %-11s %s\n", "#", "STATUS", "CREW", "ITEM" }
    $2 == "dropped" && filter != "all" { next }
    {
      cs = ($2 == "active") ? crewstate($3) : "-"
      if (filter == "open" && $2 != "open" && $2 != "active") next
      label = $2
      if ($2 == "active" && cs != "-") label = "active/" cs
      printf "%-4s %-9s %-11s %s\n", $1, label, $3, $4
      if (notes == 1 && $5 != "" && $5 != "-") printf "%-26s ↳ %s\n", "", $5
    }
  ' "$TODO"
  ;;
*)
  foreman_die "usage: crew-todo.sh add|note|list|start|done|open|drop|sync|summary"
  ;;
esac
