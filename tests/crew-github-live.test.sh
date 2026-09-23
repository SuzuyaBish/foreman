#!/usr/bin/env bash
# crew-github-live.test.sh - the GitHub boundary, for real (opt-in).
#
# Everything up to this boundary is covered with a stubbed gh: the merge
# mechanics against real git worktrees, and the whole local delivery path in
# tests/crew-e2e-live.test.sh. This file covers what stubs cannot: a real push, a
# real pull request, a real merge, and a real remote branch deletion.
#
#   FOREMAN_E2E=1 FOREMAN_E2E_REPO=<owner>/<name> \
#     bin/crew-test.sh tests/crew-github-live.test.sh
#
# It requires the repository name to be given explicitly, and refuses to run if
# that repository already exists -- so it can never touch one of the captain's
# real repositories. It creates it private and deletes it again in the trap.
#
# Cost and side effects, all deliberate:
#   * it spends real model tokens (a crew that commits, pushes and opens a PR);
#   * it opens a real Herdr tab, closed again in the trap;
#   * it registers folder trust for a throwaway worktree;
#   * it writes gh's credential helper into the throwaway repository's own
#     config, never the captain's global config, so `git push` cannot hang on a
#     prompt in an unattended pane.
# The trap puts all of it back: the tab, the trust entry, the session directory pi
# creates for the crew, and the throwaway repository.
#
# Deleting the repository needs the `delete_repo` token scope. Without it the
# push/PR/merge path still proves itself; the repo is left behind and the exact
# command to remove it is printed.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REPO=${FOREMAN_E2E_REPO:-}
if [ "${FOREMAN_E2E:-0}" != 1 ] || [ -z "$REPO" ]; then
  echo "skip: set FOREMAN_E2E=1 and FOREMAN_E2E_REPO=<owner>/<name> to run the live GitHub path"
  exit 0
fi
for tool in herdr pi git jq gh; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "skip: $tool is not on PATH"
    exit 0
  }
done
if ! herdr --session "${FOREMAN_SESSION:-default}" workspace list >/dev/null 2>&1; then
  echo "skip: no Herdr server on session ${FOREMAN_SESSION:-default}"
  exit 0
fi
if gh repo view "$REPO" >/dev/null 2>&1; then
  fail "$REPO already exists; this test only ever creates and deletes a repo of its own"
fi

TIMEOUT=${FOREMAN_E2E_TIMEOUT:-420}
case "$TIMEOUT" in '' | *[!0-9]*) TIMEOUT=420 ;; esac

AMBIENT_WS=${HERDR_WORKSPACE_ID:-}
fm_home >/dev/null
[ -z "$AMBIENT_WS" ] || export HERDR_WORKSPACE_ID="$AMBIENT_WS"
unset PI_TRUST_FILE

ID=gh-live-$$
BRANCH="crew/$ID"
PROJ="$FOREMAN_PROJECTS/github-sandbox"
WT="$FOREMAN_WORKTREES/$ID"
TAB=
WS=
STOPPED=0

cleanup() {
  if [ "$STOPPED" = 0 ]; then
    "$BIN/crew-stop.sh" "$ID" --close --reason "github e2e cleanup" >/dev/null 2>&1 || true
  fi
  if [ -n "${TAB:-}" ]; then
    herdr --session "${FOREMAN_SESSION:-default}" tab close "$TAB" >/dev/null 2>&1 || true
  fi
  if [ -z "$AMBIENT_WS" ] && [ -n "${WS:-}" ] && [ "$WS" != "$AMBIENT_WS" ]; then
    herdr --session "${FOREMAN_SESSION:-default}" workspace close "$WS" >/dev/null 2>&1 || true
  fi
  # Leave no trace in the captain's pi state: pi keys a session directory by the
  # crew's cwd, and the launch registered folder trust for that cwd.
  if [ -n "${WT:-}" ]; then
    rm -rf "${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/sessions/--$(printf '%s' "${WT#/}" | tr '/' '-')--"
    "$BIN/crew-trust.sh" --remove "$WT" >/dev/null 2>&1 || true
  fi
  if ! gh repo delete "$REPO" --yes >/dev/null 2>&1; then
    printf 'note: %s was left behind (deleting needs the delete_repo scope):\n' "$REPO"
    printf '      gh auth refresh -s delete_repo && gh repo delete %s --yes\n' "$REPO" >&2
  fi
  fm_test_cleanup
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

state_of() { sed -n 's/^state=//p' "$FOREMAN_HOME/tasks/$ID/status" 2>/dev/null; }
note_of() { sed -n 's/^note=//p' "$FOREMAN_HOME/tasks/$ID/status" 2>/dev/null; }
pr_of() { sed -n 's/^pr=//p' "$FOREMAN_HOME/tasks/$ID/meta" 2>/dev/null; }
pr_state() { gh pr view "$(pr_of)" --json state -q .state 2>/dev/null || true; }
remote_has_branch() { [ -n "$(git -C "$PROJ" ls-remote --heads origin "$BRANCH" 2>/dev/null)" ]; }

wait_for() {
  local what=$1
  shift
  local waited=0
  while [ "$waited" -lt "$TIMEOUT" ]; do
    if "$@"; then return 0; fi
    sleep 5
    waited=$((waited + 5))
  done
  fail "$what did not happen within ${TIMEOUT}s (state=$(state_of) note=$(note_of))"
}
reviewed() { [ "$(state_of)" = review ]; }
settled() {
  case "$(state_of)" in
  review | done | failed | blocked) return 0 ;;
  *) return 1 ;;
  esac
}

test_the_pull_request_path() {
  mkdir -p "$PROJ"
  git -C "$PROJ" init -q -b main
  git -C "$PROJ" config user.name "E2E Captain"
  git -C "$PROJ" config user.email "e2e@example.test"
  printf 'seed\n' >"$PROJ/seed.txt"
  git -C "$PROJ" add seed.txt
  git -C "$PROJ" commit -qm "seed"
  # Scope gh's credential helper to this throwaway repo: the same user's global
  # config is off limits, and an unattended pane cannot answer a prompt.
  git -C "$PROJ" config credential.helper '!gh auth git-credential'

  gh repo create "$REPO" --private --source "$PROJ" --remote origin --push >/dev/null 2>&1 ||
    fail "could not create the throwaway repository $REPO"
  assert_contains "$(gh repo view "$REPO" --json visibility -q .visibility 2>/dev/null)" "PRIVATE" \
    "the throwaway repository is private"
  pass "a throwaway private repository is created and seeded"

  local out
  out=$("$BIN/crew-spawn.sh" "$ID" --project github-sandbox --delivery pr -- \
    "Add a file HELLO.md whose only content is this line: hello from the crew. Commit it, push the branch, open a pull request for it, and report review with the pull request url.") ||
    fail "spawn failed: $out"
  assert_contains "$out" "delivery pr" "the crew is working the pull request path"
  TAB=$(sed -n 's/^tab=//p' "$FOREMAN_HOME/tasks/$ID/meta")
  WS=$(sed -n 's/^workspace=//p' "$FOREMAN_HOME/tasks/$ID/meta")
  [ -n "$TAB" ] || fail "no Herdr tab was recorded"

  wait_for "the crew to settle" settled
  [ "$(state_of)" = review ] ||
    fail "the crew did not reach review: state=$(state_of) note=$(note_of)"
  pass "a real crew pushes a branch and reports review"

  # A review task is only useful if the pull request is real.
  local pr
  pr=$(pr_of)
  [ -n "$pr" ] || fail "review was reported with no pull request recorded"
  assert_contains "$pr" "github.com" "the recorded pull request is a real url"
  assert_present "$WT/HELLO.md" "the crew's file is on its branch"
  assert_equals "hello from the crew" "$(head -1 "$WT/HELLO.md")" "the file has the asked-for line"
  assert_equals "OPEN" "$(pr_state)" "the pull request is open on GitHub"
  assert_equals "1" "$(gh pr view "$pr" --json files -q '.files | length' 2>/dev/null)" \
    "the pull request carries exactly the crew's one file"
  remote_has_branch || fail "the branch was never pushed to the remote"
  pass "the pull request is a real, open, one-file pull request on GitHub"
}

test_the_merge_releases_everything() {
  local pr
  pr=$(pr_of)
  "$BIN/crew-merge.sh" "$ID" --delete-branch >/dev/null || fail "the merge failed"
  assert_equals "done" "$(state_of)" "the merge settles the task"
  assert_contains "$(note_of)" "merged by the foreman" "the settlement names the merge"
  assert_equals "MERGED" "$(pr_state)" "GitHub reports the pull request merged"
  assert_absent "$WT" "the worktree is removed"

  # The point of --delete-branch: the branch is gone on the remote, not just
  # locally. This is the half a stubbed gh can never show.
  local waited=0
  while remote_has_branch && [ "$waited" -lt 60 ]; do
    sleep 5
    waited=$((waited + 5))
  done
  if remote_has_branch; then fail "the remote branch survived --delete-branch"; fi
  pass "the merge reaches GitHub, and the remote branch is deleted"

  # A second merge must refuse: the task is done, and there is nothing to merge.
  if "$BIN/crew-merge.sh" "$ID" >/dev/null 2>&1; then fail "a done task could be merged again"; fi
  pass "a merged task cannot be merged twice"
}

test_the_work_lands_on_the_default_branch() {
  # The merged file must actually be on main: that is what "delivered" means.
  git -C "$PROJ" fetch -q origin main 2>/dev/null || true
  assert_equals "hello from the crew" "$(git -C "$PROJ" show origin/main:HELLO.md 2>/dev/null | head -1)" \
    "the crew's file is on the remote default branch"
  pass "the merged change is really on main, not just marked merged"
}

test_the_pull_request_path
test_the_merge_releases_everything
test_the_work_lands_on_the_default_branch

STOPPED=1
"$BIN/crew-stop.sh" "$ID" --close --reason "github e2e complete" >/dev/null 2>&1 || true
TAB=
