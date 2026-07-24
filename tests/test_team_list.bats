#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
}

teardown() {
  teardown_test_env
}

json_field() {
  local escaped; escaped="$(printf %s "$1" | sed "s/'/''/g")"
  sqlite_mem "SELECT json_extract('$escaped', '\$.$2');"
}

@test "team list: reports nothing when there are no teams" {
  run bash "$SCRIPTS/team-list.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"No teams found"* ]]
  run bash "$SCRIPTS/team-list.sh" --json
  [ "$status" -eq 0 ]
  [ "$(json_field "$output" schema_version)" = "1" ]
  [ "$(json_field "$output" teams)" = "[]" ]
}

@test "team list --json: reports every locally known team, canonically sorted by name" {
  bash "$SCRIPTS/join.sh" zteam alice claude-code /tmp/project-a
  bash "$SCRIPTS/join.sh" ateam bob claude-code /tmp/project-b
  run bash "$SCRIPTS/team-list.sh" --json
  [ "$status" -eq 0 ]
  local teams; teams="$(json_field "$output" teams)"
  [ "$(sqlite_mem "SELECT json_extract('$(printf %s "$teams" | sed "s/'/''/g")', '\$[0].name');")" = "ateam" ]
  [ "$(sqlite_mem "SELECT json_extract('$(printf %s "$teams" | sed "s/'/''/g")', '\$[1].name');")" = "zteam" ]
}

@test "team list --json: an unconnected team has binding_state=none, team_id=null" {
  bash "$SCRIPTS/join.sh" myteam alice claude-code /tmp/project-a
  run bash "$SCRIPTS/team-list.sh" --json
  [ "$status" -eq 0 ]
  local team; team="$(sqlite_mem "SELECT json_extract('$(printf %s "$(json_field "$output" teams)" | sed "s/'/''/g")', '\$[0]');")"
  local escaped; escaped="$(printf %s "$team" | sed "s/'/''/g")"
  [ "$(sqlite_mem "SELECT json_extract('$escaped', '\$.binding_state');")" = "none" ]
  [ "$(sqlite_mem "SELECT json_extract('$escaped', '\$.team_id');")" = "" ]
  [ "$(sqlite_mem "SELECT json_extract('$escaped', '\$.onboarding_state');")" = "not_connected" ]
  [ "$(sqlite_mem "SELECT json_extract('$escaped', '\$.promote_eligible');")" = "0" ]
  [ "$(sqlite_mem "SELECT json_extract('$escaped', '\$.blocked_reason');")" = "adr_0010_not_implemented" ]
}

@test "team list --json: an actively connected team has binding_state=active and a real team_id" {
  bash "$SCRIPTS/join.sh" myteam alice claude-code /tmp/project-a

  MOCK_REVOKE_FAIL="${MOCK_REVOKE_FAIL:-}" python3 "$BATS_TEST_DIRNAME/helpers/mock_remote_server.py" 0 \
    > "$TEST_SKILL_DIR/server.port" 2>"$TEST_SKILL_DIR/server.log" &
  local mock_pid=$!
  for _ in $(seq 1 50); do
    [ -s "$TEST_SKILL_DIR/server.port" ] && break
    sleep 0.05
  done
  local mock_port; mock_port="$(cat "$TEST_SKILL_DIR/server.port")"
  local endpoint="http://127.0.0.1:$mock_port"
  bash "$SCRIPTS/remote.sh" connect --endpoint "$endpoint" good-token myteam
  local committed_team_id
  committed_team_id=$(python3 -c "import json; print(json.load(open('$SCRIPTS/../teams/myteam/config.json'))['remote_binding']['remote_team_id'])")

  run bash "$SCRIPTS/team-list.sh" --json
  kill "$mock_pid" 2>/dev/null || true
  [ "$status" -eq 0 ]
  local escaped; escaped="$(printf %s "$(sqlite_mem "SELECT json_extract('$(printf %s "$(json_field "$output" teams)" | sed "s/'/''/g")', '\$[0]');")" | sed "s/'/''/g")"
  [ "$(sqlite_mem "SELECT json_extract('$escaped', '\$.binding_state');")" = "active" ]
  [ "$(sqlite_mem "SELECT json_extract('$escaped', '\$.team_id');")" = "$committed_team_id" ]
  [ "$(sqlite_mem "SELECT json_extract('$escaped', '\$.onboarding_state');")" = "connected" ]
  # No secret and no absolute filesystem path anywhere in the output.
  [[ "$output" != *"session-credential"* ]]
  [[ "$output" != *"/tmp/project-a"* ]]
}

@test "team list --json: a disconnected team has binding_state=disconnected, team_id retained" {
  bash "$SCRIPTS/join.sh" myteam alice claude-code /tmp/project-a
  python3 "$BATS_TEST_DIRNAME/helpers/mock_remote_server.py" 0 \
    > "$TEST_SKILL_DIR/server.port" 2>"$TEST_SKILL_DIR/server.log" &
  local mock_pid=$!
  for _ in $(seq 1 50); do
    [ -s "$TEST_SKILL_DIR/server.port" ] && break
    sleep 0.05
  done
  local mock_port; mock_port="$(cat "$TEST_SKILL_DIR/server.port")"
  local endpoint="http://127.0.0.1:$mock_port"
  bash "$SCRIPTS/remote.sh" connect --endpoint "$endpoint" good-token myteam
  bash "$SCRIPTS/remote.sh" disconnect myteam
  kill "$mock_pid" 2>/dev/null || true

  run bash "$SCRIPTS/team-list.sh" --json
  [ "$status" -eq 0 ]
  local escaped; escaped="$(printf %s "$(sqlite_mem "SELECT json_extract('$(printf %s "$(json_field "$output" teams)" | sed "s/'/''/g")', '\$[0]');")" | sed "s/'/''/g")"
  [ "$(sqlite_mem "SELECT json_extract('$escaped', '\$.binding_state');")" = "disconnected" ]
  [ "$(sqlite_mem "SELECT json_extract('$escaped', '\$.team_id');")" != "" ]
}

@test "team list --scope project: only includes teams registered for the given project" {
  bash "$SCRIPTS/join.sh" projteam alice claude-code /tmp/project-a
  bash "$SCRIPTS/join.sh" otherteam bob claude-code /tmp/project-b
  run bash "$SCRIPTS/team-list.sh" --json --scope project /tmp/project-a
  [ "$status" -eq 0 ]
  local teams; teams="$(json_field "$output" teams)"
  [ "$(sqlite_mem "SELECT json_array_length('$(printf %s "$teams" | sed "s/'/''/g")');")" -eq 1 ]
  [ "$(sqlite_mem "SELECT json_extract('$(printf %s "$teams" | sed "s/'/''/g")', '\$[0].name');")" = "projteam" ]
  [ "$(sqlite_mem "SELECT json_extract('$(printf %s "$teams" | sed "s/'/''/g")', '\$[0].scope');")" = "project" ]
}

@test "team list --scope all: includes every team, with per-team scope classifying project vs other" {
  bash "$SCRIPTS/join.sh" projteam alice claude-code /tmp/project-a
  bash "$SCRIPTS/join.sh" otherteam bob claude-code /tmp/project-b
  run bash "$SCRIPTS/team-list.sh" --json --scope all /tmp/project-a
  [ "$status" -eq 0 ]
  local teams; teams="$(json_field "$output" teams)"
  [ "$(sqlite_mem "SELECT json_array_length('$(printf %s "$teams" | sed "s/'/''/g")');")" -eq 2 ]
  local proj_line other_line
  proj_line="$(sqlite_mem "SELECT json_extract('$(printf %s "$teams" | sed "s/'/''/g")', '\$[0]');" )"
  other_line="$(sqlite_mem "SELECT json_extract('$(printf %s "$teams" | sed "s/'/''/g")', '\$[1]');" )"
  # ateam-style alphabetical sort: otherteam < projteam
  [ "$(sqlite_mem "SELECT json_extract('$(printf %s "$proj_line" | sed "s/'/''/g")', '\$.name');")" = "otherteam" ]
  [ "$(sqlite_mem "SELECT json_extract('$(printf %s "$proj_line" | sed "s/'/''/g")', '\$.scope');")" = "other" ]
  [ "$(sqlite_mem "SELECT json_extract('$(printf %s "$other_line" | sed "s/'/''/g")', '\$.name');")" = "projteam" ]
  [ "$(sqlite_mem "SELECT json_extract('$(printf %s "$other_line" | sed "s/'/''/g")', '\$.scope');")" = "project" ]
}

@test "team list: rejects an invalid --scope value" {
  run bash "$SCRIPTS/team-list.sh" --scope bogus
  [ "$status" -ne 0 ]
  [[ "$output" == *"--scope must be"* ]]
}

@test "team list --json: a team name containing a single quote round-trips correctly" {
  local team="o'brien-team"
  bash "$SCRIPTS/join.sh" "$team" carol claude-code /tmp/project-c
  run bash "$SCRIPTS/team-list.sh" --json
  [ "$status" -eq 0 ]
  local teams; teams="$(json_field "$output" teams)"
  [ "$(sqlite_mem "SELECT json_extract('$(printf %s "$teams" | sed "s/'/''/g")', '\$[0].name');")" = "$team" ]
}

@test "team list: skips a team whose config.json contains a duplicate JSON key, with a stderr warning" {
  mkdir -p "$SCRIPTS/../teams/badteam"
  printf '{"name":"badteam","agents":{},"agents":{}}' > "$SCRIPTS/../teams/badteam/config.json"
  bash "$SCRIPTS/join.sh" goodteam alice claude-code /tmp/project-a

  # bats' `run` merges stdout+stderr into $output, which would corrupt JSON
  # parsing here (the script emits the warning on stderr, the payload on
  # stdout) — check each stream in its own `run`, not the combined one.
  run bash -c "bash '$SCRIPTS/team-list.sh' --json 2>/dev/null"
  [ "$status" -eq 0 ]
  local teams; teams="$(json_field "$output" teams)"
  [ "$(sqlite_mem "SELECT json_array_length('$(printf %s "$teams" | sed "s/'/''/g")');")" -eq 1 ]
  [ "$(sqlite_mem "SELECT json_extract('$(printf %s "$teams" | sed "s/'/''/g")', '\$[0].name');")" = "goodteam" ]

  run bash -c "bash '$SCRIPTS/team-list.sh' --json 2>&1 >/dev/null"
  [[ "$output" == *"skipping 'badteam'"* ]]
}

@test "team list: skips a team whose config.json is not valid JSON, with a stderr warning" {
  mkdir -p "$SCRIPTS/../teams/badteam"
  printf 'not even json' > "$SCRIPTS/../teams/badteam/config.json"

  run bash -c "bash '$SCRIPTS/team-list.sh' --json 2>/dev/null"
  [ "$status" -eq 0 ]
  [ "$(json_field "$output" teams)" = "[]" ]

  run bash -c "bash '$SCRIPTS/team-list.sh' --json 2>&1 >/dev/null"
  [[ "$output" == *"skipping 'badteam'"* ]]
}

@test "team list: human-readable output includes name and binding state" {
  bash "$SCRIPTS/join.sh" myteam alice claude-code /tmp/project-a
  run bash "$SCRIPTS/team-list.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"myteam"* ]]
  [[ "$output" == *"none"* ]]
}
