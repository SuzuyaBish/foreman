#!/usr/bin/env bash
# crew-config.sh - the crew session's settings.
# Usage: crew-config.sh [show]
#        crew-config.sh get <key>
#        crew-config.sh set <key> <value>
#        crew-config.sh unset <key>
#
# Keys: crewModel crewThinking crewApprove crewIsolate trustPaths
# Stored in $FOREMAN_HOME/config.json, so settings are per-foreman-home and
# never committed.
set -eu

. "$(cd "$(dirname "$0")" && pwd)/foreman-lib.sh"

KEYS="crewModel crewThinking crewApprove crewIsolate trustPaths crewDelivery"

valid_key() {
  case " $KEYS " in *" $1 "*) return 0 ;; esac
  return 1
}

# Booleans are stored as JSON booleans so a reader never has to parse "yes".
is_bool_key() {
  case "$1" in crewApprove | crewIsolate | trustPaths) return 0 ;; esac
  return 1
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
  TMP="$FOREMAN_CONFIG.tmp.$$"
  mkdir -p "$FOREMAN_HOME"
  if is_bool_key "$K"; then
    case "$V" in
    true | 1 | yes | on) V=true ;;
    false | 0 | no | off) V=false ;;
    *) foreman_die "$K takes true or false, got: $V" ;;
    esac
    if [ -f "$FOREMAN_CONFIG" ]; then
      jq --arg k "$K" --argjson v "$V" '.[$k] = $v' "$FOREMAN_CONFIG" >"$TMP"
    else
      jq -n --arg k "$K" --argjson v "$V" '{($k): $v}' >"$TMP"
    fi
  else
    if [ -f "$FOREMAN_CONFIG" ]; then
      jq --arg k "$K" --arg v "$V" '.[$k] = $v' "$FOREMAN_CONFIG" >"$TMP"
    else
      jq -n --arg k "$K" --arg v "$V" '{($k): $v}' >"$TMP"
    fi
  fi
  mv "$TMP" "$FOREMAN_CONFIG"
  printf '%s=%s\n' "$K" "$V"
  ;;
unset)
  K=${2:-}
  valid_key "$K" || foreman_die "unknown config key: ${K:-<none>} (keys: $KEYS)"
  [ -f "$FOREMAN_CONFIG" ] || exit 0
  TMP="$FOREMAN_CONFIG.tmp.$$"
  jq --arg k "$K" 'del(.[$k])' "$FOREMAN_CONFIG" >"$TMP" && mv "$TMP" "$FOREMAN_CONFIG"
  printf 'unset %s\n' "$K"
  ;;
*)
  foreman_die "usage: crew-config.sh [show|get <key>|set <key> <value>|unset <key>]"
  ;;
esac
