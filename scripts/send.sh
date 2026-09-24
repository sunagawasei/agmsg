#!/usr/bin/env bash
set -euo pipefail

# Usage: send.sh <team> <from> <to> <message|--stdin> [--force] [--wait]
#                [--timeout <sec>] [--interval <sec>]
#
# Message body: pass it as the 4th positional argument (legacy), or pass --stdin
# to read the entire body from standard input. --stdin keeps a large body (e.g. a
# headless worker's full reply) off the argv, so it can't hit ARG_MAX or be
# mangled by shell quoting — the bridge workers use it for exactly that.
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
TEAM="${1:?Usage: send.sh <team> <from> <to> <message|--stdin> [--force] [--wait] [--timeout <sec>] [--interval <sec>]}"
FROM="${2:?Missing from agent}"
TO="${3:?Missing to agent}"
shift 3

# Body source: stdin when the body slot (the 4th positional) is exactly --stdin,
# otherwise that positional IS the body. Only the body slot is inspected, so a
# body that merely begins with '-' (or contains "--stdin") still works as the 4th
# arg — the sole reserved value is a 4th arg that is literally "--stdin".
if [ "${1:-}" = "--stdin" ]; then
  BODY="$(cat)"
else
  BODY="${1:?Missing message body (or pass --stdin to read it from stdin)}"
  shift
fi

WAIT=0
FORCE=0
TIMEOUT="${AGMSG_SEND_WAIT_TIMEOUT:-300}"
INTERVAL="${AGMSG_SEND_WAIT_INTERVAL:-2}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --stdin) shift ;;   # already consumed by the pre-scan above
    --force) FORCE=1; shift ;;
    --wait) WAIT=1; shift ;;
    --timeout) TIMEOUT="${2:?--timeout needs seconds}"; shift 2 ;;
    --interval) INTERVAL="${2:?--interval needs seconds}"; shift 2 ;;
    -h|--help)
      echo "Usage: send.sh <team> <from> <to> <message|--stdin> [--force] [--wait] [--timeout <sec>] [--interval <sec>]"
      exit 0 ;;
    *) echo "send: unknown option: $1" >&2; exit 1 ;;
  esac
done

case "$TIMEOUT" in ''|*[!0-9]*) echo "send: --timeout must be a whole number of seconds" >&2; exit 1 ;; esac
case "$INTERVAL" in ''|*[!0-9]*) echo "send: --interval must be a whole number of seconds" >&2; exit 1 ;; esac
[ "$INTERVAL" -gt 0 ] || INTERVAL=1

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/storage.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/validate.sh"

# #414: TEAM becomes a path segment (teams/$TEAM/config.json) below whether or
# not --force is given, so validate it unconditionally, before any config-path
# resolution or DB init. --force bypasses roster *membership* only — it must
# never bypass team-name path safety.
agmsg_validate_team_name "$TEAM" || exit 1

# A seat that sends names its own pane if it is not named. Best-effort: terminal
# discovery/naming must never make message delivery fail.
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/self-name.sh"
agmsg_self_name_on_action "$TEAM" "$FROM" || true

agmsg_storage_load
DB="$(agmsg_db_path)"

# A Claude session must not accidentally address another session's private
# team. Project teams remain unrestricted; explicit cross-team work has an
# opt-in escape hatch.
if [ "${AGMSG_ALLOW_CROSS_TEAM:-0}" != 1 ] \
    && [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then
  case "$TEAM" in
    s-*)
      # shellcheck disable=SC1091
      source "$SCRIPT_DIR/lib/session-team.sh"
      EXPECT_TEAM="$(agmsg_session_team_name 2>/dev/null || true)"
      if [ -n "$EXPECT_TEAM" ] && [ "$TEAM" != "$EXPECT_TEAM" ]; then
        echo "send: refusing cross-session send — '$TEAM' is another session's private team; this session's own team is '$EXPECT_TEAM'. Use \$TEAM from whoami.sh; set AGMSG_ALLOW_CROSS_TEAM=1 to override." >&2
        exit 1
      fi
      ;;
  esac
fi

# Keep the full-schema bootstrap (registry + storage tables) for a first-ever
# command; the message write itself goes through the storage facade below.
[ -f "$DB" ] || bash "$SCRIPT_DIR/internal/init-db.sh" >/dev/null

# #355: reject a from/to that isn't registered in <team> — an unnoticed typo
# (e.g. a stray send to "dummy") used to insert successfully with exit 0,
# landing an undeliverable message and polluting history. Validation lives
# here (the front door), not in storage.sh, so other entry points (api.sh)
# can keep their own policy. --force bypasses this for intentional
# pre-registration sends (e.g. notifying a role before its own join.sh runs).
if [ "$FORCE" -ne 1 ]; then
  TEAM_CONFIG="$SCRIPT_DIR/../teams/$TEAM/config.json"

  _agmsg_roster_check() {
    local role="$1" name="$2"
    if [ ! -f "$TEAM_CONFIG" ]; then
      echo "Error: team '$TEAM' has no registered agents — cannot send as $role '$name' (use --force to bypass)." >&2
      return 1
    fi
    local cfg_sql name_sql found roster
    cfg_sql=$(agmsg_sql_readfile_path "$TEAM_CONFIG")
    name_sql=$(printf '%s' "$name" | sed "s/'/''/g")
    found=$(agmsg_sqlite_mem "
      WITH raw(json) AS (SELECT CAST(readfile('$cfg_sql') AS TEXT)),
      cfg(json) AS (SELECT CASE WHEN json_valid(json) THEN json END FROM raw)
      SELECT value
      FROM cfg, json_each(json_extract(cfg.json, '\$.agents'))
      WHERE key = '$name_sql';
    ")
    if [ -z "$found" ]; then
      roster=$(agmsg_sqlite_mem "
        WITH raw(json) AS (SELECT CAST(readfile('$cfg_sql') AS TEXT)),
        cfg(json) AS (SELECT CASE WHEN json_valid(json) THEN json END FROM raw)
        SELECT group_concat(key, ', ')
        FROM cfg, json_each(json_extract(cfg.json, '\$.agents'));
      ")
      echo "Error: $role agent '$name' is not registered in team '$TEAM' (registered: ${roster:-none}). Use --force to bypass." >&2
      return 1
    fi
    return 0
  }

  _agmsg_roster_check "from" "$FROM" || exit 1
  _agmsg_roster_check "to" "$TO" || exit 1
fi

# Write through the storage axis (§2.1 storage_send) — the active driver now owns
# the message log (an append-only message_sent event), not a direct INSERT.
# storage_send re-inits its schema idempotently before writing, which subsumes the
# #114 concurrent first-write race the old path retried around (a process seeing
# the DB file before the table exists just creates it).
SENT_EVENT_ID="$(storage_send "$TEAM" "$FROM" "$TO" "$BODY")"

echo "Sent to $TO in team $TEAM"

[ "$WAIT" -eq 1 ] || exit 0

# --- reply wait -----------------------------------------------------------
# Block until <to> replies to <from> with a message newer than the one we sent.
# Newlines in the body are flattened to a literal "\n" so the printed reply
# stays a single line — same convention as watch.sh's stream.
T_ESC="$(printf '%s' "$TEAM" | sed "s/'/''/g")"
F_ESC="$(printf '%s' "$FROM" | sed "s/'/''/g")"
O_ESC="$(printf '%s' "$TO" | sed "s/'/''/g")"
E_ESC="$(printf '%s' "$SENT_EVENT_ID" | sed "s/'/''/g")"
SENT_ID="$(agmsg_sqlite "$DB" \
  "SELECT legacy_id FROM events WHERE type='message_sent' AND id='$E_ESC' LIMIT 1;" \
  2>/dev/null | tr -d '\r')"
case "$SENT_ID" in ''|*[!0-9]*) echo "send: could not resolve sent message id" >&2; exit 1 ;; esac
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
