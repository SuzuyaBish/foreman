#!/usr/bin/env bash
# shellcheck disable=SC1010  # "done" is a subcommand argument here, not a loop terminator.
# shellcheck disable=SC2016  # the brief's backticks and $( ) are literal prose the test asserts on.
# crew-spawn.test.sh - creating one crew member.
#
# Spawn is where the sealed-context contract is established: the brief is the
# crew member's whole world, its delivery mode decides how it hands work over,
# isolation decides whether it can touch the captain's checkout, and the launch
# is what arms the busy incarnation. All of that is asserted here on plain
# directories and stub Herdr panes.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_home >/dev/null
fm_herdr_stub >/dev/null
fm_pi_agent_dir >/dev/null
fm_pi_stub >/dev/null
fm_git_isolate

SPAWN="$BIN/crew-spawn.sh"
TASKDIR="$FOREMAN_HOME/tasks"
meta_of() { sed -n "s/^$2=//p" "$TASKDIR/$1/meta" 2>/dev/null | head -1; }

test_plain_directory_spawn() {
  local dir out
  dir=$(fm_tmproot plain-cwd)
  out=$("$SPAWN" first "$dir" do the thing)
  assert_contains "$out" "launched first" "spawn reports the launch"
  assert_contains "$out" "cwd $dir" "spawn reports the working directory"
  assert_contains "$out" "delivery report" "a non-git directory defaults to a report deliverable"

  assert_equals "do the thing" "$(cat "$TASKDIR/first/task.md")" "the task text is stored verbatim"
  assert_present "$TASKDIR/first/brief.md" "the brief exists"
  assert_present "$TASKDIR/first/pi-ext.ts" "the crew extension is generated"
  assert_present "$TASKDIR/first/busy-gen" "the busy incarnation is armed"
  assert_present "$TASKDIR/first/inbox/handled" "the inbox is prepared"

  local brief
  brief=$(cat "$TASKDIR/first/brief.md")
  assert_contains "$brief" "do the thing" "the brief carries the task"
  assert_contains "$brief" "$TASKDIR/first/report.md" "the brief names the report file"
  assert_contains "$brief" "crew_report" "the brief teaches the reporting tool"
  assert_not_contains "$brief" "crew-report.sh" "the brief does not hand the crew a bash command"
  assert_contains "$brief" 'crew_report(verb="done", note=' "the report brief shows the finishing call"
  assert_contains "$brief" "needs-decision" "the brief explains how to ask for a decision"
  assert_contains "$brief" "crew-inbox.sh" "the brief tells the crew to check its inbox"
  assert_contains "$brief" "Never merge a pull request" "the brief states the authority rule"

  assert_equals "working" "$(sed -n 's/^state=//p' "$TASKDIR/first/status")" "a spawned crew is working"
  assert_contains "$(cat "$TASKDIR/first/meta")" "harness=pi" "the harness is recorded"
  assert_contains "$(cat "$TASKDIR/first/meta")" "delivery=report" "the delivery mode is recorded"
  assert_present "$TASKDIR/first/busy-state" "the busy record is seeded"

  local pane
  pane=$(sed -n 's/^pane=default://p' "$TASKDIR/first/meta")
  assert_present "$HERDR_STUB_STATE/pane-$pane" "the recorded pane exists in Herdr"
  assert_contains "$(fm_herdr_pane_runs)" "$TASKDIR/first/brief.md" "the launch points the agent at its brief"

  # The crew must be started with the harness's own extension out of the picture.
  # Self-hosting is the case that broke: the project is this repo, so the worktree
  # ships .pi/extensions/foreman.ts, pi discovers it beside the crew's extension,
  # both register lavish_*, and the refusal takes the crew's tools with it.
  local launched
  launched=$(fm_herdr_pane_runs)
  assert_contains "$launched" "-ne " "extension discovery is off, so a project's own extensions cannot collide"
  assert_contains "$launched" "-e $TASKDIR/first/pi-ext.ts" "the crew's own extension is still named explicitly"
  assert_contains "$launched" "FOREMAN_CREW=first" "the session is marked as a crew for anything it starts later"
  pass "a spawn seals the task, arms busy and launches one agent"
}

test_brief_prose_is_data_not_shell() {
  local dir err brief
  dir=$(fm_tmproot brief-prose)
  err=$(mktemp)
  # The stub Herdr meets a real spawn, so the brief template is evaluated here.
  # An unescaped backtick or `$( )` in the prose would run a command and print
  # to stderr. Capture stderr on its own: the original defect was invisible
  # because stdout stayed clean and every other test only read stdout. `--delivery
  # pr` also exercises the second generated template (the finishing block), which
  # must fill its branch name without leaving a token behind.
  "$SPAWN" brief-prose "$dir" --delivery pr 'echo $(id) `id`' 2>"$err" >/dev/null
  assert_equals "" "$(cat "$err")" "spawning prints nothing on stderr"

  brief=$(cat "$TASKDIR/brief-prose/brief.md")
  # The exact sentence that #42's rewrite left a hole in, with the line wrap it
  # renders at. Its backticked tokens are the shape that broke: the shell ran
  # `lavish_open`, found nothing, and substituted the empty string.
  assert_contains "$brief" 'A board with no pick blocks is not ready to open: `lavish_open` runs
`crew-board.sh check` first and refuses it.' \
    "the Lavish sentence survives with both backticked tokens"
  assert_not_contains "$brief" 'not ready to open:  runs' \
    "the Lavish sentence has no hole where the command used to run"
  assert_contains "$brief" '`window.lavish.queuePrompt()` exactly once' "a backticked call survives verbatim"
  assert_contains "$brief" '`<form data-lavish-question="…">` with radios' "backticked markup with an attribute survives"
  assert_contains "$brief" 'through the
`crew_report` tool' "the reporting tool is backticked and present"
  # A task is data too: shell metacharacters in it are never re-expanded.
  assert_contains "$brief" 'echo $(id) `id`' "task text with shell metacharacters is literal"
  # The finishing block's own template was filled, not dumped raw.
  assert_contains "$brief" 'lives on branch `crew/brief-prose`' "the delivery branch is filled in"
  assert_not_contains "$brief" '__ID__' "no __ID__ token leaks into the brief"
  assert_not_contains "$brief" '__TASK__' "no __TASK__ token leaks into the brief"
  assert_not_contains "$brief" '__DELIVERY_BLOCK__' "no block token leaks into the brief"
  rm -f "$err"
  pass "the brief is prose as data: nothing expands, nothing hits stderr"
}

test_delivery_mode_detection() {
  local plain git gitorigin out
  plain=$(fm_tmproot delivery-plain)
  "$SPAWN" d-plain "$plain" task >/dev/null
  assert_contains "$(cat "$TASKDIR/d-plain/meta")" "delivery=report" "a non-git directory cannot deliver a branch"

  git=$(fm_tmproot delivery-git)
  fm_git_repo "$git" >/dev/null
  "$SPAWN" d-local "$git" task >/dev/null
  assert_contains "$(cat "$TASKDIR/d-local/meta")" "delivery=local" "a git repo without an origin delivers locally"

  gitorigin=$(fm_tmproot delivery-origin)
  fm_git_repo "$gitorigin" --origin >/dev/null
  fm_gh_stub >/dev/null
  "$SPAWN" d-pr "$gitorigin" task >/dev/null
  assert_contains "$(cat "$TASKDIR/d-pr/meta")" "delivery=pr" "a git repo with an origin and gh delivers a pull request"

  "$SPAWN" d-explicit "$plain" --delivery local task >/dev/null
  assert_contains "$(cat "$TASKDIR/d-explicit/meta")" "delivery=local" "an explicit delivery mode wins over detection"
  if "$SPAWN" d-bad "$plain" --delivery nonsense task >/dev/null 2>&1; then
    fail "an unknown delivery mode was accepted"
  fi
  pass "delivery mode is detected, overridable and bounded"
}

test_isolation_uses_a_worktree() {
  local proj out
  proj="$FOREMAN_PROJECTS/proj"
  fm_git_repo "$proj" --origin >/dev/null
  fm_gh_stub >/dev/null
  out=$("$SPAWN" iso --project proj "isolated task")
  assert_contains "$out" "worktree" "spawn reports the worktree"
  assert_contains "$out" "branch crew/iso" "spawn reports the branch"

  local wt="$FOREMAN_WORKTREES/iso"
  assert_present "$wt/.git" "the worktree exists"
  assert_contains "$(cat "$TASKDIR/iso/meta")" "project=$proj" "the owning project is recorded"
  assert_contains "$(cat "$TASKDIR/iso/meta")" "worktree=$wt" "the worktree is recorded"
  # The launch records what was already running in the crew's directory, so a
  # --no-isolate crew cannot be blamed for the captain's own processes there.
  assert_present "$TASKDIR/iso/processes-at-launch" "the launch snapshots the directory it starts in"
  assert_contains "$(cat "$TASKDIR/iso/meta")" "branch=crew/iso" "the branch is recorded"
  git -C "$proj" show-ref --verify --quiet refs/heads/crew/iso ||
    fail "the crew branch exists in the project"
  assert_contains "$(cat "$TASKDIR/iso/meta")" "delivery=pr" "an origin remote makes the crew deliver a pull request"
  assert_contains "$(cat "$TASKDIR/iso/brief.md")" "git push -u origin crew/iso" "an isolated delivery teaches the push"
  assert_contains "$(cat "$TASKDIR/iso/brief.md")" 'crew_report(verb="review", note=' "the pr brief shows the review call"
  # Placing a crew for a project is what "working on that project" means, so it
  # is also what puts the project in front of the todo board.
  assert_equals "proj" "$("$BIN/crew-todo.sh" focus)" "spawning for a project puts it in focus"
  pass "isolation gives the crew its own worktree on its own branch"
}

test_project_without_isolation() {
  local proj
  proj="$FOREMAN_PROJECTS/plainproj"
  fm_git_repo "$proj" >/dev/null
  "$SPAWN" shared --project plainproj --no-isolate task >/dev/null
  assert_contains "$(cat "$TASKDIR/shared/meta")" "cwd=$proj" "no-isolate works in the project checkout"
  assert_absent "$FOREMAN_WORKTREES/shared" "no worktree is created"
  pass "--no-isolate is honoured"
}

test_a_spawn_that_names_the_item_labels_the_workspace() {
  local proj seq
  proj="$FOREMAN_PROJECTS/tagged"
  fm_git_repo "$proj" --origin >/dev/null
  fm_gh_stub >/dev/null
  "$BIN/crew-todo.sh" add --project tagged "label the crew" >/dev/null
  seq=$(cut -f1 "$FOREMAN_HOME/todo.tsv" | tail -1)

  "$SPAWN" tagged-iso --project tagged --todo "$seq" "isolated and numbered" >/dev/null
  assert_contains "$(fm_herdr_calls)" "--label └ #$seq tagged-iso" \
    "the workspace label leads with the item number"
  # The worktree directory name is deliberately NOT renamed: Herdr renders the
  # workspace label, and the worktree path is the teardown anchor. Renaming it
  # would be an invisible, load-bearing change.
  assert_present "$FOREMAN_WORKTREES/tagged-iso/.git" "the worktree keeps its plain id name"
  pass "a spawn that names the item puts the number in the workspace label"
}

test_arguments_are_validated() {
  local dir
  dir=$(fm_tmproot args)
  if "$SPAWN" "Bad_Id" "$dir" task >/dev/null 2>&1; then fail "an invalid task id was accepted"; fi
  if "$SPAWN" notask "$dir" >/dev/null 2>&1; then fail "an empty task was accepted"; fi
  if "$SPAWN" neither --delivery report -- "task" >/dev/null 2>&1; then fail "a spawn with no target was accepted"; fi
  if "$SPAWN" both "$dir" --project proj task >/dev/null 2>&1; then fail "a cwd and a project together were accepted"; fi
  if "$SPAWN" unknown "$dir" --bogus task >/dev/null 2>&1; then fail "an unknown option was accepted"; fi
  if "$SPAWN" isolate-alone "$dir" --isolate task >/dev/null 2>&1; then
    fail "isolate without a project was accepted"
  fi
  "$SPAWN" dup "$dir" task >/dev/null
  if "$SPAWN" dup "$dir" task >/dev/null 2>&1; then fail "a duplicate task id was accepted"; fi
  pass "bad ids, missing tasks and conflicting targets are refused"
}

test_double_dash_and_model_options() {
  local dir
  dir=$(fm_tmproot options)
  "$SPAWN" dashed "$dir" -- --not-an-option-and-not-a-flag >/dev/null
  assert_equals "--not-an-option-and-not-a-flag" "$(cat "$TASKDIR/dashed/task.md")" \
    "everything after -- is task text"

  "$SPAWN" tuned "$dir" --model m1 --thinking high "tuned task" >/dev/null
  assert_contains "$(cat "$TASKDIR/tuned/meta")" "model=m1" "the model is recorded"
  assert_contains "$(cat "$TASKDIR/tuned/meta")" "thinking=high" "the thinking level is recorded"
  local runs
  runs=$(fm_herdr_pane_runs | grep "tuned")
  assert_contains "$runs" "--model m1" "the model reaches the launch command"
  assert_contains "$runs" "--thinking high" "the thinking level reaches the launch command"
  assert_contains "$runs" "--approve" "folder trust is pre-approved by default"

  "$BIN/crew-config.sh" set crewApprove false >/dev/null
  "$SPAWN" unapproved "$dir" "another task" >/dev/null
  runs=$(fm_herdr_pane_runs | grep "unapproved")
  assert_not_contains "$runs" "--approve" "crewApprove=false drops the approve flag"
  pass "task text and per-crew model options are handled"
}

test_spawn_records_the_config_model() {
  # The model a crew runs on is recorded where recovery reads it, even when it
  # came from config rather than a flag: a relaunch must land on the same model.
  local dir runs
  dir=$(fm_tmproot config-model)
  "$BIN/crew-config.sh" set crewModel cfg-provider/cfg-model >/dev/null
  "$BIN/crew-config.sh" set crewThinking low >/dev/null
  "$SPAWN" cfgmodel "$dir" "config model task" >/dev/null
  assert_equals "cfg-provider/cfg-model" "$(meta_of cfgmodel model)" "the config model is recorded in meta"
  assert_equals "low" "$(meta_of cfgmodel thinking)" "the config thinking level is recorded in meta"
  runs=$(fm_herdr_pane_runs | grep "cfgmodel")
  assert_contains "$runs" "--model cfg-provider/cfg-model" "the config model reaches the launch command"
  assert_contains "$runs" "--thinking low" "the config thinking level reaches the launch command"

  "$SPAWN" flagmodel "$dir" --model flag-model "flag model task" >/dev/null
  assert_equals "flag-model" "$(meta_of flagmodel model)" "a flag beats config and is what is recorded"
  assert_equals "low" "$(meta_of flagmodel thinking)" "an unflagged thinking level still comes from config"
  "$BIN/crew-config.sh" unset crewModel >/dev/null
  "$BIN/crew-config.sh" unset crewThinking >/dev/null
  pass "spawn records the effective model and thinking level in meta"
}

test_spawn_surfaces_uncommitted_checkout_work() {
  local proj out
  proj="$FOREMAN_PROJECTS/dirtysource"
  fm_git_repo "$proj" --origin >/dev/null
  fm_gh_stub >/dev/null
  printf 'local edit\n' >>"$proj/seed.txt"

  out=$("$SPAWN" dirty-src --project dirtysource "isolated task" 2>&1)
  assert_contains "$out" "uncommitted work" "spawn surfaces the worktree warning"
  assert_contains "$out" "will not carry it" "the warning states the consequence"
  assert_contains "$out" "launched dirty-src" "the spawn still goes ahead"
  assert_present "$FOREMAN_WORKTREES/dirty-src/.git" "the worktree was created anyway"
  pass "an isolated spawn tells the foreman what the worktree will not carry"
}

test_spawn_surfaces_a_stale_base() {
  local proj out
  proj="$FOREMAN_PROJECTS/staleproj"
  fm_git_behind "$proj" "landed while we looked" >/dev/null
  fm_gh_stub >/dev/null

  out=$("$SPAWN" stale-base --project staleproj "isolated task" 2>&1)
  assert_contains "$out" "behind" "spawn surfaces the stale-base warning"
  assert_contains "$out" "landed while we looked" "the warning names the missing commit"
  assert_contains "$out" "sync the checkout before spawning" "the warning says what to do"
  assert_contains "$out" "launched stale-base" "the spawn still goes ahead"
  pass "an isolated spawn from a stale base tells the foreman"
}

test_reuse_warning_for_a_linked_item() {
  local dir out seq
  dir=$(fm_tmproot reuse-cwd)
  fm_task reuse-owner working >/dev/null
  fm_attach_pane reuse-owner >/dev/null
  "$BIN/crew-todo.sh" add --project proj "sharpen the house lines" >/dev/null
  seq=$(cut -f1 "$FOREMAN_HOME/todo.tsv" | tail -1)
  "$BIN/crew-todo.sh" start "$seq" reuse-owner >/dev/null

  out=$("$SPAWN" reuse-second "$dir" --todo "$seq" "the sharpened task" 2>&1)
  assert_contains "$out" "already linked to crew reuse-owner" "a spawn for a linked item warns"
  assert_contains "$out" "crew_send reuse-owner" "the warning names the reuse command"
  assert_contains "$out" "launched reuse-second" "a warning is not a refusal: the spawn still happens"
  assert_present "$TASKDIR/reuse-second/brief.md" "the warned spawn still creates the crew"

  # A linked crew whose instance is gone gets the recovery path, not a send.
  fm_task reuse-lost done >/dev/null
  "$BIN/crew-todo.sh" start "$seq" reuse-lost >/dev/null
  out=$("$SPAWN" reuse-third "$dir" --todo "$seq" "another pass" 2>&1)
  assert_contains "$out" "recover it in place: crew_recover --relaunch reuse-lost" \
    "a linked crew whose pane is gone points at recovery"
  pass "a spawn for an item that already has a crew warns and still goes ahead"
}

test_spawn_does_not_warn_for_a_clean_item() {
  local dir out seq
  dir=$(fm_tmproot clean-cwd)
  "$BIN/crew-todo.sh" add --project proj "brand new work" >/dev/null
  seq=$(cut -f1 "$FOREMAN_HOME/todo.tsv" | tail -1)

  out=$("$SPAWN" clean-first "$dir" --todo "$seq" "new item" 2>&1)
  assert_not_contains "$out" "already linked" "an unlinked item does not warn"
  assert_contains "$out" "launched clean-first" "the spawn proceeds"

  "$BIN/crew-todo.sh" start "$seq" clean-first >/dev/null
  out=$("$SPAWN" clean-second "$dir" --todo "$seq" "genuinely different work" 2>&1)
  assert_contains "$out" "already linked to crew clean-first" "a live linked crew does warn"

  # A link pointing at a crew that is gone (archived, or never really there) is
  # not live work, so it is not a reason to warn.
  "$BIN/crew-todo.sh" start "$seq" ghost-crew >/dev/null
  out=$("$SPAWN" clean-third "$dir" --todo "$seq" "genuinely different work" 2>&1)
  assert_not_contains "$out" "already linked" "a link to a gone crew does not warn"

  # No --todo means spawn cannot know the item, so it cannot warn.
  out=$("$SPAWN" clean-fourth "$dir" "no item named" 2>&1)
  assert_not_contains "$out" "already linked" "a spawn that names no item does not warn"

  if "$SPAWN" bad-todo "$dir" --todo xx task >/dev/null 2>&1; then
    fail "a non-numeric --todo was accepted"
  fi
  pass "only a live linked crew warns, and --todo is validated"
}

test_workspace_resolution() {
  local dir ws
  dir=$(fm_tmproot workspace)
  HERDR_WORKSPACE_ID=ws-ambient
  HERDR_SESSION=default
  export HERDR_WORKSPACE_ID HERDR_SESSION
  fm_herdr_seed_workspace ws-ambient skills

  # Each crew member gets its own workspace. Herdr has no parent/child relation
  # to use, so the hierarchy *is* the child glyph in the label plus the move that
  # puts the workspace directly after the foreman's own.
  "$SPAWN" ws-ambient-task "$dir" task >/dev/null
  assert_contains "$(fm_herdr_calls)" "workspace create" "the crew gets a workspace of its own"
  assert_contains "$(fm_herdr_calls)" "--label └ ws-ambient-task" "the workspace is labelled as a child"
  ws=$(meta_of ws-ambient-task workspace)
  assert_equals "ws-ambient" "$(meta_of ws-ambient-task parent_workspace)" "the parent workspace is recorded"
  assert_contains "$(fm_herdr_moves)" "$ws" "the new workspace is moved after its parent"
  unset HERDR_WORKSPACE_ID HERDR_SESSION

  "$SPAWN" ws-created-task "$dir" task >/dev/null
  assert_contains "$(fm_herdr_calls)" "--label foreman" "outside a workspace the foreman gets a dedicated one"
  assert_contains "$(meta_of ws-created-task parent_workspace)" "ws-" "that workspace becomes the parent"
  pass "every crew member gets its own workspace, placed as a child of the foreman's"
}

test_plain_directory_spawn
test_brief_prose_is_data_not_shell
test_delivery_mode_detection
test_isolation_uses_a_worktree
test_a_spawn_that_names_the_item_labels_the_workspace
test_project_without_isolation
test_arguments_are_validated
test_double_dash_and_model_options
test_spawn_records_the_config_model
test_spawn_surfaces_uncommitted_checkout_work
test_spawn_surfaces_a_stale_base
test_reuse_warning_for_a_linked_item
test_spawn_does_not_warn_for_a_clean_item
test_workspace_resolution
