#!/usr/bin/env bash
set -euo pipefail

# One-shot pending-message oracle for the headless claude-code bridge.
# Subscription and actas ownership are re-evaluated on every poll.

PROJECT_PATH="${1:?Usage: watch-once.sh <project_path> <agent_type> [--name <agent>] [--team <team>] [--pair <team<TAB>agent>] [--timeout <sec>] [--interval <sec>]}"
AGENT_TYPE="${2:?Missing agent_type}"
shift 2

ACTIVE_NAME=""
TEAM_FILTER=""
PAIR_FILTERS=""
TIMEOUT="${AGMSG_WATCH_ONCE_TIMEOUT:-300}"
INTERVAL="${AGMSG_WATCH_ONCE_INTERVAL:-2}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --name) ACTIVE_NAME="${2:?--name needs an agent name}"; shift 2 ;;
    --team) TEAM_FILTER="${2:?--team needs a team name}"; shift 2 ;;
    --pair) PAIR_FILTERS="${PAIR_FILTERS:+$PAIR_FILTERS$'\n'}${2:?--pair needs team<TAB>agent}"; shift 2 ;;
    --timeout) TIMEOUT="${2:?--timeout needs seconds}"; shift 2 ;;
    --interval) INTERVAL="${2:?--interval needs seconds}"; shift 2 ;;
    -h|--help)
      echo "Usage: watch-once.sh <project_path> <agent_type> [--name <agent>] [--team <team>] [--pair <team<TAB>agent>] [--timeout <sec>] [--interval <sec>]"
      exit 0 ;;
    *) echo "claude-code watch-once: unknown option: $1" >&2; exit 1 ;;
  esac
done

case "$TIMEOUT" in ''|*[!0-9]*) echo "claude-code watch-once: --timeout must be a whole number of seconds" >&2; exit 1 ;; esac
case "$INTERVAL" in ''|*[!0-9]*) echo "claude-code watch-once: --interval must be a whole number of seconds" >&2; exit 1 ;; esac
[ "$INTERVAL" -gt 0 ] || INTERVAL=1

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../../../lib/storage.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../../../lib/actas-lock.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../../../lib/resolve-project.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../../../lib/subscription.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/_delivery.sh"

PROJECT_PATH="$(agmsg_resolve_project "$PROJECT_PATH" "$AGENT_TYPE")"
DB="$(agmsg_db_path)"
deadline=$(( $(date +%s) + TIMEOUT ))

while true; do
  # Re-resolve on every poll so an actas transfer immediately removes a pair
  # from this bridge before the next pending result can wake it.
  PAIRS="$(agmsg_claude_code_eligible_pairs \
    "$PROJECT_PATH" "$AGENT_TYPE" "$TEAM_FILTER" "$ACTIVE_NAME" "$PAIR_FILTERS")" \
    || exit 1
  if [ -z "$PAIRS" ]; then
    echo "claude-code watch-once: no available subscription for project=$PROJECT_PATH type=$AGENT_TYPE name=${ACTIVE_NAME:-*} team=${TEAM_FILTER:-*}" >&2
    exit 1
  fi

  WHERE_PAIRS="$(agmsg_subscription_where "$PAIRS")"
  if [ -f "$DB" ]; then
    row="$(agmsg_sqlite -separator $'\t' "$DB" "
      SELECT COUNT(*), COALESCE(MAX(id), 0)
      FROM messages
      WHERE read_at IS NULL AND ($WHERE_PAIRS);
    " 2>/dev/null || true)"
    count="${row%%$'\t'*}"
    max_id="${row#*$'\t'}"
    case "$count" in ''|*[!0-9]*) count=0 ;; esac
    case "$max_id" in ''|*[!0-9]*) max_id=0 ;; esac
    if [ "$count" -gt 0 ]; then
      printf 'status=pending count=%s max_id=%s\n' "$count" "$max_id"
      exit 0
    fi
  fi

  now=$(date +%s)
  if [ "$now" -ge "$deadline" ]; then
    echo "status=timeout"
    exit 2
  fi
  sleep_for="$INTERVAL"
  remaining=$(( deadline - now ))
  [ "$remaining" -lt "$sleep_for" ] && sleep_for="$remaining"
  [ "$sleep_for" -gt 0 ] || sleep_for=1
  sleep "$sleep_for"
done
