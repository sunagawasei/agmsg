#!/usr/bin/env bats

# lib/inbox-target.sh: the single resolver for "which (team, agent) is THIS
# session's inbox", shared by check-inbox.sh's `stop` path today and the
# injection watcher later ([subtask:D]). Covers:
#   - session-team capability (type.conf) AND runtime opt-in (delivery.
#     session_team), never capability alone
#   - role priority over session-team, and falling back to session-team when
#     the role's actas lock is held by another live session
#   - raw-sid handling (composite/malformed/empty) feeding
#     agmsg_session_team_name_from_id
#   - check-inbox.sh's stop_output=followup output shape and the
#     AGMSG_CURSOR_BRIDGE short-circuit

load test_helper

setup() {
  setup_test_env
  export SKILL_DIR="$TEST_SKILL_DIR"
  export SCRIPT_DIR="$SCRIPTS"
  export RUN_DIR="$SKILL_DIR/run"
  mkdir -p "$RUN_DIR"
  # shellcheck disable=SC1090
  source "$SCRIPTS/lib/inbox-target.sh"
  export TEST_PROJECT="$(mktemp -d)"
}

teardown() {
  teardown_test_env
  rm -rf "$TEST_PROJECT"
}

enable_st() { bash "$SCRIPTS/config.sh" set delivery.session_team true >/dev/null; }

# --- capability AND runtime opt-in (never capability alone) ---

@test "session_team=false: cursor (has the capability) still falls back to project-team" {
  bash "$SCRIPTS/config.sh" set delivery.session_team false >/dev/null
  bash "$SCRIPTS/join.sh" projteam alice cursor "$TEST_PROJECT" >/dev/null
  run agmsg_inbox_target cursor "$TEST_PROJECT" "raw-sid-1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"agent=alice"* ]]
  [[ "$output" == *"teams=projteam"* ]]
  [[ "$output" != *"teams=s-"* ]]
}

@test "session_team=false: claude-code falls back to project-team" {
  bash "$SCRIPTS/config.sh" set delivery.session_team false >/dev/null
  bash "$SCRIPTS/join.sh" projteam alice claude-code "$TEST_PROJECT" >/dev/null
  run agmsg_inbox_target claude-code "$TEST_PROJECT" "raw-sid-1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"agent=alice"* ]]
  [[ "$output" == *"teams=projteam"* ]]
  [[ "$output" != *"teams=s-"* ]]
}

@test "session_team=false: a type with no session_team capability falls back to project-team" {
  bash "$SCRIPTS/config.sh" set delivery.session_team false >/dev/null
  bash "$SCRIPTS/join.sh" projteam alice codex "$TEST_PROJECT" >/dev/null
  run agmsg_inbox_target codex "$TEST_PROJECT" "raw-sid-1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"agent=alice"* ]]
  [[ "$output" == *"teams=projteam"* ]]
  [[ "$output" != *"teams=s-"* ]]
}

# --- raw session-id handling (agmsg_session_team_name_from_id passthrough) ---

@test "session team name: strips a .<pid> suffix from a composite raw sid" {
  enable_st
  run agmsg_inbox_target cursor "$TEST_PROJECT" "abc123.456"
  [ "$status" -eq 0 ]
  [[ "$output" == *"teams=s-abc123 "* ]]
  [[ "$output" != *"s-abc123.456"* ]]
}

@test "session team name: an unusual but non-empty raw sid passes through unchanged" {
  enable_st
  run agmsg_inbox_target cursor "$TEST_PROJECT" 'weird!!id'
  [ "$status" -eq 0 ]
  [[ "$output" == *"teams=s-weird!!id"* ]]
}

@test "session team name: an empty raw sid falls back to project-team resolution" {
  enable_st
  bash "$SCRIPTS/join.sh" projteam alice cursor "$TEST_PROJECT" >/dev/null
  run agmsg_inbox_target cursor "$TEST_PROJECT" ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"teams=projteam"* ]]
  [[ "$output" != *"teams=s-"* ]]
}

# --- role priority over session-team ---

@test "role priority: an active actas role wins over session-team routing" {
  enable_st
  bash "$SCRIPTS/join.sh" projteam reviewer cursor "$TEST_PROJECT" >/dev/null
  agmsg_role_session_record projteam reviewer sess-R "$TEST_PROJECT" cursor
  run agmsg_inbox_target cursor "$TEST_PROJECT" "sess-R"
  [ "$status" -eq 0 ]
  [[ "$output" == *"agent=reviewer"* ]]
  [[ "$output" == *"teams=projteam"* ]]
  [[ "$output" != *"teams=s-"* ]]
}

@test "role priority: a role lock held by another live session falls back to session-team" {
  enable_st
  bash "$SCRIPTS/join.sh" projteam reviewer cursor "$TEST_PROJECT" >/dev/null
  agmsg_role_session_record projteam reviewer sess-R "$TEST_PROJECT" cursor
  # A different, still-live session currently owns the actas lock for this role.
  echo "other-live-sid" > "$RUN_DIR/cc-instance.$$"
  echo "other-live-sid" > "$(actas_lock_path projteam reviewer)"
  run agmsg_inbox_target cursor "$TEST_PROJECT" "sess-R"
  [ "$status" -eq 0 ]
  [[ "$output" == *"agent=claude"* ]]
  [[ "$output" == *"teams=s-sess-R"* ]]
}

# --- end-to-end: registration order must not perturb session-team routing ---
# (the bug this resolver fixes: check-inbox.sh used to pick whoami.sh's first
# registered agent for `multiple=true`, so a same-project headless cursor
# worker could steal a session's own delivery)

@test "check-inbox (cursor, session-team on): worker registered before the session reads only its own inbox" {
  enable_st
  bash "$SCRIPTS/config.sh" set delivery.turn.check_interval 0 >/dev/null
  bash "$SCRIPTS/join.sh" reviewteam opus-review cursor "$TEST_PROJECT" >/dev/null
  bash "$SCRIPTS/join.sh" reviewteam human       cursor "$TEST_PROJECT" >/dev/null
  bash "$SCRIPTS/join.sh" s-sess-A claude cursor "$TEST_PROJECT" >/dev/null
  bash "$SCRIPTS/join.sh" s-sess-A human  cursor "$TEST_PROJECT" >/dev/null
  bash "$SCRIPTS/send.sh" reviewteam human opus-review "for-worker" >/dev/null
  bash "$SCRIPTS/send.sh" s-sess-A human claude "for-session" >/dev/null
  run bash -c "echo '{\"session_id\":\"sess-A\"}' | bash '$SCRIPTS/check-inbox.sh' cursor '$TEST_PROJECT'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"for-session"* ]]
  [[ "$output" != *"for-worker"* ]]
}

@test "check-inbox (cursor, session-team on): worker registered after the session still reads only its own inbox" {
  enable_st
  bash "$SCRIPTS/config.sh" set delivery.turn.check_interval 0 >/dev/null
  bash "$SCRIPTS/join.sh" s-sess-A claude cursor "$TEST_PROJECT" >/dev/null
  bash "$SCRIPTS/join.sh" s-sess-A human  cursor "$TEST_PROJECT" >/dev/null
  bash "$SCRIPTS/join.sh" reviewteam human       cursor "$TEST_PROJECT" >/dev/null
  bash "$SCRIPTS/join.sh" reviewteam opus-review cursor "$TEST_PROJECT" >/dev/null
  bash "$SCRIPTS/send.sh" reviewteam human opus-review "for-worker" >/dev/null
  bash "$SCRIPTS/send.sh" s-sess-A human claude "for-session" >/dev/null
  run bash -c "echo '{\"session_id\":\"sess-A\"}' | bash '$SCRIPTS/check-inbox.sh' cursor '$TEST_PROJECT'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"for-session"* ]]
  [[ "$output" != *"for-worker"* ]]
}

# --- check-inbox.sh: stop_output=followup ---

@test "check-inbox (cursor, stop_output=followup): emits a single-line JSON followup_message for new messages" {
  bash "$SCRIPTS/join.sh" testteam alice cursor "$TEST_PROJECT" >/dev/null
  bash "$SCRIPTS/join.sh" testteam bob   cursor "$TEST_PROJECT" >/dev/null
  bash "$SCRIPTS/config.sh" set delivery.turn.check_interval 0 >/dev/null
  bash "$SCRIPTS/send.sh" testteam bob alice "ping cursor" >/dev/null
  run bash -c "echo '{}' | bash '$SCRIPTS/check-inbox.sh' cursor '$TEST_PROJECT'"
  [ "$status" -eq 0 ]
  local lines
  lines=$(printf '%s\n' "$output" | wc -l | tr -d ' ')
  [ "$lines" -eq 1 ]
  [[ "$output" != *'"decision"'* ]]
  local msg
  msg=$(sqlite_mem "SELECT json_extract('$(printf '%s' "$output" | sed "s/'/''/g")', '\$.followup_message');")
  [[ "$msg" == *"ping cursor"* ]]
}

@test "check-inbox (cursor, stop_output=followup): escapes quotes, backslashes and embedded newlines" {
  bash "$SCRIPTS/join.sh" testteam alice cursor "$TEST_PROJECT" >/dev/null
  bash "$SCRIPTS/join.sh" testteam bob   cursor "$TEST_PROJECT" >/dev/null
  bash "$SCRIPTS/config.sh" set delivery.turn.check_interval 0 >/dev/null
  printf 'say "hi"\\ok\nline two' | bash "$SCRIPTS/send.sh" testteam bob alice --stdin >/dev/null
  run bash -c "echo '{}' | bash '$SCRIPTS/check-inbox.sh' cursor '$TEST_PROJECT'"
  [ "$status" -eq 0 ]
  local lines
  lines=$(printf '%s\n' "$output" | wc -l | tr -d ' ')
  [ "$lines" -eq 1 ]
  local msg
  msg=$(sqlite_mem "SELECT json_extract('$(printf '%s' "$output" | sed "s/'/''/g")', '\$.followup_message');")
  [[ "$msg" == *'say "hi"\ok'* ]]
  [[ "$msg" == *$'line two'* ]]
}

@test "check-inbox (cursor, stop_output=followup): emits nothing when the inbox is empty" {
  bash "$SCRIPTS/join.sh" testteam alice cursor "$TEST_PROJECT" >/dev/null
  bash "$SCRIPTS/config.sh" set delivery.turn.check_interval 0 >/dev/null
  run bash -c "echo '{}' | bash '$SCRIPTS/check-inbox.sh' cursor '$TEST_PROJECT'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- check-inbox.sh: AGMSG_CURSOR_BRIDGE short-circuit ---

@test "check-inbox: AGMSG_CURSOR_BRIDGE=1 exits immediately with no output" {
  bash "$SCRIPTS/join.sh" testteam alice cursor "$TEST_PROJECT" >/dev/null
  bash "$SCRIPTS/config.sh" set delivery.turn.check_interval 0 >/dev/null
  bash "$SCRIPTS/send.sh" testteam alice alice "should never surface" --force >/dev/null 2>&1 || true
  run env AGMSG_CURSOR_BRIDGE=1 bash "$SCRIPTS/check-inbox.sh" cursor "$TEST_PROJECT" </dev/null
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---段9 codex findings F3 / F11: inject-watcher deference and control-char escaping ---

@test "check-inbox (cursor): defers to a live inject watcher instead of double-delivering (F3)" {
  bash "$SCRIPTS/join.sh" testteam alice cursor "$TEST_PROJECT" >/dev/null
  bash "$SCRIPTS/join.sh" testteam bob   cursor "$TEST_PROJECT" >/dev/null
  bash "$SCRIPTS/config.sh" set delivery.turn.check_interval 0 >/dev/null
  bash "$SCRIPTS/send.sh" testteam bob alice "held by the inject watcher" >/dev/null

  # A live process standing in for the inject watcher, registered under the
  # instance id check-inbox derives from this session_id.
  sleep 120 &
  local watcher_pid=$!
  local sid="sess-f3"
  # Same derivation check-inbox.sh uses for the pidfile token.
  local iid
  iid=$(bash -c "
    source '$SCRIPTS/lib/compat.sh'
    source '$SCRIPTS/lib/instance-id.sh'
    agmsg_normalize_instance_id '$sid' cursor
  ")
  printf '%s\n' "$watcher_pid" > "$RUN_DIR/inject-watch.$iid.pid"

  # stderr is dropped: instance-id emits an advisory warning when it cannot
  # resolve an agent pid outside a real cursor process, and bats folds stderr
  # into $output.
  run bash -c "printf '{\"session_id\":\"$sid\"}' | bash '$SCRIPTS/check-inbox.sh' cursor '$TEST_PROJECT' 2>/dev/null"
  kill "$watcher_pid" 2>/dev/null || true
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  # Deferring must not consume the message: the inject watcher still needs it.
  # --format ids is the non-consuming read (it never marks rows read).
  run bash "$SCRIPTS/inbox.sh" testteam alice --format ids
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [[ "$output" == *"held by the inject watcher"* ]]
}

@test "check-inbox (cursor): a dead inject watcher pidfile does not suppress delivery (F3)" {
  bash "$SCRIPTS/join.sh" testteam alice cursor "$TEST_PROJECT" >/dev/null
  bash "$SCRIPTS/join.sh" testteam bob   cursor "$TEST_PROJECT" >/dev/null
  bash "$SCRIPTS/config.sh" set delivery.turn.check_interval 0 >/dev/null
  bash "$SCRIPTS/send.sh" testteam bob alice "stale pidfile must not hide this" >/dev/null

  local sid="sess-f3-stale"
  local iid
  iid=$(bash -c "
    source '$SCRIPTS/lib/compat.sh'
    source '$SCRIPTS/lib/instance-id.sh'
    agmsg_normalize_instance_id '$sid' cursor
  ")
  # A pid that cannot be alive.
  printf '%s\n' 999999 > "$RUN_DIR/inject-watch.$iid.pid"

  run bash -c "printf '{\"session_id\":\"$sid\"}' | bash '$SCRIPTS/check-inbox.sh' cursor '$TEST_PROJECT' 2>/dev/null"
  [ "$status" -eq 0 ]
  [[ "$output" == *"stale pidfile must not hide this"* ]]
}

@test "check-inbox (cursor, stop_output=followup): escapes CR and other C0 control characters (F11)" {
  bash "$SCRIPTS/join.sh" testteam alice cursor "$TEST_PROJECT" >/dev/null
  bash "$SCRIPTS/join.sh" testteam bob   cursor "$TEST_PROJECT" >/dev/null
  bash "$SCRIPTS/config.sh" set delivery.turn.check_interval 0 >/dev/null
  printf 'carriage\rreturn and \001 control' | bash "$SCRIPTS/send.sh" testteam bob alice --stdin >/dev/null

  run bash -c "echo '{}' | bash '$SCRIPTS/check-inbox.sh' cursor '$TEST_PROJECT'"
  [ "$status" -eq 0 ]
  # The payload must be valid JSON: a raw CR/control byte inside a JSON string
  # is invalid and the runtime would drop the whole followup after the rows were
  # already marked read.
  local valid
  valid=$(sqlite_mem "SELECT json_valid('$(printf '%s' "$output" | sed "s/'/''/g")');")
  [ "$valid" -eq 1 ]
  [[ "$output" != *$'\r'* ]]
  local msg
  msg=$(sqlite_mem "SELECT json_extract('$(printf '%s' "$output" | sed "s/'/''/g")', '\$.followup_message');")
  [[ "$msg" == *"carriage"* ]]
  [[ "$msg" == *"return and"* ]]
}
