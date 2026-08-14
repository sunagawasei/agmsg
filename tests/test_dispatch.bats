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

_db_request_seen() {
  local body="$1" result
  result="$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" \
    "SELECT 1 FROM messages WHERE team='demo' AND from_agent='alice' AND to_agent='bob' AND body='$body' LIMIT 1;")" || return 1
  [ "$result" = 1 ]
}

reply_after_request() {
  local body="$1"
  wait_until 5 _db_request_seen "$body" || return 1
  bash "$SCRIPTS/send.sh" demo bob alice "pong" >/dev/null
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

# Every other test here passes `--type codex`, so none of them exercises the
# default — which is where #783 actually bit. dispatch.sh must resolve a type
# for the commands that require one, but whoami.sh is the caller that can work
# it out itself, and handing it the `codex` default replaced detection with a
# guess: a Claude Code user on Windows who never set AGMSG_AGENT_TYPE asked "am
# I joined AS CODEX?", got the truthful `not_joined=true`, and read it as "I am
# not joined". Reverting either half of the dispatch change turns this red.
@test "dispatch: with no type chosen, identity comes from detection, not the codex default (#783)" {
  local proj="$BATS_TEST_TMPDIR/project-claude"
  mkdir -p "$proj"
  bash "$SCRIPTS/join.sh" demo carol claude-code "$proj"

  # Control first. If detection does not land on claude-code here, the
  # assertion below would pass or fail for a reason that has nothing to do
  # with dispatch, and this line says so instead of staying quiet.
  run env CLAUDE_CODE_SESSION_ID=test-session bash "$SCRIPTS/whoami.sh" "$proj"
  [ "$status" -eq 0 ]
  # A plain command: a non-last `[[ ]]` cannot fail the test on bash 3.2 (#670),
  # and a control that cannot fail is not a control.
  grep -qF "type=claude-code" <<<"$output"

  run env CLAUDE_CODE_SESSION_ID=test-session bash "$SCRIPTS/windows/dispatch.sh" --project "$proj" -- inbox
  [ "$status" -eq 0 ]
  [[ "$output" =~ "No new messages." ]]
}

# The other direction: a type the caller DID choose must still be honoured, so
# the fix above cannot be "ignore the type argument".
@test "dispatch: an explicitly chosen type is still what identity is resolved as (#783)" {
  local proj="$BATS_TEST_TMPDIR/project-both"
  mkdir -p "$proj"
  bash "$SCRIPTS/join.sh" demo dave claude-code "$proj"

  # Asked as codex, dave is not there — dispatch must stop rather than quietly
  # resolve him. (The output is `suggest=true`, not `not_joined=true`: setup()
  # registers codex agents in other projects, so the scan has something to
  # suggest. What matters is that dave is not the answer.)
  run env CLAUDE_CODE_SESSION_ID=test-session bash "$SCRIPTS/windows/dispatch.sh" --type codex --project "$proj" -- inbox
  [ "$status" -eq 2 ]
  [[ ! "$output" =~ "agent=dave" ]]
}

# WHAT THIS BINDS IS THE BREAKAGE, NOT THE REPAIR. Detecting the type inside
# whoami.sh fixed the message a user reads; it did not fix what dispatch then
# WRITES. `actas` resolves the identity from the claude-code registration and
# immediately calls identities.sh and join.sh — with the type dispatch is
# holding. Left at the `codex` literal, an already-joined claude-code user gets
# a SECOND registration under codex: one person, two identities.
#
# So the assertion is that the wrong record does not appear. Asserting "the
# claude-code one is used" would pass while an extra codex row was created
# beside it.
@test "dispatch: actas with no type chosen does not register the user again under codex (#801)" {
  local proj="$BATS_TEST_TMPDIR/project-actas"
  mkdir -p "$proj"
  bash "$SCRIPTS/join.sh" demo erin claude-code "$proj"

  # Control: nothing is registered as codex in this project yet, so a codex
  # row found afterwards can only have been created by the run below.
  run bash "$SCRIPTS/identities.sh" "$proj" codex
  [ -z "$output" ]

  run env CLAUDE_CODE_SESSION_ID=test-session bash "$SCRIPTS/windows/dispatch.sh" --project "$proj" -- actas frank
  [ "$status" -eq 0 ]

  run bash "$SCRIPTS/identities.sh" "$proj" codex
  [ -z "$output" ]
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
  ( reply_after_request ping ) &
  run bash "$SCRIPTS/windows/dispatch.sh" --type codex --project "$PROJECT_ALICE" --team demo --agent alice -- ask bob "ping" --timeout 5 --interval 1
  wait
  [ "$status" -eq 0 ]
  [[ "$output" =~ "status=reply" ]]
  [[ "$output" =~ "pong" ]]
  [[ "$output" =~ "bob → alice" ]]
}

@test "dispatch: ask separates --timeout from a multi-word message body" {
  ( reply_after_request "check the server please" ) &
  run bash "$SCRIPTS/windows/dispatch.sh" --type codex --project "$PROJECT_ALICE" --team demo --agent alice -- ask bob check the server please --timeout 5 --interval 1
  wait
  [ "$status" -eq 0 ]
  [[ "$output" =~ "status=reply" ]]
  run bash "$SCRIPTS/windows/dispatch.sh" --type codex --project "$PROJECT_ALICE" --team demo -- history
  [[ "$output" =~ "check the server please" ]]
}

@test "dispatch: ask keeps a --timeout literal inside the message body (only trailing options are peeled)" {
  ( reply_after_request "set --timeout 5 in the config" ) &
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
  ( reply_after_request "raw body --interval 9 --timeout 9" ) &
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

@test "dispatch: 'team list' reaches team-list.sh, not team.sh (co1 P1 — 'list' must never be treated as a team name)" {
  run bash "$SCRIPTS/windows/dispatch.sh" --type codex --project "$PROJECT_ALICE" -- team list --json
  [ "$status" -eq 0 ]
  # team.sh's "Team not found: list" / "Team: list" output would appear if
  # this had been misrouted to team.sh with "list" as the team name.
  [[ "$output" != *"Team not found: list"* ]]
  [[ "$output" != *"Team: list"* ]]
  [ "$(echo "$output" | python3 -c "import json,sys; print(json.load(sys.stdin)['schema_version'])")" = "1" ]
  local names
  names="$(echo "$output" | python3 -c "import json,sys; print(','.join(t['name'] for t in json.load(sys.stdin)['teams']))")"
  [[ ",$names," == *",demo,"* ]]
}

@test "dispatch: bare 'team demo' still reaches team.sh (no regression from the 'team list' routing fix)" {
  run bash "$SCRIPTS/windows/dispatch.sh" --type codex --project "$PROJECT_ALICE" -- team demo
  [ "$status" -eq 0 ]
  [[ "$output" == *"Team: demo"* ]]
}
