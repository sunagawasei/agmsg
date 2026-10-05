#!/usr/bin/env bats

# This fork ships three agent types (claude-code, codex, cursor). These tests
# keep the removed types and products from creeping back into tracked files.

load test_helper

REMOVED_NAMES='grok-build|grok_build|GROK_SESSION_ID|antigravity|gemini|copilot|hermes|opencode|agmsg-app'

@test "removed-types: bundled types are exactly claude-code, codex and cursor" {
  run bash -c "cd '$BATS_TEST_DIRNAME/..' && ls scripts/drivers/types"
  [ "$status" -eq 0 ]
  [ "$output" = $'claude-code\ncodex\ncursor' ]
}

@test "removed-types: app, site, plugins and scripts/windows are gone" {
  local d
  for d in app site plugins scripts/windows; do
    [ ! -e "$BATS_TEST_DIRNAME/../$d" ]
  done
}

# `git grep` / `grep` exit 0 (matches) or 1 (none); anything else is a failed
# search, which must not be read as "no references".
_search() { # <dir-relative cmd...>; sets status/output
  run bash -c "cd '$BATS_TEST_DIRNAME/..' && $1"
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ] || { echo "search failed ($status): $output" >&2; return 1; }
}

@test "removed-types: no tracked file names a removed type outside the allowlist" {
  # Allowed: history (CHANGELOG, ADRs), this file, the install.sh prune list,
  # test_install.bats lines tagged removed-type-fixture, the --agent-type rejection case,
  # and the contributor credit line.
  _search "git grep -nIiE '$REMOVED_NAMES' -- . ':!CHANGELOG.md' ':!docs/adr' ':!tests/test_removed_types.bats'"
  local hits
  hits="$(printf '%s\n' "$output" \
    | { grep -vE '^install\.sh:.*for _agmsg_removed in ' || true; } \
    | { grep -vE '^tests/test_install\.bats:.*(--agent-type gemini|Unsupported --agent-type .gemini.)' || true; } \
    | { grep -vE '^tests/test_install\.bats:.*removed-type-fixture' || true; } \
    | { grep -vE '^README(\.ja)?\.md:.*(External contributors|外部コントリビューター)' || true; })"
  [ -z "$hits" ] || { echo "$hits" >&2; false; }
}

@test "removed-types: remaining templates' spawn lists name no removed type" {
  _search "grep -nIiE '$REMOVED_NAMES' scripts/drivers/types/*/template.md"
  [ -z "$output" ] || { echo "$output" >&2; false; }
}

@test "removed-types: docs link no deleted path (site/, pages.yml, docs/opencode.md)" {
  _search "git grep -nIE '\]\((\./)?(site/|docs/opencode\.md|\.github/workflows/pages\.yml)' -- '*.md'"
  [ -z "$output" ] || { echo "$output" >&2; false; }
}
