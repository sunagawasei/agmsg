#!/usr/bin/env bats

# Unit tests for codex-bridge-launcher.sh thread resolution (#350).
# The launcher must bind the bridge to the role's RECORDED codex thread instead
# of the app-server's ambiguous "loaded" thread (which a co-resident codex thread
# in the same cwd could otherwise capture). A mock bridge (AGMSG_CODEX_BRIDGE_CMD)
# records the --thread the launcher passes.

load test_helper

setup() {
  setup_test_env
  export SKILL_DIR="$TEST_SKILL_DIR"
  export RUN_DIR="$SKILL_DIR/run"; mkdir -p "$RUN_DIR"
  export PROJ="$TEST_SKILL_DIR/proj"; mkdir -p "$PROJ"
  bash "$SCRIPTS/join.sh" team alice codex "$PROJ" >/dev/null

  export CAPTURE="$TEST_SKILL_DIR/thread-capture.txt"
  export MOCK="$TEST_SKILL_DIR/mock-bridge.sh"
  cat > "$MOCK" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$CAPTURE"
[ -z "\${MOCK_BRIDGE_SLEEP:-}" ] || sleep "\$MOCK_BRIDGE_SLEEP"
exit 0
EOF
  chmod +x "$MOCK"
  export AGMSG_CODEX_BRIDGE_CMD="$MOCK"
  export LAUNCHER="$SCRIPTS/drivers/types/codex/codex-bridge-launcher.sh"
  LIVE_PARENT_SEQUENCE=0
}

teardown() { teardown_test_env; }

# Write a role-session record (team, agent) -> thread for a project.
put_record() {
  SKILL_DIR="$TEST_SKILL_DIR" bash -c \
    'source "$1/lib/role-session.sh"; agmsg_role_session_record "$2" "$3" "$4" "$5" "$6"' \
    _ "$SCRIPTS" "$@"
}

write_request() {
  local thread="$1" hash
  hash=$(SKILL_DIR="$TEST_SKILL_DIR" bash -c \
    'source "$1/lib/hash.sh"; printf "%s" "$2" | agmsg_sha1' _ "$SCRIPTS" "$PROJ")
  printf 'codex\t%s\tws://127.0.0.1:1\n' "$thread" > "$RUN_DIR/codex-bridge-request.$hash"
}

# Start a signal-controlled live PID without imposing a fixed-duration sleep on
# the test. Opening the FIFO read/write keeps the read blocked until TERM.
start_live_parent() {
  LIVE_PARENT_SEQUENCE=$((LIVE_PARENT_SEQUENCE + 1))
  local fifo="$TEST_SKILL_DIR/live-parent.$LIVE_PARENT_SEQUENCE.fifo"
  local ready="$fifo.ready"
  mkfifo "$fifo"
  bash -c '
    trap "exit 0" TERM INT
    exec 9<>"$1"
    : > "$2"
    IFS= read -r _ <&9
  ' _ "$fifo" "$ready" 3>&- &
  LAST_LIVE_PARENT=$!
  wait_for_file "$ready"
  rm -f "$fifo" "$ready"
}

stop_live_parent() {
  local pid="$1"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

capture_line_count_at_least() {
  local expected="$1" count=0
  [ -f "$CAPTURE" ] || return 1
  count="$(wc -l < "$CAPTURE" | tr -d ' ')"
  [ "$count" -ge "$expected" ]
}

capture_contains() {
  [ -f "$CAPTURE" ] || return 1
  grep -q -- "$1" "$CAPTURE" 2>/dev/null
}

codex_child_locks_gone() {
  local storage_dir="${AGMSG_STORAGE_PATH:-$TEST_SKILL_DIR/db}"
  local db="${storage_dir%/}/messages.db" schema_count count
  [ -f "$db" ] || return 1
  schema_count="$(sqlite3 "$db" \
    "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'locks';")" \
    || return 2
  [ "$schema_count" -eq 1 ] || return 1
  count="$(sqlite3 "$db" \
    "SELECT COUNT(*) FROM locks WHERE resource LIKE 'codex-child:%';")" \
    || return 2
  [ "$count" -eq 0 ]
}

# Drive one complete dispatcher scan, then retire its controlled parent. fd 3
# is closed on both processes so a stray descriptor cannot keep Bats open on
# macOS (#bats-fd3). expected=0 uses the identity-cache marker as proof that
# the first scan entered its body; that body completes before the dead parent
# is checked at the next loop boundary.
run_launcher() {
  local expected="${1:-1}" p launcher_pid
  start_live_parent
  p="$LAST_LIVE_PARENT"
  bash "$LAUNCHER" codex "$PROJ" "ws://127.0.0.1:1" "$p" \
    >/dev/null 2>&1 3>&- &
  launcher_pid=$!
  if [ "$expected" -gt 0 ]; then
    wait_until 10 capture_line_count_at_least "$expected"
  else
    wait_for_file "$RUN_DIR/.identity-cache.$launcher_pid"
  fi
  stop_live_parent "$p"
  wait "$launcher_pid" 2>/dev/null || true
  if [ "$expected" -gt 0 ] && [ -z "${MOCK_BRIDGE_SLEEP:-}" ]; then
    wait_until 10 codex_child_locks_gone
  fi
}

@test "launcher: binds the recorded thread when the record's project matches (#350)" {
  put_record team alice rec-thread-1 "$PROJ" codex
  run_launcher
  [ -f "$CAPTURE" ]
  grep -q -- "--thread rec-thread-1" "$CAPTURE"
  ! grep -q -- "--thread loaded" "$CAPTURE"
}

@test "launcher: passes the active storage override as a workspace root" {
  export AGMSG_STORAGE_PATH="$TEST_SKILL_DIR/custom-store"
  put_record team alice rec-thread-1 "$PROJ" codex
  run_launcher

  grep -q -- "--workspace-root $AGMSG_STORAGE_PATH" "$CAPTURE"
  ! grep -q -- "--workspace-root $TEST_SKILL_DIR/db" "$CAPTURE"
}

@test "launcher: child-lock readiness distinguishes initialization from query errors" {
  export AGMSG_STORAGE_PATH="$TEST_SKILL_DIR/custom-store"
  local db="$AGMSG_STORAGE_PATH/messages.db"

  run codex_child_locks_gone
  [ "$status" -eq 1 ]

  mkdir -p "$AGMSG_STORAGE_PATH"
  sqlite3 "$db" "PRAGMA user_version = 1;"
  run codex_child_locks_gone
  [ "$status" -eq 1 ]

  sqlite3 "$db" "
    CREATE TABLE locks(
      resource TEXT PRIMARY KEY,
      owner_pid INTEGER NOT NULL,
      acquired_at TEXT NOT NULL
    );
    INSERT INTO locks VALUES('codex-child:pending', 123, datetime('now'));
  "
  run codex_child_locks_gone
  [ "$status" -eq 1 ]

  sqlite3 "$db" "DELETE FROM locks;"
  run codex_child_locks_gone
  [ "$status" -eq 0 ]

  sqlite3() { return 9; }
  run codex_child_locks_gone
  [ "$status" -eq 2 ]
}

@test "launcher: leaves a role without a recorded live thread unsubscribed (#150)" {
  run_launcher 0
  [ ! -f "$CAPTURE" ]
}

@test "launcher: leaves a role with a foreign-project record unsubscribed (#150)" {
  put_record team alice other-thread "/some/other/project" codex
  run_launcher 0
  [ ! -f "$CAPTURE" ]
}

@test "launcher: writes the bound-thread file so a later launcher can rebind (#350)" {
  put_record team alice rec-thread-1 "$PROJ" codex
  run_launcher
  [ "$(cat "$RUN_DIR/codex-bridge.team.alice.thread" 2>/dev/null)" = "rec-thread-1" ]
}

@test "launcher: replaces a stale role pidfile with the spawned bridge pid" {
  put_record team alice rec-thread-1 "$PROJ" codex
  export MOCK_BRIDGE_SLEEP=3
  printf '%s\n' 99999999 > "$RUN_DIR/codex-bridge.team.alice.pid"
  run_launcher 3>&- & local driver_pid=$!

  local recorded=""
  stale_pidfile_replaced() {
    recorded="$(cat "$RUN_DIR/codex-bridge.team.alice.pid" 2>/dev/null || true)"
    [ -n "$recorded" ] && [ "$recorded" != 99999999 ]
  }
  wait_until 5 stale_pidfile_replaced
  [ -n "$recorded" ]
  [ "$recorded" != 99999999 ]
  kill -0 "$recorded"

  wait "$driver_pid" 2>/dev/null || true
}

@test "launcher: starts one bridge per recorded role and thread (#150 phase 2)" {
  bash "$SCRIPTS/join.sh" team bob codex "$PROJ" >/dev/null
  put_record team alice thread-alice "$PROJ" codex
  put_record team bob thread-bob "$PROJ" codex
  run_launcher 2

  local lines=0
  lines=$(wc -l < "$CAPTURE" | tr -d ' ')
  [ "$lines" -ge 2 ]
  grep -q -- $'--pair team\talice --thread thread-alice' "$CAPTURE"
  grep -q -- $'--pair team\tbob --thread thread-bob' "$CAPTURE"
}

@test "launcher: only one dispatcher runs per project" {
  put_record team alice thread-alice "$PROJ" codex
  export MOCK_BRIDGE_SLEEP=8
  start_live_parent; local parent_a="$LAST_LIVE_PARENT"
  start_live_parent; local parent_b="$LAST_LIVE_PARENT"

  bash "$LAUNCHER" codex "$PROJ" "ws://127.0.0.1:1" "$parent_a" >/dev/null 2>&1 3>&- &
  local launcher_a=$!
  bash "$LAUNCHER" codex "$PROJ" "ws://127.0.0.1:1" "$parent_b" >/dev/null 2>&1 3>&- &
  local launcher_b=$!

  wait_for_file "$CAPTURE"
  [ -f "$CAPTURE" ]
  [ "$(wc -l < "$CAPTURE" | tr -d ' ')" -eq 1 ]

  stop_live_parent "$parent_a"
  stop_live_parent "$parent_b"
  wait "$launcher_a" 2>/dev/null || true
  wait "$launcher_b" 2>/dev/null || true
}

@test "launcher: stale dispatcher reclamation remains singleton under contention" {
  put_record team alice thread-alice "$PROJ" codex
  export MOCK_BRIDGE_SLEEP=8
  local hash lock_db
  hash=$(printf '%s' "$PROJ" | bash -c 'source "$1"; agmsg_sha1' _ "$SCRIPTS/lib/hash.sh")
  lock_db="$TEST_SKILL_DIR/db/messages.db"
  sqlite3 "$lock_db" "CREATE TABLE locks(resource TEXT PRIMARY KEY, owner_pid INTEGER NOT NULL, acquired_at TEXT NOT NULL); INSERT INTO locks VALUES('codex-dispatcher:$hash', 99999999, datetime('now'));"
  # A crash from the former two-directory implementation can leave this behind.
  # The transactional lock protocol must not depend on that legacy reaper.
  mkdir "$RUN_DIR/codex-bridge-dispatcher.$hash.reap"
  export AGMSG_TEST_DISPATCHER_STALE_BARRIER="$TEST_SKILL_DIR/stale-observed"
  start_live_parent; local parent_a="$LAST_LIVE_PARENT"
  start_live_parent; local parent_b="$LAST_LIVE_PARENT"

  bash "$LAUNCHER" codex "$PROJ" "ws://127.0.0.1:1" "$parent_a" >/dev/null 2>&1 3>&- &
  local launcher_a=$!
  bash "$LAUNCHER" codex "$PROJ" "ws://127.0.0.1:1" "$parent_b" >/dev/null 2>&1 3>&- &
  local launcher_b=$!

  wait_for_file "$CAPTURE"
  [ -f "$CAPTURE" ]
  [ "$(wc -l < "$CAPTURE" | tr -d ' ')" -eq 1 ]

  stop_live_parent "$parent_a"
  stop_live_parent "$parent_b"
  wait "$launcher_a" 2>/dev/null || true
  wait "$launcher_b" 2>/dev/null || true
}

@test "launcher: project request thread never overrides per-role recorded threads (#150 phase 2)" {
  bash "$SCRIPTS/join.sh" team bob codex "$PROJ" >/dev/null
  put_record team alice thread-alice "$PROJ" codex
  put_record team bob thread-bob "$PROJ" codex
  write_request thread-bob
  run_launcher 2

  grep -q -- $'--pair team\talice --thread thread-alice' "$CAPTURE"
  grep -q -- $'--pair team\tbob --thread thread-bob' "$CAPTURE"
  ! grep -q -- $'--pair team\talice --thread thread-bob' "$CAPTURE"
}

@test "launcher: role record update keeps child scoped to the same pair" {
  put_record team alice thread-before "$PROJ" codex
  start_live_parent; local p="$LAST_LIVE_PARENT"
  bash "$LAUNCHER" codex "$PROJ" "ws://127.0.0.1:1" "$p" $'team\talice' >/dev/null 2>&1 3>&- &
  local launcher_pid=$!
  wait_until 5 capture_contains $'--pair team\talice --thread thread-before'
  grep -q -- $'--pair team\talice --thread thread-before' "$CAPTURE"
  put_record team alice thread-after "$PROJ" codex
  wait_until 5 capture_contains $'--pair team\talice --thread thread-after'
  stop_live_parent "$p"
  wait "$launcher_pid" 2>/dev/null || true

  grep -q -- $'--pair team\talice --thread thread-before' "$CAPTURE"
  grep -q -- $'--pair team\talice --thread thread-after' "$CAPTURE"
  ! grep -q -- '--pair team bob' "$CAPTURE"
}

# Count live role-child launcher processes for this test's project. A child is
# distinguished from a dispatcher by carrying the role pair as its 5th argument;
# match on the agent name rather than the whole pair, because macOS ps renders
# the tab inside that argument as the escape sequence \011, not a literal tab.
#
# Only processes whose parent is not itself a match are counted. Every command
# substitution the launcher runs forks a subshell that inherits the launcher's
# argv, so those subshells are indistinguishable from a real child by command
# line alone -- a naive count reads 3 where there is one child, depending purely
# on when the sample lands. Filtering on ppid counts independent children, which
# is the property these tests are actually about.
count_child_launchers() {
  ps -Ao pid=,ppid=,args= 2>/dev/null \
    | grep -F "$LAUNCHER" \
    | grep -F "$PROJ" \
    | grep alice \
    | awk '{ pid[$1] = 1; parent[$1] = $2 }
           END { n = 0; for (p in pid) if (!(parent[p] in pid)) n++; print n }'
}

# Block until the child count settles on <n>, then return it. Spawn and exit are
# both asynchronous, so sampling on the first sighting races the transition.
wait_for_child_count() {
  local want="$1"
  wait_until 10 child_count_is "$want" || true
  count_child_launchers
}

child_count_is() {
  [ "$(count_child_launchers)" -eq "$1" ]
}

@test "launcher: a replacement dispatcher does not double the role children (#485)" {
  put_record team alice thread-alice "$PROJ" codex
  export MOCK_BRIDGE_SLEEP=12
  start_live_parent; local parent_a="$LAST_LIVE_PARENT"
  start_live_parent; local parent_b="$LAST_LIVE_PARENT"

  # Dispatcher A spawns the role child, which is nohup'd and outlives A.
  bash "$LAUNCHER" codex "$PROJ" "ws://127.0.0.1:1" "$parent_a" >/dev/null 2>&1 3>&- &
  local dispatcher_a=$!
  [ "$(wait_for_child_count 1)" -eq 1 ]

  # SIGKILL is what a pane teardown effectively does to a dispatcher that never
  # trapped the signal: the EXIT trap does not run, so the lock row is left
  # behind owned by a dead pid, exactly the state a replacement dispatcher hits.
  kill -9 "$dispatcher_a" 2>/dev/null || true
  wait "$dispatcher_a" 2>/dev/null || true
  [ "$(wait_for_child_count 1)" -eq 1 ]

  # Dispatcher B reclaims the stale lock and, with an empty known_pairs, spawns
  # a second child for the SAME pair. Without the per-role lock that child would
  # live on and poll forever alongside the first.
  bash "$LAUNCHER" codex "$PROJ" "ws://127.0.0.1:1" "$parent_b" >/dev/null 2>&1 3>&- &
  local dispatcher_b=$!
  # The duplicate is spawned and then has to lose the lock race; settle on the
  # steady state rather than on whichever side of that transition we land.
  [ "$(wait_for_child_count 1)" -eq 1 ]
  sleep 1
  [ "$(count_child_launchers)" -eq 1 ]

  kill "$dispatcher_b" 2>/dev/null || true
  wait "$dispatcher_b" 2>/dev/null || true
  stop_live_parent "$parent_a"
  stop_live_parent "$parent_b"
}

@test "launcher: a re-registered role gets a fresh child after deregistration (#485)" {
  put_record team alice thread-alice "$PROJ" codex
  export MOCK_BRIDGE_SLEEP=12
  start_live_parent; local parent="$LAST_LIVE_PARENT"
  bash "$LAUNCHER" codex "$PROJ" "ws://127.0.0.1:1" "$parent" >/dev/null 2>&1 3>&- &
  local dispatcher=$!
  [ "$(wait_for_child_count 1)" -eq 1 ]

  # Deregistering the role retires its child through the existing re-exec path.
  bash "$SCRIPTS/leave.sh" team alice >/dev/null 2>&1 || true
  [ "$(wait_for_child_count 0)" -eq 0 ]

  # The dispatcher must have forgotten the pair. Otherwise known_pairs still
  # lists it, the re-spawn is suppressed, and the role silently never gets a
  # bridge again for the rest of the app-server's life.
  bash "$SCRIPTS/join.sh" team alice codex "$PROJ" >/dev/null
  put_record team alice thread-alice "$PROJ" codex
  [ "$(wait_for_child_count 1)" -eq 1 ]

  kill "$dispatcher" 2>/dev/null || true
  wait "$dispatcher" 2>/dev/null || true
  stop_live_parent "$parent"
}

@test "launcher: the identity cache still sees a role added mid-loop (#466)" {
  # The poll no longer re-runs identities.sh every tick; it serves a cache
  # guarded on the team configs' mtimes. This is the test that fails if that
  # guard never invalidates: a role joined while the dispatcher is already
  # looping has to be picked up anyway.
  put_record team alice thread-alice "$PROJ" codex
  export MOCK_BRIDGE_SLEEP=20
  start_live_parent; local parent="$LAST_LIVE_PARENT"
  bash "$LAUNCHER" codex "$PROJ" "ws://127.0.0.1:1" "$parent" >/dev/null 2>&1 3>&- &
  local dispatcher=$!
  wait_until 8 capture_contains $'--pair team\talice'
  grep -q -- $'--pair team\talice' "$CAPTURE"

  # Let the loop settle into its backed-off steady state before changing
  # anything, so this exercises a cache hit being invalidated rather than a
  # loop that happened to still be resolving every tick.
  sleep 3
  bash "$SCRIPTS/join.sh" team bob codex "$PROJ" >/dev/null
  put_record team bob thread-bob "$PROJ" codex
  wait_until 10 capture_contains $'--pair team\tbob'
  grep -q -- $'--pair team\tbob --thread thread-bob' "$CAPTURE"

  kill "$dispatcher" 2>/dev/null || true
  wait "$dispatcher" 2>/dev/null || true
  stop_live_parent "$parent"
}
