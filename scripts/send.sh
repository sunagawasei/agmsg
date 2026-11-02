#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   send.sh <team> <from> <to> <message> [flags]                # body as ONE quoted arg
#   send.sh <team> <from> <to> --body-file <path> [flags]       # body read from a file
#   send.sh <team> <from> <to> --body - [flags]                 # body read from stdin
#   send.sh <team> <from> <to> --stdin [flags]                  # same as --body -
#   flags: [--force] [--wait] [--timeout <sec>] [--interval <sec>]
#
# --body-file matches poke.sh, for the same reason (#507) AND to close #1101: a caller
# who learned --body-file from poke used to have send take the literal string
# "--body-file" as the message and exit zero (the flag has different meanings on the two
# adjacent commands). A positional <message> also passes through the CALLER's shell first,
# where a backtick or $( ) executes and its span silently vanishes; send bodies are longer
# and likelier to contain them. So a message that is a bare unconsumed flag (starts with
# --, and is not --body-file/--body/--stdin) is REFUSED rather than sent, and a mistyped
# flag never lands as content. Trailing newlines are stripped from a file/stdin body, as in
# poke (command-substitution semantics).
#
# --stdin keeps a large body (e.g. a headless worker's full reply) off the argv, so it
# can't hit ARG_MAX or be mangled by shell quoting — the bridge workers use it for exactly
# that.
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

die() { echo "send.sh: $*" >&2; exit 1; }

TEAM="${1:?Usage: send.sh <team> <from> <to> <message|--stdin|--body-file PATH|--body -> [--force] [--wait] [--timeout <sec>] [--interval <sec>]}"
FROM="${2:?Missing from agent}"
TO="${3:?Missing to agent}"
shift 3

# Body source: decided by the body slot (the 4th positional) alone. --body-file and
# --body consume their own argument; the remaining arguments are flags.
[ "$#" -gt 0 ] || die "Missing message body (or pass --stdin to read it from stdin)"
case "$1" in
  --stdin)
    BODY="$(cat)"
    shift
    ;;
  --body-file)
    [ "$#" -ge 2 ] || die "--body-file takes exactly one path"
    [ -r "$2" ] || die "cannot read body file: $2"
    BODY="$(cat -- "$2")"
    shift 2
    ;;
  --body)
    [ "${2:-}" = "-" ] \
      || die "--body accepts only '-' (read stdin); for a file use --body-file <path>"
    BODY="$(cat)"
    shift 2
    ;;
  --*)
    die "unrecognized option '${1}' — a message that starts with '-' must go through --body-file <path> or --body - (a bare flag is refused so a mistyped one is never sent as the message, #1101)"
    ;;
  *)
    BODY="$1"
    shift
    ;;
esac
# One rule for every body source: a body with nothing but whitespace is refused,
# so an empty heredoc or a failed pipe cannot deliver a blank message.
case "$BODY" in
  *[![:space:]]*) ;;
  *) echo "send: refusing an empty message body (nothing but whitespace)" >&2; exit 1 ;;
esac

WAIT=0
FORCE=0
TIMEOUT="${AGMSG_SEND_WAIT_TIMEOUT:-300}"
INTERVAL="${AGMSG_SEND_WAIT_INTERVAL:-2}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --stdin) shift ;;   # tolerated after the body, as before
    --force) FORCE=1; shift ;;
    --wait) WAIT=1; shift ;;
    --timeout) TIMEOUT="${2:?--timeout needs seconds}"; shift 2 ;;
    --interval) INTERVAL="${2:?--interval needs seconds}"; shift 2 ;;
    -h|--help)
      echo "Usage: send.sh <team> <from> <to> <message|--stdin|--body-file PATH|--body -> [--force] [--wait] [--timeout <sec>] [--interval <sec>]"
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
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/type-registry.sh"

# #414: TEAM becomes a path segment (teams/$TEAM/config.json) below whether or
# not --force is given, so validate it unconditionally, before any config-path
# resolution or DB init. --force bypasses roster *membership* only — it must
# never bypass team-name path safety.
agmsg_validate_team_name "$TEAM" || exit 1

# A seat that sends names its own pane if it is not named (self-name.sh): the
# 1.3.0 rule that every live seat's terminal id/name is right in any state,
# tied to the action rather than to a CLI's boot path. Best-effort, never fails
# the send; the common case is one file read.
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/self-name.sh"
agmsg_self_name_on_action "$TEAM" "$FROM" || true
# And, once and early, fix its own CLI session name by typing /rename into its own
# pane (self-rename.sh, #1081). Best-effort, never fails the send; opt out with
# AGMSG_SELF_RENAME=off (or the whole family with AGMSG_SELF_NAME=off).
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/self-rename.sh"
agmsg_self_rename_on_action "$TEAM" "$FROM" || true

agmsg_storage_load
DB="$(agmsg_db_path "$TEAM")"

# A session must not accidentally address another session's private team.
# Project teams remain unrestricted; explicit cross-team work has an opt-in
# escape hatch. "Who is calling" comes from the shared resolver
# (lib/session-team.sh): a caller with no session identity (a bridge process,
# a plain shell) is not guarded; an ambiguous one (two hosts' session ids, or
# an unusable one) may not address any session team. A headless worker resumed
# by its bridge inherits its OWN session id, so it is allowed to address the
# team its bridge serves, proven by the bridge's provenance record rather than
# by anything in the env (lib/headless-provenance.sh).
# This is an accidental-isolation guard, not an authentication boundary.
if [ "${AGMSG_ALLOW_CROSS_TEAM:-0}" != 1 ]; then
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/lib/session-team.sh"
  if agmsg_session_team_enabled; then
    SKILL_DIR="${SKILL_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/lib/instance-id.sh"
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/lib/headless-provenance.sh"
    _send_hp_ok=0
    if [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then
      _send_hp_sid="$(agmsg_session_normalize_sid claude-code "$CLAUDE_CODE_SESSION_ID")"
      if [ -n "$_send_hp_sid" ] && agmsg_headless_provenance_allows "$_send_hp_sid" "$TEAM"; then
        _send_hp_ok=1
      fi
    fi
    if [ "$_send_hp_ok" -ne 1 ]; then
      agmsg_session_resolve
      if [ "$AGMSG_SESSION_STATE" != none ]; then
        _send_class="$(agmsg_session_team_class "$TEAM")"
        _send_refuse=0
        case "$_send_class" in
          project) ;;
          session)
            if [ "$AGMSG_SESSION_STATE" != ok ] || [ "$TEAM" != "$AGMSG_SESSION_TEAM" ]; then
              _send_refuse=1
            fi
            ;;
          *) _send_refuse=1 ;;
        esac
        if [ "$_send_refuse" -eq 1 ]; then
          if [ "$AGMSG_SESSION_STATE" = ok ]; then
            echo "send: refusing cross-session send — '$TEAM' is another session's private team; this session's own team is '$AGMSG_SESSION_TEAM'. Use \$TEAM from whoami.sh; set AGMSG_ALLOW_CROSS_TEAM=1 to override." >&2
          else
            echo "send: refusing send to session team '$TEAM' — this caller's session identity is ambiguous or unusable. Use \$TEAM from whoami.sh; set AGMSG_ALLOW_CROSS_TEAM=1 to override." >&2
          fi
          exit 1
        fi
      fi
    fi
  fi
fi

# A reaped session team has no dir; a row written to its name now would land in
# the next generation of the same session id on resume. --force skips the roster
# check, so refuse a dir-less name that agmsg_session_team_class calls a session
# team. For claude-code that is s-<1-128 chars of [0-9A-Za-z_-]>, no marker needed,
# so a dir-less project team named like that (s-foo) is refused too: the s- prefix
# is reserved. Other project team names still get pre-registration sends.
if [ "$FORCE" -eq 1 ]; then
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/lib/session-team.sh"
  if agmsg_session_team_enabled \
     && [ "$(agmsg_session_team_class "$TEAM")" = session ] \
     && [ ! -d "$SCRIPT_DIR/../teams/$TEAM" ]; then
    echo "send: session team '$TEAM' has no live directory — refusing --force send to a reaped session team." >&2
    exit 1
  fi
fi

# Keep the full-schema bootstrap (registry + storage tables) for a first-ever
# command; the message write itself goes through the storage facade below.
[ -f "$DB" ] || bash "$SCRIPT_DIR/internal/init-db.sh" >/dev/null

# Unconditional (moved ahead of the --force gate below): the generic
# per-type message plug after storage_send needs this path regardless of
# --force.
TEAM_CONFIG="$SCRIPT_DIR/../teams/$TEAM/config.json"

# #355: reject a from/to that isn't registered in <team> — an unnoticed typo
# (e.g. a stray send to "dummy") used to insert successfully with exit 0,
# landing an undeliverable message and polluting history. Validation lives
# here (the front door), not in storage.sh, so other entry points (api.sh)
# can keep their own policy. --force bypasses this for intentional
# pre-registration sends (e.g. notifying a role before its own join.sh runs).
if [ "$FORCE" -ne 1 ]; then
  _agmsg_roster_check() {
    local role="$1" name="$2"
    if [ ! -f "$TEAM_CONFIG" ]; then
      echo "Error: team '$TEAM' has no registered agents — cannot send as $role '$name' (use --force to bypass)." >&2
      return 1
    fi
    local cfg_sql name_sql found roster q="'"
    cfg_sql=$(agmsg_sql_readfile_path "$TEAM_CONFIG")
    name_sql=${name//$q/$q$q}
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
if ! SENT_EVENT_ID="$(storage_send "$TEAM" "$FROM" "$TO" "$BODY")" || [ -z "$SENT_EVENT_ID" ]; then
  echo "send: could not confirm the message to $TO in team $TEAM was stored (the storage driver reported a failure; its own error, if any, is above). Check history before resending." >&2
  exit 1
fi
# The generic per-type message plug below keys on this id.
MSG_ID="$SENT_EVENT_ID"

echo "Sent to $TO in team $TEAM"

# Generic per-type "message arrived" plug (scripts/drivers/types/<type>/_message.sh):
# lets a type react to a message just sent to one of its own members, without
# this script knowing any type's name (ext-tool's dispatch launch is the
# first and, so far, only example -- see scripts/drivers/ext-tools/README.md
# for its own adapter contract). Best-effort: any failure a hook reports must
# never turn a successful send into a failed one -- the message is already
# saved by this point. A hook may not call exit.
if [ -n "${MSG_ID:-}" ] && [ -f "$TEAM_CONFIG" ]; then
  # Quote held in a variable, not written inline in the pattern (#897): a
  # literal \' replacement disagrees between bash 3.2 (keeps the backslash,
  # doubling into \'\') and bash 4+ (doubles into ''), and this scope has no
  # $q from _agmsg_roster_check's own local above to reuse.
  q="'"
  TO_SQL=${TO//$q/$q$q}
  # Every distinct type $TO is registered as, from its registrations array
  # (every other type's shape) or its bare top-level type (the shape a team
  # with no id-bearing roster still has) -- an agent registered under more
  # than one type gets the hook called once per type that defines one.
  TO_TYPES="$(agmsg_sqlite_mem "
    WITH raw(json) AS (SELECT CAST(readfile('$(agmsg_sql_readfile_path "$TEAM_CONFIG")') AS TEXT)),
    cfg(json) AS (SELECT CASE WHEN json_valid(json) THEN json END FROM raw),
    agent(a) AS (SELECT value FROM cfg, json_each(json_extract(cfg.json, '\$.agents')) WHERE key = '$TO_SQL')
    SELECT group_concat(DISTINCT t) FROM (
      SELECT json_extract(value, '\$.type') AS t
      FROM agent, json_each(json_extract(agent.a, '\$.registrations'))
      WHERE json_extract(value, '\$.type') IS NOT NULL
      UNION
      SELECT json_extract(agent.a, '\$.type') AS t
      FROM agent
      WHERE json_extract(agent.a, '\$.type') IS NOT NULL
    );
  " 2>/dev/null)"
  if [ -n "$TO_TYPES" ]; then
    IFS=',' read -ra _AGMSG_TO_TYPES <<<"$TO_TYPES"
    for _agmsg_to_type in "${_AGMSG_TO_TYPES[@]}"; do
      _agmsg_msg_type_dir="$(agmsg_type_dir "$_agmsg_to_type" 2>/dev/null || true)"
      if [ -n "$_agmsg_msg_type_dir" ] && [ -f "$_agmsg_msg_type_dir/_message.sh" ]; then
        # shellcheck disable=SC1090
        . "$_agmsg_msg_type_dir/_message.sh"
        if declare -F agmsg_type_on_message >/dev/null 2>&1; then
          _AGMSG_MSG_BODY_FILE="$(mktemp)"
          printf '%s' "$BODY" > "$_AGMSG_MSG_BODY_FILE"
          # The `|| true` is load-bearing, not style: this script runs under
          # `set -e`, and this hook is SOURCED into it, so `set -e` is still
          # active inside it -- any command failing partway through the
          # hook (not just an explicit non-zero return) would otherwise trip
          # errexit right here and kill send.sh itself, after the message
          # was already saved and "Sent to ..." already printed, skipping
          # the cleanup below too (review finding). The hook's own contract
          # is "a failure never turns a successful send into a failed one,
          # and the caller decides how this ends" -- shielding the call is
          # what keeps that true regardless of what happens inside the hook.
          agmsg_type_on_message "$TEAM" "$FROM" "$TO" "$MSG_ID" "$_AGMSG_MSG_BODY_FILE" || true
          rm -f "$_AGMSG_MSG_BODY_FILE"
        fi
      fi
    done
  fi
fi

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
             replace(replace(replace(body, char(13), ''), char(10), '\\n'), char(31), char(9247))
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
