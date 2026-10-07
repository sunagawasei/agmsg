#!/usr/bin/env bats

# agmsg_session_team_enabled keeps its answer for the rest of one process only
# when that process opts in (session-start.sh). Anything else re-reads the config.

load test_helper

setup() {
  setup_test_env
  PROJ="$BATS_TEST_TMPDIR/project"
  mkdir -p "$PROJ"
}

teardown() {
  teardown_test_env
}

enable_st()  { bash "$SCRIPTS/config.sh" set delivery.session_team true >/dev/null; }
disable_st() { bash "$SCRIPTS/config.sh" set delivery.session_team false >/dev/null; }

# Prints the answer for each of two calls, with the config flipped between them.
two_calls() {
  SCRIPTS="$SCRIPTS" CFG="$SCRIPTS/config.sh" bash -c '
    source "$SCRIPTS/lib/session-team.sh"
    '"$1"'
    a=no; agmsg_session_team_enabled && a=yes
    bash "$CFG" set delivery.session_team false >/dev/null
    b=no; agmsg_session_team_enabled && b=yes
    echo "$a $b"'
}

@test "a process that did not opt in sees a config change between two calls" {
  enable_st
  run two_calls ':'
  [ "$status" -eq 0 ]
  [ "$output" = "yes no" ]
}

@test "an opted-in process keeps its first answer" {
  enable_st
  run two_calls '_AGMSG_SESSION_TEAM_MEMO=1'
  [ "$status" -eq 0 ]
  [ "$output" = "yes yes" ]
}

@test "session-start ignores an inherited exported memo and value" {
  enable_st
  run env _AGMSG_SESSION_TEAM_MEMO=1 _AGMSG_SESSION_TEAM_VAL=0 \
    bash "$SCRIPTS/session-start.sh" claude-code "$PROJ" \
    <<< '{"session_id":"sess-MEMO"}'
  [ "$status" -eq 0 ]
  [ -d "$TEST_SKILL_DIR/teams/s-sess-MEMO" ]
}
