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
agmsg_storage_load
DB="$(agmsg_db_path)"

# Preserve the read-only "not initialized yet" behaviour: an inbox check must not
# create the store, so guard on the file before touching the facade.
if [ ! -f "$DB" ]; then
  if [ "$QUIET" = true ] || [ "$FORMAT" = ids ]; then exit 0; fi
  echo "No messages (DB not initialized)"
  exit 0
fi

# Unread comes from the storage facade (§2.1 storage_list_unread = the event log
# UNION the legacy messages table), as one JSONL record per line in delivery
# order. Parse it with sqlite's JSON funcs in a single pass — the repo idiom, no
# jq dependency (cf. lib/hooks-json.sh).
UNREAD_JSONL=$(storage_list_unread "$TEAM" "$AGENT")

if [ -z "$UNREAD_JSONL" ]; then
  if [ "$QUIET" = true ]; then exit 0; fi
  echo "No new messages."
  exit 0
fi

# JSONL -> JSON array -> "from \x1f body \x1f at \x1f id" rows (newlines/tabs in
# the body escaped so each message stays one display line).
_arr="[$(printf '%s' "$UNREAD_JSONL" | paste -sd, -)]"
ROWS=$(agmsg_sqlite ':memory:' "
  SELECT json_extract(value,'\$.from') || char(31) ||
         replace(replace(json_extract(value,'\$.body'), char(10), '\n'), char(9), '\t') || char(31) ||
         json_extract(value,'\$.at') || char(31) ||
         json_extract(value,'\$.id')
  FROM json_each('$(printf '%s' "$_arr" | sed "s/'/''/g")');
")

COUNT=$(printf '%s\n' "$ROWS" | wc -l | tr -d ' ')
echo "$COUNT new message(s):"
echo ""
IDS=()
while IFS=$'\x1f' read -r from body ts id; do
  [ -n "$id" ] || continue
  echo "  [$ts] $from: $body"
  IDS+=("$id")
done <<< "$ROWS"
echo ""

# Test seam: a two-file barrier that lets the race regression test land a
# message deterministically between display and mark. No-op unless set.
if [ -n "${AGMSG_TEST_MARK_BARRIER:-}" ]; then
  : > "$AGMSG_TEST_MARK_BARRIER.reached"
  _agmsg_barrier_waited=0
  while [ ! -e "$AGMSG_TEST_MARK_BARRIER.release" ]; do
    sleep 0.05
    _agmsg_barrier_waited=$((_agmsg_barrier_waited + 1))
    [ "$_agmsg_barrier_waited" -ge 200 ] && break # 10s safety cap
  done
fi

# Mark read via the storage facade (§2.1 storage_mark_read_batch): recipient-
# scoped and idempotent. For a legacy id it records a message_read event
# without mutating the legacy row (§2.4). Only the ids collected from the
# rows actually displayed above — never a blanket match — so a message that
# arrives after the SELECT above can never be marked read unseen. Non-fatal —
# may fail in sandboxed environments.
if [ "${#IDS[@]}" -gt 0 ]; then
  storage_mark_read_batch "$TEAM" "$AGENT" "${IDS[@]}" >/dev/null 2>&1 || true
fi
