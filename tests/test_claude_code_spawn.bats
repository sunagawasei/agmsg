#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
  export PROJ="$TEST_SKILL_DIR/project"
  export FAKE_BIN="$TEST_SKILL_DIR/fake-bin"
  export CAPTURE="$TEST_SKILL_DIR/claude-spawn-capture"
  export FAKE_CLAUDE="$FAKE_BIN/claude"
  export FAKE_BRIDGE="$FAKE_BIN/claude-code-bridge-fake.sh"
  export PS_STUB_LOG="$CAPTURE/ps-stub.log"
  export PGREP_STUB_LOG="$CAPTURE/pgrep-stub.log"
  mkdir -p "$PROJ" "$FAKE_BIN" "$CAPTURE" "$TEST_SKILL_DIR/run"
  bash "$SCRIPTS/join.sh" team leader claude-code "$PROJ" >/dev/null
  # Interactive placement is part of the test input, never ambient host state.
  # A host tmux/herdr session would otherwise bypass the terminal fixture.
  unset TMUX HERDR_ENV HERDR_PANE_ID HERDR_WORKSPACE_ID
  hash -r 2>/dev/null || true

  cat > "$FAKE_CLAUDE" <<'STUB'
#!/usr/bin/env bash
set -u

{
  printf 'CMD'
  for arg in "$@"; do printf '\t%s' "$arg"; done
  printf '\n'
} >> "$FAKE_CAPTURE/claude-invocations"

if [ "${1:-}" = "--version" ]; then
  printf '%s\n' "${FAKE_VERSION:-2.1.220 (Claude Code)}"
  exit "${FAKE_VERSION_RC:-0}"
fi

is_print=0
is_stream_json=0
is_verbose=0
previous=""
for arg in "$@"; do
  [ "$arg" = "-p" ] && is_print=1
  [ "$arg" = "--verbose" ] && is_verbose=1
  [ "$previous" = "--output-format" ] && [ "$arg" = "stream-json" ] && is_stream_json=1
  [ "$arg" = "--output-format=stream-json" ] && is_stream_json=1
  previous="$arg"
done
if [ "$is_print" = 1 ] && [ "$is_stream_json" = 1 ] && [ "$is_verbose" != 1 ]; then
  printf '%s\n' 'Error: When using --print, --output-format=stream-json requires --verbose.' >&2
  exit 1
fi

count_file="$FAKE_CAPTURE/probe-count"
n="$(cat "$count_file" 2>/dev/null || echo 0)"
n=$((n + 1))
printf '%s\n' "$n" > "$count_file"
args_file="$FAKE_CAPTURE/probe.args.$n"
env_file="$FAKE_CAPTURE/probe.env.$n"
prompt_file="$FAKE_CAPTURE/probe.prompt.$n"
: > "$args_file"
settings=""
previous=""
for arg in "$@"; do
  printf 'ARG=%s\n' "$arg" >> "$args_file"
  [ "$previous" = "--settings" ] && settings="$arg"
  previous="$arg"
done
printf 'cwd=%s\nconfig=%s\nsid=%s\nclaudecode=%s\nchild=%s\n' \
  "$PWD" "${CLAUDE_CONFIG_DIR:-<unset>}" \
  "${CLAUDE_CODE_SESSION_ID:-<unset>}" "${CLAUDECODE:-<unset>}" \
  "${CLAUDE_CODE_CHILD_SESSION:-<unset>}" > "$env_file"
cat > "$prompt_file"
[ -n "$settings" ] && cp "$settings" "$FAKE_CAPTURE/probe.settings.$n"

case "${FAKE_PROBE_MODE:-complete}" in
  exit) exit 7 ;;
esac

layout="$(sed -n '1s/.*layout=\([^ .]*\).*/\1/p' "$prompt_file")"
token="$(grep -Eo 'agmsg-probe-[0-9]+' "$prompt_file" | head -1)"
[ -n "$layout" ] && [ -n "$token" ] || exit 8

if [ "${FAKE_VERBOSE_EVENTS:-0}" = 1 ]; then
  printf '{"type":"system","subtype":"init","session_id":"verbose-noise"}\n'
  printf '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"verbose-noise"}}}\n'
  printf '{"type":"assistant","message":{"content":[{"type":"text","text":"verbose-noise"}]}}\n'
fi

emit_pair() {
  local id="$1" tool="$2" marker="$3" is_error="$4" body="$5"
  local result_id="$id"
  [ "${FAKE_PROBE_MODE:-complete}" = uncorrelated ] && result_id="${id}-wrong"
  printf '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"%s","name":"%s","input":{"marker":"%s"}}]}}\n' \
    "$id" "$tool" "$marker"
  printf '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"%s","is_error":%s,"content":"%s"}]}}\n' \
    "$result_id" "$is_error" "$body"
}

case "$layout" in
  consultant)
    emit_pair c1 Bash "$token-consultant-scratch" false "completed"
    emit_pair c2 Bash "$token-repo-bash" false "Permission denied by sandbox"
    if [ "${FAKE_PROBE_MODE:-complete}" != missing ] \
      && { [ "${FAKE_PROBE_MODE:-complete}" != missing-first ] || [ "$n" -gt 1 ]; }; then
      emit_pair c3 Bash "$token-run-write" false "completed"
    fi
    ;;
  implementer)
    emit_pair i1 Bash "$token-repo-bash" false "completed"
    emit_pair i2 Edit "$token-repo-edit" false "completed"
    emit_pair i3 Write "$token-repo-write" false "completed"
    if [ "${FAKE_PROBE_MODE:-complete}" != missing ] \
      && { [ "${FAKE_PROBE_MODE:-complete}" != missing-first ] || [ "$n" -gt 1 ]; }; then
      emit_pair i4 Bash "$token-run-write" false "completed"
    fi
    ;;
  reviewer)
    emit_pair r1 Bash "$token-repo-bash" false "Permission denied by sandbox"
    emit_pair r2 Edit "$token-repo-edit" true "Permission denied by policy"
    emit_pair r3 Write "$token-repo-write" true "Permission denied by policy"
    emit_pair r4 Read "$token-sensitive-read" true "Permission denied by policy"
    if [ "${FAKE_PROBE_MODE:-complete}" != missing ] \
      && { [ "${FAKE_PROBE_MODE:-complete}" != missing-first ] || [ "$n" -gt 1 ]; }; then
      emit_pair r5 Bash "$token-run-write" false "completed"
    fi
    ;;
  *) exit 9 ;;
esac
printf '{"type":"result","subtype":"success","result":"text is never probe evidence"}\n'
STUB
  chmod +x "$FAKE_CLAUDE"

  cat > "$FAKE_BRIDGE" <<'STUB'
#!/usr/bin/env bash
set -u
name=""
team=""
project=""
previous=""
for arg in "$@"; do
  [ "$previous" = "--name" ] && name="$arg"
  [ "$previous" = "--team" ] && team="$arg"
  [ "$previous" = "--project" ] && project="$arg"
  previous="$arg"
done
capture="$FAKE_CAPTURE/bridge.args.$name"
: > "$capture"
printf '%s\n' "$$" >> "$FAKE_CAPTURE/bridge-launches"
for arg in "$@"; do printf 'ARG=%s\n' "$arg" >> "$capture"; done
printf 'cwd=%s\nconfig=%s\nsid=%s\nclaudecode=%s\nchild=%s\n' \
  "$PWD" "${CLAUDE_CONFIG_DIR:-<unset>}" \
  "${CLAUDE_CODE_SESSION_ID:-<unset>}" "${CLAUDECODE:-<unset>}" \
  "${CLAUDE_CODE_CHILD_SESSION:-<unset>}" > "$FAKE_CAPTURE/bridge.env.$name"

[ "${FAKE_BRIDGE_MODE:-live}" = live ] || exit 9
base="$FAKE_RUN/claude-code-bridge.$team.$name"
printf '%s\n' "$$" > "$base.pid"
printf 'pid=%s\nproject=%s\nteam=%s\nname=%s\ntype=claude-code\n' \
  "$$" "$project" "$team" "$name" > "$base.meta"
cleanup() {
  [ "$(cat "$base.pid" 2>/dev/null || true)" = "$$" ] && rm -f "$base.pid"
  [ "$(sed -n 's/^pid=//p' "$base.meta" 2>/dev/null | head -1)" = "$$" ] && rm -f "$base.meta"
  exit 0
}
trap cleanup TERM INT
while :; do sleep 1; done
STUB
  chmod +x "$FAKE_BRIDGE"
  cat > "$FAKE_BIN/record-terminal.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$FAKE_CAPTURE/interactive-launch"
printf 'resolved_claude=%s\n' "$(command -v claude 2>/dev/null || true)" \
  > "$FAKE_CAPTURE/interactive-resolution"
STUB
  chmod +x "$FAKE_BIN/record-terminal.sh"

  export AGMSG_CLAUDE_CMD="$FAKE_CLAUDE"
  export AGMSG_CLAUDE_BRIDGE_CMD="$FAKE_BRIDGE"
  export FAKE_CAPTURE="$CAPTURE"
  export FAKE_RUN="$TEST_SKILL_DIR/run"
  export FAKE_VERSION="2.1.220 (Claude Code)"
  export FAKE_VERSION_RC=0
  export FAKE_PROBE_MODE=complete
  export FAKE_BRIDGE_MODE=live
  export AGMSG_CLAUDE_PROBE_TIMEOUT=3
  export AGMSG_CLAUDE_SPAWN_READY_TICKS=30

  # Hermetic process discovery: production intentionally scans the real process
  # table, but tests must see only bridges launched inside this isolated fixture.
  cat > "$FAKE_BIN/ps" <<'STUB'
#!/usr/bin/env bash
requested="${*: -1}"
printf 'requested=%s argv=%s\n' "$requested" "$*" >> "$PS_STUB_LOG"
for args_file in "$FAKE_CAPTURE"/bridge.args.*; do
  [ -f "$args_file" ] || continue
  name="${args_file#"$FAKE_CAPTURE/bridge.args."}"
  pidfile="$FAKE_RUN/claude-code-bridge.team.$name.pid"
  [ "$(cat "$pidfile" 2>/dev/null || true)" = "$requested" ] || continue
  key="$(awk '$0=="ARG=--identity-key" { getline; sub(/^ARG=/,""); print; exit }' "$args_file")"
  [ -n "$key" ] || continue
  printf '%s --identity-key %s\n' "$FAKE_BRIDGE" "$key"
  exit 0
done
printf 'unrelated process\n'
STUB
  cat > "$FAKE_BIN/pgrep" <<'STUB'
#!/usr/bin/env bash
printf 'argv=%s\n' "$*" >> "$PGREP_STUB_LOG"
for pidfile in "$FAKE_RUN"/claude-code-bridge.*.pid; do
  [ -f "$pidfile" ] || continue
  file="${pidfile##*/}"
  identity="${file#claude-code-bridge.}"
  identity="${identity%.pid}"
  name="${identity#*.}"
  [ -f "$FAKE_CAPTURE/bridge.args.$name" ] || continue
  pid="$(cat "$pidfile" 2>/dev/null || true)"
  case "$pid" in ''|*[!0-9]*) continue ;; esac
  printf '%s\n' "$pid"
done
STUB
  chmod +x "$FAKE_BIN/ps" "$FAKE_BIN/pgrep"
}

teardown() {
  local pidfile pid
  if [ -f "$CAPTURE/bridge-launches" ]; then
    while IFS= read -r pid; do
      case "$pid" in ''|*[!0-9]*) continue ;; esac
      kill "$pid" 2>/dev/null || true
    done < "$CAPTURE/bridge-launches"
  fi
  for pidfile in "$TEST_SKILL_DIR"/run/claude-code-bridge.*.pid; do
    [ -f "$pidfile" ] || continue
    pid="$(cat "$pidfile" 2>/dev/null || true)"
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    kill "$pid" 2>/dev/null || true
  done
  sleep 0.1
  teardown_test_env
}

spawn_claude() {
  local name="$1"
  shift
  env CLAUDE_CODE_SESSION_ID=parent-sid CLAUDECODE=parent CLAUDE_CODE_CHILD_SESSION=parent-child \
    PATH="$FAKE_BIN:$PATH" \
    bash "$SCRIPTS/spawn.sh" claude-code "$name" \
      --project "$PROJ" --team team --headless "$@"
}

spawn_claude_configured() {
  local name="$1"
  shift
  env CLAUDE_CODE_SESSION_ID=parent-sid CLAUDECODE=parent CLAUDE_CODE_CHILD_SESSION=parent-child \
    TMUX= HERDR_ENV=0 HERDR_PANE_ID= HERDR_WORKSPACE_ID= \
    PATH="$FAKE_BIN:$PATH" \
    AGMSG_TERMINAL="$FAKE_BIN/record-terminal.sh {cmd}" \
    bash "$SCRIPTS/spawn.sh" claude-code "$name" \
      --project "$PROJ" --team team --no-wait "$@"
}

wait_bridge_capture() {
  wait_for_file "$CAPTURE/bridge.args.$1"
}

spawn_record_for() {
  local name="$1" file
  for file in "$TEST_SKILL_DIR"/run/spawn.*; do
    [ -f "$file" ] || continue
    grep -q $'\tclaude-code$' "$file" || continue
    case "$file" in *"$name"*) printf '%s' "$file"; return 0 ;; esac
  done
  return 1
}

json_scalar() {
  local file="$1" sql="$2"
  sqlite_mem "SELECT $sql FROM (SELECT readfile('$(rf "$file")') AS j);" | tr -d '\r'
}

json_array_has() {
  local file="$1" path="$2" value="$3" value_sql
  value_sql="$(printf '%s' "$value" | sed "s/'/''/g")"
  [ "$(sqlite_mem "SELECT COUNT(*) FROM json_each(readfile('$(rf "$file")'), '$path') WHERE value='$value_sql';")" -gt 0 ]
}

policy_shape() {
  awk '
    $0 == "ARG=--model" || $0 == "ARG=--effort" ||
    $0 == "ARG=--settings" || $0 == "ARG=--add-dir" ||
    $0 == "ARG=--disallowedTools" {
      print
      if (getline > 0) print
    }
  ' "$1"
}

@test "claude-code manifest advertises headless capability and consultant spawn has exact artifacts/env/cwd" {
  [ "$(bash -c "source '$SCRIPTS/lib/type-registry.sh'; agmsg_type_get claude-code headless")" = yes ]
  [ "$(bash -c "source '$SCRIPTS/lib/type-registry.sh'; agmsg_type_get claude-code spawn_unset_env")" = "CLAUDE_CODE_SESSION_ID CLAUDECODE CLAUDE_CODE_CHILD_SESSION" ]

  run spawn_claude consultant
  [ "$status" -eq 0 ]
  [[ "$output" == *"spawned headless consultant claude-code 'consultant'"* ]]
  wait_bridge_capture consultant

  local base="$TEST_SKILL_DIR/run/claude-code-bridge.team.consultant"
  local scratch="$TEST_SKILL_DIR/run/claude-code-team-consultant-cwd"
  local settings="$base.settings.json" pid record
  [ "$(sqlite_mem "SELECT json_valid(readfile('$(rf "$settings")'));")" = 1 ]
  [ "$(json_scalar "$settings" "json_extract(j,'\$.sandbox.failIfUnavailable')")" = 1 ]
  [ "$(json_scalar "$settings" "json_extract(j,'\$.sandbox.allowUnsandboxedCommands')")" = 0 ]
  json_array_has "$settings" '$.sandbox.filesystem.allowWrite' "$scratch"
  ! json_array_has "$settings" '$.sandbox.filesystem.allowWrite' "$PROJ"
  ! grep -Fxq 'ARG=--add-dir' "$CAPTURE/bridge.args.consultant"

  pid="$(cat "$base.pid")"
  [ -n "$pid" ]
  [ "$(cat "$base.meta")" = "$(printf 'pid=%s\nproject=%s\nidentities=team/consultant\ntype=claude-code' "$pid" "$scratch")" ]
  [ -f "$base.log" ]
  record="$(spawn_record_for consultant)"
  [ "$(cat "$record")" = "$(printf 'pid:%s\t%s\tclaude-code' "$pid" "$scratch")" ]

  grep -Fxq "cwd=$scratch" "$CAPTURE/probe.env.1"
  grep -Fxq "config=$TEST_SKILL_DIR/db/claude-worker-home" "$CAPTURE/probe.env.1"
  grep -Fxq 'sid=<unset>' "$CAPTURE/probe.env.1"
  grep -Fxq 'claudecode=<unset>' "$CAPTURE/probe.env.1"
  grep -Fxq 'child=<unset>' "$CAPTURE/probe.env.1"
  grep -Fxq "cwd=$scratch" "$CAPTURE/bridge.env.consultant"
  grep -Fxq 'ARG=--output-format' "$CAPTURE/bridge.args.consultant"
  grep -Fxq 'ARG=json' "$CAPTURE/bridge.args.consultant"
  grep -Fxq 'ARG=--identity-key' "$CAPTURE/bridge.args.consultant"
}

@test "implementer resolves model effort timeout and role with CLI model precedence" {
  bash "$SCRIPTS/config.sh" set spawn.claude_model.impl config-model
  bash "$SCRIPTS/config.sh" set spawn.claude_effort.impl high
  bash "$SCRIPTS/config.sh" set spawn.claude_turn_timeout.impl 91
  bash "$SCRIPTS/config.sh" set spawn.claude_implementer.impl true
  printf 'IMPLEMENTER ROLE\n' > "$TEST_SKILL_DIR/role.md"

  run spawn_claude impl --model cli-model --role-file "$TEST_SKILL_DIR/role.md"
  [ "$status" -eq 0 ]
  wait_bridge_capture impl

  local base="$TEST_SKILL_DIR/run/claude-code-bridge.team.impl"
  local settings="$base.settings.json"
  grep -Fxq 'ARG=--model' "$CAPTURE/bridge.args.impl"
  grep -Fxq 'ARG=cli-model' "$CAPTURE/bridge.args.impl"
  ! grep -Fxq 'ARG=config-model' "$CAPTURE/bridge.args.impl"
  grep -Fxq 'ARG=--effort' "$CAPTURE/bridge.args.impl"
  grep -Fxq 'ARG=high' "$CAPTURE/bridge.args.impl"
  grep -Fxq 'ARG=--turn-timeout' "$CAPTURE/bridge.args.impl"
  grep -Fxq 'ARG=91' "$CAPTURE/bridge.args.impl"
  grep -Fxq 'ARG=--add-dir' "$CAPTURE/bridge.args.impl"
  grep -Fxq "ARG=$PROJ" "$CAPTURE/bridge.args.impl"
  grep -Fxq 'ARG=--role-file' "$CAPTURE/bridge.args.impl"
  [ "$(cat "$base.role")" = "IMPLEMENTER ROLE" ]
  json_array_has "$settings" '$.permissions.allow' "Edit($PROJ/**)"
  json_array_has "$settings" '$.permissions.allow' "Write($PROJ/**)"
  json_array_has "$settings" '$.sandbox.filesystem.allowWrite' "$PROJ"
}

@test "reviewer runtime is strictly probe policy plus disallowedTools and settings enforce deeper denies" {
  bash "$SCRIPTS/config.sh" set spawn.claude_reviewer true
  bash "$SCRIPTS/config.sh" set spawn.claude_model.review opus
  bash "$SCRIPTS/config.sh" set spawn.claude_effort.review high

  run spawn_claude review
  [ "$status" -eq 0 ]
  wait_bridge_capture review

  local base="$TEST_SKILL_DIR/run/claude-code-bridge.team.review"
  local settings="$base.settings.json"
  local runtime_without_outer="$TEST_SKILL_DIR/runtime-policy"
  local probe_policy="$TEST_SKILL_DIR/probe-policy"
  policy_shape "$CAPTURE/bridge.args.review" \
    | awk '$0=="ARG=--disallowedTools" { getline; next } { print }' \
    > "$runtime_without_outer"
  policy_shape "$CAPTURE/probe.args.1" > "$probe_policy"
  run diff -u "$probe_policy" "$runtime_without_outer"
  [ "$status" -eq 0 ]
  [ "$(grep -Fxc 'ARG=--disallowedTools' "$CAPTURE/bridge.args.review")" -eq 1 ]
  grep -Fxq 'ARG=Edit,Write,NotebookEdit' "$CAPTURE/bridge.args.review"
  ! grep -Fq 'ARG=--disallowedTools' "$CAPTURE/probe.args.1"
  run diff -u "$CAPTURE/probe.env.1" "$CAPTURE/bridge.env.review"
  [ "$status" -eq 0 ]

  json_array_has "$settings" '$.permissions.deny' "Edit($PROJ/**)"
  json_array_has "$settings" '$.permissions.deny' "Write($PROJ/**)"
  ! json_array_has "$settings" '$.permissions.deny' "Read"
  json_array_has "$settings" '$.sandbox.filesystem.denyWrite' "$PROJ"
  json_array_has "$settings" '$.sandbox.filesystem.denyRead' "/"
  json_array_has "$settings" '$.sandbox.filesystem.allowRead' "$PROJ"
  json_array_has "$settings" '$.sandbox.filesystem.allowRead' "$TEST_SKILL_DIR"
  json_array_has "$settings" '$.sandbox.filesystem.allowRead' "/nix"
  grep -Fq 'Read(**/*credentials*/**)' "$settings"
  grep -Fq "$TEST_SKILL_DIR/db/claude-worker-home/projects/**" "$settings"
}

@test "inherit add-dirs defaults off and obeys global then per-name overrides through shared collector" {
  local shared="$TEST_SKILL_DIR/shared"
  local toolchain="$TEST_SKILL_DIR/toolchain"
  mkdir -p "$PROJ/.claude" "$shared" "$toolchain"
  printf '{"permissions":{"additionalDirectories":["%s","%s"]}}\n' \
    "$shared" "$toolchain" > "$PROJ/.claude/settings.local.json"

  run spawn_claude off-default --reviewer
  [ "$status" -eq 0 ]
  wait_bridge_capture off-default
  ! grep -Fxq "ARG=$shared" "$CAPTURE/bridge.args.off-default"
  ! json_array_has "$TEST_SKILL_DIR/run/claude-code-bridge.team.off-default.settings.json" \
    '$.sandbox.filesystem.allowRead' "$shared"

  bash "$SCRIPTS/config.sh" set spawn.claude_inherit_add_dirs true
  run spawn_claude global-on --reviewer
  [ "$status" -eq 0 ]
  wait_bridge_capture global-on
  grep -Fxq "ARG=$shared" "$CAPTURE/bridge.args.global-on"
  json_array_has "$TEST_SKILL_DIR/run/claude-code-bridge.team.global-on.settings.json" \
    '$.sandbox.filesystem.allowRead' "$shared"

  bash "$SCRIPTS/config.sh" set spawn.claude_inherit_add_dirs.global-off false
  run spawn_claude global-off --reviewer
  [ "$status" -eq 0 ]
  wait_bridge_capture global-off
  ! grep -Fxq "ARG=$shared" "$CAPTURE/bridge.args.global-off"

  bash "$SCRIPTS/config.sh" set spawn.claude_inherit_add_dirs false
  bash "$SCRIPTS/config.sh" set spawn.claude_inherit_add_dirs.per-on true
  run spawn_claude per-on --reviewer
  [ "$status" -eq 0 ]
  wait_bridge_capture per-on
  grep -Fxq "ARG=$toolchain" "$CAPTURE/bridge.args.per-on"

  bash "$SCRIPTS/config.sh" set spawn.claude_inherit_add_dirs true
  run spawn_claude 'unsafe+name' --reviewer
  [ "$status" -eq 0 ]
  [[ "$output" == *"not a safe config-key segment"* ]]
  wait_bridge_capture 'unsafe+name'
  grep -Fxq "ARG=$shared" "$CAPTURE/bridge.args.unsafe+name"
}

@test "explicit mode precedence matches codex and contradictory explicit modes fail" {
  bash "$SCRIPTS/config.sh" set spawn.claude_headless true
  bash "$SCRIPTS/config.sh" set spawn.claude_reviewer true
  bash "$SCRIPTS/config.sh" set spawn.claude_implementer.worker true

  run spawn_claude_configured configured
  [ "$status" -eq 0 ]
  [[ "$output" == *"spawned headless reviewer claude-code"* ]]

  run spawn_claude_configured interactive --interactive
  [ "$status" -eq 0 ]
  [ -f "$CAPTURE/interactive-launch" ]
  [ "$(cat "$CAPTURE/interactive-resolution")" = "resolved_claude=$FAKE_CLAUDE" ]
  [ ! -e "$CAPTURE/bridge.args.interactive" ]

  run spawn_claude worker
  [ "$status" -eq 0 ]
  [[ "$output" == *"headless implementer claude-code"* ]]

  bash "$SCRIPTS/config.sh" set spawn.claude_implementer.explicit-review true
  run spawn_claude explicit-review --reviewer
  [ "$status" -eq 0 ]
  [[ "$output" == *"headless reviewer claude-code"* ]]

  run spawn_claude no-reviewer --no-reviewer
  [ "$status" -eq 0 ]
  [[ "$output" == *"headless consultant claude-code"* ]]

  run spawn_claude contradiction --reviewer --implementer
  [ "$status" -ne 0 ]
  [[ "$output" == *"mutually exclusive"* ]]
  [ ! -e "$TEST_SKILL_DIR/run/claude-code-bridge.team.contradiction.settings.json" ]
}

@test "unsafe option values and invalid timeout are rejected without argv injection" {
  bash "$SCRIPTS/config.sh" set spawn.claude_model.safe 'bad;model'
  bash "$SCRIPTS/config.sh" set spawn.claude_effort.safe 'high$(oops)'
  bash "$SCRIPTS/config.sh" set spawn.claude_turn_timeout.safe 0003

  run spawn_claude safe
  [ "$status" -eq 0 ]
  [[ "$output" == *"ignoring unsafe Claude model"* ]]
  [[ "$output" == *"ignoring unsafe Claude effort"* ]]
  [[ "$output" == *"ignoring invalid Claude turn timeout"* ]]
  wait_bridge_capture safe
  ! grep -Fq 'bad;model' "$CAPTURE/bridge.args.safe"
  ! grep -Fq 'high$(oops)' "$CAPTURE/bridge.args.safe"
  ! grep -Fxq 'ARG=--turn-timeout' "$CAPTURE/bridge.args.safe"

  run spawn_claude unsafe-cli --model 'x;touch'
  [ "$status" -eq 0 ]
  [[ "$output" == *"ignoring unsafe Claude model"* ]]
  wait_bridge_capture unsafe-cli
  ! grep -Fq 'x;touch' "$CAPTURE/bridge.args.unsafe-cli"
}

@test "minimum version is numeric and malformed or wrong suffix fails before artifacts" {
  export FAKE_VERSION="2.1.99 (Claude Code)"
  run spawn_claude below
  [ "$status" -ne 0 ]
  [[ "$output" == *"below the live-verified minimum 2.1.220"* ]]
  [ ! -e "$TEST_SKILL_DIR/run/claude-code-bridge.team.below.log" ]

  export FAKE_VERSION="2.1.220 (Claude Code)"
  run spawn_claude equal
  [ "$status" -eq 0 ]

  export FAKE_VERSION="2.2.0 (Claude Code)"
  run spawn_claude above
  [ "$status" -eq 0 ]

  export FAKE_VERSION="2.1.220"
  run spawn_claude malformed
  [ "$status" -ne 0 ]
  [[ "$output" == *"unparseable Claude Code version"* ]]
  [ ! -e "$TEST_SKILL_DIR/run/claude-code-bridge.team.malformed.log" ]

  export FAKE_VERSION="2.1.220 (Claude)"
  run spawn_claude wrong-suffix
  [ "$status" -ne 0 ]
  [[ "$output" == *"unparseable Claude Code version"* ]]
}

@test "fake Claude reproduces the real stream-json verbose requirement" {
  run "$FAKE_CLAUDE" -p --output-format stream-json --no-session-persistence
  [ "$status" -eq 1 ]
  [ "$output" = "Error: When using --print, --output-format=stream-json requires --verbose." ]
  [ ! -e "$CAPTURE/probe-count" ]
}

@test "probe supplies verbose and unrelated verbose events neither break nor satisfy correlation" {
  export FAKE_VERBOSE_EVENTS=1
  run spawn_claude verbose-events --reviewer
  [ "$status" -eq 0 ]
  grep -Fxq 'ARG=--verbose' "$CAPTURE/probe.args.1"
  [ "$(grep -Fxc 'ARG=--verbose' "$CAPTURE/probe.args.1")" -eq 1 ]

  printf '0\n' > "$CAPTURE/probe-count"
  export FAKE_PROBE_MODE=missing
  run spawn_claude verbose-missing --reviewer
  [ "$status" -ne 0 ]
  [[ "$output" == *"did not produce every required correlated tool event after 2 attempts"* ]]
  grep -Fxq 'ARG=--verbose' "$CAPTURE/probe.args.1"
  grep -Fxq 'ARG=--verbose' "$CAPTURE/probe.args.2"
  [ ! -e "$CAPTURE/bridge.args.verbose-missing" ]

  printf '0\n' > "$CAPTURE/probe-count"
  export FAKE_PROBE_MODE=uncorrelated
  run spawn_claude verbose-uncorrelated --reviewer
  [ "$status" -ne 0 ]
  [[ "$output" == *"did not produce every required correlated tool event after 2 attempts"* ]]
  [ ! -e "$CAPTURE/bridge.args.verbose-uncorrelated" ]
}

@test "probe retries once for missing events and fails closed on missing or uncorrelated results" {
  export FAKE_PROBE_MODE=missing-first
  run spawn_claude retry --reviewer
  [ "$status" -eq 0 ]
  [ "$(cat "$CAPTURE/probe-count")" -eq 2 ]

  printf '0\n' > "$CAPTURE/probe-count"
  export FAKE_PROBE_MODE=missing
  run spawn_claude missing --reviewer
  [ "$status" -ne 0 ]
  [[ "$output" == *"did not produce every required correlated tool event after 2 attempts"* ]]
  [ ! -e "$TEST_SKILL_DIR/run/claude-code-bridge.team.missing.settings.json" ]
  [ ! -e "$CAPTURE/bridge.args.missing" ]

  printf '0\n' > "$CAPTURE/probe-count"
  export FAKE_PROBE_MODE=uncorrelated
  run spawn_claude unrelated --reviewer
  [ "$status" -ne 0 ]
  [ ! -e "$CAPTURE/bridge.args.unrelated" ]
}

@test "concurrent same-identity spawns run one probe and bridge while winner artifacts survive" {
  local output_a="$BATS_TEST_TMPDIR/concurrent-a.out"
  local output_b="$BATS_TEST_TMPDIR/concurrent-b.out"
  local status_a="$BATS_TEST_TMPDIR/concurrent-a.status"
  local status_b="$BATS_TEST_TMPDIR/concurrent-b.status"
  (
    if spawn_claude concurrent > "$output_a" 2>&1; then
      printf '0\n' > "$status_a"
    else
      printf '%s\n' "$?" > "$status_a"
    fi
  ) &
  local pid_a=$!
  (
    if spawn_claude concurrent > "$output_b" 2>&1; then
      printf '0\n' > "$status_b"
    else
      printf '%s\n' "$?" > "$status_b"
    fi
  ) &
  local pid_b=$!
  wait "$pid_a"
  wait "$pid_b"

  [ "$(cat "$status_a")" -eq 0 ]
  [ "$(cat "$status_b")" -eq 0 ]
  [ "$(cat "$CAPTURE/probe-count")" -eq 1 ]
  [ "$(wc -l < "$CAPTURE/bridge-launches" | tr -d ' ')" -eq 1 ]
  [ -s "$PS_STUB_LOG" ]
  [ -s "$PGREP_STUB_LOG" ]
  [ "$(grep -h -c 'spawned headless consultant' "$output_a" "$output_b" | awk '{s += $1} END {print s}')" -eq 1 ]
  [ "$(grep -h -c 'already running' "$output_a" "$output_b" | awk '{s += $1} END {print s}')" -eq 1 ]

  local base="$TEST_SKILL_DIR/run/claude-code-bridge.team.concurrent"
  local scratch="$TEST_SKILL_DIR/run/claude-code-team-concurrent-cwd"
  local settings="$base.settings.json"
  local pid record record_count=0 file
  [ "$(sqlite_mem "SELECT json_valid(readfile('$(rf "$settings")'));")" = 1 ]
  grep -Fxq "ARG=$settings" "$CAPTURE/bridge.args.concurrent"
  [ -d "$scratch" ]
  [ -f "$base.log" ]
  [ -z "$(find "$TEST_SKILL_DIR/run" -maxdepth 1 -name 'claude-code-bridge.team.concurrent.probe.*' -print -quit)" ]

  pid="$(cat "$base.pid")"
  [ -n "$pid" ]
  [ "$(cat "$base.meta")" = "$(printf 'pid=%s\nproject=%s\nidentities=team/concurrent\ntype=claude-code' "$pid" "$scratch")" ]
  for file in "$TEST_SKILL_DIR"/run/spawn.*; do
    [ -f "$file" ] || continue
    record_count=$((record_count + 1))
    record="$file"
  done
  [ "$record_count" -eq 1 ]
  [ "$(cat "$record")" = "$(printf 'pid:%s\t%s\tclaude-code' "$pid" "$scratch")" ]
}

@test "placement-lock acquisition timeout fails closed without touching owner artifacts" {
  local base="$TEST_SKILL_DIR/run/claude-code-bridge.team.lockfail"
  local scratch="$TEST_SKILL_DIR/run/claude-code-team-lockfail-cwd"
  local lock="$TEST_SKILL_DIR/run/placement.team__lockfail.lock"
  mkdir "$scratch" "$lock"
  printf '{"winner":true}\n' > "$base.settings.json"
  printf 'winner-log\n' > "$base.log"
  printf 'winner-meta\n' > "$base.meta"
  printf 'winner-pid\n' > "$base.pid"
  printf 'winner-scratch\n' > "$scratch/winner"

  run spawn_claude lockfail
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not acquire placement lock"* ]]
  [ ! -e "$CAPTURE/probe-count" ]
  [ ! -e "$CAPTURE/bridge.args.lockfail" ]
  [ ! -e "$CAPTURE/bridge-launches" ]
  ! spawn_record_for lockfail

  [ "$(cat "$base.settings.json")" = '{"winner":true}' ]
  [ "$(cat "$base.log")" = winner-log ]
  [ "$(cat "$base.meta")" = winner-meta ]
  [ "$(cat "$base.pid")" = winner-pid ]
  [ "$(cat "$scratch/winner")" = winner-scratch ]
  [ -d "$lock" ]
}

@test "duplicate guard requires live argv identity and stale or wrong identity does not block spawn" {
  run spawn_claude duplicate
  [ "$status" -eq 0 ]
  local first_pid
  first_pid="$(cat "$TEST_SKILL_DIR/run/claude-code-bridge.team.duplicate.pid")"
  grep -Fq $'CMD\t--version' "$CAPTURE/claude-invocations"
  grep -Fq $'CMD\t-p\t--verbose\t--output-format\tstream-json' "$CAPTURE/claude-invocations"
  [ -s "$PGREP_STUB_LOG" ]

  run spawn_claude duplicate
  [ "$status" -eq 0 ]
  [[ "$output" == *"already running"* ]]
  [ "$(cat "$TEST_SKILL_DIR/run/claude-code-bridge.team.duplicate.pid")" = "$first_pid" ]
  grep -Fq "requested=$first_pid " "$PS_STUB_LOG"

  printf '999999\n' > "$TEST_SKILL_DIR/run/claude-code-bridge.team.stale.pid"
  run spawn_claude stale
  [ "$status" -eq 0 ]
  wait_bridge_capture stale

  local unrelated=$$
  printf '%s\n' "$unrelated" > "$TEST_SKILL_DIR/run/claude-code-bridge.team.wrong.pid"
  run spawn_claude wrong
  [ "$status" -eq 0 ]
  wait_bridge_capture wrong
}

@test "bridge launch failure unwinds only owned artifacts and preserves recovery blobs" {
  local base="$TEST_SKILL_DIR/run/claude-code-bridge.team.fail"
  printf 'saved-session\n' > "$base.session"
  printf '[{"to":"leader","body":"saved"}]\n' > "$base.outbound.json"
  printf 'FAIL ROLE\n' > "$TEST_SKILL_DIR/fail-role.md"
  export FAKE_BRIDGE_MODE=exit

  run spawn_claude fail --reviewer --role-file "$TEST_SKILL_DIR/fail-role.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"failed to publish a live owner pid"* ]]
  [ "$(cat "$base.session")" = saved-session ]
  [ -f "$base.outbound.json" ]
  [ ! -e "$base.settings.json" ]
  [ ! -e "$base.pid" ]
  [ ! -e "$base.meta" ]
  [ ! -e "$base.role" ]
  [ ! -e "$base.log" ]
  [ ! -e "$TEST_SKILL_DIR/run/claude-code-team-fail-cwd" ]
  run bash "$SCRIPTS/identities.sh" "$TEST_SKILL_DIR/run/claude-code-team-fail-cwd" claude-code
  [[ "$output" != *$'team\tfail'* ]]
}
