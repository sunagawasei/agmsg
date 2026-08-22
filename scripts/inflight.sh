#!/usr/bin/env bash
set -euo pipefail

# CLI for durable in-flight records. Sourced helpers live in lib/inflight.sh.
#
# Usage:
#   inflight.sh write <team> <name> <type> <epoch> <pid> <start-token> <consumers-file>
#   inflight.sh settle <team> <name> <epoch> <start-token>
#   inflight.sh compensate <team> <name> <epoch> <start-token>
#   inflight.sh unread-count <team> <name> <ids>
#   inflight.sh deadletter-for <team> <name>
#   inflight.sh flush-outbox <team> <name>
#   inflight.sh reap-dead
#   inflight.sh start-token <pid>

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/inflight.sh"

cmd="${1:-}"
shift || true
case "$cmd" in
  write)
    agmsg_inflight_write "$@"
    ;;
  settle)
    agmsg_inflight_settle "$@"
    ;;
  compensate)
    agmsg_inflight_compensate "$(agmsg_inflight_path "$1" "$2" "$3" "$4")"
    ;;
  unread-count)
    agmsg_inflight_unread_count "$@"
    ;;
  deadletter-for)
    agmsg_inflight_deadletter_for "$@"
    ;;
  flush-outbox)
    agmsg_inflight_outbox_flush "${1:?team required}" "${2:?name required}" || true
    ;;
  reap-dead)
    agmsg_inflight_reap_dead
    ;;
  start-token)
    agmsg_pid_start_token "${1:?pid required}"
    ;;
  *)
    echo "Usage: inflight.sh write|settle|compensate|unread-count|deadletter-for|flush-outbox|reap-dead|start-token ..." >&2
    exit 2
    ;;
esac
