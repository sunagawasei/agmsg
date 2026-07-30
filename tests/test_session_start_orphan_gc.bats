#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
  PROJ="/tmp/agmsg-orphan-gc-proj"
  export SKILL_DIR="$TEST_SKILL_DIR"
  # shellcheck disable=SC1091
  source "$SCRIPTS/lib/actas-lock.sh"
}

teardown() {
  teardown_test_env
}

enable_session_team() {
  bash "$SCRIPTS/config.sh" set delivery.session_team true >/dev/null
}

run_session_start() {
  printf '{"session_id":"gc-current"}' \
    | bash "$SCRIPTS/session-start.sh" claude-code "$PROJ"
}

@test "session-start orphan GC reaps every stale headless name and preserves interactive placements" {
  enable_session_team

  local team='s-DEAD-ABC'
  local codex_name='worker__ space 日本語'
  local cursor_name='cursor worker'
  local codex_rec cursor_rec interactive_rec
  mkdir -p "$TEST_SKILL_DIR/run" "$TEST_SKILL_DIR/teams/$team"
  codex_rec="$(agmsg_spawn_path "$team" "$codex_name")"
  cursor_rec="$(agmsg_spawn_path "$team" "$cursor_name")"
  interactive_rec="$(agmsg_spawn_path "$team" 'interactive__worker')"

  sleep 300 & local codex_pid=$!
  sleep 300 & local cursor_pid=$!
  printf 'pid:%s\t%s\tcodex\n' "$codex_pid" "$PROJ" > "$codex_rec"
  printf 'pid=%s\n' "$codex_pid" > "$TEST_SKILL_DIR/run/codex-bridge.$team.$codex_name.meta"
  printf 'pid:%s\t%s\tcursor\n' "$cursor_pid" "$PROJ" > "$cursor_rec"
  printf 'pid=%s\n' "$cursor_pid" > "$TEST_SKILL_DIR/run/cursor-bridge.$team.$cursor_name.meta"
  printf '%%99\t%s\tclaude-code\n' "$PROJ" > "$interactive_rec"
  printf '@99\t%s\tclaude-code\n' "$PROJ" > "${interactive_rec}2"
  printf 'herdr:w:p99\t%s\tclaude-code\n' "$PROJ" > "${interactive_rec}3"

  run run_session_start
  [ "$status" -eq 0 ]

  run kill -0 "$codex_pid"
  [ "$status" -ne 0 ]
  run kill -0 "$cursor_pid"
  [ "$status" -ne 0 ]
  [ ! -e "$codex_rec" ]
  [ ! -e "$cursor_rec" ]
  [ -e "$interactive_rec" ]
  [ -e "${interactive_rec}2" ]
  [ -e "${interactive_rec}3" ]
  kill "$codex_pid" "$cursor_pid" 2>/dev/null || true
}

@test "session-start orphan GC uses one snapshot when a headless record becomes interactive" {
  enable_session_team

  local team='s-C0DE-7EA'
  local name='race-worker'
  local rec marker real_cat stub_bin
  mkdir -p "$TEST_SKILL_DIR/run" "$TEST_SKILL_DIR/teams/$team"
  rec="$(agmsg_spawn_path "$team" "$name")"
  sleep 300 & local worker_pid=$!
  printf 'pid:%s\t%s\tcodex\n' "$worker_pid" "$PROJ" > "$rec"
  printf 'pid=%s\n' "$worker_pid" > "$TEST_SKILL_DIR/run/codex-bridge.$team.$name.meta"

  marker="$TEST_SKILL_DIR/run/race-cat.marker"
  real_cat="$(command -v cat)"
  stub_bin="$TEST_SKILL_DIR/race-bin"
  mkdir -p "$stub_bin"
  cat > "$stub_bin/cat" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "$RACE_REC" ] && [ ! -e "$RACE_MARKER" ]; then
  : > "$RACE_MARKER"
  printf '%%99\t%s\tclaude-code\n' "$RACE_PROJECT" > "$RACE_REC"
fi
exec "$REAL_CAT" "$@"
EOF
  chmod +x "$stub_bin/cat"

  export PATH="$stub_bin:$PATH" RACE_REC="$rec" RACE_MARKER="$marker" \
    RACE_PROJECT="$PROJ" REAL_CAT="$real_cat"
  run run_session_start
  [ "$status" -eq 0 ]
  run kill -0 "$worker_pid"
  [ "$status" -eq 0 ]
  [ "$(head -1 "$rec")" = $'%99\t'"$PROJ"$'\tclaude-code' ]
  kill "$worker_pid" 2>/dev/null || true
}

@test "session-start orphan GC skips a nonconforming team segment" {
  enable_session_team

  local rec="$TEST_SKILL_DIR/run/spawn.s-foo__bar__w"
  mkdir -p "$TEST_SKILL_DIR/run"
  sleep 300 & local worker_pid=$!
  printf 'pid:%s\t%s\tcodex\n' "$worker_pid" "$PROJ" > "$rec"

  run run_session_start
  [ "$status" -eq 0 ]
  run kill -0 "$worker_pid"
  [ "$status" -eq 0 ]
  [ -e "$rec" ]
  kill "$worker_pid" 2>/dev/null || true
}

@test "session-start orphan GC skips a noncanonical worker suffix" {
  enable_session_team

  local malformed="$TEST_SKILL_DIR/run/spawn.s-DEAD__%41"
  local canonical="$TEST_SKILL_DIR/run/spawn.s-DEAD__A"
  local log="$TEST_SKILL_DIR/run/despawn-calls.log"
  mkdir -p "$TEST_SKILL_DIR/run"
  sleep 300 & local worker_pid=$!
  printf 'pid:%s\t%s\tcodex\n' "$worker_pid" "$PROJ" > "$malformed"
  printf 'pid:%s\t%s\tcodex\n' "$worker_pid" "$PROJ" > "$canonical"

  cat > "$SCRIPTS/despawn.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GC_LOG"
EOF
  chmod +x "$SCRIPTS/despawn.sh"
  export GC_LOG="$log"

  run run_session_start
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$log")" -eq 1 ]
  [[ "$(head -1 "$log")" == "s-DEAD claude A "* ]]
  run kill -0 "$worker_pid"
  [ "$status" -eq 0 ]
  [ -e "$malformed" ]
  [ -e "$canonical" ]
  kill "$worker_pid" 2>/dev/null || true
}

@test "session-start orphan GC skips malformed records and leaves live-owner records" {
  enable_session_team

  local stale_team='s-DEAD'
  local live_team='s-1A7E'
  local stale_name='stale'
  local live_name='live'
  local stale_rec live_rec
  mkdir -p "$TEST_SKILL_DIR/run"
  stale_rec="$(agmsg_spawn_path "$stale_team" "$stale_name")"
  live_rec="$(agmsg_spawn_path "$live_team" "$live_name")"

  sleep 300 & local stale_pid=$!
  sleep 300 & local live_pid=$!
  sleep 300 & local owner_pid=$!
  printf 'pid:%s\t%s\tcodex\n' "$stale_pid" "$PROJ" > "$stale_rec"
  printf 'pid=%s\n' "$stale_pid" > "$TEST_SKILL_DIR/run/codex-bridge.$stale_team.$stale_name.meta"
  printf 'pid:%s\t%s\tcodex\n' "$live_pid" "$PROJ" > "$live_rec"
  printf 'pid=%s\n' "$live_pid" > "$TEST_SKILL_DIR/run/codex-bridge.$live_team.$live_name.meta"
  printf 'pid:%s\t%s\tcodex\n' "$stale_pid" "$PROJ" > "$TEST_SKILL_DIR/run/spawn.s-DEAD__bad%ZZ"
  printf '%s\t%s\tclaude-code\n' '%99' "$PROJ" > "$TEST_SKILL_DIR/run/spawn.s-DEAD__interactive"
  printf '1A7E\n' > "$TEST_SKILL_DIR/run/cc-instance.$owner_pid"

  run run_session_start
  [ "$status" -eq 0 ]

  run kill -0 "$stale_pid"
  [ "$status" -ne 0 ]
  run kill -0 "$live_pid"
  [ "$status" -eq 0 ]
  [ -e "$live_rec" ]
  [ -e "$TEST_SKILL_DIR/run/spawn.s-DEAD__bad%ZZ" ]
  [ -e "$TEST_SKILL_DIR/run/spawn.s-DEAD__interactive" ]
  kill "$stale_pid" "$live_pid" "$owner_pid" 2>/dev/null || true
}

@test "session-start orphan GC leaves TTL GC behavior unchanged" {
  enable_session_team

  mkdir -p "$TEST_SKILL_DIR/teams/s-OLD-TTL" "$TEST_SKILL_DIR/teams/s-RECENT-TTL"
  printf '{"name":"s-OLD-TTL","agents":{}}\n' > "$TEST_SKILL_DIR/teams/s-OLD-TTL/config.json"
  printf '{"name":"s-RECENT-TTL","agents":{}}\n' > "$TEST_SKILL_DIR/teams/s-RECENT-TTL/config.json"
  touch -t 202501010000 "$TEST_SKILL_DIR/teams/s-OLD-TTL/config.json" "$TEST_SKILL_DIR/teams/s-OLD-TTL"

  run run_session_start
  [ "$status" -eq 0 ]
  [ ! -d "$TEST_SKILL_DIR/teams/s-OLD-TTL" ]
  [ -d "$TEST_SKILL_DIR/teams/s-RECENT-TTL" ]
}
