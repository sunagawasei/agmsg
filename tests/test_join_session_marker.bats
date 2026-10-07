#!/usr/bin/env bats

# AGMSG_JOIN_MARK_SESSION_TEAM=1: the join that creates config.json writes the
# session-team marker first, and a failed marker write fails the join.

load test_helper

setup() {
  setup_test_env
  PROJ="$BATS_TEST_TMPDIR/project"
  mkdir -p "$PROJ"
}

teardown() {
  teardown_test_env
}

@test "MARK=1 creates the team with session-team and config.json" {
  AGMSG_JOIN_MARK_SESSION_TEAM=1 run bash "$SCRIPTS/join.sh" st1 alice claude-code "$PROJ"
  [ "$status" -eq 0 ]
  [ -f "$TEST_SKILL_DIR/teams/st1/session-team" ]
  [ -f "$TEST_SKILL_DIR/teams/st1/config.json" ]
}

@test "MARK=1 fails the join and leaves no config.json when the marker cannot be written" {
  mkdir -p "$TEST_SKILL_DIR/teams/st2/session-team"
  AGMSG_JOIN_MARK_SESSION_TEAM=1 run bash "$SCRIPTS/join.sh" st2 alice claude-code "$PROJ"
  [ "$status" -ne 0 ]
  [[ "$output" == *"session-team marker"* ]]
  [ ! -e "$TEST_SKILL_DIR/teams/st2/config.json" ]
}

@test "join without MARK does not create the marker" {
  run bash "$SCRIPTS/join.sh" st3 alice claude-code "$PROJ"
  [ "$status" -eq 0 ]
  [ -f "$TEST_SKILL_DIR/teams/st3/config.json" ]
  [ ! -e "$TEST_SKILL_DIR/teams/st3/session-team" ]
}

@test "MARK=1 on an existing team does not mark it" {
  run bash "$SCRIPTS/join.sh" st4 alice claude-code "$PROJ"
  [ "$status" -eq 0 ]
  AGMSG_JOIN_MARK_SESSION_TEAM=1 run bash "$SCRIPTS/join.sh" st4 bob claude-code "$PROJ"
  [ "$status" -eq 0 ]
  [ ! -e "$TEST_SKILL_DIR/teams/st4/session-team" ]
}
