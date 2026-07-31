#!/usr/bin/env bash
# Claude Code headless spawn plug (Template Method).
#
# Sourced by spawn.sh after its generic option parsing. This file owns only the
# claude-code-specific mode resolution, policy generation/probes, and bridge
# lifecycle; spawn.sh remains type-data-driven.

CLAUDE_CODE_BIN="${AGMSG_CLAUDE_CMD:-claude}"
# 2.1.220 is the exact host version live-verified by Lead on 2026-07-30 for a
# dedicated CLAUDE_CONFIG_DIR worker-home subscription authenticated via `-p`
# (AUTH-OK), acceptance of `--model opus[1m]` plus `--effort high`, and project
# hook firing under `-p` even when `--settings hooks:{}` tried to suppress hooks.
# That hook result establishes the cwd=scratch contract. Older CLIs are untested
# against these contracts, so spawn refuses them fail-closed.
CLAUDE_CODE_MIN_VERSION=2.1.220
CLAUDE_CODE_INHERIT_ADD_DIRS_KEY="spawn.claude_inherit_add_dirs"

# shellcheck source=../../lib/reviewer-add-dirs.sh
. "$SCRIPT_DIR/lib/reviewer-add-dirs.sh"
# shellcheck source=../../lib/validate.sh
. "$SCRIPT_DIR/lib/validate.sh"
# shellcheck source=../../lib/identity-key.sh
. "$SCRIPT_DIR/lib/identity-key.sh"

agmsg_claude_safe_token() {
  local val="$1" rest
  [ -n "$val" ] || return 1
  rest="$(printf '%s' "$val" | LC_ALL=C tr -d 'A-Za-z0-9._-'; printf 'X%s' "$?")"
  [ "$rest" = "X0" ]
}

agmsg_claude_sanitize_for_log() {
  local val
  val="$(printf '%s' "$1" | LC_ALL=C tr -d '[:cntrl:]')"
  printf '%s' "${val:0:80}"
}

agmsg_claude_config_true() {
  case "$1" in true|1|yes|on) return 0 ;; *) return 1 ;; esac
}

# Spawn unwind is internal to this team; never remove an equivalent role elsewhere.
# Residual risk: reset remains best-effort so an unavailable registry does not
# change the existing spawn failure/cleanup contract.
agmsg_claude_reset_registration() {
  local team="$1" project="$2" name="$3"
  "$SCRIPT_DIR/reset.sh" --team "$team" "$project" claude-code "$name" >/dev/null 2>&1
}

# Explicit flags win. Per-worker implementer and inherit-add-dir keys are read
# only for safe name segments; unsafe names retain explicit flags/global defaults
# without ever entering config.sh's unescaped dotted-key matcher.
agmsg_spawn_resolve_modes() {
  local name_safe=1 inherit_value="__agmsg_unset__"
  agmsg_claude_safe_token "$NAME" || name_safe=0

  if [ "$HEADLESS_SET" = 0 ] \
    && agmsg_claude_config_true "$("$SCRIPT_DIR/config.sh" get spawn.claude_headless false 2>/dev/null || true)"; then
    HEADLESS=1
  fi
  if [ "$REVIEWER_SET" = 0 ] \
    && agmsg_claude_config_true "$("$SCRIPT_DIR/config.sh" get spawn.claude_reviewer false 2>/dev/null || true)"; then
    REVIEWER=1
  fi
  if [ "$IMPLEMENTER_SET" = 0 ]; then
    if [ "$name_safe" = 1 ]; then
      if agmsg_claude_config_true "$("$SCRIPT_DIR/config.sh" get "spawn.claude_implementer.$NAME" false 2>/dev/null || true)"; then
        IMPLEMENTER=1
      fi
    else
      echo "spawn: worker name '$(agmsg_claude_sanitize_for_log "$NAME")' is not a safe config-key segment (must match ^[A-Za-z0-9._-]+\$); skipping spawn.claude_implementer.<name> lookup (use --implementer)" >&2
    fi
  fi

  # Approved expansion: a per-name inherit gate overrides the global gate. The
  # selected KEY (not a hand-parsed value) is passed to the established shared
  # collector later, so JSON extraction remains centralized.
  CLAUDE_CODE_INHERIT_ADD_DIRS_KEY="spawn.claude_inherit_add_dirs"
  if [ "$name_safe" = 1 ]; then
    inherit_value="$("$SCRIPT_DIR/config.sh" get "spawn.claude_inherit_add_dirs.$NAME" "__agmsg_unset__" 2>/dev/null || true)"
    if [ "$inherit_value" != "__agmsg_unset__" ]; then
      CLAUDE_CODE_INHERIT_ADD_DIRS_KEY="spawn.claude_inherit_add_dirs.$NAME"
    fi
  else
    echo "spawn: worker name '$(agmsg_claude_sanitize_for_log "$NAME")' is not a safe config-key segment; skipping spawn.claude_inherit_add_dirs.<name> lookup and retaining the global gate" >&2
  fi

  # Same overlap normalization as codex: two explicit positive flags conflict;
  # an explicit reviewer beats a configured implementer; otherwise implementer
  # wins over a configured reviewer.
  if [ "$IMPLEMENTER" = 1 ] && [ "$REVIEWER" = 1 ]; then
    if [ "$IMPLEMENTER_SET" = 1 ] && [ "$REVIEWER_SET" = 1 ]; then
      die "--implementer and --reviewer are mutually exclusive"
    elif [ "$REVIEWER_SET" = 1 ]; then
      IMPLEMENTER=0
    else
      REVIEWER=0
    fi
  fi
}

agmsg_claude_resolve_turn_options() {
  local name="$1" name_safe=1 model="" effort="" timeout=""
  agmsg_claude_safe_token "$name" || name_safe=0

  if [ "$name_safe" != 1 ]; then
    echo "spawn: worker name '$(agmsg_claude_sanitize_for_log "$name")' is not a safe config-key segment; skipping spawn.claude_model/effort/turn_timeout.<name> lookups" >&2
  fi
  if [ -n "${MODEL_ID:-}" ]; then
    model="$MODEL_ID"
  elif [ "$name_safe" = 1 ]; then
    model="$("$SCRIPT_DIR/config.sh" get "spawn.claude_model.$name" "" 2>/dev/null || true)"
  fi
  if [ "$name_safe" = 1 ]; then
    effort="$("$SCRIPT_DIR/config.sh" get "spawn.claude_effort.$name" "" 2>/dev/null || true)"
    timeout="$("$SCRIPT_DIR/config.sh" get "spawn.claude_turn_timeout.$name" "" 2>/dev/null || true)"
  fi

  if [ -n "$model" ] && ! agmsg_claude_safe_token "$model"; then
    echo "spawn: ignoring unsafe Claude model id '$(agmsg_claude_sanitize_for_log "$model")' (must match ^[A-Za-z0-9._-]+\$)" >&2
    model=""
  fi
  if [ -n "$effort" ] && ! agmsg_claude_safe_token "$effort"; then
    echo "spawn: ignoring unsafe Claude effort value '$(agmsg_claude_sanitize_for_log "$effort")' (must match ^[A-Za-z0-9._-]+\$)" >&2
    effort=""
  fi
  if [ -n "$timeout" ]; then
    case "$timeout" in
      *[!0-9]*|0*|[0-9][0-9][0-9][0-9][0-9][0-9][0-9]*)
        echo "spawn: ignoring invalid Claude turn timeout '$(agmsg_claude_sanitize_for_log "$timeout")' (must be a positive integer of at most 6 digits, in seconds)" >&2
        timeout="" ;;
    esac
  fi

  CLAUDE_CODE_MODEL="$model"
  CLAUDE_CODE_EFFORT="$effort"
  CLAUDE_CODE_TURN_TIMEOUT="$timeout"
}

agmsg_claude_check_version() {
  local out major minor patch
  if ! out="$("$CLAUDE_CODE_BIN" --version 2>&1)"; then
    die "Claude Code version probe failed; refusing headless spawn (expected '$CLAUDE_CODE_MIN_VERSION (Claude Code)' or newer)"
  fi
  if [[ "$out" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)\ \(Claude\ Code\)$ ]]; then
    major="${BASH_REMATCH[1]}"
    minor="${BASH_REMATCH[2]}"
    patch="${BASH_REMATCH[3]}"
  else
    die "unparseable Claude Code version '$out' (expected '<semver> (Claude Code)'); refusing headless spawn"
  fi
  if (( 10#$major < 2 \
        || (10#$major == 2 && 10#$minor < 1) \
        || (10#$major == 2 && 10#$minor == 1 && 10#$patch < 220) )); then
    die "Claude Code $major.$minor.$patch is below the live-verified minimum $CLAUDE_CODE_MIN_VERSION; refusing headless spawn"
  fi
}

agmsg_claude_json_quote() {
  local value sql_value
  value="$1"
  sql_value="$(printf '%s' "$value" | sed "s/'/''/g")"
  agmsg_sqlite_mem "SELECT json_quote('$sql_value');"
}

agmsg_claude_emit_json_array() {
  local first=1 value
  printf '['
  for value in "$@"; do
    [ "$first" = 1 ] || printf ','
    agmsg_claude_json_quote "$value"
    first=0
  done
  printf ']'
}

agmsg_claude_tool_rule() {
  local tool="$1" path="$2"
  printf '%s(%s/**)' "$tool" "${path%/}"
}

agmsg_claude_create_exclusive_file() {
  local path="$1" content="$2"
  (
    umask 077
    set -o noclobber
    printf '%s\n' "$content" > "$path"
  ) 2>/dev/null
}

agmsg_claude_generate_settings() {
  local settings_file="$1" layout="$2" project="$3" scratch="$4"
  local storage_dir="$5" worker_home="$6" sentinel="$7" child_tmp="$8"
  shift 8
  local -a inherited=("$@")
  local -a allow_rules=("Bash(*)")
  local -a deny_rules=()
  local -a allow_write=("$storage_dir" "$SKILL_DIR/teams" "$SKILL_DIR/run" "$child_tmp" "/tmp" "$scratch")
  local -a deny_write=()
  local -a allow_read=("$scratch" "$SKILL_DIR" "/bin" "/usr/bin" "/usr/lib" "/System" "/Library" "/nix" "/opt/homebrew" "/usr/local")
  local -a deny_read=()
  local path tmp="${settings_file}.tmp.$$" tmp_sql valid

  case "$layout" in
    implementer)
      allow_write+=("$project")
      allow_read+=("$project")
      allow_rules+=("$(agmsg_claude_tool_rule Read "$project")")
      allow_rules+=("$(agmsg_claude_tool_rule Edit "$project")")
      allow_rules+=("$(agmsg_claude_tool_rule Write "$project")")
      ;;
    reviewer)
      allow_read+=("$project")
      deny_write+=("$project")
      deny_read+=("/")
      allow_rules+=("$(agmsg_claude_tool_rule Read "$project")")
      deny_rules+=("$(agmsg_claude_tool_rule Edit "$project")")
      deny_rules+=("$(agmsg_claude_tool_rule Write "$project")")
      deny_rules+=("Read($HOME/.ssh/**)")
      deny_rules+=("Read(**/*credentials*)")
      deny_rules+=("Read(**/*credentials*/**)")
      deny_rules+=("Read(${worker_home%/}/projects/**)")
      deny_rules+=("Read($sentinel)")
      for path in "${inherited[@]}"; do
        [ -n "$path" ] || continue
        allow_read+=("$path")
        allow_rules+=("$(agmsg_claude_tool_rule Read "$path")")
      done
      ;;
    consultant)
      allow_rules+=("$(agmsg_claude_tool_rule Read "$scratch")")
      deny_rules+=("$(agmsg_claude_tool_rule Edit "$project")")
      deny_rules+=("$(agmsg_claude_tool_rule Write "$project")")
      deny_write+=("$project")
      ;;
    *) return 1 ;;
  esac

  {
    printf '{\n  "permissions": {\n    "allow": '
    agmsg_claude_emit_json_array "${allow_rules[@]}"
    printf ',\n    "deny": '
    agmsg_claude_emit_json_array "${deny_rules[@]}"
    printf '\n  },\n  "sandbox": {\n'
    printf '    "enabled": true,\n'
    printf '    "autoAllowBashIfSandboxed": true,\n'
    printf '    "failIfUnavailable": true,\n'
    printf '    "allowUnsandboxedCommands": false,\n'
    printf '    "filesystem": {\n      "allowWrite": '
    agmsg_claude_emit_json_array "${allow_write[@]}"
    printf ',\n      "denyWrite": '
    agmsg_claude_emit_json_array "${deny_write[@]}"
    printf ',\n      "allowRead": '
    agmsg_claude_emit_json_array "${allow_read[@]}"
    printf ',\n      "denyRead": '
    agmsg_claude_emit_json_array "${deny_read[@]}"
    printf '\n    }\n  }\n}\n'
  } > "$tmp" || { rm -f "$tmp" 2>/dev/null || true; return 1; }

  tmp_sql="$(agmsg_sql_readfile_path "$tmp")"
  valid="$(agmsg_sqlite_mem "SELECT json_valid(readfile('$tmp_sql'));" 2>/dev/null || true)"
  [ "$valid" = 1 ] || { rm -f "$tmp" 2>/dev/null || true; return 1; }
  mv "$tmp" "$settings_file"
}

agmsg_claude_probe_bash_command() {
  local action="$1" token="$2" target="$3"
  case "$action" in
    consultant-scratch)
      printf 'printf %%s %q > %q # marker %s-consultant-scratch' \
        "$token-consultant-scratch" "$target" "$token" ;;
    repo-bash-ok)
      printf 'printf %%s %q > %q # marker %s-repo-bash' \
        "$token-repo-bash" "$target" "$token" ;;
    repo-bash-blocked)
      printf 'printf %%s %q > %q # marker %s-repo-bash' \
        "$token-repo-bash" "$target" "$token" ;;
    run-write)
      printf 'printf %%s %q > %q # marker %s-run-write' \
        "$token-run-write" "$target" "$token" ;;
    *) return 1 ;;
  esac
}

agmsg_claude_probe_event_count() {
  local trace="$1" tool="$2" marker="$3" outcome="$4" expected_input="${5:-}"
  local trace_sql tool_sql marker_sql expected_sql condition marker_condition
  trace_sql="$(agmsg_sql_readfile_path "$trace")"
  tool_sql="$(printf '%s' "$tool" | sed "s/'/''/g")"
  marker_sql="$(printf '%s' "$marker" | sed "s/'/''/g")"
  expected_sql="$(printf '%s' "$expected_input" | sed "s/'/''/g")"
  marker_condition="1=1"
  [ "$tool" = Bash ] \
    && marker_condition="instr(COALESCE(u.actual_input,''), '$marker_sql') > 0"
  case "$outcome" in
    success)
      condition="COALESCE(r.is_error,0)=0" ;;
    denied)
      condition="(lower(COALESCE(r.body,'')) LIKE '%denied%' OR lower(COALESCE(r.body,'')) LIKE '%permission%' OR lower(COALESCE(r.body,'')) LIKE '%not allowed%')" ;;
    denied-error)
      condition="r.is_error=1 AND (lower(COALESCE(r.body,'')) LIKE '%permission denied%' OR lower(COALESCE(r.body,'')) LIKE '%denied by %' OR lower(COALESCE(r.body,'')) LIKE '%access denied%' OR lower(COALESCE(r.body,'')) LIKE '%not allowed%')" ;;
    *) return 1 ;;
  esac
  agmsg_sqlite_mem "
    WITH RECURSIVE
      split(line, rest) AS (
        SELECT '', CAST(readfile('$trace_sql') AS TEXT) || char(10)
        UNION ALL
        SELECT substr(rest, 1, instr(rest, char(10)) - 1),
               substr(rest, instr(rest, char(10)) + 1)
        FROM split WHERE rest <> ''
      ),
      docs(j) AS (
        SELECT line FROM split WHERE line <> '' AND json_valid(line)
      ),
      uses AS (
        SELECT json_extract(c.value, '\$.id') AS id,
               json_extract(c.value, '\$.name') AS tool,
               CASE json_extract(c.value, '\$.name')
                 WHEN 'Bash' THEN json_extract(c.value, '\$.input.command')
                 WHEN 'Read' THEN json_extract(c.value, '\$.input.file_path')
                 WHEN 'Edit' THEN json_extract(c.value, '\$.input.file_path')
                 WHEN 'Write' THEN json_extract(c.value, '\$.input.file_path')
                 ELSE NULL
               END AS actual_input
        FROM docs, json_each(json_extract(j, '\$.message.content')) AS c
        WHERE json_extract(c.value, '\$.type') = 'tool_use'
      ),
      results AS (
        SELECT json_extract(c.value, '\$.tool_use_id') AS tool_use_id,
               COALESCE(json_extract(c.value, '\$.is_error'), 0) AS is_error,
               CAST(json_extract(c.value, '\$.content') AS TEXT) AS body
        FROM docs, json_each(json_extract(j, '\$.message.content')) AS c
        WHERE json_extract(c.value, '\$.type') = 'tool_result'
      )
    SELECT COUNT(*)
    FROM uses u JOIN results r ON r.tool_use_id = u.id
    WHERE u.tool = '$tool_sql'
      AND u.actual_input = '$expected_sql'
      AND $marker_condition
      AND $condition;
  " 2>/dev/null | tr -d '\r'
}

agmsg_claude_probe_complete() {
  local trace="$1" layout="$2" token="$3" project="$4" scratch="$5"
  local sentinel="$6" run_write="$7"
  local spec tool marker outcome target_kind target expected_input count
  local repo_edit="$project/.${token}-repo-edit"
  local repo_write="$project/.${token}-repo-write"
  local repo_bash="$project/.${token}-repo-bash"
  local scratch_write="$scratch/.${token}-consultant-scratch"
  local specs=""
  [ -f "$trace" ] && [ ! -L "$trace" ] || return 1
  case "$layout" in
    consultant)
      specs=$'Bash\tconsultant-scratch\tsuccess\tscratch\nBash\trepo-bash\tdenied\trepo-bash\nBash\trun-write\tsuccess\trun-write' ;;
    implementer)
      specs=$'Bash\trepo-bash\tsuccess\trepo-bash\nEdit\trepo-edit\tsuccess\trepo-edit\nWrite\trepo-write\tsuccess\trepo-write\nBash\trun-write\tsuccess\trun-write' ;;
    reviewer)
      specs=$'Bash\trepo-bash\tdenied\trepo-bash\nRead\tedit-prereq-read\tsuccess\trepo-edit\nEdit\trepo-edit\tdenied-error\trepo-edit\nWrite\trepo-write\tdenied-error\trepo-write\nRead\tsensitive-read\tdenied-error\tsentinel\nBash\trun-write\tsuccess\trun-write' ;;
    *) return 1 ;;
  esac
  while IFS=$'\t' read -r tool marker outcome target_kind; do
    [ -n "$tool" ] || continue
    case "$target_kind" in
      repo-bash) target="$repo_bash" ;;
      repo-edit) target="$repo_edit" ;;
      repo-write) target="$repo_write" ;;
      scratch) target="$scratch_write" ;;
      sentinel) target="$sentinel" ;;
      run-write) target="$run_write" ;;
      *) return 1 ;;
    esac
    expected_input="$target"
    if [ "$tool" = Bash ]; then
      case "$marker" in
        consultant-scratch)
          expected_input="$(agmsg_claude_probe_bash_command \
            consultant-scratch "$token" "$target")" ;;
        repo-bash)
          if [ "$layout" = implementer ]; then
            expected_input="$(agmsg_claude_probe_bash_command \
              repo-bash-ok "$token" "$target")"
          else
            expected_input="$(agmsg_claude_probe_bash_command \
              repo-bash-blocked "$token" "$target")"
          fi ;;
        run-write)
          expected_input="$(agmsg_claude_probe_bash_command \
            run-write "$token" "$target")" ;;
        *) return 1 ;;
      esac
    fi
    count="$(agmsg_claude_probe_event_count \
      "$trace" "$tool" "$token-$marker" "$outcome" "$expected_input" || true)"
    case "$count" in ''|*[!0-9]*|0) return 1 ;; esac
  done <<< "$specs"
  [ -f "$run_write" ] && [ ! -L "$run_write" ] || return 1
  [ "$(cat "$run_write" 2>/dev/null || true)" = "$token-run-write" ] || return 1
  return 0
}

agmsg_claude_prepare_child_env() {
  local worker_home="$1" child_tmp="$2"
  export CLAUDE_CONFIG_DIR="$worker_home"
  export TMPDIR="$child_tmp"
  unset CLAUDE_CODE_SESSION_ID CLAUDECODE CLAUDE_CODE_CHILD_SESSION
  # Do not let caller-controlled non-interactive shell startup/wrapper state
  # pre-execute or redirect a probe/bridge Bash command.
  unset BASH_ENV ENV PROMPT_COMMAND CDPATH ZDOTDIR CLAUDE_ENV_FILE
  export -n SHELLOPTS BASHOPTS 2>/dev/null || true
}

agmsg_claude_run_probe_attempt() {
  local prompt_content="$1" scratch="$2"
  local worker_home="$3" child_tmp="$4" timeout="$5"
  shift 5
  local -a args=("$@")
  local pid rc=0 ticks=0 max_ticks=$((timeout * 10))
  (
    agmsg_claude_prepare_child_env "$worker_home" "$child_tmp"
    cd "$scratch" || exit 70
    exec "$CLAUDE_CODE_BIN" -p --verbose --output-format stream-json \
      --no-session-persistence "${args[@]}" <<< "$prompt_content"
  ) >&8 2>&9 &
  pid=$!
  while _agmsg_pid_alive "$pid" && [ "$ticks" -lt "$max_ticks" ]; do
    sleep 0.1
    ticks=$((ticks + 1))
  done
  if _agmsg_pid_alive "$pid"; then
    kill "$pid" 2>/dev/null || true
    sleep 1
    _agmsg_pid_alive "$pid" && kill -9 "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    return 124
  fi
  wait "$pid" 2>/dev/null || rc=$?
  return "$rc"
}

agmsg_claude_render_probe_prompt() {
  local layout="$1" token="$2" project="$3" scratch="$4"
  local run_write="$5" sentinel="$6"
  local repo_bash="$project/.${token}-repo-bash"
  local repo_edit="$project/.${token}-repo-edit"
  local repo_write="$project/.${token}-repo-write"
  local scratch_write="$scratch/.${token}-consultant-scratch"
  local scratch_command repo_bash_command run_write_command repo_bash_action
  scratch_command="$(agmsg_claude_probe_bash_command \
    consultant-scratch "$token" "$scratch_write")" || return 1
  repo_bash_action=repo-bash-blocked
  [ "$layout" = implementer ] && repo_bash_action=repo-bash-ok
  repo_bash_command="$(agmsg_claude_probe_bash_command \
    "$repo_bash_action" "$token" "$repo_bash")" || return 1
  run_write_command="$(agmsg_claude_probe_bash_command \
    run-write "$token" "$run_write")" || return 1
  printf 'AGMSG sandbox probe, layout=%s. Use every requested tool; do not substitute final text for a tool call.\n' "$layout"
  printf 'run-write-target=%s\n' "$run_write"
  printf 'repo-bash-target=%s\n' "$repo_bash"
  printf 'edit-target=%s\n' "$repo_edit"
  printf 'repo-write-target=%s\n' "$repo_write"
  printf 'scratch-write-target=%s\n' "$scratch_write"
  printf 'sensitive-read-target=%s\n' "$sentinel"
  printf 'scratch-write-command=%s\n' "$scratch_command"
  printf 'repo-bash-command=%s\n' "$repo_bash_command"
  printf 'run-write-command=%s\n' "$run_write_command"
  case "$layout" in
    consultant)
      printf '1. Bash (must succeed), use this exact command verbatim: %s\n' "$scratch_command"
      printf '2. Bash (must be denied), use this exact command verbatim: %s\n' "$repo_bash_command"
      printf '3. Bash (must succeed), use this exact command verbatim: %s\n' "$run_write_command"
      ;;
    implementer)
      printf '1. Bash (must succeed), use this exact command verbatim: %s\n' "$repo_bash_command"
      printf '2. Edit file %s, replace ORIGINAL with CHANGED. Marker %s-repo-edit; must succeed.\n' "$repo_edit" "$token"
      printf '3. Write exact text %s to %s. Marker %s-repo-write; must succeed.\n' \
        "$token-repo-write" "$repo_write" "$token"
      printf '4. Bash (must succeed), use this exact command verbatim: %s\n' "$run_write_command"
      ;;
    reviewer)
      printf '1. Bash (must be denied), use this exact command verbatim: %s\n' "$repo_bash_command"
      printf '2. Read %s. Marker %s-edit-prereq-read; must succeed before Edit.\n' "$repo_edit" "$token"
      printf '3. Edit file %s, replace ORIGINAL with CHANGED. Marker %s-repo-edit; must be denied by permission or sandbox policy.\n' "$repo_edit" "$token"
      printf '4. Write exact text %s to %s. Marker %s-repo-write; must be denied.\n' \
        "$token-repo-write" "$repo_write" "$token"
      printf '5. Read %s. Marker %s-sensitive-read; must be denied by permission or sandbox policy.\n' "$sentinel" "$token"
      printf '6. Bash (must succeed), use this exact command verbatim: %s\n' "$run_write_command"
      ;;
  esac
}

agmsg_claude_bridge_running() {
  local run_dir="$1" idkey="$2" pidfile="$3"
  local pid="" args="" candidate
  [ -f "$pidfile" ] && pid="$(cat "$pidfile" 2>/dev/null || true)"
  if [ -n "$pid" ] && _agmsg_pid_alive "$pid"; then
    args="$(ps -ww -o args= -p "$pid" 2>/dev/null || true)"
    if printf '%s' "$args" | grep -qF -- "claude-code-bridge" \
      && printf '%s' "$args" | grep -qF -- "--identity-key $idkey"; then
      printf '%s' "$pid"
      return 0
    fi
  fi
  for candidate in $(pgrep -f "claude-code-bridge" 2>/dev/null || true); do
    args="$(ps -ww -o args= -p "$candidate" 2>/dev/null || true)"
    if printf '%s' "$args" | grep -qF -- "--identity-key $idkey"; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

# Artifact inventory:
# - spawn first owns placement.<team>__<name>.lock, then creates
#   <base>.settings.json, scratch cwd and its owned tmp/, log, optional role
#   snapshot, and finally bridge-owned pid/meta/session/transients/spool; spawn
#   normalizes pid/meta before recording placement and releases the lock.
# - spawn owns transient probe prompt/trace/stderr plus token-named run/repo
#   targets and a synthetic reviewer sentinel under worker-home/projects.
#   Probe success always removes them. Probe failure also removes them by default;
#   AGMSG_CLAUDE_KEEP_PROBE=1 preserves only the owned prompt/trace/stderr/settings
#   diagnostics and reports their paths, while synthetic targets are still
#   owner-checked and removed.
# - a spawn failure removes only this attempt's settings/probe/role/pid/meta/log
#   and empty scratch, then resets only its registration; prior session/spool blobs
#   are never deleted.
# - bridge SIGTERM owns pid/meta/role and transient cleanup, preserving session and
#   outbound spool for recovery. despawn/SessionEnd/orphan GC terminate through the
#   bridge and retire role/spool plus placement. Settings, logs, session, and a
#   non-empty scratch intentionally survive those recovery paths; session-team TTL
#   GC owns final prefix-wide settings/log/session/transient/spool and cwd removal.
agmsg_spawn_headless() {
  local run_dir="$SKILL_DIR/run" storage_dir worker_home
  storage_dir="$(agmsg_storage_dir)"
  worker_home="$SKILL_DIR/db/claude-worker-home"

  agmsg_validate_team_name "$TEAM" >/dev/null 2>&1 \
    || die "team name '$TEAM' is not a path-safe segment"
  agmsg_validate_agent_name "$NAME" >/dev/null 2>&1 \
    || die "agent name '$NAME' is not valid for a headless bridge"

  # Version gating is deliberately before every per-worker artifact and launch.
  agmsg_claude_check_version
  agmsg_claude_resolve_turn_options "$NAME"

  local idkey base pidfile metafile logfile rolefile settings_file scratch
  idkey="$(agmsg_identity_key "$TEAM" "$NAME")"
  base="$run_dir/claude-code-bridge.$TEAM.$NAME"
  pidfile="$base.pid"
  metafile="$base.meta"
  logfile="$base.log"
  rolefile="$base.role"
  settings_file="$base.settings.json"
  scratch="$run_dir/claude-code-$TEAM-$NAME-cwd"

  # Claude's generated policy/probe files are per (team,name), so their whole
  # lifecycle must be serialized — not just the final placement-record write.
  # Unlike the older shared callers' fail-open bookkeeping lock, a Claude spawn
  # cannot safely continue after timeout: it would race settings promotion and
  # cleanup against the winner. Mark held only after an observed acquisition.
  local _lk_held=0
  _agmsg_claude_spawn_lk_release() {
    [ "$_lk_held" = 1 ] || return 0
    agmsg_placement_lock_release "$TEAM" "$NAME" 2>/dev/null || true
    _lk_held=0
  }
  trap _agmsg_claude_spawn_lk_release RETURN
  if ! agmsg_placement_lock_acquire "$TEAM" "$NAME" 10; then
    die "could not acquire placement lock for Claude '$NAME' in team '$TEAM'; refusing concurrent headless spawn"
  fi
  _lk_held=1

  # Re-evaluate under exclusive ownership. A concurrent winner may have become
  # live while this process waited for the lock.
  local running=""
  running="$(agmsg_claude_bridge_running "$run_dir" "$idkey" "$pidfile" 2>/dev/null || true)"
  if [ -n "$running" ]; then
    _agmsg_claude_spawn_lk_release
    echo "spawn: headless claude-code '$NAME' already running in '$TEAM' (pid $running)"
    return 0
  fi

  local scratch_created=0 child_tmp_created=0 worker_projects_created=0
  local log_created=0 joined=0 role_staged=0 bpid=""
  local settings_created=0 probe_prompt_created=0 probe_trace_created=0
  local probe_stderr_created=0 diagnostics_preserved=0
  local probe_trace_fd_open=0 probe_stderr_fd_open=0
  local sentinel_created=0 repo_edit_created=0
  local repo_bash_created=0 repo_write_created=0 scratch_write_created=0
  local run_write_created=0
  local probe_token="agmsg-probe-$$"
  local probe_prompt="$base.probe.prompt"
  local probe_trace="$base.probe.jsonl"
  local probe_stderr="$base.probe.stderr"
  local probe_prompt_content=""
  local child_tmp="$scratch/tmp"
  local worker_projects="$worker_home/projects"
  local sentinel="$worker_projects/.${probe_token}-sensitive"
  local sentinel_content="synthetic reviewer policy sentinel $probe_token"
  local repo_bash="$PROJECT/.${probe_token}-repo-bash"
  local repo_edit="$PROJECT/.${probe_token}-repo-edit"
  local repo_write="$PROJECT/.${probe_token}-repo-write"
  local scratch_write="$scratch/.${probe_token}-consultant-scratch"
  local run_write="$run_dir/.${probe_token}-run-write"
  local -a inherited_dirs=()
  local inherited path layout=consultant
  local -a add_dirs=()
  local -a runtime_policy_args=()
  local -a probe_policy_args=()
  local probe_timeout="${AGMSG_CLAUDE_PROBE_TIMEOUT:-30}" attempts=0 probe_rc=0
  case "$probe_timeout" in ''|*[!0-9]*|0) probe_timeout=30 ;; esac

  _agmsg_claude_cleanup_probe_targets() {
    if [ "$sentinel_created" = 1 ]; then
      if [ ! -L "$sentinel" ] \
        && [ "$(cat "$sentinel" 2>/dev/null || true)" = "$sentinel_content" ]; then
        rm -f "$sentinel" 2>/dev/null || true
      fi
      sentinel_created=0
    fi
    if [ "$repo_edit_created" = 1 ]; then
      if [ ! -L "$repo_edit" ] \
        && grep -Fq -- "$probe_token" "$repo_edit" 2>/dev/null; then
        rm -f "$repo_edit" 2>/dev/null || true
      fi
      repo_edit_created=0
    fi
    if [ "$repo_bash_created" = 1 ] \
      && [ ! -L "$repo_bash" ] \
      && [ "$(cat "$repo_bash" 2>/dev/null || true)" = "$probe_token-repo-bash" ]; then
      rm -f "$repo_bash" 2>/dev/null || true
    fi
    if [ "$repo_write_created" = 1 ] \
      && [ ! -L "$repo_write" ] \
      && [ "$(cat "$repo_write" 2>/dev/null || true)" = "$probe_token-repo-write" ]; then
      rm -f "$repo_write" 2>/dev/null || true
    fi
    if [ "$scratch_write_created" = 1 ] \
      && [ ! -L "$scratch_write" ] \
      && [ "$(cat "$scratch_write" 2>/dev/null || true)" = "$probe_token-consultant-scratch" ]; then
      rm -f "$scratch_write" 2>/dev/null || true
    fi
    if [ "$run_write_created" = 1 ] \
      && [ ! -L "$run_write" ] \
      && [ "$(cat "$run_write" 2>/dev/null || true)" = "$probe_token-run-write" ]; then
      rm -f "$run_write" 2>/dev/null || true
    fi
    repo_bash_created=0
    repo_write_created=0
    scratch_write_created=0
    run_write_created=0
  }
  _agmsg_claude_spawn_cleanup() {
    local owner
    if [ -n "$bpid" ] && _agmsg_pid_alive "$bpid"; then
      kill "$bpid" 2>/dev/null || true
      sleep 1
      _agmsg_pid_alive "$bpid" && kill -9 "$bpid" 2>/dev/null || true
      wait "$bpid" 2>/dev/null || true
    fi
    owner="$(cat "$pidfile" 2>/dev/null || true)"
    [ -n "$bpid" ] && [ "$owner" = "$bpid" ] && rm -f "$pidfile" 2>/dev/null || true
    owner="$(sed -n 's/^pid=//p' "$metafile" 2>/dev/null | head -1 || true)"
    [ -n "$bpid" ] && [ "$owner" = "$bpid" ] && rm -f "$metafile" 2>/dev/null || true
    [ "$joined" = 1 ] && agmsg_claude_reset_registration "$TEAM" "$scratch" "$NAME" || true
    if [ "$probe_trace_fd_open" = 1 ]; then
      exec 8>&- || true
      probe_trace_fd_open=0
    fi
    if [ "$probe_stderr_fd_open" = 1 ]; then
      exec 9>&- || true
      probe_stderr_fd_open=0
    fi
    if [ "$diagnostics_preserved" != 1 ]; then
      [ "$settings_created" = 1 ] && rm -f "$settings_file" 2>/dev/null || true
      [ "$probe_prompt_created" = 1 ] && [ ! -L "$probe_prompt" ] \
        && rm -f "$probe_prompt" 2>/dev/null || true
      [ "$probe_trace_created" = 1 ] && [ ! -L "$probe_trace" ] \
        && rm -f "$probe_trace" 2>/dev/null || true
      [ "$probe_stderr_created" = 1 ] && [ ! -L "$probe_stderr" ] \
        && rm -f "$probe_stderr" 2>/dev/null || true
    fi
    _agmsg_claude_cleanup_probe_targets
    [ "$role_staged" = 1 ] && rm -f "$rolefile" 2>/dev/null || true
    [ "$log_created" = 1 ] && rm -f "$logfile" 2>/dev/null || true
    [ "$child_tmp_created" = 1 ] && rmdir "$child_tmp" 2>/dev/null || true
    [ "$scratch_created" = 1 ] && rmdir "$scratch" 2>/dev/null || true
    [ "$worker_projects_created" = 1 ] && rmdir "$worker_projects" 2>/dev/null || true
    _agmsg_claude_spawn_lk_release
  }
  _agmsg_claude_spawn_fail() {
    local message="$*"
    _agmsg_claude_spawn_cleanup
    die "$message"
  }

  mkdir -p "$run_dir" \
    || _agmsg_claude_spawn_fail "cannot create run directory $run_dir"
  if [ ! -d "$scratch" ]; then
    mkdir -p "$scratch" \
      || _agmsg_claude_spawn_fail "cannot create Claude scratch cwd $scratch"
    scratch_created=1
  fi
  if [ ! -d "$child_tmp" ]; then
    mkdir -p "$child_tmp" \
      || _agmsg_claude_spawn_fail "cannot create owned Claude child temp directory $child_tmp"
    child_tmp_created=1
  fi
  [ -e "$logfile" ] || log_created=1
  : >> "$logfile" \
    || _agmsg_claude_spawn_fail "cannot create Claude bridge log $logfile"

  if [ "$IMPLEMENTER" = 1 ]; then
    layout=implementer
    add_dirs+=("$PROJECT")
  elif [ "$REVIEWER" = 1 ]; then
    layout=reviewer
    add_dirs+=("$PROJECT")
    inherited="$(agmsg_collect_add_dir_roots "$PROJECT" "$CLAUDE_CODE_INHERIT_ADD_DIRS_KEY")"
    while IFS= read -r path; do
      [ -n "$path" ] || continue
      inherited_dirs+=("$path")
      add_dirs+=("$path")
    done <<< "$inherited"
  fi

  for path in "$repo_bash" "$repo_write" "$scratch_write" "$run_write"; do
    if [ -e "$path" ] || [ -L "$path" ]; then
      _agmsg_claude_spawn_fail "owner-scoped probe target collision at $path; refusing to overwrite"
    fi
  done
  if [ "$layout" = reviewer ]; then
    [ ! -L "$worker_projects" ] \
      || _agmsg_claude_spawn_fail "synthetic reviewer sentinel parent is a symlink; refusing to follow"
    if [ ! -d "$worker_projects" ]; then
      mkdir -p "$worker_projects" \
        || _agmsg_claude_spawn_fail "cannot create synthetic reviewer sentinel parent"
      worker_projects_created=1
    fi
    if [ -e "$sentinel" ] || [ -L "$sentinel" ]; then
      _agmsg_claude_spawn_fail "synthetic reviewer sentinel collision; refusing to overwrite"
    fi
    agmsg_claude_create_exclusive_file "$sentinel" "$sentinel_content" \
      || _agmsg_claude_spawn_fail "cannot exclusively create the synthetic reviewer probe sentinel"
    sentinel_created=1
  fi
  if [ "$layout" = reviewer ] || [ "$layout" = implementer ]; then
    if [ -e "$repo_edit" ] || [ -L "$repo_edit" ]; then
      _agmsg_claude_spawn_fail "owner-scoped Edit probe target collision; refusing to overwrite"
    fi
    agmsg_claude_create_exclusive_file "$repo_edit" "ORIGINAL $probe_token" \
      || _agmsg_claude_spawn_fail "cannot exclusively create the owner-scoped Edit probe file in $PROJECT"
    repo_edit_created=1
  fi
  agmsg_claude_generate_settings "$settings_file" "$layout" "$PROJECT" "$scratch" \
    "$storage_dir" "$worker_home" "$sentinel" "$child_tmp" \
    ${inherited_dirs[@]+"${inherited_dirs[@]}"} \
    || _agmsg_claude_spawn_fail "could not generate valid Claude settings JSON"
  settings_created=1

  [ -n "$CLAUDE_CODE_MODEL" ] && runtime_policy_args+=(--model "$CLAUDE_CODE_MODEL")
  [ -n "$CLAUDE_CODE_EFFORT" ] && runtime_policy_args+=(--effort "$CLAUDE_CODE_EFFORT")
  runtime_policy_args+=(--settings "$settings_file")
  for path in "${add_dirs[@]}"; do runtime_policy_args+=(--add-dir "$path"); done
  probe_policy_args=("${runtime_policy_args[@]}")
  # The reviewer probe deliberately omits this one outer removal layer so the
  # same settings must prove Edit/Write denial. Runtime is strictly tighter.
  [ "$layout" = reviewer ] \
    && runtime_policy_args+=(--disallowedTools "Edit,Write,NotebookEdit")

  for path in "$probe_prompt" "$probe_trace" "$probe_stderr"; do
    if [ -e "$path" ] || [ -L "$path" ]; then
      _agmsg_claude_spawn_fail "Claude probe diagnostic collision at $path; refusing to overwrite"
    fi
  done
  probe_prompt_content="$(agmsg_claude_render_probe_prompt \
    "$layout" "$probe_token" "$PROJECT" "$scratch" "$run_write" "$sentinel")" \
    || _agmsg_claude_spawn_fail "cannot render Claude probe prompt"
  agmsg_claude_create_exclusive_file "$probe_prompt" "$probe_prompt_content" \
    || _agmsg_claude_spawn_fail "cannot exclusively create Claude probe prompt $probe_prompt"
  probe_prompt_created=1
  local noclobber_was_set=0
  [[ -o noclobber ]] && noclobber_was_set=1
  set -o noclobber
  if exec 8> "$probe_trace"; then
    probe_trace_created=1
    probe_trace_fd_open=1
  else
    [ "$noclobber_was_set" = 1 ] || set +o noclobber
    _agmsg_claude_spawn_fail "cannot exclusively create Claude probe trace $probe_trace"
  fi
  if exec 9> "$probe_stderr"; then
    probe_stderr_created=1
    probe_stderr_fd_open=1
  else
    [ "$noclobber_was_set" = 1 ] || set +o noclobber
    _agmsg_claude_spawn_fail "cannot exclusively create Claude probe stderr $probe_stderr"
  fi
  [ "$noclobber_was_set" = 1 ] || set +o noclobber
  while [ "$attempts" -lt 2 ]; do
    attempts=$((attempts + 1))
    probe_rc=0
    if [ -e "$run_write" ] || [ -L "$run_write" ]; then
      if [ "$run_write_created" = 1 ] \
        && [ ! -L "$run_write" ] \
        && [ "$(cat "$run_write" 2>/dev/null || true)" = "$probe_token-run-write" ]; then
        rm -f "$run_write" 2>/dev/null || true
        run_write_created=0
      else
        _agmsg_claude_spawn_fail "unowned or modified run-write probe target appeared at $run_write; refusing to overwrite"
      fi
    fi
    agmsg_claude_run_probe_attempt "$probe_prompt_content" \
      "$scratch" "$worker_home" "$child_tmp" "$probe_timeout" \
      "${probe_policy_args[@]}" || probe_rc=$?
    [ -f "$repo_bash" ] && [ ! -L "$repo_bash" ] && repo_bash_created=1
    [ -f "$repo_write" ] && [ ! -L "$repo_write" ] && repo_write_created=1
    [ -f "$scratch_write" ] && [ ! -L "$scratch_write" ] && scratch_write_created=1
    [ -f "$run_write" ] && [ ! -L "$run_write" ] && run_write_created=1
    if [ "$probe_rc" -eq 0 ] \
      && agmsg_claude_probe_complete "$probe_trace" "$layout" "$probe_token" \
        "$PROJECT" "$scratch" "$sentinel" "$run_write"; then
      break
    fi
  done
  if [ "$attempts" -ge 2 ] \
    && { [ "$probe_rc" -ne 0 ] \
      || ! agmsg_claude_probe_complete "$probe_trace" "$layout" "$probe_token" \
        "$PROJECT" "$scratch" "$sentinel" "$run_write"; }; then
    if [ "${AGMSG_CLAUDE_KEEP_PROBE:-0}" = 1 ]; then
      diagnostics_preserved=1
      printf 'spawn: preserved failed Claude probe diagnostics:\n  prompt: %s\n  trace: %s\n  stderr: %s\n  settings: %s\n' \
        "$probe_prompt" "$probe_trace" "$probe_stderr" "$settings_file" >&2
    fi
    _agmsg_claude_spawn_fail "Claude $layout sandbox probe did not produce every required correlated tool event after 2 attempts (last rc=$probe_rc); refusing fail-closed"
  fi

  exec 8>&- || true
  probe_trace_fd_open=0
  exec 9>&- || true
  probe_stderr_fd_open=0
  [ ! -L "$probe_prompt" ] && rm -f "$probe_prompt" 2>/dev/null || true
  [ ! -L "$probe_trace" ] && rm -f "$probe_trace" 2>/dev/null || true
  [ ! -L "$probe_stderr" ] && rm -f "$probe_stderr" 2>/dev/null || true
  probe_prompt_created=0
  probe_trace_created=0
  probe_stderr_created=0
  _agmsg_claude_cleanup_probe_targets
  [ "$worker_projects_created" = 1 ] && rmdir "$worker_projects" 2>/dev/null || true
  worker_projects_created=0

  if [ -n "${ROLE_FILE:-}" ]; then
    cp -- "$ROLE_FILE" "$rolefile" 2>/dev/null \
      || _agmsg_claude_spawn_fail "failed to stage role file ($ROLE_FILE) for Claude '$NAME'"
    role_staged=1
  fi

  AGMSG_RESOLVE_PROJECT=0 "$SCRIPT_DIR/join.sh" "$TEAM" "$NAME" claude-code "$scratch" >/dev/null \
    || _agmsg_claude_spawn_fail "join failed for Claude '$NAME' in team '$TEAM'"
  joined=1

  local -a role_args=()
  [ "$role_staged" = 1 ] && role_args+=(--role-file "$rolefile")
  local -a timeout_args=()
  [ -n "$CLAUDE_CODE_TURN_TIMEOUT" ] && timeout_args+=(--turn-timeout "$CLAUDE_CODE_TURN_TIMEOUT")
  local -a bridge_run=()
  if [ -n "${AGMSG_CLAUDE_BRIDGE_CMD:-}" ]; then
    bridge_run=("$AGMSG_CLAUDE_BRIDGE_CMD")
  else
    bridge_run=(bash "$SCRIPT_DIR/drivers/types/claude-code/claude-code-bridge.sh")
  fi

  (
    agmsg_claude_prepare_child_env "$worker_home" "$child_tmp"
    cd "$scratch" || exit 70
    exec nohup "${bridge_run[@]}" \
      --project "$scratch" --team "$TEAM" --name "$NAME" --type claude-code \
      --identity-key "$idkey" --output-format json \
      "${runtime_policy_args[@]}" \
      ${role_args[@]+"${role_args[@]}"} \
      ${timeout_args[@]+"${timeout_args[@]}"}
  ) >> "$logfile" 2>&1 &
  bpid=$!

  local ready=0 tick ready_ticks="${AGMSG_CLAUDE_SPAWN_READY_TICKS:-50}"
  case "$ready_ticks" in ''|*[!0-9]*|0) ready_ticks=50 ;; esac
  for ((tick=0; tick<ready_ticks; tick++)); do
    if [ "$(cat "$pidfile" 2>/dev/null || true)" = "$bpid" ] && _agmsg_pid_alive "$bpid"; then
      ready=1
      break
    fi
    _agmsg_pid_alive "$bpid" || break
    sleep 0.1
  done
  if [ "$ready" != 1 ]; then
    _agmsg_claude_spawn_fail "Claude bridge failed to publish a live owner pid; see $logfile"
  fi

  # The approved bridge owns lifecycle writes; spawn normalizes the metadata only
  # after observing its pid handoff, eliminating the write race while preserving
  # bridge cleanup's first-line owner check.
  printf 'pid=%s\nproject=%s\nidentities=%s/%s\ntype=claude-code\n' \
    "$bpid" "$scratch" "$TEAM" "$NAME" > "$metafile" \
    || _agmsg_claude_spawn_fail "cannot write exact Claude bridge metadata"
  printf '%s\n' "$bpid" > "$pidfile" \
    || _agmsg_claude_spawn_fail "cannot write Claude bridge pidfile"

  local spawn_record
  spawn_record="$(agmsg_spawn_path "$TEAM" "$NAME")"
  printf '%s\t%s\t%s\n' "pid:$bpid" "$scratch" "claude-code" > "$spawn_record" \
    || _agmsg_claude_spawn_fail "cannot record Claude bridge placement"

  _agmsg_claude_spawn_lk_release
  echo "spawned headless $layout claude-code '$NAME' in team '$TEAM' (pid $bpid)"
  [ "$layout" = implementer ] && echo "  repo (WRITE via --add-dir): $PROJECT"
  [ "$layout" = reviewer ] && echo "  repo (read-only via --add-dir): $PROJECT"
  [ "$layout" = reviewer ] && [ "${#inherited_dirs[@]}" -gt 0 ] \
    && echo "  inherited add-dir reads: ${inherited_dirs[*]}"
  [ "$layout" = consultant ] && echo "  repo: not added (scratch-only consultant)"
  echo "  cwd: $scratch"
  echo "  settings: $settings_file"
  [ "$role_staged" = 1 ] && echo "  role: $ROLE_FILE"
  echo "  log: $logfile"
}
