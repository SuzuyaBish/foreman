#!/usr/bin/env bash
# tests/lib.sh - shared helpers for the foreman behaviour tests.
#
# Sourced by every tests/<subject>.test.sh. Provides reporters, assertions,
# self-cleaning temp roots, an isolated foreman home, and fake `herdr`, `gh`,
# `pi` and `lavish-axi` binaries so a test can drive the real scripts without
# touching a live Herdr session, a real repository, or the captain's pi state.
set -u

# shellcheck disable=SC2034 # ROOT and BIN are consumed by the sourcing tests.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC2034
BIN="$ROOT/bin"
# --- reporters --------------------------------------------------------------

# A failed assertion aborts the file: each test file owns one subject and is
# reported by the runner as a single pass/fail, with its output attached.
fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

# --- assertions -------------------------------------------------------------

# assert_equals <expected> <actual> <msg>
assert_equals() {
  [ "$1" = "$2" ] || fail "$3 (expected '$1', got '$2')"
}

# assert_not_equals <unexpected> <actual> <msg>
assert_not_equals() {
  [ "$1" != "$2" ] || fail "$3 (unexpectedly got '$1')"
}

# assert_contains <haystack> <needle> <msg>
assert_contains() {
  case "$1" in
  *"$2"*) : ;;
  *)
    fail "$3 (missing: '$2')"
    ;;
  esac
}

# assert_not_contains <haystack> <needle> <msg>
assert_not_contains() {
  case "$1" in
  *"$2"*) fail "$3 (unexpected: '$2')" ;;
  esac
}

# expect_code <expected> <actual> <label>
expect_code() {
  [ "$1" = "$2" ] || fail "$3 (expected exit $1, got $2)"
}

# assert_grep <fixed-string> <file> <msg>
assert_grep() {
  grep -F -- "$1" "$2" >/dev/null || fail "$3"
}

# assert_no_grep <fixed-string> <file> <msg>
assert_no_grep() {
  ! grep -F -- "$1" "$2" >/dev/null || fail "$3"
}

# assert_present <path> <msg> / assert_absent <path> <msg>
assert_present() { [ -e "$1" ] || fail "$2"; }
assert_absent() { [ ! -e "$1" ] || fail "$2"; }

# --- self-cleaning temp roots -----------------------------------------------
#
# fm_tmproot is almost always called as `X=$(fm_tmproot prefix)`, so it must
# register through a file rather than shell state that dies with the subshell.
FM_TEST_REGISTRY=$(mktemp "${TMPDIR:-/tmp}/.foreman-test.$$.XXXXXX") || exit 1

fm_test_cleanup() {
  if [ -f "$FM_TEST_REGISTRY" ]; then
    while IFS= read -r d; do
      [ -n "$d" ] && rm -rf "$d"
    done <"$FM_TEST_REGISTRY"
    rm -f "$FM_TEST_REGISTRY"
  fi
}
trap fm_test_cleanup EXIT
trap 'fm_test_cleanup; exit 130' INT
trap 'fm_test_cleanup; exit 143' TERM

fm_tmproot() { # [prefix] -> fresh directory path
  local prefix=${1:-foreman-test} root
  root=$(mktemp -d "${TMPDIR:-/tmp}/${prefix}.XXXXXX") || return 1
  root=$(cd -P -- "$root" && pwd -P) || return 1
  printf '%s\n' "$root" >>"$FM_TEST_REGISTRY"
  printf '%s\n' "$root"
}

# --- isolated environment ---------------------------------------------------

# fm_home: create a throwaway foreman home/projects/worktrees and export the
# four env vars every foreman script honours. Prints the home path.
fm_home() {
  local root
  root=$(fm_tmproot fm-home) || return 1
  FOREMAN_HOME="$root/home"
  FOREMAN_PROJECTS="$root/projects"
  FOREMAN_WORKTREES="$root/worktrees"
  PI_TRUST_FILE="$root/trust.json"
  mkdir -p "$FOREMAN_HOME" "$FOREMAN_PROJECTS" "$FOREMAN_WORKTREES"
  FOREMAN_SESSION=${FOREMAN_SESSION:-default}
  # Herdr's ambient identity must never leak in: a test that inherits the
  # captain's pane, tab or socket would take a different path than a bare shell.
  unset HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_TAB_ID HERDR_PANE_ID
  export FOREMAN_HOME FOREMAN_PROJECTS FOREMAN_WORKTREES FOREMAN_SESSION PI_TRUST_FILE
  printf '%s\n' "$FOREMAN_HOME"
}

# fm_git_isolate: never let a fixture repository read the host's git config.
fm_git_isolate() {
  GIT_CONFIG_GLOBAL=/dev/null
  GIT_CONFIG_SYSTEM=/dev/null
  GIT_AUTHOR_NAME=foreman-test
  GIT_AUTHOR_EMAIL=foreman-test@example.test
  GIT_COMMITTER_NAME=foreman-test
  GIT_COMMITTER_EMAIL=foreman-test@example.test
  export GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM
  export GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
}

# fm_fakebin: a bin dir that goes first on PATH. Sets FM_FAKEBIN and PATH in
# the calling shell (never captured in a subshell, or the export would be lost).
fm_fakebin() {
  if [ -n "${FM_FAKEBIN:-}" ] && [ -d "${FM_FAKEBIN:-}" ]; then
    return 0
  fi
  local dir
  dir=$(fm_tmproot fm-fakebin) || return 1
  mkdir -p "$dir"
  FM_FAKEBIN="$dir"
  PATH="$FM_FAKEBIN:$PATH"
  export FM_FAKEBIN PATH
}

# fm_path_without <tool...>: a PATH that resolves everything the current PATH
# does except the named tools. Used to simulate a missing binary without
# dropping whole directories (which would also hide git, awk, jq, ...).
fm_path_without() {
  local dir src entry name skip tool
  local tools=("$@")
  dir=$(fm_tmproot fm-path-sans) || return 1
  local dirs
  IFS=: read -ra dirs <<<"$PATH"
  for src in "${dirs[@]}"; do
    [ -d "$src" ] || continue
    for entry in "$src"/*; do
      [ -e "$entry" ] || [ -L "$entry" ] || continue
      name=${entry##*/}
      [ -e "$dir/$name" ] && continue
      skip=0
      for tool in "${tools[@]}"; do
        if [ "$name" = "$tool" ]; then
          skip=1
          break
        fi
      done
      [ "$skip" -eq 1 ] && continue
      ln -s "$entry" "$dir/$name" 2>/dev/null || true
    done
  done
  printf '%s\n' "$dir"
}

# --- fake herdr -------------------------------------------------------------
#
# The stub keeps one file per pane under $HERDR_STUB_STATE, so pane existence is
# a file existence check and a test can "destroy" a pane by removing its file.
# Agent registration is separate: a pane exists until closed, but an agent can
# exit (fm_herdr_agent_exit) while the pane survives — the exact churn the
# recovery and liveness code has to tell apart.

fm_herdr_stub() {
  local state
  fm_fakebin || return 1
  state=$(fm_tmproot fm-herdr-state) || return 1
  HERDR_STUB_STATE="$state"
  export HERDR_STUB_STATE
  : >"$state/calls"
  cat >"$FM_FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
state=${HERDR_STUB_STATE:?herdr stub: HERDR_STUB_STATE unset}
mkdir -p "$state"
printf '%s\n' "$*" >>"$state/calls"

if [ "${1:-}" = --session ]; then shift 2; fi
cmd=${1:-}
shift || true

pane_exists() { [ -f "$state/pane-$1" ]; }
next_id() {
  local f="$state/seq-$1" n=0
  [ -f "$f" ] && n=$(cat "$f")
  n=$((n + 1))
  printf '%s\n' "$n" >"$f"
  printf '%s-%s' "$1" "$n"
}

case "$cmd" in
status)
  running=true
  [ -f "$state/server-down" ] && running=false
  stale=false
  [ -f "$state/server-stale" ] && stale=true
  jq -cn --argjson r "$running" --argjson s "$stale" \
    '{client:{version:"stub-0.9.1"},server:{running:$r,status:(if $r then "running" else "stopped" end),version:"stub-0.9.1",server_binary_stale:$s,compatible:true}}'
  ;;
workspace)
  sub=${1:-}
  shift || true
  case "$sub" in
  list)
    printf '{"result":{"workspaces":['
    first=1
    if [ -f "$state/workspaces" ]; then
      while IFS=$(printf '\t') read -r id label; do
        [ -n "$id" ] || continue
        [ "$first" = 1 ] || printf ','
        first=0
        jq -cn --arg i "$id" --arg l "$label" '{workspace_id:$i,label:$l}'
      done <"$state/workspaces"
    fi
    printf ']}}\n'
    ;;
  create)
    [ ! -f "$state/workspace-create-fail" ] || exit 1
    label= cwd=
    while [ $# -gt 0 ]; do
      case "$1" in
      --label) label=$2; shift 2 ;;
      --cwd) cwd=$2; shift 2 ;;
      --no-focus) shift ;;
      *) shift ;;
      esac
    done
    id=$(next_id ws)
    tab=$(next_id tab)
    pane=$(next_id pane)
    printf 'tab=%s\ncwd=%s\nlabel=%s\n' "$tab" "$cwd" "$label" >"$state/pane-$pane"
    printf '%s\n' "$pane" >>"$state/ws-$id"
    printf '%s\t%s\n' "$id" "${label:-}" >>"$state/workspaces"
    # Herdr answers with the workspace, its seeded tab, and that tab's root pane.
    jq -cn --arg i "$id" --arg t "$tab" --arg p "$pane" \
      '{result:{workspace:{workspace_id:$i},tab:{tab_id:$t},root_pane:{pane_id:$p}}}'
    ;;
  get)
    id=${1:-}
    grep -q "^$id"$'\t' "$state/workspaces" 2>/dev/null || exit 1
    jq -cn --arg i "$id" '{result:{workspace:{workspace_id:$i}}}'
    ;;
  close)
    id=${1:-}
    grep -q "^$id"$'\t' "$state/workspaces" 2>/dev/null || exit 1
    if [ -f "$state/ws-$id" ]; then
      while IFS= read -r p; do
        [ -n "$p" ] && rm -f "$state/pane-$p"
      done <"$state/ws-$id"
      rm -f "$state/ws-$id"
    fi
    grep -v "^$id"$'\t' "$state/workspaces" >"$state/workspaces.tmp" 2>/dev/null || :
    mv "$state/workspaces.tmp" "$state/workspaces"
    printf '{"result":{}}\n'
    ;;
  *) exit 1 ;;
  esac
  ;;
tab)
  sub=${1:-}
  shift || true
  case "$sub" in
  create)
    cwd= label=
    while [ $# -gt 0 ]; do
      case "$1" in
      --workspace) shift 2 ;;
      --cwd) cwd=$2; shift 2 ;;
      --label) label=$2; shift 2 ;;
      --no-focus) shift ;;
      *) shift ;;
      esac
    done
    tab=$(next_id tab)
    pane=$(next_id pane)
    printf 'tab=%s\ncwd=%s\nlabel=%s\n' "$tab" "$cwd" "$label" >"$state/pane-$pane"
    jq -cn --arg t "$tab" --arg p "$pane" '{result:{tab:{tab_id:$t},root_pane:{pane_id:$p}}}'
    ;;
  rename)
    # <tab> <label>: the label of the seeded tab lives in its pane file.
    t=${1:-}
    label=${2:-}
    for f in "$state"/pane-*; do
      [ -f "$f" ] || continue
      if [ "$(sed -n 's/^tab=//p' "$f")" = "$t" ]; then
        cwd=$(sed -n 's/^cwd=//p' "$f")
        printf 'tab=%s\ncwd=%s\nlabel=%s\n' "$t" "$cwd" "$label" >"$f"
      fi
    done
    printf '{"result":{}}\n'
    ;;
  close)
    t=${1:-}
    for f in "$state"/pane-*; do
      [ -f "$f" ] || continue
      if [ "$(sed -n 's/^tab=//p' "$f")" = "$t" ]; then rm -f "$f"; fi
    done
    printf '{"result":{}}\n'
    ;;
  *) exit 1 ;;
  esac
  ;;
pane)
  sub=${1:-}
  shift || true
  case "$sub" in
  get)
    p=${1:-}
    pane_exists "$p" && printf '{"result":{"pane":{"pane_id":"%s"}}}\n' "$p" || exit 1
    ;;
  run)
    p=${1:-}
    shift || true
    pane_exists "$p" || exit 1
    printf '%s\t%s\n' "$p" "$*" >>"$state/runs"
    # A crew member that quits the agent leaves the pane but no agent.
    case "$*" in */quit*) : >"$state/no-agent-$p" ;; esac
    printf '{"result":{}}\n'
    ;;
  send-keys)
    p=${1:-}
    shift || true
    pane_exists "$p" || exit 1
    printf 'keys\t%s\t%s\n' "$p" "$*" >>"$state/runs"
    printf '{"result":{}}\n'
    ;;
  read)
    p=${1:-}
    shift || true
    n=200
    while [ $# -gt 0 ]; do
      case "$1" in
      --lines) n=$2; shift 2 ;;
      --source) shift 2 ;;
      *) shift ;;
      esac
    done
    [ -f "$state/content-$p" ] && tail -n "$n" "$state/content-$p"
    ;;
  *) exit 1 ;;
  esac
  ;;
agent)
  sub=${1:-}
  shift || true
  p=${1:-}
  if [ "$sub" = get ] && pane_exists "$p" && [ ! -f "$state/no-agent-$p" ]; then
    printf '{"result":{"agent":{"pane_id":"%s"}}}\n' "$p"
  else
    exit 1
  fi
  ;;
session)
  sub=${1:-}
  case "$sub" in
  list)
    jq -cn --arg s "$state/socket" \
      '{sessions:[{name:"default",running:true,socket_path:$s}]}'
    ;;
  *) exit 1 ;;
  esac
  ;;
*) exit 1 ;;
esac
SH
  chmod +x "$FM_FAKEBIN/herdr"
  # The workspace mover is socket-only in Herdr, so the tests substitute the
  # transport and watch the request instead of opening a socket.
  cat >"$FM_FAKEBIN/herdr-mover" <<'SH'
#!/usr/bin/env bash
set -u
state=${HERDR_STUB_STATE:?herdr mover stub: HERDR_STUB_STATE unset}
[ ! -f "$state/mover-fail" ] || exit 1
printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$state/moves"
SH
  chmod +x "$FM_FAKEBIN/herdr-mover"
  FOREMAN_HERDR_MOVER="$FM_FAKEBIN/herdr-mover"
  export FOREMAN_HERDR_MOVER
  printf '%s\n' "$state"
}

# fm_herdr_seed_workspace <id> <label>: a workspace that already exists before
# the test starts, as the captain's own always does.
fm_herdr_seed_workspace() {
  printf '%s\t%s\n' "$1" "${2:-}" >>"$HERDR_STUB_STATE/workspaces"
}

# fm_herdr_moves: every workspace.move the launch asked for, "<socket>\t<ws>\t<index>".
fm_herdr_moves() { cat "$HERDR_STUB_STATE/moves" 2>/dev/null || true; }

# fm_herdr_mover_fail: make every move request fail, to prove the fallback.
fm_herdr_mover_fail() { : >"$HERDR_STUB_STATE/mover-fail"; }

# fm_herdr_workspace_create_fail: a Herdr that cannot give a crew a workspace, so
# the launch has to fall back to the flat layout.
fm_herdr_workspace_create_fail() { : >"$HERDR_STUB_STATE/workspace-create-fail"; }

# fm_herdr_workspace_panes <id>: panes that live in a workspace.
fm_herdr_workspace_panes() { cat "$HERDR_STUB_STATE/ws-$1" 2>/dev/null || true; }

# fm_herdr_last_pane: the pane id of the most recently created tab.
fm_herdr_last_pane() {
  local f
  for f in "$HERDR_STUB_STATE"/pane-*; do :; done
  [ -f "$f" ] || return 1
  printf '%s\n' "${f##*/pane-}"
}

# fm_herdr_kill_pane <pane>: the pane is gone (tab destroyed / endpoint lost).
fm_herdr_kill_pane() { rm -f "$HERDR_STUB_STATE/pane-$1"; }

# fm_herdr_agent_exit <pane>: the pane survives, its agent does not.
fm_herdr_agent_exit() { : >"$HERDR_STUB_STATE/no-agent-$1"; }

# fm_herdr_calls: every stub invocation, one per line.
fm_herdr_calls() { cat "$HERDR_STUB_STATE/calls" 2>/dev/null || true; }

# fm_herdr_pane_runs: "<pane>\t<command>" for every pane run / send-keys.
fm_herdr_pane_runs() { cat "$HERDR_STUB_STATE/runs" 2>/dev/null || true; }

# --- fake gh ----------------------------------------------------------------

fm_gh_stub() {
  local state
  fm_fakebin || return 1
  state=$(fm_tmproot fm-gh-state) || return 1
  GH_STUB_STATE="$state"
  export GH_STUB_STATE
  : >"$state/calls"
  cat >"$FM_FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
set -u
state=${GH_STUB_STATE:?gh stub: GH_STUB_STATE unset}
printf '%s\n' "$*" >>"$state/calls"
cmd=${1:-}
shift || true
if [ "$cmd" = auth ]; then
  [ -f "$state/auth-fail" ] && exit 1
  printf 'Logged in to github.com account test\n'
  exit 0
fi
case "$cmd" in
pr)
  sub=${1:-}
  shift || true
  case "$sub" in
  view)
    [ -f "$state/pr.json" ] || exit 1
    cat "$state/pr.json"
    ;;
  create)
    printf 'https://example.test/o/r/pull/%s\n' "$(cat "$state/next-pr" 2>/dev/null || printf 7)"
    ;;
  merge)
    code=0
    [ -f "$state/merge-exit" ] && code=$(cat "$state/merge-exit")
    [ -f "$state/merge-reason" ] && cat "$state/merge-reason" >&2
    exit "$code"
    ;;
  *) exit 1 ;;
  esac
  ;;
*) exit 1 ;;
esac
SH
  chmod +x "$FM_FAKEBIN/gh"
  printf '%s\n' "$state"
}

# fm_gh_pr_state <MERGED|CLOSED|OPEN> [draft] : configure `gh pr view`.
fm_gh_pr_state() {
  local state=$1 draft=${2:-false}
  jq -cn --arg s "$state" --argjson d "$draft" \
    '{state:$s,isDraft:$d,mergedAt:null,url:"https://example.test/o/r/pull/7"}' \
    >"$GH_STUB_STATE/pr.json"
}

fm_gh_calls() { cat "$GH_STUB_STATE/calls" 2>/dev/null || true; }

# --- fake pi ----------------------------------------------------------------

fm_pi_stub() {
  fm_fakebin || return 1
  cat >"$FM_FAKEBIN/pi" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = --list-models ]; then
  printf 'model-alpha\nmodel-beta\nmodel-gamma\n'
  exit 0
fi
printf 'pi stub: %s\n' "$*"
SH
  chmod +x "$FM_FAKEBIN/pi"
}

# --- fake lavish-axi --------------------------------------------------------

fm_lavish_stub() {
  fm_fakebin || return 1
  cat >"$FM_FAKEBIN/lavish-axi" <<'SH'
#!/usr/bin/env bash
set -u
state=${LAVISH_STUB_STATE:?lavish stub: LAVISH_STUB_STATE unset}
printf '%s\n' "$*" >>"$state/calls"
printf 'board opened for %s\n' "${1:-}"
SH
  chmod +x "$FM_FAKEBIN/lavish-axi"
  LAVISH_STUB_STATE=$(fm_tmproot fm-lavish-state)
  : >"$LAVISH_STUB_STATE/calls"
  export LAVISH_STUB_STATE
}

# --- fixtures ---------------------------------------------------------------

# fm_task <id> [state]: a minimal, self-consistent task record.
fm_task() {
  local id=$1 state=${2:-working} dir
  dir="$FOREMAN_HOME/tasks/$id"
  mkdir -p "$dir/inbox/handled"
  {
    printf 'harness=pi\n'
    printf 'created=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } >"$dir/meta"
  {
    printf 'state=%s\n' "$state"
    printf 'at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'note=\n'
  } >"$dir/status"
  : >"$dir/events"
  printf '%s\n' "$dir"
}

# fm_iso_ago <seconds>: an ISO-8601 UTC timestamp that many seconds in the past.
fm_iso_ago() {
  local s=$1
  if date -u -v-1S +%s >/dev/null 2>&1; then
    date -u -v-"${s}"S +%Y-%m-%dT%H:%M:%SZ
  else
    date -u -d "@$(( $(date +%s) - s ))" +%Y-%m-%dT%H:%M:%SZ
  fi
}

# fm_age_task <id> <seconds>: backdate a task's status so an age bound is met.
fm_age_task() {
  local f="$FOREMAN_HOME/tasks/$1/status" state note
  state=$(sed -n 's/^state=//p' "$f")
  note=$(sed -n 's/^note=//p' "$f")
  printf 'state=%s\nat=%s\nnote=%s\n' "$state" "$(fm_iso_ago "$2")" "$note" >"$f"
}

# fm_attach_pane <id>: create a stub tab/pane and record it as the task's
# endpoint, the way a launch would. Prints the pane id.
fm_attach_pane() {
  local id=$1 out pane tab
  out=$(herdr --session "${FOREMAN_SESSION:-default}" tab create \
    --workspace ws-stub --cwd /tmp --label "crew-$id" --no-focus) || return 1
  pane=$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id')
  tab=$(printf '%s' "$out" | jq -r '.result.tab.tab_id')
  {
    printf 'pane=%s:%s\n' "${FOREMAN_SESSION:-default}" "$pane"
    printf 'tab=%s\n' "$tab"
    printf 'workspace=ws-stub\n'
  } >>"$FOREMAN_HOME/tasks/$id/meta"
  printf '%s\n' "$pane"
}

# fm_git_repo <dir> [--origin]: a committed repository, optionally with an
# origin remote, so delivery-mode detection can be exercised.
fm_git_repo() {
  local dir=$1 origin=${2:-}
  mkdir -p "$dir"
  git -C "$dir" init -q
  printf 'seed\n' >"$dir/seed.txt"
  git -C "$dir" add seed.txt
  git -C "$dir" -c user.name=foreman-test -c user.email=foreman-test@example.test \
    commit -qm seed
  [ "$origin" = "--origin" ] || return 0
  git -C "$dir" remote add origin "https://example.test/o/r.git"
  printf '%s\n' "$dir"
}
