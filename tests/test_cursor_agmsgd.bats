#!/usr/bin/env bats
# cursor seats reached through agmsgd: nudge conditions, mis-delivery guard and
# the offer line. A stub herdr and temp dirs only; the real install is untouched.

setup() {
  export TEST_SKILL_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cursor-agmsgd.XXXXXX")"
  TEST_SKILL_DIR="$(cd "$TEST_SKILL_DIR" && pwd -P)"
}

teardown() { rm -rf "$TEST_SKILL_DIR"; }

@test "cursor channel: nudges an idle pane once, leaves messages untouched, uses the record socket" {
  run node "$BATS_TEST_DIRNAME/helpers/cursor_agmsgd_channel.mjs" nudge
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"nudge ok"* ]]
}

@test "cursor channel: a pane with another terminal_id is not nudged and the seat is blocked" {
  run node "$BATS_TEST_DIRNAME/helpers/cursor_agmsgd_channel.mjs" wrong-terminal
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"wrong-terminal ok"* ]]
}

@test "daemon offer cursor: available with herdr on PATH, unavailable naming herdr without it" {
  cp -R "$BATS_TEST_DIRNAME/../scripts" "$TEST_SKILL_DIR/scripts"
  mkdir -p "$TEST_SKILL_DIR/run" "$TEST_SKILL_DIR/db" "$TEST_SKILL_DIR/bin"
  export AGMSG_CONFIG="$TEST_SKILL_DIR/config.json"
  export AGMSG_STORAGE_PATH="$TEST_SKILL_DIR/db"
  sqlite3 "$TEST_SKILL_DIR/run/install.db" < "$TEST_SKILL_DIR/scripts/daemon/schema.sql"

  # Only the stub directory plus the tools daemon.sh needs; the developer's own herdr must not leak in.
  local tools="$TEST_SKILL_DIR/tools" t
  mkdir -p "$tools"
  for t in bash sh sqlite3 tr dirname basename cat sed awk date uname mkdir node; do
    ln -s "$(command -v "$t")" "$tools/$t"
  done

  run env PATH="$tools" bash "$TEST_SKILL_DIR/scripts/daemon.sh" offer cursor
  [ "$status" -eq 0 ]
  [[ "$output" == "agmsgd=unavailable reason="*herdr* ]]

  printf '#!/bin/sh\nexit 0\n' > "$TEST_SKILL_DIR/bin/herdr"
  chmod +x "$TEST_SKILL_DIR/bin/herdr"
  run env PATH="$TEST_SKILL_DIR/bin:$tools" bash "$TEST_SKILL_DIR/scripts/daemon.sh" offer cursor
  [ "$status" -eq 0 ]
  [ "$output" = "agmsgd=available" ]
}
