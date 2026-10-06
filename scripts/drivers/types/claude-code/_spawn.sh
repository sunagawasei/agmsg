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
# Only 2.1.226 has been verified to scrub the OAuth token from Bash child
# environments; 2.1.220 is unverified, so the accepted range starts at 2.1.226.
CLAUDE_CODE_MIN_VERSION=2.1.226
CLAUDE_CODE_INHERIT_ADD_DIRS_KEY="spawn.claude_inherit_add_dirs"
# Raw `--version` stdout, set once by agmsg_claude_check_version. The probe
# cache key (item 2, see agmsg_claude_probe_cache_key) reuses this instead of
# invoking the CLI a second time.
CLAUDE_CODE_VERSION_OUTPUT=""

# Fixed, never-existing paths standing in for the 3 per-spawn-unique settings
# inputs (scratch/child_tmp/sentinel) when normalizing settings for the probe
# cache key. agmsg_claude_physical_path returns its input unchanged for a path
# that does not exist, so substituting these keeps agmsg_claude_render_settings_json
# deterministic across TEAM/NAME/PID (see docs on agmsg_claude_probe_cache_key).
_AGMSG_CLAUDE_PROBE_CACHE_PLACEHOLDER_SCRATCH="/agmsg-claude-probe-cache-placeholder/scratch"
_AGMSG_CLAUDE_PROBE_CACHE_PLACEHOLDER_SENTINEL="/agmsg-claude-probe-cache-placeholder/sentinel"
_AGMSG_CLAUDE_PROBE_CACHE_PLACEHOLDER_CHILD_TMP="/agmsg-claude-probe-cache-placeholder/child-tmp"
# Claude Code's host-wide managed-settings root. Overridable so bats can inject
# those layers without touching the real /Library copy; production keeps the
# documented default.
: "${AGMSG_CLAUDE_MANAGED_SETTINGS_DIR:=/Library/Application Support/ClaudeCode}"

# shellcheck source=../../lib/reviewer-add-dirs.sh
. "$SCRIPT_DIR/lib/reviewer-add-dirs.sh"
# shellcheck source=../../lib/validate.sh
. "$SCRIPT_DIR/lib/validate.sh"
# shellcheck source=../../lib/identity-key.sh
. "$SCRIPT_DIR/lib/identity-key.sh"

# Explicit order: top-level statements in these parts (AGMSG_CLAUDE_WRITE_ROOTS=())
# must run after the constants and libs above.
# shellcheck source=_spawn-config.sh
. "$SCRIPT_DIR/drivers/types/claude-code/_spawn-config.sh"
# shellcheck source=_spawn-paths.sh
. "$SCRIPT_DIR/drivers/types/claude-code/_spawn-paths.sh"
# shellcheck source=_spawn-settings.sh
. "$SCRIPT_DIR/drivers/types/claude-code/_spawn-settings.sh"
# shellcheck source=_spawn-probe-cache.sh
. "$SCRIPT_DIR/drivers/types/claude-code/_spawn-probe-cache.sh"
# shellcheck source=_spawn-probe.sh
. "$SCRIPT_DIR/drivers/types/claude-code/_spawn-probe.sh"

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
  agmsg_pending_spawn_owner_capture
  storage_dir="$(agmsg_storage_dir)"
  worker_home="$SKILL_DIR/db/claude-worker-home"

  agmsg_validate_team_name "$TEAM" >/dev/null 2>&1 \
    || die "team name '$TEAM' is not a path-safe segment"
  agmsg_validate_agent_name "$NAME" >/dev/null 2>&1 \
    || die "agent name '$NAME' is not valid for a headless bridge"

  # The reviewer root guard also precedes the CLI call, the placement lock and
  # every per-worker artifact, so a refusal leaves nothing behind.
  local scratch="$run_dir/claude-code-$TEAM-$NAME-cwd"
  if [ "$IMPLEMENTER" != 1 ] && [ "$REVIEWER" = 1 ]; then
    agmsg_claude_set_write_roots "$storage_dir" "$scratch/tmp" "$scratch"
    agmsg_claude_reviewer_root_guard "$PROJECT" || exit 1
  fi

  # Version gating is deliberately before every per-worker artifact and launch.
  agmsg_claude_check_version
  agmsg_claude_resolve_turn_options "$NAME"

  local idkey base pidfile metafile logfile rolefile settings_file
  idkey="$(agmsg_identity_key "$TEAM" "$NAME")"
  base="$run_dir/claude-code-bridge.$TEAM.$NAME"
  pidfile="$base.pid"
  metafile="$base.meta"
  logfile="$base.log"
  rolefile="$base.role"
  settings_file="$base.settings.json"

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
  local probe_cache_enabled=1 probe_cache_ttl="" probe_cache_ttl_valid=0
  local probe_cache_key="" probe_cache_hit=0
  local probe_cache_recordable=0

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
  # A symlinked scratch would point the .claude removal below outside run/.
  [ ! -L "$scratch" ] \
    || _agmsg_claude_spawn_fail "Claude scratch cwd $scratch is a symlink; refusing to use it"
  if [ ! -d "$scratch" ]; then
    mkdir -p "$scratch" \
      || _agmsg_claude_spawn_fail "cannot create Claude scratch cwd $scratch"
    scratch_created=1
  fi
  # Project-local settings left by a previous worker would be read by this one.
  if [ -e "$scratch/.claude" ] || [ -L "$scratch/.claude" ]; then
    if [ -L "$scratch/.claude" ]; then rm -f -- "$scratch/.claude"; else rm -rf -- "$scratch/.claude"; fi \
      || _agmsg_claude_spawn_fail "cannot remove stale $scratch/.claude"
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

  # Probe cache decision (spawn.claude_probe_cache*, see [task:probe-cache]).
  # The key is computed even when a disabled/bypass/invalid-TTL path will not
  # hit or write, so a later live-probe failure can still forget a stale record.
  if ! agmsg_claude_config_true \
    "$("$SCRIPT_DIR/config.sh" get spawn.claude_probe_cache true 2>/dev/null || true)"; then
    probe_cache_enabled=0
  fi
  probe_cache_ttl="$("$SCRIPT_DIR/config.sh" get spawn.claude_probe_cache_ttl 86400 2>/dev/null || true)"
  case "$probe_cache_ttl" in
    ''|*[!0-9]*|0) probe_cache_ttl_valid=0 ;;
    *) probe_cache_ttl_valid=1 ;;
  esac
  if [ "$probe_cache_enabled" = 1 ] && [ "$probe_cache_ttl_valid" = 1 ]; then
    probe_cache_recordable=1
  fi
  if probe_cache_key="$(agmsg_claude_probe_cache_key "$layout" "$PROJECT" \
    "$storage_dir" "$worker_home" "$CLAUDE_CODE_MODEL" "$CLAUDE_CODE_EFFORT" \
    "$CLAUDE_CODE_VERSION_OUTPUT" "$CLAUDE_CODE_BIN" \
    ${inherited_dirs[@]+"${inherited_dirs[@]}"})"; then
    if [ "$probe_cache_recordable" = 1 ] \
      && [ "${AGMSG_CLAUDE_PROBE_FORCE:-0}" != 1 ] \
      && agmsg_claude_probe_cache_check_hit "$probe_cache_key" "$probe_cache_ttl"; then
      probe_cache_hit=1
    fi
  else
    probe_cache_key=""
  fi

  if [ "$probe_cache_hit" != 1 ]; then
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
  fi
  agmsg_claude_generate_settings "$settings_file" "$layout" "$PROJECT" "$scratch" \
    "$storage_dir" "$worker_home" "$sentinel" "$child_tmp" \
    ${inherited_dirs[@]+"${inherited_dirs[@]}"} \
    || _agmsg_claude_spawn_fail "could not generate valid Claude settings JSON"
  settings_created=1

  [ -n "$CLAUDE_CODE_MODEL" ] && runtime_policy_args+=(--model "$CLAUDE_CODE_MODEL")
  [ -n "$CLAUDE_CODE_EFFORT" ] && runtime_policy_args+=(--effort "$CLAUDE_CODE_EFFORT")
  runtime_policy_args+=(--settings "$settings_file")
  for path in ${add_dirs[@]+"${add_dirs[@]}"}; do runtime_policy_args+=(--add-dir "$path"); done
  probe_policy_args=("${runtime_policy_args[@]}")
  # The reviewer probe deliberately omits this one outer removal layer so the
  # same settings must prove Edit/Write denial. Runtime is strictly tighter.
  [ "$layout" = reviewer ] \
    && runtime_policy_args+=(--disallowedTools "Edit,Write,NotebookEdit")

  if [ "$probe_cache_hit" = 1 ]; then
    echo "spawn: reusing cached Claude $layout sandbox probe result; skipping live probe"
  else
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
        if [ -n "$probe_cache_key" ] && [ "$probe_cache_recordable" = 1 ]; then
          agmsg_claude_probe_cache_write "$probe_cache_key" "$layout" \
            "$CLAUDE_CODE_VERSION_OUTPUT" \
            || echo "spawn: could not record Claude sandbox probe cache entry (non-fatal)" >&2
        fi
        break
      fi
    done
    if [ "$attempts" -ge 2 ] \
      && { [ "$probe_rc" -ne 0 ] \
        || ! agmsg_claude_probe_complete "$probe_trace" "$layout" "$probe_token" \
          "$PROJECT" "$scratch" "$sentinel" "$run_write"; }; then
      if [ -n "$probe_cache_key" ]; then
        agmsg_claude_probe_cache_forget "$probe_cache_key" || true
      else
        agmsg_claude_probe_cache_forget_all || true
      fi
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
  fi

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

  local spawn_record placement_record bridge_start
  spawn_record="$(agmsg_spawn_path "$TEAM" "$NAME")"
  placement_record="$(printf '%s\t%s\t%s' "pid:$bpid" "$scratch" "claude-code")"
  printf '%s\n' "$placement_record" > "$spawn_record" \
    || _agmsg_claude_spawn_fail "cannot record Claude bridge placement"
  bridge_start="$(agmsg_pid_start_token "$bpid" 2>/dev/null || true)"

  # despawn takes the placement lock inside the lifecycle lock; release ours
  # before the pending record's publish takes the lifecycle lock.
  _agmsg_claude_spawn_lk_release
  agmsg_pending_teardown_write_spawn_owner "$TEAM" "$NAME" claude-code \
    "$placement_record" "$bridge_start" || true
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
