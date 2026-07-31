#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
  export PROJ="$TEST_SKILL_DIR/project"
  export RUN="$TEST_SKILL_DIR/run"
  mkdir -p "$PROJ" "$RUN"
  unset TMUX_PANE HERDR_PANE_ID HERDR_ENV
}

teardown() {
  teardown_test_env
}

@test "force despawn scopes reset to the operated team" {
  bash "$SCRIPTS/join.sh" team-a alice claude-code "$PROJ" >/dev/null
  bash "$SCRIPTS/join.sh" team-b alice claude-code "$PROJ" >/dev/null
  printf '%%99\t%s\tclaude-code\n' "$PROJ" > "$RUN/spawn.team-a__alice"

  run bash "$SCRIPTS/despawn.sh" team-a leader alice --force
  [ "$status" -eq 0 ]
  [ ! -e "$RUN/spawn.team-a__alice" ]

  run bash "$SCRIPTS/identities.sh" "$PROJ" claude-code
  [ "$status" -eq 0 ]
  [[ "$output" != *$'team-a\talice'* ]]
  [[ "$output" == *$'team-b\talice'* ]]
}

@test "graceful watch ctrl:despawn scopes reset to the message team" {
  bash "$SCRIPTS/join.sh" team-a alice claude-code "$PROJ" >/dev/null
  bash "$SCRIPTS/join.sh" team-a leader claude-code "$PROJ" >/dev/null
  bash "$SCRIPTS/join.sh" team-b alice claude-code "$PROJ" >/dev/null

  AGMSG_WATCH_INTERVAL=1 env -u TMUX_PANE -u HERDR_PANE_ID -u HERDR_ENV \
    bash "$SCRIPTS/watch.sh" sess-internal "$PROJ" claude-code alice \
    >"$RUN/watch.out" 2>"$RUN/watch.err" 3>&- &
  local watch_pid=$!
  wait_for_file "$RUN/ready.team-a__alice"

  run bash "$SCRIPTS/send.sh" team-a leader alice ctrl:despawn
  [ "$status" -eq 0 ]
  wait_for_pid_exit "$watch_pid"
  wait "$watch_pid" 2>/dev/null || true

  run bash "$SCRIPTS/identities.sh" "$PROJ" claude-code
  [ "$status" -eq 0 ]
  [[ "$output" != *$'team-a\talice'* ]]
  [[ "$output" == *$'team-b\talice'* ]]
}

@test "claude-code spawn unwind helper scopes reset to its team" {
  bash "$SCRIPTS/join.sh" team-a alice claude-code "$PROJ" >/dev/null
  bash "$SCRIPTS/join.sh" team-b alice claude-code "$PROJ" >/dev/null

  run bash -c '
    SCRIPT_DIR="$1"
    source "$SCRIPT_DIR/drivers/types/claude-code/_spawn.sh"
    agmsg_claude_reset_registration team-a "$2" alice
  ' _ "$SCRIPTS" "$PROJ"
  [ "$status" -eq 0 ]

  run bash "$SCRIPTS/identities.sh" "$PROJ" claude-code
  [ "$status" -eq 0 ]
  [[ "$output" != *$'team-a\talice'* ]]
  [[ "$output" == *$'team-b\talice'* ]]
}
