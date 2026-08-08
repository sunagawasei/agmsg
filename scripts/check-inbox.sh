#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/lib/compat.sh"

# Check inbox across all teams with cooldown. Skips if last check was < 60 seconds ago.
# Usage: check-inbox.sh <type> <project_path>

TYPE="${1:?Usage: check-inbox.sh <type> <project_path>}"
PROJECT="${2:?Missing project_path}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/storage.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/actas-lock.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/resolve-project.sh"  # agmsg_agent_pid, for instance-id derivation
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/type-registry.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/process-identity.sh"

# Some Stop-hook runtimes (codex, copilot) want an explicit JSON status object
# even when there is nothing to deliver; others (claude-code) stay silent. This
# is the type's manifest `stop_output=` (data), not a hardcoded type list.
STOP_OUTPUT="$(agmsg_type_get "$TYPE" stop_output 2>/dev/null || true)"
emit_status_json() {
  [ "$STOP_OUTPUT" = "json" ] || return 0
  printf '{\n  "continue": true,\n  "systemMessage": "%s"\n}\n' "$1"
}

# Hook runtimes that pass JSON do so on stdin. Interactive invocations such as
# Gemini's PostToolUse command may inherit a terminal stdin instead; reading
# unconditionally there blocks waiting for input. The `[ ! -t 0 ]` guard just below
# only rules out that TTY case -- a non-TTY stdin whose write end is left
# open (a hook runtime that writes the payload and then simply never closes
# the pipe) still leaves this `cat` waiting for an EOF that never arrives.
# Stop/turn hooks run synchronously, so a `cat` stuck here freezes the whole
# agent pane until the user kills it. Bound the read; a runtime that forgets
# to close its pipe still gets its payload delivered (it's already sitting in
# the command substitution buffer by the time the deadline fires), just a few
# seconds late instead of never. Fails open when `timeout` isn't on PATH
# (stock macOS) -- same unbounded read as before, no regression there. #381
INPUT=""
if [ ! -t 0 ]; then
  if command -v timeout >/dev/null 2>&1; then
    INPUT=$(timeout "${AGMSG_HOOK_STDIN_TIMEOUT:-2}" cat 2>/dev/null || true)
  else
    INPUT=$(cat 2>/dev/null || true)
  fi
fi

# Prevent infinite loop: if stop hook is already active, exit silently
if echo "$INPUT" | grep -q '"stop_hook_active"[[:space:]]*:[[:space:]]*true' 2>/dev/null; then
  exit 0
fi

# The session id is still resolved: the actas-ownership check further down
# needs it. Only the deferral that used to follow it is gone. The field name
# differs by vendor: Claude Code emits snake_case "session_id"; Grok Build (and
# Cursor) emit camelCase "sessionId". Try snake first (claude-code unaffected),
# then camel, then the GROK_SESSION_ID env Grok injects into every hook.
SESSION_ID=$(printf '%s' "$INPUT" \
  | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
  | head -1)
[ -z "$SESSION_ID" ] && SESSION_ID=$(printf '%s' "$INPUT" \
  | sed -n 's/.*"sessionId"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
  | head -1)
[ -z "$SESSION_ID" ] && SESSION_ID="${GROK_SESSION_ID:-}"
# Normalized to the per-process instance id (#93), which is the token the
# actas owner file is keyed on.
[ -n "$SESSION_ID" ] && SESSION_ID="$(agmsg_normalize_instance_id "$SESSION_ID" "$TYPE")"

# No deferral to a live watcher (#694).
#
# This used to exit here whenever a watcher process was alive for this session,
# to avoid double delivery in `both` mode. The condition was LIVENESS, and the
# failure `both` exists for preserves liveness exactly: a watcher that is alive
# and delivering nothing. So the one mode advertised as a safety net stood down
# in front of the one situation it was wanted for. On 2026-08-08 a session with
# a broken watcher was switched to `both` to recover delivery and nothing
# changed; what worked was `mode turn`, which stops the watcher, which removes
# the liveness signal, which lets this hook run.
#
# Removing it does not double-deliver, and that is measured rather than
# assumed. Both sides consume through the same state:
#
#   watcher      storage_read_cursor_consume -> inserts a `message_read` event
#                per delivered id AND advances read_cursors.local_position
#   this hook    storage_list_unread -> excludes rows at or below that cursor
#                AND rows with a `message_read` event
#
# So a message the watcher has emitted is not offered here. The remaining
# window is an interleave: this hook SELECTs, the watcher emits and consumes
# the same row, then this hook marks it read. Bounded by one poll interval, and
# the trade is explicit -- a rare duplicate line against a mode that silently
# delivered nothing at all.
#
# Deferral was an optimisation, not a correctness requirement. The read state
# is the correctness requirement, and it was already there.

# Identify agent and teams
WHOAMI=$("$SCRIPT_DIR/whoami.sh" "$PROJECT" "$TYPE")
# suggest=true means this identity is registered only under a DIFFERENT
# project, so it is not joined here -> deliver nothing (mirror not_joined).
# Without this the else-branch extracts "agents=" as the agent name.
if echo "$WHOAMI" | grep -Eq "not_joined=true|suggest=true"; then
  exit 0
fi

# Handle multiple identities: use first agent name
if echo "$WHOAMI" | grep -q "multiple=true"; then
  AGENT=$(echo "$WHOAMI" | sed -n 's/.*agents=\([^,]*\).*/\1/p')
else
  # Anchor on a leading "agent=" so "agents=" (multiple/suggest) cannot match.
  AGENT=$(echo "$WHOAMI" | sed -n 's/^agent=\([^ ]*\).*/\1/p')
fi
TEAMS=$(echo "$WHOAMI" | sed -n 's/.*teams=\([^ ]*\).*/\1/p')

if [ -z "$AGENT" ] || [ -z "$TEAMS" ]; then
  exit 0
fi

# Cooldown check. The marker is hook runtime state, not message storage, so it
# lives in the skill's run dir — independent of AGMSG_STORAGE_PATH. Keeping it
# out of the store means an overridden/sandboxed store still gets delivery even
# when the default db dir doesn't exist.
MARKER="$SKILL_DIR/run/.lastcheck-$AGENT"

if [ -f "$MARKER" ]; then
  last=$(compat_file_mtime "$MARKER")
  now=$(date +%s)
  # Prefer the new delivery.turn.check_interval; fall back to legacy
  # hook.check_interval for users who haven't migrated.
  INTERVAL=$("$SCRIPT_DIR/config.sh" get delivery.turn.check_interval "")
  [ -z "$INTERVAL" ] && INTERVAL=$("$SCRIPT_DIR/config.sh" get hook.check_interval 60)
  case "$INTERVAL" in ''|*[!0-9]*) INTERVAL=60 ;; esac
  if [ $(( now - last )) -lt "$INTERVAL" ]; then
    emit_status_json "agmsg: check skipped (cooldown)"
    exit 0
  fi
fi

mkdir -p "$SKILL_DIR/run"
touch "$MARKER"

# Check for unread messages and mark as read
agmsg_storage_load
DB="$(agmsg_db_path)"
if [ ! -f "$DB" ]; then exit 0; fi

# Messages are marked read inside this loop; the whole batch is emitted after
# it. Under `set -e` an unguarded command substitution ends the script the
# moment it fails -- and a failure while processing a LATER team lands after
# an EARLIER team's rows were already stamped read_at, before either emit
# point. Those messages are read, undelivered, and never offered again.
# Measured on 8a2fe623: first_deliveries=0 first_read=1 second_unread=1 rc=5.
#
# So a failure stops the loop instead of ending the script, and what was
# already accumulated is delivered.
#
# The failure is reported IN THE PAYLOAD, not by the exit status. The runtimes
# read stdout as control JSON only on exit 0, so a non-zero exit throws the
# delivery away -- which is what the first attempt at this fix did, on exactly
# the path that was broken. When there are messages to hand over the status is
# 0 and the text says the poll was partial; only when there is nothing to
# deliver does the status carry the failure.
OUTPUT=""
# Messages are marked read per team INSIDE this loop, but emitted only AFTER
# it. Under errexit, a failure while processing a later team (either command
# substitution below) would abort between those two points: earlier teams'
# messages end up read_at-stamped yet never delivered, and never re-offered
# (#637). So loop failures stop the loop instead of the script — whatever was
# already accumulated still reaches an emit point, teams after the failing one
# stay untouched (unread), and the failure status is re-raised on exit.
CLAIM_RC=0
IFS=',' read -ra TEAM_LIST <<< "$TEAMS"
for team in "${TEAM_LIST[@]}"; do
  storage_store_exists "$team" || continue

  # ONE guarded boundary for everything that reads or formats — and it must NOT
  # be invoked from a condition context.
  #
  # `RESULT=$(...) || _rc=$?` looks equivalent and is not. Putting the
  # substitution on the left of `||` makes the whole thing a tested command, and
  # errexit is then suppressed for what runs inside it — including the `set -e`
  # the subshell sets for itself. Measured: storage_init returned 13,
  # storage_list_unread carried on regardless, the assignment landed empty and
  # SUCCEEDED, and the `[ -n "" ] || exit 98` two lines later became the
  # subshell's status. A backend failure arrived at the caller as "this team has
  # no unread messages", and the poll reported a clean turn.
  #
  # A single non-conditional assignment with errexit lifted around it does not
  # have that property: the subshell's own `set -e` aborts at the first failure
  # and its status is what `$?` holds. The lift is two lines wide and restored
  # immediately.
  #
  # This is also why the failing operations are not listed with `|| return`
  # inside: an enumeration is short by one the next time an operation is added,
  # which is the defect this file exists to fix.
  #
  # The first attempt listed the substitutions and guarded each -- and missed
  # one (`_arr`), which is the whole failure mode this file is about: an
  # enumeration is short by one and the one it is short by is the defect. A
  # subshell with its own errexit does not need the list. Anything in here that
  # fails ends the subshell, and its status is read from `$?` below instead of
  # ending the script.
  #
  # 97 and 98 are the two ordinary reasons to skip a team, carried as statuses
  # because a subshell cannot `continue` its caller's loop.
  set +e
  RESULT=$(
    set -euo pipefail
    # Honor actas exclusivity locks. If (team, AGENT) is held by another live
    # session, that session owns that role's inbox — don't deliver here.
    # Mirrors watch.sh's per-pair filtering (#62).
    #
    # AGENT comes from whoami.sh: the first registered agent for
    # (project, type), NOT the session's in-memory actas role — the Codex
    # caveat documented in README.
    state=$(actas_lock_state "$team" "$AGENT" "${SESSION_ID:-}")
    # The leading `(` is load-bearing, not style. bash 3.2 -- which is /bin/bash
    # on macOS, and what the macOS CI jobs run -- scans `$( ... )` for its
    # closing paren without understanding `case`, so an unbalanced pattern paren
    # ends the substitution early and the `;;` that follows is a syntax error.
    # The whole file failed to parse; every check-inbox test on macOS died with
    # "syntax error near unexpected token `;;'". Balancing the paren fixes it and
    # is identical under bash 5.
    case "$state" in (other:*) exit 97 ;; esac

    # Unread via the storage facade (§2.1 storage_list_unread = events ∪ legacy),
    # JSONL parsed in one pass with sqlite's JSON funcs (no jq; cf. lib/hooks-json.sh).
    # id is kept so the mark step below targets exactly the rows shown.
    UNREAD_JSONL=$(storage_list_unread "$team" "$AGENT")
    [ -n "$UNREAD_JSONL" ] || exit 98
    _arr="[$(printf '%s' "$UNREAD_JSONL" | paste -sd, -)]"
    agmsg_sqlite ':memory:' "
      SELECT json_extract(value,'\$.from') || char(31) ||
             replace(replace(json_extract(value,'\$.body'), char(10), '\n'), char(9), '\t') || char(31) ||
             json_extract(value,'\$.at') || char(31) ||
             json_extract(value,'\$.id')
      FROM json_each('$(printf '%s' "$_arr" | sed "s/'/''/g")');
    "
  )
  _rc=$?
  set -e
  case "$_rc" in
    0)     ;;
    97|98) continue ;;
    *)     LOOP_RC=$_rc; LOOP_FAILED_TEAM="$team"; break ;;
  esac

  RESULT=$(agmsg_sqlite "$DB" "
    SELECT id || char(31) || from_agent || char(31) || replace(replace(body, char(10), '\n'), char(9), '\t') || char(31) || created_at
    FROM messages WHERE team='$team_sql' AND to_agent='$AGENT_SQL' AND read_at IS NULL
    ORDER BY created_at ASC;
  ") || { CLAIM_RC=$?; break; }
  if [ -n "$RESULT" ]; then
    COUNT=$(echo "$RESULT" | wc -l | tr -d ' ')
    OUTPUT+="$COUNT new message(s) in $team:"$'\n'
    IDS=""
    while IFS=$'\x1f' read -r id from body ts; do
      OUTPUT+="  [$ts] $from: $body"$'\n'
      case "$id" in
        ''|*[!0-9]*) ;; # defensive: never splice a non-numeric value into SQL
        *) IDS="${IDS:+$IDS,}$id" ;;
      esac
    done <<< "$RESULT"
    OUTPUT+=$'\n'
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
    # Mark as read — only the ids captured above, so a message that arrives
    # between the SELECT and this UPDATE is not marked read unseen.
    if [ -n "$IDS" ]; then
      agmsg_sqlite "$DB" "UPDATE messages SET read_at=strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id IN ($IDS);" 2>/dev/null || true
    fi
  fi
done

# No new messages. Both emit points re-raise a loop failure captured above:
# exiting 0 here would convert "a team's query failed" into "nothing to
# deliver", which is the silent half of #637.
if [ -z "$OUTPUT" ]; then
  # Both exits need the guard, not just the one that carries messages. A loop
  # that stopped on a failure before accumulating anything has not established
  # that there is nothing to deliver -- it established that it could not look.
  # Saying "no new messages" and exiting 0 there is the same lie in a quieter
  # voice, and the hook runtime treats it as a clean turn.
  [ "$LOOP_RC" -eq 0 ] || exit "$LOOP_RC"
  emit_status_json "agmsg: no new messages"
  exit "$CLAIM_RC"
fi

# New messages found
if [ -n "$OUTPUT" ]; then
  # Escape for JSON: backslash, double-quote, newlines, tabs (macOS/Linux compatible)
  ESCAPED=$(printf '%s' "$OUTPUT" | sed 's/\\/\\\\/g; s/"/\\"/g; s/	/\\t/g' | awk '{if(NR>1) printf "\\n"; printf "%s",$0}')
  cat <<ENDJSON
{
  "decision": "block",
  "reason": "$ESCAPED"
}
ENDJSON
  exit "$CLAIM_RC"
fi
