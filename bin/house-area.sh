#!/usr/bin/env bash
# house-area.sh - the chart: add, list, show and archive an area.
#
# Usage: house-area.sh add <slug> [--title T] [--kind K] [--where W]
#                                    [--bind B] [--status S] [--next N]
#        house-area.sh list
#        house-area.sh show <slug>
#        house-area.sh archive <slug>
#        house-area.sh --help
#
# An area is any ongoing thread the captain keeps in his head: a repo, a project
# that lives in its own chat, a deck or talk, a craft like branding or the
# design skill. It is NOT a git project and NOT a crew task. An area is named by
# the captain, may live anywhere on the machine, and its truth is the chart, not
# git. Archiving retires it from the active list; the file is never deleted.
set -eu

. "$(cd "$(dirname "$0")" && pwd)/house-lib.sh"

usage() {
  cat <<'EOF'
usage: house-area.sh add <slug> [--title T] [--kind K] [--where W]
                                   [--bind B] [--status S] [--next N]
       house-area.sh list
       house-area.sh show <slug>
       house-area.sh archive <slug>

add      start a chart. kind is one of: repo chat deck craft other.
list     one line per active area: slug, kind, updated, next.
show     print the whole chart.
archive  retire an area out of the active list (the file is kept).
EOF
}

ACTION=${1:-list}
[ $# -ge 1 ] && shift || true

case "$ACTION" in
-h | --help)
  usage
  exit 0
  ;;
add)
  SLUG=${1:-}
  [ -n "$SLUG" ] || house_die "usage: house-area.sh add <slug> [--title T] [--kind K] [--where W] [--bind B] [--status S] [--next N]"
  shift
  TITLE=$SLUG
  KIND=other
  WHERE=
  BIND=
  STATUS=
  NEXT=
  while [ $# -gt 0 ]; do
    case "$1" in
    --title)
      [ $# -ge 2 ] || house_die "--title requires a value"
      TITLE=$2
      shift 2
      ;;
    --kind)
      [ $# -ge 2 ] || house_die "--kind requires a value"
      KIND=$2
      shift 2
      ;;
    --where)
      [ $# -ge 2 ] || house_die "--where requires a value"
      WHERE=$2
      shift 2
      ;;
    --bind)
      [ $# -ge 2 ] || house_die "--bind requires a value"
      BIND=$2
      shift 2
      ;;
    --status)
      [ $# -ge 2 ] || house_die "--status requires a value"
      STATUS=$2
      shift 2
      ;;
    --next)
      [ $# -ge 2 ] || house_die "--next requires a value"
      NEXT=$2
      shift 2
      ;;
    *) house_die "unknown add option: $1" ;;
    esac
  done
  house_slug_ok "$SLUG" || house_die "bad area slug: $SLUG (lowercase letters, digits and dashes; max 32)"
  house_kind_ok "$KIND" || house_die "bad area kind: $KIND (one of: $HOUSE_KINDS)"
  # Every value must be one line before it is printed into the chart, or a
  # title carrying a newline could inject a field.
  TITLE=$(house_sanitize_field title "$TITLE")
  WHERE=$(house_sanitize_field where "$WHERE")
  BIND=$(house_sanitize_field bind "$BIND")
  STATUS=$(house_sanitize_field status "$STATUS")
  NEXT=$(house_sanitize_field next "$NEXT")
  house_find_area "$SLUG" >/dev/null 2>&1 && house_die "area already exists: $SLUG (use show or note)"
  mkdir -p "$HOUSE_AREAS"
  path=$(house_area_path "$SLUG")
  today=$(house_today)
  {
    printf '# house area: %s\n\n' "$SLUG"
    printf 'slug: %s\n' "$SLUG"
    printf 'title: %s\n' "$TITLE"
    printf 'kind: %s\n' "$KIND"
    printf 'where: %s\n' "$WHERE"
    printf 'bind: %s\n' "$BIND"
    printf 'opened: %s\n' "$today"
    printf 'updated: %s\n' "$today"
    printf 'status: %s\n' "$STATUS"
    printf 'next: %s\n' "$NEXT"
    printf '\n## Log\n\n'
  } >"$path"
  printf 'house: added area %s (%s)\n' "$SLUG" "$KIND"
  ;;
list)
  [ $# -eq 0 ] || house_die "usage: house-area.sh list"
  found=0
  for slug in $(house_slugs); do
    found=1
    path=$(house_area_path "$slug")
    kind=$(house_field "$path" kind)
    updated=$(house_field "$path" updated)
    next=$(house_field "$path" next)
    printf '%-18s %-6s %-10s %s\n' "$slug" "${kind:--}" "${updated:--}" "${next:--}"
  done
  if [ "$found" -eq 0 ]; then
    printf 'house: no areas\n'
  fi
  ;;
show)
  slug=${1:-}
  [ -n "$slug" ] || house_die "usage: house-area.sh show <slug>"
  house_slug_ok "$slug" || house_die "bad area slug: $slug (lowercase letters, digits and dashes; max 32)"
  path=$(house_find_area "$slug") || house_die "no such area: $slug"
  cat "$path"
  ;;
archive)
  slug=${1:-}
  [ -n "$slug" ] || house_die "usage: house-area.sh archive <slug>"
  path=$(house_require_area "$slug")
  mkdir -p "$HOUSE_ARCHIVED"
  mv "$path" "$(house_archived_path "$slug")"
  printf 'house: archived area %s\n' "$slug"
  ;;
*)
  house_die "unknown house-area action: $ACTION (try --help)"
  ;;
esac
