#!/usr/bin/env bats

# session-team mode (opt-in delivery.session_team): each Claude session uses its
# own team s-<bare-session-uuid>, so concurrent / resumed sessions sharing a
# project directory are isolated (no cross-session crosstalk). PR1 = the
# crosstalk-stop core: whoami resolution, watch --team pinning, team-scoped
# ask/wait, and the lazy-codex no-op guard.

load test_helper

setup() {
  setup_test_env
  PROJ="/tmp/agmsg-st-proj"
  # shellcheck disable=SC1091
  source "$SCRIPTS/lib/identity-key.sh"
}

teardown() {
  teardown_test_env
}

enable_st() { bash "$SCRIPTS/config.sh" set delivery.session_team true >/dev/null; }

_db_body_present() {
  local body="$1" result
  result="$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" \
    "SELECT 1 FROM messages WHERE body='$body' LIMIT 1;")" || return 1
  [ "$result" = 1 ]
}

wait_for_db_body() {
  wait_until 5 _db_body_present "$1"
}

# --- whoami: current-team resolution ---------------------------------------

@test "session-team off: whoami uses project->team (unchanged)" {
  bash "$SCRIPTS/join.sh" base alice claude-code "$PROJ" >/dev/null
  run env CLAUDE_CODE_SESSION_ID=sess-X bash "$SCRIPTS/whoami.sh" "$PROJ" claude-code
  [ "$status" -eq 0 ]
  [[ "$output" == *"teams=base"* ]]
  [[ "$output" != *"teams=s-"* ]]
}

@test "session-team on: whoami resolves to s-<uuid>/claude from the env" {
  enable_st
  run env CLAUDE_CODE_SESSION_ID=sess-X bash "$SCRIPTS/whoami.sh" "$PROJ" claude-code
  [ "$status" -eq 0 ]
  [[ "$output" == *"agent=claude"* ]]
  [[ "$output" == *"teams=s-sess-X"* ]]
}

@test "session-team on but no CLAUDE_CODE_SESSION_ID: falls back to project->team" {
  enable_st
  bash "$SCRIPTS/join.sh" base alice claude-code "$PROJ" >/dev/null
  run env -u CLAUDE_CODE_SESSION_ID bash "$SCRIPTS/whoami.sh" "$PROJ" claude-code
  [ "$status" -eq 0 ]
  [[ "$output" == *"teams=base"* ]]
  [[ "$output" != *"teams=s-"* ]]
}

@test "session-team on: codex (no session id) is never short-circuited" {
  enable_st
  bash "$SCRIPTS/join.sh" base codexagent codex "$PROJ" >/dev/null
  run env -u CLAUDE_CODE_SESSION_ID bash "$SCRIPTS/whoami.sh" "$PROJ" codex
  [ "$status" -eq 0 ]
  [[ "$output" != *"teams=s-"* ]]
}

# --- watch --team pinning: the monitor isolation -----------------------------

@test "watch --team pins the subscription to one team (no cross-session delivery)" {
  enable_st
  # Same project dir registered into TWO session teams (the accumulation case).
  bash "$SCRIPTS/join.sh" s-AAA claude claude-code "$PROJ" >/dev/null
  bash "$SCRIPTS/join.sh" s-AAA peer codex "$PROJ" >/dev/null
  bash "$SCRIPTS/join.sh" s-BBB claude claude-code "$PROJ" >/dev/null
  bash "$SCRIPTS/join.sh" s-BBB peer codex "$PROJ" >/dev/null

  AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" sess-w "$PROJ" claude-code claude --team s-AAA \
    >"$TEST_SKILL_DIR/w.log" 2>/dev/null &
  local pid=$!
  # Wait until the watcher is actually receiving (it stamps a readiness sentinel
  # AFTER taking its watermark). Sending before that would, under load, let the
  # watcher take its mark past our message and skip it as "history".
  local ready="$TEST_SKILL_DIR/run/ready.s-AAA__claude"
  wait_for_file "$ready"

  bash "$SCRIPTS/send.sh" s-AAA peer claude "MSG-in-AAA" >/dev/null
  bash "$SCRIPTS/send.sh" s-BBB peer claude "MSG-in-BBB" >/dev/null
  # Poll for delivery of the in-team message (robust to load).
  wait_for_file_contains "$TEST_SKILL_DIR/w.log" "MSG-in-AAA"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  grep -q "MSG-in-AAA" "$TEST_SKILL_DIR/w.log"
  ! grep -q "MSG-in-BBB" "$TEST_SKILL_DIR/w.log"
}

# --- ask/--wait is team-scoped: the reply-matching isolation -----------------

@test "ask/--wait only matches a reply in the same team" {
  enable_st
  bash "$SCRIPTS/join.sh" s-AAA claude claude-code "$PROJ" >/dev/null
  bash "$SCRIPTS/join.sh" s-AAA codex codex "$PROJ" >/dev/null
  bash "$SCRIPTS/join.sh" s-BBB claude claude-code "$PROJ" >/dev/null
  bash "$SCRIPTS/join.sh" s-BBB codex codex "$PROJ" >/dev/null
  AGMSG_SEND_WAIT_INTERVAL=1 bash "$SCRIPTS/send.sh" s-AAA claude codex "Q" --wait --timeout 12 \
    >"$TEST_SKILL_DIR/ask.log" 2>/dev/null &
  local pid=$!
  wait_for_file_contains "$TEST_SKILL_DIR/ask.log" "Sent to codex in team s-AAA"
  bash "$SCRIPTS/send.sh" s-BBB codex claude "wrong-team-reply" >/dev/null  # other session team
  wait_for_db_body "wrong-team-reply"
  bash "$SCRIPTS/send.sh" s-AAA codex claude "right-reply" >/dev/null       # our team
  wait "$pid" 2>/dev/null || true

  grep -q "status=reply" "$TEST_SKILL_DIR/ask.log"
  grep -q "right-reply" "$TEST_SKILL_DIR/ask.log"
  ! grep -q "wrong-team-reply" "$TEST_SKILL_DIR/ask.log"
}

# --- send.sh cross-session isolation guard -----------------------------------

@test "send: refuses a cross-session send in session-team mode" {
  # session-team on + a session id present, but $TEAM is ANOTHER session's team
  # (the exact mistake that leaked a message across sessions): must refuse before
  # any insert, so the wrong team never receives the message.
  enable_st
  run env CLAUDE_CODE_SESSION_ID=sess-MINE bash "$SCRIPTS/send.sh" s-sess-OTHER claude codex "leak"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "refusing cross-session send"
  # And nothing landed in the other team.
  run sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT count(*) FROM messages WHERE team='s-sess-OTHER';"
  [ "$output" = "0" ]
}

@test "send: allows a send to the session's OWN team in session-team mode" {
  enable_st
  bash "$SCRIPTS/join.sh" s-sess-MINE claude claude-code "$PROJ" >/dev/null
  bash "$SCRIPTS/join.sh" s-sess-MINE codex codex "$PROJ" >/dev/null
  run env CLAUDE_CODE_SESSION_ID=sess-MINE bash "$SCRIPTS/send.sh" s-sess-MINE claude codex "ok"
  [ "$status" -eq 0 ]
}

@test "send: AGMSG_ALLOW_CROSS_TEAM escape hatch permits a cross-team send" {
  enable_st
  bash "$SCRIPTS/join.sh" s-sess-OTHER claude claude-code "$PROJ" >/dev/null
  bash "$SCRIPTS/join.sh" s-sess-OTHER codex codex "$PROJ" >/dev/null
  run env CLAUDE_CODE_SESSION_ID=sess-MINE AGMSG_ALLOW_CROSS_TEAM=1 \
    bash "$SCRIPTS/send.sh" s-sess-OTHER claude codex "deliberate"
  [ "$status" -eq 0 ]
}

@test "send: no cross-session guard when session-team mode is off" {
  # Mode off → no expected team → any team is allowed (legacy project-team flows).
  bash "$SCRIPTS/join.sh" s-sess-OTHER claude claude-code "$PROJ" >/dev/null
  bash "$SCRIPTS/join.sh" s-sess-OTHER codex codex "$PROJ" >/dev/null
  run env CLAUDE_CODE_SESSION_ID=sess-MINE bash "$SCRIPTS/send.sh" s-sess-OTHER claude codex "ok"
  [ "$status" -eq 0 ]
}

@test "send: no cross-session guard when there is no CLAUDE_CODE_SESSION_ID" {
  # A bridge reply runs send.sh with the env var scrubbed by codex's sandbox, so
  # there is no expected team and the reply to any team passes.
  enable_st
  bash "$SCRIPTS/join.sh" s-sess-OTHER claude claude-code "$PROJ" >/dev/null
  bash "$SCRIPTS/join.sh" s-sess-OTHER codex codex "$PROJ" >/dev/null
  run env -u CLAUDE_CODE_SESSION_ID bash "$SCRIPTS/send.sh" s-sess-OTHER codex claude "reply"
  [ "$status" -eq 0 ]
}

@test "send: does not block a send to a PROJECT team even with a session id present" {
  # Regression: a gemini/cursor agent whose env merely inherited
  # CLAUDE_CODE_SESSION_ID resolves a project team via whoami (session-team
  # resolution is claude-code-only). Its project-team send must NOT be refused —
  # the guard only protects session teams (s-*), not project teams.
  enable_st
  bash "$SCRIPTS/join.sh" myproject gemini gemini "$PROJ" >/dev/null
  bash "$SCRIPTS/join.sh" myproject claude claude-code "$PROJ" >/dev/null
  run env CLAUDE_CODE_SESSION_ID=sess-MINE bash "$SCRIPTS/send.sh" myproject gemini claude "ok"
  [ "$status" -eq 0 ]
}

# --- ensure-codex: safe no-op guard ------------------------------------------

@test "ensure-codex: no-op (exit 0, silent) when session-team mode is off" {
  run env CLAUDE_CODE_SESSION_ID=sess-X bash "$SCRIPTS/ensure-codex.sh" "$PROJ"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "ensure-codex: no-op when mode on but no CLAUDE_CODE_SESSION_ID" {
  enable_st
  run env -u CLAUDE_CODE_SESSION_ID bash "$SCRIPTS/ensure-codex.sh" "$PROJ"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "ensure-codex: recognizes an existing role-scoped bridge by identity key" {
  enable_st
  local key
  key="$(agmsg_identity_key s-sess-LIVE codex)"
  local stub_bin="$TEST_SKILL_DIR/ensure-stub"
  mkdir -p "$stub_bin"
  cat > "$stub_bin/pgrep" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"codex-bridge\\.js"*"--identity-key $EXPECTED_IDENTITY_KEY"*) exit 0 ;;
  *) exit 1 ;;
esac
STUB
  chmod +x "$stub_bin/pgrep"

  run env PATH="$stub_bin:$PATH" EXPECTED_IDENTITY_KEY="$key" \
    CLAUDE_CODE_SESSION_ID=sess-LIVE bash "$SCRIPTS/ensure-codex.sh" "$PROJ"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already running"* ]]
}

@test "ensure-codex: a longer identity-key prefix is not mistaken for this worker" {
  enable_st
  # s-X<TAB>aa is 6 bytes, so its unpadded base64 is a prefix of the encoding
  # for s-X<TAB>aabbb (9 bytes). This exercises the exact collision shape.
  local legacy_short legacy_long long_key
  legacy_short="$(printf '%s\t%s' s-X aa | base64 | tr -d '\r\n' | tr '+/' '-_')"
  legacy_long="$(printf '%s\t%s' s-X aabbb | base64 | tr -d '\r\n' | tr '+/' '-_')"
  [[ "$legacy_short" != *"="* ]]
  [[ "$legacy_long" == "$legacy_short"* ]]
  long_key="$(agmsg_identity_key s-X aabbb)"

  local stub_bin="$TEST_SKILL_DIR/ensure-prefix-stub"
  mkdir -p "$stub_bin"
  cat > "$stub_bin/pgrep" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = "-f" ] || exit 1
printf 'node /x/codex-bridge.js --identity-key %s --pair s-X\\taabbb\n' \
  "$LONG_IDENTITY_KEY" | grep -Eq -- "${2:-}"
STUB
  chmod +x "$stub_bin/pgrep"

  # Make the expected post-scan spawn attempt deterministic: the assertion is
  # that ensure-codex reaches it instead of returning "already running".
  mv "$SCRIPTS/spawn.sh" "$SCRIPTS/spawn.sh.real"
  printf '#!/usr/bin/env bash\nexit 37\n' > "$SCRIPTS/spawn.sh"
  chmod +x "$SCRIPTS/spawn.sh"

  run env PATH="$stub_bin:$PATH" LONG_IDENTITY_KEY="$long_key" \
    CLAUDE_CODE_SESSION_ID=X bash "$SCRIPTS/ensure-codex.sh" "$PROJ" aa
  [ "$status" -eq 1 ]
  [[ "$output" == *"failed to spawn"* ]]
  [[ "$output" != *"already running"* ]]
}

# --- PR2: SessionEnd teardown + orphan GC ------------------------------------

@test "session-end: tears down this session's codex worker, keeps team/history" {
  enable_st
  # Fake a spawned headless codex: a live process, its placement record, and the
  # bridge meta the real worker writes — so despawn's pid-reuse guard confirms the
  # recorded pid against meta and proceeds to kill it.
  agmsg_test_start_session_owner
  test_fixture_start_reaped_process sleep 300
  local fake="$TEST_REAPED_PID"
  mkdir -p "$TEST_SKILL_DIR/run"
  printf 'pid:%s\t%s\tcodex\n' "$fake" "/tmp/scratch-end" > "$TEST_SKILL_DIR/run/spawn.s-sessEND__codex"
  printf 'pid=%s\n' "$fake" > "$TEST_SKILL_DIR/run/codex-bridge.s-sessEND.codex.meta"
  printf '{"session_id":"sessEND"}' | bash "$SCRIPTS/session-end.sh" claude-code "$PROJ"
  agmsg_test_stop_session_owner
  # Teardown is detached now; poll for the placement-record removal (its last step).
  wait_until 8 bash -c "[ ! -f '$TEST_SKILL_DIR/run/spawn.s-sessEND__codex' ]"
  [ ! -f "$TEST_SKILL_DIR/run/spawn.s-sessEND__codex" ]          # placement removed
  # A bare `! kill -0` is exempt from set -e, so assert deadness via `run` to make
  # the teardown genuinely enforced (it was a silent no-op before).
  run kill -0 "$fake"; [ "$status" -ne 0 ]                       # worker torn down
  kill "$fake" 2>/dev/null || true                               # no leak on assertion failure
}

@test "session-end: tears down a codex worker via ps-args when no meta exists" {
  enable_st
  # No meta file: despawn's guard must confirm the recorded pid IS our bridge by
  # its command line before killing (PID-reuse safety). Stub ps for this pid so
  # the check is deterministic even in a sandbox that denies process listings.
  local key
  key="$(agmsg_identity_key s-sessAPS codex)"
  test_fixture_start_reaped_process sleep 300
  local fake="$TEST_REAPED_PID"
  local stub_bin="$TEST_SKILL_DIR/ps-stub"
  mkdir -p "$stub_bin"
  cat > "$stub_bin/ps" <<'STUB'
#!/usr/bin/env bash
if [ "$*" = "-ww -o args= -p $FAKE_BRIDGE_PID" ]; then
  printf 'node /x/codex-bridge.js --identity-key %s --pair s-sessAPS\tcodex --inline-inbox\n' "$FAKE_IDENTITY_KEY"
  exit 0
fi
exit 1
STUB
  chmod +x "$stub_bin/ps"
  mkdir -p "$TEST_SKILL_DIR/run"
  agmsg_test_start_session_owner
  printf 'pid:%s\t%s\tcodex\n' "$fake" "/tmp/scratch-aps" > "$TEST_SKILL_DIR/run/spawn.s-sessAPS__codex"
  printf '{"session_id":"sessAPS"}' | env PATH="$stub_bin:$PATH" \
    FAKE_BRIDGE_PID="$fake" FAKE_IDENTITY_KEY="$key" \
    bash "$SCRIPTS/session-end.sh" claude-code "$PROJ"
  agmsg_test_stop_session_owner
  wait_until 8 bash -c "[ ! -f '$TEST_SKILL_DIR/run/spawn.s-sessAPS__codex' ]"
  [ ! -f "$TEST_SKILL_DIR/run/spawn.s-sessAPS__codex" ]
  run kill -0 "$fake"; [ "$status" -ne 0 ]
  kill "$fake" 2>/dev/null || true
}

@test "session-start: derives the session team from the stdin session_id (env-independent)" {
  enable_st
  local out
  out="$(env -u CLAUDE_CODE_SESSION_ID bash -c 'printf "{\"session_id\":\"sess-STDIN\"}" | bash "'"$SCRIPTS"'/session-start.sh" claude-code "'"$PROJ"'"' 2>/dev/null || true)"
  [ -d "$TEST_SKILL_DIR/teams/s-sess-STDIN" ]          # team created from stdin id
  [[ "$out" == *"--team s-sess-STDIN"* ]]              # watcher pinned to it
}

@test "session-start: session-team gate uses SQLite JSON1 without Node" {
  enable_st
  local stub_bin="$TEST_SKILL_DIR/no-node-bin"
  mkdir -p "$stub_bin"
  cat > "$stub_bin/node" <<'STUB'
#!/usr/bin/env bash
echo "node must not be invoked by session-start" >&2
exit 91
STUB
  chmod +x "$stub_bin/node"

  run env PATH="$stub_bin:$PATH" bash "$SCRIPTS/session-start.sh" \
    claude-code "$PROJ" <<< '{"session_id":"sess-SQLITE"}'
  [ "$status" -eq 0 ]
  [ -d "$TEST_SKILL_DIR/teams/s-sess-SQLITE" ]
  [[ "$output" == *"--team s-sess-SQLITE"* ]]
  [[ "$output" != *"node must not be invoked"* ]]
}

@test "session-start: codex is not rejected by the Claude-only session gate" {
  enable_st
  run env -u CLAUDE_CODE_SESSION_ID bash "$SCRIPTS/session-start.sh" \
    codex "$PROJ" </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" != *"refusing Claude Code session-team registration"* ]]
}

@test "session-start: trims a padded stdin session_id before team registration" {
  enable_st
  run bash "$SCRIPTS/session-start.sh" claude-code "$PROJ" \
    <<< '{"session_id":" sess-PAD "}'
  [ "$status" -eq 0 ]
  [ -d "$TEST_SKILL_DIR/teams/s-sess-PAD" ]
  [ ! -d "$TEST_SKILL_DIR/teams/s- sess-PAD " ]
  [[ "$output" == *"--team s-sess-PAD"* ]]
}

@test "session-start: rejects a leading-dot session_id before creating s-" {
  enable_st
  run bash "$SCRIPTS/session-start.sh" claude-code "$PROJ" \
    <<< '{"session_id":".abc"}'
  [ "$status" -eq 0 ]
  [ ! -d "$TEST_SKILL_DIR/teams/s-" ]
  [[ "$output" == *"refusing Claude Code session-team registration"* ]]
  [[ "$output" != *".abc"* ]]
}

@test "session-start: accepts a large valid hook payload without argv overflow" {
  enable_st
  local padding payload
  padding="$(printf '%*s' 300000 '' | tr ' ' x)"
  payload="{\"session_id\":\"sess-LARGE\",\"padding\":\"$padding\"}"

  run bash "$SCRIPTS/session-start.sh" claude-code "$PROJ" <<< "$payload"
  [ "$status" -eq 0 ]
  [ -d "$TEST_SKILL_DIR/teams/s-sess-LARGE" ]
  [[ "$output" == *"--team s-sess-LARGE"* ]]
}

@test "session-start: embedded dot-command in payload cannot execute (sqlite3 stdin mode)" {
  enable_st
  local sentinel="$TEST_SKILL_DIR/injection-sentinel"
  rm -f "$sentinel"
  run bash "$SCRIPTS/session-start.sh" claude-code "$PROJ" <<EOF
{"session_id":"sess-DOT",
.shell touch $sentinel
"x":"y"}
EOF
  [ "$status" -eq 0 ]
  [ ! -f "$sentinel" ]
  [[ "$output" == *"refusing Claude Code session-team registration"* ]]
}

@test "session-start: dot-command after an embedded single quote still cannot execute" {
  enable_st
  local sentinel="$TEST_SKILL_DIR/injection-sentinel-quote"
  rm -f "$sentinel"
  run bash "$SCRIPTS/session-start.sh" claude-code "$PROJ" <<EOF
{"session_id":"sess-DOT-quote'",
.shell touch $sentinel
"x":"y"}
EOF
  [ "$status" -eq 0 ]
  [ ! -f "$sentinel" ]
  [[ "$output" == *"refusing Claude Code session-team registration"* ]]
}

@test "session-start: exploit-shaped payload (CTE-closing dot-command) is rejected" {
  enable_st
  local sentinel="$TEST_SKILL_DIR/injection-sentinel-exploit"
  rm -f "$sentinel"
  # Closes the raw(j) CTE with the embedded quote, appends a syntactically
  # complete statement ending in `;`, then a line starting with `.` — the
  # shape sqlite3 stdin mode needs to leave the string literal and run a
  # dot-command (verified to execute when escaping is removed, see the
  # negative-control test below). Uses `.output` (a sqlite3 built-in) rather
  # than `.shell touch` so the probe has no dependency on an external `touch`
  # binary being on PATH.
  run bash "$SCRIPTS/session-start.sh" claude-code "$PROJ" <<EOF
{"session_id":"x'),z(a) AS (SELECT 1) SELECT 1;
.output $sentinel
SELECT 1;
","y":"y"}
EOF
  [ "$status" -eq 0 ]
  [ ! -f "$sentinel" ]
  [[ "$output" == *"refusing Claude Code session-team registration"* ]]
}

@test "session-start: exploit-shaped payload executes once escaping is removed (negative control)" {
  enable_st
  local sentinel="$TEST_SKILL_DIR/injection-sentinel-negctl"
  rm -f "$sentinel"
  local match_count line_no orig_line mutant
  match_count="$(grep -c '_claude_input_sql=' "$SCRIPTS/session-start.sh")"
  # Fails closed (instead of silently mutating the wrong line) if the
  # escaping call moved, was renamed, or was duplicated.
  [ "$match_count" -eq 1 ]
  line_no="$(grep -n '_claude_input_sql=' "$SCRIPTS/session-start.sh" | cut -d: -f1)"
  orig_line="$(sed -n "${line_no}p" "$SCRIPTS/session-start.sh")"
  [[ "$orig_line" == *"sed \"s/'/''/g\""* ]]
  mutant="$SCRIPTS/session-start-mutant.sh"
  # The real line is `if ! _claude_input_sql="$(... | sed ...)"; then`,
  # followed by a reject-and-exit body and `fi`. Replacing just this line
  # with a bare assignment would leave that `then`/`fi` dangling (syntax
  # error); replacing it with `if false; then` would skip the reject body
  # but also skip the assignment itself. Doing the assignment first, then
  # opening an always-false `if`, keeps both: escaping is disabled AND the
  # reject body stays unreachable.
  sed "${line_no}s#.*#  _claude_input_sql=\"\$(printf '%s' \"\$INPUT\" | cat)\"; if false; then#" \
    "$SCRIPTS/session-start.sh" > "$mutant"
  chmod +x "$mutant"

  run bash "$mutant" claude-code "$PROJ" <<EOF
{"session_id":"x'),z(a) AS (SELECT 1) SELECT 1;
.output $sentinel
SELECT 1;
","y":"y"}
EOF
  # Proves the positive test above actually detects an escaping regression,
  # rather than being rejected by json_valid for unrelated reasons.
  [ -f "$sentinel" ]
}

@test "session-start: a NUL byte inside session_id is rejected, not silently truncated" {
  enable_st
  # SQLite's length()/GLOB predicates stop at the first NUL, so if the CLI or
  # bash forwarded bytes after it unfiltered, this would smuggle a path
  # traversal past the allowlist. \u0000 is valid JSON; sqlite3's json1
  # decodes it to a real NUL byte.
  run bash "$SCRIPTS/session-start.sh" claude-code "$PROJ" \
    <<< '{"session_id":"a\u0000/../../tmp/evil"}'
  [ "$status" -eq 0 ]
  [ ! -d "$TEST_SKILL_DIR/teams/s-a" ]
  [[ "$output" == *"refusing Claude Code session-team registration"* ]]
}

@test "session-start: path-separator and traversal shapes in session_id are rejected" {
  enable_st
  local payload
  for payload in '{"session_id":"../../tmp/x"}' '{"session_id":"a/b"}' \
    '{"session_id":"a\\\\b"}'; do
    run bash "$SCRIPTS/session-start.sh" claude-code "$PROJ" <<< "$payload"
    [ "$status" -eq 0 ]
    [[ "$output" == *"refusing Claude Code session-team registration"* ]]
  done
}

@test "session-start: an over-length session_id is rejected" {
  enable_st
  local long_sid payload
  long_sid="$(printf '%*s' 200 '' | tr ' ' a)"
  payload="{\"session_id\":\"$long_sid\"}"
  run bash "$SCRIPTS/session-start.sh" claude-code "$PROJ" <<< "$payload"
  [ "$status" -eq 0 ]
  [[ "$output" == *"refusing Claude Code session-team registration"* ]]
  run bash -c "ls -d '$TEST_SKILL_DIR'/teams/s-a* 2>/dev/null"
  [ -z "$output" ]
}

@test "session-start: session_id length boundary — 128 accepted, 129 rejected" {
  enable_st
  local sid128 sid129
  sid128="$(printf '%*s' 128 '' | tr ' ' a)"
  sid129="$(printf '%*s' 129 '' | tr ' ' a)"

  run bash "$SCRIPTS/session-start.sh" claude-code "$PROJ" <<< "{\"session_id\":\"$sid128\"}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"--team s-$sid128"* ]]

  run bash "$SCRIPTS/session-start.sh" claude-code "$PROJ" <<< "{\"session_id\":\"$sid129\"}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"refusing Claude Code session-team registration"* ]]
}

@test "session-start: a sed failure in the pre-gate SESSION_ID extraction does not kill the script via errexit" {
  # Regression guard: the pre-gate SESSION_ID extraction (shared by every
  # type, not just claude-code) used to be a bare `sed | head` assignment.
  # Originally this was tested with a real malformed-UTF-8 byte, reproduced
  # against the macOS system sed. But this repo's tests run under nix's
  # GNU sed 4.9, which does NOT fail on that byte (verified directly) — a
  # real malformed-byte payload exercises nothing here, so the sed call is
  # stubbed to fail directly instead. Only the session_id-matching sed
  # invocation fails; the gate's own sed calls (which don't match this
  # pattern) still run normally.
  enable_st
  local stub_bin="$TEST_SKILL_DIR/no-sed-sessionid-bin" real_sed
  mkdir -p "$stub_bin"
  real_sed="$(command -v sed)"
  cat > "$stub_bin/sed" <<STUB
#!/usr/bin/env bash
for arg in "\$@"; do
  case "\$arg" in
    *'"session_id"'*) exit 1 ;;
  esac
done
exec "$real_sed" "\$@"
STUB
  chmod +x "$stub_bin/sed"

  # An invalid charset (space) makes the gate itself reject independent of
  # whether pre-gate extraction succeeded, so the asserts below hold either
  # way — what this test actually pins down is that the stubbed sed failure
  # doesn't crash the script before reaching that gate.
  run env PATH="$stub_bin:$PATH" bash "$SCRIPTS/session-start.sh" claude-code "$PROJ" \
    <<< '{"session_id":"in valid"}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"refusing Claude Code session-team registration"* ]]
  run bash -c "ls -d '$TEST_SKILL_DIR'/teams/s-* 2>/dev/null"
  [ -z "$output" ]
}

@test "session-start: a sed failure in the cwd extraction does not kill the script via errexit (unconditional path)" {
  # Same regression class as the session_id test above, for the cwd
  # extraction. Unlike session_id, this one runs for every type/mode with
  # no gate downstream to converge on a guaranteed rejection, so this test
  # only pins "doesn't crash" (status 0), not a specific outcome. Same GNU
  # sed caveat as above: stub the cwd-matching sed call to fail directly
  # rather than relying on a real malformed byte.
  #
  # Without a joined pair, PAIRS and SESSION_TEAM are both empty and the
  # script exits early (before the cwd extraction this test targets) —
  # join first so execution actually reaches that code.
  bash "$SCRIPTS/join.sh" base alice claude-code "$PROJ" >/dev/null
  # Also fails the path-normalization sed (`s#//*#/#g`), unique to this one
  # call site, so the `|| HOOK_CWD_NORM="$HOOK_CWD"` guard gets teeth too —
  # not just the extraction guard above it.
  local stub_bin="$TEST_SKILL_DIR/no-sed-cwd-bin" real_sed
  mkdir -p "$stub_bin"
  real_sed="$(command -v sed)"
  cat > "$stub_bin/sed" <<STUB
#!/usr/bin/env bash
for arg in "\$@"; do
  case "\$arg" in
    *'"cwd"'*|*'s#//*#/#g'*) exit 1 ;;
  esac
done
exec "$real_sed" "\$@"
STUB
  chmod +x "$stub_bin/sed"

  run env PATH="$stub_bin:$PATH" bash "$SCRIPTS/session-start.sh" claude-code "$PROJ" \
    <<< '{"session_id":"sess-OK","cwd":"/some/path"}'
  [ "$status" -eq 0 ]
}

@test "session-start: a raw NUL byte in stdin (not JSON-escaped) is rejected" {
  enable_st
  # Unlike the earlier \u0000 JSON-escape test above, this NUL is a literal byte in
  # the hook's stdin. bash's own $(cat) command substitution silently drops
  # it and splices "a" and "b" together, so by the time INPUT is built the
  # NUL is already gone — instr(sid, char(0)) never sees it. Only stripping
  # NUL bytes from the saved raw file and comparing its length before/after
  # catches this (comparing against INPUT's length would false-positive on
  # any trailing newline, which $(...) also strips).
  local payload_file="$TEST_SKILL_DIR/raw-nul-payload.json"
  printf '{"session_id":"a' > "$payload_file"
  printf '\0' >> "$payload_file"
  printf 'b"}' >> "$payload_file"
  run bash "$SCRIPTS/session-start.sh" claude-code "$PROJ" < "$payload_file"
  [ "$status" -eq 0 ]
  [ ! -d "$TEST_SKILL_DIR/teams/s-ab" ]
  [[ "$output" == *"refusing Claude Code session-team registration"* ]]
}

@test "session-start: a sed failure while building the SQL literal fails closed with a message" {
  # Same regression class as the wc test below, for the sibling bare
  # assignment (_claude_input_sql) that had the identical errexit exposure.
  # session-start.sh calls sed elsewhere too (the session_id/sessionId
  # extraction above the gate), so the stub only fails the specific
  # escaping invocation and delegates everything else to the real sed —
  # otherwise this would test that earlier, unrelated sed call instead.
  enable_st
  local stub_bin="$TEST_SKILL_DIR/no-sed-bin" real_sed
  mkdir -p "$stub_bin"
  real_sed="$(command -v sed)"
  cat > "$stub_bin/sed" <<STUB
#!/usr/bin/env bash
for arg in "\$@"; do
  case "\$arg" in
    *"s/'/''/g"*) exit 1 ;;
  esac
done
exec "$real_sed" "\$@"
STUB
  chmod +x "$stub_bin/sed"

  run env PATH="$stub_bin:$PATH" bash "$SCRIPTS/session-start.sh" claude-code "$PROJ" \
    <<< '{"session_id":"sess-SEDFAIL"}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"refusing Claude Code session-team registration"* ]]
}

@test "session-start: a wc failure in the byte-count check fails closed with a message, not a silent errexit" {
  # Regression guard: an earlier version of this check was a bare
  # `x="$(wc ... | tr ...)"` assignment, which under set -e -o pipefail dies
  # right there on a wc/tr failure with NO message and a non-zero exit —
  # the digit-string checks below it would never even run.
  enable_st
  local stub_bin="$TEST_SKILL_DIR/no-wc-bin"
  mkdir -p "$stub_bin"
  cat > "$stub_bin/wc" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
  chmod +x "$stub_bin/wc"

  run env PATH="$stub_bin:$PATH" bash "$SCRIPTS/session-start.sh" claude-code "$PROJ" \
    <<< '{"session_id":"sess-WCFAIL"}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"refusing Claude Code session-team registration"* ]]
}

@test "session-start: mktemp failure fails closed, not falling back to the NUL-blind read" {
  enable_st
  local stub_bin="$TEST_SKILL_DIR/no-mktemp-bin"
  mkdir -p "$stub_bin"
  cat > "$stub_bin/mktemp" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
  chmod +x "$stub_bin/mktemp"

  local payload_file="$TEST_SKILL_DIR/raw-nul-payload-mktempfail.json"
  printf '{"session_id":"a' > "$payload_file"
  printf '\0' >> "$payload_file"
  printf 'b"}' >> "$payload_file"

  run env PATH="$stub_bin:$PATH" bash "$SCRIPTS/session-start.sh" claude-code "$PROJ" < "$payload_file"
  [ "$status" -eq 0 ]
  [ ! -d "$TEST_SKILL_DIR/teams/s-ab" ]
  [[ "$output" == *"refusing Claude Code session-team registration"* ]]
}

@test "session-start: no leftover temp file after a rejection or a normal run" {
  enable_st
  local before after

  run bash "$SCRIPTS/session-start.sh" claude-code "$PROJ" <<< '{"session_id":"sess-CLEANUP"}'
  [ "$status" -eq 0 ]
  before="$(find "$TEST_SKILL_DIR/run" -maxdepth 1 -name 'agmsg-hookin.*' 2>/dev/null | wc -l | tr -d '[:space:]')"
  [ "$before" -eq 0 ]

  run bash "$SCRIPTS/session-start.sh" claude-code "$PROJ" <<< '{"session_id":".rejected"}'
  [ "$status" -eq 0 ]
  after="$(find "$TEST_SKILL_DIR/run" -maxdepth 1 -name 'agmsg-hookin.*' 2>/dev/null | wc -l | tr -d '[:space:]')"
  [ "$after" -eq 0 ]
}

@test "session-start: non-claude-code and mode-off types never write a hook-input temp file" {
  # The temp-file capture (and its disk-write side effect) is scoped to the
  # claude-code + session-team-mode-on gate only — codex/mode-off must keep
  # the plain, no-disk-write read.
  run bash "$SCRIPTS/session-start.sh" codex "$PROJ" <<< '{"sessionId":"sess-CODEX"}'
  [ "$status" -eq 0 ]
  run bash -c "find '$TEST_SKILL_DIR/run' -maxdepth 1 -name 'agmsg-hookin.*' 2>/dev/null"
  [ -z "$output" ]

  run bash "$SCRIPTS/session-start.sh" claude-code "$PROJ" <<< '{"session_id":"sess-MODEOFF"}'
  [ "$status" -eq 0 ]
  run bash -c "find '$TEST_SKILL_DIR/run' -maxdepth 1 -name 'agmsg-hookin.*' 2>/dev/null"
  [ -z "$output" ]
}

@test "session-start: without the raw-byte-count check, a raw NUL would smuggle bytes past instr() (negative control)" {
  enable_st
  local match_count line_no mutant payload_file
  match_count="$(grep -c '_claude_raw_len" != "' "$SCRIPTS/session-start.sh")"
  # Fails closed (instead of silently mutating the wrong line) if this
  # check moved, was renamed, or was duplicated.
  [ "$match_count" -eq 1 ]
  line_no="$(grep -n '_claude_raw_len" != "' "$SCRIPTS/session-start.sh" | cut -d: -f1)"
  mutant="$SCRIPTS/session-start-mutant-rawlen.sh"
  sed "${line_no}s#.*#    if false; then#" "$SCRIPTS/session-start.sh" > "$mutant"
  chmod +x "$mutant"

  payload_file="$TEST_SKILL_DIR/raw-nul-payload-negctl.json"
  printf '{"session_id":"a' > "$payload_file"
  printf '\0' >> "$payload_file"
  printf 'b"}' >> "$payload_file"
  run bash "$mutant" claude-code "$PROJ" < "$payload_file"
  # Proves the positive test above actually detects the raw-NUL regression,
  # rather than being rejected by some unrelated check.
  [ -d "$TEST_SKILL_DIR/teams/s-ab" ]
}

@test "session-start: mode off, claude-code SessionStart is unaffected by the gate" {
  # Regression guard for the default (session-team mode off) configuration:
  # the gate must not fire, and legacy behavior must be unchanged.
  run env CLAUDE_CODE_SESSION_ID=sess-DEFAULT bash "$SCRIPTS/session-start.sh" \
    claude-code "$PROJ" <<< '{"session_id":"sess-DEFAULT"}'
  [ "$status" -eq 0 ]
  [[ "$output" != *"refusing Claude Code session-team registration"* ]]
  [[ "$output" != *"--team s-"* ]]
}

@test "session-start: env-only Claude session id is rejected before registration" {
  enable_st
  run env CLAUDE_CODE_SESSION_ID=sess-OTHER \
    bash "$SCRIPTS/session-start.sh" claude-code "$PROJ" </dev/null
  [ "$status" -eq 0 ]
  [ ! -d "$TEST_SKILL_DIR/teams/s-sess-OTHER" ]
  [[ "$output" == *"refusing Claude Code session-team registration"* ]]
  [[ "$output" != *"sess-OTHER"* ]]
}

@test "session-start: rejected env-only id skips stale session-team TTL GC" {
  enable_st
  mkdir -p "$TEST_SKILL_DIR/teams/s-victim"
  printf '%s\n' '{"name":"s-victim","agents":{}}' \
    > "$TEST_SKILL_DIR/teams/s-victim/config.json"
  touch -t 202501010000 "$TEST_SKILL_DIR/teams/s-victim" \
    "$TEST_SKILL_DIR/teams/s-victim/config.json"

  run env CLAUDE_CODE_SESSION_ID=sess-OTHER \
    bash "$SCRIPTS/session-start.sh" claude-code "$PROJ" </dev/null
  [ "$status" -eq 0 ]
  [ -d "$TEST_SKILL_DIR/teams/s-victim" ]
}

@test "session-start: camelCase sessionId is rejected for Claude session teams" {
  enable_st
  run bash "$SCRIPTS/session-start.sh" claude-code "$PROJ" \
    <<< '{"sessionId":"cursorCamel"}'
  [ "$status" -eq 0 ]
  [ ! -d "$TEST_SKILL_DIR/teams/s-cursorCamel" ]
  [[ "$output" == *"refusing Claude Code session-team registration"* ]]
}

@test "session-start: snake_case wins over camelCase and inherited env" {
  enable_st
  run env CLAUDE_CODE_SESSION_ID=sess-ENV \
    bash "$SCRIPTS/session-start.sh" claude-code "$PROJ" \
    <<< '{"session_id":"sess-REAL","sessionId":"cursorCamel"}'
  [ "$status" -eq 0 ]
  [ -d "$TEST_SKILL_DIR/teams/s-sess-REAL" ]
  [ ! -d "$TEST_SKILL_DIR/teams/s-sess-ENV" ]
  [ ! -d "$TEST_SKILL_DIR/teams/s-cursorCamel" ]
  [[ "$output" == *"--team s-sess-REAL"* ]]
  [[ "$output" != *"sess-ENV"* ]]
  [[ "$output" != *"cursorCamel"* ]]
}

@test "session-start: rejected payload skips hygiene for stale pidfiles and actas locks" {
  enable_st
  mkdir -p "$TEST_SKILL_DIR/run"
  printf '%s\n' 999999 > "$TEST_SKILL_DIR/run/watch.stale.pid"
  printf '%s\n' sess-OTHER > "$TEST_SKILL_DIR/run/actas.s-victim__claude.session"

  run env CLAUDE_CODE_SESSION_ID=sess-OTHER \
    bash "$SCRIPTS/session-start.sh" claude-code "$PROJ" </dev/null
  [ "$status" -eq 0 ]
  [ -f "$TEST_SKILL_DIR/run/watch.stale.pid" ]
  [ -f "$TEST_SKILL_DIR/run/actas.s-victim__claude.session" ]
}

@test "session-start: malformed and non-string session_id payloads fail closed" {
  enable_st
  mkdir -p "$TEST_SKILL_DIR/teams/s-victim"
  printf '%s\n' '{"name":"s-victim","agents":{}}' \
    > "$TEST_SKILL_DIR/teams/s-victim/config.json"
  touch -t 202501010000 "$TEST_SKILL_DIR/teams/s-victim" \
    "$TEST_SKILL_DIR/teams/s-victim/config.json"

  local payload
  for payload in '{}' '{' '{"session_id":""}' '{"session_id":null}' \
    '{"session_id":42}' '{"nested":{"session_id":"nested-only"}}'; do
    run env CLAUDE_CODE_SESSION_ID=sess-ENV \
      bash "$SCRIPTS/session-start.sh" claude-code "$PROJ" <<< "$payload"
    [ "$status" -eq 0 ]
    [[ "$output" == *"refusing Claude Code session-team registration"* ]]
    [[ "$output" != *"sess-ENV"* ]]
    [[ "$output" != *"nested-only"* ]]
  done
  [ ! -d "$TEST_SKILL_DIR/teams/s-sess-ENV" ]
  [ -d "$TEST_SKILL_DIR/teams/s-victim" ]
}

@test "session-start: a genuinely absent session_id makes NO synthetic session team" {
  enable_st
  env -u CLAUDE_CODE_SESSION_ID bash -c 'printf "{}" | bash "'"$SCRIPTS"'/session-start.sh" claude-code "'"$PROJ"'"' >/dev/null 2>&1 || true
  # No s-unknown-* team fabricated; the rejected hook must not scan or register.
  run bash -c "ls -d '$TEST_SKILL_DIR'/teams/s-unknown-* 2>/dev/null"
  [ -z "$output" ]
}

@test "delivery monitor: joins and pins the current session team mid-session" {
  enable_st

  run env CLAUDE_CODE_SESSION_ID=sess-MID bash "$SCRIPTS/delivery.sh" set monitor claude-code "$PROJ"
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude --team s-sess-MID"* ]]

  run bash "$SCRIPTS/identities.sh" "$PROJ" claude-code
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude"* ]]
}

@test "session-end: keeps the codex worker if a parallel-resume sibling is alive" {
  enable_st
  test_fixture_start_reaped_process sleep 300
  local fake="$TEST_REAPED_PID"
  mkdir -p "$TEST_SKILL_DIR/run"
  printf 'pid:%s\t%s\tcodex\n' "$fake" "/tmp/scratch-sib" > "$TEST_SKILL_DIR/run/spawn.s-sessSIB__codex"
  # A live sibling instance of the SAME bare session (different pid).
  test_fixture_start_reaped_process sleep 300
  local sib="$TEST_REAPED_PID"
  printf 'sessSIB.%s\n' "$sib" > "$TEST_SKILL_DIR/run/cc-instance.$sib"
  agmsg_test_start_session_owner
  printf '{"session_id":"sessSIB"}' | bash "$SCRIPTS/session-end.sh" claude-code "$PROJ"
  agmsg_test_stop_session_owner
  # Retained negative window: sibling preservation has no completion artifact
  # to poll, so keep one watchdog cadence before asserting survival.
  sleep 1
  kill -0 "$fake" 2>/dev/null                          # NOT torn down (sibling alive)
  kill "$fake" "$sib" 2>/dev/null || true
}

@test "session-end: no teardown when session-team mode is off" {
  sleep 30 & local fake=$!
  mkdir -p "$TEST_SKILL_DIR/run"
  printf 'pid:%s\t%s\tcodex\n' "$fake" "/tmp/scratch-off" > "$TEST_SKILL_DIR/run/spawn.s-sessOFF__codex"
  printf '{"session_id":"sessOFF"}' | bash "$SCRIPTS/session-end.sh" claude-code "$PROJ"
  kill -0 "$fake" 2>/dev/null                                    # untouched
  kill "$fake" 2>/dev/null || true
}

@test "session-start: orphan-codex GC reports a bridge whose owner session is unverified" {
  enable_st
  # Report-only GC must leave the process and placement alone. A plain sleep is
  # enough: nix coreutils is a multicall binary, so `exec -a` with a bridge
  # argv0 makes `sleep` exit immediately (`unknown program`).
  test_fixture_start_reaped_process sleep 300
  local fake="$TEST_REAPED_PID"
  mkdir -p "$TEST_SKILL_DIR/run"
  printf 'pid:%s\t%s\tcodex\n' "$fake" "/tmp/scratch-gc" > "$TEST_SKILL_DIR/run/spawn.s-DEADCA__codex"
  printf 'pid=%s\nidentities=s-DEADCA/codex\ntype=codex\n' "$fake" > "$TEST_SKILL_DIR/run/codex-bridge.s-DEADCA.codex.meta"
  # A live (different) session start runs the GC pass.
  run bash -c "printf '{\"session_id\":\"sess-gc-self\"}' | bash '$SCRIPTS/session-start.sh' claude-code '$PROJ'"
  [ "$status" -eq 0 ]
  kill -0 "$fake" 2>/dev/null
  [ -f "$TEST_SKILL_DIR/run/spawn.s-DEADCA__codex" ]
  [[ "$output" == *"agmsg: orphan candidate team=s-DEADCA worker=codex bridge_pid=$fake spawn_age_s="* ]]
  kill "$fake" 2>/dev/null || true
}

# --- PR3: stale session-team TTL GC ------------------------------------------

@test "session-start: TTL GC reaps a stale (old + dead-owner) session team, keeps recent" {
  enable_st
  # Old + dead owner → reaped.
  mkdir -p "$TEST_SKILL_DIR/teams/s-OLDGC"
  echo '{"name":"s-OLDGC","agents":{}}' > "$TEST_SKILL_DIR/teams/s-OLDGC/config.json"
  touch -t 202501010000 "$TEST_SKILL_DIR/teams/s-OLDGC/config.json" "$TEST_SKILL_DIR/teams/s-OLDGC"
  # Recent (dead owner but fresh mtime) → kept.
  mkdir -p "$TEST_SKILL_DIR/teams/s-RECENTGC"
  echo '{"name":"s-RECENTGC","agents":{}}' > "$TEST_SKILL_DIR/teams/s-RECENTGC/config.json"

  printf '{"session_id":"sess-ttl-self"}' | bash "$SCRIPTS/session-start.sh" claude-code "$PROJ" >/dev/null 2>&1 || true

  [ ! -d "$TEST_SKILL_DIR/teams/s-OLDGC" ]      # old + dead → reaped
  [ -d "$TEST_SKILL_DIR/teams/s-RECENTGC" ]     # too recent → kept
}
