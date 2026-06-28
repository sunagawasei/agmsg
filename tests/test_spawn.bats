#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env

  # Stub the agent CLIs so `command -v` succeeds without the real tools, and
  # provide a `record.sh` that captures the launch command instead of opening
  # a terminal. PATH is prepended so the stubs win.
  export STUB_BIN="$TEST_SKILL_DIR/stub-bin"
  mkdir -p "$STUB_BIN"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB_BIN/claude"
  # codex stub. `codex sandbox ...` drives the reviewer enforcement probes. A real
  # enforcing reviewer profile DENIES a write under the repo cwd — surfaced as
  # touch's own "Operation not permitted" (NOT sandbox_apply) — but ALLOWS a write
  # under agmsg's run/ dir (the reply-path positive probe). The preflight
  # `codex sandbox -- /usr/bin/true` (no touch) just runs. Mirror that so the
  # hardened 3-way probe in _spawn.sh classifies the denial as enforcing and
  # proceeds. Tests that simulate a fail-open / nested build override this per-test.
  cat > "$STUB_BIN/codex" <<'CODEX_STUB'
#!/usr/bin/env bash
if [ "$1" = sandbox ]; then
  case "$*" in
    *"rm -f"*) exit 0 ;;                                                   # positive probe (run/ write) — allowed
    *touch*)   echo "touch: probe: Operation not permitted" >&2; exit 1 ;; # repo write — denied (enforcing)
    *)         exit 0 ;;                                                   # preflight (true) / other — ok
  esac
fi
exit 0
CODEX_STUB
  # grok-build and hermes need only a trivial success stub.
  for bin in grok hermes; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB_BIN/$bin"
    chmod +x "$STUB_BIN/$bin"
  done
  chmod +x "$STUB_BIN/claude" "$STUB_BIN/codex"
  export CAPTURE="$TEST_SKILL_DIR/launch-capture.txt"
  cat > "$STUB_BIN/record.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$CAPTURE"
EOF
  chmod +x "$STUB_BIN/record.sh"
  export PATH="$STUB_BIN:$PATH"

  # Never inherit a real tmux server from the test runner — force the
  # OS-terminal path, which we redirect into record.sh via a {cmd} template.
  unset TMUX
  export AGMSG_TERMINAL="$STUB_BIN/record.sh {cmd}"

  export PROJ="$TEST_SKILL_DIR/proj"
  mkdir -p "$PROJ"
}

teardown() {
  teardown_test_env
}

# --- argument validation ---

@test "spawn: rejects unsupported agent type (gemini)" {
  run bash "$SCRIPTS/spawn.sh" gemini foo --project "$PROJ"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "not supported by spawn yet" ]]
}

@test "spawn: rejects unsupported agent type (opencode)" {
  run bash "$SCRIPTS/spawn.sh" opencode foo --project "$PROJ"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "not supported by spawn yet" ]]
}

@test "spawn: rejects unknown agent type" {
  run bash "$SCRIPTS/spawn.sh" frobnicate foo --project "$PROJ"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "unknown agent type" ]]
}

@test "spawn: requires a name" {
  run bash "$SCRIPTS/spawn.sh" claude-code
  [ "$status" -ne 0 ]
  [[ "$output" =~ "Usage" ]]
}

@test "spawn: rejects invalid --split" {
  run bash "$SCRIPTS/spawn.sh" claude-code foo --project "$PROJ" --split z
  [ "$status" -ne 0 ]
  [[ "$output" =~ "--split must be" ]]
}

@test "spawn: rejects a nonexistent project" {
  run bash "$SCRIPTS/spawn.sh" claude-code foo --project /no/such/dir
  [ "$status" -ne 0 ]
  [[ "$output" =~ "project path does not exist" ]]
}

@test "spawn: errors when the target CLI is not installed" {
  rm -f "$STUB_BIN/codex"
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  # Restrict PATH so a real codex installed on the host can't satisfy the
  # check — only the stub dir (now lacking codex) plus system utilities.
  run env PATH="$STUB_BIN:/usr/bin:/bin" bash "$SCRIPTS/spawn.sh" codex foo --project "$PROJ"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "not found on PATH" ]]
}

# --- team resolution ---

@test "spawn: errors when no team is registered for the project" {
  run bash "$SCRIPTS/spawn.sh" claude-code foo --project "$PROJ"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "no team is registered" ]]
}

@test "spawn: errors when the project belongs to multiple teams without --team" {
  bash "$SCRIPTS/join.sh" team-a existing-a claude-code "$PROJ"
  bash "$SCRIPTS/join.sh" team-b existing-b codex "$PROJ"
  run bash "$SCRIPTS/spawn.sh" claude-code foo --project "$PROJ"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "multiple teams" ]]
}

@test "spawn: team resolution survives a single quote in the project path" {
  # resolve_team reads configs via readfile() + SQL string literals, so a
  # project path with a single quote no longer produces a SQL syntax error or
  # a false "no team is registered". (The spawn as a whole may still fail
  # downstream: join.sh and the other shared scripts bind config JSON via
  # `.param set`, which can't carry a single quote — a pre-existing,
  # codebase-wide limitation tracked separately, not introduced here.)
  local quoted="$TEST_SKILL_DIR/pro'j"
  mkdir -p "$quoted"
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$quoted"
  run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$quoted"
  [[ "$output" != *"no team is registered"* ]]
  [[ "$output" != *"syntax error"* ]]
}

@test "spawn: --team disambiguates a multi-team project" {
  bash "$SCRIPTS/join.sh" team-a existing-a claude-code "$PROJ"
  bash "$SCRIPTS/join.sh" team-b existing-b codex "$PROJ"
  run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --team team-b --no-wait
  [ "$status" -eq 0 ]
  run bash "$SCRIPTS/identities.sh" "$PROJ" claude-code
  [[ "$output" =~ team-b$'\t'alice ]]
}

# --- happy path / launch command ---

@test "spawn: pre-joins the name and launches the CLI with the actas prompt" {
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  [[ "$output" =~ "spawned claude-code 'alice'" ]]

  # alice is now registered to the resolved team.
  run bash "$SCRIPTS/identities.sh" "$PROJ" claude-code
  [[ "$output" =~ "alice" ]]

  # The terminal template is handed the path to a generated boot script; that
  # script cd's into the project and runs claude with the actas slash command.
  # (printf %q escapes the spaces in the prompt as "\ ", so assert on tokens.)
  # The slash command is named after the skill dir basename (the install
  # command name), not a hardcoded "agmsg".
  local cmd; cmd="$(basename "$TEST_SKILL_DIR")"
  boot="$(cat "$CAPTURE")"
  [ -f "$boot" ]
  run cat "$boot"
  [[ "$output" == *"claude"* ]]
  [[ "$output" == *"/$cmd"* ]]
  [[ "$output" == *"actas"* ]]
  [[ "$output" == *"alice"* ]]
  [[ "$output" == *"$PROJ"* ]]
}

@test "spawn: grok-build launches the plain grok CLI with the actas prompt" {
  # grok-build is spawnable and monitor=no, so spawn skips the readiness wait.
  # Delivery is a rule file (no hook), so no folder-trust flag is needed —
  # the launch is the bare `grok "/<cmd> actas <name>"`, like claude-code.
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run bash "$SCRIPTS/spawn.sh" grok-build alice --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  boot="$(cat "$CAPTURE")"
  [ -f "$boot" ]
  run cat "$boot"
  [[ "$output" == *"grok"* ]]
  [[ "$output" == *"actas"* ]]
  [[ "$output" == *"alice"* ]]
  [[ "$output" != *"--trust"* ]]
}

# --- --model (#135): per-type model flag, pass-through id ---

@test "spawn --model: claude-code launch includes its --model flag + id" {
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --model claude-opus-4-8 --no-wait
  [ "$status" -eq 0 ]
  boot="$(cat "$CAPTURE")"
  run cat "$boot"
  [[ "$output" == *"claude --model claude-opus-4-8"* ]]
  [[ "$output" == *"actas"* ]]
}

@test "spawn --model: codex launch uses its -m model flag" {
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run bash "$SCRIPTS/spawn.sh" codex alice --project "$PROJ" --model gpt-5 --no-wait
  [ "$status" -eq 0 ]
  boot="$(cat "$CAPTURE")"
  run cat "$boot"
  [[ "$output" == *"codex -m gpt-5"* ]]
}

@test "spawn --model: grok-build launch uses its --model flag" {
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run bash "$SCRIPTS/spawn.sh" grok-build alice --project "$PROJ" --model grok-build --no-wait
  [ "$status" -eq 0 ]
  boot="$(cat "$CAPTURE")"
  run cat "$boot"
  [[ "$output" == *"grok --model grok-build"* ]]
}

@test "spawn --model: refused for a type with no model_arg in its manifest" {
  run bash "$SCRIPTS/spawn.sh" hermes foo --project "$PROJ" --model whatever --no-wait
  [ "$status" -ne 0 ]
  [[ "$output" =~ "does not support --model" ]]
}

@test "spawn: no --model leaves the launch flag-free" {
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  boot="$(cat "$CAPTURE")"
  run cat "$boot"
  [[ "$output" != *"--model"* ]]
}

@test "spawn: actas prompt uses the install command name (not hardcoded agmsg)" {
  # Rename the skill dir to a custom command name and re-point SCRIPTS so the
  # script resolves SKILL_DIR basename = the custom name.
  local custom="$TEST_SKILL_DIR/../m-$$"
  cp -R "$TEST_SKILL_DIR" "$custom"
  bash "$custom/scripts/join.sh" myteam existing claude-code "$PROJ"
  run env AGMSG_TERMINAL="$STUB_BIN/record.sh {cmd}" \
    bash "$custom/scripts/spawn.sh" claude-code alice --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  boot="$(cat "$CAPTURE")"
  run cat "$boot"
  [[ "$output" == *"/m-$$"* ]]
  [[ "$output" != *"/agmsg actas"* ]]
  rm -rf "$custom"
}

@test "spawn: --boot-prompt appends an initial task to the actas prompt" {
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait \
    --boot-prompt "review the diff"
  [ "$status" -eq 0 ]

  # The boot script still carries the actas slash command, and now ALSO the
  # task text, so the spawned agent claims its identity AND acts on the task in
  # its first turn. (printf %q escapes spaces, so assert on tokens.)
  boot="$(cat "$CAPTURE")"
  [ -f "$boot" ]
  run cat "$boot"
  [[ "$output" == *"actas"* ]]
  [[ "$output" == *"alice"* ]]
  [[ "$output" == *"review"* ]]
  [[ "$output" == *"diff"* ]]
}

@test "spawn: without --boot-prompt the boot script carries no extra task text" {
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]

  # Guards the byte-identical claim: with no --boot-prompt, only the actas command
  # is passed — no task text leaks into the boot script.
  boot="$(cat "$CAPTURE")"
  [ -f "$boot" ]
  run cat "$boot"
  [[ "$output" == *"actas"* ]]
  [[ "$output" != *"review the diff"* ]]
}

@test "spawn: errors when \$TMUX is set but tmux is not on PATH" {
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  # $TMUX set (we look like we're inside tmux) but a PATH that lacks the tmux
  # binary. Mirror the system utilities into a dir that omits tmux, so the test
  # holds on hosts where tmux IS installed (e.g. ubuntu-latest runners) — the
  # point is exercising spawn's "tmux binary not on PATH" branch, not whether
  # the host happens to ship tmux.
  local notmux="$BATS_TEST_TMPDIR/notmux-bin"
  mkdir -p "$notmux"
  local d f b
  for d in /usr/bin /bin; do
    [ -d "$d" ] || continue
    for f in "$d"/*; do
      b=$(basename "$f")
      [ "$b" = tmux ] && continue
      [ -e "$notmux/$b" ] || ln -s "$f" "$notmux/$b" 2>/dev/null || true
    done
  done
  run env TMUX="/tmp/fake,1,0" PATH="$STUB_BIN:$notmux" \
    bash "$SCRIPTS/spawn.sh" claude-code foo --project "$PROJ"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "tmux binary is not on PATH" ]]
}

@test "spawn: codex spawns the codex CLI" {
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  run bash "$SCRIPTS/spawn.sh" codex reviewer --project "$PROJ"
  [ "$status" -eq 0 ]
  boot="$(cat "$CAPTURE")"
  [ -f "$boot" ]
  run cat "$boot"
  [[ "$output" == *"codex"* ]]
  [[ "$output" == *"actas"* ]]
  [[ "$output" == *"reviewer"* ]]
}

# --- pre-flight exclusivity check ---

@test "spawn: refuses when the name is held by another live session" {
  bash "$SCRIPTS/join.sh" myteam alice claude-code "$PROJ"
  # Forge a live owner for (myteam, alice).
  setup_live_owner "$TEST_SKILL_DIR/run" LIVESID
  printf '%s\n' LIVESID > "$TEST_SKILL_DIR/run/actas.myteam__alice.session"

  run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "held by a live session" ]]
}

# --- readiness handshake (#108) ---

@test "spawn: readiness handshake returns status=ready when the watcher attaches" {
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  mkdir -p "$TEST_SKILL_DIR/run"
  local ready="$TEST_SKILL_DIR/run/ready.myteam__alice"
  # The terminal "launch" just touches the ready sentinel (and comments out the
  # boot script so its interactive shell never runs in the test).
  run env -u TMUX bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" \
    --ready-timeout 10 --terminal "touch $ready # {cmd}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=ready"* ]]
}

@test "spawn: readiness handshake times out (status=timeout, exit 3) when nothing attaches" {
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run env -u TMUX bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" \
    --ready-timeout 2 --terminal "true # {cmd}"
  [ "$status" -eq 3 ]
  [[ "$output" == *"status=timeout"* ]]
}

@test "spawn: --no-wait returns immediately with no readiness status" {
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  [[ "$output" != *"status="* ]]
}

@test "spawn: codex skips the readiness wait (no Monitor)" {
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  run bash "$SCRIPTS/spawn.sh" codex reviewer --project "$PROJ"
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipping readiness wait"* ]]
}

# --- headless codex (config-driven default) ---

# A fake codex-bridge that records its args AND the injected app-server command,
# so headless tests can assert the sandbox policy without launching real codex.
_make_fake_bridge() {
  cat > "$STUB_BIN/fake-bridge.sh" <<EOF
#!/usr/bin/env bash
printf 'ARGS: %s\n' "\$*" >> "$CAPTURE"
printf 'APPCMD: %s\n' "\${AGMSG_CODEX_APP_SERVER_CMD:-}" >> "$CAPTURE"
exit 0
EOF
  chmod +x "$STUB_BIN/fake-bridge.sh"
}

@test "spawn: --headless is rejected for claude-code" {
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --headless
  [ "$status" -ne 0 ]
  [[ "$output" == *"--headless is not supported"* ]]
}

@test "spawn: codex defaults to headless when spawn.codex_headless=true" {
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  bash "$SCRIPTS/config.sh" set spawn.codex_headless true
  _make_fake_bridge

  run env AGMSG_CODEX_BRIDGE_CMD="$STUB_BIN/fake-bridge.sh" \
    bash "$SCRIPTS/spawn.sh" codex reviewer --project "$PROJ"
  [ "$status" -eq 0 ]
  [[ "$output" == *"spawned headless codex 'reviewer'"* ]]

  # The bridge runs in the background (nohup &); wait for its capture to land.
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$CAPTURE" ] && break; sleep 0.2; done
  run cat "$CAPTURE"
  [[ "$output" == *"--type codex"* ]]
  [[ "$output" == *"--team myteam"* ]]
  [[ "$output" == *"--name reviewer"* ]]
  [[ "$output" == *"--inline-inbox"* ]]
  [[ "$output" == *"codex-myteam-cwd"* ]]                # --project = scratch cwd
  [[ "$output" == *"sandbox_mode=workspace-write"* ]]    # app-server policy injected
  [[ "$output" == *"approval_policy=never"* ]]
  [[ "$output" == *"web_search=live"* ]]
  [[ "$output" == *"writable_roots="* ]]

  # reviewer was registered to the scratch dir, not the real project.
  run cat "$TEST_SKILL_DIR/teams/myteam/config.json"
  [[ "$output" == *"codex-myteam-cwd"* ]]
}

@test "spawn: codex --interactive forces the TUI even when headless is the default" {
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  bash "$SCRIPTS/config.sh" set spawn.codex_headless true
  run bash "$SCRIPTS/spawn.sh" codex reviewer --project "$PROJ" --interactive
  [ "$status" -eq 0 ]
  # TUI path: the {cmd} terminal template (record.sh) captured a boot script path.
  boot="$(cat "$CAPTURE")"
  [ -f "$boot" ]
  run cat "$boot"
  [[ "$output" == *"codex"* ]]
  [[ "$output" == *"actas"* ]]
  [[ "$output" == *"reviewer"* ]]
}

@test "spawn: codex --headless works without the config key (explicit opt-in)" {
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  _make_fake_bridge
  run env AGMSG_CODEX_BRIDGE_CMD="$STUB_BIN/fake-bridge.sh" \
    bash "$SCRIPTS/spawn.sh" codex reviewer --project "$PROJ" --headless
  [ "$status" -eq 0 ]
  [[ "$output" == *"spawned headless codex 'reviewer'"* ]]
}

@test "spawn: codex --reviewer launches in the repo under the read-only profile" {
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  _make_fake_bridge

  run env AGMSG_CODEX_BRIDGE_CMD="$STUB_BIN/fake-bridge.sh" \
    bash "$SCRIPTS/spawn.sh" codex rv --project "$PROJ" --headless --reviewer
  [ "$status" -eq 0 ]
  [[ "$output" == *"spawned headless reviewer codex 'rv'"* ]]

  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$CAPTURE" ] && break; sleep 0.2; done
  run cat "$CAPTURE"
  [[ "$output" == *"--name rv"* ]]
  [[ "$output" == *"--project $PROJ"* ]]                  # cwd = the real repo
  [[ "$output" != *"codex-myteam-cwd"* ]]                 # NOT the scratch dir
  [[ "$output" == *"default_permissions=agmsg-reviewer"* ]]
  [[ "$output" == *"permissions.agmsg-reviewer.filesystem="* ]]
  [[ "$output" == *":workspace_roots"* ]]
  [[ "$output" != *"sandbox_mode=workspace-write"* ]]     # profile supersedes sandbox_mode
  [[ "$output" == *"web_search=live"* ]]
  [[ "$output" == *"approval_policy=never"* ]]

  # registered to the real project, not a scratch dir.
  run cat "$TEST_SKILL_DIR/teams/myteam/config.json"
  [[ "$output" != *"codex-myteam-cwd"* ]]
}

@test "spawn: codex defaults to reviewer when spawn.codex_reviewer=true" {
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  bash "$SCRIPTS/config.sh" set spawn.codex_headless true
  bash "$SCRIPTS/config.sh" set spawn.codex_reviewer true
  _make_fake_bridge

  run env AGMSG_CODEX_BRIDGE_CMD="$STUB_BIN/fake-bridge.sh" \
    bash "$SCRIPTS/spawn.sh" codex rv --project "$PROJ"
  [ "$status" -eq 0 ]
  [[ "$output" == *"spawned headless reviewer codex 'rv'"* ]]

  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$CAPTURE" ] && break; sleep 0.2; done
  run cat "$CAPTURE"
  [[ "$output" == *"default_permissions=agmsg-reviewer"* ]]
  [[ "$output" != *"sandbox_mode=workspace-write"* ]]
}

@test "spawn: --reviewer on an interactive codex spawn is rejected" {
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  run bash "$SCRIPTS/spawn.sh" codex rv --project "$PROJ" --interactive --reviewer
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires --headless"* ]]
}

@test "spawn: --reviewer refuses to launch when the sandbox is not enforced (fail closed)" {
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  _make_fake_bridge
  # Simulate a codex build that does NOT enforce the profile: the sandbox probe's
  # repo write succeeds (exit 0), which the guard must treat as fail-open.
  printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB_BIN/codex"
  chmod +x "$STUB_BIN/codex"

  run env AGMSG_CODEX_BRIDGE_CMD="$STUB_BIN/fake-bridge.sh" \
    bash "$SCRIPTS/spawn.sh" codex rv --project "$PROJ" --headless --reviewer
  [ "$status" -ne 0 ]
  [[ "$output" == *"not enforced"* ]]
  # The bridge must NOT have been launched (no capture written).
  [ ! -s "$CAPTURE" ]
}

@test "spawn: refuses when nested inside an outer Seatbelt sandbox (sandbox_apply)" {
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  _make_fake_bridge
  # Simulate codex running inside an outer macOS Seatbelt sandbox: applying its own
  # per-command sandbox fails with sandbox-exec's sandbox_apply error. The worker
  # could read but never run send.sh to reply, so refuse before registering.
  printf '#!/usr/bin/env bash\n[ "$1" = sandbox ] && { echo "sandbox-exec: sandbox_apply: Operation not permitted" >&2; exit 1; }\nexit 0\n' > "$STUB_BIN/codex"
  chmod +x "$STUB_BIN/codex"

  run env AGMSG_CODEX_BRIDGE_CMD="$STUB_BIN/fake-bridge.sh" \
    bash "$SCRIPTS/spawn.sh" codex rv --project "$PROJ" --headless --reviewer
  [ "$status" -ne 0 ]
  [[ "$output" == *"outer macOS Seatbelt sandbox"* ]]
  # The bridge must NOT have been launched (no capture written).
  [ ! -s "$CAPTURE" ]
}

@test "spawn: a normal write denial is enforcement, not nesting (no sandbox_apply)" {
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  _make_fake_bridge
  # The enforcing case: the probed repo write is DENIED and surfaced as touch's own
  # "Operation not permitted" (NO sandbox_apply), while the run/ positive probe is
  # ALLOWED. This must launch normally and not be mistaken for a nested outer sandbox.
  cat > "$STUB_BIN/codex" <<'CODEX_STUB'
#!/usr/bin/env bash
if [ "$1" = sandbox ]; then
  case "$*" in
    *"rm -f"*) exit 0 ;;
    *touch*)   echo "touch: probe: Operation not permitted" >&2; exit 1 ;;
    *)         exit 0 ;;
  esac
fi
exit 0
CODEX_STUB
  chmod +x "$STUB_BIN/codex"

  run env AGMSG_CODEX_BRIDGE_CMD="$STUB_BIN/fake-bridge.sh" \
    bash "$SCRIPTS/spawn.sh" codex rv --project "$PROJ" --headless --reviewer
  [ "$status" -eq 0 ]
  [[ "$output" == *"spawned headless reviewer codex 'rv'"* ]]
}

# --- reviewer /add-dir read-root inheritance (spawn.codex_inherit_add_dirs) ---

@test "spawn: codex reviewer inherits /add-dir read roots when spawn.codex_inherit_add_dirs=true" {
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  bash "$SCRIPTS/config.sh" set spawn.codex_inherit_add_dirs true
  local adddir="$TEST_SKILL_DIR/adddir"; mkdir -p "$adddir"
  mkdir -p "$PROJ/.claude"
  printf '{"permissions":{"additionalDirectories":["%s"]}}' "$adddir" > "$PROJ/.claude/settings.local.json"
  _make_fake_bridge

  run env AGMSG_CODEX_BRIDGE_CMD="$STUB_BIN/fake-bridge.sh" \
    bash "$SCRIPTS/spawn.sh" codex rv --project "$PROJ" --headless --reviewer
  [ "$status" -eq 0 ]

  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$CAPTURE" ] && break; sleep 0.2; done
  run cat "$CAPTURE"
  [[ "$output" == *"\"$adddir\"=\"read\""* ]]        # the add-dir is granted READ
  [[ "$output" == *"default_permissions=agmsg-reviewer"* ]]
}

@test "spawn: codex reviewer does NOT inherit /add-dir roots when the gate is off (default)" {
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  local adddir="$TEST_SKILL_DIR/adddir"; mkdir -p "$adddir"
  mkdir -p "$PROJ/.claude"
  printf '{"permissions":{"additionalDirectories":["%s"]}}' "$adddir" > "$PROJ/.claude/settings.local.json"
  _make_fake_bridge

  run env AGMSG_CODEX_BRIDGE_CMD="$STUB_BIN/fake-bridge.sh" \
    bash "$SCRIPTS/spawn.sh" codex rv --project "$PROJ" --headless --reviewer
  [ "$status" -eq 0 ]
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$CAPTURE" ] && break; sleep 0.2; done
  run cat "$CAPTURE"
  [[ "$output" == *"default_permissions=agmsg-reviewer"* ]]   # reviewer still active
  [[ "$output" != *"$adddir"* ]]                              # but the add-dir is not granted
}

@test "spawn: codex reviewer skips a non-existent /add-dir entry (still launches)" {
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  bash "$SCRIPTS/config.sh" set spawn.codex_inherit_add_dirs true
  mkdir -p "$PROJ/.claude"
  printf '{"permissions":{"additionalDirectories":["/no/such/dir/xyz"]}}' > "$PROJ/.claude/settings.local.json"
  _make_fake_bridge

  run env AGMSG_CODEX_BRIDGE_CMD="$STUB_BIN/fake-bridge.sh" \
    bash "$SCRIPTS/spawn.sh" codex rv --project "$PROJ" --headless --reviewer
  [ "$status" -eq 0 ]                                          # a stale add-dir never bricks the spawn
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$CAPTURE" ] && break; sleep 0.2; done
  run cat "$CAPTURE"
  [[ "$output" != *"/no/such/dir/xyz"* ]]
}

@test "spawn: codex reviewer skips an /add-dir path with a single quote (no shell injection)" {
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  bash "$SCRIPTS/config.sh" set spawn.codex_inherit_add_dirs true
  # An existing directory whose name carries a single quote + shell metacharacters.
  # The value is spliced into appcmd's single-quoted -c '…filesystem=…', which the
  # bridge re-parses via `/bin/sh -lc`; a ' would break out → command injection.
  local evil="$TEST_SKILL_DIR/ev'il; touch $TEST_SKILL_DIR/PWNED; :"
  mkdir -p "$evil"
  mkdir -p "$PROJ/.claude"
  printf '{"permissions":{"additionalDirectories":["%s"]}}' "$evil" > "$PROJ/.claude/settings.local.json"
  _make_fake_bridge

  run env AGMSG_CODEX_BRIDGE_CMD="$STUB_BIN/fake-bridge.sh" \
    bash "$SCRIPTS/spawn.sh" codex rv --project "$PROJ" --headless --reviewer
  [ "$status" -eq 0 ]                                       # launches on the base profile
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$CAPTURE" ] && break; sleep 0.2; done
  run cat "$CAPTURE"
  [[ "$output" != *"PWNED"* ]]                              # payload never reached the launch command
  [ ! -e "$TEST_SKILL_DIR/PWNED" ]                          # and nothing executed it
}

@test "spawn: codex reviewer does not re-grant the project root as an /add-dir read root" {
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  bash "$SCRIPTS/config.sh" set spawn.codex_inherit_add_dirs true
  mkdir -p "$PROJ/.claude"
  printf '{"permissions":{"additionalDirectories":["%s"]}}' "$PROJ" > "$PROJ/.claude/settings.local.json"
  _make_fake_bridge

  run env AGMSG_CODEX_BRIDGE_CMD="$STUB_BIN/fake-bridge.sh" \
    bash "$SCRIPTS/spawn.sh" codex rv --project "$PROJ" --headless --reviewer
  [ "$status" -eq 0 ]
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$CAPTURE" ] && break; sleep 0.2; done
  run cat "$CAPTURE"
  [[ "$output" != *"\"$PROJ\"=\"read\""* ]]   # already :workspace_roots — not re-granted
}

@test "spawn: grok-build skips the readiness wait even without --no-wait (monitor=no)" {
  # Regression guard: grok-build's monitor watcher attaches via the agent's
  # actas/rule launch (no SessionStart hook) and only in monitor mode, so there
  # is no ready sentinel for spawn to await. With monitor=no, spawn must skip the
  # wait and return immediately instead of hanging a default turn/off-mode spawn
  # until --ready-timeout. (Without this, monitor=yes made the wait fire.)
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run env -u TMUX bash "$SCRIPTS/spawn.sh" grok-build alice --project "$PROJ" \
    --terminal "true # {cmd}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipping readiness wait"* ]]
  [[ "$output" != *"status=timeout"* ]]
  [[ "$output" != *"status=ready"* ]]
}

# --- initial prompt (--boot-prompt) ---
# spawn folds an optional initial task into the agent's first prompt: the boot
# prompt becomes the actas slash command followed (newline-separated) by the
# task, so the new agent claims its identity AND starts the task in one turn —
# the only way to hand a one-shot goal to a no-Monitor peer (codex). These tests
# assert on the generated boot script the terminal template is handed (captured
# via record.sh), the same way the actas-prompt tests above do.

@test "spawn: --boot-prompt requires a task (missing arg errors)" {
  run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --boot-prompt
  [ "$status" -ne 0 ]
  [[ "$output" == *"--boot-prompt needs a task"* ]]
}

@test "spawn: --boot-prompt \"\" is treated as no task (no-op, not an error)" {
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  # An explicit empty string must NOT abort the spawn — it degrades to a plain
  # spawn (so a scripted `--boot-prompt "$VAR"` with an empty VAR still works).
  run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait --boot-prompt ""
  [ "$status" -eq 0 ]
  boot="$(cat "$CAPTURE")"
  run cat "$boot"
  [[ "$output" == *"actas"* ]]
  [[ "$output" == *"alice"* ]]
  # No task appended → no newline-join → boot prompt unchanged.
  [[ "$output" != *'\n'* ]]
}

@test "spawn: --boot-prompt folds the initial task into the boot prompt (codex)" {
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  run bash "$SCRIPTS/spawn.sh" codex reviewer --project "$PROJ" \
    --boot-prompt "REVIEW_THE_DIFF"
  [ "$status" -eq 0 ]
  boot="$(cat "$CAPTURE")"
  [ -f "$boot" ]
  run cat "$boot"
  [[ "$output" == *"actas"* ]]
  [[ "$output" == *"reviewer"* ]]
  [[ "$output" == *"REVIEW_THE_DIFF"* ]]
}
