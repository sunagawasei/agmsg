#!/usr/bin/env bash
set -euo pipefail

# despawn.sh — tear down a spawned crew member, the inverse of spawn.sh.
#
# Usage:
#   despawn.sh <team> <from> <name> [--force] [--timeout <secs>]
#
#   <team>   team the member is in
#   <from>   the leader's own agent name (sender of the control message)
#   <name>   the member to tear down
#
# Default (graceful): send a `ctrl:despawn` control message to <name>. The
# member's watcher (watch.sh) sees it, drops its own role (releasing the actas
# lock) and folds its OWN pane through the terminal driver named by its placement
# record — so tmux AND herdr members fold themselves (a plain/OS-terminal member
# has no addressable pane, so it drops its role and its window is closed by hand).
# We block until the lock is released, up to --timeout; on timeout the member
# didn't respond (dead watcher, or a monitor=no member with no watcher) — re-run
# with --force. A `free` lock with a placement record is NOT proof the member is
# gone (a monitor=no type never holds one): that reports `needs-force` and KEEPS
# the record, rather than a false `ok` (#625).
#
# --force: skip the message and tear the member down from here through the
# terminal driver named by the placement record. The teardown must be CONFIRMED
# (the ref resolves to a terminal, the driver loads, and terminal_despawn exits 0)
# BEFORE the record / registration / lock are dropped — an unconfirmed teardown
# keeps all three and reports `status=error`, so the record (the only retry
# authority) is never deleted out from under a pane that is still alive (#625, the
# --force side). For when the member's watcher can't respond.
#
# --expect-record <line> (force only): a compare-and-act guard. The live spawn
# record must still equal <line> exactly, or despawn does nothing and reports
# status=skipped reason=record-changed. kill/reset/rm then act ONLY on the id/
# proj/type parsed from <line>, never a value re-read from the file. This lets a
# DETACHED teardown (session-end's worker) snapshot the record at hook time and
# safely refuse to tear down a worker that a fast lazy-respawn replaced in the
# meantime. The whole force section runs under a placement lock so the compare
# and the rm are atomic against a concurrent spawn-record write.
#
# See #109.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"  # actas-lock.sh requires SKILL_DIR
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/actas-lock.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/identity-key.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/inflight.sh"
source "$SCRIPT_DIR/lib/terminal-registry.sh"  # kill via the terminal driver

die() { echo "despawn: $*" >&2; exit 1; }

TEAM="${1:-}"; FROM="${2:-}"; NAME="${3:-}"
[ -n "$TEAM" ] && [ -n "$FROM" ] && [ -n "$NAME" ] \
  || die "Usage: despawn.sh <team> <from> <name> [--force] [--timeout <secs>]"
shift 3 || true

FORCE=0
TIMEOUT=30
EXPECT_RECORD=""        # --expect-record <line>: compare-and-act guard (force only)
EXPECT_SET=0
EXPECT_BRIDGE_START=""  # --expect-bridge-start <token>: live PID generation guard
EXPECT_BRIDGE_START_SET=0
while [ $# -gt 0 ]; do
  case "$1" in
    --force) FORCE=1; shift ;;
    --timeout) TIMEOUT="${2:?--timeout needs seconds}"; shift 2 ;;
    --expect-record) EXPECT_RECORD="${2-}"; EXPECT_SET=1; shift 2 ;;
    --expect-bridge-start) EXPECT_BRIDGE_START="${2-}"; EXPECT_BRIDGE_START_SET=1; shift 2 ;;
    *) die "unknown option: $1" ;;
  esac
done
case "$TIMEOUT" in ''|*[!0-9]*) die "--timeout must be a whole number of seconds" ;; esac

SPAWN_REC="$(agmsg_spawn_path "$TEAM" "$NAME")"

# A plain/non-watchdog despawn is an intentional stop and therefore invalidates
# a pending watchdog recovery reservation once teardown is confirmed or safely
# skipped. An unverified force attempt preserves it along with every other
# target artifact. A watchdog-scoped call carries its owner token and never
# invalidates an intent here; after compare-and-act, watchdog removes only the
# reservation that still matches its exact owner/record stamp.
WATCHDOG_TOKEN="${AGMSG_WATCHDOG_INTENT_TOKEN:-}"
WATCHDOG_INTENT=""
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/validate.sh"
if agmsg_validate_team_name "$TEAM" >/dev/null 2>&1 \
    && agmsg_validate_agent_name "$NAME" >/dev/null 2>&1; then
  WATCHDOG_INTENT="$SKILL_DIR/run/watchdog.$TEAM.$NAME.intent"
fi

# Headless codex workers (recorded as pid:<n>) have no watcher to answer a
# ctrl:despawn — the graceful path's free-lock branch would just drop the record
# and leave the bridge running. Promote to the force path so we actually stop it.
if [ "$FORCE" != "1" ] && [ -f "$SPAWN_REC" ]; then
  IFS=$'\t' read -r _hid _ _ < "$SPAWN_REC"
  case "$_hid" in pid:*) FORCE=1 ;; esac
fi

# Stop a headless bridge worker (placement recorded as pid:<n>) safely. Works for
# any headless type: the meta file and the process command line are both named
# `<type>-bridge` (codex-bridge.js, cursor-bridge.sh, …), so the type — parsed
# from the spawn record's 3rd field and passed in as $4 — selects which to check.
# Guard against PID reuse two ways before killing:
#   - meta present: the bridge's meta pid must equal the recorded pid, else the
#     record is stale (a re-spawn updated meta but not the placement) — skip.
#   - meta absent/empty: confirm the live pid's command line IS our bridge for
#     this team+name via the opaque --identity-key emitted by both headless
#     spawners. A recycled pid (now an unrelated process) fails the match and is
#     left alone. The old code skipped the guard entirely when meta was missing
#     and killed the pid blindly — a PID-reuse footgun.
# Return 0 when absence is confirmed, 2 for a confirmed identity mismatch, and
# 4 when identity or post-signal absence cannot be verified. SIGTERM comes
# first (the bridge stops its work loop and any child it owns, e.g. codex's
# stdio app-server), with SIGKILL as fallback.
kill_headless_pid() {
  local pid="$1" team="$2" name="$3" type="${4:-codex}" meta meta_pid n=0 args identity_key
  local kill_poll_interval kill_poll_max
  local -a argv=() arg
  local bridge_token=0 identity_token=0 expect_identity=0
  local current_start="" expect_method current_method
  kill_poll_interval="$(agmsg_wait_knob_resolve \
    "${AGMSG_KILL_POLL_INTERVAL-}" 1 0.01 60 decimal)"
  kill_poll_max="$(agmsg_wait_knob_resolve \
    "${AGMSG_KILL_POLL_MAX-}" 5 1 10000 integer)"
  case "$pid" in
    ''|*[!0-9]*)
      echo "despawn: invalid headless pid '$pid' for $team/$name — identity unverified" >&2
      return 4 ;;
  esac
  if ! [ "$pid" -gt 0 ] 2>/dev/null; then
    echo "despawn: invalid headless pid '$pid' for $team/$name — identity unverified" >&2
    return 4
  fi
  meta="$SKILL_DIR/run/$type-bridge.$team.$name.meta"
  [ -f "$meta" ] && meta_pid="$(sed -n 's/^pid=//p' "$meta" 2>/dev/null)"
  _agmsg_pid_alive "$pid" || return 0
  if [ -n "${meta_pid:-}" ]; then
    if [ "$meta_pid" != "$pid" ]; then
      echo "despawn: recorded pid $pid != bridge meta pid $meta_pid for $team/$name — skipping kill (stale record?)" >&2
      return 2
    fi
  else
    identity_key="$(agmsg_identity_key "$team" "$name")"
    if ! args="$(ps -ww -o args= -p "$pid" 2>/dev/null)" || [ -z "$args" ]; then
      echo "despawn: could not inspect argv for live pid $pid for $team/$name — identity unverified" >&2
      return 4
    fi
    # ps returns a command-line rendering, so split it into argv-like tokens and
    # require both markers as complete tokens. Bridge launchers use one of the
    # known script extensions; a prefix/suffix near-match is not our bridge.
    read -r -a argv <<<"$args" || true
    if [ "${#argv[@]}" -eq 0 ]; then
      echo "despawn: could not inspect argv for live pid $pid for $team/$name — identity unverified" >&2
      return 4
    fi
    for arg in "${argv[@]}"; do
      if [ "$expect_identity" = 1 ]; then
        [ "$arg" = "$identity_key" ] && identity_token=1
        expect_identity=0
        continue
      fi
      [ "$arg" = "--identity-key" ] && expect_identity=1
      case "$arg" in
        "$type-bridge"|*/"$type-bridge"|"$type-bridge".js|*/"$type-bridge".js|"$type-bridge".sh|*/"$type-bridge".sh)
          bridge_token=1 ;;
      esac
    done
    if [ "$bridge_token" != 1 ]; then
      echo "despawn: pid $pid is not a $type-bridge for $team/$name and no meta confirms it — skipping kill (pid reuse?)" >&2
      return 2
    fi
    # A visible bridge with no matching identity may be truncated or redacted.
    if [ "$identity_token" != 1 ]; then
      echo "despawn: could not verify the $type-bridge identity for live pid $pid for $team/$name — identity unverified" >&2
      return 4
    fi
  fi
  if [ "${EXPECT_BRIDGE_START_SET:-0}" = 1 ]; then
    if [ -z "${EXPECT_BRIDGE_START:-}" ]; then
      echo "despawn: --expect-bridge-start is empty for live pid $pid for $team/$name — identity unverified" >&2
      return 4
    fi
    current_start="$(agmsg_pid_start_token "$pid" 2>/dev/null)" || {
      echo "despawn: could not read start token for live pid $pid for $team/$name — identity unverified" >&2
      return 4
    }
    expect_method="$(agmsg_pid_start_token_method "$EXPECT_BRIDGE_START" 2>/dev/null || true)"
    current_method="$(agmsg_pid_start_token_method "$current_start" 2>/dev/null || true)"
    if [ -z "$expect_method" ] || [ -z "$current_method" ] \
        || [ "$expect_method" != "$current_method" ]; then
      echo "despawn: start-token method unverifiable for live pid $pid for $team/$name — skipping kill" >&2
      return 4
    fi
    if [ "$current_start" != "$EXPECT_BRIDGE_START" ]; then
      echo "despawn: live pid $pid for $team/$name is a different process generation — skipping kill" >&2
      return 5
    fi
    current_start="$(agmsg_pid_start_token "$pid" 2>/dev/null)" || {
      echo "despawn: could not re-read start token for live pid $pid for $team/$name — identity unverified" >&2
      return 4
    }
    if [ "$current_start" != "$EXPECT_BRIDGE_START" ]; then
      echo "despawn: live pid $pid for $team/$name is a different process generation — skipping kill" >&2
      return 5
    fi
  fi
  kill "$pid" 2>/dev/null || true
  while _agmsg_pid_alive "$pid" && [ "$n" -lt "$kill_poll_max" ]; do
    sleep "$kill_poll_interval"
    n=$((n + 1))
  done
  if _agmsg_pid_alive "$pid"; then
    if [ "${EXPECT_BRIDGE_START_SET:-0}" = 1 ]; then
      current_start="$(agmsg_pid_start_token "$pid" 2>/dev/null)" || {
        echo "despawn: could not re-read start token before SIGKILL for live pid $pid for $team/$name — identity unverified" >&2
        return 4
      }
      if [ "$current_start" != "$EXPECT_BRIDGE_START" ]; then
        echo "despawn: live pid $pid for $team/$name is a different process generation — skipping SIGKILL" >&2
        return 5
      fi
    fi
    kill -9 "$pid" 2>/dev/null || true
    echo "despawn: bridge pid $pid did not exit on SIGTERM — sent SIGKILL" >&2
    n=0
    while _agmsg_pid_alive "$pid" && [ "$n" -lt "$kill_poll_max" ]; do
      sleep "$kill_poll_interval"
      n=$((n + 1))
    done
  fi
  _agmsg_pid_alive "$pid" || return 0
  echo "despawn: bridge pid $pid is still alive after signals — teardown unverified" >&2
  return 4
}

# Retire the bridge's persistent per-identity state: failstate streak counters
# and spooled outbound payloads. These deliberately survive the bridge's own EXIT
# cleanup and a crash/lazy-respawn (so a broken-message streak or an undelivered
# payload is not forgotten); only a sanctioned permanent teardown — this script,
# which session-end's worker also calls with --force — retires them. Glob over
# the type prefix (cursor-bridge/codex-bridge/…) so the state cannot strand if
# the member's type changed across respawns.
gc_bridge_state() {
  rm -f "$SKILL_DIR/run/"*"-bridge.$TEAM.$NAME.failstate" \
        "$SKILL_DIR/run/"*"-bridge.$TEAM.$NAME.outbound."* 2>/dev/null || true
}

# What does the terminal say about the recorded pane, RIGHT NOW? Read only —
# nothing is closed here.
#
# Prints one of: no-record / gone / present / unknown.
#
# It resolves the record the same way kill_recorded_placement does, and stops
# short of the kill. `terminal_despawn` cannot be used for this: measured on a
# throwaway tmux server, `kill-pane` returns non-zero both for a pane that is
# already gone and for one it could not close, and the driver maps both to 13.
# Asking with it would make a graceful teardown that WORKED report needs-force.
recorded_pane_state() {
  [ -f "$SPAWN_REC" ] || { printf 'no-record'; return 0; }
  local id _proj _type _fence _term _bare _out _rc=0
  IFS=$'\t' read -r id _proj _type _fence < "$SPAWN_REC"
  [ -n "$id" ] || { printf 'unknown'; return 0; }
  _term="$(agmsg_terminal_ref_terminal "$id")" || { printf 'unknown'; return 0; }
  _bare="$(agmsg_terminal_ref_id "$id")"       || { printf 'unknown'; return 0; }
  agmsg_terminal_load "$_term" 2>/dev/null     || { printf 'unknown'; return 0; }
  declare -F terminal_pane_state >/dev/null 2>&1 || { printf 'unknown'; return 0; }
  _out="$(terminal_pane_state "$_bare" 2>/dev/null)" || _rc=$?
  # The token is the answer and the code says whether it is a settled one. A
  # non-zero (13 unsupported, 10 unreachable) is NOT an answer about the pane,
  # whatever was printed.
  [ "$_rc" -eq 0 ] || { printf 'unknown'; return 0; }
  case "$_out" in
    gone|present) printf '%s' "$_out" ;;
    *)            printf 'unknown' ;;
  esac
  return 0
}

# Kill the placement described by a record LINE ("<id>\t<proj>\t<type>[\t<fence>]").
# ids are self-describing: pid:<n> headless bridge worker, otherwise a
# <terminal>:<id> (or legacy bare %N/@N) pane through the terminal-driver registry.
# Operates on the LINE passed in, never a re-read of the file, so a caller that
# snapshotted the record (despawn --expect-record) tears down exactly what it verified.
# Returns 0 when the placement is confirmed gone; a pid: placement returns
# kill_headless_pid's 2/4/5. A pane teardown the terminal did not confirm (the ref did
# not resolve, the driver would not load, or terminal_despawn failed) returns 6 and
# leaves the reason in KILL_RECORDED_REASON: the caller must keep the record, which
# is the only retry authority.
kill_recorded_placement() {
  local id _proj _type _fence _term _bare _reason="" result=0
  IFS=$'\t' read -r id _proj _type _fence <<<"${1-}"
  [ -n "$id" ] || return 4
  KILL_RECORDED_REASON=""
  case "$id" in
    pid:*)
      if kill_headless_pid "${id#pid:}" "$TEAM" "$NAME" "${_type:-codex}"; then
        result=0
      else
        result=$?
      fi
      ;;
    *)
      _term="$(agmsg_terminal_ref_terminal "$id")" || return 6   # unknown/corrupt ref
      _bare="$(agmsg_terminal_ref_id "$id")"
      agmsg_terminal_load "$_term" 2>/dev/null || return 6       # driver would not load
      _reason="$(terminal_despawn "$_bare" "$_fence" 2>&1)" || {
        KILL_RECORDED_REASON="$_reason"
        return 6
      }
      ;;
  esac
  return "$result"
}

if [ "$FORCE" = "1" ]; then
  # Serialize against a concurrent spawn-record write (spawn.sh launch_headless),
  # so the compare and the rm below can't straddle a fresh lazy-respawn.
  # Compare-and-act recovery (--expect-record) fail-closes if the lock cannot
  # be held: the record compare is not a substitute for excluding a concurrent
  # spawn rewrite.
  placement_lock_held=0
  if agmsg_placement_lock_acquire "$TEAM" "$NAME" 10; then
    placement_lock_held=1
  elif [ "$EXPECT_SET" = 1 ]; then
    # A stale --expect-record snapshot is a safe no-op: compare without holding
    # the placement lock so we never rmdir a lock directory we failed to create.
    cur="$(cat "$SPAWN_REC" 2>/dev/null || true)"
    if [ "$cur" != "$EXPECT_RECORD" ]; then
      echo "status=skipped name=$NAME team=$TEAM reason=record-changed"
      exit 0
    fi
    echo "status=unverified name=$NAME team=$TEAM reason=placement-lock"
    exit 4
  fi

  # Resolve the record line to act on. With --expect-record, the live record must
  # still equal the snapshot or we do nothing (a respawn replaced it); and we act
  # on the SNAPSHOT's fields, never a value re-read from the (possibly rewritten)
  # file. Without it, fall back to the live record (manual despawn).
  rec=""
  if [ "$EXPECT_SET" = "1" ]; then
    cur="$(cat "$SPAWN_REC" 2>/dev/null || true)"
    if [ "$cur" != "$EXPECT_RECORD" ]; then
      if [ "$placement_lock_held" -eq 1 ]; then
        agmsg_placement_lock_release "$TEAM" "$NAME"
      fi
      [ -n "$WATCHDOG_INTENT" ] && [ -z "$WATCHDOG_TOKEN" ] \
        && rm -f -- "$WATCHDOG_INTENT" 2>/dev/null || true
      echo "status=skipped name=$NAME team=$TEAM reason=record-changed"
      exit 0
    fi
    rec="$EXPECT_RECORD"
  else
    if [ ! -f "$SPAWN_REC" ]; then
      if [ "$placement_lock_held" -eq 1 ]; then
        agmsg_placement_lock_release "$TEAM" "$NAME"
      fi
      [ -n "$WATCHDOG_INTENT" ] && [ -z "$WATCHDOG_TOKEN" ] \
        && rm -f -- "$WATCHDOG_INTENT" 2>/dev/null || true
      die "no placement record for '$TEAM/$NAME' — nothing to force (was it launched via 'spawn'? graceful despawn does not need this)"
    fi
    rec="$(cat "$SPAWN_REC" 2>/dev/null || true)"
  fi

  IFS=$'\t' read -r _id _proj _type _fence <<<"$rec"
  placement_result=0
  if kill_recorded_placement "$rec"; then
    placement_result=0
  else
    placement_result=$?
  fi
  if [ "$placement_result" -eq 4 ]; then
    if [ "$placement_lock_held" -eq 1 ]; then
      agmsg_placement_lock_release "$TEAM" "$NAME"
    fi
    echo "status=unverified name=$NAME team=$TEAM reason=process-state"
    exit 4
  fi
  if [ "$placement_result" -eq 5 ]; then
    if [ "$placement_lock_held" -eq 1 ]; then
      agmsg_placement_lock_release "$TEAM" "$NAME"
    fi
    echo "status=skipped name=$NAME team=$TEAM reason=bridge-generation-changed"
    exit 5
  fi
  if [ "${EXPECT_BRIDGE_START_SET:-0}" = 1 ] && [ "$placement_result" -eq 2 ]; then
    if [ "$placement_lock_held" -eq 1 ]; then
      agmsg_placement_lock_release "$TEAM" "$NAME"
    fi
    echo "status=unverified name=$NAME team=$TEAM reason=identity-mismatch"
    exit 2
  fi
  if [ "$placement_result" -eq 6 ]; then
    # Teardown NOT confirmed. Keep the record (the only retry authority), the
    # registration and the lock, and say so — never claim a forced teardown that did
    # not happen (the #625 shape, on the --force side).
    if [ "$placement_lock_held" -eq 1 ]; then
      agmsg_placement_lock_release "$TEAM" "$NAME"
    fi
    echo "despawn: could not confirm '$NAME' was torn down via its placement record ($_id) — the terminal driver did not report the pane closed (unknown/corrupt ref, the driver would not load, or the terminal returned an error).${KILL_RECORDED_REASON:+ Reason: $KILL_RECORDED_REASON} The record is KEPT so you can retry; check the pane manually." >&2
    echo "status=error name=$NAME team=$TEAM note=force-teardown-unconfirmed"
    exit 1
  fi
  [ -n "$WATCHDOG_INTENT" ] && [ -z "$WATCHDOG_TOKEN" ] \
    && rm -f -- "$WATCHDOG_INTENT" 2>/dev/null || true
  # Confirmed kill (or already-dead placement): dead-letter outstanding turns.
  # Identity mismatch / generation change never reach here. Notices use --force
  # and an inflight outbox, so they do not need the spawn record we are about
  # to delete.
  agmsg_inflight_deadletter_for "$TEAM" "$NAME" || true
  # Drop the member's registration, and release its (now-stale) lock.
  if [ -n "${_proj:-}" ] && [ -n "${_type:-}" ]; then
    # Internal teardown must not remove an equivalent registration in another team.
    if [ "$_type" = "claude-code" ]; then
      AGMSG_RESOLVE_PROJECT=0 \
        "$SCRIPT_DIR/reset.sh" --team "$TEAM" "$_proj" "$_type" "$NAME" >/dev/null 2>&1 || true
    else
      "$SCRIPT_DIR/reset.sh" --team "$TEAM" "$_proj" "$_type" "$NAME" >/dev/null 2>&1 || true
    fi
  fi
  # Releasing needs an owner we actually READ: `actas_lock_owner` answered "" for
  # "no lock", "unreadable" and "empty" alike. (#983)
  _own_r="$(actas_lock_read "$TEAM" "$NAME")"
  if [ "${_own_r%%$'\t'*}" = "ok" ] && [ -n "${_own_r#*$'\t'}" ]; then
    actas_lock_release "$TEAM" "$NAME" "${_own_r#*$'\t'}" 2>/dev/null || true
  fi
  # Also drop the role snapshot: a forced teardown may SIGKILL the bridge before
  # its own cleanup runs, so remove run/<type>-bridge.<team>.<name>.role here too.
  rm -f "$SPAWN_REC" "$SKILL_DIR/run/${_type:-codex}-bridge.$TEAM.$NAME.role" 2>/dev/null || true
  gc_bridge_state
  if [ "$placement_lock_held" -eq 1 ]; then
    agmsg_placement_lock_release "$TEAM" "$NAME"
  fi
  echo "status=forced name=$NAME team=$TEAM"
  exit 0
fi

# --- Graceful ---
[ -n "$WATCHDOG_INTENT" ] && [ -z "$WATCHDOG_TOKEN" ] \
  && rm -f -- "$WATCHDOG_INTENT" 2>/dev/null || true
# No `|| echo free`: a failed classification is not "the lock is free". This
# branch decides whether to send a `ctrl:despawn` at all, and `free` is the arm
# that concludes the member is already gone. `unknown:` must not reach it — an
# unverified state is a reason to stop and say so, not to act. (#983)
state="$(actas_lock_state "$TEAM" "$NAME" "" 2>/dev/null)" || state="unknown:state_call_failed"
case "$state" in
  unknown:*)
    echo "despawn: '$NAME' — could not determine who holds this role (${state#unknown:}); not sending ctrl:despawn. Check the lock and retry." >&2
    echo "status=error name=$NAME team=$TEAM note=lock-state-unknown"
    exit 1
    ;;
  free)
    # #625: a free actas lock does NOT prove the member is gone. A monitor=no type
    # (cursor, codex) never runs a watcher and so NEVER holds a lock; a member whose
    # watcher merely died reads identically. So split on the placement record — the
    # positive evidence that something was spawned and may still be running.
    if [ -f "$SPAWN_REC" ]; then
      # A pane/process was placed and is likely still there. Do NOT delete the record
      # (--force reads exactly this — deleting it here is what made the advised
      # recovery impossible), and do NOT report a teardown we did not perform.
      echo "despawn: '$NAME' holds no live actas lock, but a placement record remains — graceful despawn cannot confirm a teardown (a monitor=no member such as cursor/codex never holds a lock; a watcher may have died). Retry with --force to tear it down via the record, which is kept intact." >&2
      echo "status=needs-force name=$NAME team=$TEAM note=no-live-lock-recorded"
      exit 1
    fi
    # No placement record: nothing was spawned here to tear down (a hand-joined
    # member, or one already gone). The free lock is all there is to act on.
    echo "despawn: '$NAME' holds no live actas lock and has no placement record — nothing to tear down here (if a window remains, it was not launched via spawn; close it directly)." >&2
    agmsg_inflight_deadletter_for "$TEAM" "$NAME" || true
    gc_bridge_state
    echo "status=ok name=$NAME team=$TEAM note=no-live-lock"
    exit 0
    ;;
esac

"$SCRIPT_DIR/send.sh" "$TEAM" "$FROM" "$NAME" "ctrl:despawn" >/dev/null

despawn_poll_interval="$(agmsg_wait_knob_resolve \
  "${AGMSG_DESPAWN_WAIT_POLL_INTERVAL-}" 1 0.01 60 decimal)"
wait_started=""
wait_last=""
wait_now=""
wait_elapsed=0
while true; do
  # `free` here means "the watcher let go, teardown is progressing". An
  # unverified state is NOT that, and `|| echo free` made every failed read look
  # like success — the wait would end and despawn would report done. Keep
  # waiting instead: the timeout below is the honest end of this loop. (#983)
  state="$(actas_lock_state "$TEAM" "$NAME" "" 2>/dev/null)" || state="unknown:state_call_failed"
  [ "$state" = "free" ] && break
  if ! wait_now="$(_agmsg_wait_epoch_seconds)"; then
    echo "status=timeout name=$NAME team=$TEAM after=${wait_elapsed}s"
    echo "despawn: '$NAME' could not read wall-clock time while waiting for teardown" >&2
    exit 3
  fi
  if [ -z "$wait_started" ]; then
    wait_started="$wait_now"
    wait_last="$wait_now"
    wait_elapsed=0
  elif [ "$wait_now" -lt "$wait_last" ]; then
    # A backward wall-clock adjustment resets the local baseline instead of
    # retaining a future deadline that could wedge graceful teardown.
    wait_started="$wait_now"
    wait_last="$wait_now"
    wait_elapsed=0
  else
    wait_last="$wait_now"
    wait_elapsed=$((wait_now - wait_started))
  fi
  if [ "$wait_elapsed" -ge "$TIMEOUT" ]; then
    echo "status=timeout name=$NAME team=$TEAM after=${wait_elapsed}s"
    echo "despawn: '$NAME' did not tear down within ${TIMEOUT}s — its watcher may be dead. Retry with --force." >&2
    exit 3
  fi
  sleep "$despawn_poll_interval"
done

# The lock going free means the watcher let go of it. It does NOT mean the pane
# was closed: the watcher releases the lock (via reset.sh) BEFORE it tries to
# close anything, and a lock whose owner has died reads as free too. Deleting the
# record on that signal is what made #1051 unrecoverable — the record is the only
# thing `--force` can work from, and it was gone before anyone knew the pane was
# still open.
#
# So ask the terminal. The record is deleted, and success reported, only when the
# answer is a settled `gone`.
#
# And ask it MORE THAN ONCE. The watcher releases the lock before it folds its
# pane, so the moment this loop is reached the pane is still `present` on a
# graceful teardown that is working correctly — measured on a live herdr session
# it stayed for tens of seconds (#1097). Checking once here reported `needs-force`
# every time, teaching everyone to reach for --force (which skips the member's own
# cleanup — the exact habit the graceful path exists to avoid). So wait for the
# pane to actually go, drawing from the SAME --timeout budget the lock wait used
# (the timeout covers the pane wait, not only the lock wait): `waited` is not
# reset. Only a pane still `present` when that budget is spent is a real
# needs-force. `unknown` is NOT polled — it means the terminal could not be asked
# at all (unsupported/unreachable), where waiting cannot change the answer and
# would only burn the whole timeout before the same needs-force.
waited="$wait_elapsed"
_pane_state="$(recorded_pane_state)"
while [ "$_pane_state" = "present" ] && [ "$waited" -lt "$TIMEOUT" ]; do
  sleep 1
  waited=$((waited + 1))
  _pane_state="$(recorded_pane_state)"
done
case "$_pane_state" in
  no-record|gone)
    agmsg_inflight_deadletter_for "$TEAM" "$NAME" || true
    rm -f "$SPAWN_REC" 2>/dev/null || true
    gc_bridge_state
    # Asking whether the record MAY go and checking that it WENT are two
    # different questions, and this branch used to answer only the first. A
    # record left behind (a read-only run dir, a permission failure) outlives
    # the pane it names, and the next `--force` reads it as a live placement and
    # tries to tear down a pane that is already gone — the same "reported
    # success, left the caller a wrong authority" shape this whole change is
    # about. So assert the STATE, not `rm`'s exit code.
    if [ -e "$SPAWN_REC" ]; then
      echo "despawn: '$NAME' was torn down, but its placement record at $SPAWN_REC could not be removed. The record now names a pane that is gone, and --force would act on it; delete it by hand." >&2
      echo "status=error name=$NAME team=$TEAM note=record-not-removed after=${waited}s"
      exit 1
    fi
    echo "status=ok name=$NAME team=$TEAM after=${waited}s"
    ;;
  present)
    echo "despawn: '$NAME' released its lock but the recorded pane is STILL OPEN after ${waited}s — the teardown did not fold the window within the timeout. The placement record is kept; retry with --force to tear it down through it." >&2
    echo "status=needs-force name=$NAME team=$TEAM note=pane-still-open after=${waited}s"
    exit 1
    ;;
  *)
    # Deliberately a different sentence from `present`: the operator's next move
    # differs. "Still open" says close it; "could not check" says look.
    echo "despawn: '$NAME' released its lock, but this terminal could not be asked whether the pane closed, so the teardown is unconfirmed. The placement record is kept; check the window, and use --force if it is still there." >&2
    echo "status=needs-force name=$NAME team=$TEAM note=teardown-unverified after=${waited}s"
    exit 1
    ;;
esac
