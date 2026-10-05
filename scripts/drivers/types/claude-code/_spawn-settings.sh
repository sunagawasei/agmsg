#!/usr/bin/env bash
# claude-code spawn plug: settings.json rendering and generation.
# Sourced by _spawn.sh after its constants and libs; do not source standalone.

# JSON emitter shared by the real spawn path and the probe cache key
# (agmsg_claude_probe_cache_normalized_settings): given the same inputs it
# prints the exact same bytes generate_settings would publish. mkdir of
# worker_home is required before physical-path aliasing (same as the pre-split
# generate_settings); this does not read or write the settings file.
agmsg_claude_render_settings_json() {
  local layout="$1" project="$2" scratch="$3"
  local storage_dir="$4" worker_home="$5" sentinel="$6" child_tmp="$7"
  shift 7
  local -a inherited=("$@")
  local -a allow_rules=("Bash(*)")
  local -a deny_rules=()
  agmsg_claude_set_write_roots "$storage_dir" "$child_tmp" "$scratch"
  local -a allow_write_candidates=(${AGMSG_CLAUDE_WRITE_ROOTS[@]+"${AGMSG_CLAUDE_WRITE_ROOTS[@]}"})
  local -a deny_write=()
  local -a allow_read_candidates=(
    "$scratch" "$SKILL_DIR" "/tmp" "/bin" "/usr/bin" "/usr/lib"
    "/System" "/Library" "/nix" "/opt/homebrew" "/usr/local"
  )
  local -a allow_write=()
  local -a allow_read=()
  local -a deny_read=()
  local -a worker_home_candidates=("$worker_home")
  local path physical rule

  # Resolve the physical alias only after the directory exists. Otherwise a
  # first spawn through a symlinked SKILL_DIR would retain only the logical deny.
  mkdir -p "$worker_home" || return 1
  physical="$(agmsg_claude_physical_path "$worker_home")"
  if [ -n "$physical" ] && [ "$physical" != "$worker_home" ]; then
    agmsg_claude_path_in_list "$physical" ${worker_home_candidates[@]+"${worker_home_candidates[@]}"} \
      || worker_home_candidates+=("$physical")
  fi

  case "$layout" in
    implementer)
      allow_write_candidates+=("$project")
      allow_read_candidates+=("$project")
      allow_rules+=("$(agmsg_claude_tool_rule Read "$project")")
      allow_rules+=("$(agmsg_claude_tool_rule Edit "$project")")
      ;;
    reviewer)
      allow_read_candidates+=("$project")
      # Bash process substitution (`< <(...)`) opens /dev/fd/N; several agmsg
      # scripts use it, and denyRead("/") below blocks it without this (#46).
      allow_read_candidates+=("/dev/fd")
      deny_write+=("$project")
      deny_read+=("/")
      allow_rules+=("$(agmsg_claude_tool_rule Read "$project")")
      deny_rules+=("$(agmsg_claude_tool_rule Edit "$project")")
      deny_rules+=("$(agmsg_claude_tool_rule Read "$HOME/.ssh")")
      deny_rules+=("Read(//**/*credentials*)")
      deny_rules+=("Read(//**/*credentials*/**)")
      deny_rules+=("$(agmsg_claude_tool_rule Read "$worker_home/projects")")
      deny_rules+=("$(agmsg_claude_exact_tool_rule Read "$sentinel")")
      for path in ${inherited[@]+"${inherited[@]}"}; do
        [ -n "$path" ] || continue
        allow_read_candidates+=("$path")
        allow_rules+=("$(agmsg_claude_tool_rule Read "$path")")
      done
      ;;
    consultant)
      allow_rules+=("$(agmsg_claude_tool_rule Read "$scratch")")
      deny_rules+=("$(agmsg_claude_tool_rule Edit "$project")")
      deny_write+=("$project")
      ;;
    *) return 1 ;;
  esac

  # The worker home can contain authentication state. Protect every layout at
  # both the built-in tool layer and the Bash filesystem sandbox layer.
  for path in ${worker_home_candidates[@]+"${worker_home_candidates[@]}"}; do
    rule="$(agmsg_claude_tool_rule Read "$path")"
    agmsg_claude_path_in_list "$rule" ${deny_rules[@]+"${deny_rules[@]}"} \
      || deny_rules+=("$rule")
    rule="$(agmsg_claude_tool_rule Edit "$path")"
    agmsg_claude_path_in_list "$rule" ${deny_rules[@]+"${deny_rules[@]}"} \
      || deny_rules+=("$rule")
    agmsg_claude_path_in_list "$path" ${deny_read[@]+"${deny_read[@]}"} \
      || deny_read+=("$path")
    agmsg_claude_path_in_list "$path" ${deny_write[@]+"${deny_write[@]}"} \
      || deny_write+=("$path")
  done

  # Seatbelt evaluates resolved filesystem paths, so retain each logical root
  # first and add its physical alias under the same permission.
  for path in ${allow_write_candidates[@]+"${allow_write_candidates[@]}"}; do
    [ -n "$path" ] || continue
    agmsg_claude_path_in_list "$path" ${allow_write[@]+"${allow_write[@]}"} \
      || allow_write+=("$path")
    physical="$(agmsg_claude_physical_path "$path")"
    if [ -n "$physical" ] && [ "$physical" != "$path" ]; then
      agmsg_claude_path_in_list "$physical" ${allow_write[@]+"${allow_write[@]}"} \
        || allow_write+=("$physical")
    fi
  done
  for path in ${allow_read_candidates[@]+"${allow_read_candidates[@]}"}; do
    [ -n "$path" ] || continue
    agmsg_claude_path_in_list "$path" ${allow_read[@]+"${allow_read[@]}"} \
      || allow_read+=("$path")
    physical="$(agmsg_claude_physical_path "$path")"
    if [ -n "$physical" ] && [ "$physical" != "$path" ]; then
      agmsg_claude_path_in_list "$physical" ${allow_read[@]+"${allow_read[@]}"} \
        || allow_read+=("$physical")
    fi
  done

  printf '{\n  "permissions": {\n    "allow": '
  agmsg_claude_emit_json_array ${allow_rules[@]+"${allow_rules[@]}"}
  printf ',\n    "deny": '
  agmsg_claude_emit_json_array ${deny_rules[@]+"${deny_rules[@]}"}
  printf '\n  },\n  "sandbox": {\n'
  printf '    "enabled": true,\n'
  printf '    "autoAllowBashIfSandboxed": true,\n'
  printf '    "failIfUnavailable": true,\n'
  printf '    "allowUnsandboxedCommands": false,\n'
  printf '    "filesystem": {\n      "allowWrite": '
  agmsg_claude_emit_json_array ${allow_write[@]+"${allow_write[@]}"}
  printf ',\n      "denyWrite": '
  agmsg_claude_emit_json_array ${deny_write[@]+"${deny_write[@]}"}
  printf ',\n      "allowRead": '
  agmsg_claude_emit_json_array ${allow_read[@]+"${allow_read[@]}"}
  printf ',\n      "denyRead": '
  agmsg_claude_emit_json_array ${deny_read[@]+"${deny_read[@]}"}
  printf '\n    }\n  }\n}\n'
}

# Thin wrapper: render into a private tmp file, validate as JSON, then publish
# atomically. Signature unchanged from before the render/wrapper split.
agmsg_claude_generate_settings() {
  local settings_file="$1"
  shift
  local tmp="${settings_file}.tmp.$$" tmp_sql valid
  agmsg_claude_render_settings_json "$@" > "$tmp" \
    || { rm -f "$tmp" 2>/dev/null || true; return 1; }
  tmp_sql="$(agmsg_sql_readfile_path "$tmp")"
  valid="$(agmsg_sqlite_mem "SELECT json_valid(readfile('$tmp_sql'));" 2>/dev/null || true)"
  [ "$valid" = 1 ] || { rm -f "$tmp" 2>/dev/null || true; return 1; }
  mv "$tmp" "$settings_file"
}
