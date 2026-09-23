#!/usr/bin/env bash
# crew-processes.test.sh - the teardown: what a crew member left running.
#
# Attribution is by working directory, because that is the only link that
# survives the thing that makes a stray hard to find (the job is orphaned to
# PID 1 when the tool shell that started it exits). The fixture tests pin the
# classification exactly - who is protected, who is a stray - and two tests
# start real orphaned processes, because the question that matters is whether
# the real path finds a real one and really stops it.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_home >/dev/null

PROC="$BIN/crew-processes.sh"

# --- exact classification ----------------------------------------------------

test_only_this_crews_processes_are_strays() {
  local root dir real out
  root=$(fm_tmproot procs-fix)
  dir="$root/proj"
  mkdir -p "$dir"
  real=$(cd "$dir" && pwd -P)
  fm_task fixed-crew working >/dev/null
  fm_task_field fixed-crew cwd "$dir"

  #  50 the pane shell   100 the agent  150 an MCP server under the agent
  # 200 the stray        210 its worker 300 an unrelated detached process
  # 400 a Lavish board   410 the adb server   999 a process working elsewhere
  cat >"$root/ps" <<EOF
   50      1 -zsh
  100     50 pi
  150    100 node /x/agent-device mcp
  200      1 node /x/vite
  210    200 node /x/vite-worker
  300      1 tail -f app.log
  400      1 node /x/lavish-axi serve
  410      1 adb -L tcp:5037 fork-server server --reply-fd 4
  999      1 sleep 5
EOF
  {
    for pid in 50 100 150 200 210 300 400 410; do
      printf 'p%s\ncproc\nfcwd\nn%s\n' "$pid" "$real"
    done
    printf 'p999\ncproc\nfcwd\nn/somewhere/else\n'
  } >"$root/lsof"

  out=$(FOREMAN_PROC_PS_FILE="$root/ps" FOREMAN_PROC_LSOF_FILE="$root/lsof" "$PROC" list fixed-crew)
  assert_contains "$out" "200" "the stray is reported"
  assert_contains "$out" "210" "its worker is reported too - it shares the cwd"
  assert_contains "$out" "300" "any detached process in the crew's directory is reported"
  assert_not_contains "$out" "100" "the agent itself is never a stray"
  assert_not_contains "$out" "150" "an MCP server still under the agent is not a stray"
  assert_not_contains "$out" "50" "the pane shell the agent runs in is not a stray"
  assert_not_contains "$out" "400" "a Lavish board is left up for the captain"
  assert_not_contains "$out" "410" "a machine-wide daemon the crew triggered is not its stray"
  assert_not_contains "$out" "999" "a process working elsewhere is not this crew's"
  assert_equals "3" "$(FOREMAN_PROC_PS_FILE="$root/ps" FOREMAN_PROC_LSOF_FILE="$root/lsof" "$PROC" count fixed-crew)" \
    "the count matches the list"
  pass "the agent, its children, its shell and Lavish are protected; nothing else is"
}

test_the_worktree_is_the_anchor_when_there_is_one() {
  local root wt cwd real out
  root=$(fm_tmproot procs-anchor)
  wt="$root/worktree"
  cwd="$root/project"
  mkdir -p "$wt" "$cwd"
  real=$(cd "$wt" && pwd -P)
  fm_task anchored-crew working >/dev/null
  fm_task_field anchored-crew worktree "$wt"
  fm_task_field anchored-crew cwd "$cwd"
  printf 'p200\ncproc\nfcwd\nn%s\n' "$real" >"$root/lsof"
  printf '  200      1 node /x/vite\n' >"$root/ps"

  out=$(FOREMAN_PROC_PS_FILE="$root/ps" FOREMAN_PROC_LSOF_FILE="$root/lsof" "$PROC" list anchored-crew)
  assert_contains "$out" "200" "an isolated crew is anchored on its worktree"

  # A process in the project checkout is not this crew's: for a worktree crew
  # the checkout belongs to the captain.
  printf 'p201\ncproc\nfcwd\nn%s\n' "$(cd "$cwd" && pwd -P)" >"$root/lsof"
  out=$(FOREMAN_PROC_PS_FILE="$root/ps" FOREMAN_PROC_LSOF_FILE="$root/lsof" "$PROC" list anchored-crew)
  assert_not_contains "$out" "200" "nothing in the project checkout is reported"
  pass "the worktree is the anchor whenever the task has one"
}

# --- real processes ----------------------------------------------------------

test_a_real_orphan_is_found_and_stopped() {
  local root dir pid out
  root=$(fm_tmproot procs-real)
  dir="$root/proj"
  mkdir -p "$dir"
  fm_task real-crew working >/dev/null
  fm_task_field real-crew cwd "$dir"

  pid=$(fm_stray "$dir" sleep 300)
  assert_equals "1" "$("$PROC" count real-crew)" "an orphaned process is found by its cwd"
  assert_contains "$("$PROC" list real-crew)" "sleep 300" "the list names what it found"

  out=$("$PROC" kill real-crew)
  assert_contains "$out" "stopped $pid (" "kill reports what it stopped"
  assert_equals "0" "$("$PROC" count real-crew)" "the directory is clear afterwards"
  if kill -0 "$pid" 2>/dev/null; then fail "the process survived the teardown"; fi
  pass "a stray the crew left behind is found and stopped"
}

test_kill_escalates_when_term_is_ignored() {
  local root dir pid
  root=$(fm_tmproot procs-kill)
  dir="$root/proj"
  mkdir -p "$dir"
  fm_task stubborn-crew working >/dev/null
  fm_task_field stubborn-crew cwd "$dir"

  pid=$(fm_stray "$dir" sh -c 'trap "" TERM; sleep 300')
  "$PROC" kill stubborn-crew --grace 1 >/dev/null
  if kill -0 "$pid" 2>/dev/null; then fail "a process that ignores TERM outlived the teardown"; fi
  assert_equals "0" "$("$PROC" count stubborn-crew)" "nothing is left running"
  pass "a process that ignores TERM is still torn down"
}

# --- honesty -----------------------------------------------------------------

test_a_clean_crew_is_silent() {
  local root dir
  root=$(fm_tmproot procs-clean)
  dir="$root/proj"
  mkdir -p "$dir"
  fm_task clean-crew working >/dev/null
  fm_task_field clean-crew cwd "$dir"

  assert_equals "" "$("$PROC" list clean-crew)" "a clean directory lists nothing"
  assert_equals "0" "$("$PROC" count clean-crew)" "and counts zero"
  assert_equals "" "$("$PROC" kill clean-crew)" "and killing nothing says nothing"
  pass "a crew that left nothing running reads as clean"
}

# The probe runs from inside the crew's directory, so its own children inherit
# the anchor as their cwd. `lsof` duly lists itself, and the run that is looking
# for strays must not report one - this exact false positive refused a real
# crew's `done` report in the live E2E before it was fixed.
test_the_probe_never_reports_itself() {
  local root dir out
  root=$(fm_tmproot procs-self)
  dir="$root/proj"
  mkdir -p "$dir"
  fm_task self-crew working >/dev/null
  fm_task_field self-crew cwd "$dir"

  out=$(cd "$dir" && "$PROC" list self-crew)
  assert_equals "" "$out" "the probe does not report its own scan"
  assert_equals "0" "$(cd "$dir" && "$PROC" count self-crew)" "and counts nothing"

  # A pid in the cwd scan that the process table cannot name is never blamed
  # either: it would be the scan itself, or something that already exited.
  printf '  100      1 pi\n' >"$root/ps"
  printf 'p999\nclsof\nfcwd\nn%s\n' "$dir" >"$root/lsof"
  out=$(FOREMAN_PROC_PS_FILE="$root/ps" FOREMAN_PROC_LSOF_FILE="$root/lsof" "$PROC" list self-crew)
  assert_equals "" "$out" "an unnamed process is not blamed on the crew"
  pass "the probe never reports itself or anything it cannot name"
}

test_a_probe_that_cannot_tell_says_so() {
  local out rc
  fm_task anchorless-crew working >/dev/null
  # No worktree and no cwd: there is no directory to attribute anything to.
  if out=$("$PROC" list anchorless-crew 2>&1); then rc=0; else rc=$?; fi
  assert_equals "3" "$rc" "a probe with no anchor reports that it cannot tell"
  assert_contains "$out" "leaving it alone" "and says it will not act on a guess"
  if out=$("$PROC" kill anchorless-crew 2>&1); then rc=0; else rc=$?; fi
  assert_equals "3" "$rc" "kill refuses to guess too"
  pass "a broken probe fails open instead of holding a crew's work hostage"
}

# The launch records what was already in the directory, so a --no-isolate crew
# cannot be blamed for - or kill - the captain's own processes there.
test_what_predated_the_crew_is_spared() {
  local root dir pid out
  root=$(fm_tmproot procs-snap)
  dir="$root/proj"
  mkdir -p "$dir"
  fm_task snap-crew working >/dev/null
  fm_task_field snap-crew cwd "$dir"

  pid=$(fm_stray "$dir" sleep 300)
  out=$("$PROC" snapshot snap-crew)
  assert_contains "$out" "1 process(es) already under" "the launch records what it found"
  assert_equals "0" "$("$PROC" count snap-crew)" "a process that predated the crew is not its stray"
  fm_kill_stray "$pid"

  out=$("$PROC" snapshot snap-crew)
  assert_contains "$out" "snapshot kept" "a relaunch keeps the original snapshot"
  assert_equals "$pid" "$(cat "$FOREMAN_HOME/tasks/snap-crew/processes-at-launch")" \
    "the kept snapshot is still the one the first launch wrote"
  pass "the captain's own processes are excluded, and a relaunch does not launder strays"
}

test_only_this_crews_processes_are_strays
test_the_worktree_is_the_anchor_when_there_is_one
test_a_real_orphan_is_found_and_stopped
test_kill_escalates_when_term_is_ignored
test_a_clean_crew_is_silent
test_the_probe_never_reports_itself
test_a_probe_that_cannot_tell_says_so
test_what_predated_the_crew_is_spared
