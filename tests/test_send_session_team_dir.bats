#!/usr/bin/env bats

# send.sh --force skips the roster check, so it must not write rows under the
# name of a reaped session team (no teams/<team> dir).

load test_helper

setup() {
  setup_test_env
  export SKILL_DIR="$TEST_SKILL_DIR"
  DB="$TEST_SKILL_DIR/db/messages.db"
  bash "$SCRIPTS/config.sh" set delivery.session_team true >/dev/null
}

teardown() { teardown_test_env; }

rows() {   # the events table may not exist when nothing was ever written
  [ -f "$DB" ] || { echo 0; return; }
  sqlite3 "$DB" "SELECT COUNT(*) FROM events WHERE type='message_sent' AND team='$1';" 2>/dev/null || echo 0
}

@test "--force to a dir-less s-<uuid> session team is refused and writes nothing" {
  run bash "$SCRIPTS/send.sh" s-11111111-2222-3333-4444-555555555555 a b hi --force
  [ "$status" -ne 0 ]
  [[ "$output" == *"session team 's-11111111-2222-3333-4444-555555555555' has no live directory"* ]]
  [ "$(rows s-11111111-2222-3333-4444-555555555555)" = 0 ]
}

@test "--force to a session team with a dir still sends" {
  mkdir -p "$TEST_SKILL_DIR/teams/s-live-1"
  run bash "$SCRIPTS/send.sh" s-live-1 a b hi --force
  [ "$status" -eq 0 ]
  [ "$(rows s-live-1)" = 1 ]
}

@test "--force to a dir-less non-s- project team still sends" {
  run bash "$SCRIPTS/send.sh" proj-x a b hi --force
  [ "$status" -eq 0 ]
  [ "$(rows proj-x)" = 1 ]
}

@test "a plain send to a session team without a dir keeps the roster error" {
  run bash "$SCRIPTS/send.sh" s-gone-2 a b hi
  [ "$status" -ne 0 ]
  [[ "$output" == *"has no registered agents"* ]]
  [ "$(rows s-gone-2)" = 0 ]
}

@test "--force to a dir-less s-foo is refused: the s- prefix is reserved while session teams are on" {
  run bash "$SCRIPTS/send.sh" s-foo a b hi --force
  [ "$status" -ne 0 ]
  [[ "$output" == *"session team 's-foo' has no live directory"* ]]
  [ "$(rows s-foo)" = 0 ]
}

@test "--force to a dir-less s-foo sends when delivery.session_team is off" {
  bash "$SCRIPTS/config.sh" set delivery.session_team false >/dev/null
  run bash "$SCRIPTS/send.sh" s-foo a b hi --force
  [ "$status" -eq 0 ]
  [ "$(rows s-foo)" = 1 ]
}
