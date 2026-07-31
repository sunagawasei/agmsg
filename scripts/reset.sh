#!/usr/bin/env bash
set -euo pipefail

# Usage: reset.sh [--team <team>] <project_path> <type> [agent_id] [session_id]
#
# Removes registrations for the given project/type across all teams.
# If agent_id is omitted, it is resolved from whoami.sh for the current project/type.
# If session_id is given, any actas exclusivity locks owned by that session_id
# for the touched (team, agent_id) pairs are released too — this is how `drop`
# returns the role to the pool so peer sessions can pick it up immediately
# without waiting for stale-lock GC.

RESET_POSITIONAL=()
TEAM_SCOPE=""
TEAM_SCOPE_SET=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --team)
      if [ "$#" -lt 2 ]; then
        echo "Usage: reset.sh [--team <team>] <project_path> <type> [agent_id] [session_id]" >&2
        exit 1
      fi
      if [ "$TEAM_SCOPE_SET" -ne 0 ]; then
        echo "Usage: reset.sh accepts only one --team option" >&2
        exit 1
      fi
      TEAM_SCOPE="$2"
      TEAM_SCOPE_SET=1
      shift 2
      ;;
    *)
      RESET_POSITIONAL+=("$1")
      shift
      ;;
  esac
done

if [ "${#RESET_POSITIONAL[@]}" -lt 2 ]; then
  echo "Usage: reset.sh [--team <team>] <project_path> <type> [agent_id] [session_id]" >&2
  exit 1
fi

PROJECT_PATH="${RESET_POSITIONAL[0]}"
AGENT_TYPE="${RESET_POSITIONAL[1]}"
TARGET_AGENT="${RESET_POSITIONAL[2]:-}"
SESSION_ID="${RESET_POSITIONAL[3]:-}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEAMS_DIR="$SKILL_DIR/teams"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/validate.sh"
# Validate before resolving projects or constructing a target-team path. An
# invalid scope must never turn into a broader all-team reset.
if [ "$TEAM_SCOPE_SET" -ne 0 ]; then
  agmsg_validate_team_name "$TEAM_SCOPE" || exit 1
fi
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/actas-lock.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/resolve-project.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/storage.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/registry-lock.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/team-config-audit.sh"
# Agent names that would misroute the $.agents.<name> JSON path below (#87
# cluster — '.', '/', '\', '"', '[', ']' all have path meaning to json1).
# Escape as a SQL string literal (parity with join.sh/rename.sh/leave.sh):
# concatenated into JSON paths below as `'$.agents.' || '<escaped>'` rather
# than spliced into the path text, so a single quote can't break the
# statement (#87 cluster).
_agmsg_sqlesc() { printf %s "$1" | sed "s/'/''/g"; }

SCOPED_TEAM_CONFIG=""
if [ "$TEAM_SCOPE_SET" -ne 0 ]; then
  SCOPED_TEAM_CONFIG="$TEAMS_DIR/$TEAM_SCOPE/config.json"
fi

# Resolve the session's real project root (see #92) so a drop issued from a
# subdir/worktree clears the registration on the project the session lives in.
# A scoped reset must not let an unrelated team's registration steer this path.
if [ "$TEAM_SCOPE_SET" -ne 0 ]; then
  PROJECT_PATH="$(agmsg_resolve_project "$PROJECT_PATH" "$AGENT_TYPE" "$TEAM_SCOPE")"
else
  PROJECT_PATH="$(agmsg_resolve_project "$PROJECT_PATH" "$AGENT_TYPE")"
fi
# Equivalent path spellings (#268) — a drop must remove a registration stored
# in any Windows/MSYS form, not just the exact resolved string.
PROJECT_SQL_IN=$(agmsg_project_sql_in_list "$PROJECT_PATH")
AGENT_TYPE_SQL=$(_agmsg_sqlesc "$AGENT_TYPE")

# A valid team that does not exist is a scoped no-op. In particular, do not
# fall through to global whoami resolution, which could report an identity from
# another team or turn this into an unintended all-team operation.
if [ "$TEAM_SCOPE_SET" -ne 0 ] && [ ! -f "$SCOPED_TEAM_CONFIG" ]; then
  echo "No registrations removed."
  exit 0
fi

# A drop releases the actas lock keyed under this session's per-process instance
# id (#93). The template passes a bare $CLAUDE_CODE_SESSION_ID; normalize to the
# same composite the watcher/claim used so the release matches the real owner
# token (and doesn't no-op against a bare key). Empty stays empty (lock release
# is then skipped, as before).
if [ -n "$SESSION_ID" ]; then
  SESSION_ID="$(agmsg_normalize_instance_id "$SESSION_ID" "$AGENT_TYPE")"
fi

if [ -z "$TARGET_AGENT" ]; then
  if [ "$TEAM_SCOPE_SET" -ne 0 ]; then
    SCOPED_CONFIG_SQL=$(agmsg_sql_readfile_path "$SCOPED_TEAM_CONFIG")
    SCOPED_MATCHES=$(agmsg_sqlite_mem "
      WITH raw(json) AS (SELECT CAST(readfile('$SCOPED_CONFIG_SQL') AS TEXT)),
      cfg(json) AS (SELECT CASE WHEN json_valid(json) THEN json END FROM raw),
      agents AS (
        SELECT key AS name,
          CASE
            WHEN json_type(json_extract(value, '\$.registrations')) = 'array' THEN json_extract(value, '\$.registrations')
            ELSE json_array(json_object('type', json_extract(value, '\$.type'), 'project', json_extract(value, '\$.project')))
          END AS registrations
        FROM cfg, json_each(json_extract(cfg.json, '\$.agents'))
      )
      SELECT DISTINCT name
      FROM agents, json_each(agents.registrations) AS r
      WHERE json_extract(r.value, '\$.project') IN ($PROJECT_SQL_IN)
        AND json_extract(r.value, '\$.type') = '$AGENT_TYPE_SQL'
      ORDER BY name;
    ")
    SCOPED_AGENT_COUNT=$(printf '%s\n' "$SCOPED_MATCHES" | sed '/^$/d' | wc -l | tr -d ' ')
    if [ "$SCOPED_AGENT_COUNT" -eq 1 ]; then
      TARGET_AGENT=$(printf '%s\n' "$SCOPED_MATCHES" | sed -n '1p')
    elif [ "$SCOPED_AGENT_COUNT" -gt 1 ]; then
      echo "Multiple identities match this project/type in team '$TEAM_SCOPE'. Pass an agent_id explicitly." >&2
      exit 1
    else
      echo "No registered identity found in team '$TEAM_SCOPE' for this project/type." >&2
      exit 1
    fi
  else
    WHOAMI=$(bash "$SCRIPT_DIR/whoami.sh" "$PROJECT_PATH" "$AGENT_TYPE")
    if echo "$WHOAMI" | grep -q '^agent='; then
      TARGET_AGENT=$(echo "$WHOAMI" | sed -n 's/.*agent=\([^ ]*\).*/\1/p')
    elif echo "$WHOAMI" | grep -q '^multiple=true'; then
      echo "Multiple identities match this project/type. Pass an agent_id explicitly." >&2
      exit 1
    else
      echo "No registered identity found for this project/type." >&2
      exit 1
    fi
  fi
fi

agmsg_validate_agent_name "$TARGET_AGENT" || exit 1
TARGET_AGENT_SQL=$(_agmsg_sqlesc "$TARGET_AGENT")

if [ ! -d "$TEAMS_DIR" ]; then
  echo "No team registrations found."
  exit 0
fi

REMOVED=0
TOUCHED_TEAMS=0
LOCK_FAILED=0

if [ "$TEAM_SCOPE_SET" -ne 0 ]; then
  RESET_CONFIGS=("$TEAMS_DIR/$TEAM_SCOPE/config.json")
else
  RESET_CONFIGS=("$TEAMS_DIR"/*/config.json)
fi

for TEAM_CONFIG in "${RESET_CONFIGS[@]}"; do
  [ -f "$TEAM_CONFIG" ] || continue
  TEAM_DIR="$(dirname "$TEAM_CONFIG")"
  TEAM_NAME="$(basename "$TEAM_DIR")"

  # Serialize this team's read-modify-write so a concurrent join/leave/rename on
  # the same team can't be clobbered (#141). Per team, released before moving on.
  # A lock timeout is NOT silently skipped: flag it and fail at the end, so a
  # `drop`/reset never reports success while leaving a team unprocessed.
  if ! agmsg_lock_acquire "$TEAM_DIR"; then
    echo "Warning: could not lock $TEAM_NAME, skipped" >&2
    LOCK_FAILED=1
    continue
  fi
  CONFIG_ESCAPED=$(sed "s/'/''/g" "$TEAM_CONFIG")

  # CONFIG_ESCAPED is spliced as a genuine SQL string literal below, NOT
  # bound via `.param set`: the sqlite3 shell's dot-command tokenizer does
  # not honour SQL '' escaping (unlike a real SQL statement's string
  # literals), so `.param set :json '...'` silently mis-parses as soon as
  # the config contains any single quote — e.g. an existing agent name like
  # "al'ice" — corrupting :json for every query below it (#87 cluster; see
  # resolve-project.sh's `resolve_team` for the same caveat).
  AGENT_JSON=$(agmsg_sqlite_mem \
    "SELECT json_extract('$CONFIG_ESCAPED', '\$.agents.' || '$TARGET_AGENT_SQL');")
  if [ -z "$AGENT_JSON" ] || [ "$AGENT_JSON" = "null" ]; then
    agmsg_lock_release
    continue
  fi

  AGENT_ESCAPED=$(printf '%s' "$AGENT_JSON" | sed "s/'/''/g")
  NORMALIZED=$(agmsg_sqlite_mem "
    WITH agent(a) AS (SELECT '$AGENT_ESCAPED')
    SELECT CASE
      WHEN json_type(json_extract(a, '\$.registrations')) = 'array' THEN a
      ELSE json_object(
        'registrations',
        json_array(json_object(
          'type', json_extract(a, '\$.type'),
          'project', json_extract(a, '\$.project')
        ))
      )
    END
    FROM agent;
  ")
  NORMALIZED_ESCAPED=$(printf '%s' "$NORMALIZED" | sed "s/'/''/g")

  MATCH_COUNT=$(agmsg_sqlite_mem "
    SELECT count(*)
    FROM json_each(json_extract('$NORMALIZED_ESCAPED', '\$.registrations'))
    WHERE json_extract(value, '\$.type') = '$AGENT_TYPE_SQL'
      AND json_extract(value, '\$.project') IN ($PROJECT_SQL_IN);
  ")
  if [ "$MATCH_COUNT" -eq 0 ]; then
    agmsg_lock_release
    continue
  fi

  FILTERED=$(agmsg_sqlite_mem "
    SELECT json_object(
      'registrations',
      COALESCE((
        SELECT json_group_array(json(value))
        FROM json_each(json_extract('$NORMALIZED_ESCAPED', '\$.registrations'))
        WHERE NOT (
          json_extract(value, '\$.type') = '$AGENT_TYPE_SQL'
          AND json_extract(value, '\$.project') IN ($PROJECT_SQL_IN)
        )
      ), json('[]'))
    );
  ")
  FILTERED_ESCAPED=$(printf '%s' "$FILTERED" | sed "s/'/''/g")
  REMAINING=$(agmsg_sqlite_mem "
    SELECT json_array_length(json_extract('$FILTERED_ESCAPED', '\$.registrations'));
  ")

  if [ "$REMAINING" -eq 0 ]; then
    UPDATED=$(agmsg_sqlite_mem \
      "SELECT json_remove('$CONFIG_ESCAPED', '\$.agents.' || '$TARGET_AGENT_SQL');")
  else
    UPDATED=$(agmsg_sqlite_mem \
      "SELECT json_set('$CONFIG_ESCAPED', '\$.agents.' || '$TARGET_AGENT_SQL', json('$FILTERED_ESCAPED'));")
  fi

  AGENT_COUNT=$(agmsg_sqlite_mem "
    SELECT count(*)
    FROM json_each(json_extract('$(printf '%s' "$UPDATED" | sed "s/'/''/g")', '\$.agents'));
  ")

  if [ "$AGENT_COUNT" -eq 0 ]; then
    rm -f "$TEAM_CONFIG"
    agmsg_lock_release
    rmdir "$TEAM_DIR" 2>/dev/null || true
  else
    agmsg_write_atomic "$TEAM_CONFIG" "$UPDATED"
    agmsg_lock_release
  fi

  REMOVED=$((REMOVED + MATCH_COUNT))
  TOUCHED_TEAMS=$((TOUCHED_TEAMS + 1))
  echo "Cleared $MATCH_COUNT registration(s) for $TARGET_AGENT from $TEAM_NAME"

  # Release the actas lock for this (team, agent) pair so peer sessions can
  # claim it without waiting for owner-session-end / stale GC.
  if [ -n "$SESSION_ID" ]; then
    actas_lock_release "$TEAM_NAME" "$TARGET_AGENT" "$SESSION_ID" 2>/dev/null || true
  fi

  # One logical reset may rewrite or delete several physical records, but it
  # emits exactly one best-effort audit event for this team after the final
  # successful config mutation.
  agmsg_team_config_audit "$TEAM_NAME" reset "$TARGET_AGENT" "$PROJECT_PATH" || true
done

if [ "$REMOVED" -eq 0 ]; then
  echo "No registrations removed."
else
  echo "Reset complete: removed $REMOVED registration(s) across $TOUCHED_TEAMS team(s)"
fi

# A team we couldn't lock was left unprocessed — surface that as a failure rather
# than reporting partial success.
if [ "$LOCK_FAILED" -ne 0 ]; then
  echo "Reset incomplete: one or more teams could not be locked." >&2
  exit 1
fi
