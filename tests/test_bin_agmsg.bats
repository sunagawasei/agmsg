#!/usr/bin/env bats

BIN="$BATS_TEST_DIRNAME/../bin/agmsg.js"

@test "bin/agmsg.js: --version exits successfully" {
  run node "$BIN" --version
  [ "$status" -eq 0 ]
  [[ "$output" =~ "agmsg bootstrapper" ]]
}

@test "bin/agmsg.js: --help exits successfully" {
  run node "$BIN" --help
  [ "$status" -eq 0 ]
  [[ "$output" =~ "npm bootstrapper for cross-agent messaging" ]]
}

# `agmsg <verb>` is the wrong guess the docs taught — a sweep of docs/design
# and docs/spec found 34 backticked commands assuming a CLI that does not
# exist. Fixing the documents does not help the person who types from memory,
# so the refusal has to name the real form.
#
# Asserted on the PATH being present, not on the wording: the value of this
# message is that it tells you what to type instead, and a test that only
# checked for "not a command" would pass on the old text.
@test "bin/agmsg.js: an unknown verb names the script to run instead" {
  run node "$BIN" send hello
  [ "$status" -eq 2 ]
  [[ "$output" =~ "is not a command" ]]
  [[ "$output" =~ "scripts/send.sh" ]]
}

# A verb with no mapping still has to answer "then what do I type", because
# the mapping is a hint that is allowed to be incomplete. `storage` is one the
# docs use and no script implements.
@test "bin/agmsg.js: an unmapped verb still points at the install" {
  run node "$BIN" storage list
  [ "$status" -eq 2 ]
  [[ "$output" =~ "is not a command" ]]
  [[ "$output" =~ "scripts/" ]]
}

@test "bin/agmsg.js: toBashPath converts backslashes to forward slashes (#262)" {
  run node -e 'const { toBashPath } = require(process.argv[1]); const input = String.raw`C:\Users\me\AppData\Local\Temp\agmsg-bootstrap-abc123\setup.sh`; const expected = "C:/Users/me/AppData/Local/Temp/agmsg-bootstrap-abc123/setup.sh"; if (toBashPath(input) !== expected) process.exit(1);' "$BIN"
  [ "$status" -eq 0 ]
}

@test "bin/agmsg.js: toBashPath is a no-op on POSIX paths" {
  run node -e 'const { toBashPath } = require(process.argv[1]); const p = "/tmp/agmsg-bootstrap-abc123/setup.sh"; if (toBashPath(p) !== p) process.exit(1);' "$BIN"
  [ "$status" -eq 0 ]
}
