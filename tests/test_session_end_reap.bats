#!/usr/bin/env bats

# SessionEnd removes the finished session's own team (dir + rows) once the
# owner is gone, but only on paths where the worker knows no one inherits it.

load test_helper

setup() {
  setup_test_env
  export SKILL_DIR="$TEST_SKILL_DIR"
  export RUN="$TEST_SKILL_DIR/run"
  export SESSION_ID="reap-session"
  export STEAM="s-$SESSION_ID"
  export DEAD_INSTANCE="${SESSION_ID}.2147483647"
  export PROJ="/tmp/agmsg-session-end-reap"
  export DB="$TEST_SKILL_DIR/db/messages.db"
  export TEST_PIDS=""
  mkdir -p "$RUN"
  bash "$SCRIPTS/config.sh" set delivery.session_team true >/dev/null
  # shellcheck disable=SC1090
  source "$SCRIPTS/lib/actas-lock.sh"
  # shellcheck disable=SC1090
  source "$SCRIPTS/lib/team-lifecycle.sh"
}

teardown() {
  local pid
  for pid in $TEST_PIDS; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  teardown_test_env
}

make_team() {   # [marked]
  mkdir -p "$TEST_SKILL_DIR/teams/$STEAM"
  printf '{"name":"%s","agents":{}}\n' "$STEAM" > "$TEST_SKILL_DIR/teams/$STEAM/config.json"
  if [ "${1:-}" = marked ]; then : > "$TEST_SKILL_DIR/teams/$STEAM/session-team"; fi
  bash "$SCRIPTS/send.sh" "$STEAM" a b seed --force >/dev/null
}

rows() {
  sqlite3 "$DB" "SELECT (SELECT COUNT(*) FROM events WHERE team='$STEAM') + (SELECT COUNT(*) FROM messages WHERE team='$STEAM');"
}

run_worker() {   # <snapshot>
  AGMSG_DRAIN_DEADLINE_S=3 AGMSG_DRAIN_POLL_INTERVAL=0.05 \
    bash "$SCRIPTS/session-end-worker.sh" \
      claude-code "$PROJ" "$SESSION_ID" "$DEAD_INSTANCE" "$1"
}

start_sibling() {
  local sibling
  sleep 300 &
  sibling=$!
  TEST_PIDS="$TEST_PIDS $sibling"
  printf '%s.%s\n' "$SESSION_ID" "$sibling" > "$RUN/cc-instance.$sibling"
}

@test "no spawn record: a dead owner's marked team loses dir and rows" {
  make_team marked
  [ "$(rows)" -gt 0 ]
  run run_worker "$RUN/none.snapshot"
  [ "$status" -eq 0 ]
  [ ! -d "$TEST_SKILL_DIR/teams/$STEAM" ]
  [ "$(rows)" -eq 0 ]
}

@test "a live same-sid sibling keeps the team" {
  make_team marked
  start_sibling
  run run_worker "$RUN/none.snapshot"
  [ "$status" -eq 0 ]
  [ -d "$TEST_SKILL_DIR/teams/$STEAM" ]
  [ "$(rows)" -gt 0 ]
}

@test "an unmarked team is kept" {
  make_team
  run run_worker "$RUN/none.snapshot"
  [ "$status" -eq 0 ]
  [ -d "$TEST_SKILL_DIR/teams/$STEAM" ]
  [ "$(rows)" -gt 0 ]
}

@test "bridge drain completing normally removes the team" {
  local snapshot="$RUN/drain.snapshot" pid record
  make_team marked
  sleep 300 &
  pid=$!
  TEST_PIDS="$TEST_PIDS $pid"
  record="$(printf 'pid:%s\t%s\tcodex' "$pid" "$PROJ")"
  printf '%s\n' "$record" > "$(agmsg_spawn_path "$STEAM" w1)"
  printf 'pid=%s\n' "$pid" > "$RUN/codex-bridge.$STEAM.w1.meta"
  printf 'w1\t%s\n' "$record" > "$snapshot"
  run run_worker "$snapshot"
  [ "$status" -eq 0 ]
  run kill -0 "$pid"
  [ "$status" -ne 0 ]
  [ ! -d "$TEST_SKILL_DIR/teams/$STEAM" ]
  [ "$(rows)" -eq 0 ]
}

@test "a drain aborted by another live fence keeps the team" {
  local snapshot="$RUN/abort.snapshot" pid record fence
  make_team marked
  sleep 300 &
  pid=$!
  TEST_PIDS="$TEST_PIDS $pid"
  record="$(printf 'pid:%s\t%s\tcodex' "$pid" "$PROJ")"
  printf '%s\n' "$record" > "$(agmsg_spawn_path "$STEAM" w1)"
  printf 'w1\t%s\n' "$record" > "$snapshot"
  fence="$(agmsg_drain_fence_path "$STEAM")"
  agmsg_drain_fence_create "$fence" other-nonce other "$STEAM" "$(date +%s)"
  run run_worker "$snapshot"
  [ "$status" -eq 0 ]
  kill -0 "$pid"
  [ -d "$TEST_SKILL_DIR/teams/$STEAM" ]
  [ "$(rows)" -gt 0 ]
}
