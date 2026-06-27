#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   inbox.sh <team> <agent_id> [--quiet]
#       Show unread messages and mark them as read (default / hook path).
#       --quiet: only output if there are unread messages.
#   inbox.sh <team> <agent_id> --format ids
#       Machine mode: print unread as `id<US>from<US>body<US>created_at` lines
#       (US = char 31) and DO NOT mark anything read. Lets a headless bridge
#       fetch the work-list, run the agent, and mark read only on success — so a
#       failed/timed-out turn never silently consumes a message.
#   inbox.sh <team> <agent_id> --mark-read-ids <id[,id...]>
#       Mark ONLY the listed message ids read (no display). The ack half of the
#       machine path; ids are validated to digits/commas before the UPDATE.

TEAM="${1:?Usage: inbox.sh <team> <agent_id> [--quiet | --format ids | --mark-read-ids <ids>]}"
AGENT="${2:?Missing agent_id}"
shift 2

QUIET=false
FORMAT=human          # human | ids
MARK_IDS=""           # non-empty → ack mode (mark only these ids read)
while [ "$#" -gt 0 ]; do
  case "$1" in
    --quiet) QUIET=true; shift ;;
    --format) FORMAT="${2:?--format needs a value (human|ids)}"; shift 2 ;;
    --mark-read-ids) MARK_IDS="${2:?--mark-read-ids needs a comma-separated id list}"; shift 2 ;;
    *) echo "inbox: unknown option: $1" >&2; exit 1 ;;
  esac
done
case "$FORMAT" in human|ids) ;; *) echo "inbox: --format must be 'human' or 'ids'" >&2; exit 1 ;; esac

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/storage.sh"
DB="$(agmsg_db_path)"

sql_escape() { printf '%s' "$1" | sed "s/'/''/g"; }
T_ESC="$(sql_escape "$TEAM")"
A_ESC="$(sql_escape "$AGENT")"

# --- ack mode: mark only the listed ids read, then exit -----------------------
if [ -n "$MARK_IDS" ]; then
  case "$MARK_IDS" in
    *[!0-9,]* | ,* | *, | *,,*)
      echo "inbox: --mark-read-ids must be a comma-separated list of message ids" >&2
      exit 1 ;;
  esac
  [ -f "$DB" ] || exit 0
  agmsg_sqlite "$DB" "
    UPDATE messages SET read_at=strftime('%Y-%m-%dT%H:%M:%SZ','now')
    WHERE team='$T_ESC' AND to_agent='$A_ESC' AND read_at IS NULL
      AND id IN ($MARK_IDS);
  " 2>/dev/null || true
  exit 0
fi

if [ ! -f "$DB" ]; then
  if [ "$QUIET" = true ] || [ "$FORMAT" = ids ]; then exit 0; fi
  echo "No messages (DB not initialized)"
  exit 0
fi

# --- machine mode: id-tagged unread, never marked read ------------------------
if [ "$FORMAT" = ids ]; then
  # id<US>from<US>body<US>created_at, one record per line. Body newlines/tabs are
  # escaped (as in human mode) so each message stays a single line for the reader.
  agmsg_sqlite "$DB" "
    SELECT id || char(31) || from_agent || char(31)
        || replace(replace(body, char(10), '\n'), char(9), '\t') || char(31) || created_at
    FROM messages WHERE team='$T_ESC' AND to_agent='$A_ESC' AND read_at IS NULL
    ORDER BY id ASC;
  "
  exit 0
fi

# Get unread messages — escape newlines/tabs in body to keep one record per line
UNREAD=$(agmsg_sqlite "$DB" "
  SELECT from_agent || char(31) || replace(replace(body, char(10), '\n'), char(9), '\t') || char(31) || created_at
  FROM messages WHERE team='$T_ESC' AND to_agent='$A_ESC' AND read_at IS NULL
  ORDER BY created_at ASC;
")

if [ -z "$UNREAD" ]; then
  if [ "$QUIET" = true ]; then exit 0; fi
  echo "No new messages."
  exit 0
fi

# Display
COUNT=$(echo "$UNREAD" | wc -l | tr -d ' ')
echo "$COUNT new message(s):"
echo ""
while IFS=$'\x1f' read -r from body ts; do
  echo "  [$ts] $from: $body"
done <<< "$UNREAD"
echo ""

# Mark as read (non-fatal — may fail in sandboxed environments)
agmsg_sqlite "$DB" "UPDATE messages SET read_at=strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE team='$T_ESC' AND to_agent='$A_ESC' AND read_at IS NULL;" 2>/dev/null || true
