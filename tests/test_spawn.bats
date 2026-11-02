#!/usr/bin/env bats

load test_helper

_capture_nonempty() {
  [ -s "$CAPTURE" ]
}

# Parse CODEX_HOME from the fake-bridge launch capture (sets REVIEWER_HOME).
_reviewer_home_from_capture() {
  run cat "$CAPTURE"
  [[ "$output" =~ CODEX_HOME=\'([^\']+)\' ]]
  REVIEWER_HOME="${BASH_REMATCH[1]}"
}

_reviewer_newest_launch_home() {
  find "$HOME/.local/state/agmsg/reviewer-codex-home/${1:-myteam}/${2:-rv}" \
    -maxdepth 1 -type d -name 'launch.*' 2>/dev/null | sort | tail -1
}

_reviewer_source_codex_spawn_plug() {
  TEAM="${1:-myteam}"
  NAME="${2:-rv}"
  SKILL_DIR="$TEST_SKILL_DIR"
  SCRIPT_DIR="$SCRIPTS"
  die() { echo "spawn: $*" >&2; exit 1; }
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/drivers/types/codex/_spawn.sh"
}

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
if [ "$1" = debug ] && [ "$2" = models ]; then
  printf '%s' '{"models":[{"slug":"gpt-5.6-sol","visibility":"list"},{"slug":"gpt-6-sol","visibility":"list"},{"slug":"gpt-10-sol","visibility":"list"},{"slug":"gpt-11-sol","visibility":"hide"},{"slug":"gpt-5.6-luna","visibility":"list"}]}'
  exit 0
fi
if [ "$1" = sandbox ]; then
  case "$*" in
    *"rm -f"*) exit 0 ;;                                                   # positive probe (run/ write) — allowed
    *planted.rules*|*agmsg-not-auth*|*/marker*) echo "Operation not permitted" >&2; exit 1 ;;
    *touch*)   echo "touch: probe: Operation not permitted" >&2; exit 1 ;; # repo write — denied (enforcing)
    *)         exit 0 ;;                                                   # preflight (true) / other — ok
  esac
fi
exit 0
CODEX_STUB
  # Other types need only a trivial success stub.
  for bin in cursor-agent; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB_BIN/$bin"
    chmod +x "$STUB_BIN/$bin"
  done
  chmod +x "$STUB_BIN/claude" "$STUB_BIN/codex"
  export CAPTURE="$TEST_SKILL_DIR/launch-capture.txt"
  cat > "$STUB_BIN/record.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$CAPTURE"
printf 'iterm\t/dev/ttys040\t123\tSat_Sep_13_02:10:11_2026\n' > "\${1}.plain-witness"
EOF
  chmod +x "$STUB_BIN/record.sh"
  export PATH="$STUB_BIN:$PATH"

  # Never inherit a real tmux server or herdr env from the test runner —
  # force the OS-terminal path, which we redirect into record.sh via a {cmd}
  # template. Unsetting HERDR_ENV/HERDR_PANE_ID is critical when the test
  # runner itself is inside herdr: a real herdr pane split would affect the
  # live session.
  unset TMUX
  unset HERDR_ENV HERDR_PANE_ID HERDR_SOCKET_PATH HERDR_WORKSPACE_ID
  unset AGMSG_CURSOR_BRIDGE_FALLBACK_MODEL
  export AGMSG_TERMINAL="$STUB_BIN/record.sh {cmd}"
  export AGMSG_TEST_PLAIN_WITNESS_ROW=$'iterm\t/dev/ttys040\t123\tSat_Sep_13_02:10:11_2026'

  export PROJ="$TEST_SKILL_DIR/proj"
  mkdir -p "$PROJ"
  # shellcheck disable=SC1091
  source "$SCRIPTS/lib/identity-key.sh"
}

teardown() {
  # The fake `codex app-server` (bash, with the python it waits on) is not in
  # any pidfile a failed test is sure to have written, and teardown_test_env
  # only reaps once its plain rm fails -- which it does not on macOS/Linux. So
  # reap everything whose argv names this test's TEST_SKILL_DIR here, always.
  # It reads argv the way the Git Bash path needs (/proc), is scoped to this
  # test's own temp dir, and the python child exits once its parent is gone.
  _reap_test_skill_dir_procs || true
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
  run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$quoted" --no-wait
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
  [[ "$output" =~ "launched claude-code 'alice'" ]]

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

@test "spawn: names the session <team>-<agent> when the type has name_arg (#339)" {
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]

  # claude-code's manifest declares name_arg=-n, so the boot script launches the
  # CLI with `-n myteam-alice` (the resolved team joined to the agent name).
  boot="$(cat "$CAPTURE")"
  run cat "$boot"
  [[ "$output" == *"-n myteam-alice"* ]]
}

@test "spawn: boot script marks the session AGMSG_SPAWNED=1 (#339)" {
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  boot="$(cat "$CAPTURE")"; run cat "$boot"
  # The spawned session carries the marker so the actas flow suppresses the
  # hand-started "rename this session" tip.
  [[ "$output" == *"export AGMSG_SPAWNED=1"* ]]
}

@test "spawn: a type without name_arg emits no name flag (#339)" {
  # codex's manifest has no name_arg=, so the boot script must not name the
  # session -- no bare `-n` token, unchanged from pre-#339 behavior.
  bash "$SCRIPTS/join.sh" gteam existing codex "$PROJ"
  run bash "$SCRIPTS/spawn.sh" codex bob --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]

  boot="$(cat "$CAPTURE")"
  run cat "$boot"
  [[ "$output" != *" -n "* ]]
  [[ "$output" != *"gteam-bob"* ]]
}

# Seed a role-session record + its transcript so spawn's resume path fires.
# Mirrors spawn's own project normalization + the driver's munging so the paths
# line up. With want_transcript=0 the record exists but the transcript does not
# (stale record → spawn must fall back to fresh).
seed_resumable() {
  local team="$1" agent="$2" uuid="$3" proj="$4" want_transcript="${5:-1}"
  local norm munged
  export SKILL_DIR="$TEST_SKILL_DIR"   # both libs below require it at source time
  # shellcheck disable=SC1090
  source "$SCRIPTS/lib/resolve-project.sh"
  norm="$(cd "$proj" && pwd)"
  norm="$(agmsg_normalize_project_path "$norm")"
  # shellcheck disable=SC1090
  source "$SCRIPTS/lib/role-session.sh"
  agmsg_role_session_record "$team" "$agent" "$uuid" "$norm"
  if [ "$want_transcript" -eq 1 ]; then
    munged="$(printf '%s' "$norm" | LC_ALL=C sed 's/[^A-Za-z0-9-]/-/g')"
    mkdir -p "$HOME/.claude/projects/$munged"
    : > "$HOME/.claude/projects/$munged/$uuid.jsonl"
  fi
}

@test "spawn: resumes the role's prior session when record + transcript exist (#339)" {
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  seed_resumable myteam alice "sess-uuid-1" "$PROJ" 1

  run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  boot="$(cat "$CAPTURE")"; run cat "$boot"
  # Resumed by uuid, still named after the role, still runs the actas prompt.
  [[ "$output" == *"--resume sess-uuid-1"* ]]
  [[ "$output" == *"-n myteam-alice"* ]]
  [[ "$output" == *"actas"* ]]
}

@test "spawn: --fresh forces a fresh session even when resumable (#339)" {
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  seed_resumable myteam alice "sess-uuid-1" "$PROJ" 1

  run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait --fresh
  [ "$status" -eq 0 ]
  boot="$(cat "$CAPTURE")"; run cat "$boot"
  [[ "$output" != *"--resume"* ]]
  [[ "$output" == *"-n myteam-alice"* ]]   # naming still applies
}

@test "spawn: falls back to fresh when the record's transcript is gone (#339)" {
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  seed_resumable myteam alice "sess-uuid-1" "$PROJ" 0   # record only, no transcript

  run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  boot="$(cat "$CAPTURE")"; run cat "$boot"
  [[ "$output" != *"--resume"* ]]
}

@test "spawn: a fresh role (no record) boots fresh (#339)" {
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  boot="$(cat "$CAPTURE")"; run cat "$boot"
  [[ "$output" != *"--resume"* ]]
}

@test "spawn: a type without resume_arg never resumes (#339)" {
  # codex has no resume_arg in its manifest, so even with a record present the
  # boot must be fresh (and codex also has no name_arg, so no -n either).
  bash "$SCRIPTS/join.sh" gteam existing codex "$PROJ"
  seed_resumable gteam bob "sess-uuid-9" "$PROJ" 1

  run bash "$SCRIPTS/spawn.sh" codex bob --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  boot="$(cat "$CAPTURE")"; run cat "$boot"
  [[ "$output" != *"--resume"* ]]
}

@test "spawn: codex resumes via the 'resume' subcommand right after the cli (#339)" {
  bash "$SCRIPTS/join.sh" cxteam existing codex "$PROJ"
  # Record a codex role->session and a matching rollout (codex's transcript).
  export SKILL_DIR="$TEST_SKILL_DIR"
  # shellcheck disable=SC1090
  source "$SCRIPTS/lib/role-session.sh"
  agmsg_role_session_record cxteam bob "cx-uuid-1" "$PROJ" codex
  mkdir -p "$HOME/.codex/sessions/2026/07/05"
  : > "$HOME/.codex/sessions/2026/07/05/rollout-2026-07-05T10-00-00-cx-uuid-1.jsonl"

  run bash "$SCRIPTS/spawn.sh" codex bob --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  boot="$(cat "$CAPTURE")"; run cat "$boot"
  # Subcommand shape: `<shim> resume cx-uuid-1 ...` -- resume token right after
  # the executable (the bundled codex-shim.sh, which forwards argv to codex).
  [[ "$output" == *"codex-shim.sh resume cx-uuid-1"* ]]
  [[ "$output" == *"actas"* ]]
  # codex has no name_arg, so no -n.
  [[ "$output" != *" -n "* ]]
}

@test "spawn: codex boots fresh when no rollout backs the record (#339)" {
  bash "$SCRIPTS/join.sh" cxteam existing codex "$PROJ"
  export SKILL_DIR="$TEST_SKILL_DIR"
  # shellcheck disable=SC1090
  source "$SCRIPTS/lib/role-session.sh"
  agmsg_role_session_record cxteam bob "cx-uuid-gone" "$PROJ" codex   # record, no rollout

  run bash "$SCRIPTS/spawn.sh" codex bob --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  boot="$(cat "$CAPTURE")"; run cat "$boot"
  [[ "$output" != *"resume"* ]]
}

@test "spawn: forwards CODEX_HOME across a terminal environment boundary (#1436)" {
  export CODEX_HOME="$TEST_SKILL_DIR/profile with spaces 'quoted' \$(literal)"
  mkdir -p "$CODEX_HOME"
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  # Capture what the launched CLI actually receives without starting Codex or
  # writing any real profile. The terminal shell has no CODEX_HOME of its own.
  printf '#!/usr/bin/env bash\nprintf "%%s" "${CODEX_HOME-unset}" > "$CAPTURE.profile"\n' > "$SCRIPTS/drivers/types/codex/codex-shim.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB_BIN/noshell"
  chmod +x "$STUB_BIN/noshell"
  local expected="$CODEX_HOME" boot
  run bash "$SCRIPTS/spawn.sh" codex alice --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  boot="$(cat "$CAPTURE")"
  run env -u CODEX_HOME SHELL="$STUB_BIN/noshell" bash "$boot"
  [ "$status" -eq 0 ]
  [ "$(cat "$CAPTURE.profile")" = "$expected" ]

  # An unset caller must not override the terminal's existing profile/default.
  run env -u CODEX_HOME bash "$SCRIPTS/spawn.sh" codex bob --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  boot="$(tail -1 "$CAPTURE")"
  run env CODEX_HOME="$expected/terminal" SHELL="$STUB_BIN/noshell" bash "$boot"
  [ "$status" -eq 0 ]
  [ "$(cat "$CAPTURE.profile")" = "$expected/terminal" ]
}

@test "spawn: boot script unsets the type's session-identity vars (#294)" {
  # A same-type spawn (claude-code from a claude-code session) must not leak the
  # parent's CLAUDE_CODE_SESSION_ID to the child, or the child mistakes the
  # parent's session for its own and every turn fails with an Authentication
  # error. The generated boot script unsets the type's detect= vars up front.
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  boot="$(cat "$CAPTURE")"
  [ -f "$boot" ]
  run cat "$boot"
  [[ "$output" == *"unset CLAUDE_CODE_SESSION_ID"* ]]
  # The unset must come before the CLI launch line, so the exec'd child never
  # sees the inherited var.
  run bash -c "grep -n 'unset CLAUDE_CODE_SESSION_ID' '$boot' | cut -d: -f1"
  local unset_line="$output"
  run bash -c "grep -n 'actas' '$boot' | head -1 | cut -d: -f1"
  [ "$unset_line" -lt "$output" ]
}

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
  [[ "$output" == *"codex-shim.sh -m gpt-5"* ]]
}

@test "spawn --model: refused for a type with no model_arg in its manifest" {
  # No real built-in is spawnable without a model_arg — fixture a minimal one,
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

# --- newly spawnable types (#277): cursor ---

@test "spawn: cursor launches cursor-agent with a bare positional prompt" {
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run bash "$SCRIPTS/spawn.sh" cursor alice --project "$PROJ" --model sonnet-4-thinking --no-wait
  [ "$status" -eq 0 ]
  boot="$(cat "$CAPTURE")"
  run cat "$boot"
  [[ "$output" == *"cursor-agent --model sonnet-4-thinking"* ]]
  [[ "$output" == *"actas"* ]]
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
  run env TMUX="/tmp/fake,1,0" TMUX_PANE="%0" PATH="$STUB_BIN:$notmux" \
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

@test "spawn: resolve_team reads team configs via agmsg_sql_readfile_path (Windows-native sqlite3 regression)" {
  # sqlite3.exe (native Windows) cannot readfile() a POSIX-form path: it returns
  # NULL, the JSON probe yields no rows, and spawn dies with 'no team is
  # registered' even though join succeeded. The helper cygpath-converts and
  # SQL-escapes; a bare sed-escape here reintroduces the bug. No portable
  # runtime probe exists (it needs a native sqlite3 plus a POSIX-form tmpdir),
  # so assert the source directly.
  run grep -F 'cfg_sql=$(agmsg_sql_readfile_path "$config_file")' "$SCRIPTS/spawn.sh"
  [ "$status" -eq 0 ]
}

@test "spawn: codex boot prompt uses the \$ skill prefix, not / (#283)" {
  # codex invokes a skill with \$<cmd>, not Claude Code's /<cmd>. The boot script
  # must carry \$<cmd> actas, never /<cmd> actas. (%q escapes the space as "\ ",
  # so match the "<prefix><cmd>\ actas" token — the cd path's /<cmd>/proj has no
  # "\ actas" and so can't false-match the slash form.)
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  run bash "$SCRIPTS/spawn.sh" codex reviewer --project "$PROJ"
  [ "$status" -eq 0 ]
  boot="$(cat "$CAPTURE")"
  [ -f "$boot" ]
  local cmd; cmd="$(basename "$TEST_SKILL_DIR")"
  run grep -F "\$$cmd"'\ actas' "$boot"
  [ "$status" -eq 0 ]
  run grep -F "/$cmd"'\ actas' "$boot"
  [ "$status" -ne 0 ]
}

@test "spawn: claude-code boot prompt keeps the / slash prefix (#283)" {
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  boot="$(cat "$CAPTURE")"
  [ -f "$boot" ]
  local cmd; cmd="$(basename "$TEST_SKILL_DIR")"
  run grep -F "/$cmd"'\ actas' "$boot"
  [ "$status" -eq 0 ]
  run grep -F "\$$cmd"'\ actas' "$boot"
  [ "$status" -ne 0 ]
}

@test "spawn: '/'-prefixed boot prompt is guarded against MSYS path conversion" {
  # On Git Bash / MSYS, an argv token starting with '/' is rewritten to a
  # Windows path when handed to a native binary: '/agmsg actas alice' arrives
  # as 'C:/Program Files/Git/agmsg actas alice'. The boot script must scope it
  # out via MSYS2_ARG_CONV_EXCL on the CLI launch line (prefix-scoped, NOT
  # MSYS_NO_PATHCONV=1, so genuine path args keep converting).
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  boot="$(cat "$CAPTURE")"
  [ -f "$boot" ]
  local cmd; cmd="$(basename "$TEST_SKILL_DIR")"
  # The guard must sit on the same line as the CLI invocation, ahead of it.
  run grep -E "^MSYS2_ARG_CONV_EXCL=/$cmd claude" "$boot"
  [ "$status" -eq 0 ]
}

@test "spawn: \$-prefixed boot prompt gets no MSYS guard (codex)" {
  # '$'-prefixed prompts are not path-shaped, so no exclusion is emitted —
  # keeps the boot script byte-identical for agentskills CLIs.
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  run bash "$SCRIPTS/spawn.sh" codex reviewer --project "$PROJ"
  [ "$status" -eq 0 ]
  boot="$(cat "$CAPTURE")"
  [ -f "$boot" ]
  run grep -F "MSYS2_ARG_CONV_EXCL" "$boot"
  [ "$status" -ne 0 ]
}

@test "spawn: boot script keeps the .command suffix only on macOS (#282)" {
  # macOS `open -a Terminal` needs .command to execute the file; every other
  # launcher runs it via bash or its shebang, and on Windows .command makes
  # Explorer/psmux open it in Notepad instead of running it.
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  boot="$(cat "$CAPTURE")"
  [ -f "$boot" ]
  if [ "$(uname -s)" = "Darwin" ]; then
    [[ "$boot" == *.command ]]
  else
    [[ "$boot" != *.command ]]
  fi
}

@test "spawn: macOS terminal launch does not steal focus (Terminal and iTerm)" {
  # A no-op-Terminal spawn (no $TMUX, no AGMSG_TERMINAL override) exercises
  # launch_macos_terminal() itself, which every other test in this file
  # bypasses via the record.sh {cmd} template. `-g`/`--background` must be
  # present so `open` never brings the newly launched terminal to the front
  # -- without it, spawning from a caller with no tmux context (e.g. a GUI
  # app) interrupts whatever the user is doing in the foreground app.
  if [ "$(uname -s)" != "Darwin" ]; then
    skip "launch_macos_terminal() is Darwin-only"
  fi
  unset AGMSG_TERMINAL
  # Deterministic regardless of which terminal actually runs this test suite
  # (launch_macos_terminal defaults to "iterm" when $TERM_PROGRAM is
  # iTerm.app, which would otherwise make this assertion flaky on an iTerm
  # dev machine).
  unset TERM_PROGRAM
  cat > "$STUB_BIN/open" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$CAPTURE"
EOF
  chmod +x "$STUB_BIN/open"

  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  run cat "$CAPTURE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"-g -a Terminal"* ]]

  rm -f "$CAPTURE"
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  AGMSG_TERMINAL=iterm run bash "$SCRIPTS/spawn.sh" codex bob --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  run cat "$CAPTURE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"-g -a iTerm"* ]]
}

# --- pre-flight exclusivity check ---

@test "spawn: refuses when the name is held by another live session" {
  bash "$SCRIPTS/join.sh" myteam alice claude-code "$PROJ"
  # Forge a live owner for (myteam, alice).
  setup_live_owner "$TEST_SKILL_DIR/run" LIVESID
  printf '%s\n' LIVESID > "$(_actas_session_path myteam alice)"

  run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "held by a live session" ]]
}

# --- readiness handshake (#108) ---

@test "spawn: readiness handshake returns status=ready when the watcher attaches" {
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  bash "$SCRIPTS/delivery.sh" set monitor claude-code "$PROJ" >/dev/null
  mkdir -p "$TEST_SKILL_DIR/run"
  # alice must already be in the roster before resolving her ready path: #1023
  # mints her member_id on join, and spawn.sh's OWN internal join.sh call (which
  # runs before it resolves its own READY_PATH) will do the exact same thing --
  # joining here first, idempotently, is what makes the two resolutions agree.
  bash "$SCRIPTS/join.sh" myteam alice claude-code "$PROJ" >/dev/null
  local ready="$(_ready_path myteam alice)"
  # The terminal "launch" just touches the ready sentinel (and comments out the
  # boot script so its interactive shell never runs in the test).
  run env -u TMUX bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" \
    --ready-timeout 10 --terminal "touch $ready # {cmd}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=ready"* ]]
}

@test "spawn: readiness handshake times out (status=timeout, exit 3) when nothing attaches" {
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  bash "$SCRIPTS/delivery.sh" set monitor claude-code "$PROJ" >/dev/null
  run env -u TMUX bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" \
    --ready-timeout 2 --terminal "true # {cmd}"
  [ "$status" -eq 3 ]
  [[ "$output" == *"status=timeout"* ]]
}

@test "spawn: a monitor-capable type skips readiness when project delivery is off (#647)" {
  # No hooks configured means this project's observable delivery mode is off.
  # A claude-code type can produce a readiness sentinel, but no watcher will be
  # started for this project, so waiting would only reach the timeout.
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  bash "$SCRIPTS/delivery.sh" set off claude-code "$PROJ" >/dev/null
  run env -u TMUX bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" \
    --ready-timeout 2 --terminal "true # {cmd}"
  [ "$status" -eq 0 ]
  grep -q "project delivery mode is 'off'" <<<"$output"
  grep -q "status=launched-unconfirmed" <<<"$output"
  grep -q "note=no-monitor-delivery" <<<"$output"
  refute grep -q "status=timeout" <<<"$output"
}

@test "spawn: a failed delivery status keeps the readiness wait fail-closed (#647)" {
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  local delivery="$SCRIPTS/delivery.sh"
  mv "$delivery" "$delivery.real"
  cat > "$delivery" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$delivery"
  run env -u TMUX bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" \
    --ready-timeout 1 --terminal "true # {cmd}"
  [ "$status" -eq 3 ]
  grep -q "delivery status failed" <<<"$output"
  grep -q "status=timeout" <<<"$output"
  refute grep -q "no-monitor-delivery" <<<"$output"
}

@test "spawn: an unrecognized delivery status from the real command keeps the wait fail-closed (#647)" {
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run bash "$SCRIPTS/delivery.sh" status claude-code "$PROJ"
  [ "$status" -eq 0 ]
  grep -q "mode: off (unrecognized:" <<<"$output"
  run env -u TMUX bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" \
    --ready-timeout 1 --terminal "true # {cmd}"
  [ "$status" -eq 3 ]
  grep -q "status output was not recognized" <<<"$output"
  grep -q "status=timeout" <<<"$output"
  refute grep -q "no-monitor-delivery" <<<"$output"
}

@test "spawn: unrecognized delivery status keeps the readiness wait fail-closed (#647)" {
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  local delivery="$SCRIPTS/delivery.sh"
  mv "$delivery" "$delivery.real"
  cat > "$delivery" <<'EOF'
#!/usr/bin/env bash
printf 'mode: maybe\n'
EOF
  chmod +x "$delivery"
  run env -u TMUX bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" \
    --ready-timeout 1 --terminal "true # {cmd}"
  [ "$status" -eq 3 ]
  grep -q "status output was not recognized" <<<"$output"
  grep -q "status=timeout" <<<"$output"
  refute grep -q "no-monitor-delivery" <<<"$output"
}

@test "spawn: a known delivery prefix with a suffix remains unrecognized (#647)" {
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  local delivery="$SCRIPTS/delivery.sh"
  mv "$delivery" "$delivery.real"
  cat > "$delivery" <<'EOF'
#!/usr/bin/env bash
printf 'mode: turnips\n'
EOF
  chmod +x "$delivery"
  run env -u TMUX bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" \
    --ready-timeout 1 --terminal "true # {cmd}"
  [ "$status" -eq 3 ]
  grep -q "status output was not recognized" <<<"$output"
  grep -q "status=timeout" <<<"$output"
  refute grep -q "no-monitor-delivery" <<<"$output"
}

@test "spawn: a suffixed explicit off status does not skip readiness (#647)" {
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  local delivery="$SCRIPTS/delivery.sh"
  mv "$delivery" "$delivery.real"
  cat > "$delivery" <<'EOF'
#!/usr/bin/env bash
printf 'mode: off (no agmsg delivery hooks installed for this project) garbage\n'
EOF
  chmod +x "$delivery"
  run env -u TMUX bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" \
    --ready-timeout 1 --terminal "true # {cmd}"
  [ "$status" -eq 3 ]
  grep -q "status output was not recognized" <<<"$output"
  grep -q "status=timeout" <<<"$output"
  refute grep -q "no-monitor-delivery" <<<"$output"
}

@test "spawn: --no-wait on a readiness_sentinel=YES type still reports launched-unconfirmed (no post-input confirmation)" {
  # Full-head review: --no-wait skips the readiness handshake by request, so startup is
  # NOT confirmed — exactly like readiness_sentinel=no. Both no-confirmation paths must report
  # status=launched-unconfirmed (a distinct note keeps the reasons apart). A readiness_sentinel=YES
  # type (claude-code) with --no-wait is the arm that was silently falling through both
  # branches with no status line at all.
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  grep -q "status=launched-unconfirmed" <<<"$output"
  grep -q "note=no-wait" <<<"$output"
  refute grep -q "status=ready" <<<"$output"
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
# printf can split a record into several writes; one cat of this small record is one
# write, so a reader that sees CAPTURE non-empty sees all three lines.
rec="$CAPTURE.rec.\$\$"
printf 'ARGS: %s\nTURN_TIMEOUT: %s\nAPPCMD: %s\n' "\$*" "\${AGMSG_CODEX_BRIDGE_TURN_TIMEOUT:-}" "\${AGMSG_CODEX_APP_SERVER_CMD:-}" > "\$rec"
cat "\$rec" >> "$CAPTURE"
rm -f "\$rec"
exit 0
EOF
  chmod +x "$STUB_BIN/fake-bridge.sh"
}

# Fake Cursor create-chat + bridge pair for headless spawn argv tests. The
# bridge exits immediately after recording its argv; no real cursor turn runs.
_make_fake_cursor_headless() {
  export CURSOR_CLI_CAPTURE="$TEST_SKILL_DIR/cursor-cli-capture.txt"
  : > "$CURSOR_CLI_CAPTURE"
  cat > "$STUB_BIN/cursor-agent" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CURSOR_CLI_CAPTURE"
if [ "${1:-}" = create-chat ]; then
  printf '%s\n' 11111111-2222-3333-4444-555555555555
  exit 0
fi
exit 1
STUB
  cat > "$STUB_BIN/fake-cursor-bridge.sh" <<EOF
#!/usr/bin/env bash
printf 'CURSOR_ARGS: %s\n' "\$*" >> "$CAPTURE"
exit 0
EOF
  chmod +x "$STUB_BIN/cursor-agent" "$STUB_BIN/fake-cursor-bridge.sh"
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
  wait_until 10 _capture_nonempty
  run cat "$CAPTURE"
  [[ "$output" == *"--type codex"* ]]
  [[ "$output" == *$'--pair myteam\treviewer'* ]]
  [[ "$output" != *"--team myteam"* ]]
  [[ "$output" != *"--name reviewer"* ]]
  [[ "$output" == *"--workspace-root $TEST_SKILL_DIR/db"* ]]
  [[ "$output" == *"--workspace-root $TEST_SKILL_DIR/teams"* ]]
  [[ "$output" == *"--workspace-root $TEST_SKILL_DIR/run"* ]]
  [[ "$output" == *"--inline-inbox"* ]]
  [[ "$output" == *"codex-myteam-cwd"* ]]                # --project = scratch cwd
  [[ "$output" == *"default_permissions=agmsg-consultant"* ]]
  [[ "$output" != *"sandbox_mode=workspace-write"* ]]
  [[ "$output" == *"approval_policy=never"* ]]
  [[ "$output" == *"web_search=live"* ]]
  [[ "$output" == *"permissions.agmsg-consultant.filesystem="* ]]
  [[ "$output" == *"permissions.agmsg-consultant.network={ enabled=false }"* ]]
  [[ "$output" != *"--enable network_proxy"* ]]
  [[ "$output" != *"CODEX_HOME="* ]]
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

@test "spawn: codex duplicate scan does not match a longer identity-key prefix" {
  # tt<TAB>aaa and tt<TAB>aaabbb produce prefix-related legacy base64 keys.
  local legacy_short legacy_long long_key short_key
  legacy_short="$(printf '%s\t%s' tt aaa | base64 | tr -d '\r\n' | tr '+/' '-_')"
  legacy_long="$(printf '%s\t%s' tt aaabbb | base64 | tr -d '\r\n' | tr '+/' '-_')"
  [[ "$legacy_short" != *"="* ]]
  [[ "$legacy_long" == "$legacy_short"* ]]
  long_key="$(agmsg_identity_key tt aaabbb)"
  short_key="$(agmsg_identity_key tt aaa)"

  bash "$SCRIPTS/join.sh" tt existing codex "$PROJ"
  _make_fake_bridge
  cat > "$STUB_BIN/pgrep" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"codex-bridge\\.js"*) printf '%s\n' 424242 ;;
esac
STUB
  cat > "$STUB_BIN/ps" <<'STUB'
#!/usr/bin/env bash
if [ "$*" = "-ww -o args= -p 424242" ]; then
  printf 'node /x/codex-bridge.js --identity-key %s --pair tt\\taaabbb\n' \
    "$LONG_IDENTITY_KEY"
  exit 0
fi
exit 1
STUB
  chmod +x "$STUB_BIN/pgrep" "$STUB_BIN/ps"

  run env AGMSG_CODEX_BRIDGE_CMD="$STUB_BIN/fake-bridge.sh" \
    LONG_IDENTITY_KEY="$long_key" \
    bash "$SCRIPTS/spawn.sh" codex aaa --team tt --project "$PROJ" --headless
  [ "$status" -eq 0 ]
  [[ "$output" == *"spawned headless codex 'aaa'"* ]]
  [[ "$output" != *"already running"* ]]
  wait_for_file_contains "$CAPTURE" "--identity-key $short_key"
  grep -qF -- "--identity-key $short_key" "$CAPTURE"
}

@test "spawn: cursor duplicate scan does not match a longer identity-key prefix" {
  local legacy_short legacy_long long_key short_key
  legacy_short="$(printf '%s\t%s' tt aaa | base64 | tr -d '\r\n' | tr '+/' '-_')"
  legacy_long="$(printf '%s\t%s' tt aaabbb | base64 | tr -d '\r\n' | tr '+/' '-_')"
  [[ "$legacy_short" != *"="* ]]
  [[ "$legacy_long" == "$legacy_short"* ]]
  long_key="$(agmsg_identity_key tt aaabbb)"
  short_key="$(agmsg_identity_key tt aaa)"

  bash "$SCRIPTS/join.sh" tt existing cursor "$PROJ"
  cat > "$STUB_BIN/cursor-agent" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "create-chat" ]; then
  printf '%s\n' 11111111-2222-3333-4444-555555555555
fi
STUB
  cat > "$STUB_BIN/fake-cursor-bridge.sh" <<EOF
#!/usr/bin/env bash
printf 'CURSOR_ARGS: %s\n' "\$*" >> "$CAPTURE"
exit 0
EOF
  cat > "$STUB_BIN/pgrep" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"cursor-bridge\\.sh"*) printf '%s\n' 424243 ;;
esac
STUB
  cat > "$STUB_BIN/ps" <<'STUB'
#!/usr/bin/env bash
if [ "$*" = "-ww -o args= -p 424243" ]; then
  printf 'bash /x/cursor-bridge.sh --identity-key %s\n' "$LONG_IDENTITY_KEY"
  exit 0
fi
exit 1
STUB
  chmod +x "$STUB_BIN/cursor-agent" "$STUB_BIN/fake-cursor-bridge.sh" \
    "$STUB_BIN/pgrep" "$STUB_BIN/ps"

  run env AGMSG_CURSOR_BRIDGE_CMD="$STUB_BIN/fake-cursor-bridge.sh" \
    LONG_IDENTITY_KEY="$long_key" \
    bash "$SCRIPTS/spawn.sh" cursor aaa --team tt --project "$PROJ" --headless
  [ "$status" -eq 0 ]
  [[ "$output" == *"spawned headless cursor reviewer 'aaa'"* ]]
  [[ "$output" != *"already running"* ]]
  wait_for_file_contains "$CAPTURE" "--identity-key $short_key"
  grep -qF -- "--identity-key $short_key" "$CAPTURE"
}

# --- headless cursor model pin / label / fallback resolution -----------------

@test "spawn: unpinned headless cursor preserves legacy model and fallback defaults" {
  bash "$SCRIPTS/join.sh" myteam existing cursor "$PROJ"
  _make_fake_cursor_headless

  run env AGMSG_CURSOR_BRIDGE_CMD="$STUB_BIN/fake-cursor-bridge.sh" \
    bash "$SCRIPTS/spawn.sh" cursor cur --team myteam --project "$PROJ" --headless
  [ "$status" -eq 0 ]
  wait_until 10 _capture_nonempty
  run cat "$CAPTURE"
  [[ "$output" != *"--model "* ]]
  [[ "$output" != *"--fallback-model"* ]]
  [[ "$output" != *"--no-fallback"* ]]
  [[ "$output" != *"--model none"* ]]
}

@test "spawn: cursor config pin and label are passed to the bridge" {
  bash "$SCRIPTS/join.sh" myteam existing cursor "$PROJ"
  bash "$SCRIPTS/config.sh" set spawn.cursor_model.cur grok-4.6
  bash "$SCRIPTS/config.sh" set spawn.cursor_model_label.cur "Cursor Grok 4.6 High Fast"
  _make_fake_cursor_headless

  run env AGMSG_CURSOR_BRIDGE_CMD="$STUB_BIN/fake-cursor-bridge.sh" \
    bash "$SCRIPTS/spawn.sh" cursor cur --team myteam --project "$PROJ" --headless
  [ "$status" -eq 0 ]
  wait_until 10 _capture_nonempty
  run cat "$CAPTURE"
  [[ "$output" == *"--model grok-4.6"* ]]
  [[ "$output" == *"--model-label Cursor Grok 4.6 High Fast"* ]]
  [[ "$output" == *"--no-fallback"* ]]
}

@test "spawn: cursor config turn timeout is passed to the bridge as --turn-timeout" {
  bash "$SCRIPTS/join.sh" myteam existing cursor "$PROJ"
  bash "$SCRIPTS/config.sh" set spawn.cursor_turn_timeout.cur 900
  _make_fake_cursor_headless

  run env AGMSG_CURSOR_BRIDGE_CMD="$STUB_BIN/fake-cursor-bridge.sh" \
    bash "$SCRIPTS/spawn.sh" cursor cur --team myteam --project "$PROJ" --headless
  [ "$status" -eq 0 ]
  wait_until 10 _capture_nonempty
  run cat "$CAPTURE"
  [[ "$output" == *"--turn-timeout 900"* ]]
}

@test "spawn: cursor without a turn timeout config leaves --turn-timeout to the bridge" {
  bash "$SCRIPTS/join.sh" myteam existing cursor "$PROJ"
  _make_fake_cursor_headless

  run env AGMSG_CURSOR_BRIDGE_CMD="$STUB_BIN/fake-cursor-bridge.sh" \
    bash "$SCRIPTS/spawn.sh" cursor cur --team myteam --project "$PROJ" --headless
  [ "$status" -eq 0 ]
  wait_until 10 _capture_nonempty
  run cat "$CAPTURE"
  [[ "$output" != *"--turn-timeout"* ]]
}

@test "spawn: cursor invalid turn timeout config is ignored with a warning" {
  bash "$SCRIPTS/join.sh" myteam existing cursor "$PROJ"
  bash "$SCRIPTS/config.sh" set spawn.cursor_turn_timeout.cur 0003
  _make_fake_cursor_headless

  run env AGMSG_CURSOR_BRIDGE_CMD="$STUB_BIN/fake-cursor-bridge.sh" \
    bash "$SCRIPTS/spawn.sh" cursor cur --team myteam --project "$PROJ" --headless
  [ "$status" -eq 0 ]
  [[ "$output" == *"ignoring invalid cursor turn timeout"* ]]
  wait_until 10 _capture_nonempty
  run cat "$CAPTURE"
  [[ "$output" != *"--turn-timeout"* ]]
}

@test "spawn: cursor pipe-separated model label is one argv to the bridge" {
  bash "$SCRIPTS/join.sh" myteam existing cursor "$PROJ"
  bash "$SCRIPTS/config.sh" set spawn.cursor_model.cur grok-4.6
  bash "$SCRIPTS/config.sh" set spawn.cursor_model_label.cur "Cursor Grok 4.6 Extra High|Cursor Grok 4.6 High Fast"
  _make_fake_cursor_headless

  run env AGMSG_CURSOR_BRIDGE_CMD="$STUB_BIN/fake-cursor-bridge.sh" \
    bash "$SCRIPTS/spawn.sh" cursor cur --team myteam --project "$PROJ" --headless
  [ "$status" -eq 0 ]
  wait_until 10 _capture_nonempty
  run cat "$CAPTURE"
  [[ "$output" == *"--model-label Cursor Grok 4.6 Extra High|Cursor Grok 4.6 High Fast"* ]]
}

@test "spawn: explicit cursor --model wins over the matching worker config" {
  bash "$SCRIPTS/join.sh" myteam existing cursor "$PROJ"
  bash "$SCRIPTS/config.sh" set spawn.cursor_model.cur from-config
  _make_fake_cursor_headless

  run env AGMSG_CURSOR_BRIDGE_CMD="$STUB_BIN/fake-cursor-bridge.sh" \
    bash "$SCRIPTS/spawn.sh" cursor cur --team myteam --project "$PROJ" \
      --headless --model from-flag
  [ "$status" -eq 0 ]
  wait_until 10 _capture_nonempty
  run cat "$CAPTURE"
  [[ "$output" == *"--model from-flag"* ]]
  [[ "$output" != *"from-config"* ]]
}

@test "spawn: cursor model config never leaks to another worker" {
  bash "$SCRIPTS/join.sh" myteam existing cursor "$PROJ"
  bash "$SCRIPTS/config.sh" set spawn.cursor_model.cur grok-4.6
  _make_fake_cursor_headless

  run env AGMSG_CURSOR_BRIDGE_CMD="$STUB_BIN/fake-cursor-bridge.sh" \
    bash "$SCRIPTS/spawn.sh" cursor other --team myteam --project "$PROJ" --headless
  [ "$status" -eq 0 ]
  wait_until 10 _capture_nonempty
  run cat "$CAPTURE"
  [[ "$output" != *"grok-4.6"* ]]
  [[ "$output" != *"--model "* ]]
}

@test "spawn: per-worker cursor fallback config wins over a non-empty environment" {
  bash "$SCRIPTS/join.sh" myteam existing cursor "$PROJ"
  bash "$SCRIPTS/config.sh" set spawn.cursor_fallback_model.cur configured-fallback
  _make_fake_cursor_headless

  run env AGMSG_CURSOR_BRIDGE_CMD="$STUB_BIN/fake-cursor-bridge.sh" \
    AGMSG_CURSOR_BRIDGE_FALLBACK_MODEL=env-fallback \
    bash "$SCRIPTS/spawn.sh" cursor cur --team myteam --project "$PROJ" --headless
  [ "$status" -eq 0 ]
  wait_until 10 _capture_nonempty
  run cat "$CAPTURE"
  [[ "$output" == *"--fallback-model configured-fallback"* ]]
  [[ "$output" != *"env-fallback"* ]]
}

@test "spawn: non-empty and explicitly-empty fallback env remain distinct" {
  bash "$SCRIPTS/join.sh" myteam existing cursor "$PROJ"
  _make_fake_cursor_headless

  run env AGMSG_CURSOR_BRIDGE_CMD="$STUB_BIN/fake-cursor-bridge.sh" \
    AGMSG_CURSOR_BRIDGE_FALLBACK_MODEL=env-fallback \
    bash "$SCRIPTS/spawn.sh" cursor envworker --team myteam --project "$PROJ" --headless
  [ "$status" -eq 0 ]
  wait_until 10 _capture_nonempty
  grep -q -- "--fallback-model env-fallback" "$CAPTURE"

  : > "$CAPTURE"
  run env AGMSG_CURSOR_BRIDGE_CMD="$STUB_BIN/fake-cursor-bridge.sh" \
    AGMSG_CURSOR_BRIDGE_FALLBACK_MODEL= \
    bash "$SCRIPTS/spawn.sh" cursor emptyworker --team myteam --project "$PROJ" --headless
  [ "$status" -eq 0 ]
  wait_until 10 _capture_nonempty
  grep -q -- "--no-fallback" "$CAPTURE"
  ! grep -q -- "--model none" "$CAPTURE"
}

@test "spawn: malformed cursor model ids fail before create-chat while unknown safe ids pass through" {
  bash "$SCRIPTS/join.sh" myteam existing cursor "$PROJ"
  _make_fake_cursor_headless
  local value
  for value in "" " " "-option" $'bad\nmodel' $'bad\x1bmodel'; do
    run env AGMSG_CURSOR_BRIDGE_CMD="$STUB_BIN/fake-cursor-bridge.sh" \
      bash "$SCRIPTS/spawn.sh" cursor cur --team myteam --project "$PROJ" \
        --headless --model "$value"
    [ "$status" -ne 0 ]
  done
  [ ! -s "$CURSOR_CLI_CAPTURE" ]
  [ ! -s "$CAPTURE" ]

  # Character-valid unknown ids cannot be resolved without calling the external
  # CLI. Spawn accepts them; a real worker would surface rejection on turn one.
  run env AGMSG_CURSOR_BRIDGE_CMD="$STUB_BIN/fake-cursor-bridge.sh" \
    bash "$SCRIPTS/spawn.sh" cursor cur --team myteam --project "$PROJ" \
      --headless --model future-model_9.9
  [ "$status" -eq 0 ]
  wait_until 10 _capture_nonempty
  grep -q -- "--model future-model_9.9" "$CAPTURE"
}

@test "spawn: malformed cursor fallback values fail closed without option injection" {
  bash "$SCRIPTS/join.sh" myteam existing cursor "$PROJ"
  _make_fake_cursor_headless
  local value
  for value in "bad fallback" "-option"; do
    bash "$SCRIPTS/config.sh" set spawn.cursor_fallback_model.cur "$value" >/dev/null
    run env AGMSG_CURSOR_BRIDGE_CMD="$STUB_BIN/fake-cursor-bridge.sh" \
      bash "$SCRIPTS/spawn.sh" cursor cur --team myteam --project "$PROJ" --headless
    [ "$status" -ne 0 ]
    [[ "$output" == *"unsafe cursor fallback model id"* ]]
  done
  for value in $'bad\nfallback' $'bad\x1bfallback'; do
    run env AGMSG_CURSOR_BRIDGE_CMD="$STUB_BIN/fake-cursor-bridge.sh" \
      AGMSG_CURSOR_BRIDGE_FALLBACK_MODEL="$value" \
      bash "$SCRIPTS/spawn.sh" cursor envworker --team myteam --project "$PROJ" --headless
    [ "$status" -ne 0 ]
    [[ "$output" == *"unsafe cursor fallback model id"* ]]
  done
  [ ! -s "$CURSOR_CLI_CAPTURE" ]
  [ ! -s "$CAPTURE" ]
}

@test "spawn: cursor model rejection sanitizes newline and control bytes" {
  bash "$SCRIPTS/join.sh" myteam existing cursor "$PROJ"
  _make_fake_cursor_headless
  local value
  value="$(printf 'bad\nFORGED\x1bmodel')"
  run env AGMSG_CURSOR_BRIDGE_CMD="$STUB_BIN/fake-cursor-bridge.sh" \
    bash "$SCRIPTS/spawn.sh" cursor cur --team myteam --project "$PROJ" \
      --headless --model "$value"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unsafe cursor model id"* ]]
  [[ "$output" != *$'\n'"FORGED"* ]]
  [[ "$output" != *$'\x1b'* ]]
}

@test "spawn: cursor per-worker config read failure never degrades to unpinned" {
  bash "$SCRIPTS/join.sh" myteam existing cursor "$PROJ"
  _make_fake_cursor_headless
  mv "$SCRIPTS/config.sh" "$SCRIPTS/config-real.sh"
  cat > "$SCRIPTS/config.sh" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = get ] && [[ "\${2:-}" == spawn.cursor_model.* ]]; then
  exit 9
fi
exec "$SCRIPTS/config-real.sh" "\$@"
EOF
  chmod +x "$SCRIPTS/config.sh"

  run env AGMSG_CURSOR_BRIDGE_CMD="$STUB_BIN/fake-cursor-bridge.sh" \
    bash "$SCRIPTS/spawn.sh" cursor cur --team myteam --project "$PROJ" --headless
  [ "$status" -ne 0 ]
  [[ "$output" == *"failed to read spawn.cursor_model.cur"* ]]
  [ ! -s "$CURSOR_CLI_CAPTURE" ]
  [ ! -s "$CAPTURE" ]
}

@test "spawn: codex bridge runtime roots include write extra roots but exclude read-only extra roots" {
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  local readroot="$TEST_SKILL_DIR/extra-read"
  local writeroot="$TEST_SKILL_DIR/extra-write"
  mkdir -p "$readroot" "$writeroot"
  bash "$SCRIPTS/config.sh" set spawn.codex_extra_fs_roots "$readroot=read,$writeroot=write"
  _make_fake_bridge

  run env AGMSG_CODEX_BRIDGE_CMD="$STUB_BIN/fake-bridge.sh" \
    bash "$SCRIPTS/spawn.sh" codex rootsworker --project "$PROJ" --headless
  [ "$status" -eq 0 ]

  local i
  wait_until 10 _capture_nonempty
  local args appcmd
  args="$(sed -n 's/^ARGS: //p' "$CAPTURE")"
  appcmd="$(sed -n 's/^APPCMD: //p' "$CAPTURE")"
  [[ "$args" == *"--workspace-root $writeroot"* ]]
  [[ "$args" != *"--workspace-root $readroot"* ]]
  [[ "$appcmd" == *"\"$readroot\"=\"read\""* ]]
  [[ "$appcmd" == *"\"$writeroot\"=\"write\""* ]]
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

  local i home
  wait_until 10 _capture_nonempty
  run cat "$CAPTURE"
  [[ "$output" == *$'--pair myteam\trv'* ]]
  [[ "$output" == *"--project $PROJ"* ]]
  [[ "$output" != *"codex-myteam-cwd"* ]]
  [[ "$output" == *"default_permissions=agmsg-reviewer"* ]]
  [[ "$output" == *"permissions.agmsg-reviewer.filesystem="* ]]
  [[ "$output" == *":workspace_roots"* ]]
  [[ "$output" != *"sandbox_mode=workspace-write"* ]]
  [[ "$output" == *"--enable network_proxy"* ]]
  codex_bin="$(type -P codex)"
  [[ "$codex_bin" == /* ]]
  [[ "$output" == *"$codex_bin app-server"* ]]
  [[ "$output" == *'"github.com"="allow"'* ]]
  [[ "$output" == *'"api.github.com"="allow"'* ]]
  [[ "$output" == *'"codeload.github.com"="allow"'* ]]
  [[ "$output" == *'"uploads.github.com"="allow"'* ]]
  [[ "$output" == *'"gist.github.com"="allow"'* ]]
  [[ "$output" == *'"objects.githubusercontent.com"="allow"'* ]]
  [[ "$output" == *'"raw.githubusercontent.com"="allow"'* ]]
  [[ "$output" != *'"example.com"="allow"'* ]]
  [ "$(printf '%s\n' "$output" | grep -o '="allow"' | wc -l | tr -d ' ')" -eq 7 ]
  [[ "$output" =~ CODEX_HOME=\'([^\']+)\' ]]
  home="${BASH_REMATCH[1]}"
  [[ "$output" == *"\"$HOME/.local/state/agmsg/reviewer-codex-home\"=\"none\""* ]]
  [[ "$output" == *"\"$TEST_SKILL_DIR/reviewer-codex-home\"=\"none\""* ]]
  [ "$(printf '%s\n' "$output" | grep -o "$home" | wc -l | tr -d ' ')" -eq 1 ]
  [ -d "$home/rules" ]
  [ -z "$(ls -A "$home/rules")" ]
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
  wait_until 10 _capture_nonempty
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

# The codex stub executes the network probe's inner shell. A fake curl on PATH
# decides each branch, so inverting or deleting a check in that shell fails
# the test. Write probes stay classified as they are for a real enforcing build.
_install_reviewer_network_stub() {
  local curldir="$TEST_SKILL_DIR/fake-curl"
  mkdir -p "$curldir"
  cat > "$curldir/curl" <<'EOF'
#!/usr/bin/env bash
joined="$*"
if [[ "$joined" == *example.com* ]]; then
  [ "${AGMSG_FAKE_CURL_MODE:-}" = allow-example ] && exit 0
  exit 56
fi
if [[ "$joined" == *1.1.1.1* ]]; then
  [ "${AGMSG_FAKE_CURL_MODE:-}" = allow-ip ] && exit 0
  exit 7
fi
if [[ "$joined" == *api.github.com* ]]; then
  if [ "${AGMSG_FAKE_CURL_MODE:-}" = deny-api ]; then
    echo "api-unreachable" >&2
    exit 28
  fi
  exit 0
fi
echo "unexpected curl: $joined" >&2
exit 99
EOF
  chmod +x "$curldir/curl"
  cat > "$STUB_BIN/codex" <<EOF
#!/usr/bin/env bash
prev=""
for a in "\$@"; do
  if [ "\$prev" = "-c" ] && [[ "\$a" == *disallowed-host-reachable* ]]; then
    script="\$a"
    printf '%s\n' "\$script" > "$TEST_SKILL_DIR/network-probe-script.txt"
    # Branch tests substitute the absolute curl so they can force each exit.
    if [ "\${AGMSG_REWRITE_CURL:-}" = 1 ]; then
      script="\${script//\\/usr\\/bin\\/curl/$curldir/curl}"
      PATH="$curldir:\$PATH" exec /bin/sh -c "\$script"
    fi
    # PATH-bypass test stays offline. Three absolute curl commands, and no
    # other curl token once comments are removed, is the production contract.
    # A bare curl falls through and is satisfied by the fake on PATH.
    body=\$(printf '%s\n' "\$script" | sed 's/^[[:space:]]*#.*//')
    abs=\$(printf '%s' "\$body" | grep -o '/usr/bin/curl' | wc -l | tr -d ' ')
    rest=\$(printf '%s' "\$body" | sed 's|/usr/bin/curl||g')
    if [ "\$abs" = 3 ] && ! printf '%s' "\$rest" | grep -Eq '(^|[^[:alnum:]_./-])curl([^[:alnum:]_./-]|$)'; then
      echo disallowed-host-reachable
      exit 10
    fi
    PATH="$curldir:\$PATH" exec /bin/sh -c "\$script"
  fi
  prev="\$a"
done
args="\$*"
if [[ "\$args" == *'&& rm'* ]]; then
  exit 0
fi
if [[ "\$args" == *planted.rules* || "\$args" == *agmsg-not-auth* || "\$args" == */marker* ]]; then
  echo "Operation not permitted"
  exit 1
fi
if [[ "\$args" == *touch* ]]; then
  echo "Operation not permitted"
  exit 1
fi
exit 0
EOF
  chmod +x "$STUB_BIN/codex"
}

@test "spawn: reviewer network probe fails when a disallowed host is reachable" {
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  _make_fake_bridge
  _install_reviewer_network_stub
  run env AGMSG_REWRITE_CURL=1 AGMSG_FAKE_CURL_MODE=allow-example AGMSG_CODEX_BRIDGE_CMD="$STUB_BIN/fake-bridge.sh" \
    bash "$SCRIPTS/spawn.sh" codex rv --project "$PROJ" --headless --reviewer
  [ "$status" -ne 0 ]
  [[ "$output" == *"disallowed-host-reachable"* ]]
  [ ! -s "$CAPTURE" ]
}

@test "spawn: reviewer network probe fails when a direct IP bypasses the proxy" {
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  _make_fake_bridge
  _install_reviewer_network_stub
  run env AGMSG_REWRITE_CURL=1 AGMSG_FAKE_CURL_MODE=allow-ip AGMSG_CODEX_BRIDGE_CMD="$STUB_BIN/fake-bridge.sh" \
    bash "$SCRIPTS/spawn.sh" codex rv --project "$PROJ" --headless --reviewer
  [ "$status" -ne 0 ]
  [[ "$output" == *"direct-ip-bypassed-proxy"* ]]
  [ ! -s "$CAPTURE" ]
}

@test "spawn: reviewer network probe fails when the allowed host is unreachable" {
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  _make_fake_bridge
  _install_reviewer_network_stub
  run env AGMSG_REWRITE_CURL=1 AGMSG_FAKE_CURL_MODE=deny-api AGMSG_CODEX_BRIDGE_CMD="$STUB_BIN/fake-bridge.sh" \
    bash "$SCRIPTS/spawn.sh" codex rv --project "$PROJ" --headless --reviewer
  [ "$status" -ne 0 ]
  [[ "$output" == *"api-unreachable"* ]]
  [ ! -s "$CAPTURE" ]
}

@test "spawn: reviewer network probe ignores a curl planted on PATH" {
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  _make_fake_bridge
  _install_reviewer_network_stub
  # The stub does not run curl. It refuses only when the probe script names
  # /usr/bin/curl three times. A bare curl is run via the fake on PATH, which
  # reports the proxy-success statuses, and the spawn would launch.
  run env AGMSG_CODEX_BRIDGE_CMD="$STUB_BIN/fake-bridge.sh" \
    bash "$SCRIPTS/spawn.sh" codex rv --project "$PROJ" --headless --reviewer
  [ "$status" -ne 0 ]
  [[ "$output" == *"disallowed-host-reachable"* ]]
  [ ! -s "$CAPTURE" ]
  local probe="$TEST_SKILL_DIR/network-probe-script.txt"
  [ -s "$probe" ]
  local abs rest
  abs=$(grep -o '/usr/bin/curl' "$probe" | wc -l | tr -d ' ')
  [ "$abs" -eq 3 ]
  rest=$(sed 's/^[[:space:]]*#.*//; s|/usr/bin/curl||g' "$probe")
  ! printf '%s' "$rest" | grep -Eq '(^|[^[:alnum:]_./-])curl([^[:alnum:]_./-]|$)'
}

@test "spawn: reviewer keeps the user's execpolicy rules file and does not load it" {
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  _make_fake_bridge
  # PROJ lives under TEST_SKILL_DIR, so this .codex is an ancestor project
  # layer and also the user's CODEX_HOME. The user layer is isolated by the
  # private home and must not be treated as a project rule.
  local fake="$TEST_SKILL_DIR/.codex"
  mkdir -p "$fake/rules"
  printf 'prefix_rule(pattern=["echo"], decision="allow")\n' > "$fake/rules/default.rules"
  printf '{}\n' > "$fake/auth.json"
  local before
  before=$(cksum "$fake/rules/default.rules")
  run env CODEX_HOME="$fake" AGMSG_CODEX_BRIDGE_CMD="$STUB_BIN/fake-bridge.sh" \
    bash "$SCRIPTS/spawn.sh" codex rv --project "$PROJ" --headless --reviewer
  [ "$status" -eq 0 ]
  [ "$(cksum "$fake/rules/default.rules")" = "$before" ]
  wait_until 10 _capture_nonempty
  _reviewer_home_from_capture
  local home="$REVIEWER_HOME"
  [ -z "$(ls -A "$home/rules")" ]
  [ -L "$home/auth.json" ]
  [ ! -e "$home/config.toml" ]
  run cat "$CAPTURE"
  [[ "$output" == *"CODEX_HOME='$home'"* ]]
  [[ "$output" != *"CODEX_HOME='$fake'"* ]]
}

@test "spawn: reviewer leaves project rules in place and does not trust the repo" {
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  _make_fake_bridge
  mkdir -p "$PROJ/.codex/rules"
  printf 'prefix_rule(pattern=["echo"], decision="allow")\n' > "$PROJ/.codex/rules/p.rules"
  local before
  before=$(cksum "$PROJ/.codex/rules/p.rules")
  run env AGMSG_CODEX_BRIDGE_CMD="$STUB_BIN/fake-bridge.sh" \
    bash "$SCRIPTS/spawn.sh" codex rv --project "$PROJ" --headless --reviewer
  [ "$status" -eq 0 ]
  [ "$(cksum "$PROJ/.codex/rules/p.rules")" = "$before" ]
  wait_until 10 _capture_nonempty
  _reviewer_home_from_capture
  local home="$REVIEWER_HOME"
  [[ "$home" == "$HOME/.local/state/agmsg/reviewer-codex-home/"* ]]
  [ ! -e "$TEST_SKILL_DIR/reviewer-codex-home" ]
  [ ! -e "$home/config.toml" ]
  [ -z "$(ls -A "$home/rules")" ]
}

@test "spawn: reviewer state directory cannot alias the skills tree" {
  _reviewer_source_codex_spawn_plug
  mkdir -p "$HOME/.local" "$HOME/.agents/skills"
  ln -s "$HOME/.agents/skills" "$HOME/.local/state"
  run agmsg_codex_reviewer_execpolicy_home_path
  [ "$status" -ne 0 ]
  [[ "$output" == *"outside skill discovery"* ]]
}

@test "spawn: reviewer still protects legacy homes from explicit filesystem grants" {
  _reviewer_source_codex_spawn_plug
  local legacy="$TEST_SKILL_DIR/reviewer-codex-home/old-team/worker/launch.1"
  mkdir -p "$legacy"
  run agmsg_reviewer_path_conflicts_execpolicy_home "$legacy"
  [ "$status" -eq 0 ]
  ln -s "$TEST_SKILL_DIR/reviewer-codex-home" "$TEST_SKILL_DIR/legacy-alias"
  run agmsg_reviewer_path_conflicts_execpolicy_home "$TEST_SKILL_DIR/legacy-alias/future-home"
  [ "$status" -eq 0 ]
}

@test "spawn: reviewer refuses a symlinked execpolicy home" {
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  _make_fake_bridge
  local victim="$TEST_SKILL_DIR/victim-home"
  mkdir -p "$victim/rules"
  printf 'keep-me\n' > "$victim/rules/keep.rules"
  mkdir -p "$HOME/.local/state/agmsg/reviewer-codex-home/myteam"
  ln -s "$victim" "$HOME/.local/state/agmsg/reviewer-codex-home/myteam/rv"
  run env AGMSG_CODEX_BRIDGE_CMD="$STUB_BIN/fake-bridge.sh" \
    bash "$SCRIPTS/spawn.sh" codex rv --project "$PROJ" --headless --reviewer
  [ "$status" -ne 0 ]
  [[ "$output" == *"symlink"* ]]
  [ "$(cat "$victim/rules/keep.rules")" = "keep-me" ]
  [ ! -s "$CAPTURE" ]
}

@test "spawn: reviewer drops an auth link when the source home has none" {
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  local with_auth="$TEST_SKILL_DIR/home-a" without_auth="$TEST_SKILL_DIR/home-b"
  mkdir -p "$with_auth" "$without_auth"
  printf '{}\n' > "$with_auth/auth.json"
  run bash -c '
    set -euo pipefail
    TEAM=myteam NAME=rv SKILL_DIR="'"$TEST_SKILL_DIR"'" SCRIPT_DIR="'"$SCRIPTS"'"
    die() { echo "spawn: $*" >&2; exit 1; }
    source "$SCRIPT_DIR/drivers/types/codex/_spawn.sh"
    AGMSG_REVIEWER_EXEC_HOME="'"$HOME"'/.local/state/agmsg/reviewer-codex-home/myteam/rv/launch.auth-probe"
    CODEX_HOME="'"$with_auth"'"
    agmsg_codex_reviewer_prepare_execpolicy_home
    [ -L "$AGMSG_REVIEWER_EXEC_HOME/auth.json" ]
    CODEX_HOME="'"$without_auth"'"
    agmsg_codex_reviewer_prepare_execpolicy_home
    [ ! -e "$AGMSG_REVIEWER_EXEC_HOME/auth.json" ]
    [ ! -L "$AGMSG_REVIEWER_EXEC_HOME/auth.json" ]
  '
  [ "$status" -eq 0 ]
}

@test "spawn: reviewer execpolicy home probe refuses an unexpected sandbox error" {
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  _make_fake_bridge
  cat > "$STUB_BIN/codex" <<'CODEX_STUB'
#!/usr/bin/env bash
if [ "$1" = sandbox ]; then
  case "$*" in
    *"rm -f"*) exit 0 ;;
    *planted.rules*|*agmsg-not-auth*|*/marker*) echo "command not found" >&2; exit 2 ;;
    *touch*) echo "touch: probe: Operation not permitted" >&2; exit 1 ;;
    *) exit 0 ;;
  esac
fi
exit 0
CODEX_STUB
  chmod +x "$STUB_BIN/codex"
  run env AGMSG_CODEX_BRIDGE_CMD="$STUB_BIN/fake-bridge.sh" \
    bash "$SCRIPTS/spawn.sh" codex rv --project "$PROJ" --headless --reviewer
  [ "$status" -ne 0 ]
  [[ "$output" == *"failed unexpectedly"* ]]
  [ ! -s "$CAPTURE" ]
}

@test "spawn: reviewer execpolicy home probe refuses when the marker is readable" {
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  _make_fake_bridge
  cat > "$STUB_BIN/codex" <<'CODEX_STUB'
#!/usr/bin/env bash
if [ "$1" = sandbox ]; then
  case "$*" in
    *"rm -f"*) exit 0 ;;
    */marker*) exit 0 ;;
    *planted.rules*|*agmsg-not-auth*) echo "Operation not permitted" >&2; exit 1 ;;
    *touch*) echo "touch: probe: Operation not permitted" >&2; exit 1 ;;
    *) exit 0 ;;
  esac
fi
exit 0
CODEX_STUB
  chmod +x "$STUB_BIN/codex"
  run env AGMSG_CODEX_BRIDGE_CMD="$STUB_BIN/fake-bridge.sh" \
    bash "$SCRIPTS/spawn.sh" codex rv --project "$PROJ" --headless --reviewer
  [ "$status" -ne 0 ]
  [[ "$output" == *"read marker succeeded"* ]]
  [ ! -s "$CAPTURE" ]
}

@test "spawn: reviewer execpolicy home probe refuses when a rule file can be written" {
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  _make_fake_bridge
  cat > "$STUB_BIN/codex" <<'CODEX_STUB'
#!/usr/bin/env bash
if [ "$1" = sandbox ]; then
  case "$*" in
    *"rm -f"*) exit 0 ;;
    *planted.rules*) exit 0 ;;
    */marker*|*agmsg-not-auth*) echo "Operation not permitted" >&2; exit 1 ;;
    *touch*) echo "touch: probe: Operation not permitted" >&2; exit 1 ;;
    *) exit 0 ;;
  esac
fi
exit 0
CODEX_STUB
  chmod +x "$STUB_BIN/codex"
  run env AGMSG_CODEX_BRIDGE_CMD="$STUB_BIN/fake-bridge.sh" \
    bash "$SCRIPTS/spawn.sh" codex rv --project "$PROJ" --headless --reviewer
  [ "$status" -ne 0 ]
  [[ "$output" == *"write rules succeeded"* ]]
  [ ! -s "$CAPTURE" ]
}

@test "spawn: reviewer execpolicy home probe refuses when the auth link can be replaced" {
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  _make_fake_bridge
  cat > "$STUB_BIN/codex" <<'CODEX_STUB'
#!/usr/bin/env bash
if [ "$1" = sandbox ]; then
  case "$*" in
    *"rm -f"*) exit 0 ;;
    *agmsg-not-auth*) exit 0 ;;
    */marker*|*planted.rules*) echo "Operation not permitted" >&2; exit 1 ;;
    *touch*) echo "touch: probe: Operation not permitted" >&2; exit 1 ;;
    *) exit 0 ;;
  esac
fi
exit 0
CODEX_STUB
  chmod +x "$STUB_BIN/codex"
  run env AGMSG_CODEX_BRIDGE_CMD="$STUB_BIN/fake-bridge.sh" \
    bash "$SCRIPTS/spawn.sh" codex rv --project "$PROJ" --headless --reviewer
  [ "$status" -ne 0 ]
  [[ "$output" == *"replace auth link succeeded"* ]]
  [ ! -s "$CAPTURE" ]
}

@test "spawn: a refused reviewer execpolicy probe does not keep the placement lock" {
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  _make_fake_bridge
  cat > "$STUB_BIN/codex" <<'CODEX_STUB'
#!/usr/bin/env bash
if [ "$1" = sandbox ]; then
  case "$*" in
    *"rm -f"*) exit 0 ;;
    *planted.rules*|*agmsg-not-auth*|*/marker*) echo "command not found" >&2; exit 2 ;;
    *touch*) echo "touch: probe: Operation not permitted" >&2; exit 1 ;;
    *) exit 0 ;;
  esac
fi
exit 0
CODEX_STUB
  chmod +x "$STUB_BIN/codex"
  run env AGMSG_CODEX_BRIDGE_CMD="$STUB_BIN/fake-bridge.sh" \
    bash "$SCRIPTS/spawn.sh" codex rv --project "$PROJ" --headless --reviewer
  [ "$status" -ne 0 ]
  [ ! -d "$TEST_SKILL_DIR/run/placement.myteam__rv.lock" ]
  cat > "$STUB_BIN/codex" <<'CODEX_STUB'
#!/usr/bin/env bash
if [ "$1" = sandbox ]; then
  case "$*" in
    *"rm -f"*) exit 0 ;;
    *planted.rules*|*agmsg-not-auth*|*/marker*) echo "Operation not permitted" >&2; exit 1 ;;
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
  [[ "$output" == *"spawned headless reviewer codex 'rv'"* ]]
}

@test "spawn: a second reviewer spawn does not rewrite a live worker's execpolicy home" {
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  _make_fake_bridge
  local home="$HOME/.local/state/agmsg/reviewer-codex-home/myteam/rv"
  local idkey
  idkey="$(agmsg_identity_key myteam rv)"
  mkdir -p "$home/rules"
  printf 'original-marker\n' > "$home/marker"
  printf 'original-rule\n' > "$home/rules/keep.rules"
  ln -s /tmp/original-auth "$home/auth.json"
  printf 'trusted\n' > "$home/config.toml"
  cat > "$STUB_BIN/pgrep" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"codex-bridge\\.js"*) printf '%s\n' 424242 ;;
esac
STUB
  cat > "$STUB_BIN/ps" <<'STUB'
#!/usr/bin/env bash
if [ "$*" = "-ww -o args= -p 424242" ]; then
  printf 'node /x/codex-bridge.js --identity-key %s\n' "$LIVE_IDENTITY_KEY"
  exit 0
fi
exit 1
STUB
  chmod +x "$STUB_BIN/pgrep" "$STUB_BIN/ps"
  run env AGMSG_CODEX_BRIDGE_CMD="$STUB_BIN/fake-bridge.sh" LIVE_IDENTITY_KEY="$idkey" \
    bash "$SCRIPTS/spawn.sh" codex rv --project "$PROJ" --headless --reviewer
  [ "$status" -eq 0 ]
  [[ "$output" == *"already running"* ]]
  [ "$(cat "$home/marker")" = "original-marker" ]
  [ "$(cat "$home/rules/keep.rules")" = "original-rule" ]
  [ "$(readlink "$home/auth.json")" = "/tmp/original-auth" ]
  [ "$(cat "$home/config.toml")" = "trusted" ]
  [ ! -s "$CAPTURE" ]
}

@test "spawn: reviewer duplicate detection falls back when the pidfile disappears" {
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  _make_fake_bridge
  local idkey home
  idkey="$(agmsg_identity_key myteam rv)"
  home="$HOME/.local/state/agmsg/reviewer-codex-home/myteam/rv/launch.stale-pid"
  mkdir -p "$home/rules"
  printf 'leave-me\n' > "$home/marker"
  local pidfile="$TEST_SKILL_DIR/run/codex-bridge.myteam.rv.pid"
  : > "$pidfile"
  cat > "$STUB_BIN/pgrep" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"codex-bridge\\.js"*) printf '%s\n' 424242 ;;
esac
STUB
  cat > "$STUB_BIN/ps" <<'STUB'
#!/usr/bin/env bash
if [ "$*" = "-ww -o args= -p 424242" ]; then
  printf 'node /x/codex-bridge.js --identity-key %s\n' "$LIVE_IDENTITY_KEY"
  exit 0
fi
exit 1
STUB
  chmod +x "$STUB_BIN/pgrep" "$STUB_BIN/ps"
  run env LIVE_IDENTITY_KEY="$idkey" \
    AGMSG_CODEX_BRIDGE_CMD="$STUB_BIN/fake-bridge.sh" \
    bash "$SCRIPTS/spawn.sh" codex rv --project "$PROJ" --headless --reviewer
  [ "$status" -eq 0 ]
  [[ "$output" == *"already running"* ]]
  [ "$(cat "$home/marker")" = "leave-me" ]
  [ ! -s "$CAPTURE" ]
}

@test "spawn: reviewer dedup falls through to pgrep when suppress is true but pidfile is empty" {
  local idkey pidfile scope
  idkey="$(agmsg_identity_key myteam rv)"
  pidfile="$TEST_SKILL_DIR/run/test-bridge.pid"
  scope='codex-bridge|myteam.rv'
  mkdir -p "$TEST_SKILL_DIR/run"
  : > "$pidfile"
  cat > "$STUB_BIN/pgrep" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"codex-bridge\\.js"*) printf '%s\n' 515151 ;;
esac
STUB
  cat > "$STUB_BIN/ps" <<'STUB'
#!/usr/bin/env bash
if [ "$*" = "-ww -o args= -p 515151" ]; then
  printf 'node /x/codex-bridge.js --identity-key %s\n' "$LIVE_IDENTITY_KEY"
  exit 0
fi
exit 1
STUB
  chmod +x "$STUB_BIN/pgrep" "$STUB_BIN/ps"
  run env LIVE_IDENTITY_KEY="$idkey" PATH="$STUB_BIN:$PATH" bash -c '
    set -euo pipefail
    TEAM=myteam NAME=rv SKILL_DIR="'"$TEST_SKILL_DIR"'" SCRIPT_DIR="'"$SCRIPTS"'"
    die() { echo "spawn: $*" >&2; exit 1; }
    source "$SCRIPT_DIR/lib/process-identity.sh"
    agmsg_process_dedup_should_suppress() { return 0; }
    source "$SCRIPT_DIR/drivers/types/codex/_spawn.sh"
    out="$(agmsg_codex_bridge_running_pid "'"$pidfile"'" "'"$scope"'" "'"$idkey"'")"
    [ "$out" = "515151" ]
  '
  [ "$status" -eq 0 ]
}

@test "spawn: reviewer refuses a symlinked execpolicy home marker" {
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  local victim="$TEST_SKILL_DIR/marker-victim"
  printf 'keep-me\n' > "$victim"
  run bash -c '
    set -euo pipefail
    TEAM=myteam NAME=rv SKILL_DIR="'"$TEST_SKILL_DIR"'" SCRIPT_DIR="'"$SCRIPTS"'"
    die() { echo "spawn: $*" >&2; exit 1; }
    source "$SCRIPT_DIR/drivers/types/codex/_spawn.sh"
    AGMSG_REVIEWER_EXEC_HOME="'"$HOME"'/.local/state/agmsg/reviewer-codex-home/myteam/rv/launch.markerprobe"
    mkdir -p "$AGMSG_REVIEWER_EXEC_HOME"
    ln -s "'"$victim"'" "$AGMSG_REVIEWER_EXEC_HOME/marker"
    CODEX_HOME=/dev/null
    if agmsg_codex_reviewer_prepare_execpolicy_home 2>&1; then exit 99; else exit 1; fi
  '
  [ "$status" -ne 0 ]
  [[ "$output" == *"marker is a symlink"* ]]
  [ "$(cat "$victim")" = "keep-me" ]
}

@test "spawn: app-server does not load project rules from an untrusted home" {
  local real
  real=$(PATH="${PATH#"$STUB_BIN:"}" type -P codex 2>/dev/null || true)
  if [ -z "$real" ] || [ ! -x "$real" ]; then
    skip "real codex binary is not on PATH"
  fi
  command -v node >/dev/null 2>&1 || skip "node is not on PATH"
  local base="$TEST_SKILL_DIR/app-server-policy"
  local repo="$base/repo" home_u="$base/home-u" home_t="$base/home-t"
  mkdir -p "$repo/.codex/rules" "$home_u/rules" "$home_t/rules"
  printf '%s\n' 'prefix_rule(pattern=["echo", "AGMSG_RULE_MARKER"], decision="allow")' > "$repo/.codex/rules/marker.rules"
  printf '%s\n' "[projects.\"$repo\"]" 'trust_level = "trusted"' > "$home_t/config.toml"
  cat > "$base/probe.js" <<'JS'
const {spawn} = require("child_process");
const fs = require("fs");
const [base, repo, home, label, codex] = process.argv.slice(2);
const logPath = `${base}/${label}.log`;
const log = fs.createWriteStream(logPath);
const child = spawn(codex, ["app-server", "--listen", "stdio://"], {
  cwd: repo,
  env: {...process.env, CODEX_HOME: home, RUST_LOG: "codex_core::exec_policy=trace"},
  stdio: ["pipe", "pipe", "pipe"],
});
child.stderr.pipe(log);
let buf = "";
let id = 0;
const pending = new Map();
child.stdout.on("data", (chunk) => {
  buf += chunk.toString();
  let nl;
  while ((nl = buf.indexOf("\n")) >= 0) {
    const line = buf.slice(0, nl);
    buf = buf.slice(nl + 1);
    if (!line.trim()) continue;
    let msg;
    try { msg = JSON.parse(line); } catch { continue; }
    if (msg.id && pending.has(msg.id)) {
      pending.get(msg.id)(msg);
      pending.delete(msg.id);
    }
  }
});
const send = (method, params) => new Promise((resolve, reject) => {
  const my = ++id;
  const timer = setTimeout(() => reject(new Error("timeout " + method)), 8000);
  pending.set(my, (msg) => { clearTimeout(timer); resolve(msg); });
  child.stdin.write(JSON.stringify({jsonrpc:"2.0", id: my, method, params}) + "\n");
});
(async () => {
  await send("initialize", {clientInfo:{name:"agmsg-probe", version:"0"}, capabilities:{experimentalApi:true}});
  child.stdin.write(JSON.stringify({jsonrpc:"2.0", method:"initialized", params:{}}) + "\n");
  await send("thread/start", {cwd: repo, ephemeral: true});
})().catch((err) => fs.appendFileSync(logPath, "\nPROBE_ERR " + err + "\n"))
  .finally(() => {
    const finish = () => log.end(() => process.exit(0));
    child.once("exit", finish);
    child.kill("SIGTERM");
    setTimeout(() => child.kill("SIGKILL"), 2000);
  });
JS
  node "$base/probe.js" "$base" "$repo" "$home_u" untrusted "$real"
  node "$base/probe.js" "$base" "$repo" "$home_t" trusted "$real"
  ! grep -q 'marker.rules' "$base/untrusted.log"
  grep -q 'marker.rules' "$base/trusted.log"
  ! grep -q 'PROBE_ERR' "$base/untrusted.log"
  ! grep -q 'PROBE_ERR' "$base/trusted.log"
}

@test "spawn: an untrusted codex home does not load project execpolicy rules" {
  local real
  real=$(PATH="${PATH#"$STUB_BIN:"}" type -P codex 2>/dev/null || true)
  if [ -z "$real" ] || [ ! -x "$real" ]; then
    skip "real codex binary is not on PATH"
  fi
  local base="$TEST_SKILL_DIR/policy-probe"
  local repo="$base/repo" home_u="$base/home-u" home_t="$base/home-t"
  mkdir -p "$repo/.codex/rules" "$home_u/rules" "$home_t/rules"
  printf '%s\n' 'prefix_rule(pattern=["echo", "AGMSG_RULE_MARKER"], decision="allow")' > "$repo/.codex/rules/marker.rules"
  printf '%s\n' "[projects.\"$repo\"]" 'trust_level = "trusted"' > "$home_t/config.toml"
  _policy_log() {
    local chome="$1" log="$2" pid
    RUST_LOG=codex_core::exec_policy=trace CODEX_HOME="$chome" \
      "$real" exec --skip-git-repo-check -C "$repo" 'say hi' </dev/null >"$log" 2>&1 &
    pid=$!
    sleep 2
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  }
  _policy_log "$home_u" "$base/untrusted.log"
  _policy_log "$home_t" "$base/trusted.log"
  refute grep -q 'marker.rules' "$base/untrusted.log"
  grep -q 'marker.rules' "$base/trusted.log"
}

@test "spawn: reviewer ignores a codex shell function and uses the absolute executable" {
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  _make_fake_bridge
  codex() { echo FUNCTION_CODEX_USED; exit 86; }
  export -f codex
  printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB_BIN/codex"
  chmod +x "$STUB_BIN/codex"
  run env AGMSG_CODEX_BRIDGE_CMD="$STUB_BIN/fake-bridge.sh" \
    bash "$SCRIPTS/spawn.sh" codex rv --project "$PROJ" --headless --reviewer
  [ "$status" -ne 0 ]
  [[ "$output" != *FUNCTION_CODEX_USED* ]]
  [[ "$output" == *"not enforced"* ]]
  [ ! -s "$CAPTURE" ]
}

@test "spawn: reviewer refuses a relative codex path" {
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  local work="$TEST_SKILL_DIR/relwork"
  mkdir -p "$work/relbin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$work/relbin/codex"
  chmod +x "$work/relbin/codex"
  run env PATH="relbin:$PATH" \
    bash -c "cd '$work' && exec bash '$SCRIPTS/spawn.sh' codex rv --project '$PROJ' --headless --reviewer"
  [ "$status" -ne 0 ]
  [[ "$output" == *"absolute executable"* ]]
  [[ "$output" == *"relbin/codex"* ]]
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
  wait_until 10 _capture_nonempty
  run cat "$CAPTURE"
  [[ "$output" == *$'--pair myteam\timpl'* ]]
  [[ "$output" == *"--project $PROJ"* ]]                  # cwd = the real repo
  [[ "$output" != *"codex-myteam-cwd"* ]]                 # NOT the scratch dir
  [[ "$output" == *"default_permissions=agmsg-implementer"* ]]
  [[ "$output" != *"sandbox_mode=workspace-write"* ]]
  [[ "$output" == *"permissions.agmsg-implementer.filesystem="* ]]
  [[ "$output" == *"permissions.agmsg-implementer.network={ enabled=false }"* ]]
  [[ "$output" != *"--enable network_proxy"* ]]
  [[ "$output" != *"CODEX_HOME="* ]]
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
  wait_until 10 _capture_nonempty
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
  wait_until 10 _capture_nonempty
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
  wait_until 10 _capture_nonempty
  run cat "$CAPTURE"
  [[ "$output" == *"codex-myteam-cwd"* ]]                # scratch cwd, not the repo
  [[ "$output" == *"default_permissions=agmsg-consultant"* ]]
  [[ "$output" != *"default_permissions=agmsg-implementer"* ]]
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
  wait_until 10 _capture_nonempty
  run cat "$CAPTURE"
  [[ "$output" == *"default_permissions=agmsg-implementer"* ]]   # confirms the implementer branch built appcmd
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
  wait_until 10 _capture_nonempty
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
    *planted.rules*|*agmsg-not-auth*|*/marker*) echo "Operation not permitted" >&2; exit 1 ;;
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
  wait_until 10 _capture_nonempty
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
  wait_until 10 _capture_nonempty
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
  wait_until 10 _capture_nonempty
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
  wait_until 10 _capture_nonempty
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
  wait_until 10 _capture_nonempty
  run cat "$CAPTURE"
  [[ "$output" != *"\"$PROJ\"=\"read\""* ]]   # already :workspace_roots — not re-granted
}

@test "spawn: codex reviewer skips /add-dir paths under reviewer-codex-home" {
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  bash "$SCRIPTS/config.sh" set spawn.codex_inherit_add_dirs true
  local sibling="$HOME/.local/state/agmsg/reviewer-codex-home/other-team/w/launch.1"
  mkdir -p "$sibling/rules"
  printf 'secret-rule\n' > "$sibling/rules/leak.rules"
  mkdir -p "$PROJ/.claude"
  printf '{"permissions":{"additionalDirectories":["%s"]}}' "$sibling" > "$PROJ/.claude/settings.local.json"
  _make_fake_bridge

  run env AGMSG_CODEX_BRIDGE_CMD="$STUB_BIN/fake-bridge.sh" \
    bash "$SCRIPTS/spawn.sh" codex rv --project "$PROJ" --headless --reviewer
  [ "$status" -eq 0 ]
  wait_until 10 _capture_nonempty
  run cat "$CAPTURE"
  [[ "$output" != *"\"$sibling\"=\"read\""* ]]
  [[ "$output" == *"\"$HOME/.local/state/agmsg/reviewer-codex-home\"=\"none\""* ]]
}

# --- reviewer gh CLI config (spawn.codex_gh_config_dir.<name>) ---

@test "spawn: codex reviewer does not inject GH_CONFIG_DIR when the per-worker key is unset" {
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  _make_fake_bridge

  run env AGMSG_CODEX_BRIDGE_CMD="$STUB_BIN/fake-bridge.sh" \
    bash "$SCRIPTS/spawn.sh" codex rv --project "$PROJ" --headless --reviewer
  [ "$status" -eq 0 ]

  local i
  wait_until 10 _capture_nonempty
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
  wait_until 10 _capture_nonempty
  run cat "$CAPTURE"
  [[ "$output" == *"\"$ghdir\"=\"read\""* ]]
  [[ "$output" == *"shell_environment_policy.set.GH_CONFIG_DIR=\"$ghdir\""* ]]
}

@test "spawn: codex reviewer ignores GH config dir under reviewer-codex-home" {
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  local sibling="$HOME/.local/state/agmsg/reviewer-codex-home/other-team/w/launch.1"
  mkdir -p "$sibling"
  printf '{}\n' > "$sibling/auth.json"
  bash "$SCRIPTS/config.sh" set spawn.codex_gh_config_dir.rv "$sibling"
  _make_fake_bridge

  run env AGMSG_CODEX_BRIDGE_CMD="$STUB_BIN/fake-bridge.sh" \
    bash "$SCRIPTS/spawn.sh" codex rv --project "$PROJ" --headless --reviewer
  [ "$status" -eq 0 ]
  [[ "$output" == *"ignoring codex GH config dir under execpolicy home tree"* ]]

  wait_until 10 _capture_nonempty
  run cat "$CAPTURE"
  [[ "$output" != *"\"$sibling\"=\"read\""* ]]
  [[ "$output" != *"GH_CONFIG_DIR"* ]]
}

@test "spawn: codex reviewer skips extra fs roots under reviewer-codex-home" {
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  local sibling="$HOME/.local/state/agmsg/reviewer-codex-home/other-team/w/launch.1"
  mkdir -p "$sibling/rules"
  bash "$SCRIPTS/config.sh" set spawn.codex_extra_fs_roots "$sibling=read"
  _make_fake_bridge

  run env AGMSG_CODEX_BRIDGE_CMD="$STUB_BIN/fake-bridge.sh" \
    bash "$SCRIPTS/spawn.sh" codex rv --project "$PROJ" --headless --reviewer
  [ "$status" -eq 0 ]

  wait_until 10 _capture_nonempty
  run cat "$CAPTURE"
  [[ "$output" != *"\"$sibling\"=\"read\""* ]]
  [[ "$output" == *"\"$HOME/.local/state/agmsg/reviewer-codex-home\"=\"none\""* ]]
}

@test "spawn: codex reviewer skips extra fs roots aliasing reviewer-codex-home" {
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  local private_alias="$TEST_SKILL_DIR/private-alias" future="$TEST_SKILL_DIR/private-alias/not-yet/child"
  ln -sfn "$HOME/.local/state/agmsg/reviewer-codex-home" "$private_alias"
  bash "$SCRIPTS/config.sh" set spawn.codex_extra_fs_roots "$future=read"
  _make_fake_bridge

  run env AGMSG_CODEX_BRIDGE_CMD="$STUB_BIN/fake-bridge.sh" \
    bash "$SCRIPTS/spawn.sh" codex rv --project "$PROJ" --headless --reviewer
  [ "$status" -eq 0 ]

  wait_until 10 _capture_nonempty
  run cat "$CAPTURE"
  [[ "$output" != *"\"$future\"=\"read\""* ]]
  [[ "$output" != *"not-yet"* ]]
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
  wait_until 10 _capture_nonempty
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
  wait_until 10 _capture_nonempty
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
  wait_until 10 _capture_nonempty
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
  wait_until 10 _capture_nonempty
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
    *planted.rules*|*agmsg-not-auth*|*/marker*) echo "Operation not permitted" >&2; exit 1 ;;
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
  wait_until 10 _capture_nonempty
  run cat "$CAPTURE"
  [[ "$output" != *"GH_CONFIG_DIR"* ]]
  [[ "$output" != *"$GH_TEST_REJECT_DIR"* ]]
}

# --- per-worker model / reasoning-effort override for headless codex ---
# (spawn.codex_model.<name> / spawn.codex_effort.<name>; see
# codex/_spawn.sh's agmsg_codex_model_effort_args). --model (interactive-spawn
# flag, reused here for the headless path) takes precedence over the config
# key for the model id; effort has no CLI flag (headless-only, config only).

@test "spawn: per-worker codex idle timeout is injected for the matching bridge only" {
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  bash "$SCRIPTS/config.sh" set spawn.codex_turn_timeout.reviewer 180
  bash "$SCRIPTS/config.sh" set spawn.codex_turn_timeout.otherworker 45
  _make_fake_bridge

  run env AGMSG_CODEX_BRIDGE_CMD="$STUB_BIN/fake-bridge.sh" \
    bash "$SCRIPTS/spawn.sh" codex reviewer --project "$PROJ" --headless
  [ "$status" -eq 0 ]
  local i
  wait_until 10 _capture_nonempty
  [ "$(sed -n 's/^TURN_TIMEOUT: //p' "$CAPTURE")" = "180" ]

  rm -f "$CAPTURE"
  run env AGMSG_CODEX_BRIDGE_CMD="$STUB_BIN/fake-bridge.sh" \
    bash "$SCRIPTS/spawn.sh" codex otherworker --project "$PROJ" --headless
  [ "$status" -eq 0 ]
  wait_until 10 _capture_nonempty
  [ "$(sed -n 's/^TURN_TIMEOUT: //p' "$CAPTURE")" = "45" ]
}

@test "spawn --model: headless codex embeds -c model=\"...\" in the app-server command" {
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  _make_fake_bridge

  run env AGMSG_CODEX_BRIDGE_CMD="$STUB_BIN/fake-bridge.sh" \
    bash "$SCRIPTS/spawn.sh" codex reviewer --project "$PROJ" --headless --model gpt-5.6-sol
  [ "$status" -eq 0 ]

  local i
  wait_until 10 _capture_nonempty
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
  wait_until 10 _capture_nonempty
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
  wait_until 10 _capture_nonempty
  run cat "$CAPTURE"
  [[ "$output" == *'model="gpt-5.6-sol"'* ]]

  # a DIFFERENT name's worker must not pick up reviewer's model.
  rm -f "$CAPTURE"
  run env AGMSG_CODEX_BRIDGE_CMD="$STUB_BIN/fake-bridge.sh" \
    bash "$SCRIPTS/spawn.sh" codex otherworker --project "$PROJ" --headless
  [ "$status" -eq 0 ]
  wait_until 10 _capture_nonempty
  run cat "$CAPTURE"
  [[ "$output" != *"model="* ]]
}

@test "spawn: a bare family name in spawn.codex_model.<name> resolves to the newest listed version" {
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  bash "$SCRIPTS/config.sh" set spawn.codex_model.reviewer sol
  _make_fake_bridge

  run env AGMSG_CODEX_BRIDGE_CMD="$STUB_BIN/fake-bridge.sh" \
    bash "$SCRIPTS/spawn.sh" codex reviewer --project "$PROJ" --headless
  [ "$status" -eq 0 ]

  local i
  wait_until 10 _capture_nonempty
  run cat "$CAPTURE"
  # gpt-10-sol beats gpt-6-sol numerically; the hidden gpt-11-sol is skipped.
  [[ "$output" == *'model="gpt-10-sol"'* ]]
}

@test "spawn: a family name with no listed model fails closed instead of spawning unpinned" {
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  bash "$SCRIPTS/config.sh" set spawn.codex_model.reviewer nosuchfamily
  _make_fake_bridge

  run env AGMSG_CODEX_BRIDGE_CMD="$STUB_BIN/fake-bridge.sh" \
    bash "$SCRIPTS/spawn.sh" codex reviewer --project "$PROJ" --headless
  [ "$status" -ne 0 ]
  [[ "$output" == *"no listed codex model for family 'nosuchfamily'"* ]]
  [ ! -s "$CAPTURE" ]
}

@test "spawn: --model takes precedence over spawn.codex_model.<name> for headless codex" {
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  bash "$SCRIPTS/config.sh" set spawn.codex_model.reviewer gpt-5-from-config
  _make_fake_bridge

  run env AGMSG_CODEX_BRIDGE_CMD="$STUB_BIN/fake-bridge.sh" \
    bash "$SCRIPTS/spawn.sh" codex reviewer --project "$PROJ" --headless --model gpt-5-from-flag
  [ "$status" -eq 0 ]

  local i
  wait_until 10 _capture_nonempty
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
  wait_until 10 _capture_nonempty
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
  wait_until 10 _capture_nonempty
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
  wait_until 10 _capture_nonempty
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
  wait_until 10 _capture_nonempty
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

  wait_until 10 _capture_nonempty
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
  wait_until 10 _capture_nonempty
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
# an unsanitized reject value echoed to stderr could carry an ANSI escape
# sequence (ESC) — see
# agmsg_codex_sanitize_for_log) ---

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

@test "spawn: an already-installed manifest with only the legacy monitor= key still skips the wait (#1214 back-compat)" {
  # Simulates an install from before the readiness_sentinel rename: the copied
  # type.conf carries ONLY the old bare monitor=no key, no readiness_sentinel=
  # at all. readiness_sentinel reading empty must not silently behave as "yes"
  # (wait) -- that would hang a no-handshake type's spawn until --ready-timeout.
  local conf="$TEST_SKILL_DIR/scripts/drivers/types/codex/type.conf"
  grep -v '^readiness_sentinel=' "$conf" > "$conf.new"
  mv "$conf.new" "$conf"
  printf 'monitor=no\n' >> "$conf"
  refute grep -q '^readiness_sentinel=' "$conf"
  grep -q '^monitor=no$' "$conf"

  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run env -u TMUX bash "$SCRIPTS/spawn.sh" codex reviewer --project "$PROJ" \
    --terminal "true # {cmd}"
  [ "$status" -eq 0 ]
  grep -q "skipping readiness wait" <<< "$output"
  refute grep -q "status=timeout" <<< "$output"
}

@test "spawn: a no-handshake type (readiness_sentinel=no) reports startup UNCONFIRMED, not a bare success" {
  # Observed live: "spawned" printed while the agent had not started (a startup shell prompt
  # ate the first keystroke of the boot command). A type with no readiness handshake
  # cannot confirm startup, so spawn must say so DISTINCTLY — status=launched-unconfirmed
  # with an explanation — instead of letting the placement line stand as success.
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run env -u TMUX bash "$SCRIPTS/spawn.sh" codex reviewer --project "$PROJ" \
    --terminal "true # {cmd}"
  [ "$status" -eq 0 ]
  grep -q "status=launched-unconfirmed" <<<"$output"
  grep -q "note=no-readiness-handshake" <<<"$output"
  grep -q "STARTUP IS UNCONFIRMED" <<<"$output"
  # the placement line is a placement FACT, not a success claim
  grep -q "launched codex 'reviewer'" <<<"$output"
  refute grep -q "spawned codex 'reviewer'" <<<"$output"
}

@test "spawn: --no-wait says 'launched' (never 'spawned'), and its unconfirmed NOTE differs from readiness_sentinel=no's" {
  # The placement word is 'launched', never 'spawned', on the --no-wait path too; and
  # the two no-confirmation reasons read apart — --no-wait carries note=no-wait, a
  # readiness_sentinel=no type carries note=no-readiness-handshake (distinct wording).
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  grep -q "launched claude-code 'alice'" <<<"$output"
  refute grep -q "spawned claude-code 'alice'" <<<"$output"
  grep -q "status=launched-unconfirmed" <<<"$output"
  grep -q "note=no-wait" <<<"$output"
  refute grep -q "note=no-readiness-handshake" <<<"$output"
}

@test "spawn: a CONFIRMED start (handshake) is the only path that proves startup (status=ready)" {
  # The positive observation — the watcher attaching (the ready sentinel) — is what
  # distinguishes "started" from "typed but never ran". Only status=ready asserts it.
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  mkdir -p "$TEST_SKILL_DIR/run"
  # See the readiness-handshake test above for why alice is joined before
  # resolving her ready path.
  bash "$SCRIPTS/join.sh" myteam alice claude-code "$PROJ" >/dev/null
  local ready="$(_ready_path myteam alice)"
  run env -u TMUX bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" \
    --ready-timeout 10 --terminal "touch $ready # {cmd}"
  [ "$status" -eq 0 ]
  grep -q "launched claude-code 'alice'" <<<"$output"
  grep -q "status=ready" <<<"$output"
  refute grep -q "status=launched-unconfirmed" <<<"$output"
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

# --- #335: psmux on Windows cannot exec an extensionless boot script ---
#
# These fake `uname -s` (via a stub honoring $FAKE_UNAME_S) and stub `tmux` to
# capture its argv, so the Windows launch path is exercised on a Linux/macOS
# runner. On Windows the boot script must run through `bash -l`; elsewhere the
# bare path (shebang-honored by Unix tmux) is kept.

@test "spawn: launch_in_tmux runs the boot script via bash -l on Windows (#335)" {
  local cap="$TEST_SKILL_DIR/tmux-argv.txt"
  : > "$cap"
  cat > "$STUB_BIN/uname" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${FAKE_UNAME_S:-Linux}"
EOF
  chmod +x "$STUB_BIN/uname"
  cat > "$STUB_BIN/tmux" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$cap"
case "\$1" in
  new-window)   echo '@1' ;;
  split-window) echo '%1' ;;
esac
exit 0
EOF
  chmod +x "$STUB_BIN/tmux"
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  # Default target is a split pane.
  run env TMUX="/tmp/fake,1,0" TMUX_PANE="%0" FAKE_UNAME_S="MINGW64_NT-10.0-19045" \
    bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  # A new window is the other branch.
  run env TMUX="/tmp/fake,1,0" TMUX_PANE="%0" FAKE_UNAME_S="MINGW64_NT-10.0-19045" \
    bash "$SCRIPTS/spawn.sh" claude-code bob --project "$PROJ" --no-wait --window
  [ "$status" -eq 0 ]
  # Both branches must launch through `bash -l <boot>`, not the bare path.
  run grep -E 'split-window .* bash -l /' "$cap"
  [ "$status" -eq 0 ]
  run grep -E 'new-window .* bash -l /' "$cap"
  [ "$status" -eq 0 ]
}

@test "spawn: launch_in_tmux keeps the bare boot path off Windows (#335)" {
  local cap="$TEST_SKILL_DIR/tmux-argv.txt"
  : > "$cap"
  cat > "$STUB_BIN/uname" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${FAKE_UNAME_S:-Linux}"
EOF
  chmod +x "$STUB_BIN/uname"
  cat > "$STUB_BIN/tmux" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$cap"
case "\$1" in
  new-window)   echo '@1' ;;
  split-window) echo '%1' ;;
esac
exit 0
EOF
  chmod +x "$STUB_BIN/tmux"
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run env TMUX="/tmp/fake,1,0" TMUX_PANE="%0" FAKE_UNAME_S="Linux" \
    bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  # Unix tmux honors the shebang, so no `bash -l` wrapper is emitted.
  run grep -F 'bash -l' "$cap"
  [ "$status" -ne 0 ]
  # ...and the bare boot path is still the launched command.
  run grep -E 'split-window .* /.*boot-' "$cap"
  [ "$status" -eq 0 ]
}

# --- herdr placement ---

# Helper: set up a fake herdr binary that records calls and returns canned JSON.
_setup_fake_herdr() {
  local herdr_stub="$STUB_BIN/herdr"
  export HERDR_CALL_LOG="$TEST_SKILL_DIR/herdr-calls.log"
  # Spawn-side naming calls `herdr agent rename` then reads the key back via
  # `herdr agent list` + `herdr pane get` (terminal_team_observe). Model that
  # faithfully: rename records the (pane_id -> key) mapping in this DB, list
  # replays it, so the read-back sees exactly the key spawn just wrote and the
  # realistic herdr tests exercise the SUCCESSFUL naming path (not the fallback).
  export HERDR_AGENT_DB="$TEST_SKILL_DIR/herdr-agents.db"
  : > "$HERDR_AGENT_DB"
  # Same shape for labels: `pane rename` records (pane_id -> label), `pane get`
  # replays the last one -- the caller pane's label is observable state (#1096).
  export HERDR_LABEL_DB="$TEST_SKILL_DIR/herdr-labels.db"
  : > "$HERDR_LABEL_DB"
  cat > "$herdr_stub" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HERDR_CALL_LOG"
# Responses are overridable so a test can hand back a differently shaped
# document (reordered keys, nested fields, extra pane objects) without
# rewriting the stub.
DEFAULT_SPLIT='{"id":"cli:pane:split","result":{"pane":{"pane_id":"wT:pN","tab_id":"wT:tA"},"type":"pane_info"}}'
DEFAULT_TAB='{"id":"cli:tab:create","result":{"root_pane":{"pane_id":"wT:pR","tab_id":"wT:tN"},"tab":{"tab_id":"wT:tN","label":"test"},"type":"tab_created"}}'
case "$1/$2" in
  pane/split)
    printf '%s\n' "${HERDR_SPLIT_RESPONSE:-$DEFAULT_SPLIT}"
    ;;
  pane/rename)
    # `pane rename <pane_id> <label>` -- record the mapping so `pane get` can
    # replay it (#1096: the caller pane's label must be observable before and
    # after a spawn, not just the argv). $3=pane id, $4=label.
    printf '%s\t%s\n' "$3" "$4" >> "$HERDR_LABEL_DB"
    echo '{"id":"cli:pane:rename","result":{"type":"ok"}}'
    ;;
  pane/run|pane/close)
    echo '{"id":"cli:pane:'"$2"'","result":{"type":"ok"}}'
    ;;
  pane/process-info)
    # requirement 1: default to a READY pane (foreground pgid == shell pid) so the
    # readiness gate passes; a test overrides HERDR_PROCESS_INFO_RESPONSE (and its exit
    # via HERDR_PROCESS_INFO_RC) to drive the not-ready / unknown arms. The default is
    # assigned separately, NOT inside ${VAR:-…}: braces in a default terminate the
    # parameter expansion early and leak trailing } into the output.
    pi_out="$HERDR_PROCESS_INFO_RESPONSE"
    [ -n "$pi_out" ] || pi_out='{"result":{"process_info":{"shell_pid":4242,"foreground_process_group_id":4242}}}'
    printf '%s\n' "$pi_out"
    exit "${HERDR_PROCESS_INFO_RC:-0}"
    ;;
  tab/create)
    printf '%s\n' "${HERDR_TAB_RESPONSE:-$DEFAULT_TAB}"
    ;;
  tab/close)
    echo '{"id":"cli:tab:close","result":{"type":"ok"}}'
    ;;
  agent/rename)
    if [ "$(grep -c '^agent rename ' "$HERDR_CALL_LOG")" -le "${HERDR_AGENT_RENAME_FAILURES:-0}" ]; then
      echo '{"error":{"code":"agent_not_found"}}' >&2
      exit 1
    fi
    # `agent rename <pane_id> <key>` — record the mapping so `agent list` can
    # replay it. $3=pane id, $4=key.
    printf '%s\t%s\n' "$3" "$4" >> "$HERDR_AGENT_DB"
    echo '{"id":"cli:agent:rename","result":{"type":"ok"}}'
    ;;
  agent/get)
    if [ "$(grep -c '^agent get ' "$HERDR_CALL_LOG")" -le "${HERDR_AGENT_GET_FAILURES:-0}" ]; then
      echo '{"error":{"code":"agent_not_found"}}' >&2
      exit 1
    fi
    _key="$(awk -F'\t' -v id="$3" '$1==id{k=$2} END{print k}' "$HERDR_AGENT_DB")"
    printf '{"result":{"agent":{"pane_id":"%s","name":"%s"}}}\n' "$3" "$_key"
    ;;
  agent/list)
    # Replay the recorded (pane_id -> name) pairs as the agents array.
    printf '{"result":{"agents":['
    _first=1
    if [ -f "$HERDR_AGENT_DB" ]; then
      while IFS="$(printf '\t')" read -r _aid _akey; do
        [ -n "$_aid" ] || continue
        [ "$_first" -eq 1 ] || printf ','
        printf '{"pane_id":"%s","name":"%s"}' "$_aid" "$_akey"
        _first=0
      done < "$HERDR_AGENT_DB"
    fi
    printf ']}}\n'
    ;;
  pane/get)
    # Minimal valid pane document. The label is the LAST one `pane rename`
    # recorded for this pane (so a test can read a pane's label back the way a
    # person would), "pane" when none was. $3=pane id.
    _label="$(awk -F'\t' -v id="$3" '$1==id{l=$2} END{print (l==""?"pane":l)}' "$HERDR_LABEL_DB" 2>/dev/null)"
    [ -n "$_label" ] || _label=pane
    printf '{"result":{"pane":{"pane_id":"%s","label":"%s","agent_status":"idle","terminal_title":"t","terminal_id":"term_spawn"}}}\n' "$3" "$_label"
    ;;
  *)
    echo '{"error":"unknown stub call: '"$*"'}' >&2
    exit 1
    ;;
esac
STUB
  chmod +x "$herdr_stub"
  export HERDR_ENV=1
  export HERDR_PANE_ID="wT:pSelf"
  export HERDR_SOCKET_PATH="$TEST_SKILL_DIR/herdr.sock"
  export HERDR_WORKSPACE_ID="wT"
  # Clear the terminal template so spawn does not take the template path.
  unset AGMSG_TERMINAL
  # Ensure the run/ directory exists for placement records.
  mkdir -p "$TEST_SKILL_DIR/run"
}

@test "spawn: herdr split — launches in a herdr pane with herdr: placement record" {
  _setup_fake_herdr
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  [[ "$output" == *"launched claude-code 'alice' in herdr"* ]]

  # herdr was called: pane split, pane rename, pane run.
  grep -q "pane split wT:pSelf --direction right --no-focus" "$HERDR_CALL_LOG"
  # The creation-time label is the final, team-prefixed one (#1096) -- the same
  # string terminal_name writes -- never the bare name.
  grep -q "^pane rename wT:pN myteam:alice$" "$HERDR_CALL_LOG"
  refute grep -q "^pane rename wT:pN alice$" "$HERDR_CALL_LOG"
  grep -q "pane run wT:pN" "$HERDR_CALL_LOG"

  # Placement record uses herdr: scheme tag.
  local rec="$(_spawn_record_path myteam alice)"
  [ -f "$rec" ]
  local rec_id
  IFS=$'\t' read -r rec_id _ _ < "$rec"
  [ "$rec_id" = "herdr:$HERDR_SOCKET_PATH:wT:pN" ]
}

@test "spawn: herdr split --split v maps to --direction down" {
  _setup_fake_herdr
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait --split v
  [ "$status" -eq 0 ]
  grep -q "pane split wT:pSelf --direction down --no-focus" "$HERDR_CALL_LOG"
}

@test "spawn: herdr --window uses tab create and extracts root_pane pane_id" {
  _setup_fake_herdr
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait --window
  [ "$status" -eq 0 ]
  # The window is created with the final, team-prefixed label too (#1096).
  grep -q "tab create --workspace wT --label myteam:alice" "$HERDR_CALL_LOG"
  grep -q "pane run wT:pR" "$HERDR_CALL_LOG"

  local rec="$(_spawn_record_path myteam alice)"
  [ -f "$rec" ]
  local rec_id
  IFS=$'\t' read -r rec_id _ _ < "$rec"
  [ "$rec_id" = "herdr:$HERDR_SOCKET_PATH:wT:pR" ]
}

@test "spawn: herdr --window falls back to split when HERDR_WORKSPACE_ID is unset" {
  _setup_fake_herdr
  unset HERDR_WORKSPACE_ID
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait --window
  [ "$status" -eq 0 ]
  # Fell back to split, not tab create.
  refute grep -q "tab create" "$HERDR_CALL_LOG"
  grep -q "pane split" "$HERDR_CALL_LOG"
}

@test "spawn: tmux takes priority over herdr (backward compat for tmux-inside-herdr)" {
  _setup_fake_herdr
  # Set $TMUX so the tmux path wins; re-set the terminal template so the test
  # doesn't actually run tmux (use the stub recorder).
  export TMUX="/tmp/fake,1,0" TMUX_PANE="%0"
  export AGMSG_TERMINAL="$STUB_BIN/record.sh {cmd}"
  # Provide a tmux stub that just records the call.
  cat > "$STUB_BIN/tmux" <<'TMUXSTUB'
#!/usr/bin/env bash
case "$1" in
  split-window) echo "%99" ;;
  select-pane|set-window-option) ;;
esac
TMUXSTUB
  chmod +x "$STUB_BIN/tmux"
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  [[ "$output" == *"in tmux"* ]]
  # herdr was NOT called.
  [ ! -f "$HERDR_CALL_LOG" ] || ! grep -q "pane split" "$HERDR_CALL_LOG"
}

# --- herdr response parsing: address the pane id by path, never by position ---
#
# herdr's replies are structured JSON, so key order and neighbouring objects
# are not part of the contract. Reading the id positionally (last "pane_id" in
# the text, or the first one inside a `[^}]*` window) silently selects a
# different pane when the shape shifts — spawn would then rename that pane, run
# the boot script in it, and persist its id as the placement record. These fix
# the shapes that break positional matching.

_spawn_recorded_id() {
  local rec="$(_spawn_record_path myteam alice)" id
  [ -f "$rec" ] || return 1
  IFS=$'\t' read -r id _ _ < "$rec"
  printf '%s' "$id"
}

@test "spawn: herdr split picks result.pane.pane_id even when another pane object follows it" {
  _setup_fake_herdr
  # A second pane object after the target: a trailing-match reader takes
  # wT:pWRONG and would drive the wrong pane.
  export HERDR_SPLIT_RESPONSE='{"id":"cli:pane:split","result":{"pane":{"pane_id":"wT:pRIGHT"},"neighbor":{"pane_id":"wT:pWRONG"}},"type":"pane_info"}'
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  grep -q "pane run wT:pRIGHT" "$HERDR_CALL_LOG"
  refute grep -q "wT:pWRONG" "$HERDR_CALL_LOG"
  [ "$(_spawn_recorded_id)" = "herdr:$HERDR_SOCKET_PATH:wT:pRIGHT" ]
}

@test "spawn: herdr split tolerates reordered keys in the pane object" {
  _setup_fake_herdr
  export HERDR_SPLIT_RESPONSE='{"result":{"type":"pane_info","pane":{"tab_id":"wT:tA","cwd":"/x","pane_id":"wT:pLAST"}},"id":"cli:pane:split"}'
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  [ "$(_spawn_recorded_id)" = "herdr:$HERDR_SOCKET_PATH:wT:pLAST" ]
}

@test "spawn: herdr --window reads root_pane.pane_id past a nested object" {
  _setup_fake_herdr
  # `scroll` and `agent_session` are real herdr fields that sort before
  # pane_id; a `[^}]*` window stops at the first closing brace and misses it.
  export HERDR_TAB_RESPONSE='{"id":"cli:tab:create","result":{"root_pane":{"agent_session":{"kind":"id"},"scroll":{"offset_from_bottom":0},"pane_id":"wT:pNESTED"},"tab":{"tab_id":"wT:tN","pane_id":"wT:pTABWRONG"},"type":"tab_created"}}'
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait --window
  [ "$status" -eq 0 ]
  grep -q "pane run wT:pNESTED" "$HERDR_CALL_LOG"
  refute grep -q "wT:pTABWRONG" "$HERDR_CALL_LOG"
  [ "$(_spawn_recorded_id)" = "herdr:$HERDR_SOCKET_PATH:wT:pNESTED" ]
}

@test "spawn: herdr split fails closed on a malformed or unusable response" {
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  local body
  # Not JSON at all; the right path missing; and a non-string value. None may
  # be treated as a usable pane id, and none may leave a placement record.
  for body in 'not json at all {{{' \
              '{"id":"cli:pane:split","result":{"type":"ok"}}' \
              '{"result":{"pane":{"pane_id":42}}}'; do
    _setup_fake_herdr
    export HERDR_SPLIT_RESPONSE="$body"
    run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait
    [ "$status" -ne 0 ]
    # The pane-id extraction + fail-closed now lives in the herdr driver (its own
    # tests pin the exact reasons); spawn reports the placement failure and — the
    # contract that matters here — leaves NO placement record and renames/runs nothing.
    grep -q "placement failed" <<<"$output"
    [ ! -f "$(_spawn_record_path myteam alice)" ]
    ! grep -q "pane run" "$HERDR_CALL_LOG" \
      || { echo "unexpected pane run for body: $body" >&3; false; }
  done
}

# --- spawn-time pending teardown (crash recovery without SessionEnd) ---

_spawn_owner_fixture() {
  SID=5AAD0001-0000-4000-8000-000000000001
  SPAWN_TEAM="s-$SID"
  bash "$SCRIPTS/config.sh" set delivery.session_team true >/dev/null
  bash "$SCRIPTS/join.sh" "$SPAWN_TEAM" lead claude-code "$PROJ" >/dev/null
  # The spawning session's process: a live pid the spawn can name as owner.
  test_fixture_start_reaped_process sleep 300
  OWNER_PID="$TEST_REAPED_PID"
  printf '#!/usr/bin/env bash\nexec sleep 300\n' > "$STUB_BIN/long-bridge.sh"
  chmod +x "$STUB_BIN/long-bridge.sh"
}

_spawn_owner_cleanup() {
  local pid
  kill "$OWNER_PID" 2>/dev/null || true
  for pid in $(cat "$TEST_SKILL_DIR"/run/*.pid 2>/dev/null); do
    kill "$pid" 2>/dev/null || true
  done
}

@test "spawn: a headless codex spawned into the caller's session team gets a verified pending record" {
  _spawn_owner_fixture
  run env CLAUDE_CODE_SESSION_ID="$SID" AGMSG_AGENT_PID="$OWNER_PID" \
    AGMSG_CODEX_BRIDGE_CMD="$STUB_BIN/long-bridge.sh" \
    bash "$SCRIPTS/spawn.sh" codex aaa --team "$SPAWN_TEAM" --project "$PROJ" --headless
  [ "$status" -eq 0 ]
  [[ "$output" == *"spawned headless codex 'aaa'"* ]]
  [[ "$output" != *"crash recovery not armed"* ]]
  export SKILL_DIR="$TEST_SKILL_DIR"
  source "$SCRIPTS/lib/actas-lock.sh"
  source "$SCRIPTS/lib/pending-teardown.sh"
  agmsg_pending_teardown_read "$(agmsg_pending_teardown_path "$SPAWN_TEAM" aaa)"
  [ "$AGMSG_PENDING_OWNER_STATE" = verified ]
  [ "$AGMSG_PENDING_OWNER_INSTANCE" = "$SID.$OWNER_PID" ]
  [ "$AGMSG_PENDING_OWNER_PID" = "$OWNER_PID" ]
  [ "$AGMSG_PENDING_RECORD" = "$(cat "$(agmsg_spawn_path "$SPAWN_TEAM" aaa)")" ]
  [ -n "$AGMSG_PENDING_BRIDGE_START" ]
  _spawn_owner_cleanup
}

@test "spawn: a headless cursor still names its owner although the spawn clears the session env" {
  _spawn_owner_fixture
  _make_fake_cursor_headless
  cp "$STUB_BIN/long-bridge.sh" "$STUB_BIN/fake-cursor-bridge.sh"
  run env CLAUDE_CODE_SESSION_ID="$SID" AGMSG_AGENT_PID="$OWNER_PID" \
    AGMSG_CURSOR_BRIDGE_CMD="$STUB_BIN/fake-cursor-bridge.sh" \
    bash "$SCRIPTS/spawn.sh" cursor aaa --team "$SPAWN_TEAM" --project "$PROJ" --headless
  [ "$status" -eq 0 ]
  [[ "$output" == *"spawned headless cursor reviewer 'aaa'"* ]]
  [[ "$output" != *"crash recovery not armed"* ]]
  export SKILL_DIR="$TEST_SKILL_DIR"
  source "$SCRIPTS/lib/actas-lock.sh"
  source "$SCRIPTS/lib/pending-teardown.sh"
  agmsg_pending_teardown_read "$(agmsg_pending_teardown_path "$SPAWN_TEAM" aaa)"
  [ "$AGMSG_PENDING_OWNER_INSTANCE" = "$SID.$OWNER_PID" ]
  [ "$AGMSG_PENDING_TYPE" = cursor ]
  _spawn_owner_cleanup
}

@test "spawn: a headless codex spawned into a project team writes no pending record" {
  _spawn_owner_fixture
  bash "$SCRIPTS/join.sh" proj-team existing codex "$PROJ" >/dev/null
  run env CLAUDE_CODE_SESSION_ID="$SID" AGMSG_AGENT_PID="$OWNER_PID" \
    AGMSG_CODEX_BRIDGE_CMD="$STUB_BIN/long-bridge.sh" \
    bash "$SCRIPTS/spawn.sh" codex aaa --team proj-team --project "$PROJ" --headless
  [ "$status" -eq 0 ]
  [ -z "$(ls "$TEST_SKILL_DIR"/run/pending-teardown.* 2>/dev/null)" ]
  _spawn_owner_cleanup
}

# --- requirement 1: herdr pre-input pane readiness (process-info gate) ---
# process-info's foreground_process_group_id == shell_pid says the shell is at its
# prompt. The gate acts on THREE outcomes distinctly (like peek's 10/12/13).

@test "spawn req1: a NOT-READY pane (foreground process running) is not typed — fail with reason, pane closed" {
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  _setup_fake_herdr
  export HERDR_PROCESS_INFO_RESPONSE='{"result":{"process_info":{"shell_pid":100,"foreground_process_group_id":200}}}'
  # The wait bound is FIXED (no env knob): this loops the whole bound (~5s) before failing.
  run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait
  [ "$status" -ne 0 ]
  grep -q "was not ready for input" <<<"$output"
  refute grep -q "pane run" "$HERDR_CALL_LOG"     # the boot was NOT typed
  grep -q "pane close" "$HERDR_CALL_LOG"          # the pane we created was closed
  [ ! -f "$(_spawn_record_path myteam alice)" ]   # nothing launched -> no record
}

@test "spawn req1: UNKNOWN readiness (process-info errors) still types, warns BEFORE-typing, and records" {
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  _setup_fake_herdr
  export HERDR_PROCESS_INFO_RC=1                  # process-info fails -> UNKNOWN (arm 3)
  run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  grep -q "pane run" "$HERDR_CALL_LOG"            # arm 3 types anyway
  grep -q "BEFORE the boot was typed" <<<"$output"
  [ -f "$(_spawn_record_path myteam alice)" ]
}

@test "spawn req1: null==null process-info is UNKNOWN, not READY (equality only after validation)" {
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  _setup_fake_herdr
  export HERDR_PROCESS_INFO_RESPONSE='{"result":{"process_info":{"shell_pid":null,"foreground_process_group_id":null}}}'
  run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  grep -q "BEFORE the boot was typed" <<<"$output"   # UNKNOWN, not a silent ready
  grep -q "pane run" "$HERDR_CALL_LOG"
}

@test "spawn req1: a numeric-STRING pid is UNKNOWN on BOTH arms and either field (json_type must be integer)" {
  # json_extract turns a JSON string "5" into 5, which would pass a digit
  # check; the classifier requires json_type=integer on BOTH fields. Each case below
  # must be UNKNOWN -> type + BEFORE-typing warning, NOT the NOT-READY 5s-wait/fail and
  # NOT a silent ready. The cases pin the drift a one-sided control would miss:
  #   - "5"/"5"  numeric string, EQUAL   (a value-only check would call it READY)
  #   - "5"/"6"  numeric string, UNEQUAL (must NOT fall to NOT-READY; the gate is on the
  #                                       values, not only the equality arm)
  #   - 5 / "5"  MIXED: an integer and a numeric string (catches type-gating only ONE
  #                                       field — the ungated string would match READY)
  #   - "5"/ 5   MIXED the other way
  local resp
  for resp in '{"result":{"process_info":{"shell_pid":"5","foreground_process_group_id":"5"}}}' \
              '{"result":{"process_info":{"shell_pid":"5","foreground_process_group_id":"6"}}}' \
              '{"result":{"process_info":{"shell_pid":5,"foreground_process_group_id":"5"}}}' \
              '{"result":{"process_info":{"shell_pid":"5","foreground_process_group_id":5}}}'; do
    bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ" >/dev/null 2>&1 || true
    _setup_fake_herdr
    export HERDR_PROCESS_INFO_RESPONSE="$resp"
    run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait
    [ "$status" -eq 0 ]                                     || { echo "FAIL status=$status for $resp"; return 1; }
    grep -q "BEFORE the boot was typed" <<<"$output"       || { echo "FAIL not UNKNOWN warning for $resp"; return 1; }
    grep -q "pane run" "$HERDR_CALL_LOG"                    || { echo "FAIL not typed for $resp"; return 1; }
    refute grep -q "was not ready for input" <<<"$output"  || { echo "FAIL fell to NOT-READY for $resp"; return 1; }
  done
}

@test "spawn req1: a READY pane types with NO readiness warning" {
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  _setup_fake_herdr                                # default process-info = equal pids
  run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  grep -q "pane run" "$HERDR_CALL_LOG"
  refute grep -q "BEFORE the boot was typed" <<<"$output"
}

@test "spawn req1: a non-herdr (plain) spawn never runs the process-info gate" {
  # The gate is herdr-only; a plain placement must not emit its warning.
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  refute grep -q "BEFORE the boot was typed" <<<"$output"
}

@test "spawn req1: arm-3 (pre-input) and launched-unconfirmed (post-input) are DISTINCT messages" {
  # The two 'unconfirmed' reasons must read apart. A readiness_sentinel=no type spawned
  # through herdr with UNKNOWN readiness shows BOTH, worded differently.
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  _setup_fake_herdr
  export HERDR_PROCESS_INFO_RC=1                  # arm 3 (before-typing unknown)
  export HERDR_AGENT_GET_FAILURES=2               # detector has not recognized the CLI yet
  run env -u TMUX bash "$SCRIPTS/spawn.sh" codex reviewer --project "$PROJ"
  [ "$status" -eq 0 ]
  grep -q "BEFORE the boot was typed" <<<"$output"          # arm 3, before typing
  grep -q "status=launched-unconfirmed" <<<"$output"         # requirement 2, after typing
  grep -q "no-readiness-handshake" <<<"$output"
  [ "$(grep -c '^agent get ' "$HERDR_CALL_LOG")" -eq 3 ]
}

# --- --terminal-driver / AGMSG_TERMINAL_DRIVER override ---
@test "spawn: --terminal-driver plain forces the OS-terminal path even when \$TMUX is set" {
  # The default setup provides a {cmd} template (AGMSG_TERMINAL -> record.sh), so the
  # plain path is captured. With $TMUX set, detection would pick tmux; the override
  # must force the OS terminal instead.
  export TMUX="/tmp/fake,1,0" TMUX_PANE="%0"
  : > "$CAPTURE"
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait --terminal-driver plain
  [ "$status" -eq 0 ]
  grep -q "terminal template" <<<"$output"
  [ -s "$CAPTURE" ]        # the OS-terminal launcher ran (record.sh captured it)
}

@test "spawn: AGMSG_TERMINAL_DRIVER=plain forces the OS-terminal path (env form)" {
  export TMUX="/tmp/fake,1,0" TMUX_PANE="%0" AGMSG_TERMINAL_DRIVER=plain
  : > "$CAPTURE"
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  [ -s "$CAPTURE" ]
}

@test "spawn: --terminal-driver validates EARLY — before team resolution or any state change" {
  # An unknown driver is a deterministic arg typo, so it must fail before spawn
  # registers a role or writes a boot file, and before an unrelated 'no team' can mask
  # it. With NO team registered for the project, a bogus driver must STILL error with
  # 'unknown terminal driver' (not 'no team') — proving the check runs at parse time.
  run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait --terminal-driver bogus
  [ "$status" -ne 0 ]
  grep -q "unknown terminal driver" <<<"$output"
  refute grep -q "no team" <<<"$output"
  # Nothing was registered for the spawn target (it failed before the pre-join).
  [ ! -f "$(_spawn_record_path myteam alice)" ]
}

@test "spawn: with no --terminal-driver override, an orca-hosted environment routes through orca's own terminal_spawn (#1447)" {
  # The launcher->driver reroute's generic auto-detect sweep must find orca by
  # capability + live detection (decided 2026-09-23: judge presence from the
  # seat's own environment, ORCA_TERMINAL_HANDLE present means orca), with no
  # name branch for it in spawn.sh itself -- this is the one behavioral proof
  # of that. $TMUX/herdr are both unset by setup().
  export TERM_PROGRAM=Orca ORCA_TERMINAL_HANDLE="term_11111111-2222-3333-4444-555555555555"
  local orca_log="$TEST_SKILL_DIR/orca-argv.log"
  cat > "$STUB_BIN/orca" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$orca_log"
if [ "\$1" = terminal ] && [ "\$2" = create ]; then
  echo '{"ok":true,"result":{"terminal":{"handle":"term_11111111-2222-3333-4444-555555555555"}}}'
fi
exit 0
EOF
  chmod +x "$STUB_BIN/orca"
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  grep -q "via the orca terminal driver" <<<"$output"
  grep -qF -- "terminal create" "$orca_log"
  # The OS-terminal fallback (record.sh, plain's witness) must never have been
  # reached -- orca placed this, not a fallback to the last-resort path.
  [ ! -s "$CAPTURE" ]
}

@test "spawn: a placement-record WRITE failure -> status=spawned-but-unrecorded, non-zero" {
  # The record is the only authority peek/poke/despawn --force have. If the write
  # fails (here: the run dir made read-only, so agmsg_write_atomic cannot even create
  # its temp beside the record — the shape a real ENOSPC/permission failure takes),
  # the member is live but unaddressable — a distinct, worse state than a clean spawn,
  # so spawn reports status=spawned-but-unrecorded with the pane ref and exits
  # non-zero, not ready. The atomic write also guarantees the failure NEVER truncates
  # a correct existing record; here there is none yet, only the failed create.
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  mkdir -p "$TEST_SKILL_DIR/run"
  chmod 500 "$TEST_SKILL_DIR/run"                       # record write will fail
  cat > "$STUB_BIN/tmux" <<'T'
#!/usr/bin/env bash
case "$1" in split-window) echo '%9' ;; select-pane|set-window-option) ;; esac
exit 0
T
  chmod +x "$STUB_BIN/tmux"
  run env TMUX="/tmp/fake,1,0" TMUX_PANE="%0" bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait
  chmod 700 "$TEST_SKILL_DIR/run"                       # restore so teardown can clean up
  [ "$status" -ne 0 ]
  grep -q "status=spawned-but-unrecorded" <<<"$output"
  # The ref names the server that owns the pane (#1051): $TMUX is "/tmp/fake,1,0",
  # so the socket is /tmp/fake. A bare 'tmux:%9' would not identify which tmux
  # server to ask, and %9 is not unique across servers.
  grep -q "tmux:/tmp/fake:%9" <<<"$output"
}

@test "spawn: the plain driver's locator protocol value does not leak, and its witness is recorded" {
  # _launch_os_terminal captures terminal_spawn's record-op stdout and verifies
  # it rather than letting the protocol value appear beside the human status.
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  refute grep -qx -- 'iterm:/dev/ttys040' <<<"$output"
  grep -q "terminal template" <<<"$output"     # the OS-terminal path did run
  local rec="$(_spawn_record_path myteam alice)"
  grep -Fq $'plain:iterm:/dev/ttys040\t' "$rec"
  grep -Fq $'\tfence=iterm:tty=/dev/ttys040,boot=123,boot_start=Sat_Sep_13_02:10:11_2026' "$rec"
}

@test "spawn: the plain witness start time is the same, and accepted, under a non-English locale (#1591)" {
  # ps spells a start time in the locale's own words (and punctuation such as '/'
  # or '.'), which the owner-witness check rejects and which would not compare
  # equal when read back under another locale. The fake ps below answers in
  # Japanese unless LC_ALL=C is set on the call itself, so this fails if any of
  # the three places that ask ps for lstart stops pinning the locale -- on a
  # machine that has no Japanese locale installed too.
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  local bin="$TEST_SKILL_DIR/locale-bin" boot="$TEST_SKILL_DIR/locale-boot.sh" out
  mkdir -p "$bin"
  cat > "$bin/ps" <<'EOF'
#!/usr/bin/env bash
fmt=""
while [ $# -gt 0 ]; do case "$1" in -o) fmt="$2"; shift 2 ;; *) shift ;; esac; done
case "$fmt" in
  lstart=) if [ "${LC_ALL:-}" = C ]; then printf 'Sat Sep 13 02:10:11 2026\n'; else printf '\xe5\x9c\x9f 9/13 02:10:11 2026\n'; fi ;;
  tty=) printf 'ttys040\n' ;;
esac
EOF
  chmod +x "$bin/ps"

  # The witness writer, exactly as spawn.sh puts it in the boot script.
  grep -F '_agmsg_start=' "$SCRIPTS/spawn.sh" | head -1 | sed "s/^  echo '//; s/'\$//; s/'\\\\''/'/g" > "$boot.line"
  out="$(env PATH="$bin:$PATH" LANG=ja_JP.UTF-8 LC_ALL=ja_JP.UTF-8 bash -c '. "$1"; printf "%s" "$_agmsg_start"' _ "$boot.line")"
  [ "$out" = Sat_Sep_13_02:10:11_2026 ]

  # The check accepts what that writes, and the readback under the same
  # non-English locale matches it.
  run env PATH="$bin:$PATH" LANG=ja_JP.UTF-8 LC_ALL=ja_JP.UTF-8 bash -c '
    . "$1/scripts/drivers/terminals/plain/ops.sh"
    export AGMSG_PLAIN_SPAWN_WITNESS="$2"
    printf "iterm\t/dev/ttys040\t4242\t%s\n" "$3" > "$2"
    _plain_spawn_locator || exit 1
    _plain_process_witness_matches 4242 "$3" /dev/ttys040 CLI
  ' _ "$TEST_SKILL_DIR" "$TEST_SKILL_DIR/locale-witness" "$out"
  [ "$status" -eq 0 ]

  # The fence a seat records about itself (terminal_fence) asks ps the same way,
  # so that what it stores is what the readback above compares against.
  run env PATH="$bin:$PATH" LANG=ja_JP.UTF-8 LC_ALL=ja_JP.UTF-8 bash -c '
    . "$1/scripts/drivers/terminals/plain/ops.sh"
    terminal_fence iterm:/dev/ttys040 4242
  ' _ "$TEST_SKILL_DIR"
  [ "$status" -eq 0 ]
  grep -Fq 'start=Sat_Sep_13_02:10:11_2026' <<<"$output"
}

# --- codex launches through the bundled shim, by path (spawn_wrapper=) ---------
# A person's shell reaches codex-shim.sh as a function or a PATH entry; the
# non-interactive shell that runs a boot script has neither, so a bare `codex`
# there is the real binary and the seat starts without --remote (measured: the
# bridge restarts every few seconds against a thread it cannot own). The
# manifest names the shim relative to the type directory and spawn addresses it
# by that bundled path.

# The executable of a boot script's CLI line: the first word that is not a
# leading VAR=value assignment (the MSYS argv guard, #336, prefixes every line).
_boot_line_executable() {
  printf '%s\n' "$1" | awk '{ for (i = 1; i <= NF; i++) if ($i !~ /=/) { print $i; exit } }'
}

@test "spawn: codex is launched through the bundled shim by its absolute path, not a bare cli" {
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  run bash "$SCRIPTS/spawn.sh" codex reviewer --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  boot="$(cat "$CAPTURE")"
  [ -f "$boot" ]
  # The CLI line's first word is the shim inside THIS skill dir -- not `codex`,
  # not something found on PATH.
  local shim; shim="$TEST_SKILL_DIR/scripts/drivers/types/codex/codex-shim.sh"
  grep -qF "$shim" "$boot"
  # And it is the executable of the actas line (the token before the prompt).
  local line; line="$(grep -F 'actas' "$boot" | head -1)"
  echo "actas line: $line"
  [ "$(_boot_line_executable "$line")" = "$shim" ]
  # The bare cli must not be launched anywhere in the script.
  [ "$(grep -cE '^codex |^[A-Z_]+=[^ ]* codex ' "$boot")" -eq 0 ]
}

@test "spawn: a declared wrapper that is missing is a refusal, never a silent bare-cli launch" {
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  # Break the bundled shim (the type manifest still declares it).
  chmod -x "$TEST_SKILL_DIR/scripts/drivers/types/codex/codex-shim.sh"
  run bash "$SCRIPTS/spawn.sh" codex reviewer --project "$PROJ" --no-wait
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -qF 'launch wrapper'
  printf '%s\n' "$output" | grep -qF 'codex-shim.sh'
  # Nothing was placed or launched: no boot script was handed to the terminal.
  [ ! -s "$CAPTURE" ]
  chmod +x "$TEST_SKILL_DIR/scripts/drivers/types/codex/codex-shim.sh"
}

@test "spawn: a type without spawn_wrapper still launches its bare cli (claude-code)" {
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  run bash "$SCRIPTS/spawn.sh" claude-code reviewer --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  boot="$(cat "$CAPTURE")"
  # The actas line's executable is the bare `claude` (resolved by the pane's
  # PATH), with no wrapper in front of it.
  local line; line="$(grep -F 'actas' "$boot" | head -1)"
  echo "actas line: $line"
  [ "$(_boot_line_executable "$line")" = claude ]
  [ "$(grep -c 'codex-shim' "$boot")" -eq 0 ]
}

@test "spawn: a spawned codex reaches the real binary WITH --remote (argv read from the boot script's launch)" {
  # End to end: run the boot script spawn wrote. Its shim resolves the real
  # codex on PATH (a fake that records argv and can bring up an app-server),
  # enters codex-monitor because the project is in monitor mode, and execs the
  # real binary with --remote. The argv the fake recorded is the evidence.
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  bash "$SCRIPTS/delivery.sh" set monitor codex "$PROJ" >/dev/null
  _install_fake_codex_bridge_stack
  run bash "$SCRIPTS/spawn.sh" codex reviewer --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  boot="$(cat "$CAPTURE")"
  run env SHELL="$STUB_BIN/noshell" bash "$boot"
  # Forced failure for the teardown test below: stop here, with the fake
  # app-server still up, the way a failing assertion would. The variable names
  # a file that receives this test's own temp dir.
  if [ -n "${AGMSG_TEST_SPAWN_FAIL_AFTER_LAUNCH:-}" ]; then
    printf '%s' "$TEST_SKILL_DIR" > "$AGMSG_TEST_SPAWN_FAIL_AFTER_LAUNCH"
    # The same listing and command-line source the reaper uses (no ps -o, which
    # Git Bash lacks).
    local _p
    for _p in $(_pids_referencing_dir "$TEST_SKILL_DIR"); do
      ( source "$SCRIPTS/lib/compat.sh"; compat_get_cmdline "$_p"; echo )
    done > "$AGMSG_TEST_SPAWN_FAIL_AFTER_LAUNCH.procs"
    false
  fi
  _assert_bridged_argv
}

@test "spawn: a test that fails after the launch leaves no fake app-server behind (teardown reap)" {
  # Runs the launch test above for real, forced to fail right after the fake
  # app-server is up. What the inner run's teardown does -- or does not do -- is
  # then read off the process list, by the temp dir the inner test reported.
  local marker="$TEST_SKILL_DIR/inner-dir" inner
  run env AGMSG_TEST_SPAWN_FAIL_AFTER_LAUNCH="$marker" \
    bats -f "reaches the real binary WITH --remote \\(argv" "$BATS_TEST_DIRNAME/test_spawn.bats"
  grep -q '^not ok 1 ' <<<"$output"
  inner="$(cat "$marker")"
  [ -n "$inner" ]
  # Both halves of the fake were up and named by the temp dir: the bash codex
  # and the python holding the listening socket. So "nothing references it
  # now" covers the python and its socket, not just the bash.
  grep -q 'codex app-server' "$marker.procs"
  grep -qi 'python.* - ' "$marker.procs"
  [ -z "$(_pids_referencing_dir "$inner")" ]
}

@test "spawn: a codex seat spawned FROM a bridged codex seat still reaches the real binary WITH --remote" {
  # codex-monitor exports AGMSG_CODEX_BRIDGE=1 right before it execs the bridged
  # TUI, so a seat spawned from inside that session inherits it, and the shim
  # passes straight to the real binary when it sees it -- ahead of any guard in
  # codex-monitor (found in review). The boot script must unset the inherited
  # bridge/opt-out state BEFORE the wrapper runs; this seeds all of it and reads
  # the argv that arrives.
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  bash "$SCRIPTS/delivery.sh" set monitor codex "$PROJ" >/dev/null
  _install_fake_codex_bridge_stack
  run bash "$SCRIPTS/spawn.sh" codex reviewer --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  boot="$(cat "$CAPTURE")"
  # The guard sits BEFORE the act: the namespace-clearing line (every
  # AGMSG_CODEX_* exported variable, enumerated at boot time) and the literal
  # unset both precede the wrapper line. One assertion per line, on purpose: an
  # `a && b && c` list does not fail the test when `a` fails.
  local ns_ln lit_ln cli_ln
  ns_ln="$(grep -n 'for _v in $(env | sed .*AGMSG_CODEX_' "$boot" | head -1 | cut -d: -f1)"
  lit_ln="$(grep -n '^unset .*CODEX_THREAD_ID' "$boot" | head -1 | cut -d: -f1)"
  cli_ln="$(grep -n 'codex-shim.sh' "$boot" | head -1 | cut -d: -f1)"
  [ -n "$ns_ln" ]
  [ -n "$lit_ln" ]
  [ -n "$cli_ln" ]
  [ "$ns_ln" -lt "$cli_ln" ]
  [ "$lit_ln" -lt "$cli_ln" ]
  grep -q '^unset .*AGMSG_REAL_CODEX' "$boot"
  run env SHELL="$STUB_BIN/noshell" \
    AGMSG_CODEX_BRIDGE=1 AGMSG_CODEX_BRIDGE_APP_SERVER="ws://127.0.0.1:1" AGMSG_CODEX_BRIDGE_LAUNCHER=1 \
    CODEX_THREAD_ID=parent-thread bash "$boot"
  _assert_bridged_argv
}

@test "spawn: an inherited AGMSG_CODEX_SHIM_DISABLE=1 does not make a spawned codex seat bypass the shim" {
  # The shim's other early exit. Seeded ALONE, so this variable is proven
  # handled on its own and not only in the company of the bridge one.
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  bash "$SCRIPTS/delivery.sh" set monitor codex "$PROJ" >/dev/null
  _install_fake_codex_bridge_stack
  run bash "$SCRIPTS/spawn.sh" codex reviewer --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  boot="$(cat "$CAPTURE")"
  run env SHELL="$STUB_BIN/noshell" \
    AGMSG_CODEX_SHIM_DISABLE=1 bash "$boot"
  _assert_bridged_argv
}

# Fake codex + bridge stack for the end-to-end launches: a `codex` on PATH that
# records its argv and can serve a fake app-server, a stub bridge launcher, and a
# stand-in for the shell the boot script execs into at the end.
_install_fake_codex_bridge_stack() {
  export CALL_LOG="$TEST_SKILL_DIR/codex-calls.log"
  cat > "$STUB_BIN/codex" <<'FAKE'
#!/usr/bin/env bash
case "${1:-}" in
  --version) echo "codex-cli 0.142.2"; exit 0 ;;
  app-server)
    # The test's own dir rides in argv (the script path), so the shared reaper
    # finds this python directly; a native Windows python keeps reporting the
    # same getppid() after its parent dies, so it cannot be left to notice.
    python3 - "$0" <<'PY'
import socket, sys, os
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 0)); s.listen(16); s.settimeout(0.2)
print("codex app-server (WebSockets)")
print("  listening on: ws://127.0.0.1:%d" % s.getsockname()[1]); sys.stdout.flush()
ppid = os.getppid()
while True:
    if os.getppid() != ppid:
        break
    try:
        c, _ = s.accept(); c.close()
    except Exception:
        pass
PY
    ;;
  *)
    printf 'real-codex' >> "$CALL_LOG"
    for a in "$@"; do printf ' <%s>' "$a" >> "$CALL_LOG"; done
    printf '\n' >> "$CALL_LOG"
    ;;
esac
FAKE
  chmod +x "$STUB_BIN/codex"
  # The bridge launcher is detached and Node-based; stand in for it BY FILE in
  # this test copy of the skill, not through AGMSG_CODEX_BRIDGE_LAUNCHER_CMD:
  # the boot script unsets every shim-stack override, so an env hook set by the
  # test would be cleared before the wrapper runs (which is the point).
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_SKILL_DIR/scripts/drivers/types/codex/codex-bridge-launcher.sh"
  # The boot script ends with `exec "$SHELL" -i`; give it a shell that just exits.
  printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB_BIN/noshell"; chmod +x "$STUB_BIN/noshell"
}

# The evidence both end-to-end tests read: the real binary was reached exactly
# once, bridged, with the actas prompt. The fake app-server is put down by teardown.
_assert_bridged_argv() {
  [ -f "$CALL_LOG" ]
  # The real binary was reached exactly once, with the bridge flag and the actas prompt.
  [ "$(grep -c '^real-codex' "$CALL_LOG")" -eq 1 ]
  grep -q '^real-codex <--remote> <ws://127\.0\.0\.1:[0-9][0-9]*>' "$CALL_LOG"
  grep -q 'actas' "$CALL_LOG"
  grep -q 'reviewer' "$CALL_LOG"
}

@test "spawn: an inherited PATH-wrapper install (AGMSG_CODEX_SHIM_WRAPPER/SCRIPT_DIR) cannot repoint the bundled shim" {
  # The installed ~/.agents/bin wrapper exports AGMSG_CODEX_SHIM_WRAPPER=1 and
  # AGMSG_CODEX_SHIM_SCRIPT_DIR before starting the bundled shim; a codex started
  # through it passes both to anything it spawns. Inherited, the bundled shim
  # would take the PARENT's script dir as its own (codex-shim.sh, the WRAPPER
  # branch) -- here a stale directory with no delivery.sh, which the shim reads
  # as "not a monitor project" and passes straight to the real binary (found in
  # review). Seeded with exactly that, the seat must still arrive bridged.
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  bash "$SCRIPTS/delivery.sh" set monitor codex "$PROJ" >/dev/null
  _install_fake_codex_bridge_stack
  local stale; stale="$TEST_SKILL_DIR/stale-install"; mkdir -p "$stale"
  run bash "$SCRIPTS/spawn.sh" codex reviewer --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  boot="$(cat "$CAPTURE")"
  run env SHELL="$STUB_BIN/noshell" \
    AGMSG_CODEX_SHIM_WRAPPER=1 AGMSG_CODEX_SHIM_SCRIPT_DIR="$stale" AGMSG_CODEX_SHIM_TARGET="$stale/codex" bash "$boot"
  _assert_bridged_argv
}

@test "spawn: inherited resolution overrides (real binary, monitor, launcher) do not steer a spawned codex seat" {
  # The remaining shim-stack inputs: a parent's AGMSG_REAL_CODEX,
  # AGMSG_CODEX_MONITOR_CMD and the launcher command overrides. Seeded with paths
  # that do not exist, the seat must still resolve everything from its own
  # install and arrive bridged; if any of them leaked through, the launch would
  # fail or go plain, and the argv below would not be recorded.
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  bash "$SCRIPTS/delivery.sh" set monitor codex "$PROJ" >/dev/null
  _install_fake_codex_bridge_stack
  run bash "$SCRIPTS/spawn.sh" codex reviewer --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  boot="$(cat "$CAPTURE")"
  run env SHELL="$STUB_BIN/noshell" \
    AGMSG_REAL_CODEX=/nonexistent/parent-codex AGMSG_CODEX_MONITOR_CMD=/nonexistent/parent-monitor \
    AGMSG_CODEX_BRIDGE_LAUNCHER_CMD=/nonexistent/parent-launcher AGMSG_CODEX_BRIDGE_CMD=/nonexistent/parent-bridge \
    bash "$boot"
  _assert_bridged_argv
}

@test "spawn: every environment variable the codex shim stack reads is cleared for a spawned seat (reader inventory)" {
  # The list in type.conf is only as good as its coverage. This pins it to the
  # readers: every ${AGMSG_CODEX_*} / ${AGMSG_REAL_CODEX} the shim, monitor and
  # launcher consult must be in spawn_unset_env, so the next control variable
  # added to the stack cannot be inherited by a spawned seat unnoticed. The
  # spawn marker itself is the one exception -- it is what the seat is.
  # Derivation: every `$VAR`/`${VAR` in the stack's bash files and every
  # `process.env.VAR` in the bridge, for VAR matching AGMSG_* or CODEX_*.
  # Each such name must be covered by spawn_unset_env — literally, or by a
  # namespace entry (`PREFIX*`) — unless it is on the short, reasoned keep list
  # below. A new reader outside the namespace fails here, which is the only way
  # a deny rule can say "we would notice".
  local dir="$SCRIPTS/drivers/types/codex" v listed entry covered
  export SKILL_DIR="$TEST_SKILL_DIR"
  # shellcheck disable=SC1090
  source "$SCRIPTS/lib/type-registry.sh"
  listed="$(agmsg_type_get codex spawn_unset_env)"
  # Kept on purpose (each with its reason in type.conf): the seat's own marker;
  # agmsg-wide configuration the CLI's actas flow legitimately inherits; test
  # hooks that only bats sets; and names that are script-local variables
  # assigned inside the stack before they are read, never environment inputs
  # (role-session lookup results, codex-monitor's parsed command/args/version,
  # the doc URL constant from delivery.sh).
  # CODEX_HOME is intentionally inherited: the session recorder records the
  # effective profile for resume, and spawned Codex seats use that same profile.
  local keep=" CODEX_HOME AGMSG_SPAWNED AGMSG_BASH AGMSG_WATCH_ONCE_INTERVAL AGMSG_WATCH_ONCE_TIMEOUT AGMSG_TEST_DISPATCHER_STALE_BARRIER AGMSG_TEST_ASSUME_CODEX_SOCKET AGMSG_ROLE_SESSION_UUID AGMSG_ROLE_SESSION_PROJECT CODEX_ARGS CODEX_COMMAND CODEX_VERSION CODEX_MONITOR_DOC_URL "
  local inventory missing=""
  inventory="$( { grep -ohE '\$\{?(AGMSG_[A-Z0-9_]+|CODEX_[A-Z0-9_]+)' "$dir"/codex-shim.sh "$dir"/codex-monitor.sh "$dir"/_app-server.sh "$dir"/codex-bridge-launcher.sh "$dir"/codex-record-session.sh "$dir"/_session-start.sh "$dir"/codex-shim-install.sh "$dir"/_delivery.sh | sed -E 's/^\$\{?//'; grep -ohE 'process\.env\.(AGMSG_[A-Z0-9_]+|CODEX_[A-Z0-9_]+)' "$dir"/codex-bridge.js | sed 's/process\.env\.//'; } | sort -u )"
  while IFS= read -r v; do
    [ -n "$v" ] || continue
    case "$keep" in *" $v "*) continue ;; esac
    covered=0
    for entry in $listed; do
      case "$entry" in
        *\*) case "$v" in "${entry%\*}"*) covered=1 ;; esac ;;
        *)   [ "$v" = "$entry" ] && covered=1 ;;
      esac
    done
    [ "$covered" -eq 1 ] || missing="$missing $v"
  done <<LIST
$inventory
LIST
  echo "inventory: $(printf '%s\n' "$inventory" | wc -l | tr -d ' ') names; not covered:$missing"
  [ -z "$missing" ]
  # Positive controls for the extractor: the inventory must contain the names
  # the two review rounds found, or an empty scan would pass vacuously.
  printf '%s\n' "$inventory" | grep -qx 'AGMSG_CODEX_SHIM_SCRIPT_DIR'
  printf '%s\n' "$inventory" | grep -qx 'AGMSG_CODEX_BRIDGE'
  printf '%s\n' "$inventory" | grep -qx 'CODEX_THREAD_ID'
}

@test "spawn: a shim-stack control variable that does not exist yet is still cleared (namespace, not list)" {
  # The deny-list failed twice in review, each time by one name. The boot
  # script therefore clears the whole AGMSG_CODEX_* namespace as enumerated from
  # the environment at boot time. Seed a name no code reads today and dump the
  # environment the real binary actually receives: the seeded name is gone,
  # while an ordinary variable survives (positive control: the dump is real and
  # the clearing is not "unset everything").
  bash "$SCRIPTS/join.sh" myteam existing codex "$PROJ"
  bash "$SCRIPTS/delivery.sh" set monitor codex "$PROJ" >/dev/null
  _install_fake_codex_bridge_stack
  # Extend the fake: on the bridged launch, also dump its environment.
  sed -i.bak 's|    printf .real-codex. >> "\$CALL_LOG"|    env > "$CALL_LOG.env"\n&|' "$STUB_BIN/codex"; rm -f "$STUB_BIN/codex.bak"
  grep -q 'env > "\$CALL_LOG.env"' "$STUB_BIN/codex"
  run bash "$SCRIPTS/spawn.sh" codex reviewer --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]
  boot="$(cat "$CAPTURE")"
  run env SHELL="$STUB_BIN/noshell" AGMSG_CODEX_FUTURE_KNOB=1 AGMSG_ROLE_SESSION_OWNER=parent-owner SPAWN_TEST_CANARY=alive bash "$boot"
  _assert_bridged_argv
  [ -f "$CALL_LOG.env" ]
  grep -q '^SPAWN_TEST_CANARY=alive$' "$CALL_LOG.env"
  [ "$(grep -c '^AGMSG_CODEX_FUTURE_KNOB=' "$CALL_LOG.env")" -eq 0 ]
  # The bridge owner is identity state for the parent seat, so a spawned seat
  # must not inherit it and accidentally match the parent's actas lock.
  [ "$(grep -c '^AGMSG_ROLE_SESSION_OWNER=' "$CALL_LOG.env")" -eq 0 ]
  # And the seat's own marker is NOT cleared by the namespace rule.
  grep -q '^AGMSG_SPAWNED=1$' "$CALL_LOG.env"
}

# ----------------------------------------------------------------------------
# Spawn-side naming: the spawner sets the pane's agent key right after creating
# it, so a codex member (whose self-naming paths never run — they are all
# Claude-Code-only) is not left keyless and reported identity=mismatch by `team`.
#
# These drive a real spawn through a FAKE herdr driver: its terminal.conf still
# advertises the `name` capability (so _name_pane proceeds), but its ops are
# scripted so no real pane is opened and the naming write / read-back are
# controllable. The driver is forced with --terminal-driver herdr (routed to
# launch_in_herdr, which is where the codex case lives).
_install_fake_naming_herdr() {
  # Overwrite ONLY ops.sh in this test's throwaway skill copy; keep terminal.conf
  # (its capabilities line carries `name`). FAKE_* env vars steer each control.
  local ops="$TEST_SKILL_DIR/scripts/drivers/terminals/herdr/ops.sh"
  cat > "$ops" <<'OPS'
# fake herdr ops for spawn-side naming tests — no real herdr calls.
terminal_check()      { echo ok; return 0; }
terminal_describe()   { printf 'capabilities=spawn despawn peek poke where arrange name\n'; }
terminal_detect()     { return 0; }
terminal_spawn() {
  # Optionally drop the readiness sentinel spawn will wait on (set by the wait-path
  # tests), simulating a watcher that attaches immediately so WAIT_READY completes
  # fast. spawn clears the sentinel just before launching and calls this after, so
  # the touch lands after the clear.
  if [ -n "${FAKE_READY_TOUCH:-}" ]; then
    mkdir -p "$(dirname "$FAKE_READY_TOUCH")" 2>/dev/null || true
    : > "$FAKE_READY_TOUCH" 2>/dev/null || true
  fi
  printf '%s\n' "${FAKE_PANE_ID:-w0:p1}"; return 0
}
terminal_despawn()    { echo ok; return 0; }
terminal_pane_state() { echo alive; return 0; }
terminal_peek()       { printf ''; return 0; }
terminal_poke()       { echo ok; return 0; }
terminal_where()      { printf ''; return 0; }
terminal_arrange()    { echo ok; return 0; }
terminal_name() {
  # Log every naming call (id team agent mode) so a control can prove the key was
  # set with the right, type-independent (team, agent). FAKE_NAME_FAILS makes
  # the first N calls reproduce herdr's pre-detection agent_not_found response.
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$FAKE_NAME_LOG"
  local calls
  calls="$(wc -l < "$FAKE_NAME_LOG" | tr -d ' ')"
  if [ "$calls" -le "${FAKE_NAME_FAILS:-0}" ]; then
    echo runtime_error
    echo '{"error":{"code":"agent_not_found"}}' >&2
    return 13
  fi
  echo ok
  return "${FAKE_NAME_RC:-0}"
}
terminal_team_observe() {
  # activity \t label \t key \t title. Field 3 (key) is what _name_pane reads
  # back; FAKE_OBSERVE_KEY forces it (a sentinel => naming looks unconfirmed).
  printf 'idle\tt:a\t%s\ttitle\n' "${FAKE_OBSERVE_KEY:-a0123456789abcdef01234567}"
}
OPS
}

# Assertions here use `grep`/`refute`, never `[[ ]]`: a non-last `[[ ]]` cannot fail
# a test on bash 3.2 (#670), and the enforced-assertions checker holds the tree at a
# baseline. Name-log content is grepped from the FILE (not `run cat`, which would
# swap $output and hide the spawn-output assertions).

@test "spawn-side naming: a codex seat that never actas'd still gets its agent key set" {
  # The whole point: codex reaches its bridge, not the watcher, so none of the
  # five self-naming call sites ever run for it. Spawn must set the key itself.
  _install_fake_naming_herdr
  bash "$SCRIPTS/join.sh" cxteam existing codex "$PROJ"
  export FAKE_NAME_LOG="$TEST_SKILL_DIR/name.log"
  : > "$FAKE_NAME_LOG"
  run env FAKE_NAME_LOG="$FAKE_NAME_LOG" \
    bash "$SCRIPTS/spawn.sh" codex bob --project "$PROJ" --terminal-driver herdr --no-wait
  [ "$status" -eq 0 ]
  # spawn's OWN output (asserted while $output still holds it): naming succeeded,
  # so this is NOT the unnamed status.
  refute grep -qF "status=spawned-but-unnamed" <<<"$output"
  # terminal_name was called for THIS pane with the seat's (team, agent) and the
  # naming-on mode ("" — key AND label). Grep the log file directly.
  local want; want="$(printf 'w0:p1\tcxteam\tbob\t')"
  grep -qF -- "$want" "$FAKE_NAME_LOG"
}

@test "spawn-side naming: herdr retries agent_not_found until detection then confirms the key (#1100)" {
  _setup_fake_herdr
  bash "$SCRIPTS/join.sh" cxteam existing codex "$PROJ"
  cat > "$STUB_BIN/sleep" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_SLEEP_LOG"
EOF
  chmod +x "$STUB_BIN/sleep"
  export FAKE_SLEEP_LOG="$TEST_SKILL_DIR/sleep.log"
  : > "$FAKE_SLEEP_LOG"

  run env HERDR_AGENT_GET_FAILURES=2 \
    FAKE_SLEEP_LOG="$FAKE_SLEEP_LOG" \
    bash "$SCRIPTS/spawn.sh" codex bob --project "$PROJ" --terminal-driver herdr --no-wait
  [ "$status" -eq 0 ]
  [ "$(grep -c '^agent get ' "$HERDR_CALL_LOG")" -eq 3 ]
  [ "$(grep -c '^agent rename ' "$HERDR_CALL_LOG")" -eq 1 ]
  [ "$(wc -l < "$FAKE_SLEEP_LOG" | tr -d ' ')" -eq 2 ]
  [ "$(grep -c '^0.1$' "$FAKE_SLEEP_LOG")" -eq 2 ]
  refute grep -qF "status=spawned-but-unnamed" <<<"$output"
}

@test "spawn-side naming: herdr bounds a persistent agent_not_found and reports unnamed (#1100)" {
  _setup_fake_herdr
  bash "$SCRIPTS/join.sh" cxteam existing codex "$PROJ"
  cat > "$STUB_BIN/sleep" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_SLEEP_LOG"
EOF
  chmod +x "$STUB_BIN/sleep"
  export FAKE_SLEEP_LOG="$TEST_SKILL_DIR/sleep.log"
  : > "$FAKE_SLEEP_LOG"

  run env HERDR_AGENT_GET_FAILURES=3 HERDR_AGENT_RENAME_FAILURES=99 \
    FAKE_SLEEP_LOG="$FAKE_SLEEP_LOG" \
    bash "$SCRIPTS/spawn.sh" codex bob --project "$PROJ" --terminal-driver herdr --no-wait
  [ "$status" -eq 0 ]
  # One driver budget across both phases, with no outer retry restarting it:
  # three failed observations, then 48 failed renames, and 50 sleeps total.
  [ "$(grep -c '^agent get ' "$HERDR_CALL_LOG")" -eq 51 ]
  [ "$(grep -c '^agent rename ' "$HERDR_CALL_LOG")" -eq 48 ]
  [ "$(wc -l < "$FAKE_SLEEP_LOG" | tr -d ' ')" -eq 50 ]
  [ "$(grep -c '^0.1$' "$FAKE_SLEEP_LOG")" -eq 50 ]
  grep -qF "status=spawned-but-unnamed" <<<"$output"
}

@test "spawn-side naming: a non-detection failure is not retried (#1100)" {
  _install_fake_naming_herdr
  bash "$SCRIPTS/join.sh" cxteam existing codex "$PROJ"
  export FAKE_NAME_LOG="$TEST_SKILL_DIR/name.log"
  : > "$FAKE_NAME_LOG"

  run env FAKE_NAME_LOG="$FAKE_NAME_LOG" FAKE_NAME_RC=13 \
    bash "$SCRIPTS/spawn.sh" codex bob --project "$PROJ" --terminal-driver herdr --no-wait
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$FAKE_NAME_LOG" | tr -d ' ')" -eq 1 ]
  grep -qF "status=spawned-but-unnamed" <<<"$output"
}

@test "spawn-side naming: names a claude-code seat too, with the same key inputs a self-name would use" {
  # Type-independence: spawn names claude-code with the identical (team, agent,
  # mode) call agmsg_terminal_name_self makes, so the derived key is the same and
  # a later self-naming re-asserts that value rather than changing it.
  _install_fake_naming_herdr
  bash "$SCRIPTS/join.sh" ccteam existing claude-code "$PROJ"
  export FAKE_NAME_LOG="$TEST_SKILL_DIR/name.log"
  : > "$FAKE_NAME_LOG"
  run env FAKE_NAME_LOG="$FAKE_NAME_LOG" \
    bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --terminal-driver herdr --no-wait
  [ "$status" -eq 0 ]
  # Same call shape as the codex case (only team/agent differ) — type-independent.
  local want; want="$(printf 'w0:p1\tccteam\talice\t')"
  grep -qF -- "$want" "$FAKE_NAME_LOG"
  # Exactly one naming call from spawn; a later self-name with the same inputs is a
  # no-op on the value (idempotent), so spawn does not need to repeat it.
  [ "$(grep -c 'w0:p1' "$FAKE_NAME_LOG")" -eq 1 ]
}

@test "spawn-side naming: AGMSG_TERMINAL_NAMING=off still sets the key (mode=key), only the label is suppressed" {
  # The key is addressing and must always be set; off suppresses the visible label
  # only. So the naming call must carry mode=key, not be skipped.
  _install_fake_naming_herdr
  bash "$SCRIPTS/join.sh" cxteam existing codex "$PROJ"
  export FAKE_NAME_LOG="$TEST_SKILL_DIR/name.log"
  : > "$FAKE_NAME_LOG"
  run env FAKE_NAME_LOG="$FAKE_NAME_LOG" AGMSG_TERMINAL_NAMING=off \
    bash "$SCRIPTS/spawn.sh" codex bob --project "$PROJ" --terminal-driver herdr --no-wait
  [ "$status" -eq 0 ]
  local want; want="$(printf 'w0:p1\tcxteam\tbob\tkey')"
  grep -qF -- "$want" "$FAKE_NAME_LOG"
}

@test "spawn-side naming: a naming that does not read back reports spawned-but-unnamed, NOT ready/launched" {
  # The read-back is the point (the rule: only say named after reading back ok, like
  # team --fix). terminal_name SUCCEEDS here (rc 0) but the key reads back as a
  # missing sentinel — so ONLY the read-back catches it. Dropping the read-back
  # and trusting the write's exit would turn this control green (mutation guard).
  _install_fake_naming_herdr
  bash "$SCRIPTS/join.sh" cxteam existing codex "$PROJ"
  export FAKE_NAME_LOG="$TEST_SKILL_DIR/name.log"
  : > "$FAKE_NAME_LOG"
  run env FAKE_NAME_LOG="$FAKE_NAME_LOG" FAKE_NAME_RC=0 \
    FAKE_OBSERVE_KEY="unknown:agent_key_missing" \
    bash "$SCRIPTS/spawn.sh" codex bob --project "$PROJ" --terminal-driver herdr --no-wait
  # Not fatal — the seat is reachable via the placement record — so exit 0.
  [ "$status" -eq 0 ]
  # A DISTINCT status, and crucially NOT a ready/launched-confirmed line.
  grep -qF "status=spawned-but-unnamed" <<<"$output"
  grep -qF "ref=herdr:w0:p1" <<<"$output"
  refute grep -qF "status=ready" <<<"$output"
  refute grep -qF "status=launched-unconfirmed" <<<"$output"
}

@test "spawn-side naming: EVERY driver non-value key prefix reads back as NOT named (seam with #1066 observe vocabulary)" {
  # The read-back derives from the shared set (agmsg_observation_has_value /
  # _AGMSG_OBSERVATION_NON_VALUE_PREFIXES), so any prefix a driver can put in the key
  # field — including the decisive-absence `absent:*` #1066 added — must make spawn
  # report NOT named. Iterating the set (rather than a hand-list) proves the
  # derivation and auto-covers a future prefix. This is the #1065/#1066 seam.
  # shellcheck disable=SC1090
  source "$SCRIPTS/lib/terminal-registry.sh"
  [ -n "$_AGMSG_OBSERVATION_NON_VALUE_PREFIXES" ]   # the set must exist (post-#1066)
  local i=0 p nm
  for p in $_AGMSG_OBSERVATION_NON_VALUE_PREFIXES; do
    i=$((i + 1)); nm="seam$i"
    _install_fake_naming_herdr
    bash "$SCRIPTS/join.sh" seamteam "$nm" codex "$PROJ"
    export FAKE_NAME_LOG="$TEST_SKILL_DIR/name.log"; : > "$FAKE_NAME_LOG"
    run env FAKE_NAME_LOG="$FAKE_NAME_LOG" FAKE_NAME_RC=0 \
      FAKE_OBSERVE_KEY="${p}agent_key_unset" \
      bash "$SCRIPTS/spawn.sh" codex "$nm" --project "$PROJ" --terminal-driver herdr --no-wait
    [ "$status" -eq 0 ] || { echo "FAIL status=$status for prefix '$p'"; return 1; }
    grep -qF "status=spawned-but-unnamed" <<<"$output" \
      || { echo "FAIL prefix '$p' was not reported unnamed: $output"; return 1; }
  done
  # Mutation guard: a REAL value must read back as NAMED, else "answer everything
  # unnamed" (e.g. dropping the read-back and always returning 1) also passes above.
  _install_fake_naming_herdr
  bash "$SCRIPTS/join.sh" seamteam seamok codex "$PROJ"
  : > "$FAKE_NAME_LOG"
  run env FAKE_NAME_LOG="$FAKE_NAME_LOG" FAKE_NAME_RC=0 \
    FAKE_OBSERVE_KEY="a0123456789abcdef01234567" \
    bash "$SCRIPTS/spawn.sh" codex seamok --project "$PROJ" --terminal-driver herdr --no-wait
  [ "$status" -eq 0 ]
  refute grep -qF "status=spawned-but-unnamed" <<<"$output"
}

@test "spawn-side naming: on the WAIT path a ready-but-unnamed seat reports spawned-but-unnamed AFTER the wait" {
  # naming and readiness are independent facts: a seat can be receiving yet unnamed.
  # The report must come AFTER the readiness wait (not bail before it), so the leader
  # sees that the watcher attached. The `after=` field is emitted ONLY by the wait
  # branch, so its presence proves the wait ran before the naming report.
  _install_fake_naming_herdr
  bash "$SCRIPTS/join.sh" wtteam alice claude-code "$PROJ"
  # actas-lock.sh needs SKILL_DIR; spawn computes it as scripts/.. = TEST_SKILL_DIR,
  # so setting it to the same value makes agmsg_ready_path match spawn's own path.
  export SKILL_DIR="$TEST_SKILL_DIR"
  # shellcheck disable=SC1090
  source "$SCRIPTS/lib/actas-lock.sh"
  export FAKE_READY_TOUCH; FAKE_READY_TOUCH="$(agmsg_ready_path wtteam alice)"
  export FAKE_NAME_LOG="$TEST_SKILL_DIR/name.log"; : > "$FAKE_NAME_LOG"
  run env FAKE_NAME_LOG="$FAKE_NAME_LOG" FAKE_READY_TOUCH="$FAKE_READY_TOUCH" \
    FAKE_NAME_RC=0 FAKE_OBSERVE_KEY="absent:agent_key_unset" \
    bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --terminal-driver herdr --ready-timeout 10
  [ "$status" -eq 0 ]
  grep -qF "status=spawned-but-unnamed" <<<"$output"
  grep -qF "after=" <<<"$output"                 # proves the wait branch, not the pre-wait bail
  refute grep -qF "status=ready" <<<"$output"
}

@test "spawn-side naming: on the WAIT path a named seat that becomes ready reports status=ready" {
  # Positive control for the wait branch: naming succeeds and the sentinel appears,
  # so the terminal status is ready (not spawned-but-unnamed).
  _install_fake_naming_herdr
  bash "$SCRIPTS/join.sh" wtteam alice claude-code "$PROJ"
  # actas-lock.sh needs SKILL_DIR; spawn computes it as scripts/.. = TEST_SKILL_DIR,
  # so setting it to the same value makes agmsg_ready_path match spawn's own path.
  export SKILL_DIR="$TEST_SKILL_DIR"
  # shellcheck disable=SC1090
  source "$SCRIPTS/lib/actas-lock.sh"
  export FAKE_READY_TOUCH; FAKE_READY_TOUCH="$(agmsg_ready_path wtteam alice)"
  export FAKE_NAME_LOG="$TEST_SKILL_DIR/name.log"; : > "$FAKE_NAME_LOG"
  run env FAKE_NAME_LOG="$FAKE_NAME_LOG" FAKE_READY_TOUCH="$FAKE_READY_TOUCH" \
    bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --terminal-driver herdr --ready-timeout 10
  [ "$status" -eq 0 ]
  grep -qF "status=ready" <<<"$output"
  refute grep -qF "status=spawned-but-unnamed" <<<"$output"
}

# --- #1096: the caller's pane is not the new member's to name ------------------------
#
# spawn pre-joins the new member by running join.sh in the CALLER's process, and
# join's boot-time self-naming resolves "self" through that environment -- the
# caller's pane. Before the fix the caller's pane took the new member's label and
# key, and the tests below only ever looked at the NEW pane, so they stayed green.
# The caller assertion is the one that goes red on that tree.

@test "spawn: herdr -- the caller's pane keeps its label and key byte-for-byte across a spawn (#1096)" {
  _setup_fake_herdr
  bash "$SCRIPTS/join.sh" myteam existing claude-code "$PROJ"
  # The caller's pane as a person sees it before the spawn: a label and a key,
  # written through the same fake so `pane get` / the agent DB replay them.
  "$STUB_BIN/herdr" pane rename wT:pSelf 'myteam:existing' >/dev/null
  "$STUB_BIN/herdr" agent rename wT:pSelf a1111111111111111111111111 >/dev/null
  local before_label before_key after_label after_key
  before_label="$("$STUB_BIN/herdr" pane get wT:pSelf | sed -n 's/.*"label":"\([^"]*\)".*/\1/p')"
  before_key="$(awk -F'\t' '$1=="wT:pSelf"{k=$2} END{print k}' "$HERDR_AGENT_DB")"
  [ "$before_label" = 'myteam:existing' ]
  [ "$before_key" = a1111111111111111111111111 ]
  : > "$HERDR_CALL_LOG"

  run bash "$SCRIPTS/spawn.sh" claude-code alice --project "$PROJ" --no-wait
  [ "$status" -eq 0 ]

  # After: the same two values, read back the same way, and no rename argv ever
  # targeted the caller's pane.
  after_label="$("$STUB_BIN/herdr" pane get wT:pSelf | sed -n 's/.*"label":"\([^"]*\)".*/\1/p')"
  after_key="$(awk -F'\t' '$1=="wT:pSelf"{k=$2} END{print k}' "$HERDR_AGENT_DB")"
  [ "$after_label" = "$before_label" ]
  [ "$after_key" = "$before_key" ]
  refute grep -qE '^(pane|agent) rename wT:pSelf ' "$HERDR_CALL_LOG"

  # The NEW pane is the one named: prefixed label at creation, then the key.
  grep -q '^pane rename wT:pN myteam:alice$' "$HERDR_CALL_LOG"
  refute grep -q '^pane rename wT:pN alice$' "$HERDR_CALL_LOG"
  grep -q '^agent rename wT:pN ' "$HERDR_CALL_LOG"
  refute grep -qF 'status=spawned-but-unnamed' <<<"$output"
}

@test "join: registration does not name the caller with naming enabled or disabled" {
  # Exercise both switch values against a fake terminal.
  unset AGMSG_SELF_NAME
  _setup_fake_herdr
  # Registration alone does not establish whose identity the caller holds.
  bash "$SCRIPTS/join.sh" myteam bob claude-code "$PROJ"
  refute grep -q ' rename ' "$HERDR_CALL_LOG"
  : > "$HERDR_CALL_LOG"
  # The switch spawn sets on its pre-join: the same join, no naming call at all.
  AGMSG_SELF_NAME=off bash "$SCRIPTS/join.sh" myteam carol claude-code "$PROJ"
  refute grep -q ' rename ' "$HERDR_CALL_LOG"
  # ...and the join itself still happened: carol is registered for the project.
  bash "$SCRIPTS/identities.sh" "$PROJ" claude-code | grep -q 'carol'
}
