#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/lib/compat.sh"

# The headless cursor worker's own turns set this so this `stop` hook never
# fires INSIDE those turns -- .cursor/hooks.json resolves by --workspace, not
# cwd, so a worker turn run with --workspace <project> would otherwise trigger
# the project's own hook on every reviewer turn (misdelivery, plus injection
# into a pane that doesn't exist). See _spawn.sh / cursor-bridge.sh.
if [ -n "${AGMSG_CURSOR_BRIDGE:-}" ]; then
  exit 0
fi

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
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/inbox-target.sh"

# Some Stop-hook runtimes (codex, copilot) want an explicit JSON status object
# even when there is nothing to deliver; cursor wants a `followup_message`
# instead; others (claude-code) stay silent. This is the type's manifest
# `stop_output=` (data), not a hardcoded type list.
STOP_OUTPUT="$(agmsg_type_get "$TYPE" stop_output 2>/dev/null || true)"
emit_status_json() {
  [ "$STOP_OUTPUT" = "json" ] || return 0
  printf '{\n  "continue": true,\n  "systemMessage": "%s"\n}\n' "$1"
}

# Shared JSON-string escaping for both output shapes below (decision/block and
# followup_message). sqlite3's json_quote covers every character JSON requires
# escaping -- including CR and the rest of U+0000..U+001F, which the previous
# sed/awk pipeline passed through raw and so could emit invalid JSON for a
# message body carrying them (the runtime then drops the payload, after the rows
# were already marked read). Emits the string body WITHOUT the surrounding
# quotes: callers supply those. Falls back to the old pipeline when sqlite3 is
# unavailable, which is no worse than before.
_agmsg_json_escape() {
  local tmp out
  if command -v sqlite3 >/dev/null 2>&1; then
    tmp=$(mktemp "${TMPDIR:-/tmp}/agmsg-esc.XXXXXX")
    printf '%s' "$1" > "$tmp"
    out=$(sqlite3 :memory: \
      "SELECT substr(q, 2, length(q) - 2) FROM (SELECT json_quote(CAST(readfile('$(printf %s "$tmp" | sed "s/'/''/g")') AS TEXT)) AS q);" 2>/dev/null || true)
    rm -f "$tmp"
    if [ -n "$out" ]; then printf '%s' "$out"; return 0; fi
    # Empty body (or a sqlite failure) falls through to the pipeline below.
  fi
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/	/\\t/g' | awk '{if(NR>1) printf "\\n"; printf "%s",$0}'
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

# Defer to the monitor watcher when one is alive for this session.
# Avoids double-delivery when delivery.mode = both. The session id field name
# differs by vendor: Claude Code AND Cursor both emit top-level snake_case
# "session_id" (measured on cursor-agent 2026.09.10-fd3934a); Grok Build is the
# one that emits camelCase "sessionId". Try snake first (claude-code/cursor
# unaffected), then camel, then the GROK_SESSION_ID env Grok injects into every
# hook.
SESSION_ID=$(printf '%s' "$INPUT" \
  | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
  | head -1)
[ -z "$SESSION_ID" ] && SESSION_ID=$(printf '%s' "$INPUT" \
  | sed -n 's/.*"sessionId"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
  | head -1)
[ -z "$SESSION_ID" ] && SESSION_ID="${GROK_SESSION_ID:-}"
# Preserve the raw (pre-normalization) id for agmsg_inbox_target below -- it
# must never see the composite "<sid>.<pid>" form the watcher dedup check
# derives just below (agmsg_session_team_name_from_id / role-session records
# both key on the bare id).
SESSION_ID_RAW="$SESSION_ID"
if [ -n "$SESSION_ID" ]; then
  # The monitor watcher keys its pidfile (and its actas owner, below) on the
  # per-process instance id (#93), not the bare session_id. Normalize to the
  # same token so this Stop-hook defers to a live watcher in `both` mode instead
  # of double-delivering.
  SESSION_ID="$(agmsg_normalize_instance_id "$SESSION_ID" "$TYPE")"
  WATCH_PROJECT="$(agmsg_resolve_project "$PROJECT" "$TYPE")"
  PIDFILE="$SKILL_DIR/run/watch.$SESSION_ID.pid"
  if [ -f "$PIDFILE" ]; then
    WATCH_PID=$(cat "$PIDFILE" 2>/dev/null || true)
    # EPERM-aware liveness (_agmsg_pid_alive): a sandbox-unsignalable watcher is still alive.
    if agmsg_process_dedup_should_suppress watch "$PIDFILE" \
        "watch|$SESSION_ID|$WATCH_PROJECT|$TYPE" \
        "$SCRIPT_DIR/watch.sh" "$SESSION_ID" "$PROJECT" "$TYPE"; then
      exit 0
    fi
  fi
  # Same deference for the cursor inject watcher, which owns its own pidfile
  # instead of watch.<iid>.pid (see cursor/inject-watch.sh). Without this, both
  # paths deliver the same message: the inject watcher holds an unread id while
  # waiting for an idle pane, this Stop hook consumes it in the meantime, and
  # the pane gets it twice -- its own pre-injection read_at recheck only closes
  # the opposite ordering.
  INJECT_PIDFILE="$SKILL_DIR/run/inject-watch.$SESSION_ID.pid"
  if [ -f "$INJECT_PIDFILE" ]; then
    INJECT_PID=$(cat "$INJECT_PIDFILE" 2>/dev/null || true)
    case "$INJECT_PID" in
      ''|*[!0-9]*) ;;
      *) if _agmsg_pid_alive "$INJECT_PID"; then exit 0; fi ;;
    esac
  fi
fi

# Identify agent and teams via the shared resolver (session-team / role /
# project-team routing) instead of calling whoami.sh directly -- see
# lib/inbox-target.sh for why a bare whoami.sh call here mis-delivers to a
# same-project headless worker's identity when `multiple=true`.
WHOAMI=$(agmsg_inbox_target "$TYPE" "$PROJECT" "$SESSION_ID_RAW")
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
DB="$(agmsg_db_path)"
if [ ! -f "$DB" ]; then exit 0; fi

_agmsg_sqlesc() { printf %s "$1" | sed "s/'/''/g"; }
AGENT_SQL="$(_agmsg_sqlesc "$AGENT")"

OUTPUT=""
IFS=',' read -ra TEAM_LIST <<< "$TEAMS"
for team in "${TEAM_LIST[@]}"; do
  team_sql="$(_agmsg_sqlesc "$team")"
  # Honor actas exclusivity locks. If (team, AGENT) is currently held by
  # another live session, that session is the owner of that role's inbox —
  # don't deliver here. Mirrors the per-pair filtering watch.sh does for
  # CC sessions (#62), giving Stop-hook delivery (codex / claude-code
  # turn-mode) the same "respect peer locks" guarantee.
  #
  # Note: AGENT comes from whoami.sh, which returns the first registered
  # agent for (project, type). It is NOT the session's in-memory actas
  # role. That asymmetry is the Codex caveat documented in README — if a
  # Codex session actas'd into <name>, check-inbox is still polling
  # whatever whoami chose first, not <name>.
  state=$(actas_lock_state "$team" "$AGENT" "${SESSION_ID:-}")
  case "$state" in
    other:*) continue ;;
  esac

  RESULT=$(agmsg_sqlite "$DB" "
    SELECT id || char(31) || from_agent || char(31) || replace(replace(body, char(10), '\n'), char(9), '\t') || char(31) || created_at
    FROM messages WHERE team='$team_sql' AND to_agent='$AGENT_SQL' AND read_at IS NULL
    ORDER BY created_at ASC;
  ")
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

# No new messages
if [ -z "$OUTPUT" ]; then
  emit_status_json "agmsg: no new messages"
  exit 0
fi

# New messages found
if [ -n "$OUTPUT" ]; then
  ESCAPED=$(_agmsg_json_escape "$OUTPUT")
  if [ "$STOP_OUTPUT" = "followup" ]; then
    printf '{"followup_message":"%s"}\n' "$ESCAPED"
    exit 0
  fi
  cat <<ENDJSON
{
  "decision": "block",
  "reason": "$ESCAPED"
}
ENDJSON
  exit 0
fi
