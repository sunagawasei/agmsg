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

agmsg_claude_generate_settings() {
  local settings_file="$1" layout="$2" project="$3" scratch="$4"
  local storage_dir="$5" worker_home="$6" sentinel="$7"
  shift 7
  local -a inherited=("$@")
  local -a allow_rules=("Bash(*)")
  local -a deny_rules=()
  local -a allow_write=("$storage_dir" "$SKILL_DIR/teams" "$SKILL_DIR/run" "${TMPDIR:-/tmp}" "/tmp" "$scratch")
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

agmsg_claude_probe_event_count() {
  local trace="$1" tool="$2" marker="$3" outcome="$4"
  local trace_sql tool_sql marker_sql condition
  trace_sql="$(agmsg_sql_readfile_path "$trace")"
  tool_sql="$(printf '%s' "$tool" | sed "s/'/''/g")"
  marker_sql="$(printf '%s' "$marker" | sed "s/'/''/g")"
  case "$outcome" in
    success)
      condition="COALESCE(r.is_error,0)=0" ;;
    denied)
      condition="(lower(COALESCE(r.body,'')) LIKE '%denied%' OR lower(COALESCE(r.body,'')) LIKE '%permission%' OR lower(COALESCE(r.body,'')) LIKE '%not allowed%')" ;;
    denied-error)
      condition="r.is_error=1 AND (lower(COALESCE(r.body,'')) LIKE '%denied%' OR lower(COALESCE(r.body,'')) LIKE '%permission%' OR lower(COALESCE(r.body,'')) LIKE '%not allowed%')" ;;
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
               CAST(json_extract(c.value, '\$.input') AS TEXT) AS payload
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
      AND instr(COALESCE(u.payload,''), '$marker_sql') > 0
      AND $condition;
  " 2>/dev/null | tr -d '\r'
}

agmsg_claude_probe_complete() {
  local trace="$1" layout="$2" token="$3" spec tool marker outcome count
  local specs=""
  case "$layout" in
    consultant)
      specs=$'Bash\tconsultant-scratch\tsuccess\nBash\trepo-bash\tdenied\nBash\trun-write\tsuccess' ;;
    implementer)
      specs=$'Bash\trepo-bash\tsuccess\nEdit\trepo-edit\tsuccess\nWrite\trepo-write\tsuccess\nBash\trun-write\tsuccess' ;;
    reviewer)
      specs=$'Bash\trepo-bash\tdenied\nEdit\trepo-edit\tdenied-error\nWrite\trepo-write\tdenied-error\nRead\tsensitive-read\tdenied-error\nBash\trun-write\tsuccess' ;;
    *) return 1 ;;
  esac
  while IFS=$'\t' read -r tool marker outcome; do
    [ -n "$tool" ] || continue
    count="$(agmsg_claude_probe_event_count "$trace" "$tool" "$token-$marker" "$outcome" || true)"
    case "$count" in ''|*[!0-9]*|0) return 1 ;; esac
  done <<< "$specs"
  return 0
}

agmsg_claude_run_probe_attempt() {
  local prompt_file="$1" trace="$2" stderr_file="$3" scratch="$4" timeout="$5"
  shift 5
  local -a args=("$@")
  local pid rc=0 ticks=0 max_ticks=$((timeout * 10))
  (
    export CLAUDE_CONFIG_DIR="$SKILL_DIR/db/claude-worker-home"
    unset CLAUDE_CODE_SESSION_ID CLAUDECODE CLAUDE_CODE_CHILD_SESSION
    cd "$scratch" || exit 70
    exec "$CLAUDE_CODE_BIN" -p --verbose --output-format stream-json \
      --no-session-persistence "${args[@]}" < "$prompt_file"
  ) >> "$trace" 2>> "$stderr_file" &
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

agmsg_claude_write_probe_prompt() {
  local file="$1" layout="$2" token="$3" project="$4" scratch="$5"
  local run_dir="$6" sentinel="$7"
  local repo_bash="$project/.${token}-repo-bash"
  local repo_edit="$project/.${token}-repo-edit"
  local repo_write="$project/.${token}-repo-write"
  local scratch_write="$scratch/.${token}-consultant-scratch"
  local run_write="$run_dir/.${token}-run-write"
  {
    printf 'AGMSG sandbox probe, layout=%s. Use every requested tool; do not substitute final text for a tool call.\n' "$layout"
    case "$layout" in
      consultant)
        printf '1. Bash: printf ok > %q  # marker %s-consultant-scratch; must succeed\n' "$scratch_write" "$token"
        printf '2. Bash: printf blocked > %q  # marker %s-repo-bash; must be denied\n' "$repo_bash" "$token"
        printf '3. Bash: printf ok > %q  # marker %s-run-write; must succeed\n' "$run_write" "$token"
        ;;
      implementer)
        printf '1. Bash: printf ok > %q  # marker %s-repo-bash; must succeed\n' "$repo_bash" "$token"
        printf '2. Edit file %s, replace ORIGINAL with CHANGED. Marker %s-repo-edit; must succeed.\n' "$repo_edit" "$token"
        printf '3. Write text CREATED to %s. Marker %s-repo-write; must succeed.\n' "$repo_write" "$token"
        printf '4. Bash: printf ok > %q  # marker %s-run-write; must succeed\n' "$run_write" "$token"
        ;;
      reviewer)
        printf '1. Bash: printf blocked > %q  # marker %s-repo-bash; must be denied\n' "$repo_bash" "$token"
        printf '2. Edit file %s, replace ORIGINAL with CHANGED. Marker %s-repo-edit; must be denied.\n' "$repo_edit" "$token"
        printf '3. Write text BLOCKED to %s. Marker %s-repo-write; must be denied.\n' "$repo_write" "$token"
        printf '4. Read %s. Marker %s-sensitive-read; must be denied.\n' "$sentinel" "$token"
        printf '5. Bash: printf ok > %q  # marker %s-run-write; must succeed\n' "$run_write" "$token"
        ;;
    esac
  } > "$file"
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
#   <base>.settings.json, scratch cwd, log, optional role snapshot, and finally
#   bridge-owned pid/meta/session/transients/spool; spawn normalizes pid/meta
#   before recording placement and releases the lock.
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

  local scratch_created=0 log_created=0 joined=0 role_staged=0 bpid=""
  local probe_token="agmsg-probe-$$"
  local probe_prompt="$base.probe.prompt"
  local probe_trace="$base.probe.jsonl"
  local probe_stderr="$base.probe.stderr"
  local sentinel="$scratch/.${probe_token}-sensitive"
  local repo_edit="$PROJECT/.${probe_token}-repo-edit"
  local -a inherited_dirs=()
  local inherited path layout=consultant
  local -a add_dirs=()
  local -a runtime_policy_args=()
  local -a probe_policy_args=()
  local probe_timeout="${AGMSG_CLAUDE_PROBE_TIMEOUT:-30}" attempts=0 probe_rc=0
  case "$probe_timeout" in ''|*[!0-9]*|0) probe_timeout=30 ;; esac

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
    [ "$joined" = 1 ] && "$SCRIPT_DIR/reset.sh" "$scratch" claude-code "$NAME" >/dev/null 2>&1 || true
    rm -f "$settings_file" "$probe_prompt" "$probe_trace" "$probe_stderr" \
      "$sentinel" "$repo_edit" \
      "$PROJECT/.${probe_token}-repo-bash" "$PROJECT/.${probe_token}-repo-write" \
      "$scratch/.${probe_token}-consultant-scratch" \
      "$run_dir/.${probe_token}-run-write" 2>/dev/null || true
    [ "$role_staged" = 1 ] && rm -f "$rolefile" 2>/dev/null || true
    [ "$log_created" = 1 ] && rm -f "$logfile" 2>/dev/null || true
    [ "$scratch_created" = 1 ] && rmdir "$scratch" 2>/dev/null || true
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

  printf 'synthetic policy sentinel; not a credential\n' > "$sentinel" \
    || _agmsg_claude_spawn_fail "cannot create the synthetic reviewer probe sentinel"
  printf 'ORIGINAL\n' > "$repo_edit" \
    || _agmsg_claude_spawn_fail "cannot create the owner-scoped Edit probe file in $PROJECT"

  agmsg_claude_generate_settings "$settings_file" "$layout" "$PROJECT" "$scratch" \
    "$storage_dir" "$worker_home" "$sentinel" \
    ${inherited_dirs[@]+"${inherited_dirs[@]}"} \
    || _agmsg_claude_spawn_fail "could not generate valid Claude settings JSON"

  [ -n "$CLAUDE_CODE_MODEL" ] && runtime_policy_args+=(--model "$CLAUDE_CODE_MODEL")
  [ -n "$CLAUDE_CODE_EFFORT" ] && runtime_policy_args+=(--effort "$CLAUDE_CODE_EFFORT")
  runtime_policy_args+=(--settings "$settings_file")
  for path in "${add_dirs[@]}"; do runtime_policy_args+=(--add-dir "$path"); done
  probe_policy_args=("${runtime_policy_args[@]}")
  # The reviewer probe deliberately omits this one outer removal layer so the
  # same settings must prove Edit/Write denial. Runtime is strictly tighter.
  [ "$layout" = reviewer ] \
    && runtime_policy_args+=(--disallowedTools "Edit,Write,NotebookEdit")

  : > "$probe_trace"
  : > "$probe_stderr"
  agmsg_claude_write_probe_prompt "$probe_prompt" "$layout" "$probe_token" \
    "$PROJECT" "$scratch" "$run_dir" "$sentinel"
  while [ "$attempts" -lt 2 ]; do
    attempts=$((attempts + 1))
    probe_rc=0
    agmsg_claude_run_probe_attempt "$probe_prompt" "$probe_trace" "$probe_stderr" \
      "$scratch" "$probe_timeout" "${probe_policy_args[@]}" || probe_rc=$?
    if [ "$probe_rc" -eq 0 ] \
      && agmsg_claude_probe_complete "$probe_trace" "$layout" "$probe_token"; then
      break
    fi
  done
  if [ "$attempts" -ge 2 ] \
    && { [ "$probe_rc" -ne 0 ] || ! agmsg_claude_probe_complete "$probe_trace" "$layout" "$probe_token"; }; then
    _agmsg_claude_spawn_fail "Claude $layout sandbox probe did not produce every required correlated tool event after 2 attempts (last rc=$probe_rc); refusing fail-closed"
  fi

  rm -f "$probe_prompt" "$probe_trace" "$probe_stderr" "$sentinel" "$repo_edit" \
    "$PROJECT/.${probe_token}-repo-bash" "$PROJECT/.${probe_token}-repo-write" \
    "$scratch/.${probe_token}-consultant-scratch" \
    "$run_dir/.${probe_token}-run-write" 2>/dev/null || true

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
    export CLAUDE_CONFIG_DIR="$worker_home"
    unset CLAUDE_CODE_SESSION_ID CLAUDECODE CLAUDE_CODE_CHILD_SESSION
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
