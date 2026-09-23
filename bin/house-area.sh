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
  [ -n "$SLUG" ] || foreman_die "usage: house-area.sh add <slug> [--title T] [--kind K] [--where W] [--bind B] [--status S] [--next N]"
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
      [ $# -ge 2 ] || foreman_die "--title requires a value"
      TITLE=$2
      shift 2
      ;;
    --kind)
      [ $# -ge 2 ] || foreman_die "--kind requires a value"
      KIND=$2
      shift 2
      ;;
    --where)
      [ $# -ge 2 ] || foreman_die "--where requires a value"
      WHERE=$2
      shift 2
      ;;
    --bind)
      [ $# -ge 2 ] || foreman_die "--bind requires a value"
      BIND=$2
      shift 2
      ;;
    --status)
      [ $# -ge 2 ] || foreman_die "--status requires a value"
      STATUS=$2
      shift 2
      ;;
    --next)
      [ $# -ge 2 ] || foreman_die "--next requires a value"
      NEXT=$2
      shift 2
      ;;
    *) foreman_die "unknown add option: $1" ;;
    esac
  done
  house_slug_ok "$SLUG" || foreman_die "bad area slug: $SLUG (lowercase letters, digits and dashes; max 32)"
  house_kind_ok "$KIND" || foreman_die "bad area kind: $KIND (one of: $HOUSE_KINDS)"
  house_find_area "$SLUG" >/dev/null 2>&1 && foreman_die "area already exists: $SLUG (use show or note)"
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
  [ $# -eq 0 ] || foreman_die "usage: house-area.sh list"
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
  [ -n "$slug" ] || foreman_die "usage: house-area.sh show <slug>"
  path=$(house_find_area "$slug") || foreman_die "no such area: $slug"
  cat "$path"
  ;;
archive)
  slug=${1:-}
  [ -n "$slug" ] || foreman_die "usage: house-area.sh archive <slug>"
  path=$(house_require_area "$slug")
  mkdir -p "$HOUSE_ARCHIVED"
  mv "$path" "$(house_archived_path "$slug")"
  printf 'house: archived area %s\n' "$slug"
  ;;
*)
  foreman_die "unknown house-area action: $ACTION (try --help)"
  ;;
esac
