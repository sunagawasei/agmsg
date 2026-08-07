#!/usr/bin/env bats

# Unit tests for codex-bridge-launcher.sh thread resolution (#350).
# The launcher must bind the bridge to the role's RECORDED codex thread instead
# of the app-server's ambiguous "loaded" thread (which a co-resident codex thread
# in the same cwd could otherwise capture). A mock bridge records the --thread
# the launcher passes.
#
# The mock replaces codex-bridge.js itself (the file the launcher's DEFAULT
# bridge_run resolves to) rather than being swapped in via AGMSG_CODEX_BRIDGE_CMD
# (#595). AGMSG_CODEX_BRIDGE_CMD is a real, documented user-facing override (a
# custom bridge wrapper), and codex-bridge-launcher.sh takes a materially
# different code path for it (a synchronous wait on the launched process) than
# for its default codex-bridge.js path -- exercising that override path here
# tested a branch these tests have no interest in and does not run for anyone
# using agmsg without a custom wrapper, and its wait, sized for a real bridge
# process's lifetime, raced these tests' shorter deregistration-response
# assertions. Only tests/ files change here: setup_test_env already copies the
# whole scripts/ tree into an isolated $TEST_SKILL_DIR per test, so overwriting
# codex-bridge.js below mutates only that disposable copy.

load test_helper

setup() {
  setup_test_env
  export SKILL_DIR="$TEST_SKILL_DIR"
  export RUN_DIR="$SKILL_DIR/run"; mkdir -p "$RUN_DIR"
  export PROJ="$TEST_SKILL_DIR/proj"; mkdir -p "$PROJ"
  # Surface join.sh's own diagnosis when it fails. `>/dev/null` discards stdout
  # and bats reports only the failing line, so a setup failure here says
  # "join.sh failed" and nothing about why -- which is the whole question when
  # it fails on one platform only.
  local _join_out _join_rc=0
  _join_out="$(bash "$SCRIPTS/join.sh" team alice codex "$PROJ" 2>&1)" || _join_rc=$?
  if [ "$_join_rc" -ne 0 ]; then
    printf 'join.sh failed (rc=%s):\n%s\n' "$_join_rc" "$_join_out" >&2
    # It exits non-zero after "Created team:" and says nothing else, so the
    # message is not where the failure is. Re-run under trace and keep the tail:
    # the last command before the exit is the one to look at.
    printf -- '--- retry under set -x (tail) ---\n' >&2
    bash -x "$SCRIPTS/join.sh" team alice codex "$PROJ" 2>&1 | tail -40 >&2 || true
    return 1
  fi

  export CAPTURE="$TEST_SKILL_DIR/thread-capture.txt"
  # A leaked AGMSG_CODEX_BRIDGE_CMD from the ambient environment (not this
  # file, which no longer sets it) would silently put the launcher back on the
  # override code path this suite is no longer testing -- unset it explicitly
  # rather than relying on it merely being absent here (#595).
  unset AGMSG_CODEX_BRIDGE_CMD
  [ -z "${AGMSG_CODEX_BRIDGE_CMD:-}" ]
  # Overwrite the (already-isolated, per-test) copy of codex-bridge.js with a
  # mock that records its argv. AGMSG_NODE is the documented override for the
  # Node binary codex-bridge-launcher.sh resolves this file through; pointing
  # it at bash makes bash the interpreter for this file regardless of its .js
  # name, so the launcher's default (no-custom-wrapper) path runs unmodified.
  cat > "$SCRIPTS/drivers/types/codex/codex-bridge.js" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$CAPTURE"
[ -z "\${MOCK_BRIDGE_SLEEP:-}" ] || sleep "\$MOCK_BRIDGE_SLEEP"
exit 0
EOF
  chmod +x "$SCRIPTS/drivers/types/codex/codex-bridge.js"
  export AGMSG_NODE="$(command -v bash)"
  export LAUNCHER="$SCRIPTS/drivers/types/codex/codex-bridge-launcher.sh"
  LIVE_PARENT_SEQUENCE=0
}

# PIDs of live per-role child launchers for this test's project: any process
# whose argv contains both LAUNCHER and PROJ, one line per pid. Not scoped to a
# single role name -- teardown must reap every role's child a test spawned
# (e.g. "the identity cache still sees a role added mid-loop" joins a second
# role, "bob", mid-test), unlike count_child_launchers below, which measures
# one specific role on purpose. This also does not dedupe transient
# command-substitution subshells by parent pid -- for killing that distinction
# does not matter, signaling and waiting on a subshell that has already
# exited on its own is a harmless no-op.
_launcher_child_pids() {
  ps -Ao pid=,args= 2>/dev/null | grep -F "$LAUNCHER" | grep -F "$PROJ" | awk '{print $1}'
}

# PIDs of bridge processes this test's launchers started. The bridge itself
# runs as "bash codex-bridge.js ..." -- its argv never contains LAUNCHER, so
# _launcher_child_pids cannot see it, and a child launcher's EXIT trap only
# releases its runtime lock; it does not kill a bridge it already nohup'd. Read
# from pidfiles instead, which live under this test's own $RUN_DIR ($TEST_
# SKILL_DIR is unique per test), so this cannot reach another test's process.
_launcher_bridge_pids() {
  local f
  for f in "$RUN_DIR"/codex-bridge.*.pid; do
    [ -f "$f" ] || continue
    cat "$f" 2>/dev/null
  done
}

# A test's own kill/wait sequence reaches the dispatcher and the short-lived
# parent it was handed, but a per-role child (nohup'd, independent of both) and
# the bridge process it launched are not direct children of anything a test
# holds a pid for, so they are not swept by "kill $dispatcher; kill $parent"
# alone -- the child only self-exits once it next notices its parent is gone,
# and never kills its own bridge except when it does so as part of noticing
# deregistration. Snapshot the pid set once, signal all of it, then wait for
# all of it, rather than interleaving kill/wait per pid against a ps/pidfile
# view that can keep changing underneath. Reaping here, and WAITING for the
# reap rather than just signaling and moving on, is what keeps
# teardown_test_env's rm -rf from racing a process still touching this test's
# $TEST_SKILL_DIR (#595/#615).
teardown() {
  local pid pids
  pids="$(_launcher_child_pids; _launcher_bridge_pids)"
  for pid in $pids; do
    kill "$pid" 2>/dev/null || true
  done
  for pid in $pids; do
    wait_for_pid_exit "$pid" || true
  done
  teardown_test_env
}

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
  # A custom bridge command is waited synchronously by its role launcher. Keep
  # the mock lifetime below wait_for_child_count's 10-second ceiling so this
  # test measures deregistration, not the intentionally blocking test adapter.
  export MOCK_BRIDGE_SLEEP=2
  sleep 20 3>&- & local parent=$!
  bash "$LAUNCHER" codex "$PROJ" "ws://127.0.0.1:1" "$parent" >/dev/null 2>&1 3>&- &
  local dispatcher=$!
  [ "$(wait_for_child_count 1)" -eq 1 ]

  # Deregistering the role retires its child through the existing re-exec path.
  run bash "$SCRIPTS/leave.sh" team alice
  [ "$status" -eq 0 ]
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

# --- which pid space (#567) ---

@test "launcher: starts the bridge when tasklist cannot see the parent (#567)" {
  skip_on_windows "stubs tasklist to model Git Bash; the real one is authoritative there"
  # Every pid the launcher waits on -- PARENT_PID, LIFETIME_PID, the dispatcher
  # lock owner -- is minted by $! or $$ in one of these shells, so under Git Bash
  # it is numbered in the MSYS space and `tasklist` has no record of it. A probe
  # that asks tasklist calls the live parent dead: the startup loop is never
  # entered, the supervision loop never runs, and no bridge is ever launched.
  # Measured on our own Windows runner -- $$, $! and a pid read back from a
  # pidfile all report tasklist_hits=0 while kill -0 answers yes.
  local stubdir="$TEST_SKILL_DIR/stub-bin"
  mkdir -p "$stubdir"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$stubdir/tasklist"
  chmod +x "$stubdir/tasklist"

  put_record team alice thread-msys "$PROJ" codex

  sleep 6 3>&- & local p=$!
  MSYSTEM=MINGW64 PATH="$stubdir:$PATH" \
    bash "$LAUNCHER" codex "$PROJ" "ws://127.0.0.1:1" "$p" >/dev/null 2>&1 3>&- || true
  wait "$p" 2>/dev/null || true
  local i
  for i in {1..30}; do [ -f "$CAPTURE" ] && break; sleep 0.1; done

  # A bridge was launched at all -- this is what the whole class costs on Windows.
  [ -f "$CAPTURE" ] || { echo "no bridge was started under a blind tasklist"; false; }
  grep -q -- '--thread thread-msys' "$CAPTURE"
}

@test "launcher: windows-native starts the bridge (#567)" {
  skip_unless_windows "the point is the real tasklist and the real MSYS pid space"
  # The counterpart to codex-monitor's windows-native test, and the half #582
  # does NOT fix: reaching the bridged handoff is not the same as delivering a
  # message. PARENT_PID is codex-monitor.sh's own $$, so on Git Bash the loops
  # at :291 and :381 are asking tasklist about an MSYS pid -- false on the first
  # evaluation, which means neither loop turns over and no bridge is ever
  # started. Real tasklist, no stub.
  put_record team alice thread-win "$PROJ" codex

  sleep 6 3>&- & local p=$!
  bash "$LAUNCHER" codex "$PROJ" "ws://127.0.0.1:1" "$p" >/dev/null 2>&1 3>&- || true
  wait "$p" 2>/dev/null || true
  local i
  for i in {1..30}; do [ -f "$CAPTURE" ] && break; sleep 0.1; done

  [ -f "$CAPTURE" ] || { echo "no bridge was started on native Windows"; false; }
  grep -q -- '--thread thread-win' "$CAPTURE"
}
