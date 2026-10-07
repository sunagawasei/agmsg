#!/usr/bin/env bash
set -euo pipefail

# List (team, agent) pairs registered for a given (project_path, agent_type).
#
# Usage: identities.sh <project_path> <agent_type>
#
# Output: one "<team>\t<agent>" line per registered pair, tab-separated.
# Empty output (and exit 0) when no pair matches. Pairs are deduplicated.
#
# Used by:
#   - whoami.sh        — exact-match enumeration for identity resolution
#   - watch.sh         — subscription set for the monitor delivery mode
#   - check-inbox.sh   — turn-mode fallback enumeration

PROJECT_PATH="${1:?Usage: identities.sh <project_path> <agent_type>}"
AGENT_TYPE="${2:?Missing agent_type}"
AGENT_TYPE_SQL=$(printf '%s' "$AGENT_TYPE" | sed "s/'/''/g")

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"  # resolve-project.sh requires SKILL_DIR
TEAMS_DIR="$SCRIPT_DIR/../teams"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/resolve-project.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/storage.sh"
PROJECT_SQL_IN=$(agmsg_project_sql_in_list "$PROJECT_PATH")

[ -d "$TEAMS_DIR" ] || exit 0

# One sqlite3 process for every team: a fork per team (two before) made this
# scan scale with the number of teams that session-start runs it against.
FILES_SQL=""
n=0
for config_file in "$TEAMS_DIR"/*/config.json; do
  [ -f "$config_file" ] || continue
  n=$((n + 1))
  FILES_SQL="${FILES_SQL:+$FILES_SQL,}($n,'$(agmsg_sql_readfile_path "$config_file")')"
done
[ "$n" -gt 0 ] || exit 0

sqlite3 -separator $'\t' :memory: "
  WITH files(idx, path) AS (VALUES $FILES_SQL),
  raw(idx, json) AS (SELECT idx, CAST(readfile(path) AS TEXT) FROM files),
  cfg(idx, json) AS (SELECT idx, CASE WHEN json_valid(json) THEN json END FROM raw),
  agents AS (
    SELECT
      cfg.idx AS idx,
      json_extract(cfg.json, '\$.name') AS team,
      key AS name,
      CASE
        WHEN json_type(json_extract(value, '\$.registrations')) = 'array' THEN json_extract(value, '\$.registrations')
        ELSE json_array(json_object('type', json_extract(value, '\$.type'), 'project', json_extract(value, '\$.project')))
      END AS registrations
    FROM cfg, json_each(json_extract(cfg.json, '\$.agents'))
    WHERE json_extract(cfg.json, '\$.name') IS NOT NULL
      AND json_extract(cfg.json, '\$.name') != ''
  )
  SELECT DISTINCT team, name
  FROM agents, json_each(agents.registrations) AS r
  WHERE json_extract(r.value, '\$.project') IN ($PROJECT_SQL_IN)
    AND json_extract(r.value, '\$.type') = '$AGENT_TYPE_SQL'
  ORDER BY idx, name;
" | tr -d '\r'
