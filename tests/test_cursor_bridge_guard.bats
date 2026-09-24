#!/usr/bin/env bats

load test_helper

# 段9 codex finding F1: the session hooks must be inert inside a headless cursor
# worker's own turns. .cursor/hooks.json resolves by --workspace, not cwd, so a
# reviewer turn run with --workspace <project> fires the project's hooks; without
# this guard the worker would join the session team, publish a cc-instance
# record, run the GC and start an inject watcher on every turn of the cursor
# review worker a claude-code main session spawned.

setup() {
  setup_test_env
  export TEST_PROJECT="$(mktemp -d)"
  export RUN_DIR="$TEST_SKILL_DIR/run"
  mkdir -p "$RUN_DIR"
  bash "$SCRIPTS/join.sh" testteam alice cursor "$TEST_PROJECT" >/dev/null
}

teardown() {
  teardown_test_env
}

# Snapshot of every path agmsg would mutate, so "nothing happened" is checked
# against real state and not just stdout.
_state_snapshot() {
  { find "$RUN_DIR" -type f 2>/dev/null | sort
    echo "--"
    find "$TEST_SKILL_DIR/teams" -type f 2>/dev/null | sort | while read -r f; do
      printf '%s\t%s\n' "$f" "$(cksum < "$f")"
    done
  }
}

@test "session-start.sh: AGMSG_CURSOR_BRIDGE=1 exits 0, emits nothing and touches no state (F1)" {
  local before after
  before="$(_state_snapshot)"
  run env AGMSG_CURSOR_BRIDGE=1 bash "$SCRIPTS/session-start.sh" cursor "$TEST_PROJECT" </dev/null
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  after="$(_state_snapshot)"
  [ "$before" = "$after" ]
}

@test "session-start.sh: AGMSG_CURSOR_BRIDGE=1 starts no inject watcher (F1)" {
  run env AGMSG_CURSOR_BRIDGE=1 bash "$SCRIPTS/session-start.sh" cursor "$TEST_PROJECT" </dev/null
  [ "$status" -eq 0 ]
  run bash -c "ls '$RUN_DIR'/inject-watch.*.pid 2>/dev/null | wc -l | tr -d ' '"
  [ "$output" = "0" ]
}

@test "session-start.sh: without the guard the same call is NOT inert (control)" {
  # Proves the assertions above are actually gated on the env var rather than on
  # the fixture being inert for some other reason.
  local before after
  before="$(_state_snapshot)"
  run bash -c "printf '{\"session_id\":\"guard-control\"}' | bash '$SCRIPTS/session-start.sh' cursor '$TEST_PROJECT' 2>/dev/null"
  after="$(_state_snapshot)"
  [ "$before" != "$after" ]
}
