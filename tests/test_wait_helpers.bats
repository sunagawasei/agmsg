#!/usr/bin/env bats
#
# The bounded condition waits in test_helper.bash decide whether many other
# tests' assertions mean anything. `wait_for_pid_exit` in particular is the
# evidence that a process was killed, so if it can report "gone" for a live
# process, every test that uses it becomes a green that proves nothing — which
# is exactly the failure that was found in the session-end test it replaced.

load test_helper

setup() {
  setup_test_env
}

teardown() {
  teardown_test_env
}

install_wait_stubs() {
  local stub="$BATS_TEST_TMPDIR/wait-stubs"
  export WAIT_HELPER_DATE_COUNT="$BATS_TEST_TMPDIR/wait-helper-date.count"
  export WAIT_HELPER_SLEEP_LOG="$BATS_TEST_TMPDIR/wait-helper-sleep.log"
  mkdir -p "$stub"
  printf '0\n' > "$WAIT_HELPER_DATE_COUNT"
  : > "$WAIT_HELPER_SLEEP_LOG"

  cat > "$stub/date" <<'DATE_STUB'
#!/usr/bin/env bash
count=0
[ ! -f "$WAIT_HELPER_DATE_COUNT" ] || IFS= read -r count < "$WAIT_HELPER_DATE_COUNT"
count=$((count + 1))
printf '%s\n' "$count" > "$WAIT_HELPER_DATE_COUNT"
printf '%s\n' $((99 + count))
DATE_STUB
  cat > "$stub/sleep" <<'SLEEP_STUB'
#!/usr/bin/env bash
printf '%s\n' "${1-}" >> "$WAIT_HELPER_SLEEP_LOG"
SLEEP_STUB
  chmod +x "$stub/date" "$stub/sleep"
  export PATH="$stub:$PATH"
}

exercise_test_fixture_cleanup() {
  local mode="$1" expected_status="$2"
  local run_id="contract-${mode}-${BATS_TEST_NUMBER}-$$"
  local root="$BATS_TEST_TMPDIR/fixture-owner-$mode"
  local ledger_dir="$BATS_TEST_TMPDIR/fixture-ledgers"
  mkdir -p "$root" "$ledger_dir"

  run env AGMSG_TEST_FIXTURE_RUN_ID="$run_id" \
    AGMSG_TEST_FIXTURE_LEDGER_DIR="$ledger_dir" bash -c '
    set -e
    source "$1"
    test_fixture_registry_init "$2"
    test_fixture_install_cleanup_traps
    test_fixture_start_agent "2.1.199" "$3"
    case "$3" in
      normal) exit 0 ;;
      INT) kill -INT "$$"; exit 99 ;;
      TERM) kill -TERM "$$"; exit 99 ;;
      *) exit 98 ;;
    esac
  ' _ "$BATS_TEST_DIRNAME/test_helper.bash" "$root" "$mode"
  [ "$status" -eq "$expected_status" ]

  run assert_no_test_fixture_survivors "$run_id" "$ledger_dir"
  [ "$status" -eq 0 ]
  [ "$output" = "fixture-survivors=0 run_id=$run_id" ]
}

exercise_bats_signal_cleanup() {
  local signal="$1"
  local run_id="contract-bats-${signal}-${BATS_TEST_NUMBER}-$$"
  local ledger_dir="$BATS_TEST_TMPDIR/fixture-ledgers"
  local nested="$BATS_TEST_TMPDIR/fixture-${signal}.bats"
  local ready="$BATS_TEST_TMPDIR/fixture-${signal}.ready"
  local log="$BATS_TEST_TMPDIR/fixture-${signal}.log"
  local runner test_pid watcher_pid fifo_pid runner_status=0 runner_timeout=0
  local guard_status guard_output
  mkdir -p "$ledger_dir"

  printf '%s\n' \
    '#!/usr/bin/env bats' \
    "load '$BATS_TEST_DIRNAME/test_helper'" \
    'setup() { setup_test_env; }' \
    'teardown() { teardown_test_env; }' \
    '@test "markerless watcher and FIFO child wait for signal cleanup" {' \
    '  sleep 300 &' \
    '  watcher_pid=$!' \
    '  test_fixture_register_owned_pid "$watcher_pid"' \
    '  test_fixture_start_agent "2.1.199" bats-signal-fifo' \
    '  fifo_pid="$TEST_FIXTURE_PID"' \
    '  printf "%s %s %s\n" "$BASHPID" "$watcher_pid" "$fifo_pid" > "$BATS_SIGNAL_READY"' \
    '  wait "$watcher_pid"' \
    '}' \
    >"$nested"

  env --default-signal=INT --default-signal=TERM \
    AGMSG_TEST_FIXTURE_RUN_ID="$run_id" \
    AGMSG_TEST_FIXTURE_LEDGER_DIR="$ledger_dir" \
    AGMSG_TEST_SOURCE_TEST_DIR="$BATS_TEST_DIRNAME" \
    BATS_SIGNAL_READY="$ready" \
    bats "$nested" >"$log" 2>&1 &
  runner=$!
  if ! wait_for_file "$ready"; then
    kill -KILL "$runner" 2>/dev/null || true
    wait "$runner" 2>/dev/null || true
    return 1
  fi
  read -r test_pid watcher_pid fifo_pid <"$ready"

  kill -"$signal" "$test_pid"
  if ! wait_for_pid_exit "$runner"; then
    runner_timeout=1
    kill -KILL "$runner" 2>/dev/null || true
  fi
  wait "$runner" 2>/dev/null || runner_status=$?

  run assert_no_test_fixture_survivors "$run_id" "$ledger_dir"
  guard_status="$status"
  guard_output="$output"
  if [ "$guard_status" -ne 0 ]; then
    kill -KILL "$watcher_pid" "$fifo_pid" 2>/dev/null || true
    wait_for_pid_exit "$watcher_pid" || true
    wait_for_pid_exit "$fifo_pid" || true
  fi

  [ "$runner_timeout" -eq 0 ]
  [ "$runner_status" -ne 0 ]
  [ "$guard_status" -eq 0 ]
  [ "$guard_output" = "fixture-survivors=0 run_id=$run_id" ]
  [ ! -s "$ledger_dir/fixture-pids.$run_id" ]
}

@test "owned fixture cleanup runs after normal exit" {
  skip_on_windows "process argv faking via exec -a (#349)"
  exercise_test_fixture_cleanup normal 0
}

@test "owned fixture cleanup runs after assertion failure" {
  skip_on_windows "process argv faking via exec -a (#349)"
  local run_id="contract-bats-failure-${BATS_TEST_NUMBER}-$$"
  local ledger_dir="$BATS_TEST_TMPDIR/fixture-ledgers"
  local nested="$BATS_TEST_TMPDIR/fixture-assertion-failure.bats"
  mkdir -p "$ledger_dir"
  printf '%s\n' \
    '#!/usr/bin/env bats' \
    "load '$BATS_TEST_DIRNAME/test_helper'" \
    'setup() { setup_test_env; }' \
    'teardown() {' \
    '  teardown_test_env' \
    '  teardown_test_env' \
    '}' \
    '@test "intentional assertion failure" {' \
    '  test_fixture_start_agent "2.1.199" assertion-failure' \
    '  false' \
    '}' \
    >"$nested"

  run env AGMSG_TEST_FIXTURE_RUN_ID="$run_id" \
    AGMSG_TEST_FIXTURE_LEDGER_DIR="$ledger_dir" \
    AGMSG_TEST_SOURCE_TEST_DIR="$BATS_TEST_DIRNAME" \
    bats "$nested"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not ok 1 intentional assertion failure"* ]]
  [ ! -s "$ledger_dir/fixture-pids.$run_id" ]

  run assert_no_test_fixture_survivors "$run_id" "$ledger_dir"
  [ "$status" -eq 0 ]
  [ "$output" = "fixture-survivors=0 run_id=$run_id" ]
}

@test "owned fixture cleanup runs after INT" {
  skip_on_windows "process argv faking via exec -a (#349)"
  exercise_test_fixture_cleanup INT 130
}

@test "owned fixture cleanup runs after TERM" {
  skip_on_windows "process argv faking via exec -a (#349)"
  exercise_test_fixture_cleanup TERM 143
}

@test "owned gated fixture exits when its owner gets TERM before release" {
  skip_on_windows "process argv faking via exec -a (#349)"
  local run_id="contract-gated-term-${BATS_TEST_NUMBER}-$$"
  local root="$BATS_TEST_TMPDIR/fixture-gated-term"
  local ledger_dir="$BATS_TEST_TMPDIR/fixture-ledgers"
  mkdir -p "$root" "$ledger_dir"

  run env AGMSG_TEST_FIXTURE_RUN_ID="$run_id" \
    AGMSG_TEST_FIXTURE_LEDGER_DIR="$ledger_dir" bash -c '
    set -e
    source "$1"
    test_fixture_registry_init "$2"
    test_fixture_install_cleanup_traps
    gate="$2/gate"
    started="$2/started"
    mkfifo "$gate"
    test_fixture_start_gated_agent "$gate" "$started" "2.1.199"
    wait_for_file "$started"
    kill -TERM "$$"
    exit 99
  ' _ "$BATS_TEST_DIRNAME/test_helper.bash" "$root"
  [ "$status" -eq 143 ]

  run assert_no_test_fixture_survivors "$run_id" "$ledger_dir"
  [ "$status" -eq 0 ]
  [ "$output" = "fixture-survivors=0 run_id=$run_id" ]
}

@test "actual Bats INT path reaps registered watcher and FIFO children" {
  skip_on_windows "POSIX Bats signal and process teardown semantics"
  exercise_bats_signal_cleanup INT
}

@test "actual Bats TERM path reaps registered watcher and FIFO children" {
  skip_on_windows "POSIX Bats signal and process teardown semantics"
  exercise_bats_signal_cleanup TERM
}

@test "owned fixture survivor guard detects live state and clears after cleanup" {
  skip_on_windows "process argv faking via exec -a (#349)"
  local run_id="contract-live-guard-${BATS_TEST_NUMBER}-$$"
  local root="$BATS_TEST_TMPDIR/fixture-live-guard"
  local ledger_dir="$BATS_TEST_TMPDIR/fixture-ledgers"
  mkdir -p "$root" "$ledger_dir"
  export AGMSG_TEST_FIXTURE_RUN_ID="$run_id"
  export AGMSG_TEST_FIXTURE_LEDGER_DIR="$ledger_dir"
  test_fixture_registry_init "$root"
  test_fixture_start_agent "2.1.199" live-guard
  local fixture_pid="$TEST_FIXTURE_PID"
  local started_path="$TEST_FIXTURE_STARTED_PATH"
  [ -f "$started_path" ]

  run assert_no_test_fixture_survivors "$run_id" "$ledger_dir"
  [ "$status" -eq 1 ]
  [[ "$output" == *"fixture-survivors=$fixture_pid run_id=$run_id"* ]]

  test_fixture_cleanup
  [ ! -e "$started_path" ]
  [ ! -s "$ledger_dir/fixture-pids.$run_id" ]
  run assert_no_test_fixture_survivors "$run_id" "$ledger_dir"
  [ "$status" -eq 0 ]
  [ "$output" = "fixture-survivors=0 run_id=$run_id" ]
}

@test "survivor guard does not revive a historical marker PID after ps mismatch" {
  local run_id="contract-marker-reuse-${BATS_TEST_NUMBER}-$$"
  local ledger_dir="$BATS_TEST_TMPDIR/fixture-ledgers"
  mkdir -p "$ledger_dir"
  printf '4242\t--agmsg-test-fixture=%s:historical:999\tmarker\n' "$run_id" \
    >"$ledger_dir/fixture-pids.$run_id"
  ps() { printf ' 4242 unrelated-process\n'; }
  kill() { return 0; }

  run test_fixture_survivor_pids "$run_id" "$ledger_dir"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "survivor guard uses each ledger signature instead of the global signature" {
  local run_id="contract-ledger-signature-${BATS_TEST_NUMBER}-$$"
  local ledger_dir="$BATS_TEST_TMPDIR/fixture-ledgers"
  local signature_a="--agmsg-test-fixture=${run_id}:A:111"
  local signature_b="--agmsg-test-fixture=${run_id}:B:222"
  mkdir -p "$ledger_dir"
  printf '4242\t%s\tmarker\n' "$signature_a" \
    >"$ledger_dir/fixture-pids.$run_id"
  ps() {
    case "$1" in
      -Ao) return 0 ;;
      eww) printf ' 4242 %s\n' "$PS_FIXTURE_SIGNATURE" ;;
      *) return 1 ;;
    esac
  }
  kill() { return 0; }

  export AGMSG_TEST_FIXTURE_SIGNATURE="$signature_b"
  PS_FIXTURE_SIGNATURE="$signature_a"
  run test_fixture_survivor_pids "$run_id" "$ledger_dir"
  [ "$status" -eq 0 ]
  [ "$output" = 4242 ]

  unset AGMSG_TEST_FIXTURE_SIGNATURE
  PS_FIXTURE_SIGNATURE="$signature_b"
  run test_fixture_survivor_pids "$run_id" "$ledger_dir"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "fixture cleanup never signals a PID with a known signature mismatch" {
  local kill_log="$BATS_TEST_TMPDIR/signature-mismatch.kill"
  : >"$kill_log"
  _AGMSG_TEST_FIXTURE_PIDS=(4242)
  printf '4242\t%s\tmarker\n' "$AGMSG_TEST_FIXTURE_SIGNATURE" \
    >>"$_AGMSG_TEST_FIXTURE_LEDGER"
  ps() { printf ' 4242 unrelated-process\n'; }
  kill() { printf '%s\n' "$*" >>"$kill_log"; return 0; }

  test_fixture_cleanup
  [ ! -s "$kill_log" ]
  [ ! -s "$_AGMSG_TEST_FIXTURE_LEDGER" ]
}

@test "survivor guard retains the exact ledger fallback when ps is denied" {
  local run_id="contract-marker-fallback-${BATS_TEST_NUMBER}-$$"
  local ledger_dir="$BATS_TEST_TMPDIR/fixture-ledgers"
  mkdir -p "$ledger_dir"
  printf '4242\t--agmsg-test-fixture=%s:live:999\tmarker\n' "$run_id" \
    >"$ledger_dir/fixture-pids.$run_id"
  ps() { return 1; }
  kill() { return 0; }

  run test_fixture_survivor_pids "$run_id" "$ledger_dir"
  [ "$status" -eq 0 ]
  [ "$output" = 4242 ]
}

@test "setup_test_env exports shortened validated production wait knobs" {
  [ "$AGMSG_SPAWN_READY_POLL_INTERVAL" = 0.05 ]
  [ "$AGMSG_PLACEMENT_LOCK_POLL_INTERVAL" = 0.05 ]
  [ "$AGMSG_KILL_POLL_INTERVAL" = 0.05 ]
  [ "$AGMSG_KILL_POLL_MAX" = 5 ]
  [ "$AGMSG_DESPAWN_WAIT_POLL_INTERVAL" = 0.05 ]
}

@test "individual wait knob overrides survive and all-knob unset is isolated" {
  export AGMSG_SPAWN_READY_POLL_INTERVAL=0.2
  export AGMSG_PLACEMENT_LOCK_POLL_INTERVAL=0.3
  export AGMSG_KILL_POLL_INTERVAL=0.4
  export AGMSG_KILL_POLL_MAX=7
  export AGMSG_DESPAWN_WAIT_POLL_INTERVAL=0.5
  run bash -c 'printf "%s/%s/%s/%s/%s\n" \
    "$AGMSG_SPAWN_READY_POLL_INTERVAL" \
    "$AGMSG_PLACEMENT_LOCK_POLL_INTERVAL" \
    "$AGMSG_KILL_POLL_INTERVAL" \
    "$AGMSG_KILL_POLL_MAX" \
    "$AGMSG_DESPAWN_WAIT_POLL_INTERVAL"'
  [ "$status" -eq 0 ]
  [ "$output" = "0.2/0.3/0.4/7/0.5" ]

  unset AGMSG_SPAWN_READY_POLL_INTERVAL
  unset AGMSG_PLACEMENT_LOCK_POLL_INTERVAL
  unset AGMSG_KILL_POLL_INTERVAL
  unset AGMSG_KILL_POLL_MAX
  unset AGMSG_DESPAWN_WAIT_POLL_INTERVAL
  [ -z "${AGMSG_SPAWN_READY_POLL_INTERVAL+set}" ]
  [ -z "${AGMSG_PLACEMENT_LOCK_POLL_INTERVAL+set}" ]
  [ -z "${AGMSG_KILL_POLL_INTERVAL+set}" ]
  [ -z "${AGMSG_KILL_POLL_MAX+set}" ]
  [ -z "${AGMSG_DESPAWN_WAIT_POLL_INTERVAL+set}" ]
}

@test "_pid_gone: reports a live process as alive" {
  sleep 5 &
  local p=$!
  run _pid_gone "$p"
  kill "$p" 2>/dev/null || true
  wait "$p" 2>/dev/null || true
  [ "$status" -ne 0 ]
}

@test "_pid_gone: reports a pid that never existed as gone" {
  # Far above any live pid on the platforms this suite runs on.
  run _pid_gone 4194303
  [ "$status" -eq 0 ]
}

@test "_pid_gone: reports an exited child as gone, zombie or not" {
  sleep 0.1 &
  local p=$!
  wait "$p" 2>/dev/null || true
  run _pid_gone "$p"
  [ "$status" -eq 0 ]
}

@test "_pid_gone: a failed kill -0 that is not ESRCH counts as ALIVE" {
  # The EPERM case cannot be produced portably in-suite, so pin the decision
  # rule itself: anything other than "no such process" must not be read as
  # death. This is the branch that keeps a sandboxed, unsignalable-but-running
  # process from being reported as exited.
  local decided
  decided=$(
    kill() { echo "bash: kill: (1234) - Operation not permitted" >&2; return 1; }
    ps() { return 1; }   # even with no process-table evidence
    _pid_gone 1234 && echo GONE || echo ALIVE
  )
  [ "$decided" = "ALIVE" ]
}

@test "wait_for_pid_exit: returns promptly once the process is gone" {
  sleep 0.05 &
  local p=$!
  _WAIT_INTERVAL=0.01
  run wait_for_pid_exit "$p"
  [ "$status" -eq 0 ]
}

@test "wait_for_pid_exit: times out rather than claiming a live process exited" {
  sleep 30 &
  local p=$!
  install_wait_stubs
  _WAIT_TIMEOUT=1 run wait_for_pid_exit "$p"
  kill "$p" 2>/dev/null || true
  wait "$p" 2>/dev/null || true
  [ "$status" -eq 1 ]
  [[ "$output" == *"wait: timeout after 1s waiting for pid $p exit"* ]]
  [ "$(cat "$WAIT_HELPER_SLEEP_LOG")" = 0.05 ]
}

@test "wait helpers return immediately when their conditions already hold" {
  local f="$BATS_TEST_TMPDIR/probe"
  echo "42" > "$f"
  run wait_for_file "$f"
  [ "$status" -eq 0 ]
  run wait_for_file_is "$f" "42"
  [ "$status" -eq 0 ]

  rm -f "$f"
  run wait_for_missing "$f"
  [ "$status" -eq 0 ]
}

@test "wait_for_file polls with a decimal macOS sleep and returns on early success" {
  local f="$BATS_TEST_TMPDIR/async-probe" creator
  (
    sleep 0.05
    : > "$f"
  ) &
  creator=$!

  _WAIT_TIMEOUT=2
  _WAIT_INTERVAL=0.01
  run wait_for_file "$f"
  wait "$creator"
  [ "$status" -eq 0 ]
  [ -f "$f" ]
}

@test "condition polling has deterministic timeout and strict hard-error diagnostics" {
  local f="$BATS_TEST_TMPDIR/never-created"
  install_wait_stubs

  _WAIT_TIMEOUT=1 run wait_for_file "$f"
  [ "$status" -eq 1 ]
  [[ "$output" == *"wait: timeout after 1s waiting for file $f"* ]]

  printf 'actual\n' > "$f"
  _WAIT_TIMEOUT=1 run wait_for_file_is "$f" expected
  [ "$status" -eq 1 ]
  [[ "$output" == *"wait: timeout after 1s waiting for exact text in $f"* ]]

  wait_helper_hard_error() { return 7; }
  run _wait_poll 10 0.05 "hard-error probe" wait_helper_hard_error
  [ "$status" -eq 7 ]
  [[ "$output" == *"wait: condition error status=7 while waiting for hard-error probe"* ]]

  run _wait_poll bad 0.05 "invalid-args probe" true
  [ "$status" -eq 2 ]
  [[ "$output" == *"wait: invalid timeout/interval for invalid-args probe"* ]]
}

@test "installed Bats 1.12 filters the slow tag while retaining ordinary tests" {
  local fixture="$BATS_TEST_TMPDIR/tag-filter.bats"
  {
    printf '%s\n' '#!/usr/bin/env bats'
    printf '%s\n' '@test "ordinary sentinel" { true; }'
    printf '# bats test_%s=slow\n' tags
    printf '%s\n' '@test "slow sentinel" { false; }'
  } > "$fixture"

  run bats --filter-tags "!slow" "$fixture"
  [ "$status" -eq 0 ]
  [[ "$output" == *"1..1"* ]]
  [[ "$output" == *"ordinary sentinel"* ]]
  [[ "$output" != *"slow sentinel"* ]]
}

@test "the A2 default-path lower-bound case is the only slow-tagged repository test" {
  local tags
  tags="$(grep -H '^# bats test_tags=slow$' "$BATS_TEST_DIRNAME"/*.bats)"
  [ "$(printf '%s\n' "$tags" | wc -l | tr -d ' ')" -eq 1 ]
  [[ "$tags" == "$BATS_TEST_DIRNAME/test_despawn_wait_knobs.bats:"* ]]
}
