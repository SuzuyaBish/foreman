#!/usr/bin/env bash
# crew-trust.sh - manage pi's folder-trust decisions for paths crew work in.
# Usage: crew-trust.sh <path>...      mark paths trusted
#        crew-trust.sh --list
#        crew-trust.sh --remove <path>...
#
# pi asks for folder trust the first time it runs in a directory it has not
# seen. Crew launches pass --approve for that run; this pre-registers the path
# so a human attaching to a crew pane, or starting pi in a project directly,
# is never prompted either.
set -eu

. "$(cd "$(dirname "$0")" && pwd)/foreman-lib.sh"

TRUST_FILE=${PI_TRUST_FILE:-$HOME/.pi/agent/trust.json}

# pi reads and writes this file too, and its own writes are outside our reach,
# but foreman's writers are serialised: parallel spawns each trusting a new
# worktree must not drop one another's entry.
write_trust() { # <jq-filter> <arg>...
  local filter=$1 tmp lock ok=0
  shift
  mkdir -p "$(dirname "$TRUST_FILE")"
  tmp="$TRUST_FILE.tmp.$$"
  lock="$TRUST_FILE.lock"
  foreman_lock_acquire "$lock" || foreman_die "could not lock $TRUST_FILE: $(foreman_lock_holder "$lock")"
  if [ -f "$TRUST_FILE" ]; then
    jq "$@" "$filter" "$TRUST_FILE" >"$tmp" && mv "$tmp" "$TRUST_FILE" && ok=1
  else
    jq "$@" -n "$filter" >"$tmp" && mv "$tmp" "$TRUST_FILE" && ok=1
  fi
  rm -f "$tmp"
  foreman_lock_release "$lock"
  [ "$ok" = 1 ] || foreman_die "could not update $TRUST_FILE"
}

case "${1:-}" in
--list)
  [ -f "$TRUST_FILE" ] || {
    printf 'no trust file at %s\n' "$TRUST_FILE"
    exit 0
  }
  jq -r 'to_entries[] | select(.value == true) | .key' "$TRUST_FILE"
  ;;
--remove)
  shift
  [ $# -gt 0 ] || foreman_die "usage: crew-trust.sh --remove <path>..."
  for p in "$@"; do
    abs=$(cd "$p" 2>/dev/null && pwd -P) || abs=$p
    write_trust 'del(.[$p])' --arg p "$abs"
    printf 'untrusted %s\n' "$abs"
  done
  ;;
'')
  foreman_die "usage: crew-trust.sh <path>... | --list | --remove <path>..."
  ;;
*)
  for p in "$@"; do
    [ -d "$p" ] || foreman_die "not a directory: $p"
    abs=$(cd "$p" && pwd -P)
    write_trust '.[$p] = true' --arg p "$abs"
    printf 'trusted %s\n' "$abs"
  done
  ;;
esac
