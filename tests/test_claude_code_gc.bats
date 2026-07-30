#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
  PROJ="/tmp/agmsg-claude-code-gc-proj"
  GC_PIDS=""
}

teardown() {
  [ -z "$GC_PIDS" ] || kill $GC_PIDS 2>/dev/null || true
  teardown_test_env
}

enable_session_team() {
  bash "$SCRIPTS/config.sh" set delivery.session_team true >/dev/null
}

run_session_start() {
  printf '{"session_id":"deadbeef-0001"}' \
    | bash "$SCRIPTS/session-start.sh" claude-code "$PROJ"
}

make_claude_code_artifacts() {
  local team="$1" name="$2" marker="$3" base suffix
  base="$TEST_SKILL_DIR/run/claude-code-bridge.$team.$name"
  mkdir -p "$TEST_SKILL_DIR/run"
  for suffix in pid meta log role session transient transient.tmp outbound.json outbound.claude.12345; do
    printf '%s\n' "$marker" > "$base.$suffix"
  done
  mkdir -p "$TEST_SKILL_DIR/run/claude-code-$team-$name-cwd"
  printf '%s\n' "$marker" > "$TEST_SKILL_DIR/run/claude-code-$team-$name-cwd/marker"
}

assert_claude_code_artifacts_exist() {
  local team="$1" name="$2" base suffix
  base="$TEST_SKILL_DIR/run/claude-code-bridge.$team.$name"
  for suffix in pid meta log role session transient transient.tmp outbound.json outbound.claude.12345; do
    [ -f "$base.$suffix" ]
  done
  [ -f "$TEST_SKILL_DIR/run/claude-code-$team-$name-cwd/marker" ]
}

assert_claude_code_artifacts_absent() {
  local team="$1" name="$2" base suffix
  base="$TEST_SKILL_DIR/run/claude-code-bridge.$team.$name"
  for suffix in pid meta log role session transient transient.tmp outbound.json outbound.claude.12345; do
    [ ! -e "$base.$suffix" ]
  done
  [ ! -e "$TEST_SKILL_DIR/run/claude-code-$team-$name-cwd" ]
}

@test "session-start TTL GC reaps stale claude-code artifacts and cwd, keeps fresh ones" {
  enable_session_team

  local stale_team='s-CAFE-001'
  local fresh_team='s-CAFE-002'
  local name
  mkdir -p "$TEST_SKILL_DIR/teams/$stale_team" "$TEST_SKILL_DIR/teams/$fresh_team"
  printf '{"name":"%s","agents":{}}\n' "$stale_team" > "$TEST_SKILL_DIR/teams/$stale_team/config.json"
  printf '{"name":"%s","agents":{}}\n' "$fresh_team" > "$TEST_SKILL_DIR/teams/$fresh_team/config.json"
  for name in worker-one worker-two; do
    make_claude_code_artifacts "$stale_team" "$name" stale
    make_claude_code_artifacts "$fresh_team" "$name" fresh
  done
  touch -t 202501010000 \
    "$TEST_SKILL_DIR/teams/$stale_team/config.json" \
    "$TEST_SKILL_DIR/teams/$stale_team"

  run run_session_start
  [ "$status" -eq 0 ]
  [ ! -d "$TEST_SKILL_DIR/teams/$stale_team" ]
  for name in worker-one worker-two; do
    assert_claude_code_artifacts_absent "$stale_team" "$name"
  done
  [ -d "$TEST_SKILL_DIR/teams/$fresh_team" ]
  for name in worker-one worker-two; do
    assert_claude_code_artifacts_exist "$fresh_team" "$name"
  done
}

@test "session-start TTL GC keeps stale claude-code artifacts for a live owner" {
  enable_session_team

  local live_team='s-CAFE-003'
  local owner_pid name
  mkdir -p "$TEST_SKILL_DIR/teams/$live_team"
  printf '{"name":"%s","agents":{}}\n' "$live_team" > "$TEST_SKILL_DIR/teams/$live_team/config.json"
  for name in live-one live-two; do
    make_claude_code_artifacts "$live_team" "$name" live
  done
  touch -t 202501010000 \
    "$TEST_SKILL_DIR/teams/$live_team/config.json" \
    "$TEST_SKILL_DIR/teams/$live_team"

  sleep 300 & owner_pid=$!
  GC_PIDS="$owner_pid"
  printf 'CAFE-003\n' > "$TEST_SKILL_DIR/run/cc-instance.$owner_pid"

  run run_session_start
  [ "$status" -eq 0 ]
  [ -d "$TEST_SKILL_DIR/teams/$live_team" ]
  for name in live-one live-two; do
    assert_claude_code_artifacts_exist "$live_team" "$name"
  done
}
