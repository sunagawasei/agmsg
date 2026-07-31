#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env

  export SKILL_DIR="$TEST_SKILL_DIR"
  export RUN_DIR="$SKILL_DIR/run"
  mkdir -p "$RUN_DIR"
  # shellcheck disable=SC1090
  source "$SCRIPTS/lib/actas-lock.sh"

  export STUB_BIN="$TEST_SKILL_DIR/wait-stub-bin"
  mkdir -p "$STUB_BIN"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB_BIN/claude"
  chmod +x "$STUB_BIN/claude"
  export PATH="$STUB_BIN:$PATH"

  export PROJ="$TEST_SKILL_DIR/project"
  mkdir -p "$PROJ"
  unset TMUX
  unset HERDR_ENV HERDR_PANE_ID HERDR_WORKSPACE_ID

  # This file's fixture shortens polling by default. Individual tests prove an
  # explicit override and the production all-unset 1-second defaults too.
  export AGMSG_SPAWN_READY_POLL_INTERVAL=0.05
  export AGMSG_PLACEMENT_LOCK_POLL_INTERVAL=0.05
}

teardown() {
  teardown_test_env
}

install_fake_wait_commands() {
  export WAIT_DATE_COUNT="$TEST_SKILL_DIR/wait-date.count"
  export WAIT_SLEEP_LOG="$TEST_SKILL_DIR/wait-sleep.log"
  : > "$WAIT_SLEEP_LOG"
  printf '0\n' > "$WAIT_DATE_COUNT"

  cat > "$STUB_BIN/date" <<'DATE_STUB'
#!/usr/bin/env bash
if [ "${1-}" != "+%s" ]; then
  exec /bin/date "$@"
fi
count=0
[ ! -f "$WAIT_DATE_COUNT" ] || IFS= read -r count < "$WAIT_DATE_COUNT"
count=$((count + 1))
printf '%s\n' "$count" > "$WAIT_DATE_COUNT"
case "${WAIT_CLOCK_MODE:-immediate}" in
  hold)
    [ "$count" -le 4 ] && printf '100\n' || printf '101\n'
    ;;
  backward)
    case "$count" in
      1) printf '100\n' ;;
      2) printf '90\n' ;;
      *) printf '91\n' ;;
    esac
    ;;
  static)
    printf '100\n'
    ;;
  *)
    [ "$count" -eq 1 ] && printf '100\n' || printf '101\n'
    ;;
esac
DATE_STUB

  cat > "$STUB_BIN/sleep" <<'SLEEP_STUB'
#!/usr/bin/env bash
printf '%s\n' "${1-}" >> "$WAIT_SLEEP_LOG"
if [ -n "${WAIT_READY_ON_SLEEP-}" ]; then
  : > "$WAIT_READY_ON_SLEEP"
fi
SLEEP_STUB
  chmod +x "$STUB_BIN/date" "$STUB_BIN/sleep"
}

register_team() {
  bash "$SCRIPTS/join.sh" wait-team existing claude-code "$PROJ"
}

spawn_wait() {
  local name="$1" timeout="$2"
  bash "$SCRIPTS/spawn.sh" claude-code "$name" \
    --project "$PROJ" --team wait-team --ready-timeout "$timeout" \
    --terminal "true # {cmd}"
}

@test "wait knob validator accepts bounded decimals and falls back for every malformed class" {
  local raw
  for raw in 0.01 0.25 1 60; do
    run agmsg_wait_knob_resolve "$raw" 1 0.01 60 decimal
    [ "$status" -eq 0 ]
    [ "$output" = "$raw" ]
  done

  for raw in "" 0 -1 NaN 1..2 " 1" "1 " 1e2 0.001 60.01 .5 1.; do
    run agmsg_wait_knob_resolve "$raw" 1 0.01 60 decimal
    [ "$status" -eq 0 ]
    [ "$output" = 1 ]
  done
}

@test "wait knob validator supports A2 decimal intervals and canonical integer max-counts unchanged" {
  run agmsg_wait_knob_resolve 0.125 1 0.01 60 decimal
  [ "$status" -eq 0 ]
  [ "$output" = 0.125 ]

  for raw in 1 37 10000; do
    run agmsg_wait_knob_resolve "$raw" 100 1 10000 integer
    [ "$status" -eq 0 ]
    [ "$output" = "$raw" ]
  done

  run agmsg_wait_knob_resolve 0008 100 1 10000 integer
  [ "$status" -eq 0 ]
  [ "$output" = 8 ]

  local raw
  for raw in "" 0 -1 NaN 1..2 " 1" "1 " 1e2 0.5 10001; do
    run agmsg_wait_knob_resolve "$raw" 100 1 10000 integer
    [ "$status" -eq 0 ]
    [ "$output" = 100 ]
  done

  run agmsg_wait_knob_resolve 5 fallback 1 10 unknown
  [ "$status" -eq 0 ]
  [ "$output" = fallback ]
}

@test "spawn helper default is short, explicit override wins, and timeout reports wall elapsed" {
  register_team
  install_fake_wait_commands
  export WAIT_CLOCK_MODE=hold

  run spawn_wait helper-default 1
  [ "$status" -eq 3 ]
  [[ "$output" == *"status=timeout name=helper-default team=wait-team after=1s"* ]]
  [ "$(wc -l < "$WAIT_SLEEP_LOG" | tr -d ' ')" -eq 4 ]
  [ "$(sort -u "$WAIT_SLEEP_LOG")" = 0.05 ]

  : > "$WAIT_SLEEP_LOG"
  printf '0\n' > "$WAIT_DATE_COUNT"
  run env AGMSG_SPAWN_READY_POLL_INTERVAL=0.2 \
    bash "$SCRIPTS/spawn.sh" claude-code explicit-override \
      --project "$PROJ" --team wait-team --ready-timeout 1 \
      --terminal "true # {cmd}"
  [ "$status" -eq 3 ]
  [[ "$output" == *"after=1s"* ]]
  [ "$(sort -u "$WAIT_SLEEP_LOG")" = 0.2 ]
}

@test "all A1 knobs unset preserve the production one-second poll defaults" {
  register_team
  install_fake_wait_commands
  export WAIT_CLOCK_MODE=immediate

  run env -u AGMSG_SPAWN_READY_POLL_INTERVAL \
    -u AGMSG_PLACEMENT_LOCK_POLL_INTERVAL \
    bash "$SCRIPTS/spawn.sh" claude-code unset-spawn \
      --project "$PROJ" --team wait-team --ready-timeout 1 \
      --terminal "true # {cmd}"
  [ "$status" -eq 3 ]
  [[ "$output" == *"after=1s"* ]]
  [ "$(sort -u "$WAIT_SLEEP_LOG")" = 1 ]

  : > "$WAIT_SLEEP_LOG"
  printf '0\n' > "$WAIT_DATE_COUNT"
  mkdir "$(_agmsg_placement_lock_path wait-team unset-placement)"
  unset AGMSG_PLACEMENT_LOCK_POLL_INTERVAL
  run agmsg_placement_lock_acquire wait-team unset-placement 1
  [ "$status" -eq 1 ]
  [ "$(sort -u "$WAIT_SLEEP_LOG")" = 1 ]
  [ -d "$(_agmsg_placement_lock_path wait-team unset-placement)" ]
}

@test "placement helper default is short and an explicit override wins" {
  install_fake_wait_commands
  export WAIT_CLOCK_MODE=immediate

  mkdir "$(_agmsg_placement_lock_path wait-team helper-placement)"
  run agmsg_placement_lock_acquire wait-team helper-placement 1
  [ "$status" -eq 1 ]
  [ "$(sort -u "$WAIT_SLEEP_LOG")" = 0.05 ]

  : > "$WAIT_SLEEP_LOG"
  printf '0\n' > "$WAIT_DATE_COUNT"
  mkdir "$(_agmsg_placement_lock_path wait-team override-placement)"
  AGMSG_PLACEMENT_LOCK_POLL_INTERVAL=0.2 run \
    agmsg_placement_lock_acquire wait-team override-placement 1
  [ "$status" -eq 1 ]
  [ "$(sort -u "$WAIT_SLEEP_LOG")" = 0.2 ]
}

@test "spawn readiness returns on the first successful fractional poll" {
  register_team
  install_fake_wait_commands
  export WAIT_CLOCK_MODE=static
  export WAIT_READY_ON_SLEEP="$RUN_DIR/ready.wait-team__early"

  run spawn_wait early 10
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=ready name=early team=wait-team after=0s"* ]]
  [ "$(wc -l < "$WAIT_SLEEP_LOG" | tr -d ' ')" -eq 1 ]
  [ "$(cat "$WAIT_SLEEP_LOG")" = 0.05 ]
}

@test "spawn readiness resets its baseline after backward wall-clock movement" {
  register_team
  install_fake_wait_commands
  export WAIT_CLOCK_MODE=backward

  run spawn_wait backward 1
  [ "$status" -eq 3 ]
  [[ "$output" == *"status=timeout name=backward team=wait-team after=1s"* ]]
  [ "$(wc -l < "$WAIT_SLEEP_LOG" | tr -d ' ')" -eq 2 ]
}

@test "placement contention resets its baseline after backward wall-clock movement" {
  install_fake_wait_commands
  export WAIT_CLOCK_MODE=backward
  local lock="$(_agmsg_placement_lock_path wait-team backward-placement)"
  mkdir "$lock"

  run agmsg_placement_lock_acquire wait-team backward-placement 1
  [ "$status" -eq 1 ]
  [ "$(wc -l < "$WAIT_SLEEP_LOG" | tr -d ' ')" -eq 2 ]
  [ -d "$lock" ]
}

@test "placement contention uses decimal sleep, honors seconds, and never fails open" {
  local lock="$(_agmsg_placement_lock_path wait-team contended)"
  mkdir "$lock"

  # Stub only wall time. The production sleep command remains on PATH, proving
  # a decimal interval is accepted by the macOS execution environment.
  export WAIT_DATE_COUNT="$TEST_SKILL_DIR/wait-date.count"
  printf '0\n' > "$WAIT_DATE_COUNT"
  cat > "$STUB_BIN/date" <<'DATE_STUB'
#!/usr/bin/env bash
count=0
[ ! -f "$WAIT_DATE_COUNT" ] || IFS= read -r count < "$WAIT_DATE_COUNT"
count=$((count + 1))
printf '%s\n' "$count" > "$WAIT_DATE_COUNT"
[ "$count" -eq 1 ] && printf '100\n' || printf '101\n'
DATE_STUB
  chmod +x "$STUB_BIN/date"

  AGMSG_PLACEMENT_LOCK_POLL_INTERVAL=0.01 run \
    agmsg_placement_lock_acquire wait-team contended 1
  [ "$status" -eq 1 ]
  [ -d "$lock" ]
}

@test "placement early success returns before clock or sleep is consulted" {
  cat > "$STUB_BIN/date" <<'FAIL_STUB'
#!/usr/bin/env bash
exit 99
FAIL_STUB
  cat > "$STUB_BIN/sleep" <<'FAIL_STUB'
#!/usr/bin/env bash
exit 99
FAIL_STUB
  chmod +x "$STUB_BIN/date" "$STUB_BIN/sleep"

  run agmsg_placement_lock_acquire wait-team free 1
  [ "$status" -eq 0 ]
  [ -d "$(_agmsg_placement_lock_path wait-team free)" ]
  agmsg_placement_lock_release wait-team free
}
