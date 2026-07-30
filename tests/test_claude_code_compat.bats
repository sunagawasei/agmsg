#!/usr/bin/env bats

# Black-box lifecycle compatibility fixtures for claude-code headless records.
# These tests use sleep(1) with controlled argv and isolated files; they do not
# claim to validate the real Claude CLI or Layer-2 process-tree behavior.

load test_helper

setup() {
  setup_test_env
  export SKILL_DIR="$TEST_SKILL_DIR"
  export RUN="$TEST_SKILL_DIR/run"
  export PROJ="$TEST_SKILL_DIR/project"
  export TEAM='s-C0DE-001'
  export TEST_PIDS=''
  export FAKE_LIVE_STATE="$TEST_SKILL_DIR/fake-live-state"
  export FAKE_SIGNAL_LOG="$TEST_SKILL_DIR/fake-signal.log"
  export FAKE_KILL_ENV="$TEST_SKILL_DIR/fake-kill-env.sh"
  mkdir -p "$RUN" "$PROJ"
  bash "$SCRIPTS/config.sh" set delivery.session_team true >/dev/null
  : > "$FAKE_LIVE_STATE"
  : > "$FAKE_SIGNAL_LOG"
  cat > "$FAKE_KILL_ENV" <<'EOF'
kill() {
  case "${1:-}" in
    -0)
      grep -Fxq "${2:-}" "$FAKE_LIVE_STATE" 2>/dev/null
      return $?
      ;;
    -9)
      printf 'KILL\t%s\n' "${2:-}" >> "$FAKE_SIGNAL_LOG"
      return 0
      ;;
    *)
      printf 'TERM\t%s\n' "${1:-}" >> "$FAKE_SIGNAL_LOG"
      grep -Fvx "${1:-}" "$FAKE_LIVE_STATE" > "$FAKE_LIVE_STATE.tmp" 2>/dev/null || true
      mv "$FAKE_LIVE_STATE.tmp" "$FAKE_LIVE_STATE"
      return 0
      ;;
  esac
}
EOF
  # shellcheck disable=SC1091
  source "$SCRIPTS/lib/actas-lock.sh"
  # shellcheck disable=SC1091
  source "$SCRIPTS/lib/identity-key.sh"
}

teardown() {
  local pid
  for pid in $TEST_PIDS; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  teardown_test_env
}

start_sleep_process() {
  sleep 300 &
  LAST_PID=$!
  TEST_PIDS="$TEST_PIDS $LAST_PID"
}

start_identity_process() {
  local name="$1" mode="${2:-correct}" type="${3:-claude-code}" key cmd
  case "$mode" in
    correct) key="$(agmsg_identity_key "$TEAM" "$name")"; cmd="node /fake/$type-bridge --identity-key $key" ;;
    wrong) key="$(agmsg_identity_key "$TEAM" wrong-identity)"; cmd="node /fake/$type-bridge --identity-key $key" ;;
    wrong-bridge) key="$(agmsg_identity_key "$TEAM" "$name")"; cmd="node /fake/prefix-$type-bridge-suffix --identity-key $key" ;;
    key-suffix) key="$(agmsg_identity_key "$TEAM" "$name")suffix"; cmd="node /fake/$type-bridge --identity-key $key" ;;
    missing) cmd="node /fake/$type-bridge" ;;
    *) return 1 ;;
  esac
  FAKE_NEXT_PID=$(( ${FAKE_NEXT_PID:-41000} + 1 ))
  LAST_PID="$FAKE_NEXT_PID"
  LAST_CMD="$cmd"
  printf '%s\n' "$LAST_PID" >> "$FAKE_LIVE_STATE"
}

assert_fake_alive() { grep -Fxq "$1" "$FAKE_LIVE_STATE"; }
assert_fake_dead() { ! grep -Fxq "$1" "$FAKE_LIVE_STATE"; }
assert_fake_signaled() { grep -Fxq $'TERM\t'"$1" "$FAKE_SIGNAL_LOG"; }
assert_fake_not_signaled() { ! grep -Fxq $'TERM\t'"$1" "$FAKE_SIGNAL_LOG"; }

write_record() {
  local team="$1" name="$2" pid="$3" project="${4:-$PROJ}" type="${5:-claude-code}"
  printf 'pid:%s\t%s\t%s\n' "$pid" "$project" "$type" \
    > "$(agmsg_spawn_path "$team" "$name")"
}

start_extension_process() {
  local name="$1" type="$2" extension="$3" key cmd
  key="$(agmsg_identity_key "$TEAM" "$name")"
  cmd="node /fake/$type-bridge.$extension --identity-key $key"
  FAKE_NEXT_PID=$(( ${FAKE_NEXT_PID:-41000} + 1 ))
  LAST_PID="$FAKE_NEXT_PID"
  LAST_CMD="$cmd"
  printf '%s\n' "$LAST_PID" >> "$FAKE_LIVE_STATE"
}

write_meta() {
  local team="$1" name="$2" pid="$3"
  printf 'pid=%s\nproject=%s\nteam=%s\nname=%s\ntype=claude-code\n' \
    "$pid" "$PROJ" "$team" "$name" \
    > "$RUN/claude-code-bridge.$team.$name.meta"
}

write_claude_artifacts() {
  local team="$1" name="$2" marker="$3" base suffix
  base="$RUN/claude-code-bridge.$team.$name"
  for suffix in pid meta log role settings.json session candidate prompt rows selected consumed stdout.json stderr watch failstate outbound.json; do
    printf '%s\n' "$marker" > "$base.$suffix"
  done
  mkdir -p "$RUN/claude-code-$team-$name-cwd"
  printf '%s\n' "$marker" > "$RUN/claude-code-$team-$name-cwd/marker"
}

assert_claude_artifacts_absent() {
  local team="$1" name="$2" base suffix
  base="$RUN/claude-code-bridge.$team.$name"
  for suffix in pid meta log role settings.json session candidate prompt rows selected consumed stdout.json stderr watch failstate outbound.json; do
    [ ! -e "$base.$suffix" ]
  done
  [ ! -e "$RUN/claude-code-$team-$name-cwd" ]
}

@test "despawn meta-present claude-code record kills only its fake bridge and retires generic state" {
  local name='worker' sibling='sibling'
  bash "$SCRIPTS/join.sh" "$TEAM" "$name" claude-code "$PROJ" >/dev/null
  bash "$SCRIPTS/join.sh" "$TEAM" "$sibling" claude-code "$PROJ" >/dev/null
  start_sleep_process
  write_record "$TEAM" "$name" "$LAST_PID"
  write_claude_artifacts "$TEAM" "$name" target
  write_meta "$TEAM" "$name" "$LAST_PID"
  write_claude_artifacts "$TEAM" "$sibling" sibling
  printf '%%42\t%s\tclaude-code\n' "$PROJ" > "$(agmsg_spawn_path "$TEAM" "$sibling")"

  run bash "$SCRIPTS/despawn.sh" "$TEAM" leader "$name" --force
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=forced"* ]]
  run kill -0 "$LAST_PID"
  [ "$status" -ne 0 ]
  [ ! -e "$(agmsg_spawn_path "$TEAM" "$name")" ]
  [ ! -e "$RUN/claude-code-bridge.$TEAM.$name.role" ]
  [ ! -e "$RUN/claude-code-bridge.$TEAM.$name.failstate" ]
  [ ! -e "$RUN/claude-code-bridge.$TEAM.$name.outbound.json" ]
  [ -f "$RUN/claude-code-bridge.$TEAM.$name.log" ]
  [ -f "$RUN/claude-code-bridge.$TEAM.$name.settings.json" ]
  [ -f "$RUN/claude-code-bridge.$TEAM.$name.session" ]
  [ -d "$RUN/claude-code-$TEAM-$name-cwd" ]
  [ -e "$(agmsg_spawn_path "$TEAM" "$sibling")" ]
  [ -f "$RUN/claude-code-bridge.$TEAM.$sibling.role" ]
  run bash "$SCRIPTS/identities.sh" "$PROJ" claude-code
  ! printf '%s\n' "$output" | grep -Fxq "$TEAM"$'\t'"$name"
  printf '%s\n' "$output" | grep -Fxq "$TEAM"$'\t'"$sibling"
}

@test "despawn meta-absent argv guard kills only exact claude-code identity" {
  local correct='argv-correct' wrong='argv-wrong' wrong_bridge='argv-wrong-bridge'
  local key_suffix='argv-key-suffix' missing='argv-missing'
  local codex='argv-codex' cursor='argv-cursor'
  local pid_correct pid_wrong pid_wrong_bridge pid_key_suffix pid_missing pid_codex pid_cursor
  local cmd_correct cmd_wrong cmd_wrong_bridge cmd_key_suffix cmd_missing cmd_codex cmd_cursor
  local ps_stub="$TEST_SKILL_DIR/ps-stub"
  mkdir -p "$ps_stub"
  cat > "$ps_stub/ps" <<'EOF'
#!/usr/bin/env bash
if [ "$*" = "-o args= -p $FAKE_PS_PID" ]; then
  printf '%s\n' "$FAKE_PS_ARGS"
  exit 0
fi
exit 1
EOF
  chmod +x "$ps_stub/ps"
  start_identity_process "$correct" correct; pid_correct="$LAST_PID"; cmd_correct="$LAST_CMD"
  start_identity_process "$wrong" wrong; pid_wrong="$LAST_PID"; cmd_wrong="$LAST_CMD"
  start_identity_process "$wrong_bridge" wrong-bridge; pid_wrong_bridge="$LAST_PID"; cmd_wrong_bridge="$LAST_CMD"
  start_identity_process "$key_suffix" key-suffix; pid_key_suffix="$LAST_PID"; cmd_key_suffix="$LAST_CMD"
  start_identity_process "$missing" missing; pid_missing="$LAST_PID"; cmd_missing="$LAST_CMD"
  start_extension_process "$codex" codex js; pid_codex="$LAST_PID"; cmd_codex="$LAST_CMD"
  start_extension_process "$cursor" cursor sh; pid_cursor="$LAST_PID"; cmd_cursor="$LAST_CMD"
  write_record "$TEAM" "$correct" "$pid_correct"
  write_record "$TEAM" "$wrong" "$pid_wrong"
  write_record "$TEAM" "$wrong_bridge" "$pid_wrong_bridge"
  write_record "$TEAM" "$key_suffix" "$pid_key_suffix"
  write_record "$TEAM" "$missing" "$pid_missing"
  write_record "$TEAM" "$codex" "$pid_codex" "$PROJ" codex
  write_record "$TEAM" "$cursor" "$pid_cursor" "$PROJ" cursor

  run env PATH="$ps_stub:$PATH" FAKE_PS_PID="$pid_correct" FAKE_PS_ARGS="$cmd_correct" \
    BASH_ENV="$FAKE_KILL_ENV" \
    bash "$SCRIPTS/despawn.sh" "$TEAM" leader "$correct" --force
  [ "$status" -eq 0 ]
  assert_fake_dead "$pid_correct"
  assert_fake_signaled "$pid_correct"

  run env PATH="$ps_stub:$PATH" FAKE_PS_PID="$pid_wrong" FAKE_PS_ARGS="$cmd_wrong" \
    BASH_ENV="$FAKE_KILL_ENV" \
    bash "$SCRIPTS/despawn.sh" "$TEAM" leader "$wrong" --force
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipping kill"* ]]
  assert_fake_alive "$pid_wrong"
  assert_fake_not_signaled "$pid_wrong"

  run env PATH="$ps_stub:$PATH" FAKE_PS_PID="$pid_wrong_bridge" FAKE_PS_ARGS="$cmd_wrong_bridge" \
    BASH_ENV="$FAKE_KILL_ENV" \
    bash "$SCRIPTS/despawn.sh" "$TEAM" leader "$wrong_bridge" --force
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipping kill"* ]]
  assert_fake_alive "$pid_wrong_bridge"
  assert_fake_not_signaled "$pid_wrong_bridge"

  run env PATH="$ps_stub:$PATH" FAKE_PS_PID="$pid_key_suffix" FAKE_PS_ARGS="$cmd_key_suffix" \
    BASH_ENV="$FAKE_KILL_ENV" \
    bash "$SCRIPTS/despawn.sh" "$TEAM" leader "$key_suffix" --force
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipping kill"* ]]
  assert_fake_alive "$pid_key_suffix"
  assert_fake_not_signaled "$pid_key_suffix"

  run env PATH="$ps_stub:$PATH" FAKE_PS_PID="$pid_missing" FAKE_PS_ARGS="$cmd_missing" \
    BASH_ENV="$FAKE_KILL_ENV" \
    bash "$SCRIPTS/despawn.sh" "$TEAM" leader "$missing" --force
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipping kill"* ]]
  assert_fake_alive "$pid_missing"
  assert_fake_not_signaled "$pid_missing"

  run env PATH="$ps_stub:$PATH" FAKE_PS_PID="$pid_codex" FAKE_PS_ARGS="$cmd_codex" \
    BASH_ENV="$FAKE_KILL_ENV" \
    bash "$SCRIPTS/despawn.sh" "$TEAM" leader "$codex" --force
  [ "$status" -eq 0 ]
  assert_fake_dead "$pid_codex"
  assert_fake_signaled "$pid_codex"

  run env PATH="$ps_stub:$PATH" FAKE_PS_PID="$pid_cursor" FAKE_PS_ARGS="$cmd_cursor" \
    BASH_ENV="$FAKE_KILL_ENV" \
    bash "$SCRIPTS/despawn.sh" "$TEAM" leader "$cursor" --force
  [ "$status" -eq 0 ]
  assert_fake_dead "$pid_cursor"
  assert_fake_signaled "$pid_cursor"
}

@test "despawn expect-record mismatch is per-worker no-op and matching snapshot tears down" {
  local name='expect-worker' current stale pid
  start_sleep_process
  pid="$LAST_PID"
  write_record "$TEAM" "$name" "$pid"
  write_meta "$TEAM" "$name" "$pid"
  printf 'spooled\n' > "$RUN/claude-code-bridge.$TEAM.$name.outbound.json"
  current="$(printf 'pid:%s\t%s\tclaude-code' "$pid" "$PROJ")"
  stale="$(printf 'pid:%s\t%s\tclaude-code' 999999 /old/project)"

  run bash "$SCRIPTS/despawn.sh" "$TEAM" leader "$name" --force --expect-record "$stale"
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=skipped"* ]] || [[ "$output" == *"record-changed"* ]]
  [ "$(cat "$(agmsg_spawn_path "$TEAM" "$name")")" = "$current" ]
  run kill -0 "$pid"
  [ "$status" -eq 0 ]
  [ -f "$RUN/claude-code-bridge.$TEAM.$name.outbound.json" ]

  run bash "$SCRIPTS/despawn.sh" "$TEAM" leader "$name" --force --expect-record "$current"
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=forced"* ]]
  run kill -0 "$pid"
  [ "$status" -ne 0 ]
  [ ! -e "$(agmsg_spawn_path "$TEAM" "$name")" ]
}

@test "session-end worker reaps matching claude-code headless rows and preserves mismatch and interactive rows" {
  local session='C0DE-SESSION-001' steam="s-C0DE-SESSION-001"
  local mismatch='mismatch-worker' peer='peer-worker' mismatch_pid peer_pid snapshot
  snapshot="$RUN/session-end.snapshot"
  start_sleep_process; mismatch_pid="$LAST_PID"
  start_sleep_process; peer_pid="$LAST_PID"
  write_record "$steam" "$mismatch" "$mismatch_pid"
  write_meta "$steam" "$mismatch" "$mismatch_pid"
  write_record "$steam" "$peer" "$peer_pid"
  write_meta "$steam" "$peer" "$peer_pid"
  printf '%%41\t%s\tclaude-code\n' "$PROJ" > "$(agmsg_spawn_path "$steam" interactive-worker)"
  printf '%s\t%s\n' "$mismatch" "$(printf 'pid:%s\t%s\tclaude-code' "$mismatch_pid" /old/project)" > "$snapshot"
  printf '%s\t%s\n' "$peer" "$(printf 'pid:%s\t%s\tclaude-code' "$peer_pid" "$PROJ")" >> "$snapshot"

  run bash "$SCRIPTS/session-end-worker.sh" claude-code "$PROJ" "$session" "$session" "$snapshot"
  [ "$status" -eq 0 ]
  run kill -0 "$mismatch_pid"
  [ "$status" -eq 0 ]
  [ -f "$(agmsg_spawn_path "$steam" "$mismatch")" ]
  run kill -0 "$peer_pid"
  [ "$status" -ne 0 ]
  [ ! -e "$(agmsg_spawn_path "$steam" "$peer")" ]
  [ -f "$(agmsg_spawn_path "$steam" interactive-worker)" ]
}

@test "session-start orphan GC reaps claude-code records and preserves interactive records" {
  local orphan_team='s-C0DE-101' interactive_team='s-C0DE-104'
  local orphan_name='orphan-worker' orphan_pid
  mkdir -p "$TEST_SKILL_DIR/teams/$orphan_team" "$TEST_SKILL_DIR/teams/$interactive_team"
  printf '{"name":"%s","agents":{}}\n' "$orphan_team" > "$TEST_SKILL_DIR/teams/$orphan_team/config.json"
  printf '{"name":"%s","agents":{}}\n' "$interactive_team" > "$TEST_SKILL_DIR/teams/$interactive_team/config.json"
  start_sleep_process; orphan_pid="$LAST_PID"
  write_record "$orphan_team" "$orphan_name" "$orphan_pid"
  write_meta "$orphan_team" "$orphan_name" "$orphan_pid"
  printf '%%99\t%s\tclaude-code\n' "$PROJ" > "$(agmsg_spawn_path "$interactive_team" interactive-worker)"

  run bash -c "printf '{\"session_id\":\"DEAD-BEEF-0001\"}' | bash '$SCRIPTS/session-start.sh' claude-code '$PROJ'"
  [ "$status" -eq 0 ]
  run kill -0 "$orphan_pid"
  [ "$status" -ne 0 ]
  [ ! -e "$(agmsg_spawn_path "$orphan_team" "$orphan_name")" ]
  [ -f "$(agmsg_spawn_path "$interactive_team" interactive-worker)" ]
  [ -d "$TEST_SKILL_DIR/teams/$orphan_team" ]
  [ -d "$TEST_SKILL_DIR/teams/$interactive_team" ]
}

@test "session-start TTL GC reaps stale claude-code artifacts and preserves fresh and interactive state" {
  local ttl_team='s-C0DE-102' fresh_team='s-C0DE-103' interactive_team='s-C0DE-104'
  local ttl_name='stale-worker' fresh_name='fresh-worker'
  mkdir -p "$TEST_SKILL_DIR/teams/$ttl_team" "$TEST_SKILL_DIR/teams/$fresh_team" \
    "$TEST_SKILL_DIR/teams/$interactive_team"
  printf '{"name":"%s","agents":{}}\n' "$ttl_team" > "$TEST_SKILL_DIR/teams/$ttl_team/config.json"
  printf '{"name":"%s","agents":{}}\n' "$fresh_team" > "$TEST_SKILL_DIR/teams/$fresh_team/config.json"
  printf '{"name":"%s","agents":{}}\n' "$interactive_team" > "$TEST_SKILL_DIR/teams/$interactive_team/config.json"
  write_claude_artifacts "$ttl_team" "$ttl_name" stale
  write_claude_artifacts "$fresh_team" "$fresh_name" fresh
  printf '%%99\t%s\tclaude-code\n' "$PROJ" > "$(agmsg_spawn_path "$interactive_team" interactive-worker)"
  touch -t 202501010000 \
    "$TEST_SKILL_DIR/teams/$ttl_team/config.json" "$TEST_SKILL_DIR/teams/$ttl_team"

  run bash -c "printf '{\"session_id\":\"DEAD-BEEF-0001\"}' | bash '$SCRIPTS/session-start.sh' claude-code '$PROJ'"
  [ "$status" -eq 0 ]
  [ ! -d "$TEST_SKILL_DIR/teams/$ttl_team" ]
  assert_claude_artifacts_absent "$ttl_team" "$ttl_name"
  [ -d "$TEST_SKILL_DIR/teams/$fresh_team" ]
  [ -f "$RUN/claude-code-bridge.$fresh_team.$fresh_name.meta" ]
  [ -d "$RUN/claude-code-$fresh_team-$fresh_name-cwd" ]
  [ -d "$TEST_SKILL_DIR/teams/$interactive_team" ]
}

@test "type registry and spawn path expose claude-code as a headless type" {
  run env -i PATH="$PATH" bash -c "source '$SCRIPTS/lib/type-registry.sh'; printf '%s\\n' \"\$(agmsg_type_get claude-code headless)\" \"\$(agmsg_type_get claude-code spawnable)\" \"\$(agmsg_type_get claude-code cli)\" \"\$(agmsg_type_get claude-code detect)\""
  [ "$status" -eq 0 ]
  [ "$output" = $'yes\nyes\nclaude\nCLAUDE_CODE_SESSION_ID' ]
  [ "$(agmsg_spawn_path "$TEAM" 'worker name')" = "$RUN/spawn.s-C0DE-001__worker%20name" ]
}
