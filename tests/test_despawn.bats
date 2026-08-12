#!/usr/bin/env bats

# Tests for despawn (#109): a leader tears down a spawned member. Graceful path
# is watcher-driven (watch.sh sees ctrl:despawn, drops its own role); --force is
# leader-driven from the recorded placement.

load test_helper

setup() {
  setup_test_env
  # Never inherit a real herdr environment from the test runner. A watcher
  # started here that keeps the host's HERDR_PANE_ID will, on ctrl:despawn,
  # close the developer's own pane — the suite kills the session running it.
  # This belongs in setup, not on individual watch.sh launches: guarding each
  # launch site means every test added later has to remember, and one that
  # did not (the #439 read_at test, added after this file first grew herdr
  # awareness) is exactly how a real host pane got closed.
  unset HERDR_ENV HERDR_PANE_ID HERDR_WORKSPACE_ID
  export PROJ="/tmp/agmsg-despawn-proj"
  export RUN="$TEST_SKILL_DIR/run"
  mkdir -p "$RUN"
  # shellcheck disable=SC1091
  source "$SCRIPTS/lib/identity-key.sh"
}

teardown() {
  teardown_test_env
}

@test "despawn: graceful — ctrl:despawn makes the member drop its role" {
  bash "$SCRIPTS/join.sh" team alice claude-code "$PROJ" >/dev/null
  bash "$SCRIPTS/join.sh" team leader claude-code "$PROJ" >/dev/null
  # Make the member session look alive so the leader sees a live lock to wait on.
  setup_live_owner "$RUN" sess-m

  # Unset TMUX_PANE and HERDR_PANE_ID: the ctrl:despawn handler runs
  # `tmux kill-pane` / `herdr pane close`, and a watcher launched from inside
  # the developer's environment would inherit the REAL pane id and close the
  # session running the tests. With both empty, the handler takes the "close
  # manually" branch — role-drop is still asserted.
  AGMSG_WATCH_INTERVAL=1 env -u TMUX_PANE -u HERDR_PANE_ID -u HERDR_ENV \
    bash "$SCRIPTS/watch.sh" sess-m "$PROJ" claude-code alice \
    >/dev/null 2>&1 3>&- &
  local wpid=$!
  # Wait for the watcher to attach (it claims the lock + writes the ready sentinel).
  wait_for_file "$RUN/ready.team__alice"
  [ -e "$RUN/ready.team__alice" ]
  [ -f "$RUN/actas.team__alice.session" ]

  run bash "$SCRIPTS/despawn.sh" team leader alice --timeout 10
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=ok"* ]]

  # Member dropped its role: lock released and registration gone.
  [ ! -f "$RUN/actas.team__alice.session" ]
  run bash "$SCRIPTS/identities.sh" "$PROJ" claude-code
  [[ "$output" != *alice* ]]

  kill "$wpid" 2>/dev/null || true; wait "$wpid" 2>/dev/null || true
}

# read_at for the most recent message with the given body, empty if unread.
_read_at_for_body() {
  ( # shellcheck disable=SC1090
    source "$SCRIPTS/lib/storage.sh"
    agmsg_sqlite "$(agmsg_db_path)" \
      "SELECT read_at FROM messages WHERE body='$1' ORDER BY id DESC LIMIT 1;" )
}

@test "despawn: graceful — ctrl:despawn control row is marked read (does not linger as unread)" {
  bash "$SCRIPTS/join.sh" team alice claude-code "$PROJ" >/dev/null
  bash "$SCRIPTS/join.sh" team leader claude-code "$PROJ" >/dev/null
  setup_live_owner "$RUN" sess-m

  AGMSG_WATCH_INTERVAL=1 env -u TMUX_PANE bash "$SCRIPTS/watch.sh" sess-m "$PROJ" claude-code alice \
    >/dev/null 2>&1 3>&- &
  local wpid=$!
  wait_for_file "$RUN/ready.team__alice"
  [ -e "$RUN/ready.team__alice" ]

  run bash "$SCRIPTS/despawn.sh" team leader alice --timeout 10
  [ "$status" -eq 0 ]

  # The ctrl:despawn row itself must not be left permanently unread — a
  # broad (non-actas) watcher that later scans this project's inbox must not
  # see it resurface as a "new" message (2026-07-19 review finding).
  [ -n "$(_read_at_for_body "ctrl:despawn")" ]

  kill "$wpid" 2>/dev/null || true; wait "$wpid" 2>/dev/null || true
}

@test "despawn --force: kills recorded placement and drops registration without the member" {
  bash "$SCRIPTS/join.sh" team alice claude-code "$PROJ" >/dev/null
  # Placement as spawn would have recorded it (pane %99 doesn't exist; kill is
  # best-effort/no-op here — we assert the registration + lock + record effects).
  printf '%s\t%s\t%s\n' '%99' "$PROJ" claude-code > "$RUN/spawn.team__alice"
  printf 'somesid\n' > "$RUN/actas.team__alice.session"

  run bash "$SCRIPTS/despawn.sh" team leader alice --force
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=forced"* ]]
  [ ! -f "$RUN/spawn.team__alice" ]                 # placement record cleaned
  [ ! -f "$RUN/actas.team__alice.session" ]         # lock released
  run bash "$SCRIPTS/identities.sh" "$PROJ" claude-code
  [[ "$output" != *alice* ]]                        # registration dropped
}

@test "despawn --force: errors when there is no placement record" {
  bash "$SCRIPTS/join.sh" team alice claude-code "$PROJ" >/dev/null
  run bash "$SCRIPTS/despawn.sh" team leader alice --force
  [ "$status" -ne 0 ]
  [[ "$output" =~ "no placement record" ]]
}

@test "despawn: times out (exit 3) when the member never drops" {
  bash "$SCRIPTS/join.sh" team alice claude-code "$PROJ" >/dev/null
  bash "$SCRIPTS/join.sh" team leader claude-code "$PROJ" >/dev/null
  setup_live_owner "$RUN" sess-m
  printf 'sess-m\n' > "$RUN/actas.team__alice.session"   # held live, no watcher to act

  run bash "$SCRIPTS/despawn.sh" team leader alice --timeout 2
  [ "$status" -eq 3 ]
  [[ "$output" == *"status=timeout"* ]]
}

@test "despawn: a broad (non-actas) watcher ignores ctrl:despawn and does not self-destruct" {
  # Regression for the self-kill bug: a leader's default watcher subscribes to
  # EVERY project role. If it acted on a ctrl:despawn addressed to one of them,
  # it would run `tmux kill-pane -t $TMUX_PANE` against the leader's OWN pane and
  # take down the leader session. A broad watcher must skip the control message.
  bash "$SCRIPTS/join.sh" team alice claude-code "$PROJ" >/dev/null
  bash "$SCRIPTS/join.sh" team leader claude-code "$PROJ" >/dev/null
  bash "$SCRIPTS/join.sh" team boss claude-code "$PROJ" >/dev/null

  # Broad watcher (no actas arg) — subscribes to both alice and leader.
  AGMSG_WATCH_INTERVAL=1 env -u TMUX_PANE -u HERDR_PANE_ID -u HERDR_ENV \
    bash "$SCRIPTS/watch.sh" sess-broad "$PROJ" claude-code \
    >/dev/null 2>&1 3>&- &
  local wpid=$!
  wait_until 10 kill -0 "$wpid"

  # Deliver a despawn aimed at alice straight into the stream.
  bash "$SCRIPTS/send.sh" team boss alice "ctrl:despawn" >/dev/null
  # Retained negative window: no completion event exists to poll; this must
  # exceed the watcher's one-second cadence before asserting it stayed alive.
  sleep 2

  kill -0 "$wpid" 2>/dev/null            # watcher still alive — did NOT self-destruct
  run bash "$SCRIPTS/identities.sh" "$PROJ" claude-code
  [[ "$output" == *alice* ]]             # broad watcher did not drop alice's role

  kill "$wpid" 2>/dev/null || true; wait "$wpid" 2>/dev/null || true
}

@test "despawn: graceful no-op when the member holds no live lock (e.g. codex)" {
  bash "$SCRIPTS/join.sh" team alice codex "$PROJ" >/dev/null
  run bash "$SCRIPTS/despawn.sh" team leader alice
  [ "$status" -eq 0 ]
  [[ "$output" == *"no-live-lock"* ]]
}
# --- headless codex worker (pid:<n> placement) ---

@test "despawn: headless codex (pid: placement) is force-torn-down on a graceful call" {
  bash "$SCRIPTS/join.sh" team rev codex "$PROJ" >/dev/null
  # Stand-in for the bridge worker.
  test_fixture_start_reaped_process sleep 300
  local dummy="$TEST_REAPED_PID"
  printf 'pid:%s\t%s\t%s\n' "$dummy" "$PROJ" codex > "$RUN/spawn.team__rev"
  printf 'pid=%s\nteam=team\nname=rev\ntype=codex\n' "$dummy" > "$RUN/codex-bridge.team.rev.meta"

  run bash "$SCRIPTS/despawn.sh" team leader rev    # graceful → auto-promotes to force
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=forced"* ]]
  ! kill -0 "$dummy" 2>/dev/null                    # bridge stand-in was killed
  [ ! -f "$RUN/spawn.team__rev" ]                   # placement record cleaned
  kill "$dummy" 2>/dev/null || true; wait "$dummy" 2>/dev/null || true
}

@test "despawn: skips kill when recorded pid disagrees with bridge meta (PID-reuse guard)" {
  bash "$SCRIPTS/join.sh" team rev codex "$PROJ" >/dev/null
  sleep 300 &
  local dummy=$!
  printf 'pid:%s\t%s\t%s\n' "$dummy" "$PROJ" codex > "$RUN/spawn.team__rev"
  # meta records a different pid → the recorded pid is treated as stale.
  printf 'pid=%s\nteam=team\nname=rev\ntype=codex\n' 999999 > "$RUN/codex-bridge.team.rev.meta"

  run bash "$SCRIPTS/despawn.sh" team leader rev
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipping kill"* ]]
  kill -0 "$dummy" 2>/dev/null                       # NOT killed
  kill "$dummy" 2>/dev/null || true; wait "$dummy" 2>/dev/null || true
}

@test "despawn: a longer identity-key prefix never authorizes killing another worker" {
  # tt<TAB>aaa is 6 bytes and tt<TAB>aaabbb is 9, so the old un-terminated
  # base64 keys were prefix-related with no padding boundary.
  local legacy_short legacy_long long_key
  legacy_short="$(printf '%s\t%s' tt aaa | base64 | tr -d '\r\n' | tr '+/' '-_')"
  legacy_long="$(printf '%s\t%s' tt aaabbb | base64 | tr -d '\r\n' | tr '+/' '-_')"
  [[ "$legacy_short" != *"="* ]]
  [[ "$legacy_long" == "$legacy_short"* ]]
  long_key="$(agmsg_identity_key tt aaabbb)"

  bash "$SCRIPTS/join.sh" tt aaa codex "$PROJ" >/dev/null
  sleep 300 &
  local survivor=$!
  printf 'pid:%s\t%s\tcodex\n' "$survivor" "$PROJ" > "$RUN/spawn.tt__aaa"

  local stub_bin="$TEST_SKILL_DIR/despawn-prefix-stub"
  mkdir -p "$stub_bin"
  cat > "$stub_bin/ps" <<'STUB'
#!/usr/bin/env bash
if [ "$*" = "-ww -o args= -p $SURVIVOR_PID" ]; then
  printf 'node /x/codex-bridge.js --identity-key %s --pair tt\\taaabbb\n' \
    "$LONG_IDENTITY_KEY"
  exit 0
fi
exit 1
STUB
  chmod +x "$stub_bin/ps"

  run env PATH="$stub_bin:$PATH" SURVIVOR_PID="$survivor" \
    LONG_IDENTITY_KEY="$long_key" \
    bash "$SCRIPTS/despawn.sh" tt leader aaa --force
  [ "$status" -eq 4 ]
  printf '%s\n' "$output" | grep -q '^status=unverified '
  [ -e "$RUN/spawn.tt__aaa" ]
  kill -0 "$survivor" 2>/dev/null
  kill "$survivor" 2>/dev/null || true
  wait "$survivor" 2>/dev/null || true
}

@test "despawn --force --expect-record: skips when the live record changed (race guard)" {
  # The detached SessionEnd teardown snapshots the spawn record at hook time. If a
  # fast lazy-respawn replaces it before the teardown runs, --expect-record must
  # make despawn no-op rather than tear down the fresh worker / drop its record.
  sleep 300 & local survivor=$!
  printf 'pid:%s\t%s\tcodex\n' "$survivor" "$PROJ" > "$RUN/spawn.team__codex"  # fresh respawn record
  local stale; stale="$(printf 'pid:%s\t%s\tcodex' 999999 /old/cwd)"           # caller's stale snapshot
  # The fresh worker's persistent bridge state must survive the skipped teardown.
  printf 'x\n' > "$RUN/codex-bridge.team.codex.outbound.json"

  run bash "$SCRIPTS/despawn.sh" team leader codex --force --expect-record "$stale"
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=skipped"* ]]
  [[ "$output" == *"reason=record-changed"* ]]
  [ -f "$RUN/spawn.team__codex" ]                    # fresh record retained
  [ -f "$RUN/codex-bridge.team.codex.outbound.json" ]  # bridge state retained too
  kill -0 "$survivor" 2>/dev/null                    # fresh worker NOT killed
  kill "$survivor" 2>/dev/null || true; wait "$survivor" 2>/dev/null || true
}

# --- permanent-teardown GC of persistent bridge state (failstate / outbound) ---
# The bridges deliberately keep run/<type>-bridge.<team>.<name>.failstate and
# .outbound.* across their own exit (crash/lazy-respawn keeps the streak and any
# undelivered payload); despawn — the sanctioned permanent teardown, also called
# by session-end's worker — must retire them.

@test "despawn --force: retires the bridge's failstate and outbound spool" {
  bash "$SCRIPTS/join.sh" team rev cursor "$PROJ" >/dev/null
  printf 'pid:%s\t%s\t%s\n' 999999 "$PROJ" cursor > "$RUN/spawn.team__rev"   # long-dead pid
  printf 'claude\x1f12\x1f3\n' > "$RUN/cursor-bridge.team.rev.failstate"
  printf '12\nspooled reply\n' > "$RUN/cursor-bridge.team.rev.outbound.claude.12345"
  printf '[]\n' > "$RUN/codex-bridge.team.rev.outbound.json"                 # historical type variant

  run bash "$SCRIPTS/despawn.sh" team leader rev --force
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=forced"* ]]
  [ ! -f "$RUN/cursor-bridge.team.rev.failstate" ]
  [ ! -f "$RUN/cursor-bridge.team.rev.outbound.claude.12345" ]
  [ ! -f "$RUN/codex-bridge.team.rev.outbound.json" ]
}

@test "despawn graceful (no live lock): also retires failstate and outbound spool" {
  bash "$SCRIPTS/join.sh" team rev codex "$PROJ" >/dev/null
  printf 'claude\x1f7\x1f2\n' > "$RUN/codex-bridge.team.rev.failstate"
  printf '[]\n' > "$RUN/codex-bridge.team.rev.outbound.json"

  run bash "$SCRIPTS/despawn.sh" team leader rev
  [ "$status" -eq 0 ]
  [[ "$output" == *"no-live-lock"* ]]
  [ ! -f "$RUN/codex-bridge.team.rev.failstate" ]
  [ ! -f "$RUN/codex-bridge.team.rev.outbound.json" ]
}

@test "despawn: bridge-state GC treats the member name literally (no glob expansion)" {
  # Regression guard for gc_bridge_state's quoting: a name containing '*' must
  # only remove ITS OWN literal state — bash does not glob-expand a variable
  # inside double quotes, and a future unquoting refactor must not change that.
  printf 'c\x1f1\x1f2\n' > "$RUN/cursor-bridge.team.rev1.failstate"
  printf '1\nspooled\n'  > "$RUN/cursor-bridge.team.rev1.outbound.claude.111"
  printf 'c\x1f1\x1f2\n' > "$RUN/cursor-bridge.team.revX.failstate"
  printf 'c\x1f1\x1f2\n' > "$RUN/cursor-bridge.team.rev*.failstate"
  printf '[]\n'          > "$RUN/codex-bridge.team.rev*.outbound.json"

  run bash "$SCRIPTS/despawn.sh" team leader 'rev*'
  [ "$status" -eq 0 ]
  [[ "$output" == *"no-live-lock"* ]]
  # the literal 'rev*' identity's state is gone…
  [ ! -f "$RUN/cursor-bridge.team.rev*.failstate" ]
  [ ! -f "$RUN/codex-bridge.team.rev*.outbound.json" ]
  # …and similarly-named identities are untouched
  [ -f "$RUN/cursor-bridge.team.rev1.failstate" ]
  [ -f "$RUN/cursor-bridge.team.rev1.outbound.claude.111" ]
  [ -f "$RUN/cursor-bridge.team.revX.failstate" ]
}

@test "despawn --force --expect-record: proceeds when the live record matches the snapshot" {
  bash "$SCRIPTS/join.sh" team codex codex "$PROJ" >/dev/null
  local rec; rec="$(printf 'pid:%s\t%s\tcodex' 999999 "$PROJ")"               # pid 999999: long dead
  printf '%s\n' "$rec" > "$RUN/spawn.team__codex"

  run bash "$SCRIPTS/despawn.sh" team leader codex --force --expect-record "$rec"
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=forced"* ]]
  [ ! -f "$RUN/spawn.team__codex" ]                  # record removed
}

@test "despawn --force: kills a herdr: placement via herdr pane close" {
  bash "$SCRIPTS/join.sh" team alice claude-code "$PROJ" >/dev/null
  # Record a herdr-tagged placement (herdr: scheme prefix).
  printf 'herdr:wC:p99\t%s\tclaude-code\n' "$PROJ" > "$RUN/spawn.team__alice"
  printf 'somesid\n' > "$RUN/actas.team__alice.session"

  # Stub herdr so we can assert the pane close call without touching real herdr.
  local stub_bin="$TEST_SKILL_DIR/stub-bin"
  mkdir -p "$stub_bin"
  cat > "$stub_bin/herdr" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HERDR_CALL_LOG"
echo '{"id":"cli:pane:close","result":{"type":"ok"}}'
STUB
  chmod +x "$stub_bin/herdr"
  export HERDR_CALL_LOG="$TEST_SKILL_DIR/herdr-calls.log"

  run env PATH="$stub_bin:$PATH" bash "$SCRIPTS/despawn.sh" team leader alice --force
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=forced"* ]]
  [ ! -f "$RUN/spawn.team__alice" ]
  # herdr was called with "pane close wC:p99" (prefix stripped).
  grep -q "pane close wC:p99" "$HERDR_CALL_LOG"
}
