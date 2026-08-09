#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
  bash "$SCRIPTS/join.sh" testteam alice claude-code /tmp/project-a

  local cfg="$TEST_SKILL_DIR/teams/testteam/config.json" escaped updated
  escaped="$(sed "s/'/''/g" "$cfg")"
  updated="$(sqlite_mem "
    SELECT json_set('$escaped', '\$.remote_binding', json_object(
      'endpoint', 'https://remote.example',
      'server_instance_id', '018f0000-0000-7000-8000-000000000001',
      'remote_team_id', '018f0000-0000-7000-8000-000000000002',
      'protocol_version', 1,
      'capabilities', json_object('write_allowed_ciphers', json_array('none')),
      'connected_at', '2026-07-30T00:00:00Z',
      'disconnected_at', null
    ));")"
  printf '%s\n' "$updated" > "$cfg"
  mkdir -p "$TEST_SKILL_DIR/run"
  ENGINE_PIDS=""
}

teardown() {
  local pid
  for pid in $ENGINE_PIDS; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  teardown_test_env
}

start_matching_engine() {
  local engine="$SCRIPTS/internal/remote-sync.mjs"
  printf '%s\n' '#!/usr/bin/env bash' \
    'trap "exit 0" TERM INT' \
    'while :; do sleep 1; done' > "$engine"
  chmod +x "$engine"
  bash "$engine" run --team testteam &
  ENGINE_PID=$!
  ENGINE_PIDS="${ENGINE_PIDS:+$ENGINE_PIDS }$ENGINE_PID"
  printf '%s\n' "$ENGINE_PID" > "$TEST_SKILL_DIR/run/remote-sync.testteam.pid"
}

# Fakes ONE question: what is this pid's argv. Everything else goes to the real
# ps.
#
# The `-o args=` guard is load-bearing. Without it the fixture answers every
# `ps -p <ENGINE_PID>` with the argv string, and liveness now asks a different
# question through the same command -- `_agmsg_pid_alive` consults
# `ps -o stat= -p` when kill(1) reports ESRCH, and reads any non-empty,
# non-zombie state as alive. A killed engine then reads as running, `sync start`
# no-ops, and the test that asserts a NEW pid fails on an assertion that names
# neither ps nor the fixture.
#
# So the fixture has to be as narrow as the thing it stands in for: a fake that
# answers questions it was never asked will answer one that matters.
write_matching_ps_fixture() {
  local fake_bin="$TEST_SKILL_DIR/fake-bin"
  mkdir -p "$fake_bin"
  printf '%s\n' '#!/usr/bin/env bash' \
    "if [[ \" \$* \" == *\" -p $ENGINE_PID \"* && \" \$* \" == *\" -o args= \"* ]]; then" \
    "  printf '%s\\n' 'bash $SCRIPTS/internal/remote-sync.mjs run --team testteam'" \
    '  exit 0' \
    'fi' \
    'exec /bin/ps "$@"' > "$fake_bin/ps"
  chmod +x "$fake_bin/ps"
  printf '%s\n' "$fake_bin"
}

write_fake_node() {
  local trailing_records="${1:-0}" fake_node="$TEST_SKILL_DIR/fake-node"
  printf '%s\n' '#!/usr/bin/env bash' \
    'if [ "${1:-}" = "--version" ]; then' \
    '  echo v23.0.0' \
    '  exit 0' \
    'fi' \
    'echo "{\"event\":\"capabilities\",\"startup_nonce\":\"${AGMSG_SYNC_START_NONCE:-}\"}"' \
    "trailing_records=$trailing_records" \
    'awk -v count="$trailing_records" '\''BEGIN {' \
    '  padding = sprintf("%16384s", "")' \
    '  gsub(/ /, "x", padding)' \
    '  for (i = 0; i < count; i++) {' \
    '    print "{\"event\":\"capabilities\",\"startup_nonce\":\"other-generation\",\"padding\":\"" padding "\"}"' \
    '  }' \
    '}'\''' \
    '[ -z "${AGMSG_TEST_LOG_READY_FILE:-}" ] || : > "$AGMSG_TEST_LOG_READY_FILE"' \
    '[ -z "${AGMSG_TEST_CHILD_PID_FILE:-}" ] || printf '\''%s\\n'\'' "$$" > "$AGMSG_TEST_CHILD_PID_FILE"' \
    'trap "exit 0" TERM INT' \
    'while :; do sleep 1; done' > "$fake_node"
  chmod +x "$fake_node"
  printf '%s\n' "$fake_node"
}

write_fake_node_ps_fixture() {
  local fake_node="$1" foreign_pid="${2:-}" ready_file="${3:-}" \
    fake_bin="$TEST_SKILL_DIR/fake-node-bin"
  mkdir -p "$fake_bin"
  # Answers the argv question only. Anything else -- notably `-o stat=`, which
  # `_agmsg_pid_alive` consults when kill(1) reports ESRCH -- goes to the real
  # ps.
  #
  # Without that guard this fixture replies to EVERY ps call, for every pid,
  # with an argv string and exit 0. Liveness then reads that string as a process
  # state: non-empty and not starting with `Z`, so a killed engine reads as
  # alive, `sync start` reports "already running", and the assertion that fails
  # is the one about the new pid -- naming neither ps nor this fixture.
  printf '%s\n' '#!/usr/bin/env bash' \
    'pid=""; args=0' \
    'for a in "$@"; do' \
    '  case "$a" in -o) ;; args=) args=1 ;; esac' \
    'done' \
    'case " $* " in *" -o args= "*) args=1 ;; esac' \
    '[ "$args" = 1 ] || exec /bin/ps "$@"' \
    'set -- "$@"' \
    'while [ $# -gt 0 ]; do' \
    '  if [ "$1" = "-p" ]; then pid="$2"; shift 2; else shift; fi' \
    'done' \
    "if { [ -n '$ready_file' ] && [ ! -f '$ready_file' ]; } || [ \"\$pid\" = '$foreign_pid' ]; then" \
    "  printf '%s\\n' 'sleep 30'" \
    'else' \
    "  printf '%s\\n' 'bash $SCRIPTS/internal/remote-sync.mjs run --team testteam'" \
    'fi' > "$fake_bin/ps"
  chmod +x "$fake_bin/ps"
  printf '%s\n' "$fake_bin"
}

remember_engine_pid() {
  ENGINE_PID="$(cat "$TEST_SKILL_DIR/run/remote-sync.testteam.pid")"
  ENGINE_PIDS="${ENGINE_PIDS:+$ENGINE_PIDS }$ENGINE_PID"
}

@test "status: reports an active binding whose engine is stopped" {
  run bash "$SCRIPTS/remote.sh" status testteam
  [ "$status" -eq 0 ]
  [[ "$output" == *"connected (engine stopped"* ]]
  # The command carries its install path and quotes its team now (#667), so the
  # bare spelling is gone. `grep -q`, not `[[ ]]`: a failing `[[ ]]` mid-body is
  # not enforced on bash 3.2 (#670), and this assertion is one that just moved.
  printf '%s\n' "$output" | grep -q -F -- "remote.sh' sync start 'testteam'"

  run bash "$SCRIPTS/remote.sh" status testteam --json
  [ "$status" -eq 0 ]
  [ "$(sqlite_mem "SELECT json_extract('$(printf '%s' "$output" | sed "s/'/''/g")', '\$.engine_state');")" = stopped ]
  [ "$(sqlite_mem "SELECT json_type('$(printf '%s' "$output" | sed "s/'/''/g")', '\$.engine_pid');")" = null ]
}

@test "status: reports a live engine only when argv matches this team" {
  start_matching_engine
  local fake_bin
  fake_bin="$(write_matching_ps_fixture)"

  run env PATH="$fake_bin:$PATH" bash "$SCRIPTS/remote.sh" status testteam
  [ "$status" -eq 0 ]
  [[ "$output" == *"connected (engine running, pid $ENGINE_PID)"* ]]

  run env PATH="$fake_bin:$PATH" bash "$SCRIPTS/remote.sh" status testteam --json
  [ "$status" -eq 0 ]
  [ "$(sqlite_mem "SELECT json_extract('$(printf '%s' "$output" | sed "s/'/''/g")', '\$.engine_state');")" = running ]
  [ "$(sqlite_mem "SELECT json_extract('$(printf '%s' "$output" | sed "s/'/''/g")', '\$.engine_pid');")" -eq "$ENGINE_PID" ]
}

@test "status: rejects a live foreign process behind a recycled pidfile" {
  sleep 30 &
  local foreign_pid=$!
  ENGINE_PIDS="${ENGINE_PIDS:+$ENGINE_PIDS }$foreign_pid"
  printf '%s\n' "$foreign_pid" > "$TEST_SKILL_DIR/run/remote-sync.testteam.pid"

  run bash "$SCRIPTS/remote.sh" status testteam
  [ "$status" -eq 0 ]
  [[ "$output" == *"connected (engine stale"* ]]
  [[ "$output" == *"pidfile $foreign_pid points at a dead or foreign process"* ]]

  run bash "$SCRIPTS/remote.sh" status testteam --json
  [ "$status" -eq 0 ]
  [ "$(sqlite_mem "SELECT json_extract('$(printf '%s' "$output" | sed "s/'/''/g")', '\$.engine_state');")" = stale ]
  [ "$(sqlite_mem "SELECT json_extract('$(printf '%s' "$output" | sed "s/'/''/g")', '\$.engine_pid');")" -eq "$foreign_pid" ]
}

@test "status: reports a dead pidfile as stale without changing exit status" {
  printf '%s\n' 2147483647 > "$TEST_SKILL_DIR/run/remote-sync.testteam.pid"

  run bash "$SCRIPTS/remote.sh" status testteam
  [ "$status" -eq 0 ]
  [[ "$output" == *"connected (engine stale"* ]]
  [[ "$output" == *"pidfile 2147483647 points at a dead or foreign process"* ]]
}

@test "status: rejects a malformed pidfile without interpreting it as a process" {
  printf '%s\n' 0123 > "$TEST_SKILL_DIR/run/remote-sync.testteam.pid"

  run bash "$SCRIPTS/remote.sh" status testteam --json
  [ "$status" -eq 0 ]
  [ "$(sqlite_mem "SELECT json_extract('$(printf '%s' "$output" | sed "s/'/''/g")', '\$.engine_state');")" = stale ]
  [ "$(sqlite_mem "SELECT json_type('$(printf '%s' "$output" | sed "s/'/''/g")', '\$.engine_pid');")" = null ]
}

@test "sync start: starts a stopped engine and status reports it running" {
  local fake_node fake_bin first_pid
  fake_node="$(write_fake_node)"
  fake_bin="$(write_fake_node_ps_fixture "$fake_node")"

  run env PATH="$fake_bin:$PATH" AGMSG_NODE="$fake_node" bash "$SCRIPTS/remote.sh" sync start testteam
  [ "$status" -eq 0 ]
  [[ "$output" == *"Sync engine started for 'testteam' (pid "* ]]
  remember_engine_pid
  kill -0 "$ENGINE_PID"

  run env PATH="$fake_bin:$PATH" bash "$SCRIPTS/remote.sh" status testteam
  [ "$status" -eq 0 ]
  [[ "$output" == *"connected (engine running, pid $ENGINE_PID)"* ]]

  first_pid="$ENGINE_PID"
  kill "$first_pid"
  wait_for_pid_exit "$first_pid"
  run bash "$SCRIPTS/remote.sh" status testteam
  [ "$status" -eq 0 ]
  [[ "$output" == *"connected (engine stale"* ]]

  run env PATH="$fake_bin:$PATH" AGMSG_NODE="$fake_node" bash "$SCRIPTS/remote.sh" sync start testteam
  [ "$status" -eq 0 ]
  remember_engine_pid
  [ "$ENGINE_PID" -ne "$first_pid" ]
  run env PATH="$fake_bin:$PATH" bash "$SCRIPTS/remote.sh" status testteam
  [ "$status" -eq 0 ]
  [[ "$output" == *"connected (engine running, pid $ENGINE_PID)"* ]]
}

@test "sync start: is a no-op when the verified engine is already running" {
  local fake_node fake_bin original_pid
  fake_node="$(write_fake_node)"
  fake_bin="$(write_fake_node_ps_fixture "$fake_node")"
  env PATH="$fake_bin:$PATH" AGMSG_NODE="$fake_node" bash "$SCRIPTS/remote.sh" sync start testteam
  remember_engine_pid
  original_pid="$ENGINE_PID"

  run env PATH="$fake_bin:$PATH" AGMSG_NODE="$fake_node" \
    bash "$SCRIPTS/remote.sh" sync start testteam
  [ "$status" -eq 0 ]
  [ "$output" = "Sync engine already running (pid $original_pid)." ]
  [ "$(cat "$TEST_SKILL_DIR/run/remote-sync.testteam.pid")" = "$original_pid" ]
  kill -0 "$original_pid"
}

@test "sync start: replaces stale ownership without signalling a foreign process" {
  local fake_node fake_bin foreign_pid
  fake_node="$(write_fake_node)"
  sleep 30 &
  foreign_pid=$!
  fake_bin="$(write_fake_node_ps_fixture "$fake_node" "$foreign_pid")"
  ENGINE_PIDS="${ENGINE_PIDS:+$ENGINE_PIDS }$foreign_pid"
  printf '%s\n' "$foreign_pid" > "$TEST_SKILL_DIR/run/remote-sync.testteam.pid"

  run env PATH="$fake_bin:$PATH" AGMSG_NODE="$fake_node" bash "$SCRIPTS/remote.sh" sync start testteam
  [ "$status" -eq 0 ]
  kill -0 "$foreign_pid"
  remember_engine_pid
  [ "$ENGINE_PID" -ne "$foreign_pid" ]

  run env PATH="$fake_bin:$PATH" bash "$SCRIPTS/remote.sh" status testteam
  [ "$status" -eq 0 ]
  [[ "$output" == *"connected (engine running, pid $ENGINE_PID)"* ]]
}

@test "disconnect removes stale ownership without signalling a foreign process" {
  sleep 30 &
  local foreign_pid=$!
  ENGINE_PIDS="${ENGINE_PIDS:+$ENGINE_PIDS }$foreign_pid"
  printf '%s\n' "$foreign_pid" > "$TEST_SKILL_DIR/run/remote-sync.testteam.pid"

  run bash "$SCRIPTS/remote.sh" disconnect testteam
  [ "$status" -eq 0 ]
  kill -0 "$foreign_pid"
  [ ! -e "$TEST_SKILL_DIR/run/remote-sync.testteam.pid" ]
}

@test "concurrent sync start serializes ownership to one engine" {
  local fake_node fake_bin first_out second_out first_status=0 second_status=0
  fake_node="$(write_fake_node)"
  fake_bin="$(write_fake_node_ps_fixture "$fake_node")"
  first_out="$(mktemp)"
  second_out="$(mktemp)"

  env PATH="$fake_bin:$PATH" AGMSG_NODE="$fake_node" bash "$SCRIPTS/remote.sh" sync start testteam >"$first_out" 2>&1 &
  local first_start=$!
  env PATH="$fake_bin:$PATH" AGMSG_NODE="$fake_node" bash "$SCRIPTS/remote.sh" sync start testteam >"$second_out" 2>&1 &
  local second_start=$!
  wait "$first_start" || first_status=$?
  wait "$second_start" || second_status=$?
  [ "$first_status" -eq 0 ]
  [ "$second_status" -eq 0 ]
  [ "$(grep -h -c 'Sync engine started' "$first_out" "$second_out" | awk '{s += $1} END {print s}')" -eq 1 ]
  [ "$(grep -h -c 'Sync engine already running' "$first_out" "$second_out" | awk '{s += $1} END {print s}')" -eq 1 ]

  remember_engine_pid
  kill -0 "$ENGINE_PID"
  rm -f "$first_out" "$second_out"
}

@test "sync start reads a complete multi-megabyte handshake log without SIGPIPE" {
  local fake_node fake_bin ready_file="$TEST_SKILL_DIR/handshake-log.ready"
  fake_node="$(write_fake_node 512)"
  fake_bin="$(write_fake_node_ps_fixture "$fake_node" "" "$ready_file")"

  run env PATH="$fake_bin:$PATH" AGMSG_NODE="$fake_node" \
    AGMSG_TEST_LOG_READY_FILE="$ready_file" \
    bash "$SCRIPTS/remote.sh" sync start testteam
  [ "$status" -eq 0 ]
  [ -f "$ready_file" ]
  remember_engine_pid
  kill -0 "$ENGINE_PID"
}

@test "sync start reaps a ready-timeout child before releasing ownership" {
  local fake_node="$TEST_SKILL_DIR/fake-node-timeout" fake_bin lock child_pid_file child_pid
  child_pid_file="$TEST_SKILL_DIR/timeout-child.pid"
  printf '%s\n' '#!/usr/bin/env bash' \
    'printf '\''%s\\n'\'' "$$" > "$AGMSG_TEST_CHILD_PID_FILE"' \
    'trap "" TERM' \
    'while :; do sleep 1; done' > "$fake_node"
  chmod +x "$fake_node"
  fake_bin="$(write_fake_node_ps_fixture "$fake_node")"

  run env PATH="$fake_bin:$PATH" AGMSG_NODE="$fake_node" \
    AGMSG_TEST_CHILD_PID_FILE="$child_pid_file" \
    bash "$SCRIPTS/remote.sh" sync start testteam
  [ "$status" -ne 0 ]
  [[ "$output" == *"did not become ready"* ]]
  [ ! -e "$TEST_SKILL_DIR/run/remote-sync.testteam.pid" ]
  child_pid="$(cat "$child_pid_file")"
  refute kill -0 "$child_pid" 2>/dev/null
  lock="$TEST_SKILL_DIR/teams/testteam/.config.lock"
  [ ! -d "$lock" ]
}

@test "sync start: rejects a team whose binding is not active" {
  local cfg="$TEST_SKILL_DIR/teams/testteam/config.json" escaped updated
  escaped="$(sed "s/'/''/g" "$cfg")"
  updated="$(sqlite_mem \
    "SELECT json_set('$escaped', '\$.remote_binding.disconnected_at', '2026-07-30T01:00:00Z');")"
  printf '%s\n' "$updated" > "$cfg"

  run bash "$SCRIPTS/remote.sh" sync start testteam
  [ "$status" -ne 0 ]
  [[ "$output" == *"team 'testteam' is disconnected"* ]]
  [ ! -e "$TEST_SKILL_DIR/run/remote-sync.testteam.pid" ]
}
