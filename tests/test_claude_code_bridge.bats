#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
  export SKILL_DIR="$TEST_SKILL_DIR"
  export RUN="$TEST_SKILL_DIR/run"
  export PROJ="$TEST_SKILL_DIR/project"
  export CAPTURE="$TEST_SKILL_DIR/claude-capture"
  export FAKE_BIN="$TEST_SKILL_DIR/bin"
  export FAKE_CLAUDE="$FAKE_BIN/claude"
  export FAKE_UUID="$FAKE_BIN/uuid"
  mkdir -p "$PROJ" "$CAPTURE" "$FAKE_BIN" "$RUN"

  bash "$SCRIPTS/join.sh" team worker claude-code "$PROJ" >/dev/null
  bash "$SCRIPTS/join.sh" team alice claude-code "$PROJ" >/dev/null
  bash "$SCRIPTS/join.sh" team bob claude-code "$PROJ" >/dev/null

  cat > "$FAKE_UUID" <<'STUB'
#!/usr/bin/env bash
count_file="$FAKE_CAPTURE/uuid-count"
n=$(cat "$count_file" 2>/dev/null || echo 0)
n=$((n + 1))
printf '%s\n' "$n" > "$count_file"
printf '00000000-0000-4000-8000-%012d\n' "$n"
STUB
  chmod +x "$FAKE_UUID"

  cat > "$FAKE_CLAUDE" <<'STUB'
#!/usr/bin/env bash
set -u
count_file="$FAKE_CAPTURE/call-count"
n=$(cat "$count_file" 2>/dev/null || echo 0)
n=$((n + 1))
printf '%s\n' "$n" > "$count_file"
args_file="$FAKE_CAPTURE/args.$n"
env_file="$FAKE_CAPTURE/env.$n"
prompt_file="$FAKE_CAPTURE/prompt.$n"
: > "$args_file"
for arg in "$@"; do printf 'ARG=%s\n' "$arg" >> "$args_file"; done
printf 'cwd=%s\nconfig=%s\nsid=%s\nclaudecode=%s\nchild=%s\n' \
  "$PWD" "${CLAUDE_CONFIG_DIR:-<unset>}" \
  "${CLAUDE_CODE_SESSION_ID:-<unset>}" "${CLAUDECODE:-<unset>}" \
  "${CLAUDE_CODE_CHILD_SESSION:-<unset>}" > "$env_file"
cat > "$prompt_file"

mode=fresh
sid=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "--session-id" ]; then sid="$arg"; mode=fresh; fi
  if [ "$prev" = "--resume" ]; then sid="$arg"; mode=resume; fi
  prev="$arg"
done
printf 'mode=%s\nsession=%s\n' "$mode" "$sid" >> "$env_file"

if [ "${FAKE_CHECK_DB:-0}" = 1 ]; then
  unread=$(sqlite3 "$FAKE_DB" \
    "SELECT COUNT(*) FROM messages WHERE team='team' AND to_agent='worker' AND read_at IS NULL;" \
    | tr -d '\r')
  printf 'unread_at_cli=%s\n' "$unread" >> "$env_file"
fi

make_transcript() {
  munged=$(printf '%s' "$PWD" | LC_ALL=C sed 's/[^A-Za-z0-9-]/-/g')
  mkdir -p "$CLAUDE_CONFIG_DIR/projects/$munged"
  printf '{"sessionId":"%s"}\n' "$sid" \
    >> "$CLAUDE_CONFIG_DIR/projects/$munged/$sid.jsonl"
}

send_outbound() {
  printf 'fake outbound call %s session %s' "$n" "$sid" \
    | bash "$FAKE_SCRIPTS/send.sh" team worker "${FAKE_TO:-alice}" --stdin >/dev/null
}

case "${FAKE_MODE:-success}" in
  resume-reject)
    if [ "$mode" = resume ]; then
      echo "Error: session $sid not found; resume rejected" >&2
      exit 7
    fi
    make_transcript
    send_outbound
    ;;
  exit7)
    [ "${FAKE_CREATE_TRANSCRIPT:-0}" = 1 ] && make_transcript
    echo "fake claude failure" >&2
    exit 7
    ;;
  no-outbound)
    make_transcript
    ;;
  missing-transcript)
    send_outbound
    ;;
  slow-success)
    if ! mkdir "$FAKE_CAPTURE/active" 2>/dev/null; then
      echo overlap >> "$FAKE_CAPTURE/overlap"
    fi
    printf '%s\n' "$$" > "$FAKE_CAPTURE/started.$n"
    sleep 2
    rmdir "$FAKE_CAPTURE/active" 2>/dev/null || true
    make_transcript
    send_outbound
    ;;
  barrier-success)
    : > "$FAKE_CAPTURE/barrier.started"
    waited=0
    while [ ! -e "$FAKE_CAPTURE/barrier.release" ] && [ "$waited" -lt 100 ]; do
      sleep 0.05
      waited=$((waited + 1))
    done
    make_transcript
    send_outbound
    ;;
  hang)
    [ "${FAKE_HANG_REJECTION:-0}" = 1 ] \
      && echo "Error: session $sid not found; resume rejected" >&2
    trap 'echo parent-TERM >> "$FAKE_CAPTURE/signals"' TERM
    (
      trap 'echo child-TERM >> "$FAKE_CAPTURE/signals"' TERM
      while :; do sleep 1; done
    ) &
    child=$!
    printf '%s %s\n' "$$" "$child" > "$FAKE_CAPTURE/hang-pids"
    while :; do sleep 1; done
    ;;
  success)
    make_transcript
    send_outbound
    ;;
  *)
    echo "unknown fake mode" >&2
    exit 9
    ;;
esac

printf '{"type":"result","subtype":"success","session_id":"%s"}\n' "$sid"
exit 0
STUB
  chmod +x "$FAKE_CLAUDE"

  export AGMSG_CLAUDE_CMD="$FAKE_CLAUDE"
  export AGMSG_UUIDGEN_CMD="$FAKE_UUID"
  export FAKE_CAPTURE="$CAPTURE"
  export FAKE_SCRIPTS="$SCRIPTS"
  export FAKE_DB="$TEST_SKILL_DIR/db/messages.db"
  export FAKE_MODE=success
  export FAKE_CHECK_DB=0
  export FAKE_CREATE_TRANSCRIPT=0
  export FAKE_HANG_REJECTION=0
  export FAKE_TO=alice
}

teardown() {
  teardown_test_env
}

bridge() {
  bash "$TYPES/claude-code/claude-code-bridge.sh" \
    --project "$PROJ" --team team --name worker \
    --identity-key test-key. \
    --once --watch-timeout 1 --interval 1 --turn-timeout 5 "$@"
}

send_to_worker() {
  local sender="$1" body="$2"
  printf '%s' "$body" \
    | bash "$SCRIPTS/send.sh" team "$sender" worker --stdin >/dev/null
}

db_scalar() {
  sqlite3 "$FAKE_DB" "$1" | tr -d '\r'
}

session_file() {
  printf '%s/claude-code-bridge.team.worker.session' "$RUN"
}

@test "claude-code bridge lifecycle, stdin, env, cwd, role, args, and mark timing" {
  printf 'STANDING ROLE\n' > "$RUN/claude-code-bridge.team.worker.role"
  send_to_worker alice "inspect this change"
  export FAKE_CHECK_DB=1

  run bridge \
    --model sonnet --effort high --settings '{"sandbox":"strict"}' \
    --add-dir "$TEST_SKILL_DIR/shared"
  [ "$status" -eq 0 ]

  armed=$(printf '%s\n' "$output" | grep -n 'claude-code-bridge: armed team/worker' | cut -d: -f1)
  wake=$(printf '%s\n' "$output" | grep -n 'claude-code-bridge: wakeup 1 for team/worker' | cut -d: -f1)
  started=$(printf '%s\n' "$output" | grep -n 'claude-code-bridge: started turn on session 00000000-0000-4000-8000-000000000001' | cut -d: -f1)
  [ "$armed" -lt "$wake" ]
  [ "$wake" -lt "$started" ]

  grep -Fxq 'ARG=-p' "$CAPTURE/args.1"
  grep -Fxq 'ARG=--output-format' "$CAPTURE/args.1"
  grep -Fxq 'ARG=json' "$CAPTURE/args.1"
  grep -Fxq 'ARG=--session-id' "$CAPTURE/args.1"
  grep -Fxq 'ARG=00000000-0000-4000-8000-000000000001' "$CAPTURE/args.1"
  grep -Fxq 'ARG=--model' "$CAPTURE/args.1"
  grep -Fxq 'ARG=sonnet' "$CAPTURE/args.1"
  grep -Fxq 'ARG=--effort' "$CAPTURE/args.1"
  grep -Fxq 'ARG=high' "$CAPTURE/args.1"
  grep -Fxq 'ARG={"sandbox":"strict"}' "$CAPTURE/args.1"
  grep -Fxq "ARG=$TEST_SKILL_DIR/shared" "$CAPTURE/args.1"

  grep -Fxq "cwd=$RUN/claude-code-team-worker-cwd" "$CAPTURE/env.1"
  grep -Fxq "config=$TEST_SKILL_DIR/db/claude-worker-home" "$CAPTURE/env.1"
  grep -Fxq 'sid=<unset>' "$CAPTURE/env.1"
  grep -Fxq 'claudecode=<unset>' "$CAPTURE/env.1"
  grep -Fxq 'child=<unset>' "$CAPTURE/env.1"
  grep -Fxq 'unread_at_cli=0' "$CAPTURE/env.1"

  [ "$(sed -n '1p' "$CAPTURE/prompt.1")" = "STANDING ROLE" ]
  grep -q "Messages from 'alice':" "$CAPTURE/prompt.1"
  grep -q "inspect this change" "$CAPTURE/prompt.1"
  grep -q "$SCRIPTS/send.sh team worker <to> <message>" "$CAPTURE/prompt.1"
  [ "$(cat "$(session_file)")" = "00000000-0000-4000-8000-000000000001" ]
  [ -f "$RUN/claude-code-bridge.team.worker.log" ]
  [ ! -e "$RUN/claude-code-bridge.team.worker.pid" ]
  [ ! -e "$RUN/claude-code-bridge.team.worker.meta" ]
  [ ! -e "$RUN/claude-code-bridge.team.worker.role" ]
}

@test "runtime disallowedTools values are forwarded and remain absent when probe policy omits them" {
  send_to_worker alice "review runtime"
  run bridge \
    --disallowedTools Edit,Write,NotebookEdit \
    --disallowedTools WebFetch
  [ "$status" -eq 0 ]
  [ "$(grep -Fxc 'ARG=--disallowedTools' "$CAPTURE/args.1")" -eq 2 ]
  grep -Fxq 'ARG=Edit,Write,NotebookEdit' "$CAPTURE/args.1"
  grep -Fxq 'ARG=WebFetch' "$CAPTURE/args.1"

  send_to_worker alice "probe-shaped omission"
  run bridge
  [ "$status" -eq 0 ]
  ! grep -Fq 'ARG=--disallowedTools' "$CAPTURE/args.2"
  ! grep -Fq 'ARG=Edit,Write,NotebookEdit' "$CAPTURE/args.2"
}

@test "confirmed session resumes on the next one-shot turn" {
  send_to_worker alice first
  run bridge
  [ "$status" -eq 0 ]

  send_to_worker alice second
  run bridge
  [ "$status" -eq 0 ]
  grep -Fxq 'ARG=--resume' "$CAPTURE/args.2"
  grep -Fxq 'ARG=00000000-0000-4000-8000-000000000001' "$CAPTURE/args.2"
  ! grep -Fxq 'ARG=--session-id' "$CAPTURE/args.2"
  [ "$(cat "$(session_file)")" = "00000000-0000-4000-8000-000000000001" ]
}

@test "exit zero with no outbound is failed per sender" {
  send_to_worker alice "from alice"
  send_to_worker bob "from bob"
  export FAKE_MODE=no-outbound

  run bridge
  [ "$status" -eq 0 ]
  [ "$(db_scalar "SELECT COUNT(*) FROM messages WHERE team='team' AND from_agent='worker' AND body LIKE '[bridge-error] claude-code turn failed%wrote no agmsg outbound%';")" -eq 2 ]
  [ "$(db_scalar "SELECT COUNT(*) FROM messages WHERE team='team' AND to_agent='worker' AND read_at IS NULL;")" -eq 0 ]
}

@test "watermark and outbound DB errors are distinct from no-outbound" {
  send_to_worker alice "preflight db failure"
  export AGMSG_CLAUDE_BRIDGE_DB_FAIL_AT=watermark
  run bridge
  [ "$status" -eq 0 ]
  [ ! -f "$CAPTURE/call-count" ]
  [ "$(db_scalar "SELECT COUNT(*) FROM messages WHERE from_agent='worker' AND body LIKE '%database error while capturing%';")" -eq 1 ]

  unset AGMSG_CLAUDE_BRIDGE_DB_FAIL_AT
  send_to_worker alice "postflight db failure"
  export AGMSG_CLAUDE_BRIDGE_DB_FAIL_AT=outbound
  export FAKE_MODE=no-outbound
  run bridge
  [ "$status" -eq 0 ]
  [ "$(cat "$CAPTURE/call-count")" -eq 1 ]
  [ "$(db_scalar "SELECT COUNT(*) FROM messages WHERE from_agent='worker' AND body LIKE '%database error prevented outbound verification%';")" -eq 1 ]
  [ "$(db_scalar "SELECT COUNT(*) FROM messages WHERE from_agent='worker' AND body LIKE '%wrote no agmsg outbound%';")" -eq 0 ]
}

@test "resume watermark error cannot reuse stale rejection output" {
  send_to_worker alice establish
  run bridge
  [ "$status" -eq 0 ]
  before="$(db_scalar "SELECT MAX(id) FROM messages;")"
  printf 'Error: stale session not found; resume rejected\n' \
    > "$RUN/claude-code-bridge.team.worker.stderr"

  send_to_worker alice "resume with unavailable DB"
  export AGMSG_CLAUDE_BRIDGE_DB_FAIL_AT=watermark
  run bridge
  [ "$status" -eq 0 ]

  [ "$(cat "$CAPTURE/call-count")" -eq 1 ]
  [ "$(db_scalar "SELECT COUNT(*) FROM messages WHERE id > $before AND from_agent='worker' AND body LIKE '%database error while capturing%';")" -eq 1 ]
  [ "$(db_scalar "SELECT COUNT(*) FROM messages WHERE id > $before AND from_agent='worker' AND body LIKE '%resume context%was rejected%';")" -eq 0 ]
}

@test "resume rejection notifies context loss before the fresh-turn watermark" {
  send_to_worker alice establish
  run bridge
  [ "$status" -eq 0 ]
  before="$(db_scalar "SELECT MAX(id) FROM messages;")"

  send_to_worker alice resume
  export FAKE_MODE=resume-reject
  run bridge
  [ "$status" -eq 0 ]

  grep -Fxq 'ARG=--resume' "$CAPTURE/args.2"
  grep -Fxq 'ARG=--session-id' "$CAPTURE/args.3"
  grep -Fxq 'ARG=00000000-0000-4000-8000-000000000002' "$CAPTURE/args.3"
  context_id="$(db_scalar "SELECT MIN(id) FROM messages WHERE id > $before AND from_agent='worker' AND body LIKE '%resume context%was rejected%';")"
  reply_id="$(db_scalar "SELECT MIN(id) FROM messages WHERE id > $before AND from_agent='worker' AND body LIKE 'fake outbound call 3%';")"
  [ -n "$context_id" ] && [ -n "$reply_id" ]
  [ "$context_id" -lt "$reply_id" ]
  [ "$(cat "$(session_file)")" = "00000000-0000-4000-8000-000000000002" ]
}

@test "nonzero fresh turn is not rerun and its candidate is reclassified next wake" {
  send_to_worker alice uncertain
  export FAKE_MODE=exit7
  export FAKE_CREATE_TRANSCRIPT=1
  run bridge
  [ "$status" -eq 0 ]
  [ "$(cat "$CAPTURE/call-count")" -eq 1 ]
  [ ! -e "$(session_file)" ]
  [ -f "$RUN/claude-code-bridge.team.worker.candidate" ]
  [ "$(db_scalar "SELECT COUNT(*) FROM messages WHERE from_agent='worker' AND body LIKE '%outcome is unknown%not rerun%';")" -eq 1 ]

  send_to_worker alice next
  export FAKE_MODE=success
  run bridge
  [ "$status" -eq 0 ]
  grep -Fxq 'ARG=--resume' "$CAPTURE/args.2"
  grep -Fxq 'ARG=00000000-0000-4000-8000-000000000001' "$CAPTURE/args.2"
  [ "$(cat "$(session_file)")" = "00000000-0000-4000-8000-000000000001" ]
  [ ! -e "$RUN/claude-code-bridge.team.worker.candidate" ]
}

@test "session is never persisted when exit zero has no transcript" {
  send_to_worker alice missing
  export FAKE_MODE=missing-transcript
  run bridge
  [ "$status" -eq 0 ]
  [ ! -e "$(session_file)" ]
  [ "$(db_scalar "SELECT COUNT(*) FROM messages WHERE from_agent='worker' AND body LIKE '%no transcript exists%';")" -eq 1 ]
}

@test "one MiB stdin cap leaves overflow unread and delivers each exact id once" {
  {
    printf 'FIRST:'
    head -c 599994 /dev/zero | tr '\0' A
  } | bash "$SCRIPTS/send.sh" team alice worker --stdin >/dev/null
  {
    printf 'SECOND:'
    head -c 599993 /dev/zero | tr '\0' B
  } | bash "$SCRIPTS/send.sh" team alice worker --stdin >/dev/null

  run bridge
  [ "$status" -eq 0 ]
  [ "$(wc -c < "$CAPTURE/prompt.1" | tr -d ' ')" -le 1048576 ]
  grep -q 'FIRST:' "$CAPTURE/prompt.1"
  ! grep -q 'SECOND:' "$CAPTURE/prompt.1"
  [ "$(db_scalar "SELECT COUNT(*) FROM messages WHERE to_agent='worker' AND read_at IS NULL AND body LIKE 'SECOND:%';")" -eq 1 ]

  run bridge
  [ "$status" -eq 0 ]
  [ "$(wc -c < "$CAPTURE/prompt.2" | tr -d ' ')" -le 1048576 ]
  grep -q 'SECOND:' "$CAPTURE/prompt.2"
  ! grep -q 'FIRST:' "$CAPTURE/prompt.2"
  [ "$(db_scalar "SELECT COUNT(*) FROM messages WHERE to_agent='worker' AND read_at IS NULL;")" -eq 0 ]
  [ "$(cat "$CAPTURE/call-count")" -eq 2 ]
}

@test "an individually oversized row is compensated without starving the same-wake batch" {
  {
    printf 'POISON:'
    head -c 1099993 /dev/zero | tr '\0' P
  } | bash "$SCRIPTS/send.sh" team bob worker --stdin >/dev/null
  poison_id="$(db_scalar "SELECT id FROM messages WHERE body LIKE 'POISON:%';")"
  {
    printf 'FITS:'
    head -c 549995 /dev/zero | tr '\0' F
  } | bash "$SCRIPTS/send.sh" team alice worker --stdin >/dev/null
  fits_id="$(db_scalar "SELECT id FROM messages WHERE body LIKE 'FITS:%';")"
  {
    printf 'DEFER:'
    head -c 549994 /dev/zero | tr '\0' D
  } | bash "$SCRIPTS/send.sh" team bob worker --stdin >/dev/null
  defer_id="$(db_scalar "SELECT id FROM messages WHERE body LIKE 'DEFER:%';")"
  export FAKE_CHECK_DB=1

  run bridge
  [ "$status" -eq 0 ]

  [ "$(cat "$CAPTURE/call-count")" -eq 1 ]
  grep -q 'FITS:' "$CAPTURE/prompt.1"
  ! grep -q 'POISON:' "$CAPTURE/prompt.1"
  ! grep -q 'DEFER:' "$CAPTURE/prompt.1"
  grep -Fxq 'unread_at_cli=1' "$CAPTURE/env.1"
  [ "$(db_scalar "SELECT COUNT(*) FROM messages WHERE id=$poison_id AND read_at IS NOT NULL;")" -eq 1 ]
  [ "$(db_scalar "SELECT COUNT(*) FROM messages WHERE id=$fits_id AND read_at IS NOT NULL;")" -eq 1 ]
  [ "$(db_scalar "SELECT COUNT(*) FROM messages WHERE id=$defer_id AND read_at IS NULL;")" -eq 1 ]
  [ "$(db_scalar "SELECT COUNT(*) FROM messages WHERE from_agent='worker' AND to_agent='bob' AND body LIKE '[bridge-error]%message id $poison_id%rendered prompt%1048576 bytes%';")" -eq 1 ]
  [ "$(printf '%s\n' "$output" | grep -c 'wakeup 1 for team/worker')" -eq 1 ]
  [ "$(printf '%s\n' "$output" | grep -c 'wakeup 2 for team/worker')" -eq 0 ]
}

@test "oversized role overhead terminally compensates rows without launching Claude" {
  head -c 2048 /dev/zero | tr '\0' R \
    > "$RUN/claude-code-bridge.team.worker.role"
  send_to_worker alice "small body"
  message_id="$(db_scalar "SELECT id FROM messages WHERE body='small body';")"
  export AGMSG_CLAUDE_BRIDGE_BATCH_BYTES=1024

  run bridge
  [ "$status" -eq 0 ]

  [ ! -e "$CAPTURE/call-count" ]
  [ "$(db_scalar "SELECT COUNT(*) FROM messages WHERE id=$message_id AND read_at IS NOT NULL;")" -eq 1 ]
  [ "$(db_scalar "SELECT COUNT(*) FROM messages WHERE from_agent='worker' AND to_agent='alice' AND body LIKE '[bridge-error]%message id $message_id%stdin batch cap of 1024 bytes%';")" -eq 1 ]
  [ "$(printf '%s\n' "$output" | grep -c 'wakeup 1 for team/worker')" -eq 1 ]
  [ "$(printf '%s\n' "$output" | grep -c 'started turn')" -eq 0 ]
}

@test "failed notice send spools JSON and retries at next startup without another turn" {
  send_to_worker alice broken
  export FAKE_MODE=exit7
  mv "$SCRIPTS/send.sh" "$SCRIPTS/send.sh.real"
  cat > "$SCRIPTS/send.sh" <<'STUB'
#!/usr/bin/env bash
if [ "${2:-}" = worker ]; then
  cat >/dev/null
  exit 9
fi
exec bash "$0.real" "$@"
STUB
  chmod +x "$SCRIPTS/send.sh"

  run bridge
  [ "$status" -eq 0 ]
  spool="$RUN/claude-code-bridge.team.worker.outbound.json"
  [ -f "$spool" ]
  [ "$(sqlite_mem "SELECT json_valid(readfile('$(rf "$spool")'));")" = 1 ]
  [ "$(cat "$CAPTURE/call-count")" -eq 1 ]

  mv "$SCRIPTS/send.sh.real" "$SCRIPTS/send.sh"
  run bridge
  [ "$status" -eq 0 ]
  [ ! -e "$spool" ]
  [ "$(cat "$CAPTURE/call-count")" -eq 1 ]
  [ "$(db_scalar "SELECT COUNT(*) FROM messages WHERE from_agent='worker' AND body LIKE '%outcome is unknown%';")" -eq 1 ]
}

@test "timeout sends TERM then KILL to the whole turn process group" {
  send_to_worker alice hang
  export FAKE_MODE=hang
  export AGMSG_CLAUDE_BRIDGE_TERM_GRACE=0.2
  run bash "$TYPES/claude-code/claude-code-bridge.sh" \
    --project "$PROJ" --team team --name worker --identity-key timeout. \
    --once --watch-timeout 1 --interval 1 --turn-timeout 1
  [ "$status" -eq 0 ]
  grep -q 'parent-TERM' "$CAPTURE/signals"
  grep -q 'child-TERM' "$CAPTURE/signals"
  read -r parent child < "$CAPTURE/hang-pids"
  wait_until 5 _pid_gone "$parent"
  wait_until 5 _pid_gone "$child"
  [ "$(db_scalar "SELECT COUNT(*) FROM messages WHERE from_agent='worker' AND body LIKE '%timed out%outcome is unknown%';")" -eq 1 ]
}

@test "timed-out resume is never retried even when stderr resembles rejection" {
  send_to_worker alice establish
  run bridge
  [ "$status" -eq 0 ]

  send_to_worker alice uncertain
  export FAKE_MODE=hang
  export FAKE_HANG_REJECTION=1
  export AGMSG_CLAUDE_BRIDGE_TERM_GRACE=0.1
  run bash "$TYPES/claude-code/claude-code-bridge.sh" \
    --project "$PROJ" --team team --name worker --identity-key timeout-resume. \
    --once --watch-timeout 1 --interval 1 --turn-timeout 1
  [ "$status" -eq 0 ]

  [ "$(cat "$CAPTURE/call-count")" -eq 2 ]
  [ ! -e "$CAPTURE/args.3" ]
  [ "$(db_scalar "SELECT COUNT(*) FROM messages WHERE from_agent='worker' AND body LIKE '%timed out%outcome is unknown%';")" -eq 1 ]
  [ "$(db_scalar "SELECT COUNT(*) FROM messages WHERE from_agent='worker' AND body LIKE '%resume context%was rejected%';")" -eq 0 ]
}

@test "concurrent bridge launch runs one CLI and consumes the id once" {
  send_to_worker alice concurrent
  export FAKE_MODE=slow-success
  bridge > "$TEST_SKILL_DIR/bridge-one.out" 2>&1 3>&- &
  first_bridge=$!
  wait_for_file "$CAPTURE/started.1"

  run bridge
  [ "$status" -ne 0 ]
  [[ "$output" == *"already running"* ]]
  wait "$first_bridge"

  [ "$(cat "$CAPTURE/call-count")" -eq 1 ]
  [ ! -e "$CAPTURE/overlap" ]
  [ "$(db_scalar "SELECT COUNT(*) FROM messages WHERE to_agent='worker' AND read_at IS NULL;")" -eq 0 ]
  [ "$(db_scalar "SELECT COUNT(*) FROM messages WHERE from_agent='worker' AND body LIKE 'fake outbound%';")" -eq 1 ]
}

@test "message arriving during a turn stays unread until the next exact snapshot" {
  send_to_worker alice early
  export FAKE_MODE=barrier-success
  bridge > "$TEST_SKILL_DIR/barrier-bridge.out" 2>&1 3>&- &
  bridge_pid=$!
  wait_for_file "$CAPTURE/barrier.started"
  send_to_worker bob late
  : > "$CAPTURE/barrier.release"
  wait "$bridge_pid"

  [ "$(db_scalar "SELECT COUNT(*) FROM messages WHERE to_agent='worker' AND read_at IS NULL AND body='late';")" -eq 1 ]
  export FAKE_MODE=success
  run bridge
  [ "$status" -eq 0 ]
  grep -q "Messages from 'bob':" "$CAPTURE/prompt.2"
  grep -q 'late' "$CAPTURE/prompt.2"
  ! grep -q 'early' "$CAPTURE/prompt.2"
}

@test "actas ownership is re-evaluated before wake and prevents CLI delivery" {
  setup_live_owner "$RUN" other-sid
  bash "$SCRIPTS/actas-claim.sh" "$PROJ" claude-code worker other-sid >/dev/null
  send_to_worker alice locked

  run bridge
  [ "$status" -ne 0 ]
  [[ "$output" == *"no available subscription"* ]]
  [ ! -e "$CAPTURE/call-count" ]
  [ "$(db_scalar "SELECT COUNT(*) FROM messages WHERE to_agent='worker' AND read_at IS NULL;")" -eq 1 ]
}
