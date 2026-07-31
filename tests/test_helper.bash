# Shared setup/teardown for agmsg BATS tests.
# Each test gets an isolated skill directory with its own DB and teams.

setup_test_env() {
  local source_test_dir="${AGMSG_TEST_SOURCE_TEST_DIR:-$BATS_TEST_DIRNAME}"
  export TEST_SKILL_DIR="$(mktemp -d)"
  mkdir -p "$TEST_SKILL_DIR"/{scripts,db,teams}
  test_fixture_registry_init "$TEST_SKILL_DIR"

  # Copy all scripts to isolated skill dir. Recursive so nested helper dirs
  # (scripts/lib/) come along without enumerating files.
  cp -R "$source_test_dir"/../scripts/. "$TEST_SKILL_DIR/scripts/"
  chmod +x "$TEST_SKILL_DIR/scripts/"*.sh
  chmod +x "$TEST_SKILL_DIR/scripts/"*.js 2>/dev/null || true

  # Agent-type manifests + per-type runtimes now live under scripts/drivers/types/
  # (the type registry reads <skill-root>/scripts/drivers/types/<name>/type.conf),
  # so the recursive scripts/ copy above already brings them along — no separate
  # copy is needed. Just ensure every type's folded runtime scripts stay executable
  # (codex-*.sh, cursor-bridge.sh, watch-once.sh …).
  chmod +x "$TEST_SKILL_DIR/scripts/drivers/types/"*/*.sh 2>/dev/null || true

  # Initialize DB
  bash "$TEST_SKILL_DIR/scripts/internal/init-db.sh"

  # Convenience vars
  export SCRIPTS="$TEST_SKILL_DIR/scripts"
  export TYPES="$TEST_SKILL_DIR/scripts/drivers/types"

  # Sandbox HOME so NO test can touch the developer's real home. Several paths
  # write under $HOME — e.g. codex-shim-install.sh creates $HOME/.agents/bin/codex
  # and install.sh's configure_codex_sandbox edits $HOME/.codex/config.toml — and
  # a leaked write would clobber the real install / shim (and dangle once this
  # temp dir is torn down). bats runs each test in its own subshell, so the
  # export is scoped to the test and needs no restore. See #41.
  export HOME="$TEST_SKILL_DIR/home"
  mkdir -p "$HOME"

  # Hermeticity: the bats process inherits the developer's own
  # CLAUDE_CODE_SESSION_ID (this suite is usually run from a Claude Code session).
  # If it leaks into a child, session-team-aware code (whoami detection, the
  # send.sh cross-session guard) would key off the developer's real session id
  # instead of the test's. Tests that need it set/absent do so explicitly with
  # `env CLAUDE_CODE_SESSION_ID=...` / `env -u CLAUDE_CODE_SESSION_ID`; clear the
  # ambient value here so neither relies on what shell launched bats.
  unset CLAUDE_CODE_SESSION_ID

  # Keep ordinary tests fast without changing production defaults. Intervals
  # are seconds (0.05s = 20 polls/s, inside the validated 0.01..60 range);
  # AGMSG_KILL_POLL_MAX is an attempt count (5, inside 1..10000). Tests may
  # override these after setup_test_env, or explicitly unset them when proving
  # the production all-unset/default path.
  export AGMSG_SPAWN_READY_POLL_INTERVAL=0.05
  export AGMSG_PLACEMENT_LOCK_POLL_INTERVAL=0.05
  export AGMSG_KILL_POLL_INTERVAL=0.05
  export AGMSG_KILL_POLL_MAX=5
  export AGMSG_DESPAWN_WAIT_POLL_INTERVAL=0.05
}

teardown_test_env() {
  test_fixture_cleanup
  rm -rf "$TEST_SKILL_DIR"
}

# --- Owned long-lived test fixtures -----------------------------------------
#
# Tests that need an agent-shaped process must not use a timeout loop or a long
# sleep as a placeholder. A failed assertion can skip the local kill path, and a
# shell whose stdin is already closed turns read-timeout loops into a CPU spin.
#
# These fixtures block on a private FIFO. The test shell holds the FIFO open for
# writing; normal teardown closes it explicitly, while EXIT/INT/TERM closes it
# automatically with the shell's file descriptors. Either way the fixture sees
# EOF and exits. Registered PIDs are still TERM'd, bounded, KILL'd if necessary,
# and waited so normal teardown leaves no zombie.

test_fixture_registry_init() {
  local root="$1" run_id="${AGMSG_TEST_FIXTURE_RUN_ID:-run-$$}"
  local ledger_dir="${AGMSG_TEST_FIXTURE_LEDGER_DIR:-$root}"
  case "$run_id" in
    ''|*[!A-Za-z0-9_.-]*)
      echo "fixture: invalid AGMSG_TEST_FIXTURE_RUN_ID: $run_id" >&2
      return 2
      ;;
  esac
  _AGMSG_TEST_FIXTURE_ROOT="$root"
  _AGMSG_TEST_FIXTURE_PIDS=()
  _AGMSG_TEST_FIXTURE_FIFOS=()
  _AGMSG_TEST_FIXTURE_SEQUENCE=0
  _AGMSG_TEST_FIXTURE_BLOCK_FD_OPEN=0
  _AGMSG_TEST_FIXTURE_BLOCK_READ_FD_OPEN=0
  _AGMSG_TEST_FIXTURE_GATE_FD_OPEN=0
  _AGMSG_TEST_FIXTURE_TRAPS_INSTALLED=0
  mkdir -p "$ledger_dir" || return 2
  _AGMSG_TEST_FIXTURE_LEDGER="$ledger_dir/fixture-pids.$run_id"
  : >>"$_AGMSG_TEST_FIXTURE_LEDGER" || return 2
  export AGMSG_TEST_FIXTURE_SIGNATURE="--agmsg-test-fixture=${run_id}:${root##*/}:$$"
  TEST_FIXTURE_PID=""
  TEST_FIXTURE_STARTED_PATH=""
}

_test_fixture_prepare_block() {
  [ "${_AGMSG_TEST_FIXTURE_BLOCK_FD_OPEN:-0}" -eq 0 ] || {
    echo "fixture: only one blocking fixture may be active per test" >&2
    return 2
  }
  _AGMSG_TEST_FIXTURE_SEQUENCE=$((_AGMSG_TEST_FIXTURE_SEQUENCE + 1))
  local fifo="$_AGMSG_TEST_FIXTURE_ROOT/fixture-block.$$.${_AGMSG_TEST_FIXTURE_SEQUENCE}.fifo"
  mkfifo "$fifo" || return 2
  if ! exec 9<>"$fifo"; then
    rm -f "$fifo"
    return 2
  fi
  if ! exec 7<"$fifo"; then
    exec 9>&-
    rm -f "$fifo"
    return 2
  fi
  _AGMSG_TEST_FIXTURE_BLOCK_FD_OPEN=1
  _AGMSG_TEST_FIXTURE_BLOCK_READ_FD_OPEN=1
  _AGMSG_TEST_FIXTURE_FIFOS[${#_AGMSG_TEST_FIXTURE_FIFOS[@]}]="$fifo"
  _AGMSG_TEST_FIXTURE_BLOCK_FIFO="$fifo"
  _AGMSG_TEST_FIXTURE_STARTED_PATH="${fifo%.fifo}.started"
  rm -f "$_AGMSG_TEST_FIXTURE_STARTED_PATH"
  TEST_FIXTURE_STARTED_PATH="$_AGMSG_TEST_FIXTURE_STARTED_PATH"
}

_test_fixture_register_pid() {
  local pid="$1" kind="${2:-marker}"
  case "$pid" in ''|*[!0-9]*) return 2 ;; esac
  case "$kind" in marker|owned) ;; *) return 2 ;; esac
  _AGMSG_TEST_FIXTURE_PIDS[${#_AGMSG_TEST_FIXTURE_PIDS[@]}]="$pid"
  printf '%s\t%s\t%s\n' "$pid" "$AGMSG_TEST_FIXTURE_SIGNATURE" "$kind" \
    >>"$_AGMSG_TEST_FIXTURE_LEDGER" || return 2
  TEST_FIXTURE_PID="$pid"
}

# Register a background process created by the test itself. Unlike the
# agent-shaped helpers below, the process may not accept an extra argv marker;
# the run-specific PID/signature ledger still makes teardown and survivor
# checks exact.
test_fixture_register_owned_pid() {
  _test_fixture_register_pid "$1" owned
}

_test_fixture_pid_signature_state() {
  local pid="$1" expected_signature="$2" inspected
  [ -n "$expected_signature" ] || return 1
  if inspected="$(ps eww -p "$pid" -o args= 2>/dev/null)"; then
    case "$inspected" in
      *"$expected_signature"*) return 0 ;;
      *) return 1 ;;
    esac
  fi
  # Inspection denial is distinct from a successful, known mismatch. The
  # owning test shell may still use its exact unreaped child PID as fallback:
  # an unreaped child PID cannot be recycled.
  return 2
}

# Start an argv0-controlled process whose remaining argv preserves the supplied
# agent semantics (for example: daemon run or --bg-spare). The final marker is
# test-only evidence for exact post-suite survivor checks.
test_fixture_start_agent() {
  local argv0="$1"
  shift
  _test_fixture_prepare_block || return
  AGMSG_TEST_FIXTURE_STARTED_PATH="$_AGMSG_TEST_FIXTURE_STARTED_PATH" bash -c '
    exec -a "$1" bash -c '"'"': > "$AGMSG_TEST_FIXTURE_STARTED_PATH"; IFS= read -r _ <&7'"'"' \
      "$1" "$2" "${@:3}"
  ' _ "$argv0" "$_AGMSG_TEST_FIXTURE_BLOCK_FIFO" "$@" \
    "$AGMSG_TEST_FIXTURE_SIGNATURE" 3>&- 4>&- 9>&- &
  exec 7>&-
  _AGMSG_TEST_FIXTURE_BLOCK_READ_FD_OPEN=0
  _test_fixture_register_pid "$!"
  if ! wait_for_file "$TEST_FIXTURE_STARTED_PATH"; then
    test_fixture_cleanup
    return 1
  fi
}

# Two-stage variant for readiness tests. fd 8 holds the gate's writer open so a
# parent that exits before releasing the gate produces EOF. fd 7 is opened while
# the parent still holds the blocking FIFO's writer, then inherited by the child;
# this avoids an open(2) race if the parent closes both writers before release.
test_fixture_start_gated_agent() {
  local gate="$1" started="$2" argv0="$3"
  shift 3
  [ "${_AGMSG_TEST_FIXTURE_GATE_FD_OPEN:-0}" -eq 0 ] || return 2
  _test_fixture_prepare_block || return
  if ! exec 8<>"$gate"; then
    exec 9>&-
    _AGMSG_TEST_FIXTURE_BLOCK_FD_OPEN=0
    return 2
  fi
  _AGMSG_TEST_FIXTURE_GATE_FD_OPEN=1
  AGMSG_TEST_FIXTURE_STARTED_PATH="$_AGMSG_TEST_FIXTURE_STARTED_PATH" bash -c '
    started="$1"; gate="$2"; argv0="$3"; block="$4"
    shift 4
    : > "$started"
    IFS= read -r _ < "$gate"
    exec -a "$argv0" bash -c '"'"': > "$AGMSG_TEST_FIXTURE_STARTED_PATH"; IFS= read -r _ <&7'"'"' \
      "$argv0" "$block" "$@"
  ' _ "$started" "$gate" "$argv0" "$_AGMSG_TEST_FIXTURE_BLOCK_FIFO" "$@" \
    "$AGMSG_TEST_FIXTURE_SIGNATURE" 3>&- 4>&- 8>&- 9>&- &
  exec 7>&-
  _AGMSG_TEST_FIXTURE_BLOCK_READ_FD_OPEN=0
  _test_fixture_register_pid "$!"
}

_test_fixture_retire_registered_pids() {
  local temporary pid signature kind owned retire
  [ "${#_AGMSG_TEST_FIXTURE_PIDS[@]}" -gt 0 ] || return 0
  [ -f "$_AGMSG_TEST_FIXTURE_LEDGER" ] || return 2
  temporary="$_AGMSG_TEST_FIXTURE_LEDGER.tmp.$$"
  : >"$temporary" || return 2

  while IFS=$'\t' read -r pid signature kind; do
    retire=0
    if [ "$signature" = "$AGMSG_TEST_FIXTURE_SIGNATURE" ]; then
      for owned in "${_AGMSG_TEST_FIXTURE_PIDS[@]}"; do
        if [ "$pid" = "$owned" ]; then
          retire=1
          break
        fi
      done
    fi
    if [ "$retire" -eq 0 ]; then
      printf '%s\t%s\t%s\n' "$pid" "$signature" "$kind" >>"$temporary" || {
        rm -f "$temporary"
        return 2
      }
    fi
  done <"$_AGMSG_TEST_FIXTURE_LEDGER"

  if ! mv "$temporary" "$_AGMSG_TEST_FIXTURE_LEDGER"; then
    rm -f "$temporary"
    return 2
  fi
}

test_fixture_cleanup() {
  local pid attempt alive signature_status ledger_status=0
  local cleanup_pids=()
  if [ "${_AGMSG_TEST_FIXTURE_GATE_FD_OPEN:-0}" -eq 1 ]; then
    exec 8>&-
    _AGMSG_TEST_FIXTURE_GATE_FD_OPEN=0
  fi
  if [ "${_AGMSG_TEST_FIXTURE_BLOCK_READ_FD_OPEN:-0}" -eq 1 ]; then
    exec 7>&-
    _AGMSG_TEST_FIXTURE_BLOCK_READ_FD_OPEN=0
  fi
  if [ "${_AGMSG_TEST_FIXTURE_BLOCK_FD_OPEN:-0}" -eq 1 ]; then
    exec 9>&-
    _AGMSG_TEST_FIXTURE_BLOCK_FD_OPEN=0
  fi

  for pid in "${_AGMSG_TEST_FIXTURE_PIDS[@]}"; do
    if _test_fixture_pid_signature_state \
      "$pid" "$AGMSG_TEST_FIXTURE_SIGNATURE"; then
      cleanup_pids[${#cleanup_pids[@]}]="$pid"
    else
      signature_status=$?
      if [ "$signature_status" -eq 2 ]; then
        cleanup_pids[${#cleanup_pids[@]}]="$pid"
      fi
    fi
  done
  for pid in "${cleanup_pids[@]}"; do
    kill -TERM "$pid" 2>/dev/null || true
  done
  attempt=0
  while [ "$attempt" -lt 20 ]; do
    alive=0
    for pid in "${cleanup_pids[@]}"; do
      kill -0 "$pid" 2>/dev/null && alive=1
    done
    [ "$alive" -eq 0 ] && break
    sleep 0.05
    attempt=$((attempt + 1))
  done
  for pid in "${cleanup_pids[@]}"; do
    kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
  done
  for pid in "${cleanup_pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done
  _test_fixture_retire_registered_pids || ledger_status=$?
  _AGMSG_TEST_FIXTURE_PIDS=()

  local fifo
  for fifo in "${_AGMSG_TEST_FIXTURE_FIFOS[@]}"; do
    rm -f "$fifo"
  done
  _AGMSG_TEST_FIXTURE_FIFOS=()
  [ -z "${_AGMSG_TEST_FIXTURE_STARTED_PATH:-}" ] ||
    rm -f "$_AGMSG_TEST_FIXTURE_STARTED_PATH"
  _AGMSG_TEST_FIXTURE_STARTED_PATH=""
  TEST_FIXTURE_PID=""
  TEST_FIXTURE_STARTED_PATH=""
  return "$ledger_status"
}

# Plain child shells used by cleanup-contract tests have no framework traps to
# preserve. Refuse to replace any existing handler; restoring therefore means
# returning all three signals to their defaults before re-raising a signal.
test_fixture_install_cleanup_traps() {
  [ -z "$(trap -p EXIT)" ] &&
    [ -z "$(trap -p INT)" ] &&
    [ -z "$(trap -p TERM)" ] || return 2
  trap '_test_fixture_exit_trap "$?"' EXIT
  trap '_test_fixture_signal_trap INT 130' INT
  trap '_test_fixture_signal_trap TERM 143' TERM
  _AGMSG_TEST_FIXTURE_TRAPS_INSTALLED=1
}

test_fixture_restore_cleanup_traps() {
  [ "${_AGMSG_TEST_FIXTURE_TRAPS_INSTALLED:-0}" -eq 1 ] || return 0
  trap - EXIT INT TERM
  _AGMSG_TEST_FIXTURE_TRAPS_INSTALLED=0
}

_test_fixture_exit_trap() {
  local exit_status="$1"
  test_fixture_cleanup
  test_fixture_restore_cleanup_traps
  exit "$exit_status"
}

_test_fixture_signal_trap() {
  local signal="$1" exit_status="$2"
  test_fixture_cleanup
  test_fixture_restore_cleanup_traps
  kill -s "$signal" "$$" 2>/dev/null || exit "$exit_status"
  exit "$exit_status"
}

# Snapshot first and filter second. The awk process therefore cannot appear in
# its own ps input even though its argv contains the complete marker.
test_fixture_survivor_pids() {
  local run_id="$1" ledger_dir="${2:-${AGMSG_TEST_FIXTURE_LEDGER_DIR:-}}"
  local snapshot matches ledger pid signature kind signature_status ps_ok=0
  case "$run_id" in ''|*[!A-Za-z0-9_.-]*) return 2 ;; esac
  snapshot="$(mktemp)" || return 2
  matches="$(mktemp)" || {
    rm -f "$snapshot"
    return 2
  }
  if ps -Ao pid=,args= >"$snapshot" 2>/dev/null; then
    awk -v marker="--agmsg-test-fixture=${run_id}:" \
      'index($0, marker) { print $1 }' "$snapshot" >>"$matches"
    ps_ok=1
  fi
  rm -f "$snapshot"

  # The ledger covers registered processes that cannot accept an argv marker,
  # and is also the exact fallback when Codex's macOS sandbox denies ps.
  if [ -n "$ledger_dir" ]; then
    ledger="$ledger_dir/fixture-pids.$run_id"
  else
    ledger=""
  fi
  if [ -n "$ledger" ] && [ -f "$ledger" ]; then
    while IFS=$'\t' read -r pid signature kind; do
      case "$pid" in
        ''|*[!0-9]*)
          rm -f "$matches"
          return 2
          ;;
      esac
      case "$signature" in
        "--agmsg-test-fixture=${run_id}:"*) ;;
        *) continue ;;
      esac
      case "$kind" in
        owned|marker|'')
          if _test_fixture_pid_signature_state "$pid" "$signature"; then
            printf '%s\n' "$pid" >>"$matches"
          else
            signature_status=$?
            # Only inspection denial permits the exact ledger/kill-0 fallback.
            # A successful signature mismatch is authoritative non-ownership.
            if [ "$signature_status" -eq 2 ]; then
              kill -0 "$pid" 2>/dev/null && printf '%s\n' "$pid" >>"$matches"
            fi
          fi
          ;;
        *) continue ;;
      esac
    done <"$ledger"
  elif [ "$ps_ok" -ne 1 ]; then
    rm -f "$matches"
    return 2
  fi

  awk '!seen[$0]++' "$matches"
  rm -f "$matches"
  return 0
}

assert_no_test_fixture_survivors() {
  local run_id="$1" ledger_dir="${2:-${AGMSG_TEST_FIXTURE_LEDGER_DIR:-}}" survivors
  survivors="$(test_fixture_survivor_pids "$run_id" "$ledger_dir")" || return
  if [ -n "$survivors" ]; then
    echo "fixture-survivors=$survivors run_id=$run_id" >&2
    return 1
  fi
  echo "fixture-survivors=0 run_id=$run_id"
}

# Skip a test on native Windows / Git Bash (MSYS/MINGW/Cygwin). Use ONLY for
# behaviour that depends on POSIX process semantics agmsg does not yet support
# there — watcher discovery/kill via ps/pgrep, and session liveness via kill -0
# (#134 Bug 2, #181). These are the residual windows-latest failures left after
# the Git Bash compat (#179) and sqlite CRLF (#180) fixes; quarantining them
# lets the experimental leg report green instead of perpetually red. Each call
# site names the tracking issue so the skip is removed when the bug is fixed.
skip_on_windows() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) skip "${1:-not yet supported on native Windows}" ;;
  esac
}

# In-memory sqlite for test ASSERTIONS, stripping CR. sqlite3.exe writes stdout
# in text mode on Windows (\n -> \r\n); $(...) keeps the trailing \r, so a probe
# like [ "$(sqlite3 :memory: 'SELECT json_valid(...)')" = "1" ] compares "1\r"
# against "1" and fails even when the script under test wrote a correct file.
# This is the test-side mirror of scripts/lib/storage.sh's agmsg_sqlite_mem.
sqlite_mem() { sqlite3 :memory: "$@" | tr -d '\r'; }

# Resolve a file path for use inside a sqlite3 readfile('...') call in a test.
# On native Windows, sqlite3 only reads a Windows path (C:\Users\...), not a Git
# Bash POSIX path (/c/Users/... or /tmp/...): an unconverted path reads back as
# empty, so the surrounding json_extract / json_valid sees nothing and the check
# fails even though the script under test wrote a correct file. cygpath -w
# converts it; a no-op off Windows (cygpath absent). The result is then single-
# quote-escaped for the SQL string literal. Mirrors scripts/lib/storage.sh's
# agmsg_sql_readfile_path — the production helper these tests are validating.
rf() {
  local p="$1"
  if command -v cygpath >/dev/null 2>&1; then
    p="$(cygpath -w "$p" 2>/dev/null || printf '%s' "$p")"
  fi
  printf '%s' "$p" | sed "s/'/''/g"
}

# --- Bounded condition waits -------------------------------------------------
#
# Wait for a condition to become true, polling, instead of sleeping a fixed
# interval and hoping. A fixed `sleep 1` after launching a watcher is wrong in
# both directions at once: it costs a whole second when the watcher was ready in
# 40ms, and it still flakes on a loaded runner where the watcher needs 1.2s.
# Polling is both faster and steadier, which is why the pattern already existed
# ad hoc in test_watch.bats, test_install.bats and test_codex_bridge_launcher.bats
# before it was hoisted here.
#
# Each returns 1 with a diagnostic on timeout, so a caller can fail with its own
# message or clean up a background process first. A condition status above 1,
# an invalid clock sample, or a failed sleep is a hard error and is returned
# immediately instead of being mistaken for "not ready yet". The 10s real-time
# ceiling is far above any normal local transition and well under the job limit.
#
# NOTE: these replace waits for a condition that will become TRUE. A test that
# asserts something does NOT happen cannot poll for it — see the comment at the
# remaining fixed sleeps in test_delivery.bats.

_WAIT_TIMEOUT=10    # wall-clock seconds
_WAIT_INTERVAL=0.05 # seconds; 20 polls/s avoids hammering

_wait_epoch_seconds() {
  local now
  now="$(command date +%s 2>/dev/null)" || return 1
  case "$now" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$now"
}

_wait_poll_args_valid() {
  local timeout="$1" interval="$2"
  LC_ALL=C awk -v timeout="$timeout" -v interval="$interval" '
    BEGIN {
      valid = timeout ~ /^[0-9]+$/ &&
              timeout + 0 > 0 && timeout + 0 <= 300 &&
              interval ~ /^[0-9]+([.][0-9]+)?$/ &&
              interval + 0 > 0 && interval + 0 <= 60
      exit(valid ? 0 : 1)
    }
  ' </dev/null
}

# _wait_poll <timeout-seconds> <poll-seconds> <description> <condition...>
#
# A condition returns 0 when ready, 1 while pending, and >1 on a hard error.
# Wall-clock rollback resets the local baseline so a future timestamp cannot
# wedge the wait.
_wait_poll() {
  local timeout="$1" interval="$2" description="$3"
  local status now="" started="" last="" elapsed=0
  shift 3

  if ! _wait_poll_args_valid "$timeout" "$interval"; then
    echo "wait: invalid timeout/interval for $description (timeout=$timeout interval=$interval)" >&2
    return 2
  fi
  [ "$#" -gt 0 ] || {
    echo "wait: missing condition for $description" >&2
    return 2
  }

  while :; do
    if "$@"; then
      return 0
    else
      status=$?
    fi
    if [ "$status" -gt 1 ]; then
      echo "wait: condition error status=$status while waiting for $description" >&2
      return "$status"
    fi

    if ! now="$(_wait_epoch_seconds)"; then
      echo "wait: wall-clock error while waiting for $description" >&2
      return 2
    fi
    if [ -z "$started" ]; then
      started="$now"
      last="$now"
      elapsed=0
    elif [ "$now" -lt "$last" ]; then
      started="$now"
      last="$now"
      elapsed=0
    else
      last="$now"
      elapsed=$((now - started))
    fi
    if [ "$elapsed" -ge "$timeout" ]; then
      echo "wait: timeout after ${elapsed}s waiting for $description" >&2
      return 1
    fi
    if ! sleep "$interval"; then
      echo "wait: sleep failed while waiting for $description (interval=$interval)" >&2
      return 2
    fi
  done
}

_wait_file_exists() {
  [ -f "$1" ]
}

_wait_path_missing() {
  [ ! -e "$1" ]
}

_wait_file_contains() {
  local file="$1" needle="$2"
  [ -f "$file" ] || return 1
  grep -q -- "$needle" "$file"
}

_wait_file_equals() {
  local file="$1" expected="$2" actual
  [ -f "$file" ] || return 1
  actual="$(cat "$file" 2>/dev/null)" || return 2
  [ "$actual" = "$expected" ]
}

wait_for_file() {
  local file="$1"
  _wait_poll "$_WAIT_TIMEOUT" "$_WAIT_INTERVAL" "file $file" \
    _wait_file_exists "$file"
}

wait_for_missing() {
  local path="$1"
  _wait_poll "$_WAIT_TIMEOUT" "$_WAIT_INTERVAL" "path removal $path" \
    _wait_path_missing "$path"
}

wait_for_file_contains() {
  local file="$1" needle="$2"
  _wait_poll "$_WAIT_TIMEOUT" "$_WAIT_INTERVAL" "text in $file" \
    _wait_file_contains "$file" "$needle"
}

# Positive evidence that a pid is gone. NOT `kill -0 || gone`.
#
# A failed `kill -0` is ESRCH (dead) or EPERM (alive, but not signalable by us —
# sandboxes do exactly this, and a live instance of it was found in
# delivery.sh status the same day this was written). Treating every failure as
# "gone" is how a wait-for-exit helper reports success for a running process,
# which turns every test built on it into a green that proves nothing. That is
# the defect this file's own callers were just fixed for; the helper must not
# reintroduce it one level down.
#
# Mirrors _agmsg_pid_alive in scripts/lib/instance-id.sh, then cross-checks the
# process table, which does not depend on signalling permission at all. Saying
# "gone" now requires kill(2) and ps to agree.
_pid_gone() {
  local pid="$1" err stat
  # `export LC_ALL=C` rather than a bare prefix: a prefix misses the builtin on
  # bash 3.2, and the ESRCH match below is on English text.
  err="$(export LC_ALL=C; kill -0 "$pid" 2>&1)" && return 1
  case "$err" in
    *[Nn]'o such process'*) ;;
    *) return 1 ;;   # EPERM and anything unrecognised mean "assume alive"
  esac
  stat="$(ps -o stat= -p "$pid" 2>/dev/null | tr -d ' ')"
  [ -z "$stat" ] && return 0
  case "$stat" in Z*) return 0 ;; esac   # terminated, just not reaped yet
  return 1
}

# Wait for a process to actually be gone. Writing a pidfile and dying are not
# atomic, so asserting `! kill -0 $pid` the instant a pidfile disappears races
# the TERM trap (#124).
wait_for_pid_exit() {
  local pid="$1"
  _wait_poll "$_WAIT_TIMEOUT" "$_WAIT_INTERVAL" "pid $pid exit" \
    _wait_pid_gone "$pid"
}

_wait_pid_gone() {
  local pid="$1"
  # Reap finished children first: an unreaped zombie still answers `kill -0`,
  # so without this a process that HAS exited can keep looking alive for the
  # whole timeout. `jobs` is what makes bash collect them.
  jobs >/dev/null 2>&1 || true
  _pid_gone "$pid"
}

# Wait for <file> to contain exactly <expected>, for pidfile handoffs where the
# file exists throughout but its contents flip to the successor.
wait_for_file_is() {
  local file="$1" expected="$2"
  _wait_poll "$_WAIT_TIMEOUT" "$_WAIT_INTERVAL" "exact text in $file" \
    _wait_file_equals "$file" "$expected"
}

# Pin a fake-owned session_id under the given run/ directory so the lock
# liveness check (which runs `kill -0` on cc-instance.<pid>) considers
# <sid> alive for the duration of the bats process.
#
# Used to be inlined in every test that needed a live peer owner. Pulled
# up here per #65 review finding 7 — the fake cc-instance pattern is part
# of the lock contract; repeating it inline invites tests that flake the
# moment we tighten what "alive" means.
#
# Usage: setup_live_owner <run_dir> <session_id>
setup_live_owner() {
  local run_dir="$1" sid="$2"
  mkdir -p "$run_dir"
  echo "$sid" > "$run_dir/cc-instance.$$"
}

# Poll a condition until it succeeds or a timeout elapses. The SessionEnd hook
# now detaches its teardown (session-end-worker.sh) so the effects (codex kill,
# spawn-record/pidfile/cc-instance removal) land asynchronously, a beat after the
# hook returns. A fixed `sleep 1` races that under load; this polls instead.
#
# Usage: wait_until <timeout_secs> <command...>
# Returns 0 as soon as <command> exits 0, or non-zero if the timeout elapses.
wait_until() {
  local timeout="$1"; shift
  _wait_poll "$timeout" "$_WAIT_INTERVAL" "condition command" "$@"
}
