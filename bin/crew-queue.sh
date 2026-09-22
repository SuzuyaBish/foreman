#!/usr/bin/env bash
# crew-queue.sh - the durable wake queue.
# Usage: crew-queue.sh append <kind> <payload...>
#        crew-queue.sh list [--after N]
#        crew-queue.sh count
#        crew-queue.sh ack <sequence>
#        crew-queue.sh clear
#
# Rows are appended before anything is announced and acknowledged by sequence,
# so a wake survives a foreman crash, a session replacement, or an extension
# reload. A row carries state and identifiers only — never crew output.
set -eu

. "$(cd "$(dirname "$0")" && pwd)/foreman-lib.sh"

ACTION=${1:-list}
case "$ACTION" in
append)
  KIND=${2:-state}
  if [ $# -ge 2 ]; then shift 2; else set --; fi
  PAYLOAD="${*-}"
  [ -n "$PAYLOAD" ] || foreman_die "empty wake payload"
  case "$KIND" in state | decision | steer | merge | recover | pr) ;; *) foreman_die "bad wake kind: $KIND" ;; esac
  seq=$(foreman_queue_append "$KIND" "$PAYLOAD")
  printf 'queued %s %s\n' "$seq" "$KIND"
  ;;
list)
  AFTER=$(foreman_queue_acked)
  if [ "${2:-}" = --after ] && [ -n "${3:-}" ]; then
    case "$3" in '' | *[!0-9]*) foreman_die "--after needs a number" ;; esac
    AFTER=$3
  fi
  rows=$(foreman_queue_pending | awk -F'\t' -v a="$AFTER" '$1 + 0 > a')
  if [ -z "$rows" ]; then
    printf 'no pending wakes\n'
    exit 0
  fi
  printf '%-5s %-8s %s\n' SEQ KIND DETAIL
  printf '%s\n' "$rows" | awk -F'\t' '{ printf "%-5s %-8s %s\n", $1, $3, $4 }'
  printf 'ack-through %s\n' "$(printf '%s\n' "$rows" | tail -n 1 | cut -f1)"
  ;;
count)
  foreman_queue_count
  printf '\n'
  ;;
ack)
  foreman_queue_ack "${2:-}" || foreman_die "ack needs a sequence number"
  printf 'acked through %s\n' "$2"
  ;;
clear)
  rm -f "$(foreman_queue_path)" "$(foreman_queue_ack_path)"
  printf 'wake queue cleared\n'
  ;;
*)
  foreman_die "usage: crew-queue.sh append <kind> <payload> | list | count | ack <seq> | clear"
  ;;
esac
