#!/usr/bin/env bats

# #804. `pull` wrote the team binding at whatever the caller's umask produced,
# and the `unlock` after it refused that file: every reader of a binding rejects
# `mode & 0o022`, and `umask 002` -- ordinary on a group-shared machine --
# produces 0664. The product refused its own output, on the happy path, every
# time, for anyone with that umask.
#
# The mode is asserted rather than the message, because the message is downstream
# of it: fix the mode and no reader has anything to refuse.

load test_helper

setup() {
  setup_test_env
  export SKILL_DIR="$TEST_SKILL_DIR"
}
teardown() { teardown_test_env; }

# `stat` is one of the flags this suite exists to keep honest across userlands.
file_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

@test "a binding written under umask 002 is not group-writable (#804)" {
  ( umask 002; bash "$SCRIPTS/join.sh" umaskteam alice claude-code /tmp/p-804 >/dev/null )
  local cfg mode
  cfg="$TEST_SKILL_DIR/teams/umaskteam/config.json"
  [ -f "$cfg" ]
  mode="$(file_mode "$cfg")"
  # The property the readers enforce, stated the way they state it.
  [ "$(( 8#$mode & 8#0022 ))" -eq 0 ]
  # And the mode this product gives its own authority files.
  [ "$mode" = "600" ]
}

@test "the same holds under umask 000, where nothing is masked (#804)" {
  # 002 is the reported case; 000 is the one that proves the write sets the mode
  # rather than merely surviving a friendly umask.
  ( umask 000; bash "$SCRIPTS/join.sh" openteam alice claude-code /tmp/p-804b >/dev/null )
  local mode
  mode="$(file_mode "$TEST_SKILL_DIR/teams/openteam/config.json")"
  [ "$(( 8#$mode & 8#0022 ))" -eq 0 ]
  [ "$mode" = "600" ]
}

@test "a rewrite of an existing binding does not widen it back (#804)" {
  # The second write goes through the same helper; a temp file left by a killed
  # run would otherwise carry its old mode through `>`.
  ( umask 002; bash "$SCRIPTS/join.sh" rewriteteam alice claude-code /tmp/p-804c >/dev/null )
  local cfg
  cfg="$TEST_SKILL_DIR/teams/rewriteteam/config.json"
  printf 'stale\n' > "$cfg.tmp.$$"
  chmod 666 "$cfg.tmp.$$"
  ( umask 002; bash "$SCRIPTS/join.sh" rewriteteam bob claude-code /tmp/p-804d >/dev/null )
  [ "$(( 8#$(file_mode "$cfg") & 8#0022 ))" -eq 0 ]
}
