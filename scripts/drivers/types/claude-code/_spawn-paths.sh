#!/usr/bin/env bash
# claude-code spawn plug: JSON/permission-rule quoting and write-path validation.
# Sourced by _spawn.sh after its constants and libs; do not source standalone.

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

agmsg_claude_escape_permission_glob() {
  local path="$1" out="" rest="$path" char
  while [ -n "$rest" ]; do
    char="${rest:0:1}"
    rest="${rest#?}"
    case "$char" in
      \\) out="${out}\\\\" ;;
      '[') out="${out}\\[" ;;
      ']') out="${out}\\]" ;;
      '*') out="${out}\\*" ;;
      '?') out="${out}\\?" ;;
      *) out="${out}${char}" ;;
    esac
  done
  printf '%s' "$out"
}

agmsg_claude_permission_path() {
  local path="$1"
  case "$path" in
    /*)
      while [ "${path#/}" != "$path" ]; do path="${path#/}"; done
      while [ -n "$path" ] && [ "${path%/}" != "$path" ]; do
        path="${path%/}"
      done
      path="$(agmsg_claude_escape_permission_glob "$path")"
      printf '//%s' "$path"
      ;;
    *)
      printf '%s' "$(agmsg_claude_escape_permission_glob "$path")"
      ;;
  esac
}

agmsg_claude_tool_rule() {
  local tool="$1" path="$2" permission_path
  permission_path="$(agmsg_claude_permission_path "$path")" || return 1
  if [ "$permission_path" = // ]; then
    printf '%s(//**)' "$tool"
  else
    printf '%s(%s/**)' "$tool" "$permission_path"
  fi
}

agmsg_claude_exact_tool_rule() {
  local tool="$1" path="$2" permission_path
  permission_path="$(agmsg_claude_permission_path "$path")" || return 1
  printf '%s(%s)' "$tool" "$permission_path"
}

agmsg_claude_physical_path() {
  local path="$1" physical
  if type agmsg_canonical_path >/dev/null 2>&1 \
    && physical="$(agmsg_canonical_path "$path")" \
    && [ -n "$physical" ]; then
    printf '%s' "$physical"
  else
    printf '%s' "$path"
  fi
}

agmsg_claude_path_in_list() {
  local needle="$1" candidate
  shift
  for candidate in "$@"; do
    [ "$candidate" = "$needle" ] && return 0
  done
  return 1
}

agmsg_claude_create_exclusive_file() {
  local path="$1" content="$2"
  (
    umask 077
    set -o noclobber
    printf '%s\n' "$content" > "$path"
  ) 2>/dev/null
}

# Writable roots the sandbox grants to a Claude worker. Shared by the settings
# renderer and the reviewer guard so both see the same set. Filled into a global
# array (not printed) so a path containing a newline stays one element.
AGMSG_CLAUDE_WRITE_ROOTS=()
agmsg_claude_set_write_roots() {
  local storage_dir="$1" child_tmp="$2" scratch="$3"
  AGMSG_CLAUDE_WRITE_ROOTS=(
    "$storage_dir" "$SKILL_DIR/teams" "$SKILL_DIR/run"
    "$child_tmp" "/tmp" "$scratch"
  )
}

# Resolve a path component by component: symlinks (including ones met after a
# `..`) are followed and `..` pops the already-resolved prefix. Components that
# do not exist yet are kept lexically, so a root that has not been created is
# still compared at the location it will land. Fails on a symlink cycle.
agmsg_claude_resolve_path() {
  local rest="$1" cur="/" comp cand target hops=0
  case "$rest" in /*) ;; *) rest="$PWD/$rest" ;; esac
  while [ -n "$rest" ]; do
    rest="${rest#/}"
    [ -n "$rest" ] || break
    comp="${rest%%/*}"
    if [ "$comp" = "$rest" ]; then rest=""; else rest="${rest#*/}"; fi
    case "$comp" in
      ''|.) ;;
      ..) cur="${cur%/*}"; [ -n "$cur" ] || cur="/" ;;
      *)
        if [ "$cur" = / ]; then cand="/$comp"; else cand="$cur/$comp"; fi
        if [ -L "$cand" ]; then
          hops=$((hops + 1))
          [ "$hops" -le 40 ] || return 1
          # -n plus a sentinel keeps every byte of the target, including a
          # trailing newline that command substitution would strip.
          target="$(readlink -n "$cand" && printf x)" || return 1
          target="${target%x}"
          case "$target" in /*) cur="/" ;; esac
          rest="$target${rest:+/$rest}"
        else
          cur="$cand"
        fi
        ;;
    esac
  done
  printf '%s' "$cur"
}

# True when <path> or one of its existing ancestors is the same file as
# <project> (-ef compares device+inode, so letter case and symlink spellings of
# the same tree match). A sub-directory of the project mounted elsewhere (bind
# mount) is not detected.
agmsg_claude_path_inside_project() {
  local cand="$1" project="$2"
  while :; do
    [ -e "$cand" ] && [ "$cand" -ef "$project" ] && return 0
    [ "$cand" = / ] && return 1
    cand="${cand%/*}"
    [ -n "$cand" ] || cand="/"
  done
}

# Claude's sandbox lets denyWrite win over allowWrite, and a reviewer denies
# writes to the whole project. A writable root inside the project is therefore
# unwritable for the reviewer (its own db/run/teams included). Refuse that
# before any CLI call, lock or file is created. A root above the project is fine.
# Anything that cannot be resolved is refused too: containment is unproven.
agmsg_claude_reviewer_root_guard() {
  local project="$1" root phys_root skill_q project_q
  if [ ! -d "$project" ]; then
    echo "spawn: reviewer sandbox cannot verify project '$project': it is not an existing directory" >&2
    return 1
  fi
  for root in "${AGMSG_CLAUDE_WRITE_ROOTS[@]}"; do
    [ -n "$root" ] || continue
    if ! phys_root="$(agmsg_claude_resolve_path "$root")"; then
      echo "spawn: reviewer sandbox cannot resolve writable root '$root' (symlink cycle?); refusing because containment in project '$project' is unproven" >&2
      return 1
    fi
    if agmsg_claude_path_inside_project "$phys_root" "$project"; then
      skill_q="$(printf '%q' "$SKILL_DIR")"
      project_q="$(printf '%q' "$project")"
      echo "spawn: reviewer sandbox cannot use project '$project': writable root '$root' (resolves to '$phys_root') lies inside it, so the project-wide write deny would also block the worker's own state." >&2
      echo "  Move run/teams/db outside the project and leave symlinks behind (stop running workers first). Edit STATE (an existing absolute directory outside the project; mkdir -p it first); the snippet checks everything before it changes anything and can be re-run after a reported problem:" >&2
      echo "    ( set -eu" >&2
      echo "      STATE=/absolute/dir/outside/the/project; SK=$skill_q; PROJECT=$project_q" >&2
      echo '      case "$STATE" in /*) ;; *) echo "STATE must be absolute" >&2; exit 1 ;; esac' >&2
      echo '      [ -d "$STATE" ] || { echo "create STATE first (mkdir -p)" >&2; exit 1; }' >&2
      echo '      for B in "$SK" "$PROJECT"; do' >&2
      echo '        p="$(cd "$STATE" && pwd -P)"' >&2
      echo '        while :; do [ "$p" -ef "$B" ] && { echo "STATE must be outside $B" >&2; exit 1; }; [ "$p" = / ] && break; p="$(dirname "$p")"; done' >&2
      echo '      done' >&2
      echo '      for d in run teams db; do' >&2
      echo '        if [ -L "$SK/$d" ]; then [ "$(readlink "$SK/$d")" = "$STATE/$d" ] && [ -d "$STATE/$d" ] || { echo "$SK/$d: unexpected symlink" >&2; exit 1; }' >&2
      echo '        elif [ -e "$SK/$d" ]; then [ ! -e "$STATE/$d" ] || { echo "$STATE/$d already exists" >&2; exit 1; }' >&2
      echo '        else [ -d "$STATE/$d" ] || { echo "$SK/$d is missing" >&2; exit 1; }' >&2
      echo '        fi' >&2
      echo '      done' >&2
      echo '      for d in run teams db; do' >&2
      echo '        [ -L "$SK/$d" ] && continue' >&2
      echo '        [ -e "$SK/$d" ] && mv "$SK/$d" "$STATE/$d"' >&2
      echo '        ln -s "$STATE/$d" "$SK/$d"' >&2
      echo '      done )' >&2
      echo "  Alternatively set AGMSG_STORAGE_PATH=<dir outside the project>/db for the message store (run and teams still need the symlinks above)." >&2
      return 1
    fi
  done
  return 0
}
