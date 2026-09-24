#!/usr/bin/env bash
# validate.sh — input validation for values that become filesystem paths.
#
# Team names are used directly as path segments in the team registry
# (teams/<name>/config.json). A name containing "/", "\", or equal to "." / ".."
# can escape teams/ and create/read/move/delete files outside the agmsg state
# tree (#140). Validate at every entry point that turns a team name into a path:
# join.sh, leave.sh, team.sh, rename.sh, rename-team.sh, doctor.sh (--team).
#
# Team names are intentionally allowed to be arbitrary UTF-8 (e.g. Japanese team
# names like "testチーム" exist in the wild), so this is a deny-list of
# path-dangerous constructs, NOT an ASCII allow-list. Multibyte UTF-8 bytes are
# all >= 0x80, so they never match the control-character range below.

# Guard against double-source.
[ -n "${_AGMSG_VALIDATE_SH:-}" ] && return 0
_AGMSG_VALIDATE_SH=1

# Return 0 if <name> is safe to use as a single path segment, else print a
# specific error to stderr and return 1.
agmsg_validate_team_name() {
  local name="$1"
  if [ -z "$name" ]; then
    echo "agmsg: invalid team name: must not be empty" >&2
    return 1
  fi
  case "$name" in
    .|..)
      echo "agmsg: invalid team name '$name': '.' and '..' are not allowed" >&2
      return 1 ;;
    */*|*\\*)
      echo "agmsg: invalid team name '$name': must not contain '/' or '\\' (path traversal)" >&2
      return 1 ;;
    -*)
      # Leading '-' would be parsed as an option by downstream tools.
      echo "agmsg: invalid team name '$name': must not start with '-'" >&2
      return 1 ;;
  esac
  # Reject control characters (NUL can't reach a shell var, but newline / tab /
  # other C0 + DEL can corrupt paths, configs, and row-counting output).
  case "$name" in
    *[[:cntrl:]]*)
      echo "agmsg: invalid team name: must not contain control characters" >&2
      return 1 ;;
  esac
  return 0
}

# Agent names are interpolated into a SQLite JSON path ($.agents.<name>); '.',
# '[', ']', '"' would misroute the path (silent wrong-key / array index), and
# '/' '\' / control chars are path/format hazards. UTF-8 (>= 0x80) is fine.
agmsg_validate_agent_name() {
  local name="$1"
  if [ -z "$name" ]; then
    echo "agmsg: invalid agent name: must not be empty" >&2
    return 1
  fi
  case "$name" in
    .|..)
      echo "agmsg: invalid agent name '$name': '.' and '..' are not allowed" >&2
      return 1 ;;
    -*)
      echo "agmsg: invalid agent name '$name': must not start with '-'" >&2
      return 1 ;;
    *[./\\\"]* | *[][]* | *[[:cntrl:]]*)
      echo "agmsg: invalid agent name '$name': must not contain . / \ \" [ ] or control characters" >&2
      return 1 ;;
  esac
  return 0
}

# Message ids from the storage facade: legacy decimal strings or UUIDv7 (same
# charset rules as inbox.sh --mark-read-ids).
agmsg_validate_message_id() {
  case "$1" in
    ''|*,*|,* ) return 1 ;;
    *[!0-9a-fA-F-]*) return 1 ;;
  esac
  return 0
}

agmsg_validate_message_id_csv() {
  local csv="$1" part
  case "$csv" in ''|,*|*,|*,,*) return 1 ;; esac
  IFS=',' read -r -a _agmsg_id_parts <<< "$csv"
  for part in "${_agmsg_id_parts[@]}"; do
    agmsg_validate_message_id "$part" || return 1
  done
  return 0
}

# Build a quoted SQL IN (...) list for validated message ids.
agmsg_message_ids_sql_in_clause() {
  local csv="$1" out="" part esc
  agmsg_validate_message_id_csv "$csv" || return 1
  IFS=',' read -r -a _agmsg_id_sql_parts <<< "$csv"
  for part in "${_agmsg_id_sql_parts[@]}"; do
    esc="$(printf '%s' "$part" | sed "s/'/''/g")"
    out="${out:+$out,}'$esc'"
  done
  printf '%s' "$out"
}

# Machine inbox row: id<US>from<US>body<US>ts (body may contain US). On success
# prints four lines — id, from, body, ts — to stdout; exit status 1 if invalid.
agmsg_parse_machine_inbox_row() {
  local line="$1"
  printf '%s' "$line" | awk -v FS="\x1f" '
    NF >= 4 {
      id = $1
      from = $2
      ts = $NF
      body = $3
      for (i = 4; i < NF; i++) body = body FS $i
      print id
      print from
      print body
      print ts
      exit 0
    }
    { exit 1 }
  '
}

# Populate shell variables named by the next four arguments (id from body ts).
# Example: agmsg_parse_machine_inbox_row_assign "$line" id from body ts
agmsg_parse_machine_inbox_row_assign() {
  local line="$1" v_id="$2" v_from="$3" v_body="$4" v_ts="$5"
  local tmp n
  tmp="$(mktemp "${TMPDIR:-/tmp}/agmsg-mrow.XXXXXX")" || return 1
  if ! agmsg_parse_machine_inbox_row "$line" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  n="$(wc -l < "$tmp" | tr -d ' ')"
  if [ "$n" -lt 4 ]; then
    rm -f "$tmp"
    return 1
  fi
  # shellcheck disable=SC2162
  read -r "$v_id" < <(sed -n '1p' "$tmp")
  # shellcheck disable=SC2162
  read -r "$v_from" < <(sed -n '2p' "$tmp")
  # shellcheck disable=SC2162
  read -r "$v_ts" < <(tail -n 1 "$tmp")
  # shellcheck disable=SC2162
  read -r "$v_body" < <(sed -n '3,$p' "$tmp" | sed '$d')
  rm -f "$tmp"
  return 0
}
