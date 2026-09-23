#!/usr/bin/env bash
# crew-processes.sh - CREW SIDE. What is this crew member still running?
#
# Usage: crew-processes.sh list <id>              one line per process still up
#        crew-processes.sh count <id>             just the number
#        crew-processes.sh kill <id> [--grace N]  stop them: TERM, then KILL
#        crew-processes.sh snapshot <id>          record what pre-dated the crew
#
# Exit 0 means the question was answered (the list may be empty). Exit 3 means
# it could not be answered at all (no anchor, no lsof), and every caller treats
# that as "leave the crew alone": a broken probe is not a reason to hold work
# hostage, and a teardown that guessed would be worse than one that did nothing.
#
# Why this exists: a crew member starts things - a dev server, a file watcher, a
# test runner, an emulator, a browser. When it finishes they keep running, and
# they hold ports and CPU for the rest of the session. By then nothing on the
# machine remembers that they belonged to a crew that is already done.
#
# Attribution is by WORKING DIRECTORY, because that is the one link that
# survives what makes a stray hard to find. The shell that started a background
# job exits and the job is reparented to PID 1: its environment cannot be read
# back afterwards (`ps -E` reports nothing for a reparented process on macOS -
# checked directly), its process group is the transient one of the tool call,
# and `herdr pane process-info` only ever lists the pane's own foreground group
# (also checked: a reparented `sleep` was invisible to it). Its cwd, though, is
# still the directory the crew was working in, and `lsof -d cwd` reports that
# for every process on the machine in about 60ms.
#
# Anchors: the crew's worktree if it has one, else its cwd. An isolated crew
# owns its worktree outright; a --no-isolate crew works inside the captain's own
# checkout, so whatever was already running there when the crew launched is
# excluded through `snapshot`.
#
# Never touched: the crew's agent and everything still descended from it, the
# agent's ancestors (the pane shell, and the multiplexer above it), and
# `lavish-axi`, whose own contract is to stay up while the captain annotates a
# board and to stop itself when the last session ends.
#
# Tests point FOREMAN_PROC_PS_FILE and FOREMAN_PROC_LSOF_FILE at fixtures
# instead of the live process table. That is the only seam, and like
# FOREMAN_HERDR_MOVER it exists so a test can be exact rather than lucky.
set -eu

. "$(cd "$(dirname "$0")" && pwd)/foreman-lib.sh"

ACTION=${1:-}
ID=${2:-}
GRACE=${FOREMAN_KILL_GRACE:-2}
if [ $# -ge 2 ]; then shift 2; else set --; fi
while [ $# -gt 0 ]; do
  case "$1" in
  --grace)
    [ $# -ge 2 ] || foreman_die "--grace requires a value"
    GRACE=$2
    shift 2
    ;;
  *) foreman_die "unknown option: $1" ;;
  esac
done

DIR=$(foreman_require_task "$ID")
SNAP="$DIR/processes-at-launch"

PSFILE=$(mktemp) || foreman_die "could not create a temp file"
PROTFILE=$(mktemp) || foreman_die "could not create a temp file"
LSOF_OUT=$(mktemp) || foreman_die "could not create a temp file"
trap 'rm -f "$PSFILE" "$PROTFILE" "$LSOF_OUT"' EXIT

# --- the process table ------------------------------------------------------

proc_ps() { # "pid ppid command" for every process
  if [ -n "${FOREMAN_PROC_PS_FILE:-}" ]; then
    cat "$FOREMAN_PROC_PS_FILE"
    return 0
  fi
  ps -A -o pid=,ppid=,command=
}

proc_cwd_scan() { # the raw `lsof -F pcn` stream
  if [ -n "${FOREMAN_PROC_LSOF_FILE:-}" ]; then
    cat "$FOREMAN_PROC_LSOF_FILE"
    return 0
  fi
  command -v lsof >/dev/null 2>&1 || return 1
  lsof -d cwd -F pcn 2>/dev/null
}

proc_canon() { # the physical path, so lsof's /private/... matches a /tmp/... meta
  local p
  p=$(cd "$1" 2>/dev/null && pwd -P) || return 1
  [ -n "$p" ] || return 1
  printf '%s' "$p"
}

proc_anchor() { # the directory this crew owns, or nothing
  local a
  a=$(foreman_meta_get "$ID" worktree)
  [ -n "$a" ] || a=$(foreman_meta_get "$ID" cwd)
  [ -n "$a" ] || return 0
  proc_canon "$a"
}

# Every pid whose cwd is the anchor or inside it. lsof -F pcn emits one field
# per line: p<pid>, c<command>, n<path>, repeating per process.
proc_cwd_pids() { # <anchor> -> pids, one per line
  awk -v anchor="$1" '
    /^p/ { pid = substr($0, 2) + 0; next }
    /^n/ {
      p = substr($0, 2)
      if (p == anchor || index(p, anchor "/") == 1) print pid
    }
  ' "$LSOF_OUT" | sort -u
}

# Pids that must never be reported or stopped: the agent, its descendants (MCP
# servers, a tool call still in flight) and its ancestors (the pane shell). The
# two sets are built separately on purpose - expanding ancestors and then
# descendants would protect every sibling in the session, which is the whole
# multiplexer's worth of processes.
proc_protected() {
  awk '
    {
      pid = $1 + 0; ppid = $2 + 0
      cmd = $0; sub(/^[ \t]*[0-9]+[ \t]+[0-9]+[ \t]+/, "", cmd)
      PP[pid] = ppid; CMD[pid] = cmd; ALL[pid] = 1
    }
    END {
      for (p in ALL) {
        if (CMD[p] ~ /(^|\/)pi([ \t]|$)/ || CMD[p] ~ /agent-device[ \t]+mcp/ || CMD[p] ~ /lavish-axi/) SEED[p] = 1
        # A machine-wide daemon is not a crew-local resource even when the crew
        # started it as a side effect. The adb server owns a fixed port that
        # other tools on this machine (the captain emulator, another crew) are
        # already talking to, so stopping it is collateral damage; it also
        # restarts itself on the next adb client. Extend this list only with
        # that same kind of reason.
        if (CMD[p] ~ /(^|\/)adb[ \t].*fork-server/) SEED[p] = 1
      }
      for (s in SEED) DESC[s] = 1
      changed = 1
      while (changed) {
        changed = 0
        for (p in ALL) if (!(p in DESC) && (PP[p] in DESC)) { DESC[p] = 1; changed = 1 }
      }
      for (s in SEED) {
        q = PP[s]
        while (q > 1) {
          if (q in ANC) break
          ANC[q] = 1
          q = PP[q]
        }
      }
      for (p in DESC) print p
      for (p in ANC) print p
    }
  ' "$PSFILE"
}

# --- what is still running --------------------------------------------------

proc_strays() { # "pid<TAB>command" per stray; exit 1 when it cannot be told
  local anchor pids
  anchor=$(proc_anchor)
  [ -n "$anchor" ] || return 1
  pids=$(proc_cwd_pids "$anchor")
  [ -n "$pids" ] || return 0
  proc_protected >"$PROTFILE"
  printf '%s\n' "$pids" | awk -v prot="$PROTFILE" -v snap="$SNAP" -v ps="$PSFILE" '
    BEGIN {
      while ((getline l < prot) > 0) PROT[l + 0] = 1
      close(prot)
      while ((getline l < snap) > 0) SNAP[l + 0] = 1
      close(snap)
      while ((getline l < ps) > 0) {
        pid = l + 0
        sub(/^[ \t]*[0-9]+[ \t]+[0-9]+[ \t]+/, "", l)
        CMD[pid] = l
      }
      close(ps)
    }
    {
      pid = $1 + 0
      if (pid == 0 || (pid in PROT) || (pid in SNAP)) next
      # Only processes this table can name are reported. A pid that is in the
      # cwd scan but not in the process table is either the scan itself (born
      # after the table was read) or something that has already exited; either
      # way it must never be blamed on the crew.
      if (!(pid in CMD)) next
      printf "%d\t%s\n", pid, CMD[pid]
    }
  '
}

proc_die_no_probe() {
  printf 'crew-processes: cannot tell what is running for %s (no anchor, or no lsof); leaving it alone\n' "$ID" >&2
  exit 3
}

# Populate the process table and the cwd scan, or say why not. Every action
# needs both, so they are read once, here.
proc_read_tables() {
  # Both tables are read with the working directory moved out of the way. The
  # probe's own children (lsof, ps, awk) would otherwise inherit the crew's cwd,
  # which IS the anchor: `lsof` lists itself, and the run that is looking for
  # strays reports one. Subshells, so the caller's cwd is untouched.
  (cd / && proc_ps >"$PSFILE")
  (cd / && proc_cwd_scan >"$LSOF_OUT") || proc_die_no_probe
}

# --- actions ----------------------------------------------------------------

case "$ACTION" in
snapshot)
  # Called by the launch, before the crew exists. A relaunch keeps the original
  # list: the strays from the run that just died are exactly what the next
  # teardown has to find, and re-snapshotting would launder them.
  if [ -f "$SNAP" ]; then
    printf 'snapshot kept (%s)\n' "$SNAP"
    exit 0
  fi
  anchor=$(proc_anchor)
  [ -n "$anchor" ] || exit 0
  proc_read_tables
  proc_cwd_pids "$anchor" >"$SNAP"
  printf 'snapshot: %s process(es) already under %s\n' "$(wc -l <"$SNAP" | tr -d ' ')" "$anchor"
  ;;

list)
  proc_read_tables
  proc_strays || proc_die_no_probe
  ;;

count)
  proc_read_tables
  strays=$(proc_strays) || proc_die_no_probe
  [ -n "$strays" ] || { printf '0\n'; exit 0; }
  printf '%s\n' "$strays" | awk 'END { print NR + 0 }'
  ;;

kill)
  proc_read_tables
  strays=$(proc_strays) || proc_die_no_probe
  [ -n "$strays" ] || exit 0
  pids=$(printf '%s\n' "$strays" | cut -f1)
  # TERM first, so a dev server flushes and removes its socket or lock file;
  # KILL only what ignored it.
  for pid in $pids; do kill -TERM "$pid" 2>/dev/null || true; done
  tries=0
  limit=$(awk -v g="$GRACE" 'BEGIN { printf "%d", g * 5 }')
  while [ "$tries" -lt "$limit" ]; do
    alive=
    for pid in $pids; do
      kill -0 "$pid" 2>/dev/null && alive=$pid
    done
    [ -z "$alive" ] && break
    sleep 0.2
    tries=$((tries + 1))
  done
  for pid in $pids; do
    kill -0 "$pid" 2>/dev/null || continue
    kill -KILL "$pid" 2>/dev/null || true
  done
  printf '%s\n' "$strays" | while IFS=$'\t' read -r pid cmd; do
    printf 'stopped %s (%s)\n' "$pid" "$cmd"
  done
  # Report the truth rather than the intent: a process that refused to die is
  # still holding its port, and the caller needs to know that. The cwd scan has
  # to be taken again here - the one read before the kill still lists them.
  sleep 0.2
  proc_cwd_scan >"$LSOF_OUT" || exit 0
  left=$(proc_strays) || exit 0
  [ -z "$left" ] || printf 'warning: %s still running after TERM and KILL\n' \
    "$(printf '%s\n' "$left" | cut -f1 | tr '\n' ' ' | sed 's/ $//')" >&2
  ;;

*)
  foreman_die "usage: crew-processes.sh list|count|kill|snapshot <id> [--grace N]"
  ;;
esac
