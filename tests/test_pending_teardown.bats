#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
  export SKILL_DIR="$TEST_SKILL_DIR"
  export RUN="$TEST_SKILL_DIR/run"
  export PROJ="$TEST_SKILL_DIR/project"
  export SESSION_ID=A11CE-55E
  export STEAM="s-$SESSION_ID"
  export PS_TZ_CAPTURE="$TEST_SKILL_DIR/ps-tz-capture"
  mkdir -p "$RUN" "$PROJ"
  local stub_bin="$TEST_SKILL_DIR/stub-bin"
  mkdir -p "$stub_bin"
  cat > "$stub_bin/ps" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = -o ] && [ "${2:-}" = lstart= ] && [ "${3:-}" = -p ]; then
  [ -z "${PS_TZ_CAPTURE:-}" ] || printf '%s\n' "${TZ:-unset}" >> "$PS_TZ_CAPTURE"
  printf 'Fri Aug 21 00:00:%02d 2026\n' "$(( ${4:-0} % 60 ))"
  exit 0
fi
exec /bin/ps "$@"
STUB
  chmod +x "$stub_bin/ps"
  export PATH="$stub_bin:$PATH"
  bash "$SCRIPTS/config.sh" set delivery.session_team true >/dev/null
  bash "$SCRIPTS/join.sh" "$STEAM" worker codex "$PROJ" >/dev/null
  # shellcheck disable=SC1091
  source "$SCRIPTS/lib/actas-lock.sh"
  # shellcheck disable=SC1091
  source "$SCRIPTS/lib/pending-teardown.sh"
}

teardown() {
  teardown_test_env
}

start_owner() {
  local duration="${1:-300}"
  test_fixture_start_reaped_process sleep "$duration"
  OWNER_PID="$TEST_REAPED_PID"
  OWNER_INSTANCE="$SESSION_ID.$OWNER_PID"
  OWNER_START="$(agmsg_pid_start_token "$OWNER_PID")"
}

start_bridge() {
  test_fixture_start_reaped_process sleep 300
  BRIDGE_PID="$TEST_REAPED_PID"
  BRIDGE_RECORD="$(printf 'pid:%s\t%s\tcodex' "$BRIDGE_PID" "$PROJ")"
  printf '%s\n' "$BRIDGE_RECORD" > "$(agmsg_spawn_path "$STEAM" worker)"
  printf 'pid=%s\n' "$BRIDGE_PID" > "$RUN/codex-bridge.$STEAM.worker.meta"
  BRIDGE_START="$(agmsg_pid_start_token "$BRIDGE_PID")"
}

write_snapshot() {
  SNAPSHOT="$RUN/session-end.snapshot"
  printf 'worker\t%s\n' "$BRIDGE_RECORD" > "$SNAPSHOT"
}

run_composite_worker() {
  env AGMSG_OWNER_EXIT_GRACE_S="${AGMSG_OWNER_EXIT_GRACE_S:-1}" \
    AGMSG_OWNER_EXIT_POLL_INTERVAL=0.05 AGMSG_DRAIN_POLL_INTERVAL=0.05 \
    bash "$SCRIPTS/session-end-worker.sh" claude-code "$PROJ" \
      "$SESSION_ID" "$OWNER_INSTANCE" "$SNAPSHOT"
}

@test "SessionEnd owner alive past grace preserves destructive artifacts and writes pending teardown" {
  start_owner
  start_bridge
  write_snapshot
  test_fixture_start_reaped_process sleep 300
  local watcher_pid="$TEST_REAPED_PID"
  printf '%s\n' "$watcher_pid" > "$RUN/watch.$OWNER_INSTANCE.pid"
  printf '%s\n' "$OWNER_INSTANCE" > "$RUN/cc-instance.$OWNER_PID"
  printf '%s\n' "$OWNER_INSTANCE" > "$(actas_lock_path "$STEAM" worker)"

  run run_composite_worker
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '^session-end-worker: teardown skipped ')" -eq 1 ]
  kill -0 "$OWNER_PID" 2>/dev/null
  kill -0 "$watcher_pid" 2>/dev/null
  kill -0 "$BRIDGE_PID" 2>/dev/null
  [ "$(cat "$RUN/cc-instance.$OWNER_PID")" = "$OWNER_INSTANCE" ]
  [ "$(cat "$(actas_lock_path "$STEAM" worker)")" = "$OWNER_INSTANCE" ]
  [ "$(cat "$(agmsg_spawn_path "$STEAM" worker)")" = "$BRIDGE_RECORD" ]

  local pending
  pending="$(agmsg_pending_teardown_path "$STEAM" worker)"
  [ -f "$pending" ]
  [[ "${pending##*/}" == pending-teardown.* ]]
  [[ "${pending##*/}" != spawn.* ]]
  agmsg_pending_teardown_read "$pending"
  [ "$AGMSG_PENDING_OWNER_STATE" = verified ]
  [ "$AGMSG_PENDING_OWNER_INSTANCE" = "$OWNER_INSTANCE" ]
  [ "$AGMSG_PENDING_OWNER_PID" = "$OWNER_PID" ]
  [ "$AGMSG_PENDING_OWNER_START" = "$OWNER_START" ]
  [ "$AGMSG_PENDING_BRIDGE_START" = "$BRIDGE_START" ]
}

@test "SessionEnd live sibling still writes pending teardown after owner grace" {
  start_owner
  start_bridge
  write_snapshot
  test_fixture_start_reaped_process sleep 300
  local sibling_pid="$TEST_REAPED_PID"
  printf '%s.%s\n' "$SESSION_ID" "$sibling_pid" > "$RUN/cc-instance.$sibling_pid"

  run run_composite_worker
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '^session-end-worker: teardown skipped .*reason=owner-still-alive pending=1 pending_write_failed=0$')" -eq 1 ]
  [ -f "$(agmsg_pending_teardown_path "$STEAM" worker)" ]
  kill -0 "$BRIDGE_PID" 2>/dev/null
  [ -f "$(agmsg_spawn_path "$STEAM" worker)" ]
}

@test "SessionEnd owner exit during grace continues normal teardown" {
  start_owner 0.3
  start_bridge
  write_snapshot

  AGMSG_OWNER_EXIT_GRACE_S=2 run run_composite_worker
  [ "$status" -eq 0 ]
  run kill -0 "$BRIDGE_PID"
  [ "$status" -ne 0 ]
  [ ! -e "$(agmsg_spawn_path "$STEAM" worker)" ]
  [ ! -e "$(agmsg_pending_teardown_path "$STEAM" worker)" ]
}

@test "SessionEnd owner exit just after timeout is completed or recovered without a leak" {
  start_owner
  start_bridge
  write_snapshot

  local pending output_path worker_pid worker_rc=0
  pending="$(agmsg_pending_teardown_path "$STEAM" worker)"
  output_path="$BATS_TEST_TMPDIR/session-end-timeout-race.log"
  AGMSG_OWNER_EXIT_GRACE_S=1 run_composite_worker >"$output_path" 2>&1 &
  worker_pid=$!

  # The atomic pending publish is the timeout boundary. Ending the owner here
  # deliberately races the worker's post-write owner recheck: either that
  # recheck completes teardown immediately, or the pending pass below does.
  wait_for_file "$pending"
  kill "$OWNER_PID" 2>/dev/null || true
  wait "$worker_pid" || worker_rc=$?
  [ "$worker_rc" -eq 0 ]

  if [ -f "$pending" ]; then
    run agmsg_pending_teardown_recover_all "$SCRIPTS/despawn.sh"
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | grep -c "^agmsg: pending teardown recovered team=$STEAM worker=worker reason=owner-dead$")" -eq 1 ]
  fi
  run kill -0 "$BRIDGE_PID"
  [ "$status" -ne 0 ]
  [ ! -e "$pending" ]
}

@test "pending teardown keeps a matching live owner generation" {
  start_owner
  start_bridge
  agmsg_pending_teardown_write "$STEAM" worker codex test-live-owner \
    "$BRIDGE_RECORD" verified "$OWNER_INSTANCE" "$OWNER_PID" "$OWNER_START" \
    "$OWNER_INSTANCE" ""

  run agmsg_pending_teardown_recover_all "$SCRIPTS/despawn.sh"
  [ "$status" -eq 0 ]
  [ "$output" = "agmsg: pending teardown retained team=$STEAM worker=worker owner_pid=$OWNER_PID reason=owner-alive" ]
  kill -0 "$OWNER_PID" 2>/dev/null
  kill -0 "$BRIDGE_PID" 2>/dev/null
  [ -f "$(agmsg_pending_teardown_path "$STEAM" worker)" ]
}

@test "pending teardown retains a dead composite owner while a bare-session sibling is alive" {
  start_bridge
  test_fixture_start_reaped_process sleep 300
  local sibling_pid="$TEST_REAPED_PID"
  local dead_pid=2147483647 dead_instance="$SESSION_ID.2147483647"
  printf '%s.%s\n' "$SESSION_ID" "$sibling_pid" > "$RUN/cc-instance.$sibling_pid"
  agmsg_pending_teardown_write "$STEAM" worker codex test-live-sibling \
    "$BRIDGE_RECORD" verified "$dead_instance" "$dead_pid" ps:dead-owner \
    "$dead_instance" ""

  run agmsg_pending_teardown_recover_all "$SCRIPTS/despawn.sh"
  [ "$status" -eq 0 ]
  [ "$output" = "agmsg: pending teardown retained team=$STEAM worker=worker reason=bare-owner-alive" ]
  kill -0 "$BRIDGE_PID" 2>/dev/null
  [ -f "$(agmsg_spawn_path "$STEAM" worker)" ]
  [ -f "$(agmsg_pending_teardown_path "$STEAM" worker)" ]
}

@test "pending teardown malformed record logs once and never tears down" {
  start_bridge
  local pending
  pending="$(agmsg_pending_teardown_path "$STEAM" worker)"
  printf 'version=2\nbroken=true\n' > "$pending"

  run agmsg_pending_teardown_recover_all "$SCRIPTS/despawn.sh"
  [ "$status" -eq 0 ]
  [ "$output" = "agmsg: pending teardown retained record=${pending##*/} reason=malformed" ]
  kill -0 "$BRIDGE_PID" 2>/dev/null
  [ -f "$pending" ]
}

@test "pending teardown version 1 remains unsupported and non-destructive" {
  start_bridge
  local pending
  pending="$(agmsg_pending_teardown_path "$STEAM" worker)"
  printf 'version=1\n' > "$pending"

  run agmsg_pending_teardown_recover_all "$SCRIPTS/despawn.sh"
  [ "$status" -eq 0 ]
  [ "$output" = "agmsg: pending teardown retained record=${pending##*/} reason=unsupported-version" ]
  kill -0 "$BRIDGE_PID" 2>/dev/null
  [ -f "$(agmsg_spawn_path "$STEAM" worker)" ]
  [ -f "$pending" ]
}

@test "pending teardown PID reuse removes the old worker without signaling the unrelated owner PID" {
  start_owner
  start_bridge
  local owner_method="${OWNER_START%%:*}"
  agmsg_pending_teardown_write "$STEAM" worker codex test-pid-reuse \
    "$BRIDGE_RECORD" verified "$OWNER_INSTANCE" "$OWNER_PID" "$owner_method:old-generation" \
    "$OWNER_INSTANCE" ""

  run agmsg_pending_teardown_recover_all "$SCRIPTS/despawn.sh"
  [ "$status" -eq 0 ]
  [ "$output" = "agmsg: pending teardown recovered team=$STEAM worker=worker reason=owner-replaced" ]
  kill -0 "$OWNER_PID" 2>/dev/null
  run kill -0 "$BRIDGE_PID"
  [ "$status" -ne 0 ]
  [ ! -e "$(agmsg_pending_teardown_path "$STEAM" worker)" ]
}

@test "pending teardown retains an owner token acquired by a different method" {
  start_owner
  start_bridge
  local recorded_start
  case "$OWNER_START" in
    proc:*) recorded_start="ps:different-method" ;;
    *) recorded_start="proc:different-method" ;;
  esac
  agmsg_pending_teardown_write "$STEAM" worker codex test-method-change \
    "$BRIDGE_RECORD" verified "$OWNER_INSTANCE" "$OWNER_PID" "$recorded_start" \
    "$OWNER_INSTANCE" ""

  run agmsg_pending_teardown_recover_all "$SCRIPTS/despawn.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"reason=start-method-unverifiable" ]]
  kill -0 "$OWNER_PID" 2>/dev/null
  kill -0 "$BRIDGE_PID" 2>/dev/null
  [ -f "$(agmsg_pending_teardown_path "$STEAM" worker)" ]
}

@test "pending teardown removes only itself when a live bridge PID was reused" {
  start_bridge
  local dead_pid=2147483647 dead_instance="$SESSION_ID.2147483647"
  local bridge_method="${BRIDGE_START%%:*}"
  agmsg_pending_teardown_write "$STEAM" worker codex test-bridge-pid-reuse \
    "$BRIDGE_RECORD" verified "$dead_instance" "$dead_pid" ps:dead-owner \
    "$dead_instance" "" "$bridge_method:old-bridge"

  run agmsg_pending_teardown_recover_all "$SCRIPTS/despawn.sh"
  [ "$status" -eq 0 ]
  [ "$output" = "agmsg: pending teardown recovered team=$STEAM worker=worker reason=bridge-replaced" ]
  kill -0 "$BRIDGE_PID" 2>/dev/null
  [ -f "$(agmsg_spawn_path "$STEAM" worker)" ]
  [ -f "$RUN/codex-bridge.$STEAM.worker.meta" ]
  [ ! -e "$(agmsg_pending_teardown_path "$STEAM" worker)" ]
}

@test "pending teardown retains a live bridge when its start token is unavailable" {
  start_bridge
  local dead_pid=2147483647 dead_instance="$SESSION_ID.2147483647"
  agmsg_pending_teardown_write "$STEAM" worker codex test-bridge-unavailable \
    "$BRIDGE_RECORD" verified "$dead_instance" "$dead_pid" ps:dead-owner \
    "$dead_instance" ""
  agmsg_pid_start_token() { return 1; }

  run agmsg_pending_teardown_recover_all "$SCRIPTS/despawn.sh"
  [ "$status" -eq 0 ]
  [ "$output" = "agmsg: pending teardown retained team=$STEAM worker=worker bridge_pid=$BRIDGE_PID reason=bridge-start-unavailable" ]
  kill -0 "$BRIDGE_PID" 2>/dev/null
  [ -f "$(agmsg_spawn_path "$STEAM" worker)" ]
  [ -f "$(agmsg_pending_teardown_path "$STEAM" worker)" ]
}

@test "pending teardown keeps a live bridge when the spawn record is already gone" {
  start_owner
  start_bridge
  agmsg_pending_teardown_write "$STEAM" worker codex test-absent-live-bridge \
    "$BRIDGE_RECORD" verified "$OWNER_INSTANCE" "$OWNER_PID" "$OWNER_START" \
    "$OWNER_INSTANCE" ""
  kill "$OWNER_PID" 2>/dev/null || true
  wait "$OWNER_PID" 2>/dev/null || true
  rm -f "$(agmsg_spawn_path "$STEAM" worker)"

  run agmsg_pending_teardown_recover_all "$SCRIPTS/despawn.sh"
  [ "$status" -eq 0 ]
  [ "$output" = "agmsg: pending teardown retained team=$STEAM worker=worker reason=spawn-record-absent" ]
  kill -0 "$BRIDGE_PID" 2>/dev/null
  [ -f "$RUN/codex-bridge.$STEAM.worker.meta" ]
  [ -f "$(agmsg_pending_teardown_path "$STEAM" worker)" ]
}

@test "pending teardown keeps a live old bridge after the spawn record is replaced" {
  start_owner
  start_bridge
  agmsg_pending_teardown_write "$STEAM" worker codex test-replaced-live-bridge \
    "$BRIDGE_RECORD" verified "$OWNER_INSTANCE" "$OWNER_PID" "$OWNER_START" \
    "$OWNER_INSTANCE" ""
  kill "$OWNER_PID" 2>/dev/null || true
  wait "$OWNER_PID" 2>/dev/null || true
  printf 'pid:2147483647\t%s\tcodex\n' "$PROJ" > "$(agmsg_spawn_path "$STEAM" worker)"

  run agmsg_pending_teardown_recover_all "$SCRIPTS/despawn.sh"
  [ "$status" -eq 0 ]
  [ "$output" = "agmsg: pending teardown retained team=$STEAM worker=worker reason=record-replaced-bridge-live" ]
  kill -0 "$BRIDGE_PID" 2>/dev/null
  [ -f "$(agmsg_pending_teardown_path "$STEAM" worker)" ]
}

@test "pending teardown drops an absent target whose bridge is already dead" {
  start_bridge
  agmsg_pending_teardown_write "$STEAM" worker codex test-absent-dead-bridge \
    "$BRIDGE_RECORD" unverified "$SESSION_ID" "" "" "$SESSION_ID" ""
  kill "$BRIDGE_PID" 2>/dev/null || true
  wait "$BRIDGE_PID" 2>/dev/null || true
  rm -f "$(agmsg_spawn_path "$STEAM" worker)"

  run agmsg_pending_teardown_recover_all "$SCRIPTS/despawn.sh"
  [ "$status" -eq 0 ]
  [ "$output" = "agmsg: pending teardown recovered team=$STEAM worker=worker reason=already-absent" ]
  [ ! -e "$(agmsg_pending_teardown_path "$STEAM" worker)" ]
}

@test "pending teardown write does not leak its restrictive umask" {
  start_bridge
  local original_umask after_umask
  original_umask="$(umask)"
  umask 022
  agmsg_pending_teardown_write "$STEAM" worker codex test-umask \
    "$BRIDGE_RECORD" unverified "$SESSION_ID" "" "" "$SESSION_ID" ""
  after_umask="$(umask)"
  umask "$original_umask"
  [ "$after_umask" = 0022 ]
}

@test "pending teardown malformed filename cannot forge a second log line" {
  local pending="$RUN/"$'pending-teardown.bad\nforged__worker'
  printf 'version=2\nbroken=true\n' > "$pending"

  run agmsg_pending_teardown_recover_all "$SCRIPTS/despawn.sh"
  [ "$status" -eq 0 ]
  [ "$output" = "agmsg: pending teardown retained record=pending-teardown.badforged__worker reason=malformed" ]
  [ "${#lines[@]}" -eq 1 ]
  [ -f "$pending" ]
}

@test "pending teardown log visibly truncates an oversized worker identifier to 80 characters" {
  local long_worker expected record pending
  long_worker="$(printf '%90s' '' | tr ' ' x)"
  expected="$(printf '%77s' '' | tr ' ' x)..."
  test_fixture_start_reaped_process sleep 300
  local bridge_pid="$TEST_REAPED_PID"
  record="$(printf 'pid:%s\t%s\tcodex' "$bridge_pid" "$PROJ")"
  printf '%s\n' "$record" > "$(agmsg_spawn_path "$STEAM" "$long_worker")"
  agmsg_pending_teardown_write "$STEAM" "$long_worker" codex test-long-log \
    "$record" unverified "$SESSION_ID" "" "" "$SESSION_ID" ""
  pending="$(agmsg_pending_teardown_path "$STEAM" "$long_worker")"

  run agmsg_pending_teardown_recover_all "$SCRIPTS/despawn.sh"
  [ "$status" -eq 0 ]
  [ "$output" = "agmsg: pending teardown retained team=$STEAM worker=$expected reason=owner-unverified" ]
  [ "${#expected}" -eq 80 ]
  kill -0 "$bridge_pid" 2>/dev/null
  [ -f "$pending" ]
}

@test "SessionStart orphan report exposes an owner-unverified pending record in one candidate line" {
  start_bridge
  agmsg_pending_teardown_write "$STEAM" worker codex test-owner-unverified \
    "$BRIDGE_RECORD" unverified "$SESSION_ID" "" "" "$SESSION_ID" ""

  run bash -c "printf '{\"session_id\":\"other-session\"}' | bash '$SCRIPTS/session-start.sh' claude-code '$PROJ'"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c "^agmsg: orphan candidate team=$STEAM worker=worker bridge_pid=$BRIDGE_PID .*pending_owner=unverified$")" -eq 1 ]
  kill -0 "$BRIDGE_PID" 2>/dev/null
  [ -f "$(agmsg_pending_teardown_path "$STEAM" worker)" ]
}

@test "pending teardown retains when the team lifecycle lock cannot be acquired" {
  start_owner
  start_bridge
  agmsg_pending_teardown_write "$STEAM" worker codex test-lock-unavailable \
    "$BRIDGE_RECORD" verified "$OWNER_INSTANCE" "$OWNER_PID" "$OWNER_START" \
    "$OWNER_INSTANCE" ""
  kill "$OWNER_PID" 2>/dev/null || true
  wait "$OWNER_PID" 2>/dev/null || true
  # shellcheck disable=SC1091
  source "$SCRIPTS/lib/team-lifecycle.sh"
  SKILL_DIR="$TEST_SKILL_DIR" STEAM="$STEAM" bash -c '
    source "$SKILL_DIR/scripts/lib/actas-lock.sh"
    source "$SKILL_DIR/scripts/lib/team-lifecycle.sh"
    agmsg_team_lifecycle_lock_acquire "$STEAM" 5
    sleep 30
  ' &
  local holder=$!
  local waited=0
  while [ "$waited" -lt 50 ]; do
    [ "$(agmsg_runtime_lock_owner "$(agmsg_team_lifecycle_resource "$STEAM")" 2>/dev/null || true)" = "$holder" ] && break
    sleep 0.05
    waited=$((waited + 1))
  done
  [ "$(agmsg_runtime_lock_owner "$(agmsg_team_lifecycle_resource "$STEAM")" 2>/dev/null || true)" = "$holder" ]

  AGMSG_LIFECYCLE_LOCK_TIMEOUT=1 run agmsg_pending_teardown_recover_all "$SCRIPTS/despawn.sh"
  [ "$status" -eq 0 ]
  [ "$output" = "agmsg: pending teardown retained team=$STEAM worker=worker reason=lifecycle-lock-unavailable" ]
  kill -0 "$BRIDGE_PID" 2>/dev/null
  [ -f "$(agmsg_pending_teardown_path "$STEAM" worker)" ]
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
}

@test "pending recover passes the recorded bridge start token to despawn" {
  start_bridge
  local dead_pid=2147483647 dead_instance="$SESSION_ID.2147483647" calls
  calls="$TEST_SKILL_DIR/despawn-args"
  agmsg_pending_teardown_write "$STEAM" worker codex test-expect-start \
    "$BRIDGE_RECORD" verified "$dead_instance" "$dead_pid" ps:dead-owner \
    "$dead_instance" "" "$BRIDGE_START"
  cat > "$SCRIPTS/despawn.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" > "$calls"
exit 0
EOF
  chmod +x "$SCRIPTS/despawn.sh"

  run agmsg_pending_teardown_recover_all "$SCRIPTS/despawn.sh"
  [ "$status" -eq 0 ]
  grep -F -- "--expect-bridge-start $BRIDGE_START" "$calls"
}

@test "bare SessionEnd does not recover a same-team pending live bridge" {
  start_bridge
  local dead_pid=2147483647 dead_instance="$SESSION_ID.2147483647"
  agmsg_pending_teardown_write "$STEAM" worker codex test-bare-session-end \
    "$BRIDGE_RECORD" verified "$dead_instance" "$dead_pid" ps:dead-owner \
    "$dead_instance" "" "$BRIDGE_START"
  write_snapshot

  run env AGMSG_OWNER_EXIT_GRACE_S=1 AGMSG_OWNER_EXIT_POLL_INTERVAL=0.05 \
    bash "$SCRIPTS/session-end-worker.sh" claude-code "$PROJ" \
      "$SESSION_ID" "$SESSION_ID" "$SNAPSHOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"reason=bare-instance-id"* ]]
  kill -0 "$BRIDGE_PID" 2>/dev/null
  [ -f "$(agmsg_pending_teardown_path "$STEAM" worker)" ]
  [ -f "$(agmsg_spawn_path "$STEAM" worker)" ]
}

@test "identity-mismatch despawn status retains the pending recovery anchor" {
  start_bridge
  local dead_pid=2147483647 dead_instance="$SESSION_ID.2147483647"
  agmsg_pending_teardown_write "$STEAM" worker codex test-identity-mismatch \
    "$BRIDGE_RECORD" verified "$dead_instance" "$dead_pid" ps:dead-owner \
    "$dead_instance" "" "$BRIDGE_START"
  cat > "$SCRIPTS/despawn.sh" <<'EOF'
#!/usr/bin/env bash
exit 2
EOF
  chmod +x "$SCRIPTS/despawn.sh"

  run agmsg_pending_teardown_recover_all "$SCRIPTS/despawn.sh"
  [ "$status" -eq 0 ]
  [ "$output" = "agmsg: pending teardown retained team=$STEAM worker=worker reason=recovery-incomplete" ]
  kill -0 "$BRIDGE_PID" 2>/dev/null
  [ -f "$(agmsg_pending_teardown_path "$STEAM" worker)" ]
}

@test "bare SessionStart does not recover another team's pending live bridge" {
  start_bridge
  local dead_pid=2147483647 dead_instance="$SESSION_ID.2147483647"
  agmsg_pending_teardown_write "$STEAM" worker codex test-bare-session-start \
    "$BRIDGE_RECORD" verified "$dead_instance" "$dead_pid" ps:dead-owner \
    "$dead_instance" "" "$BRIDGE_START"

  run env AGMSG_AGENT_PID= bash -c \
    "printf '{\"session_id\":\"other-session\"}' | bash '$SCRIPTS/session-start.sh' claude-code '$PROJ'"
  [ "$status" -eq 0 ]
  kill -0 "$BRIDGE_PID" 2>/dev/null
  [ -f "$(agmsg_pending_teardown_path "$STEAM" worker)" ]
  [ -f "$(agmsg_spawn_path "$STEAM" worker)" ]
}

@test "empty bridge_start pending never despawns after the pid is observed dead" {
  start_bridge
  local dead_pid=2147483647 dead_instance="$SESSION_ID.2147483647"
  local calls="$TEST_SKILL_DIR/despawn-args" pending
  pending="$(agmsg_pending_teardown_path "$STEAM" worker)"
  kill "$BRIDGE_PID" 2>/dev/null || true
  wait_until 5 _pid_gone "$BRIDGE_PID"
  agmsg_pending_teardown_write "$STEAM" worker codex test-empty-start \
    "$BRIDGE_RECORD" verified "$dead_instance" "$dead_pid" ps:dead-owner \
    "$dead_instance" ""
  agmsg_pending_teardown_read "$pending"
  [ -z "$AGMSG_PENDING_BRIDGE_START" ]
  cat > "$SCRIPTS/despawn.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" > "$calls"
exit 0
EOF
  chmod +x "$SCRIPTS/despawn.sh"

  run agmsg_pending_teardown_recover_all "$SCRIPTS/despawn.sh"
  [ "$status" -eq 0 ]
  [ ! -e "$calls" ]
  [[ "$output" == *"reason=bridge-start-unavailable" ]]
  [ -f "$pending" ]
  [ -f "$(agmsg_spawn_path "$STEAM" worker)" ]
}

@test "empty bridge_start pending does not signal a live pid at the recorded placement" {
  start_bridge
  local dead_pid=2147483647 dead_instance="$SESSION_ID.2147483647"
  local calls="$TEST_SKILL_DIR/despawn-args" pending
  pending="$(agmsg_pending_teardown_path "$STEAM" worker)"
  _agmsg_pid_alive() { return 1; }
  agmsg_pending_teardown_write "$STEAM" worker codex test-empty-start-live \
    "$BRIDGE_RECORD" verified "$dead_instance" "$dead_pid" ps:dead-owner \
    "$dead_instance" ""
  unset -f _agmsg_pid_alive
  agmsg_pending_teardown_read "$pending"
  [ -z "$AGMSG_PENDING_BRIDGE_START" ]
  cat > "$SCRIPTS/despawn.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" > "$calls"
exit 0
EOF
  chmod +x "$SCRIPTS/despawn.sh"

  run agmsg_pending_teardown_recover_all "$SCRIPTS/despawn.sh"
  [ "$status" -eq 0 ]
  [ ! -e "$calls" ]
  kill -0 "$BRIDGE_PID" 2>/dev/null
  [ -f "$pending" ]
  [ -f "$(agmsg_spawn_path "$STEAM" worker)" ]
}

@test "unverified pending write does not clobber a verified snapshot" {
  start_owner
  start_bridge
  local pending old
  agmsg_pending_teardown_write "$STEAM" worker codex test-verified-first \
    "$BRIDGE_RECORD" verified "$OWNER_INSTANCE" "$OWNER_PID" "$OWNER_START" \
    "$OWNER_INSTANCE" "" "$BRIDGE_START"
  pending="$(agmsg_pending_teardown_path "$STEAM" worker)"
  old="$(cat "$pending")"
  run agmsg_pending_teardown_write "$STEAM" worker codex test-unverified-second \
    "$BRIDGE_RECORD" unverified "$SESSION_ID" "" "" "$SESSION_ID" ""
  [ "$status" -ne 0 ]
  [ "$(cat "$pending")" = "$old" ]
}

@test "pending recover does not unlink a newer snapshot published during despawn" {
  start_bridge
  local dead_pid=2147483647 dead_instance="$SESSION_ID.2147483647"
  local pending newer spawn_rec
  pending="$(agmsg_pending_teardown_path "$STEAM" worker)"
  spawn_rec="$(agmsg_spawn_path "$STEAM" worker)"
  agmsg_pending_teardown_write "$STEAM" worker codex test-old-snapshot \
    "$BRIDGE_RECORD" verified "$dead_instance" "$dead_pid" ps:dead-owner \
    "$dead_instance" "" "$BRIDGE_START"
  newer="$TEST_SKILL_DIR/newer.pending"
  awk '{ if ($0 ~ /^reason=/) print "reason=newer-snapshot"; else print }' \
    "$pending" > "$newer"
  cat > "$SCRIPTS/despawn.sh" <<EOF
#!/usr/bin/env bash
cat "$newer" > "$pending"
rm -f -- "$spawn_rec"
exit 0
EOF
  chmod +x "$SCRIPTS/despawn.sh"

  run agmsg_pending_teardown_recover_all "$SCRIPTS/despawn.sh"
  [ "$status" -eq 0 ]
  cmp -s "$newer" "$pending"
}
