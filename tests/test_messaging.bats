#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
  # Create a team and two agents
  bash "$SCRIPTS/join.sh" testteam alice claude-code /tmp/project-a
  bash "$SCRIPTS/join.sh" testteam bob claude-code /tmp/project-b
}

teardown() {
  teardown_test_env
}

# --- send.sh ---

@test "send: delivers a message" {
  run bash "$SCRIPTS/send.sh" testteam alice bob "hello"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Sent to bob" ]]
}

@test "send: fails without required args" {
  run bash "$SCRIPTS/send.sh"
  [ "$status" -ne 0 ]
}

# --- inbox.sh ---

@test "inbox: shows no messages when empty" {
  run bash "$SCRIPTS/inbox.sh" testteam alice
  [ "$status" -eq 0 ]
  [[ "$output" =~ "No new messages" ]]
}

@test "inbox: shows received message" {
  bash "$SCRIPTS/send.sh" testteam alice bob "hello bob"
  run bash "$SCRIPTS/inbox.sh" testteam bob
  [ "$status" -eq 0 ]
  [[ "$output" =~ "hello bob" ]]
  [[ "$output" =~ "alice" ]]
}

@test "inbox: marks messages as read" {
  bash "$SCRIPTS/send.sh" testteam alice bob "read me"
  bash "$SCRIPTS/inbox.sh" testteam bob >/dev/null
  run bash "$SCRIPTS/inbox.sh" testteam bob
  [ "$status" -eq 0 ]
  [[ "$output" =~ "No new messages" ]]
}

@test "inbox: --quiet suppresses output when no messages" {
  run bash "$SCRIPTS/inbox.sh" testteam alice --quiet
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "inbox: --quiet shows output when messages exist" {
  bash "$SCRIPTS/send.sh" testteam bob alice "ping"
  run bash "$SCRIPTS/inbox.sh" testteam alice --quiet
  [ "$status" -eq 0 ]
  [[ "$output" =~ "ping" ]]
}

@test "inbox: handles multiline message body" {
  bash "$SCRIPTS/send.sh" testteam alice bob "line1
line2
line3"
  run bash "$SCRIPTS/inbox.sh" testteam bob
  [ "$status" -eq 0 ]
  [[ "$output" =~ "1 new message" ]]
  [[ "$output" =~ "alice" ]]
}

@test "history: handles multiline message body" {
  bash "$SCRIPTS/send.sh" testteam alice bob "multi
line"
  run bash "$SCRIPTS/history.sh" testteam
  [ "$status" -eq 0 ]
  [[ "$output" =~ "alice" ]]
  [[ "$output" =~ "bob" ]]
}

# --- history.sh ---

@test "history: shows message history" {
  bash "$SCRIPTS/send.sh" testteam alice bob "msg1"
  bash "$SCRIPTS/send.sh" testteam bob alice "msg2"
  run bash "$SCRIPTS/history.sh" testteam
  [ "$status" -eq 0 ]
  [[ "$output" =~ "msg1" ]]
  [[ "$output" =~ "msg2" ]]
}

@test "history: filters by agent" {
  bash "$SCRIPTS/send.sh" testteam alice bob "for bob"
  bash "$SCRIPTS/send.sh" testteam bob alice "for alice"
  run bash "$SCRIPTS/history.sh" testteam alice
  [ "$status" -eq 0 ]
  [[ "$output" =~ "for" ]]
}

@test "history: respects limit" {
  bash "$SCRIPTS/send.sh" testteam alice bob "msg1"
  bash "$SCRIPTS/send.sh" testteam alice bob "msg2"
  bash "$SCRIPTS/send.sh" testteam alice bob "msg3"
  # limit=1 should return exactly 1 line with arrow
  run bash "$SCRIPTS/history.sh" testteam "" 1
  [ "$status" -eq 0 ]
  local count=$(echo "$output" | grep -c "→")
  [ "$count" -eq 1 ]
}

@test "history: shows no history message when empty" {
  run bash "$SCRIPTS/history.sh" testteam
  [ "$status" -eq 0 ]
  [[ "$output" =~ "No message history" ]]
}

# --- send --stdin / inbox machine mode (headless bridge plumbing) ---

@test "send: --stdin reads the body from standard input" {
  printf 'line one\nline two with "quotes"' | bash "$SCRIPTS/send.sh" testteam alice bob --stdin
  run bash "$SCRIPTS/inbox.sh" testteam bob
  [ "$status" -eq 0 ]
  [[ "$output" == *"line one"* ]]
  [[ "$output" == *'line two with "quotes"'* ]]
}

@test "inbox: --format ids prints id-tagged rows and does NOT mark read" {
  bash "$SCRIPTS/send.sh" testteam alice bob "first"
  bash "$SCRIPTS/send.sh" testteam alice bob "second"
  run bash "$SCRIPTS/inbox.sh" testteam bob --format ids
  [ "$status" -eq 0 ]
  [[ "$output" == *"first"* ]]
  [[ "$output" == *"second"* ]]
  local n1; n1=$(printf '%s\n' "$output" | grep -c .)
  [ "$n1" -eq 2 ]
  # fetching again still returns both — nothing was marked read
  run bash "$SCRIPTS/inbox.sh" testteam bob --format ids
  local n2; n2=$(printf '%s\n' "$output" | grep -c .)
  [ "$n2" -eq 2 ]
}

@test "inbox: --mark-read-ids marks only the listed ids" {
  bash "$SCRIPTS/send.sh" testteam alice bob "keep-unread"   # id 1
  bash "$SCRIPTS/send.sh" testteam alice bob "ack-this"      # id 2
  bash "$SCRIPTS/inbox.sh" testteam bob --mark-read-ids 2
  run bash "$SCRIPTS/inbox.sh" testteam bob --format ids
  [[ "$output" == *"keep-unread"* ]]
  [[ "$output" != *"ack-this"* ]]
}

@test "inbox: --mark-read-ids rejects a non-numeric id list" {
  run bash "$SCRIPTS/inbox.sh" testteam bob --mark-read-ids "1;DROP TABLE messages"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "comma-separated list of message ids" ]]
}
