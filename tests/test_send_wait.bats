#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
  export PROJ="/tmp/agmsg-send-wait-proj"
  bash "$SCRIPTS/join.sh" team alice codex "$PROJ" >/dev/null
  bash "$SCRIPTS/join.sh" team bob codex "$PROJ" >/dev/null
}

teardown() {
  teardown_test_env
}

@test "send: plain send is unchanged (no --wait, returns immediately)" {
  run bash "$SCRIPTS/send.sh" team alice bob "hello"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Sent to bob in team team" ]]
  # No wait status lines on the plain path.
  [[ ! "$output" =~ "status=" ]]
}

@test "send --wait: exits 2 on timeout when no reply arrives" {
  run bash "$SCRIPTS/send.sh" team alice bob "ping" --wait --timeout 1 --interval 1
  [ "$status" -eq 2 ]
  [[ "$output" =~ "Sent to bob in team team" ]]
  [[ "$output" =~ "status=timeout" ]]
}

@test "send --wait: returns the reply when <to> replies to <from>" {
  # bob replies shortly after alice begins waiting.
  ( sleep 1; bash "$SCRIPTS/send.sh" team bob alice "pong" >/dev/null ) &
  run bash "$SCRIPTS/send.sh" team alice bob "ping" --wait --timeout 5 --interval 1
  wait
  [ "$status" -eq 0 ]
  [[ "$output" =~ "status=reply" ]]
  [[ "$output" =~ "pong" ]]
  [[ "$output" =~ "bob → alice" ]]
}

@test "send --wait: ignores a message addressed to a different agent" {
  ( sleep 1; bash "$SCRIPTS/send.sh" team bob carol "not for alice" >/dev/null ) &
  run bash "$SCRIPTS/send.sh" team alice bob "ping" --wait --timeout 3 --interval 1
  wait
  [ "$status" -eq 2 ]
  [[ "$output" =~ "status=timeout" ]]
}

@test "send --wait: ignores a pre-existing message (reply must be newer than this send)" {
  # An older message from bob to alice exists before alice's --wait send. The
  # id-scoped wait must NOT match it, proving it waits for a fresh reply.
  bash "$SCRIPTS/send.sh" team bob alice "old message" >/dev/null
  run bash "$SCRIPTS/send.sh" team alice bob "ping" --wait --timeout 1 --interval 1
  [ "$status" -eq 2 ]
  [[ "$output" =~ "status=timeout" ]]
}

@test "send --wait: does not mark the reply read (inbox.sh stays the read cursor)" {
  ( sleep 1; bash "$SCRIPTS/send.sh" team bob alice "pong" >/dev/null ) &
  run bash "$SCRIPTS/send.sh" team alice bob "ping" --wait --timeout 5 --interval 1
  wait
  [ "$status" -eq 0 ]
  [[ "$output" =~ "pong" ]]
  # The reply must still be unread for alice's inbox — --wait never consumes it.
  run bash "$SCRIPTS/inbox.sh" team alice --quiet
  [ "$status" -eq 0 ]
  [[ "$output" =~ "pong" ]]
}

@test "send --wait: returns a reply containing quotes and emoji intact" {
  ( sleep 1; bash "$SCRIPTS/send.sh" team bob alice 'done "ok" 確認 🚀' >/dev/null ) &
  run bash "$SCRIPTS/send.sh" team alice bob "ping" --wait --timeout 5 --interval 1
  wait
  [ "$status" -eq 0 ]
  [[ "$output" == *'done "ok" 確認 🚀'* ]]
}

@test "send --wait: flattens newlines in the reply to a single line" {
  ( sleep 1; bash "$SCRIPTS/send.sh" team bob alice $'line1\nline2' >/dev/null ) &
  run bash "$SCRIPTS/send.sh" team alice bob "ping" --wait --timeout 5 --interval 1
  wait
  [ "$status" -eq 0 ]
  # char(10) is rendered as a literal backslash-n so the reply stays one line.
  [[ "$output" == *'line1\nline2'* ]]
}

@test "send: rejects an unknown option" {
  run bash "$SCRIPTS/send.sh" team alice bob "ping" --bogus
  [ "$status" -ne 0 ]
  [[ "$output" =~ "unknown option" ]]
}
