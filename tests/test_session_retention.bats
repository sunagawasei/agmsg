#!/usr/bin/env bats

# Message retention for finished session teams (docs/adr/0005): the TTL GC in
# session-start.sh removes the dir; lib/session-retention.sh removes the rows.

load test_helper

setup() {
  setup_test_env
  PROJ="/tmp/agmsg-retention-proj"
  export SKILL_DIR="$TEST_SKILL_DIR"
  DB="$TEST_SKILL_DIR/db/messages.db"
  mkdir -p "$TEST_SKILL_DIR/run"
  bash "$SCRIPTS/config.sh" set delivery.session_team true >/dev/null
  # shellcheck disable=SC1091
  source "$SCRIPTS/lib/actas-lock.sh"
  # shellcheck disable=SC1091
  source "$SCRIPTS/lib/pending-teardown.sh"
}

teardown() {
  teardown_test_env
}

run_session_start() {
  printf '{"session_id":"gc-current"}' \
    | bash "$SCRIPTS/session-start.sh" claude-code "$PROJ"
}

# make_team <team> [marked]: a dir old enough for the TTL GC.
make_team() {
  mkdir -p "$TEST_SKILL_DIR/teams/$1"
  printf '{"name":"%s","agents":{}}\n' "$1" > "$TEST_SKILL_DIR/teams/$1/config.json"
  if [ "${2:-}" = marked ]; then : > "$TEST_SKILL_DIR/teams/$1/session-team"; fi
  touch -t 202501010000 "$TEST_SKILL_DIR/teams/$1/config.json" "$TEST_SKILL_DIR/teams/$1"
  if [ "${2:-}" = marked ]; then touch -t 202501010000 "$TEST_SKILL_DIR/teams/$1/session-team"; fi
}

# seed_rows <team> <age_days> [count]: rows in events and the legacy mirror.
seed_rows() {
  local team="$1" age="$2" n="${3:-1}" i
  bash "$SCRIPTS/send.sh" "$team" a b seed --force >/dev/null
  for ((i = 1; i < n; i++)); do bash "$SCRIPTS/send.sh" "$team" a b "seed$i" --force >/dev/null; done
  sqlite3 "$DB" "UPDATE events SET at=strftime('%Y-%m-%dT%H:%M:%SZ','now','-$age days') WHERE team='$team';
                 UPDATE messages SET created_at=strftime('%Y-%m-%dT%H:%M:%SZ','now','-$age days') WHERE team='$team';"
}

rows() {
  sqlite3 "$DB" "SELECT (SELECT COUNT(*) FROM events WHERE team='$1') + (SELECT COUNT(*) FROM messages WHERE team='$1');"
}

@test "a marked team whose dir the TTL GC removes loses its old rows and leaves a tombstone" {
  make_team s-AAA-1 marked
  seed_rows s-AAA-1 30 2
  run run_session_start
  [ "$status" -eq 0 ]
  [ ! -d "$TEST_SKILL_DIR/teams/s-AAA-1" ]
  [ "$(rows s-AAA-1)" = 0 ]
  [ -f "$TEST_SKILL_DIR/run/session-tombstone.s-AAA-1" ]
}

@test "rows inside the window survive the dir GC and are deleted by a later sweep" {
  make_team s-AAA-2 marked
  seed_rows s-AAA-2 1
  run run_session_start
  [ "$status" -eq 0 ]
  [ "$(rows s-AAA-2)" != 0 ]
  [ -f "$TEST_SKILL_DIR/run/session-tombstone.s-AAA-2" ]
  sqlite3 "$DB" "UPDATE events SET at='2025-01-01T00:00:00Z' WHERE team='s-AAA-2'; UPDATE messages SET created_at='2025-01-01T00:00:00Z' WHERE team='s-AAA-2';"
  run run_session_start
  [ "$status" -eq 0 ]
  [ "$(rows s-AAA-2)" = 0 ]
  # the tombstone itself is not old yet, so it stays
  [ -f "$TEST_SKILL_DIR/run/session-tombstone.s-AAA-2" ]
  touch -t 202501010000 "$TEST_SKILL_DIR/run/session-tombstone.s-AAA-2"
  run run_session_start
  [ ! -f "$TEST_SKILL_DIR/run/session-tombstone.s-AAA-2" ]
}

@test "the delete is scoped by age: a row newer than the window stays" {
  make_team s-AAA-3 marked
  seed_rows s-AAA-3 30
  bash "$SCRIPTS/send.sh" s-AAA-3 a b fresh --force >/dev/null
  run run_session_start
  [ "$status" -eq 0 ]
  [ "$(sqlite3 "$DB" "SELECT COUNT(*) FROM messages WHERE team='s-AAA-3' AND body='fresh'")" = 1 ]
  [ "$(sqlite3 "$DB" "SELECT COUNT(*) FROM messages WHERE team='s-AAA-3' AND body='seed'")" = 0 ]
}

@test "an orphan with a tombstone loses its old rows" {
  seed_rows s-BBB-1 30
  : > "$TEST_SKILL_DIR/run/session-tombstone.s-BBB-1"
  run run_session_start
  [ "$status" -eq 0 ]
  [ "$(rows s-BBB-1)" = 0 ]
}

@test "a dir GC'd without a marker keeps its rows, and so does s-manual" {
  make_team s-CCC-1
  seed_rows s-CCC-1 30
  seed_rows s-manual 30
  run run_session_start
  [ "$status" -eq 0 ]
  [ ! -d "$TEST_SKILL_DIR/teams/s-CCC-1" ]
  [ "$(rows s-CCC-1)" != 0 ]
  [ "$(rows s-manual)" != 0 ]
  [ ! -f "$TEST_SKILL_DIR/run/session-tombstone.s-CCC-1" ]
}

@test "a failed rm -rf keeps the rows" {
  make_team s-DDD-1 marked
  seed_rows s-DDD-1 30
  mkdir "$TEST_SKILL_DIR/shim"
  printf '#!/bin/sh\ncase "$*" in *s-DDD-1*) exit 1 ;; esac\nexec /bin/rm "$@"\n' > "$TEST_SKILL_DIR/shim/rm"
  chmod +x "$TEST_SKILL_DIR/shim/rm"
  PATH="$TEST_SKILL_DIR/shim:$PATH" run run_session_start
  [ -d "$TEST_SKILL_DIR/teams/s-DDD-1" ]
  [ "$(rows s-DDD-1)" != 0 ]
  [ ! -f "$TEST_SKILL_DIR/run/session-tombstone.s-DDD-1" ]
}

@test "a failing delete rolls everything back and keeps the tombstone" {
  seed_rows s-EEE-1 30 2
  : > "$TEST_SKILL_DIR/run/session-tombstone.s-EEE-1"
  sqlite3 "$DB" "CREATE TRIGGER block_msg_delete BEFORE DELETE ON messages BEGIN SELECT RAISE(ABORT,'no'); END;"
  before="$(rows s-EEE-1)"
  run run_session_start
  [ "$status" -eq 0 ]
  [ "$(rows s-EEE-1)" = "$before" ]
  [ -f "$TEST_SKILL_DIR/run/session-tombstone.s-EEE-1" ]
}

@test "TTL GC removes cursor-bridge files of the reaped team" {
  make_team s-FFF-1 marked
  : > "$TEST_SKILL_DIR/run/cursor-bridge.s-FFF-1.cursor.log"
  : > "$TEST_SKILL_DIR/run/cursor-bridge.s-FFF-1.cursor.meta"
  run run_session_start
  [ "$status" -eq 0 ]
  [ ! -e "$TEST_SKILL_DIR/run/cursor-bridge.s-FFF-1.cursor.log" ]
  [ ! -e "$TEST_SKILL_DIR/run/cursor-bridge.s-FFF-1.cursor.meta" ]
}

# --- vetoes: the TTL dir GC and the row sweep must agree ---------------------

veto_case() {   # <kind>
  local kind="$1" team="s-VETO-$1"
  case "$kind" in
    live-bridge)
      sleep 300 & VETO_PID=$!
      printf 'pid:%s\t%s\tcodex\n' "$VETO_PID" "$PROJ" > "$TEST_SKILL_DIR/run/spawn.${team}__w"
      ;;
    unverified-placement)
      printf 'pid:not-a-number\t%s\tcodex\n' "$PROJ" > "$TEST_SKILL_DIR/run/spawn.${team}__w"
      ;;
    unverified-leading-zero)
      printf 'pid:007\t%s\tcodex\n' "$PROJ" > "$TEST_SKILL_DIR/run/spawn.${team}__w"
      ;;
    bare-owner-alive)
      sleep 300 & VETO_PID=$!
      printf '%s\n' "${team#s-}" > "$TEST_SKILL_DIR/run/cc-instance.$VETO_PID"
      ;;
  esac
  # TTL path: dir present and old
  make_team "$team" marked
  seed_rows "$team" 30
  run run_session_start
  [ "$status" -eq 0 ]
  [ -d "$TEST_SKILL_DIR/teams/$team" ]
  [ "$(rows "$team")" != 0 ]
  # sweep path: dir gone, tombstone present
  rm -rf "$TEST_SKILL_DIR/teams/$team"
  : > "$TEST_SKILL_DIR/run/session-tombstone.$team"
  run run_session_start
  [ "$status" -eq 0 ]
  [ "$(rows "$team")" != 0 ]
  if [ -n "${VETO_PID:-}" ]; then kill "$VETO_PID" 2>/dev/null || true; fi
}

@test "veto live-bridge: the dir and the rows stay" { veto_case live-bridge; }
@test "veto unverified-placement: the dir and the rows stay" { veto_case unverified-placement; }
@test "veto unverified-leading-zero: the dir and the rows stay" { veto_case unverified-leading-zero; }
@test "veto bare-owner-alive: the dir and the rows stay" { veto_case bare-owner-alive; }

@test "a live cursor bridge with no team dir keeps the rows" {
  sleep 300 & local pid=$!
  seed_rows s-VETO-cursor 30
  : > "$TEST_SKILL_DIR/run/session-tombstone.s-VETO-cursor"
  printf 'pid:%s\t%s\tcursor\n' "$pid" "$PROJ" > "$TEST_SKILL_DIR/run/spawn.s-VETO-cursor__reviewer"
  run run_session_start
  kill "$pid" 2>/dev/null || true
  [ "$(rows s-VETO-cursor)" != 0 ]
}

@test "a team dir that exists again is not swept" {
  seed_rows s-GGG-1 30
  : > "$TEST_SKILL_DIR/run/session-tombstone.s-GGG-1"
  mkdir -p "$TEST_SKILL_DIR/teams/s-GGG-1"
  run run_session_start
  [ "$(rows s-GGG-1)" != 0 ]
}

# --- marker ------------------------------------------------------------------

@test "session-start marks a session team dir that it created" {
  printf '{"session_id":"mark-1"}' | bash "$SCRIPTS/session-start.sh" claude-code "$PROJ" >/dev/null 2>&1 || true
  [ -f "$TEST_SKILL_DIR/teams/s-mark-1/session-team" ]
}

@test "session-start does not mark a team dir that already existed" {
  mkdir -p "$TEST_SKILL_DIR/teams/s-mark-2"
  printf '{"name":"s-mark-2","agents":{}}\n' > "$TEST_SKILL_DIR/teams/s-mark-2/config.json"
  printf '{"session_id":"mark-2"}' | bash "$SCRIPTS/session-start.sh" claude-code "$PROJ" >/dev/null 2>&1 || true
  [ ! -f "$TEST_SKILL_DIR/teams/s-mark-2/session-team" ]
}

@test "marker is written for a cursor session through the same path" {
  # cursor's plug reaches the shared join in session-start.sh (type.conf: session_team=yes)
  grep -q '^session_team=yes' "$SCRIPTS/drivers/types/cursor/type.conf"
  grep -q 'agmsg_retention_marker_path' "$SCRIPTS/session-start.sh"
}

# --- storage driver ----------------------------------------------------------

@test "a non-sqlite active storage driver leaves the sqlite rows alone" {
  seed_rows s-HHH-1 30
  : > "$TEST_SKILL_DIR/run/session-tombstone.s-HHH-1"
  AGMSG_STORAGE_DRIVER=fake-driver run run_session_start
  [ "$(rows s-HHH-1)" != 0 ]
}

# --- doctor ------------------------------------------------------------------

@test "doctor does not report a tombstone as an orphaned seat" {
  : > "$TEST_SKILL_DIR/run/session-tombstone.s-III-1"
  run bash "$SCRIPTS/doctor.sh"
  [[ "$output" != *"s-III-1"* ]]
}

# --- manual command ----------------------------------------------------------

@test "gc-session-orphans --dry-run deletes nothing" {
  seed_rows s-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee 30
  run bash "$SCRIPTS/gc-session-orphans.sh" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"would delete s-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"* ]]
  [ "$(rows s-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee)" != 0 ]
}

@test "gc-session-orphans --apply deletes only uuid-shaped, dir-less, vetoless teams with all rows old" {
  seed_rows s-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee 30
  seed_rows s-manual 30
  seed_rows s-11111111-2222-3333-4444-555555555555 30
  bash "$SCRIPTS/send.sh" s-11111111-2222-3333-4444-555555555555 a b fresh --force >/dev/null
  seed_rows s-99999999-2222-3333-4444-555555555555 30
  mkdir -p "$TEST_SKILL_DIR/teams/s-99999999-2222-3333-4444-555555555555"
  run bash "$SCRIPTS/gc-session-orphans.sh" --apply
  [ "$status" -eq 0 ]
  [ "$(rows s-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee)" = 0 ]
  [ "$(rows s-manual)" != 0 ]
  [ "$(rows s-11111111-2222-3333-4444-555555555555)" != 0 ]
  [ "$(rows s-99999999-2222-3333-4444-555555555555)" != 0 ]
}

@test "a tombstone does not authorise deleting a newer project team of the same name" {
  seed_rows s-JJJ-1 30
  : > "$TEST_SKILL_DIR/run/session-tombstone.s-JJJ-1"
  make_team s-JJJ-1
  run run_session_start
  [ ! -f "$TEST_SKILL_DIR/run/session-tombstone.s-JJJ-1" ]
  rm -rf "$TEST_SKILL_DIR/teams/s-JJJ-1"
  run run_session_start
  [ "$(rows s-JJJ-1)" != 0 ]
}

@test "strict delete keeps every row when one is inside the window" {
  seed_rows s-kkkkkkkk-bbbb-cccc-dddd-eeeeeeeeeeee 30
  bash "$SCRIPTS/send.sh" s-kkkkkkkk-bbbb-cccc-dddd-eeeeeeeeeeee a b fresh --force >/dev/null
  # shellcheck disable=SC1091
  source "$SCRIPTS/lib/storage.sh"; source "$SCRIPTS/lib/session-retention.sh"
  agmsg_retention_delete_rows s-kkkkkkkk-bbbb-cccc-dddd-eeeeeeeeeeee 7 strict
  [ "$(rows s-kkkkkkkk-bbbb-cccc-dddd-eeeeeeeeeeee)" = 4 ]
}

@test "gc-session-orphans --dry-run does not touch inflight records" {
  local t=s-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee rec
  seed_rows "$t" 30
  rec="$TEST_SKILL_DIR/run/inflight-record.$(_actas_lock_encode "$t")=x"
  printf 'garbage\n' > "$rec"
  run bash "$SCRIPTS/gc-session-orphans.sh" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"skip   $t (live-inflight)"* ]]
  [ -f "$rec" ]
  [ "$(rows "$t")" != 0 ]
}

@test "a reap whose tombstone vanished before the lock keeps the rows" {
  seed_rows s-KKK-1 30
  run bash -c '
    set -e
    SCRIPT_DIR="$1"; SKILL_DIR="$2"; RUN_DIR="$2/run"
    for l in compat actas-lock storage team-lifecycle instance-id process-identity pending-teardown inflight session-retention; do source "$SCRIPT_DIR/lib/$l.sh"; done
    agmsg_retention_reap_team s-KKK-1 || true
  ' _ "$SCRIPTS" "$TEST_SKILL_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *proof-gone* ]]
  [ "$(rows s-KKK-1)" != 0 ]
}

@test "join marks the team only when it creates config.json" {
  AGMSG_JOIN_MARK_SESSION_TEAM=1 AGMSG_RESOLVE_PROJECT=0 bash "$SCRIPTS/join.sh" s-LLL-1 claude claude-code "$PROJ" >/dev/null
  [ -f "$TEST_SKILL_DIR/teams/s-LLL-1/session-team" ]
  make_team s-LLL-2
  AGMSG_JOIN_MARK_SESSION_TEAM=1 AGMSG_RESOLVE_PROJECT=0 bash "$SCRIPTS/join.sh" s-LLL-2 claude claude-code "$PROJ" >/dev/null
  [ ! -f "$TEST_SKILL_DIR/teams/s-LLL-2/session-team" ]
}

@test "a sweep running while an unmarked dir is reaped cannot use the old tombstone" {
  seed_rows s-MMM-1 30
  : > "$TEST_SKILL_DIR/run/session-tombstone.s-MMM-1"
  make_team s-MMM-1
  mkdir "$TEST_SKILL_DIR/shim"
  cat > "$TEST_SKILL_DIR/shim/rm" <<SH
#!/bin/sh
case "\$*" in *teams/s-MMM-1*)
  /bin/rm "\$@"
  AGMSG_LIFECYCLE_LOCK_TIMEOUT=1 /bin/bash -c '
    SCRIPT_DIR="$SCRIPTS"; SKILL_DIR="$TEST_SKILL_DIR"; RUN_DIR="$TEST_SKILL_DIR/run"
    for l in compat actas-lock storage team-lifecycle instance-id process-identity pending-teardown inflight session-retention; do . "\$SCRIPT_DIR/lib/\$l.sh"; done
    agmsg_retention_sweep'
  exit 0 ;;
esac
exec /bin/rm "\$@"
SH
  chmod +x "$TEST_SKILL_DIR/shim/rm"
  PATH="$TEST_SKILL_DIR/shim:$PATH" run run_session_start
  [ ! -d "$TEST_SKILL_DIR/teams/s-MMM-1" ]
  [ ! -f "$TEST_SKILL_DIR/run/session-tombstone.s-MMM-1" ]
  [ "$(rows s-MMM-1)" != 0 ]
}

@test "an unmarked dir stays when its stale tombstone cannot be removed" {
  seed_rows s-NNN-1 30
  : > "$TEST_SKILL_DIR/run/session-tombstone.s-NNN-1"
  make_team s-NNN-1
  mkdir "$TEST_SKILL_DIR/shim"
  printf '#!/bin/sh\ncase "$*" in *session-tombstone.s-NNN-1*) exit 1 ;; esac\nexec /bin/rm "$@"\n' > "$TEST_SKILL_DIR/shim/rm"
  chmod +x "$TEST_SKILL_DIR/shim/rm"
  PATH="$TEST_SKILL_DIR/shim:$PATH" run run_session_start
  [ -d "$TEST_SKILL_DIR/teams/s-NNN-1" ]
  [ "$(rows s-NNN-1)" != 0 ]
}

@test "veto unverified-placement: a spawn record that cannot be read keeps the team" {
  [ "$(id -u)" -ne 0 ] || skip "root reads every file"
  local team=s-VETO-unread
  printf 'pid:1\t%s\tcodex\n' "$PROJ" > "$TEST_SKILL_DIR/run/spawn.${team}__w"
  chmod 000 "$TEST_SKILL_DIR/run/spawn.${team}__w"
  seed_rows "$team" 30
  : > "$TEST_SKILL_DIR/run/session-tombstone.$team"
  run run_session_start
  chmod 600 "$TEST_SKILL_DIR/run/spawn.${team}__w"
  [ "$status" -eq 0 ]
  [ "$(rows "$team")" != 0 ]
}
