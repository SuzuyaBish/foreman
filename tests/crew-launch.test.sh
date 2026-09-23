#!/usr/bin/env bash
# crew-launch.test.sh - the pi command a crew member is started with.
#
# A crew runs with extension discovery off (`-ne`) so a self-hosted worktree's
# foreman extension cannot load beside the crew's own. That also drops the
# packages the captain installed globally, and with them any model provider they
# bring, so the launcher names each installed global package back with `-e`.
# Asserted here against a fixture pi agent directory, never the captain's own.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_home >/dev/null
fm_herdr_stub >/dev/null
fm_pi_stub >/dev/null
fm_pi_agent_dir >/dev/null
AGENT=$PI_CODING_AGENT_DIR

SPAWN="$BIN/crew-spawn.sh"
TASKDIR="$FOREMAN_HOME/tasks"
launched() { fm_herdr_pane_runs | grep "FOREMAN_CREW=$1 "; }

test_global_packages_are_loaded() {
  local dir runs
  dir=$(fm_tmproot launch-cwd)
  mkdir -p "$AGENT/npm/node_modules/pi-provider" \
    "$AGENT/npm/node_modules/@scope/scoped" \
    "$AGENT/npm/node_modules/filtered/ext" \
    "$AGENT/npm/node_modules/silenced" \
    "$AGENT/git/github.com/someone/gitpkg" \
    "$AGENT/local-pkg"
  cat >"$AGENT/settings.json" <<'JSON'
{
  "defaultProvider": "fake-bridge",
  "packages": [
    "npm:pi-provider",
    "npm:@scope/scoped@^1.2.0",
    "npm:not-installed",
    "git:github.com/someone/gitpkg@v1",
    "./local-pkg",
    { "source": "npm:filtered", "extensions": ["./ext/one.ts"] },
    { "source": "npm:silenced", "extensions": [] }
  ]
}
JSON
  : >"$AGENT/npm/node_modules/filtered/ext/one.ts"

  "$SPAWN" pkgs "$dir" "a task" >/dev/null
  runs=$(launched pkgs)
  assert_contains "$runs" "-ne " "discovery stays off"
  assert_contains "$runs" "-e $TASKDIR/pkgs/pi-ext.ts -e $AGENT/npm/node_modules/pi-provider" \
    "the crew's own extension comes first, then the global packages"
  assert_contains "$runs" "-e $AGENT/npm/node_modules/@scope/scoped " "a scoped, versioned npm package resolves to its install"
  assert_contains "$runs" "-e $AGENT/git/github.com/someone/gitpkg " "a git package resolves to its checkout"
  assert_contains "$runs" "-e $AGENT/local-pkg " "a local package resolves against the agent directory"
  assert_contains "$runs" "-e $AGENT/npm/node_modules/filtered/ext/one.ts " "a filtered package passes only the files it names"
  assert_not_contains "$runs" "not-installed" "a package that is not installed is skipped, never installed"
  assert_not_contains "$runs" "silenced" "a package whose extensions are turned off stays off"
  assert_not_contains "$runs" "npm:" "an installed path is passed, never a source pi would reinstall"
  pass "the captain's installed global packages are named back into the crew"
}

test_project_local_extensions_stay_off() {
  local dir runs
  dir=$(fm_tmproot project-local)
  mkdir -p "$dir/.pi/extensions" "$dir/.pi/npm/node_modules/proj-pkg"
  : >"$dir/.pi/extensions/foreman.ts"
  printf '{"packages":["npm:proj-pkg"]}\n' >"$dir/.pi/settings.json"
  printf '{"packages":[]}\n' >"$AGENT/settings.json"
  "$SPAWN" projlocal "$dir" "a task" >/dev/null
  runs=$(launched projlocal)
  assert_not_contains "$runs" "foreman.ts" "a project's own extension is not named"
  assert_not_contains "$runs" "proj-pkg" "a project-local package is not named"
  assert_contains "$runs" "-e $TASKDIR/projlocal/pi-ext.ts" "the crew's own extension still loads"
  pass "project-local extensions and packages stay excluded"
}

test_a_bad_settings_file_still_launches() {
  local dir runs out
  dir=$(fm_tmproot bad-settings)

  rm -f "$AGENT/settings.json"
  out=$("$SPAWN" nosettings "$dir" "a task" 2>&1)
  assert_contains "$out" "launched nosettings" "a missing settings file still launches"
  runs=$(launched nosettings)
  assert_contains "$runs" "-e $TASKDIR/nosettings/pi-ext.ts " "the crew's own extension is the only one"
  assert_not_contains "$runs" "$AGENT" "nothing from the agent directory is named"

  printf '{ "packages": [ "npm:pi-provider", \n' >"$AGENT/settings.json"
  out=$("$SPAWN" badjson "$dir" "a task" 2>&1)
  assert_contains "$out" "launched badjson" "a malformed settings file still launches"
  assert_not_contains "$(launched badjson)" "$AGENT" "a malformed file names no packages"

  printf '{ "packages": "npm:pi-provider" }\n' >"$AGENT/settings.json"
  out=$("$SPAWN" oddshape "$dir" "a task" 2>&1)
  assert_contains "$out" "launched oddshape" "a packages value that is not a list still launches"
  assert_not_contains "$(launched oddshape)" "$AGENT" "an unexpected shape names no packages"

  printf '[1, 2]\n' >"$AGENT/settings.json"
  out=$("$SPAWN" notobject "$dir" "a task" 2>&1)
  assert_contains "$out" "launched notobject" "a settings file that is not an object still launches"
  pass "a missing or malformed settings file never fails a launch"
}

test_recovery_loads_the_same_packages() {
  local cwd runs
  cwd=$(fm_tmproot recover-pkgs)
  printf '{"packages":["npm:pi-provider"]}\n' >"$AGENT/settings.json"
  fm_task rpk working >/dev/null
  printf 'brief\n' >"$TASKDIR/rpk/brief.md"
  printf 'cwd=%s\n' "$cwd" >>"$TASKDIR/rpk/meta"
  "$BIN/crew-recover.sh" --relaunch rpk >/dev/null
  runs=$(launched rpk)
  assert_contains "$runs" "-e $AGENT/npm/node_modules/pi-provider" "a recovery relaunch loads the global packages too"
  pass "a recovery relaunch gets the same providers as a spawn"
}

test_global_packages_are_loaded
test_project_local_extensions_stay_off
test_a_bad_settings_file_still_launches
test_recovery_loads_the_same_packages
