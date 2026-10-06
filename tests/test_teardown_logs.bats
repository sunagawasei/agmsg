#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
  export PROJ="$TEST_SKILL_DIR/project"
  mkdir -p "$PROJ"
}

teardown() {
  teardown_test_env
}

@test "codex-bridge SIGTERM logs the received signal exactly once" {
  run node - "$TYPES/codex/codex-bridge.js" "$PROJ" <<'NODE'
const { CodexBridge } = require(process.argv[2]);
const bridge = new CodexBridge({
  project: process.argv[3],
  type: "codex",
  requestTimeoutMs: 0,
  turnTimeout: 0,
  maxWakes: 0,
}, [{ team: "team", name: "worker" }]);
bridge.shutdown = async () => {};
bridge.installSignals();
process.kill(process.pid, "SIGTERM");
setTimeout(() => process.exit(2), 1000);
NODE
  [ "$status" -eq 0 ]
  # Every bridge log line carries the writing process's "[pid] " prefix.
  printf '%s\n' "$output" | grep -Eq '^\[[0-9]+\] codex-bridge: received SIGTERM; shutting down$'
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 1 ]
}
