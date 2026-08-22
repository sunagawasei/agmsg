#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
  PROJ="/tmp/agmsg-orphan-gc-proj"
  export SKILL_DIR="$TEST_SKILL_DIR"
  mkdir -p "$TEST_SKILL_DIR/run"
  # shellcheck disable=SC1091
  source "$SCRIPTS/lib/actas-lock.sh"
  # shellcheck disable=SC1091
  source "$SCRIPTS/lib/pending-teardown.sh"
  # shellcheck disable=SC1091
  source "$SCRIPTS/lib/inflight.sh"
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

@test "session-start orphan GC reports every stale headless name and preserves all placements" {
  enable_session_team

  local team='s-DEAD-ABC'
  local codex_name='worker__ space 日本語'
  local cursor_name='cursor worker'
  local codex_rec cursor_rec interactive_rec
  mkdir -p "$TEST_SKILL_DIR/run" "$TEST_SKILL_DIR/teams/$team"
  codex_rec="$(agmsg_spawn_path "$team" "$codex_name")"
  cursor_rec="$(agmsg_spawn_path "$team" "$cursor_name")"
  interactive_rec="$(agmsg_spawn_path "$team" 'interactive__worker')"

  test_fixture_start_reaped_process sleep 300
  local codex_pid="$TEST_REAPED_PID"
  test_fixture_start_reaped_process sleep 300
  local cursor_pid="$TEST_REAPED_PID"
  printf 'pid:%s\t%s\tcodex\n' "$codex_pid" "$PROJ" > "$codex_rec"
  printf 'pid=%s\n' "$codex_pid" > "$TEST_SKILL_DIR/run/codex-bridge.$team.$codex_name.meta"
  printf 'pid:%s\t%s\tcursor\n' "$cursor_pid" "$PROJ" > "$cursor_rec"
  printf 'pid=%s\n' "$cursor_pid" > "$TEST_SKILL_DIR/run/cursor-bridge.$team.$cursor_name.meta"
  printf '%%99\t%s\tclaude-code\n' "$PROJ" > "$interactive_rec"
  printf '@99\t%s\tclaude-code\n' "$PROJ" > "${interactive_rec}2"
  printf 'herdr:w:p99\t%s\tclaude-code\n' "$PROJ" > "${interactive_rec}3"

  run run_session_start
  [ "$status" -eq 0 ]
  local start_output="$output"

  run kill -0 "$codex_pid"
  [ "$status" -eq 0 ]
  run kill -0 "$cursor_pid"
  [ "$status" -eq 0 ]
  [ -e "$codex_rec" ]
  [ -e "$cursor_rec" ]
  [ -e "$interactive_rec" ]
  [ -e "${interactive_rec}2" ]
  [ -e "${interactive_rec}3" ]
  [ "$(printf '%s\n' "$start_output" | grep -c '^agmsg: orphan candidate ')" -eq 2 ]
  [[ "$start_output" == *"team=$team worker=$codex_name bridge_pid=$codex_pid spawn_age_s="* ]]
  [[ "$start_output" == *"team=$team worker=$cursor_name bridge_pid=$cursor_pid spawn_age_s="* ]]
  kill "$codex_pid" "$cursor_pid" 2>/dev/null || true
}

@test "session-start orphan GC uses one snapshot when a headless record becomes interactive" {
  enable_session_team

  local team='s-C0DE-7EA'
  local name='race-worker'
  local rec marker real_cat stub_bin
  mkdir -p "$TEST_SKILL_DIR/run" "$TEST_SKILL_DIR/teams/$team"
  rec="$(agmsg_spawn_path "$team" "$name")"
  test_fixture_start_reaped_process sleep 300
  local worker_pid="$TEST_REAPED_PID"
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
  test_fixture_start_reaped_process sleep 300
  local worker_pid="$TEST_REAPED_PID"
  printf 'pid:%s\t%s\tcodex\n' "$worker_pid" "$PROJ" > "$rec"

  run run_session_start
  [ "$status" -eq 0 ]
  run kill -0 "$worker_pid"
  [ "$status" -eq 0 ]
  [ -e "$rec" ]
  kill "$worker_pid" 2>/dev/null || true
}

@test "session-start orphan report strips controls from a decoded worker name" {
  enable_session_team

  local team=s-DEAD10B name=$'bad\nforged' rec
  mkdir -p "$TEST_SKILL_DIR/run" "$TEST_SKILL_DIR/teams/$team"
  rec="$(agmsg_spawn_path "$team" "$name")"
  test_fixture_start_reaped_process sleep 300
  local worker_pid="$TEST_REAPED_PID"
  printf 'pid:%s\t%s\tcodex\n' "$worker_pid" "$PROJ" > "$rec"

  run run_session_start
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c "^agmsg: orphan candidate team=$team worker=badforged bridge_pid=$worker_pid ")" -eq 1 ]
  [ "$(printf '%s\n' "$output" | grep -c '^forged bridge_pid=')" -eq 0 ]
  kill -0 "$worker_pid" 2>/dev/null
  [ -f "$rec" ]
}

@test "session-start orphan GC never calls despawn and skips a noncanonical worker suffix" {
  enable_session_team

  local malformed="$TEST_SKILL_DIR/run/spawn.s-DEAD__%41"
  local canonical="$TEST_SKILL_DIR/run/spawn.s-DEAD__A"
  local log="$TEST_SKILL_DIR/run/despawn-calls.log"
  mkdir -p "$TEST_SKILL_DIR/run"
  test_fixture_start_reaped_process sleep 300
  local worker_pid="$TEST_REAPED_PID"
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
  local start_output="$output"
  [ ! -e "$log" ]
  [ "$(printf '%s\n' "$start_output" | grep -c '^agmsg: orphan candidate ')" -eq 1 ]
  [[ "$start_output" == *"team=s-DEAD worker=A bridge_pid=$worker_pid spawn_age_s="* ]]
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

  test_fixture_start_reaped_process sleep 300
  local stale_pid="$TEST_REAPED_PID"
  test_fixture_start_reaped_process sleep 300
  local live_pid="$TEST_REAPED_PID"
  test_fixture_start_reaped_process sleep 300
  local owner_pid="$TEST_REAPED_PID"
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
  [ "$status" -eq 0 ]
  run kill -0 "$live_pid"
  [ "$status" -eq 0 ]
  [ -e "$live_rec" ]
  [ -e "$stale_rec" ]
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

@test "session-start orphan GC reports one candidate and live bridge veto preserves TTL artifacts" {
  enable_session_team

  local team='s-DEAD-FEED' name='worker' rec
  mkdir -p "$TEST_SKILL_DIR/run" "$TEST_SKILL_DIR/teams/$team"
  printf '{"name":"%s","agents":{}}\n' "$team" \
    > "$TEST_SKILL_DIR/teams/$team/config.json"
  rec="$(agmsg_spawn_path "$team" "$name")"
  test_fixture_start_reaped_process sleep 300
  local worker_pid="$TEST_REAPED_PID"
  printf 'pid:%s\t%s\tcodex\n' "$worker_pid" "$PROJ" > "$rec"
  touch -t 202501010000 \
    "$TEST_SKILL_DIR/teams/$team/config.json" "$TEST_SKILL_DIR/teams/$team"

  run run_session_start
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c "^agmsg: orphan candidate team=$team worker=$name ")" -eq 1 ]
  [[ "$output" == *"session-team TTL GC skipped team=$team reason=live-bridge bridge_pid=$worker_pid"* ]]
  [ -f "$rec" ]
  [ -d "$TEST_SKILL_DIR/teams/$team" ]
  kill "$worker_pid" 2>/dev/null || true
}

@test "session-start TTL GC keeps every artifact shape when the bare owner is live" {
  enable_session_team

  local owner_pid team kind rec
  for kind in none stale interactive malformed; do
    team="s-A11CE-$kind"
    mkdir -p "$TEST_SKILL_DIR/teams/$team"
    printf '{"name":"%s","agents":{}}\n' "$team" > "$TEST_SKILL_DIR/teams/$team/config.json"
    test_fixture_start_reaped_process sleep 300
    owner_pid="$TEST_REAPED_PID"
    printf '%s\n' "${team#s-}" > "$TEST_SKILL_DIR/run/cc-instance.$owner_pid"
    rec="$(agmsg_spawn_path "$team" worker)"
    case "$kind" in
      none) ;;
      stale) printf 'pid:99999999\t%s\tcodex\n' "$PROJ" > "$rec" ;;
      interactive) printf '%%99\t%s\tclaude-code\n' "$PROJ" > "$rec" ;;
      malformed) printf 'not-a-record\n' > "$rec" ;;
    esac
    printf '%s\n' "$kind" > "$TEST_SKILL_DIR/teams/$team/artifact"
    touch -t 202501010000 "$TEST_SKILL_DIR/teams/$team" "$TEST_SKILL_DIR/teams/$team/config.json"
  done

  run run_session_start
  [ "$status" -eq 0 ]
  for kind in none stale interactive malformed; do
    team="s-A11CE-$kind"
    [ -f "$TEST_SKILL_DIR/teams/$team/artifact" ]
    [[ "$output" == *"session-team TTL GC skipped team=$team reason=bare-owner-alive"* ]]
  done
}

@test "session-start TTL GC sanitizes both skip-log team fields" {
  enable_session_team

  local owner_team=$'s-A11CE\nOWNER' bridge_team=$'s-B71D6E\nBRIDGE'
  local owner_pid bridge_pid raw_bridge_rec
  mkdir -p "$TEST_SKILL_DIR/teams/$owner_team" \
    "$TEST_SKILL_DIR/teams/$bridge_team"
  test_fixture_start_reaped_process sleep 300
  owner_pid="$TEST_REAPED_PID"
  printf '%s\n' "${owner_team#s-}" > "$TEST_SKILL_DIR/run/cc-instance.$owner_pid"
  test_fixture_start_reaped_process sleep 300
  bridge_pid="$TEST_REAPED_PID"
  raw_bridge_rec="$TEST_SKILL_DIR/run/spawn.${bridge_team}__worker"
  printf 'pid:%s\t%s\tcodex\n' "$bridge_pid" "$PROJ" > "$raw_bridge_rec"

  run run_session_start
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '^agmsg: session-team TTL GC skipped team=s-A11CEOWNER reason=bare-owner-alive$')" -eq 1 ]
  [ "$(printf '%s\n' "$output" | grep -c "^agmsg: session-team TTL GC skipped team=s-B71D6EBRIDGE reason=live-bridge bridge_pid=$bridge_pid$")" -eq 1 ]
  [ "$(printf '%s\n' "$output" | grep -Ec '^(OWNER|BRIDGE) reason=')" -eq 0 ]
  kill -0 "$owner_pid" 2>/dev/null
  kill -0 "$bridge_pid" 2>/dev/null
}

@test "session-start TTL GC keeps a live bridge and deletes only an all-dead team" {
  enable_session_team

  local live_team=s-B71D6E dead_team=s-DEAD77 live_rec dead_rec
  mkdir -p "$TEST_SKILL_DIR/teams/$live_team" "$TEST_SKILL_DIR/teams/$dead_team"
  printf '{"name":"%s","agents":{}}\n' "$live_team" > "$TEST_SKILL_DIR/teams/$live_team/config.json"
  printf '{"name":"%s","agents":{}}\n' "$dead_team" > "$TEST_SKILL_DIR/teams/$dead_team/config.json"
  test_fixture_start_reaped_process sleep 300
  local bridge_pid="$TEST_REAPED_PID"
  live_rec="$(agmsg_spawn_path "$live_team" worker)"
  dead_rec="$(agmsg_spawn_path "$dead_team" worker)"
  printf 'pid:%s\t%s\tcodex\n' "$bridge_pid" "$PROJ" > "$live_rec"
  printf 'pid:99999999\t%s\tcodex\n' "$PROJ" > "$dead_rec"
  touch -t 202501010000 "$TEST_SKILL_DIR/teams/$live_team" \
    "$TEST_SKILL_DIR/teams/$live_team/config.json" "$TEST_SKILL_DIR/teams/$dead_team" \
    "$TEST_SKILL_DIR/teams/$dead_team/config.json"

  run run_session_start
  [ "$status" -eq 0 ]
  [ -d "$TEST_SKILL_DIR/teams/$live_team" ]
  [ -f "$live_rec" ]
  [ ! -d "$TEST_SKILL_DIR/teams/$dead_team" ]
  [ ! -e "$dead_rec" ]
  [[ "$output" == *"session-team TTL GC skipped team=$live_team reason=live-bridge bridge_pid=$bridge_pid"* ]]
  kill "$bridge_pid" 2>/dev/null || true
}

@test "session-start TTL GC removes retained pending records with the stale team" {
  enable_session_team

  local team=s-DEAD-PENDING name=worker rec pending
  mkdir -p "$TEST_SKILL_DIR/teams/$team"
  printf '{"name":"%s","agents":{}}\n' "$team" \
    > "$TEST_SKILL_DIR/teams/$team/config.json"
  rec="$(agmsg_spawn_path "$team" "$name")"
  printf 'pid:2147483647\t%s\tcodex\n' "$PROJ" > "$rec"
  agmsg_pending_teardown_write "$team" "$name" codex test-ttl-pending \
    "$(cat "$rec")" unverified DEAD-PENDING "" "" DEAD-PENDING ""
  pending="$(agmsg_pending_teardown_path "$team" "$name")"
  [ -f "$pending" ]
  touch -t 202501010000 "$TEST_SKILL_DIR/teams/$team" \
    "$TEST_SKILL_DIR/teams/$team/config.json"

  run run_session_start
  [ "$status" -eq 0 ]
  [ ! -d "$TEST_SKILL_DIR/teams/$team" ]
  [ ! -e "$rec" ]
  [ ! -e "$pending" ]
}

@test "session-start TTL GC keeps teams whose pid placement is malformed or zero" {
  enable_session_team

  local kind team rec
  for kind in abc zero; do
    team="s-DEAD10$kind"
    mkdir -p "$TEST_SKILL_DIR/teams/$team"
    printf '{"name":"%s","agents":{}}\n' "$team" \
      > "$TEST_SKILL_DIR/teams/$team/config.json"
    rec="$(agmsg_spawn_path "$team" worker)"
    case "$kind" in
      abc) printf 'pid:abc\t%s\tcodex\n' "$PROJ" > "$rec" ;;
      zero) printf 'pid:0\t%s\tcodex\n' "$PROJ" > "$rec" ;;
    esac
    printf '%s\n' "$kind" > "$TEST_SKILL_DIR/teams/$team/artifact"
    touch -t 202501010000 \
      "$TEST_SKILL_DIR/teams/$team" "$TEST_SKILL_DIR/teams/$team/config.json"
  done

  run run_session_start
  [ "$status" -eq 0 ]
  for kind in abc zero; do
    team="s-DEAD10$kind"
    [ -f "$TEST_SKILL_DIR/teams/$team/artifact" ]
    [ -f "$(agmsg_spawn_path "$team" worker)" ]
    [[ "$output" == *"session-team TTL GC skipped team=$team reason=unverified-placement"* ]]
  done
}

@test "session-start TTL GC keeps a team with live inflight even without a spawn record" {
  enable_session_team

  local team=s-DEAD1F17 name=worker pid start rec consumers="$TEST_SKILL_DIR/run/c-live"
  mkdir -p "$TEST_SKILL_DIR/run" "$TEST_SKILL_DIR/teams/$team"
  printf '{"name":"%s","agents":{}}\n' "$team" \
    > "$TEST_SKILL_DIR/teams/$team/config.json"
  test_fixture_start_reaped_process sleep 300
  pid="$TEST_REAPED_PID"
  start="$(agmsg_pid_start_token "$pid")"
  printf 'alice\t8\n' > "$consumers"
  agmsg_inflight_write "$team" "$name" codex 1 "$pid" "$start" "$consumers"
  rec="$(agmsg_inflight_path "$team" "$name" 1 "$start")"
  [ -f "$rec" ]
  [ ! -e "$(agmsg_spawn_path "$team" "$name")" ]
  touch -t 202501010000 \
    "$TEST_SKILL_DIR/teams/$team" "$TEST_SKILL_DIR/teams/$team/config.json"

  run run_session_start
  [ "$status" -eq 0 ]
  [[ "$output" == *"session-team TTL GC skipped team=$team reason=live-inflight"* ]]
  [ -d "$TEST_SKILL_DIR/teams/$team" ]
  [ -f "$rec" ]
  kill "$pid" 2>/dev/null || true
}

@test "session-start TTL GC reaps dead inflight then deletes the stale team" {
  enable_session_team

  local team=s-DEADDEAD name=worker pid start rec consumers="$TEST_SKILL_DIR/run/c-dead"
  mkdir -p "$TEST_SKILL_DIR/run" "$TEST_SKILL_DIR/teams/$team"
  printf '{"name":"%s","agents":{}}\n' "$team" \
    > "$TEST_SKILL_DIR/teams/$team/config.json"
  test_fixture_start_reaped_process sleep 300
  pid="$TEST_REAPED_PID"
  start="$(agmsg_pid_start_token "$pid")"
  printf 'alice\t9\n' > "$consumers"
  agmsg_inflight_write "$team" "$name" codex 1 "$pid" "$start" "$consumers"
  rec="$(agmsg_inflight_path "$team" "$name" 1 "$start")"
  [ -f "$rec" ]
  kill "$pid" 2>/dev/null || true
  wait_until 5 _pid_gone "$pid"
  touch -t 202501010000 \
    "$TEST_SKILL_DIR/teams/$team" "$TEST_SKILL_DIR/teams/$team/config.json"

  run run_session_start
  [ "$status" -eq 0 ]
  [ ! -d "$TEST_SKILL_DIR/teams/$team" ]
  [ ! -e "$rec" ]
}
