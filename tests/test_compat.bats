#!/usr/bin/env bats

# Tests for compat.sh fallback paths (#225): /proc → CIM → ps -l degraded.
# These tests exercise the MSYS2-specific branches and are skipped on other
# platforms where the POSIX ps -o paths are used directly.

load test_helper

skip_unless_msys() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) ;;
    *) skip "MSYS2-only test" ;;
  esac
}

_stub_cmdline_visible() (
  local cmd stub_name="${_STUB##*/}"
  # Exercise the same forced-CIM observation seam used by the fallback cases;
  # setup readiness must not be satisfied by /proc while CIM is still stale.
  _AGMSG_COMPAT_NO_PROC=1
  export _AGMSG_COMPAT_NO_PROC
  unset _AGMSG_COMPAT_NO_CIM
  cmd="$(compat_get_cmdline "$_STUB_PID" 2>/dev/null || true)"
  # Require the full fixture path as one command-line token, not a substring
  # from a still-starting parent command.
  case " $cmd " in
    *"/$stub_name"[[:space:]]*) return 0 ;;
  esac
  return 1
)

setup() {
  setup_test_env
  skip_unless_msys

  # Stub script under TEST_SKILL_DIR/scripts/ so the full-path scoped-kill
  # pattern (*"$TEST_SKILL_DIR/scripts/stub-watch.sh"*) can be tested.
  _STUB="$TEST_SKILL_DIR/scripts/stub-watch.sh"
  printf '#!/usr/bin/env bash\nsleep 60\n' > "$_STUB"
  chmod +x "$_STUB"

  bash "$_STUB" 3>&- &
  _STUB_PID=$!
  # shellcheck disable=SC1090
  source "$SCRIPTS/lib/compat.sh"
  # Poll until the actual compat command-line lookup sees the fixture, so the
  # MSYS / CIM path is ready without a fixed startup delay.
  wait_until 5 _stub_cmdline_visible
}

teardown() {
  kill "$_STUB_PID" 2>/dev/null || true
  wait "$_STUB_PID" 2>/dev/null || true
  teardown_test_env
}

# ── /proc path (normal — regression guard) ───────────────────────────────

@test "compat_get_cmdline returns full argv via /proc" {
  result=$(compat_get_cmdline "$_STUB_PID")
  [[ "$result" == *stub-watch.sh* ]]
}

@test "compat_get_comm returns basename via /proc" {
  result=$(compat_get_comm "$_STUB_PID")
  [ "$result" = "bash" ]
}

# ── CIM fallback path (_AGMSG_COMPAT_NO_PROC=1) ─────────────────────────

@test "compat_get_cmdline returns full argv via CIM when /proc bypassed" {
  export _AGMSG_COMPAT_NO_PROC=1
  result=$(compat_get_cmdline "$_STUB_PID")
  [ -n "$result" ]
  [[ "$result" == *stub-watch.sh* ]]
}

@test "compat_get_cmdline via CIM contains script path for scoped-kill match" {
  export _AGMSG_COMPAT_NO_PROC=1
  cmd=$(compat_get_cmdline "$_STUB_PID")
  # The scoped-kill pattern used by delivery.sh / session-end.sh / watch.sh
  # matches the full path with forward slashes, not just the bare filename.
  case "$cmd" in
    *"$TEST_SKILL_DIR/scripts/stub-watch.sh"*) true ;;
    *) echo "cmdline did not contain full path: $cmd" >&2; false ;;
  esac
}

@test "compat_get_comm returns basename without .exe via CIM when /proc bypassed" {
  export _AGMSG_COMPAT_NO_PROC=1
  result=$(compat_get_comm "$_STUB_PID")
  [ "$result" = "bash" ]
}

@test "compat_get_comm strips .exe suffix from CIM result" {
  export _AGMSG_COMPAT_NO_PROC=1
  result=$(compat_get_comm "$_STUB_PID")
  # Must not contain .exe — CIM returns Windows-style "bash.exe".
  [[ "$result" != *.exe ]]
}

# ── ps -l degraded path (_AGMSG_COMPAT_NO_PROC=1 + _AGMSG_COMPAT_NO_CIM=1) ─

@test "compat_get_cmdline degrades to executable-only when both /proc and CIM unavailable" {
  export _AGMSG_COMPAT_NO_PROC=1
  export _AGMSG_COMPAT_NO_CIM=1
  result=$(compat_get_cmdline "$_STUB_PID")
  # Degraded: returns only the COMMAND column (executable path), no args.
  [ -n "$result" ]
  [[ "$result" != *stub-watch.sh* ]]
}

@test "compat_get_comm degrades to basename when both /proc and CIM unavailable" {
  export _AGMSG_COMPAT_NO_PROC=1
  export _AGMSG_COMPAT_NO_CIM=1
  result=$(compat_get_comm "$_STUB_PID")
  [ "$result" = "bash" ]
}
