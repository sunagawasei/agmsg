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

@test "a leftover permissive temp is never opened, so no content passes through it (#804)" {
  # THE STALE-TEMP CASE, and it has to be driven through the helper directly.
  #
  # An earlier version of this test spawned `join.sh` and planted a decoy named
  # `<dest>.tmp.$$` — but `$$` there was the TEST's pid, and the script writing
  # the file has its own. The decoy never had the name the old implementation
  # would have opened, so the control passed against both implementations. It
  # proved nothing, which is the same defect it exists to catch.
  #
  # Calling the helper in this shell makes `$$` the one it would use.
  local probe decoy
  probe="$TEST_SKILL_DIR/stale.json"
  decoy="$probe.tmp.$$"
  printf 'SENTINEL-NOT-TOUCHED\n' > "$decoy"
  chmod 666 "$decoy"

  # shellcheck disable=SC1091
  source "$SCRIPTS/lib/registry-lock.sh"
  agmsg_write_atomic "$probe" '{"endpoint":"https://host/t/THE-SECRET/"}'

  # 1. the leftover is still THERE. This is the assertion that discriminates:
  # the old implementation opened this exact path and then `mv`'d it into place,
  # so under that code the decoy does not survive at all -- it becomes the
  # destination. Its disappearance is the observable, and it has to be asserted
  # before its contents, because `cat` on a missing file is a different failure
  # with a different message.
  [ -f "$decoy" ]
  # 2. and it still holds its own bytes
  [ "$(cat "$decoy")" = "SENTINEL-NOT-TOUCHED" ]
  # 3. and the secret is not in it, at any mode. This one cannot be the reason
  # the test reddens -- adoption removes the file rather than leaving it with
  # the secret inside -- so it is a guard against a future implementation that
  # writes through the leftover WITHOUT consuming it, not the discriminator.
  #
  # `refute`, not `! grep`: a command under `!` is exempt from errexit, so the
  # negated form returns non-zero and the test carries on regardless -- it could
  # not fail. The repository has a checker for exactly this, and it was right to
  # stop this file. #715 is the same mechanism, found the same way.
  refute grep -q 'THE-SECRET' "$decoy"
  # 4. the real write happened, privately
  grep -q 'THE-SECRET' "$probe"
  [ "$(file_mode "$probe")" = "600" ]
  rm -f "$decoy"
}

@test "the temp the helper creates is private before any content is written (#804)" {
  # Asserted on the primitive rather than on a race: `mktemp` creates at 0600,
  # so there is no moment at which the file exists more permissively. If the
  # helper is changed to create-then-narrow, this stops holding.
  local probe
  probe="$TEST_SKILL_DIR/probe.json"
  ( umask 002
    source "$SCRIPTS/lib/registry-lock.sh"
    # A content large enough that the write is not one atomic-looking blip.
    agmsg_write_atomic "$probe" "$(head -c 200000 /dev/zero | tr '\0' 'x')" )
  [ "$(file_mode "$probe")" = "600" ]
  # No temp survives beside it.
  [ -z "$(find "$TEST_SKILL_DIR" -maxdepth 1 -name 'probe.json.tmp.*' -print -quit)" ]
}

@test "a write that fails part-way leaves the old file exactly as it was (#804)" {
  # `mv` makes a reader see the whole new file or the whole old one. It does not
  # make the CONTENT whole: a printf that writes half the payload and then fails
  # would be published, indivisibly, as a truncated destination (review).
  #
  # The failure is forced with `ulimit -f`, and SIGXFSZ is ignored so the write
  # RETURNS the error instead of killing the shell -- which is what makes the
  # helper's own handling observable rather than the kernel's.
  local dest original
  dest="$TEST_SKILL_DIR/partial.json"
  original='{"keep":"this exact byte string"}'
  printf '%s\n' "$original" > "$dest"
  chmod 600 "$dest"
  local before
  before="$(cat "$dest")"

  local status=0
  (
    trap '' XFSZ
    ulimit -f 1          # 512-byte blocks: a 200 KB payload cannot land
    # shellcheck disable=SC1091
    source "$SCRIPTS/lib/registry-lock.sh"
    agmsg_write_atomic "$dest" "$(head -c 200000 /dev/zero | tr '\0' 'x')"
  ) 2>/dev/null || status=$?

  # 1. it did not claim success
  [ "$status" -ne 0 ]
  # 2. the old destination is byte-for-byte what it was
  [ "$(cat "$dest")" = "$before" ]
  # 3. and nothing private was left lying beside it
  [ -z "$(find "$TEST_SKILL_DIR" -maxdepth 1 -name 'partial.json.tmp.*' -print -quit)" ]
}
