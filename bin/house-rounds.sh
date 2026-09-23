#!/usr/bin/env bash
# house-rounds.sh - the physician's rounds: where every area stands.
#
# Usage: house-rounds.sh [--all] [--stale-days N] [--digest]
#        house-rounds.sh --help
#
# One line per area: slug, kind, updated, status and the diagnosed next step.
# An area with no `next`, or an `updated` older than the stale bound, is marked
# so nothing rots silently. `--digest` collapses it to one summary line for
# session start. Reading rounds never writes: it is a look, not a visit.
set -eu

. "$(cd "$(dirname "$0")" && pwd)/house-lib.sh"

usage() {
  cat <<'EOF'
usage: house-rounds.sh [--all] [--stale-days N] [--digest]

Take the rounds: one line per area with its status and next step. Areas with no
next step, or an updated date older than the stale bound (default 14 days, or
HOUSE_STALE_DAYS), are marked. --all includes archived areas; --digest prints
one summary line.
EOF
}

ALL=0
DIGEST=0
STALE_DAYS=${HOUSE_STALE_DAYS:-14}
while [ $# -gt 0 ]; do
  case "$1" in
  -h | --help)
    usage
    exit 0
    ;;
  --all)
    ALL=1
    shift
    ;;
  --digest)
    DIGEST=1
    shift
    ;;
  --stale-days)
    [ $# -ge 2 ] || house_die "--stale-days requires a number"
    case "$2" in
    '' | *[!0-9]*) house_die "--stale-days requires a whole number of days" ;;
    esac
    STALE_DAYS=$2
    shift 2
    ;;
  *) house_die "unknown rounds option: $1 (try --help)" ;;
  esac
done

total=0
stale_count=0
none_count=0

if [ "$ALL" -eq 1 ]; then
  slugs=$(house_slugs --all)
else
  slugs=$(house_slugs)
fi

NL='
'
lines=
for slug in $slugs; do
  if [ "$ALL" -eq 1 ] && [ -f "$(house_archived_path "$slug")" ]; then
    path=$(house_archived_path "$slug")
    archived=1
  else
    path=$(house_area_path "$slug")
    archived=0
  fi
  [ -f "$path" ] || continue
  total=$((total + 1))
  kind=$(house_field "$path" kind)
  updated=$(house_field "$path" updated)
  status=$(house_field "$path" status)
  next=$(house_trim "$(house_field "$path" next)")

  marks=
  age=$(house_age_days "$path" 2>/dev/null || printf '')
  if [ -z "$age" ]; then
    stale=1
    marks="$marks [stale ?]"
  elif [ "$age" -gt "$STALE_DAYS" ]; then
    stale=1
    marks="$marks [stale ${age}d]"
  else
    stale=0
  fi
  [ "$stale" -eq 1 ] && stale_count=$((stale_count + 1))
  if [ -z "$next" ]; then
    none_count=$((none_count + 1))
    marks="$marks [no next]"
  fi
  [ "$archived" -eq 1 ] && marks="$marks [archived]"

  row=$(printf '%-18s %-6s %-10s status: %s  next: %s%s' \
    "$slug" "${kind:--}" "${updated:--}" "${status:--}" "${next:--}" "$marks")
  if [ -z "$lines" ]; then
    lines=$row
  else
    lines="$lines$NL$row"
  fi
done

if [ "$DIGEST" -eq 1 ]; then
  if [ "$total" -eq 0 ]; then
    printf 'house: no areas\n'
  else
    printf 'house: %s area%s · %s stale · %s no next\n' \
      "$total" "$([ "$total" -eq 1 ] || printf 's')" "$stale_count" "$none_count"
  fi
  exit 0
fi

if [ "$total" -eq 0 ]; then
  printf 'house rounds: no areas\n'
  exit 0
fi

printf 'house rounds: %s area%s (%s stale, %s no next)\n' \
  "$total" "$([ "$total" -eq 1 ] || printf 's')" "$stale_count" "$none_count"
printf '%s\n' "$lines"
