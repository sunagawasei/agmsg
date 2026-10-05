#!/usr/bin/env bats

# watch.sh polls at 1 second unless AGMSG_WATCH_INTERVAL or an explicit
# delivery.monitor.poll_interval says otherwise; an empty or non-numeric value
# falls back to that same default.

load test_helper

setup() {
  setup_test_env
  unset HERDR_PANE_ID HERDR_ENV
  export PROJ="/tmp/agmsg-watch-poll-proj"
  bash "$SCRIPTS/join.sh" team alice claude-code "$PROJ" >/dev/null
  bash "$SCRIPTS/join.sh" team bob claude-code "$PROJ" >/dev/null
  # Seed a read message so the watcher reaches the idle poll loop.
  bash "$SCRIPTS/send.sh" team bob alice "seed" >/dev/null
  bash "$SCRIPTS/inbox.sh" team alice >/dev/null
}

teardown() {
  teardown_test_env
}

# Prints the first whole-second `sleep` argument watch.sh uses between polls.
# The shim shortens the real sleep so the test does not wait out a 5s interval.
poll_sleep_arg() {
  local shimbin="$BATS_TEST_TMPDIR/shim-bin" log="$BATS_TEST_TMPDIR/sleep.log" real i
  mkdir -p "$shimbin"
  : >"$log"
  real="$(command -v sleep)"
  cat >"$shimbin/sleep" <<SHIM
#!/usr/bin/env bash
case "\${1:-}" in ''|*[!0-9]*) exec '$real' "\$@" ;; esac
echo "\$1" >> '$log'
exec '$real' 0.2
SHIM
  chmod +x "$shimbin/sleep"
  PATH="$shimbin:$PATH" bash "$SCRIPTS/watch.sh" poll-sess "$PROJ" claude-code alice \
    >/dev/null 2>&1 3>&- 4>&- &
  local wpid=$!
  for i in $(seq 1 100); do
    [ -s "$log" ] && break
    "$real" 0.2
  done
  kill "$wpid" 2>/dev/null || true
  wait "$wpid" 2>/dev/null || true
  head -n 1 "$log"
}

@test "watch poll interval: defaults to 1 with no env and no config entry" {
  run poll_sleep_arg
  [ "$output" = "1" ]
}

@test "watch poll interval: AGMSG_WATCH_INTERVAL wins over config" {
  bash "$SCRIPTS/config.sh" set delivery.monitor.poll_interval 3 >/dev/null
  AGMSG_WATCH_INTERVAL=5 run poll_sleep_arg
  [ "$output" = "5" ]
}

@test "watch poll interval: an explicit config value is used" {
  bash "$SCRIPTS/config.sh" set delivery.monitor.poll_interval 3 >/dev/null
  run poll_sleep_arg
  [ "$output" = "3" ]
}

@test "watch poll interval: a non-numeric config value falls back to 1" {
  bash "$SCRIPTS/config.sh" set delivery.monitor.poll_interval abc >/dev/null
  run poll_sleep_arg
  [ "$output" = "1" ]
}

@test "watch poll interval: a non-numeric env value falls back to 1, not to config" {
  bash "$SCRIPTS/config.sh" set delivery.monitor.poll_interval 3 >/dev/null
  AGMSG_WATCH_INTERVAL=abc run poll_sleep_arg
  [ "$output" = "1" ]
}
