# Shared setup/teardown for agmsg BATS tests.
# Each test gets an isolated skill directory with its own DB and teams.

setup_test_env() {
  export TEST_SKILL_DIR="$(mktemp -d)"
  mkdir -p "$TEST_SKILL_DIR"/{scripts,db,teams}

  # Copy all scripts to isolated skill dir. Recursive so nested helper dirs
  # (scripts/lib/) come along without enumerating files.
  cp -R "$BATS_TEST_DIRNAME"/../scripts/. "$TEST_SKILL_DIR/scripts/"
  chmod +x "$TEST_SKILL_DIR/scripts/"*.sh
  chmod +x "$TEST_SKILL_DIR/scripts/"*.js 2>/dev/null || true

  # Initialize DB
  bash "$TEST_SKILL_DIR/scripts/init-db.sh"

  # Convenience vars
  export SCRIPTS="$TEST_SKILL_DIR/scripts"

  # Sandbox HOME so NO test can touch the developer's real home. Several paths
  # write under $HOME — e.g. codex-shim-install.sh creates $HOME/.agents/bin/codex
  # and install.sh's configure_codex_sandbox edits $HOME/.codex/config.toml — and
  # a leaked write would clobber the real install / shim (and dangle once this
  # temp dir is torn down). bats runs each test in its own subshell, so the
  # export is scoped to the test and needs no restore. See #41.
  export HOME="$TEST_SKILL_DIR/home"
  mkdir -p "$HOME"
}

teardown_test_env() {
  rm -rf "$TEST_SKILL_DIR"
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
  local deadline=$(( SECONDS + timeout ))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if "$@"; then return 0; fi
    sleep 0.1
  done
  "$@"
}
