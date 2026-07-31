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

@test "join audits one line for a new team and its seven fields" {
  bash "$SCRIPTS/join.sh" team alice claude-code /tmp/project

  [ "$(audit_count)" -eq 1 ]
  run awk -F '\t' 'NF != 7 { exit 1 } $3 != "join.sh" || $4 != "team" || $5 != "join" || $6 != "alice" || $7 != "/tmp/project" { exit 1 }' "$(audit_log)"
  [ "$status" -eq 0 ]
  run awk -F '\t' 'length($1) != 20 || substr($1, 5, 1) != "-" || substr($1, 8, 1) != "-" || substr($1, 11, 1) != "T" || substr($1, 14, 1) != ":" || substr($1, 17, 1) != ":" || substr($1, 20, 1) != "Z" || $2 !~ /^[0-9][0-9]*$/ { exit 1 }' "$(audit_log)"
  [ "$status" -eq 0 ]
}

@test "join audits an added registration but not an identical re-join" {
  bash "$SCRIPTS/join.sh" team alice claude-code /tmp/project-a
  bash "$SCRIPTS/join.sh" team alice codex /tmp/project-b
  [ "$(audit_count)" -eq 2 ]

  bash "$SCRIPTS/join.sh" team alice codex /tmp/project-b
  [ "$(audit_count)" -eq 2 ]
}

@test "leave audits both rewrite and last-member deletion exactly once" {
  bash "$SCRIPTS/join.sh" team alice claude-code /tmp/project-a
  bash "$SCRIPTS/join.sh" team bob codex /tmp/project-b
  bash "$SCRIPTS/leave.sh" team alice
  [ "$(audit_count)" -eq 3 ]
  [ "$(audit_field 4)" = "team" ]
  [ "$(audit_field 5)" = "leave" ]
  [ "$(audit_field 6)" = "alice" ]
  [ "$(audit_field 7)" = "" ]

  bash "$SCRIPTS/leave.sh" team bob
  [ "$(audit_count)" -eq 4 ]
  [ ! -d "$TEST_SKILL_DIR/teams/team" ]
}

@test "agent rename audits old and new names after the multi-write mutation" {
  bash "$SCRIPTS/join.sh" team old claude-code /tmp/project
  bash "$SCRIPTS/rename.sh" team old new

  [ "$(audit_count)" -eq 2 ]
  [ "$(audit_field 4)" = "team" ]
  [ "$(audit_field 5)" = "rename-agent" ]
  [ "$(audit_field 6)" = "old" ]
  [ "$(audit_field 7)" = "new" ]
}

@test "team rename audits source and destination semantics after all writes" {
  bash "$SCRIPTS/join.sh" old-team alice claude-code /tmp/project
  bash "$SCRIPTS/rename-team.sh" old-team new-team

  [ "$(audit_count)" -eq 2 ]
  [ "$(audit_field 4)" = "old-team" ]
  [ "$(audit_field 5)" = "rename-team" ]
  [ "$(audit_field 6)" = "" ]
  [ "$(audit_field 7)" = "new-team" ]
  [ -f "$TEST_SKILL_DIR/teams/new-team/config.json" ]
}

@test "failed and no-op mutations do not append audit lines" {
  run bash "$SCRIPTS/leave.sh" missing alice
  [ "$status" -ne 0 ]
  run bash "$SCRIPTS/rename.sh" missing old new
  [ "$status" -ne 0 ]
  run bash "$SCRIPTS/rename-team.sh" missing new-team
  [ "$status" -ne 0 ]
  [ "$(audit_count)" -eq 0 ]

  bash "$SCRIPTS/join.sh" team alice claude-code /tmp/project
  [ "$(audit_count)" -eq 1 ]
  run bash "$SCRIPTS/leave.sh" team absent
  [ "$status" -ne 0 ]
  [ "$(audit_count)" -eq 1 ]
}

@test "audit failures never change successful mutation status" {
  printf '%s\n' 'agmsg_team_config_audit() { return 42; }' > "$SCRIPTS/lib/team-config-audit.sh"

  bash "$SCRIPTS/join.sh" team old claude-code /tmp/project
  bash "$SCRIPTS/join.sh" team other codex /tmp/project-b
  bash "$SCRIPTS/leave.sh" team other
  bash "$SCRIPTS/rename.sh" team old new
  bash "$SCRIPTS/rename-team.sh" team renamed

  [ -f "$TEST_SKILL_DIR/teams/renamed/config.json" ]
  [ ! -f "$(audit_log)" ]
}
