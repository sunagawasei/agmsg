#!/usr/bin/env bats

# watch.sh --max-seconds=N: shortly before the host's cap the watcher prints one
# "re-arm" or "stopping" line and exits 0 on its own; without the option it
# never ends by itself.

load test_helper

setup() {
  setup_test_env
  unset HERDR_PANE_ID HERDR_ENV AGMSG_CC_MONITOR_KEEP_ALIVE
  export PROJ="/tmp/agmsg-watch-renew-proj"
  bash "$SCRIPTS/join.sh" team alice claude-code "$PROJ" >/dev/null
  bash "$SCRIPTS/join.sh" team bob claude-code "$PROJ" >/dev/null
}

teardown() {
  teardown_test_env
}

# Wait up to <secs> for pid <1> to exit; non-zero if it is still running.
_wait_exit() {
  local pid="$1" secs="$2" i
  for ((i = 0; i < secs * 5; i++)); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.2
  done
  return 1
}

@test "watch --max-seconds: with nothing delivered it prints 'stopping' and exits 0" {
  AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" renew-stop "$PROJ" claude-code alice --max-seconds=2 \
    >"$BATS_TEST_TMPDIR/out" 2>/dev/null 3>&- 4>&- &
  local pid=$!
  _wait_exit "$pid" 40 || { kill "$pid" 2>/dev/null; false; }
  wait "$pid"
  grep -q '^agmsg watch: stopping - ' "$BATS_TEST_TMPDIR/out"
  refute grep -q 'agmsg watch: re-arm' "$BATS_TEST_TMPDIR/out"
}

@test "watch --max-seconds: with AGMSG_CC_MONITOR_KEEP_ALIVE set it prints 're-arm' naming the exact command and description" {
  AGMSG_CC_MONITOR_KEEP_ALIVE=1 AGMSG_WATCH_INTERVAL=1 \
    bash "$SCRIPTS/watch.sh" renew-keep "$PROJ" claude-code alice --max-seconds=2 \
    >"$BATS_TEST_TMPDIR/out" 2>/dev/null 3>&- 4>&- &
  local pid=$!
  _wait_exit "$pid" 40 || { kill "$pid" 2>/dev/null; false; }
  wait "$pid"
  local line
  line="$(grep '^agmsg watch: re-arm - ' "$BATS_TEST_TMPDIR/out")"
  [ -n "$line" ]
  [[ "$line" == *"watch.sh renew-keep "*" claude-code alice --max-seconds=2 description: agmsg inbox stream (acting as alice) persistent: true timeout_ms: 1800000" ]]
  [ "$(grep -c '^agmsg watch: ' "$BATS_TEST_TMPDIR/out")" -eq 1 ]
}

@test "watch --max-seconds: a message delivered in this run makes it 're-arm' even without KEEP_ALIVE" {
  AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" renew-deliv "$PROJ" claude-code --max-seconds=20 \
    >"$BATS_TEST_TMPDIR/out" 2>/dev/null 3>&- 4>&- &
  local pid=$!
  bash "$SCRIPTS/send.sh" team bob alice "hello-renew" >/dev/null
  _wait_exit "$pid" 60 || { kill "$pid" 2>/dev/null; false; }
  wait "$pid"
  grep -q 'hello-renew' "$BATS_TEST_TMPDIR/out"
  grep -q '^agmsg watch: re-arm - ' "$BATS_TEST_TMPDIR/out"
  refute grep -q 'agmsg watch: stopping' "$BATS_TEST_TMPDIR/out"
}

@test "watch --max-seconds: a non-numeric value is ignored and the watcher keeps running" {
  AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" renew-bad "$PROJ" claude-code alice --max-seconds=abc \
    >"$BATS_TEST_TMPDIR/out" 2>/dev/null 3>&- 4>&- &
  local pid=$!
  sleep 3
  kill -0 "$pid"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  refute grep -q 'agmsg watch: ' "$BATS_TEST_TMPDIR/out"
}

@test "watch: without --max-seconds the watcher never ends by itself" {
  AGMSG_CC_MONITOR_KEEP_ALIVE=1 AGMSG_WATCH_INTERVAL=1 \
    bash "$SCRIPTS/watch.sh" renew-none "$PROJ" claude-code alice \
    >"$BATS_TEST_TMPDIR/out" 2>/dev/null 3>&- 4>&- &
  local pid=$!
  sleep 3
  kill -0 "$pid"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  refute grep -q 'agmsg watch: ' "$BATS_TEST_TMPDIR/out"
}

# Elapsed time and delivery count are exported across an install-change
# re-exec (AGMSG_WATCH_ELAPSED_BASE / AGMSG_WATCH_DELIVERED_BASE); a restart
# that lands past the limit must still renew or stop on its first cycle.
@test "watch --max-seconds: elapsed time carried over a restart past the limit ends the first cycle" {
  AGMSG_WATCH_ELAPSED_BASE=100 AGMSG_WATCH_INTERVAL=1 \
    bash "$SCRIPTS/watch.sh" renew-base "$PROJ" claude-code alice --max-seconds=50 \
    >"$BATS_TEST_TMPDIR/out" 2>/dev/null 3>&- 4>&- &
  local pid=$!
  _wait_exit "$pid" 10 || { kill "$pid" 2>/dev/null; false; }
  wait "$pid"
  grep -q '^agmsg watch: stopping - ' "$BATS_TEST_TMPDIR/out"
}

@test "watch --max-seconds: delivery count carried over a restart makes it 're-arm'" {
  AGMSG_WATCH_ELAPSED_BASE=100 AGMSG_WATCH_DELIVERED_BASE=1 AGMSG_WATCH_INTERVAL=1 \
    bash "$SCRIPTS/watch.sh" renew-carry "$PROJ" claude-code alice --max-seconds=50 \
    >"$BATS_TEST_TMPDIR/out" 2>/dev/null 3>&- 4>&- &
  local pid=$!
  _wait_exit "$pid" 10 || { kill "$pid" 2>/dev/null; false; }
  wait "$pid"
  grep -q '^agmsg watch: re-arm - ' "$BATS_TEST_TMPDIR/out"
}

@test "watch --max-seconds: an explicitly empty AGMSG_CC_MONITOR_KEEP_ALIVE counts as OFF" {
  AGMSG_CC_MONITOR_KEEP_ALIVE= AGMSG_WATCH_ELAPSED_BASE=100 AGMSG_WATCH_INTERVAL=1 \
    bash "$SCRIPTS/watch.sh" renew-empty "$PROJ" claude-code alice --max-seconds=50 \
    >"$BATS_TEST_TMPDIR/out" 2>/dev/null 3>&- 4>&- &
  local pid=$!
  _wait_exit "$pid" 10 || { kill "$pid" 2>/dev/null; false; }
  wait "$pid"
  grep -q '^agmsg watch: stopping - ' "$BATS_TEST_TMPDIR/out"
}
