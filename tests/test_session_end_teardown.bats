#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
  export SKILL_DIR="$TEST_SKILL_DIR"
  export RUN="$TEST_SKILL_DIR/run"
  export SESSION_ID="teardown-session"
  export STEAM="s-$SESSION_ID"
  export PROJ="/tmp/agmsg-session-end-teardown"
  export TEST_PIDS=""
  mkdir -p "$RUN"
  bash "$SCRIPTS/config.sh" set delivery.session_team true >/dev/null
  # shellcheck disable=SC1090
  source "$SCRIPTS/lib/actas-lock.sh"
}

teardown() {
  local pid
  for pid in $TEST_PIDS; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  teardown_test_env
}

start_headless() {
  local name="$1" type="$2" pid record
  sleep 300 &
  pid=$!
  TEST_PIDS="$TEST_PIDS $pid"
  record="$(printf 'pid:%s\t%s\t%s' "$pid" "$PROJ" "$type")"
  printf '%s\n' "$record" > "$(agmsg_spawn_path "$STEAM" "$name")"
  printf 'pid=%s\n' "$pid" > "$RUN/$type-bridge.$STEAM.$name.meta"
  HEADLESS_PID="$pid"
  HEADLESS_RECORD="$record"
}

write_snapshot_row() {
  local snapshot="$1" name="$2" record="$3"
  printf '%s\t%s\n' "$name" "$record" >> "$snapshot"
}

@test "session-end tears down every headless worker and preserves interactive records" {
  local codex_one_pid codex_two_pid cursor_pid
  start_headless "codex__one" codex
  codex_one_pid="$HEADLESS_PID"
  start_headless "codex two" codex
  codex_two_pid="$HEADLESS_PID"
  start_headless "カーソル 三" cursor
  cursor_pid="$HEADLESS_PID"

  printf '%%41\t%s\tclaude-code\n' "$PROJ" > "$(agmsg_spawn_path "$STEAM" "pane worker")"
  printf '@42\t%s\tclaude-code\n' "$PROJ" > "$(agmsg_spawn_path "$STEAM" "window worker")"
  printf 'herdr:wT:p43\t%s\tclaude-code\n' "$PROJ" > "$(agmsg_spawn_path "$STEAM" "herdr worker")"

  printf '{"session_id":"%s"}' "$SESSION_ID" \
    | bash "$SCRIPTS/session-end.sh" claude-code "$PROJ"

  wait_until 8 bash -c \
    "[ ! -e '$(agmsg_spawn_path "$STEAM" "codex__one")' ] &&
     [ ! -e '$(agmsg_spawn_path "$STEAM" "codex two")' ] &&
     [ ! -e '$(agmsg_spawn_path "$STEAM" "カーソル 三")' ]"

  run kill -0 "$codex_one_pid"
  [ "$status" -ne 0 ]
  run kill -0 "$codex_two_pid"
  [ "$status" -ne 0 ]
  run kill -0 "$cursor_pid"
  [ "$status" -ne 0 ]

  [ -f "$(agmsg_spawn_path "$STEAM" "pane worker")" ]
  [ -f "$(agmsg_spawn_path "$STEAM" "window worker")" ]
  [ -f "$(agmsg_spawn_path "$STEAM" "herdr worker")" ]
}

@test "session-end snapshot strips only the encoded-team prefix and decodes each name" {
  local capture="$TEST_SKILL_DIR/snapshot-capture" encoded_name
  encoded_name="$(_actas_lock_encode 'worker__二 号')"
  printf 'pid:101\t%s\tcodex\n' "$PROJ" \
    > "$RUN/spawn.$(_actas_lock_encode "$STEAM")__$encoded_name"

  mv "$SCRIPTS/session-end-worker.sh" "$SCRIPTS/session-end-worker.sh.real"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "argc=%s\nsnapshot=%s\n" "$#" "$5" > "$CAPTURE"' \
    'cat "$5" >> "$CAPTURE"' \
    'exit 0' > "$SCRIPTS/session-end-worker.sh"
  chmod +x "$SCRIPTS/session-end-worker.sh"

  CAPTURE="$capture" printf '{"session_id":"%s"}' "$SESSION_ID" \
    | env CAPTURE="$capture" bash "$SCRIPTS/session-end.sh" claude-code "$PROJ"
  wait_for_file_contains "$capture" "worker__二 号"

  grep -q '^argc=5$' "$capture"
  grep -q "^snapshot=$RUN/.session-end-snapshot\\." "$capture"
  grep -q "$(printf '^worker__二 号\tpid:101\t%s\tcodex$' "$PROJ")" "$capture"
}

@test "one nonzero despawn does not stop later snapshot rows" {
  local snapshot="$RUN/nonzero.snapshot" calls="$TEST_SKILL_DIR/despawn-calls"
  write_snapshot_row "$snapshot" bad \
    "$(printf 'pid:not-a-number\t%s\tcodex' "$PROJ")"
  write_snapshot_row "$snapshot" good \
    "$(printf 'pid:202\t%s\tcursor' "$PROJ")"

  mv "$SCRIPTS/despawn.sh" "$SCRIPTS/despawn.sh.real"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "%s\n" "$3" >> "$DESPAWN_CALLS"' \
    '[ "$3" = bad ] && exit 7' \
    'exit 0' > "$SCRIPTS/despawn.sh"
  chmod +x "$SCRIPTS/despawn.sh"

  run env DESPAWN_CALLS="$calls" bash "$SCRIPTS/session-end-worker.sh" \
    claude-code "$PROJ" "$SESSION_ID" "$SESSION_ID" "$snapshot"
  [ "$status" -eq 0 ]
  [ "$(sed -n '1p' "$calls")" = bad ]
  [ "$(sed -n '2p' "$calls")" = good ]
}

@test "a per-worker record mismatch leaves that worker but reaps matching peers" {
  local survivor_pid survivor_live peer_pid peer_record snapshot="$RUN/mismatch.snapshot"
  start_headless survivor codex
  survivor_pid="$HEADLESS_PID"
  survivor_live="$HEADLESS_RECORD"
  start_headless peer cursor
  peer_pid="$HEADLESS_PID"
  peer_record="$HEADLESS_RECORD"

  write_snapshot_row "$snapshot" survivor \
    "$(printf 'pid:%s\t/old/project\tcodex' "$survivor_pid")"
  write_snapshot_row "$snapshot" peer "$peer_record"

  run bash "$SCRIPTS/session-end-worker.sh" \
    claude-code "$PROJ" "$SESSION_ID" "$SESSION_ID" "$snapshot"
  [ "$status" -eq 0 ]

  kill -0 "$survivor_pid" 2>/dev/null
  [ "$(cat "$(agmsg_spawn_path "$STEAM" survivor)")" = "$survivor_live" ]
  run kill -0 "$peer_pid"
  [ "$status" -ne 0 ]
  [ ! -e "$(agmsg_spawn_path "$STEAM" peer)" ]
}

@test "missing and empty snapshots are no-op" {
  local worker_pid worker_record empty="$RUN/empty.snapshot"
  start_headless untouched codex
  worker_pid="$HEADLESS_PID"
  worker_record="$HEADLESS_RECORD"
  : > "$empty"

  run bash "$SCRIPTS/session-end-worker.sh" \
    claude-code "$PROJ" "$SESSION_ID" "$SESSION_ID" "$empty"
  [ "$status" -eq 0 ]
  kill -0 "$worker_pid" 2>/dev/null
  [ "$(cat "$(agmsg_spawn_path "$STEAM" untouched)")" = "$worker_record" ]

  run bash "$SCRIPTS/session-end-worker.sh" \
    claude-code "$PROJ" "$SESSION_ID" "$SESSION_ID" "$RUN/missing.snapshot"
  [ "$status" -eq 0 ]
  kill -0 "$worker_pid" 2>/dev/null
  [ "$(cat "$(agmsg_spawn_path "$STEAM" untouched)")" = "$worker_record" ]
}

@test "a live sibling skips every snapshot row" {
  local worker_pid worker_record sibling snapshot="$RUN/sibling.snapshot"
  start_headless shared codex
  worker_pid="$HEADLESS_PID"
  worker_record="$HEADLESS_RECORD"
  write_snapshot_row "$snapshot" shared "$worker_record"

  sleep 300 &
  sibling=$!
  TEST_PIDS="$TEST_PIDS $sibling"
  printf '%s.%s\n' "$SESSION_ID" "$sibling" > "$RUN/cc-instance.$sibling"

  run bash "$SCRIPTS/session-end-worker.sh" \
    claude-code "$PROJ" "$SESSION_ID" "$SESSION_ID" "$snapshot"
  [ "$status" -eq 0 ]
  kill -0 "$worker_pid" 2>/dev/null
  [ "$(cat "$(agmsg_spawn_path "$STEAM" shared)")" = "$worker_record" ]
}
