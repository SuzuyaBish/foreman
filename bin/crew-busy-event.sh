#!/usr/bin/env bash
# crew-busy-event.sh - the only writer of a crew member's semantic busy record.
#
# Usage: crew-busy-event.sh arm <home> <id> [--state busy|idle|unknown]
#                                      [--source S] [--event E]
#        crew-busy-event.sh apply <home> <id> <busy|idle|unknown>
#                                      (--gen G | --current-gen) --source S --event E
#        crew-busy-event.sh retire <home> <id> (--gen G | --current-gen)
#
# Arming mints an incarnation token and seeds the record at seq=1. Every later
# event must present that token, so an extension that outlives its crew member —
# or a stale pane reusing a task id — fails closed instead of writing state for
# the wrong process.
set -eu

. "$(cd "$(dirname "$0")" && pwd)/foreman-lib.sh"

ACTION=${1:-}
HOME_DIR=${2:-}
ID=${3:-}
[ -n "$HOME_DIR" ] && [ -n "$ID" ] || foreman_die "usage: crew-busy-event.sh <arm|apply|retire> <home> <id> ..."
shift 3 || true

foreman_use_home "$HOME_DIR"
DIR=$(foreman_task_dir "$ID")
REC="$DIR/busy-state"
GEN="$DIR/busy-gen"
LOCK="$DIR/.busy.lock"

acquire() {
  local tries=0
  while ! mkdir "$LOCK" 2>/dev/null; do
    tries=$((tries + 1))
    # A crashed writer can leave the lock behind; it is only ever held for a
    # few milliseconds, so anything older than this is stale.
    if [ "$tries" -eq 20 ] && [ -d "$LOCK" ]; then
      age=$(( $(date +%s) - $(stat -f %m "$LOCK" 2>/dev/null || stat -c %Y "$LOCK" 2>/dev/null || date +%s) ))
      [ "$age" -lt 30 ] || rmdir "$LOCK" 2>/dev/null || true
    fi
    [ "$tries" -lt 100 ] || return 1
    sleep 0.05
  done
}
release() { rmdir "$LOCK" 2>/dev/null || true; }

new_gen() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr 'A-Z' 'a-z'
  else
    printf '%s-%s-%s' "$$" "$(date +%s)" "$RANDOM"
  fi
}

STATE=
SOURCE=
EVENT=
GEN_ARG=
while [ $# -gt 0 ]; do
  case "$1" in
  --state | --source | --event | --gen)
    [ $# -ge 2 ] || foreman_die "$1 requires a value"
    case "$1" in
    --state) STATE=$2 ;;
    --source) SOURCE=$2 ;;
    --event) EVENT=$2 ;;
    --gen) GEN_ARG=$2 ;;
    esac
    shift 2
    ;;
  --current-gen)
    GEN_ARG=current
    shift
    ;;
  *)
    [ -z "$STATE" ] || foreman_die "unexpected argument: $1"
    STATE=$1
    shift
    ;;
  esac
done

case "$ACTION" in
arm)
  mkdir -p "$DIR"
  [ -n "$STATE" ] || STATE=busy
  [ -n "$SOURCE" ] || SOURCE=fm-spawn
  [ -n "$EVENT" ] || EVENT=launch-brief
  acquire || foreman_die "busy record is locked"
  token=$(new_gen)
  printf '%s\n' "$token" >"$GEN"
  seq=1
  case "$STATE" in busy | idle | unknown) ;; *) STATE=unknown ;; esac
  printf 'v1 gen=%s seq=%s state=%s source=%s event=%s ts=%s\n' \
    "$token" "$seq" "$STATE" "$SOURCE" "$EVENT" "$(date +%s)" >"$REC"
  release
  printf '%s\n' "$token"
  ;;
apply)
  [ -n "$STATE" ] || foreman_die "apply needs a state"
  case "$STATE" in busy | idle | unknown) ;; *) foreman_die "bad state: $STATE" ;; esac
  [ -n "$SOURCE" ] || SOURCE=crew-ext
  [ -n "$EVENT" ] || EVENT=unknown
  [ -n "$GEN_ARG" ] || foreman_die "apply needs --gen or --current-gen"
  acquire || exit 1
  current=$(cat "$GEN" 2>/dev/null || printf '')
  if [ "$GEN_ARG" = current ]; then
    GEN_ARG=$current
  fi
  if [ -z "$current" ] || [ "$GEN_ARG" != "$current" ]; then
    release
    exit 1
  fi
  seq=0
  if [ -f "$REC" ]; then
    for tok in $(head -n 1 "$REC"); do
      case "$tok" in seq=*) seq=${tok#seq=} ;; esac
    done
  fi
  case "$seq" in '' | *[!0-9]*) seq=0 ;; esac
  seq=$((seq + 1))
  printf 'v1 gen=%s seq=%s state=%s source=%s event=%s ts=%s\n' \
    "$GEN_ARG" "$seq" "$STATE" "$SOURCE" "$EVENT" "$(date +%s)" >"$REC"
  release
  ;;
retire)
  acquire || exit 1
  current=$(cat "$GEN" 2>/dev/null || printf '')
  if [ -n "$GEN_ARG" ] && [ "$GEN_ARG" != current ] && [ "$GEN_ARG" != "$current" ]; then
    release
    exit 1
  fi
  rm -f "$REC" "$GEN"
  release
  ;;
*)
  foreman_die "unknown action: ${ACTION:-<none>} (arm|apply|retire)"
  ;;
esac
