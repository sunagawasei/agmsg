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
  # Other types need only a trivial success stub.
  for bin in grok hermes cursor-agent gemini agy copilot opencode; do
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

@test "spawn: rejects a known type with neither cli= nor spawn= (#277)" {
  # All nine built-ins are spawnable now, so the 'not supported by spawn yet'
  # gate (a known type missing both cli= and spawn=) needs a fixture — no
  # real built-in demonstrates it any more.
  local nd="$TEST_SKILL_DIR/scripts/drivers/types/noclitype"
  mkdir -p "$nd"
  printf 'name=noclitype\ntemplate=template.md\n' > "$nd/type.conf"
  run bash "$SCRIPTS/spawn.sh" noclitype foo --project "$PROJ"
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

@test "spawn: a multi-word cli= (opencode) checks only its first word's existence (#277)" {
  rm -f "$STUB_BIN/opencode"
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run env PATH="$STUB_BIN:/usr/bin:/bin" bash "$SCRIPTS/spawn.sh" opencode foo --project "$PROJ"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "'opencode' not found on PATH" ]]
  # never searches for the literal multi-word string as one executable name
  [[ "$output" != *"'opencode run --interactive' not found"* ]]
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
  # No real built-in is spawnable without a model_arg (#279 dropped hermes'
  # spawnable=yes, its only remaining example) — fixture a minimal one,
  # reusing the already-stubbed `claude` binary as its cli=.
  local nd="$TEST_SKILL_DIR/scripts/drivers/types/nomodeltype"
  mkdir -p "$nd"
  printf 'name=nomodeltype\ntemplate=template.md\ncli=claude\nspawnable=yes\n' > "$nd/type.conf"
  run bash "$SCRIPTS/spawn.sh" nomodeltype foo --project "$PROJ" --model whatever --no-wait
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

# --- newly spawnable types (#277): cursor, gemini, antigravity, copilot, opencode ---

@test "spawn: cursor launches cursor-agent with a bare positional prompt" {
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run bash "$SCRIPTS/spawn.sh" cursor alice --project "$PROJ" --model sonnet-4-thinking --no-wait
  [ "$status" -eq 0 ]
  boot="$(cat "$CAPTURE")"
  run cat "$boot"
  [[ "$output" == *"cursor-agent --model sonnet-4-thinking"* ]]
  [[ "$output" == *"actas"* ]]
}

@test "spawn: gemini launches gemini with a bare positional prompt" {
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run bash "$SCRIPTS/spawn.sh" gemini alice --project "$PROJ" --model gemini-3-pro --no-wait
  [ "$status" -eq 0 ]
  boot="$(cat "$CAPTURE")"
  run cat "$boot"
  [[ "$output" == *"gemini --model gemini-3-pro"* ]]
  [[ "$output" == *"actas"* ]]
}

@test "spawn: antigravity launches agy with --prompt-interactive (not a bare positional)" {
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run bash "$SCRIPTS/spawn.sh" antigravity alice --project "$PROJ" --model gemini-3-pro --no-wait
  [ "$status" -eq 0 ]
  boot="$(cat "$CAPTURE")"
  run cat "$boot"
  [[ "$output" == *"agy --model gemini-3-pro --prompt-interactive"* ]]
  [[ "$output" == *"actas"* ]]
}

@test "spawn: copilot launches copilot with --interactive (not a bare positional)" {
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run bash "$SCRIPTS/spawn.sh" copilot alice --project "$PROJ" --model gpt-5.4 --no-wait
  [ "$status" -eq 0 ]
  boot="$(cat "$CAPTURE")"
  run cat "$boot"
  [[ "$output" == *"copilot --model gpt-5.4 --interactive"* ]]
  [[ "$output" == *"actas"* ]]
}

@test "spawn: opencode launches its 'run --interactive' fixed subcommand prefix" {
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run bash "$SCRIPTS/spawn.sh" opencode alice --project "$PROJ" --model anthropic/claude-opus-4-8 --no-wait
  [ "$status" -eq 0 ]
  boot="$(cat "$CAPTURE")"
  run cat "$boot"
  [[ "$output" == *"opencode run --interactive --model anthropic/claude-opus-4-8"* ]]
  [[ "$output" == *"actas"* ]]
  # no bare 'opencode' invocation without the fixed prefix
  [[ "$output" != *$'\n''opencode --model'* ]]
}

@test "spawn: prompt_arg lands after spawn-options, immediately before the prompt" {
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  local opts="$TEST_SKILL_DIR/spawn_options.yaml"
  cat > "$opts" <<'YAML'
antigravity:
  --sandbox: true
YAML
  run env AGMSG_SPAWN_OPTIONS_FILE="$opts" \
    bash "$SCRIPTS/spawn.sh" antigravity alice --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  boot="$(cat "$CAPTURE")"
  run cat "$boot"
  [[ "$output" == *"agy --sandbox --prompt-interactive"* ]]
}

# --- spawn options (#273): per-type extra CLI args from a YAML file ---

@test "spawn: injects spawn-options flags from AGMSG_SPAWN_OPTIONS_FILE" {
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  local opts="$TEST_SKILL_DIR/spawn_options.yaml"
  cat > "$opts" <<'YAML'
claude-code:
  --permission-mode: acceptEdits
  --dangerously-skip-permissions: true
YAML
  run env AGMSG_SPAWN_OPTIONS_FILE="$opts" \
    bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  boot="$(cat "$CAPTURE")"
  run cat "$boot"
  [[ "$output" == *"claude --permission-mode acceptEdits --dangerously-skip-permissions"* ]]
  [[ "$output" == *"actas"* ]]
}

@test "spawn: spawn-options flags land after --model, before the actas prompt" {
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  local opts="$TEST_SKILL_DIR/spawn_options.yaml"
  cat > "$opts" <<'YAML'
claude-code:
  --permission-mode: acceptEdits
YAML
  run env AGMSG_SPAWN_OPTIONS_FILE="$opts" \
    bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --model claude-opus-4-8 --no-wait
  [ "$status" -eq 0 ]
  boot="$(cat "$CAPTURE")"
  run cat "$boot"
  [[ "$output" == *"claude --model claude-opus-4-8 --permission-mode acceptEdits"* ]]
}

@test "spawn: a false spawn-options value suppresses that flag" {
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  local opts="$TEST_SKILL_DIR/spawn_options.yaml"
  cat > "$opts" <<'YAML'
claude-code:
  --dangerously-skip-permissions: false
YAML
  run env AGMSG_SPAWN_OPTIONS_FILE="$opts" \
    bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  boot="$(cat "$CAPTURE")"
  run cat "$boot"
  [[ "$output" != *"--dangerously-skip-permissions"* ]]
}

@test "spawn: only the spawned type's section applies, not another type's" {
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  local opts="$TEST_SKILL_DIR/spawn_options.yaml"
  cat > "$opts" <<'YAML'
codex:
  --sandbox: workspace-write
YAML
  run env AGMSG_SPAWN_OPTIONS_FILE="$opts" \
    bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  boot="$(cat "$CAPTURE")"
  run cat "$boot"
  [[ "$output" != *"--sandbox"* ]]
}

@test "spawn: no spawn-options file leaves the launch unchanged" {
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run env AGMSG_SPAWN_OPTIONS_FILE="$TEST_SKILL_DIR/no-such-file.yaml" \
    bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  boot="$(cat "$CAPTURE")"
  run cat "$boot"
  [[ "$output" == *"claude"*"actas"* ]]
}

@test "spawn: falls back to ~/.agmsg/config/spawn_options.yaml when the env var is unset" {
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  mkdir -p "$HOME/.agmsg/config"
  cat > "$HOME/.agmsg/config/spawn_options.yaml" <<'YAML'
claude-code:
  --permission-mode: acceptEdits
YAML
  unset AGMSG_SPAWN_OPTIONS_FILE
  run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  boot="$(cat "$CAPTURE")"
  run cat "$boot"
  [[ "$output" == *"--permission-mode acceptEdits"* ]]
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

# --- fail-closed: agmsg install path quote/backslash safety (codex review) ---

@test "spawn: refuses a headless codex when the agmsg install path contains a quote (fail closed, all layouts)" {
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  _make_fake_bridge

  # A symlink whose name contains a single quote, pointing at the real
  # (quote-free) TEST_SKILL_DIR. `cd LINK && pwd` (what spawn.sh's
  # SCRIPT_DIR/SKILL_DIR derivation does under the hood) keeps the LOGICAL
  # path — the quote survives — reproducing an agmsg install path with a
  # character that would otherwise break the single-quoted -c clauses / TOML
  # strings SKILL_DIR/run_dir are hand-spliced into.
  local link="${TEST_SKILL_DIR}-evil'quote"
  ln -s "$TEST_SKILL_DIR" "$link"

  run env AGMSG_CODEX_BRIDGE_CMD="$STUB_BIN/fake-bridge.sh" \
    bash "$link/scripts/spawn.sh" codex impl --project "$PROJ" --headless --implementer
  [ "$status" -ne 0 ]
  [[ "$output" == *"install path contains a quote/backslash"* ]]
  # The bridge must NOT have been launched (no capture written).
  [ ! -s "$CAPTURE" ]

  rm -f "$link"
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
  [[ "$output" == *"default_permissions=agmsg-consultant"* ]]
  [[ "$output" != *"sandbox_mode=workspace-write"* ]]
  [[ "$output" == *"approval_policy=never"* ]]
  [[ "$output" == *"web_search=live"* ]]
  [[ "$output" == *"permissions.agmsg-consultant.filesystem="* ]]
  # No model/effort override was requested: appcmd must end EXACTLY at
  # approval_policy=never (end-of-string anchor, not just a substring match) —
  # a substring check alone would miss a regression that appends a stray/empty
  # clause after it, and neither "model=" nor the effort key must appear at all.
  [[ "$output" =~ approval_policy=never$ ]]
  [[ "$output" != *"model="* ]]
  [[ "$output" != *"model_reasoning_effort="* ]]

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
  # No model/effort override was requested: appcmd must end EXACTLY at
  # approval_policy=never on the REVIEWER branch too (the other appcmd
  # assignment — see the consultant-branch anchor above).
  [[ "$output" =~ approval_policy=never$ ]]
  [[ "$output" != *"model="* ]]
  [[ "$output" != *"model_reasoning_effort="* ]]

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

# --- headless codex implementer (cwd=repo + workspace-write) ---

@test "spawn: codex --implementer launches in the repo with workspace-write" {
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  _make_fake_bridge

  run env AGMSG_CODEX_BRIDGE_CMD="$STUB_BIN/fake-bridge.sh" \
    bash "$SCRIPTS/spawn.sh" codex impl --project "$PROJ" --headless --implementer
  [ "$status" -eq 0 ]
  [[ "$output" == *"spawned headless implementer codex 'impl'"* ]]

  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$CAPTURE" ] && break; sleep 0.2; done
  run cat "$CAPTURE"
  [[ "$output" == *"--name impl"* ]]
  [[ "$output" == *"--project $PROJ"* ]]                  # cwd = the real repo
  [[ "$output" != *"codex-myteam-cwd"* ]]                 # NOT the scratch dir
  [[ "$output" == *"default_permissions=agmsg-implementer"* ]]
  [[ "$output" != *"sandbox_mode=workspace-write"* ]]
  [[ "$output" == *"permissions.agmsg-implementer.filesystem="* ]]
  [[ "$output" != *"default_permissions=agmsg-reviewer"* ]]
  [[ "$output" == *"web_search=live"* ]]
  [[ "$output" == *"approval_policy=never"* ]]

  # registered to the real project, not a scratch dir.
  run cat "$TEST_SKILL_DIR/teams/myteam/config.json"
  [[ "$output" != *"codex-myteam-cwd"* ]]
}

@test "spawn: codex defaults to implementer when spawn.codex_implementer.<name>=true" {
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  bash "$SCRIPTS/config.sh" set spawn.codex_implementer.impl2 true
  # A conflicting GLOBAL reviewer default must not win over the per-worker
  # implementer key.
  bash "$SCRIPTS/config.sh" set spawn.codex_reviewer true
  _make_fake_bridge

  run env AGMSG_CODEX_BRIDGE_CMD="$STUB_BIN/fake-bridge.sh" \
    bash "$SCRIPTS/spawn.sh" codex impl2 --project "$PROJ" --headless
  [ "$status" -eq 0 ]
  [[ "$output" == *"spawned headless implementer codex 'impl2'"* ]]

  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$CAPTURE" ] && break; sleep 0.2; done
  run cat "$CAPTURE"
  [[ "$output" == *"default_permissions=agmsg-implementer"* ]]
  [[ "$output" != *"sandbox_mode=workspace-write"* ]]
  [[ "$output" != *"default_permissions=agmsg-reviewer"* ]]
}

@test "spawn: explicit --reviewer wins over spawn.codex_implementer.<name>=true (explicit beats config)" {
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  bash "$SCRIPTS/config.sh" set spawn.codex_implementer.rvw true
  _make_fake_bridge

  run env AGMSG_CODEX_BRIDGE_CMD="$STUB_BIN/fake-bridge.sh" \
    bash "$SCRIPTS/spawn.sh" codex rvw --project "$PROJ" --headless --reviewer
  [ "$status" -eq 0 ]
  [[ "$output" == *"spawned headless reviewer codex 'rvw'"* ]]

  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$CAPTURE" ] && break; sleep 0.2; done
  run cat "$CAPTURE"
  [[ "$output" == *"default_permissions=agmsg-reviewer"* ]]
  [[ "$output" != *"sandbox_mode=workspace-write"* ]]
}

@test "spawn: explicit --no-implementer wins over spawn.codex_implementer.<name>=true (falls back to consultant)" {
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  bash "$SCRIPTS/config.sh" set spawn.codex_implementer.noimpl true
  _make_fake_bridge

  run env AGMSG_CODEX_BRIDGE_CMD="$STUB_BIN/fake-bridge.sh" \
    bash "$SCRIPTS/spawn.sh" codex noimpl --project "$PROJ" --headless --no-implementer
  [ "$status" -eq 0 ]
  [[ "$output" == *"spawned headless codex 'noimpl'"* ]]
  [[ "$output" != *"implementer"* ]]

  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$CAPTURE" ] && break; sleep 0.2; done
  run cat "$CAPTURE"
  [[ "$output" == *"codex-myteam-cwd"* ]]                # scratch cwd, not the repo
  [[ "$output" == *"sandbox_mode=workspace-write"* ]]
  [[ "$output" != *"default_permissions=agmsg-reviewer"* ]]
}

@test "spawn: --implementer and --reviewer are mutually exclusive" {
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  run bash "$SCRIPTS/spawn.sh" codex rv3 --project "$PROJ" --headless --implementer --reviewer
  [ "$status" -ne 0 ]
  [[ "$output" == *"mutually exclusive"* ]]

  # nothing was registered for the contradictory identity.
  run cat "$TEST_SKILL_DIR/teams/myteam/config.json"
  [[ "$output" != *"rv3"* ]]
}

@test "spawn: --implementer requires headless" {
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  run bash "$SCRIPTS/spawn.sh" codex rv4 --project "$PROJ" --interactive --implementer
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires --headless"* ]]
}

@test "spawn --model: headless IMPLEMENTER codex also embeds -c model=\"...\" (implementer appcmd branch)" {
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  _make_fake_bridge

  run env AGMSG_CODEX_BRIDGE_CMD="$STUB_BIN/fake-bridge.sh" \
    bash "$SCRIPTS/spawn.sh" codex implm --project "$PROJ" --headless --implementer --model gpt-5.6-sol
  [ "$status" -eq 0 ]
  [[ "$output" == *"spawned headless implementer codex 'implm'"* ]]

  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$CAPTURE" ] && break; sleep 0.2; done
  run cat "$CAPTURE"
  [[ "$output" == *"sandbox_mode=workspace-write"* ]]   # confirms the implementer branch built appcmd
  [[ "$output" == *'model="gpt-5.6-sol"'* ]]
}

@test "spawn: an unsafe worker name skips the spawn.codex_implementer.<name> lookup (warns, --implementer flag still works)" {
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  # Decoy: a DIFFERENT (safe) name's config key must never leak into this one.
  bash "$SCRIPTS/config.sh" set spawn.codex_implementer.reviewer true
  _make_fake_bridge

  # No --implementer: the config lookup for this unsafe name must be skipped
  # outright (not attempted) — the spawn stays a plain consultant, not implementer.
  run env AGMSG_CODEX_BRIDGE_CMD="$STUB_BIN/fake-bridge.sh" \
    bash "$SCRIPTS/spawn.sh" codex 'worker+3' --project "$PROJ" --headless
  [ "$status" -eq 0 ]
  [[ "$output" == *"not a safe config-key segment"* ]]
  [[ "$output" == *"spawn.codex_implementer.<name>"* ]]
  [[ "$output" == *"spawned headless codex 'worker+3'"* ]]   # consultant, not implementer

  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$CAPTURE" ] && break; sleep 0.2; done
  run cat "$CAPTURE"
  [[ "$output" == *"codex-myteam-cwd"* ]]                 # scratch cwd, not the repo
  [[ "$output" != *"default_permissions=agmsg-reviewer"* ]]

  # An EXPLICIT --implementer bypasses the per-name config lookup entirely (no
  # implementer-lookup warning needed — the flag itself decides, config is
  # never consulted). The unsafe name still triggers the UNRELATED
  # spawn.codex_model.<name>/spawn.codex_effort.<name> warning (that lookup
  # always runs regardless of layout — see the "unsafe worker NAME as a
  # config-key segment" tests below) — assert on the implementer-specific
  # message, not the shared "not a safe config-key segment" substring, so
  # this test isn't confused by that independent warning.
  rm -f "$CAPTURE"
  run env AGMSG_CODEX_BRIDGE_CMD="$STUB_BIN/fake-bridge.sh" \
    bash "$SCRIPTS/spawn.sh" codex 'worker+4' --project "$PROJ" --headless --implementer
  [ "$status" -eq 0 ]
  [[ "$output" != *"skipping spawn.codex_implementer.<name> lookup"* ]]
  [[ "$output" == *"spawned headless implementer codex 'worker+4'"* ]]
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

# --- reviewer gh CLI config (spawn.codex_gh_config_dir.<name>) ---

@test "spawn: codex reviewer does not inject GH_CONFIG_DIR when the per-worker key is unset" {
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  _make_fake_bridge

  run env AGMSG_CODEX_BRIDGE_CMD="$STUB_BIN/fake-bridge.sh" \
    bash "$SCRIPTS/spawn.sh" codex rv --project "$PROJ" --headless --reviewer
  [ "$status" -eq 0 ]

  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$CAPTURE" ] && break; sleep 0.2; done
  run cat "$CAPTURE"
  [[ "$output" != *"GH_CONFIG_DIR"* ]]
}

@test "spawn: codex reviewer grants and injects a valid per-worker GH config directory" {
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  local ghdir="$TEST_SKILL_DIR/gh-config-rv"; mkdir -p "$ghdir"
  bash "$SCRIPTS/config.sh" set spawn.codex_gh_config_dir.rv "$ghdir"
  _make_fake_bridge

  run env AGMSG_CODEX_BRIDGE_CMD="$STUB_BIN/fake-bridge.sh" \
    bash "$SCRIPTS/spawn.sh" codex rv --project "$PROJ" --headless --reviewer
  [ "$status" -eq 0 ]

  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$CAPTURE" ] && break; sleep 0.2; done
  run cat "$CAPTURE"
  [[ "$output" == *"\"$ghdir\"=\"read\""* ]]
  [[ "$output" == *"shell_environment_policy.set.GH_CONFIG_DIR=\"$ghdir\""* ]]
}

@test "spawn: codex reviewer ignores a relative per-worker GH config directory with a warning" {
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  bash "$SCRIPTS/config.sh" set spawn.codex_gh_config_dir.rv relative/gh-config
  _make_fake_bridge

  run env AGMSG_CODEX_BRIDGE_CMD="$STUB_BIN/fake-bridge.sh" \
    bash "$SCRIPTS/spawn.sh" codex rv --project "$PROJ" --headless --reviewer
  [ "$status" -eq 0 ]
  [[ "$output" == *"ignoring invalid codex GH config dir"* ]]

  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$CAPTURE" ] && break; sleep 0.2; done
  run cat "$CAPTURE"
  [[ "$output" != *"GH_CONFIG_DIR"* ]]
  [[ "$output" != *"relative/gh-config"* ]]
}

@test "spawn: codex reviewer ignores a quoted per-worker GH config directory with a warning" {
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  local ghdir="$TEST_SKILL_DIR/gh'config"; mkdir -p "$ghdir"
  bash "$SCRIPTS/config.sh" set spawn.codex_gh_config_dir.rv "$ghdir"
  _make_fake_bridge

  run env AGMSG_CODEX_BRIDGE_CMD="$STUB_BIN/fake-bridge.sh" \
    bash "$SCRIPTS/spawn.sh" codex rv --project "$PROJ" --headless --reviewer
  [ "$status" -eq 0 ]
  [[ "$output" == *"ignoring invalid codex GH config dir"* ]]

  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$CAPTURE" ] && break; sleep 0.2; done
  run cat "$CAPTURE"
  [[ "$output" != *"GH_CONFIG_DIR"* ]]
  [[ "$output" != *"$ghdir"* ]]
}

@test "spawn: codex reviewer ignores a non-existent per-worker GH config directory with a warning" {
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  local ghdir="$TEST_SKILL_DIR/no-such-gh-config"
  bash "$SCRIPTS/config.sh" set spawn.codex_gh_config_dir.rv "$ghdir"
  _make_fake_bridge

  run env AGMSG_CODEX_BRIDGE_CMD="$STUB_BIN/fake-bridge.sh" \
    bash "$SCRIPTS/spawn.sh" codex rv --project "$PROJ" --headless --reviewer
  [ "$status" -eq 0 ]
  [[ "$output" == *"ignoring invalid codex GH config dir"* ]]

  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$CAPTURE" ] && break; sleep 0.2; done
  run cat "$CAPTURE"
  [[ "$output" != *"GH_CONFIG_DIR"* ]]
  [[ "$output" != *"$ghdir"* ]]
}

@test "spawn: codex implementer ignores a configured per-worker GH config directory" {
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  local ghdir="$TEST_SKILL_DIR/gh-config-impl"; mkdir -p "$ghdir"
  bash "$SCRIPTS/config.sh" set spawn.codex_gh_config_dir.impl "$ghdir"
  _make_fake_bridge

  run env AGMSG_CODEX_BRIDGE_CMD="$STUB_BIN/fake-bridge.sh" \
    bash "$SCRIPTS/spawn.sh" codex impl --project "$PROJ" --headless --implementer
  [ "$status" -eq 0 ]
  [[ "$output" != *"codex GH config dir"* ]]

  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$CAPTURE" ] && break; sleep 0.2; done
  run cat "$CAPTURE"
  [[ "$output" != *"GH_CONFIG_DIR"* ]]
  [[ "$output" != *"$ghdir"* ]]
}

@test "spawn: codex reviewer drops only GH config injection when its augmented profile probe fails" {
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  export GH_TEST_REJECT_DIR="$TEST_SKILL_DIR/gh-config-rejected"
  mkdir -p "$GH_TEST_REJECT_DIR"
  bash "$SCRIPTS/config.sh" set spawn.codex_gh_config_dir.rv "$GH_TEST_REJECT_DIR"
  _make_fake_bridge
  cat > "$STUB_BIN/codex" <<'CODEX_STUB'
#!/usr/bin/env bash
if [ "$1" = sandbox ]; then
  case "$*" in
    *"$GH_TEST_REJECT_DIR"*) exit 1 ;;
    *"rm -f"*) exit 0 ;;
    *touch*) echo "touch: probe: Operation not permitted" >&2; exit 1 ;;
    *) exit 0 ;;
  esac
fi
exit 0
CODEX_STUB
  chmod +x "$STUB_BIN/codex"

  run env AGMSG_CODEX_BRIDGE_CMD="$STUB_BIN/fake-bridge.sh" \
    bash "$SCRIPTS/spawn.sh" codex rv --project "$PROJ" --headless --reviewer
  [ "$status" -eq 0 ]
  [[ "$output" == *"reviewer codex GH config injection disabled"* ]]
  [[ "$output" == *"spawned headless reviewer codex 'rv'"* ]]

  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$CAPTURE" ] && break; sleep 0.2; done
  run cat "$CAPTURE"
  [[ "$output" != *"GH_CONFIG_DIR"* ]]
  [[ "$output" != *"$GH_TEST_REJECT_DIR"* ]]
}

# --- per-worker model / reasoning-effort override for headless codex ---
# (spawn.codex_model.<name> / spawn.codex_effort.<name>; see
# codex/_spawn.sh's agmsg_codex_model_effort_args). --model (interactive-spawn
# flag, reused here for the headless path) takes precedence over the config
# key for the model id; effort has no CLI flag (headless-only, config only).

@test "spawn --model: headless codex embeds -c model=\"...\" in the app-server command" {
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  _make_fake_bridge

  run env AGMSG_CODEX_BRIDGE_CMD="$STUB_BIN/fake-bridge.sh" \
    bash "$SCRIPTS/spawn.sh" codex reviewer --project "$PROJ" --headless --model gpt-5.6-sol
  [ "$status" -eq 0 ]

  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$CAPTURE" ] && break; sleep 0.2; done
  run cat "$CAPTURE"
  [[ "$output" == *'model="gpt-5.6-sol"'* ]]
}

@test "spawn --model: headless REVIEWER codex also embeds -c model=\"...\" (both appcmd branches)" {
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  _make_fake_bridge

  run env AGMSG_CODEX_BRIDGE_CMD="$STUB_BIN/fake-bridge.sh" \
    bash "$SCRIPTS/spawn.sh" codex rv --project "$PROJ" --headless --reviewer --model gpt-5.6-sol
  [ "$status" -eq 0 ]
  [[ "$output" == *"spawned headless reviewer codex 'rv'"* ]]

  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$CAPTURE" ] && break; sleep 0.2; done
  run cat "$CAPTURE"
  [[ "$output" == *"default_permissions=agmsg-reviewer"* ]]   # confirms the reviewer branch built appcmd
  [[ "$output" == *'model="gpt-5.6-sol"'* ]]
}

@test "spawn: headless codex embeds -c model=\"...\" from config key spawn.codex_model.<name>" {
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  bash "$SCRIPTS/config.sh" set spawn.codex_model.reviewer gpt-5.6-sol
  _make_fake_bridge

  run env AGMSG_CODEX_BRIDGE_CMD="$STUB_BIN/fake-bridge.sh" \
    bash "$SCRIPTS/spawn.sh" codex reviewer --project "$PROJ" --headless
  [ "$status" -eq 0 ]

  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$CAPTURE" ] && break; sleep 0.2; done
  run cat "$CAPTURE"
  [[ "$output" == *'model="gpt-5.6-sol"'* ]]

  # a DIFFERENT name's worker must not pick up reviewer's model.
  rm -f "$CAPTURE"
  run env AGMSG_CODEX_BRIDGE_CMD="$STUB_BIN/fake-bridge.sh" \
    bash "$SCRIPTS/spawn.sh" codex otherworker --project "$PROJ" --headless
  [ "$status" -eq 0 ]
  for i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$CAPTURE" ] && break; sleep 0.2; done
  run cat "$CAPTURE"
  [[ "$output" != *"model="* ]]
}

@test "spawn: --model takes precedence over spawn.codex_model.<name> for headless codex" {
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  bash "$SCRIPTS/config.sh" set spawn.codex_model.reviewer gpt-5-from-config
  _make_fake_bridge

  run env AGMSG_CODEX_BRIDGE_CMD="$STUB_BIN/fake-bridge.sh" \
    bash "$SCRIPTS/spawn.sh" codex reviewer --project "$PROJ" --headless --model gpt-5-from-flag
  [ "$status" -eq 0 ]

  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$CAPTURE" ] && break; sleep 0.2; done
  run cat "$CAPTURE"
  [[ "$output" == *'model="gpt-5-from-flag"'* ]]
  [[ "$output" != *"gpt-5-from-config"* ]]
}

@test "spawn: headless codex embeds -c model_reasoning_effort=\"...\" from config key spawn.codex_effort.<name>" {
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  bash "$SCRIPTS/config.sh" set spawn.codex_effort.reviewer high
  _make_fake_bridge

  run env AGMSG_CODEX_BRIDGE_CMD="$STUB_BIN/fake-bridge.sh" \
    bash "$SCRIPTS/spawn.sh" codex reviewer --project "$PROJ" --headless
  [ "$status" -eq 0 ]

  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$CAPTURE" ] && break; sleep 0.2; done
  run cat "$CAPTURE"
  [[ "$output" == *'model_reasoning_effort="high"'* ]]
}

@test "spawn: an unsafe headless codex model value is ignored, not embedded (fail closed)" {
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  _make_fake_bridge

  run env AGMSG_CODEX_BRIDGE_CMD="$STUB_BIN/fake-bridge.sh" \
    bash "$SCRIPTS/spawn.sh" codex reviewer --project "$PROJ" --headless --model 'foo;rm'
  [ "$status" -eq 0 ]                          # the spawn still proceeds, just without the override
  [[ "$output" == *"ignoring unsafe codex model id"* ]]

  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$CAPTURE" ] && break; sleep 0.2; done
  run cat "$CAPTURE"
  [[ "$output" != *"foo;rm"* ]]                # payload never reached appcmd
  [[ "$output" != *" -c model="* ]]            # no override clause at all
  [[ "$output" != *" -c 'model="* ]]           # the exact splice signature we emit is absent too
}

@test "spawn: a broken/failing 'tr' fails closed for agmsg_codex_model_effort_args (isolated)" {
  # agmsg_codex_safe_token's validation runs entirely through `tr`. If tr is
  # missing/broken, a naive "delete allowed chars, check remainder empty"
  # implementation would see EMPTY output for ANY value (tr never ran, so it
  # never emitted the disallowed bytes either) and misread that as "nothing
  # disallowed" — fail-OPEN.
  #
  # `tr` is ALSO a load-bearing dependency of unrelated agmsg machinery
  # (storage.sh's agmsg_sqlite_mem strips \r via tr for EVERY sqlite call,
  # including join.sh's registration and spawn.sh's own team resolution) — a
  # stub that breaks tr globally on PATH breaks a full `spawn.sh` run for
  # reasons that have nothing to do with this check. Test the helper directly
  # instead: source just the codex spawn plug in an isolated subshell with a
  # broken tr ahead on PATH, and confirm a genuinely unsafe MODEL_ID is still
  # rejected (no `-c 'model=...'` clause in the function's output) rather than
  # silently accepted because tr never ran to report anything disallowed.
  local stubdir="$TEST_SKILL_DIR/broken-tr-stub"
  mkdir -p "$stubdir"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$stubdir/tr"
  chmod +x "$stubdir/tr"

  run env PATH="$stubdir:$PATH" SCRIPT_DIR="$SCRIPTS" MODEL_ID='foo;rm' bash -c '
    set -euo pipefail
    die() { echo "die: $*" >&2; exit 1; }
    . "$SCRIPT_DIR/drivers/types/codex/_spawn.sh"
    agmsg_codex_model_effort_args reviewer
  '
  [ "$status" -eq 0 ]
  [[ "$output" != *"foo;rm"* ]]
  [[ "$output" != *" -c 'model="* ]]
}

@test "spawn: an unsafe headless codex effort config value is ignored, not embedded (fail closed)" {
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  bash "$SCRIPTS/config.sh" set spawn.codex_effort.reviewer 'high; touch pwned'
  _make_fake_bridge

  run env AGMSG_CODEX_BRIDGE_CMD="$STUB_BIN/fake-bridge.sh" \
    bash "$SCRIPTS/spawn.sh" codex reviewer --project "$PROJ" --headless
  [ "$status" -eq 0 ]

  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$CAPTURE" ] && break; sleep 0.2; done
  run cat "$CAPTURE"
  [[ "$output" != *"pwned"* ]]
  [[ "$output" != *"model_reasoning_effort="* ]]
  [[ "$output" != *" -c 'model_reasoning_effort="* ]]   # the exact splice signature we emit is absent too
}

# --- unsafe worker NAME as a config-key segment (spawn.codex_model.<name> /
# spawn.codex_effort.<name> are UNESCAPED awk-ERE field text in config.sh — a
# name legal for actas/validate.sh but containing an ERE metacharacter or a
# space could silently misresolve to the wrong config line) ---

@test "spawn: an unsafe worker name skips the config-key lookup (warns, spawn still succeeds, --model unaffected)" {
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  # Decoy: a DIFFERENT (safe) name's config key must never leak into this one.
  bash "$SCRIPTS/config.sh" set spawn.codex_model.reviewer gpt-5.6-decoy
  _make_fake_bridge

  # No --model: the config lookup for this unsafe name must be skipped outright
  # (not attempted, not merely validated-and-rejected) — no override at all.
  run env AGMSG_CODEX_BRIDGE_CMD="$STUB_BIN/fake-bridge.sh" \
    bash "$SCRIPTS/spawn.sh" codex 'worker+1' --project "$PROJ" --headless
  [ "$status" -eq 0 ]
  [[ "$output" == *"not a safe config-key segment"* ]]
  [[ "$output" == *"spawn.codex_model.<name>/spawn.codex_effort.<name>"* ]]

  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$CAPTURE" ] && break; sleep 0.2; done
  run cat "$CAPTURE"
  [[ "$output" != *" -c model="* ]]
  [[ "$output" != *"gpt-5.6-decoy"* ]]           # the decoy's value never leaked in
  [[ "$output" != *"model_reasoning_effort="* ]]

  # With --model given, the same unsafe name must still warn (config is still
  # skipped) but --model itself is unaffected by the name's safety.
  rm -f "$CAPTURE"
  run env AGMSG_CODEX_BRIDGE_CMD="$STUB_BIN/fake-bridge.sh" \
    bash "$SCRIPTS/spawn.sh" codex 'worker+2' --project "$PROJ" --headless --model gpt-5.6-sol
  [ "$status" -eq 0 ]
  [[ "$output" == *"not a safe config-key segment"* ]]

  for i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$CAPTURE" ] && break; sleep 0.2; done
  run cat "$CAPTURE"
  [[ "$output" == *'model="gpt-5.6-sol"'* ]]
}

@test "spawn: the model/effort -c clauses survive a real shell re-parse as single argv tokens" {
  # codex-bridge.js hands the captured appcmd STRING to
  # spawn("/bin/sh", ["-lc", appcmd]) — sh re-parses it as shell syntax. Go one
  # level past asserting on the string: actually feed it through a shell against
  # a stub "codex" that dumps its argv one-per-line, and assert each -c value
  # arrives as ONE argv token shaped exactly `model="..."` /
  # `model_reasoning_effort="..."` — proving the single-quote/double-quote
  # splice (see agmsg_codex_model_effort_args) isn't split or mangled by the
  # re-parse. Uses `sh -c` (no `-l`): a login shell sources profile scripts that
  # can reorder PATH ahead of our stub dir (observed with Homebrew's
  # path_helper) and pick up a REAL codex binary instead — an environment
  # artifact unrelated to what this test checks (quoting survival), so avoiding
  # `-l` keeps the test deterministic without weakening the thing under test.
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  bash "$SCRIPTS/config.sh" set spawn.codex_effort.reviewer high
  _make_fake_bridge

  run env AGMSG_CODEX_BRIDGE_CMD="$STUB_BIN/fake-bridge.sh" \
    bash "$SCRIPTS/spawn.sh" codex reviewer --project "$PROJ" --headless --model gpt-5.6-sol
  [ "$status" -eq 0 ]

  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$CAPTURE" ] && break; sleep 0.2; done
  local appcmd
  appcmd="$(sed -n 's/^APPCMD: //p' "$CAPTURE")"
  [ -n "$appcmd" ]

  local argvdir="$TEST_SKILL_DIR/argv-stub"
  mkdir -p "$argvdir"
  # Absolute-path shebang (not `#!/usr/bin/env bash`): PATH below is
  # deliberately restricted to ONLY this stub dir (env -i), and `env` would
  # need PATH to find `bash` — an absolute shebang is resolved by the kernel
  # directly, so it needs no PATH lookup at all.
  cat > "$argvdir/codex" <<'STUB'
#!/bin/bash
for a in "$@"; do printf 'ARGV<%s>\n' "$a"; done
STUB
  chmod +x "$argvdir/codex"

  run env -i PATH="$argvdir" /bin/sh -c "$appcmd"
  [ "$status" -eq 0 ]
  [[ "$output" == *'ARGV<model="gpt-5.6-sol">'* ]]
  [[ "$output" == *'ARGV<model_reasoning_effort="high">'* ]]
}

# --- control-byte sanitization of REJECTED values in warnings (#codex-review:
# an unsanitized reject value echoed to stderr could forge an extra log line
# (embedded newline) or an ANSI escape sequence (ESC) — see
# agmsg_codex_sanitize_for_log) ---

@test "spawn: a reject warning strips an embedded newline (no forged extra log line)" {
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  _make_fake_bridge

  local evil
  evil="$(printf 'evilvalue\nPWNED_LINE')"
  run env AGMSG_CODEX_BRIDGE_CMD="$STUB_BIN/fake-bridge.sh" \
    bash "$SCRIPTS/spawn.sh" codex reviewer --project "$PROJ" --headless --model "$evil"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ignoring unsafe codex model id"* ]]
  # The embedded newline must be gone from the warning — it must never appear as
  # its own line (a raw newline immediately followed by the payload's tail).
  [[ "$output" != *$'\n'"PWNED_LINE"* ]]
}

@test "spawn: a reject warning strips embedded ANSI/control bytes (no raw escape reaches stderr)" {
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  _make_fake_bridge

  local ansi_evil
  ansi_evil="$(printf 'evilANSI\x1b[2K\x1b[1A')"
  run env AGMSG_CODEX_BRIDGE_CMD="$STUB_BIN/fake-bridge.sh" \
    bash "$SCRIPTS/spawn.sh" codex reviewer --project "$PROJ" --headless --model "$ansi_evil"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ignoring unsafe codex model id"* ]]
  # No raw ESC (0x1b) byte reaches the combined output — the CSI sequence's
  # printable remainder ("[2K", "[1A") is harmless without its leading ESC.
  [[ "$output" != *$'\x1b'* ]]
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
