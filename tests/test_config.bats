#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
}

teardown() {
  teardown_test_env
}

@test "config show: creates default config if none exists" {
  run bash "$SCRIPTS/config.sh" show
  [ "$status" -eq 0 ]
  [[ "$output" =~ "check_interval" ]]
  [ -f "$TEST_SKILL_DIR/db/config.yaml" ]
}

@test "config get: returns default value when no config" {
  run bash "$SCRIPTS/config.sh" get hook.check_interval 60
  [ "$status" -eq 0 ]
  [ "$output" = "60" ]
}

@test "config set: sets a value" {
  bash "$SCRIPTS/config.sh" set hook.check_interval 30
  run bash "$SCRIPTS/config.sh" get hook.check_interval
  [ "$status" -eq 0 ]
  [ "$output" = "30" ]
}

@test "config set: updates existing value" {
  bash "$SCRIPTS/config.sh" set hook.check_interval 30
  bash "$SCRIPTS/config.sh" set hook.check_interval 120
  run bash "$SCRIPTS/config.sh" get hook.check_interval
  [ "$output" = "120" ]
}

@test "config set: adds new section and key" {
  bash "$SCRIPTS/config.sh" show >/dev/null
  bash "$SCRIPTS/config.sh" set display.timestamp_format relative
  run bash "$SCRIPTS/config.sh" get display.timestamp_format
  [ "$output" = "relative" ]
}

@test "config get: returns default for missing key" {
  run bash "$SCRIPTS/config.sh" get nonexistent.key fallback
  [ "$output" = "fallback" ]
}

@test "config set: same field name in different sections" {
  bash "$SCRIPTS/config.sh" set hook.format abc
  bash "$SCRIPTS/config.sh" set display.format xyz
  run bash "$SCRIPTS/config.sh" get hook.format
  [ "$output" = "abc" ]
  run bash "$SCRIPTS/config.sh" get display.format
  [ "$output" = "xyz" ]
}

# --- literal key matching (a "." in a dotted per-worker field, e.g. the
# spawn.codex_implementer.<name> layout key, must NOT act as a regex wildcard) ---

@test "config get: a literal '.' in a per-worker key does not wildcard-match a decoy key one character off (fail closed)" {
  # Decoy stored FIRST: if the lookup below were still ERE-based, the
  # unescaped "." in "foo.bar" would match ANY character, including the "X"
  # in this decoy — silently returning true for a key that was never set.
  bash "$SCRIPTS/config.sh" set spawn.codex_implementer.fooXbar true
  run bash "$SCRIPTS/config.sh" get spawn.codex_implementer.foo.bar false
  [ "$output" = "false" ]
}

@test "config get/set: a dotted per-worker key and its 1-char-off decoy coexist without cross-contamination" {
  # Reverse order (dotted key set first) and opposite values, so a leak in
  # either direction would flip the wrong assertion.
  bash "$SCRIPTS/config.sh" set spawn.codex_implementer.foo.bar false
  bash "$SCRIPTS/config.sh" set spawn.codex_implementer.fooXbar true
  run bash "$SCRIPTS/config.sh" get spawn.codex_implementer.foo.bar default
  [ "$output" = "false" ]
  run bash "$SCRIPTS/config.sh" get spawn.codex_implementer.fooXbar default
  [ "$output" = "true" ]
}
