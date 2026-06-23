#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
  export PROJECT_ALICE="$BATS_TEST_TMPDIR/project-alice"
  export PROJECT_BOB="$BATS_TEST_TMPDIR/project-bob"
  export PROJECT_MULTI="$BATS_TEST_TMPDIR/project-multi"
  mkdir -p "$PROJECT_ALICE" "$PROJECT_BOB" "$PROJECT_MULTI"
  bash "$SCRIPTS/join.sh" demo alice codex "$PROJECT_ALICE"
  bash "$SCRIPTS/join.sh" demo bob codex "$PROJECT_BOB"
}

teardown() {
  teardown_test_env
}

@test "dispatch: explicit team and agent can check inbox" {
  run bash "$SCRIPTS/windows/dispatch.sh" --type codex --project "$PROJECT_BOB" --team demo --agent bob -- inbox
  [ "$status" -eq 0 ]
  [[ "$output" =~ "No new messages." ]]
}

@test "dispatch: environment team and agent can check inbox" {
  run env AGMSG_TEAM=demo AGMSG_AGENT=bob bash "$SCRIPTS/windows/dispatch.sh" --type codex --project "$PROJECT_BOB" -- inbox
  [ "$status" -eq 0 ]
  [[ "$output" =~ "No new messages." ]]
}

@test "dispatch: whoami single identity resolves inbox" {
  run bash "$SCRIPTS/windows/dispatch.sh" --type codex --project "$PROJECT_ALICE" -- inbox
  [ "$status" -eq 0 ]
  [[ "$output" =~ "No new messages." ]]
}

@test "dispatch: multiple identity stops without choosing" {
  bash "$SCRIPTS/join.sh" many first codex "$PROJECT_MULTI"
  bash "$SCRIPTS/join.sh" many second codex "$PROJECT_MULTI"

  run bash "$SCRIPTS/windows/dispatch.sh" --type codex --project "$PROJECT_MULTI" -- inbox
  [ "$status" -eq 2 ]
  [[ "$output" =~ "multiple=true" ]]
  [[ "$output" =~ "agmsg -Team <team> -Agent <agent> inbox" ]]
}

@test "dispatch: send then history preserves Japanese, quotes, and emoji" {
  local message='確認しました "quoted" emoji 🚀'
  run bash "$SCRIPTS/windows/dispatch.sh" --type codex --project "$PROJECT_ALICE" --team demo --agent alice -- send bob "$message"
  [ "$status" -eq 0 ]

  run bash "$SCRIPTS/windows/dispatch.sh" --type codex --project "$PROJECT_ALICE" --team demo -- history
  [ "$status" -eq 0 ]
  [[ "$output" =~ "$message" ]]
}

@test "dispatch: ask blocks then times out (exit 2) when no reply arrives" {
  run bash "$SCRIPTS/windows/dispatch.sh" --type codex --project "$PROJECT_ALICE" --team demo --agent alice -- ask bob "ping" --timeout 1 --interval 1
  [ "$status" -eq 2 ]
  [[ "$output" =~ "Sent to bob in team demo" ]]
  [[ "$output" =~ "status=timeout" ]]
}

@test "dispatch: ask returns the reply when bob replies to alice" {
  ( sleep 1; bash "$SCRIPTS/send.sh" demo bob alice "pong" >/dev/null ) &
  run bash "$SCRIPTS/windows/dispatch.sh" --type codex --project "$PROJECT_ALICE" --team demo --agent alice -- ask bob "ping" --timeout 5 --interval 1
  wait
  [ "$status" -eq 0 ]
  [[ "$output" =~ "status=reply" ]]
  [[ "$output" =~ "pong" ]]
  [[ "$output" =~ "bob → alice" ]]
}

@test "dispatch: ask separates --timeout from a multi-word message body" {
  ( sleep 1; bash "$SCRIPTS/send.sh" demo bob alice "pong" >/dev/null ) &
  run bash "$SCRIPTS/windows/dispatch.sh" --type codex --project "$PROJECT_ALICE" --team demo --agent alice -- ask bob check the server please --timeout 5 --interval 1
  wait
  [ "$status" -eq 0 ]
  [[ "$output" =~ "status=reply" ]]
  run bash "$SCRIPTS/windows/dispatch.sh" --type codex --project "$PROJECT_ALICE" --team demo -- history
  [[ "$output" =~ "check the server please" ]]
}

@test "dispatch: ask keeps a --timeout literal inside the message body (only trailing options are peeled)" {
  ( sleep 1; bash "$SCRIPTS/send.sh" demo bob alice "pong" >/dev/null ) &
  run bash "$SCRIPTS/windows/dispatch.sh" --type codex --project "$PROJECT_ALICE" --team demo --agent alice -- ask bob set --timeout 5 in the config --timeout 5 --interval 1
  wait
  [ "$status" -eq 0 ]
  [[ "$output" =~ "status=reply" ]]
  run bash "$SCRIPTS/windows/dispatch.sh" --type codex --project "$PROJECT_ALICE" --team demo -- history
  # The body keeps the inner "--timeout 5"; only the final option pair was consumed.
  [[ "$output" =~ "set --timeout 5 in the config" ]]
}

@test "dispatch: ask rejects an empty message body (exit 2)" {
  run bash "$SCRIPTS/windows/dispatch.sh" --type codex --project "$PROJECT_ALICE" --team demo --agent alice -- ask bob --timeout 1
  [ "$status" -eq 2 ]
  [[ "$output" =~ "usage: agmsg ask" ]]
}

@test "dispatch: ask -- delimiter sends a body that itself ends with flag-like tokens" {
  ( sleep 1; bash "$SCRIPTS/send.sh" demo bob alice "pong" >/dev/null ) &
  run bash "$SCRIPTS/windows/dispatch.sh" --type codex --project "$PROJECT_ALICE" --team demo --agent alice -- ask bob --timeout 5 -- raw body --interval 9 --timeout 9
  wait
  [ "$status" -eq 0 ]
  [[ "$output" =~ "status=reply" ]]
  run bash "$SCRIPTS/windows/dispatch.sh" --type codex --project "$PROJECT_ALICE" --team demo -- history
  [[ "$output" =~ "raw body --interval 9 --timeout 9" ]]
}

@test "dispatch: codex mode off and turn delegate to delivery" {
  run bash "$SCRIPTS/windows/dispatch.sh" --type codex --project "$PROJECT_ALICE" -- mode off
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Delivery mode set to 'off'" ]]

  run bash "$SCRIPTS/windows/dispatch.sh" --type codex --project "$PROJECT_ALICE" -- mode turn
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Delivery mode set to 'turn'" ]]
}
