#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
}

teardown() {
  teardown_test_env
}

audit_log() {
  printf '%s/run/team-config-audit.log' "$TEST_SKILL_DIR"
}

audit_count() {
  local log
  log="$(audit_log)"
  [ -f "$log" ] || { printf '0\n'; return 0; }
  wc -l < "$log" | tr -d ' '
}

audit_field() {
  local field="$1"
  awk -F '\t' -v field="$field" 'END { print $field }' "$(audit_log)"
}

@test "reset --team mutates only the validated target team" {
  bash "$SCRIPTS/join.sh" first alice claude-code /tmp/project
  bash "$SCRIPTS/join.sh" second alice claude-code /tmp/project

  run bash "$SCRIPTS/reset.sh" --team first /tmp/project claude-code alice
  [ "$status" -eq 0 ]
  [ ! -f "$TEST_SKILL_DIR/teams/first/config.json" ]
  [ -f "$TEST_SKILL_DIR/teams/second/config.json" ]
  [ "$(audit_count)" -eq 3 ]
  [ "$(audit_field 4)" = "first" ]
  [ "$(audit_field 5)" = "reset" ]
  [ "$(audit_field 6)" = "alice" ]
  [ "$(audit_field 7)" = "/tmp/project" ]
}

@test "scoped reset resolves an omitted agent only within the target team" {
  bash "$SCRIPTS/join.sh" first alice claude-code /tmp/project
  bash "$SCRIPTS/join.sh" second bob claude-code /tmp/project

  run bash "$SCRIPTS/reset.sh" --team first /tmp/project claude-code
  [ "$status" -eq 0 ]
  [ ! -d "$TEST_SKILL_DIR/teams/first" ]
  [ -f "$TEST_SKILL_DIR/teams/second/config.json" ]
  [ "$(audit_count)" -eq 3 ]
  [ "$(audit_field 4)" = "first" ]
  [ "$(audit_field 6)" = "alice" ]
}

@test "reset without --team preserves the all-team sweep" {
  bash "$SCRIPTS/join.sh" first alice claude-code /tmp/project
  bash "$SCRIPTS/join.sh" second alice claude-code /tmp/project

  run bash "$SCRIPTS/reset.sh" /tmp/project claude-code alice
  [ "$status" -eq 0 ]
  [[ "$output" =~ "across 2 team(s)" ]]
  [ ! -d "$TEST_SKILL_DIR/teams/first" ]
  [ ! -d "$TEST_SKILL_DIR/teams/second" ]
  [ "$(audit_count)" -eq 4 ]
}

@test "a valid nonexistent --team is a safe no-op and never falls back to sweep" {
  bash "$SCRIPTS/join.sh" survivor alice claude-code /tmp/project

  run bash "$SCRIPTS/reset.sh" --team absent /tmp/project claude-code alice
  [ "$status" -eq 0 ]
  [[ "$output" =~ "No registrations removed." ]]
  [ -f "$TEST_SKILL_DIR/teams/survivor/config.json" ]
  [ "$(audit_count)" -eq 1 ]
}

@test "a valid nonexistent --team without an agent is an exit-zero no-op" {
  bash "$SCRIPTS/join.sh" survivor alice claude-code /tmp/project

  run bash "$SCRIPTS/reset.sh" --team absent /tmp/project claude-code
  [ "$status" -eq 0 ]
  [[ "$output" =~ "No registrations removed." ]]
  [ -f "$TEST_SKILL_DIR/teams/survivor/config.json" ]
  [ "$(audit_count)" -eq 1 ]
}

@test "unrelated team project registrations cannot steer scoped resolution" {
  local root="$BATS_TEST_TMPDIR/project-root"
  mkdir -p "$root/subdir"
  bash "$SCRIPTS/join.sh" first alice claude-code "$root"
  bash "$SCRIPTS/join.sh" second bob claude-code "$root/subdir"

  run bash "$SCRIPTS/reset.sh" --team first "$root/subdir" claude-code
  [ "$status" -eq 0 ]
  [ ! -d "$TEST_SKILL_DIR/teams/first" ]
  [ -f "$TEST_SKILL_DIR/teams/second/config.json" ]
  [ "$(audit_count)" -eq 3 ]
  [ "$(audit_field 4)" = "first" ]
  [ "$(audit_field 6)" = "alice" ]
}

@test "invalid or incomplete --team values fail before any scope widening" {
  bash "$SCRIPTS/join.sh" survivor alice claude-code /tmp/project
  local sentinel="$TEST_SKILL_DIR/outside-sentinel"
  printf '%s\n' untouched > "$sentinel"
  local invalid name
  for invalid in "" ".." "bad/name" $'bad\\name' "-bad" $'bad\tname' $'bad\nname' $'bad\001name'; do
    run bash "$SCRIPTS/reset.sh" --team "$invalid" /tmp/project claude-code alice
    [ "$status" -ne 0 ]
  done
  run bash "$SCRIPTS/reset.sh" --team
  [ "$status" -ne 0 ]

  [ -f "$TEST_SKILL_DIR/teams/survivor/config.json" ]
  [ "$(cat "$sentinel")" = "untouched" ]
  [ "$(audit_count)" -eq 1 ]
}

@test "rewrite and deletion each produce one reset audit line" {
  bash "$SCRIPTS/join.sh" team alice claude-code /tmp/project-a
  bash "$SCRIPTS/join.sh" team bob claude-code /tmp/project-b
  bash "$SCRIPTS/reset.sh" --team team /tmp/project-a claude-code alice

  [ -f "$TEST_SKILL_DIR/teams/team/config.json" ]
  [ "$(audit_count)" -eq 3 ]
  [ "$(audit_field 5)" = "reset" ]
  [ "$(audit_field 6)" = "alice" ]

  bash "$SCRIPTS/reset.sh" --team team /tmp/project-b claude-code bob
  [ ! -d "$TEST_SKILL_DIR/teams/team" ]
  [ "$(audit_count)" -eq 4 ]
  run awk -F '\t' 'NF != 7 { exit 1 } $5 != "join" && $5 != "reset" { exit 1 }' "$(audit_log)"
  [ "$status" -eq 0 ]
}

@test "no-op and failed resets do not append audit lines" {
  bash "$SCRIPTS/join.sh" team alice claude-code /tmp/project
  run bash "$SCRIPTS/reset.sh" --team team /tmp/other-project claude-code alice
  [ "$status" -eq 0 ]
  [ "$(audit_count)" -eq 1 ]

  run bash "$SCRIPTS/reset.sh" --team team /tmp/project claude-code "bad.agent"
  [ "$status" -ne 0 ]
  [ "$(audit_count)" -eq 1 ]
}

@test "audit failure does not change reset success" {
  bash "$SCRIPTS/join.sh" team alice claude-code /tmp/project
  printf '%s\n' 'agmsg_team_config_audit() { return 42; }' > "$SCRIPTS/lib/team-config-audit.sh"

  run bash "$SCRIPTS/reset.sh" --team team /tmp/project claude-code alice
  [ "$status" -eq 0 ]
  [[ "$output" =~ "removed 1 registration" ]]
  [ ! -d "$TEST_SKILL_DIR/teams/team" ]
}

@test "Windows dispatch reset and drop retain all-team behavior" {
  bash "$SCRIPTS/join.sh" first alice codex /tmp/project
  bash "$SCRIPTS/join.sh" second alice codex /tmp/project

  run bash "$SCRIPTS/windows/dispatch.sh" --type codex --project /tmp/project --team first --agent alice -- reset
  [ "$status" -eq 0 ]
  [ ! -d "$TEST_SKILL_DIR/teams/first" ]
  [ ! -d "$TEST_SKILL_DIR/teams/second" ]

  bash "$SCRIPTS/join.sh" first alice codex /tmp/project
  bash "$SCRIPTS/join.sh" second alice codex /tmp/project
  run bash "$SCRIPTS/windows/dispatch.sh" --type codex --project /tmp/project --team first -- drop alice
  [ "$status" -eq 0 ]
  [ ! -d "$TEST_SKILL_DIR/teams/first" ]
  [ ! -d "$TEST_SKILL_DIR/teams/second" ]
}
