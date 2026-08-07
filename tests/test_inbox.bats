#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
  bash "$SCRIPTS/join.sh" testteam alice claude-code /tmp/project-a
  bash "$SCRIPTS/join.sh" testteam bob claude-code /tmp/project-a
  BARRIER="$TEST_SKILL_DIR/mark-barrier"
}

teardown() {
  teardown_test_env
}

# Counts unread via the storage facade (send.sh now writes the event log, not
# the legacy messages table's read_at column — a raw "read_at IS NULL" count
# would silently always read 0 post-flip and never catch a real regression).
unread_count() {
  bash -c '
    source "'"$SCRIPTS"'/lib/storage.sh"
    agmsg_storage_load
    storage_list_unread testteam "$1"
  ' _ "$1" | grep -c .
}

# Wait until the script under test has displayed and is paused before its
# mark UPDATE (barrier .reached appears), with a bounded wait.
await_barrier_reached() {
  wait_for_file "$BARRIER.reached"
}

# --- inbox.sh -----------------------------------------------------------

@test "inbox: displays unread messages and marks exactly those as read" {
  bash "$SCRIPTS/send.sh" testteam bob alice "first"
  bash "$SCRIPTS/send.sh" testteam bob alice "second"
  run bash "$SCRIPTS/inbox.sh" testteam alice
  [ "$status" -eq 0 ]
  [[ "$output" == *"2 new message(s):"* ]]
  [[ "$output" == *"first"* ]]
  [[ "$output" == *"second"* ]]
  [ "$(unread_count alice)" -eq 0 ]
}

@test "inbox: --quiet is silent when there is nothing unread" {
  run bash "$SCRIPTS/inbox.sh" testteam alice --quiet
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "inbox: a message arriving between display and mark is NOT marked read unseen" {
  bash "$SCRIPTS/send.sh" testteam bob alice "early"
  # Pause the run between display and mark, land a message inside the window,
  # then release. With the old blanket "WHERE read_at IS NULL" mark, the late
  # message was silently marked read without ever having been displayed.
  AGMSG_TEST_MARK_BARRIER="$BARRIER" bash "$SCRIPTS/inbox.sh" testteam alice > "$TEST_SKILL_DIR/first-run.out" 3>&- &
  bg_pid=$!
  await_barrier_reached
  bash "$SCRIPTS/send.sh" testteam bob alice "late"
  : > "$BARRIER.release"
  wait "$bg_pid"
  run cat "$TEST_SKILL_DIR/first-run.out"
  [[ "$output" == *"early"* ]]
  [[ "$output" != *"late"* ]]
  # The late message must still be unread…
  [ "$(unread_count alice)" -eq 1 ]
  # …and surface on the next check
  run bash "$SCRIPTS/inbox.sh" testteam alice
  [ "$status" -eq 0 ]
  [[ "$output" == *"late"* ]]
  [ "$(unread_count alice)" -eq 0 ]
}


# Make ONE team's store unreadable without touching any other team's.
#
# Teams share a single store until they are partitioned, so corrupting the file
# a team resolves to by default breaks every team at once -- and then the FIRST
# team fails, which is the harmless case, not the one under test. Switching this
# team to its own partition first is what makes the failure land where the
# defect needs it: after an earlier team has already been marked read.
_break_only_this_teams_store() {
  local team="$1" cfg="$TEST_SKILL_DIR/teams/$1/config.json" updated db
  updated="$(sqlite_mem "SELECT json_set(CAST(readfile('$(rf "$cfg")') AS TEXT), '\$.drivers.partition', 'per-team');")"
  printf '%s' "$updated" > "$cfg"
  db="$(cd "$TEST_SKILL_DIR" && bash -c '. scripts/lib/storage.sh; agmsg_storage_load; agmsg_db_path '"$team" 2>/dev/null)"
  [ -n "$db" ] || return 1
  mkdir -p "$(dirname "$db")"
  printf 'not a database' > "$db"
}

# --- check-inbox.sh ------------------------------------------------------

@test "check-inbox: a later team's query failure does not lose earlier teams' messages (#637)" {
  # alice is in two teams; glob order enumerates testteam before zteam.
  bash "$SCRIPTS/join.sh" zteam alice claude-code /tmp/project-a
  bash "$SCRIPTS/join.sh" zteam bob claude-code /tmp/project-a
  bash "$SCRIPTS/send.sh" testteam bob alice "early"
  bash "$SCRIPTS/send.sh" zteam bob alice "in-zteam"

  # PATH shim: fail (SQLITE_BUSY-style rc=5) exactly the unread SELECT for the
  # second team; everything else passes through to the real sqlite3. testteam's
  # messages are read_at-stamped inside the loop before zteam is queried, so
  # without the loop-failure guard this abort loses them silently.
  REAL_SQLITE3="$(command -v sqlite3)"
  mkdir -p "$TEST_SKILL_DIR/shim"
  cat > "$TEST_SKILL_DIR/shim/sqlite3" <<SHIM
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in
    *"team='zteam'"*"read_at IS NULL"*) exit 5 ;;
  esac
done
exec "$REAL_SQLITE3" "\$@"
SHIM
  chmod +x "$TEST_SKILL_DIR/shim/sqlite3"

  run env PATH="$TEST_SKILL_DIR/shim:$PATH" \
    bash "$SCRIPTS/check-inbox.sh" claude-code /tmp/project-a < /dev/null
  # testteam's message was already marked read when zteam failed — it MUST
  # still have been emitted, or it is lost forever (never re-offered).
  [[ "$output" == *"early"* ]]
  [[ "$output" != *"in-zteam"* ]]
  # The failure is not swallowed: the loop's status is re-raised on exit.
  [ "$status" -eq 5 ]
  # testteam delivered-and-read; zteam untouched, so its message re-surfaces.
  [ "$(unread_count alice)" -eq 0 ]
  [ "$(sqlite3 "$DBPATH" "SELECT COUNT(*) FROM messages WHERE team='zteam' AND to_agent='alice' AND read_at IS NULL;" | tr -d '\r')" -eq 1 ]
}

@test "check-inbox: a message arriving between display and mark is NOT marked read unseen" {
  bash "$SCRIPTS/send.sh" testteam bob alice "early"
  AGMSG_TEST_MARK_BARRIER="$BARRIER" bash "$SCRIPTS/check-inbox.sh" claude-code /tmp/project-a > "$TEST_SKILL_DIR/check-run.out" 2>/dev/null 3>&- &
  bg_pid=$!
  await_barrier_reached
  bash "$SCRIPTS/send.sh" testteam bob alice "late"
  : > "$BARRIER.release"
  wait "$bg_pid" || true
  run cat "$TEST_SKILL_DIR/check-run.out"
  [[ "$output" == *"early"* ]]
  [[ "$output" != *"late"* ]]
  # The late message was not silently marked read by the first run
  [ "$(unread_count alice)" -eq 1 ]
}
