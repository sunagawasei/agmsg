#!/usr/bin/env bash
set -euo pipefail

# gc-session-orphans.sh — delete the messages of session teams that predate the
# marker/tombstone scheme (or whose dir was removed some other way).
#
# Usage: gc-session-orphans.sh [--dry-run | --apply]     (default: --dry-run)
#
# A team qualifies only when ALL hold: its name is s-<8-4-4-4-12 hex>, it has
# rows, teams/<team> does not exist, no veto applies (same set as the TTL GC),
# and every row is older than delivery.message_retention_days. The name shape
# is the only evidence of "session team" here, so a project team that was named
# s-<uuid> and whose dir is gone is deleted too: that is why this never runs
# automatically. --apply re-checks each team and deletes by team AND age.

MODE=dry-run
case "${1:-}" in
  ''|--dry-run) ;;
  --apply) MODE=apply ;;
  *) echo "usage: gc-session-orphans.sh [--dry-run | --apply]" >&2; exit 2 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RUN_DIR="$SKILL_DIR/run"
for _lib in compat actas-lock storage team-lifecycle instance-id process-identity pending-teardown inflight session-retention; do
  # shellcheck disable=SC1090
  source "$SCRIPT_DIR/lib/$_lib.sh"
done

agmsg_retention_supported || { echo "gc-session-orphans: active storage driver is not sqlite; nothing to do" >&2; exit 0; }
days="$(agmsg_retention_days)"
db="$(agmsg_db_path)"
[ -f "$db" ] || { echo "no message store"; exit 0; }

uuid_re='^s-[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$'
found=0 deleted=0
while IFS= read -r team; do
  [ -n "$team" ] || continue
  printf '%s' "$team" | grep -Eq "$uuid_re" || continue
  [ -d "$SKILL_DIR/teams/$team" ] && continue
  tl="$(agmsg_sqlesc "$team")"
  # A row newer than the window means the team is not (yet) abandoned.
  fresh="$(agmsg_sqlite "$db" "SELECT (SELECT COUNT(*) FROM events WHERE team='$tl' AND at >= strftime('%Y-%m-%dT%H:%M:%SZ','now','-$days days')) + (SELECT COUNT(*) FROM messages WHERE team='$tl' AND created_at >= strftime('%Y-%m-%dT%H:%M:%SZ','now','-$days days'));" | tr -d '\r')"
  [ "$fresh" = 0 ] || continue
  if [ "$MODE" = dry-run ]; then vmode=readonly; else vmode=; fi
  if reason="$(agmsg_retention_veto "$team" $vmode)"; then
    echo "skip   $team ($reason)"
    continue
  fi
  found=$((found + 1))
  rows="$(agmsg_retention_remaining "$team")"
  if [ "$MODE" = dry-run ]; then
    echo "would delete $team ($rows rows)"
    continue
  fi
  if out="$(agmsg_retention_reap_team "$team" strict)" && [ "$(agmsg_retention_remaining "$team")" = 0 ]; then
    deleted=$((deleted + 1)); echo "deleted $team ($rows rows)"
  elif [ -z "${out:-}" ] || [ "$out" = deleted ]; then
    echo "skip   $team (new rows arrived)"
  else
    echo "skip   $team ($out)"
  fi
done < <(agmsg_sqlite "$db" "SELECT team FROM events WHERE team LIKE 's-%' UNION SELECT team FROM messages WHERE team LIKE 's-%';" | tr -d '\r')

if [ "$MODE" = dry-run ]; then
  echo "$found team(s) would be deleted. Re-run with --apply."
else
  echo "deleted the messages of $deleted team(s)."
fi
