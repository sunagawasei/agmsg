#!/usr/bin/env bash
set -euo pipefail

# Usage: team.sh <team>
#        team.sh <team> --health <name> <expected-type>
# Shows team members, or asserts that one member is registered exactly once
# under <expected-type> and that its headless bridge is the live lease owner.

health_usage() {
  cat <<'EOF_USAGE'
Usage: team.sh <team>
       team.sh <team> --health <name> <expected-type>

--health applies to headless bridge owners only: claude-code, codex, cursor.
It does not describe interactive members or watchers.

Exit codes for --health:
   0  healthy: one registration of <expected-type>, bridge owns its lease
   1  team not found
   2  usage error or unknown <expected-type>
  10  type mismatch: <name> is registered, but not as <expected-type>
  11  not registered: <name> is absent from the team or has no registration
  12  bridge absent: registered, but no live bridge process was found
  13  owner unconfirmed: lease degraded or unverifiable (bridge may be alive)
  14  duplicate registration: <name> has more than one registration
  15  <expected-type> is not a headless bridge owner type
EOF_USAGE
}

case "${1:-}" in
  -h|--help) health_usage; exit 0 ;;
esac

TEAM="${1:?Usage: team.sh <team> [--health <name> <expected-type>]}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Reject team names that would escape teams/ as a path segment (#140).
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/validate.sh"
agmsg_validate_team_name "$TEAM" || exit 1

CONFIG="$SCRIPT_DIR/../teams/$TEAM/config.json"

if [ ! -f "$CONFIG" ]; then
  echo "Team not found: $TEAM"
  exit 1
fi

if [ "${2:-}" = "--health" ]; then
  [ "$#" -eq 4 ] || { health_usage >&2; exit 2; }
  HEALTH_NAME="$3"
  HEALTH_TYPE="$4"
  agmsg_validate_agent_name "$HEALTH_NAME" >/dev/null 2>&1 || { health_usage >&2; exit 2; }
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/lib/type-registry.sh"
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/lib/process-identity.sh"
  if ! agmsg_is_known_type "$HEALTH_TYPE"; then
    echo "health: unknown type '$HEALTH_TYPE'" >&2
    exit 2
  fi

  # The one place that calls into process-identity.sh. Prints a stable health
  # vocabulary (owned | absent | unconfirmed), so a change to the library's
  # state names only has to be absorbed here.
  _health_lease_state() {
    agmsg_process_identity_state "$1" "$2" "$3" || true
    case "${AGMSG_PROCESS_STATE:-}" in
      owned) echo owned ;;
      stale|legacy-dead|unverified-dead|degraded-dead) echo absent ;;
      *) echo unconfirmed ;;
    esac
  }

  # Spliced as SQL literals for the same reason as CONFIG_ESCAPED below.
  H_CONFIG_ESCAPED=$(sed "s/'/''/g" "$CONFIG")
  H_NAME_ESCAPED=$(printf '%s' "$HEALTH_NAME" | sed "s/'/''/g")
  H_TYPE_ESCAPED=$(printf '%s' "$HEALTH_TYPE" | sed "s/'/''/g")
  # total registrations, then registrations of the expected type; 0 0 when absent
  read -r H_TOTAL H_MATCH < <(sqlite3 -separator ' ' :memory: \
    "WITH regs AS (
       SELECT json_extract(r.value, '\$.type') AS type
       FROM json_each(json_extract('$H_CONFIG_ESCAPED', '\$.agents')) AS a,
            json_each(CASE
              WHEN json_type(json_extract(a.value, '\$.registrations')) = 'array' THEN json_extract(a.value, '\$.registrations')
              ELSE json_array(json_object('type', json_extract(a.value, '\$.type')))
            END) AS r
       WHERE a.key = '$H_NAME_ESCAPED'
     )
     SELECT COUNT(*), COALESCE(SUM(type = '$H_TYPE_ESCAPED'), 0) FROM regs;" | tr -d '\r')

  h_report() { echo "health: $TEAM/$HEALTH_NAME type=$HEALTH_TYPE $2"; exit "$1"; }

  [ "$H_TOTAL" -gt 0 ] || h_report 11 "not registered"
  [ "$H_MATCH" -gt 0 ] || h_report 10 "type mismatch: registered, but not as $HEALTH_TYPE"
  [ "$H_TOTAL" -le 1 ] || h_report 14 "duplicate registration: $H_TOTAL registrations"
  # Both gates: the manifest must declare headless, and the type must have a
  # bridge kind here (a headless manifest alone says nothing about pidfile names).
  H_HEADLESS="$(agmsg_type_get "$HEALTH_TYPE" headless)"
  case "$H_HEADLESS:$HEALTH_TYPE" in
    yes:claude-code|yes:codex|yes:cursor) H_KIND="$HEALTH_TYPE-bridge" ;;
    *) h_report 15 "not a headless bridge owner type" ;;
  esac
  H_STATE=$(_health_lease_state "$H_KIND" \
    "$SCRIPT_DIR/../run/$H_KIND.$TEAM.$HEALTH_NAME.pid" "$H_KIND|$TEAM.$HEALTH_NAME")
  case "$H_STATE" in
    owned) h_report 0 "bridge owns its lease" ;;
    absent) h_report 12 "bridge absent" ;;
    *) h_report 13 "owner unconfirmed: lease degraded or unverifiable (bridge may be alive)" ;;
  esac
fi

echo "Team: $TEAM"
echo ""

COUNT=0
# CONFIG_ESCAPED is spliced as a genuine SQL string literal below, NOT bound
# via `.param set`: the sqlite3 shell's dot-command tokenizer does not
# honour SQL '' escaping (unlike a real SQL statement's string literals), so
# `.param set :json '...'` silently mis-parses as soon as the config
# contains any single quote — e.g. an agent name like "al'ice" — and prints
# `.parameter`'s own usage help as if it were query output, with exit 0
# (#87 cluster; see resolve-project.sh's `resolve_team` for the same
# caveat).
CONFIG_ESCAPED=$(sed "s/'/''/g" "$CONFIG")
while IFS='	' read -r name types project registrations; do
  if [ "${registrations:-0}" -eq 0 ]; then
    # A member this machine has never registered locally: pulled with the team,
    # real, and correctly without registrations. Saying so beats printing an
    # empty type and a "?" project, which reads as damage.
    echo "  $name (remote — no local registration)"
  elif [ "$registrations" -gt 1 ]; then
    echo "  $name ($types) — $project (+$((registrations - 1)) more)"
  else
    echo "  $name ($types) — $project"
  fi
  COUNT=$((COUNT + 1))
# tr -d '\r': sqlite3.exe on Windows emits CRLF rows; the trailing CR would make
# the `registrations` field "N\r" and trip the integer test in the loop (#130).
done < <(sqlite3 -separator '	' :memory: \
  "WITH agents AS (
     SELECT
       key AS name,
       CASE
         WHEN json_type(json_extract(value, '\$.registrations')) = 'array' THEN json_extract(value, '\$.registrations')
         ELSE json_array(json_object('type', json_extract(value, '\$.type'), 'project', json_extract(value, '\$.project')))
       END AS registrations
     FROM json_each(json_extract('$CONFIG_ESCAPED', '\$.agents'))
   )
   SELECT
     name,
     group_concat(DISTINCT json_extract(r.value, '\$.type')),
     COALESCE((
       SELECT json_extract(r2.value, '\$.project')
       FROM json_each(agents.registrations) AS r2
       ORDER BY CAST(r2.key AS INTEGER) DESC
       LIMIT 1
     ), '?'),
     json_array_length(registrations)
   -- LEFT JOIN, not a comma join: a member whose registrations array is empty
   -- produces no rows from json_each, so an inner join dropped them from the
   -- listing entirely and from the count with it. That is the normal state on
   -- a machine that pulled the team rather than joining it.
   FROM agents LEFT JOIN json_each(agents.registrations) AS r
   GROUP BY name, registrations;" | tr -d '\r')

echo ""
echo "$COUNT member(s)"
