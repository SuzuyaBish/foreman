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

# House speaks as House, never as the foreman: a refusal from a house script
# must not name a different persona. `FOREMAN_MODE=house` is the launcher's
# marker, but the voice is House's regardless of how the script was reached.
house_die() {
  printf 'house: %s\n' "$*" >&2
  exit 1
}

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
# neither exists. The slug is validated here too, so a traversal like
# `show ../secret` can never reach a file outside the chart.
house_find_area() {
  house_slug_ok "${1:-}" || return 1
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
  house_slug_ok "${1:-}" || house_die "bad area slug: ${1:-<none>} (lowercase letters, digits and dashes; max 32)"
  local p
  p=$(house_area_path "$1")
  [ -f "$p" ] || house_die "no such area: $1"
  printf '%s' "$p"
}

# One header field, or nothing. Anchored so a log line can never answer for a
# field, and only the first when a hand-edited chart carries a duplicate.
house_field() { # <path> <key>
  sed -n "s/^$2: //p" "$1" 2>/dev/null | head -n 1
}

# Chart fields are one physical line each. A value carrying a newline or tab
# would inject a second field or split the log, so every path that writes a
# field runs the value through here first. A carriage return is refused with
# them: a CRLF value would otherwise read back with a trailing CR.
house_sanitize_field() { # <key> <value> -> prints the value, or dies
  local key=${1:-field} value=${2-}
  case "$value" in
  *$'\n'* | *$'\t'* | *$'\r'*)
    house_die "$key must be one line (no newline, carriage return or tab)"
    ;;
  esac
  printf '%s' "$value"
}

# A log line is one line too, but a note is prose: flatten rather than refuse,
# so a multi-line thought still charts as one dated line.
house_flatten_log() { # <text>
  printf '%s' "${1-}" | tr '\t\r\n' '   '
}

# Whitespace with nothing in it is not a next step. Fold it to empty before any
# guard tests it, so `[no next]` and prescribe's check cannot be defeated by
# spaces.
house_trim() { # <text>
  printf '%s' "${1-}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

# One writer per chart, the same mkdir primitive crew-send.sh uses for the
# inbox: atomic everywhere that matters, and it gives up rather than wait
# forever behind a writer that died holding it.
house_lock_acquire() { # <lock-dir>
  local i
  for i in $(seq 1 400); do
    mkdir "$1" 2>/dev/null && return 0
    sleep 0.05
  done
  return 1
}

# The one writer. Every field set and every log append goes through here, under
# a per-chart lock, rewriting the whole chart with a temp and mv so no reader
# ever sees it half-written and no writer can lose another's append. Values
# reach awk through a tab-separated directives file, never `-v`, so a backslash
# stays a backslash instead of becoming an escape. A key's first line is
# replaced and its later duplicates dropped, so a hand-edited duplicate heals
# on the next write. Missing fields go before "## Log", or before the first log
# line, or a "## Log" header is created; the log lines are appended last.
house_edit() { # <path> [--set <key> <value>]... [--log <date> <text>]...
  local path=$1
  shift
  [ -f "$path" ] || house_die "no such chart: $path"

  local dirs tmp lock
  dirs=$(mktemp "${TMPDIR:-/tmp}/house-edit.XXXXXX") || house_die "could not stage chart edits"
  tmp="$path.tmp.$$"
  lock="$path.lock"
  # shellcheck disable=SC2064 # expand the temp names now, not at trap time
  trap 'rm -rf "$lock" "$tmp" "$dirs"' EXIT

  while [ $# -gt 0 ]; do
    case "$1" in
    --set)
      [ $# -ge 3 ] || house_die "internal: house_edit --set needs a key and a value"
      local sval
      # Capture first: a command substitution inside printf would swallow the
      # sanitizer's failure and write a half-checked directive.
      sval=$(house_sanitize_field "$2" "$3") || exit 1
      printf 'S\t%s\t%s\n' "$2" "$sval" >>"$dirs"
      shift 3
      ;;
    --log)
      [ $# -ge 3 ] || house_die "internal: house_edit --log needs a date and text"
      local lval
      lval=$(house_flatten_log "$3") || exit 1
      printf 'L\t%s\t%s\n' "$2" "$lval" >>"$dirs"
      shift 3
      ;;
    *)
      house_die "internal: bad house_edit operation: $1"
      ;;
    esac
  done

  house_lock_acquire "$lock" || house_die "could not lock chart $path (another writer is busy)"

  if ! awk -F '\t' '
    FILENAME == ARGV[1] {
      if ($1 == "S") { skey[$2] = $3; if (!($2 in order)) order[++n] = $2 }
      else if ($1 == "L") { ldate[++m] = $2; ltext[m] = $3 }
      next
    }
    {
      isfield = ""
      for (i = 1; i <= n; i++) {
        k = order[i]
        if (index($0, k ":") == 1) { isfield = k; break }
      }
      if (isfield != "") {
        if (!(isfield in placed)) { print isfield ": " skey[isfield]; placed[isfield] = 1 }
        next
      }
      is_header = ($0 ~ /^## Log/) ? 1 : 0
      is_log = ($0 ~ /^- /) ? 1 : 0
      if (!inserted && (is_header || is_log)) {
        for (i = 1; i <= n; i++) {
          k = order[i]
          if (!(k in placed)) { print k ": " skey[k]; placed[k] = 1 }
        }
        if (!header_seen && !is_header) { print ""; print "## Log"; emitted_header = 1 }
        inserted = 1
      }
      if (is_header) { header_seen = 1; emitted_header = 1 }
      print
    }
    END {
      if (!inserted) {
        for (i = 1; i <= n; i++) {
          k = order[i]
          if (!(k in placed)) { print k ": " skey[k]; placed[k] = 1 }
        }
      }
      if (m > 0) {
        if (!emitted_header) { print ""; print "## Log" }
        for (i = 1; i <= m; i++) print "- " ldate[i] " - " ltext[i]
      }
    }
  ' "$dirs" "$path" >"$tmp"; then
    house_die "could not write chart $path"
  fi

  mv "$tmp" "$path"
  rm -rf "$lock"
  rm -f "$dirs"
  trap - EXIT
}

# One convention, UTC everywhere. `updated` is written as a UTC civil date and
# the age is a difference of UTC calendar days, so the stale boundary does not
# move with the reader's TZ.
house_today() { date -u +%Y-%m-%d; }
house_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
house_ts() { date -u +%Y%m%dT%H%M%SZ; }

# A YYYY-MM-DD date to epoch at UTC midnight, GNU or BSD date.
house_epoch_date() { # <YYYY-MM-DD>
  TZ=UTC0 date -j -f '%Y-%m-%d' "$1" +%s 2>/dev/null ||
    TZ=UTC0 date -d "$1" +%s 2>/dev/null || printf ''
}

# Whole UTC calendar days since the chart was last written. Negative for a date
# in the future, empty when the date is unreadable. Calendar days, not elapsed
# seconds, so `house_today` and the field are always read the same way.
house_age_days() { # <path>
  local updated since today today_epoch
  updated=$(house_field "$1" updated)
  [ -n "$updated" ] || return 1
  since=$(house_epoch_date "$updated")
  [ -n "$since" ] || return 1
  today=$(house_today)
  today_epoch=$(house_epoch_date "$today")
  [ -n "$today_epoch" ] || return 1
  printf '%s' "$(((today_epoch - since) / 86400))"
}

# A compact relative age for the glanceable rows: `2d`, `0d`. A future date reads
# as `0d`; the caller's marks say `[future]`.
house_age_label() { # <path>
  local age
  age=$(house_age_days "$1" 2>/dev/null || printf '')
  [ -n "$age" ] || return 1
  [ "$age" -lt 0 ] && age=0
  printf '%s' "${age}d"
}

# Clip a one-line field for a compact table: at most <width> characters, with an
# ellipsis when it was cut. `area show` prints the file whole; only the
# glanceable rows clip.
house_clip() { # <text> <width>
  local text=${1-} width=${2:-40}
  if [ "${#text}" -le "$width" ]; then
    printf '%s' "$text"
  else
    printf '%s…' "${text:0:$((width - 1))}"
  fi
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
