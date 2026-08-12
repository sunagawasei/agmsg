#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
  export SKILL_DIR="$TEST_SKILL_DIR"
  export RUN="$TEST_SKILL_DIR/run"
  export PROJ="$TEST_SKILL_DIR/project"
  export TEAM="s-A11CE-001"
  export WATCHDOG_NOW_FILE="$TEST_SKILL_DIR/now"
  export WATCHDOG_DATE_STATUS_FILE="$TEST_SKILL_DIR/date-status"
  export WATCHDOG_TOMBSTONE_MTIME_FILE="$TEST_SKILL_DIR/tombstone-mtime"
  export WATCHDOG_CALLS="$TEST_SKILL_DIR/calls"
  export WATCHDOG_MODE=ok
  export TEST_PIDS=""
  mkdir -p "$RUN" "$PROJ"
  printf '1000\n' >"$WATCHDOG_NOW_FILE"
  printf '0\n' >"$WATCHDOG_DATE_STATUS_FILE"
  : >"$WATCHDOG_TOMBSTONE_MTIME_FILE"

  STUB_BIN="$TEST_SKILL_DIR/stub-bin"
  mkdir -p "$STUB_BIN"
  cat >"$STUB_BIN/date" <<'STUB'
#!/usr/bin/env bash
if [ "$#" -eq 1 ] && [ "$1" = +%s ]; then
  cat "$WATCHDOG_NOW_FILE"
  status="$(cat "$WATCHDOG_DATE_STATUS_FILE")"
  exit "$status"
else
  /bin/date "$@"
fi
STUB
  chmod +x "$STUB_BIN/date"

  cat >"$STUB_BIN/stat" <<'STUB'
#!/usr/bin/env bash
last=""
for arg in "$@"; do last="$arg"; done
case "$last" in
  */watchdog.*.tombstone)
    if [ -s "$WATCHDOG_TOMBSTONE_MTIME_FILE" ]; then
      cat "$WATCHDOG_TOMBSTONE_MTIME_FILE"
    else
      cat "$WATCHDOG_NOW_FILE"
    fi
    exit 0
    ;;
esac
exec /usr/bin/stat "$@"
STUB
  chmod +x "$STUB_BIN/stat"
  export PATH="$STUB_BIN:$PATH"

  # shellcheck disable=SC1091
  source "$SCRIPTS/lib/actas-lock.sh"
  # shellcheck disable=SC1091
  source "$SCRIPTS/lib/identity-key.sh"
}

teardown() {
  local pid
  for pid in $TEST_PIDS; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  teardown_test_env
}

join_worker() {
  local name="${1:-worker}" type="${2:-codex}" project="${3:-$PROJ}"
  AGMSG_RESOLVE_PROJECT=0 bash "$SCRIPTS/join.sh" "$TEAM" "$name" "$type" "$project" >/dev/null
}

write_record() {
  local name="$1" pid="$2" type="${3:-codex}" project="${4:-$PROJ}"
  printf 'pid:%s\t%s\t%s\n' "$pid" "$project" "$type" >"$(agmsg_spawn_path "$TEAM" "$name")"
}

set_now() {
  printf '%s\n' "$1" >"$WATCHDOG_NOW_FILE"
}

install_recovery_stubs() {
  cat >"$SCRIPTS/despawn.sh" <<'STUB'
#!/usr/bin/env bash
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
export SKILL_DIR="$root"
source "$root/scripts/lib/actas-lock.sh"
team="$1"; name="$3"; shift 3
expect=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --expect-record) expect="$2"; shift 2 ;;
    *) shift ;;
  esac
done
spawn_rec="$(agmsg_spawn_path "$team" "$name")"
intent="$root/run/watchdog.$team.$name.intent"
{
  printf 'despawn:%s\n' "$name"
  printf 'expect:%s\n' "$expect"
  printf 'token:%s\n' "${AGMSG_WATCHDOG_INTENT_TOKEN:-}"
  IFS= read -r owner <"$intent" 2>/dev/null || owner=""
  printf 'owner:%s\n' "$owner"
} >>"$WATCHDOG_CALLS"
case "${WATCHDOG_MODE:-ok}" in
  record-change)
    printf 'pid:777777\t%s\tcodex\n' "$root/replacement" >"$spawn_rec"
    echo "status=skipped name=$name team=$team reason=record-changed"
    exit 0
    ;;
  delete-intent)
    rm -f "$spawn_rec" "$intent"
    echo "status=forced name=$name team=$team"
    exit 0
    ;;
  tombstone)
    rm -f "$spawn_rec"
    printf 'session-end\n' >"$root/run/watchdog.$team.tombstone"
    echo "status=forced name=$name team=$team"
    exit 0
    ;;
  fail-despawn)
    exit 17
    ;;
  unverified-despawn)
    exit 4
    ;;
  fail-first-despawn)
    [ "$name" = aaa ] && exit 17
    ;;
  compensation-fail)
    if grep -q '^spawn:' "$WATCHDOG_CALLS" 2>/dev/null; then
      exit 17
    fi
    ;;
  timeout-despawn)
    trap '' TERM
    sleep 300 &
    child=$!
    printf '%s %s\n' "$$" "$child" >"$root/run/despawn-timeout.pids"
    wait "$child"
    ;;
  hold-despawn)
    sleep 300 &
    child=$!
    printf '%s %s\n' "$$" "$child" >"$root/run/despawn-timeout.pids"
    for _ in {1..100}; do
      [ -e "$root/run/hold-despawn.release" ] && break
      sleep "$AGMSG_PLACEMENT_LOCK_POLL_INTERVAL"
    done
    [ -e "$root/run/hold-despawn.release" ] || exit 18
    kill "$child" 2>/dev/null || true
    wait "$child" 2>/dev/null || true
    rm -f "$spawn_rec"
    echo "status=forced name=$name team=$team"
    exit 0
    ;;
esac
current="$(cat "$spawn_rec" 2>/dev/null || true)"
if [ "$current" != "$expect" ]; then
  echo "status=skipped name=$name team=$team reason=record-changed"
  exit 0
fi
rm -f "$spawn_rec"
echo "status=forced name=$name team=$team"
STUB
  chmod +x "$SCRIPTS/despawn.sh"

  cat >"$SCRIPTS/spawn.sh" <<'STUB'
#!/usr/bin/env bash
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
export SKILL_DIR="$root"
source "$root/scripts/lib/actas-lock.sh"
type="$1"; name="$2"; shift 2
team=""; project=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --team) team="$2"; shift 2 ;;
    --project) project="$2"; shift 2 ;;
    *) shift ;;
  esac
done
{
  printf 'spawn:%s\n' "$name"
  printf 'shape:%s:%s:%s\n' "$type" "$team" "$project"
} >>"$WATCHDOG_CALLS"
case "${WATCHDOG_MODE:-ok}" in
  fail-spawn) exit 19 ;;
  timeout-spawn)
    # Real spawn joins before a potentially slow bridge launch. Mirror that so
    # the next pass's "still registered" gate can authorize the saved intent.
    AGMSG_RESOLVE_PROJECT=0 bash "$root/scripts/join.sh" \
      "$team" "$name" "$type" "$project" >/dev/null
    trap '' TERM
    sleep 300 &
    child=$!
    printf '%s %s\n' "$$" "$child" >"$root/run/spawn-timeout.pids"
    wait "$child"
    ;;
  delete-intent-during-spawn|compensation-fail)
    rm -f "$root/run/watchdog.$team.$name.intent"
    ;;
  tombstone-during-spawn)
    printf 'session-end\n' >"$root/run/watchdog.$team.tombstone"
    ;;
esac
printf 'pid:999999\t%s\t%s\n' "$project" "$type" >"$(agmsg_spawn_path "$team" "$name")"
exit 0
STUB
  chmod +x "$SCRIPTS/spawn.sh"
}

run_watchdog() {
  run env AGMSG_WATCHDOG_PROCESS_TIMEOUT="${AGMSG_WATCHDOG_PROCESS_TIMEOUT:-5}" \
    AGMSG_WATCHDOG_PROCESS_GRACE="${AGMSG_WATCHDOG_PROCESS_GRACE:-0}" \
    WATCHDOG_MODE="$WATCHDOG_MODE" \
    bash "$SCRIPTS/watchdog.sh" "$TEAM"
}

assert_no_calls() {
  [ ! -s "$WATCHDOG_CALLS" ]
}

@test "watchdog validates exactly one session-team argument before state paths" {
  run bash "$SCRIPTS/watchdog.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Usage"* ]]

  run bash "$SCRIPTS/watchdog.sh" ordinary-team
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a session-team"* ]]

  run bash "$SCRIPTS/watchdog.sh" "$TEAM" extra
  [ "$status" -ne 0 ]
  [[ "$output" == *"Usage"* ]]
  [ ! -e "$RUN/watchdog.ordinary-team.lock" ]
}

@test "dead record reserves exact intent, despawns, reverifies, and respawns with exact line" {
  join_worker worker codex
  local rec
  rec="$(printf 'pid:999999\t%s\tcodex' "$PROJ")"
  printf '%s\n' "$rec" >"$(agmsg_spawn_path "$TEAM" worker)"
  install_recovery_stubs

  run_watchdog
  [ "$status" -eq 0 ]
  [ "$output" = "watchdog: respawned worker (reason=dead)" ]
  grep -Fxq "expect:$rec" "$WATCHDOG_CALLS"
  grep -Eq '^token:watchdog:[0-9]+:1000:[0-9]+$' "$WATCHDOG_CALLS"
  grep -Eq '^owner:owner=watchdog:[0-9]+:1000:[0-9]+$' "$WATCHDOG_CALLS"
  grep -Fxq "shape:codex:$TEAM:$PROJ" "$WATCHDOG_CALLS"
  [ ! -e "$RUN/watchdog.$TEAM.worker.intent" ]
  [ "$(cat "$RUN/watchdog.$TEAM.worker.last")" = 1000 ]
  [ "$(cat "$RUN/watchdog.$TEAM.worker.attempts")" = 1000 ]
}

@test "alive meta-matched placement is skipped and clears recovered rate state" {
  join_worker worker codex
  sleep 300 &
  local pid=$!
  TEST_PIDS="$TEST_PIDS $pid"
  write_record worker "$pid"
  printf 'pid=%s\n' "$pid" >"$RUN/codex-bridge.$TEAM.worker.meta"
  printf '900\n' >"$RUN/watchdog.$TEAM.worker.last"
  printf '800\n' >"$RUN/watchdog.$TEAM.worker.attempts"
  printf 'capped\n' >"$RUN/watchdog.$TEAM.worker.capped"
  install_recovery_stubs

  run_watchdog
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  assert_no_calls
  [ ! -e "$RUN/watchdog.$TEAM.worker.last" ]
  [ ! -e "$RUN/watchdog.$TEAM.worker.attempts" ]
  [ ! -e "$RUN/watchdog.$TEAM.worker.capped" ]
}

@test "meta-absent guard requires exact bridge and identity-key argv tokens" {
  join_worker worker codex
  sleep 300 &
  local pid=$! key
  TEST_PIDS="$TEST_PIDS $pid"
  write_record worker "$pid"
  key="$(agmsg_identity_key "$TEAM" worker)"
  cat >"$STUB_BIN/ps" <<'STUB'
#!/usr/bin/env bash
if [ "$1 $2 $3 $4" = "-o args= -p $LIVE_PID" ]; then
  printf '%s\n' "$PS_ARGS"
  exit 0
fi
exec /bin/ps "$@"
STUB
  chmod +x "$STUB_BIN/ps"
  install_recovery_stubs

  PS_ARGS="bash /x/codex-bridge.js --identity-key $key" LIVE_PID="$pid" run_watchdog
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  assert_no_calls

  PS_ARGS="bash /x/codex-bridge.js.backup --identity-key ${key}suffix" \
    LIVE_PID="$pid" run_watchdog
  [ "$status" -eq 0 ]
  [ "$output" = "watchdog: respawned worker (reason=dead)" ]
}

@test "meta pid mismatch is dead even while the recorded pid is live" {
  join_worker worker cursor
  sleep 300 &
  local pid=$!
  TEST_PIDS="$TEST_PIDS $pid"
  write_record worker "$pid" cursor
  printf 'pid=999999\n' >"$RUN/cursor-bridge.$TEAM.worker.meta"
  install_recovery_stubs

  run_watchdog
  [ "$status" -eq 0 ]
  [ "$output" = "watchdog: respawned worker (reason=dead)" ]
  grep -Fxq "shape:cursor:$TEAM:$PROJ" "$WATCHDOG_CALLS"
}

@test "record replacement, deleted intent, and mid-pass tombstone each abort safely" {
  local mode
  for mode in record-change delete-intent tombstone; do
    # Each case uses its own registered name and state namespace.
    local name="worker-$mode"
    join_worker "$name" codex
    write_record "$name" 999999
  done
  install_recovery_stubs

  WATCHDOG_MODE=record-change run_watchdog
  [ "$status" -eq 0 ]
  ! grep -q '^spawn:' "$WATCHDOG_CALLS"
  [ ! -e "$RUN/watchdog.$TEAM.worker-record-change.intent" ]

  : >"$WATCHDOG_CALLS"
  safe_record="$(agmsg_spawn_path "$TEAM" worker-delete-intent)"
  # Remove other records so the pass isolates this mode.
  rm -f "$(agmsg_spawn_path "$TEAM" worker-record-change)" \
    "$(agmsg_spawn_path "$TEAM" worker-tombstone)"
  WATCHDOG_MODE=delete-intent run_watchdog
  [ "$status" -eq 0 ]
  ! grep -q '^spawn:' "$WATCHDOG_CALLS"
  [ ! -e "$RUN/watchdog.$TEAM.worker-delete-intent.intent" ]
  [ ! -e "$safe_record" ]

  : >"$WATCHDOG_CALLS"
  write_record worker-tombstone 999999
  WATCHDOG_MODE=tombstone run_watchdog
  [ "$status" -eq 0 ]
  ! grep -q '^spawn:' "$WATCHDOG_CALLS"
  [ -e "$RUN/watchdog.$TEAM.tombstone" ]
  [ ! -e "$RUN/watchdog.$TEAM.worker-tombstone.intent" ]
}

@test "post-precheck invalidation and fresh tombstone compensate the exact new record without respawn" {
  join_worker worker-delete-intent-during-spawn codex
  write_record worker-delete-intent-during-spawn 888888
  install_recovery_stubs

  WATCHDOG_MODE=delete-intent-during-spawn run_watchdog
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(grep -c '^despawn:worker-delete-intent-during-spawn$' "$WATCHDOG_CALLS")" -eq 2 ]
  grep -Fxq "$(printf 'expect:pid:999999\t%s\tcodex' "$PROJ")" "$WATCHDOG_CALLS"
  [ ! -e "$(agmsg_spawn_path "$TEAM" worker-delete-intent-during-spawn)" ]
  [ ! -e "$RUN/watchdog.$TEAM.worker-delete-intent-during-spawn.intent" ]

  : >"$WATCHDOG_CALLS"
  join_worker worker-tombstone-during-spawn codex
  write_record worker-tombstone-during-spawn 888888
  WATCHDOG_MODE=tombstone-during-spawn run_watchdog
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(grep -c '^despawn:worker-tombstone-during-spawn$' "$WATCHDOG_CALLS")" -eq 2 ]
  grep -Fxq "$(printf 'expect:pid:999999\t%s\tcodex' "$PROJ")" "$WATCHDOG_CALLS"
  [ ! -e "$(agmsg_spawn_path "$TEAM" worker-tombstone-during-spawn)" ]
  [ ! -e "$RUN/watchdog.$TEAM.worker-tombstone-during-spawn.intent" ]
}

@test "failed post-spawn compensation emits exact notice and leaves no compensation marker" {
  join_worker worker codex
  write_record worker 888888
  install_recovery_stubs
  export WATCHDOG_MODE=compensation-fail

  run_watchdog
  [ "$status" -eq 0 ]
  [ "$output" = "watchdog: compensation incomplete $TEAM/worker" ]
  [ "$(grep -c '^despawn:worker$' "$WATCHDOG_CALLS")" -eq 2 ]
  grep -Fxq "$(printf 'expect:pid:999999\t%s\tcodex' "$PROJ")" "$WATCHDOG_CALLS"
  [ -f "$(agmsg_spawn_path "$TEAM" worker)" ]
  [ ! -e "$RUN/watchdog.$TEAM.worker.intent" ]
  run find "$RUN" -maxdepth 1 -name 'watchdog*.compensation*' -print
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "pre-existing tombstone prevents despawn and spawn" {
  join_worker worker codex
  write_record worker 999999
  printf 'session-end\n' >"$RUN/watchdog.$TEAM.tombstone"
  install_recovery_stubs

  run_watchdog
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  assert_no_calls
  [ -f "$(agmsg_spawn_path "$TEAM" worker)" ]
  [ ! -e "$RUN/watchdog.$TEAM.worker.intent" ]
}

@test "expired or nonaffirmative tombstones fail open instead of wedging recovery" {
  join_worker expired codex
  write_record expired 999999
  printf 'old-session\n' >"$RUN/watchdog.$TEAM.tombstone"
  printf '399\n' >"$WATCHDOG_TOMBSTONE_MTIME_FILE"
  install_recovery_stubs

  run_watchdog
  [ "$status" -eq 0 ]
  [ "$output" = "watchdog: respawned expired (reason=dead)" ]
  grep -q '^spawn:expired$' "$WATCHDOG_CALLS"

  : >"$WATCHDOG_CALLS"
  rm -f "$(agmsg_spawn_path "$TEAM" expired)"
  join_worker malformed codex
  write_record malformed 999999
  printf 'not-one\nline\n' >"$RUN/watchdog.$TEAM.tombstone"
  : >"$WATCHDOG_TOMBSTONE_MTIME_FILE"

  run_watchdog
  [ "$status" -eq 0 ]
  [ "$output" = "watchdog: respawned malformed (reason=dead)" ]
  grep -q '^spawn:malformed$' "$WATCHDOG_CALLS"
}

@test "cooldown skips at 59 seconds and permits at the 60-second boundary" {
  join_worker worker codex
  write_record worker 999999
  printf '941\n' >"$RUN/watchdog.$TEAM.worker.last"
  install_recovery_stubs

  run_watchdog
  [ "$status" -eq 0 ]
  assert_no_calls
  [ -f "$(agmsg_spawn_path "$TEAM" worker)" ]

  set_now 1001
  run_watchdog
  [ "$status" -eq 0 ]
  [ "$output" = "watchdog: respawned worker (reason=dead)" ]
  grep -q '^spawn:worker$' "$WATCHDOG_CALLS"
}

@test "three existing in-window epochs block the fourth and notify once per capped transition" {
  join_worker worker codex
  write_record worker 999999
  printf '998\n999\n' >"$RUN/watchdog.$TEAM.worker.attempts"
  install_recovery_stubs

  run_watchdog
  [ "$status" -eq 0 ]
  [ "$output" = "watchdog: respawned worker (reason=dead)" ]
  [ "$(wc -l <"$RUN/watchdog.$TEAM.worker.attempts" | tr -d ' ')" -eq 3 ]

  : >"$WATCHDOG_CALLS"
  set_now 1060
  run_watchdog
  [ "$status" -eq 0 ]
  [ "$output" = "watchdog: crashloop capped worker (attempts>=3/hour)" ]
  assert_no_calls

  printf '1050\n' >>"$RUN/watchdog.$TEAM.worker.attempts"
  set_now 1120
  run_watchdog
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  assert_no_calls

  # All four epochs expire. This leaves capped state and permits a new attempt.
  set_now 5001
  run_watchdog
  [ "$status" -eq 0 ]
  [ "$output" = "watchdog: respawned worker (reason=dead)" ]
  [ ! -e "$RUN/watchdog.$TEAM.worker.capped" ]
  [ "$(cat "$RUN/watchdog.$TEAM.worker.attempts")" = 5001 ]
}

@test "backward wall-clock movement resets cooldown and attempts without wedging" {
  join_worker worker codex
  write_record worker 999999
  printf '2000\n' >"$RUN/watchdog.$TEAM.worker.last"
  printf '1900\n2000\n2100\n' >"$RUN/watchdog.$TEAM.worker.attempts"
  install_recovery_stubs
  set_now 900

  run_watchdog
  [ "$status" -eq 0 ]
  [ "$output" = "watchdog: respawned worker (reason=dead)" ]
  [ "$(cat "$RUN/watchdog.$TEAM.worker.last")" = 900 ]
  [ "$(cat "$RUN/watchdog.$TEAM.worker.attempts")" = 900 ]
}

@test "numeric date output with nonzero status fails closed before recovery state" {
  join_worker worker codex
  write_record worker 999999
  install_recovery_stubs
  printf '9\n' >"$WATCHDOG_DATE_STATUS_FILE"

  run_watchdog
  printf '0\n' >"$WATCHDOG_DATE_STATUS_FILE"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  assert_no_calls
  [ -f "$(agmsg_spawn_path "$TEAM" worker)" ]
  [ ! -e "$RUN/watchdog.$TEAM.worker.intent" ]
  [ ! -e "$RUN/watchdog.$TEAM.worker.last" ]
  [ ! -e "$RUN/watchdog.$TEAM.worker.attempts" ]
}

@test "malformed process grace falls back instead of preventing recovery subprocesses" {
  join_worker worker codex
  install_recovery_stubs
  local grace now=1000

  for grace in . 1..2 1.2.3; do
    write_record worker 888888
    set_now "$now"
    : >"$WATCHDOG_CALLS"
    AGMSG_WATCHDOG_PROCESS_GRACE="$grace" run_watchdog
    [ "$status" -eq 0 ]
    [ "$output" = "watchdog: respawned worker (reason=dead)" ]
    grep -q '^despawn:worker$' "$WATCHDOG_CALLS"
    grep -q '^spawn:worker$' "$WATCHDOG_CALLS"
    rm -f "$(agmsg_spawn_path "$TEAM" worker)"
    now=$((now + 60))
  done
}

@test "stale, malformed, or unregistered intent never resurrects a worker" {
  join_worker worker codex
  local rec intent
  rec="$(printf 'pid:999999\t%s\tcodex' "$PROJ")"
  intent="$RUN/watchdog.$TEAM.worker.intent"
  printf 'owner=watchdog:123:399:9\ncreated=399\n%s\n' "$rec" >"$intent"
  install_recovery_stubs

  run_watchdog
  [ "$status" -eq 0 ]
  assert_no_calls
  [ ! -e "$intent" ]

  # A fresh-looking intent for a name outside the roster is never enumerated.
  printf 'owner=watchdog:123:1000:9\ncreated=1000\n%s\n' "$rec" \
    >"$RUN/watchdog.$TEAM.unregistered.intent"
  run_watchdog
  [ "$status" -eq 0 ]
  assert_no_calls
  [ ! -e "$RUN/watchdog.$TEAM.unregistered.intent" ]
}

@test "registered fresh intent with absent record resumes at spawn without a second despawn" {
  join_worker worker codex
  local rec="$(
    printf 'pid:999999\t%s\tcodex' "$PROJ"
  )"
  # Age exactly 600 seconds is still a valid recovery anchor.
  printf 'owner=watchdog:123:400:9\ncreated=400\n%s\n' "$rec" \
    >"$RUN/watchdog.$TEAM.worker.intent"
  install_recovery_stubs

  run_watchdog
  [ "$status" -eq 0 ]
  [ "$output" = "watchdog: respawned worker (reason=dead)" ]
  ! grep -q '^despawn:' "$WATCHDOG_CALLS"
  grep -q '^spawn:worker$' "$WATCHDOG_CALLS"
}

@test "one non-timeout worker failure does not stop later registered recovery" {
  join_worker aaa codex
  join_worker zzz cursor
  write_record aaa 999999
  write_record zzz 999998 cursor
  install_recovery_stubs
  export WATCHDOG_MODE=fail-first-despawn

  run_watchdog
  [ "$status" -eq 0 ]
  [ "$output" = $'watchdog: despawn incomplete s-A11CE-001/aaa (status=17)\nwatchdog: respawned zzz (reason=dead)' ]
  grep -q '^despawn:aaa$' "$WATCHDOG_CALLS"
  grep -q '^despawn:zzz$' "$WATCHDOG_CALLS"
  ! grep -q '^spawn:aaa$' "$WATCHDOG_CALLS"
  grep -q '^spawn:zzz$' "$WATCHDOG_CALLS"
  [ -f "$RUN/watchdog.$TEAM.aaa.intent" ]
  [ -f "$(agmsg_spawn_path "$TEAM" aaa)" ]
}

@test "unverified teardown is rate-limited and capped without record loss or respawn" {
  join_worker worker codex
  write_record worker 999999
  install_recovery_stubs
  export WATCHDOG_MODE=unverified-despawn
  local record="$(agmsg_spawn_path "$TEAM" worker)"
  local intent="$RUN/watchdog.$TEAM.worker.intent"
  local attempts="$RUN/watchdog.$TEAM.worker.attempts"
  local last="$RUN/watchdog.$TEAM.worker.last"

  run_watchdog
  [ "$status" -eq 0 ]
  [ "$output" = "watchdog: despawn incomplete $TEAM/worker (status=4)" ]
  [ "$(cat "$attempts")" = 1000 ]
  [ "$(cat "$last")" = 1000 ]
  [ -f "$record" ]
  [ -f "$intent" ]
  ! grep -q '^spawn:' "$WATCHDOG_CALLS"

  : > "$WATCHDOG_CALLS"
  run_watchdog
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  assert_no_calls

  set_now 1060
  run_watchdog
  [ "$status" -eq 0 ]
  [ "$output" = "watchdog: despawn incomplete $TEAM/worker (status=4)" ]
  [ "$(cat "$attempts")" = $'1000\n1060' ]
  [ "$(cat "$last")" = 1060 ]

  : > "$WATCHDOG_CALLS"
  set_now 1120
  run_watchdog
  [ "$status" -eq 0 ]
  [ "$output" = "watchdog: despawn incomplete $TEAM/worker (status=4)" ]
  [ "$(cat "$attempts")" = $'1000\n1060\n1120' ]

  : > "$WATCHDOG_CALLS"
  set_now 1180
  run_watchdog
  [ "$status" -eq 0 ]
  [ "$output" = "watchdog: crashloop capped worker (attempts>=3/hour)" ]
  assert_no_calls
  [ -f "$record" ]
  [ -f "$intent" ]
}

@test "only registered names in the requested team are inspected" {
  join_worker worker codex
  write_record worker 999999
  local other='s-B0B-002'
  AGMSG_RESOLVE_PROJECT=0 bash "$SCRIPTS/join.sh" "$other" outsider codex "$PROJ" >/dev/null
  printf 'pid:999999\t%s\tcodex\n' "$PROJ" >"$RUN/spawn.${other}__outsider"
  printf 'pid:999999\t%s\tcodex\n' "$PROJ" >"$RUN/spawn.${TEAM}__ghost"
  install_recovery_stubs

  run_watchdog
  [ "$status" -eq 0 ]
  grep -q '^spawn:worker$' "$WATCHDOG_CALLS"
  ! grep -q 'outsider' "$WATCHDOG_CALLS"
  ! grep -q 'ghost' "$WATCHDOG_CALLS"
  [ -f "$RUN/spawn.${other}__outsider" ]
  [ -f "$RUN/spawn.${TEAM}__ghost" ]
}

@test "non-blocking team flock makes a concurrent pass a successful no-op" {
  join_worker worker codex
  write_record worker 999999
  install_recovery_stubs
  export WATCHDOG_MODE=hold-despawn
  export AGMSG_WATCHDOG_PROCESS_TIMEOUT=5
  export AGMSG_WATCHDOG_PROCESS_GRACE=0

  bash "$SCRIPTS/watchdog.sh" "$TEAM" >"$RUN/first.out" 2>"$RUN/first.err" &
  local first=$!
  TEST_PIDS="$TEST_PIDS $first"
  wait_for_file "$RUN/watchdog.$TEAM.worker.intent"
  wait_for_file "$WATCHDOG_CALLS"

  run_watchdog
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(grep -c '^despawn:worker$' "$WATCHDOG_CALLS")" -eq 1 ]

  run env AGMSG_WATCHDOG_LOCK_TOKEN=caller-spoof \
    AGMSG_WATCHDOG_PROCESS_TIMEOUT=5 AGMSG_WATCHDOG_PROCESS_GRACE=0 \
    WATCHDOG_MODE="$WATCHDOG_MODE" bash "$SCRIPTS/watchdog.sh" "$TEAM"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(grep -c '^despawn:worker$' "$WATCHDOG_CALLS")" -eq 1 ]

  run bash -c '
    exec 7<<<caller-spoof
    export AGMSG_WATCHDOG_LOCK_TOKEN=caller-spoof
    export AGMSG_WATCHDOG_PROCESS_TIMEOUT=5
    export AGMSG_WATCHDOG_PROCESS_GRACE=0
    exec bash "$1" "$2"
  ' watchdog-forge "$SCRIPTS/watchdog.sh" "$TEAM"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(grep -c '^despawn:worker$' "$WATCHDOG_CALLS")" -eq 1 ]

  : > "$RUN/hold-despawn.release"
  wait "$first"
  TEST_PIDS="${TEST_PIDS/ $first/}"
  [ "$(grep -c '^spawn:worker$' "$WATCHDOG_CALLS")" -eq 1 ]
}

@test "despawn timeout kills its whole group, aborts the pass, and next pass recovers" {
  join_worker aaa codex
  join_worker zzz cursor
  write_record aaa 999999
  write_record zzz 999998 cursor
  install_recovery_stubs
  export WATCHDOG_MODE=timeout-despawn
  export AGMSG_WATCHDOG_PROCESS_TIMEOUT=1
  export AGMSG_WATCHDOG_PROCESS_GRACE=0

  run_watchdog
  [ "$status" -eq 0 ]
  [ "$output" = "watchdog: despawn incomplete $TEAM/aaa (status=124)" ]
  [ -f "$RUN/watchdog.$TEAM.aaa.intent" ]
  ! grep -q '^spawn:' "$WATCHDOG_CALLS"
  ! grep -q '^despawn:zzz$' "$WATCHDOG_CALLS"
  read -r parent child <"$RUN/despawn-timeout.pids"
  wait_for_pid_exit "$parent"
  wait_for_pid_exit "$child"

  : >"$WATCHDOG_CALLS"
  WATCHDOG_MODE=ok run_watchdog
  [ "$status" -eq 0 ]
  [[ "$output" == *"watchdog: respawned aaa (reason=dead)"* ]]
  [[ "$output" == *"watchdog: respawned zzz (reason=dead)"* ]]
}

@test "spawn timeout kills its whole group, leaves intent, and a later pass resumes it" {
  join_worker worker codex
  write_record worker 999999
  install_recovery_stubs
  export WATCHDOG_MODE=timeout-spawn
  export AGMSG_WATCHDOG_PROCESS_TIMEOUT=1
  export AGMSG_WATCHDOG_PROCESS_GRACE=0

  run_watchdog
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -f "$RUN/watchdog.$TEAM.worker.intent" ]
  [ ! -e "$(agmsg_spawn_path "$TEAM" worker)" ]
  read -r parent child <"$RUN/spawn-timeout.pids"
  wait_for_pid_exit "$parent"
  wait_for_pid_exit "$child"

  : >"$WATCHDOG_CALLS"
  set_now 1060
  WATCHDOG_MODE=ok run_watchdog
  [ "$status" -eq 0 ]
  [ "$output" = "watchdog: respawned worker (reason=dead)" ]
  ! grep -q '^despawn:' "$WATCHDOG_CALLS"
  grep -q '^spawn:worker$' "$WATCHDOG_CALLS"
}

@test "plain despawn deletes a pending intent while watchdog-owned despawn preserves it" {
  join_worker worker codex
  local rec intent token=owned
  rec="$(printf 'pid:999999\t%s\tcodex' "$PROJ")"
  printf '%s\n' "$rec" >"$(agmsg_spawn_path "$TEAM" worker)"
  intent="$RUN/watchdog.$TEAM.worker.intent"
  printf 'owner=%s\ncreated=1000\n%s\n' "$token" "$rec" >"$intent"

  run env AGMSG_WATCHDOG_INTENT_TOKEN="$token" \
    bash "$SCRIPTS/despawn.sh" "$TEAM" claude worker --force --expect-record stale
  [ "$status" -eq 0 ]
  [ -f "$intent" ]

  printf 'owner=replacement\ncreated=1000\n%s\n' "$rec" >"$intent"
  run env AGMSG_WATCHDOG_INTENT_TOKEN="$token" \
    bash "$SCRIPTS/despawn.sh" "$TEAM" claude worker --force --expect-record stale
  [ "$status" -eq 0 ]
  [ -f "$intent" ]
  grep -Fxq 'owner=replacement' "$intent"

  run bash "$SCRIPTS/despawn.sh" "$TEAM" claude worker --force --expect-record stale
  [ "$status" -eq 0 ]
  [ ! -e "$intent" ]
}
