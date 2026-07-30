#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
  PROJ="$BATS_TEST_TMPDIR/project with spaces"
  mkdir -p "$PROJ"
  bash "$SCRIPTS/config.sh" set delivery.session_team true >/dev/null
}

teardown() { teardown_test_env; }

write_pgrep_stub() {
  local mode="$1" stub_bin="$TEST_SKILL_DIR/stub-bin"
  mkdir -p "$stub_bin"
  case "$mode" in
    match)
      cat > "$stub_bin/pgrep" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"$EXPECTED_BRIDGE"*"--identity-key $EXPECTED_IDENTITY_KEY"*) exit 0 ;;
  *) exit 1 ;;
esac
STUB
      ;;
    miss)
      cat > "$stub_bin/pgrep" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
      ;;
    wrong)
      cat > "$stub_bin/pgrep" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"$EXPECTED_BRIDGE"*"--identity-key wrong:"*) exit 0 ;;
  *) exit 1 ;;
esac
STUB
      ;;
  esac
  chmod +x "$stub_bin/pgrep"
  printf '%s\n' "$stub_bin"
}

write_spawn_stub() {
  local status="$1" stub="$TEST_SKILL_DIR/scripts/spawn.sh"
  cat > "$stub" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TEST_SKILL_DIR/spawn.args"
exit $status
STUB
  chmod +x "$stub"
}

enable_claude_headless_fixture() {
  cat > "$TYPES/claude-code/type.conf" <<'CONF'
name=claude-code
spawnable=yes
headless=yes
CONF
}

@test "ensure-codex: preserves no-op behavior outside session-team mode" {
  bash "$SCRIPTS/config.sh" set delivery.session_team false >/dev/null
  run env CLAUDE_CODE_SESSION_ID=sess-X bash "$SCRIPTS/ensure-codex.sh" "$PROJ"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "ensure-codex: delegates with default codex name and preserves spawn args" {
  local stub_bin
  stub_bin="$(write_pgrep_stub miss)"
  write_spawn_stub 37
  run env PATH="$stub_bin:$PATH" CLAUDE_CODE_SESSION_ID=sess-CODEX \
    bash "$SCRIPTS/ensure-codex.sh" "$PROJ"
  [ "$status" -eq 1 ]
  [[ "$output" == *"failed to spawn codex 'codex'"* ]]
  grep -q -- "codex codex --team s-sess-CODEX --project $PROJ --headless" "$TEST_SKILL_DIR/spawn.args"
}

@test "ensure-headless: claude-code uses its type bridge and explicit name" {
  enable_claude_headless_fixture
  local stub_bin
  stub_bin="$(write_pgrep_stub miss)"
  write_spawn_stub 0
  run env PATH="$stub_bin:$PATH" CLAUDE_CODE_SESSION_ID=sess-CLAUDE \
    bash "$SCRIPTS/ensure-headless.sh" claude-code "$PROJ" reviewer
  [ "$status" -eq 0 ]
  [[ "$output" == *"spawned headless claude-code 'reviewer'"* ]]
  grep -q -- "claude-code reviewer --team s-sess-CLAUDE --project $PROJ --headless" "$TEST_SKILL_DIR/spawn.args"
}

@test "ensure-headless: claude-code duplicate scan uses the claude-code-bridge token" {
  enable_claude_headless_fixture
  local stub_bin="$TEST_SKILL_DIR/claude-stub-bin"
  mkdir -p "$stub_bin"
  cat > "$stub_bin/pgrep" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *claude-code-bridge*--identity-key*) exit 0 ;;
  *) exit 1 ;;
esac
STUB
  chmod +x "$stub_bin/pgrep"
  run env PATH="$stub_bin:$PATH" CLAUDE_CODE_SESSION_ID=sess-CLAUDE-LIVE \
    bash "$SCRIPTS/ensure-headless.sh" claude-code "$PROJ"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already running"* ]]
}

@test "ensure-headless: live matching bridge skips spawn" {
  local key stub_bin
  key="$(source "$SCRIPTS/lib/identity-key.sh"; agmsg_identity_key s-sess-LIVE codex)"
  stub_bin="$(write_pgrep_stub match)"
  write_spawn_stub 37
  run env PATH="$stub_bin:$PATH" EXPECTED_BRIDGE='codex-bridge\.js' \
    EXPECTED_IDENTITY_KEY="$key" CLAUDE_CODE_SESSION_ID=sess-LIVE \
    bash "$SCRIPTS/ensure-headless.sh" codex "$PROJ"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already running"* ]]
  [ ! -e "$TEST_SKILL_DIR/spawn.args" ]
}

@test "ensure-headless: wrong identity or dead scan result spawns" {
  local key stub_bin
  key="$(source "$SCRIPTS/lib/identity-key.sh"; agmsg_identity_key s-sess-WRONG codex)"
  stub_bin="$(write_pgrep_stub wrong)"
  write_spawn_stub 0
  run env PATH="$stub_bin:$PATH" EXPECTED_BRIDGE='codex-bridge\.js' \
    EXPECTED_IDENTITY_KEY="$key" CLAUDE_CODE_SESSION_ID=sess-WRONG \
    bash "$SCRIPTS/ensure-headless.sh" codex "$PROJ" worker
  [ "$status" -eq 0 ]
  [[ "$output" == *"spawned headless codex 'worker'"* ]]
  grep -q -- "codex worker --team s-sess-WRONG --project $PROJ --headless" "$TEST_SKILL_DIR/spawn.args"
}

@test "ensure-headless: concurrent fresh-lock contenders allow one spawn" {
  local stub_bin="$TEST_SKILL_DIR/stub-bin" pid1 pid2 status1 status2
  mkdir -p "$stub_bin"
  write_pgrep_stub miss >/dev/null
  cat > "$SCRIPTS/spawn.sh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TEST_SKILL_DIR/spawn.args"
sleep 1
exit 0
STUB
  chmod +x "$SCRIPTS/spawn.sh"

  env PATH="$stub_bin:$PATH" CLAUDE_CODE_SESSION_ID=sess-FRESH \
    bash "$SCRIPTS/ensure-headless.sh" codex "$PROJ" >"$TEST_SKILL_DIR/out1" 2>&1 &
  pid1=$!
  env PATH="$stub_bin:$PATH" CLAUDE_CODE_SESSION_ID=sess-FRESH \
    bash "$SCRIPTS/ensure-headless.sh" codex "$PROJ" >"$TEST_SKILL_DIR/out2" 2>&1 &
  pid2=$!
  status1=0; wait "$pid1" || status1=$?
  status2=0; wait "$pid2" || status2=$?

  [ "$status1" -eq 0 ]
  [ "$status2" -eq 0 ]
  [ "$(grep -c '^codex codex ' "$TEST_SKILL_DIR/spawn.args")" -eq 1 ]
  grep -q "spawn already in flight" "$TEST_SKILL_DIR/out1" "$TEST_SKILL_DIR/out2"
}

@test "ensure-headless: stale lock is reclaimed before spawning" {
  local stub_bin="$TEST_SKILL_DIR/stub-bin"
  local lock="$TEST_SKILL_DIR/run/ensure-codex.s-sess-STALE__codex.lock"
  mkdir -p "$stub_bin" "$lock"
  touch -t 200001010000 "$lock"
  write_pgrep_stub miss >/dev/null
  write_spawn_stub 0
  run env PATH="$stub_bin:$PATH" CLAUDE_CODE_SESSION_ID=sess-STALE \
    bash "$SCRIPTS/ensure-headless.sh" codex "$PROJ"
  [ "$status" -eq 0 ]
  [[ "$output" == *"spawned headless codex 'codex'"* ]]
  grep -q -- "codex codex --team s-sess-STALE --project $PROJ --headless" "$TEST_SKILL_DIR/spawn.args"
}

@test "ensure-headless: rejects invalid and non-headless types" {
  run bash "$SCRIPTS/ensure-headless.sh" bogus "$PROJ"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown agent type"* ]]

  run bash "$SCRIPTS/ensure-headless.sh" gemini "$PROJ"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not headless-capable"* ]]
}
