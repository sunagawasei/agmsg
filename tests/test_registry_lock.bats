#!/usr/bin/env bats

# The lock is a mkdir. mkdir fails for more than one reason, and only one of
# them ever clears on its own — so the failure the operator is shown has to say
# which one it was.
#
# From the field: a second machine running as a different OS account pointed at
# the first one's store. The team directory was 0755 and owned by the other
# user, so mkdir could never succeed. The message said "timed out acquiring
# registry lock", which sent three separate diagnoses after processes — a sync
# engine was killed for it — while the cause sat in the directory's mode the
# whole time.

load test_helper

setup() {
  setup_test_env
  LOCKLIB="$SCRIPTS/lib/registry-lock.sh"
  TEAM_DIR="$BATS_TEST_TMPDIR/teams/someteam"
  mkdir -p "$TEAM_DIR"
}

teardown() {
  # Restore before the harness cleans up, or the tree cannot be removed.
  chmod u+w "$TEAM_DIR" 2>/dev/null || true
  teardown_test_env
}

acquire() {  # runs the acquire in its own shell, with a short spin budget
  run env AGMSG_LOCK_TRIES="${TRIES:-5}" LOCKLIB="$LOCKLIB" TEAM_DIR="$TEAM_DIR" bash -c '
    . "$LOCKLIB"
    agmsg_lock_acquire "$TEAM_DIR"
  '
}

@test "lock: a held lock is contention — it waits, then reports a timeout" {
  # The reason the spin exists. Nothing here should change.
  mkdir "$TEAM_DIR/.config.lock"
  acquire
  [ "$status" -ne 0 ]
  [[ "$output" == *"timed out acquiring registry lock"* ]]
  # And must NOT blame permissions: this directory is perfectly writable.
  [[ "$output" != *"cannot be written to"* ]]
}

@test "lock: an unwritable team dir fails immediately and names the cause" {
  if [ "$(id -u)" = "0" ]; then
    skip "root ignores the mode bits this is about"
  fi
  # No lock directory exists — nothing is holding anything. mkdir still cannot
  # succeed, and no amount of waiting changes that.
  chmod a-w "$TEAM_DIR"
  [ ! -e "$TEAM_DIR/.config.lock" ]

  # A budget large enough that the old code visibly waits (~2s) and small
  # enough that a regression FAILS rather than hanging CI. The first draft used
  # 100000 to make the wait unmistakable and instead sat for ten minutes: a
  # regression must be reported, not survived.
  TRIES=200 acquire
  [ "$status" -ne 0 ]

  # Fast-fail, asserted by what it did NOT say rather than by a clock. The old
  # code reaches the budget and says "timed out"; this path never enters the
  # spin at all. Timing assertions are flaky; this one is exact.
  [[ "$output" != *"timed out"* ]]

  # And it says what is actually wrong, in terms someone can act on.
  [[ "$output" == *"cannot create the registry lock"* ]]
  [[ "$output" == *"waiting will not clear it"* ]]
  [[ "$output" == *"mkdir:"* ]]
  # The evidence: who owns it, and who we are.
  [[ "$output" == *"running as:"* ]]
  [[ "$output" == *"uid="* ]]
}

@test "lock: the timeout carries the mkdir error too" {
  # Even on the path this function did not anticipate, the errno is not thrown
  # away. `2>/dev/null` discarding it is what left the field with one sentence
  # and no cause.
  mkdir "$TEAM_DIR/.config.lock"
  acquire
  [ "$status" -ne 0 ]
  [[ "$output" == *"last mkdir error:"* ]]
  [[ "$output" == *"File exists"* || "$output" == *"exists"* ]]
}

@test "lock: a free, writable team dir is acquired" {
  # The positive control. Without it, a version that failed every acquire
  # would satisfy both failure tests above.
  run env LOCKLIB="$LOCKLIB" TEAM_DIR="$TEAM_DIR" bash -c '
    . "$LOCKLIB"
    agmsg_lock_acquire "$TEAM_DIR" || exit 1
    [ -d "$TEAM_DIR/.config.lock" ] || exit 2
    agmsg_lock_release
    [ ! -d "$TEAM_DIR/.config.lock" ] || exit 3
  '
  [ "$status" -eq 0 ]
}

@test "lock: a held lock names its holder (#778)" {
  # A lock directory with nothing in it says something holds it and nothing
  # about what. When one leaks, that is the difference between "remove this,
  # the process is gone" and guessing — and guessing wrong removes a live lock.
  run env LOCKLIB="$LOCKLIB" TEAM_DIR="$TEAM_DIR" bash -c '
    . "$LOCKLIB"
    agmsg_lock_acquire "$TEAM_DIR" || exit 1
    cat "$TEAM_DIR/.config.lock/holder"
  '
  [ "$status" -eq 0 ]
  grep -qE "^pid [0-9]+$" <<<"$output"
  grep -q "^command " <<<"$output"
}

@test "lock: a lock that cannot be released says so, and the way out works (#778)" {
  # The defect: `rmdir … || true` treated "already gone" and "will not go" as
  # the same event. The second is a permanent leak — every later command for
  # this team waits for a holder that is never coming back — and it was silent.
  run env LOCKLIB="$LOCKLIB" TEAM_DIR="$TEAM_DIR" bash -c '
    . "$LOCKLIB"
    agmsg_lock_acquire "$TEAM_DIR" || exit 1
    printf "x\n" > "$TEAM_DIR/.config.lock/stray"
    agmsg_lock_release
  '
  grep -q "could not release the registry lock" <<<"$output"
  grep -q "commands for this team will wait" <<<"$output"

  # The route it prints has to work on the case that produced it. `rmdir` does
  # not: it is what just failed. Lifted out of the message and run, so the two
  # cannot drift apart.
  local remedy
  remedy="$(grep -oE 'rm -r .*' <<<"$output" | tail -1)"
  [ -n "$remedy" ]
  run bash -c "$remedy"
  [ "$status" -eq 0 ]
  [ ! -d "$TEAM_DIR/.config.lock" ]
}

@test "lock: releasing a lock that is already gone stays quiet (#778)" {
  # The other half of the same distinction. A lock that is already released is
  # not an event, and reporting it would train the operator to ignore the line
  # that matters.
  run env LOCKLIB="$LOCKLIB" TEAM_DIR="$TEAM_DIR" bash -c '
    . "$LOCKLIB"
    agmsg_lock_acquire "$TEAM_DIR" || exit 1
    rm -f "$TEAM_DIR/.config.lock/holder"; rmdir "$TEAM_DIR/.config.lock"
    agmsg_lock_release
  '
  [ "$status" -eq 0 ]
  refute grep -q "could not release" <<<"$output"
}
