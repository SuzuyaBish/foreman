#!/usr/bin/env bash
# crew-test.sh - run the foreman behaviour tests.
#
# Usage: crew-test.sh [<test-file> ...]
#        crew-test.sh --list
#
# With no arguments, every tests/*.test.sh runs in sorted order, each in its own
# process and its own isolated foreman home. A test file is one subject: it
# prints `ok -` lines and exits non-zero on the first failed assertion, and the
# runner reports one PASS/FAIL per file with its captured output.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TESTS_DIR="$ROOT/tests"

LIST=0
SELECTED=()
while [ $# -gt 0 ]; do
  case "$1" in
  --list) LIST=1; shift ;;
  -h | --help)
    sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  -*)
    printf 'crew-test: unknown option: %s\n' "$1" >&2
    exit 2
    ;;
  *)
    SELECTED+=("$1")
    shift
    ;;
  esac
done

if [ "$LIST" = 1 ]; then
  for t in "$TESTS_DIR"/*.test.sh; do
    [ -e "$t" ] || continue
    printf '%s\n' "$t"
  done
  exit 0
fi

if [ "${#SELECTED[@]}" -eq 0 ]; then
  for t in "$TESTS_DIR"/*.test.sh; do
    [ -e "$t" ] || continue
    SELECTED+=("$t")
  done
fi

[ "${#SELECTED[@]}" -gt 0 ] || {
  printf 'crew-test: no test files found in %s\n' "$TESTS_DIR" >&2
  exit 1
}

TOTAL=0
FAILED=0
SUITE_START=$SECONDS
FAILED_NAMES=()

for t in "${SELECTED[@]}"; do
  # A relative path is resolved against the repo root so the runner can be
  # called from anywhere.
  case "$t" in
  /*) path=$t ;;
  *) path="$ROOT/$t" ;;
  esac
  [ -f "$path" ] || {
    printf 'crew-test: no such test: %s\n' "$t" >&2
    FAILED=$((FAILED + 1))
    FAILED_NAMES+=("$t (missing)")
    continue
  }
  name=${path#"$TESTS_DIR"/}
  TOTAL=$((TOTAL + 1))
  out=$(mktemp "${TMPDIR:-/tmp}/crew-test-out.XXXXXX")
  start=$SECONDS
  if bash "$path" >"$out" 2>&1; then
    status=0
  else
    status=$?
  fi
  dur=$((SECONDS - start))
  if [ "$status" -eq 0 ]; then
    printf 'PASS  %-34s %ss\n' "$name" "$dur"
    sed 's/^/      /' "$out"
  else
    FAILED=$((FAILED + 1))
    FAILED_NAMES+=("$name")
    printf 'FAIL  %-34s %ss (exit %s)\n' "$name" "$dur" "$status"
    sed 's/^/      /' "$out"
  fi
  rm -f "$out"
done

printf '\n%d test file(s) · %d failed · %ss\n' "$TOTAL" "$FAILED" "$((SECONDS - SUITE_START))"
if [ "$FAILED" -gt 0 ]; then
  printf 'failed: %s\n' "${FAILED_NAMES[*]}"
  exit 1
fi
