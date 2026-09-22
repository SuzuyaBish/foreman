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

write_trust() { # <jq-filter> <arg>...
  local filter=$1
  shift
  mkdir -p "$(dirname "$TRUST_FILE")"
  local tmp
  tmp="$TRUST_FILE.tmp.$$"
  if [ -f "$TRUST_FILE" ]; then
    jq "$@" "$filter" "$TRUST_FILE" >"$tmp" || {
      rm -f "$tmp"
      foreman_die "could not update $TRUST_FILE"
    }
  else
    jq "$@" -n "$filter" >"$tmp" || {
      rm -f "$tmp"
      foreman_die "could not create $TRUST_FILE"
    }
  fi
  mv "$tmp" "$TRUST_FILE"
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
