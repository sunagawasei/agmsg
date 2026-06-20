#!/usr/bin/env bats

# session-team mode (opt-in delivery.session_team): each Claude session uses its
# own team s-<bare-session-uuid>, so concurrent / resumed sessions sharing a
# project directory are isolated (no cross-session crosstalk). PR1 = the
# crosstalk-stop core: whoami resolution, watch --team pinning, team-scoped
# ask/wait, and the lazy-codex no-op guard.

load test_helper

setup() {
  setup_test_env
  PROJ="/tmp/agmsg-st-proj"
}

teardown() {
  teardown_test_env
}

enable_st() { bash "$SCRIPTS/config.sh" set delivery.session_team true >/dev/null; }

# --- whoami: current-team resolution ---------------------------------------

@test "session-team off: whoami uses project->team (unchanged)" {
  bash "$SCRIPTS/join.sh" base alice claude-code "$PROJ" >/dev/null
  run env CLAUDE_CODE_SESSION_ID=sess-X bash "$SCRIPTS/whoami.sh" "$PROJ" claude-code
  [ "$status" -eq 0 ]
  [[ "$output" == *"teams=base"* ]]
  [[ "$output" != *"teams=s-"* ]]
}

@test "session-team on: whoami resolves to s-<uuid>/claude from the env" {
  enable_st
  run env CLAUDE_CODE_SESSION_ID=sess-X bash "$SCRIPTS/whoami.sh" "$PROJ" claude-code
  [ "$status" -eq 0 ]
  [[ "$output" == *"agent=claude"* ]]
  [[ "$output" == *"teams=s-sess-X"* ]]
}

@test "session-team on but no CLAUDE_CODE_SESSION_ID: falls back to project->team" {
  enable_st
  bash "$SCRIPTS/join.sh" base alice claude-code "$PROJ" >/dev/null
  run env -u CLAUDE_CODE_SESSION_ID bash "$SCRIPTS/whoami.sh" "$PROJ" claude-code
  [ "$status" -eq 0 ]
  [[ "$output" == *"teams=base"* ]]
  [[ "$output" != *"teams=s-"* ]]
}

@test "session-team on: codex (no session id) is never short-circuited" {
  enable_st
  bash "$SCRIPTS/join.sh" base codexagent codex "$PROJ" >/dev/null
  run env -u CLAUDE_CODE_SESSION_ID bash "$SCRIPTS/whoami.sh" "$PROJ" codex
  [ "$status" -eq 0 ]
  [[ "$output" != *"teams=s-"* ]]
}

# --- watch --team pinning: the monitor isolation -----------------------------

@test "watch --team pins the subscription to one team (no cross-session delivery)" {
  enable_st
  # Same project dir registered into TWO session teams (the accumulation case).
  bash "$SCRIPTS/join.sh" s-AAA claude claude-code "$PROJ" >/dev/null
  bash "$SCRIPTS/join.sh" s-BBB claude claude-code "$PROJ" >/dev/null

  AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" sess-w "$PROJ" claude-code claude --team s-AAA \
    >"$TEST_SKILL_DIR/w.log" 2>/dev/null &
  local pid=$!
  # Wait until the watcher is actually receiving (it stamps a readiness sentinel
  # AFTER taking its watermark). Sending before that would, under load, let the
  # watcher take its mark past our message and skip it as "history".
  local ready="$TEST_SKILL_DIR/run/ready.s-AAA__claude"
  for _ in $(seq 1 40); do [ -e "$ready" ] && break; sleep 0.25; done

  bash "$SCRIPTS/send.sh" s-AAA peer claude "MSG-in-AAA" >/dev/null
  bash "$SCRIPTS/send.sh" s-BBB peer claude "MSG-in-BBB" >/dev/null
  # Poll for delivery of the in-team message (robust to load).
  for _ in $(seq 1 24); do grep -q "MSG-in-AAA" "$TEST_SKILL_DIR/w.log" && break; sleep 0.25; done
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  grep -q "MSG-in-AAA" "$TEST_SKILL_DIR/w.log"
  ! grep -q "MSG-in-BBB" "$TEST_SKILL_DIR/w.log"
}

# --- ask/--wait is team-scoped: the reply-matching isolation -----------------

@test "ask/--wait only matches a reply in the same team" {
  enable_st
  AGMSG_SEND_WAIT_INTERVAL=1 bash "$SCRIPTS/send.sh" s-AAA claude codex "Q" --wait --timeout 12 \
    >"$TEST_SKILL_DIR/ask.log" 2>/dev/null &
  local pid=$!
  sleep 1.5
  bash "$SCRIPTS/send.sh" s-BBB codex claude "wrong-team-reply" >/dev/null  # other session team
  sleep 1.5
  bash "$SCRIPTS/send.sh" s-AAA codex claude "right-reply" >/dev/null       # our team
  wait "$pid" 2>/dev/null || true

  grep -q "status=reply" "$TEST_SKILL_DIR/ask.log"
  grep -q "right-reply" "$TEST_SKILL_DIR/ask.log"
  ! grep -q "wrong-team-reply" "$TEST_SKILL_DIR/ask.log"
}

# --- ensure-codex: safe no-op guard ------------------------------------------

@test "ensure-codex: no-op (exit 0, silent) when session-team mode is off" {
  run env CLAUDE_CODE_SESSION_ID=sess-X bash "$SCRIPTS/ensure-codex.sh" "$PROJ"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "ensure-codex: no-op when mode on but no CLAUDE_CODE_SESSION_ID" {
  enable_st
  run env -u CLAUDE_CODE_SESSION_ID bash "$SCRIPTS/ensure-codex.sh" "$PROJ"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- PR2: SessionEnd teardown + orphan GC ------------------------------------

@test "session-end: tears down this session's codex worker, keeps team/history" {
  enable_st
  # Fake a spawned headless codex: a live process + its placement record.
  sleep 300 & local fake=$!
  mkdir -p "$TEST_SKILL_DIR/run"
  printf 'pid:%s\t%s\tcodex\n' "$fake" "/tmp/scratch-end" > "$TEST_SKILL_DIR/run/spawn.s-sessEND__codex"
  printf '{"session_id":"sessEND"}' | bash "$SCRIPTS/session-end.sh" claude-code "$PROJ"
  sleep 1
  ! kill -0 "$fake" 2>/dev/null                                  # worker torn down
  [ ! -f "$TEST_SKILL_DIR/run/spawn.s-sessEND__codex" ]          # placement removed
}

@test "session-end: no teardown when session-team mode is off" {
  sleep 30 & local fake=$!
  mkdir -p "$TEST_SKILL_DIR/run"
  printf 'pid:%s\t%s\tcodex\n' "$fake" "/tmp/scratch-off" > "$TEST_SKILL_DIR/run/spawn.s-sessOFF__codex"
  printf '{"session_id":"sessOFF"}' | bash "$SCRIPTS/session-end.sh" claude-code "$PROJ"
  kill -0 "$fake" 2>/dev/null                                    # untouched
  kill "$fake" 2>/dev/null || true
}

@test "session-start: orphan-codex GC reaps a bridge whose owner session is dead" {
  enable_st
  # Fake a headless codex bridge for a DEAD session (no live cc-instance for it).
  ( exec -a "node /x/codex-bridge.js --team s-DEADGC --name codex --inline-inbox" sleep 300 ) &
  local fake=$!
  mkdir -p "$TEST_SKILL_DIR/run"
  printf 'pid:%s\t%s\tcodex\n' "$fake" "/tmp/scratch-gc" > "$TEST_SKILL_DIR/run/spawn.s-DEADGC__codex"
  # A live (different) session start runs the GC pass.
  printf '{"session_id":"sess-gc-self"}' | bash "$SCRIPTS/session-start.sh" claude-code "$PROJ" >/dev/null 2>&1 || true
  sleep 1
  ! kill -0 "$fake" 2>/dev/null
}

# --- PR3: stale session-team TTL GC ------------------------------------------

@test "session-start: TTL GC reaps a stale (old + dead-owner) session team, keeps recent" {
  enable_st
  # Old + dead owner → reaped.
  mkdir -p "$TEST_SKILL_DIR/teams/s-OLDGC"
  echo '{"name":"s-OLDGC","agents":{}}' > "$TEST_SKILL_DIR/teams/s-OLDGC/config.json"
  touch -t 202501010000 "$TEST_SKILL_DIR/teams/s-OLDGC/config.json" "$TEST_SKILL_DIR/teams/s-OLDGC"
  # Recent (dead owner but fresh mtime) → kept.
  mkdir -p "$TEST_SKILL_DIR/teams/s-RECENTGC"
  echo '{"name":"s-RECENTGC","agents":{}}' > "$TEST_SKILL_DIR/teams/s-RECENTGC/config.json"

  printf '{"session_id":"sess-ttl-self"}' | bash "$SCRIPTS/session-start.sh" claude-code "$PROJ" >/dev/null 2>&1 || true

  [ ! -d "$TEST_SKILL_DIR/teams/s-OLDGC" ]      # old + dead → reaped
  [ -d "$TEST_SKILL_DIR/teams/s-RECENTGC" ]     # too recent → kept
}
