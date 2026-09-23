#!/usr/bin/env bash
# crew-doctor.sh - check this machine before a session starts.
#
# Usage: crew-doctor.sh [--quiet]
#
# Verifies the tools the foreman cannot run without, the Herdr server it talks
# to, and the two tools only some deliveries need. `--quiet` prints only
# problems plus one verdict line, so a session-start hook can run it without
# noise; it always prints the verdict, so a caller can tell healthy from not.
#
# Exit 0 when every required check passed (warnings allowed), 1 otherwise.
set -eu

. "$(cd "$(dirname "$0")" && pwd)/foreman-lib.sh"

QUIET=0
[ "${1:-}" = "--quiet" ] && QUIET=1

FAILED=0
WARNED=0

line() { # <level> <name> <detail>
  local level=$1 name=$2 detail=${3:-}
  case "$level" in
  ok) [ "$QUIET" = 1 ] && return 0 ;;
  warn) WARNED=$((WARNED + 1)) ;;
  FAIL) FAILED=$((FAILED + 1)) ;;
  esac
  printf '  %-5s %-13s %s\n' "$level" "$name" "$detail"
}

have() { command -v "$1" >/dev/null 2>&1; }

[ "$QUIET" = 1 ] || printf 'crew-doctor: %s (session %s)\n' "$FOREMAN_ROOT" "$FOREMAN_SESSION"

# Required: every one of these is on the path of an ordinary session.
for tool in herdr jq git pi; do
  if have "$tool"; then
    line ok "$tool" "$(command -v "$tool")"
  else
    line FAIL "$tool" "not on PATH"
  fi
done

# The server is what actually runs the panes; the CLI existing is not enough.
if have herdr; then
  status=$(herdr --session "$FOREMAN_SESSION" status --json 2>/dev/null) || status=
  if [ -z "$status" ]; then
    line FAIL "herdr server" "status did not answer; is herdr installed correctly?"
  elif have jq; then
    running=$(printf '%s' "$status" | jq -r '.server.running // false' 2>/dev/null)
    version=$(printf '%s' "$status" | jq -r '.server.version // "?"' 2>/dev/null)
    if [ "$running" = true ]; then
      line ok "herdr server" "running $version (session $FOREMAN_SESSION)"
      [ "$(printf '%s' "$status" | jq -r '.server.server_binary_stale // false' 2>/dev/null)" = true ] &&
        line warn "herdr server" "server binary is stale; restart it when convenient"
    else
      line FAIL "herdr server" "no server is running; crew cannot be launched"
    fi
  fi
fi

# gh and its auth are only needed for pull-request delivery, so a problem here
# is a warning: report and local delivery still work.
if have gh; then
  line ok gh "$(command -v gh)"
  if gh auth status >/dev/null 2>&1; then
    line ok "gh auth" "authenticated"
  else
    line warn "gh auth" "not authenticated; pull-request delivery will fail"
  fi
else
  line warn gh "not on PATH; pull-request delivery is unavailable"
fi

# Lavish boards are optional: only a visual deliverable needs them.
if have lavish-axi; then
  line ok lavish-axi "$(command -v lavish-axi)"
else
  line warn lavish-axi "not on PATH; review boards are unavailable"
fi

# State must be writable, and projects/ is where crew work comes from.
if mkdir -p "$FOREMAN_HOME" 2>/dev/null && [ -w "$FOREMAN_HOME" ]; then
  line ok "state" "$FOREMAN_HOME"
else
  line FAIL "state" "$FOREMAN_HOME is not writable"
fi
if [ -d "$FOREMAN_PROJECTS" ]; then
  line ok projects "$FOREMAN_PROJECTS"
else
  line warn projects "missing; no project work until a repo is cloned there"
fi

if [ "$FAILED" -gt 0 ]; then
  printf 'crew-doctor: %s problem(s)\n' "$FAILED"
  exit 1
fi
if [ "$WARNED" -gt 0 ]; then
  printf 'crew-doctor: ready (%s warning(s))\n' "$WARNED"
  exit 0
fi
printf 'crew-doctor: ok\n'
