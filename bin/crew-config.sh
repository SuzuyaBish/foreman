#!/usr/bin/env bash
# crew-config.sh - the crew session's settings.
# Usage: crew-config.sh [show]
#        crew-config.sh get <key>
#        crew-config.sh set <key> <value>
#        crew-config.sh unset <key>
#
# Keys: crewModel crewThinking crewApprove crewIsolate trustPaths crewDelivery
#       crewWake crewWidget crewCalm
# Stored in $FOREMAN_HOME/config.json, so settings are per-foreman-home and
# never committed.
set -eu

. "$(cd "$(dirname "$0")" && pwd)/foreman-lib.sh"

KEYS="crewModel crewThinking crewApprove crewIsolate trustPaths crewDelivery crewWake crewWidget crewCalm"

valid_key() {
  case " $KEYS " in *" $1 "*) return 0 ;; esac
  return 1
}

# Booleans are stored as JSON booleans so a reader never has to parse "yes".
is_bool_key() {
  case "$1" in crewApprove | crewIsolate | trustPaths | crewWake | crewWidget | crewCalm) return 0 ;; esac
  return 1
}

# Every write is a read-modify-write of the whole file, so it happens under one
# lock. Without it two `set`s fired at once each read the old file and the last
# mv won: the first key was lost and the next crew ran on the wrong model. The
# temp file sits beside config.json so the mv is an atomic rename.
config_write() { # <jq-args>... <filter>
  local lock="$FOREMAN_CONFIG.lock" tmp="$FOREMAN_CONFIG.tmp.$$" ok=0
  mkdir -p "$FOREMAN_HOME"
  foreman_lock_acquire "$lock" ||
    foreman_die "could not lock $FOREMAN_CONFIG: $(foreman_lock_holder "$lock"); nothing was written"
  if [ -f "$FOREMAN_CONFIG" ]; then
    jq "$@" "$FOREMAN_CONFIG" >"$tmp" && mv "$tmp" "$FOREMAN_CONFIG" && ok=1
  else
    jq -n "$@" >"$tmp" && mv "$tmp" "$FOREMAN_CONFIG" && ok=1
  fi
  rm -f "$tmp"
  foreman_lock_release "$lock"
  [ "$ok" = 1 ] || foreman_die "could not update $FOREMAN_CONFIG; nothing was written"
}

ACTION=${1:-show}
case "$ACTION" in
show)
  if [ -f "$FOREMAN_CONFIG" ]; then
    jq . "$FOREMAN_CONFIG"
  else
    printf '{}\n'
  fi
  ;;
get)
  K=${2:-}
  valid_key "$K" || foreman_die "unknown config key: ${K:-<none>} (keys: $KEYS)"
  printf '%s\n' "$(foreman_config_get "$K")"
  ;;
set)
  K=${2:-}
  V=${3:-}
  valid_key "$K" || foreman_die "unknown config key: ${K:-<none>} (keys: $KEYS)"
  [ -n "$V" ] || foreman_die "usage: crew-config.sh set <key> <value>"
  if is_bool_key "$K"; then
    case "$V" in
    true | 1 | yes | on) V=true ;;
    false | 0 | no | off) V=false ;;
    *) foreman_die "$K takes true or false, got: $V" ;;
    esac
    config_write --arg k "$K" --argjson v "$V" '.[$k] = $v'
  else
    config_write --arg k "$K" --arg v "$V" '.[$k] = $v'
  fi
  printf '%s=%s\n' "$K" "$V"
  ;;
unset)
  K=${2:-}
  valid_key "$K" || foreman_die "unknown config key: ${K:-<none>} (keys: $KEYS)"
  [ -f "$FOREMAN_CONFIG" ] || exit 0
  config_write --arg k "$K" 'del(.[$k])'
  printf 'unset %s\n' "$K"
  ;;
*)
  foreman_die "usage: crew-config.sh [show|get <key>|set <key> <value>|unset <key>]"
  ;;
esac
