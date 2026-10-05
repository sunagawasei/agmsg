#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

load test_helper

setup() {
  setup_test_env
  RUN_DIR="$TEST_SKILL_DIR/run"
  mkdir -p "$RUN_DIR"
  OWNER_PID=""
}

teardown() {
  if [ -n "$OWNER_PID" ]; then
    kill -TERM "$OWNER_PID" 2>/dev/null || true
    wait "$OWNER_PID" 2>/dev/null || true
  fi
  teardown_test_env
}

write_config() {
  mkdir -p "$TEST_SKILL_DIR/teams/hteam"
  printf '%s\n' "$1" >"$TEST_SKILL_DIR/teams/hteam/config.json"
}

reg() { printf '{"type":"%s","project":"/p"}' "$1"; }

health() { run bash "$SCRIPTS/team.sh" hteam --health "$@"; }

# A leased bridge exactly as the production launcher publishes it.
start_bridge() {
  local kind="$1" name="$2" target="$TEST_SKILL_DIR/target.sh" ready="$TEST_SKILL_DIR/ready"
  printf '#!/usr/bin/env bash\n: >"$1"\nexec sleep 600\n' >"$target"
  chmod +x "$target"
  rm -f "$ready"
  AGMSG_TEST_PROCESS_PYTHON="$(command -v python3)" \
    bash "$SCRIPTS/internal/process-owner-launch.sh" \
    --kind "$kind" --pidfile "$RUN_DIR/$kind.hteam.$name.pid" --scope "$kind|hteam.$name" \
    -- "$target" "$ready" >/dev/null 2>&1 &
  OWNER_PID=$!
  wait_for_file "$ready"
}

# A degraded owner record (no lease) for a live process, written by hand: the
# launcher's degraded path is exercised in test_process_owner.bats.
write_degraded_owner() {
  local kind="$1" name="$2" pid="$3" scope_hash
  scope_hash="$(bash -c 'source "$1"; agmsg_process_scope_hash "$2"' _ "$SCRIPTS/lib/process-identity.sh" "$kind|hteam.$name")"
  printf '%s\n' "$pid" >"$RUN_DIR/$kind.hteam.$name.pid"
  printf 'version=1\npid=%s\nkind=%s\nscope=%s\ngeneration=g1\nlease=degraded\ninterpreter=\n' \
    "$pid" "$kind" "$scope_hash" >"$RUN_DIR/$kind.hteam.$name.owner"
}

@test "team health: a member that is not in the team exits 11" {
  write_config "{\"name\":\"hteam\",\"agents\":{\"a\":{\"registrations\":[$(reg codex)]}}}"
  health ghost codex
  [ "$status" -eq 11 ]
}

@test "team health: a member with an empty registrations array exits 11" {
  write_config '{"name":"hteam","agents":{"a":{"registrations":[]}}}'
  health a codex
  [ "$status" -eq 11 ]
}

@test "team health: a member registered under another type exits 10" {
  write_config "{\"name\":\"hteam\",\"agents\":{\"a\":{\"registrations\":[$(reg claude-code)]}}}"
  health a codex
  [ "$status" -eq 10 ]
}

@test "team health: two registrations of the expected type exit 14" {
  write_config "{\"name\":\"hteam\",\"agents\":{\"a\":{\"registrations\":[$(reg codex),$(reg codex)]}}}"
  health a codex
  [ "$status" -eq 14 ]
}

@test "team health: the expected type plus another type exits 14" {
  write_config "{\"name\":\"hteam\",\"agents\":{\"a\":{\"registrations\":[$(reg codex),$(reg cursor)]}}}"
  health a codex
  [ "$status" -eq 14 ]
}

@test "team health: a legacy single type/project entry counts as one registration" {
  write_config '{"name":"hteam","agents":{"a":{"type":"codex","project":"/p"}}}'
  health a codex
  [ "$status" -eq 12 ]
}

@test "team health: an unknown expected type exits 2" {
  write_config "{\"name\":\"hteam\",\"agents\":{\"a\":{\"registrations\":[$(reg codex)]}}}"
  health a nosuchtype
  [ "$status" -eq 2 ]
}

@test "team health: wrong argument count exits 2" {
  write_config "{\"name\":\"hteam\",\"agents\":{}}"
  health a
  [ "$status" -eq 2 ]
}

@test "team health: a missing team exits 1" {
  run bash "$SCRIPTS/team.sh" noteam --health a codex
  [ "$status" -eq 1 ]
}

@test "team health: --help names the headless owner types and every exit code" {
  run bash "$SCRIPTS/team.sh" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude-code, codex, cursor"* ]]
  for c in 10 11 12 13 14 15; do [[ "$output" == *"  $c  "* ]]; done
}

@test "team health: a registered member with no pidfile exits 12" {
  write_config "{\"name\":\"hteam\",\"agents\":{\"a\":{\"registrations\":[$(reg cursor)]}}}"
  health a cursor
  [ "$status" -eq 12 ]
}

@test "team health: an owner record whose lease is free exits 12" {
  write_config "{\"name\":\"hteam\",\"agents\":{\"a\":{\"registrations\":[$(reg codex)]}}}"
  sleep 0 & local gone=$!
  wait "$gone"
  printf '%s\n' "$gone" >"$RUN_DIR/codex-bridge.hteam.a.pid"
  printf 'version=1\npid=%s\nkind=codex-bridge\nscope=x\ngeneration=g1\nlease=leased\n' \
    "$gone" >"$RUN_DIR/codex-bridge.hteam.a.owner"
  health a codex
  [ "$status" -eq 12 ]
}

@test "team health: a legacy pidfile with a live pid and no owner record exits 13" {
  write_config "{\"name\":\"hteam\",\"agents\":{\"a\":{\"registrations\":[$(reg codex)]}}}"
  printf '%s\n' "$$" >"$RUN_DIR/codex-bridge.hteam.a.pid"
  health a codex
  [ "$status" -eq 13 ]
}

@test "team health: a degraded owner exits 13 for each headless type" {
  local t
  for t in claude-code codex cursor; do
    write_config "{\"name\":\"hteam\",\"agents\":{\"a\":{\"registrations\":[$(reg "$t")]}}}"
    write_degraded_owner "$t-bridge" a "$$"
    health a "$t"
    [ "$status" -eq 13 ]
  done
}

@test "team health: a degraded owner whose pid is dead exits 12" {
  write_config "{\"name\":\"hteam\",\"agents\":{\"a\":{\"registrations\":[$(reg codex)]}}}"
  sleep 0 & local gone=$!
  wait "$gone"
  write_degraded_owner codex-bridge a "$gone"
  health a codex
  [ "$status" -eq 12 ]
}

@test "team health: a leased owner started by the production launcher exits 0 for each headless type" {
  local t
  for t in claude-code codex cursor; do
    write_config "{\"name\":\"hteam\",\"agents\":{\"a\":{\"registrations\":[$(reg "$t")]}}}"
    start_bridge "$t-bridge" a
    health a "$t"
    [ "$status" -eq 0 ]
    kill -TERM "$OWNER_PID" 2>/dev/null || true
    wait "$OWNER_PID" 2>/dev/null || true
    OWNER_PID=""
    rm -f "$RUN_DIR"/"$t"-bridge.hteam.a.*
  done
}

@test "team health: a leased owner registered under another bridge's name exits 12 not 0" {
  write_config "{\"name\":\"hteam\",\"agents\":{\"a\":{\"registrations\":[$(reg codex)]}}}"
  start_bridge cursor-bridge a
  health a codex
  [ "$status" -eq 12 ]
}

@test "team listing: output and exit are unchanged by --health support" {
  write_config "{\"name\":\"hteam\",\"agents\":{\"a\":{\"registrations\":[$(reg codex)]}}}"
  run bash "$SCRIPTS/team.sh" hteam
  [ "$status" -eq 0 ]
  [[ "$output" == *"Team: hteam"* ]]
  [[ "$output" == *"  a (codex) — /p"* ]]
  [[ "$output" == *"1 member(s)"* ]]
}

@test "team health: a live lease whose owner record carries another scope exits 13" {
  write_config "{\"name\":\"hteam\",\"agents\":{\"a\":{\"registrations\":[$(reg codex)]}}}"
  start_bridge codex-bridge other
  local f
  for f in pid owner; do
    mv "$RUN_DIR/codex-bridge.hteam.other.$f" "$RUN_DIR/codex-bridge.hteam.a.$f"
  done
  for f in "$RUN_DIR"/codex-bridge.hteam.other.lease.*; do
    mv "$f" "$RUN_DIR/codex-bridge.hteam.a.lease.${f##*.lease.}"
  done
  health a codex
  [ "$status" -eq 13 ]
}

@test "team health: a leased bridge is not reported healthy when the lease probe is unavailable" {
  write_config "{\"name\":\"hteam\",\"agents\":{\"a\":{\"registrations\":[$(reg codex)]}}}"
  start_bridge codex-bridge a
  AGMSG_TEST_PROCESS_LOCKF=/nonexistent/lockf health a codex
  [ "$status" -eq 13 ]
}

@test "team health: a type whose manifest is not headless exits 15" {
  write_config "{\"name\":\"hteam\",\"agents\":{\"a\":{\"registrations\":[$(reg codex)]}}}"
  sed -i.bak 's/^headless=yes/headless=no/' "$TEST_SKILL_DIR/scripts/drivers/types/codex/type.conf"
  health a codex
  [ "$status" -eq 15 ]
}

@test "team health: a name with a newline exits 2 and prints no health line" {
  write_config "{\"name\":\"hteam\",\"agents\":{}}"
  health $'a\nb' codex
  [ "$status" -eq 2 ]
  [[ "$output" != *"health: hteam/"* ]]
}
