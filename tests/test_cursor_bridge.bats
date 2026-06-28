#!/usr/bin/env bats

load test_helper

# cursor-bridge.sh is driven against a STUB cursor-agent (AGMSG_CURSOR_AGENT_CMD)
# so these tests never touch the network. The stub answers `create-chat` with a
# fixed uuid and, in `-p` mode, echoes a result JSON whose session_id is whatever
# --resume id it was handed (so it matches the bridge's --chat-id). FAKE_CURSOR_MODE
# forces the failure shapes; FAKE_CURSOR_LOG records argv for the flag-set guard.

setup() {
  setup_test_env
  export PROJ="$TEST_SKILL_DIR/proj"
  mkdir -p "$PROJ" "$TEST_SKILL_DIR/run"

  # cursor-agent stub
  export FAKE_CURSOR_LOG="$TEST_SKILL_DIR/fake-cursor.log"
  : > "$FAKE_CURSOR_LOG"
  # Capture sinks for the read-only / add-dir assertions (set per-test as needed).
  export FAKE_CURSOR_PWD="$TEST_SKILL_DIR/fake-cursor.pwd"
  export FAKE_CURSOR_CLIJSON="$TEST_SKILL_DIR/fake-cursor.clijson"
  export FAKE_CURSOR_PROMPT="$TEST_SKILL_DIR/fake-cursor.prompt"
  STUB="$TEST_SKILL_DIR/fake-cursor.sh"
  cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
echo "ARGS: $*" >> "${FAKE_CURSOR_LOG:-/dev/null}"
if [ "$1" = "create-chat" ]; then
  echo "11111111-2222-3333-4444-555555555555"
  exit 0
fi
# -p turn: record cwd + any generated .cursor/cli.json + the prompt (stdin) so the
# read-only/add-dir tests can inspect them (the bridge cleans the scratch cwd on exit).
[ -n "${FAKE_CURSOR_PWD:-}" ] && printf '%s\n' "$PWD" > "$FAKE_CURSOR_PWD"
[ -n "${FAKE_CURSOR_CLIJSON:-}" ] && [ -f "$PWD/.cursor/cli.json" ] && cp "$PWD/.cursor/cli.json" "$FAKE_CURSOR_CLIJSON"
[ -n "${FAKE_CURSOR_PROMPT:-}" ] && cat > "$FAKE_CURSOR_PROMPT" 2>/dev/null || true
resume=""; prev=""
for a in "$@"; do [ "$prev" = "--resume" ] && resume="$a"; prev="$a"; done
result="STUB_REPLY"; iserr="false"
case "${FAKE_CURSOR_MODE:-ok}" in
  error)       iserr="true" ;;
  invalid)     echo "this is not json"; exit 0 ;;
  mismatch)    resume="deadbeef-0000-0000-0000-000000000000" ;;
  empty)       result="" ;;
  hang)        sleep 30 ;;   # outlive the test's short TURN_TIMEOUT, then get killed
  exitnonzero) printf '{"is_error":false,"result":"LEAK","session_id":"%s"}\n' "$resume"; exit 3 ;;
  signaldeath) printf '{"is_error":false,"result":"GHOST","session_id":"%s"}\n' "$resume"; kill -KILL $$ ;;
esac
printf '{"is_error":%s,"result":"%s","session_id":"%s"}\n' "$iserr" "$result" "$resume"
EOF
  chmod +x "$STUB"
  export AGMSG_CURSOR_AGENT_CMD="$STUB"

  # cur = the headless reviewer identity; alice/bob = senders.
  bash "$SCRIPTS/join.sh" team cur cursor "$PROJ" >/dev/null
  bash "$SCRIPTS/join.sh" team alice claude-code "$PROJ" >/dev/null
  bash "$SCRIPTS/join.sh" team bob claude-code "$PROJ" >/dev/null
}

teardown() {
  teardown_test_env
}

bridge() {  # run the bridge for cur, one drain
  run bash "$TYPES/cursor/cursor-bridge.sh" \
    --once --project "$PROJ" --team team --name cur --chat-id testchat-1234-1234-1234-123456789012
}

@test "cursor-bridge: help exits successfully" {
  run bash "$TYPES/cursor/cursor-bridge.sh" --help
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Headless read-only Cursor reviewer" ]]
}

@test "cursor-bridge: requires --project/--team/--name/--chat-id" {
  run bash "$TYPES/cursor/cursor-bridge.sh" --team team --name cur --chat-id x
  [ "$status" -ne 0 ]
  [[ "$output" =~ "--project is required" ]]
}

@test "cursor-bridge: delivers a reply and marks the message read" {
  bash "$SCRIPTS/send.sh" team alice cur "review this please" >/dev/null
  bridge
  [ "$status" -eq 0 ]
  # alice received cur's reply
  run bash "$SCRIPTS/inbox.sh" team alice --format ids
  [[ "$output" == *"STUB_REPLY"* ]]
  # cur's inbox is now drained (message marked read on success)
  run bash "$SCRIPTS/inbox.sh" team cur --format ids
  [ -z "$output" ]
}

@test "cursor-bridge: runs cursor read-only (--trust, never --force)" {
  bash "$SCRIPTS/send.sh" team alice cur "hi" >/dev/null
  bridge
  grep -q -- "--trust" "$FAKE_CURSOR_LOG"
  ! grep -q -- "--force" "$FAKE_CURSOR_LOG"
  ! grep -q -- "--yolo" "$FAKE_CURSOR_LOG"
}

@test "cursor-bridge: is_error result leaves the message unread, no reply" {
  export FAKE_CURSOR_MODE=error
  bash "$SCRIPTS/send.sh" team alice cur "boom" >/dev/null
  bridge
  # still unread for cur
  run bash "$SCRIPTS/inbox.sh" team cur --format ids
  [[ "$output" == *"boom"* ]]
  # alice got nothing
  run bash "$SCRIPTS/inbox.sh" team alice --format ids
  [ -z "$output" ]
}

@test "cursor-bridge: invalid JSON leaves the message unread" {
  export FAKE_CURSOR_MODE=invalid
  bash "$SCRIPTS/send.sh" team alice cur "x" >/dev/null
  bridge
  run bash "$SCRIPTS/inbox.sh" team cur --format ids
  [ -n "$output" ]
  run bash "$SCRIPTS/inbox.sh" team alice --format ids
  [ -z "$output" ]
}

@test "cursor-bridge: session_id mismatch leaves the message unread" {
  export FAKE_CURSOR_MODE=mismatch
  bash "$SCRIPTS/send.sh" team alice cur "x" >/dev/null
  bridge
  run bash "$SCRIPTS/inbox.sh" team cur --format ids
  [ -n "$output" ]
}

@test "cursor-bridge: empty result leaves the message unread" {
  export FAKE_CURSOR_MODE=empty
  bash "$SCRIPTS/send.sh" team alice cur "x" >/dev/null
  bridge
  run bash "$SCRIPTS/inbox.sh" team cur --format ids
  [ -n "$output" ]
}

@test "cursor-bridge: replies to each sender separately (no cross-talk)" {
  bash "$SCRIPTS/send.sh" team alice cur "from alice" >/dev/null
  bash "$SCRIPTS/send.sh" team bob cur "from bob" >/dev/null
  bridge
  [ "$status" -eq 0 ]
  run bash "$SCRIPTS/inbox.sh" team alice --format ids
  [[ "$output" == *"STUB_REPLY"* ]]
  run bash "$SCRIPTS/inbox.sh" team bob --format ids
  [[ "$output" == *"STUB_REPLY"* ]]
  # two separate cursor turns ran (one per sender)
  run grep -c -- "--resume" "$FAKE_CURSOR_LOG"
  [ "$output" -eq 2 ]
}

@test "cursor-bridge: refuses a second instance for the same identity" {
  sleep 30 &
  local livepid=$!
  echo "$livepid" > "$TEST_SKILL_DIR/run/cursor-bridge.team.cur.pid"
  run bash "$TYPES/cursor/cursor-bridge.sh" \
    --once --project "$PROJ" --team team --name cur --chat-id x-1-2-3-456789012345
  kill "$livepid" 2>/dev/null || true
  [ "$status" -eq 1 ]
  [[ "$output" =~ "already running" ]]
}

@test "cursor-bridge: a hung turn is timed out and the message stays unread" {
  export FAKE_CURSOR_MODE=hang
  export AGMSG_CURSOR_BRIDGE_TURN_TIMEOUT=2
  bash "$SCRIPTS/send.sh" team alice cur "will hang" >/dev/null
  bridge
  # turn killed by the watchdog → no reply, message retained
  run bash "$SCRIPTS/inbox.sh" team cur --format ids
  [ -n "$output" ]
  run bash "$SCRIPTS/inbox.sh" team alice --format ids
  [ -z "$output" ]
}

@test "cursor-bridge: a non-zero cursor exit is a failure even with valid JSON" {
  export FAKE_CURSOR_MODE=exitnonzero
  bash "$SCRIPTS/send.sh" team alice cur "leaky" >/dev/null
  bridge
  # cursor printed valid JSON but exited 3 → treat as failure, do NOT reply/ack
  run bash "$SCRIPTS/inbox.sh" team alice --format ids
  [ -z "$output" ]
  [[ "$output" != *"LEAK"* ]]
  run bash "$SCRIPTS/inbox.sh" team cur --format ids
  [ -n "$output" ]
}

@test "cursor-bridge: a signal-killed cursor is a failure even with valid JSON" {
  export FAKE_CURSOR_MODE=signaldeath
  bash "$SCRIPTS/send.sh" team alice cur "ghost" >/dev/null
  bridge
  # cursor printed valid JSON then died by SIGKILL → 128+signal, treated as failure
  run bash "$SCRIPTS/inbox.sh" team alice --format ids
  [ -z "$output" ]
  [[ "$output" != *"GHOST"* ]]
  run bash "$SCRIPTS/inbox.sh" team cur --format ids
  [ -n "$output" ]
}

# --- read-only enforcement + add-dir advertising ------------------------------

bridge_ro() {  # run the bridge for cur, READ-ONLY, one drain; $1 = optional add-dirs-file
  local extra=()
  [ -n "${1:-}" ] && extra=(--add-dirs-file "$1")
  run bash "$TYPES/cursor/cursor-bridge.sh" \
    --once --readonly --project "$PROJ" --team team --name cur \
    --chat-id testchat-1234-1234-1234-123456789012 \
    ${extra[@]+"${extra[@]}"}
}

@test "cursor-bridge: --readonly generates a cli.json denying Write and Shell" {
  bash "$SCRIPTS/send.sh" team alice cur "review" >/dev/null
  bridge_ro
  [ "$status" -eq 0 ]
  [ -f "$FAKE_CURSOR_CLIJSON" ]
  run cat "$FAKE_CURSOR_CLIJSON"
  [[ "$output" == *'"permissions"'* ]]
  [[ "$output" == *'"deny"'* ]]
  [[ "$output" == *'"Write(**)"'* ]]
  [[ "$output" == *'"Shell(**)"'* ]]
  # at least one credential Read() deny entry is present
  [[ "$output" == *'"Read('* ]]
}

@test "cursor-bridge: --readonly runs from a scratch cwd with --workspace=project" {
  bash "$SCRIPTS/send.sh" team alice cur "review" >/dev/null
  bridge_ro
  [ "$status" -eq 0 ]
  grep -q -- "--workspace $PROJ" "$FAKE_CURSOR_LOG"
  # cwd was the per-identity scratch cfg dir, NOT the project
  run cat "$FAKE_CURSOR_PWD"
  [[ "$output" == *"cursor-cfg.team.cur"* ]]
  [ "$output" != "$PROJ" ]
}

@test "cursor-bridge: --readonly never passes --force/--yolo" {
  bash "$SCRIPTS/send.sh" team alice cur "review" >/dev/null
  bridge_ro
  grep -q -- "--trust" "$FAKE_CURSOR_LOG"
  ! grep -q -- "--force" "$FAKE_CURSOR_LOG"
  ! grep -q -- "--yolo" "$FAKE_CURSOR_LOG"
}

@test "cursor-bridge: without --readonly there is no --workspace (back-compat)" {
  bash "$SCRIPTS/send.sh" team alice cur "review" >/dev/null
  bridge
  [ "$status" -eq 0 ]
  ! grep -q -- "--workspace" "$FAKE_CURSOR_LOG"
  # reply still delivered the legacy way
  run bash "$SCRIPTS/inbox.sh" team alice --format ids
  [[ "$output" == *"STUB_REPLY"* ]]
}

@test "cursor-bridge: --readonly denylist excludes project-internal credential paths" {
  local hm="$TEST_SKILL_DIR/home"
  mkdir -p "$hm/.ssh" "$hm/.config/cursor"
  local proj="$hm/.config"          # project CONTAINS .config/cursor
  bash "$SCRIPTS/send.sh" team alice cur "review" >/dev/null
  run env HOME="$hm" bash "$TYPES/cursor/cursor-bridge.sh" \
    --once --readonly --project "$proj" --team team --name cur \
    --chat-id testchat-1234-1234-1234-123456789012
  [ "$status" -eq 0 ]
  run cat "$FAKE_CURSOR_CLIJSON"
  # ~/.ssh is OUTSIDE the project → denied
  [[ "$output" == *"Read($hm/.ssh/**)"* ]]
  # ~/.config/cursor is INSIDE the project → must NOT be denied (would blind the reviewer)
  [[ "$output" != *"Read($hm/.config/cursor/**)"* ]]
}

@test "cursor-bridge: rejects a team/name with path-traversal characters (fail closed)" {
  # A name with '/' must never compose the rm -rf'd scratch CFGDIR outside run/.
  run bash "$TYPES/cursor/cursor-bridge.sh" \
    --once --readonly --project "$PROJ" --team team --name "../evil" \
    --chat-id testchat-1234-1234-1234-123456789012
  [ "$status" -ne 0 ]
  [[ "$output" == *"path-safe segment"* ]]
  # nothing got created outside run/ for the crafted name
  [ ! -e "$TEST_SKILL_DIR/cursor-cfg.team.../evil" ]
}

@test "cursor-bridge: --readonly warns when a credential path is inside the workspace" {
  local hm="$TEST_SKILL_DIR/home2"
  mkdir -p "$hm/.ssh" "$hm/.config/cursor"
  # project = $HOME → ALL credential denies are workspace-internal and dropped
  bash "$SCRIPTS/send.sh" team alice cur "review" >/dev/null
  run env HOME="$hm" bash "$TYPES/cursor/cursor-bridge.sh" \
    --once --readonly --project "$hm" --team team --name cur \
    --chat-id testchat-1234-1234-1234-123456789012
  [ "$status" -eq 0 ]
  # the reduced denylist is surfaced, not silent
  [[ "$output" == *"WARNING"* ]]
  [[ "$output" == *"inside the workspace"* ]]
}

@test "cursor-bridge: --add-dirs-file advertises the dirs in the prompt" {
  local adf="$TEST_SKILL_DIR/adddirs.txt"
  printf '%s\n' "/tmp/extra-one" "/tmp/extra-two" > "$adf"
  bash "$SCRIPTS/send.sh" team alice cur "review" >/dev/null
  bridge_ro "$adf"
  [ "$status" -eq 0 ]
  run cat "$FAKE_CURSOR_PROMPT"
  [[ "$output" == *"/tmp/extra-one"* ]]
  [[ "$output" == *"/tmp/extra-two"* ]]
}
