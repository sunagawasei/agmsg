#!/usr/bin/env bash
set -u
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/lib/compat.sh"
WATCH_ORIGINAL_ARGS=("$@")

# Stream new agmsg messages for the current session as they arrive.
#
# Intended to be launched by Claude Code's Monitor tool from the SessionStart
# hook (`session-start.sh`), but also works standalone as `tail -f` for
# inbox: any agent runtime that can read stdout can consume it.
#
# Usage: watch.sh <session_id> <project_path> <agent_type> [active_name]
#
# Behavior:
#   - Resolves (team, agent) pairs for (project_path, agent_type) via
#     identities.sh. By default, subscribes to messages addressed to any
#     of those pairs.
#   - When [active_name] is given, narrows the subscription to only pairs
#     whose agent name matches — useful for `actas` exclusive role mode.
#   - A fresh session sets the high-water mark to the current MAX(id) at
#     startup, so the stream begins with whatever arrives after launch — no
#     replay of historical messages. The mark is persisted per session_id, so
#     a restart of this session's watcher (actas/drop/clear/self-restart)
#     resumes from the last delivered id and does not drop messages that
#     arrived during the restart gap. See #107.
#   - Polls the SQLite DB at AGMSG_WATCH_INTERVAL seconds (default 5, also
#     overridable via the delivery.monitor.poll_interval config key).
#   - Emits one line per new message:
#         <ts> | <team> | <from> → <to> | <body>
#     Newlines in body are escaped to literal "\n" so each message stays a
#     single line — easier for Monitor to deliver as one event.
#   - Writes a pidfile at ~/.agents/agmsg/run/watch.<session_id>.pid and
#     removes it on EXIT / SIGTERM / SIGINT.

# session_id is normally baked into the launch command (CLAUDE_CODE_SESSION_ID /
# GROK_SESSION_ID). An empty first arg is tolerated and resolved below (after the
# libs are sourced) rather than failing hard, so a runtime that cannot bake one
# in — notably Grok Build's `monitor` tool, where "$GROK_SESSION_ID" expands to
# empty — still starts the watcher. A literal `-` first arg is the caller-side
# sentinel for the same "no session id" case: some launcher shells re-evaluate
# the command line and DROP a quoted-but-empty argument entirely (shifting every
# later argument one slot left), so command templates pass
# "${GROK_SESSION_ID:--}" and `-` is folded into the empty-arg path here.
# project_path and agent_type are required. [--team <team>] pins the
# subscription to one team for session-team mode.
ARG_COUNT=$#
SESSION_ID="${1:-}"
[ "$SESSION_ID" = "-" ] && SESSION_ID=""
PROJECT_PATH="${2:-}"
AGENT_TYPE="${3:-}"

# Missing required args fail on STDOUT, not via ${n:?}: bash prints the :?
# message to stderr, which the monitor tool consuming this stream never
# surfaces — the launch would die invisibly. A short arg list is also how a
# shifted three-argument launch (no active_name; empty session id dropped by
# the caller shell, see above) presents, so name that cause here too.
if [ -z "$PROJECT_PATH" ] || [ -z "$AGENT_TYPE" ]; then
  echo "ERROR: watch.sh needs <session_id> <project_path> <agent_type> [active_name] [--team <team>]; got $ARG_COUNT argument(s). A caller shell may have dropped an empty session_id argument and shifted the rest. Pass the sentinel '-' (e.g. \"\${GROK_SESSION_ID:--}\") instead of an empty string."
  exit 1
fi
shift 3

# [active_name] narrows the subscription to one agent name (actas mode).
# [--team <team>] pins the subscription to a single team — required by
# session-team mode, where one project dir is registered into many s-<uuid>
# teams and identities.sh would otherwise enumerate all of them (cross-session
# delivery). With the pin, only the current session's team is subscribed.
ACTIVE_NAME=""
TEAM_PIN=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --team)
      if [ "$#" -lt 2 ] || [ -z "$2" ]; then
        echo "ERROR: watch.sh --team needs a value"
        exit 1
      fi
      TEAM_PIN="$2"
      shift 2
      ;;
    *)
      if [ -z "$ACTIVE_NAME" ]; then ACTIVE_NAME="$1"; shift
      else
        echo "ERROR: watch.sh unexpected argument: $1"
        exit 1
      fi
      ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/storage.sh"
agmsg_storage_load
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/actas-lock.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/resolve-project.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/process-identity.sh"

# Fail loudly on an unknown agent_type instead of running with zero
# subscriptions. The dominant real-world cause is a shifted argument list: a
# launcher shell that drops an empty first argument (see the session_id note
# above) makes project_path land in $2 and agent_type receive whatever was in
# $4 — typically an agent/role name. identities.sh then resolves nothing and,
# without this guard, the watcher keeps polling forever while delivering
# nothing: a silent zero-subscription outage that looks alive from the
# outside. Same shape as the DB-open healthcheck (#197): one loud line on
# stdout (the monitor event stream), then exit.
#
# Hot path stays free: a built-in type is confirmed by a single manifest stat.
# A name with '/' or '..' is rejected outright — it is never a type name, and
# letting it reach the registry would concatenate it into a filesystem path
# (e.g. '../types/claude-code' would resolve to a builtin manifest and pass).
# Only a legitimate non-builtin name pays for the registry (trusted external
# plugins can add types), and the full type enumeration runs only in the
# error message.
case "$AGENT_TYPE" in
  */*|*..*)
    echo "ERROR: invalid agent type '$AGENT_TYPE' (type names never contain '/' or '..'). Arguments may have shifted: a caller shell can drop an empty session_id argument entirely. Pass the sentinel '-' (e.g. \"\${GROK_SESSION_ID:--}\") instead of an empty string."
    exit 1
    ;;
esac
if [ ! -f "$SCRIPT_DIR/drivers/types/$AGENT_TYPE/type.conf" ]; then
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/lib/type-registry.sh"
  if ! agmsg_type_dir "$AGENT_TYPE" >/dev/null 2>&1; then
    echo "ERROR: unknown agent type '$AGENT_TYPE' (supported: $(agmsg_known_types | sort -u | paste -sd, - | sed 's/,/, /g')). Arguments may have shifted: a caller shell can drop an empty session_id argument entirely. Pass the sentinel '-' (e.g. \"\${GROK_SESSION_ID:--}\") instead of an empty string."
    exit 1
  fi
fi

# Resolve a session id when the launcher could not bake one in (empty first arg).
# Grok Build's `monitor` tool runs the watcher with $GROK_SESSION_ID unset, so
# neither the env var nor the instance-id ppid walk (it keys on the claude/codex
# agent binaries) yields grok's session. Bind to a composite "<session_id>.<grok
# _pid>" instead — keyed this way the watermark/pidfile are stable across watcher
# relaunches (no replay gap) and liveness-gated on the grok pid, so the watcher
# self-exits once grok dies rather than lingering as a bare-id orphan (#245).
# agmsg_grok_instance_id handles both `grok --resume <id>` and a fresh `grok`
# (no --resume). Fall back to a throwaway id only if no live grok is found, so the
# watcher still starts (#238). Uses the raw project path the watcher was launched
# with, before agmsg_resolve_project rewrites it, to match grok's session dir.
if [ -z "$SESSION_ID" ]; then
  case "$AGENT_TYPE" in
    grok-build)
      SESSION_ID="$(agmsg_grok_instance_id "$PROJECT_PATH" 2>/dev/null || true)"
      # A fresh grok watcher reaps bare-id grok watchers left behind by older
      # (pre-composite) versions whose grok has since exited (#245). Specific-PID
      # kill only — never a pattern kill.
      agmsg_reap_orphan_grok_watchers "$PROJECT_PATH" "$$" 2>/dev/null || true
      ;;
  esac
  [ -z "$SESSION_ID" ] && SESSION_ID="agmsg-$(compat_uuidgen | tr 'A-Z' 'a-z')"
fi

# Resolve the session's real project root (see #92). The actas/drop/ensure-
# monitor flows relaunch this watcher with a raw "$(pwd)"; without resolution a
# watcher started from a subdir/worktree finds no registration and exits, so
# actas would switch the from-line yet silently kill the receive side. A
# detached watcher (no agent process to walk to) degrades to the ancestor /
# git-common-dir signals, which still recover the nested/worktree cases.
PROJECT_PATH="$(agmsg_resolve_project "$PROJECT_PATH" "$AGENT_TYPE")"

# Disambiguate parallel --continue/--resume sessions that share a session_id
# (#93). All per-process state below — pidfile, watermark, actas owner, ready
# sentinel — keys on this per-process instance id rather than the bare
# session_id, so two processes that share a session_id no longer collide on the
# same pidfile and kill each other (#66 was a within-session dedup; here it must
# not fire across sibling processes). Idempotent: the SessionStart directive
# already passes a composite id (no re-derive); the command template's manual
# monitor/actas/drop steps pass a bare session_id and we self-derive here.
SESSION_ID="$(agmsg_normalize_instance_id "$SESSION_ID" "$AGENT_TYPE")"

# A resumed session may replay an old Monitor directive whose composite id
# still embeds the previous agent pid. Rebind every downstream artifact and
# liveness check to the live agent ancestor before claiming the watcher slot.
if agmsg_instance_is_composite "$SESSION_ID" && ! agmsg_instance_alive "$SESSION_ID"; then
  stale_pid="${SESSION_ID##*.}"
  live_pid="$(agmsg_agent_pid "$AGENT_TYPE" || true)"
  case "$live_pid" in
    ''|*[!0-9]*)
      echo "agmsg watch: composite instance pid $stale_pid is dead and no live $AGENT_TYPE agent found in ancestry; exiting (stale directive?)" >&2
      exit 0
      ;;
  esac
  if ! _agmsg_pid_alive "$live_pid"; then
    echo "agmsg watch: composite instance pid $stale_pid is dead and no live $AGENT_TYPE agent found in ancestry; exiting (stale directive?)" >&2
    exit 0
  fi
  SESSION_ID="$(agmsg_instance_id_from_pid "${SESSION_ID%.*}" "$live_pid")"
  echo "agmsg watch: instance pid $stale_pid is gone; adopted live agent pid $live_pid (stale directive, e.g. resumed session)" >&2
fi

DB="$(agmsg_db_path)"
RUN_DIR="$SKILL_DIR/run"
PIDFILE="$RUN_DIR/watch.$SESSION_ID.pid"
LOGFILE="$RUN_DIR/watch.$SESSION_ID.log"

# Everything this process has to say, somewhere a person can read afterwards.
#
# stderr alone was not that place (#691). In the configuration this actually
# runs in, fd2 is /dev/null: the watcher's fd1 is the socket to its session and
# its fd2 goes nowhere. So every message explaining an otherwise invisible
# state -- roles skipped, a claim refused, the reason a watcher stopped -- was
# written to a file descriptor with no reader. A delivery investigation then
# has to reconstruct from process tables and database state what the one
# component that knew was unable to say.
#
# Beside the pidfile, because this process already owns that directory and the
# pair is what a reader wants: which pid, and what it thought it was doing.
#
# Bounded by rotation, one generation kept: an unbounded log in a directory
# nobody prunes is its own defect. The ceiling is stated exactly, because the
# first version claimed one it did not deliver -- it compared the size BEFORE
# the write, so a live log at cap-1 could take one more line and end over the
# cap, and a live log already past the cap was moved to `.1` still oversized.
#
# The decision includes the bytes about to be written, so:
#
#   live file    never exceeds cap, EXCEPT when one record is itself larger
#                than cap -- then the file is exactly that record, because
#                rotating first and writing it whole is better than dropping
#                the one line someone is looking for.
#   `.1`         a former live file, so bounded the same way.
#   on disk      at most 2 x max(cap, longest single record).
#
# A record here is one diagnostic line with a timestamp and a pid; the longest
# realistic one is a few hundred bytes against a 128 KiB default.
#
# Still echoed to stderr: when someone runs watch.sh by hand, stderr IS the
# place they are looking, and losing that to make the file work would trade one
# silence for another.
WATCH_LOG_MAX_BYTES="${AGMSG_WATCH_LOG_MAX_BYTES:-131072}"
# Normalized the way INTERVAL above is. What an un-normalized value costs was
# measured rather than assumed, because the first version of this comment named
# a failure that does not happen here: the value never enters `$(( ))`, so it
# cannot be read as a variable name, and this script sets `-u` but not `-e`, so
# nothing dies.
#
# It reaches the right-hand side of `[ ... -gt "$WATCH_LOG_MAX_BYTES" ]`. A
# word there makes the test error non-fatally and read as false, forever, so
# rotation simply never fires and the log grows unbounded -- the one property
# this design was chosen for. A cap of `0` is the opposite failure: every
# record is over it, so each one rotates and throws the previous generation
# away, which is the diagnostics this exists to keep.
#
# Anything that is not a positive integer -- empty, words, 0, negative --
# becomes the default, so a misconfigured cap degrades to the shipped bound
# rather than to no bound or to a one-line window.
case "$WATCH_LOG_MAX_BYTES" in
  ''|*[!0-9]*) WATCH_LOG_MAX_BYTES=131072 ;;
  *) [ "$WATCH_LOG_MAX_BYTES" -gt 0 ] || WATCH_LOG_MAX_BYTES=131072 ;;
esac

# Pairs already reported as storeless, so the notice is once per process.
NO_STORE_REPORTED=""

watch_log() {
  local msg="$*" record size=0 bytes
  printf 'agmsg watch: %s\n' "$msg" >&2
  mkdir -p "$RUN_DIR" 2>/dev/null || return 0
  # Built first, so the rotation decision can weigh what is actually going to
  # be appended rather than only what is already there.
  record="$(printf '%s [%s] %s' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$$" "$msg")"
  if [ -f "$LOGFILE" ]; then
    size="$(compat_file_size "$LOGFILE" 2>/dev/null || echo 0)"
    case "$size" in ''|*[!0-9]*) size=0 ;; esac
    # +1 for the newline. Rotate when this write WOULD cross the cap, not once
    # it already has.
    #
    # Counted in BYTES, with `wc -c`, because the cap is bytes and so is the
    # size `stat` returns. `${#record}` counts CHARACTERS in a UTF-8 locale, and
    # a team or agent name may legally be Unicode -- the storeless and actas
    # diagnostics put those names in the record. A multibyte line then passes a
    # character-count check and lands over the byte cap, which is the contract
    # this rotation exists to hold. One extra process per diagnostic is nothing:
    # these are emitted a handful of times per watcher, not per poll.
    bytes="$(printf '%s' "$record" | wc -c | tr -d '[:space:]' 2>/dev/null)"
    # If the byte count cannot be had, rotate rather than guess. Falling back
    # to `${#record}` would reinstate the character count this just replaced --
    # the exact wrong unit, and fail-OPEN: the bound would quietly stop holding
    # whenever `wc` is missing or answers oddly. Rotating costs one early
    # generation; the diagnostic itself is still written whole below.
    case "$bytes" in ''|*[!0-9]*) bytes="$WATCH_LOG_MAX_BYTES" ;; esac
    if [ "$(( size + bytes + 1 ))" -gt "$WATCH_LOG_MAX_BYTES" ]; then
      mv -f "$LOGFILE" "$LOGFILE.1" 2>/dev/null || true
    fi
  fi
  # Never fatal: a sandbox that cannot write here must not take delivery down.
  printf '%s\n' "$record" >> "$LOGFILE" 2>/dev/null || true
}

# Resolve poll interval. Env var wins over config, default 5s.
INTERVAL="${AGMSG_WATCH_INTERVAL:-}"
if [ -z "$INTERVAL" ]; then
  INTERVAL="$("$SCRIPT_DIR/config.sh" get delivery.monitor.poll_interval 5 2>/dev/null || echo 5)"
fi
case "$INTERVAL" in ''|*[!0-9]*) INTERVAL=5 ;; esac

mkdir -p "$RUN_DIR" 2>/dev/null || true

# Sequential re-invocation of Monitor for this same session_id leaves the
# previous watch.sh running but loses track of it (pidfile gets clobbered).
# Stop the prior holder before claiming the slot. ps args check defends
# against pid recycling — only touch processes whose cmdline still matches
# our watch.sh. See #66.
#
# When ps is unavailable (e.g. Claude Code sandbox), fall back to _agmsg_pid_alive
# which confirms the pid is alive but cannot validate the cmdline. It is EPERM-aware
# so a live-but-unsignalable sibling watcher isn't misread as dead and left running.
if [ -f "$PIDFILE" ]; then
  prev_pid=$(cat "$PIDFILE" 2>/dev/null || true)
  if [ -n "$prev_pid" ] && [ "$prev_pid" != "$$" ] && _agmsg_pid_alive_local "$prev_pid"; then
    prev_cmd=$(compat_get_cmdline "$prev_pid" 2>/dev/null || true)
    if [ -n "$prev_cmd" ]; then
      case "$prev_cmd" in
        *"$SKILL_DIR/scripts/watch.sh"*) kill "$prev_pid" 2>/dev/null || true ;;
      esac
    else
      # ps unavailable (sandboxed) — skip cmdline validation, rely on the
      # _agmsg_pid_alive check above
      kill "$prev_pid" 2>/dev/null || true
    fi
  fi
fi

# The acquire-then-exec bootstrap above is the single-owner claim.  Do not add
# a PID-based takeover here: signal authorization belongs exclusively to
# agmsg_process_signal_owned, and a duplicate never reaches this body.
# Readiness sentinels this watcher created (see #108). Populated once the
# subscription is resolved; removed on exit so the file is present iff a live
# watcher is currently receiving for that role.
READY_FILES=""
cleanup() {
  # EXIT only removes the pidfile if it still records our pid. A successor
  # watcher (Monitor re-invoked for the same session_id) overwrites $PIDFILE
  # with its own pid before killing us; without this guard our EXIT trap
  # would erase the successor's record. See #66.
  agmsg_process_cleanup_self watch "$PIDFILE" "@hash:$WATCH_OWNER_SCOPE_HASH"
  if [ -n "$READY_FILES" ]; then
    while IFS= read -r _rf; do
      [ -z "$_rf" ] && continue
      # Only remove a sentinel we still own. A successor actas watcher for the
      # same (team, name) overwrites it with its own session_id before this one
      # exits; without this guard our EXIT could delete the live successor's
      # sentinel. Mirrors the pidfile guard above. See #108 review.
      local _owner=""
      [ -f "$_rf" ] && IFS= read -r _owner < "$_rf" || true
      [ "$_owner" = "$SESSION_ID" ] && rm -f "$_rf" 2>/dev/null || true
    done <<< "$READY_FILES"
  fi
  [ -n "${INSTALL_STAMP:-}" ] && rm -f "$INSTALL_STAMP" 2>/dev/null || true
}
# Install these traps as early as re-entry permits because owner publication
# can precede the target becoming signal-ready.
trap cleanup EXIT
trap 'exit 0' INT TERM HUP

# A resident process keeps executing the code it was started with. An update
# rewrites the scripts in place (same inode -- confirmed with lsof, #684), so
# after one this watcher is running code from before it while everything it
# talks to has moved on. Measured on the reported pair: a 1.1.13 watcher, after
# `npx agmsg@1.2.0-rc.1 install` landed under it, stayed ALIVE and stopped
# delivering -- the message was never printed and never marked read, and
# nothing was written to stderr. Liveness is exactly what made it invisible.
#
# The guard is a timestamp rather than a version comparison, so it does not
# only catch the table that moved this time. ANY file under scripts/ being
# newer than this watcher's start means the code it is running is no longer the
# code on disk, whatever changed -- which is the class, not the instance.
#
# `run/` is deliberately outside the watched tree: pidfiles and readiness
# sentinels are written by watchers themselves and would trip it immediately.
INSTALL_STAMP="$RUN_DIR/.watch-start.$SESSION_ID"
: > "$INSTALL_STAMP" 2>/dev/null || true

# True when anything under scripts/ was written after this watcher started.
# `-print -quit` stops at the first hit, so the common case is one stat-walk
# that exits early rather than a full tree scan every cycle.
_install_changed() {
  [ -f "$INSTALL_STAMP" ] || return 1
  [ -n "$(find "$SCRIPT_DIR" -newer "$INSTALL_STAMP" -print -quit 2>/dev/null)" ]
}

# Resolve subscription set.
PAIRS="$("$SCRIPT_DIR/identities.sh" "$PROJECT_PATH" "$AGENT_TYPE")"
if [ -n "$TEAM_PIN" ]; then
  PAIRS=$(printf '%s\n' "$PAIRS" | awk -v t="$TEAM_PIN" -F'\t' 'NF >= 2 && $1 == t')
fi
if [ -n "$ACTIVE_NAME" ]; then
  PAIRS=$(printf '%s\n' "$PAIRS" | awk -v n="$ACTIVE_NAME" -F'\t' 'NF >= 2 && $2 == n')
fi

# Honor actas exclusivity locks. A (team, agent) pair currently owned by
# another live session is removed from this watcher's subscription so
# messages addressed to that role only reach the owning session. Pairs we
# own (or that are free) stay in. See #62.
#
# When ACTIVE_NAME is set (the watcher was launched by an `actas` flow),
# we also CLAIM the lock for each surviving pair. Implicit claim here makes
# the exclusivity take effect machine-wide on the next peer watcher cycle,
# without needing the skill cmd templates to call a separate helper. If a
# claim fails because another live session beat us to it, exit with an
# error — the user's host agent surfaces stderr and the original (broad)
# watcher was already stopped by the actas flow, so this state is recoverable
# by `drop` on the other session.
if [ -n "$PAIRS" ]; then
  filtered=""
  skipped=""
  held=""
  while IFS=$'\t' read -r _team _agent; do
    [ -z "$_team" ] && continue
    state=$(actas_lock_state "$_team" "$_agent" "$SESSION_ID")
    case "$state" in
      other:*)
        # If the caller is asking specifically for this name (actas flow),
        # treat the conflict as a hard failure. Otherwise (broad subscribe)
        # silently skip — peer owns the role, we don't need it.
        if [ -n "$ACTIVE_NAME" ]; then
          held="${held:+$held }${_team}/${_agent}(${state#other:})"
        else
          skipped="${skipped:+$skipped }${_team}/${_agent}(${state#other:})"
        fi
        continue
        ;;
    esac
    if [ -n "$ACTIVE_NAME" ]; then
      # Implicit claim — `actas` was the invoking flow. Covers the race
      # where state-check said free but a peer claimed it between then and
      # now.
      result=$(actas_lock_claim "$_team" "$_agent" "$SESSION_ID" 2>/dev/null || true)
      case "$result" in
        held:*)
          held="${held:+$held }${_team}/${_agent}(${result#held:})"
          continue
          ;;
      esac
    fi
    filtered="${filtered:+$filtered$'\n'}${_team}"$'\t'"${_agent}"
  done <<< "$PAIRS"
  PAIRS="$filtered"
  if [ -n "$skipped" ]; then
    echo "agmsg watch: skipping pairs held by other sessions: $skipped" >&2
  fi
  if [ -n "$held" ]; then
    echo "agmsg watch: cannot claim (held by other sessions): $held" >&2
    echo "agmsg watch: run \`/agmsg drop <name>\` in the owning session, then retry." >&2
    exit 1
  fi
fi

if [ -z "$PAIRS" ]; then
  if [ -n "$ACTIVE_NAME" ]; then
    echo "agmsg watch: no registration for agent '$ACTIVE_NAME' in $PROJECT_PATH ($AGENT_TYPE); nothing to do"
  else
    echo "agmsg watch: no available identities (all held by other sessions, or none joined); nothing to do"
  fi
  exit 0
fi

# SUB_PAIRS holds the subscription as <team>:<agent> tokens — the argument form
# the storage facade's watch ops take (§2.2). Live delivery goes entirely through
# storage_watch_tip / storage_watch_after now, so no SQL WHERE clause is built here.
SUB_PAIRS=()
while IFS=$'\t' read -r team agent; do
  [ -z "$team" ] && continue
  SUB_PAIRS+=("$team:$agent")
done <<< "$PAIRS"

# Determine the starting watermark.
#
# The watermark is persisted per session_id so that a *restart* of this
# session's watcher resumes from the last delivered id instead of jumping to
# the current MAX(id). Monitor restarts are routine — `actas`/`drop` do
# TaskStop + relaunch, `/clear`/resume re-fires the SessionStart directive, and
# a killed watcher self-restarts — and the old "start from MAX(id)" behavior
# silently dropped every message that landed in the gap between the previous
# watcher stopping and the new one taking its mark. Resuming from the persisted
# watermark closes that gap; staying strictly after the last delivered id
# avoids re-streaming anything already seen. See #107.
#
# A *fresh* session (no persisted watermark) still starts from the current
# MAX(id) — live push, no replay of history (the no-arg inbox check covers
# historical unread, not this stream).
# The watermark is now an OPAQUE delivery cursor (§2.2), not an integer id — the
# active storage driver issues and interprets it; this script only persists the
# latest token and passes it back unchanged.
WATERMARK_FILE="$RUN_DIR/watch.$SESSION_ID.watermark"
persist_watermark() { printf '%s\n' "$LAST" > "$WATERMARK_FILE" 2>/dev/null || true; }

# Mark a row's read_at so a later inbox.sh call does not re-surface it as
# unread — the watermark only stops THIS watcher from re-streaming a row, it
# never touches read_at (see the call sites below for the full rationale).
# Shared by both the normal delivery path and the ctrl:despawn control-row
# path so the two do not drift (#review finding, 2026-07-19). $1 is trusted
# to be a DB-sourced id everywhere this is called, but it is guarded anyway
# (matches inbox.sh's own defensive stance) since it is interpolated into SQL.
#
# $2/$3 (team, to) scope this to the DEFINITIVE receiver for that role:
#   - an exclusive watcher (ACTIVE_NAME set) only marks its own role's rows.
#   - a broad watcher (ACTIVE_NAME empty) subscribes to every registered role
#     in the project (see PAIRS above), so without this guard it would also
#     mark read_at for a role that has its OWN exclusive watcher — e.g. a
#     leader's default SessionStart watcher racing/clobbering the read state
#     an actas'd member's exclusive watcher is responsible for. Skip when an
#     exclusive ready sentinel for (team, to) exists; that role's own watcher
#     owns the read state (review finding, 2026-07-19).
#
# Note: this is a best-effort mark on local write success, not a delivery ack
# — there is no protocol to confirm the downstream Monitor reader actually
# consumed the line (a pipe write can succeed into a kernel buffer even if the
# reader is about to exit). A stronger guarantee needs the claim/ack redesign
# tracked in #373; out of scope for this fix (review finding, 2026-07-19).
mark_read() {
  local mid="$1" team="$2" to="$3"
  case "$mid" in
    ''|*[!0-9]*) return 0 ;;
  esac
  if [ -z "$ACTIVE_NAME" ] && [ -n "$team" ] && [ -n "$to" ]; then
    [ -e "$(agmsg_ready_path "$team" "$to")" ] && return 0
  fi
  agmsg_sqlite "$DB" "UPDATE messages SET read_at=strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id=$mid AND read_at IS NULL;" 2>/dev/null \
    || echo "agmsg watch: could not mark message $mid read (db busy/unavailable); a later inbox.sh call will re-surface it" >&2
}

LAST=""
if [ -f "$WATERMARK_FILE" ]; then
  # Opaque token: a single whitespace-free line. No integer validation — just
  # strip stray surrounding whitespace.
  LAST="$(tr -d '[:space:]' < "$WATERMARK_FILE" 2>/dev/null || true)"
fi
if [ -z "$LAST" ]; then
  # A fresh watcher starts from the current tip (live push, no history replay).
  LAST="$(storage_watch_tip "${SUB_PAIRS[@]}" 2>/dev/null || true)"
  case "$LAST" in '') LAST=0 ;; esac
  persist_watermark
fi

# DB-open healthcheck (#197). The main loop guards every query with
# `2>/dev/null || true`, so when sqlite3 cannot open the store the watcher keeps
# spinning and silently delivers nothing — a silent outage. The native
# sqlite3.exe / Git Bash path mismatch behind #197 is one trigger (now fixed in
# agmsg_db_path), but permissions, a missing binary, or a corrupt file fail the
# same way. A *missing* DB file is normal (no messages sent yet), so only flag
# the case where the file exists but a trivial query cannot run: emit one line
# on stdout (the Monitor event stream) and exit, turning the silent failure into
# a visible one. Done before the ready sentinel so we never signal "ready" for a
# watcher that cannot read the store.
if [ -f "$DB" ] && ! agmsg_sqlite "$DB" "SELECT 1;" >/dev/null 2>&1; then
  echo "ERROR: cannot open message DB $DB"
  exit 1
fi

# Signal readiness. Once the subscription is resolved and the watermark is set,
# this watcher will deliver anything that arrives from here on, so it is safe
# for a leader to start sending. Only exclusive (actas) watchers signal — a
# spawned agent always starts its watcher in actas mode — and the sentinel is
# removed on exit (cleanup), so it tracks "a live watcher is receiving for this
# role". `spawn --wait-ready` polls for it. See #108.
if [ -n "$ACTIVE_NAME" ]; then
  while IFS=$'\t' read -r _rt _ra; do
    [ -z "$_rt" ] && continue
    _rp="$(agmsg_ready_path "$_rt" "$_ra")"
    # Stamp our session_id so cleanup (and a successor watcher) can tell whose
    # sentinel it is — keeps "present iff a live watcher is receiving" honest
    # across a quick actas restart. See #108 review.
    printf '%s\n' "$SESSION_ID" > "$_rp" 2>/dev/null || true
    READY_FILES="${READY_FILES:+$READY_FILES$'\n'}$_rp"
  done <<< "$PAIRS"
fi

# Pairs another session currently holds, so each departure and each return is
# announced once instead of every cycle. Membership is not a decision -- the
# lock is -- it only records what has already been said (#683).
#
# Held as newline-separated entries and compared as EXACT strings, never as
# patterns. A team name is arbitrary UTF-8 minus a path deny-list and an agent
# name minus a JSON-path deny-list (validate.sh), so either may contain glob
# metacharacters, a sed delimiter, or a space. A `case` pattern or an
# `s|…|…|` built out of one is a bug that only appears for some names --
# the class this repo has paid for before with quotes in names (#87). Newline
# is the one byte a name cannot contain, control characters being rejected, so
# it is the safe separator.
HELD_ELSEWHERE=""

_held_elsewhere_has() {
  local want="$1" line
  [ -n "$HELD_ELSEWHERE" ] || return 1
  while IFS= read -r line; do
    [ "$line" = "$want" ] && return 0
  done <<< "$HELD_ELSEWHERE"
  return 1
}

_held_elsewhere_without() {
  local drop="$1" line out=""
  [ -n "$HELD_ELSEWHERE" ] || return 0
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    [ "$line" = "$drop" ] && continue
    out="${out:+$out
}$line"
  done <<< "$HELD_ELSEWHERE"
  printf '%s' "$out"
}

while true; do
  # The installation changed under us (#684). Say it on STDOUT, not stderr:
  # stdout is the delivery channel the session is reading, and this watcher's
  # stderr goes to /dev/null in every launcher we ship, which is why the
  # original failure was silent for hours. Then exit, so "the monitor stopped"
  # is what the session sees instead of a live process delivering nothing.
  if _install_changed; then
    printf 'agmsg watch: the agmsg installation was updated while this watcher was running, so it is still executing the code from before the update. Exiting rather than appearing to work. Restart this session (or run /agmsg actas <name>) to resume delivery.\n'
    exit 0
  fi
  # Liveness guard (#67): exit promptly once the originating agent session is
  # gone. A plain pipe gives no portable way to notice a *downstream* consumer
  # that closed silently — printf '' raises no EPIPE, and macOS buffers a final
  # write into an already-dead reader — so a quiet watcher whose session died
  # would otherwise spin forever (the macOS-runner 33-min stall; #210's job
  # timeout only caps the symptom). `kill -0` on the agent pid embedded in the
  # composite instance id is portable (Git Bash falls back to tasklist; see
  # _agmsg_pid_alive). Gated on a composite id only: a bare id (degraded, no
  # resolved agent pid) keeps the prior behavior and is not liveness-gated.
  if agmsg_instance_is_composite "$SESSION_ID" && ! agmsg_instance_alive "$SESSION_ID"; then
    # Say which condition fired and which token it decided about (#692). The
    # guard is right; the silence is what costs. A watcher that stops here, one
    # that was killed, one that crashed early and one that was never started
    # were four indistinguishable states -- and a test watcher launched with a
    # session id that does not resolve hits this immediately, so the test then
    # runs against no watcher at all while looking exactly like one that did.
    # That happened twice in one investigation before anyone noticed.
    watch_log "session $SESSION_ID is no longer alive; stopping."
    exit 0
  fi
  while IFS=$'\t' read -r pair_team pair_agent; do
    [ -z "$pair_team" ] && continue
    # Ownership is re-read every cycle, because it can change under a running
    # watcher and nothing else notices. The subscription set and the startup
    # lock check both happen once, above; a session that claims this role
    # afterwards moves the lock file and starts its own watcher, and this
    # process would otherwise keep polling the same pair forever.
    #
    # That is not a harmless duplicate. The read cursor is one per
    # (team, agent) and storage_watch_after excludes rows already read, so
    # whoever polls first TAKES the row and the other sees nothing. When the
    # one that takes it is this stale process, its printf succeeds -- stdout is
    # still an open pipe to a live session -- so the id is marked read and the
    # message is gone, delivered to a stream nobody is reading (#683).
    #
    # Only the lock file is read here, not the whole subscription set: losing a
    # pair is the half a running process can detect for the price of a file
    # read. Gaining one is the caller's job, at the point it creates the team.
    pair_state="$(actas_lock_state "$pair_team" "$pair_agent" "$SESSION_ID" 2>/dev/null || echo free)"
    case "$pair_state" in
      other:*)
        if [ -n "$ACTIVE_NAME" ]; then
          # This watcher exists to serve exactly this role and no longer owns
          # it. Stop -- and say so: stderr is the only place a reason survives,
          # and a watcher that ends without one is indistinguishable from one
          # that crashed.
          watch_log "${pair_team}/${pair_agent} is now held by session ${pair_state#other:}."
          watch_log "this watcher no longer owns that role and is stopping."
          watch_log "messages for it stay unread and reach the session that claimed it."
          exit 0
        fi
        # Broad subscription: this watcher serves other roles too, so skip the
        # pair rather than ending the process -- exiting here would take down a
        # whole session's delivery because one of its roles moved elsewhere.
        #
        # Skipped FOR AS LONG AS someone else holds it, not permanently. When
        # the holder goes away the lock reads free again and this watcher takes
        # the pair back, which is the same rule the startup filter uses (a
        # stale lock is free). Dropping it for good would be worse: the role is
        # still registered to this project, so nobody would deliver for it
        # until the session restarted.
        #
        # Announced on each transition, not each cycle -- a per-cycle message
        # would bury the log, and announcing only the first time would make a
        # second departure invisible.
        if ! _held_elsewhere_has "${pair_team}/${pair_agent}"; then
          HELD_ELSEWHERE="${HELD_ELSEWHERE:+$HELD_ELSEWHERE
}${pair_team}/${pair_agent}"
          echo "agmsg watch: ${pair_team}/${pair_agent} was claimed by session ${pair_state#other:}; not serving it while they hold it." >&2
        fi
        continue
        ;;
      *)
        # Free or ours. If we had stepped aside for it, say that we are taking
        # it back -- otherwise the log shows a role leaving and never returning,
        # which reads as a permanent drop.
        if _held_elsewhere_has "${pair_team}/${pair_agent}"; then
          HELD_ELSEWHERE="$(_held_elsewhere_without "${pair_team}/${pair_agent}")"
          echo "agmsg watch: ${pair_team}/${pair_agent} is unheld again; serving it here." >&2
        fi
        ;;
    esac
    # Per team: with a store per team, "one team has no store yet" is a
    # normal state, and a single check outside this loop would silence
    # delivery for every OTHER team as well.
    # Skipped, and said once. The same "stop quietly" shape as the guard above
    # (#692): a team with no store yet is a normal state, but a team that
    # silently stops being delivered every cycle is not distinguishable from
    # one that is fine. Once per pair per process -- a line every poll interval
    # would bury the log this exists to make readable.
    if ! storage_store_exists "$pair_team"; then
      case " $NO_STORE_REPORTED " in
        *" $pair_team:$pair_agent "*) ;;
        *) NO_STORE_REPORTED="$NO_STORE_REPORTED $pair_team:$pair_agent"
           watch_log "${pair_team}/${pair_agent}: no store yet; skipping this pair until one exists." ;;
      esac
      continue
    fi
    READ_CURSOR="$(storage_read_cursor_get "$pair_team" "$pair_agent" 2>/dev/null || true)"
    [ -n "$READ_CURSOR" ] || READ_CURSOR=0
    OUT="$(storage_watch_after "$READ_CURSOR" "$pair_team:$pair_agent" 2>/dev/null || true)"
    if [ -n "$OUT" ]; then
      _arr="[$(printf '%s' "$OUT" | paste -sd, -)]"
      ROWS="$(agmsg_sqlite ':memory:' "
        SELECT COALESCE(json_extract(value,'\$.type'),'') || char(31) ||
               COALESCE(json_extract(value,'\$.id'),'') || char(31) ||
               COALESCE(json_extract(value,'\$.at'),'') || char(31) ||
               COALESCE(json_extract(value,'\$.team'),'') || char(31) ||
               COALESCE(json_extract(value,'\$.from'),'') || char(31) ||
               COALESCE(json_extract(value,'\$.to'),'') || char(31) ||
               replace(replace(replace(COALESCE(json_extract(value,'\$.body'),''), char(13), ''), char(10), '\\n'), char(9), '\t') || char(31) ||
               COALESCE(json_extract(value,'\$.cursor'),'')
        FROM json_each('$(printf '%s' "$_arr" | sed "s/'/''/g")');
      " 2>/dev/null || true)"

      while IFS=$'\x1f' read -r kind id ts team from to body cursor; do
        [ -z "$kind" ] && continue
        if [ "$kind" = "cursor" ]; then
          # Trailing cursor = the resume point. Advance + persist only after the
          # batch's messages were delivered above; a crash mid-batch re-delivers
          # from the old cursor (at-least-once, never skip — §2.2).
          LAST="$cursor"; persist_watermark
          continue
        fi
        [ "$kind" = "message_sent" ] || continue
        [ -z "$id" ] && continue
        # Control message: a leader's `despawn` sends `ctrl:despawn` to this
        # role. Tear ourselves down rather than printing it — drop the role
        # (releases the lock + registration) then close our own tmux pane,
        # which also ends the agent CLI sharing it. Deterministic teardown, no
        # dependence on the agent LLM noticing the message. See #109.
        if [ "$body" = "ctrl:despawn" ]; then
          # Only an EXCLUSIVE watcher dedicated to exactly this role tears
          # itself down. A broad-subscription watcher (e.g. a leader whose
          # default watcher subscribes to every project role, including the
          # despawn target) must NOT act on it — its $TMUX_PANE is the leader's
          # own pane, so killing it would take down the leader's session. The
          # spawned member's watcher runs in actas mode (ACTIVE_NAME=$to) in its
          # own pane; that's the one meant to respond. A broad watcher `continue`s
          # and reaches the trailing cursor at batch end, so its watermark advances
          # past this control message. The target watcher below exits BEFORE the
          # cursor record, so it does not persist a cursor — harmless, since it
          # drops the role and won't resume as it; a same-session resume would
          # re-read the despawn (at-least-once) and re-tear-down idempotently. See #109.
          if [ -z "$ACTIVE_NAME" ] || [ "$to" != "$ACTIVE_NAME" ]; then
            continue
          fi
          # Read the placement record BEFORE reset.sh. reset.sh releases the
          # actas lock, and the leader's despawn deletes the record as soon as
          # it observes that lock go free — so reading it afterwards races the
          # cleanup and would intermittently see nothing.
          placed_id=""
          spawn_rec="$(agmsg_spawn_path "$team" "$to")"
          [ -f "$spawn_rec" ] && IFS=$'\t' read -r placed_id _ _ < "$spawn_rec"
          # This control row is an internal teardown; scope reset to its message team.
          "$SCRIPT_DIR/reset.sh" --team "$team" "$PROJECT_PATH" "$AGENT_TYPE" "$to" "$SESSION_ID" >/dev/null 2>&1 || true
          if [ -n "${TMUX_PANE:-}" ] && command -v tmux >/dev/null 2>&1; then
            tmux kill-pane -t "$TMUX_PANE" 2>/dev/null || true
          # Closing a herdr pane needs more than "a pane id is in the
          # environment". HERDR_* is inherited by every descendant of a herdr
          # pane, so a watcher merely STARTED inside one — a developer running
          # the test suite, or any agent that actas'd by hand — carries the
          # HOST pane's id. Acting on that closes the host. Require both the
          # full herdr environment (matching spawn's own detection) and proof
          # that agmsg itself placed this pane: the recorded placement for this
          # (team, agent) must name exactly the pane we are sitting in.
          # Otherwise fall through to the manual branch. This is the herdr
          # counterpart of the tmux path's ACTIVE_NAME gating (#109).
          elif [ "${HERDR_ENV:-}" = "1" ] && [ -n "${HERDR_PANE_ID:-}" ] \
               && [ "$placed_id" = "herdr:$HERDR_PANE_ID" ] \
               && command -v herdr >/dev/null 2>&1; then
            herdr pane close "$HERDR_PANE_ID" 2>/dev/null || true
          else
            echo "agmsg watch: despawned '$to' (role dropped); close this window manually" >&2
          fi
          exit 0
        fi
        if ! printf '%s | %s | %s → %s | %s\n' "$ts" "$team" "$from" "$to" "$body"; then
          cleanup
          exit 0
        fi
      done <<< "$ROWS"
    fi
    if [ -n "$DESPAWN_TARGET" ]; then
      "$SCRIPT_DIR/reset.sh" "$PROJECT_PATH" "$AGENT_TYPE" "$DESPAWN_TARGET" "$SESSION_ID" >/dev/null 2>&1 || true
      if [ -n "${TMUX_PANE:-}" ] && command -v tmux >/dev/null 2>&1; then
        tmux kill-pane -t "$TMUX_PANE" 2>/dev/null || true
      else
        watch_log "despawned '$DESPAWN_TARGET' (role dropped); close this window manually"
      fi
      exit 0
    fi
    fi
  done <<< "$PAIRS"

  # Run sleep in the background and `wait` for it so signal traps fire
  # immediately. Bash defers traps while a foreground builtin like `sleep`
  # is blocking, which would otherwise delay shutdown by up to $INTERVAL.
  sleep "$INTERVAL" 19>&- &
  wait $! 2>/dev/null
done
