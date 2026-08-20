#!/usr/bin/env bats

load test_helper

# cursor-bridge.sh is driven against a STUB cursor-agent (AGMSG_CURSOR_AGENT_CMD)
# so these tests never touch the network. The stub answers `create-chat` with a
# fixed uuid and, in `-p` mode, emits the observed stream-json shape: one init,
# intermediate user/thinking/assistant events, then one result whose session_id
# is the --resume id. FAKE_CURSOR_MODE forces failure shapes;
# FAKE_CURSOR_LOG records argv for the flag-set guard.

setup() {
  setup_test_env
  export PROJ="$TEST_SKILL_DIR/proj"
  mkdir -p "$PROJ" "$TEST_SKILL_DIR/run"
  unset AGMSG_CURSOR_BRIDGE_FALLBACK_MODEL
  unset FAKE_CURSOR_MODEL_JSON

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
resume=""; model=""; prev=""
for a in "$@"; do
  [ "$prev" = "--resume" ] && resume="$a"
  [ "$prev" = "--model" ] && model="$a"
  prev="$a"
done
result="STUB_REPLY"; iserr="false"; result_subtype="success"
case "$model" in
  grok-4.6) default_model_json='"Cursor Grok 4.6 High Fast"' ;;
  composer-2.5) default_model_json='"Cursor Composer 2.5"' ;;
  *) default_model_json='"Cursor Stub Model"' ;;
esac
model_json="${FAKE_CURSOR_MODEL_JSON:-$default_model_json}"

emit_init() {
  if [ "${1:-}" = no-model ]; then
    printf '{"type":"system","subtype":"init","apiKeySource":"login","cwd":"/tmp","session_id":"%s","permissionMode":"default"}\n' "$resume"
  else
    printf '{"type":"system","subtype":"init","apiKeySource":"login","cwd":"/tmp","session_id":"%s","model":%s,"permissionMode":"default"}\n' "$resume" "$model_json"
  fi
}
emit_middle() {
  printf '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"secret prompt"}]},"session_id":"%s"}\n' "$resume"
  printf '{"type":"thinking","subtype":"delta","text":"private thought","session_id":"%s"}\n' "$resume"
  printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"%s"}]},"session_id":"%s"}\n' "$result" "$resume"
}
emit_result() {
  local newline="${1:-yes}"
  local fmt='{"type":"result","subtype":"%s","duration_ms":4111,"duration_api_ms":4111,"is_error":%s,"result":"%s","session_id":"%s","request_id":"req-1","usage":{"inputTokens":13666,"outputTokens":29,"cacheReadTokens":4992,"cacheWriteTokens":0}}'
  if [ "$newline" = yes ]; then fmt="$fmt\n"; fi
  printf "$fmt" "$result_subtype" "$iserr" "$result" "$resume"
}

case "${FAKE_CURSOR_MODE:-ok}" in
  error)       iserr="true" ;;
  iserrorzero) iserr="0" ;;
  invalid|nonjson) echo "this is not json"; exit 0 ;;
  mismatch)    resume="deadbeef-0000-0000-0000-000000000000" ;;
  empty)       result="" ;;
  hang)        sleep 30 ;;   # outlive the test's short TURN_TIMEOUT, then get killed
  subtypeerror) result_subtype="error" ;;
  exitnonzero) result="LEAK"; emit_init; emit_middle; emit_result; exit 3 ;;
  signaldeath) result="GHOST"; emit_init; emit_middle; emit_result; kill -KILL $$ ;;
  nonretriable) echo "NonRetriableError: Agent Looping Detected" >&2; exit 1 ;;
  actionrequired) echo "ActionRequiredError: You're out of usage. Switch to auto to continue." >&2; exit 1 ;;
  transientfail) echo "some transient network hiccup" >&2; exit 1 ;;
  # terminal on the default model, healthy on a forced --model (per-model outage)
  fallbackok)  if [ -n "$model" ]; then result="FALLBACK_REPLY"; else echo "NonRetriableError: Agent Looping Detected" >&2; exit 1; fi ;;
  pinnedfallbackok) if [ "$model" = composer-2.5 ]; then result="FALLBACK_REPLY"; else echo "NonRetriableError: Agent Looping Detected" >&2; exit 1; fi ;;
  resultmissing) emit_init; emit_middle; exit 0 ;;
  resulttwice) emit_init; emit_middle; emit_result; emit_result; exit 0 ;;
  resultnotlast) emit_init; emit_result; emit_middle; exit 0 ;;
  initmissing) emit_middle; emit_result; exit 0 ;;
  inittwice) emit_init; emit_init; emit_middle; emit_result; exit 0 ;;
  initafterresult) emit_result; emit_init; exit 0 ;;
  warning) echo "warning: update available"; emit_init; emit_middle; emit_result; exit 0 ;;
  scalar) echo '42'; emit_init; emit_middle; emit_result; exit 0 ;;
  array) echo '[]'; emit_init; emit_middle; emit_result; exit 0 ;;
  truncated) emit_init; emit_middle; printf '{"type":"result","subtype":"success"'; exit 0 ;;
  nonewline) emit_init; emit_middle; emit_result no; exit 0 ;;
  blanklines) printf '\n'; emit_init; printf '\n'; emit_middle; printf '\n'; emit_result; printf '\n'; exit 0 ;;
  initnomodel) emit_init no-model; emit_middle; emit_result; exit 0 ;;
  longstream)
    emit_init
    printf '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"secret prompt"}]},"session_id":"%s"}\n' "$resume"
    i=0
    while [ "$i" -lt 500 ]; do
      printf '{"type":"thinking","subtype":"delta","text":"private thought %s","session_id":"%s"}\n' "$i" "$resume"
      i=$((i + 1))
    done
    printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"%s"}]},"session_id":"%s"}\n' "$result" "$resume"
    emit_result
    exit 0 ;;
esac
emit_init
emit_middle
emit_result
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

bridge() {  # run the bridge for cur, one drain; extra bridge argv are accepted
  run bash "$TYPES/cursor/cursor-bridge.sh" \
    --once --project "$PROJ" --team team --name cur --chat-id testchat-1234-1234-1234-123456789012 "$@"
}

# Simulate a persistent send-path outage (e.g. a sandbox EPERM): the bridge calls
# $SCRIPTS_DIR/send.sh — this test's isolated copy — so swap it for an
# always-failing stub, and restore the real one to model the path recovering.
break_send() {
  cp "$SCRIPTS/send.sh" "$SCRIPTS/send.sh.orig"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$SCRIPTS/send.sh"
  chmod +x "$SCRIPTS/send.sh"
}
restore_send() {
  mv "$SCRIPTS/send.sh.orig" "$SCRIPTS/send.sh"
  chmod +x "$SCRIPTS/send.sh"
}

turns_run() {  # number of -p cursor turns the stub has recorded so far
  grep -c -- "--resume" "$FAKE_CURSOR_LOG" || true
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

@test "cursor-bridge: rejects malformed direct model and fallback argv" {
  local flag value
  for flag in --model --fallback-model; do
    for value in "" " " "-option" $'bad\nvalue' $'bad\x1bvalue'; do
      run bash "$TYPES/cursor/cursor-bridge.sh" \
        --once --project "$PROJ" --team team --name cur \
        --chat-id testchat-1234-1234-1234-123456789012 \
        "$flag" "$value"
      [ "$status" -ne 0 ]
    done
  done
  [ "$(turns_run)" -eq 0 ]
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
  # a normal (non-fallback) turn never forces --model (global config inheritance)
  ! grep -q -- "--model" "$FAKE_CURSOR_LOG"
  grep -q -- "--output-format stream-json" "$FAKE_CURSOR_LOG"
}

@test "cursor-bridge: a pinned model is passed on every normal turn" {
  bash "$SCRIPTS/send.sh" team alice cur "one" >/dev/null
  bash "$SCRIPTS/send.sh" team bob cur "two" >/dev/null
  bridge --model grok-4.6
  [ "$status" -eq 0 ]
  [ "$(grep -c -- "--model grok-4.6" "$FAKE_CURSOR_LOG")" -eq 2 ]
  ! grep -q -- "--model composer-2.5" "$FAKE_CURSOR_LOG"
}

@test "cursor-bridge: explicit fallback succeeds with a pin and exact pinned label" {
  export FAKE_CURSOR_MODE=pinnedfallbackok
  bash "$SCRIPTS/send.sh" team alice cur "recover" >/dev/null
  bridge --model grok-4.6 --model-label "Cursor Grok 4.6 High Fast" \
    --fallback-model composer-2.5
  [ "$status" -eq 0 ]
  [ "$(turns_run)" -eq 2 ]
  sed -n '1p' "$FAKE_CURSOR_LOG" | grep -q -- "--model grok-4.6"
  sed -n '2p' "$FAKE_CURSOR_LOG" | grep -q -- "--model composer-2.5"
  run bash "$SCRIPTS/inbox.sh" team alice --format ids
  [[ "$output" == *"FALLBACK_REPLY"* ]]
  grep -q -- "requested='composer-2.5'.*fallback=true" "$TEST_SKILL_DIR/run/cursor-bridge.team.cur.log"
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

@test "cursor-bridge: legacy integer is_error=0 remains accepted" {
  export FAKE_CURSOR_MODE=iserrorzero
  bash "$SCRIPTS/send.sh" team alice cur "legacy zero" >/dev/null
  bridge
  [ "$status" -eq 0 ]
  run bash "$SCRIPTS/inbox.sh" team alice --format ids
  [[ "$output" == *"STUB_REPLY"* ]]
  run bash "$SCRIPTS/inbox.sh" team cur --format ids
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

@test "cursor-bridge: malformed stream-json structures all fail closed" {
  export AGMSG_CURSOR_BRIDGE_MAX_CONSEC_FAILURES=100
  export AGMSG_CURSOR_BRIDGE_FALLBACK_MODEL=""
  bash "$SCRIPTS/send.sh" team alice cur "structural-contract" >/dev/null
  local mode
  for mode in resultmissing resulttwice resultnotlast initmissing inittwice \
              initafterresult nonjson warning scalar array truncated; do
    export FAKE_CURSOR_MODE="$mode"
    bridge
    [ "$status" -eq 0 ]
    run bash "$SCRIPTS/inbox.sh" team cur --format ids
    [[ "$output" == *"structural-contract"* ]]
    run bash "$SCRIPTS/inbox.sh" team alice --format ids
    [ -z "$output" ]
  done
}

@test "cursor-bridge: hundreds of thinking delta lines parse in one turn" {
  export FAKE_CURSOR_MODE=longstream
  bash "$SCRIPTS/send.sh" team alice cur "large stream" >/dev/null
  bridge
  [ "$status" -eq 0 ]
  run bash "$SCRIPTS/inbox.sh" team alice --format ids
  [[ "$output" == *"STUB_REPLY"* ]]
  run bash "$SCRIPTS/inbox.sh" team cur --format ids
  [ -z "$output" ]
}

@test "cursor-bridge: subtype=error leaves the message unread" {
  export FAKE_CURSOR_MODE=subtypeerror
  bash "$SCRIPTS/send.sh" team alice cur "bad subtype" >/dev/null
  bridge
  run bash "$SCRIPTS/inbox.sh" team cur --format ids
  [[ "$output" == *"bad subtype"* ]]
}

@test "cursor-bridge: a complete final JSON event needs no trailing newline" {
  export FAKE_CURSOR_MODE=nonewline
  bash "$SCRIPTS/send.sh" team alice cur "no newline" >/dev/null
  bridge
  [ "$status" -eq 0 ]
  run bash "$SCRIPTS/inbox.sh" team alice --format ids
  [[ "$output" == *"STUB_REPLY"* ]]
  run bash "$SCRIPTS/inbox.sh" team cur --format ids
  [ -z "$output" ]
}

@test "cursor-bridge: empty JSONL lines are ignored" {
  export FAKE_CURSOR_MODE=blanklines
  bash "$SCRIPTS/send.sh" team alice cur "blank lines" >/dev/null
  bridge
  [ "$status" -eq 0 ]
  run bash "$SCRIPTS/inbox.sh" team alice --format ids
  [[ "$output" == *"STUB_REPLY"* ]]
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
  [ "$status" -ne 0 ]
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

# --- dead-letter: terminal errors, fallback-model retry, failure ceiling -----
# The default fallback model (composer-2.5) is active in these tests unless a
# test exports AGMSG_CURSOR_BRIDGE_FALLBACK_MODEL= (empty = disabled), so a
# terminal failure first retries once with --model before dead-lettering.

@test "cursor-bridge: a transient (non-terminal) failure still leaves the message unread" {
  export FAKE_CURSOR_MODE=transientfail
  bash "$SCRIPTS/send.sh" team alice cur "boom" >/dev/null
  bridge
  [ "$status" -eq 0 ]
  # no bridge-error notice — this is an ordinary retry-later failure
  run bash "$SCRIPTS/inbox.sh" team alice --format ids
  [ -z "$output" ]
  run bash "$SCRIPTS/inbox.sh" team cur --format ids
  [[ "$output" == *"boom"* ]]
}

@test "cursor-bridge: NonRetriableError dead-letters when the fallback also fails" {
  export FAKE_CURSOR_MODE=nonretriable    # fails on EVERY model, fallback included
  bash "$SCRIPTS/send.sh" team alice cur "boom" >/dev/null
  bridge
  [ "$status" -eq 0 ]
  # the fallback retry was attempted (--model on the second call) before dead-letter
  grep -q -- "--model composer-2.5" "$FAKE_CURSOR_LOG"
  # alice got a [bridge-error] notice quoting the terminal error line
  run bash "$SCRIPTS/inbox.sh" team alice --format ids
  [[ "$output" == *"[bridge-error]"* ]]
  [[ "$output" == *"NonRetriableError: Agent Looping Detected"* ]]
  # cur's inbox is drained (dead-lettered ids are marked read, like a success)
  run bash "$SCRIPTS/inbox.sh" team cur --format ids
  [ -z "$output" ]
  # a second drain runs no further cursor turn for this (already-read) message
  local before after
  before="$(grep -c -- "--resume" "$FAKE_CURSOR_LOG")"
  bridge
  after="$(grep -c -- "--resume" "$FAKE_CURSOR_LOG")"
  [ "$before" -eq "$after" ]
}

@test "cursor-bridge: ActionRequiredError dead-letters when the fallback also fails" {
  export FAKE_CURSOR_MODE=actionrequired
  bash "$SCRIPTS/send.sh" team alice cur "boom" >/dev/null
  bridge
  [ "$status" -eq 0 ]
  run bash "$SCRIPTS/inbox.sh" team alice --format ids
  [[ "$output" == *"[bridge-error]"* ]]
  [[ "$output" == *"ActionRequiredError:"* ]]
  run bash "$SCRIPTS/inbox.sh" team cur --format ids
  [ -z "$output" ]
}

@test "cursor-bridge: a terminal error salvaged by the fallback model replies normally" {
  export FAKE_CURSOR_MODE=fallbackok   # terminal without --model, healthy with it
  bash "$SCRIPTS/send.sh" team alice cur "boom" >/dev/null
  bridge
  [ "$status" -eq 0 ]
  [[ "$output" == *"fallback model used (composer-2.5)"* ]]
  # alice got the REAL reply from the fallback turn, not a bridge-error notice
  run bash "$SCRIPTS/inbox.sh" team alice --format ids
  [[ "$output" == *"FALLBACK_REPLY"* ]]
  [[ "$output" != *"[bridge-error]"* ]]
  # ids were marked read via the normal success path
  run bash "$SCRIPTS/inbox.sh" team cur --format ids
  [ -z "$output" ]
}

@test "cursor-bridge: an empty fallback-model env dead-letters without a retry" {
  export FAKE_CURSOR_MODE=nonretriable
  export AGMSG_CURSOR_BRIDGE_FALLBACK_MODEL=""
  bash "$SCRIPTS/send.sh" team alice cur "boom" >/dev/null
  bridge
  [ "$status" -eq 0 ]
  # no fallback attempt at all — dead-letter fires on the first terminal failure
  ! grep -q -- "--model" "$FAKE_CURSOR_LOG"
  run bash "$SCRIPTS/inbox.sh" team alice --format ids
  [[ "$output" == *"[bridge-error]"* ]]
  run bash "$SCRIPTS/inbox.sh" team cur --format ids
  [ -z "$output" ]
}

@test "cursor-bridge: --no-fallback overrides explicit and environment fallback models" {
  export FAKE_CURSOR_MODE=nonretriable
  export AGMSG_CURSOR_BRIDGE_FALLBACK_MODEL=env-model
  bash "$SCRIPTS/send.sh" team alice cur "boom" >/dev/null
  bridge --fallback-model configured-model --no-fallback
  [ "$status" -eq 0 ]
  [ "$(turns_run)" -eq 1 ]
  ! grep -q -- "--model configured-model" "$FAKE_CURSOR_LOG"
  ! grep -q -- "--model env-model" "$FAKE_CURSOR_LOG"
}

@test "cursor-bridge: explicit fallback model overrides a non-empty environment fallback" {
  export FAKE_CURSOR_MODE=nonretriable
  export AGMSG_CURSOR_BRIDGE_FALLBACK_MODEL=env-model
  bash "$SCRIPTS/send.sh" team alice cur "boom" >/dev/null
  bridge --fallback-model configured-model
  [ "$status" -eq 0 ]
  grep -q -- "--model configured-model" "$FAKE_CURSOR_LOG"
  ! grep -q -- "--model env-model" "$FAKE_CURSOR_LOG"
}

@test "cursor-bridge: a pinned worker defaults fallback off" {
  export FAKE_CURSOR_MODE=nonretriable
  bash "$SCRIPTS/send.sh" team alice cur "pinned terminal" >/dev/null
  bridge --model grok-4.6
  [ "$status" -eq 0 ]
  [ "$(turns_run)" -eq 1 ]
  run bash "$SCRIPTS/inbox.sh" team alice --format ids
  [[ "$output" == *"[bridge-error]"* ]]
}

@test "cursor-bridge: pinned transient failures retry unread until the existing ceiling" {
  export FAKE_CURSOR_MODE=transientfail
  export AGMSG_CURSOR_BRIDGE_MAX_CONSEC_FAILURES=2
  bash "$SCRIPTS/send.sh" team alice cur "pinned transient" >/dev/null
  bridge --model grok-4.6
  run bash "$SCRIPTS/inbox.sh" team cur --format ids
  [[ "$output" == *"pinned transient"* ]]
  bridge --model grok-4.6
  [ "$(turns_run)" -eq 2 ]
  ! grep -q -- "--model composer-2.5" "$FAKE_CURSOR_LOG"
  run bash "$SCRIPTS/inbox.sh" team alice --format ids
  [[ "$output" == *"2 consecutive failures"* ]]
}

# --- effective-model audit and exact display-label verification --------------

@test "cursor-bridge: configured model label matches exactly" {
  bash "$SCRIPTS/send.sh" team alice cur "verify" >/dev/null
  bridge --model grok-4.6 --model-label "Cursor Grok 4.6 High Fast"
  [ "$status" -eq 0 ]
  run bash "$SCRIPTS/inbox.sh" team alice --format ids
  [[ "$output" == *"STUB_REPLY"* ]]
  run cat "$TEST_SKILL_DIR/run/cursor-bridge.team.cur.log"
  [[ "$output" == *"requested='grok-4.6'"* ]]
  [[ "$output" == *"reported='Cursor Grok 4.6 High Fast'"* ]]
  [[ "$output" == *"fallback=false"* ]]
}

@test "cursor-bridge: model label mismatch immediately dead-letters without replying or retrying" {
  bash "$SCRIPTS/send.sh" team alice cur "verify" >/dev/null
  bridge --model grok-4.6 --model-label "Cursor Grok 4.60" --fallback-model composer-2.5
  [ "$status" -eq 0 ]
  [ "$(turns_run)" -eq 1 ]
  run bash "$SCRIPTS/inbox.sh" team alice --format ids
  [[ "$output" == *"[bridge-error]"* ]]
  [[ "$output" == *"model label mismatch"* ]]
  [[ "$output" != *"STUB_REPLY"* ]]
  run bash "$SCRIPTS/inbox.sh" team cur --format ids
  [ -z "$output" ]
  bridge --model grok-4.6 --model-label "Cursor Grok 4.60" --fallback-model composer-2.5
  [ "$(turns_run)" -eq 1 ]
}

@test "cursor-bridge: pinned label-mismatch dead-letter spools only the notice when send fails" {
  bash "$SCRIPTS/send.sh" team alice cur "verify with broken send" >/dev/null
  break_send
  bridge --model grok-4.6 --model-label "Wrong Label"
  [ "$status" -eq 0 ]
  [ "$(turns_run)" -eq 1 ]
  bridge --model grok-4.6 --model-label "Wrong Label"
  [ "$(turns_run)" -eq 1 ]
  restore_send
  bridge --model grok-4.6 --model-label "Wrong Label"
  [ "$(turns_run)" -eq 1 ]
  run bash "$SCRIPTS/inbox.sh" team alice --format ids
  [[ "$output" == *"[bridge-error]"* ]]
  [[ "$output" != *"STUB_REPLY"* ]]
  run bash "$SCRIPTS/inbox.sh" team cur --format ids
  [ -z "$output" ]
}

@test "cursor-bridge: label unset records the reported model without comparing" {
  export FAKE_CURSOR_MODEL_JSON='"Unexpected Exact Label"'
  bash "$SCRIPTS/send.sh" team alice cur "record only" >/dev/null
  bridge --model grok-4.6
  [ "$status" -eq 0 ]
  run bash "$SCRIPTS/inbox.sh" team alice --format ids
  [[ "$output" == *"STUB_REPLY"* ]]
  grep -q -- "reported='Unexpected Exact Label'" "$TEST_SKILL_DIR/run/cursor-bridge.team.cur.log"
}

@test "cursor-bridge: unpinned turn neither compares nor requires init.model" {
  export FAKE_CURSOR_MODE=initnomodel
  bash "$SCRIPTS/send.sh" team alice cur "legacy default" >/dev/null
  bridge --model-label "Ignored Without Pin"
  [ "$status" -eq 0 ]
  run bash "$SCRIPTS/inbox.sh" team alice --format ids
  [[ "$output" == *"STUB_REPLY"* ]]
  grep -q -- "requested='<default>' reported='<unreported>'" "$TEST_SKILL_DIR/run/cursor-bridge.team.cur.log"
}

@test "cursor-bridge: pinned turn requires a non-empty init.model even without a label" {
  export FAKE_CURSOR_MODE=initnomodel
  bash "$SCRIPTS/send.sh" team alice cur "missing reported model" >/dev/null
  bridge --model grok-4.6
  [ "$status" -eq 0 ]
  run bash "$SCRIPTS/inbox.sh" team cur --format ids
  [[ "$output" == *"missing reported model"* ]]
  run bash "$SCRIPTS/inbox.sh" team alice --format ids
  [ -z "$output" ]
}

@test "cursor-bridge: audit sanitizes control bytes and caps a malicious reported label" {
  local long
  long="$(printf 'A%.0s' {1..400})"
  export FAKE_CURSOR_MODEL_JSON="\"shown\\nFORGED\\u001b${long}\""
  bash "$SCRIPTS/send.sh" team alice cur "audit" >/dev/null
  bridge --model grok-4.6
  [ "$status" -eq 0 ]
  local log="$TEST_SKILL_DIR/run/cursor-bridge.team.cur.log"
  [ "$(grep -c -- "model-audit" "$log")" -eq 1 ]
  ! grep -q '^FORGED' "$log"
  run grep $'\x1b' "$log"
  [ "$status" -ne 0 ]
  local audit_line
  audit_line="$(grep -- "model-audit" "$log")"
  [ "${#audit_line}" -lt 300 ]
}

@test "cursor-bridge: N consecutive non-matching failures dead-letter too" {
  export FAKE_CURSOR_MODE=transientfail
  export AGMSG_CURSOR_BRIDGE_MAX_CONSEC_FAILURES=3
  bash "$SCRIPTS/send.sh" team alice cur "boom" >/dev/null
  bridge   # failure 1/3 — still unread, no notice
  run bash "$SCRIPTS/inbox.sh" team alice --format ids
  [ -z "$output" ]
  bridge   # failure 2/3 — still unread, no notice
  run bash "$SCRIPTS/inbox.sh" team alice --format ids
  [ -z "$output" ]
  bridge   # failure 3/3 — ceiling reached, dead-letter fires
  [ "$status" -eq 0 ]
  run bash "$SCRIPTS/inbox.sh" team alice --format ids
  [[ "$output" == *"[bridge-error]"* ]]
  [[ "$output" == *"3 consecutive failures"* ]]
  run bash "$SCRIPTS/inbox.sh" team cur --format ids
  [ -z "$output" ]
}

@test "cursor-bridge: a new message resets the consecutive-failure count" {
  export FAKE_CURSOR_MODE=transientfail
  export AGMSG_CURSOR_BRIDGE_MAX_CONSEC_FAILURES=2
  bash "$SCRIPTS/send.sh" team alice cur "first" >/dev/null
  bridge   # failure 1/2 for ids={first}
  # a second message changes the ids group for alice → the streak resets to 1
  bash "$SCRIPTS/send.sh" team alice cur "second" >/dev/null
  bridge   # failure 1/2 for ids={first,second} — must NOT dead-letter yet
  run bash "$SCRIPTS/inbox.sh" team alice --format ids
  [ -z "$output" ]
  run bash "$SCRIPTS/inbox.sh" team cur --format ids
  [[ "$output" == *"first"* ]]
  [[ "$output" == *"second"* ]]
}

# --- outbound spool: a broken send path must not re-burn turns ----------------

@test "cursor-bridge: a spooled dead-letter notice retries only the send, never the turn" {
  export FAKE_CURSOR_MODE=nonretriable
  bash "$SCRIPTS/send.sh" team alice cur "boom" >/dev/null
  break_send
  bridge   # turn + fallback fail, notice send fails → notice spooled to outbound
  [ "$status" -eq 0 ]
  local burned
  burned="$(turns_run)"
  bridge   # outbound present → zero cursor calls, send retried (and fails) only
  bridge
  [ "$(turns_run)" -eq "$burned" ]
  restore_send
  bridge   # send path recovered → notice delivered, ids read — still no new turn
  [ "$(turns_run)" -eq "$burned" ]
  run bash "$SCRIPTS/inbox.sh" team alice --format ids
  [[ "$output" == *"[bridge-error]"* ]]
  run bash "$SCRIPTS/inbox.sh" team cur --format ids
  [ -z "$output" ]
}

@test "cursor-bridge: a spooled fallback reply is resent verbatim without re-burning the fallback" {
  export FAKE_CURSOR_MODE=fallbackok
  bash "$SCRIPTS/send.sh" team alice cur "boom" >/dev/null
  break_send
  bridge   # normal turn terminal, fallback succeeds, reply send fails → reply spooled
  [ "$status" -eq 0 ]
  local burned
  burned="$(turns_run)"
  [ "$burned" -eq 2 ]   # exactly one normal + one fallback turn ran
  bridge   # spool present → no further turns of either kind
  [ "$(turns_run)" -eq "$burned" ]
  restore_send
  bridge   # cached reply goes out as-is; still no new turns
  [ "$(turns_run)" -eq "$burned" ]
  run bash "$SCRIPTS/inbox.sh" team alice --format ids
  [[ "$output" == *"FALLBACK_REPLY"* ]]
  [[ "$output" != *"[bridge-error]"* ]]
  run bash "$SCRIPTS/inbox.sh" team cur --format ids
  [ -z "$output" ]
}

# --- failstate robustness ------------------------------------------------------

@test "cursor-bridge: corrupt failstate lines read as 0 and the bridge survives" {
  export FAKE_CURSOR_MODE=transientfail
  bash "$SCRIPTS/send.sh" team alice cur "x" >/dev/null
  # find the real unread id so the corrupt count sits on the row the bridge reads
  run bash "$SCRIPTS/inbox.sh" team cur --format ids
  local id="${output%%$'\x1f'*}"
  local fs="$TEST_SKILL_DIR/run/cursor-bridge.team.cur.failstate"
  printf 'zzz\n' > "$fs"                            # partial line (sender only)
  printf 'bob\x1f%s\x1f\n' "$id" >> "$fs"           # empty count
  printf 'alice\x1f%s\x1fbanana\n' "$id" >> "$fs"   # non-numeric count
  bridge
  [ "$status" -eq 0 ]
  # count read as 0 (not a crash, not a dead-letter): message still unread
  run bash "$SCRIPTS/inbox.sh" team cur --format ids
  [ -n "$output" ]
  run bash "$SCRIPTS/inbox.sh" team alice --format ids
  [ -z "$output" ]
}

@test "cursor-bridge: a zero-padded failstate count is read as decimal (08 -> 8)" {
  export FAKE_CURSOR_MODE=transientfail
  export AGMSG_CURSOR_BRIDGE_FALLBACK_MODEL=""   # keep the ceiling path pure
  export AGMSG_CURSOR_BRIDGE_MAX_CONSEC_FAILURES=9
  bash "$SCRIPTS/send.sh" team alice cur "x" >/dev/null
  run bash "$SCRIPTS/inbox.sh" team cur --format ids
  local id="${output%%$'\x1f'*}"
  printf 'alice\x1f%s\x1f08\n' "$id" > "$TEST_SKILL_DIR/run/cursor-bridge.team.cur.failstate"
  bridge
  [ "$status" -eq 0 ]
  # 08 → 8 (not invalid octal), this failure is the 9th → ceiling → dead-letter
  run bash "$SCRIPTS/inbox.sh" team alice --format ids
  [[ "$output" == *"9 consecutive failures"* ]]
  run bash "$SCRIPTS/inbox.sh" team cur --format ids
  [ -z "$output" ]
}

@test "cursor-bridge: last.json retains only init and result and deletes the raw stream" {
  bash "$SCRIPTS/send.sh" team alice cur "filter retained output" >/dev/null
  bash "$TYPES/cursor/cursor-bridge.sh" \
    --interval 30 --project "$PROJ" --team team --name cur \
    --chat-id testchat-1234-1234-1234-123456789012 \
    >"$TEST_SKILL_DIR/bridge.stdout" 2>"$TEST_SKILL_DIR/bridge.stderr" &
  local bridge_pid=$!
  test_fixture_register_owned_pid "$bridge_pid"
  local outfile="$TEST_SKILL_DIR/run/cursor-bridge.team.cur.last.json"
  wait_for_file_contains "$TEST_SKILL_DIR/run/cursor-bridge.team.cur.log" "model-audit"
  [ -f "$outfile" ]
  [ "$(awk 'NF { n++ } END { print n+0 }' "$outfile")" -eq 2 ]
  grep -q '"type":"system"' "$outfile"
  grep -q '"type":"result"' "$outfile"
  ! grep -q '"type":"user"' "$outfile"
  ! grep -q '"type":"thinking"' "$outfile"
  ! grep -q '"type":"assistant"' "$outfile"
  [ ! -e "$outfile.stream" ]
  kill "$bridge_pid" 2>/dev/null || true
  wait "$bridge_pid" 2>/dev/null || true
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

@test "cursor-bridge: --role-file prepends the standing role to the prompt" {
  local rf="$TEST_SKILL_DIR/role.md"
  printf '%s\n' "You are the planner. unique-role-marker-xyz." > "$rf"
  bash "$SCRIPTS/send.sh" team alice cur "do a thing" >/dev/null
  run bash "$TYPES/cursor/cursor-bridge.sh" \
    --once --readonly --project "$PROJ" --team team --name cur \
    --chat-id testchat-1234-1234-1234-123456789012 \
    --role-file "$rf"
  [ "$status" -eq 0 ]
  run cat "$FAKE_CURSOR_PROMPT"
  [[ "$output" == *"unique-role-marker-xyz"* ]]
}

@test "cursor-bridge: no --role-file keeps the generic reviewer intro (back-compat)" {
  bash "$SCRIPTS/send.sh" team alice cur "do a thing" >/dev/null
  bridge_ro
  [ "$status" -eq 0 ]
  run cat "$FAKE_CURSOR_PROMPT"
  [[ "$output" == *"headless agmsg reviewer"* ]]
}
