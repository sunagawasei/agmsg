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

# --- check-inbox.sh ------------------------------------------------------

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
