#!/usr/bin/env bash
# cursor delivery plug — cursor-agent's native hooks.json (superseding the
# .cursor/rules/agmsg.mdc rule file from #131).
#
# cursor-agent's hooks.json is FLAT (`{"version":1,"hooks":{"stop":[{"command":
# "..."}]}}`) and lowerCamel-named (stop/sessionStart/sessionEnd/
# beforeSubmitPrompt), unlike claude-code/codex's nested `hooks[].hooks[]`
# PascalCase shape — hooks-json.sh's strip/add helpers assume that nested shape,
# so this plug carries its own flat-shape equivalents rather than reusing them.
# Both still lean on hooks-json.sh's readfile()/writefile() + byte-length-guard
# pattern (see its header for the #95/#143/#162 history that pattern fixes).
#
# Sourced by delivery.sh's agmsg_delivery_load_plug, so SKILL_DIR, SKILL_NAME,
# resolve_hooks_file, _agmsg_shq, sql_readfile_path, agmsg_sqlite_mem, and
# prune_empty_hooks_file (shape-agnostic — it only inspects the `.hooks` object
# itself) are already in scope.

# SQL-literal-escaped path prefix that identifies an agmsg-owned hook command.
_CURSOR_OWNED_PREFIX="$(printf '%s' "$SKILL_DIR/scripts/" | sed "s/'/''/g")"

# Strip agmsg-owned entries from <event> in the flat hooks.json at <path>. An
# entry is agmsg-owned when its own "command" references the scripts directory
# agmsg actually writes ($SKILL_DIR/scripts/), not the bare skill name: with the
# real install name (agmsg) a name match also strips a user hook whose command
# merely mentions the word. The claude/codex shape helper in lib/hooks-json.sh
# still matches on the name; that is upstream behaviour left untouched here.
_cursor_strip_event() {
  local path="$1" event="$2" sql_path
  sql_path=$(sql_readfile_path "$path")
  local tmp tmp_sql
  tmp=$(mktemp "${TMPDIR:-/tmp}/agmsg.XXXXXX")
  tmp_sql=$(sql_readfile_path "$tmp")
  local wrote
  wrote=$(agmsg_sqlite_mem "
    WITH src AS (SELECT readfile('$sql_path') AS j),
    out AS (SELECT coalesce(CASE
      WHEN json_extract(src.j, '\$.hooks.$event') IS NULL THEN
        src.j
      WHEN (SELECT count(*) FROM json_each(json_extract(src.j, '\$.hooks.$event')) AS s
            WHERE coalesce(instr(json_extract(s.value, '\$.command'), '$_CURSOR_OWNED_PREFIX'), 0) = 0) = 0 THEN
        json_remove(src.j, '\$.hooks.$event')
      ELSE
        json_set(src.j, '\$.hooks.$event',
          (SELECT json_group_array(json(s.value))
           FROM json_each(json_extract(src.j, '\$.hooks.$event')) AS s
           WHERE coalesce(instr(json_extract(s.value, '\$.command'), '$_CURSOR_OWNED_PREFIX'), 0) = 0)
        )
    END, '') AS blob FROM src)
    SELECT writefile('$tmp_sql', blob) = length(CAST(blob AS BLOB)) FROM out;
  ") || { rm -f "$tmp"; return 1; }
  [ "$wrote" = "1" ] || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$path"
}

# Append a flat {"command":"<cmd>"} entry to .hooks.<event> in the hooks.json at
# <path>, creating the arrays/objects as needed.
_cursor_add_event() {
  local path="$1" event="$2" cmd="$3" sql_path
  sql_path=$(sql_readfile_path "$path")
  local cmd_lit
  cmd_lit=$(printf '%s' "$cmd" | sed "s/'/''/g")
  local entry_sql="json_object('command','$cmd_lit')"

  local tmp tmp_sql
  tmp=$(mktemp "${TMPDIR:-/tmp}/agmsg.XXXXXX")
  tmp_sql=$(sql_readfile_path "$tmp")
  local wrote
  wrote=$(agmsg_sqlite_mem "
    WITH base AS (
      SELECT CASE WHEN json_extract(readfile('$sql_path'), '\$.hooks') IS NULL
                  THEN json_set(readfile('$sql_path'), '\$.hooks', json('{}'))
                  ELSE readfile('$sql_path') END AS s
    ),
    out AS (SELECT CASE
      WHEN json_extract(s, '\$.hooks.$event') IS NULL THEN
        json_set(s, '\$.hooks.$event', json_array($entry_sql))
      ELSE
        json_set(s, '\$.hooks.$event',
          (SELECT json_group_array(json(v.value)) FROM (
             SELECT value FROM json_each(json_extract(s, '\$.hooks.$event'))
             UNION ALL
             SELECT $entry_sql
           ) v)
        )
    END AS blob FROM base)
    SELECT writefile('$tmp_sql', blob) = length(CAST(blob AS BLOB)) FROM out;
  ") || { rm -f "$tmp"; return 1; }
  [ "$wrote" = "1" ] || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$path"
}

# Stamp {"version":1} when the file has no version yet, so a cursor-agent
# reading it sees the config-format version its hooks.json docs describe.
_cursor_ensure_version() {
  local path="$1" sql_path
  sql_path=$(sql_readfile_path "$path")
  local tmp tmp_sql
  tmp=$(mktemp "${TMPDIR:-/tmp}/agmsg.XXXXXX")
  tmp_sql=$(sql_readfile_path "$tmp")
  local wrote
  wrote=$(agmsg_sqlite_mem "
    WITH src AS (SELECT readfile('$sql_path') AS j),
    out AS (SELECT CASE WHEN json_extract(src.j, '\$.version') IS NULL
                        THEN json_set(src.j, '\$.version', 1)
                        ELSE src.j END AS blob FROM src)
    SELECT writefile('$tmp_sql', blob) = length(CAST(blob AS BLOB)) FROM out;
  ") || { rm -f "$tmp"; return 1; }
  [ "$wrote" = "1" ] || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$path"
}

agmsg_delivery_apply() {
  local type="$1"
  local project="$2"
  local mode="$3"

  local hooks_file
  hooks_file=$(resolve_hooks_file "$type" "$project")
  mkdir -p "$(dirname "$hooks_file")"

  # Migrate off the pre-hooks.json rule file (#131): an agmsg-owned .mdc is
  # retired now that cursor-agent has a native hooks.json; a user-authored one
  # is left in place. Runs for every mode, including off, since off must clean
  # it up too. hooks_file= no longer names this path (manifest now points at
  # hooks.json), so the old location is spelled out here.
  local old_rule="$project/.cursor/rules/agmsg.mdc"
  # Match the command line the old plug generated, not the bare skill name: a
  # user-authored .mdc that merely mentions agmsg must survive (this deletes the
  # whole file, so a loose match is destructive).
  if [ -f "$old_rule" ] && grep -qF "$SKILL_DIR/scripts/check-inbox.sh" "$old_rule" 2>/dev/null; then
    rm -f "$old_rule"
  fi

  local tmp_state
  tmp_state=$(mktemp "${TMPDIR:-/tmp}/agmsg-state.XXXXXX")
  if [ -f "$hooks_file" ]; then
    cp "$hooks_file" "$tmp_state"
  else
    printf '{}' > "$tmp_state"
  fi

  # 1) Strip any prior agmsg ownership from all four events this plug uses.
  _cursor_strip_event "$tmp_state" stop
  _cursor_strip_event "$tmp_state" sessionStart
  _cursor_strip_event "$tmp_state" sessionEnd
  _cursor_strip_event "$tmp_state" beforeSubmitPrompt

  # 2) Re-add what this mode wants. Each argument is shell-quoted with
  # _agmsg_shq (see delivery.sh's agmsg_delivery_apply_default for why: $project
  # is attacker-influenceable and a bare '...' literal breaks out of its
  # argument boundary on an embedded quote).
  case "$mode" in
    monitor)
      local ss se
      ss="$(_agmsg_shq "$SKILL_DIR/scripts/session-start.sh") $(_agmsg_shq "$type") $(_agmsg_shq "$project")"
      se="$(_agmsg_shq "$SKILL_DIR/scripts/session-end.sh") $(_agmsg_shq "$type") $(_agmsg_shq "$project")"
      _cursor_add_event "$tmp_state" sessionStart "$ss"
      _cursor_add_event "$tmp_state" sessionEnd "$se"
      # cursor-agent does not fire sessionStart on a --resume; beforeSubmitPrompt
      # (which does fire) reruns the same session-start.sh command so a resumed
      # session still gets its watcher. session-start.sh's own idempotence
      # (dedup across calls) is [subtask:C]'s concern, not this plug's.
      _cursor_add_event "$tmp_state" beforeSubmitPrompt "$ss"
      ;;
    turn)
      local st
      st="$(_agmsg_shq "$SKILL_DIR/scripts/check-inbox.sh") $(_agmsg_shq "$type") $(_agmsg_shq "$project")"
      _cursor_add_event "$tmp_state" stop "$st"
      ;;
    both)
      local ss se st
      ss="$(_agmsg_shq "$SKILL_DIR/scripts/session-start.sh") $(_agmsg_shq "$type") $(_agmsg_shq "$project")"
      se="$(_agmsg_shq "$SKILL_DIR/scripts/session-end.sh") $(_agmsg_shq "$type") $(_agmsg_shq "$project")"
      st="$(_agmsg_shq "$SKILL_DIR/scripts/check-inbox.sh") $(_agmsg_shq "$type") $(_agmsg_shq "$project")"
      _cursor_add_event "$tmp_state" sessionStart "$ss"
      _cursor_add_event "$tmp_state" sessionEnd "$se"
      _cursor_add_event "$tmp_state" beforeSubmitPrompt "$ss"
      _cursor_add_event "$tmp_state" stop "$st"
      ;;
    off)
      : # already stripped
      ;;
    *)
      rm -f "$tmp_state"
      echo "Unknown mode: $mode (use monitor|turn|both|off)" >&2
      return 1
      ;;
  esac

  _cursor_ensure_version "$tmp_state"
  prune_empty_hooks_file "$tmp_state"

  mv "$tmp_state" "$hooks_file"
}

# cursor's default status parser can't reuse agmsg_delivery_status_default: that
# reads the nested claude/codex `.hooks.<Event>[].hooks[].command` shape and
# PascalCase event names, so against cursor's flat lowerCamel file it always
# reads zero entries and reports mode: off regardless of actual state.
agmsg_delivery_status() {
  local type="$1" project="$2"
  local hf
  hf=$(resolve_hooks_file "$type" "$project")
  local has_ss=0 has_st=0
  if [ -f "$hf" ]; then
    local sql_hf
    sql_hf=$(sql_readfile_path "$hf")
    has_ss=$(agmsg_sqlite_mem "
      SELECT EXISTS(
        SELECT 1 FROM json_each(json_extract(readfile('$sql_hf'), '\$.hooks.sessionStart')) AS s
        WHERE instr(json_extract(s.value, '\$.command'), '$_CURSOR_OWNED_PREFIX') > 0
      );" 2>/dev/null || echo 0)
    has_st=$(agmsg_sqlite_mem "
      SELECT EXISTS(
        SELECT 1 FROM json_each(json_extract(readfile('$sql_hf'), '\$.hooks.stop')) AS s
        WHERE instr(json_extract(s.value, '\$.command'), '$_CURSOR_OWNED_PREFIX') > 0
      );" 2>/dev/null || echo 0)
  fi
  local mode="off"
  if [ "$has_ss" = "1" ] && [ "$has_st" = "1" ]; then mode="both"
  elif [ "$has_ss" = "1" ]; then mode="monitor"
  elif [ "$has_st" = "1" ]; then mode="turn"
  fi
  echo "mode: $mode"

  if [ -f "$hf" ]; then
    local sql_hf count
    sql_hf=$(sql_readfile_path "$hf")
    echo "hooks file: $hf"
    count=$(agmsg_sqlite_mem "SELECT json_array_length(json_extract(readfile('$sql_hf'), '\$.hooks.sessionStart'));" 2>/dev/null || echo 0)
    case "$count" in ''|*[!0-9]*) count=0 ;; esac
    echo "  sessionStart entries:       $count"
    count=$(agmsg_sqlite_mem "SELECT json_array_length(json_extract(readfile('$sql_hf'), '\$.hooks.sessionEnd'));" 2>/dev/null || echo 0)
    case "$count" in ''|*[!0-9]*) count=0 ;; esac
    echo "  sessionEnd entries:         $count"
    count=$(agmsg_sqlite_mem "SELECT json_array_length(json_extract(readfile('$sql_hf'), '\$.hooks.beforeSubmitPrompt'));" 2>/dev/null || echo 0)
    case "$count" in ''|*[!0-9]*) count=0 ;; esac
    echo "  beforeSubmitPrompt entries: $count"
    count=$(agmsg_sqlite_mem "SELECT json_array_length(json_extract(readfile('$sql_hf'), '\$.hooks.stop'));" 2>/dev/null || echo 0)
    case "$count" in ''|*[!0-9]*) count=0 ;; esac
    echo "  stop entries:               $count"
  fi
}

# New extension point (delivery.sh's do_set does not call this yet — wiring it
# in is [subtask:D]'s job). cursor-agent has no Monitor tool of its own, so
# monitor/both delivery needs a herdr pane to stream the watcher's output into;
# without one, the mode would silently do nothing observable. turn/off need
# neither, so they always pass.
agmsg_delivery_preflight() {
  local type="$1" project="$2" mode="$3"
  case "$mode" in
    monitor|both)
      if ! command -v herdr >/dev/null 2>&1; then
        echo "cursor $mode delivery needs the herdr binary on PATH (not found)" >&2
        return 1
      fi
      if [ -z "${HERDR_PANE_ID:-}" ]; then
        echo "cursor $mode delivery needs HERDR_PANE_ID set (not set)" >&2
        return 1
      fi
      ;;
  esac
  return 0
}
