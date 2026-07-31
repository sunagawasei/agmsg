#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
  export SKILL_DIR="$TEST_SKILL_DIR"
  export PROJ="$TEST_SKILL_DIR/project"
  export RUN="$TEST_SKILL_DIR/run"
  export RUN_DIR="$RUN"
  export STUB_BIN="$TEST_SKILL_DIR/wait-stub-bin"
  export WAIT_SLEEP_LOG="$TEST_SKILL_DIR/wait-sleep.log"
  export WAIT_DATE_COUNT="$TEST_SKILL_DIR/wait-date.count"
  mkdir -p "$PROJ" "$RUN" "$STUB_BIN"
  unset AGMSG_KILL_POLL_INTERVAL AGMSG_KILL_POLL_MAX AGMSG_DESPAWN_WAIT_POLL_INTERVAL
  unset TEST_SUBJECT_PID
  source "$SCRIPTS/lib/actas-lock.sh"
}

teardown() {
  if [ -n "${TEST_SUBJECT_PID:-}" ]; then
    kill -9 "$TEST_SUBJECT_PID" 2>/dev/null || true
    wait "$TEST_SUBJECT_PID" 2>/dev/null || true
  fi
  teardown_test_env
}

install_sleep_stub() {
  cat > "$STUB_BIN/sleep" <<'SLEEP_STUB'
#!/usr/bin/env bash
printf '%s\n' "${1-}" >> "$WAIT_SLEEP_LOG"
if [ -n "${WAIT_RELEASE_PATH:-}" ]; then
  rm -f -- "$WAIT_RELEASE_PATH"
fi
exit 0
SLEEP_STUB
  chmod +x "$STUB_BIN/sleep"
  : > "$WAIT_SLEEP_LOG"
}

install_date_stub() {
  cat > "$STUB_BIN/date" <<'DATE_STUB'
#!/usr/bin/env bash
if [ "${1-}" != "+%s" ]; then
  exec /bin/date "$@"
fi
count=0
[ ! -f "$WAIT_DATE_COUNT" ] || IFS= read -r count < "$WAIT_DATE_COUNT"
count=$((count + 1))
printf '%s\n' "$count" > "$WAIT_DATE_COUNT"
case "${WAIT_DATE_MODE:-timeout}" in
  timeout|early)
    [ "$count" -eq 1 ] && printf '100\n' || printf '101\n' ;;
  backward)
    case "$count" in
      1) printf '100\n' ;;
      2) printf '90\n' ;;
      *) printf '91\n' ;;
    esac ;;
  error)
    printf '100\n'
    exit 2 ;;
  *)
    exec /bin/date +%s ;;
esac
exit 0
DATE_STUB
  chmod +x "$STUB_BIN/date"
  printf '0\n' > "$WAIT_DATE_COUNT"
}

start_ignoring_subject() {
  bash -c 'trap "" TERM; while :; do /bin/sleep 1; done' &
  TEST_SUBJECT_PID=$!
}

register_headless_fixture() {
  local team="$1" name="$2"
  bash "$SCRIPTS/join.sh" "$team" "$name" codex "$PROJ" >/dev/null
  printf 'pid=%s\nteam=%s\nname=%s\ntype=codex\n' \
    "$TEST_SUBJECT_PID" "$team" "$name" > "$RUN/codex-bridge.$team.$name.meta"
  printf 'pid:%s\t%s\tcodex\n' "$TEST_SUBJECT_PID" "$PROJ" \
    > "$RUN/spawn.${team}__${name}"
}

register_graceful_fixture() {
  local team="$1" name="$2" sid="$3"
  bash "$SCRIPTS/join.sh" "$team" "$name" claude-code "$PROJ" >/dev/null
  bash "$SCRIPTS/join.sh" "$team" leader claude-code "$PROJ" >/dev/null
  setup_live_owner "$RUN" "$sid"
  printf '%s\n' "$sid" > "$RUN/actas.${team}__${name}.session"
}

@test "despawn wait knob validation is bounded and independent" {
  local raw
  for raw in "" 0 -1 NaN 1..2 " 1" "1 " 1e2 0.001 60.01 .5 1.; do
    run agmsg_wait_knob_resolve "$raw" 1 0.01 60 decimal
    [ "$status" -eq 0 ]
    [ "$output" = 1 ]
  done
  for raw in "" 0 -1 NaN 1..2 " 1" "1 " 1e2 0.5 10001; do
    run agmsg_wait_knob_resolve "$raw" 5 1 10000 integer
    [ "$status" -eq 0 ]
    [ "$output" = 5 ]
  done
  run agmsg_wait_knob_resolve 0.125 1 0.01 60 decimal
  [ "$status" -eq 0 ]
  [ "$output" = 0.125 ]
  run agmsg_wait_knob_resolve 7 5 1 10000 integer
  [ "$status" -eq 0 ]
  [ "$output" = 7 ]
}

@test "force kill uses configured interval and max-count independently" {
  install_sleep_stub
  start_ignoring_subject
  register_headless_fixture kill-team interval-two
  run env PATH="$STUB_BIN:$PATH" AGMSG_KILL_POLL_INTERVAL=0.01 AGMSG_KILL_POLL_MAX=2 \
    bash "$SCRIPTS/despawn.sh" kill-team leader interval-two --force
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$WAIT_SLEEP_LOG" | tr -d ' ')" -eq 2 ]
  [ "$(sort -u "$WAIT_SLEEP_LOG")" = 0.01 ]
  ! kill -0 "$TEST_SUBJECT_PID" 2>/dev/null
  TEST_SUBJECT_PID=""

  : > "$WAIT_SLEEP_LOG"
  start_ignoring_subject
  register_headless_fixture kill-team interval-five
  run env PATH="$STUB_BIN:$PATH" AGMSG_KILL_POLL_INTERVAL=0.01 AGMSG_KILL_POLL_MAX=1.2 \
    bash "$SCRIPTS/despawn.sh" kill-team leader interval-five --force
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$WAIT_SLEEP_LOG" | tr -d ' ')" -eq 5 ]
  [ "$(sort -u "$WAIT_SLEEP_LOG")" = 0.01 ]
  ! kill -0 "$TEST_SUBJECT_PID" 2>/dev/null
  TEST_SUBJECT_PID=""
}

@test "graceful wait keeps timeout in seconds while using fractional polling" {
  install_sleep_stub
  install_date_stub
  register_graceful_fixture wait-team timeout-one sess-timeout
  run env PATH="$STUB_BIN:$PATH" AGMSG_DESPAWN_WAIT_POLL_INTERVAL=0.05 \
    bash "$SCRIPTS/despawn.sh" wait-team leader timeout-one --timeout 1
  [ "$status" -eq 3 ]
  [[ "$output" == *"status=timeout name=timeout-one team=wait-team after=1s"* ]]
  [ "$(cat "$WAIT_SLEEP_LOG")" = 0.05 ]
}

@test "graceful wait returns early and reports verified elapsed seconds" {
  install_sleep_stub
  install_date_stub
  register_graceful_fixture wait-team early-success sess-early
  export WAIT_RELEASE_PATH="$RUN/actas.wait-team__early-success.session"
  run env PATH="$STUB_BIN:$PATH" AGMSG_DESPAWN_WAIT_POLL_INTERVAL=0.02 \
    bash "$SCRIPTS/despawn.sh" wait-team leader early-success --timeout 10
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=ok name=early-success team=wait-team after=1s"* ]]
  [ "$(cat "$WAIT_SLEEP_LOG")" = 0.02 ]
}

@test "graceful wait resets backward clocks and fails safely on clock errors" {
  install_sleep_stub
  install_date_stub
  export WAIT_DATE_MODE=backward
  register_graceful_fixture wait-team backward-clock sess-backward
  run env PATH="$STUB_BIN:$PATH" AGMSG_DESPAWN_WAIT_POLL_INTERVAL=0.02 \
    bash "$SCRIPTS/despawn.sh" wait-team leader backward-clock --timeout 1
  [ "$status" -eq 3 ]
  [[ "$output" == *"status=timeout name=backward-clock team=wait-team after=1s"* ]]
  [ "$(wc -l < "$WAIT_SLEEP_LOG" | tr -d ' ')" -eq 2 ]
  [ "$(sort -u "$WAIT_SLEEP_LOG")" = 0.02 ]

  : > "$WAIT_SLEEP_LOG"
  printf '0\n' > "$WAIT_DATE_COUNT"
  export WAIT_DATE_MODE=error
  register_graceful_fixture wait-team clock-error sess-error
  run env PATH="$STUB_BIN:$PATH" AGMSG_DESPAWN_WAIT_POLL_INTERVAL=0.02 \
    bash "$SCRIPTS/despawn.sh" wait-team leader clock-error --timeout 10
  [ "$status" -eq 3 ]
  [[ "$output" == *"status=timeout name=clock-error team=wait-team after=0s"* ]]
  [ ! -s "$WAIT_SLEEP_LOG" ]
}

# bats test_tags=slow
@test "unset knobs retain the default five real one-second kill polls" {
  start_ignoring_subject
  register_headless_fixture slow-team default-five
  local started ended elapsed
  started="$(date +%s)"
  run env -u AGMSG_KILL_POLL_INTERVAL -u AGMSG_KILL_POLL_MAX \
    -u AGMSG_DESPAWN_WAIT_POLL_INTERVAL \
    bash "$SCRIPTS/despawn.sh" slow-team leader default-five --force
  ended="$(date +%s)"
  elapsed=$((ended - started))
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=forced name=default-five team=slow-team"* ]]
  [ "$elapsed" -ge 5 ]
  ! kill -0 "$TEST_SUBJECT_PID" 2>/dev/null
  TEST_SUBJECT_PID=""
}
