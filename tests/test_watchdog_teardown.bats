#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
  export SKILL_DIR="$TEST_SKILL_DIR"
  export RUN="$TEST_SKILL_DIR/run"
  export PROJ="$TEST_SKILL_DIR/project"
  export TEST_PIDS=""
  mkdir -p "$RUN" "$PROJ"
  bash "$SCRIPTS/config.sh" set delivery.session_team true >/dev/null
}

teardown() {
  local pid
  for pid in $TEST_PIDS; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  teardown_test_env
}

stub_session_end_worker() {
  cat > "$SCRIPTS/session-end-worker.sh" <<'EOF'
#!/usr/bin/env bash
run_dir="$(cd "$(dirname "$0")/.." && pwd)/run"
team="s-${3%%.*}"
tombstone="$run_dir/watchdog.$team.tombstone"
if [ -f "$tombstone" ]; then
  printf '%s\n' "$4" > "${RESULT:?}"
else
  printf 'recovered\n' > "${RESULT:?}"
  : > "${RECOVERY:?}"
fi
exit 0
EOF
  chmod +x "$SCRIPTS/session-end-worker.sh"
}

@test "session-end writes the team tombstone before detaching its worker" {
  local sid='D0E0-TEARDOWN-001' team="s-D0E0-TEARDOWN-001" result="$RUN/worker-result"
  export RESULT="$result"
  stub_session_end_worker

  run bash -c \
    "printf '{\"session_id\":\"$sid\"}' | env RESULT='$result' bash '$SCRIPTS/session-end.sh' claude-code '$PROJ'"
  [ "$status" -eq 0 ]
  wait_for_file "$result"
  [ -s "$result" ]
  [ "$(cat "$RUN/watchdog.$team.tombstone")" = "$(cat "$result")" ]
}

@test "a mid-teardown fake recovery is blocked by the intentional tombstone" {
  local sid='D0E0-TEARDOWN-002' team="s-D0E0-TEARDOWN-002"
  local result="$RUN/recovery-result" recovery="$RUN/recovered"
  export RESULT="$result" RECOVERY="$recovery"
  stub_session_end_worker

  run bash -c \
    "printf '{\"session_id\":\"$sid\"}' | env RESULT='$result' RECOVERY='$recovery' bash '$SCRIPTS/session-end.sh' claude-code '$PROJ'"
  [ "$status" -eq 0 ]
  wait_for_file "$result"
  [ "$(cat "$result")" != recovered ]
  [ ! -e "$recovery" ]
  [ -f "$RUN/watchdog.$team.tombstone" ]
}

@test "session-end-worker kills watch.sh before its first headless despawn" {
  local sid='D0E0-WATCH-001' instance='D0E0-WATCH-001.7001'
  local snapshot="$RUN/session.snapshot" order="$RUN/despawn-order"
  local watch_pid env_file

  # The isolated compat shim makes the ordinary sleep process look like the
  # watch.sh named in its pidfile; the fake kill function records the signal
  # before the first despawn stub is entered.
  mv "$SCRIPTS/lib/compat.sh" "$SCRIPTS/lib/compat.real.sh"
  cat > "$SCRIPTS/lib/compat.sh" <<EOF
#!/usr/bin/env bash
source "$SCRIPTS/lib/compat.real.sh"
compat_get_cmdline() { printf '%s' '$SCRIPTS/watch.sh'; }
EOF
  sleep 300 &
  watch_pid=$!
  TEST_PIDS="$TEST_PIDS $watch_pid"
  printf '%s\n' "$watch_pid" > "$RUN/watch.$instance.pid"
  printf 'worker\tpid:123\t%s\tcodex\n' "$PROJ" > "$snapshot"
  printf 'pid:123\t%s\tcodex\n' "$PROJ" \
    > "$RUN/spawn.s-D0E0-WATCH-001__worker"

  cat > "$SCRIPTS/despawn.sh" <<'EOF'
#!/usr/bin/env bash
if [ -f "$WATCH_KILLED" ]; then
  printf 'watch-killed\n' > "$DESPAWN_ORDER"
else
  printf 'watch-still-live\n' > "$DESPAWN_ORDER"
fi
exit 0
EOF
  chmod +x "$SCRIPTS/despawn.sh"
  env_file="$RUN/fake-kill-env.sh"
  cat > "$env_file" <<'EOF'
kill() {
  if [ "${1:-}" = "$WATCH_PID" ]; then
    : > "$WATCH_KILLED"
  fi
  builtin kill "$@"
}
EOF

  run env BASH_ENV="$env_file" WATCH_PID="$watch_pid" \
    WATCH_KILLED="$RUN/watch-killed" DESPAWN_ORDER="$order" \
    bash "$SCRIPTS/session-end-worker.sh" claude-code "$PROJ" \
      "$sid" "$instance" "$snapshot"
  [ "$status" -eq 0 ]
  [ "$(cat "$order")" = watch-killed ]
  [ ! -e "$RUN/watch.$instance.pid" ]
}

@test "session-start clears only its own tombstone and missing cleanup is a no-op" {
  local sid='D0E0-START-001' own="s-D0E0-START-001" other='s-D0E0-OTHER'
  printf '%s\n' "$sid" > "$RUN/watchdog.$own.tombstone"
  printf 'other\n' > "$RUN/watchdog.$other.tombstone"

  run bash -c \
    "printf '{\"session_id\":\"$sid\"}' | bash '$SCRIPTS/session-start.sh' claude-code '$PROJ'"
  [ "$status" -eq 0 ]
  [ ! -e "$RUN/watchdog.$own.tombstone" ]
  [ -f "$RUN/watchdog.$other.tombstone" ]

  run bash -c \
    "printf '{\"session_id\":\"$sid\"}' | bash '$SCRIPTS/session-start.sh' claude-code '$PROJ'"
  [ "$status" -eq 0 ]
  [ ! -e "$RUN/watchdog.$own.tombstone" ]
  [ -f "$RUN/watchdog.$other.tombstone" ]
}

@test "live sibling skips despawn and owner cleanup reopens recovery" {
  local sid='D0E0-SIBLING-001' instance='D0E0-SIBLING-001.7001'
  local snapshot="$RUN/sibling.snapshot" calls="$RUN/despawn-calls"
  local sibling_pid worker_pid tombstone="$RUN/watchdog.s-D0E0-SIBLING-001.tombstone"

  sleep 300 &
  sibling_pid=$!
  TEST_PIDS="$TEST_PIDS $sibling_pid"
  printf '%s.%s\n' "$sid" "$sibling_pid" > "$RUN/cc-instance.$sibling_pid"
  sleep 300 &
  worker_pid=$!
  TEST_PIDS="$TEST_PIDS $worker_pid"
  printf 'worker\tpid:%s\t%s\tcodex\n' "$worker_pid" "$PROJ" > "$snapshot"
  printf '%s\n' "$instance" > "$tombstone"

  cat > "$SCRIPTS/despawn.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$3" >> "$DESPAWN_CALLS"
exit 0
EOF
  chmod +x "$SCRIPTS/despawn.sh"

  run env DESPAWN_CALLS="$calls" bash "$SCRIPTS/session-end-worker.sh" \
    claude-code "$PROJ" "$sid" "$instance" "$snapshot"
  [ "$status" -eq 0 ]
  [ ! -e "$tombstone" ]
  [ ! -e "$calls" ]
  run kill -0 "$worker_pid"
  [ "$status" -eq 0 ]
}

@test "owner mismatch preserves a newer teardown stamp" {
  local sid='D0E0-OWNER-001' old='D0E0-OWNER-001.7001' new='D0E0-OWNER-001.7002'
  local tombstone="$RUN/watchdog.s-$sid.tombstone"
  printf '%s\n' "$new" > "$tombstone"
  run bash "$SCRIPTS/session-end-worker.sh" claude-code "$PROJ" "$sid" "$old" "$RUN/missing.snapshot"
  [ "$status" -eq 0 ]
  [ "$(cat "$tombstone")" = "$new" ]
  run bash "$SCRIPTS/session-end-worker.sh" claude-code "$PROJ" "$sid" "$new" "$RUN/missing.snapshot"
  [ "$status" -eq 0 ]
  [ ! -e "$tombstone" ]
}

@test "empty or missing snapshots still retire the owner stamp" {
  local sid='D0E0-EMPTY-001' instance='D0E0-EMPTY-001.7001'
  local tombstone="$RUN/watchdog.s-$sid.tombstone" empty="$RUN/empty.snapshot"
  printf '%s\n' "$instance" > "$tombstone"
  : > "$empty"
  run bash "$SCRIPTS/session-end-worker.sh" claude-code "$PROJ" "$sid" "$instance" "$empty"
  [ "$status" -eq 0 ]
  [ ! -e "$tombstone" ]

  printf '%s\n' "$instance" > "$tombstone"
  bash "$SCRIPTS/config.sh" set delivery.session_team false >/dev/null
  run bash "$SCRIPTS/session-end-worker.sh" claude-code "$PROJ" "$sid" "$instance" "$RUN/missing.snapshot"
  [ "$status" -eq 0 ]
  [ ! -e "$tombstone" ]
}

watchdog_run() {
  local stamp="$1" mode="${2:-fresh}" tombstone="$RUN/watchdog.s-WATCH-FRESH.tombstone"
  local watchdog_stub="$SCRIPTS/watchdog.sh" start_pid
  bash "$SCRIPTS/config.sh" set delivery.session_team true >/dev/null
  bash "$SCRIPTS/join.sh" s-WATCH-FRESH alice claude-code "$PROJ" >/dev/null
  cat > "$watchdog_stub" <<'EOF'
#!/usr/bin/env bash
: > "${WATCHDOG_LAUNCHED:?}"
EOF
  chmod +x "$watchdog_stub"
  printf '%s' "$stamp" > "$tombstone"
  case "$mode" in
    missing) rm -f "$tombstone" ;;
    old) touch -t 202001010000 "$tombstone" ;;
    future) touch -t 209901010000 "$tombstone" ;;
    stat-fail) ;;
  esac
  if [ "$mode" = stat-fail ]; then
    mkdir -p "$RUN/stat-bin"
    cat > "$RUN/stat-bin/stat" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "$RUN/stat-bin/stat"
    PATH="$RUN/stat-bin:$PATH" bash "$SCRIPTS/watch.sh" WATCH-FRESH "$PROJ" claude-code --team s-WATCH-FRESH &
  else
    bash "$SCRIPTS/watch.sh" WATCH-FRESH "$PROJ" claude-code --team s-WATCH-FRESH &
  fi
  start_pid=$!
  TEST_PIDS="$TEST_PIDS $start_pid"
  if [ "$mode" = fresh ]; then
    sleep 0.3
    [ ! -e "$WATCHDOG_LAUNCHED" ]
  else
    wait_for_file "$WATCHDOG_LAUNCHED"
    [ -e "$WATCHDOG_LAUNCHED" ]
  fi
  kill "$start_pid" 2>/dev/null || true
  wait "$start_pid" 2>/dev/null || true
}

@test "a mid-teardown or SIGKILL stamp suppresses only while fresh" {
  export WATCHDOG_LAUNCHED="$RUN/watchdog-launched"
  watchdog_run owner fresh
  watchdog_run owner old
  rm -f "$WATCHDOG_LAUNCHED"
  watchdog_run owner future
  rm -f "$WATCHDOG_LAUNCHED"
  watchdog_run $'owner\nother' malformed
  rm -f "$WATCHDOG_LAUNCHED"
  watchdog_run '' missing
  rm -f "$WATCHDOG_LAUNCHED"
  watchdog_run owner stat-fail
}

@test "no secondary watchdog marker artifacts are produced" {
  local sid='D0E0-NO-SIDECAR-001' instance='D0E0-NO-SIDECAR-001.7001'
  printf '%s\n' "$instance" > "$RUN/watchdog.s-$sid.tombstone"
  run bash "$SCRIPTS/session-end-worker.sh" claude-code "$PROJ" "$sid" "$instance" "$RUN/missing.snapshot"
  [ "$status" -eq 0 ]
  run find "$RUN" -maxdepth 1 \( -name '*.pending' -o -name 'watchdog.*.*.tombstone' -o -name '*.lock' \) -print
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
