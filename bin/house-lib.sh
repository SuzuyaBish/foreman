#!/usr/bin/env bash
# house-lib.sh - chart paths and field helpers for House.
#
# House is foreman's sibling: it keeps a chart of the captain's ongoing areas
# and writes prescriptions. It examines, diagnoses and prescribes; it never
# spawns, merges, archives, edits or executes. This file holds only paths and
# plain-text helpers - the discipline lives in the SKILL and the tools.
#
# The chart is deliberately plain text: `slug: value` header lines, a blank
# line, then an append-only dated log. Greppable, human-editable, and readable
# with sed. It lives under FOREMAN_HOME, so it is per-installation and never
# committed.
#
# Sourced by every bin/house-*.sh. No side effects on source beyond paths.

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/foreman-lib.sh"

HOUSE_DIR="$FOREMAN_HOME/house"
HOUSE_AREAS="$HOUSE_DIR/areas"
HOUSE_ARCHIVED="$HOUSE_DIR/archived"
HOUSE_OUTBOX="$HOUSE_DIR/outbox"

# Kinds are a closed set so `rounds` and `prescribe` can branch on them without
# guessing. `repo` means a git repository (deliver a PR); everything else is a
# thread with no repository (deliver a report).
HOUSE_KINDS="repo chat deck craft other"

house_slug_ok() { foreman_valid_id "${1:-}"; }

house_kind_ok() {
  local k
  for k in $HOUSE_KINDS; do
    [ "${1:-}" = "$k" ] && return 0
  done
  return 1
}

house_area_path() { printf '%s/%s.md' "$HOUSE_AREAS" "$1"; }
house_archived_path() { printf '%s/%s.md' "$HOUSE_ARCHIVED" "$1"; }

# The chart for a slug, active or archived; prints nothing and fails when
# neither exists.
house_find_area() {
  local p
  p=$(house_area_path "${1:-}")
  if [ -f "$p" ]; then
    printf '%s' "$p"
    return 0
  fi
  p=$(house_archived_path "${1:-}")
  if [ -f "$p" ]; then
    printf '%s' "$p"
    return 0
  fi
  return 1
}

# The active chart for a slug, or die. Diagnostics and prescribing only ever
# act on an active area; `show` is the one verb that also reads the archived.
house_require_area() {
  house_slug_ok "${1:-}" || foreman_die "bad area slug: ${1:-<none>} (lowercase letters, digits and dashes; max 32)"
  local p
  p=$(house_area_path "$1")
  [ -f "$p" ] || foreman_die "no such area: $1"
  printf '%s' "$p"
}

# One header field, or nothing. Anchored so a log line can never answer for a
# field.
house_field() { # <path> <key>
  sed -n "s/^$2: //p" "$1" 2>/dev/null | head -n 1
}

# Replace a header field in place, inserting it before "## Log" when the chart
# does not have it yet (a hand-edited or hand-written chart). Atomic via a
# temp file and mv, so a reader never sees half a chart.
house_set_field() { # <path> <key> <value>
  local path=$1 key=$2 value=$3 tmp
  tmp="$path.tmp.$$"
  awk -v key="$key" -v val="$value" '
    BEGIN { done = 0; seen_log = 0 }
    {
      if (index($0, key ":") == 1) { print key ": " val; done = 1; next }
      if (!seen_log && $0 ~ /^## Log/) {
        if (!done) { print key ": " val; done = 1 }
        seen_log = 1
      }
      print
    }
    END { if (!done) print key ": " val }
  ' "$path" >"$tmp" && mv "$tmp" "$path"
}

# Append a dated line to the log, ending with a newline even if the file did
# not.
house_log_append() { # <path> <date> <text>
  local path=$1 date=$2 text=$3
  [ -z "$(tail -c 1 "$path" 2>/dev/null)" ] || printf '\n' >>"$path"
  printf -- '- %s - %s\n' "$date" "$text" >>"$path"
}

house_today() { date +%Y-%m-%d; }
house_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
house_ts() { date -u +%Y%m%dT%H%M%SZ; }

# A YYYY-MM-DD date to epoch, GNU or BSD date.
house_epoch_date() { # <YYYY-MM-DD>
  date -j -f '%Y-%m-%d' "$1" +%s 2>/dev/null ||
    date -d "$1" +%s 2>/dev/null || printf ''
}

# Days since the chart was last touched; empty when the date is unreadable.
house_age_days() { # <path>
  local updated since now
  updated=$(house_field "$1" updated)
  [ -n "$updated" ] || return 1
  since=$(house_epoch_date "$updated")
  [ -n "$since" ] || return 1
  now=$(date +%s)
  printf '%s' "$(((now - since) / 86400))"
}

# Every active slug, sorted. With --all, archived slugs follow and are marked
# by the caller via the path it reads.
house_slugs() { # [--all]
  local d
  [ -d "$HOUSE_AREAS" ] || {
    [ "${1:-}" = --all ] && [ -d "$HOUSE_ARCHIVED" ] || return 0
  }
  if [ -d "$HOUSE_AREAS" ]; then
    for d in "$HOUSE_AREAS"/*.md; do
      [ -e "$d" ] || continue
      basename "$d" .md
    done
  fi
  if [ "${1:-}" = --all ] && [ -d "$HOUSE_ARCHIVED" ]; then
    for d in "$HOUSE_ARCHIVED"/*.md; do
      [ -e "$d" ] || continue
      basename "$d" .md
    done
  fi
}

# The newest outbox file for a slug, or nothing.
house_latest_outbox() { # <slug>
  local f best='' best_key=''
  [ -d "$HOUSE_OUTBOX" ] || return 0
  for f in "$HOUSE_OUTBOX/$1"-*.md; do
    [ -e "$f" ] || continue
    if [ -z "$best_key" ] || [ "$f" \> "$best_key" ]; then
      best=$f
      best_key=$f
    fi
  done
  [ -n "$best" ] && printf '%s' "$best"
  # Always succeed: an absent outbox is a normal answer, and a nonzero here
  # would abort a caller under `set -e` before it could explain what is missing.
  return 0
}
