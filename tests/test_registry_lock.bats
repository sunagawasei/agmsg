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
  # $PRE is evaluated after the library is sourced: a test redefines a function
  # there (the process scope, a hook point, ps) to stage one interleaving.
  run env AGMSG_LOCK_TRIES="${TRIES:-5}" LOCKLIB="$LOCKLIB" TEAM_DIR="$TEAM_DIR" PRE="${PRE:-}" POST="${POST:-:}" bash -c '
    . "$LOCKLIB"
    eval "$PRE"
    agmsg_lock_acquire "$TEAM_DIR" || exit $?
    eval "$POST"
  '
}

# A process scope the tests control, so none of them depends on what this
# machine's /etc/machine-id or ioreg says.
SCOPE_PRE='_agmsg_lock_scope_load() { _AGMSG_LOCK_SCOPE_LOADED=1; _AGMSG_LOCK_SCOPE="m1:b1:n1"; };'
SCOPE=m1:b1:n1

# A well-formed holder record inside <dir> (the lock directory, made if absent).
mkholder() {   # <dir> <token> <pid> [scope]
  mkdir -p "$1"
  {
    printf 'token %s\npid %s\ncommand t\nhost %s\n' "$2" "$3" "$(uname -n)"
    [ -z "${4:-}" ] || printf 'scope %s\n' "$4"
  } > "$1/holder.$2"
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
    cat "$TEAM_DIR"/.config.lock/holder.*
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

@test "lock: after a failed release, the printed remedy lets the next acquire succeed (#778, #1445)" {
  run env LOCKLIB="$LOCKLIB" TEAM_DIR="$TEAM_DIR" bash -c '
    . "$LOCKLIB"
    agmsg_lock_acquire "$TEAM_DIR" || exit 1
    printf "x\n" > "$TEAM_DIR/.config.lock/stray"
    agmsg_lock_release
  '
  grep -q "could not release the registry lock" <<<"$output"
  local remedy
  remedy="$(grep -oE 'rm -r .*' <<<"$output" | tail -1)"
  [ -n "$remedy" ]
  # Until the remedy runs the lock is still held: a second acquirer cannot take it.
  run env LOCKLIB="$LOCKLIB" TEAM_DIR="$TEAM_DIR" AGMSG_LOCK_SECONDS=1 AGMSG_LOCK_TRIES=5 bash -c '
    . "$LOCKLIB"; agmsg_lock_acquire "$TEAM_DIR"
  '
  [ "$status" -ne 0 ]
  run bash -c "$remedy"
  [ "$status" -eq 0 ]
  run env LOCKLIB="$LOCKLIB" TEAM_DIR="$TEAM_DIR" bash -c '
    . "$LOCKLIB"
    agmsg_lock_acquire "$TEAM_DIR" || exit 1
    agmsg_lock_release
  '
  [ "$status" -eq 0 ]
  [ ! -d "$TEAM_DIR/.config.lock" ]
  # The failed release's record stays at its staged name, inert: no acquirer
  # looks for that name.
  [ "$(ls "$TEAM_DIR"/.config.lock.rel.* 2>/dev/null | wc -l | tr -d " ")" = 1 ]
}

@test "lock: releasing a lock that is already gone stays quiet (#778)" {
  # The other half of the same distinction. A lock that is already released is
  # not an event, and reporting it would train the operator to ignore the line
  # that matters.
  run env LOCKLIB="$LOCKLIB" TEAM_DIR="$TEAM_DIR" bash -c '
    . "$LOCKLIB"
    agmsg_lock_acquire "$TEAM_DIR" || exit 1
    rm -f "$TEAM_DIR"/.config.lock/holder.*; rmdir "$TEAM_DIR/.config.lock"
    agmsg_lock_release
  '
  [ "$status" -eq 0 ]
  refute grep -q "could not release" <<<"$output"
}

@test "lock: the wait is budgeted in seconds, and stops at the declared one (#779)" {
  # The old budget was an attempt count with "= ~10s" written beside it. That
  # arithmetic holds only where an mkdir and a sleep are free: measured here,
  # 100 attempts take 3 seconds, not 1 — and the report that raised this saw
  # minutes on Windows. A wait announced in seconds has to be counted in them.
  mkdir -p "$TEAM_DIR/.config.lock"
  local start end
  start="$(date +%s)"
  # TRIES is set to a number that CANNOT be the thing that stops this: measured
  # on this machine, ~100 attempts take 3 seconds, so 300 would run about nine
  # if the wait were counted in iterations. Only the time bound ends it at two.
  # Deliberately not 1000000 — under a mutation that removes the time bound,
  # that number does not fail the test, it hangs the suite, and a check that
  # hangs instead of reddening is a worse check than one that is slow.
  run env AGMSG_LOCK_SECONDS=2 AGMSG_LOCK_TRIES=300 LOCKLIB="$LOCKLIB" TEAM_DIR="$TEAM_DIR" bash -c '
    . "$LOCKLIB"
    agmsg_lock_acquire "$TEAM_DIR"
  '
  end="$(date +%s)"
  [ "$status" -ne 0 ]
  # Not "roughly": the point of the change is that the number in the message is
  # about the wait. Allow one second of slack for the clock's granularity.
  [ "$((end - start))" -ge 2 ]
  [ "$((end - start))" -le 4 ]
  grep -q "timed out acquiring registry lock" <<<"$output"
  grep -qE "after [0-9]+s" <<<"$output"
}

@test "lock: the attempt ceiling still ends the wait, and says which bound it was (#779)" {
  # Both bounds exist and they are different facts. An operator deciding
  # whether to retry needs the one that actually stopped it — "1000 tries" and
  # "10 seconds" send them to different places.
  mkdir -p "$TEAM_DIR/.config.lock"
  run env AGMSG_LOCK_TRIES=5 AGMSG_LOCK_SECONDS=60 LOCKLIB="$LOCKLIB" TEAM_DIR="$TEAM_DIR" bash -c '
    . "$LOCKLIB"
    agmsg_lock_acquire "$TEAM_DIR"
  '
  [ "$status" -ne 0 ]
  # Same phrase for both bounds — callers match on it. The clause is what
  # separates them, and an operator deciding whether to retry needs the clause.
  grep -q "timed out acquiring registry lock" <<<"$output"
  grep -qE "after 5 attempts" <<<"$output"
  refute grep -qE "after [0-9]+s$" <<<"$output"
}

@test "lock: release leaves a SUCCESSOR's lock alone (#778)" {
  # The hazard this change created. The remedy printed for a stuck lock tells
  # an operator to remove the directory; another process can then take the same
  # path. Releasing on "I once locked this path" would delete the successor's
  # lock and take mutual exclusion away from a process that is using it —
  # worse than the leak (raised in review).
  run env LOCKLIB="$LOCKLIB" TEAM_DIR="$TEAM_DIR" bash -c '
    . "$LOCKLIB"
    agmsg_lock_acquire "$TEAM_DIR" || exit 1
    rm -f "$TEAM_DIR"/.config.lock/holder.*; rmdir "$TEAM_DIR/.config.lock"
    mkdir "$TEAM_DIR/.config.lock"
    printf "token successor-owns-this\n" > "$TEAM_DIR/.config.lock/holder.successor-owns-this"
    agmsg_lock_release
    [ -d "$TEAM_DIR/.config.lock" ] || exit 2
    grep -q "successor-owns-this" "$TEAM_DIR/.config.lock/holder.successor-owns-this" || exit 3
  '
  [ "$status" -eq 0 ]
}

@test "lock: the printed remedy is safe on a path with a space (#778)" {
  # A store root or a team name may contain a space — team names are validated
  # against empty / . / .. / / / \ / a leading - / control characters, and
  # nothing else. An unquoted path in a pasted command becomes several
  # arguments, and `rm -r` then removes something the operator never read about.
  local spaced="$BATS_TEST_TMPDIR/with space/team"
  mkdir -p "$spaced" "$BATS_TEST_TMPDIR/with space/DO-NOT-TOUCH"
  run env LOCKLIB="$LOCKLIB" SPACED="$spaced" bash -c '
    . "$LOCKLIB"
    agmsg_lock_acquire "$SPACED" || exit 1
    printf "x\n" > "$SPACED/.config.lock/stray"
    agmsg_lock_release
  '
  local remedy
  remedy="$(grep -oE "rm -r .*" <<<"$output" | tail -1)"
  [ -n "$remedy" ]
  # Run it the way it is meant to be run: through a shell, as one pasted line.
  run bash -c "$remedy"
  [ "$status" -eq 0 ]
  [ ! -d "$spaced/.config.lock" ]
  # And it took nothing else with it.
  [ -d "$BATS_TEST_TMPDIR/with space/DO-NOT-TOUCH" ]
}

@test "lock: a process holding TWO locks releases both (#778)" {
  # This library's contract is that a caller can hold several locks at once —
  # rename-team takes two. A single per-process token is overwritten by the
  # second acquire, so releasing the first reads a mismatch, calls it someone
  # else's, and leaks it. Measured before the fix: both leaked (raised in
  # review).
  local a="$BATS_TEST_TMPDIR/A" b="$BATS_TEST_TMPDIR/B"
  mkdir -p "$a" "$b"
  run env LOCKLIB="$LOCKLIB" A="$a" B="$b" bash -c '
    . "$LOCKLIB"
    agmsg_lock_acquire "$A" || exit 1
    agmsg_lock_acquire "$B" || exit 1
    agmsg_lock_release
    [ ! -d "$A/.config.lock" ] || exit 2
    [ ! -d "$B/.config.lock" ] || exit 3
  '
  [ "$status" -eq 0 ]
  refute grep -q "not releasing" <<<"$output"
}

@test "lock: a stuck lock keeps saying WHO, not just that it is owned (#778)" {
  # The moment the diagnosis is needed is the moment the removal fails. The
  # record is not put back (the path may belong to a successor by then), so the
  # message itself carries who held it, and the record stays at its staged name.
  run env LOCKLIB="$LOCKLIB" TEAM_DIR="$TEAM_DIR" bash -c '
    . "$LOCKLIB"
    agmsg_lock_acquire "$TEAM_DIR" || exit 1
    printf "x\n" > "$TEAM_DIR/.config.lock/stray"
    agmsg_lock_release 2>&1
  '
  [ "$status" -eq 0 ]
  grep -qE "it was held by: token .* pid [0-9]+ command .* host " <<<"$output"
  [ "$(ls "$TEAM_DIR"/.config.lock.rel.* | wc -l | tr -d ' ')" = 1 ]
  # And nothing was put back into the directory the operator is about to remove.
  [ -z "$(ls "$TEAM_DIR"/.config.lock/ | grep -v '^stray$' || true)" ]
}

@test "lock: two locks taken in the same second by the same pid differ (#778)" {
  # Ownership is decided by this token, so a collision means deleting someone
  # else's successor — the hazard the token exists to close. A pid and a second
  # are not unique across hosts on a shared store.
  local a="$BATS_TEST_TMPDIR/T1" b="$BATS_TEST_TMPDIR/T2"
  mkdir -p "$a" "$b"
  run env LOCKLIB="$LOCKLIB" A="$a" B="$b" bash -c '
    . "$LOCKLIB"
    agmsg_lock_acquire "$A" || exit 1
    agmsg_lock_acquire "$B" || exit 1
    sed -n "s/^token //p" "$A"/.config.lock/holder.* "$B"/.config.lock/holder.*
  '
  [ "$status" -eq 0 ]
  [ "$(sort -u <<<"$output" | grep -c .)" -eq 2 ]
}

@test "lock: with no entropy source, no token is recorded and nothing is removed (#778)" {
  # Fail-safe means NO token, not a weak one. With neither /dev/urandom nor
  # $RANDOM, what is left is host.pid.second — which collides across hosts, and
  # a collision makes this process delete someone else's successor. So the
  # degraded path records nothing, release finds no match, and the lock leaks
  # rather than being taken from whoever holds it (raised in review).
  local lib="$BATS_TEST_TMPDIR/nolib.sh"
  sed -e 's|^ *nonce="\$(LC_ALL=C od.*|nonce=""|' \
      -e 's|^ *\[ -n "\$nonce" \] \|\| nonce=.*|:|' "$LOCKLIB" > "$lib"
  bash -n "$lib"

  run env LIB="$lib" TEAM_DIR="$TEAM_DIR" bash -c '
    . "$LIB"
    agmsg_lock_acquire "$TEAM_DIR" || exit 1
    [ -z "$(ls "$TEAM_DIR"/.config.lock/ 2>/dev/null)" ] || exit 2
    agmsg_lock_release
    [ -d "$TEAM_DIR/.config.lock" ] || exit 3
  '
  [ "$status" -eq 0 ]
  # And the refusal names the real reason rather than accusing another process.
  grep -q "cannot prove the lock is its own" <<<"$output"
}

@test "lock: a failed release is clean under set -u (#778)" {
  # The dead `saved` restore was an unbound-variable error waiting for a caller
  # with `set -u`, and every test here ran without it — so the suite could not
  # have caught it. The reviewer found it by reading. This drives the same path
  # with `set -u` on, which is the shape a real caller has.
  run env LOCKLIB="$LOCKLIB" TEAM_DIR="$TEAM_DIR" SNAP="$BATS_TEST_TMPDIR/holder.before" bash -c '
    set -u
    . "$LOCKLIB"
    agmsg_lock_acquire "$TEAM_DIR" || exit 1
    cp "$TEAM_DIR"/.config.lock/holder.* "$SNAP"
    printf "x\n" > "$TEAM_DIR/.config.lock/stray"
    agmsg_lock_release
  '
  # The release reports the stuck lock and does not abort the caller.
  [ "$status" -eq 0 ]
  grep -q "could not release the registry lock" <<<"$output"
  refute grep -qi "unbound variable" <<<"$output"
  # And the holder is BYTE FOR BYTE what acquire wrote. Checking that `pid` and
  # `command` are present would pass a change that drops `token` or `host`,
  # rewrites a value, reorders the lines, or appends to the file — and the claim
  # being made is that a failed release does not touch it at all (raised in
  # review). The comparison is against a copy taken while the lock was held.
  run diff "$BATS_TEST_TMPDIR/holder.before" "$TEAM_DIR"/.config.lock.rel.*
  [ "$status" -eq 0 ]
}

@test "lock: a successful release does not abort the caller when tidying the staged holder fails (#994)" {
  # #994 review round 3: after a SUCCESSFUL rmdir, the staged holder copy is
  # best-effort cleaned up — its own comment says a failure there is
  # harmless, since nothing looks for a holder under that name again. But an
  # unguarded `command -v rm && rm -f "$staged"` on its own line fails the
  # whole statement when `rm` exists and only the removal itself fails, and
  # under a caller's `set -e` that aborts the process right after the lock
  # was correctly released.
  #
  # Called directly, not through agmsg_lock_release/agmsg_lock_release_one:
  # both of those already wrap the call in `|| true`, and bash suspends
  # `set -e` for the whole duration of a function call made in a
  # non-final position of an AND-OR list — so going through either one
  # would pass regardless of whether this line is guarded, and prove
  # nothing. `_agmsg_lock_drop` has to be safe on its own, not merely safe
  # because its only two callers today happen to shield it.
  #
  # `rm` is overridden as a shell function here (found by `command -v` the
  # same as a real binary) so the failure is exercised without needing an
  # unremovable file.
  run env LOCKLIB="$LOCKLIB" TEAM_DIR="$TEAM_DIR" bash -c '
    set -e
    . "$LOCKLIB"
    rm() { return 1; }
    agmsg_lock_acquire "$TEAM_DIR" || exit 1
    _agmsg_lock_drop "$TEAM_DIR/.config.lock"
    echo survived
  '
  [ "$status" -eq 0 ]
  grep -q "^survived$" <<<"$output"
  [ ! -d "$TEAM_DIR/.config.lock" ]
}

# --- breaking a lock only when its holder is known to be gone (#865) ---------
#
# A killed holder leaves its directory behind and nothing ever removed it, so
# the team stayed wedged until someone deleted it by hand. The record lives INSIDE
# the lock directory as holder.<token> (the token is the generation), and a lock
# is broken only when that one record was written in THIS process table (its
# scope matches) and names a pid that is positively not running.

dead_pid() { sleep 0 & local p=$!; wait "$p" 2>/dev/null || true; printf '%s' "$p"; }

@test "lock: a dead holder's lock is broken; a live holder, another process table, an unusable or missing record are kept (#865)" {
  local gone live lock="$TEAM_DIR/.config.lock"
  gone="$(dead_pid)"
  sleep 30 &
  live=$!
  # CONTROLS: the dead pid is really not running and the live one really is.
  run env PID="$gone" LOCKLIB="$LOCKLIB" bash -c '. "$LOCKLIB"; _agmsg_lock_load_liveness; _agmsg_pid_alive_local "$PID"'
  [ "$status" -ne 0 ]
  run env PID="$live" LOCKLIB="$LOCKLIB" bash -c '. "$LOCKLIB"; _agmsg_lock_load_liveness; _agmsg_pid_alive_local "$PID"'
  [ "$status" -eq 0 ]

  # A live holder: kept.
  mkholder "$lock" t1 "$live" "$SCOPE"
  PRE="$SCOPE_PRE" acquire
  [ "$status" -ne 0 ]
  grep -qF "timed out acquiring registry lock" <<<"$output"
  grep -qF "answered as alive" <<<"$output"
  refute grep -qF "broke a registry lock" <<<"$output"
  [ -f "$lock/holder.t1" ]

  # The same dead number, same HOSTNAME, a DIFFERENT process table: kept. The
  # host name does not say which table a pid belongs to.
  mkholder "$lock" t1 "$gone" "m1:b1:other-pid-namespace"
  PRE="$SCOPE_PRE" acquire
  [ "$status" -ne 0 ]
  refute grep -qF "broke a registry lock" <<<"$output"
  grep -qF "not written on this machine" <<<"$output"
  [ -f "$lock/holder.t1" ]

  # This process cannot name its own table (no machine id, no readlink...): it
  # judges nothing, however the record reads.
  mkholder "$lock" t1 "$gone" "$SCOPE"
  PRE='_agmsg_lock_scope_load() { _AGMSG_LOCK_SCOPE_LOADED=1; _AGMSG_LOCK_SCOPE=""; };' acquire
  [ "$status" -ne 0 ]
  refute grep -qF "broke a registry lock" <<<"$output"
  [ -f "$lock/holder.t1" ]

  # A record with no scope (written where none could be read): kept.
  mkholder "$lock" t1 "$gone"
  PRE="$SCOPE_PRE" acquire
  [ "$status" -ne 0 ]
  refute grep -qF "broke a registry lock" <<<"$output"
  [ -f "$lock/holder.t1" ]

  # A pid that is not a usable number: "cannot tell", never "dead".
  local bad
  for bad in 0 abc 99999999999; do
    mkholder "$lock" t1 "$bad" "$SCOPE"
    PRE="$SCOPE_PRE" acquire
    [ "$status" -ne 0 ]
    refute grep -qF "broke a registry lock" <<<"$output"
    [ -f "$lock/holder.t1" ]
  done

  # A record whose name and content disagree about the generation: kept.
  mkholder "$lock" t1 "$gone" "$SCOPE"
  mv "$lock/holder.t1" "$lock/holder.t2"
  PRE="$SCOPE_PRE" acquire
  [ "$status" -ne 0 ]
  refute grep -qF "broke a registry lock" <<<"$output"
  [ -f "$lock/holder.t2" ]
  rm -f "$lock/holder.t2"

  # Two records: an acquire race caught in the act. Nothing says which is current.
  mkholder "$lock" t1 "$gone" "$SCOPE"
  mkholder "$lock" t2 "$gone" "$SCOPE"
  PRE="$SCOPE_PRE" acquire
  [ "$status" -ne 0 ]
  refute grep -qF "broke a registry lock" <<<"$output"
  grep -qF "more than one holder record" <<<"$output"
  [ -f "$lock/holder.t1" ] && [ -f "$lock/holder.t2" ]
  rm -f "$lock"/holder.*

  # No record at all: kept, and the timeout says how to remove it.
  PRE="$SCOPE_PRE" acquire
  [ "$status" -ne 0 ]
  refute grep -qF "broke a registry lock" <<<"$output"
  grep -qF "records no holder" <<<"$output"
  grep -qF "rmdir" <<<"$output"
  [ -d "$lock" ]
  rmdir "$lock"

  # A dead holder in this process table: broken, and the acquire then succeeds.
  mkholder "$lock" t1 "$gone" "$SCOPE"
  PRE="$SCOPE_PRE" acquire
  [ "$status" -eq 0 ]
  grep -qF "broke a registry lock" <<<"$output"
  kill "$live" 2>/dev/null || true
}

@test "lock: a ps that fails is not proof of death (#970)" {
  local gone lock="$TEAM_DIR/.config.lock"
  gone="$(dead_pid)"
  mkholder "$lock" t1 "$gone" "$SCOPE"
  PRE="$SCOPE_PRE ps() { return 1; };" acquire
  [ "$status" -ne 0 ]
  refute grep -qF "broke a registry lock" <<<"$output"
  [ -f "$lock/holder.t1" ]
}

# --- the generation is bound to the directory --------------------------------

@test "lock: the record dies with its directory, so the printed remedy leaves nothing for a breaker to judge (#865)" {
  local gone lock="$TEAM_DIR/.config.lock"
  gone="$(dead_pid)"
  # A failed release prints `rm -r <lock>`; running it must take the record too.
  mkholder "$lock" t1 "$gone" "$SCOPE"
  printf 'x\n' > "$lock/stray"
  run bash -c "rm -r '$lock'"
  [ "$status" -eq 0 ]
  [ -z "$(ls -A "$TEAM_DIR")" ]
}

@test "lock: an owner that has made the directory but not yet recorded itself is not broken or taken (#865)" {
  # The interleaving the sibling-record layout lost: A has made its directory and
  # not published; a contender arrives. There is no stale record anywhere for it
  # to judge, so it waits.
  PRE="$SCOPE_PRE"'
    _agmsg_lock_test_hook() {
      [ "$1" = acquire:after-mkdir ] || return 0
      [ -z "${B_RAN:-}" ] || return 0; B_RAN=1
      ( AGMSG_LOCK_SECONDS=1 AGMSG_LOCK_TRIES=5 agmsg_lock_acquire "$TEAM_DIR" ) >"$TEAM_DIR/../b.out" 2>&1 && echo B-OWNED >> "$TEAM_DIR/../b.out"
    }' POST='[ -f "$(echo "$TEAM_DIR"/.config.lock/holder.*)" ]' acquire
  [ "$status" -eq 0 ]
  refute grep -q "B-OWNED" "$BATS_TEST_TMPDIR/teams/b.out"
  grep -q "timed out acquiring registry lock" "$BATS_TEST_TMPDIR/teams/b.out"
}

@test "lock: a release whose token read is followed by a successor takeover removes nothing of the successor's (#865)" {
  run env LOCKLIB="$LOCKLIB" TEAM_DIR="$TEAM_DIR" bash -c '
    . "$LOCKLIB"
    agmsg_lock_acquire "$TEAM_DIR" || exit 1
    _agmsg_lock_test_hook() {
      [ "$1" = drop:before-claim ] || return 0
      rm -r "$2"; mkdir "$2"
      printf "token succ\npid 1\n" > "$2/holder.succ"
    }
    agmsg_lock_release
    [ -f "$TEAM_DIR/.config.lock/holder.succ" ] || exit 2
  '
  [ "$status" -eq 0 ]
  refute grep -q "could not release" <<<"$output"
}

@test "lock: a directory removed and retaken between the stage and the rmdir keeps its new owner (#865)" {
  # Stage-then-rmdir is the window an external removal lands in. The successor has
  # published, so its directory is not empty and the rmdir leaves it.
  run env LOCKLIB="$LOCKLIB" TEAM_DIR="$TEAM_DIR" bash -c '
    . "$LOCKLIB"
    agmsg_lock_acquire "$TEAM_DIR" || exit 1
    _agmsg_lock_test_hook() {
      [ "$1" = drop:after-claim ] || return 0
      rm -r "$2"; mkdir "$2"
      printf "token succ\npid 1\n" > "$2/holder.succ"
    }
    agmsg_lock_release
    [ -f "$TEAM_DIR/.config.lock/holder.succ" ] || exit 2
  '
  [ "$status" -eq 0 ]
  refute grep -q "could not release" <<<"$output"
}

@test "lock: a successor that has only made the directory finds its publish fail and starts over (#865)" {
  # The one case an rmdir cannot tell apart: a bare directory. Whoever removes it
  # (a stale release, a breaker) cannot know, so the owner checks: its publish
  # fails, and it makes the directory again instead of believing it holds it.
  PRE="$SCOPE_PRE"'
    _agmsg_lock_test_hook() {
      [ "$1" = acquire:after-mkdir ] || return 0
      [ -z "${DONE:-}" ] || return 0; DONE=1
      rmdir "$2"
    }' POST='[ "$(ls "$TEAM_DIR"/.config.lock/ | wc -l | tr -d " ")" = 1 ] && ls "$TEAM_DIR"/.config.lock/ | grep -q "\.1$"' acquire
  [ "$status" -eq 0 ]
}

@test "lock: a stale breaker whose record was already claimed and replaced removes nothing (#865)" {
  local gone lock="$TEAM_DIR/.config.lock"
  gone="$(dead_pid)"
  mkholder "$lock" old "$gone" "$SCOPE"
  # Between its judgement and its claim, another breaker removes the directory
  # and a successor publishes a live record of its own.
  sleep 30 &
  local live=$!
  run env LOCKLIB="$LOCKLIB" LOCK="$lock" LIVE="$live" SCOPE="$SCOPE" bash -c '
    . "$LOCKLIB"
    _agmsg_lock_scope_load() { _AGMSG_LOCK_SCOPE_LOADED=1; _AGMSG_LOCK_SCOPE="$SCOPE"; }
    _agmsg_lock_test_hook() {
      [ "$1" = break:after-judge ] || return 0
      rm -r "$2"; mkdir "$2"
      printf "token new\npid %s\ncommand t\nhost h\nscope %s\n" "$LIVE" "$SCOPE" > "$2/holder.new"
    }
    ! _agmsg_lock_break_dead "$LOCK"
  '
  kill "$live" 2>/dev/null || true
  [ "$status" -eq 0 ]
  [ -f "$lock/holder.new" ]
}

@test "lock: two breakers of one dead record never hold the lock at the same time (#865)" {
  local gone lock="$TEAM_DIR/.config.lock" i
  gone="$(dead_pid)"
  mkholder "$lock" old "$gone" "$SCOPE"
  # Each contender, once it holds the lock, records that it is inside, stays a
  # moment, and leaves. A second one inside at once leaves a mark. The wait budget
  # is widened: this test is about exclusion, and on a machine where starting a
  # process is slow three turns in a row can exceed the default 10 seconds.
  for i in 1 2 3; do
    ( env AGMSG_LOCK_SECONDS=60 AGMSG_LOCK_TRIES=100000 LOCKLIB="$LOCKLIB" TEAM_DIR="$TEAM_DIR" CS="$BATS_TEST_TMPDIR/cs" LOG="$BATS_TEST_TMPDIR/log.$i" SCOPE="$SCOPE" bash -c '
        . "$LOCKLIB"
        _agmsg_lock_scope_load() { _AGMSG_LOCK_SCOPE_LOADED=1; _AGMSG_LOCK_SCOPE="$SCOPE"; }
        agmsg_lock_acquire "$TEAM_DIR" 2>/dev/null || { echo FAILED > "$LOG"; exit 1; }
        mkdir "$CS" 2>/dev/null || echo OVERLAP >> "$LOG"
        sleep 0.2
        rmdir "$CS" 2>/dev/null
        echo OK >> "$LOG"
        agmsg_lock_release
      ' ) &
  done
  wait
  [ "$(cat "$BATS_TEST_TMPDIR"/log.* | grep -c '^OK$')" -eq 3 ]
  refute grep -q "OVERLAP\|FAILED" "$BATS_TEST_TMPDIR"/log.*
  [ ! -d "$lock" ]
}

@test "lock: an acquirer that finds a second record backs off without taking the first one's directory (#865)" {
  local lock="$TEAM_DIR/.config.lock" other
  sleep 30 &
  other=$!
  # A breaker removed A's bare directory and B made a new one and recorded itself
  # before A's record landed.
  PRE="$SCOPE_PRE"'
    _agmsg_lock_test_hook() {
      [ "$1" = acquire:after-mkdir ] || return 0
      [ -z "${DONE:-}" ] || return 0; DONE=1
      rmdir "$2"; mkdir "$2"
      printf "token b\npid '"$other"'\ncommand t\nhost h\nscope m1:b1:n1\n" > "$2/holder.b"
    }' acquire
  kill "$other" 2>/dev/null || true
  # A could not take it, and said so by waiting out its budget; B's record and
  # directory are untouched, and A left nothing of its own behind.
  [ "$status" -ne 0 ]
  [ -f "$lock/holder.b" ]
  [ "$(ls "$lock" | wc -l | tr -d ' ')" = 1 ]
  [ -z "$(ls -A "$TEAM_DIR" | grep -vx '\.config\.lock' || true)" ]
  # CONTROL: the assertion above does see a leftover under the names a failed
  # attempt would leave (`ls` without -A hides every one of them).
  mkdir "$TEAM_DIR/.config.lock.pub.x"
  [ -n "$(ls -A "$TEAM_DIR" | grep -vx '\.config\.lock' || true)" ]
}

@test "lock: when the record cannot be put in place the directory is taken back, not retried against (#865)" {
  PRE='mv() { case "$2" in */holder.*) return 1 ;; esac; command mv "$@"; };' TRIES=50 acquire
  [ "$status" -ne 0 ]
  grep -q "could not record this process as the holder" <<<"$output"
  refute grep -q "timed out" <<<"$output"
  [ ! -d "$TEAM_DIR/.config.lock" ]
  [ -z "$(ls -A "$TEAM_DIR")" ]
}

@test "lock: a minimal PATH (no dirname, rm, readlink) still acquires and releases, and records no scope (#865)" {
  local bin="$BATS_TEST_TMPDIR/minbin" c
  mkdir -p "$bin"
  for c in mkdir rmdir mv sed head tr od date sort basename paste cat; do
    ln -s "$(command -v "$c")" "$bin/$c"
  done
  run env -i PATH="$bin" LOCKLIB="$LOCKLIB" TEAM_DIR="$TEAM_DIR" /bin/bash --norc -c '
    . "$LOCKLIB"
    agmsg_lock_acquire "$TEAM_DIR" || exit 1
    rec="$(echo "$TEAM_DIR"/.config.lock/holder.*)"
    [ -f "$rec" ] || exit 2
    while IFS= read -r l; do case "$l" in scope*) exit 3 ;; esac; done < "$rec"
    agmsg_lock_release || exit 4
    [ ! -d "$TEAM_DIR/.config.lock" ] || exit 5
  '
  [ "$status" -eq 0 ]
}

@test "lock: the pasted remedy is one literal path even when the team name holds an apostrophe or a metacharacter (#865)" {
  local odd="$BATS_TEST_TMPDIR/teams/x';touch OWNED;'y"
  mkdir -p "$odd/.config.lock"
  run env AGMSG_LOCK_TRIES=3 LOCKLIB="$LOCKLIB" TEAM_DIR="$odd" bash -c '. "$LOCKLIB"; agmsg_lock_acquire "$TEAM_DIR"'
  [ "$status" -ne 0 ]
  local remedy
  remedy="$(grep -oE '^agmsg:   rmdir .*' <<<"$output" | sed 's/^agmsg:   //')"
  [ -n "$remedy" ]
  cd "$BATS_TEST_TMPDIR"
  run bash -c "$remedy"
  [ "$status" -eq 0 ]
  [ ! -d "$odd/.config.lock" ]
  [ ! -e "$BATS_TEST_TMPDIR/OWNED" ]
}

@test "lock: a record's own fields cannot put control characters on the operator's terminal (#865)" {
  local lock="$TEAM_DIR/.config.lock" esc
  esc="$(printf '\033')"
  mkdir -p "$lock"
  printf 'token t1\npid 1\ncommand t\nhost %s]0;owned%s\nscope %s\n' "$esc" "$esc" "$SCOPE" > "$lock/holder.t1"
  PRE="$SCOPE_PRE" acquire
  [ "$status" -ne 0 ]
  grep -q "the lock records:" <<<"$output"
  [ "$(printf '%s' "$output" | LC_ALL=C tr -cd '\033' | wc -c | tr -d ' ')" = 0 ]
}

@test "lock: a token from an earlier hold of the same path is not proof of ownership for a later one that could not make its own (#865)" {
  run env LOCKLIB="$LOCKLIB" TEAM_DIR="$TEAM_DIR" bash -c '
    . "$LOCKLIB"
    agmsg_lock_acquire "$TEAM_DIR" || exit 1
    agmsg_lock_release
    od() { return 1; }
    unset RANDOM
    agmsg_lock_acquire "$TEAM_DIR" || exit 2
    agmsg_lock_release 2>&1
    [ -d "$TEAM_DIR/.config.lock" ] || exit 3
  '
  [ "$status" -eq 0 ]
  grep -q "cannot prove the lock is its own" <<<"$output"
}

@test "lock: acquire, break and release run clean under set -euo pipefail (#865)" {
  local gone
  gone="$(dead_pid)"
  mkholder "$TEAM_DIR/.config.lock" old "$gone" "$SCOPE"
  run env LOCKLIB="$LOCKLIB" TEAM_DIR="$TEAM_DIR" bash -c '
    set -euo pipefail
    . "$LOCKLIB"
    _agmsg_lock_scope_load() { _AGMSG_LOCK_SCOPE_LOADED=1; _AGMSG_LOCK_SCOPE=m1:b1:n1; }
    agmsg_lock_acquire "$TEAM_DIR"
    agmsg_lock_release
    agmsg_lock_acquire "$TEAM_DIR"
    agmsg_lock_release_one "$TEAM_DIR"
    [ ! -d "$TEAM_DIR/.config.lock" ]
    echo survived
  '
  [ "$status" -eq 0 ]
  grep -q "^survived$" <<<"$output"
}

@test "lock: a holder that started a writer to outlive it marks its lock unbreakable, and a dead pid does not break it (#865)" {
  local gone lock="$TEAM_DIR/.config.lock"
  gone="$(dead_pid)"
  # The acquirer that asks for it records `break no`...
  run env LOCKLIB="$LOCKLIB" TEAM_DIR="$TEAM_DIR" bash -c '
    . "$LOCKLIB"
    agmsg_lock_acquire "$TEAM_DIR" unbreakable || exit 1
    cat "$TEAM_DIR"/.config.lock/holder.*
  '
  [ "$status" -eq 0 ]
  grep -qx "break no" <<<"$output"
  # ...and an ordinary acquirer leaves no such line.
  run env LOCKLIB="$LOCKLIB" TEAM_DIR="$TEAM_DIR" bash -c '
    . "$LOCKLIB"
    agmsg_lock_acquire "$TEAM_DIR" || exit 1
    cat "$TEAM_DIR"/.config.lock/holder.*
  '
  refute grep -q "^break" <<<"$output"

  # A dead pid in a record marked `break no` is reported, not broken.
  mkholder "$lock" t1 "$gone" "$SCOPE"
  printf 'break no\n' >> "$lock/holder.t1"
  PRE="$SCOPE_PRE" acquire
  [ "$status" -ne 0 ]
  refute grep -qF "broke a registry lock" <<<"$output"
  grep -qF "not to be broken automatically" <<<"$output"
  [ -f "$lock/holder.t1" ]
}

@test "roster-sync-driver takes its lock as unbreakable (#865)" {
  grep -qE '^agmsg_lock_acquire "\$team_dir" unbreakable$' "$SCRIPTS/internal/roster-sync-driver.sh"
}

@test "lock: a newline in the host name or command cannot add a field to the record, and a doubled or odd break field is not trusted (#865)" {
  local gone lock="$TEAM_DIR/.config.lock"
  gone="$(dead_pid)"
  # A host name carrying `break yes` on a line of its own, from an acquirer that
  # asked for unbreakable: the record must still have exactly one `break` line.
  run env LOCKLIB="$LOCKLIB" TEAM_DIR="$TEAM_DIR" HOSTNAME="$(printf 'node\nbreak yes')" bash -c '
    . "$LOCKLIB"
    agmsg_lock_acquire "$TEAM_DIR" unbreakable || exit 1
    cat "$TEAM_DIR"/.config.lock/holder.*
  '
  [ "$status" -eq 0 ]
  [ "$(grep -c '^break ' <<<"$output")" = 1 ]
  grep -qx "break no" <<<"$output"
  [ "$(grep -c '^host ' <<<"$output")" = 1 ]

  # By hand: two break lines, and a break that says something else. Neither is
  # trusted, so neither lets a dead pid break the lock.
  mkholder "$lock" t1 "$gone" "$SCOPE"
  printf 'break yes\nbreak no\n' >> "$lock/holder.t1"
  PRE="$SCOPE_PRE" acquire
  [ "$status" -ne 0 ]
  refute grep -qF "broke a registry lock" <<<"$output"
  rm -f "$lock/holder.t1"
  mkholder "$lock" t1 "$gone" "$SCOPE"
  printf 'break yes\n' >> "$lock/holder.t1"
  PRE="$SCOPE_PRE" acquire
  [ "$status" -ne 0 ]
  refute grep -qF "broke a registry lock" <<<"$output"
  [ -f "$lock/holder.t1" ]
}

@test "lock: an option the acquire does not know is refused rather than read as unbreakable (#865)" {
  run env LOCKLIB="$LOCKLIB" TEAM_DIR="$TEAM_DIR" bash -c '. "$LOCKLIB"; agmsg_lock_acquire "$TEAM_DIR" unbreakble'
  [ "$status" -ne 0 ]
  grep -q "unknown option" <<<"$output"
  [ ! -d "$TEAM_DIR/.config.lock" ]
}

@test "lock: a directory with no record but something else in it says to look, not to rmdir (#865)" {
  local lock="$TEAM_DIR/.config.lock"
  mkdir -p "$lock"
  printf 'x\\n' > "$lock/stray"
  PRE="$SCOPE_PRE" acquire
  [ "$status" -ne 0 ]
  grep -q "no holder record but is not empty" <<<"$output"
  grep -qE "^agmsg:   ls -la " <<<"$output"
  refute grep -qE "^agmsg:   rmdir " <<<"$output"
}

@test "lock: a newline in the name the script was started as cannot add a field either (#865)" {
  local script="$BATS_TEST_TMPDIR/$(printf 'run\nbreak yes').sh"
  printf '. "%s"\nagmsg_lock_acquire "%s" unbreakable || exit 1\ncat "%s"/.config.lock/holder.*\n' "$LOCKLIB" "$TEAM_DIR" "$TEAM_DIR" > "$script"
  run bash "$script"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^break ' <<<"$output")" = 1 ]
  grep -qx "break no" <<<"$output"
  [ "$(grep -c '^command ' <<<"$output")" = 1 ]
}

@test "lock: a live holder marked break no is alive (not unbreakable), a dead one is unbreakable (#865)" {
  local gone live lock="$TEAM_DIR/.config.lock"
  gone="$(dead_pid)"
  sleep 30 &
  live=$!
  mkholder "$lock" t1 "$live" "$SCOPE"
  printf 'break no\n' >> "$lock/holder.t1"
  run env LOCKLIB="$LOCKLIB" LOCK="$lock" bash -c '
    . "$LOCKLIB"
    _agmsg_lock_scope_load() { _AGMSG_LOCK_SCOPE_LOADED=1; _AGMSG_LOCK_SCOPE=m1:b1:n1; }
    _agmsg_lock_judge "$LOCK" || :
    echo "$_J_VERDICT"
  '
  kill "$live" 2>/dev/null || true
  [ "$output" = alive ]
  rm -f "$lock/holder.t1"
  mkholder "$lock" t1 "$gone" "$SCOPE"
  printf 'break no\n' >> "$lock/holder.t1"
  run env LOCKLIB="$LOCKLIB" LOCK="$lock" bash -c '
    . "$LOCKLIB"
    _agmsg_lock_scope_load() { _AGMSG_LOCK_SCOPE_LOADED=1; _AGMSG_LOCK_SCOPE=m1:b1:n1; }
    _agmsg_lock_judge "$LOCK" || :
    echo "$_J_VERDICT"
  '
  [ "$output" = unbreakable ]
}

@test "lock: two break lines and a single odd break value are each malformed on their own (#865)" {
  local gone lock="$TEAM_DIR/.config.lock" v
  gone="$(dead_pid)"
  mkholder "$lock" t1 "$gone" "$SCOPE"
  printf 'break no\nbreak no\n' >> "$lock/holder.t1"
  run env LOCKLIB="$LOCKLIB" LOCK="$lock" bash -c '
    . "$LOCKLIB"
    _agmsg_lock_scope_load() { _AGMSG_LOCK_SCOPE_LOADED=1; _AGMSG_LOCK_SCOPE=m1:b1:n1; }
    _agmsg_lock_judge "$LOCK" || :
    echo "$_J_VERDICT"
  '
  [ "$output" = malformed ]
  rm -f "$lock/holder.t1"
  mkholder "$lock" t1 "$gone" "$SCOPE"
  printf 'break yes\n' >> "$lock/holder.t1"
  run env LOCKLIB="$LOCKLIB" LOCK="$lock" bash -c '
    . "$LOCKLIB"
    _agmsg_lock_scope_load() { _AGMSG_LOCK_SCOPE_LOADED=1; _AGMSG_LOCK_SCOPE=m1:b1:n1; }
    _agmsg_lock_judge "$LOCK" || :
    echo "$_J_VERDICT"
  '
  [ "$output" = malformed ]
}

@test "lock: nothing but mkdir, mv and rmdir is started between taking a lock and releasing it (#865)" {
  # The time from a successful mkdir to the release is serialised across every
  # contender, and every program started in it is paid by all of them in turn.
  # On a machine where starting a program is slow, three contenders' turns
  # exceeded the wait budget and the last one gave up. The entropy and the
  # process scope are fetched BEFORE the lock is taken; this keeps them there,
  # whatever the machine's speed is, by looking at what runs rather than timing it.
  #
  # The PATH is CLOSED: it holds a recording shim for each program the setup
  # before the lock and the lock's own steps need, and nothing else. A program
  # added to the held interval that is not in that list is "command not found",
  # which fails the run instead of going unrecorded.
  local shims="$BATS_TEST_TMPDIR/shims" log="$BATS_TEST_TMPDIR/spawns" c real
  mkdir -p "$shims"
  : > "$log"
  for c in mkdir mv rmdir od tr date ioreg sysctl shasum sha256sum readlink uname rm; do
    real="$(command -v "$c" 2>/dev/null)" || continue
    printf '#!/bin/bash\necho "%s $*" >> "$SPAWNLOG"\nexec %s "$@"\n' "$c" "$real" > "$shims/$c"
    chmod +x "$shims/$c"
  done
  run env -i SPAWNLOG="$log" PATH="$shims" LOCKLIB="$LOCKLIB" TEAM_DIR="$TEAM_DIR" "$BASH" --norc -c '
    unset HOSTNAME
    . "$LOCKLIB"
    agmsg_lock_acquire "$TEAM_DIR" || exit 1
    echo HELD >> "$SPAWNLOG"
    agmsg_lock_release || exit 2
    echo RELEASED >> "$SPAWNLOG"
  ' </dev/null
  # Any failure below shows what was recorded, so a rare one can be read.
  _dump() { echo "status=$status"; echo "$output"; echo "spawn log:"; cat "$log"; }
  [ "$status" -eq 0 ] || { _dump >&2; false; }
  ! grep -q "not found" <<<"$output" || { _dump >&2; false; }
  # CONTROL: the shims do see the programs that the setup before the lock needs.
  grep -q "^od " "$log" || { _dump >&2; false; }
  # From the mkdir that takes the lock to the rmdir that frees it, only the
  # lock's own three programs run -- and the rmdir has to be there, so an `rm`
  # slipped in before it cannot end the interval early.
  [ -n "$(grep -E '^mkdir .*\.config\.lock$' "$log")" ] || { _dump >&2; false; }
  [ -n "$(grep -E '^rmdir .*\.config\.lock$' "$log")" ] || { _dump >&2; false; }
  [ -z "$(sed -n '/^mkdir .*\.config\.lock$/,/^rmdir .*\.config\.lock$/p' "$log" | grep -Ev '^(mkdir|mv|rmdir) |^HELD$' || true)" ] || { _dump >&2; false; }
}

@test "lock: a caller's own variable named _NOW survives an acquire (#865)" {
  run env LOCKLIB="$LOCKLIB" TEAM_DIR="$TEAM_DIR" bash -c '
    . "$LOCKLIB"
    _NOW=sentinel
    agmsg_lock_acquire "$TEAM_DIR" || exit 1
    agmsg_lock_release
    [ "$_NOW" = sentinel ]
  '
  [ "$status" -eq 0 ]
}

@test "lock: with several IOPlatformUUID lines the first one is the machine id, and the program is read to its end (macOS) (#865)" {
  case "${OSTYPE:-}" in darwin*) ;; *) skip "macOS only" ;; esac
  local shims="$BATS_TEST_TMPDIR/ioshim" boot expected
  mkdir -p "$shims"
  cat > "$shims/ioreg" <<'IOEOF'
#!/bin/bash
echo '    "IOPlatformUUID" = "AAAAAAAA-1111-2222-3333-444444444444"'
echo '    "IOPlatformUUID" = "BBBBBBBB-1111-2222-3333-444444444444"'
echo DONE >> "$IOLOG"
IOEOF
  chmod +x "$shims/ioreg"
  boot="$(sysctl -n kern.bootsessionuuid)"
  expected="$(printf 'agmsg-lock-scope:%s:%s:-' "AAAAAAAA-1111-2222-3333-444444444444" "$boot" | shasum -a 256 | { read -r h _; printf '%s' "$h"; })"
  run env IOLOG="$BATS_TEST_TMPDIR/io.log" PATH="$shims:$PATH" LOCKLIB="$LOCKLIB" bash -c '. "$LOCKLIB"; _agmsg_lock_scope_load; printf "%s" "$_AGMSG_LOCK_SCOPE"'
  [ "$status" -eq 0 ]
  [ "$output" = "$expected" ]
  # The program ran to its end before the scope was returned.
  [ -f "$BATS_TEST_TMPDIR/io.log" ]
}

@test "lock: without SECONDS, and under set -u, the wait still ends at the declared budget (#779)" {
  mkdir -p "$TEAM_DIR/.config.lock"
  local start end
  start="$(date +%s)"
  run env AGMSG_LOCK_SECONDS=2 AGMSG_LOCK_TRIES=100000 LOCKLIB="$LOCKLIB" TEAM_DIR="$TEAM_DIR" bash -c '
    set -u
    . "$LOCKLIB"
    unset SECONDS
    agmsg_lock_acquire "$TEAM_DIR"
  '
  end="$(date +%s)"
  [ "$status" -ne 0 ]
  [ "$((end - start))" -ge 2 ]
  [ "$((end - start))" -le 5 ]
  grep -qE "timed out acquiring registry lock .* after [0-9]+s" <<<"$output"
}

@test "lock: a publish that fails starts nothing but mkdir, mv and rmdir before the directory is freed (#865)" {
  local shims="$BATS_TEST_TMPDIR/shims" log="$BATS_TEST_TMPDIR/spawns" c real
  mkdir -p "$shims"
  : > "$log"
  for c in mkdir mv rmdir od tr date ioreg sysctl shasum sha256sum readlink uname rm; do
    real="$(command -v "$c" 2>/dev/null)" || continue
    if [ "$c" = mv ]; then
      # Fails when the target is a holder record, as a full disk or a permission
      # problem on the directory would.
      printf '#!/bin/bash\necho "mv $*" >> "$SPAWNLOG"\ncase "$2" in */holder.*) exit 1 ;; esac\nexec %s "$@"\n' "$real" > "$shims/$c"
    else
      printf '#!/bin/bash\necho "%s $*" >> "$SPAWNLOG"\nexec %s "$@"\n' "$c" "$real" > "$shims/$c"
    fi
    chmod +x "$shims/$c"
  done
  run env -i SPAWNLOG="$log" PATH="$shims" LOCKLIB="$LOCKLIB" TEAM_DIR="$TEAM_DIR" "$BASH" --norc -c '
    . "$LOCKLIB"
    agmsg_lock_acquire "$TEAM_DIR"
  ' </dev/null
  [ "$status" -ne 0 ]
  grep -q "could not record this process as the holder" <<<"$output"
  [ ! -d "$TEAM_DIR/.config.lock" ]
  [ -n "$(grep -E '^rmdir .*\.config\.lock$' "$log")" ]
  # Up to the rmdir that frees the directory, only the lock's own programs ran.
  [ -z "$(sed -n '/^mkdir .*\.config\.lock$/,/^rmdir .*\.config\.lock$/p' "$log" | grep -Ev '^(mkdir|mv|rmdir) ' || true)" ]
}
