#!/usr/bin/env bats

# The SessionEnd hook entry carries a per-hook `timeout` (seconds) for the types
# whose manifest sets hook_session_end_timeout, because the default budget is
# 1.5s and shared by every SessionEnd hook.

load test_helper

setup() {
  setup_test_env
  export SKILL_DIR="$TEST_SKILL_DIR"
  TEST_PROJECT="$TEST_SKILL_DIR/proj"
  mkdir -p "$TEST_PROJECT"
  SETTINGS="$TEST_PROJECT/.claude/settings.local.json"
}

teardown() { teardown_test_env; }

_fake_codex_path() {
  local dir="$TEST_SKILL_DIR/fakebin"
  mkdir -p "$dir"
  printf '#!/bin/sh\necho "%s"\n' "$1" > "$dir/codex"
  chmod +x "$dir/codex"
  printf '%s' "$dir"
}

# jq-free JSON read: <file> <json path>; empty when absent.
jget() {
  sqlite_mem "SELECT json_extract(readfile('$(rf "$1")'), '$2');"
}

@test "claude-code monitor/both: the SessionEnd entry has timeout 5, SessionStart and Stop have none" {
  local mode
  for mode in monitor both; do
    rm -f "$SETTINGS"
    bash "$SCRIPTS/delivery.sh" set "$mode" claude-code "$TEST_PROJECT"
    [ "$(jget "$SETTINGS" '$.hooks.SessionEnd[0].hooks[0].timeout')" = "5" ]
    [ -z "$(jget "$SETTINGS" '$.hooks.SessionStart[0].hooks[0].timeout')" ]
    if [ "$mode" = both ]; then
      [ -z "$(jget "$SETTINGS" '$.hooks.Stop[0].hooks[0].timeout')" ]
    fi
  done
}

@test "re-running delivery set turns a SessionEnd entry registered without timeout into one with timeout 5" {
  mkdir -p "$TEST_PROJECT/.claude"
  printf '%s' '{"hooks":{"SessionEnd":[{"matcher":"","hooks":[{"type":"command","command":"'"$SCRIPTS"'/session-end.sh claude-code x"}]}]}}' > "$SETTINGS"
  [ -z "$(jget "$SETTINGS" '$.hooks.SessionEnd[0].hooks[0].timeout')" ]
  bash "$SCRIPTS/delivery.sh" set monitor claude-code "$TEST_PROJECT"
  bash "$SCRIPTS/delivery.sh" set monitor claude-code "$TEST_PROJECT"
  [ "$(sqlite_mem "SELECT json_array_length(json_extract(readfile('$(rf "$SETTINGS")'), '\$.hooks.SessionEnd'));")" = "1" ]
  [ "$(jget "$SETTINGS" '$.hooks.SessionEnd[0].hooks[0].timeout')" = "5" ]
}

@test "a type without hook_session_end_timeout (codex) gets a SessionEnd entry with no timeout" {
  run env PATH="$(_fake_codex_path 'codex-cli 0.149.1'):$PATH" bash "$SCRIPTS/delivery.sh" set monitor codex "$TEST_PROJECT"
  local hf="$TEST_PROJECT/.codex/hooks.json"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ -f "$hf" ]
  [ "$(sqlite_mem "SELECT json_array_length(json_extract(readfile('$(rf "$hf")'), '\$.hooks.SessionEnd'));")" = "1" ]
  [ -z "$(jget "$hf" '$.hooks.SessionEnd[0].hooks[0].timeout')" ]
}

@test "add_event_entry_file: no fifth argument leaves the entry unchanged; a bad timeout is ignored" {
  source "$SCRIPTS/lib/storage.sh"
  source "$SCRIPTS/lib/hooks-json.sh"
  local f="$TEST_SKILL_DIR/h.json" v
  printf '{}' > "$f"
  add_event_entry_file "$f" SessionEnd "echo hi" ""
  [ -z "$(jget "$f" '$.hooks.SessionEnd[0].hooks[0].timeout')" ]
  for v in "" "abc" "0" "00" "61" "-1" "5;DROP" "1.5" "100" "99999999999999999999" "5'" $'5\n6'; do
    printf '{}' > "$f"
    add_event_entry_file "$f" SessionEnd "echo hi" "" "$v"
    [ -z "$(jget "$f" '$.hooks.SessionEnd[0].hooks[0].timeout')" ] || { echo "timeout written for [$v]"; return 1; }
    [ "$(jget "$f" '$.hooks.SessionEnd[0].hooks[0].command')" = "echo hi" ]
  done
  for v in 1 5 05 60; do
    printf '{}' > "$f"
    add_event_entry_file "$f" SessionEnd "echo hi" "" "$v"
    [ "$(jget "$f" '$.hooks.SessionEnd[0].hooks[0].timeout')" = "$((10#$v))" ] || { echo "no timeout for [$v]"; return 1; }
  done
}
