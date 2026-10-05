#!/usr/bin/env bash
# claude-code spawn plug: sandbox probe command, completion check and prompt.
# Sourced by _spawn.sh after its constants and libs; do not source standalone.

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
    denied-error)
      condition="r.is_error=1 AND (
        lower(COALESCE(r.body,'')) LIKE '%permission denied%'
        OR lower(COALESCE(r.body,'')) LIKE '%denied by %'
        OR lower(COALESCE(r.body,'')) LIKE '%access denied%'
        OR lower(COALESCE(r.body,'')) LIKE '%not allowed%'
        OR lower(COALESCE(r.body,'')) LIKE '%operation not permitted%'
        OR (
          lower(COALESCE(r.body,'')) LIKE '%requested permissions to %'
          AND (
            lower(COALESCE(r.body,'')) LIKE '%haven’t granted it yet.%'
            OR lower(COALESCE(r.body,'')) LIKE '%haven''t granted it yet.%'
          )
        )
      )" ;;
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
      specs=$'Bash\tconsultant-scratch\tsuccess\tscratch\nBash\trepo-bash\tdenied-error\trepo-bash\nBash\trun-write\tsuccess\trun-write' ;;
    implementer)
      specs=$'Bash\trepo-bash\tsuccess\trepo-bash\nEdit\trepo-edit\tsuccess\trepo-edit\nWrite\trepo-write\tsuccess\trepo-write\nBash\trun-write\tsuccess\trun-write' ;;
    reviewer)
      specs=$'Bash\trepo-bash\tdenied-error\trepo-bash\nRead\tedit-prereq-read\tsuccess\trepo-edit\nEdit\trepo-edit\tdenied-error\trepo-edit\nWrite\trepo-write\tdenied-error\trepo-write\nRead\tsensitive-read\tdenied-error\tsentinel\nBash\trun-write\tsuccess\trun-write' ;;
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

  # Correlated tool results prove which operation Claude attempted and which
  # policy layer rejected it. Exact filesystem effects are the primary proof:
  # a denial-looking message must never hide a write that actually occurred.
  case "$layout" in
    consultant)
      [ -f "$scratch_write" ] && [ ! -L "$scratch_write" ] || return 1
      [ "$(cat "$scratch_write" 2>/dev/null || true)" = \
        "$token-consultant-scratch" ] || return 1
      [ ! -e "$repo_bash" ] && [ ! -L "$repo_bash" ] || return 1
      ;;
    implementer)
      [ -f "$repo_bash" ] && [ ! -L "$repo_bash" ] || return 1
      [ "$(cat "$repo_bash" 2>/dev/null || true)" = \
        "$token-repo-bash" ] || return 1
      [ -f "$repo_edit" ] && [ ! -L "$repo_edit" ] || return 1
      [ "$(cat "$repo_edit" 2>/dev/null || true)" = \
        "CHANGED $token" ] || return 1
      [ -f "$repo_write" ] && [ ! -L "$repo_write" ] || return 1
      [ "$(cat "$repo_write" 2>/dev/null || true)" = \
        "$token-repo-write" ] || return 1
      ;;
    reviewer)
      [ -f "$repo_edit" ] && [ ! -L "$repo_edit" ] || return 1
      [ "$(cat "$repo_edit" 2>/dev/null || true)" = \
        "ORIGINAL $token" ] || return 1
      [ ! -e "$repo_write" ] && [ ! -L "$repo_write" ] || return 1
      [ ! -e "$repo_bash" ] && [ ! -L "$repo_bash" ] || return 1
      ;;
    *) return 1 ;;
  esac

  [ -f "$run_write" ] && [ ! -L "$run_write" ] || return 1
  [ "$(cat "$run_write" 2>/dev/null || true)" = "$token-run-write" ] || return 1
  return 0
}

agmsg_claude_prepare_child_env() {
  local worker_home="$1" child_tmp="$2"
  export CLAUDE_CONFIG_DIR="$worker_home"
  export TMPDIR="$child_tmp"
  export AGMSG_RESOLVE_PROJECT=0
  unset CLAUDE_CODE_SESSION_ID CLAUDECODE CLAUDE_CODE_CHILD_SESSION
  agmsg_session_unset_env
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
