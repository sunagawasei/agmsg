#!/usr/bin/env bats

load test_helper

# cursor's hooks.json plug (scripts/drivers/types/cursor/_delivery.sh): a FLAT,
# lowerCamel-named hooks file (stop/sessionStart/sessionEnd/beforeSubmitPrompt),
# unlike claude-code/codex's nested PascalCase `hooks[].hooks[]` shape that
# test_delivery.bats exercises. delivery.sh now calls agmsg_delivery_preflight
# before it writes the hooks file, so monitor/both here need herdr and
# HERDR_PANE_ID present; setup() supplies both as fixtures so this file is
# hermetic and does not depend on the host running inside a herdr pane. The
# preflight's own negative cases below still invoke the plug directly, with the
# fixtures removed.

setup() {
  setup_test_env
  export AGMSG_AGENT_PID=""
  export TEST_PROJECT="$(mktemp -d)"
  BASH_BIN="$(command -v bash)"
  # monitor/both preflight fixtures (see the header): a herdr stub on PATH and a
  # pane id, so `delivery.sh set monitor|both` reaches agmsg_delivery_apply
  # whether or not the host shell is inside a real herdr pane.
  HERDR_STUB_BIN="$TEST_SKILL_DIR/stubbin-herdr"
  mkdir -p "$HERDR_STUB_BIN"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$HERDR_STUB_BIN/herdr"
  chmod +x "$HERDR_STUB_BIN/herdr"
  PATH="$HERDR_STUB_BIN:$PATH"
  export PATH
  export HERDR_PANE_ID="w1:p1"
}

teardown() {
  teardown_test_env
  rm -rf "$TEST_PROJECT"
}

hooks_file() {
  echo "$TEST_PROJECT/.cursor/hooks.json"
}

# Number of entries under .hooks.<event>, or 0 when the event/file is absent.
hooks_count() {
  local event="$1" file="${2:-$(hooks_file)}"
  [ -f "$file" ] || { echo 0; return; }
  sqlite_mem "SELECT coalesce(json_array_length(json_extract(readfile('$(rf "$file")'), '\$.hooks.$event')), 0);"
}

hooks_command() {  # <event> <index> [file]
  local event="$1" idx="$2" file="${3:-$(hooks_file)}"
  sqlite_mem "SELECT json_extract(readfile('$(rf "$file")'), '\$.hooks.$event[$idx].command');"
}

old_rule_file() {
  echo "$TEST_PROJECT/.cursor/rules/agmsg.mdc"
}

# --- shape: flat, lowerCamel (no claude-code-style nesting or PascalCase) ---

@test "cursor set turn: writes a flat stop entry, no nested hooks[]" {
  bash "$SCRIPTS/delivery.sh" set turn cursor "$TEST_PROJECT"
  [ -f "$(hooks_file)" ]
  [ "$(hooks_count stop)" = "1" ]
  [[ "$(hooks_command stop 0)" == *"check-inbox.sh"* ]]
  local nested
  nested=$(sqlite_mem "SELECT json_extract(readfile('$(rf "$(hooks_file)")'), '\$.hooks.stop[0].hooks');")
  [ -z "$nested" ]
}

@test "cursor set turn: does not leak claude-code's PascalCase Stop key" {
  bash "$SCRIPTS/delivery.sh" set turn cursor "$TEST_PROJECT"
  local pascal
  pascal=$(sqlite_mem "SELECT json_extract(readfile('$(rf "$(hooks_file)")'), '\$.hooks.Stop');")
  [ -z "$pascal" ]
}

@test "cursor set monitor: writes sessionStart, sessionEnd, beforeSubmitPrompt, no stop" {
  bash "$SCRIPTS/delivery.sh" set monitor cursor "$TEST_PROJECT"
  [ "$(hooks_count sessionStart)" = "1" ]
  [ "$(hooks_count sessionEnd)" = "1" ]
  [ "$(hooks_count beforeSubmitPrompt)" = "1" ]
  [ "$(hooks_count stop)" = "0" ]
  [[ "$(hooks_command sessionStart 0)" == *"session-start.sh"* ]]
  [[ "$(hooks_command sessionEnd 0)" == *"session-end.sh"* ]]
  # beforeSubmitPrompt reruns session-start.sh: cursor-agent does not fire
  # sessionStart on --resume, so this is the only hook that still runs then.
  [[ "$(hooks_command beforeSubmitPrompt 0)" == *"session-start.sh"* ]]
}

@test "cursor set both: writes all four events" {
  bash "$SCRIPTS/delivery.sh" set both cursor "$TEST_PROJECT"
  [ "$(hooks_count sessionStart)" = "1" ]
  [ "$(hooks_count sessionEnd)" = "1" ]
  [ "$(hooks_count beforeSubmitPrompt)" = "1" ]
  [ "$(hooks_count stop)" = "1" ]
}

@test "cursor set off: removes all agmsg-owned events" {
  bash "$SCRIPTS/delivery.sh" set both cursor "$TEST_PROJECT"
  bash "$SCRIPTS/delivery.sh" set off cursor "$TEST_PROJECT"
  [ "$(hooks_count sessionStart)" = "0" ]
  [ "$(hooks_count sessionEnd)" = "0" ]
  [ "$(hooks_count beforeSubmitPrompt)" = "0" ]
  [ "$(hooks_count stop)" = "0" ]
}

@test "cursor: turn -> monitor swaps hooks cleanly" {
  bash "$SCRIPTS/delivery.sh" set turn cursor "$TEST_PROJECT"
  bash "$SCRIPTS/delivery.sh" set monitor cursor "$TEST_PROJECT"
  [ "$(hooks_count stop)" = "0" ]
  [ "$(hooks_count sessionStart)" = "1" ]
}

@test "cursor set turn: stamps version 1 when absent" {
  bash "$SCRIPTS/delivery.sh" set turn cursor "$TEST_PROJECT"
  local v
  v=$(sqlite_mem "SELECT json_extract(readfile('$(rf "$(hooks_file)")'), '\$.version');")
  [ "$v" = "1" ]
}

@test "cursor set turn: command survives a project path with a space and an apostrophe" {
  local sp="$TEST_PROJECT/Mobile Documents/o'brien proj"
  mkdir -p "$sp"
  run bash "$SCRIPTS/delivery.sh" set turn cursor "$sp"
  [ "$status" -eq 0 ]
  local cmd
  cmd="$(hooks_command stop 0 "$sp/.cursor/hooks.json")"
  eval "set -- $cmd"
  [ "$2" = "cursor" ]
  [ "$3" = "$sp" ]
}

# --- idempotency ---

@test "cursor set turn: idempotent across repeats" {
  bash "$SCRIPTS/delivery.sh" set turn cursor "$TEST_PROJECT"
  bash "$SCRIPTS/delivery.sh" set turn cursor "$TEST_PROJECT"
  bash "$SCRIPTS/delivery.sh" set turn cursor "$TEST_PROJECT"
  [ "$(hooks_count stop)" = "1" ]
}

@test "cursor set both: idempotent across repeats" {
  bash "$SCRIPTS/delivery.sh" set both cursor "$TEST_PROJECT"
  bash "$SCRIPTS/delivery.sh" set both cursor "$TEST_PROJECT"
  [ "$(hooks_count sessionStart)" = "1" ]
  [ "$(hooks_count sessionEnd)" = "1" ]
  [ "$(hooks_count beforeSubmitPrompt)" = "1" ]
  [ "$(hooks_count stop)" = "1" ]
}

# --- preserves a user-authored entry alongside agmsg's own ---

@test "cursor set turn: preserves a pre-existing user-authored stop entry" {
  mkdir -p "$TEST_PROJECT/.cursor"
  echo '{"version":1,"hooks":{"stop":[{"command":"echo user"}]}}' > "$(hooks_file)"
  bash "$SCRIPTS/delivery.sh" set turn cursor "$TEST_PROJECT"
  [ "$(hooks_count stop)" = "2" ]
  grep -q "echo user" "$(hooks_file)"
  grep -q "check-inbox.sh" "$(hooks_file)"
}

@test "cursor set off: drops only agmsg's stop entry, keeps the user's" {
  mkdir -p "$TEST_PROJECT/.cursor"
  echo '{"version":1,"hooks":{"stop":[{"command":"echo user"}]}}' > "$(hooks_file)"
  bash "$SCRIPTS/delivery.sh" set turn cursor "$TEST_PROJECT"
  bash "$SCRIPTS/delivery.sh" set off cursor "$TEST_PROJECT"
  [ "$(hooks_count stop)" = "1" ]
  grep -q "echo user" "$(hooks_file)"
  ! grep -q "check-inbox.sh" "$(hooks_file)"
}

# --- agmsg_delivery_status ---

@test "cursor delivery status: derives 'monitor'" {
  bash "$SCRIPTS/delivery.sh" set monitor cursor "$TEST_PROJECT" >/dev/null
  run bash "$SCRIPTS/delivery.sh" status cursor "$TEST_PROJECT"
  [[ "$output" =~ "mode: monitor" ]]
}

@test "cursor delivery status: derives 'turn'" {
  bash "$SCRIPTS/delivery.sh" set turn cursor "$TEST_PROJECT" >/dev/null
  run bash "$SCRIPTS/delivery.sh" status cursor "$TEST_PROJECT"
  [[ "$output" =~ "mode: turn" ]]
}

@test "cursor delivery status: derives 'both'" {
  bash "$SCRIPTS/delivery.sh" set both cursor "$TEST_PROJECT" >/dev/null
  run bash "$SCRIPTS/delivery.sh" status cursor "$TEST_PROJECT"
  [[ "$output" =~ "mode: both" ]]
}

@test "cursor delivery status: derives 'off' with no hooks file at all" {
  run bash "$SCRIPTS/delivery.sh" status cursor "$TEST_PROJECT"
  [[ "$output" =~ "mode: off" ]]
}

# --- migration off the pre-hooks.json .mdc rule file (#131) ---

@test "cursor migration: an agmsg-owned .mdc rule file is removed on set turn" {
  mkdir -p "$TEST_PROJECT/.cursor/rules"
  cat > "$(old_rule_file)" <<EOF
---
alwaysApply: true
---
# agmsg Integration Rule
- Command: '$SCRIPTS/check-inbox.sh' cursor '$TEST_PROJECT'
EOF
  bash "$SCRIPTS/delivery.sh" set turn cursor "$TEST_PROJECT"
  [ ! -f "$(old_rule_file)" ]
}

@test "cursor migration: an agmsg-owned .mdc rule file is removed on set off too" {
  mkdir -p "$TEST_PROJECT/.cursor/rules"
  cat > "$(old_rule_file)" <<EOF
---
alwaysApply: true
---
- Command: '$SCRIPTS/check-inbox.sh' cursor '$TEST_PROJECT'
EOF
  bash "$SCRIPTS/delivery.sh" set off cursor "$TEST_PROJECT"
  [ ! -f "$(old_rule_file)" ]
}

@test "cursor migration: a user-authored .mdc rule file is left alone" {
  mkdir -p "$TEST_PROJECT/.cursor/rules"
  cat > "$(old_rule_file)" <<'EOF'
---
alwaysApply: true
---
# my own rule, unrelated to agmsg
EOF
  bash "$SCRIPTS/delivery.sh" set turn cursor "$TEST_PROJECT"
  [ -f "$(old_rule_file)" ]
  grep -q "my own rule" "$(old_rule_file)"
}

# --- agmsg_delivery_preflight (no delivery.sh caller yet; sourced directly) ---

_cursor_preflight() {  # <mode> <path_dir>
  local mode="$1" pathdir="$2"
  mkdir -p "$pathdir"
  run env PATH="$pathdir" "$BASH_BIN" -c '
    . "$1/cursor/_delivery.sh"
    agmsg_delivery_preflight cursor "$2" "$3"
  ' _ "$TYPES" "$TEST_PROJECT" "$mode"
}

@test "cursor preflight: monitor fails when herdr is not on PATH" {
  _cursor_preflight monitor "$TEST_SKILL_DIR/emptybin"
  [ "$status" -ne 0 ]
  [[ "$output" == *"herdr"* ]]
}

@test "cursor preflight: monitor fails when HERDR_PANE_ID is unset even with herdr present" {
  local stubbin="$TEST_SKILL_DIR/stubbin-nopane"
  mkdir -p "$stubbin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$stubbin/herdr"
  chmod +x "$stubbin/herdr"
  run env -u HERDR_PANE_ID PATH="$stubbin" "$BASH_BIN" -c '
    . "$1/cursor/_delivery.sh"
    agmsg_delivery_preflight cursor "$2" monitor
  ' _ "$TYPES" "$TEST_PROJECT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"HERDR_PANE_ID"* ]]
}

@test "cursor preflight: monitor succeeds with herdr on PATH and HERDR_PANE_ID set" {
  local stubbin="$TEST_SKILL_DIR/stubbin-ok"
  mkdir -p "$stubbin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$stubbin/herdr"
  chmod +x "$stubbin/herdr"
  run env HERDR_PANE_ID=pane-1 PATH="$stubbin" "$BASH_BIN" -c '
    . "$1/cursor/_delivery.sh"
    agmsg_delivery_preflight cursor "$2" monitor
  ' _ "$TYPES" "$TEST_PROJECT"
  [ "$status" -eq 0 ]
}

@test "cursor preflight: both mode has the same herdr gate as monitor" {
  _cursor_preflight both "$TEST_SKILL_DIR/emptybin"
  [ "$status" -ne 0 ]
  [[ "$output" == *"herdr"* ]]
}

@test "cursor preflight: turn mode passes without herdr" {
  _cursor_preflight turn "$TEST_SKILL_DIR/emptybin"
  [ "$status" -eq 0 ]
}

@test "cursor preflight: off mode passes without herdr" {
  _cursor_preflight off "$TEST_SKILL_DIR/emptybin"
  [ "$status" -eq 0 ]
}

# --- 段9 codex finding F8: ownership matching must not be a bare-name match ---

@test "cursor: a user hook whose command merely mentions the skill name survives set/off (F8)" {
  mkdir -p "$TEST_PROJECT/.cursor"
  printf '{"version":1,"hooks":{"stop":[{"command":"/usr/local/bin/notify --tag agmsg-mention"}]}}' \
    > "$TEST_PROJECT/.cursor/hooks.json"

  bash "$SCRIPTS/delivery.sh" set turn cursor "$TEST_PROJECT"
  run cat "$TEST_PROJECT/.cursor/hooks.json"
  [[ "$output" == *"agmsg-mention"* ]]
  [[ "$output" == *"check-inbox.sh"* ]]

  bash "$SCRIPTS/delivery.sh" set off cursor "$TEST_PROJECT"
  run cat "$TEST_PROJECT/.cursor/hooks.json"
  [[ "$output" == *"agmsg-mention"* ]]
  [[ "$output" != *"check-inbox.sh"* ]]
}

@test "cursor: a user-authored .cursor/rules/agmsg.mdc that only mentions the name is kept (F8)" {
  mkdir -p "$TEST_PROJECT/.cursor/rules"
  printf -- '---\nalwaysApply: true\n---\n# my own notes about agmsg\n' \
    > "$TEST_PROJECT/.cursor/rules/agmsg.mdc"

  bash "$SCRIPTS/delivery.sh" set turn cursor "$TEST_PROJECT"
  [ -f "$TEST_PROJECT/.cursor/rules/agmsg.mdc" ]
  run cat "$TEST_PROJECT/.cursor/rules/agmsg.mdc"
  [[ "$output" == *"my own notes"* ]]
}

@test "cursor: the old agmsg-generated .mdc is retired on migration (F8)" {
  mkdir -p "$TEST_PROJECT/.cursor/rules"
  printf -- '---\nalwaysApply: true\n---\n# agmsg Integration Rule\n- Command: %s/scripts/check-inbox.sh cursor %s\n' \
    "$TEST_SKILL_DIR" "$TEST_PROJECT" > "$TEST_PROJECT/.cursor/rules/agmsg.mdc"

  bash "$SCRIPTS/delivery.sh" set turn cursor "$TEST_PROJECT"
  [ ! -f "$TEST_PROJECT/.cursor/rules/agmsg.mdc" ]
}
