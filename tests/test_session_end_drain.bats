#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
  export SKILL_DIR="$TEST_SKILL_DIR"
  export RUN="$TEST_SKILL_DIR/run"
  export SESSION_ID="drain-session"
  export STEAM="s-$SESSION_ID"
  export PROJ="$TEST_SKILL_DIR/project"
  export TEST_PIDS=""
  mkdir -p "$RUN" "$PROJ"
  bash "$SCRIPTS/config.sh" set delivery.session_team true >/dev/null
  bash "$SCRIPTS/join.sh" "$STEAM" claude claude-code "$PROJ" >/dev/null
  # shellcheck disable=SC1090
  source "$SCRIPTS/lib/actas-lock.sh"
  # shellcheck disable=SC1090
  source "$SCRIPTS/lib/identity-key.sh"
  # shellcheck disable=SC1090
  source "$SCRIPTS/lib/team-lifecycle.sh"

  BRIDGE_STUB="$TEST_SKILL_DIR/bridge-stub.sh"
  cat > "$BRIDGE_STUB" <<'STUB'
#!/usr/bin/env bash
set -u
child=""
finish() {
  [ -n "$child" ] && kill "$child" 2>/dev/null || true
  [ -n "$child" ] && wait "$child" 2>/dev/null || true
  exit 0
}
on_term() {
  printf 'TERM\n' >> "$STUB_EVENTS"
  finish
}
on_usr2() {
  printf 'USR2\n' >> "$STUB_EVENTS"
  [ "${STUB_MODE:-exit-on-usr2}" = exit-on-usr2 ] && finish
}
trap on_term TERM INT
trap on_usr2 USR2
sleep 300 &
child=$!
printf '%s\n' "$child" > "$STUB_CHILD_PID"
printf '%s\n' "$$" > "$STUB_READY"
while kill -0 "$child" 2>/dev/null; do
  wait "$child" 2>/dev/null || true
done
STUB
  chmod +x "$BRIDGE_STUB"
}

teardown() {
  local pid
  for pid in $TEST_PIDS; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  teardown_test_env
}

start_stub_bridge() {
  local name="$1" capability="$2" mode="${3:-exit-on-usr2}" pid record
  local ready="$TEST_SKILL_DIR/$name.ready" child="$TEST_SKILL_DIR/$name.child"
  local events="$TEST_SKILL_DIR/$name.events"
  # bats installs a TERM handler in the test shell. Reset it before forking so
  # the bridge stub can install and exercise its own cleanup handler.
  trap - TERM
  STUB_READY="$ready" STUB_CHILD_PID="$child" STUB_EVENTS="$events" STUB_MODE="$mode" \
    bash "$BRIDGE_STUB" --identity-key "$(agmsg_identity_key "$STEAM" "$name")" &
  pid=$!
  TEST_PIDS="$TEST_PIDS $pid"
  wait_for_file "$ready"
  record="$(printf 'pid:%s\t%s\tcodex' "$pid" "$PROJ")"
  printf '%s\n' "$record" > "$(agmsg_spawn_path "$STEAM" "$name")"
  printf 'pid=%s\n' "$pid" > "$RUN/codex-bridge.$STEAM.$name.meta"
  [ "$capability" = 1 ] && printf 'drain_capable=1\n' >> "$RUN/codex-bridge.$STEAM.$name.meta"
  STUB_PID="$pid"
  STUB_RECORD="$record"
  STUB_EVENTS_PATH="$events"
  STUB_CHILD_PATH="$child"
}

run_worker() {
  local snapshot="$1" instance="${2:-$SESSION_ID}"
  AGMSG_DRAIN_DEADLINE_S="${AGMSG_DRAIN_DEADLINE_S:-3}" \
  AGMSG_DRAIN_LEASE_INTERVAL_S="${AGMSG_DRAIN_LEASE_INTERVAL_S:-1}" \
  AGMSG_DRAIN_LEASE_STALE_S="${AGMSG_DRAIN_LEASE_STALE_S:-3}" \
  AGMSG_DRAIN_POLL_INTERVAL=0.05 \
    bash "$SCRIPTS/session-end-worker.sh" \
      claude-code "$PROJ" "$SESSION_ID" "$instance" "$snapshot"
}

write_snapshot() {
  local path="$1" name="$2" record="$3"
  printf '%s\t%s\n' "$name" "$record" >> "$path"
}

@test "drain fence requires four matching fields and rejects stale or symlinked records" {
  local fence now
  fence="$(agmsg_drain_fence_path "$STEAM")"
  now="$(date +%s)"
  agmsg_drain_fence_create "$fence" nonce owner "$STEAM" "$now"
  agmsg_drain_fence_is_live "$fence" "$STEAM" 3
  [ "$AGMSG_DRAIN_FENCE_NONCE" = nonce ]
  [ "$AGMSG_DRAIN_FENCE_OWNER" = owner ]

  run agmsg_drain_fence_is_live "$fence" other-team 3
  [ "$status" -ne 0 ]
  printf 'nonce=old\nowner=owner\nteam=%s\nlease_epoch=%s\n' "$STEAM" "$((now - 4))" > "$fence"
  run agmsg_drain_fence_is_live "$fence" "$STEAM" 3
  [ "$status" -ne 0 ]

  rm -f "$fence"
  ln -s "$TEST_SKILL_DIR/not-a-fence" "$fence"
  run agmsg_drain_fence_is_live "$fence" "$STEAM" 3
  [ "$status" -ne 0 ]
}

@test "fence lease refresh is owner checked and atomically rewrites all content" {
  local fence now later before
  fence="$(agmsg_drain_fence_path "$STEAM")"
  now="$(date +%s)"
  later=$((now + 1))
  agmsg_drain_fence_create "$fence" nonce owner "$STEAM" "$now"
  before="$(cat "$fence")"
  run agmsg_drain_fence_refresh "$fence" wrong owner "$STEAM" "$later"
  [ "$status" -ne 0 ]
  [ "$(cat "$fence")" = "$before" ]
  agmsg_drain_fence_refresh "$fence" nonce owner "$STEAM" "$later"
  grep -Fxq "lease_epoch=$later" "$fence"
  [ "$(wc -l < "$fence" | tr -d ' ')" -eq 4 ]
}

@test "non-capable bridge gets no USR2 and force cleanup leaves no child orphan" {
  local snapshot="$RUN/noncap.snapshot" pid child
  start_stub_bridge old-worker 0 ignore-usr2
  pid="$STUB_PID"
  child="$(cat "$STUB_CHILD_PATH")"
  write_snapshot "$snapshot" old-worker "$STUB_RECORD"

  run run_worker "$snapshot"
  [ "$status" -eq 0 ]
  run grep -q '^USR2$' "$STUB_EVENTS_PATH"
  [ "$status" -ne 0 ]
  grep -q '^TERM$' "$STUB_EVENTS_PATH"
  run kill -0 "$pid"
  [ "$status" -ne 0 ]
  wait_for_pid_exit "$child"
  [ ! -e "$(agmsg_spawn_path "$STEAM" old-worker)" ]
}

@test "two concurrent workers produce one fence owner and one bridge nudge" {
  local snapshot="$RUN/shared.snapshot" pid w1 w2
  start_stub_bridge capable 1 exit-on-usr2
  pid="$STUB_PID"
  write_snapshot "$snapshot" capable "$STUB_RECORD"
  printf '%s\n' "$SESSION_ID" > "$RUN/watchdog.$STEAM.tombstone"

  run_worker "$snapshot" > "$TEST_SKILL_DIR/worker1.log" 2>&1 & w1=$!
  run_worker "$snapshot" > "$TEST_SKILL_DIR/worker2.log" 2>&1 & w2=$!
  wait "$w1"
  wait "$w2"

  [ "$(grep -c '^USR2$' "$STUB_EVENTS_PATH")" -eq 1 ]
  wait_for_pid_exit "$pid"
  [ ! -e "$(agmsg_spawn_path "$STEAM" capable)" ]
  [ ! -e "$(agmsg_drain_fence_path "$STEAM")" ]
}

@test "missing draining marker never causes force before the common deadline" {
  local snapshot="$RUN/no-marker.snapshot" pid worker
  start_stub_bridge slow-capable 1 ignore-usr2
  pid="$STUB_PID"
  write_snapshot "$snapshot" slow-capable "$STUB_RECORD"
  AGMSG_DRAIN_DEADLINE_S=2 run_worker "$snapshot" > "$TEST_SKILL_DIR/worker.log" 2>&1 &
  worker=$!
  sleep 0.4
  kill -0 "$pid" 2>/dev/null
  [ ! -e "$RUN/draining.${STEAM}__slow-capable.$pid" ]
  wait "$worker"
  run kill -0 "$pid"
  [ "$status" -ne 0 ]
  [ "$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" \
    "SELECT COUNT(*) FROM messages WHERE team='$STEAM' AND to_agent='claude' AND body LIKE '[drain-timeout]%';" \
    | tr -d '\r')" -eq 1 ]
}

@test "replacing a live fence makes the old owner abort without force" {
  local snapshot="$RUN/replaced.snapshot" pid worker fence now
  start_stub_bridge replaced 1 ignore-usr2
  pid="$STUB_PID"
  write_snapshot "$snapshot" replaced "$STUB_RECORD"
  AGMSG_DRAIN_DEADLINE_S=4 run_worker "$snapshot" > "$TEST_SKILL_DIR/worker.log" 2>&1 &
  worker=$!
  fence="$(agmsg_drain_fence_path "$STEAM")"
  wait_for_file "$fence"
  now="$(date +%s)"
  printf 'nonce=replacement\nowner=other\nteam=%s\nlease_epoch=%s\n' "$STEAM" "$now" \
    > "$fence.tmp-test"
  mv "$fence.tmp-test" "$fence"
  wait "$worker"

  kill -0 "$pid" 2>/dev/null
  [ -e "$(agmsg_spawn_path "$STEAM" replaced)" ]
  grep -Fxq 'nonce=replacement' "$fence"
}

@test "meta PID mismatch neither nudges nor kills the unrelated process" {
  local snapshot="$RUN/pid-reuse.snapshot" pid
  start_stub_bridge reused 1 ignore-usr2
  pid="$STUB_PID"
  printf 'pid=999999\ndrain_capable=1\n' > "$RUN/codex-bridge.$STEAM.reused.meta"
  write_snapshot "$snapshot" reused "$STUB_RECORD"

  run run_worker "$snapshot"
  [ "$status" -eq 0 ]
  kill -0 "$pid" 2>/dev/null
  [ ! -s "$STUB_EVENTS_PATH" ]
  [ ! -e "$(agmsg_spawn_path "$STEAM" reused)" ]
}

@test "stale fence takeover is serialized so only one concurrent issuer wins" {
  local snapshot="$RUN/stale.snapshot" pid fence old w1 w2
  start_stub_bridge stale-target 1 exit-on-usr2
  pid="$STUB_PID"
  write_snapshot "$snapshot" stale-target "$STUB_RECORD"
  fence="$(agmsg_drain_fence_path "$STEAM")"
  old=$(( $(date +%s) - 20 ))
  printf 'nonce=stale\nowner=old\nteam=%s\nlease_epoch=%s\n' "$STEAM" "$old" > "$fence"

  run_worker "$snapshot" > "$TEST_SKILL_DIR/stale1.log" 2>&1 & w1=$!
  run_worker "$snapshot" > "$TEST_SKILL_DIR/stale2.log" 2>&1 & w2=$!
  wait "$w1"
  wait "$w2"
  [ "$(grep -c '^USR2$' "$STUB_EVENTS_PATH")" -eq 1 ]
  run kill -0 "$pid"
  [ "$status" -ne 0 ]
}

@test "deleting an owned fence aborts without forcing the capable bridge" {
  local snapshot="$RUN/deleted.snapshot" pid worker fence
  start_stub_bridge deleted 1 ignore-usr2
  pid="$STUB_PID"
  write_snapshot "$snapshot" deleted "$STUB_RECORD"
  AGMSG_DRAIN_DEADLINE_S=4 run_worker "$snapshot" > "$TEST_SKILL_DIR/deleted.log" 2>&1 &
  worker=$!
  fence="$(agmsg_drain_fence_path "$STEAM")"
  wait_for_file "$fence"
  rm -f "$fence"
  wait "$worker"

  kill -0 "$pid" 2>/dev/null
  [ -e "$(agmsg_spawn_path "$STEAM" deleted)" ]
}

@test "symlinking an owned fence aborts without forcing or deleting the replacement" {
  local snapshot="$RUN/symlink.snapshot" pid worker fence target
  start_stub_bridge symlinked 1 ignore-usr2
  pid="$STUB_PID"
  write_snapshot "$snapshot" symlinked "$STUB_RECORD"
  AGMSG_DRAIN_DEADLINE_S=4 run_worker "$snapshot" > "$TEST_SKILL_DIR/symlink.log" 2>&1 &
  worker=$!
  fence="$(agmsg_drain_fence_path "$STEAM")"
  wait_for_file "$fence"
  target="$TEST_SKILL_DIR/replacement-target"
  printf 'not a fence\n' > "$target"
  rm -f "$fence"
  ln -s "$target" "$fence"
  wait "$worker"

  kill -0 "$pid" 2>/dev/null
  [ -L "$fence" ]
  [ -e "$(agmsg_spawn_path "$STEAM" symlinked)" ]
}

@test "drain wait renews the watchdog tombstone with the same owner" {
  local snapshot="$RUN/tombstone.snapshot" worker tombstone first_mtime second_mtime
  start_stub_bridge leased 1 ignore-usr2
  write_snapshot "$snapshot" leased "$STUB_RECORD"
  tombstone="$RUN/watchdog.$STEAM.tombstone"
  AGMSG_DRAIN_DEADLINE_S=3 run_worker "$snapshot" > "$TEST_SKILL_DIR/tombstone.log" 2>&1 &
  worker=$!
  wait_for_file "$tombstone"
  # GNU stat first: BSD stat rejects -c and falls through, while GNU stat
  # "succeeds" on -f with filesystem garbage, so the BSD-first order breaks
  # under the nix devShell PATH.
  first_mtime="$(stat -c '%Y' "$tombstone" 2>/dev/null || stat -f '%m' "$tombstone")"
  sleep 1.4
  second_mtime="$(stat -c '%Y' "$tombstone" 2>/dev/null || stat -f '%m' "$tombstone")"
  [ "$second_mtime" -gt "$first_mtime" ]
  [ "$(cat "$tombstone")" = "$SESSION_ID" ]
  wait "$worker"
}

@test "SessionStart registration serialized before final cleanup makes teardown abort" {
  local snapshot="$RUN/session-start-race.snapshot" pid holder ready publish state
  start_stub_bridge protected 0 ignore-usr2
  pid="$STUB_PID"
  write_snapshot "$snapshot" protected "$STUB_RECORD"
  ready="$TEST_SKILL_DIR/lifecycle-holder.ready"
  publish="$TEST_SKILL_DIR/lifecycle-holder.publish"

  SKILL_DIR="$TEST_SKILL_DIR" STEAM="$STEAM" READY="$ready" PUBLISH="$publish" \
    bash -c '
      source "$SKILL_DIR/scripts/lib/actas-lock.sh"
      source "$SKILL_DIR/scripts/lib/team-lifecycle.sh"
      agmsg_team_lifecycle_lock_acquire "$STEAM" 5 || exit 1
      : > "$READY"
      while [ ! -e "$PUBLISH" ]; do sleep 0.02; done
      state="$SKILL_DIR/run/cc-instance.$$"
      printf "%s\n" "drain-session.new.$$" > "$state"
      agmsg_team_lifecycle_lock_release "$STEAM"
      sleep 2
    ' &
  holder=$!
  TEST_PIDS="$TEST_PIDS $holder"
  wait_for_file "$ready"

  run_worker "$snapshot" > "$TEST_SKILL_DIR/session-start-race.log" 2>&1 &
  sleep 0.2
  : > "$publish"
  wait "$!"

  kill -0 "$pid" 2>/dev/null
  state="$RUN/cc-instance.$holder"
  [ -f "$state" ]
  [ -e "$(agmsg_spawn_path "$STEAM" protected)" ]
  [ ! -e "$(agmsg_drain_fence_path "$STEAM")" ]
}
