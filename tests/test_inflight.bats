#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
  export SKILL_DIR="$TEST_SKILL_DIR"
  export RUN="$TEST_SKILL_DIR/run"
  export PROJ="$TEST_SKILL_DIR/project"
  mkdir -p "$RUN" "$PROJ"
  bash "$SCRIPTS/join.sh" team worker codex "$PROJ" >/dev/null
  bash "$SCRIPTS/join.sh" team alice codex "$PROJ" >/dev/null
  # shellcheck disable=SC1091
  source "$SCRIPTS/lib/inflight.sh"
}

teardown() {
  teardown_test_env
}

write_consumers() {
  local path="$1"
  printf 'alice\t%s\n' "$2" > "$path"
}

start_bridge() {
  test_fixture_start_reaped_process sleep 300
  BRIDGE_PID="$TEST_REAPED_PID"
  BRIDGE_START="$(agmsg_pid_start_token "$BRIDGE_PID")"
}

ipath() {
  agmsg_inflight_path team worker "$1" "$BRIDGE_START"
}

unread_count() {
  sqlite3 "$TEST_SKILL_DIR/db/messages.db" \
    "SELECT COUNT(*) FROM messages WHERE team='team' AND to_agent='worker' AND read_at IS NULL;"
}

alice_notices() {
  sqlite3 "$TEST_SKILL_DIR/db/messages.db" \
    "SELECT body FROM messages WHERE team='team' AND to_agent='alice' AND from_agent='worker';"
}

@test "inflight write then settle removes the record without notifying" {
  start_bridge
  local mid consumers="$RUN/consumers"
  bash "$SCRIPTS/send.sh" team alice worker "please do this" >/dev/null
  mid="$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT id FROM messages WHERE team='team' AND to_agent='worker';")"
  write_consumers "$consumers" "$mid"
  agmsg_inflight_write team worker codex 1 "$BRIDGE_PID" "$BRIDGE_START" "$consumers"
  [ -f "$(ipath 1)" ]
  agmsg_inflight_settle team worker 1 "$BRIDGE_START"
  [ ! -f "$(ipath 1)" ]
  [ -z "$(alice_notices)" ]
}

@test "inflight epochs coexist and the first reply does not clobber the other" {
  start_bridge
  write_consumers "$RUN/c1" "11"
  write_consumers "$RUN/c2" "22"
  agmsg_inflight_write team worker codex 1 "$BRIDGE_PID" "$BRIDGE_START" "$RUN/c1"
  agmsg_inflight_write team worker codex 2 "$BRIDGE_PID" "$BRIDGE_START" "$RUN/c2"
  [ -f "$(ipath 1)" ]
  [ -f "$(ipath 2)" ]
  agmsg_inflight_settle team worker 1 "$BRIDGE_START"
  [ ! -f "$(ipath 1)" ]
  [ -f "$(ipath 2)" ]
}

@test "reap retains a live same-generation in-flight record and does not notify" {
  start_bridge
  write_consumers "$RUN/c" "7"
  agmsg_inflight_write team worker codex 1 "$BRIDGE_PID" "$BRIDGE_START" "$RUN/c"
  agmsg_inflight_reap_dead
  [ -f "$(ipath 1)" ]
  [ -z "$(alice_notices)" ]
  kill -0 "$BRIDGE_PID"
}

@test "gc_team retains live same-generation inflight and still dead-letters after death" {
  start_bridge
  write_consumers "$RUN/c" "8"
  agmsg_inflight_write team worker codex 1 "$BRIDGE_PID" "$BRIDGE_START" "$RUN/c"
  run agmsg_inflight_gc_team team
  [ "$status" -ne 0 ]
  [ -f "$(ipath 1)" ]
  [ -z "$(alice_notices)" ]
  kill "$BRIDGE_PID" 2>/dev/null || true
  wait_until 5 _pid_gone "$BRIDGE_PID"
  agmsg_inflight_reap_dead
  [ ! -f "$(ipath 1)" ]
  [[ "$(alice_notices)" == *"(ids 8)"* ]]
}

@test "gc_team reaps a dead generation then allows team deletion" {
  start_bridge
  write_consumers "$RUN/c" "9"
  agmsg_inflight_write team worker codex 1 "$BRIDGE_PID" "$BRIDGE_START" "$RUN/c"
  kill "$BRIDGE_PID" 2>/dev/null || true
  wait_until 5 _pid_gone "$BRIDGE_PID"
  run agmsg_inflight_gc_team team
  [ "$status" -eq 0 ]
  [ ! -f "$(ipath 1)" ]
  [[ "$(alice_notices)" == *"(ids 9)"* ]]
}

@test "reap dead-letters a dead generation, leaves read_at set, and does not restore unread" {
  start_bridge
  local mid
  bash "$SCRIPTS/send.sh" team alice worker "doomed" >/dev/null
  mid="$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT id FROM messages WHERE team='team' AND to_agent='worker';")"
  bash "$SCRIPTS/inbox.sh" team worker --mark-read-ids "$mid" >/dev/null
  [ "$(unread_count)" -eq 0 ]
  write_consumers "$RUN/c" "$mid"
  agmsg_inflight_write team worker codex 3 "$BRIDGE_PID" "$BRIDGE_START" "$RUN/c"
  kill "$BRIDGE_PID" 2>/dev/null || true
  wait_until 5 _pid_gone "$BRIDGE_PID"
  agmsg_inflight_reap_dead
  [ ! -f "$(ipath 3)" ]
  [ "$(unread_count)" -eq 0 ]
  [[ "$(alice_notices)" == *"[bridge-error] codex turn interrupted (ids $mid)"* ]]
}

@test "dead-letter retry does not need a spawn record" {
  start_bridge
  write_consumers "$RUN/c" "9"
  agmsg_inflight_write team worker codex 1 "$BRIDGE_PID" "$BRIDGE_START" "$RUN/c"
  rm -f "$RUN/spawn.team__worker"
  kill "$BRIDGE_PID" 2>/dev/null || true
  wait_until 5 _pid_gone "$BRIDGE_PID"
  agmsg_inflight_reap_dead
  [[ "$(alice_notices)" == *"(ids 9)"* ]]
}

@test "confirmed despawn --force dead-letters outstanding in-flight" {
  start_bridge
  write_consumers "$RUN/c" "42"
  agmsg_inflight_write team worker codex 1 "$BRIDGE_PID" "$BRIDGE_START" "$RUN/c"
  printf 'pid:%s\t%s\tcodex\n' "$BRIDGE_PID" "$PROJ" > "$RUN/spawn.team__worker"
  printf 'pid=%s\n' "$BRIDGE_PID" > "$RUN/codex-bridge.team.worker.meta"
  run bash "$SCRIPTS/despawn.sh" team leader worker --force
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=forced"* ]]
  [ ! -f "$(ipath 1)" ]
  [[ "$(alice_notices)" == *"(ids 42)"* ]]
}

@test "identity-mismatch despawn does not dead-letter a live in-flight generation" {
  start_bridge
  write_consumers "$RUN/c" "5"
  agmsg_inflight_write team worker codex 1 "$BRIDGE_PID" "$BRIDGE_START" "$RUN/c"
  local rec method
  rec="$(printf 'pid:%s\t%s\tcodex' "$BRIDGE_PID" "$PROJ")"
  printf '%s\n' "$rec" > "$RUN/spawn.team__worker"
  printf 'pid=%s\n' "$BRIDGE_PID" > "$RUN/codex-bridge.team.worker.meta"
  method="${BRIDGE_START%%:*}"
  run bash "$SCRIPTS/despawn.sh" team leader worker --force \
    --expect-record "$rec" --expect-bridge-start "$method:not-this-generation"
  [ "$status" -eq 5 ]
  [[ "$output" == *"reason=bridge-generation-changed"* ]]
  kill -0 "$BRIDGE_PID"
  [ -f "$(ipath 1)" ]
  [ -z "$(alice_notices)" ]
}

@test "outbox delivers after send failure without depending on spawn" {
  start_bridge
  write_consumers "$RUN/c" "8"
  agmsg_inflight_write team worker codex 1 "$BRIDGE_PID" "$BRIDGE_START" "$RUN/c"
  kill "$BRIDGE_PID" 2>/dev/null || true
  wait_until 5 _pid_gone "$BRIDGE_PID"
  mv "$SCRIPTS/send.sh" "$SCRIPTS/send.sh.real"
  cat > "$SCRIPTS/send.sh" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
  chmod +x "$SCRIPTS/send.sh"
  agmsg_inflight_reap_dead
  [ -f "$(ipath 1)" ] || [ -d "$(agmsg_inflight_outbox_dir team worker)" ]
  mv "$SCRIPTS/send.sh.real" "$SCRIPTS/send.sh"
  chmod +x "$SCRIPTS/send.sh"
  agmsg_inflight_outbox_flush team worker || true
  agmsg_inflight_reap_dead
  [[ "$(alice_notices)" == *"(ids 8)"* ]]
}

@test "compensate still delivers after roster and old bridge spool are gone" {
  start_bridge
  write_consumers "$RUN/c" "8"
  agmsg_inflight_write team worker codex 1 "$BRIDGE_PID" "$BRIDGE_START" "$RUN/c"
  kill "$BRIDGE_PID" 2>/dev/null || true
  wait_until 5 _pid_gone "$BRIDGE_PID"
  rm -f "$TEST_SKILL_DIR/teams/team/config.json"
  printf '[]\n' > "$RUN/codex-bridge.team.worker.outbound.json"
  agmsg_inflight_reap_dead
  rm -f "$RUN/"*"-bridge.team.worker.outbound."* 2>/dev/null || true
  agmsg_inflight_outbox_flush team worker || true
  agmsg_inflight_reap_dead
  [[ "$(alice_notices)" == *"(ids 8)"* ]]
}

@test "CLI flush-outbox delivers under set -euo pipefail" {
  local dir
  dir="$(agmsg_inflight_outbox_dir team worker)"
  mkdir -p "$dir"
  printf 'alice' > "$dir/queued.to"
  printf '[bridge-error] cli flush (ids 8): notice' > "$dir/queued.body"
  run bash "$SCRIPTS/inflight.sh" flush-outbox team worker
  [ "$status" -eq 0 ]
  [[ "$output" == *"inflight outbox delivered"* ]]
  [[ "$(alice_notices)" == *"(ids 8)"* ]]
  [ ! -e "$dir" ]
}

@test "same epoch from two generations coexists and does not overwrite" {
  start_bridge
  write_consumers "$RUN/c1" "1"
  agmsg_inflight_write team worker codex 1 "$BRIDGE_PID" "$BRIDGE_START" "$RUN/c1"
  local old_path old_pid old_start
  old_path="$(ipath 1)"
  old_pid="$BRIDGE_PID"
  old_start="$BRIDGE_START"
  # ps(1) lstart is second-granularity on macOS; same-second spawns share a token
  # and inflight paths collide (Linux proc starttime does not have this flake).
  while :; do
    start_bridge
    [ "$BRIDGE_START" != "$old_start" ] && break
    sleep 1
  done
  write_consumers "$RUN/c2" "2"
  agmsg_inflight_write team worker codex 1 "$BRIDGE_PID" "$BRIDGE_START" "$RUN/c2"
  [ -f "$old_path" ]
  [ -f "$(ipath 1)" ]
  [ "$old_path" != "$(ipath 1)" ]
  agmsg_inflight_read "$old_path"
  [ "${AGMSG_INFLIGHT_IDS[0]}" = "1" ]
  agmsg_inflight_read "$(ipath 1)"
  [ "${AGMSG_INFLIGHT_IDS[0]}" = "2" ]
  kill "$old_pid" 2>/dev/null || true
  wait_until 5 _pid_gone "$old_pid"
  agmsg_inflight_reap_dead
  [ ! -f "$old_path" ]
  [ -f "$(ipath 1)" ]
  [[ "$(alice_notices)" == *"(ids 1)"* ]]
  [[ "$(alice_notices)" != *"(ids 2)"* ]]
}

@test "write refuses to clobber an existing generation epoch" {
  start_bridge
  write_consumers "$RUN/c" "3"
  agmsg_inflight_write team worker codex 1 "$BRIDGE_PID" "$BRIDGE_START" "$RUN/c"
  write_consumers "$RUN/c2" "4"
  run agmsg_inflight_write team worker codex 1 "$BRIDGE_PID" "$BRIDGE_START" "$RUN/c2"
  [ "$status" -ne 0 ]
  agmsg_inflight_read "$(ipath 1)"
  [ "${AGMSG_INFLIGHT_IDS[0]}" = "3" ]
}

@test "write rejects more senders than the record can round-trip" {
  start_bridge
  local i consumers="$RUN/many"
  : > "$consumers"
  i=1
  while [ "$i" -le 32 ]; do
    printf 'alice-%s\t%s\n' "$i" "$i" >> "$consumers"
    i=$((i + 1))
  done
  run agmsg_inflight_write team worker codex 1 "$BRIDGE_PID" "$BRIDGE_START" "$consumers"
  [ "$status" -ne 0 ]
  [ ! -f "$(ipath 1)" ]
}

@test "unread-count treats a missing DB as unverifiable, not zero unread" {
  rm -f "$TEST_SKILL_DIR/db/messages.db"
  run bash "$SCRIPTS/inflight.sh" unread-count team worker 1
  [ "$status" -eq 2 ]
  ! [[ "$(printf '%s' "$output" | tr -d '\r\n')" =~ ^[0-9]+$ ]]
}

@test "unread-count refuses malformed ids without reporting a count" {
  run bash "$SCRIPTS/inflight.sh" unread-count team worker "1,"
  [ "$status" -eq 2 ]
  ! [[ "$(printf '%s' "$output" | tr -d '\r\n')" =~ ^[0-9]+$ ]]
}

@test "unread-count reports zero only after a verified mark-read" {
  local mid
  bash "$SCRIPTS/send.sh" team alice worker "please do this" >/dev/null
  mid="$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT id FROM messages WHERE team='team' AND to_agent='worker';")"
  run bash "$SCRIPTS/inflight.sh" unread-count team worker "$mid"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
  bash "$SCRIPTS/inbox.sh" team worker --mark-read-ids "$mid" >/dev/null
  run bash "$SCRIPTS/inflight.sh" unread-count team worker "$mid"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}
