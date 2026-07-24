#!/usr/bin/env bash
set -euo pipefail

# Usage: team-list.sh [--json] [--scope all|project] [<project_path>]
#
# Read-only, secret-free enumeration of every locally known team (ADR 0007
# family addition — koit-approved OSS interface, same review track as
# `remote status --json` / `remote pending list|abort`). Unlike
# `team.sh <team>` (shows one team's members), this lists every team this
# device knows about, across every registered project.
#
# --json: strict, versioned machine ABI:
#   { schema_version, teams: [{ name, team_id, scope, binding_state,
#     onboarding_state, promote_eligible, blocked_reason }] }
# With no --json, prints the equivalent as human-readable text.
#
# --scope (default: all) — all: every locally known team (this is the
#   authority a no-arg cloud `connect` flow must use to decide whether the
#   choice is ambiguous; narrowing to `project` must never be what that
#   decision is based on, since it could silently hide a team that would
#   otherwise make "just pick one" wrong). project: only teams that have at
#   least one agent registration for <project_path> (default: cwd) — a
#   convenience filter for a human looking at their own project, not a
#   substitute for `all` in an automated decision. Every entry's own
#   "scope" field is "project" or "other" regardless of which --scope was
#   requested, so a consumer can always tell which is which even under
#   `all`.
#
# team_id/onboarding_state/promote_eligible/blocked_reason are placeholders
# ahead of ADR 0010 (local-first onboarding / roster convergence), which is
# still in design review as of this writing:
#   - team_id: the team's remote_team_id if it has ever connected
#     (ADR 0007's remote_binding — the only server-issued team identifier
#     that exists in the CURRENT schema), else null. ADR 0010 may
#     introduce a portable team_id independent of any remote connection;
#     this field will pick that up once it exists.
#   - onboarding_state: "connected" | "not_connected" — derived only from
#     whether a remote binding exists today. ADR 0010's actual onboarding
#     state machine (promote/join/pending-acceptance/etc.) is not
#     implemented yet; this is intentionally a coarse stand-in, not a
#     preview of that enum.
#   - promote_eligible: always false. The real gate is ADR 0010's reserve
#     CAS, which does not exist yet — false is the fail-closed placeholder
#     until that authority exists; this field must never claim a team is
#     promotable before the mechanism that would make it safe is built.
#   - blocked_reason: "adr_0010_not_implemented" whenever promote_eligible
#     is false for that reason (currently: always), else null.
# None of these four are load-bearing for anything today; they exist so
# consumers can start writing against the final field set now. Revisit
# all four once ADR 0010's local config v2 lands.
#
# Bounded (never unbounded local enumeration/output): at most
# MAX_TEAMS team dirs are considered (excess are skipped with a stderr
# warning — never silently truncated without saying so), and each config.json
# read is capped at MAX_CONFIG_BYTES. A team whose config fails strict
# parsing (invalid JSON, or a duplicate key at any depth — the same #87/D4
# class of hygiene this ADR family already applies to server-supplied
# JSON, held to config.json too) is skipped with a stderr warning rather
# than guessed at.
#
# Never mutates local state, and never prints a secret or an absolute
# filesystem path (the "scope" field is a classification, "project" or
# "other" — never the literal project path itself).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEAMS_DIR="$SKILL_DIR/teams"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/resolve-project.sh"

MAX_TEAMS=10000
MAX_CONFIG_BYTES=$((10 * 1024 * 1024))

json=0
scope="all"
project_path=""
while [ $# -gt 0 ]; do
  case "$1" in
    --json) json=1; shift ;;
    --scope) scope="${2:?--scope requires a value}"; shift 2 ;;
    --scope=*) scope="${1#--scope=}"; shift ;;
    *) project_path="$1"; shift ;;
  esac
done
case "$scope" in
  all|project) ;;
  *) echo "agmsg: --scope must be 'all' or 'project'" >&2; exit 1 ;;
esac
[ -n "$project_path" ] || project_path="$(pwd)"

work_file="$(mktemp "${TMPDIR:-/tmp}/agmsg-team-list-work.XXXXXX")"
chmod 600 "$work_file"
trap 'rm -f "$work_file"' EXIT INT TERM

if [ -d "$TEAMS_DIR" ]; then
  count=0
  for d in "$TEAMS_DIR"/*/; do
    [ -d "$d" ] || continue
    cfg="${d}config.json"
    [ -f "$cfg" ] || continue
    count=$((count + 1))
    if [ "$count" -gt "$MAX_TEAMS" ]; then
      echo "agmsg: team list bounded at $MAX_TEAMS teams — some local teams were not enumerated" >&2
      break
    fi
    name="$(basename "$d")"
    printf '%s\t%s\n' "$name" "$cfg" >> "$work_file"
  done
fi

variants_file="$(mktemp "${TMPDIR:-/tmp}/agmsg-team-list-variants.XXXXXX")"
chmod 600 "$variants_file"
trap 'rm -f "$work_file" "$variants_file"' EXIT INT TERM
agmsg_project_path_variants "$project_path" > "$variants_file"

format="human"
[ "$json" -eq 1 ] && format="json"

python3 "$SCRIPT_DIR/internal/team-list.py" \
  --entries "$work_file" --variants "$variants_file" \
  --scope "$scope" --max-config-bytes "$MAX_CONFIG_BYTES" --format "$format"
