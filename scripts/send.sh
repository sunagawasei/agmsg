#!/usr/bin/env bash
set -euo pipefail

# Usage: send.sh <team> <from> <to> <message> [--wait] [--timeout <sec>] [--interval <sec>]
#
# Without --wait: insert the message and return immediately (legacy behavior).
#
# With --wait: after sending, BLOCK in the foreground until <to> replies back to
# <from> — i.e. a message with id greater than the one just sent, from_agent=<to>,
# to_agent=<from>, same team — then print that reply and exit 0. On timeout,
# print `status=timeout` and exit 2.
#
#   Exits:
#     0  reply received (with --wait), or message sent (without --wait)
#     2  --wait timed out with no reply
#
# Why id-scoped rather than read_at-scoped (cf. watch-once.sh): the reply wait
# keys on `id > <sent_id>` + sender, so it ignores any pre-existing unread
# backlog and never collides with a monitor watcher's id-watermark cursor. The
# inbox does NOT need to be drained first, and --wait never marks anything read
# (inbox.sh remains the sole read cursor).
#
# Intended use (Claude Code): when you send a message expecting a reply and want
# the assistant to stay "busy" instead of ending its turn, pass --wait so the
# foreground block holds the turn open (and the terminal's "running" state) until
# the reply lands. Bash tool calls cap at 10 min, so keep --timeout below that
# (e.g. 540) and loop send --wait calls within a single turn for longer
# exchanges. A monitor watcher will also surface the same reply as a duplicate
# event afterward — treat the --wait result as authoritative and ignore it.

TEAM="${1:?Usage: send.sh <team> <from> <to> <message> [--wait] [--timeout <sec>] [--interval <sec>]}"
FROM="${2:?Missing from agent}"
TO="${3:?Missing to agent}"
BODY="${4:?Missing message body}"
shift 4

WAIT=0
TIMEOUT="${AGMSG_SEND_WAIT_TIMEOUT:-300}"
INTERVAL="${AGMSG_SEND_WAIT_INTERVAL:-2}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --wait) WAIT=1; shift ;;
    --timeout) TIMEOUT="${2:?--timeout needs seconds}"; shift 2 ;;
    --interval) INTERVAL="${2:?--interval needs seconds}"; shift 2 ;;
    -h|--help)
      echo "Usage: send.sh <team> <from> <to> <message> [--wait] [--timeout <sec>] [--interval <sec>]"
      exit 0 ;;
    *) echo "send: unknown option: $1" >&2; exit 1 ;;
  esac
done

case "$TIMEOUT" in ''|*[!0-9]*) echo "send: --timeout must be a whole number of seconds" >&2; exit 1 ;; esac
case "$INTERVAL" in ''|*[!0-9]*) echo "send: --interval must be a whole number of seconds" >&2; exit 1 ;; esac
[ "$INTERVAL" -gt 0 ] || INTERVAL=1

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/storage.sh"
DB="$(agmsg_db_path)"

[ -f "$DB" ] || bash "$SCRIPT_DIR/internal/init-db.sh" >/dev/null

sql_escape() { printf '%s' "$1" | sed "s/'/''/g"; }
T_ESC="$(sql_escape "$TEAM")"
F_ESC="$(sql_escape "$FROM")"
O_ESC="$(sql_escape "$TO")"
B_ESC="$(sql_escape "$BODY")"

# Insert and capture the new row id in one connection so --wait can scope the
# reply strictly to messages that arrive AFTER this send. id is INTEGER PRIMARY
# KEY AUTOINCREMENT, so last_insert_rowid() == messages.id.
INSERT="INSERT INTO messages (team, from_agent, to_agent, body) VALUES ('$T_ESC', '$F_ESC', '$O_ESC', '$B_ESC'); SELECT last_insert_rowid();"

# Retry once after ensuring the schema. Under a concurrent first-write fan-out
# (leader → N members against a fresh/override store), one process can see the
# DB file exist before the winning initializer has finished creating the table,
# so its INSERT would hit "no such table". init-db.sh is idempotent + uses the
# busy_timeout, so re-running it waits for the schema, then the INSERT lands.
# See #114.
if ! SENT_ID="$(agmsg_sqlite "$DB" "$INSERT" 2>/dev/null)"; then
  bash "$SCRIPT_DIR/internal/init-db.sh" >/dev/null
  SENT_ID="$(agmsg_sqlite "$DB" "$INSERT")"
fi
case "$SENT_ID" in ''|*[!0-9]*) SENT_ID=0 ;; esac

echo "Sent to $TO in team $TEAM"

[ "$WAIT" -eq 1 ] || exit 0

# --- reply wait -----------------------------------------------------------
# Block until <to> replies to <from> with a message newer than the one we sent.
# Newlines in the body are flattened to a literal "\n" so the printed reply
# stays a single line — same convention as watch.sh's stream.
REPLY_WHERE="id > $SENT_ID AND team='$T_ESC' AND from_agent='$O_ESC' AND to_agent='$F_ESC'"
deadline=$(( $(date +%s) + TIMEOUT ))

while true; do
  if [ -f "$DB" ]; then
    row="$(agmsg_sqlite -separator $'\x1f' "$DB" "
      SELECT id, created_at, team, from_agent, to_agent,
             replace(replace(body, char(13), ''), char(10), '\\n')
      FROM messages
      WHERE $REPLY_WHERE
      ORDER BY id LIMIT 1;
    " 2>/dev/null || true)"
    if [ -n "$row" ]; then
      IFS=$'\x1f' read -r rid ts rteam rfrom rto rbody <<< "$row"
      printf 'status=reply id=%s\n' "$rid"
      printf '%s | %s | %s → %s | %s\n' "$ts" "$rteam" "$rfrom" "$rto" "$rbody"
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
