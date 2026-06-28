#!/usr/bin/env bash
# Resolve an optional "role prompt" file for a spawned headless agent, so a
# cursor/codex worker boots already knowing its STANDING role (e.g. cursor =
# pre-implementation planner that returns patches, codex = review-only that
# returns findings) instead of being handed that role in every single message.
# This is the persistence layer for the role: the bridge prepends the file's
# text to each turn's prompt (cursor) or passes it as developer_instructions
# (codex) — see each type's _spawn.sh.
#
# Pure lookup: no I/O beyond one config read and a file-existence test. Echoes
# the resolved role-file path on stdout, or NOTHING. Resolution, first hit wins:
#   1. explicit  --role-file <path>      (caller passes it in as $3)
#   2. db/spawn-roles/<name>.<type>.md   (per-(actas-name, agent-type) convention)
#
# Gated by config spawn.roles_enabled (default true). With no matching file the
# function prints nothing => the caller injects no role => byte-identical to the
# pre-feature behaviour. --no-role (disable=1, $4) forces the no-op regardless of
# config or an existing file. The db/spawn-roles/ dir is NOT shipped with content
# (install.sh only mkdir's it); a user drops role files in to opt a name in.
#
# Requires the caller to have set SCRIPT_DIR (for config.sh) and SKILL_DIR (for
# the db/ root) — spawn.sh's global context provides both.
agmsg_spawn_role_resolve() {
  local name="$1" type="$2" explicit="${3:-}" disable="${4:-0}"
  [ "$disable" = 1 ] && return 0
  case "$("$SCRIPT_DIR/config.sh" get spawn.roles_enabled true 2>/dev/null || true)" in
    false|0|no|off) return 0 ;;
  esac
  local f=""
  if [ -n "$explicit" ]; then
    f="$explicit"
  else
    # Convention path only: refuse a name/type that is not a safe single path
    # segment, so a crafted name (../x, a/b) can never resolve a *.md outside
    # db/spawn-roles. Defence-in-depth — spawn.sh's join/name validation is the
    # primary guard; this keeps the resolver safe on its own too.
    case "$name" in ""|*[/\\]*|*..*) return 0 ;; esac
    case "$type" in ""|*[/\\]*|*..*) return 0 ;; esac
    f="$SKILL_DIR/db/spawn-roles/${name}.${type}.md"
  fi
  # Require a READABLE REGULAR file: not a directory (a readable dir passes -r and
  # would later fail the worker's read) and not an unreadable file (the worker
  # would start role-less while the caller believes its role is pinned).
  { [ -f "$f" ] && [ -r "$f" ]; } || return 0
  printf '%s' "$f"
}
