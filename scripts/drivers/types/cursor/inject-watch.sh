#!/usr/bin/env bash
set -u

# Injection watcher for cursor's monitor/both delivery modes. cursor-agent has
# no Monitor tool (unlike claude-code), so instead of streaming into a live
# tool call (watch.sh), this polls the inbox and pushes new messages straight
# into the pane via `herdr agent prompt`.
#
# Usage: inject-watch.sh <session_id> <project_path> <type> <pane_id> <instance_id> [terminal_id]
#
# Deliberately NOT built on watch.sh: watch.sh marks a line read the instant it
# writes it to stdout, so a line that fails to inject, is still queued, or was
# read-ahead into a pipe is unrecoverable once the process exits (see
# watch.sh's own header). This watcher instead does a non-consuming id-tagged
# fetch (inbox.sh --format ids) and marks a message read only AFTER `herdr
# agent prompt` reports success — the same fetch/ack split cursor-bridge.sh
# uses for headless turns.
#
# [terminal_id] (optional, sixth arg): the pane's herdr `terminal_id` at
# launch time, re-checked on every injection alongside pane_id/agent/cwd.
# herdr's pane_id names a layout SLOT, not a process -- when the process
# occupying a pane exits and a new one starts in the same slot (same
# pane_id), herdr attaches it as a NEW terminal_id (confirmed by reading
# herdr's own AgentInfo/agent_info source: pane_id is the layout::PaneId,
# terminal_id is the separately-allocated attached_terminal_id). Without this,
# a pane_id reused for an unrelated new session in the same project passes
# every other check and gets the OLD session's queued content (review
# finding: the existing pane-reuse test only covered a DIFFERENT cwd, not
# this same-cwd case). Omitted (empty) skips the check, for callers that
# cannot resolve it (HERDR_PANE_ID has no accompanying terminal id) or direct
# invocations that predate this arg.
#
# Env overrides (production defaults are fine; tests need these to avoid real
# timing/binaries):
#   AGMSG_HERDR_CMD            — herdr binary or stub (default: herdr)
#   AGMSG_INJECT_POLL_INTERVAL — seconds between polls (default: 2)
#   AGMSG_INJECT_RETRY_LIMIT   — failed-injection attempts before giving up (default: 5)

INJECT_ORIGINAL_ARGS=("$@")

SESSION_ID="${1:?Usage: inject-watch.sh <session_id> <project_path> <type> <pane_id> <instance_id> [terminal_id]}"
PROJECT="${2:?Missing project_path}"
TYPE="${3:?Missing type}"
PANE_ID="${4:?Missing pane_id}"
INSTANCE_ID="${5:?Missing instance_id}"
EXPECTED_TERMINAL_ID="${6:-}"

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_DIR="$(cd "$SELF_DIR/../../.." && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RUN_DIR="$SKILL_DIR/run"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/compat.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/storage.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/inbox-target.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/process-identity.sh"

HERDR="${AGMSG_HERDR_CMD:-herdr}"
POLL_INTERVAL="${AGMSG_INJECT_POLL_INTERVAL:-2}"
RETRY_LIMIT="${AGMSG_INJECT_RETRY_LIMIT:-5}"

mkdir -p "$RUN_DIR" 2>/dev/null || true

PIDFILE="$RUN_DIR/inject-watch.$INSTANCE_ID.pid"
JOURNAL="$RUN_DIR/inject-watch.$INSTANCE_ID.journal"
RESEND_PENDING="$RUN_DIR/inject-watch.$INSTANCE_ID.resend-pending"

# --- Explicit single-owner lifecycle: own pidfile, never watch.*.pid. ---
# session-start.sh's per-instance GC treats watch.*.pid as claude-code's
# Monitor watcher; sharing that namespace would make this process a target of
# GC/dedup logic built around watch.sh semantics it doesn't have.
#
# Single instance + verified ownership via process-identity.sh's owner/lease
# sidecar (same mechanism watch.sh and cursor-bridge.sh use), NOT a bare
# `kill -0` PID check: found in review that PID-only liveness/kill has no
# defense against PID reuse (a since-exited inject-watch's PID recycled by an
# unrelated process), and that delivery.sh's old cmdline-substring dedup
# needed `ps`, which is unavailable in some sandboxes (2 delivery set off/turn
# tests timed out there). This kind ("inject-watch") has no legacy pidfile
# format to stay compatible with, so no --legacy-needle is passed.
INJECT_OWNER_SCOPE="inject-watch|$INSTANCE_ID|$PROJECT|$TYPE"
if agmsg_process_assert_bootstrap inject-watch "$PIDFILE" "$INJECT_OWNER_SCOPE"; then
  INJECT_OWNER_SCOPE_HASH="$AGMSG_PROCESS_SCOPE_HASH"
else
  _owner_bootstrap_rc=$?
  [ "$_owner_bootstrap_rc" -eq 75 ] || exit "$_owner_bootstrap_rc"
  exec "$SCRIPT_DIR/internal/process-owner-launch.sh" \
    --kind inject-watch --pidfile "$PIDFILE" --scope "$INJECT_OWNER_SCOPE" \
    -- bash "$SELF_DIR/inject-watch.sh" "${INJECT_ORIGINAL_ARGS[@]}"
fi

READY="$RUN_DIR/inject-watch.$INSTANCE_ID.ready"
_cleanup() {
  rm -f "$READY"
  agmsg_process_cleanup_self inject-watch "$PIDFILE" "@hash:$INJECT_OWNER_SCOPE_HASH"
}
trap _cleanup EXIT
trap 'exit 0' TERM INT HUP
# Present iff a live instance has these traps installed -- same convention as
# watch.sh's own READY_FILES. The pidfile alone isn't enough evidence: it is
# written by process-owner-launch.sh's lease acquire, BEFORE this script (the
# launcher's exec target) has even started, let alone reached the traps above
# -- a signal sent in that window hits the untrapped default disposition and
# this process dies without running _cleanup, orphaning the pidfile/owner/
# lease (found in review).
: > "$READY"

# A journal left by a PREVIOUS instance (this one dead, pidfile stale) means
# its ids may already have reached the pane via a herdr call that succeeded
# right before that process died, before it could ack — loss-safe favors
# re-injecting over silently dropping them. Snapshot which ids need the
# one-time "(再送)" disclosure that this content may be a duplicate. An id this
# process later retries after an herdr failure IT observed is known
# undelivered, so its own retries never carry that disclosure (see inject_one).
if [ -f "$JOURNAL" ]; then
  cut -f1 "$JOURNAL" > "$RESEND_PENDING" 2>/dev/null || true
fi

_sqlesc() { printf '%s' "$1" | sed "s/'/''/g"; }

# storage.sh's agmsg_sqlite_mem has no -escape off (that fix, #102/#143, only
# covers agmsg_sqlite's file-backed queries): on sqlite3 >= 3.50 a char(31)
# byte embedded in a :memory: query's result renders as the two literal chars
# "^_" instead of the raw byte, which silently breaks pane_status's
# `IFS=$'\x1f' read` below (three empty/garbled fields, no error). Reuse
# storage.sh's own probed flag rather than vendoring a second probe. This is a
# local workaround, not a fix — agmsg_sqlite_mem itself should grow the same
# -escape off handling agmsg_sqlite already has.
_pane_sqlite_mem() {
  _agmsg_escape_flag >/dev/null
  # shellcheck disable=SC2086
  sqlite3 $_AGMSG_ESCAPE_FLAG :memory: "$@" | tr -d '\r'
}

# Reverse inbox.sh/check-inbox.sh's char(10)->'\n', char(9)->'\t' escaping
# (applied there so a multi-line body survives a line-oriented `read` intact)
# right before the text goes into the pane, where real newlines belong.
_unescape_nt() {
  local s="$1"
  s="${s//\\n/$'\n'}"
  s="${s//\\t/$'\t'}"
  printf '%s' "$s"
}

journal_write() {  # <id> <team> <agent> <retry>
  local id="$1" team="$2" agent="$3" retry="$4" tmp jid jteam jagent jretry
  tmp="$JOURNAL.tmp.$$"
  : > "$tmp"
  if [ -f "$JOURNAL" ]; then
    while IFS=$'\t' read -r jid jteam jagent jretry; do
      [ -n "$jid" ] && [ "$jid" != "$id" ] || continue
      printf '%s\t%s\t%s\t%s\n' "$jid" "$jteam" "$jagent" "$jretry" >> "$tmp"
    done < "$JOURNAL"
  fi
  printf '%s\t%s\t%s\t%s\n' "$id" "$team" "$agent" "$retry" >> "$tmp"
  mv "$tmp" "$JOURNAL"
}

journal_remove() {  # <id>
  local id="$1" tmp jid jteam jagent jretry
  [ -f "$JOURNAL" ] || return 0
  tmp="$JOURNAL.tmp.$$"
  : > "$tmp"
  while IFS=$'\t' read -r jid jteam jagent jretry; do
    [ -n "$jid" ] && [ "$jid" != "$id" ] || continue
    printf '%s\t%s\t%s\t%s\n' "$jid" "$jteam" "$jagent" "$jretry" >> "$tmp"
  done < "$JOURNAL"
  if [ -s "$tmp" ]; then mv "$tmp" "$JOURNAL"; else rm -f "$tmp" "$JOURNAL"; fi
}

resend_pending_consume() {  # <id>
  local id="$1" tmp
  [ -f "$RESEND_PENDING" ] || return 0
  tmp="$RESEND_PENDING.tmp.$$"
  grep -vxF "$id" "$RESEND_PENDING" > "$tmp" 2>/dev/null || true
  if [ -s "$tmp" ]; then mv "$tmp" "$RESEND_PENDING"; else rm -f "$tmp" "$RESEND_PENDING"; fi
}

resend_pending_has() {  # <id>
  [ -f "$RESEND_PENDING" ] && grep -qxF "$1" "$RESEND_PENDING" 2>/dev/null
}

journal_has() {  # <id>
  [ -f "$JOURNAL" ] && cut -f1 "$JOURNAL" 2>/dev/null | grep -qxF "$1"
}

# Resolve this session's (team, agent) the same way check-inbox.sh does, via
# the shared resolver both hooks agree on (lib/inbox-target.sh) rather than a
# bespoke copy here (see that file's header for why a copy would drift).
# Sets TARGET_AGENT / TARGET_TEAMS (comma-joined); returns 1 when unresolved.
resolve_target() {
  local whoami
  whoami="$(agmsg_inbox_target "$TYPE" "$PROJECT" "$SESSION_ID" 2>/dev/null)" || whoami=""
  [ -n "$whoami" ] || return 1
  echo "$whoami" | grep -Eq "not_joined=true|suggest=true" && return 1
  if echo "$whoami" | grep -q "multiple=true"; then
    TARGET_AGENT=$(echo "$whoami" | sed -n 's/.*agents=\([^,]*\).*/\1/p')
  else
    TARGET_AGENT=$(echo "$whoami" | sed -n 's/^agent=\([^ ]*\).*/\1/p')
  fi
  TARGET_TEAMS=$(echo "$whoami" | sed -n 's/.*teams=\([^ ]*\).*/\1/p')
  [ -n "$TARGET_AGENT" ] && [ -n "$TARGET_TEAMS" ]
}

# Query herdr for this pane's current status/agent/cwd. Echoes one of:
# idle done working blocked missing wrong-agent wrong-cwd unknown.
# Re-run right before EVERY injection attempt, not cached across a poll
# cycle's whole message batch: a pane can go from idle to working between two
# messages in the same batch, and a stale herdr binary/pane id must never be
# mistaken for a green light. Handles the response as a bare array or wrapped
# in .result/.agents — the real binary's exact top-level shape was not pinned
# down when this was written (see [subtask:D]'s question about session-start
# wiring); adjust here if it drifts.
pane_status() {
  local json esc pane_esc row st agent_name cwd terminal_id
  json="$("$HERDR" agent list 2>/dev/null)" || { printf 'missing'; return 0; }
  [ -n "$json" ] || { printf 'missing'; return 0; }
  esc="$(_sqlesc "$json")"
  pane_esc="$(_sqlesc "$PANE_ID")"
  row="$(_pane_sqlite_mem "
    WITH raw(j) AS (SELECT '$esc'),
    valid(j) AS (SELECT j FROM raw WHERE json_valid(j)),
    arr(j) AS (
      SELECT CASE
        WHEN json_type((SELECT j FROM valid)) = 'array' THEN (SELECT j FROM valid)
        WHEN json_type((SELECT j FROM valid), '\$.result') = 'array' THEN json_extract((SELECT j FROM valid), '\$.result')
        WHEN json_type((SELECT j FROM valid), '\$.agents') = 'array' THEN json_extract((SELECT j FROM valid), '\$.agents')
        ELSE NULL END
    )
    SELECT coalesce(json_extract(e.value,'\$.agent_status'),'') || char(31)
        || coalesce(json_extract(e.value,'\$.agent'),'') || char(31)
        || coalesce(json_extract(e.value,'\$.cwd'),'') || char(31)
        || coalesce(json_extract(e.value,'\$.terminal_id'),'')
    FROM arr, json_each(arr.j) AS e
    WHERE json_extract(e.value,'\$.pane_id') = '$pane_esc'
    LIMIT 1;
  " 2>/dev/null)"
  [ -n "$row" ] || { printf 'missing'; return 0; }
  IFS=$'\x1f' read -r st agent_name cwd terminal_id <<<"$row"
  [ "$agent_name" = "cursor" ] || { printf 'wrong-agent'; return 0; }
  [ "$cwd" = "$PROJECT" ] || { printf 'wrong-cwd'; return 0; }
  # pane_id names a layout slot, not a process: a pane_id reused for a new
  # session in the same project/agent/cwd would otherwise pass every check
  # above (see this file's header on terminal_id vs pane_id). Only enforced
  # when a terminal_id was captured at launch (EXPECTED_TERMINAL_ID empty ->
  # skip, e.g. HERDR_PANE_ID launches with no accompanying terminal id).
  if [ -n "$EXPECTED_TERMINAL_ID" ] && [ "$terminal_id" != "$EXPECTED_TERMINAL_ID" ]; then
    printf 'wrong-terminal'; return 0
  fi
  case "$st" in
    idle|done|working|blocked) printf '%s' "$st" ;;
    *) printf 'unknown' ;;
  esac
}

DB="$(agmsg_db_path)"

# inbox.sh --mark-read-ids swallows its own DB write failures (`|| true`,
# scripts/inbox.sh) and always exits 0, so its exit status is not evidence of
# anything. This is the only real signal that an ack actually took effect.
_msg_is_read() {  # <id>
  local v
  v="$(agmsg_sqlite "$DB" "SELECT read_at FROM messages WHERE id=$1;" 2>/dev/null)"
  [ -n "$v" ]
}

# Attempt one message's delivery. <retry> is this id's failed-attempt count
# BEFORE this call; <resend> is 1 only for a journal entry inherited at this
# process's startup (see the RESEND_PENDING snapshot above) — a disclosure
# that this content may already have reached the pane from a prior, crashed
# instance. A failure THIS process observes directly (herdr's own non-zero
# exit) is known undelivered, so its own retries never carry that disclosure.
inject_one() {
  local team="$1" agent="$2" id="$3" retry="$4" resend="$5"
  local row from body_escaped body header text

  # Re-check unread status right before acting on it — both the primary guard
  # against injecting stale content and the only guard against `both` mode's
  # stop hook winning the race and marking this id read first.
  row="$(agmsg_sqlite "$DB" "
    SELECT from_agent || char(31) || replace(replace(body, char(10), '\n'), char(9), '\t')
    FROM messages
    WHERE id=$id AND team='$(_sqlesc "$team")' AND to_agent='$(_sqlesc "$agent")' AND read_at IS NULL;
  " 2>/dev/null)"
  if [ -z "$row" ]; then
    journal_remove "$id"
    resend_pending_consume "$id"
    return 0
  fi
  IFS=$'\x1f' read -r from body_escaped <<<"$row"

  case "$(pane_status)" in
    idle|done) ;;
    *) return 0 ;;  # leave unread; retried next poll cycle, no retry-count cost
  esac

  # Record in-flight BEFORE calling herdr: a crash between a successful herdr
  # call and the ack below must still leave a trace to re-inject from (the
  # RESEND_PENDING snapshot on the next startup reads this).
  journal_write "$id" "$team" "$agent" "$retry"

  body="$(_unescape_nt "$body_escaped")"
  header="agmsg inbox: $team $from → $agent"
  [ "$resend" = 1 ] && header="$header (再送)"
  text="$header
$body"

  if "$HERDR" agent prompt "$PANE_ID" "$text" >/dev/null 2>&1; then
    "$SCRIPT_DIR/inbox.sh" "$team" "$agent" --mark-read-ids "$id" >/dev/null 2>&1
    if _msg_is_read "$id"; then
      journal_remove "$id"
      resend_pending_consume "$id"
    else
      # Content already reached the pane but the ack didn't take (DB write
      # failure inbox.sh swallowed). Leave the in-flight journal entry alone
      # (still holds the pre-attempt retry count) and mark this id for a
      # resend disclosure immediately, the same treatment RESEND_PENDING gives
      # an id inherited from a crashed prior instance -- the next attempt
      # (this process's own retry_journal, or a future restart) discloses the
      # possible duplicate instead of silently repeating it.
      printf '%s\n' "$id" >> "$RESEND_PENDING"
    fi
    return 0
  fi

  resend_pending_consume "$id"  # this process now has first-hand non-delivery proof
  retry=$((retry + 1))
  if [ "$retry" -ge "$RETRY_LIMIT" ]; then
    if printf '%s' "[inject-error] delivery to $agent failed after $RETRY_LIMIT attempt(s) (message id $id). Resend to retry." \
        | "$SCRIPT_DIR/send.sh" "$team" "$agent" "$from" --stdin --force >/dev/null 2>&1; then
      "$SCRIPT_DIR/inbox.sh" "$team" "$agent" --mark-read-ids "$id" >/dev/null 2>&1
      if _msg_is_read "$id"; then
        journal_remove "$id"
        return 0
      fi
      # Notice sent but the ack didn't take -- fall through and keep retrying
      # (below), same as a failed send: acking here would lose the message
      # even though nothing confirms the sender actually got the notice.
    fi
    # Neither branch above returned: the notice failed to send, or it sent
    # but the ack didn't take. Do NOT ack the original message in either
    # case -- losing both the content and the failure notice would be worse
    # than leaving it unread. journal_write below persists this same
    # already-at-limit retry count, so the next cycle retries this give-up
    # branch again instead of resetting to a fresh attempt count.
  fi
  journal_write "$id" "$team" "$agent" "$retry"
}

# Re-attempt everything still in-flight from a prior cycle/crash before
# fetching anything new, so a retry never starves behind a growing backlog.
# Safe to mutate $JOURNAL (via inject_one -> journal_write/journal_remove)
# while this loop's `< "$JOURNAL"` redirection is still open: a rewrite
# replaces the directory entry, but this loop keeps reading the original,
# still-open inode's remaining content undisturbed (standard rename-under-a-
# reader semantics).
retry_journal() {
  [ -f "$JOURNAL" ] || return 0
  local jid jteam jagent jretry resend
  while IFS=$'\t' read -r jid jteam jagent jretry; do
    [ -n "$jid" ] || continue
    resend=0
    resend_pending_has "$jid" && resend=1
    inject_one "$jteam" "$jagent" "$jid" "$jretry" "$resend"
  done < "$JOURNAL"
}

poll_new() {
  resolve_target || return 0
  local team rows id from body ts
  IFS=',' read -ra _teams <<< "$TARGET_TEAMS"
  for team in "${_teams[@]}"; do
    [ -n "$team" ] || continue
    rows="$("$SCRIPT_DIR/inbox.sh" "$team" "$TARGET_AGENT" --format ids 2>/dev/null)"
    [ -n "$rows" ] || continue
    while IFS=$'\x1f' read -r id from body ts; do
      [ -n "$id" ] || continue
      # A failed-but-not-yet-given-up id stays unread, so it reappears here on
      # every poll -- retry_journal (run earlier in the same cycle) is already
      # the authority for it. Without this guard, this call below always
      # passes retry=0 and overwrites retry_journal's just-incremented count,
      # so the failure count never climbs to RETRY_LIMIT (found in review: the
      # id gets stuck retrying forever instead of eventually giving up).
      journal_has "$id" && continue
      inject_one "$team" "$TARGET_AGENT" "$id" 0 0
    done <<< "$rows"
  done
}

while :; do
  retry_journal
  poll_new
  # Background + wait (not a foreground sleep) so TERM/INT are handled the
  # instant they arrive instead of waiting out the rest of the interval —
  # same idiom watch.sh uses and for the same reason (bash defers a trap
  # while a foreground sleep is running).
  sleep "$POLL_INTERVAL" &
  wait $!
done
