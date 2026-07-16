#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
}

teardown() {
  teardown_test_env
}

resolve_extra_fs_roots() {
  env SCRIPT_DIR="$SCRIPTS" bash -c '
    set -euo pipefail
    die() { echo "die: $*" >&2; exit 1; }
    . "$SCRIPT_DIR/drivers/types/codex/_spawn.sh"
    agmsg_codex_extra_fs_roots worker
  '
}

@test "codex extra fs roots: unset config returns an empty fragment" {
  run resolve_extra_fs_roots
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "codex extra fs roots: expands a leading tilde-home path" {
  bash "$SCRIPTS/config.sh" set spawn.codex_extra_fs_roots '~/x=read'

  run resolve_extra_fs_roots
  [ "$status" -eq 0 ]
  [ "$output" = ", \"$HOME/x\"=\"read\"" ]
}

@test "codex extra fs roots: rejects an invalid permission" {
  bash "$SCRIPTS/config.sh" set spawn.codex_extra_fs_roots '~/x=exec'

  run resolve_extra_fs_roots
  [ "$status" -ne 0 ]
  [[ "$output" == *"expected read or write"* ]]
}

@test "codex extra fs roots: rejects a double quote in the path" {
  bash "$SCRIPTS/config.sh" set spawn.codex_extra_fs_roots '~/x"quoted=read'

  run resolve_extra_fs_roots
  [ "$status" -ne 0 ]
  [[ "$output" == *"quote/backslash"* ]]
}
