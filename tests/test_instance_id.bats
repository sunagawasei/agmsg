#!/usr/bin/env bats

# Tests for the per-process instance id (#93): parallel claude --continue /
# --resume processes share a session_id, so watcher/lock state keyed on the
# bare session_id collides. instance-id.sh disambiguates with the enclosing
# agent pid. These cover the helper functions and the actas-lock distinctness
# the fix turns on.

load test_helper

setup() {
  setup_test_env
  export SKILL_DIR="$TEST_SKILL_DIR"
  export RUN_DIR="$SKILL_DIR/run"
  mkdir -p "$RUN_DIR"
  # shellcheck disable=SC1090
  source "$SKILL_DIR/scripts/lib/resolve-project.sh"
  # shellcheck disable=SC1090
  source "$SKILL_DIR/scripts/lib/instance-id.sh"
  # shellcheck disable=SC1090
  source "$SKILL_DIR/scripts/lib/actas-lock.sh"
}

teardown() { teardown_test_env; }

# --- agmsg_instance_id_from_pid ---

@test "instance_id_from_pid: numeric pid yields composite" {
  [ "$(agmsg_instance_id_from_pid sess 1234)" = "sess.1234" ]
}

@test "instance_id_from_pid: empty pid yields bare sid" {
  [ "$(agmsg_instance_id_from_pid sess "")" = "sess" ]
}

@test "instance_id_from_pid: non-numeric pid yields bare sid" {
  [ "$(agmsg_instance_id_from_pid sess abc)" = "sess" ]
}

# --- agmsg_instance_is_composite ---

@test "is_composite: true for <sid>.<numeric>" {
  agmsg_instance_is_composite "sess.1234"
}

@test "is_composite: true for a UUID-shaped sid with numeric suffix" {
  agmsg_instance_is_composite "11111111-2222-3333-4444-555555555555.987"
}

@test "is_composite: false for a bare sid" {
  ! agmsg_instance_is_composite "sess"
}

@test "is_composite: false for empty suffix" {
  ! agmsg_instance_is_composite "sess."
}

@test "is_composite: false for empty prefix" {
  ! agmsg_instance_is_composite ".1234"
}

@test "is_composite: false for non-numeric suffix" {
  ! agmsg_instance_is_composite "sess.12a"
}

# --- agmsg_instance_bare_sid ---

@test "bare_sid: strips the pid from a composite token" {
  [ "$(agmsg_instance_bare_sid "sess.1234")" = "sess" ]
}

@test "bare_sid: UUID-shaped composite yields the bare UUID" {
  [ "$(agmsg_instance_bare_sid "11111111-2222-3333-4444-555555555555.987")" = "11111111-2222-3333-4444-555555555555" ]
}

@test "bare_sid: a bare sid passes through unchanged" {
  [ "$(agmsg_instance_bare_sid "sess")" = "sess" ]
}

@test "bare_sid: a non-composite token with a dot but non-numeric suffix is unchanged" {
  # "sess.12a" is NOT composite (suffix not all-digits), so it is a bare sid.
  [ "$(agmsg_instance_bare_sid "sess.12a")" = "sess.12a" ]
}

# --- agmsg_instance_alive ---

@test "instance_alive: composite with a live pid is alive" {
  skip_on_windows "instance-id live PID liveness under Git Bash (#182)"
  agmsg_instance_alive "sess.$$"
}

@test "instance_alive: composite with a dead pid is not alive" {
  ! agmsg_instance_alive "sess.2147483647"
}

@test "instance_alive: composite is not alive when cc-instance.<pid> now names a different token (#349)" {
  skip_on_windows "instance-id live PID liveness under Git Bash (#182)"
  # Simulates a shared pid (Claude Code 2.1.x daemon) whose cc-instance record
  # was overwritten by a newer session attaching to the same pid — the pid is
  # still alive, but this token is no longer the one it currently names.
  echo "newsess.$$" > "$RUN_DIR/cc-instance.$$"
  ! agmsg_instance_alive "oldsess.$$"
}

@test "instance_alive: composite is alive when cc-instance.<pid> still names this exact token (#349)" {
  skip_on_windows "instance-id live PID liveness under Git Bash (#182)"
  echo "sess.$$" > "$RUN_DIR/cc-instance.$$"
  agmsg_instance_alive "sess.$$"
}

@test "instance_alive: bare sid with a live cc-instance is alive" {
  skip_on_windows "instance-id live PID liveness under Git Bash (#182)"
  echo "barex" > "$RUN_DIR/cc-instance.$$"
  agmsg_instance_alive "barex"
}

@test "instance_alive: bare sid is alive when cc-instance was upgraded to composite (compat)" {
  skip_on_windows "instance-id live PID liveness under Git Bash (#182)"
  # A pre-upgrade lock holds a bare sid while cc-instance already stores the
  # composite "<sid>.<pid>" — must not be stale'd out.
  echo "barey.$$" > "$RUN_DIR/cc-instance.$$"
  agmsg_instance_alive "barey"
}

@test "instance_alive: bare sid with no cc-instance is not alive" {
  ! agmsg_instance_alive "ghost"
}

@test "instance_alive: empty token is not alive" {
  ! agmsg_instance_alive ""
}

# --- _agmsg_pid_alive: EPERM vs ESRCH (Claude Code sandbox) ---
#
# Under the sandbox `kill -0` on a live pid returns EPERM, not ESRCH. Only ESRCH
# is dead; EPERM must read as alive or the watcher self-exits. `kill` is stubbed
# to script each errno string (real EPERM is hard to force).

@test "pid_alive: a real live pid (self) is alive" {
  skip_on_windows "POSIX kill path; Windows uses tasklist (#134)"
  _agmsg_pid_alive $$
}

@test "pid_alive: a real dead pid is not alive (ESRCH end-to-end)" {
  skip_on_windows "POSIX kill path; Windows uses tasklist (#134)"
  ! _agmsg_pid_alive 2147483647
}

@test "pid_alive: a signalable pid (kill -0 exit 0) is alive" {
  skip_on_windows "POSIX kill path; Windows uses tasklist (#134)"
  kill() { return 0; }
  _agmsg_pid_alive 12345
}

# A pid that is genuinely gone, so the real ps agrees with the stubbed kill.
# Stubbing kill alone stopped being enough once "dead" required ps to agree:
# a made-up number like 999 IS a running process on some hosts, which is
# exactly the case the cross-check exists to catch.
gone_pid() {
  local pid
  pid="$(bash -c 'echo $$')"
  wait_for_pid_exit "$pid" || true
  echo "$pid"
}

@test "pid_alive: ESRCH 'No such process' reads as dead" {
  skip_on_windows "POSIX kill path; Windows uses tasklist (#134)"
  local gone; gone="$(gone_pid)"
  kill() { echo "bash: kill: ($gone) - No such process" >&2; return 1; }
  ! _agmsg_pid_alive "$gone"
}

@test "pid_alive: lowercase 'no such process' (zsh wording) also reads as dead" {
  skip_on_windows "POSIX kill path; Windows uses tasklist (#134)"
  local gone; gone="$(gone_pid)"
  kill() { echo "kill: ($gone) - no such process" >&2; return 1; }
  ! _agmsg_pid_alive "$gone"
}

@test "pid_alive: ESRCH is not enough while ps still shows the process" {
  skip_on_windows "POSIX kill path; Windows uses tasklist (#134)"
  # kill(2) and ps must agree before a pid is called dead. ps does not depend on
  # signalling permission at all, so it is what stops "cannot signal" from
  # becoming "not running" — and calling a live pid dead is how a running
  # owner's lock gets reclaimed out from under it.
  kill() { echo "bash: kill: ($$) - No such process" >&2; return 1; }
  _agmsg_pid_alive $$
}

@test "pid_alive: EPERM 'Operation not permitted' reads as alive (sandbox)" {
  skip_on_windows "POSIX kill path; Windows uses tasklist (#134)"
  kill() { echo "bash: kill: (1) - Operation not permitted" >&2; return 1; }
  _agmsg_pid_alive 1
}

@test "pid_alive: an unrecognized kill failure defaults to alive (fail-safe)" {
  skip_on_windows "POSIX kill path; Windows uses tasklist (#134)"
  kill() { echo "kill: some novel platform error" >&2; return 1; }
  _agmsg_pid_alive 42
}

@test "pid start token ps fallback pins UTC across caller timezones" {
  local capture="$TEST_SKILL_DIR/ps-timezones" tokyo_token la_token
  ps() {
    printf '%s\n' "${TZ:-unset}" >> "$capture"
    printf 'Fri Aug 21 00:00:00 2026\n'
  }

  tokyo_token="$(TZ=Asia/Tokyo agmsg_pid_start_token 2147483646)"
  la_token="$(TZ=America/Los_Angeles agmsg_pid_start_token 2147483646)"
  [ "$tokyo_token" = "ps:Fri Aug 21 00:00:00 2026" ]
  [ "$la_token" = "$tokyo_token" ]
  [ "$(sed -n '1p' "$capture")" = UTC ]
  [ "$(sed -n '2p' "$capture")" = UTC ]
}

# --- #954: the ps cross-check must tell "proof of absence" from "absence of
# proof". Both halves are asserted with the SAME genuinely-dead pid, so a result
# of "alive" can ONLY be the canary suppressing the death verdict, never the pid
# being live -- exactly the distinction the bug erased. ---

@test "pid_alive: a truly-gone pid is PROVEN dead when ps answers, and cleanup fires (#954)" {
  skip_on_windows "POSIX kill path; Windows uses tasklist (#134)"
  # A pid this shell minted and reaped: kill(2) returns a real ESRCH, real ps
  # lists our own $$ but not the gone pid -> positive proof of absence.
  sh -c 'exit 0' & local gone=$!; wait "$gone" 2>/dev/null
  run _agmsg_pid_alive_local "$gone"
  [ "$status" -ne 0 ] || { echo "a gone pid with a working ps read alive"; false; }
  # The cleanup-side contract: `... || rm -f` DOES delete for a proven-gone pid.
  local marker="$RUN_DIR/marker.$gone"; : > "$marker"
  _agmsg_pid_alive_local "$gone" || rm -f "$marker"
  [ ! -e "$marker" ] || { echo "cleanup did not fire on a proven-dead pid"; false; }
}

@test "pid_alive: a truly-gone pid reads ALIVE when ps cannot answer -- a failed observation is not proof, and cleanup is suppressed (#954)" {
  skip_on_windows "POSIX kill path; Windows uses tasklist (#134)"
  sh -c 'exit 0' & local gone=$!; wait "$gone" 2>/dev/null
  # ps cannot answer: it emits nothing and fails. The canary ($$) is absent from
  # the output, so the helper cannot see even itself -> observation failed. The
  # pid is genuinely gone, so "alive" here is UNAMBIGUOUSLY the canary firing.
  ps() { return 1; }
  run _agmsg_pid_alive_local "$gone"
  [ "$status" -eq 0 ] || { echo "a failed ps was read as proof of death (the #954 bug)"; false; }
  # The cleanup-side contract: `... || rm -f` does NOT delete when we could not
  # observe. The file a live process might still own is left intact.
  local marker="$RUN_DIR/marker.$gone"; : > "$marker"
  _agmsg_pid_alive_local "$gone" || rm -f "$marker"
  [ -e "$marker" ] || { echo "cleanup fired on an UNKNOWN observation (UNKNOWN leaked to the cleanup side)"; false; }
}

@test "pid_alive: ps that omits the target but still lists the canary is proof of death (#954)" {
  skip_on_windows "POSIX kill path; Windows uses tasklist (#134)"
  # ps answers (lists $$, proving it ran) but does not list the target -> the
  # target is provably gone even though ps was reachable.
  kill() { echo "bash: kill: - No such process" >&2; return 1; }
  ps() { printf '%s S\n' "$$"; }   # only the canary, never the queried target
  run _agmsg_pid_alive_local 424242
  [ "$status" -ne 0 ] || { echo "an answered ps that omits the target did not read dead"; false; }
}

@test "pid_alive_local: a tab-only caller IFS does not break canary parsing (#970)" {
  skip_on_windows "POSIX kill path; Windows uses tasklist (#134)"
  # cmd_sync_start reads its engine-status check via `IFS=$'\t' read ...
  # < <(...)`, and that IFS leaks into everything run inside the process
  # substitution -- this function's own read of the ps snapshot included.
  # Same fixture shape as the #954 "canary present, target absent -> proof
  # of death" test above (ps lists only $$, a complete and otherwise-valid
  # snapshot), but read under a tab-only ambient IFS. Space cannot split a
  # tab-only IFS field, so `$_p` parses as the WHOLE unsplit line and
  # matches neither `$$` nor the target: the canary line fails to register
  # even though ps answered correctly, canary stays 0, and a genuinely-dead
  # pid reads alive through the #954 UNKNOWN fallback -- for a reason that
  # has nothing to do with the snapshot itself being incomplete.
  kill() { echo "bash: kill: - No such process" >&2; return 1; }
  ps() { printf '%s S\n' "$$"; }   # only the canary, never the queried target
  IFS=$'\t'
  run _agmsg_pid_alive_local 424242
  [ "$status" -ne 0 ] || { echo "a tab-only caller IFS broke ps-output parsing and read a dead pid as alive"; false; }
}

@test "pid_alive: a snapshot with output but WITHOUT the canary is UNKNOWN, not death (#954)" {
  skip_on_windows "POSIX kill path; Windows uses tasklist (#134)"
  # The subtle leak: ps returns SOME lines but not our own $$ (a partial or garbage
  # snapshot, or a failure that still printed something). Without the canary the
  # observation is untrusted, so a genuinely-gone pid must STILL read alive -- a
  # non-empty result is not itself proof the snapshot was complete. No retry count
  # or partial output may turn this into a death verdict, and cleanup stays put.
  sh -c 'exit 0' & local gone=$!; wait "$gone" 2>/dev/null
  ps() { printf '999999 R\n'; }   # a line, but never $$ and never the target
  run _agmsg_pid_alive_local "$gone"
  [ "$status" -eq 0 ] || { echo "a canary-less snapshot was read as proof of death"; false; }
  local marker="$RUN_DIR/marker.$gone"; : > "$marker"
  _agmsg_pid_alive_local "$gone" || rm -f "$marker"
  [ -e "$marker" ] || { echo "cleanup fired on a canary-less snapshot (UNKNOWN leaked to cleanup)"; false; }
}

@test "pid_alive: a ps that lists the canary but EXITS NON-ZERO is a truncated snapshot -> UNKNOWN, not death (#954)" {
  skip_on_windows "POSIX kill path; Windows uses tasklist (#134)"
  # The last leak: ps prints part of the snapshot -- even our own $$ -- and THEN
  # fails. The target's line may simply never have been reached, so its absence
  # from a truncated listing is not proof. A non-zero exit must read as UNKNOWN
  # regardless of what partial output was captured. (This is also why an "ps -Ao"
  # a platform does not support fails safe rather than lying "gone".)
  sh -c 'exit 0' & local gone=$!; wait "$gone" 2>/dev/null
  ps() { printf '%s S\n' "$$"; return 1; }   # canary printed, then ps fails
  run _agmsg_pid_alive_local "$gone"
  [ "$status" -eq 0 ] || { echo "a non-zero ps exit was read as proof of death despite partial output"; false; }
  local marker="$RUN_DIR/marker.$gone"; : > "$marker"
  _agmsg_pid_alive_local "$gone" || rm -f "$marker"
  [ -e "$marker" ] || { echo "cleanup fired on a failed (truncated) ps snapshot"; false; }
}

@test "pid_alive_local: MSYS corroborates via a canaried ps -l listing, without turning unknown into dead (#970 Windows)" {
  skip_on_windows "stubs uname/kill/ps; the real ones are authoritative on Windows"
  # _agmsg_pid_alive_local's POSIX corroboration (above) takes a whole-table
  # `ps -Ao pid=,stat=` snapshot, which MSYS2's ps does not support (no -o).
  # #970's first MSYS attempt queried `ps -l -p PID` (pid-filtered) instead --
  # measured live on real Windows Git Bash (2026-09-23): a DEAD pid makes
  # `ps -l -p` exit 1, header line and all, so requiring rc=0 (correctly, per
  # #954's own rule) made the dead case UNREACHABLE, forever -- the Windows
  # CI hang this was meant to fix never actually closed. The fix is the
  # query, not the rule: an UNFILTERED `ps -l` behaves like the POSIX
  # `ps -Ao` snapshot (exits 0, lists everything including our own row), so
  # the same canary technique applies -- a positive sighting of our own $$
  # proves the listing completed, and the target's absence from THAT
  # listing is what proves death.
  uname() { printf 'MINGW64_NT-10.0-26100\n'; }

  # A genuinely dead pid: kill(2) reports ESRCH regardless of platform.
  sh -c 'exit 0' & local gone=$!; wait "$gone" 2>/dev/null

  # 1) self and target both listed -> alive.
  ps() {
    printf 'PID PPID PGID WINPID TTY UID STIME COMMAND\n'
    printf '%s 1 1 999 ? 0 0 sh\n' "$$"
    printf '%s 1 1 998 ? 0 0 sh\n' "$gone"
  }
  run _agmsg_pid_alive_local "$gone"
  [ "$status" -eq 0 ] || { echo "MSYS: a pid ps -l actually listed did not read alive"; false; }

  # 2) self listed, target absent -> positive proof of death. This is the
  # case the Windows hang needed and never got from the -p-filtered query.
  ps() {
    printf 'PID PPID PGID WINPID TTY UID STIME COMMAND\n'
    printf '%s 1 1 999 ? 0 0 sh\n' "$$"
  }
  run _agmsg_pid_alive_local "$gone"
  [ "$status" -ne 0 ] || { echo "MSYS: a ps -l listing self but omitting the target did not read dead"; false; }

  # 3) ps fails outright -> UNKNOWN. #954's rule holds here exactly as it
  # does on POSIX: a failed observation must never be read as proof of death.
  ps() { return 1; }
  run _agmsg_pid_alive_local "$gone"
  [ "$status" -eq 0 ] || { echo "MSYS: a failed ps -l was read as proof of death"; false; }

  # 4) ps succeeds (rc=0) but the listing carries no row for our own $$ --
  # canary absent, so the listing cannot be trusted as complete -> UNKNOWN,
  # exactly the POSIX branch's own truncated-snapshot rule.
  ps() {
    printf 'PID PPID PGID WINPID TTY UID STIME COMMAND\n'
    printf '999999 1 1 999 ? 0 0 sh\n'
  }
  run _agmsg_pid_alive_local "$gone"
  [ "$status" -eq 0 ] || { echo "MSYS: a ps -l listing with no canary row was read as proof of death"; false; }

  # 5) Regression pin for the exact shape measured live on real Windows Git
  # Bash from the OLD -p-filtered query on a dead pid: header only, rc=1.
  # Kept so an accidental return to a -p-filtered query is caught here,
  # never again only on a live CI runner.
  ps() { printf 'PID PPID PGID WINPID TTY UID STIME COMMAND\n'; return 1; }
  run _agmsg_pid_alive_local "$gone"
  [ "$status" -eq 0 ] || { echo "MSYS: the real dead-pid ps -l -p shape (header only, rc=1) was read as proof of death"; false; }

  # 6) (review) Cygwin/MSYS ps -l documents an optional leading state flag
  # (S/I/O) on SOME rows, not reflected in the header and not present on
  # every row -- pushing that row's PID to the second field. Self's row is
  # unflagged (the canary still succeeds by column 1 alone), but the
  # TARGET's row -- STOPPED (SIGSTOP), which is alive, not dead -- carries
  # a flag. Column-1-only reading would miss the target's real pid entirely
  # and misreport a live-but-stopped process as dead; this is the exact
  # hole review found and #954's own failure shape.
  #
  # The flagged row is verbatim what review measured live (MINGW64, a bash
  # stopped with `kill -STOP`; only the pid substitutes this test's own
  # target) -- column widths, leading space, and the STIME shape included,
  # a stronger fixture than a hand-written one. The SAME pid resumed (`kill
  # -CONT`) was also measured, flag gone and PID back in column 1 -- i.e.
  # the flag is this process's transient stopped state, not a property of
  # the pid. I and O were not reached live in that measurement; the regex
  # below still matches them on Cygwin's own documented flag set, but only
  # S has real hardware behind it here.
  ps() {
    printf 'PID PPID PGID WINPID TTY UID STIME COMMAND\n'
    printf '%s 1 1 999 ? 0 0 sh\n' "$$"
    printf 'S %s 3967149 3967078    1026648  ?         197609 23:30:42 /usr/bin/bash\n' "$gone"
  }
  run _agmsg_pid_alive_local "$gone"
  [ "$status" -eq 0 ] || { echo "MSYS: a stopped-but-alive target whose ps -l row carried a leading state flag was read as dead"; false; }
}

@test "pid_alive: a failing ps under set -e does not terminate a non-conditional caller (#954)" {
  skip_on_windows "POSIX kill path; Windows uses tasklist (#134)"
  # The leaf helper's contract must not depend on caller syntax. Called as a bare
  # statement under errexit, a ps that fails must not kill the shell before the
  # UNKNOWN -> alive verdict: the observation failure has to surface as "alive",
  # never as caller termination.
  run bash -c '
    set -e
    source "'"$SKILL_DIR"'/scripts/lib/instance-id.sh"
    ps() { return 1; }
    kill() { echo "bash: kill: - No such process" >&2; return 1; }
    _agmsg_pid_alive_local 99999999
    echo REACHED-alive
  '
  [ "$status" -eq 0 ] || { echo "the caller shell died on a failing ps under set -e"; false; }
  printf '%s\n' "$output" | grep -q REACHED-alive || { echo "did not continue past the helper call"; false; }
}

# --- sourcing on a PATH without dirname ---
#
# instance-id.sh locates compat.sh with builtins only. A $(dirname ...) here
# fails on a PATH that lacks it, and _agmsg_detect_platform is then undefined
# for _agmsg_pid_alive_local's MSYS branch.

# A PATH holding the tools the liveness check needs, and no dirname.
_no_dirname_path() {
  local bin="$BATS_TEST_TMPDIR/nodirname-bin" t
  mkdir -p "$bin"
  for t in ps uname awk sed grep tr cat head sleep; do
    command -v "$t" >/dev/null 2>&1 && ln -sf "$(command -v "$t")" "$bin/$t"
  done
  [ ! -e "$bin/dirname" ]
  printf '%s' "$bin"
}

@test "instance-id.sh sourced without dirname on PATH still defines _agmsg_detect_platform" {
  skip_on_windows "POSIX PATH layout"
  local bin; bin="$(_no_dirname_path)"
  run env PATH="$bin" "$BASH" -c '
    . "'"$SKILL_DIR"'/scripts/lib/instance-id.sh"
    declare -f _agmsg_detect_platform >/dev/null || { echo "detect_platform undefined"; exit 1; }
    _agmsg_detect_platform && echo "platform=$_agmsg_platform"
  '
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *platform=* ]]
}

@test "instance-id.sh sourced without dirname on PATH still proves a dead pid dead" {
  skip_on_windows "POSIX kill path; Windows uses tasklist (#134)"
  local bin; bin="$(_no_dirname_path)"
  sh -c 'exit 0' & local gone=$!; wait "$gone" 2>/dev/null
  run env PATH="$bin" "$BASH" -c '
    . "'"$SKILL_DIR"'/scripts/lib/instance-id.sh"
    if _agmsg_pid_alive_local '"$gone"'; then echo alive; exit 1; fi
    echo dead
  '
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$output" = dead ]
}

@test "instance-id.sh sourced directly under set -e does not abort, with and without dirname" {
  skip_on_windows "POSIX PATH layout"
  local bin; bin="$(_no_dirname_path)"
  run "$BASH" -c 'set -e; . "'"$SKILL_DIR"'/scripts/lib/instance-id.sh"; echo SOURCED'
  [ "$status" -eq 0 ] && [ "$output" = SOURCED ] || { echo "$output"; false; }
  run env PATH="$bin" "$BASH" -c 'set -e; . "'"$SKILL_DIR"'/scripts/lib/instance-id.sh"; echo SOURCED'
  [ "$status" -eq 0 ] && [ "$output" = SOURCED ] || { echo "$output"; false; }
}

@test "instance-id.sh sourced by a bare file name (no slash in BASH_SOURCE) finds compat.sh in the cwd" {
  skip_on_windows "POSIX PATH layout"
  run "$BASH" -c 'cd "'"$SKILL_DIR"'/scripts/lib" && . ./instance-id.sh && declare -f _agmsg_detect_platform >/dev/null && echo ok'
  [ "$output" = ok ] || { echo "$output"; false; }
}

# --- agmsg_normalize_instance_id ---

@test "normalize: a composite token passes through unchanged (idempotent)" {
  [ "$(agmsg_normalize_instance_id "sess.4242" claude-code 2>/dev/null)" = "sess.4242" ]
}

@test "normalize: a bare sid derives the composite from the agent pid" {
  # Stub the resolver so the derivation is deterministic without a real agent
  # ancestor (bats has none).
  agmsg_agent_pid() { echo 4242; }
  [ "$(agmsg_normalize_instance_id "sess" claude-code)" = "sess.4242" ]
}

@test "normalize: falls back to the bare sid when the agent pid is unresolved" {
  agmsg_agent_pid() { return 1; }
  # Capture stdout only — the fallback also writes a warning to stderr.
  local got
  got="$(agmsg_normalize_instance_id "sess" claude-code 2>/dev/null)"
  [ "$got" = "sess" ]
}

@test "normalize: warns on stderr when falling back" {
  agmsg_agent_pid() { return 1; }
  run bash -c '
    source "'"$SKILL_DIR"'/scripts/lib/resolve-project.sh"
    source "'"$SKILL_DIR"'/scripts/lib/instance-id.sh"
    agmsg_agent_pid() { return 1; }
    agmsg_normalize_instance_id sess claude-code 2>&1 1>/dev/null
  '
  [[ "$output" == *"falling back to bare session_id"* ]]
}

# --- AGMSG_AGENT_PID override ---

@test "override: a numeric AGMSG_AGENT_PID pins the resolved pid" {
  sleep 60 & local agent_pid=$!
  AGMSG_AGENT_PID="$agent_pid" run agmsg_agent_pid claude-code
  [ "$status" -eq 0 ]
  [ "$output" = "$agent_pid" ]
  [ "$(AGMSG_AGENT_PID="$agent_pid" agmsg_instance_id sess claude-code)" = "sess.$agent_pid" ]
  kill "$agent_pid" 2>/dev/null || true
  wait "$agent_pid" 2>/dev/null || true
}

@test "override: an empty AGMSG_AGENT_PID forces the bare fallback" {
  AGMSG_AGENT_PID="" run agmsg_agent_pid claude-code
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [ "$(AGMSG_AGENT_PID="" agmsg_instance_id sess claude-code 2>/dev/null)" = "sess" ]
}

@test "override: a non-numeric AGMSG_AGENT_PID is ignored with a warning" {
  AGMSG_AGENT_PID="abc" run agmsg_agent_pid claude-code
  [ "$status" -ne 0 ]
  [[ "$output" == *"ignoring non-numeric AGMSG_AGENT_PID"* ]]
}

@test "override: a dead AGMSG_AGENT_PID warns and falls back to the ppid walk" {
  local walk_pid="$$"
  compat_get_ppid() { printf '%s\n' "$walk_pid"; }
  agmsg_pid_is_agent() { [ "$1" = "$walk_pid" ]; }

  AGMSG_AGENT_PID=2147483647 run agmsg_agent_pid claude-code
  [ "$status" -eq 0 ]
  [[ "$output" == *"ignoring dead AGMSG_AGENT_PID=2147483647"* ]]
  [ "${lines[${#lines[@]} - 1]}" = "$walk_pid" ]
}

# --- CLAUDE_PID hook subprocess contract ---

@test "claude pid: resolves a live CLAUDE_PID before a blocked ps walk" {
  unset AGMSG_AGENT_PID
  compat_get_ppid() { return 1; }
  ps() { return 1; }
  CLAUDE_PID="$$" run agmsg_agent_pid claude-code
  [ "$status" -eq 0 ]
  [ "$output" = "$$" ]
}

@test "claude pid: explicit empty AGMSG_AGENT_PID still forces bare fallback" {
  AGMSG_AGENT_PID="" CLAUDE_PID="$$" run agmsg_agent_pid claude-code
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "claude pid: non-numeric AGMSG_AGENT_PID still forces bare fallback" {
  AGMSG_AGENT_PID=invalid CLAUDE_PID="$$" run agmsg_agent_pid claude-code
  [ "$status" -ne 0 ]
  [[ "$output" == *"ignoring non-numeric AGMSG_AGENT_PID"* ]]
  [[ "$output" != *"$$"* ]]
}

@test "claude pid: dead AGMSG_AGENT_PID falls through to a live CLAUDE_PID" {
  AGMSG_AGENT_PID=2147483647 CLAUDE_PID="$$" run agmsg_agent_pid claude-code
  [ "$status" -eq 0 ]
  [[ "$output" == *"ignoring dead AGMSG_AGENT_PID=2147483647"* ]]
  [ "${lines[${#lines[@]} - 1]}" = "$$" ]
}

@test "claude pid: invalid CLAUDE_PID values fall through to the ancestry walk" {
  local raw
  unset AGMSG_AGENT_PID
  compat_get_ppid() { return 1; }
  for raw in 0 -1 invalid " 1" "1 " $'1\n2'; do
    CLAUDE_PID="$raw" run agmsg_agent_pid claude-code
    [ "$status" -ne 0 ]
    [ -z "$output" ]
  done
}

@test "claude pid: non-claude types ignore a live CLAUDE_PID" {
  unset AGMSG_AGENT_PID
  compat_get_ppid() { return 1; }
  CLAUDE_PID="$$" run agmsg_agent_pid codex
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

# --- actas distinctness: the #93 payoff ---

# Two instance ids that share a session_id prefix but differ in pid must be
# treated as distinct owners — the collision that broke the actas lock is gone.
@test "actas: same session_id, different pid -> distinct live owners (#93)" {
  skip_on_windows "instance-id live PID liveness under Git Bash (#182)"
  sleep 60 3>&- & local pa=$!
  sleep 60 3>&- & local pb=$!
  local ta="sess.$pa" tb="sess.$pb"

  # pa claims; pb is refused because pa is a live, distinct owner.
  run actas_lock_claim team alice "$ta"
  [ "$status" -eq 0 ]
  run actas_lock_claim team alice "$tb"
  [ "$status" -eq 1 ]
  [ "$output" = "held:$ta" ]

  # State classification agrees from both sides.
  [ "$(actas_lock_state team alice "$ta")" = "mine" ]
  [ "$(actas_lock_state team alice "$tb")" = "other:$ta" ]

  # When the owner pid dies, the lock is reclaimable (stale → free).
  kill "$pa" 2>/dev/null || true
  wait "$pa" 2>/dev/null || true
  [ "$(actas_lock_state team alice "$tb")" = "free" ]

  kill "$pb" 2>/dev/null || true
  wait "$pb" 2>/dev/null || true
}

# --- liveness: "can I signal this" is not "is this running" ---

# A pid that exists but this user cannot signal, so `kill -0` fails with EPERM
# rather than ESRCH. pid 1 is that on any normal desktop or CI runner; when the
# suite runs as root, or in a container where pid 1 is ours, there is no such
# pid to borrow and the distinction under test cannot be staged.
require_eperm_pid() {
  local err
  # An `A && skip` list is a FAILING command on exactly the run we want, which
  # bats' errexit turns into a test failure instead of a skip.
  if kill -0 1 2>/dev/null; then skip "pid 1 is signalable here; no EPERM fixture available"; fi
  # `|| true`: the substitution's status is the failing kill, and a bare
  # assignment carrying it trips errexit before the case can decide anything.
  err="$(export LC_ALL=C; kill -0 1 2>&1)" || true
  case "$err" in
    *[Nn]'o such process'*) skip "pid 1 does not exist here" ;;
  esac
}

@test "instance-id: an unsignalable pid is alive, not dead" {
  require_eperm_pid
  run _agmsg_pid_alive 1
  [ "$status" -eq 0 ]
}

@test "instance-id: liveness rejects a dead pid, and anything that is not a pid" {
  local dead
  dead="$(bash -c 'echo $$')"
  wait_for_pid_exit "$dead" || true
  run _agmsg_pid_alive "$dead"; [ "$status" -ne 0 ]
  run _agmsg_pid_alive "";     [ "$status" -ne 0 ]
  run _agmsg_pid_alive "abc";  [ "$status" -ne 0 ]
  run _agmsg_pid_alive "12x";  [ "$status" -ne 0 ]
  run _agmsg_pid_alive $$;     [ "$status" -eq 0 ]
}

@test "instance-id: 0 is not a live pid, it is this process group" {
  # `kill -0 0` SUCCEEDS: 0 addresses the caller's own process group, not pid 0.
  # A digits-only check therefore called 0 alive, and callers kill whatever this
  # reports alive — `kill 0` TERMs the group, the caller included. All it takes
  # is a pidfile holding 0.
  run kill -0 0; [ "$status" -eq 0 ]
  local bad
  for bad in 0 00 000 0123; do
    run _agmsg_pid_alive "$bad"
    [ "$status" -ne 0 ] || { echo "_agmsg_pid_alive $bad reported alive"; false; }
    run _agmsg_pid_valid "$bad"
    [ "$status" -ne 0 ] || { echo "_agmsg_pid_valid $bad accepted it"; false; }
  done
  run _agmsg_pid_valid $$;   [ "$status" -eq 0 ]
  run _agmsg_pid_valid "";   [ "$status" -ne 0 ]
  run _agmsg_pid_valid "1x"; [ "$status" -ne 0 ]
}

@test "instance-id: a pid too large for pid_t is dead, not alive forever" {
  # Past INT32_MAX kill(1) rejects the ARGUMENT instead of reporting ESRCH, and
  # everything that is not ESRCH is read as EPERM, i.e. alive. Unbounded, an
  # oversized value in a pidfile reads as alive forever: its lock is never
  # reclaimed and its bridge is never restarted.
  local err
  err="$(export LC_ALL=C; kill -0 2147483648 2>&1)" || true
  case "$err" in
    *[Nn]'o such process'*) skip "kill treats out-of-range pids as ESRCH here" ;;
  esac
  local bad
  for bad in 2147483648 4294967296 999999999999999999999; do
    run _agmsg_pid_valid "$bad"
    [ "$status" -ne 0 ] || { echo "_agmsg_pid_valid $bad accepted it"; false; }
    run _agmsg_pid_alive "$bad"
    [ "$status" -ne 0 ] || { echo "_agmsg_pid_alive $bad reported alive"; false; }
  done
  # The boundary itself is a legal pid value and must still be accepted.
  run _agmsg_pid_valid 2147483647; [ "$status" -eq 0 ]
  run _agmsg_pid_valid 9999999;    [ "$status" -eq 0 ]
}

@test "instance-id: the pid ceiling is the platform's, not one number" {
  # A Windows process id is a DWORD, and liveness there reads the native process
  # table through tasklist rather than kill(1)'s signed pid_t. Applying the
  # POSIX ceiling to it would call a legitimate native pid dead and its live
  # watcher stale. Only the bound depends on MSYSTEM, so both sides are
  # checkable from either host.
  run env MSYSTEM=MINGW64 bash -c \
    'SKILL_DIR="'"$SKILL_DIR"'"; . "$SKILL_DIR/scripts/lib/instance-id.sh"
     _agmsg_pid_valid 2147483648 || exit 1
     _agmsg_pid_valid 4294967295 || exit 2
     _agmsg_pid_valid 4294967296 && exit 3
     _agmsg_pid_valid 0 && exit 4
     exit 0'
  [ "$status" -eq 0 ]

  # POSIX keeps the signed pid_t ceiling.
  run _agmsg_pid_valid 2147483648; [ "$status" -ne 0 ]
  run _agmsg_pid_valid 4294967295; [ "$status" -ne 0 ]
}

@test "instance-id: liveness answers alive on the builtin, before any subshell" {
  # The launcher polls liveness in loops that were deliberately made fork-free
  # (#466/#496). Routing them through a helper is only acceptable while the
  # common answer — alive — is still decided by the builtin, so the cheap check
  # has to come first and has to be able to return on its own.
  local body fast slow
  # The fast path lives in the _local helper now; _agmsg_pid_alive delegates to
  # it once the Windows branch declines. A function call is not a fork, so the
  # property this test exists for is unchanged -- but it has to be read where
  # the code is.
  body="$(declare -f _agmsg_pid_alive_local)"
  fast="$(printf '%s\n' "$body" | grep -n 'kill -0 .*&& return 0;$' | grep -v '\$(' | head -1 | cut -d: -f1)"
  slow="$(printf '%s\n' "$body" | grep -n 'kill -0 .*2>&1' | head -1 | cut -d: -f1)"
  [ -n "$fast" ]
  [ -n "$slow" ]
  [ "$fast" -lt "$slow" ]
  # And the delegation is a plain call, not a subshell, so the fork-free claim
  # survives the split.
  printf '%s\n' "$(declare -f _agmsg_pid_alive)" | grep -q '^ *_agmsg_pid_alive_local "\$pid"$'
}

# --- which pid space (#567) ---

@test "pid_alive_local: a pid we minted is alive even where tasklist cannot see it" {
  skip_on_windows "stubs tasklist; the real one is authoritative on Windows"
  # MSYSTEM steers _agmsg_pid_alive into its tasklist branch. tasklist reports
  # Windows pids, and a pid from $! or $$ in one of these shells is numbered in
  # the MSYS space, so it is absent -- which the plain helper reads as dead.
  # _local is the one that must not ask.
  local stub="$BATS_TEST_TMPDIR/stub-bin"
  mkdir -p "$stub"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$stub/tasklist"
  chmod +x "$stub/tasklist"

  MSYSTEM=MINGW64 PATH="$stub:$PATH" _agmsg_pid_alive_local $$
  # The counterpart, pinned so the split is not a distinction without a
  # difference: the same live pid reads as dead through the plain helper.
  ! MSYSTEM=MINGW64 PATH="$stub:$PATH" _agmsg_pid_alive $$
}

@test "pid_alive_local: an oversized pid is dead on Windows too" {
  skip_on_windows "POSIX kill path; the ceiling is what is under test"
  # The validator widens to the DWORD range when MSYSTEM is set, because a
  # Windows pid is a DWORD and tasklist is only asked to match a number. But
  # _local hands the value to kill(1) even there, and past INT32_MAX kill
  # rejects the argument rather than reporting ESRCH -- which reads as alive.
  # Inheriting the wide ceiling would make an oversized pidfile value alive
  # forever: lock never reclaimed, bridge never restarted (#505).
  local err
  err="$(export LC_ALL=C; kill -0 2147483648 2>&1)" || true
  case "$err" in
    *[Nn]'o such process'*) skip "kill treats out-of-range pids as ESRCH here" ;;
  esac
  local bad
  for bad in 2147483648 4294967295; do
    run env MSYSTEM=MINGW64 bash -c \
      ". '$SCRIPTS/lib/instance-id.sh'; _agmsg_pid_alive_local $bad"
    [ "$status" -ne 0 ] || { echo "_agmsg_pid_alive_local $bad reported alive"; false; }
  done
  # The platform ceiling itself is untouched: the same value is still a legal
  # thing to ask tasklist about.
  run env MSYSTEM=MINGW64 bash -c \
    ". '$SCRIPTS/lib/instance-id.sh'; _agmsg_pid_valid 4294967295"
  [ "$status" -eq 0 ]
}

@test "pid_alive_local: EPERM still reads as alive (sandbox)" {
  skip_on_windows "POSIX kill path"
  # The reason the fix is not a bare `kill -0`: a pid we minted is still a pid a
  # sandbox may refuse to let us signal, and #505 is what made that not mean dead.
  kill() { echo "bash: kill: (1) - Operation not permitted" >&2; return 1; }
  _agmsg_pid_alive_local 1
}

@test "no shipped script decides liveness with a bare kill -0" {
  # #500's lesson: a partially-hardened file reads as a fixed one. Every
  # liveness check must go through _agmsg_pid_alive, which is EPERM-aware and
  # cross-checks ps; instance-id.sh is where that check is implemented, so it
  # is the one file allowed to call kill -0 directly. A line may carry
  # `agmsg-kill0-ok` where the pid is the caller's own parent and the answer
  # must not depend on ps (watchdog.sh's lock-holder child).
  local offenders
  offenders="$(cd "$BATS_TEST_DIRNAME/.." && grep -rn -e 'kill -0' -e 'kill -s 0' scripts bin 2>/dev/null \
    | grep -v '^scripts/lib/instance-id.sh:' \
    | grep -v ':[0-9]*: *#' \
    | grep -v 'agmsg-kill0-ok' || true)"
  [ -z "$offenders" ] || { echo "$offenders"; false; }
}

# --- agmsg_cc_instance_current: the strict reader of run/cc-instance.<pid> ---

@test "cc_instance_current: a well-formed record for this pid prints its token" {
  printf 'sid-new.4242\n' > "$RUN_DIR/cc-instance.4242"
  run agmsg_cc_instance_current 4242
  [ "$status" -eq 0 ]
  [ "$output" = "sid-new.4242" ]
}

@test "cc_instance_current: no record is rc 1" {
  run agmsg_cc_instance_current 4242
  [ "$status" -eq 1 ]
}

@test "cc_instance_current: a record that cannot authorize anything is rc 2" {
  local variant
  for variant in empty bare wrong-pid dotted-sid multiline spaced blank-line nul symlink dangling directory; do
    rm -rf "$RUN_DIR/cc-instance.4242"
    case "$variant" in
      empty) : > "$RUN_DIR/cc-instance.4242" ;;
      bare) printf 'sid-new\n' > "$RUN_DIR/cc-instance.4242" ;;
      wrong-pid) printf 'sid-new.4243\n' > "$RUN_DIR/cc-instance.4242" ;;
      dotted-sid) printf 'a.b.4242\n' > "$RUN_DIR/cc-instance.4242" ;;
      multiline) printf 'sid-new.4242\nextra\n' > "$RUN_DIR/cc-instance.4242" ;;
      spaced) printf 'sid-new.4242 \n' > "$RUN_DIR/cc-instance.4242" ;;
      blank-line) printf 'sid-new.4242\n\n' > "$RUN_DIR/cc-instance.4242" ;;
      nul) printf 'sid\0-new.4242\n' > "$RUN_DIR/cc-instance.4242" ;;
      symlink)
        printf 'sid-new.4242\n' > "$BATS_TEST_TMPDIR/real"
        ln -s "$BATS_TEST_TMPDIR/real" "$RUN_DIR/cc-instance.4242" ;;
      dangling) ln -s "$BATS_TEST_TMPDIR/nowhere" "$RUN_DIR/cc-instance.4242" ;;
      directory) mkdir "$RUN_DIR/cc-instance.4242" ;;
    esac
    run agmsg_cc_instance_current 4242
    [ "$status" -eq 2 ] || { echo "$variant: rc=$status out=$output"; return 1; }
  done
}

@test "cc_instance_current: a non-numeric pid is rc 2" {
  run agmsg_cc_instance_current "4242x"
  [ "$status" -eq 2 ]
}
