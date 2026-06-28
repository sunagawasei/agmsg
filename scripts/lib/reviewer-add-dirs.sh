#!/usr/bin/env bash
# Shared harvest of the Claude session's "/add-dir" READ roots from a project's
# settings (permissions.additionalDirectories in <project>/.claude/settings.json
# + settings.local.json). Used by both reviewer spawns:
#   - codex: formats each dir into a seatbelt filesystem-table read entry.
#   - cursor: advertises the dirs in the bridge prompt (cursor reads them already;
#     this just tells the model they are in scope — see cursor/_spawn.sh).
#
# Gated by a per-type config key (passed in) so each reviewer opts in
# independently. Echoes ONE original (un-resolved, ~-expanded) directory path per
# line; prints nothing when the gate is off, sqlite3 is missing, or nothing
# qualifies.
#
# Requires the caller to have sourced (as codex/_spawn.sh and cursor/_spawn.sh do,
# via spawn.sh's global context):
#   - $SCRIPT_DIR/config.sh                                  (gate lookup)
#   - lib/storage.sh: agmsg_sql_readfile_path, agmsg_sqlite_mem
#
# Validation is identical to the original inline codex logic so codex output is
# byte-unchanged: skip blank / non-existent / non-directory / quote-or-backslash-
# bearing paths (an embedded ' " or \ would break the shell/TOML the codex caller
# splices the value into) and the project root itself (already a workspace root);
# dedup by resolved path. A malformed settings file yields no roots (the sqlite
# error is swallowed) — fail-safe, never fatal.
agmsg_collect_add_dir_roots() {
  local project="$1" config_key="$2"
  case "$("$SCRIPT_DIR/config.sh" get "$config_key" false 2>/dev/null || true)" in
    true|1|yes|on) ;;
    *) return 0 ;;
  esac
  command -v sqlite3 >/dev/null 2>&1 || return 0
  local project_real; project_real="$(cd "$project" 2>/dev/null && pwd -P || printf '%s' "$project")"
  local seen=" " f sqlp d dreal
  for f in "$project/.claude/settings.json" "$project/.claude/settings.local.json"; do
    [ -f "$f" ] || continue
    sqlp="$(agmsg_sql_readfile_path "$f")"
    while IFS= read -r d; do
      [ -n "$d" ] || continue
      case "$d" in "~") d="$HOME" ;; "~/"*) d="$HOME/${d#\~/}" ;; esac
      case "$d" in *"'"*|*'"'*|*'\'*) continue ;; esac
      [ -d "$d" ] || continue                              # skip non-existent / non-directory
      dreal="$(cd "$d" 2>/dev/null && pwd -P || printf '%s' "$d")"
      [ "$dreal" = "$project_real" ] && continue           # project root already a workspace root
      case "$seen" in *" $dreal "*) continue ;; esac        # dedup by resolved path
      seen="$seen$dreal "
      printf '%s\n' "$d"
    done < <(agmsg_sqlite_mem "SELECT value FROM json_each(readfile('$sqlp'), '\$.permissions.additionalDirectories')" 2>/dev/null || true)
  done
}
