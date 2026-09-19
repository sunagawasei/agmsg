#!/usr/bin/env bash
set -u
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/lib/compat.sh"
WATCH_ORIGINAL_ARGS=("$@")

# Captured before anything below parses or resolves them, so a self-restart
# (see _install_changed's handling in the main loop) can exec the installed
# watch.sh with the exact argv this process was launched with, rather than
# replaying already-resolved values through resolution logic a second time.
ORIG_ARGS=("$@")

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
[ "$SESSION_ID" = "-" ] && SESSION_ID="" # #477: caller sentinel for empty session id
PROJECT_PATH="${2:?Missing project_path}"
AGENT_TYPE="${3:?Missing agent_type}"
ACTIVE_NAME="${4:-}"

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
# The prior holder has to go. ps args check defends against pid recycling —
# only touch processes whose cmdline still matches our watch.sh. See #66.
#
# When ps is unavailable (e.g. Claude Code sandbox), fall back to kill -0
# which confirms the pid is alive but cannot validate the cmdline.
#
# WHO to displace is decided here; the signal is sent AFTER this process has
# written its own pid (#595). Sending it first is what made the predecessor's
# own EXIT guard unsound: that guard removes the pidfile only if it still
# records the predecessor's pid, and read-check-remove is three steps, so a
# successor writing between the read and the remove has its record deleted by
# a process on its way out. The successor never writes again, so the slot
# stays empty while a live watcher owns it.
#
# Claiming first removes the interleaving rather than narrowing it: once the
# file names the successor before the predecessor is ever signalled, the read
# that the predecessor's cleanup performs cannot see the predecessor's own
# pid, so the guard's condition is false and it deletes nothing.
#
# The comment on that guard already described this order as the one in force.
# It was not; the code signalled first.
PREV_PID_TO_DISPLACE=""
if [ -f "$PIDFILE" ]; then
  prev_pid=$(cat "$PIDFILE" 2>/dev/null || true)
  if [ -n "$prev_pid" ] && [ "$prev_pid" != "$$" ] && _agmsg_pid_alive_local "$prev_pid"; then
    prev_cmd=$(compat_get_cmdline "$prev_pid" 2>/dev/null || true)
    if [ -n "$prev_cmd" ]; then
      case "$prev_cmd" in
        *"$SKILL_DIR/scripts/watch.sh"*) PREV_PID_TO_DISPLACE="$prev_pid" ;;
      esac
    else
      # ps unavailable (sandboxed) — skip cmdline validation, rely on kill -0
      PREV_PID_TO_DISPLACE="$prev_pid"
    fi
  fi
fi

# Metadata BEFORE the pidfile, deliberately.
#
# A reader that finds a live pid with no filter file cannot tell what that
# watcher is doing OR which project it serves, so it SKIPS it. Written the other
# way round, every filtered watcher spends its startup window in exactly that
# state, and a scan landing in the window reaches the opposite conclusion from
# the one this metadata exists to support -- it would count nothing where there
# is something to count, or, before the project was recorded, warn about a
# watcher sharing nothing. The pidfile is what makes this process visible at
# all, so nothing may be visible before what describes it (raised in review).
#
# The project is part of the record because RUN_DIR is per INSTALL, not per
# project: two projects using the same install both write here, and their
# watchers do not share a subscription -- the pairs come from the project's own
# registrations. Counting across projects would warn about a hazard that does
# not exist (also raised in review).
FILTERFILE="$RUN_DIR/watch.$SESSION_ID.filter"
# Three lines: role, project, and OWNER PID.
#
# The owner is what makes this survive a successor. The replacement path signals
# the previous watcher and does not wait for it, so the order is: successor
# writes this file, predecessor's EXIT runs, reads the pidfile (still its own
# pid), and removes both -- taking the successor's fresh metadata with it. The
# successor is then live with a pidfile and no filter, which a reader classifies
# as pre-change and skips, so a real second unfiltered watcher in this project
# goes unreported. The pidfile transfers ownership by being overwritten; this
# file has to carry its own (raised in review).
printf '%s\n%s\n%s\n' "${ACTIVE_NAME:-unfiltered}" "$PROJECT_PATH" "$$" > "$FILTERFILE" 2>/dev/null || true

echo $$ > "$PIDFILE"

# The slot is ours on disk; now the previous holder can be told to go (#595).
# Nothing waits for it to finish: it is displaced, not depended on, and its
# EXIT will find a pidfile that names this process and leave it alone.
if [ -n "$PREV_PID_TO_DISPLACE" ]; then
  kill "$PREV_PID_TO_DISPLACE" 2>/dev/null || true
fi

# --- Say when this watcher is sharing an inbox with another (#683). ---
#
# A watcher started WITHOUT an active name subscribes to every (team, agent)
# registered for this project that nobody else has claimed. The read cursor is
# one per pair, so when two such watchers exist, whoever polls first takes the
# row and the other sees nothing -- the comment at the subscription site says
# exactly this. The message is not duplicated and it is not lost loudly: it is
# delivered to one of them, and the other's `inbox.sh` truthfully answers "no
# new messages" because the row was read.
#
# Nothing observable is left behind, which is why this has to be said at the one
# moment something can be said: startup.
#
# NOT a lease. This process still subscribes to exactly what it would have
# subscribed to; it only stops being quiet about the fact that someone else is
# doing the same. Exclusion is a separate decision.
# Only when the hazard is real. A warning printed on every start is a warning
# nobody reads, and an unfiltered watcher running alone is not in danger.
if [ -z "$ACTIVE_NAME" ]; then
  _sharing=0
  for _pf in "$RUN_DIR"/watch.*.pid; do
    [ -f "$_pf" ] || continue
    [ "$_pf" = "$PIDFILE" ] && continue
    _other_pid="$(cat "$_pf" 2>/dev/null || true)"
    case "$_other_pid" in ''|*[!0-9]*) continue ;; esac
    # `_agmsg_pid_alive_local`, not a bare `kill -0`. The bare form reads EPERM
    # as "dead", so a watcher this process cannot signal -- another user, a
    # sandbox -- would be counted as gone and its inbox-sharing left unsaid. The
    # repo enforces this (`no shipped script decides liveness with a bare
    # kill -0`), and it caught this line: the first version used the bare form
    # while the comment above it claimed to use what the rest of the file uses.
    #
    # A pidfile left by a crashed watcher names nobody, which is why liveness is
    # checked at all: counting one would fire the warning on an installation
    # that has no second watcher.
    _agmsg_pid_alive_local "$_other_pid" || continue
    _other_filter="${_pf%.pid}.filter"
    # An absent filter file is a watcher from BEFORE this change. It cannot be
    # asked which project it serves, so it is not counted: warning on it would
    # fire for every unrelated project sharing this install, and this warning is
    # only worth having if it is true. A pre-change watcher in the SAME project
    # is a real hazard that goes unreported here -- named in the PR rather than
    # papered over, and it disappears as installs update.
    [ -f "$_other_filter" ] || continue
    _other_name="$(sed -n '1p' "$_other_filter" 2>/dev/null || true)"
    _other_project="$(sed -n '2p' "$_other_filter" 2>/dev/null || true)"
    # Same project only. RUN_DIR is per install; the subscription is per
    # project, so a watcher in another project shares no pairs with this one.
    [ "$_other_project" = "$PROJECT_PATH" ] || continue
    [ "$_other_name" = "unfiltered" ] || continue
    _sharing=$((_sharing + 1))
  done
  if [ "$_sharing" -gt 0 ]; then
    watch_log "another watcher ($_sharing) is receiving for the same unclaimed roles in this project."
    watch_log "messages addressed to those roles will reach whichever of us polls first, and the others will not see them."
    watch_log "to receive only your own: /agmsg actas <name>"
  fi
fi
# Readiness sentinels this watcher created (see #108). Populated once the
# subscription is resolved; removed on exit so the file is present iff a live
# watcher is currently receiving for that role.
READY_FILES=""
cleanup() {
  # EXIT only removes the pidfile if it still records our pid. A successor
  # watcher (Monitor re-invoked for the same session_id) overwrites $PIDFILE
  # with its own pid before signalling us, so this read sees the successor's
  # pid and leaves its record alone. See #66, and #595 for what happened when
  # the signal came first: read, then the successor's write, then this remove
  # — a guard that is three steps cannot decide anything about a file another
  # process may write between them. The order is what makes it sound, not the
  # comparison.
  #
  # This is still not atomic, and it is not relied on to be: a predecessor
  # that entered cleanup for its OWN reasons before any successor existed can
  # still race a newcomer's write. That window is not the relaunch path and
  # is not what #595 observed.
  local pidfile_pid=""
  [ -f "$PIDFILE" ] && IFS= read -r pidfile_pid < "$PIDFILE" || true
  # Both files are removed by their owner, but they do not share an owner test:
  # the pidfile's owner is whoever it names, and the filter file's is whoever it
  # records. See below for why the pidfile cannot answer for both.
  #
  # Neither may be left behind. A stale pidfile makes the next watcher count a
  # ghost. A stale filter file is worse in the direction that matters: it keeps
  # asserting a role on behalf of a dead process, and if that role is a name,
  # every other watcher reads it as "filtered, not sharing" -- so the warning is
  # SUPPRESSED by a process that no longer exists.
  [ "$pidfile_pid" = "$$" ] && rm -f "$PIDFILE"
  # The filter file is judged on ITS OWN recorded owner, not on the pidfile.
  # During a replacement the pidfile still names the predecessor while the
  # successor's metadata is already on disk, so deciding by the pidfile lets the
  # predecessor delete a file it did not write.
  _ff="$RUN_DIR/watch.$SESSION_ID.filter"
  if [ -f "$_ff" ] && [ "$(sed -n '3p' "$_ff" 2>/dev/null || true)" = "$$" ]; then
    rm -f "$_ff" 2>/dev/null || true
  fi
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
#
# Keyed on the PID as well as the session id, because two watchers can hold the
# same session id at once: Monitor re-invoked for one session leaves the old
# watcher running until the successor kills it (#66), and both run cleanup. A
# stamp named for the session alone is one file they share, so the loser's EXIT
# trap deletes the winner's. `_install_changed` returns false when its stamp is
# missing, so the successor would go on running with the guard silently off --
# the same shape as the bug this guard exists for, and failing in the same
# reassuring direction. $PIDFILE and $READY_FILES carry ownership checks for
# exactly this; a per-process name gets it without a check to keep in sync.
# Found in review.
#
# A SIGKILLed watcher leaves its stamp behind, which is the same exposure the
# pidfile already has, and the file is empty.
INSTALL_STAMP="$RUN_DIR/.watch-start.$SESSION_ID.$$"
: > "$INSTALL_STAMP" 2>/dev/null || true

# True when anything under scripts/ was written after this watcher started.
# `-print -quit` stops at the first hit, so the common case is one stat-walk
# that exits early rather than a full tree scan every cycle.
_install_changed() {
  [ -f "$INSTALL_STAMP" ] || return 1
  [ -n "$(find "$SCRIPT_DIR" -newer "$INSTALL_STAMP" -print -quit 2>/dev/null)" ]
}

# True only once the install that touched scripts/ has FINISHED, not merely
# started (review finding: install.sh rewrites the tree over a window, #963,
# so watch.sh itself can already be executable while a sibling file it
# sources is still old, missing, or half-written -- _install_changed alone
# cannot tell "one file so far" from "the whole generation").
#
# VERSION is install.sh's own last write that touches anything under
# scripts/ (cp -R scripts/, then chmod, THEN VERSION -- confirmed by reading
# both its --update and fresh-install paths). No new marker to invent: an
# install that has finished leaves VERSION newer than everything it just
# copied, and one still mid-copy has not written it yet, or has not written
# it again since this watcher's own start.
#
# STRICTLY newer, not "at least as new as" (review finding, round 3): a
# non-strict comparison lets an OLD, unrelated VERSION whose timestamp
# happens to TIE with this watcher's own start -- a real possibility on a
# coarse-timestamp filesystem -- pass as "complete" the moment a later
# install's scripts write lands, before that install has written its OWN
# VERSION. A tie proves nothing either way, so it is treated as NOT
# complete: the one cost is that a genuinely-finished install landing in the
# very same clock tick as this watcher's own start falls back to today's
# visible exit instead of restarting -- rare, and no worse than before this
# PR, never a mixed-generation exec.
_install_complete() {
  local version_file="$SKILL_DIR/VERSION"
  [ -f "$version_file" ] || return 1
  [ "$version_file" -nt "$INSTALL_STAMP" ]
}

# True once BOTH a complete generation and an executable watch.sh are in
# place -- the two conditions a restart actually needs. Split out so the main
# handler below can ask "can I go now?" without repeating both checks.
_install_ready() {
  _install_complete && [ -x "$SCRIPT_DIR/watch.sh" ]
}

# How long an install that has started (changed files exist) but not yet
# finished (not _install_ready) is tolerated before falling back to the
# visible exit (review finding, round 4, #684 follow-up). install.sh writes
# scripts/ over many separate file operations before its own last write
# (VERSION); a watcher's poll can land in that window on essentially any real
# install, not just a rare half-written one, so committing to the visible
# exit the FIRST time this is observed was giving up too early.
#
# Time-based, not a poll count (#779's own reasoning applies here too): the
# poll interval is itself configurable, so a count-based bound would silently
# change how long this actually waits whenever the interval changes.
#
# Fixed production ceiling of 60s. The environment may only LOWER it, to an
# integer from 1 to 60 inclusive (review finding, round 5): anything else --
# non-numeric, zero, or above 60 -- is rejected back to 60, so an inherited or
# forged value can never raise or remove the bound. 3-or-more-digit input is
# rejected by pattern alone, before any numeric comparison, specifically so a
# very long digit string is never handed to `[ -gt ]`/`-lt` at all -- some
# shells' arithmetic evaluation is not guaranteed well-defined for arbitrarily
# large integers, and this avoids relying on it being.
AGMSG_WATCH_INSTALL_INCOMPLETE_TIMEOUT="${AGMSG_WATCH_INSTALL_INCOMPLETE_TIMEOUT:-60}"
case "$AGMSG_WATCH_INSTALL_INCOMPLETE_TIMEOUT" in
  [1-9]|[1-5][0-9]|60) ;;
  *) AGMSG_WATCH_INSTALL_INCOMPLETE_TIMEOUT=60 ;;
esac

# Time this cycle first observed "changed but not ready" -- empty means
# either nothing has changed yet, or it already resolved (readied and
# restarted, which never returns here to clear it -- exec starts a fresh
# process with this unset again -- so no explicit reset is needed there).
#
# Measured with $SECONDS, not `date +%s`: it needs no external command (so it
# has no failure mode to handle), but it is NOT a monotonic clock -- per
# bash's own manual, both the value recorded at shell startup and each later
# reference are obtained by querying the system clock, so an administrative
# clock change moves it exactly as it would move `date +%s`. The negative-
# elapsed handling below stays in place because of this, not despite it.
_INSTALL_INCOMPLETE_SINCE=""

# Fixed, internal, non-negotiable (review finding: an env-supplied limit can
# be forged or inherited from an unrelated process). Tagged with this exact
# (session id, pid) chain so a restart count inherited from a DIFFERENT
# watcher's chain -- e.g. a stray leaked environment variable -- is never
# mistaken for this one's own; exec preserves both session id and pid, so
# this chain's own count always matches itself across every restart in it.
_WATCH_INSTALL_RESTART_LIMIT=5
_WATCH_INSTALL_RESTART_CHAIN="$SESSION_ID.$$"

# Counts only CONSECUTIVE restarts: reset to zero the first time a cycle
# passes with nothing changed (see the main loop below), so an ordinary,
# well-spaced-out install is never more than one restart closer to the cap,
# no matter how many separate installs this watcher has already lived
# through.
_install_restart_count() {
  if [ "${AGMSG_WATCH_RESTART_CHAIN:-}" = "$_WATCH_INSTALL_RESTART_CHAIN" ]; then
    case "${AGMSG_WATCH_RESTART_COUNT:-}" in
      ''|*[!0-9]*) printf '0' ;;
      *) printf '%s' "$AGMSG_WATCH_RESTART_COUNT" ;;
    esac
  else
    printf '0'
  fi
}

_install_restart_count_reset() {
  [ -z "${AGMSG_WATCH_RESTART_COUNT:-}" ] && [ -z "${AGMSG_WATCH_RESTART_CHAIN:-}" ] && return 0
  unset AGMSG_WATCH_RESTART_COUNT AGMSG_WATCH_RESTART_CHAIN
}

# Restart on the new code in place of exiting (#684 follow-up). `exec` replaces
# this process image without forking, so there is never a moment with two
# watchers polling the same subscription, and the read cursor lives in the
# storage driver, not in this process, so a restart resumes from consumed
# state and delivers nothing twice, exactly as a manual restart already does
# today.
#
# `cleanup` (the EXIT trap's own function) runs BEFORE exec, releasing
# $PIDFILE/$FILTERFILE/$READY_FILES under THIS image's own naming -- exec
# skips the EXIT trap, so without this a future release that ever changes one
# of those paths or formats would orphan the old-named file forever, nobody
# left holding its name to clean it up. The new image re-creates all three
# fresh under whichever naming its own code uses, exactly as a freshly
# launched watcher would.
#
# The actas lock is deliberately NOT released here. Its lock file names this
# session's own owner token ($SESSION_ID), and exec changes neither that nor
# the pid, so the file stays continuously correct across the swap -- there is
# no window where it reads as free. The new image's own startup still calls
# actas_lock_claim for each pair it owns; since the recorded owner already
# equals its own sid, that call is a no-op self-confirmation (see
# _actas_lock_try_claim's existing==sid branch), never a fresh claim that
# could race a peer.
#
# This is scoped to today's lock ABI, unlike $PIDFILE/$FILTERFILE/$READY_FILES
# above: cleanup does not touch the lock at all, so nothing here migrates it.
# If a future release ever changes the lock's own path or format, the new
# image's claim can no longer be counted on to see existing==sid, and this
# self-restart path must not be used for that release -- it falls back to
# today's stop-and-manually-rearm behavior instead, same as before this PR.
#
# Not ready yet is NOT an immediate exit (review finding, round 4): it just
# returns, leaving the rest of this cycle's loop body -- the liveness guard,
# message delivery, the sleep -- to run exactly as it would have if nothing
# had changed. Delivery keeps working while an install is still in flight;
# only once AGMSG_WATCH_INSTALL_INCOMPLETE_TIMEOUT seconds have passed
# without ever becoming ready does this fall back to the ORIGINAL, unchanged
# exit -- a still-changing-past-the-timeout or genuinely broken install still
# produces the same clear stop it always has, rather than an indefinite wait.
#
# A negative elapsed reading (round 5: only possible if the system clock was
# moved backward mid-wait, since $SECONDS is wall-clock-based, not monotonic
# -- confirmed against bash's own manual) is treated the same as "timeout
# elapsed", not as "keep waiting": an elapsed time that cannot be trusted is
# exactly the case the visible exit exists for, the same reasoning as an
# install that is taking implausibly long.
_handle_install_changed() {
  local new_watch="$SCRIPT_DIR/watch.sh" restarts elapsed

  if _install_ready; then
    _INSTALL_INCOMPLETE_SINCE=""
    restarts="$(_install_restart_count)"
    if [ "$restarts" -lt "$_WATCH_INSTALL_RESTART_LIMIT" ]; then
      watch_log "the agmsg installation was updated while this watcher was running; restarting on the new code (same process, same subscription)."
      cleanup
      AGMSG_WATCH_RESTART_COUNT=$((restarts + 1))
      AGMSG_WATCH_RESTART_CHAIN="$_WATCH_INSTALL_RESTART_CHAIN"
      export AGMSG_WATCH_RESTART_COUNT AGMSG_WATCH_RESTART_CHAIN
      # The watch_report call below is reached only if exec itself fails to
      # replace the process image (e.g. an interpreter it can no longer
      # exec); it is the fallback for that failure, not dead code.
      # shellcheck disable=SC2093
      exec "$new_watch" "${ORIG_ARGS[@]}"
      watch_report "exec of the updated watch.sh failed; exiting instead of running stale code."
      exit 1
    fi
    watch_report "the agmsg installation kept changing across $restarts restart(s) in a row; exiting rather than looping. Restart this session (or run /agmsg actas <name>) to resume delivery."
    exit 0
  fi

  if [ -z "$_INSTALL_INCOMPLETE_SINCE" ]; then
    _INSTALL_INCOMPLETE_SINCE="$SECONDS"
    return 0
  fi
  elapsed=$((SECONDS - _INSTALL_INCOMPLETE_SINCE))
  if [ "$elapsed" -ge 0 ] && [ "$elapsed" -lt "$AGMSG_WATCH_INSTALL_INCOMPLETE_TIMEOUT" ]; then
    return 0
  fi

  watch_report "the agmsg installation was updated while this watcher was running, so it is still executing the code from before the update. Exiting rather than appearing to work. Restart this session (or run /agmsg actas <name>) to resume delivery."
  exit 0
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
  # The installation changed under us (#684). _handle_install_changed execs
  # the new watch.sh in place once it can prove the generation is finished,
  # so the stream never visibly stops; its own exit paths still report on
  # STDOUT (watch_report, not watch_log -- every launcher we ship sends this
  # watcher's stderr to /dev/null) so "the monitor stopped" is what the
  # session sees, instead of a live process silently delivering nothing.
  # Not-yet-ready is handled by returning rather than exiting, so this falls
  # through to the rest of the loop body below on a cycle spent waiting --
  # delivery is not paused while an install is still in flight.
  if _install_changed; then
    _handle_install_changed
  else
    # Reaching here means this cycle saw no change at all -- the "one clean
    # cycle" that ends a run of consecutive restarts (see
    # _install_restart_count above). A no-op on a watcher that never
    # restarted. Deliberately NOT run on a cycle spent waiting for
    # completion (the `if` branch above): the change is still pending, so
    # resetting the consecutive-restart count here would let a rapid
    # restart-wait-restart cycle dodge the cap it exists to enforce.
    _install_restart_count_reset
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
