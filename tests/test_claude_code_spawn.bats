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
  unset BASH_ENV ENV PROMPT_COMMAND CDPATH ZDOTDIR CLAUDE_ENV_FILE
  unset AGMSG_CLAUDE_KEEP_PROBE FAKE_WRONG_RUN_PATH
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
shellopts_exported=unset
bashopts_exported=unset
env | grep -q '^SHELLOPTS=' && shellopts_exported=set
env | grep -q '^BASHOPTS=' && bashopts_exported=set
printf 'cwd=%s\nconfig=%s\nsid=%s\nclaudecode=%s\nchild=%s\ntmpdir=%s\nresolve_project=%s\nbash_env=%s\nenv=%s\nprompt_command=%s\ncdpath=%s\nzdotdir=%s\nclaude_env_file=%s\nshellopts_exported=%s\nbashopts_exported=%s\n' \
  "$PWD" "${CLAUDE_CONFIG_DIR:-<unset>}" \
  "${CLAUDE_CODE_SESSION_ID:-<unset>}" "${CLAUDECODE:-<unset>}" \
  "${CLAUDE_CODE_CHILD_SESSION:-<unset>}" "${TMPDIR:-<unset>}" \
  "${AGMSG_RESOLVE_PROJECT:-<unset>}" \
  "${BASH_ENV:-<unset>}" "${ENV:-<unset>}" "${PROMPT_COMMAND:-<unset>}" \
  "${CDPATH:-<unset>}" "${ZDOTDIR:-<unset>}" "${CLAUDE_ENV_FILE:-<unset>}" \
  "$shellopts_exported" "$bashopts_exported" > "$env_file"
cat > "$prompt_file"
[ -n "$settings" ] && cp "$settings" "$FAKE_CAPTURE/probe.settings.$n"

case "${FAKE_PROBE_MODE:-complete}" in
  exit) exit 7 ;;
esac

layout="$(sed -n '1s/.*layout=\([^ .]*\).*/\1/p' "$prompt_file")"
token="$(grep -Eo 'agmsg-probe-[0-9]+' "$prompt_file" | head -1)"
[ -n "$layout" ] && [ -n "$token" ] || exit 8
run_target="$(sed -n 's/^run-write-target=//p' "$prompt_file" | head -1)"
repo_bash_target="$(sed -n 's/^repo-bash-target=//p' "$prompt_file" | head -1)"
edit_target="$(sed -n 's/^edit-target=//p' "$prompt_file" | head -1)"
repo_write_target="$(sed -n 's/^repo-write-target=//p' "$prompt_file" | head -1)"
scratch_target="$(sed -n 's/^scratch-write-target=//p' "$prompt_file" | head -1)"
sensitive_target="$(sed -n 's/^sensitive-read-target=//p' "$prompt_file" | head -1)"
scratch_command="$(sed -n 's/^scratch-write-command=//p' "$prompt_file" | head -1)"
repo_bash_command="$(sed -n 's/^repo-bash-command=//p' "$prompt_file" | head -1)"
run_write_command="$(sed -n 's/^run-write-command=//p' "$prompt_file" | head -1)"
events_file="$FAKE_CAPTURE/probe.events.$n"
: > "$events_file"

if [ "${FAKE_VERBOSE_EVENTS:-0}" = 1 ]; then
  printf '{"type":"system","subtype":"init","session_id":"verbose-noise"}\n'
  printf '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"verbose-noise"}}}\n'
  printf '{"type":"assistant","message":{"content":[{"type":"text","text":"verbose-noise"}]}}\n'
fi

emit_pair() {
  local id="$1" tool="$2" marker="$3" is_error="$4" body="$5"
  local actual_input="${6:-}" other_field="${7:-}" result_id="$id"
  local actual_json other_json
  [ "${FAKE_PROBE_MODE:-complete}" = uncorrelated ] && result_id="${id}-wrong"
  actual_json="$(printf '%s' "$actual_input" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  other_json="$(printf '%s' "$other_field" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  if [ "$tool" = Bash ]; then
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"%s","name":"%s","input":{"command":"%s","note":"%s"}}]}}\n' \
      "$id" "$tool" "$actual_json" "$other_json" | tee -a "$events_file"
  else
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"%s","name":"%s","input":{"file_path":"%s","note":"%s"}}]}}\n' \
      "$id" "$tool" "$actual_json" "$other_json" | tee -a "$events_file"
  fi
  printf '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"%s","is_error":%s,"content":"%s"}]}}\n' \
    "$result_id" "$is_error" "$body" | tee -a "$events_file"
}

emit_run_write() {
  local target="$run_target"
  if [ "${FAKE_PROBE_MODE:-complete}" = wrong-run-path ]; then
    target="${FAKE_WRONG_RUN_PATH:?FAKE_WRONG_RUN_PATH is required}"
  fi
  printf '%s' "$token-run-write" > "$target"
  printf 'run_path=%s\n' "$target" >> "$FAKE_CAPTURE/probe.effects.$n"
  emit_pair "${1:?}" Bash "$token-run-write" false "completed" "$run_write_command"
}

case "$layout" in
  consultant)
    printf '%s' "$token-consultant-scratch" > "$scratch_target"
    emit_pair c1 Bash "$token-consultant-scratch" false "completed" "$scratch_command"
    emit_pair c2 Bash "$token-repo-bash" true \
      "(eval):1: operation not permitted: $repo_bash_target" "$repo_bash_command"
    if [ "${FAKE_PROBE_MODE:-complete}" != missing ] \
      && { [ "${FAKE_PROBE_MODE:-complete}" != missing-first ] || [ "$n" -gt 1 ]; }; then
      emit_run_write c3
    fi
    ;;
  implementer)
    printf '%s' "$token-repo-bash" > "$repo_bash_target"
    printf '%s' "CHANGED $token" > "$edit_target"
    printf '%s' "$token-repo-write" > "$repo_write_target"
    emit_pair i1 Bash "$token-repo-bash" false "completed" "$repo_bash_command"
    emit_pair i2 Edit "$token-repo-edit" false "completed" "$edit_target"
    emit_pair i3 Write "$token-repo-write" false "completed" "$repo_write_target"
    if [ "${FAKE_PROBE_MODE:-complete}" != missing ] \
      && { [ "${FAKE_PROBE_MODE:-complete}" != missing-first ] || [ "$n" -gt 1 ]; }; then
      emit_run_write i4
    fi
    ;;
  reviewer)
    emit_pair r1 Bash "$token-repo-bash" true \
      "(eval):1: operation not permitted: $repo_bash_target" "$repo_bash_command"
    emit_pair r2read Read "$token-edit-prereq-read" false "completed" "$edit_target"
    if [ "${FAKE_PROBE_MODE:-complete}" = edit-precondition ]; then
      emit_pair r2 Edit "$token-repo-edit" true "<tool_use_error>File has not been read yet</tool_use_error>" "$edit_target"
    else
      emit_pair r2 Edit "$token-repo-edit" true \
        "Claude requested permissions to write to $edit_target, but you haven’t granted it yet." "$edit_target"
    fi
    emit_pair r3 Write "$token-repo-write" true \
      "Claude requested permissions to write to $repo_write_target, but you haven’t granted it yet." "$repo_write_target"
    case "${FAKE_PROBE_MODE:-complete}" in
      reviewer-edit-side-effect)
        printf '%s' "CHANGED $token" > "$edit_target" ;;
      reviewer-write-side-effect)
        printf '%s' "$token-repo-write" > "$repo_write_target" ;;
      reviewer-bash-side-effect)
        printf '%s' "$token-repo-bash" > "$repo_bash_target" ;;
    esac
    case "${FAKE_PROBE_MODE:-complete}" in
      sensitive-read-success)
        emit_pair r4 Read "$token-sensitive-read" false "synthetic read succeeded" "$sensitive_target" ;;
      sensitive-error-only)
        emit_pair r4 Read "$token-sensitive-read" true "synthetic tool error" "$sensitive_target" ;;
      sensitive-cwd-override)
        emit_pair r4 Read "$token-sensitive-read" true \
          "Claude requested permissions to read from $sensitive_target, but you haven’t granted it yet." \
          "$PWD/.not-the-sentinel" ;;
      sensitive-prefix)
        emit_pair r4 Read "$token-sensitive-read" true \
          "Claude requested permissions to read from $sensitive_target, but you haven’t granted it yet." \
          "${sensitive_target}.backup" ;;
      sensitive-other-field)
        emit_pair r4 Read "$token-sensitive-read" true \
          "Claude requested permissions to read from $sensitive_target, but you haven’t granted it yet." \
          "$PWD/.not-the-sentinel" "$sensitive_target" ;;
      *)
        emit_pair r4 Read "$token-sensitive-read" true \
          "Claude requested permissions to read from $sensitive_target, but you haven’t granted it yet." \
          "$sensitive_target" ;;
    esac
    if [ "${FAKE_PROBE_MODE:-complete}" != missing ] \
      && { [ "${FAKE_PROBE_MODE:-complete}" != missing-first ] || [ "$n" -gt 1 ]; }; then
      emit_run_write r5
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
shellopts_exported=unset
bashopts_exported=unset
env | grep -q '^SHELLOPTS=' && shellopts_exported=set
env | grep -q '^BASHOPTS=' && bashopts_exported=set
printf 'cwd=%s\nconfig=%s\nsid=%s\nclaudecode=%s\nchild=%s\ntmpdir=%s\nresolve_project=%s\nbash_env=%s\nenv=%s\nprompt_command=%s\ncdpath=%s\nzdotdir=%s\nclaude_env_file=%s\nshellopts_exported=%s\nbashopts_exported=%s\n' \
  "$PWD" "${CLAUDE_CONFIG_DIR:-<unset>}" \
  "${CLAUDE_CODE_SESSION_ID:-<unset>}" "${CLAUDECODE:-<unset>}" \
  "${CLAUDE_CODE_CHILD_SESSION:-<unset>}" "${TMPDIR:-<unset>}" \
  "${AGMSG_RESOLVE_PROJECT:-<unset>}" \
  "${BASH_ENV:-<unset>}" "${ENV:-<unset>}" "${PROMPT_COMMAND:-<unset>}" \
  "${CDPATH:-<unset>}" "${ZDOTDIR:-<unset>}" "${CLAUDE_ENV_FILE:-<unset>}" \
  "$shellopts_exported" "$bashopts_exported" > "$FAKE_CAPTURE/bridge.env.$name"

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
  model="$(awk '$0=="ARG=--model" { getline; sub(/^ARG=/,""); print; exit }' "$args_file")"
  [ -n "$key" ] || continue
  if [ -n "$model" ]; then
    printf 'returned=%s --model %s --identity-key %s\n' \
      "$FAKE_BRIDGE" "$model" "$key" >> "$PS_STUB_LOG"
    printf '%s --model %s --identity-key %s\n' "$FAKE_BRIDGE" "$model" "$key"
  else
    printf '%s --identity-key %s\n' "$FAKE_BRIDGE" "$key"
  fi
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
  local pidfile pid terminated=""
  if [ -f "$CAPTURE/bridge-launches" ]; then
    while IFS= read -r pid; do
      case "$pid" in ''|*[!0-9]*) continue ;; esac
      kill "$pid" 2>/dev/null || true
      terminated="$terminated $pid"
    done < "$CAPTURE/bridge-launches"
  fi
  for pidfile in "$TEST_SKILL_DIR"/run/claude-code-bridge.*.pid; do
    [ -f "$pidfile" ] || continue
    pid="$(cat "$pidfile" 2>/dev/null || true)"
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    kill "$pid" 2>/dev/null || true
    terminated="$terminated $pid"
  done
  for pid in $terminated; do
    wait_for_pid_exit "$pid"
  done
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

json_array_count() {
  local file="$1" path="$2" value="$3" value_sql
  value_sql="$(printf '%s' "$value" | sed "s/'/''/g")"
  sqlite_mem "SELECT COUNT(*) FROM json_each(readfile('$(rf "$file")'), '$path') WHERE value='$value_sql';"
}

json_array_index() {
  local file="$1" path="$2" value="$3" value_sql
  value_sql="$(printf '%s' "$value" | sed "s/'/''/g")"
  sqlite_mem "SELECT MIN(CAST(key AS INTEGER)) FROM json_each(readfile('$(rf "$file")'), '$path') WHERE value='$value_sql';"
}

assert_json_array_unique() {
  local file="$1" path="$2" total distinct
  total="$(sqlite_mem "SELECT COUNT(*) FROM json_each(readfile('$(rf "$file")'), '$path');")"
  distinct="$(sqlite_mem "SELECT COUNT(DISTINCT value) FROM json_each(readfile('$(rf "$file")'), '$path');")"
  [ "$total" = "$distinct" ]
}

assert_permission_rule_shapes() {
  local file="$1" rule
  while IFS= read -r rule; do
    case "$rule" in
      Write\(*|NotebookEdit\(*) return 1 ;;
      *"(///"*) return 1 ;;
      *"(/"*)
        case "$rule" in *"(//"*) ;; *) return 1 ;; esac
        ;;
    esac
  done < <(
    sqlite_mem "
      SELECT value FROM json_each(readfile('$(rf "$file")'), '\$.permissions.allow')
      UNION ALL
      SELECT value FROM json_each(readfile('$(rf "$file")'), '\$.permissions.deny');
    "
  )
}

physical_path() {
  local path="$1" physical
  if physical="$(cd "$path" 2>/dev/null && pwd -P)" && [ -n "$physical" ]; then
    printf '%s' "$physical"
  else
    printf '%s' "$path"
  fi
}

assert_json_path_alias() {
  local file="$1" path="$2" raw="$3" physical raw_index physical_index
  physical="$(physical_path "$raw")"
  [ "$(json_array_count "$file" "$path" "$raw")" -eq 1 ]
  if [ "$physical" != "$raw" ]; then
    [ "$(json_array_count "$file" "$path" "$physical")" -eq 1 ]
    raw_index="$(json_array_index "$file" "$path" "$raw")"
    physical_index="$(json_array_index "$file" "$path" "$physical")"
    [ "$raw_index" -lt "$physical_index" ]
  fi
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

@test "claude-code sandbox path aliases preserve narrow role scopes and order" {
  local physical_skill="$TEST_SKILL_DIR"
  local logical_skill="$BATS_TEST_TMPDIR/skill-logical"
  local physical_project="$TEST_SKILL_DIR/alias-project-physical"
  local logical_project="$BATS_TEST_TMPDIR/project-logical"
  local physical_tmp="$TEST_SKILL_DIR/process-tmp-physical"
  local logical_tmp="$BATS_TEST_TMPDIR/process-tmp-logical"
  local physical_inherited="$TEST_SKILL_DIR/inherited-physical"
  local logical_inherited="$BATS_TEST_TMPDIR/inherited-logical"
  mkdir -p "$physical_project/.claude" "$physical_tmp" "$physical_inherited"
  ln -s "$physical_skill" "$logical_skill"
  ln -s "$physical_project" "$logical_project"
  ln -s "$physical_tmp" "$logical_tmp"
  ln -s "$physical_inherited" "$logical_inherited"
  printf '{"permissions":{"additionalDirectories":["%s"]}}\n' \
    "$logical_inherited" > "$physical_project/.claude/settings.local.json"

  export SCRIPTS="$logical_skill/scripts"
  export PROJ="$logical_project"
  export TMPDIR="$logical_tmp"
  bash "$SCRIPTS/config.sh" set spawn.claude_inherit_add_dirs true

  run spawn_claude alias-consultant
  [ "$status" -eq 0 ]
  wait_bridge_capture alias-consultant
  run spawn_claude alias-implementer --implementer
  [ "$status" -eq 0 ]
  wait_bridge_capture alias-implementer
  run spawn_claude alias-reviewer --reviewer
  [ "$status" -eq 0 ]
  wait_bridge_capture alias-reviewer

  local consultant="$TEST_SKILL_DIR/run/claude-code-bridge.team.alias-consultant.settings.json"
  local implementer="$TEST_SKILL_DIR/run/claude-code-bridge.team.alias-implementer.settings.json"
  local reviewer="$TEST_SKILL_DIR/run/claude-code-bridge.team.alias-reviewer.settings.json"
  local consultant_scratch="$logical_skill/run/claude-code-team-alias-consultant-cwd"
  local implementer_scratch="$logical_skill/run/claude-code-team-alias-implementer-cwd"
  local reviewer_scratch="$logical_skill/run/claude-code-team-alias-reviewer-cwd"
  local settings scratch raw path missing_tmp missing_settings

  run bash -c "
    SCRIPT_DIR='$SCRIPTS'
    SKILL_DIR='${SCRIPTS%/scripts}'
    . \"\$SCRIPT_DIR/lib/resolve-project.sh\"
    . \"\$SCRIPT_DIR/drivers/types/claude-code/_spawn.sh\"
    agmsg_claude_tool_rule Read /tmp/
    printf '\\n'
    agmsg_claude_tool_rule Read //tmp/
    printf '\\n'
    agmsg_claude_tool_rule Read /
    printf '\\n'
    agmsg_claude_tool_rule Read //
  "
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'Read(//tmp/**)\nRead(//tmp/**)\nRead(//**)\nRead(//**)')" ]

  for settings in "$consultant" "$implementer" "$reviewer"; do
    [ "$(sqlite_mem "SELECT json_valid(readfile('$(rf "$settings")'));")" = 1 ]
    assert_permission_rule_shapes "$settings"
    assert_json_array_unique "$settings" '$.sandbox.filesystem.allowWrite'
    assert_json_array_unique "$settings" '$.sandbox.filesystem.allowRead'
    for raw in "$logical_skill/db" "$logical_skill/teams" "$logical_skill/run" \
      "/tmp"; do
      assert_json_path_alias "$settings" '$.sandbox.filesystem.allowWrite' "$raw"
    done
    for raw in "$logical_skill" "/tmp" "/bin" "/usr/bin" "/usr/lib" \
      "/System" "/Library" "/nix" "/opt/homebrew" "/usr/local"; do
      assert_json_path_alias "$settings" '$.sandbox.filesystem.allowRead' "$raw"
    done
    [ "$(json_array_count "$settings" '$.sandbox.filesystem.allowRead' "/nix")" -eq 1 ]
    for path in '$.sandbox.filesystem.allowWrite' '$.sandbox.filesystem.allowRead'; do
      ! json_array_has "$settings" "$path" "$logical_tmp"
      ! json_array_has "$settings" "$path" "$physical_tmp"
    done
    ! json_array_has "$settings" '$.sandbox.filesystem.allowWrite' \
      "$logical_skill/db/claude-worker-home"
    ! json_array_has "$settings" '$.sandbox.filesystem.allowRead' "$HOME"
  done

  [ "$(physical_path /nix)" = /nix ]
  if [ "$(uname -s)" = Darwin ]; then
    [ "$(physical_path /tmp)" = /private/tmp ]
    for settings in "$consultant" "$implementer" "$reviewer"; do
      json_array_has "$settings" '$.sandbox.filesystem.allowWrite' /private/tmp
      json_array_has "$settings" '$.sandbox.filesystem.allowRead' /private/tmp
    done
  fi

  for settings in "$consultant" "$implementer" "$reviewer"; do
    case "$settings" in
      "$consultant") scratch="$consultant_scratch" ;;
      "$implementer") scratch="$implementer_scratch" ;;
      "$reviewer") scratch="$reviewer_scratch" ;;
    esac
    assert_json_path_alias "$settings" '$.sandbox.filesystem.allowWrite' "$scratch"
    assert_json_path_alias "$settings" '$.sandbox.filesystem.allowWrite' "$scratch/tmp"
    assert_json_path_alias "$settings" '$.sandbox.filesystem.allowRead' "$scratch"
  done

  for path in '$.sandbox.filesystem.allowWrite' '$.sandbox.filesystem.allowRead'; do
    ! json_array_has "$consultant" "$path" "$logical_project"
    ! json_array_has "$consultant" "$path" "$physical_project"
  done
  assert_json_path_alias "$implementer" '$.sandbox.filesystem.allowWrite' "$logical_project"
  assert_json_path_alias "$implementer" '$.sandbox.filesystem.allowRead' "$logical_project"
  assert_json_path_alias "$reviewer" '$.sandbox.filesystem.allowRead' "$logical_project"
  ! json_array_has "$reviewer" '$.sandbox.filesystem.allowWrite' "$logical_project"
  ! json_array_has "$reviewer" '$.sandbox.filesystem.allowWrite' "$physical_project"
  assert_json_path_alias "$reviewer" '$.sandbox.filesystem.allowRead' "$logical_inherited"
  ! json_array_has "$reviewer" '$.sandbox.filesystem.allowWrite' "$logical_inherited"
  ! json_array_has "$reviewer" '$.sandbox.filesystem.allowWrite' "$physical_inherited"

  json_array_has "$consultant" '$.sandbox.filesystem.denyWrite' "$logical_project"
  json_array_has "$reviewer" '$.sandbox.filesystem.denyWrite' "$logical_project"
  json_array_has "$reviewer" '$.sandbox.filesystem.denyRead' "/"
  json_array_has "$consultant" '$.permissions.allow' "Read(/$consultant_scratch/**)"
  ! json_array_has "$consultant" '$.permissions.allow' "Read($consultant_scratch/**)"
  json_array_has "$consultant" '$.permissions.deny' "Edit(/$logical_project/**)"
  ! json_array_has "$consultant" '$.permissions.deny' "Edit($logical_project/**)"
  json_array_has "$implementer" '$.permissions.allow' "Read(/$logical_project/**)"
  json_array_has "$implementer" '$.permissions.allow' "Edit(/$logical_project/**)"
  [ "$(json_array_count "$implementer" '$.permissions.allow' \
    "Edit(/$logical_project/**)")" -eq 1 ]
  json_array_has "$reviewer" '$.permissions.allow' "Read(/$logical_project/**)"
  ! json_array_has "$reviewer" '$.permissions.allow' "Read($logical_project/**)"
  json_array_has "$reviewer" '$.permissions.allow' "Read(/$logical_inherited/**)"
  ! json_array_has "$reviewer" '$.permissions.allow' "Read($logical_inherited/**)"
  json_array_has "$reviewer" '$.permissions.deny' "Edit(/$logical_project/**)"
  ! json_array_has "$reviewer" '$.permissions.deny' "Edit($logical_project/**)"
  json_array_has "$reviewer" '$.permissions.deny' "Read(/$HOME/.ssh/**)"
  ! grep -Fq 'Write(' "$consultant"
  ! grep -Fq 'Write(' "$implementer"
  ! grep -Fq 'Write(' "$reviewer"
  ! grep -Fq 'NotebookEdit(' "$consultant"
  ! grep -Fq 'NotebookEdit(' "$implementer"
  ! grep -Fq 'NotebookEdit(' "$reviewer"
  ! grep -Fq '(///' "$consultant"
  ! grep -Fq '(///' "$implementer"
  ! grep -Fq '(///' "$reviewer"
  [ "$(grep -Fxc 'ARG=--disallowedTools' "$CAPTURE/bridge.args.alias-reviewer")" -eq 1 ]
  grep -Fxq 'ARG=Edit,Write,NotebookEdit' "$CAPTURE/bridge.args.alias-reviewer"
  ! grep -Fq 'ARG=--disallowedTools' "$CAPTURE/probe.args.3"

  missing_tmp="$BATS_TEST_TMPDIR/missing-process-tmp"
  missing_settings="$BATS_TEST_TMPDIR/missing-settings.json"
  [ ! -e "$missing_tmp" ]
  (
    export TMPDIR="$missing_tmp"
    SCRIPT_DIR="$SCRIPTS"
    SKILL_DIR="${SCRIPTS%/scripts}"
    . "$SCRIPT_DIR/lib/resolve-project.sh"
    . "$SCRIPT_DIR/drivers/types/claude-code/_spawn.sh"
    agmsg_claude_generate_settings "$missing_settings" consultant \
      "$logical_project" "$consultant_scratch" "$logical_skill/db" \
      "$logical_skill/db/claude-worker-home" \
      "$logical_skill/db/claude-worker-home/projects/missing-sentinel" \
      "$consultant_scratch/tmp"
  )
  [ "$(sqlite_mem "SELECT json_valid(readfile('$(rf "$missing_settings")'));")" = 1 ]
  [ "$(json_array_count "$missing_settings" \
    '$.sandbox.filesystem.allowWrite' "$missing_tmp")" -eq 0 ]
  [ "$(json_array_count "$missing_settings" \
    '$.sandbox.filesystem.allowRead' "$missing_tmp")" -eq 0 ]
  assert_json_array_unique "$missing_settings" '$.sandbox.filesystem.allowWrite'
  assert_json_array_unique "$missing_settings" '$.sandbox.filesystem.allowRead'
  assert_permission_rule_shapes "$missing_settings"
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
  json_array_has "$settings" '$.sandbox.filesystem.allowWrite' "$scratch/tmp"
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
  grep -Fxq "tmpdir=$scratch/tmp" "$CAPTURE/probe.env.1"
  grep -Fxq 'resolve_project=0' "$CAPTURE/probe.env.1"
  grep -Fxq 'bash_env=<unset>' "$CAPTURE/probe.env.1"
  grep -Fxq 'env=<unset>' "$CAPTURE/probe.env.1"
  grep -Fxq 'prompt_command=<unset>' "$CAPTURE/probe.env.1"
  grep -Fxq 'cdpath=<unset>' "$CAPTURE/probe.env.1"
  grep -Fxq 'zdotdir=<unset>' "$CAPTURE/probe.env.1"
  grep -Fxq 'claude_env_file=<unset>' "$CAPTURE/probe.env.1"
  grep -Fxq 'shellopts_exported=unset' "$CAPTURE/probe.env.1"
  grep -Fxq 'bashopts_exported=unset' "$CAPTURE/probe.env.1"
  grep -Fxq "cwd=$scratch" "$CAPTURE/bridge.env.consultant"
  grep -Fxq "tmpdir=$scratch/tmp" "$CAPTURE/bridge.env.consultant"
  grep -Fxq 'resolve_project=0' "$CAPTURE/bridge.env.consultant"
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
  json_array_has "$settings" '$.permissions.allow' "Edit(/$PROJ/**)"
  ! json_array_has "$settings" '$.permissions.allow' "Edit($PROJ/**)"
  ! grep -Fq 'Write(' "$settings"
  ! grep -Fq 'NotebookEdit(' "$settings"
  json_array_has "$settings" '$.sandbox.filesystem.allowWrite' "$PROJ"
}

@test "bracketed Claude model alias reaches probe and bridge argv unchanged" {
  bash "$SCRIPTS/config.sh" set spawn.claude_model.alias 'opus[1m]'

  run spawn_claude alias
  [ "$status" -eq 0 ]
  wait_bridge_capture alias

  [ "$(awk '$0=="ARG=--model" { getline; print; exit }' "$CAPTURE/probe.args.1")" = \
    'ARG=opus[1m]' ]
  [ "$(awk '$0=="ARG=--model" { getline; print; exit }' "$CAPTURE/bridge.args.alias")" = \
    'ARG=opus[1m]' ]
  [ "$(grep -Fxc 'ARG=--model' "$CAPTURE/probe.args.1")" -eq 1 ]
  [ "$(grep -Fxc 'ARG=--model' "$CAPTURE/bridge.args.alias")" -eq 1 ]
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
  local sentinel_target probe_token repo_bash_target repo_edit_target repo_write_target
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

  json_array_has "$settings" '$.permissions.allow' "Read(/$PROJ/**)"
  ! json_array_has "$settings" '$.permissions.allow' "Read($PROJ/**)"
  json_array_has "$settings" '$.permissions.deny' "Edit(/$PROJ/**)"
  ! json_array_has "$settings" '$.permissions.deny' "Edit($PROJ/**)"
  ! grep -Fq 'Write(' "$settings"
  ! grep -Fq 'NotebookEdit(' "$settings"
  ! grep -Fq '(///' "$settings"
  ! json_array_has "$settings" '$.permissions.deny' "Read"
  json_array_has "$settings" '$.sandbox.filesystem.denyWrite' "$PROJ"
  json_array_has "$settings" '$.sandbox.filesystem.denyRead' "/"
  json_array_has "$settings" '$.sandbox.filesystem.allowRead' "$PROJ"
  json_array_has "$settings" '$.sandbox.filesystem.allowRead' "$TEST_SKILL_DIR"
  json_array_has "$settings" '$.sandbox.filesystem.allowRead' "/nix"
  json_array_has "$settings" '$.permissions.deny' 'Read(//**/*credentials*)'
  json_array_has "$settings" '$.permissions.deny' 'Read(//**/*credentials*/**)'
  ! json_array_has "$settings" '$.permissions.deny' 'Read(**/*credentials*)'
  ! json_array_has "$settings" '$.permissions.deny' 'Read(**/*credentials*/**)'
  json_array_has "$settings" '$.permissions.deny' \
    "Read(/$TEST_SKILL_DIR/db/claude-worker-home/projects/**)"
  grep -Fq "sensitive-read-target=$TEST_SKILL_DIR/db/claude-worker-home/projects/" \
    "$CAPTURE/probe.prompt.1"
  sentinel_target="$(sed -n 's/^sensitive-read-target=//p' \
    "$CAPTURE/probe.prompt.1" | head -1)"
  json_array_has "$settings" '$.permissions.deny' "Read(/$sentinel_target)"
  ! json_array_has "$settings" '$.permissions.deny' "Read($sentinel_target)"
  [ ! -e "$sentinel_target" ]
  ! grep -Fq "sensitive-read-target=$TEST_SKILL_DIR/run/claude-code-team-review-cwd/" \
    "$CAPTURE/probe.prompt.1"
  grep -Fq '"id":"r2read","name":"Read"' "$CAPTURE/probe.events.1"
  grep -Fq 'marker agmsg-probe-' "$CAPTURE/probe.events.1"
  grep -Fq '"id":"r2read","name":"Read","input":{"file_path":"'"$PROJ"'/.agmsg-probe-' \
    "$CAPTURE/probe.events.1"
  grep -Fq '"id":"r2","name":"Edit"' "$CAPTURE/probe.events.1"
  probe_token="$(grep -Eo 'agmsg-probe-[0-9]+' "$CAPTURE/probe.prompt.1" | head -1)"
  repo_bash_target="$PROJ/.${probe_token}-repo-bash"
  repo_edit_target="$PROJ/.${probe_token}-repo-edit"
  repo_write_target="$PROJ/.${probe_token}-repo-write"
  grep -Fq \
    "\"content\":\"(eval):1: operation not permitted: $repo_bash_target\"" \
    "$CAPTURE/probe.events.1"
  grep -Fq \
    "\"content\":\"Claude requested permissions to write to $repo_edit_target, but you haven’t granted it yet.\"" \
    "$CAPTURE/probe.events.1"
  grep -Fq \
    "\"content\":\"Claude requested permissions to write to $repo_write_target, but you haven’t granted it yet.\"" \
    "$CAPTURE/probe.events.1"
  grep -Fq \
    "\"content\":\"Claude requested permissions to read from $sentinel_target, but you haven’t granted it yet.\"" \
    "$CAPTURE/probe.events.1"
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

@test "malformed bracketed Claude model aliases are rejected" {
  local -a malformed=(
    'opus[[1m]]'
    'opus[1m'
    'opus1m]'
    'opus[1m][x]'
    '[1m]opus'
    'opus[]'
    'opus[1/m]'
    $'opus[1m]\n'
  )
  local model name probe_number=0

  for model in "${malformed[@]}"; do
    probe_number=$((probe_number + 1))
    name="bad-model-$probe_number"
    run spawn_claude "$name" --model "$model"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ignoring unsafe Claude model"* ]]
    wait_bridge_capture "$name"
    ! grep -Fxq 'ARG=--model' "$CAPTURE/probe.args.$probe_number"
    ! grep -Fxq 'ARG=--model' "$CAPTURE/bridge.args.$name"
  done
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

@test "reviewer sensitive Read targets the outside-cwd sentinel and fails closed on success or target substitution" {
  export FAKE_PROBE_MODE=sensitive-read-success
  run spawn_claude sensitive-success --reviewer
  [ "$status" -ne 0 ]
  [[ "$output" == *"did not produce every required correlated tool event"* ]]
  [ ! -e "$CAPTURE/bridge.args.sensitive-success" ]
  grep -Fq '"name":"Read","input":{"file_path":"'"$TEST_SKILL_DIR"'/db/claude-worker-home/projects/' \
    "$CAPTURE/probe.events.1"
  grep -Fq '"is_error":false,"content":"synthetic read succeeded"' \
    "$CAPTURE/probe.events.1"

  printf '0\n' > "$CAPTURE/probe-count"
  export FAKE_PROBE_MODE=sensitive-error-only
  run spawn_claude sensitive-error-only --reviewer
  [ "$status" -ne 0 ]
  [ ! -e "$CAPTURE/bridge.args.sensitive-error-only" ]
  grep -Fq '"is_error":true,"content":"synthetic tool error"' \
    "$CAPTURE/probe.events.1"

  printf '0\n' > "$CAPTURE/probe-count"
  export FAKE_PROBE_MODE=sensitive-cwd-override
  run spawn_claude sensitive-cwd --reviewer
  [ "$status" -ne 0 ]
  [ ! -e "$CAPTURE/bridge.args.sensitive-cwd" ]
  grep -Fq '"file_path":"'"$TEST_SKILL_DIR"'/run/claude-code-team-sensitive-cwd-cwd/.not-the-sentinel"' \
    "$CAPTURE/probe.events.1"

  printf '0\n' > "$CAPTURE/probe-count"
  export FAKE_PROBE_MODE=sensitive-prefix
  run spawn_claude sensitive-prefix --reviewer
  [ "$status" -ne 0 ]
  [ ! -e "$CAPTURE/bridge.args.sensitive-prefix" ]
  grep -Fq -- '-sensitive.backup","note":""' "$CAPTURE/probe.events.1"

  printf '0\n' > "$CAPTURE/probe-count"
  export FAKE_PROBE_MODE=sensitive-other-field
  run spawn_claude sensitive-other --reviewer
  [ "$status" -ne 0 ]
  [ ! -e "$CAPTURE/bridge.args.sensitive-other" ]
  grep -Fq '"file_path":"'"$TEST_SKILL_DIR"'/run/claude-code-team-sensitive-other-cwd/.not-the-sentinel","note":"'"$TEST_SKILL_DIR"'/db/claude-worker-home/projects/' \
    "$CAPTURE/probe.events.1"
}

@test "reviewer denial messages cannot mask repo Edit, Write, or Bash side effects" {
  local mode name
  for mode in \
    reviewer-edit-side-effect \
    reviewer-write-side-effect \
    reviewer-bash-side-effect; do
    printf '0\n' > "$CAPTURE/probe-count"
    export FAKE_PROBE_MODE="$mode"
    name="${mode#reviewer-}"
    run spawn_claude "$name" --reviewer
    [ "$status" -ne 0 ]
    [[ "$output" == *"did not produce every required correlated tool event"* ]]
    [ ! -e "$CAPTURE/bridge.args.$name" ]
  done
}

@test "probe and bridge scrub hostile shell state and exact run-file proof rejects wrong temp writes" {
  local hostile_tmp="$TEST_SKILL_DIR/hostile-tmp"
  local hostile_env="$TEST_SKILL_DIR/hostile-bash-env"
  local hostile_marker="$CAPTURE/hostile-wrapper-ran"
  mkdir -p "$hostile_tmp"
  cat > "$hostile_env" <<'HOSTILE'
if [ "${0:-}" = "${FAKE_CLAUDE:-}" ] && [ "${1:-}" != "--version" ]; then
  printf 'hostile wrapper ran\n' > "$HOSTILE_WRAPPER_MARKER"
  export TMPDIR="$HOSTILE_TMPDIR"
fi
HOSTILE
  export HOSTILE_WRAPPER_MARKER="$hostile_marker"
  export HOSTILE_TMPDIR="$hostile_tmp"
  export TMPDIR="$hostile_tmp"
  export BASH_ENV="$hostile_env"
  export ENV="$hostile_env"
  export PROMPT_COMMAND='printf hostile-prompt-command'
  export CDPATH="$hostile_tmp"
  export ZDOTDIR="$hostile_tmp"
  export CLAUDE_ENV_FILE="$hostile_tmp/claude-env"
  export SHELLOPTS BASHOPTS

  run spawn_claude hostile-env --reviewer
  [ "$status" -eq 0 ]
  wait_bridge_capture hostile-env
  local scratch="$TEST_SKILL_DIR/run/claude-code-team-hostile-env-cwd"
  local settings="$TEST_SKILL_DIR/run/claude-code-bridge.team.hostile-env.settings.json"
  [ ! -e "$hostile_marker" ]
  grep -Fxq "tmpdir=$scratch/tmp" "$CAPTURE/probe.env.1"
  grep -Fxq "tmpdir=$scratch/tmp" "$CAPTURE/bridge.env.hostile-env"
  grep -Fxq 'bash_env=<unset>' "$CAPTURE/probe.env.1"
  grep -Fxq 'env=<unset>' "$CAPTURE/probe.env.1"
  grep -Fxq 'prompt_command=<unset>' "$CAPTURE/probe.env.1"
  grep -Fxq 'cdpath=<unset>' "$CAPTURE/probe.env.1"
  grep -Fxq 'zdotdir=<unset>' "$CAPTURE/probe.env.1"
  grep -Fxq 'claude_env_file=<unset>' "$CAPTURE/probe.env.1"
  grep -Fxq 'shellopts_exported=unset' "$CAPTURE/probe.env.1"
  grep -Fxq 'bashopts_exported=unset' "$CAPTURE/probe.env.1"
  run diff -u "$CAPTURE/probe.env.1" "$CAPTURE/bridge.env.hostile-env"
  [ "$status" -eq 0 ]
  json_array_has "$settings" '$.sandbox.filesystem.allowWrite' "$scratch/tmp"
  ! json_array_has "$settings" '$.sandbox.filesystem.allowWrite' "$hostile_tmp"
  grep -Fq "run_path=$TEST_SKILL_DIR/run/.agmsg-probe-" \
    "$CAPTURE/probe.effects.1"

  printf '0\n' > "$CAPTURE/probe-count"
  export FAKE_PROBE_MODE=wrong-run-path
  export FAKE_WRONG_RUN_PATH="$hostile_tmp/wrong-run"
  run spawn_claude wrong-run --reviewer
  [ "$status" -ne 0 ]
  [[ "$output" == *"did not produce every required correlated tool event"* ]]
  [ "$(cat "$hostile_tmp/wrong-run")" = "$(grep -Eo 'agmsg-probe-[0-9]+' "$CAPTURE/probe.prompt.1" | head -1)-run-write" ]
  [ ! -e "$CAPTURE/bridge.args.wrong-run" ]
}

@test "Edit precondition error is rejected and KEEP_PROBE preserves only owned failure diagnostics" {
  export FAKE_PROBE_MODE=edit-precondition
  run spawn_claude edit-clean --reviewer
  [ "$status" -ne 0 ]
  local clean_base="$TEST_SKILL_DIR/run/claude-code-bridge.team.edit-clean"
  [ ! -e "$clean_base.settings.json" ]
  [ ! -e "$clean_base.probe.prompt" ]
  [ ! -e "$clean_base.probe.jsonl" ]
  [ ! -e "$clean_base.probe.stderr" ]
  [ ! -e "$CAPTURE/bridge.args.edit-clean" ]
  [ -z "$(find "$PROJ" -maxdepth 1 -name '.agmsg-probe-*-repo-edit' -print -quit)" ]
  [ -z "$(find "$TEST_SKILL_DIR/db/claude-worker-home/projects" \
    -maxdepth 1 -name '.agmsg-probe-*-sensitive' -print -quit 2>/dev/null)" ]

  printf '0\n' > "$CAPTURE/probe-count"
  export AGMSG_CLAUDE_KEEP_PROBE=1
  run spawn_claude edit-keep --reviewer
  [ "$status" -ne 0 ]
  local keep_base="$TEST_SKILL_DIR/run/claude-code-bridge.team.edit-keep"
  [[ "$output" == *"prompt: $keep_base.probe.prompt"* ]]
  [[ "$output" == *"trace: $keep_base.probe.jsonl"* ]]
  [[ "$output" == *"stderr: $keep_base.probe.stderr"* ]]
  [[ "$output" == *"settings: $keep_base.settings.json"* ]]
  [ -f "$keep_base.settings.json" ]
  [ -f "$keep_base.probe.prompt" ]
  [ -f "$keep_base.probe.jsonl" ]
  [ -f "$keep_base.probe.stderr" ]
  [ ! -s "$keep_base.probe.stderr" ]
  [ "$(find "$TEST_SKILL_DIR/run" -maxdepth 1 \
    -name 'claude-code-bridge.team.edit-keep*' | wc -l | tr -d ' ')" -eq 4 ]
  grep -Fq '"id":"r2read"' "$keep_base.probe.jsonl"
  grep -Fq '<tool_use_error>File has not been read yet</tool_use_error>' \
    "$keep_base.probe.jsonl"
  [ ! -e "$keep_base.log" ]
  [ ! -e "$CAPTURE/bridge.args.edit-keep" ]
  [ -z "$(find "$PROJ" -maxdepth 1 -name '.agmsg-probe-*-repo-edit' -print -quit)" ]
  [ -z "$(find "$TEST_SKILL_DIR/db/claude-worker-home/projects" \
    -maxdepth 1 -name '.agmsg-probe-*-sensitive' -print -quit 2>/dev/null)" ]

  printf '0\n' > "$CAPTURE/probe-count"
  export FAKE_PROBE_MODE=complete
  run spawn_claude keep-success --reviewer
  [ "$status" -eq 0 ]
  local success_base="$TEST_SKILL_DIR/run/claude-code-bridge.team.keep-success"
  [ -f "$success_base.settings.json" ]
  [ ! -e "$success_base.probe.prompt" ]
  [ ! -e "$success_base.probe.jsonl" ]
  [ ! -e "$success_base.probe.stderr" ]
}

@test "pre-existing probe-target collisions fail closed without deleting foreign files" {
  local collision_env="$TEST_SKILL_DIR/collision-bash-env"
  local name=foreign-collision
  local scratch="$TEST_SKILL_DIR/run/claude-code-team-$name-cwd"
  cat > "$collision_env" <<'COLLISION'
if [ "${0:-}" = "${SPAWN_SCRIPT_FOR_COLLISION:-}" ]; then
  collision_token="agmsg-probe-$$"
  collision_scratch="$FAKE_RUN/claude-code-team-$COLLISION_NAME-cwd"
  mkdir -p "$collision_scratch"
  printf 'foreign repo bash\n' > "$PROJ/.${collision_token}-repo-bash"
  printf 'foreign repo write\n' > "$PROJ/.${collision_token}-repo-write"
  printf 'foreign scratch\n' > "$collision_scratch/.${collision_token}-consultant-scratch"
  printf 'foreign run\n' > "$FAKE_RUN/.${collision_token}-run-write"
fi
COLLISION
  export SPAWN_SCRIPT_FOR_COLLISION="$SCRIPTS/spawn.sh"
  export COLLISION_NAME="$name"
  export BASH_ENV="$collision_env"

  run spawn_claude "$name"
  [ "$status" -ne 0 ]
  [[ "$output" == *"owner-scoped probe target collision"* ]]
  [ ! -e "$CAPTURE/probe-count" ]
  [ ! -e "$CAPTURE/bridge.args.$name" ]
  [ ! -e "$TEST_SKILL_DIR/run/claude-code-bridge.team.$name.settings.json" ]

  local repo_bash repo_write scratch_write run_write
  repo_bash="$(find "$PROJ" -maxdepth 1 -name '.agmsg-probe-*-repo-bash' -print -quit)"
  repo_write="$(find "$PROJ" -maxdepth 1 -name '.agmsg-probe-*-repo-write' -print -quit)"
  scratch_write="$(find "$scratch" -maxdepth 1 -name '.agmsg-probe-*-consultant-scratch' -print -quit)"
  run_write="$(find "$TEST_SKILL_DIR/run" -maxdepth 1 -name '.agmsg-probe-*-run-write' -print -quit)"
  [ "$(cat "$repo_bash")" = "foreign repo bash" ]
  [ "$(cat "$repo_write")" = "foreign repo write" ]
  [ "$(cat "$scratch_write")" = "foreign scratch" ]
  [ "$(cat "$run_write")" = "foreign run" ]
}

@test "dangling symlink probe collisions and exclusive owner creation never follow links" {
  local symlink_env="$TEST_SKILL_DIR/symlink-bash-env"
  local output_victim="$TEST_SKILL_DIR/output-victim"
  local sentinel_victim="$TEST_SKILL_DIR/sentinel-victim"
  local edit_victim="$TEST_SKILL_DIR/edit-victim"
  local prompt_victim="$TEST_SKILL_DIR/prompt-victim"
  local trace_victim="$TEST_SKILL_DIR/trace-victim"
  local stderr_victim="$TEST_SKILL_DIR/stderr-victim"
  cat > "$symlink_env" <<'SYMLINKS'
if [ "${0:-}" = "${SPAWN_SCRIPT_FOR_SYMLINK:-}" ]; then
  symlink_token="agmsg-probe-$$"
  case "${2:-}" in
    link-output)
      symlink_path="$PROJ/.${symlink_token}-repo-bash"
      ln -s "$OUTPUT_LINK_VICTIM" "$symlink_path"
      ;;
    link-sentinel)
      mkdir -p "$TEST_SKILL_DIR/db/claude-worker-home/projects"
      symlink_path="$TEST_SKILL_DIR/db/claude-worker-home/projects/.${symlink_token}-sensitive"
      ln -s "$SENTINEL_LINK_VICTIM" "$symlink_path"
      ;;
    link-edit)
      symlink_path="$PROJ/.${symlink_token}-repo-edit"
      ln -s "$EDIT_LINK_VICTIM" "$symlink_path"
      ;;
    link-prompt)
      symlink_path="$FAKE_RUN/claude-code-bridge.team.link-prompt.probe.prompt"
      ln -s "$PROMPT_LINK_VICTIM" "$symlink_path"
      ;;
    link-trace)
      symlink_path="$FAKE_RUN/claude-code-bridge.team.link-trace.probe.jsonl"
      ln -s "$TRACE_LINK_VICTIM" "$symlink_path"
      ;;
    link-stderr)
      symlink_path="$FAKE_RUN/claude-code-bridge.team.link-stderr.probe.stderr"
      ln -s "$STDERR_LINK_VICTIM" "$symlink_path"
      ;;
    regular-prompt)
      symlink_path="$FAKE_RUN/claude-code-bridge.team.regular-prompt.probe.prompt"
      printf 'preserved prompt\n' > "$symlink_path"
      ;;
    *) return 0 ;;
  esac
  printf '%s\n' "$symlink_path" > "$CAPTURE/symlink-path.${2:-unknown}"
fi
SYMLINKS
  export SPAWN_SCRIPT_FOR_SYMLINK="$SCRIPTS/spawn.sh"
  export OUTPUT_LINK_VICTIM="$output_victim"
  export SENTINEL_LINK_VICTIM="$sentinel_victim"
  export EDIT_LINK_VICTIM="$edit_victim"
  export PROMPT_LINK_VICTIM="$prompt_victim"
  export TRACE_LINK_VICTIM="$trace_victim"
  export STDERR_LINK_VICTIM="$stderr_victim"
  export BASH_ENV="$symlink_env"

  run spawn_claude link-output
  [ "$status" -ne 0 ]
  [[ "$output" == *"owner-scoped probe target collision"* ]]
  local output_link
  output_link="$(cat "$CAPTURE/symlink-path.link-output")"
  [ -L "$output_link" ]
  [ "$(readlink "$output_link")" = "$output_victim" ]
  [ ! -e "$output_victim" ]
  [ ! -e "$CAPTURE/probe-count" ]

  run spawn_claude link-sentinel --reviewer
  [ "$status" -ne 0 ]
  [[ "$output" == *"synthetic reviewer sentinel collision"* ]]
  local sentinel_link
  sentinel_link="$(cat "$CAPTURE/symlink-path.link-sentinel")"
  [ -L "$sentinel_link" ]
  [ "$(readlink "$sentinel_link")" = "$sentinel_victim" ]
  [ ! -e "$sentinel_victim" ]
  [ ! -e "$CAPTURE/probe-count" ]

  run spawn_claude link-edit --reviewer
  [ "$status" -ne 0 ]
  [[ "$output" == *"owner-scoped Edit probe target collision"* ]]
  local edit_link
  edit_link="$(cat "$CAPTURE/symlink-path.link-edit")"
  [ -L "$edit_link" ]
  [ "$(readlink "$edit_link")" = "$edit_victim" ]
  [ ! -e "$edit_victim" ]
  [ ! -e "$CAPTURE/probe-count" ]

  local diagnostic_name diagnostic_link diagnostic_victim
  for diagnostic_name in link-prompt link-trace link-stderr; do
    case "$diagnostic_name" in
      link-prompt) diagnostic_victim="$prompt_victim" ;;
      link-trace) diagnostic_victim="$trace_victim" ;;
      link-stderr) diagnostic_victim="$stderr_victim" ;;
    esac
    run spawn_claude "$diagnostic_name"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Claude probe diagnostic collision"* ]]
    diagnostic_link="$(cat "$CAPTURE/symlink-path.$diagnostic_name")"
    [ -L "$diagnostic_link" ]
    [ "$(readlink "$diagnostic_link")" = "$diagnostic_victim" ]
    [ ! -e "$diagnostic_victim" ]
    [ ! -e "$CAPTURE/probe-count" ]
    [ ! -e "$CAPTURE/bridge.args.$diagnostic_name" ]
  done

  run spawn_claude regular-prompt
  [ "$status" -ne 0 ]
  [[ "$output" == *"Claude probe diagnostic collision"* ]]
  local regular_prompt
  regular_prompt="$(cat "$CAPTURE/symlink-path.regular-prompt")"
  [ ! -L "$regular_prompt" ]
  [ "$(cat "$regular_prompt")" = "preserved prompt" ]
  [ ! -e "$CAPTURE/probe-count" ]
  [ ! -e "$CAPTURE/bridge.args.regular-prompt" ]

  local helper_link="$TEST_SKILL_DIR/helper-link"
  local helper_victim="$TEST_SKILL_DIR/helper-victim"
  ln -s "$helper_victim" "$helper_link"
  run env SCRIPTS_UNDER_TEST="$SCRIPTS" bash -c '
    SCRIPT_DIR="$SCRIPTS_UNDER_TEST"
    . "$SCRIPT_DIR/drivers/types/claude-code/_spawn.sh"
    agmsg_claude_create_exclusive_file "$1" owned
  ' _ "$helper_link"
  [ "$status" -ne 0 ]
  [ -L "$helper_link" ]
  [ "$(readlink "$helper_link")" = "$helper_victim" ]
  [ ! -e "$helper_victim" ]
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

@test "duplicate guard treats a bracketed model as argv data and keeps pgrep pattern constant" {
  run spawn_claude model-pattern --model 'opus[1m]'
  [ "$status" -eq 0 ]
  wait_bridge_capture model-pattern

  local first_pid launches
  first_pid="$(cat "$TEST_SKILL_DIR/run/claude-code-bridge.team.model-pattern.pid")"
  launches="$(wc -l < "$CAPTURE/bridge-launches" | tr -d ' ')"

  run spawn_claude model-pattern --model 'opus[1m]'
  [ "$status" -eq 0 ]
  [[ "$output" == *"already running"* ]]
  [ "$(cat "$TEST_SKILL_DIR/run/claude-code-bridge.team.model-pattern.pid")" = "$first_pid" ]
  [ "$(wc -l < "$CAPTURE/bridge-launches" | tr -d ' ')" = "$launches" ]
  grep -Fq "returned=$FAKE_BRIDGE --model opus[1m] --identity-key " "$PS_STUB_LOG"
  grep -Fxq 'argv=-f claude-code-bridge' "$PGREP_STUB_LOG"
  ! grep -Fq 'opus[1m]' "$PGREP_STUB_LOG"
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
