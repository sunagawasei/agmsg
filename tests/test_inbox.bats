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

@test "check-inbox: a later team's failure does not swallow an earlier team's messages (#637)" {
  # Marking happens inside the loop; emitting happens after it. Under set -e an
  # unguarded substitution ended the script the moment a LATER team failed --
  # after an EARLIER team's rows were stamped read_at and before either emit
  # point. Those messages were read, undelivered, and never offered again.
  #
  # The failing team is named to sort AFTER the one holding the message: the
  # loop walks teams in order, and the whole defect is a failure that lands
  # after an earlier team was already marked read. A name that sorted first
  # would fail before anything was accumulated -- a different, harmless case.
  bash "$SCRIPTS/join.sh" zzlastteam alice claude-code /tmp/project-a >/dev/null
  bash "$SCRIPTS/send.sh" testteam bob alice "first team message" >/dev/null
  _break_only_this_teams_store zzlastteam

  run bash "$SCRIPTS/check-inbox.sh" claude-code /tmp/project-a </dev/null

  # The failure is still reported -- this is not "carry on regardless".
  [ "$status" -ne 0 ]
  # And the message that was marked read reached the operator.
  [[ "$output" == *"first team message"* ]]
}

@test "check-inbox: a failure with nothing accumulated does not report 'no new messages' (#637)" {
  # The quieter half of the same lie. A loop that stopped before accumulating
  # anything has not established that there is nothing to deliver -- only that
  # it could not look. Exiting 0 with "no new messages" tells the hook runtime
  # the turn was clean.
  bash "$SCRIPTS/join.sh" zzlastteam alice claude-code /tmp/project-a >/dev/null
  _break_only_this_teams_store zzlastteam

  run bash "$SCRIPTS/check-inbox.sh" claude-code /tmp/project-a </dev/null
  [ "$status" -ne 0 ]
  [[ "$output" != *"no new messages"* ]]
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
