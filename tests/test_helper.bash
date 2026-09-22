# Shared setup/teardown for agmsg BATS tests.
# Each test gets an isolated skill directory with its own DB and teams.

# #1095: a test that exercises join.sh/actas-claim.sh/spawn.sh/watch.sh/
# session-start.sh/check-inbox.sh (or the two libraries under them) is, as far
# as the self-naming primitive can tell, a seat acting -- so it names the pane
# it is running in, with its own fixture team/agent. On a real machine that is
# the developer's own terminal, inherited because bats runs inside it. This is
# TOP-LEVEL, not inside setup_test_env(): `load test_helper` runs it before
# ANY test's own setup(), so it reaches every file that loads this one,
# including one (test_install.bats) whose own setup() never calls
# setup_test_env. A file that deliberately exercises the switch itself
# (test_self_name.bats, test_self_rename.bats) unsets this right after
# loading -- that is a local, visible override, not a gap in this default.
# Hard safety boundary: a test that opts back into self-naming must first install
# a fake terminal. Clear every ambient terminal marker while this helper loads,
# before any suite-level setup or test body can unset AGMSG_SELF_NAME. Tests that
# deliberately model a real terminal restore these variables explicitly, using
# a fake driver or a documented fixture socket.
unset TMUX TMUX_PANE TMUX_TMPDIR
unset HERDR_ENV HERDR_PANE_ID HERDR_SOCKET_PATH HERDR_WORKSPACE_ID HERDR_TAB_ID HERDR_SESSION HERDR_BIN_PATH HERDR_STARTUP_CWD
# #1229: the claude-code transcript-path resolver (agmsg_transcript_path)
# prefers CLAUDE_CONFIG_DIR over $HOME/.claude when set -- a developer or
# agent running under a multi-account profile carries this in their real
# shell, and every fixture in this suite that creates a transcript under the
# sandboxed HOME assumes that IS the resolved root. Left ambient, those tests
# would silently resolve against the real profile dir instead of the fixture.
unset CLAUDE_CONFIG_DIR
# #1229: poke.sh's plain-no-pane fallback resolves ITS OWN caller identity
# from AGMSG_SESSION_ID/CLAUDE_CODE_SESSION_ID/CODEX_THREAD_ID (the same
# chain fix.sh uses). Left ambient, a suite run from inside a real
# claude-code session (this repo's own dev loop very much included) would
# make that resolution succeed using the DEVELOPER's real session id instead
# of whatever the fixture set up, silently changing which branch a test
# exercises. Tests that deliberately model a caller set these explicitly.
unset AGMSG_SESSION_ID CLAUDE_CODE_SESSION_ID CODEX_THREAD_ID
export AGMSG_SELF_NAME=off

setup_test_env() {
  # A test never inherits the developer's terminal. The terminal drivers
  # identify "this pane" from the environment (tmux: $TMUX/$TMUX_PANE; herdr:
  # HERDR_PANE_ID, measured 2026-09-08), and join/send/inbox/history name the
  # caller's pane through it -- so a suite run from inside a real tmux or herdr
  # pane would otherwise write the fixture's team:agent onto the developer's
  # own pane. Tests that want a terminal set these AFTER this call, against a
  # fake on PATH. CI runners carry none of these, so nothing changes there.
  unset TMUX TMUX_PANE TMUX_TMPDIR
  unset HERDR_ENV HERDR_PANE_ID HERDR_SOCKET_PATH HERDR_WORKSPACE_ID HERDR_TAB_ID HERDR_SESSION HERDR_BIN_PATH HERDR_STARTUP_CWD
  unset CLAUDE_CONFIG_DIR
  unset AGMSG_SESSION_ID CLAUDE_CODE_SESSION_ID CODEX_THREAD_ID
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
  # Claude Code v2.1.214+ also exports its own process id to hook/Bash
  # subprocesses. Tests that exercise this resolver input set it explicitly;
  # clearing the ambient value keeps unrelated ancestry and bare-id cases
  # independent of the CLI process that launched bats.
  unset CLAUDE_PID
  # SessionEnd teardown waits for a composite owner PID to disappear
  # (S1-c). The ancestry walk would otherwise pick up the Claude/Cursor
  # process that launched bats, treat it as a still-live owner, and skip
  # every legitimate teardown assertion. Empty AGMSG_AGENT_PID forces the
  # documented bare-sid fallback for watchers and instance-id helpers.
  # SessionEnd tests that want destructive teardown must pass a composite
  # INSTANCE_ID whose owner PID is already dead; a bare id now skips teardown.
  export AGMSG_AGENT_PID=""

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

# PIDs (one per line, this shell excluded) whose command line references <dir>.
# The detached codex children — codex-bridge-launcher.sh and the codex-bridge.js it
# starts (codex-monitor.sh spawns the launcher with `… &`, "outlives this script") —
# resolve their SKILL_DIR from their own script path, so their argv carries
# TEST_SKILL_DIR. The launcher records no pidfile of its own, so a pidfile sweep cannot
# reach it; the command line is what names it. Unix uses ps; on Git Bash ps enumerates
# MSYS processes, which the launcher/bridge are, so it reaches them there too.
#
# LIMIT (named deliberately, not a defect): this matches only processes that carry
# $dir IN THEIR ARGV. A process whose CWD is inside $dir but whose argv does not name
# it would NOT be found. The two known holders are argv-visible today — the launcher
# resolves SKILL_DIR from its own script path (argv[0]), and the bridge receives
# --workspace-root <dir> — so they are caught; but that is a property of THOSE two, not
# a guarantee about any future holder. A cwd/open-fd sweep (lsof) would close the gap;
# it is deliberately NOT used because lsof is slow and this runs in EVERY test's
# teardown — too heavy for the ~all tests that hold nothing. If a future detached child
# holds $dir without naming it in argv, revisit (add an lsof pass gated on the rm
# actually failing, so the cost is paid only when it is needed).
_pids_referencing_dir() {   # <dir>
  ps -eo pid=,args= 2>/dev/null |
    AGMSG_REAP_DIR="$1" awk -v me="$$" 'index($0, ENVIRON["AGMSG_REAP_DIR"]) { if ($1+0 != me+0) print $1 }'
}

# Reap any process still holding $TEST_SKILL_DIR, then let handles release, BEFORE the
# rm. Those detached children keep writing $TEST_SKILL_DIR/run after the test body
# returns and are in no pidset the tests kill, so the bare rm below races them and fails
# `rm: Directory not empty` (or, on Windows, `Device or resource busy` on the bridge's
# open messages.db). #662 == #1036 == #1049.
#
# Scope is $TEST_SKILL_DIR ITSELF — a unique mktemp path — so matching it in process
# args cannot reach a developer's live bridge or another test's processes; this is never
# a blanket `pkill codex-bridge.js`. Guarded to a temp path so a mis-set variable can
# never turn the scan loose on a short/rooty prefix. A single `ps` for the ~all tests
# that spawn nothing.
#
# The SIGTERM→wait→SIGKILL sequence is EXERCISED by tests/test_teardown_reap.bats (kill,
# scope-safety, no-op, guard); whether the wait budget is long enough on a load-3-digit
# host, and whether killing a holder RELEASES the Windows file handle before the rm, are
# both timing/OS facts this repo cannot measure on the author's loaded machine — CI
# (dedicated runners, Windows leg) measures them. Written as designed-and-static-checked,
# NOT as "measured", per the day's rule that a claim states how it was verified (#1036).
_reap_test_skill_dir_procs() {
  local dir="${TEST_SKILL_DIR:-}"
  case "$dir" in
    ""|/|/tmp|/var|/private|/usr|"$HOME") return 0 ;;
  esac
  case "$dir" in
    /tmp/*|/private/*|/var/folders/*|/private/var/folders/*) : ;;
    *)
      # Outside the well-known temp roots, allow ONLY under a TMPDIR that is set AND a
      # real path — never unset, "", or "/". Resolve and VALIDATE the prefix before using
      # it as a pattern: a pattern assembled from an empty prefix ("${TMPDIR:+…}" with
      # TMPDIR unset, or "${TMPDIR%/}" with TMPDIR="/") degenerates to match ANY non-empty
      # dir. This guards a KILL, so the loose failure kills EXTRA processes, not nothing
      # (co2 BLOCKING). Strip the trailing slash first, then require the result non-empty,
      # so unset / "" / "/" all fail closed. Only then is "$_tmp" safe as a pattern prefix.
      local _tmp="${TMPDIR:-}"; _tmp="${_tmp%/}"
      [ -n "$_tmp" ] || return 0
      case "$dir" in "$_tmp"/?*) : ;; *) return 0 ;; esac
      ;;
  esac
  local pids tries=0 sig p
  while :; do
    pids="$(_pids_referencing_dir "$dir")"
    [ -n "$pids" ] || return 0
    # Escalate to SIGKILL quickly (after ~0.3s of SIGTERM): a detached launcher may not
    # act on SIGTERM, and this is a teardown, not a graceful shutdown. SIGKILL is
    # uncatchable, so once sent the process WILL die — the only remaining wait is for ps
    # to stop listing it, which a heavily loaded host can slow. So keep re-checking up
    # to ~6s (a bound only ever reached when something is genuinely stuck; the ~all tests
    # that hold nothing return on the first check above), then return and let the rm
    # surface anything still there. The 6s headroom is what covers a load-3-digit host.
    sig=TERM; [ "$tries" -ge 3 ] && sig=KILL
    for p in $pids; do kill "-$sig" "$p" 2>/dev/null || true; done
    [ "$tries" -ge 60 ] && return 1
    sleep 0.1 2>/dev/null || true
    tries=$((tries + 1))
  done
}

teardown_test_env() {
  # Try the plain rm FIRST, and only reap when it actually fails. The reaper's scan is a
  # full `ps -eo pid=,args=`; running it in EVERY teardown would add that cost to all of
  # the (vast majority of) tests that hold nothing — across the suite's hundreds of tests
  # that dominates the runtime and pushes CI shards over their timeout. The race it fixes
  # is rare (only the codex tests spawn the detached launcher), and it announces itself
  # as a non-zero rm ("Directory not empty" / "Device or resource busy"), so pay the cost
  # exactly there: on failure, reap the TEST_SKILL_DIR-scoped holders and retry.
  rm -rf "$TEST_SKILL_DIR" 2>/dev/null && return 0
  local reap_status=0 rm_status=0
  _reap_test_skill_dir_procs || reap_status=$?
  rm -rf "$TEST_SKILL_DIR" || rm_status=$?
  [ "$reap_status" -eq 0 ] && [ "$rm_status" -eq 0 ]
}

# Bind SessionEnd tests to a live owner PID so session-end.sh publishes a
# composite INSTANCE_ID. Artifacts (pidfiles, cc-instance, actas owners)
# created after this call must use that same AGMSG_AGENT_PID. Kill the owner
# after session-end.sh returns so the detached worker can authorize teardown.
agmsg_test_start_session_owner() {
  test_fixture_start_reaped_process sleep 300
  export AGMSG_TEST_OWNER_PID="$TEST_REAPED_PID"
  export AGMSG_AGENT_PID="$AGMSG_TEST_OWNER_PID"
  export AGMSG_OWNER_EXIT_GRACE_S="${AGMSG_OWNER_EXIT_GRACE_S:-2}"
}

agmsg_test_stop_session_owner() {
  kill "${AGMSG_TEST_OWNER_PID:-}" 2>/dev/null || true
  wait "${AGMSG_TEST_OWNER_PID:-}" 2>/dev/null || true
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

# Start a process under a short-lived supervisor that waits for and reaps it.
# Production headless bridges are detached from spawn.sh and adopted by init;
# this fixture gives signal-based teardown tests the same post-exit ESRCH
# behavior instead of leaving a Bats-owned zombie until the foreground command
# returns. TEST_REAPED_PID identifies the target; the registered supervisor
# owns cleanup if an assertion aborts before the target is stopped.
test_fixture_start_reaped_process() {
  local pidfile supervisor
  _AGMSG_TEST_FIXTURE_SEQUENCE=$((_AGMSG_TEST_FIXTURE_SEQUENCE + 1))
  pidfile="$_AGMSG_TEST_FIXTURE_ROOT/reaped.$$.${_AGMSG_TEST_FIXTURE_SEQUENCE}.pid"
  rm -f "$pidfile"
  bash -c '
    pidfile="$1"
    marker="$2"
    shift 2
    child=""
    finish() {
      status="$1"
      trap "" TERM INT
      if [ -n "$child" ] && kill -0 "$child" 2>/dev/null; then
        kill -TERM "$child" 2>/dev/null || true
        attempt=0
        while kill -0 "$child" 2>/dev/null && [ "$attempt" -lt 20 ]; do
          /bin/sleep 0.05
          attempt=$((attempt + 1))
        done
        kill -0 "$child" 2>/dev/null \
          && kill -KILL "$child" 2>/dev/null || true
      fi
      [ -z "$child" ] || wait "$child" 2>/dev/null || true
      exit "$status"
    }
    trap "finish 143" TERM
    trap "finish 130" INT
    "$@" &
    child=$!
    printf "%s\n" "$child" > "$pidfile"
    wait "$child"
    exit $?
  ' _ "$pidfile" "$AGMSG_TEST_FIXTURE_SIGNATURE" "$@" &
  supervisor=$!
  _test_fixture_register_pid "$supervisor" || return
  wait_for_file "$pidfile" || return
  IFS= read -r TEST_REAPED_PID < "$pidfile" || return
  case "$TEST_REAPED_PID" in ''|*[!0-9]*) return 2 ;; esac
  [ "$TEST_REAPED_PID" -gt 0 ] 2>/dev/null || return 2
  TEST_REAPED_SUPERVISOR_PID="$supervisor"
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

agmsg_install_fake_tmux() {
  export FAKE_TMUX_STATE="${FAKE_TMUX_STATE:-$FAKEBIN/tmux.labels}"
  : >"$FAKE_TMUX_STATE"
  cat >"$FAKEBIN/tmux" <<EOF
#!/usr/bin/env bash
{ printf 'tmux'; for a in "\$@"; do printf ' [%s]' "\$a"; done; printf '\n'; } >> "$ARGV_LOG"
state='$FAKE_TMUX_STATE'
args=("\$@")
if [ "\${args[0]}" = -S ]; then args=("\${args[@]:2}"); fi
case "\${args[0]}" in
  new-window) echo '@7' ;;
  split-window) echo '%9' ;;
  capture-pane) printf 'line one\nline two\n' ;;
  set-option)
    if [ "\${args[4]}" = '@agmsg_agent' ]; then
      pane="\${args[3]}"; label="\${args[5]}"
      [ -f "\$state" ] && grep -v "^\$pane	" "\$state" >"\$state.new" 2>/dev/null || : >"\$state.new"
      printf '%s\t%s\n' "\$pane" "\$label" >>"\$state.new"
      mv "\$state.new" "\$state"
    fi ;;
  display-message)
    if [ "\${args[4]}" = '#{pane_id}|#{@agmsg_agent}' ]; then
      pane="\${args[3]}"
      label="\$(awk -F'\t' -v p="\$pane" '\$1 == p { print \$2 }' "\$state" 2>/dev/null)"
      printf '%s|%s\n' "\$pane" "\$label"
    fi ;;
esac
exit 0
EOF
  chmod +x "$FAKEBIN/tmux"
  export PATH="$FAKEBIN:$PATH"
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

# The inverse, for the handful of tests whose whole point is native Windows: the
# real tasklist, the real MSYS pid space, no stub in between. Everywhere else
# they would prove nothing, so they skip rather than pass vacuously.
skip_unless_windows() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) ;;
    *) skip "${1:-only meaningful under Git Bash}" ;;
  esac
}

# Antigravity's TUI monitor is intentionally Linux-only. Installation tests
# which execute its shim use this guard; file-handling tests remain portable.
skip_unless_linux() {
  [ "$(uname -s)" = Linux ] || skip "${1:-Antigravity TUI monitor is Linux-only}"
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

# Fail the test when <cmd> SUCCEEDS.
#
# `! cmd` cannot do this. POSIX errexit exempts a negated command, on every
# bash, so `! grep -q needle file` is silent when the needle IS there -- the
# one outcome it was written to catch. Measured on 3.2.57 and 5.3.15: both
# report `ok` (#670).
#
# Deliberately not `run cmd` + `[ "$status" -ne 0 ]`, which also works: `run`
# overwrites `$output` and `$status`, so converting an absence check that way
# silently breaks any assertion after it that still reads `$output`. That is a
# real bug, not a hypothetical -- it happened twice in #697 -- and 48 sites is
# too many to hand that to.
#
# Says what failed, because a bare `false` leaves the reader to work out which
# of several absence checks was the one that fired.
refute() {
  if "$@"; then
    echo "refute: '$*' unexpectedly succeeded" >&2
    return 1
  fi
}

# A live process whose command line contains <path>, and nothing else.
#
# The kill paths in session-end.sh / session-start.sh only signal a pid whose
# cmdline still looks like this install's watch.sh -- a deliberate defence
# against pid recycling. Fixtures used a bare `sleep`, whose cmdline does not
# match, so the kill never fired and the assertion checking for it was `!
# kill -0 ...`, which is silent on every bash. The tests passed for years
# without once exercising the branch they are named after (#670).
#
# It runs a script that sleeps; it does NOT exec, which would drop the argument
# from the command line, and it does NOT start the real watcher -- a live
# watcher inside a test is how a suite grows processes that outlive it.
# Sets DECOY_PID rather than printing it: `pid="$(spawn_...)"` runs the `&` in
# a command substitution's subshell, and the child dies with that subshell. The
# first version did exactly that, and the tests using it went green because the
# decoy was already gone -- not because anything had killed it. Returning
# through a variable keeps the process a child of the test.
# The same reader the product uses to decide whether a pid is one of ours, so
# a fixture's precondition is checked the way session-end.sh checks it rather
# than by a lookalike.
_decoy_cmdline() {
  # shellcheck disable=SC1090
  . "$SCRIPTS/lib/compat.sh"
  compat_get_cmdline "$1"
}

spawn_decoy_with_cmdline() {
  local path="$1" decoy
  decoy="$(mktemp -d)/decoy.sh"
  printf '#!/usr/bin/env bash\nsleep 30\n' > "$decoy"
  chmod +x "$decoy"
  bash "$decoy" "$path" 3>&- &
  DECOY_PID=$!
}

# Sends <count> messages of ~<bodylen> bytes each from <from> to <to> on
# <team>, via storage_send directly rather than send.sh's own CLI (#777
# argv-length regressions in inbox.sh/check-inbox.sh/watch.sh/watch-once.sh).
#
# A plain bash FUNCTION CALL, not a subprocess: `storage_send "$team" ...
# "$body"` hands the body to sqlite3 through the same escaped-argv path
# production code uses for a single INSERT (which is not itself in scope --
# no test here builds a body anywhere near that ceiling), but building the
# backlog this way never has to exec anything with the WHOLE backlog as one
# argument, which is exactly the shape production code used to get wrong
# on read. Bodies are tagged "$label-$i-<pad>" so a caller can assert both
# ends of the run (index 0 and count-1) are actually present in what the
# script under test displayed, not just that its exit status was 0.
# 1.3.1 CI speedup: a 100-message backlog through the loop below used to
# spawn one sqlite3 process PER MESSAGE (storage_send's own -bail invocation),
# which is what made the two tests that build a real argv-ceiling-sized
# backlog the two slowest in this file. Verified before switching: a 3-message
# batch built the old way (storage_send in a loop, one sqlite3 call each) and
# the new way (one sqlite3 call for all 3) were compared row-for-row across
# both `messages` and `events` -- same team/from/to/body fields, same rowid
# sequencing, same events.legacy_id -> messages.rowid linkage. Only
# created_at differs, because the batched form finishes fast enough that
# _sqlite_now's second-granularity clock barely advances between messages --
# expected, not a correctness difference (each message's timestamp is still
# a real, distinct call to the same clock function). Only takes this path
# when the driver is sqlite (the only one an argv-ceiling concern applies to,
# and the one whose private functions this depends on); any other driver
# keeps the one-call-per-message loop unchanged.
bulk_send_direct() {
  local team="$1" from="$2" to="$3" count="$4" bodylen="$5" label="$6" \
    i=0 pad
  pad="$(head -c "$bodylen" /dev/zero | tr '\0' 'x')"
  (
    # shellcheck disable=SC1090
    source "$SCRIPTS/lib/storage.sh"
    agmsg_storage_load
    if declare -F _sqlite_message_sent_sql >/dev/null 2>&1 \
      && declare -F _sqlite_db >/dev/null 2>&1 \
      && declare -F _sqlite_now >/dev/null 2>&1; then
      storage_init "$team" >/dev/null 2>&1 || true
      local db batch id at
      db="$(_sqlite_db "$team")"
      batch=""
      while [ "$i" -lt "$count" ]; do
        id="$(compat_uuid7)"
        at="$(_sqlite_now)"
        batch="${batch}
$(_sqlite_message_sent_sql "$team" "$from" "$to" "${label}-${i}-${pad}" "$id" "$at")"
        i=$((i + 1))
      done
      agmsg_sqlite_warm
      printf '%s\n' "$batch" | agmsg_sqlite -bail "$db" >/dev/null
    else
      while [ "$i" -lt "$count" ]; do
        storage_send "$team" "$from" "$to" "${label}-${i}-${pad}" >/dev/null
        i=$((i + 1))
      done
    fi
  )
}
