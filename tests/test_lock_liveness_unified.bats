#!/usr/bin/env bats

# The placement lock, the claude-code bridge instance lock and the team lifecycle
# lock answer "is the holder gone" through the same primitives as the registry
# lock (registry-lock.sh) and the same liveness function (instance-id.sh).

load test_helper

setup() {
  setup_test_env
  export SKILL_DIR="$TEST_SKILL_DIR"
  export RUN_DIR="$SKILL_DIR/run"
  mkdir -p "$RUN_DIR"
  # shellcheck disable=SC1090
  source "$SCRIPTS/lib/actas-lock.sh"
  LOCK="$(_agmsg_placement_lock_path team agent)"
}

teardown() {
  teardown_test_env
}

# A lock directory whose holder record was written by a process that has since
# been killed: the record is real (this host's scope), the pid is not running.
leave_dead_lock() {   # <lock>
  run env LOCKLIB="$SCRIPTS/lib/registry-lock.sh" L="$1" bash -c '
    . "$LOCKLIB"
    _agmsg_lock_ident
    _agmsg_lock_try "$L" "" 0 || exit 1
    kill -9 $$
  '
  [ -f "$1"/holder.* ]
}

require_scope() {
  run bash -c '. "$1"; _agmsg_lock_scope_load; [ -n "$_AGMSG_LOCK_SCOPE" ]' _ "$SCRIPTS/lib/registry-lock.sh"
  [ "$status" -eq 0 ] || skip "this host cannot name its process table, so no holder can be judged"
}

age_dir() {   # <dir> -- mtime three minutes back
  touch -t "$(date -v-3M +%Y%m%d%H%M.%S 2>/dev/null || date -d '3 minutes ago' +%Y%m%d%H%M.%S)" "$1"
}

@test "placement: a lock whose holder was killed is broken at once" {
  require_scope
  leave_dead_lock "$LOCK"
  agmsg_placement_lock_acquire team agent 3
  [ -f "$LOCK"/holder.* ]
  agmsg_placement_lock_release team agent
  [ ! -e "$LOCK" ]
}

@test "placement: a live holder is kept however old the lock is" {
  require_scope
  env LOCKLIB="$SCRIPTS/lib/registry-lock.sh" L="$LOCK" bash -c '
    . "$LOCKLIB"; _agmsg_lock_ident; _agmsg_lock_try "$L" "" 0 || exit 1; exec sleep 30
  ' &
  holder=$!
  local n=0
  until [ -n "$(ls "$LOCK"/holder.* 2>/dev/null)" ]; do
    n=$((n + 1))
    [ "$n" -lt 200 ] && kill -0 "$holder" 2>/dev/null || { kill "$holder" 2>/dev/null; false; }
    sleep 0.05
  done
  age_dir "$LOCK"
  run env AGMSG_PLACEMENT_LOCK_POLL_INTERVAL=0.05 bash -c '
    . "$1"; agmsg_placement_lock_acquire team agent 1' _ "$SCRIPTS/lib/actas-lock.sh"
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  [ "$status" -eq 1 ]
}

@test "placement: an empty directory is kept while new and removed after two minutes" {
  mkdir "$LOCK"
  AGMSG_PLACEMENT_LOCK_POLL_INTERVAL=0.05 run agmsg_placement_lock_acquire team agent 1
  [ "$status" -eq 1 ]
  [ -d "$LOCK" ]
  age_dir "$LOCK"
  run agmsg_placement_lock_acquire team agent 3
  [ "$status" -eq 0 ]
}

@test "placement: release leaves a lock this process does not hold" {
  mkdir "$LOCK"
  : > "$LOCK/holder.other"
  agmsg_placement_lock_release team agent
  [ -f "$LOCK/holder.other" ]
}

@test "placement: two processes racing for one lock never hold it together" {
  local i
  for i in 1 2 3 4; do
    (
      . "$SCRIPTS/lib/actas-lock.sh"
      agmsg_placement_lock_acquire team agent 10 || exit 9
      mkdir "$BATS_TEST_TMPDIR/in-section" || exit 8
      sleep 0.2
      rmdir "$BATS_TEST_TMPDIR/in-section"
      agmsg_placement_lock_release team agent
    ) &
    pids="${pids:-} $!"
  done
  for p in $pids; do wait "$p"; done
}

@test "lifecycle: an owner pid that cannot be signalled (EPERM) is alive, not taken over" {
  source "$SCRIPTS/lib/team-lifecycle.sh"
  res="$(agmsg_team_lifecycle_resource team)"
  storage_init >/dev/null 2>&1 || true
  [ "$(agmsg_runtime_lock_acquire "$res" 424242)" = 424242 ]
  kill() { echo "bash: kill: (424242) - Operation not permitted" >&2; return 1; }
  AGMSG_LIFECYCLE_LOCK_POLL_INTERVAL=0.05 run agmsg_team_lifecycle_lock_acquire team 1
  [ "$status" -eq 1 ]
}
