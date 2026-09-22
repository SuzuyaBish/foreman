#!/usr/bin/env bash
# crew-models.sh - list the models pi can run, bounded.
# Usage: crew-models.sh [search]
# The foreman uses this to resolve a model the captain names before setting it.
set -eu

. "$(cd "$(dirname "$0")" && pwd)/foreman-lib.sh"

PI_BIN=${FOREMAN_PI_BIN:-pi}
command -v "$PI_BIN" >/dev/null 2>&1 || foreman_die "pi is not on PATH"

MAX=${FOREMAN_MODELS_MAX:-40}
RAW=$("$PI_BIN" --list-models "${1:-}" 2>&1) || foreman_die "could not list models"
TOTAL=$(printf '%s\n' "$RAW" | wc -l | tr -d ' ')
printf '%s\n' "$RAW" | head -n "$MAX"
if [ "$TOTAL" -gt "$MAX" ]; then
  printf '…[%s models total; narrow with a search term]\n' "$TOTAL"
fi
