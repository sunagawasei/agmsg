#!/usr/bin/env bats

# Integration tests for the actas exclusivity lock wiring:
#   - actas-claim.sh
#   - reset.sh with session_id releases lock
#   - session-end.sh releases this session's locks
#   - session-start.sh GCs stale locks
#   - watch.sh excludes pairs held by other live sessions
# Primitive-level coverage is in test_actas_lock.bats.

load test_helper

setup() {
  setup_test_env
  # Pin bare instance-id keying (#93): owner tokens / pidfiles stay keyed on the
  # raw session_id these tests pass, deterministic whether the suite runs under
  # an agent process (composite) or in CI (bare). The composite path has
  # dedicated coverage in test_instance_id.bats / test_watch.bats.
  export AGMSG_AGENT_PID=""
  export SKILL_DIR="$TEST_SKILL_DIR"
  export RUN_DIR="$SKILL_DIR/run"
  mkdir -p "$RUN_DIR"
  # Source the lib so we can call its functions directly from the test body.
  # shellcheck disable=SC1090
  source "$SKILL_DIR/scripts/lib/actas-lock.sh"
}

teardown() { teardown_test_env; }

# Helper: register a (team, agent) pair for the test project under claude-code.
fake_register() {
  local team="$1" agent="$2" proj="${3:-/tmp/p1}"
  bash "$SKILL_DIR/scripts/join.sh" "$team" "$agent" claude-code "$proj"
}

# Helper: fake that this test process owns a session_id (use our own pid for
# the cc-instance file so liveness checks pass).
fake_session() {
  local sid="$1"
  echo "$sid" > "$RUN_DIR/cc-instance.$$"
  printf '%s' "$sid"
}

# --- placement lock concurrency ---

@test "placement lock: true concurrent contenders yield exactly one acquisition" {
  local go="$BATS_TEST_TMPDIR/placement.go"
  local result_a="$BATS_TEST_TMPDIR/placement.a"
  local result_b="$BATS_TEST_TMPDIR/placement.b"
  local ready_a="$BATS_TEST_TMPDIR/placement.ready.a"
  local ready_b="$BATS_TEST_TMPDIR/placement.ready.b"
  local release="$BATS_TEST_TMPDIR/placement.release"

  placement_contender() {
    local result="$1" ready="$2"
    : > "$ready"
    wait_for_file "$go" || return 1
    if agmsg_placement_lock_acquire T alice 0; then
      printf 'acquired\n' > "$result"
      wait_for_file "$release" || return 1
      agmsg_placement_lock_release T alice
    else
      printf 'blocked\n' > "$result"
    fi
  }

  placement_contender "$result_a" "$ready_a" &
  local pid_a=$!
  placement_contender "$result_b" "$ready_b" &
  local pid_b=$!
  wait_for_file "$ready_a"
  wait_for_file "$ready_b"
  : > "$go"
  wait_for_file "$result_a"
  wait_for_file "$result_b"
  : > "$release"
  wait "$pid_a"
  wait "$pid_b"

  [ "$(grep -hxc acquired "$result_a" "$result_b" | awk '{ sum += $1 } END { print sum }')" -eq 1 ]
  [ "$(grep -hxc blocked "$result_a" "$result_b" | awk '{ sum += $1 } END { print sum }')" -eq 1 ]
  [ ! -d "$(_agmsg_placement_lock_path T alice)" ]
}

# --- actas-claim.sh ---

@test "actas-claim: status=ok and claim recorded when role is free" {
  fake_register T alice
  fake_session "sid-me" >/dev/null

  run bash "$SKILL_DIR/scripts/actas-claim.sh" /tmp/p1 claude-code alice "sid-me"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "status=ok" ]]
  [[ "$output" =~ "team=T" ]]
  [ "$(actas_lock_owner T alice)" = "sid-me" ]
}

@test "actas-claim: status=held when role is held by another live session" {
  skip_on_windows "actas live-session liveness under Git Bash (#182)"
  fake_register T alice
  fake_session "sid-owner" >/dev/null     # this test process is the "live owner"
  echo "sid-owner" > "$(actas_lock_path T alice)"

  run bash "$SKILL_DIR/scripts/actas-claim.sh" /tmp/p1 claude-code alice "sid-thief"
  [ "$status" -eq 1 ]
  [[ "$output" =~ "status=held" ]]
  [[ "$output" =~ "team=T" ]]
  [[ "$output" =~ "owner=sid-owner" ]]
  [ "$(actas_lock_owner T alice)" = "sid-owner" ]   # not stolen
}

@test "actas-claim: status=not_registered when name is unknown" {
  fake_register T alice
  fake_session "sid-me" >/dev/null

  run bash "$SKILL_DIR/scripts/actas-claim.sh" /tmp/p1 claude-code unknown "sid-me"
  [ "$status" -eq 2 ]
  [[ "$output" =~ "status=not_registered" ]]
}

# --- reset.sh releases the lock when session_id is passed ---

@test "reset: with session_id, releases the lock for the dropped role" {
  fake_register T alice
  actas_lock_claim T alice "sid-me"
  [ -f "$(actas_lock_path T alice)" ]

  bash "$SKILL_DIR/scripts/reset.sh" /tmp/p1 claude-code alice "sid-me" >/dev/null

  [ ! -f "$(actas_lock_path T alice)" ]
}

@test "reset: without session_id, does not touch lock (back-compat)" {
  fake_register T alice
  actas_lock_claim T alice "sid-me"

  bash "$SKILL_DIR/scripts/reset.sh" /tmp/p1 claude-code alice >/dev/null

  [ -f "$(actas_lock_path T alice)" ]
  [ "$(actas_lock_owner T alice)" = "sid-me" ]
}

# --- session-end.sh releases all locks owned by the exiting session ---

@test "session-end: releases all locks owned by the exiting session_id" {
  fake_register T alice
  fake_register T bob
  fake_register U alice /tmp/p2
  agmsg_test_start_session_owner
  local instance="sid-going.$AGMSG_TEST_OWNER_PID"
  actas_lock_claim T alice "$instance"
  actas_lock_claim T bob   "$instance"
  fake_session "sid-keeper" >/dev/null
  echo "sid-keeper" > "$(actas_lock_path U alice)"

  printf '{"session_id":"sid-going"}' | bash "$SKILL_DIR/scripts/session-end.sh" claude-code /tmp/p1
  agmsg_test_stop_session_owner

  # Teardown (incl. actas_lock_release_all) is detached now — poll for it.
  wait_until 8 bash -c "[ ! -f '$(actas_lock_path T alice)' ] && [ ! -f '$(actas_lock_path T bob)' ]"
  [ ! -f "$(actas_lock_path T alice)" ]
  [ ! -f "$(actas_lock_path T bob)" ]
  [ -f   "$(actas_lock_path U alice)" ]
}

# --- session-start.sh GCs stale locks ---

@test "session-start: GCs composite locks whose owner pid is dead and keeps bare false-dead locks" {
  echo "sid-ghost.2147483647" > "$(actas_lock_path T alice)"
  echo "sid-bare-ghost" > "$(actas_lock_path T bob)"
  fake_register T alice
  fake_register T bob
  echo "sid-current" > "$RUN_DIR/cc-instance.$$"

  printf '{"session_id":"sid-current"}' \
    | bash "$SKILL_DIR/scripts/session-start.sh" claude-code /tmp/p1 >/dev/null 2>&1 || true

  [ ! -f "$(actas_lock_path T alice)" ]
  [ -f "$(actas_lock_path T bob)" ]
}

# --- watch.sh subscription exclusion ---
# Run watch.sh briefly and inspect its stderr for the exclusion message.

@test "watch: excludes pairs held by another live session (stderr message)" {
  skip_on_windows "actas watcher liveness under Git Bash (#182)"
  fake_register T alice
  fake_register T bob
  fake_session "sid-other" >/dev/null
  # Lock alice for sid-other (this test process pretends to be sid-other).
  echo "sid-other" > "$(actas_lock_path T alice)"

  # Run watch.sh in background with a tiny interval, capture stderr quickly.
  AGMSG_WATCH_INTERVAL=1 bash "$SKILL_DIR/scripts/watch.sh" "sid-mine" /tmp/p1 claude-code \
    >/dev/null 2> "$BATS_TEST_TMPDIR/watch.err" 3>&- &
  local wpid=$!
  wait_for_file_contains "$BATS_TEST_TMPDIR/watch.err" \
    "skipping pairs held by other sessions"
  kill "$wpid" 2>/dev/null || true
  wait "$wpid" 2>/dev/null || true

  run cat "$BATS_TEST_TMPDIR/watch.err"
  [[ "$output" =~ "skipping pairs held by other sessions" ]]
  [[ "$output" =~ "T/alice" ]]
}

@test "watch: with active_name held by other session, exits with held error" {
  skip_on_windows "actas watcher liveness under Git Bash (#182)"
  fake_register T alice
  fake_session "sid-other" >/dev/null
  echo "sid-other" > "$(actas_lock_path T alice)"

  run env AGMSG_WATCH_INTERVAL=1 bash "$SKILL_DIR/scripts/watch.sh" "sid-mine" /tmp/p1 claude-code alice
  [ "$status" -eq 1 ]
  [[ "$output" =~ "cannot claim" ]]
  [[ "$output" =~ "T/alice" ]]
  # Lock was not stolen.
  [ "$(actas_lock_owner T alice)" = "sid-other" ]
}

@test "watch: with active_name on a free pair, claims and continues" {
  skip_on_windows "actas watcher process mgmt under Git Bash (#182)"
  fake_register T alice

  AGMSG_WATCH_INTERVAL=1 bash "$SKILL_DIR/scripts/watch.sh" "sid-me" /tmp/p1 claude-code alice \
    >/dev/null 2> "$BATS_TEST_TMPDIR/watch.err" 3>&- &
  local wpid=$!
  wait_for_file "$(actas_lock_path T alice)"
  [ "$(actas_lock_owner T alice)" = "sid-me" ]

  kill "$wpid" 2>/dev/null || true
  wait "$wpid" 2>/dev/null || true
}

# --- watch.sh releasing a pair it no longer owns (#683) ---

# The subscription set and the lock check both happen once, before the polling
# loop (watch.sh 159-211 vs the loop at 274). So a watcher that is already
# running never notices that another session took its role: it keeps polling the
# same pair, and because the read cursor is one per (team, agent) and
# storage_watch_after excludes rows already read, WHOEVER POLLS FIRST takes the
# row and the other sees nothing.
#
# When the one that takes it is the older process, its printf succeeds -- its
# stdout is still an open pipe to a live session -- so the id is appended to
# DELIVERED_IDS and the message is marked read. Nothing surfaces it. That is the
# reported symptom: consumed, marked read, and never delivered.
@test "watch: a pair claimed by another session is released, not consumed (#683)" {
  skip_on_windows "actas watcher process mgmt under Git Bash (#182)"
  fake_register T alice
  fake_register T bob

  AGMSG_WATCH_INTERVAL=1 bash "$SKILL_DIR/scripts/watch.sh" "sid-old" /tmp/p1 claude-code alice \
    > "$BATS_TEST_TMPDIR/old.out" 2> "$BATS_TEST_TMPDIR/old.err" 3>&- &
  local old=$!
  local i
  for i in $(seq 1 50); do
    [ "$(actas_lock_owner T alice)" = "sid-old" ] && break
    sleep 0.1
  done
  [ "$(actas_lock_owner T alice)" = "sid-old" ]

  # A second session takes the role — what `/agmsg actas` does from a new
  # session. It needs to look ALIVE, or the lock reads as stale and free.
  sleep 60 &
  local newpid=$!
  echo "sid-new" > "$RUN_DIR/cc-instance.$newpid"
  echo "sid-new" > "$(actas_lock_path T alice)"

  bash "$SKILL_DIR/scripts/send.sh" T bob alice "after the handover" >/dev/null

  # Several poll cycles at the 1s interval set above.
  sleep 4
  kill "$newpid" 2>/dev/null || true

  # It must not have taken a message addressed to a role it no longer owns.
  run cat "$BATS_TEST_TMPDIR/old.out"
  [[ "$output" != *"after the handover"* ]]

  # It must have stopped. A watcher that keeps running is what consumes the
  # next message too.
  ! kill -0 "$old" 2>/dev/null

  # And it must say why. Exiting silently is the same defect class -- this
  # watcher's stderr is the only place a reason can survive.
  run cat "$BATS_TEST_TMPDIR/old.err"
  [[ "$output" == *"T/alice"* ]]
  [[ "$output" == *"sid-new"* ]]

  # The message is still unread, so the session that now owns the role is
  # offered it. Without this, "did not print it" would also pass for a watcher
  # that consumed the row and threw it away.
  local left
  left="$(bash -c '
    source "'"$SKILL_DIR"'/scripts/lib/storage.sh"
    agmsg_storage_load
    storage_list_unread T alice
  ' | grep -c .)"
  [ "$left" -eq 1 ]

  kill "$old" 2>/dev/null || true
  wait "$old" 2>/dev/null || true
}

# The other half, and the one that decides whether this fix is safe: a watcher
# with a BROAD subscription serves several roles, so a role moving elsewhere
# must cost it that role and nothing else. Exiting here would take down a whole
# session's delivery because one member ran `actas` somewhere -- a worse failure
# than the one being fixed.
@test "watch: a broad watcher drops only the claimed pair and keeps serving the rest (#683)" {
  skip_on_windows "actas watcher process mgmt under Git Bash (#182)"
  fake_register T alice
  fake_register T bob
  fake_register T carol

  AGMSG_WATCH_INTERVAL=1 bash "$SKILL_DIR/scripts/watch.sh" "sid-broad" /tmp/p1 claude-code \
    > "$BATS_TEST_TMPDIR/broad.out" 2> "$BATS_TEST_TMPDIR/broad.err" 3>&- &
  local broad=$!
  sleep 1

  sleep 60 &
  local newpid=$!
  echo "sid-new" > "$RUN_DIR/cc-instance.$newpid"
  echo "sid-new" > "$(actas_lock_path T alice)"

  bash "$SKILL_DIR/scripts/send.sh" T carol alice "for the role that moved" >/dev/null
  bash "$SKILL_DIR/scripts/send.sh" T carol bob   "for the role that stayed" >/dev/null
  sleep 4
  kill "$newpid" 2>/dev/null || true

  # Still running — this is the assertion the fix has to earn.
  kill -0 "$broad" 2>/dev/null

  run cat "$BATS_TEST_TMPDIR/broad.out"
  [[ "$output" == *"for the role that stayed"* ]]
  [[ "$output" != *"for the role that moved"* ]]

  # And it said which pair it gave up.
  run cat "$BATS_TEST_TMPDIR/broad.err"
  [[ "$output" == *"T/alice"* ]]

  kill "$broad" 2>/dev/null || true
  wait "$broad" 2>/dev/null || true
}

# Stepping aside is for as long as someone else holds the role, not forever.
# The review of the first version caught the opposite claim in my own
# description: the pair stays in the subscription and comes back when the lock
# reads free again. Permanence would be the worse behaviour -- the role is still
# registered to this project, so nobody would deliver for it until the session
# restarted -- so this pins the return rather than the drop.
@test "watch: a broad watcher takes a pair back once nobody holds it (#683)" {
  skip_on_windows "actas watcher process mgmt under Git Bash (#182)"
  fake_register T alice
  fake_register T carol

  AGMSG_WATCH_INTERVAL=1 bash "$SKILL_DIR/scripts/watch.sh" "sid-broad" /tmp/p1 claude-code \
    > "$BATS_TEST_TMPDIR/broad.out" 2> "$BATS_TEST_TMPDIR/broad.err" 3>&- &
  local broad=$!
  sleep 1

  sleep 60 &
  local newpid=$!
  echo "sid-new" > "$RUN_DIR/cc-instance.$newpid"
  echo "sid-new" > "$(actas_lock_path T alice)"
  sleep 2

  # It stepped aside while the other session was live.
  bash "$SKILL_DIR/scripts/send.sh" T carol alice "while it was held" >/dev/null
  sleep 2
  run cat "$BATS_TEST_TMPDIR/broad.out"
  [[ "$output" != *"while it was held"* ]]

  # The holder disappears. The lock file stays behind — a stale owner reads as
  # free, which is exactly the state the startup filter already treats as
  # available.
  kill "$newpid" 2>/dev/null || true
  wait "$newpid" 2>/dev/null || true
  rm -f "$RUN_DIR/cc-instance.$newpid"
  sleep 3

  # Both messages are delivered now: the one that arrived while it was held is
  # still unread, so taking the pair back means handing it over, not skipping it.
  bash "$SKILL_DIR/scripts/send.sh" T carol alice "after it was released" >/dev/null
  sleep 3

  run cat "$BATS_TEST_TMPDIR/broad.out"
  [[ "$output" == *"while it was held"* ]]
  [[ "$output" == *"after it was released"* ]]

  # And the log shows both transitions, so a reader is not left thinking the
  # role went away for good.
  run cat "$BATS_TEST_TMPDIR/broad.err"
  [[ "$output" == *"while they hold it"* ]]
  [[ "$output" == *"unheld again"* ]]

  kill "$broad" 2>/dev/null || true
  wait "$broad" 2>/dev/null || true
}
