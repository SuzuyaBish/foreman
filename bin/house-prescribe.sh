#!/usr/bin/env bash
# house-prescribe.sh - write the ready-to-paste prompt for an area.
#
# Usage: house-prescribe.sh <slug> [--copy] [--stdout] [--context FILE]
#        house-prescribe.sh --help
#
# The prescription is assembled from the chart so a fresh chat needs nothing
# else: what the area is, where it stands, the diagnosed next step, and the
# captain's standing conventions. stdout is exactly the prompt, so it is
# paste-ready and pipe-ready; the outbox path and clipboard news go to stderr.
# `--stdout` skips the outbox for a pure pipe; `--copy` puts it on the
# clipboard and degrades with a clear message when no clipboard tool exists.
set -eu

. "$(cd "$(dirname "$0")" && pwd)/house-lib.sh"

usage() {
  cat <<'EOF'
usage: house-prescribe.sh <slug> [--copy] [--stdout] [--context FILE]

Print a paste-ready prompt for <slug> built from its chart, and write it to the
outbox. --copy also puts it on the clipboard (pbcopy, xclip or wl-copy), and
does not fail when none is available. --stdout skips the outbox write.
--context FILE appends that file as extra context.
EOF
}

house_clip_copy() { # stdin -> clipboard; 127 when no tool exists, else the tool's code
  HOUSE_CLIP_TOOL=
  if command -v pbcopy >/dev/null 2>&1; then
    HOUSE_CLIP_TOOL=pbcopy
    pbcopy
  elif command -v xclip >/dev/null 2>&1; then
    HOUSE_CLIP_TOOL=xclip
    xclip -selection clipboard
  elif command -v wl-copy >/dev/null 2>&1; then
    HOUSE_CLIP_TOOL=wl-copy
    wl-copy
  else
    return 127
  fi
}

case "${1:-}" in
-h | --help)
  usage
  exit 0
  ;;
esac

SLUG=${1:-}
[ -n "$SLUG" ] || house_die "usage: house-prescribe.sh <slug> [--copy] [--stdout] [--context FILE]"
shift

COPY=0
TO_STDOUT=0
CONTEXT=
while [ $# -gt 0 ]; do
  case "$1" in
  --copy)
    COPY=1
    shift
    ;;
  --stdout)
    TO_STDOUT=1
    shift
    ;;
  --context)
    [ $# -ge 2 ] || house_die "--context requires a file"
    CONTEXT=$2
    shift 2
    ;;
  *) house_die "unknown prescribe option: $1 (try --help)" ;;
  esac
done

path=$(house_require_area "$SLUG")
TITLE=$(house_field "$path" title)
KIND=$(house_field "$path" kind)
WHERE=$(house_field "$path" where)
UPDATED=$(house_field "$path" updated)
STATUS=$(house_field "$path" status)
NEXT=$(house_trim "$(house_field "$path" next)")

[ -n "$NEXT" ] || house_die "area $SLUG has no diagnosed next step; run: house-next.sh $SLUG <step>"
[ -n "$TITLE" ] || TITLE=$SLUG
[ -n "$KIND" ] || KIND=other
[ -n "$WHERE" ] || WHERE="not recorded"
[ -n "$STATUS" ] || STATUS="No status recorded."
[ -n "$UPDATED" ] || UPDATED="unknown"

CONTEXT_BLOCK=""
if [ -n "$CONTEXT" ]; then
  [ -f "$CONTEXT" ] || house_die "no such context file: $CONTEXT"
  CONTEXT_BLOCK=$(cat <<EOF

Extra context (from $CONTEXT):

$(cat "$CONTEXT")
EOF
)
fi

case "$KIND" in
repo)
  DELIVERY="This area is a repository. Commit on a branch, push it, and open a
pull request; nothing is delivered until the captain merges it. Leave the
branch in place afterwards."
  WHERE_LINE="$WHERE (a repository)"
  ;;
chat)
  DELIVERY="This area lives in its own chat, not a repository. Write the result to a
report file and reply with its path; do not open a pull request."
  WHERE_LINE="$WHERE"
  ;;
*)
  DELIVERY="This area is not a repository. Write the result to a report file and reply
with its path; do not open a pull request."
  WHERE_LINE="$WHERE"
  ;;
esac

tmp=$(mktemp "${TMPDIR:-/tmp}/house-prescribe.XXXXXX")
trap 'rm -f "$tmp"' EXIT
cat >"$tmp" <<EOF
House prescription - $TITLE

You are picking up one of the captain's ongoing areas. Work only on the
diagnosed next step below; do not widen the scope without asking.

Area: $TITLE ($SLUG)
Kind: $KIND
Where: $WHERE_LINE
Last touched: $UPDATED

Where it stands:
$STATUS

Diagnosed next step:
$NEXT

Standing conventions:
- Contract first: before changing anything, state what "done" means for this
  step in a line or two, then do exactly that.
- Evidence over assertion: show the command you ran and its output, or the
  diff, rather than claiming it works.
- Keep it scoped: no opportunistic refactors, no unrelated cleanup.
- Report one line at the end: what changed, the evidence, and what is still
  open.

Delivery:
$DELIVERY

Start with the next step above. If it is wrong or already done, say so before
improvising a different one.
$CONTEXT_BLOCK
EOF

if [ "$TO_STDOUT" -eq 0 ]; then
  mkdir -p "$HOUSE_OUTBOX"
  base="$SLUG-$(house_ts)"
  file="$HOUSE_OUTBOX/$base.md"
  n=2
  while [ -e "$file" ]; do
    file="$HOUSE_OUTBOX/$base-$n.md"
    n=$((n + 1))
  done
  cp "$tmp" "$file"
  printf 'house: wrote %s\n' "$file" >&2
fi

if [ "$COPY" -eq 1 ]; then
  if house_clip_copy <"$tmp"; then
    printf 'house: copied to clipboard\n' >&2
  else
    clip_rc=$?
    if [ "$clip_rc" -eq 127 ]; then
      printf 'house: no clipboard tool (pbcopy, xclip, wl-copy) on PATH; the prescription is above\n' >&2
    else
      printf 'house: clipboard tool %s failed (exit %s); the prescription is above\n' \
        "${HOUSE_CLIP_TOOL:-?}" "$clip_rc" >&2
    fi
  fi
fi

cat "$tmp"
