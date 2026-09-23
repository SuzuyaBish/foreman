#!/usr/bin/env bash
# crew-board.sh - scaffold and check a Lavish review board.
#
# Usage: crew-board.sh new <out.html>
#        crew-board.sh check <board.html> [--text-only]
#
# `new` copies the foreman board template into place. `check` lints a board for
# the two faults that reached the captain on a hand-built board, and is run by
# crew-lavish.sh before a board opens:
#
#   * a board that declares NO choices. Lavish draws no pick UI of its own; a
#     page that never calls window.lavish.queuePrompt() gives the captain nothing
#     to click. This is a hard refusal, because it is the norm the brief states -
#     "a board with no pick blocks is not ready to open". A deliberately
#     text-only board is legitimate, so `--text-only` proceeds.
#
#   * an overlay that can bleed out of its own box: an absolutely positioned
#     ::before/::after with no overflow:hidden anywhere to clip it, or the
#     two-classes-on-an-ancestor selector that made our first safe-margin
#     override silently never apply. These are warnings, not refusals: the
#     artifact may clip another way, and a warning should not hold the captain's
#     review hostage.
set -eu

. "$(cd "$(dirname "$0")" && pwd)/foreman-lib.sh"

TEMPLATE="$FOREMAN_ROOT/assets/board-template.html"

usage() {
  printf 'usage: crew-board.sh new <out.html>\n' >&2
  printf '       crew-board.sh check <board.html> [--text-only]\n' >&2
  exit 2
}

has() { grep -qE -- "$1" "$2"; } # has <regex> <file>

# strip_comments: write the artifact with HTML (`<!-- -->`) and CSS/JS block
# (`/* */`) comments removed. The checks below must read what the browser runs,
# not prose: a comment that says "queuePrompt" must not satisfy the choices
# check, and one that says "overflow: hidden" must not silence the overlay check.
# (`//` line comments are left in place: stripping them risks a URL's `https://`.)
strip_comments() {
  awk '
    BEGIN { html = 0; css = 0 }
    {
      line = $0; out = ""
      while (length(line) > 0) {
        if (html) {
          i = index(line, "-->"); if (i == 0) { line = ""; break }
          line = substr(line, i + 3); html = 0
        } else if (css) {
          i = index(line, "*/"); if (i == 0) { line = ""; break }
          line = substr(line, i + 2); css = 0
        } else {
          ih = index(line, "<!--"); ic = index(line, "/*")
          if (ih == 0 && ic == 0) { out = out line; line = ""; break }
          if (ih != 0 && (ic == 0 || ih < ic)) {
            out = out substr(line, 1, ih - 1); line = substr(line, ih + 4); html = 1
          } else {
            out = out substr(line, 1, ic - 1); line = substr(line, ic + 2); css = 1
          }
        }
      }
      print out
    }'
}

ACTION=${1:-}
case "$ACTION" in
new)
  OUT=${2:-}
  [ -n "$OUT" ] || usage
  [ -f "$TEMPLATE" ] || foreman_die "board template is missing: $TEMPLATE"
  if [ -e "$OUT" ]; then
    foreman_die "refusing to overwrite existing file: $OUT"
  fi
  cp "$TEMPLATE" "$OUT"
  printf 'wrote %s from %s\n' "$OUT" "$TEMPLATE"
  printf 'replace the sample content, keep the forms wired, then: crew-board.sh check %s\n' "$OUT"
  ;;
check)
  FILE=${2:-}
  [ -n "$FILE" ] || usage
  shift 2 || true
  TEXT_ONLY=0
  while [ $# -gt 0 ]; do
    case "$1" in
    --text-only) TEXT_ONLY=1 ;;
    *) usage ;;
    esac
    shift
  done
  [ -f "$FILE" ] || foreman_die "no such board artifact: $FILE"

  STRIPPED=$(mktemp "${TMPDIR:-/tmp}/crew-board.XXXXXX")
  trap 'rm -f "$STRIPPED"' EXIT
  strip_comments <"$FILE" >"$STRIPPED"

  # 1. Does it declare choices? A board declares a choice either with a
  #    `data-lavish-question` form (single choice) or with a `queueKey` in the
  #    options its dispatch button passes to queuePrompt (multi-pick). Either
  #    way it must actually call queuePrompt, or the control does nothing.
  questions=$(grep -oE 'data-lavish-question=' "$STRIPPED" | wc -l | tr -d ' ')
  declares_choice=0
  if has 'data-lavish-question=|queueKey:' "$STRIPPED" && has 'queuePrompt\(' "$STRIPPED"; then
    declares_choice=1
  fi

  if [ "$declares_choice" != 1 ] && [ "$TEXT_ONLY" != 1 ]; then
    cat >&2 <<EOF
board-check: refused - this board declares no choices.
  A Lavish board has no pick UI of its own: with no data-lavish-question form
  and no queueKey passed to queuePrompt, the captain has nothing to click.
  Build it from the foreman template (\`crew-board.sh new <out.html>\`), or pass
  --text-only to open a deliberately static board.
EOF
    exit 1
  fi

  # 2. Overlay bleed. `::before`/`::after` positioned absolutely, with a fixed
  #    pixel size, needs `overflow: hidden` on its anchor; and the small-frame
  #    override must not use two compounded classes on an ancestor.
  warnings=0
  overlay=0
  if has '::(before|after)' "$STRIPPED" && has 'position:[[:space:]]*absolute' "$STRIPPED"; then
    overlay=1
  fi
  clipped=0
  if has 'overflow:[[:space:]]*hidden' "$STRIPPED"; then clipped=1; fi
  if [ "$overlay" = 1 ] && [ "$clipped" != 1 ]; then
    printf 'board-check: warn - an absolutely positioned ::before/::after overlay is present but\n' >&2
    printf '  the board declares no `overflow: hidden`. A fixed-size overlay can paint outside its box\n' >&2
    printf '  (the safe-margin guides did). Add `overflow: hidden` to the frame that anchors it.\n' >&2
    warnings=$((warnings + 1))
  fi
  if has '\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+[[:space:]]+[^,{]*::(before|after)' "$STRIPPED"; then
    printf 'board-check: warn - a ::before/::after selector compounds two classes on an ancestor\n' >&2
    printf '  (like `.a.b .frame::before`). That only matches if one element carries both classes;\n' >&2
    printf '  put the modifier class on the element the guide is anchored to instead.\n' >&2
    warnings=$((warnings + 1))
  fi

  if [ "$warnings" -gt 0 ]; then
    printf 'board-check: %s warning%s above - opening anyway\n' "$warnings" \
      "$([ "$warnings" = 1 ] && printf '' || printf 's')" >&2
  fi
  overlay_note=
  [ "$overlay" = 1 ] && overlay_note=', overlay checked'
  if [ "$TEXT_ONLY" = 1 ]; then
    printf 'board-check: ok - text-only board (no choices declared)%s\n' "$overlay_note"
  elif [ "$questions" = 1 ]; then
    printf 'board-check: ok - 1 declared question%s\n' "$overlay_note"
  else
    printf 'board-check: ok - %s declared questions%s\n' "$questions" "$overlay_note"
  fi
  exit 0
  ;;
*)
  usage
  ;;
esac
