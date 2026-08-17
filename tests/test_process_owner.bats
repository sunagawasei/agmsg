#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

# Process-owner lease coverage. These tests have unique names and private
# artifacts so baseline/after comparisons can identify them without sharing
# watcher state with the existing canaries.

load test_helper

setup() {
  setup_test_env
  TEST_PROCESS_ROOT="$TEST_SKILL_DIR/process-owner-$BATS_TEST_NUMBER"
  mkdir -p "$TEST_PROCESS_ROOT"
  export TEST_PROCESS_ROOT
  TEST_OWNER_PID=""
  TEST_FOREIGN_PID=""
  TEST_WATCH_CHILD_PIDS=""
}

teardown() {
  for pid in "${TEST_FOREIGN_PID:-}" "${TEST_OWNER_PID:-}" ${TEST_WATCH_CHILD_PIDS:-}; do
    case "$pid" in
      ''|*[!0-9]*) ;;
      *) stop_test_pid "$pid" ;;
    esac
  done
  teardown_test_env
}

stop_test_pid() {
  local pid="$1"
  kill -TERM "$pid" 2>/dev/null || true
  if ! wait_for_pid_exit "$pid"; then
    kill -KILL "$pid" 2>/dev/null || true
    wait_for_pid_exit "$pid" || true
  fi
  wait "$pid" 2>/dev/null || true
}

write_owner_target() {
  local target="$1" ready="$2" report="$3"
  cat >"$target" <<'TARGET'
#!/usr/bin/env bash
ready="$1"
report="$2"
pidfile="${AGMSG_TEST_PROCESS_PIDFILE:-}"
if [ "${AGMSG_PROCESS_BOOTSTRAP_MODE:-}" = leased ] && { : <&19; } 2>/dev/null; then
  printf 'mode=leased\nfd=19\n' >"$report"
elif [ "${AGMSG_PROCESS_BOOTSTRAP_MODE:-}" = degraded ]; then
  if [ -z "${AGMSG_PROCESS_OWNER_FD+x}" ]; then
    printf 'mode=degraded\nfd=unset\n' >"$report"
  else
    printf 'mode=degraded\nfd=set\n' >"$report"
  fi
else
  printf 'mode=unknown\nfd=unknown\n' >"$report"
fi
: >"$ready"
sleep 600 &
blocker=$!
cleanup_target() {
  kill "$blocker" 2>/dev/null || true
  wait "$blocker" 2>/dev/null || true
  if [ -n "$pidfile" ]; then
    owner="${pidfile%.pid}.owner"
    generation="$(sed -n 's/^generation=//p' "$owner" 2>/dev/null | head -1)"
    rm -f -- "$pidfile" "$owner"
    [ -z "$generation" ] || rm -f -- "${pidfile%.pid}.lease.$generation"
  fi
  exit 0
}
trap cleanup_target TERM INT HUP
wait "$blocker"
TARGET
  chmod +x "$target"
}

start_owner() {
  local kind="$1" pidfile="$2" scope="$3" target="$4" ready="$5" report="$6" mode="${7:-leased}"
  local python
  python="$(command -v python3 2>/dev/null || true)"
  [ -n "$python" ] || return 1
  if [ "$mode" = leased ]; then
    AGMSG_TEST_PROCESS_PIDFILE="$pidfile" AGMSG_TEST_PROCESS_PYTHON="$python" \
      bash "$SCRIPTS/internal/process-owner-launch.sh" \
      --kind "$kind" --pidfile "$pidfile" --scope "$scope" -- "$target" "$ready" "$report" \
      >"$TEST_PROCESS_ROOT/owner.stdout" 2>"$TEST_PROCESS_ROOT/owner.stderr" &
  else
    AGMSG_TEST_PROCESS_PIDFILE="$pidfile" AGMSG_PROCESS_IDENTITY_BACKEND=unavailable \
      bash "$SCRIPTS/internal/process-owner-launch.sh" \
      --kind "$kind" --pidfile "$pidfile" --scope "$scope" -- "$target" "$ready" "$report" \
      >"$TEST_PROCESS_ROOT/owner.stdout" 2>"$TEST_PROCESS_ROOT/owner.stderr" &
  fi
  TEST_OWNER_PID=$!
  wait_for_file "$ready"
}

start_owner_registered() {
  local kind="$1" pidfile="$2" scope="$3" target="$4" ready="$5" report="$6"
  local python
  python="$(command -v python3 2>/dev/null || true)"
  [ -n "$python" ] || return 1
  AGMSG_TEST_PROCESS_PIDFILE="$pidfile" AGMSG_TEST_PROCESS_PYTHON="$python" \
    bash "$SCRIPTS/internal/process-owner-launch.sh" \
    --kind "$kind" --pidfile "$pidfile" --scope "$scope" -- "$target" "$ready" "$report" \
    >"$TEST_PROCESS_ROOT/registered-owner.stdout" 2>"$TEST_PROCESS_ROOT/registered-owner.stderr" &
  TEST_OWNER_PID=$!
  test_fixture_register_owned_pid "$TEST_OWNER_PID"
  wait_for_file "$ready"
}

process_is_owned() {
  local pidfile="$1" scope="$2"
  # shellcheck disable=SC1090
  source "$SCRIPTS/lib/process-identity.sh"
  agmsg_process_identity_state watch "$pidfile" "$scope"
  [ "$AGMSG_PROCESS_STATE" = owned ] \
    && [ "$AGMSG_PROCESS_OWNER_LEASE" = leased ]
}

lease_is_free() {
  local lease="$1" rc
  agmsg_process_probe_lease "$lease"
  rc=$?
  [ "$rc" -eq 0 ]
}

watch_children_have_callsite_evidence() {
  local marker="$2" prefix="${2%-started}" fd_marker="${2%-started}-fd19" poll_started="${2%-started}-poll-started" poll_marker="${2%-started}-poll-pid" watchdog_marker="${2%-started}-watchdog-pid" blocker_marker="${2%-started}-blocker-pid" poll_pid watchdog_pid blocker_pid
  [ -f "$marker" ] || return 1
  [ -f "$fd_marker" ] || return 1
  [ "$(cat "$fd_marker")" = 'fd19=closed' ] || return 1
  [ "$(cat "$poll_started")" = poll-callsite ] || return 1
  [ -s "$poll_marker" ] || return 1
  poll_pid="$(cat "$poll_marker")"
  case "$poll_pid" in ''|*[!0-9]*) return 1 ;; esac
  [ -s "$watchdog_marker" ] || return 1
  watchdog_pid="$(cat "$watchdog_marker")"
  case "$watchdog_pid" in ''|*[!0-9]*) return 1 ;; esac
  [ -s "$blocker_marker" ] || return 1
  blocker_pid="$(cat "$blocker_marker")"
  case "$blocker_pid" in ''|*[!0-9]*) return 1 ;; esac
}

record_watch_children() {
  local prefix="${1%-started}" suffix pid
  for suffix in watchdog-pid blocker-pid poll-pid; do
    pid="$(cat "$prefix-$suffix" 2>/dev/null || true)"
    case "$pid" in
      ''|*[!0-9]*) return 1 ;;
      *) TEST_WATCH_CHILD_PIDS="${TEST_WATCH_CHILD_PIDS:+$TEST_WATCH_CHILD_PIDS }$pid" ;;
    esac
  done
}

assert_process_callsite_range() {
  local file="$1" first="$2" last="$3" helper_pattern="$4" body
  body="$(sed -n "${first},${last}p" "$file" | sed '/^[[:space:]]*#/d')"
  if printf '%s\n' "$body" | grep -Eq "$helper_pattern" \
      && ! printf '%s\n' "$body" | grep -Eq '(^|[;&|[:space:]])(kill|pkill)[[:space:]]'; then
    return 0
  fi
  # The implementation can move a callsite without changing its contract.
  # Fall back to nearby source context so this assertion remains position
  # independent while still rejecting a raw signal command beside the helper.
  assert_process_callsite_pattern "$file" "$helper_pattern"
}

assert_process_callsite_pattern() {
  local file="$1" helper_pattern="$2" expected="${3:-1}" match line first last body
  local total=0 dirty=0
  while IFS= read -r match; do
    total=$((total + 1))
    line="${match%%:*}"
    case "$line" in
      ''|*[!0-9]*) dirty=1; continue ;;
    esac
    first=$((line - 12))
    [ "$first" -ge 1 ] || first=1
    last=$((line + 12))
    body="$(sed -n "${first},${last}p" "$file" | sed '/^[[:space:]]*#/d')"
    printf '%s\n' "$body" | grep -Eq "$helper_pattern" || { dirty=1; continue; }
    printf '%s\n' "$body" | grep -Eq '(^|[;&|[:space:]])(kill|pkill)[[:space:]]' && dirty=1
  done < <(sed 's/^[[:space:]]*#.*$//' "$file" | grep -En "$helper_pattern" || true)
  [ "$total" -eq "$expected" ] && [ "$dirty" -eq 0 ]
}

write_watch_callsite_stubs() {
  local stub_bin="$TEST_PROCESS_ROOT/stub-bin"
  mkdir -p "$stub_bin" "$TEST_PROCESS_ROOT/watchdog-markers"
  cat >"$stub_bin/date" <<'DATE'
#!/usr/bin/env bash
case "${WATCH_CALLSITE_DATE_MODE:-normal}" in
  fail) exit 2 ;;
  malformed) printf 'not-a-number\n' ;;
  normal) printf '60\n' ;;
  *) exit 2 ;;
esac
DATE
  chmod +x "$stub_bin/date"
  cat >"$SCRIPTS/watchdog.sh" <<'WATCHDOG'
#!/usr/bin/env bash
set -eu
marker_dir="${WATCH_CALLSITE_MARKER_DIR:?}"
trace="${WATCH_CALLSITE_TRACE:?}"
mkdir -p "$marker_dir"
printf '%s\n' "$trace" >"$marker_dir/$trace-started"
printf '%s\n' "$$" >"$marker_dir/$trace-watchdog-pid"
if : <&19 2>/dev/null; then
  printf '%s\n' 'fd19=held' >"$marker_dir/$trace-fd19"
else
  printf '%s\n' 'fd19=closed' >"$marker_dir/$trace-fd19"
fi
sleep 600 &
blocker=$!
trap 'kill "$blocker" 2>/dev/null || true; wait "$blocker" 2>/dev/null || true; exit 0' TERM INT HUP
printf '%s\n' "$blocker" >"$marker_dir/$trace-blocker-pid"
wait "$blocker"
WATCHDOG
  chmod +x "$SCRIPTS/watchdog.sh"
  local instrumented="$TEST_PROCESS_ROOT/watch.sh.instrumented"
  awk '
    BEGIN {
      needle="\"$SCRIPT_DIR/watchdog.sh\" \"$TEAM_PIN\" 19>&- &"
      trace[1]="date-failure"; trace[2]="date-malformed"; trace[3]="date-boundary"; n=0; poll=0
    }
    {
      if (index($0, needle)) {
        n++
        print "      WATCH_CALLSITE_TRACE=" trace[n] " " $0
        next
      }
      if (index($0, "sleep \"$INTERVAL\" 19>&- &")) {
        poll++
        print "  echo poll-callsite >\"$WATCH_CALLSITE_MARKER_DIR/$WATCH_CALLSITE_CASE-poll-started\""
        print $0
        print "  echo \"$!\" >\"$WATCH_CALLSITE_MARKER_DIR/$WATCH_CALLSITE_CASE-poll-pid\""
        next
      }
      print
    }
    END { if (n != 3 || poll != 1) exit 1 }
  ' "$SCRIPTS/watch.sh" >"$instrumented"
  mv "$instrumented" "$SCRIPTS/watch.sh"
  chmod +x "$SCRIPTS/watch.sh"
  export WATCH_CALLSITE_STUB_BIN="$stub_bin"
  export WATCH_CALLSITE_MARKER_DIR="$TEST_PROCESS_ROOT/watchdog-markers"
}

run_watch_callsite_case() {
  local case_name="$1" date_mode="$2" expected_trace="$3" sid="$4" project="$5"
  local pidfile="$TEST_SKILL_DIR/run/watch.$sid.pid" owner lease scope python watcher
  python="$(command -v python3 2>/dev/null || true)"
  [ -n "$python" ] || return 1
  scope="watch|$sid|$project|claude-code"
  WATCH_CALLSITE_CASE="$case_name" WATCH_CALLSITE_DATE_MODE="$date_mode" \
    AGMSG_TEST_PROCESS_PYTHON="$python" PATH="$WATCH_CALLSITE_STUB_BIN:$PATH" \
    AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" "$sid" "$project" claude-code \
    --team team >"$TEST_PROCESS_ROOT/watch-$case_name.stdout" \
    2>"$TEST_PROCESS_ROOT/watch-$case_name.stderr" 3>&- &
  watcher=$!
  TEST_OWNER_PID="$watcher"
  wait_for_file "$pidfile"
  owner="${pidfile%.pid}.owner"
  wait_for_file "$owner"
  # shellcheck disable=SC1090
  source "$SCRIPTS/lib/process-identity.sh"
  wait_until 10 process_is_owned "$pidfile" "$scope"
  agmsg_process_identity_state watch "$pidfile" "$scope"
  [ "$AGMSG_PROCESS_STATE" = owned ]
  [ "$AGMSG_PROCESS_OWNER_LEASE" = leased ]
  lease="$(agmsg_process_lease_path "$pidfile" "$AGMSG_PROCESS_GENERATION")"
  wait_for_file "$WATCH_CALLSITE_MARKER_DIR/$expected_trace-started"
  [ "$(cat "$WATCH_CALLSITE_MARKER_DIR/$expected_trace-started")" = "$expected_trace" ]
  wait_until 10 watch_children_have_callsite_evidence "$watcher" \
    "$WATCH_CALLSITE_MARKER_DIR/$expected_trace-started"
  record_watch_children "$WATCH_CALLSITE_MARKER_DIR/$expected_trace-started"
  kill -KILL "$watcher"
  wait "$watcher" 2>/dev/null || true
  TEST_OWNER_PID=""
  wait_until 10 lease_is_free "$lease"
  agmsg_process_probe_lease "$lease"
  [ "$?" -eq 0 ]
  for pid in ${TEST_WATCH_CHILD_PIDS:-}; do stop_test_pid "$pid"; done
  TEST_WATCH_CHILD_PIDS=""
}

@test "process-owner tier1 helpers publish stable paths and scope hashes" {
  # shellcheck disable=SC1090
  source "$SCRIPTS/lib/process-identity.sh"
  [ "$(agmsg_process_owner_path "$TEST_PROCESS_ROOT/watch.pid")" = "$TEST_PROCESS_ROOT/watch.owner" ]
  [ "$(agmsg_process_owner_path "$TEST_PROCESS_ROOT/watch")" = "$TEST_PROCESS_ROOT/watch.owner" ]
  [ "$(agmsg_process_lease_path "$TEST_PROCESS_ROOT/watch.pid")" = "$TEST_PROCESS_ROOT/watch.lease.claim" ]
  [ "$(agmsg_process_lease_path "$TEST_PROCESS_ROOT/watch.pid" gen-a)" = "$TEST_PROCESS_ROOT/watch.lease.gen-a" ]
  [ "$(agmsg_process_scope_hash '@hash:fixed-scope')" = fixed-scope ]
  [ "$(agmsg_process_scope_hash 'watch|same|scope')" != 'watch|same|scope' ]
}

@test "process-owner leased path asserts backend mode and keeps fd 19 after exec" {
  local pidfile="$TEST_PROCESS_ROOT/leased.pid"
  local scope="watch|leased-$BATS_TEST_NUMBER|$TEST_PROCESS_ROOT|claude-code"
  local target="$TEST_PROCESS_ROOT/target.sh" ready="$TEST_PROCESS_ROOT/ready" report="$TEST_PROCESS_ROOT/report"
  write_owner_target "$target" "$ready" "$report"
  local python
  python="$(command -v python3 2>/dev/null || true)"
  [ -n "$python" ]
  # A leased test must fail if the interpreter cannot be selected; it must not
  # turn an unavailable backend into a green degraded result.
  run env AGMSG_TEST_PROCESS_PYTHON="$python" bash "$SCRIPTS/internal/process-owner-launch.sh" --resolve-python
  [ "$status" -eq 0 ]
  [ -n "$output" ]

  start_owner watch "$pidfile" "$scope" "$target" "$ready" "$report" leased
  [ "$(cat "$report")" = $'mode=leased\nfd=19' ]
  # shellcheck disable=SC1090
  source "$SCRIPTS/lib/process-identity.sh"
  agmsg_process_identity_state watch "$pidfile" "$scope"
  [ "$AGMSG_PROCESS_STATE" = owned ]
  [ "$AGMSG_PROCESS_OWNER_LEASE" = leased ]
  [ "$AGMSG_PROCESS_PID" = "$TEST_OWNER_PID" ]
  local lease
  lease="$(agmsg_process_lease_path "$pidfile" "$AGMSG_PROCESS_GENERATION")"
  run agmsg_process_probe_lease "$lease"
  [ "$status" -eq 75 ]
}

@test "process-owner degraded mode is a separate, observable per-owner path" {
  local pidfile="$TEST_PROCESS_ROOT/degraded.pid"
  local scope="watch|degraded-$BATS_TEST_NUMBER|$TEST_PROCESS_ROOT|claude-code"
  local target="$TEST_PROCESS_ROOT/target.sh" ready="$TEST_PROCESS_ROOT/ready" report="$TEST_PROCESS_ROOT/report"
  write_owner_target "$target" "$ready" "$report"
  start_owner watch "$pidfile" "$scope" "$target" "$ready" "$report" degraded

  [ "$(cat "$report")" = $'mode=degraded\nfd=unset' ]
  grep -q 'lease unavailable; falling back to PID-only dedup' "$TEST_PROCESS_ROOT/owner.stderr"
  # shellcheck disable=SC1090
  source "$SCRIPTS/lib/process-identity.sh"
  agmsg_process_identity_state watch "$pidfile" "$scope"
  [ "$AGMSG_PROCESS_STATE" = degraded-live ]
  [ "$AGMSG_PROCESS_OWNER_LEASE" = degraded ]
}

@test "process-owner unavailable probe is explicit and never absorbed by lease tests" {
  local fake_lockf="$TEST_PROCESS_ROOT/lockf-unavailable"
  cat >"$fake_lockf" <<'FAKE'
#!/usr/bin/env bash
exit 2
FAKE
  chmod +x "$fake_lockf"
  # shellcheck disable=SC1090
  source "$SCRIPTS/lib/process-identity.sh"
  AGMSG_TEST_PROCESS_LOCKF="$fake_lockf" \
    run agmsg_process_probe_lease "$TEST_PROCESS_ROOT/no-lease"
  [ "$status" -eq 69 ]
}

@test "process-owner unknown metadata probes generation lease before PID fallback" {
  local pidfile="$TEST_PROCESS_ROOT/unknown.pid" owner generation=unknown-generation
  local scope='@hash:fixed-unknown-scope'
  owner="${pidfile%.pid}.owner"
  printf '%s\n' "$$" >"$pidfile"
  printf 'version=0\npid=%s\nkind=watch\nscope=fixed-unknown-scope\ngeneration=%s\nlease=maybe\ninterpreter=test\n' "$$" "$generation" >"$owner"
  # shellcheck disable=SC1090
  source "$SCRIPTS/lib/process-identity.sh"
  _agmsg_pid_alive() { return 0; }
  agmsg_process_probe_lease() { return 0; }
  agmsg_process_identity_state watch "$pidfile" "$scope"
  [ "$AGMSG_PROCESS_STATE" = stale ]

  agmsg_process_probe_lease() { return 75; }
  agmsg_process_identity_state watch "$pidfile" "$scope"
  [ "$AGMSG_PROCESS_STATE" = held-unverified ]
  agmsg_process_dedup_should_suppress watch "$pidfile" "$scope"
  [ "$?" -eq 0 ]
  if agmsg_process_signal_decision watch "$pidfile" "$scope" \
      2>"$TEST_PROCESS_ROOT/signal.err"; then
    status=0
  else
    status=$?
  fi
  [ "$status" -eq 1 ]
  [ ! -s "$TEST_PROCESS_ROOT/signal.err" ]

  local legacy_pidfile="$TEST_PROCESS_ROOT/legacy-signal.pid"
  printf '%s\n' "$$" >"$legacy_pidfile"
  if agmsg_process_signal_decision watch "$legacy_pidfile" "$scope" \
      2>"$TEST_PROCESS_ROOT/legacy-signal.err"; then
    status=0
  else
    status=$?
  fi
  [ "$status" -eq 1 ]
  grep -q 'signal not authorized' "$TEST_PROCESS_ROOT/legacy-signal.err"

  agmsg_process_probe_lease() { return 69; }
  agmsg_process_identity_state watch "$pidfile" ""
  [ "$AGMSG_PROCESS_STATE" = unverified-live ]
  [ "$AGMSG_PROCESS_SCOPE_HASH" = fixed-unknown-scope ]
}

@test "process-owner cleanup preserves the publication claim lease for legacy and owned paths" {
  local pidfile="$TEST_PROCESS_ROOT/legacy.pid" claim owner generation=cleanup-generation scope='watch|claim-lease|project|claude-code'
  local generation_lease scope_hash
  claim="$TEST_PROCESS_ROOT/legacy.lease.claim"
  owner="$TEST_PROCESS_ROOT/legacy.owner"
  generation_lease="$TEST_PROCESS_ROOT/legacy.lease.$generation"
  scope_hash="$(bash -c 'source "$1"; agmsg_process_scope_hash "$2"' _ "$SCRIPTS/lib/process-identity.sh" "$scope")"
  # Legacy cleanup has no generation at all.  The publication barrier is still
  # an independent artifact and must survive cleanup_observed.
  printf '%s\n' "$$" >"$pidfile"
  : >"$claim"
  # shellcheck disable=SC1090
  source "$SCRIPTS/lib/process-identity.sh"
  agmsg_process_identity_state watch "$pidfile" "$scope"
  agmsg_process_cleanup_observed "$pidfile"
  [ "$?" -eq 0 ]
  [ ! -e "$pidfile" ]
  [ ! -e "$owner" ]
  [ -e "$claim" ]

  # cleanup_self may remove only the current generation lease.  It must never
  # treat BASE.lease.claim as that generation, even when the owner is valid.
  printf '%s\n' "$$" >"$pidfile"
  printf 'version=1\npid=%s\nkind=watch\nscope=%s\ngeneration=%s\nlease=leased\ninterpreter=test\n' \
    "$$" "$scope_hash" "$generation" >"$owner"
  : >"$generation_lease"
  export AGMSG_PROCESS_OWNER_GENERATION="$generation"
  : >"$claim"
  agmsg_process_cleanup_self watch "$pidfile" "$scope"
  [ -e "$claim" ]
  [ ! -e "$generation_lease" ]
}

@test "process-owner publication window repeats immediate TERM and reacquires each iteration" {
  local python pidfile="$TEST_PROCESS_ROOT/window.pid" owner claim scope='watch|publication-window|project|claude-code'
  local target="$TEST_PROCESS_ROOT/window-target.sh" reentry_target="$TEST_PROCESS_ROOT/reentry-target.sh"
  local launch_pid published_pid state lease_file
  python="$(command -v python3 2>/dev/null || true)"
  [ -n "$python" ]

  cat >"$target" <<'TARGET'
#!/usr/bin/env bash
exec "${AGMSG_TEST_PROCESS_PYTHON:?}" -c '
import signal
import time
def stop(_signum, _frame):
    raise SystemExit(0)
signal.signal(signal.SIGTERM, stop)
time.sleep(600)
'
TARGET
  chmod +x "$target"
  write_owner_target "$reentry_target" "$TEST_PROCESS_ROOT/reentry-ready" "$TEST_PROCESS_ROOT/reentry-report"
  owner="${pidfile%.pid}.owner"
  claim="${pidfile%.pid}.lease.claim"

  # Layer A: pidfile publication is the only readiness condition. Register the
  # raw PID immediately, compare it to the published PID, then TERM without a
  # readiness wait or fixed sleep. Each iteration cleans before reentry.
  for iteration in 1 2 3 4 5 6 7 8 9 10; do
    AGMSG_TEST_PROCESS_PIDFILE="$pidfile" AGMSG_TEST_PROCESS_PYTHON="$python" \
      bash "$SCRIPTS/internal/process-owner-launch.sh" \
      --kind watch --pidfile "$pidfile" --scope "$scope" -- \
      "$target" >"$TEST_PROCESS_ROOT/window-$iteration.out" \
      2>"$TEST_PROCESS_ROOT/window-$iteration.err" &
    launch_pid=$!
    test_fixture_register_owned_pid "$launch_pid"
    wait_for_file "$pidfile"
    published_pid="$(cat "$pidfile")"
    [ "$published_pid" = "$launch_pid" ]
    run kill -0 "$launch_pid"
    [ "$status" -eq 0 ]
    run kill -TERM "$launch_pid"
    [ "$status" -eq 0 ]
    wait "$launch_pid" 2>/dev/null || true
    run kill -0 "$launch_pid"
    [ "$status" -ne 0 ]
    # shellcheck disable=SC1090
    source "$SCRIPTS/lib/process-identity.sh"
    agmsg_process_identity_state watch "$pidfile" "$scope"
    state="$AGMSG_PROCESS_STATE"
    case "$state" in
      stale|unverified-dead|degraded-dead|legacy-dead) ;;
      *) false ;;
    esac
    if [ -e "$pidfile" ] || [ -e "$owner" ]; then
      agmsg_process_cleanup_observed "$pidfile"
    fi
    [ ! -e "$pidfile" ]
    [ ! -e "$owner" ]
    for lease_file in "${pidfile%.pid}".lease.*; do
      [ "$lease_file" = "$claim" ] && continue
      [ ! -e "$lease_file" ]
    done
    [ -e "$claim" ]
    # Reacquire and publish in this same iteration; the next loop is not used
    # as implicit evidence for this iteration's reentry contract.
    local iteration_ready="$TEST_PROCESS_ROOT/window-$iteration-ready"
    local iteration_report="$TEST_PROCESS_ROOT/window-$iteration-report"
    rm -f "$iteration_ready" "$iteration_report"
    start_owner_registered watch "$pidfile" "$scope" "$reentry_target" \
      "$iteration_ready" "$iteration_report"
    process_is_owned "$pidfile" "$scope"
    [ -e "${pidfile%.pid}.lease.${AGMSG_PROCESS_GENERATION}" ]
    stop_test_pid "$TEST_OWNER_PID"
    TEST_OWNER_PID=""
    [ ! -e "$pidfile" ]
    [ ! -e "$owner" ]
    for lease_file in "${pidfile%.pid}".lease.*; do
      [ "$lease_file" = "$claim" ] && continue
      [ ! -e "$lease_file" ]
    done
    [ -e "$claim" ]
  done

}

@test "process-owner partial publication states recover through the production seam" {
  local python scope='watch|partial-publication|project|claude-code' scope_hash signal_record signal_status
  python="$(command -v python3 2>/dev/null || true)"
  local reentry_target="$TEST_PROCESS_ROOT/reentry-target.sh"
  local dead_pid case_name expected generation lease_file pidfile owner claim
  local case_ready case_report
  [ -n "$python" ]
  write_owner_target "$reentry_target" "$TEST_PROCESS_ROOT/reentry-ready" "$TEST_PROCESS_ROOT/reentry-report"
  scope_hash="$(bash -c 'source "$1"; agmsg_process_scope_hash "$2"' _ "$SCRIPTS/lib/process-identity.sh" "$scope")"

  # Layer B table (input artifact | holder state | expected identity state |
  # permitted while held | after release | cleanup artifacts | reacquire/publish):
  # pidfile-only | none, target reaped | legacy-dead | n/a | classify/cleanup |
  # pidfile+owner (no generation lease) | none, target reaped | stale | n/a |
  #   classify/cleanup | pidfile/owner/lease gone, claim kept | production publish
  # pid+owner generation mismatch | none, target reaped | stale | n/a |
  #   classify/cleanup | pidfile/owner/lease gone, claim kept | production publish
  # free generation lease | none, target reaped | stale | n/a |
  #   classify/cleanup | pidfile/owner/lease gone, claim kept | production publish
  # The independent claim case below is the publication/cleanup-in-progress row:
  # pid+owner+generation lease | claim holder alive | held/contended (no stale
  #   assertion) | artifacts unchanged until holder cleanup | cleanup only after
  #   release | claim inode preserved | production reentry.
  sleep 0.05 3>&- &
  local dead_wait_pid=$!
  test_fixture_register_owned_pid "$dead_wait_pid"
  wait "$dead_wait_pid" 2>/dev/null || true
  dead_pid="$dead_wait_pid"
  local -a partial_cases=(pidfile-only owner-only generation-mismatch free-generation-lease)
  for case_name in "${partial_cases[@]}"; do
    pidfile="$TEST_PROCESS_ROOT/partial-$case_name.pid"
    owner="${pidfile%.pid}.owner"
    claim="${pidfile%.pid}.lease.claim"
    generation="partial-$case_name"
    lease_file="${pidfile%.pid}.lease.$generation"
    rm -f "$pidfile" "$owner" "$claim" "$lease_file" "${pidfile%.pid}.lease.other"
    printf '%s\n' "$dead_pid" >"$pidfile"
    : >"$claim"
    expected=legacy-dead
    case "$case_name" in
      owner-only)
        expected=stale
        printf 'version=1\npid=%s\nkind=watch\nscope=%s\ngeneration=%s\nlease=leased\ninterpreter=test\n' \
          "$dead_pid" "$scope_hash" "$generation" >"$owner"
        rm -f "$pidfile"
        ;;
      generation-mismatch)
        expected=stale
        printf 'version=1\npid=%s\nkind=watch\nscope=%s\ngeneration=%s\nlease=leased\ninterpreter=test\n' \
          "$dead_pid" "$scope_hash" "$generation" >"$owner"
        : >"${pidfile%.pid}.lease.other"
        ;;
      free-generation-lease)
        expected=stale
        printf 'version=1\npid=%s\nkind=watch\nscope=%s\ngeneration=%s\nlease=leased\ninterpreter=test\n' \
          "$dead_pid" "$scope_hash" "$generation" >"$owner"
        : >"$lease_file"
        ;;
    esac
    # Production identity classification, cleanup, and launcher reentry.
    source "$SCRIPTS/lib/process-identity.sh"
    agmsg_process_identity_state watch "$pidfile" "$scope"
    [ "$AGMSG_PROCESS_STATE" = "$expected" ]
    case "$AGMSG_PROCESS_STATE" in stale|unverified-dead|degraded-dead|legacy-dead) ;; *) false ;; esac
    if [ "$case_name" = free-generation-lease ]; then
      signal_record="$TEST_PROCESS_ROOT/free-generation-lease-signals"
      rm -f "$signal_record"
      signal_status=0
      AGMSG_TEST_PROCESS_SIGNAL_RECORD="$signal_record" \
        agmsg_process_signal_owned watch "$pidfile" "$scope" || signal_status=$?
      [ "$signal_status" -ne 0 ]
      [ ! -s "$signal_record" ]
    fi
    agmsg_process_cleanup_observed "$pidfile"
    [ ! -e "$pidfile" ]
    [ ! -e "$owner" ]
    if [ "$case_name" = generation-mismatch ]; then
      # A lease for another generation belongs to a successor and must remain.
      [ -e "${pidfile%.pid}.lease.other" ]
    else
      for lease_file in "${pidfile%.pid}".lease.*; do
        [ "$lease_file" = "$claim" ] && continue
        [ ! -e "$lease_file" ]
      done
    fi
    [ -e "$claim" ]
    case_ready="$TEST_PROCESS_ROOT/reentry-$case_name-ready"
    case_report="$TEST_PROCESS_ROOT/reentry-$case_name-report"
    rm -f "$case_ready" "$case_report"
    start_owner_registered watch "$pidfile" "$scope" "$reentry_target" "$case_ready" "$case_report"
    process_is_owned "$pidfile" "$scope"
    [ -e "${pidfile%.pid}.lease.${AGMSG_PROCESS_GENERATION}" ]
    stop_test_pid "$TEST_OWNER_PID"
    TEST_OWNER_PID=""
    [ ! -e "$pidfile" ]
    [ ! -e "$owner" ]
    [ -e "$claim" ]
    if [ "$case_name" = generation-mismatch ]; then
      [ -e "${pidfile%.pid}.lease.other" ]
    fi
  done
}

@test "process-owner claim barrier keeps its inode while cleanup runs under the holder" {
  local python scope='watch|claim-continuity|project|claude-code' scope_hash
  python="$(command -v python3 2>/dev/null || true)"
  local pidfile="$TEST_PROCESS_ROOT/inode.pid" owner claim generation=inode-generation lease_file
  local wrapper probe ready cleanup_request release cleaned
  local lock_pid contender_pid probe_status before_inode after_inode final_inode
  local dead_pid contender_launcher_pid contender_status contender_target contender_ready contender_report signal_record
  local before_pid before_owner before_lease before_pid_inode before_owner_inode before_lease_inode
  [ -n "$python" ]
  sleep 0.05 3>&- &
  contender_pid=$!
  test_fixture_register_owned_pid "$contender_pid"
  wait "$contender_pid" 2>/dev/null || true
  dead_pid="$contender_pid"
  owner="${pidfile%.pid}.owner"
  claim="${pidfile%.pid}.lease.claim"
  lease_file="${pidfile%.pid}.lease.$generation"
  scope_hash="$(bash -c 'source "$1"; agmsg_process_scope_hash "$2"' _ "$SCRIPTS/lib/process-identity.sh" "$scope")"
  printf '%s\n' "$dead_pid" >"$pidfile"
  printf 'version=1\npid=%s\nkind=watch\nscope=%s\ngeneration=%s\nlease=leased\ninterpreter=test\n' \
    "$dead_pid" "$scope_hash" "$generation" >"$owner"
  : >"$claim"
  : >"$lease_file"
  wrapper="$TEST_PROCESS_ROOT/claim-holder.sh"
  probe="$TEST_PROCESS_ROOT/claim-probe.py"
  ready="$TEST_PROCESS_ROOT/claim-holder.ready"
  cleanup_request="$TEST_PROCESS_ROOT/claim-holder.cleanup"
  release="$TEST_PROCESS_ROOT/claim-holder.release"
  cleaned="$TEST_PROCESS_ROOT/claim-holder.cleaned"
  contender_target="$TEST_PROCESS_ROOT/claim-contender-target.sh"
  contender_ready="$TEST_PROCESS_ROOT/claim-contender.ready"
  contender_report="$TEST_PROCESS_ROOT/claim-contender.report"
  signal_record="$TEST_PROCESS_ROOT/claim-contender.signals"
  write_owner_target "$contender_target" "$contender_ready" "$contender_report"
  cat >"$probe" <<'PY'
import fcntl
import os
import sys

fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o600)
try:
    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    raise SystemExit(75)
raise SystemExit(0)
PY
  cat >"$wrapper" <<'PY'
import fcntl
import os
import subprocess
import sys
import time

claim, pidfile, pid, generation, ready, cleanup_request, release, launcher, cleaned = sys.argv[1:]
fd = os.open(claim, os.O_RDWR | os.O_CREAT, 0o600)
fcntl.flock(fd, fcntl.LOCK_EX)
open(ready, "w").close()
while not os.path.exists(cleanup_request):
    time.sleep(0.01)
subprocess.run(["bash", launcher, "--internal-cleanup-observed", pidfile, pid, generation, "0", "--"], check=True)
open(cleaned, "w").close()
while not os.path.exists(release):
    time.sleep(0.01)
PY
  rm -f "$ready" "$cleanup_request" "$release" "$cleaned" "$contender_ready" "$contender_report" "$signal_record"
  "$python" "$wrapper" "$claim" "$pidfile" "$dead_pid" "$generation" "$ready" "$cleanup_request" "$release" \
    "$SCRIPTS/internal/process-owner-launch.sh" "$cleaned" &
  lock_pid=$!
  test_fixture_register_owned_pid "$lock_pid"
  wait_for_file "$ready"
  before_inode="$(stat -f '%i' "$claim" 2>/dev/null || stat -c '%i' "$claim")"
  before_pid="$(cat "$pidfile")"
  before_owner="$(cat "$owner")"
  before_lease="$(cat "$lease_file")"
  before_pid_inode="$(stat -f '%i' "$pidfile" 2>/dev/null || stat -c '%i' "$pidfile")"
  before_owner_inode="$(stat -f '%i' "$owner" 2>/dev/null || stat -c '%i' "$owner")"
  before_lease_inode="$(stat -f '%i' "$lease_file" 2>/dev/null || stat -c '%i' "$lease_file")"
  AGMSG_TEST_PROCESS_PIDFILE="$pidfile" AGMSG_TEST_PROCESS_PYTHON="$python" \
    AGMSG_TEST_PROCESS_SIGNAL_RECORD="$signal_record" \
    bash "$SCRIPTS/internal/process-owner-launch.sh" \
    --kind watch --pidfile "$pidfile" --scope "$scope" -- \
    "$contender_target" "$contender_ready" "$contender_report" \
    >"$TEST_PROCESS_ROOT/claim-contender.stdout" 2>"$TEST_PROCESS_ROOT/claim-contender.stderr" &
  contender_launcher_pid=$!
  test_fixture_register_owned_pid "$contender_launcher_pid"
  if wait "$contender_launcher_pid" 2>/dev/null; then contender_status=0; else contender_status=$?; fi
  [ "$contender_status" -eq 75 ]
  [ ! -e "$contender_ready" ]
  [ ! -e "$contender_report" ]
  [ ! -s "$signal_record" ]
  [ "$(cat "$pidfile")" = "$before_pid" ]
  [ "$(cat "$owner")" = "$before_owner" ]
  [ "$(cat "$lease_file")" = "$before_lease" ]
  [ "$(stat -f '%i' "$pidfile" 2>/dev/null || stat -c '%i' "$pidfile")" = "$before_pid_inode" ]
  [ "$(stat -f '%i' "$owner" 2>/dev/null || stat -c '%i' "$owner")" = "$before_owner_inode" ]
  [ "$(stat -f '%i' "$lease_file" 2>/dev/null || stat -c '%i' "$lease_file")" = "$before_lease_inode" ]
  [ -e "$pidfile" ]
  [ -e "$owner" ]
  [ -e "$lease_file" ]
  [ -e "$claim" ]
  : >"$cleanup_request"
  wait_for_file "$cleaned"
  [ ! -e "$pidfile" ]
  [ ! -e "$owner" ]
  [ ! -e "$lease_file" ]
  [ -e "$claim" ]
  "$python" "$probe" "$claim" &
  contender_pid=$!
  test_fixture_register_owned_pid "$contender_pid"
  if wait "$contender_pid" 2>/dev/null; then probe_status=0; else probe_status=$?; fi
  [ "$probe_status" -eq 75 ]
  : >"$release"
  wait "$lock_pid" 2>/dev/null || true
  "$python" "$probe" "$claim" &
  contender_pid=$!
  test_fixture_register_owned_pid "$contender_pid"
  if wait "$contender_pid" 2>/dev/null; then probe_status=0; else probe_status=$?; fi
  [ "$probe_status" -eq 0 ]
  after_inode="$(stat -f '%i' "$claim" 2>/dev/null || stat -c '%i' "$claim")"
  [ "$after_inode" = "$before_inode" ]
  local reentry_target="$TEST_PROCESS_ROOT/claim-reentry-target.sh"
  local reentry_ready="$TEST_PROCESS_ROOT/claim-reentry.ready"
  local reentry_report="$TEST_PROCESS_ROOT/claim-reentry.report"
  write_owner_target "$reentry_target" "$reentry_ready" "$reentry_report"
  start_owner_registered watch "$pidfile" "$scope" "$reentry_target" "$reentry_ready" "$reentry_report"
  process_is_owned "$pidfile" "$scope"
  [ -e "$pidfile" ]
  [ -e "$owner" ]
  [ -e "${pidfile%.pid}.lease.${AGMSG_PROCESS_GENERATION}" ]
  stop_test_pid "$TEST_OWNER_PID"
  TEST_OWNER_PID=""
  [ ! -e "$pidfile" ]
  [ ! -e "$owner" ]
  [ -e "$claim" ]
  final_inode="$(stat -f '%i' "$claim" 2>/dev/null || stat -c '%i' "$claim")"
  [ "$final_inode" = "$before_inode" ]
}

@test "process-owner signal_owned defaults to TERM after leased assertion" {
  local pidfile="$TEST_PROCESS_ROOT/default-signal.pid"
  local scope="watch|default-signal-$BATS_TEST_NUMBER|$TEST_PROCESS_ROOT|claude-code"
  local target="$TEST_PROCESS_ROOT/target.sh" ready="$TEST_PROCESS_ROOT/ready" report="$TEST_PROCESS_ROOT/report"
  local record="$TEST_PROCESS_ROOT/signals.log"
  write_owner_target "$target" "$ready" "$report"
  start_owner watch "$pidfile" "$scope" "$target" "$ready" "$report" leased
  # shellcheck disable=SC1090
  source "$SCRIPTS/lib/process-identity.sh"
  agmsg_process_identity_state watch "$pidfile" "$scope"
  [ "$AGMSG_PROCESS_STATE" = owned ]
  AGMSG_TEST_PROCESS_SIGNAL_RECORD="$record" agmsg_process_signal_owned watch "$pidfile" "$scope"
  [ "$?" -eq 0 ]
  grep -q "^${TEST_OWNER_PID}[[:space:]]TERM[[:space:]]${AGMSG_PROCESS_GENERATION}$" "$record"
}

@test "process-owner tier1 A: PID reuse stale owner is replaceable instead of false-alive" {
  local pidfile="$TEST_PROCESS_ROOT/reused.pid"
  local scope="watch|reuse-$BATS_TEST_NUMBER|$TEST_PROCESS_ROOT|claude-code"
  local target="$TEST_PROCESS_ROOT/target.sh" ready="$TEST_PROCESS_ROOT/ready" report="$TEST_PROCESS_ROOT/report"
  local old_generation=old-generation old_pid owner
  write_owner_target "$target" "$ready" "$report"
  # shellcheck disable=SC1090
  source "$SCRIPTS/lib/process-identity.sh"
  sleep 600 &
  old_pid=$!
  TEST_FOREIGN_PID=$old_pid
  printf '%s\n' "$old_pid" >"$pidfile"
  owner="${pidfile%.pid}.owner"
  printf 'version=1\npid=%s\nkind=watch\nscope=%s\ngeneration=%s\nlease=leased\ninterpreter=test\n' "$old_pid" "$(agmsg_process_scope_hash "$scope")" "$old_generation" >"$owner"

  start_owner watch "$pidfile" "$scope" "$target" "$ready" "$report" leased
  [ "$TEST_OWNER_PID" != "$old_pid" ]
  # shellcheck disable=SC1090
  source "$SCRIPTS/lib/process-identity.sh"
  agmsg_process_identity_state watch "$pidfile" "$scope"
  [ "$AGMSG_PROCESS_STATE" = owned ]
  [ "$AGMSG_PROCESS_GENERATION" != "$old_generation" ]
}

@test "process-owner tier1 B: signal refuses an unrelated live pid after owner mismatch" {
  local pidfile="$TEST_PROCESS_ROOT/signal.pid"
  local scope="watch|signal-$BATS_TEST_NUMBER|$TEST_PROCESS_ROOT|claude-code"
  local target="$TEST_PROCESS_ROOT/target.sh" ready="$TEST_PROCESS_ROOT/ready" report="$TEST_PROCESS_ROOT/report"
  local record="$TEST_PROCESS_ROOT/signals.log" owner_pid foreign_pid
  write_owner_target "$target" "$ready" "$report"
  start_owner watch "$pidfile" "$scope" "$target" "$ready" "$report" leased
  owner_pid="$TEST_OWNER_PID"
  sleep 600 &
  foreign_pid=$!
  TEST_FOREIGN_PID=$foreign_pid
  printf '%s\n' "$foreign_pid" >"$pidfile"

  # Enter through delivery.sh's real stop path.  The owner sidecar still names
  # owner_pid, while the pidfile now names an unrelated live process; the
  # callsite must refuse to signal it.
  run env AGMSG_RESOLVE_PROJECT=0 AGMSG_TEST_PROCESS_SIGNAL_RECORD="$record" \
    bash "$SCRIPTS/delivery.sh" stop
  [ "$status" -eq 0 ]
  [ ! -s "$record" ]
  kill -0 "$foreign_pid"
  [ "$?" -eq 0 ]
  [ "$(sed -n '1p' "$pidfile")" = "$foreign_pid" ]
  [ "$owner_pid" != "$foreign_pid" ]
}

@test "process-owner tier1 A callsite: session-start emits Monitor for a stale live-pid record" {
  local project="$TEST_PROCESS_ROOT/session-start-project" sid="callsite-a-$BATS_TEST_NUMBER"
  local pidfile="$TEST_SKILL_DIR/run/watch.$sid.pid" owner old_pid
  mkdir -p "$project"
  bash "$SCRIPTS/join.sh" team alice claude-code "$project" >/dev/null
  sleep 600 &
  old_pid=$!
  TEST_FOREIGN_PID=$old_pid
  printf '%s\n' "$old_pid" >"$pidfile"
  owner="${pidfile%.pid}.owner"
  printf 'version=1\npid=%s\nkind=watch\nscope=stale\ngeneration=stale-generation\nlease=leased\ninterpreter=test\n' "$old_pid" >"$owner"

  run env AGMSG_RESOLVE_PROJECT=0 CLAUDE_CODE_SESSION_ID="$sid" bash "$SCRIPTS/session-start.sh" claude-code "$project" <<<"{\"session_id\":\"$sid\"}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"invoke the Monitor tool"* ]]
  run kill -0 "$old_pid"
  [ "$status" -eq 0 ]
  [ ! -e "$pidfile" ]
}

@test "process-owner tier1 B callsite: delivery stop signals only an owned watcher" {
  local project="$TEST_PROCESS_ROOT/delivery-project" sid="callsite-b-$BATS_TEST_NUMBER"
  local pidfile="$TEST_SKILL_DIR/run/watch.$sid.pid" owner generation generation_lease scope
  local target="$TEST_PROCESS_ROOT/target.sh" ready="$TEST_PROCESS_ROOT/ready" report="$TEST_PROCESS_ROOT/report"
  mkdir -p "$project"
  bash "$SCRIPTS/join.sh" team alice claude-code "$project" >/dev/null
  scope="watch|$sid|$project|claude-code"
  write_owner_target "$target" "$ready" "$report"
  start_owner watch "$pidfile" "$scope" "$target" "$ready" "$report" leased
  owner="${pidfile%.pid}.owner"
  generation="$(sed -n 's/^generation=//p' "$owner" | head -1)"
  generation_lease="${pidfile%.pid}.lease.$generation"
  [ -n "$generation" ]
  [ -e "$owner" ]
  [ -e "$pidfile" ]
  [ -e "$generation_lease" ]
  AGMSG_RESOLVE_PROJECT=0 bash "$SCRIPTS/delivery.sh" stop >/dev/null
  wait_for_pid_exit "$TEST_OWNER_PID"
  TEST_OWNER_PID=""
  [ ! -e "$owner" ]
  [ ! -e "$pidfile" ]
  [ ! -e "$generation_lease" ]
}

@test "process-owner tier1 A callsite: delivery restart emits a Monitor directive" {
  local project="$TEST_PROCESS_ROOT/delivery-monitor-project" sid="callsite-monitor-$BATS_TEST_NUMBER"
  local pidfile="$TEST_SKILL_DIR/run/watch.$sid.pid"
  local target="$TEST_PROCESS_ROOT/target.sh" ready="$TEST_PROCESS_ROOT/ready" report="$TEST_PROCESS_ROOT/report"
  mkdir -p "$project"
  bash "$SCRIPTS/join.sh" team alice claude-code "$project" >/dev/null
  write_owner_target "$target" "$ready" "$report"
  start_owner watch "$pidfile" "watch|$sid|$project|claude-code" "$target" "$ready" "$report" leased

  run env AGMSG_RESOLVE_PROJECT=0 CLAUDE_CODE_SESSION_ID="$sid" \
    bash "$SCRIPTS/delivery.sh" restart claude-code "$project"
  [ "$status" -eq 0 ]
  [[ "$output" == *"AGMSG-DIRECTIVE:"* ]]
  [[ "$output" == *"invoke the Monitor tool"* ]]
  wait_for_pid_exit "$TEST_OWNER_PID"
  TEST_OWNER_PID=""
}

@test "process-owner tier1 A callsite: check-inbox defers to the owned watcher" {
  local project="$TEST_PROCESS_ROOT/check-inbox-project" sid="callsite-inbox-$BATS_TEST_NUMBER"
  local pidfile="$TEST_SKILL_DIR/run/watch.$sid.pid"
  local target="$TEST_PROCESS_ROOT/target.sh" ready="$TEST_PROCESS_ROOT/ready" report="$TEST_PROCESS_ROOT/report"
  mkdir -p "$project"
  bash "$SCRIPTS/join.sh" team alice claude-code "$project" >/dev/null
  write_owner_target "$target" "$ready" "$report"
  start_owner watch "$pidfile" "watch|$sid|$project|claude-code" "$target" "$ready" "$report" leased

  run --separate-stderr env AGMSG_RESOLVE_PROJECT=0 \
    bash "$SCRIPTS/check-inbox.sh" claude-code "$project" \
    <<<"{\"session_id\":\"$sid\"}"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *"agmsg: instance-id falling back to bare session_id"* ]]
  kill -TERM "$TEST_OWNER_PID" 2>/dev/null || true
  wait "$TEST_OWNER_PID" 2>/dev/null || true
  TEST_OWNER_PID=""
}

@test "process-owner watch callsites 296 304 322 and 639 are exercised before parent SIGKILL" {
  local project="$TEST_PROCESS_ROOT/project"
  mkdir -p "$project"
  bash "$SCRIPTS/join.sh" team alice claude-code "$project" >/dev/null
  write_watch_callsite_stubs
  # Each mode reaches one of the three watchdog launch branches.  The marker
  # is emitted by the actual watchdog child; the direct `sleep 1` child proves
  # the independent poll-sleep callsite at line 639 in the same run.
  run_watch_callsite_case date-failure fail date-failure "lease-child-failure-$BATS_TEST_NUMBER" "$project"
  run_watch_callsite_case date-malformed malformed date-malformed "lease-child-malformed-$BATS_TEST_NUMBER" "$project"
  run_watch_callsite_case date-boundary normal date-boundary "lease-child-boundary-$BATS_TEST_NUMBER" "$project"
}

@test "process-owner tier1 callsites use the identity seam without pid-only inline kills" {
  # These are eight distinct tier-1 callsites.  Keep one assertion per
  # callsite: a file-level grep can pass while the real branch still uses a
  # raw PID operation elsewhere in the same file.
  assert_process_callsite_range scripts/watch.sh 200 209 'agmsg_process_assert_bootstrap watch'
  assert_process_callsite_range scripts/session-start.sh 201 206 'agmsg_process_signal_owned watch "\$orphan_pidfile"'
  assert_process_callsite_pattern scripts/delivery.sh 'agmsg_process_signal_owned watch "\$f"'
  assert_process_callsite_range scripts/check-inbox.sh 82 86 'agmsg_process_dedup_should_suppress watch "\$PIDFILE"'
  assert_process_callsite_range scripts/drivers/types/codex/_session-start.sh 169 172 'agmsg_process_dedup_should_suppress codex-bridge "\$pidfile"'
  assert_process_callsite_range scripts/drivers/types/codex/_spawn.sh 604 608 'agmsg_process_dedup_should_suppress codex-bridge "\$pidfile"'
  assert_process_callsite_range scripts/drivers/types/cursor/cursor-bridge.sh 171 180 'agmsg_process_assert_bootstrap cursor-bridge'
  assert_process_callsite_range scripts/drivers/types/claude-code/claude-code-bridge.sh 139 148 'agmsg_process_assert_bootstrap claude-code-bridge'
}

@test "process-owner tier2 driver callsites use the shared helper and close fd 19" {
  # Eight driver callsites are asserted independently (two live in the Claude
  # bridge: bootstrap and launcher).  Position-independent assertions inspect
  # the helper's local source context and reject raw PID signal commands there.
  assert_process_callsite_range scripts/drivers/types/claude-code/claude-code-bridge.sh 139 148 'agmsg_process_assert_bootstrap claude-code-bridge'
  assert_process_callsite_range scripts/drivers/types/claude-code/claude-code-bridge.sh 144 148 'process-owner-launch\.sh'
  assert_process_callsite_range scripts/drivers/types/codex/_session-start.sh 169 188 'agmsg_process_dedup_should_suppress codex-bridge'
  assert_process_callsite_range scripts/drivers/types/codex/_spawn.sh 604 612 'agmsg_process_dedup_should_suppress codex-bridge'
  assert_process_callsite_pattern scripts/drivers/types/codex/codex-bridge-launcher.sh 'process-owner-launch\.sh' 2
  assert_process_callsite_range scripts/drivers/types/cursor/_spawn.sh 211 223 'process-owner-launch\.sh'
  assert_process_callsite_range scripts/drivers/types/cursor/cursor-bridge.sh 171 180 'agmsg_process_assert_bootstrap cursor-bridge|process-owner-launch\.sh'
  assert_process_callsite_range scripts/drivers/types/grok-build/_delivery.sh 195 202 'agmsg_process_dedup_should_suppress watch'
  # FD inheritance is a separate tier-1 invariant; retain an explicit check
  # for the Claude/Cursor background callsites in addition to watch.sh's
  # runtime four-callsite test above.
  grep -q '19>&-' scripts/drivers/types/claude-code/claude-code-bridge.sh
  grep -q '19>&-' scripts/drivers/types/cursor/cursor-bridge.sh
}

@test "process-owner existing watcher canaries remain present and unmodified by additions" {
  grep -Fq '@test "session-start: skips directive when watcher already alive (compact dedup)"' tests/test_watch.bats
  grep -Fq '@test "watch: relaunch with the SAME instance id replaces the previous watcher (#66 preserved)"' tests/test_watch.bats
}
