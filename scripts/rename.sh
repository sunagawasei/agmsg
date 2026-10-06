#!/usr/bin/env bash
set -euo pipefail

# Usage: rename.sh <team> <old_name> <new_name>
#
# Renames an agent in team config and updates all messages in DB.
#
# It deliberately does NOT touch run/. Those files are runtime state, not a
# record of the team: `actas.<team>__<agent>.session` (the exclusivity lock),
# `role-session.<team>__<agent>`, `ready.<team>__<agent>`, and the codex bridge's
# `codex-bridge.<team>.<agent>.*`. Thirteen files read them between them, and
# rewriting the state of a process that is currently running, because its name
# changed, is a good way to break the one thing that was working.
#
# What that leaves behind is orphans under the old name. They are harmless:
# nothing is running under that name to read them, and the next start writes
# fresh ones. The exclusivity lock is the one worth clearing by hand — a lock
# held by a name that no longer exists is the kind of thing a future reuse check
# trips over.
#
# Written down because two renames in a row produced the same leftovers and the
# second person asked whether it was intended. It is. A bulk rename would
# multiply them, and nobody should have to rediscover that it was a choice.

TEAM="${1:?Usage: rename.sh <team> <old_name> <new_name>}"
OLD_NAME="${2:?Missing old agent name}"
NEW_NAME="${3:?Missing new agent name}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/storage.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/registry-lock.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/team-config-audit.sh"
# Reject team names that would escape teams/ as a path segment (#140), and
# agent names that would misroute the $.agents.<name> JSON path below (#87
# cluster — '.', '/', '\', '"', '[', ']' all have path meaning to json1).
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/validate.sh"
agmsg_validate_team_name "$TEAM" || exit 1
agmsg_validate_agent_name "$OLD_NAME" || exit 1
agmsg_validate_agent_name "$NEW_NAME" || exit 1
TEAMS_DIR="$SCRIPT_DIR/../teams"
DB="$(agmsg_db_path)"
# Escape interpolated identifiers as SQL string literals (parity with
# send.sh): a team/agent name with a single quote would break the UPDATE.
_agmsg_sqlesc() { printf %s "$1" | sed "s/'/''/g"; }
# Computed up front: every $.agents.<name> path lookup below concatenates
# these as escaped SQL string literals (`'$.agents.' || '<escaped>'`) rather
# than splicing the raw name into the path text, so a name containing a
# single quote can't break out of the surrounding SQL statement (#87 cluster
# — join.sh's PR272 fix for the same bug class, applied here).
OLD_NAME_SQL=$(_agmsg_sqlesc "$OLD_NAME")
NEW_NAME_SQL=$(_agmsg_sqlesc "$NEW_NAME")
TEAM_CONFIG="$TEAMS_DIR/$TEAM/config.json"

if [ ! -f "$TEAM_CONFIG" ]; then
  echo "Team not found: $TEAM"
  exit 1
fi

# Serialize the read-modify-write so a concurrent join/leave/reset on this team
# can't be clobbered (#141). The team dir exists (checked above).
agmsg_lock_acquire "$TEAMS_DIR/$TEAM" || exit 1

# --- Update team config ---
CONFIG_ESCAPED=$(sed "s/'/''/g" "$TEAM_CONFIG")

# CONFIG_ESCAPED/UPDATED_ESCAPED are spliced as genuine SQL string literals
# below, NOT bound via `.param set`: the sqlite3 shell's dot-command
# tokenizer does not honour SQL '' escaping (unlike a real SQL statement's
# string literals), so `.param set :json '...'` silently mis-parses as soon
# as the JSON contains any single quote — e.g. an agent name like "al'ice"
# — corrupting :json for every query below it (#87 cluster; see
# resolve-project.sh's `resolve_team` for the same caveat).

# Check old exists
OLD_VAL=$(agmsg_sqlite_mem \
  "SELECT json_extract('$CONFIG_ESCAPED', '\$.agents.' || '$OLD_NAME_SQL');")
if [ -z "$OLD_VAL" ] || [ "$OLD_VAL" = "null" ]; then
  echo "Agent $OLD_NAME not in team $TEAM"
  exit 1
fi

# Check new doesn't exist
NEW_VAL=$(agmsg_sqlite_mem \
  "SELECT json_extract('$CONFIG_ESCAPED', '\$.agents.' || '$NEW_NAME_SQL');")
if [ -n "$NEW_VAL" ] && [ "$NEW_VAL" != "null" ]; then
  echo "Agent $NEW_NAME already exists in team $TEAM"
  exit 1
fi

# A name that left the team keeps its read cursor in the shared store. Moving
# this agent's cursor onto it would overwrite one of the two read positions, and
# either choice hides or resurrects messages, so the rename is refused instead.
if [ -f "$DB" ] \
  && [ "$(agmsg_sqlite "$DB" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='read_cursors';" | tr -d '\r')" = 1 ] \
  && [ "$(agmsg_sqlite "$DB" "SELECT COUNT(*) FROM read_cursors WHERE team='$(_agmsg_sqlesc "$TEAM")' AND agent='$NEW_NAME_SQL';" | tr -d '\r')" != 0 ]; then
  echo "Agent $NEW_NAME still has read state from an earlier registration in team $TEAM; its history is not merged." >&2
  exit 1
fi

# Rename: set new key with old value, remove old key
UPDATED=$(agmsg_sqlite_mem \
  "SELECT json_remove(json_set('$CONFIG_ESCAPED', '\$.agents.' || '$NEW_NAME_SQL', json_extract('$CONFIG_ESCAPED', '\$.agents.' || '$OLD_NAME_SQL')), '\$.agents.' || '$OLD_NAME_SQL');")

# Tombstone the old name so a later join/actas can't silently revive it (#360):
# a CLI's slash-command history can resubmit `/agmsg actas <old_name>` well
# after this rename, and without this record join.sh would happily
# re-materialize <old_name>, rolling the rename back with no warning.
# Stored as an array of {from,to,at} entries (rather than keying an object by
# the old name) so a name containing a single quote can't break the JSON path
# expression the way a raw `$.agents.$OLD_NAME` splice would — from/to are
# bound as ordinary SQL string values, never spliced into a path.
# (OLD_NAME_SQL/NEW_NAME_SQL already computed above.)
RENAMED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
UPDATED_ESCAPED=$(printf '%s' "$UPDATED" | sed "s/'/''/g")
UPDATED=$(agmsg_sqlite_mem \
  "SELECT json_set('$UPDATED_ESCAPED', '\$.renamed',
     json_insert(
       CASE WHEN json_type(json_extract('$UPDATED_ESCAPED', '\$.renamed')) = 'array'
            THEN json_extract('$UPDATED_ESCAPED', '\$.renamed') ELSE json('[]') END,
       '\$[#]', json_object('from', '$OLD_NAME_SQL', 'to', '$NEW_NAME_SQL', 'at', '$RENAMED_AT')
     )
   );")

agmsg_write_atomic "$TEAM_CONFIG" "$UPDATED"

# --- Update messages in DB ---
# Rewrite the agent name in the event log (where storage_send writes), its read
# cursors, and the legacy messages table. Without the events/cursor updates a
# rename orphans every message sent since the storage flip and resets the
# agent's read position.
if [ -f "$DB" ]; then
  TEAM_LIT=$(_agmsg_sqlesc "$TEAM")
  OLD_LIT=$(_agmsg_sqlesc "$OLD_NAME")
  NEW_LIT=$(_agmsg_sqlesc "$NEW_NAME")
  RENAME_SQL=""
  if [ "$(agmsg_sqlite "$DB" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='events';" | tr -d '\r')" = 1 ]; then
    RENAME_SQL="$RENAME_SQL
      UPDATE events SET from_agent='$NEW_LIT' WHERE team='$TEAM_LIT' AND from_agent='$OLD_LIT';
      UPDATE events SET to_agent='$NEW_LIT' WHERE team='$TEAM_LIT' AND to_agent='$OLD_LIT';
      UPDATE events SET agent='$NEW_LIT' WHERE type='message_read' AND team='$TEAM_LIT' AND agent='$OLD_LIT';"
  fi
  if [ "$(agmsg_sqlite "$DB" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='read_cursors';" | tr -d '\r')" = 1 ]; then
    RENAME_SQL="$RENAME_SQL
      UPDATE read_cursors SET agent='$NEW_LIT' WHERE team='$TEAM_LIT' AND agent='$OLD_LIT';"
  fi
  agmsg_sqlite "$DB" "BEGIN IMMEDIATE;
    UPDATE messages SET from_agent='$NEW_LIT' WHERE team='$TEAM_LIT' AND from_agent='$OLD_LIT';
    UPDATE messages SET to_agent='$NEW_LIT' WHERE team='$TEAM_LIT' AND to_agent='$OLD_LIT';
    $RENAME_SQL
    COMMIT;"
fi

agmsg_lock_release
agmsg_team_config_audit "$TEAM" rename-agent "$OLD_NAME" "$NEW_NAME" || true
echo "Renamed $OLD_NAME → $NEW_NAME in team $TEAM"
