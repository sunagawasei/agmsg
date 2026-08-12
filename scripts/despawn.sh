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
# lock) and closes its own tmux pane — ending its CLI. We block until the lock
# is released, up to --timeout (default 30s); on timeout the member didn't
# respond (dead watcher, or a codex member with no Monitor) — re-run with
# --force.
#
# --force: skip the message and tear the member down from here using the
# placement recorded at spawn time — kill its tmux pane/window and drop its
# registration. For when the member's watcher can't respond.
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
# See #109. Graceful teardown's full pane-close is tmux-only (the member needs a
# tmux pane to close); an OS-terminal member drops its role but its window must
# be closed by hand.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"  # actas-lock.sh requires SKILL_DIR
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/actas-lock.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/identity-key.sh"

die() { echo "despawn: $*" >&2; exit 1; }

TEAM="${1:-}"; FROM="${2:-}"; NAME="${3:-}"
[ -n "$TEAM" ] && [ -n "$FROM" ] && [ -n "$NAME" ] \
  || die "Usage: despawn.sh <team> <from> <name> [--force] [--timeout <secs>]"
shift 3 || true

FORCE=0
TIMEOUT=30
EXPECT_RECORD=""        # --expect-record <line>: compare-and-act guard (force only)
EXPECT_SET=0
while [ $# -gt 0 ]; do
  case "$1" in
    --force) FORCE=1; shift ;;
    --timeout) TIMEOUT="${2:?--timeout needs seconds}"; shift 2 ;;
    --expect-record) EXPECT_RECORD="${2-}"; EXPECT_SET=1; shift 2 ;;
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
  kill "$pid" 2>/dev/null || true
  while _agmsg_pid_alive "$pid" && [ "$n" -lt "$kill_poll_max" ]; do
    sleep "$kill_poll_interval"
    n=$((n + 1))
  done
  if _agmsg_pid_alive "$pid"; then
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

# Kill the placement described by a record LINE ("<id>\t<proj>\t<type>"). ids are
# self-describing: %N pane, @N window, pid:<n> headless bridge worker. Operates on
# the LINE passed in, never a re-read of the file, so a caller that snapshotted
# the record (despawn --expect-record) tears down exactly what it verified.
kill_recorded_placement() {
  local id _proj _type result=0
  IFS=$'\t' read -r id _proj _type <<<"${1-}"
  [ -n "$id" ] || return 4
  case "$id" in
    pid:*)
      if kill_headless_pid "${id#pid:}" "$TEAM" "$NAME" "${_type:-codex}"; then
        result=0
      else
        result=$?
      fi
      ;;
    herdr:*)
      command -v herdr >/dev/null 2>&1 && herdr pane close "${id#herdr:}" 2>/dev/null || true
      ;;
    %*|@*)
      if command -v tmux >/dev/null 2>&1; then
        case "$id" in
          %*) tmux kill-pane   -t "$id" 2>/dev/null || true ;;
          @*) tmux kill-window -t "$id" 2>/dev/null || true ;;
        esac
      fi ;;
  esac
  printf '%s\t%s\t%s\n' "$id" "$_proj" "$_type"
  return "$result"
}

if [ "$FORCE" = "1" ]; then
  # Serialize against a concurrent spawn-record write (spawn.sh launch_headless),
  # so the compare and the rm below can't straddle a fresh lazy-respawn. Fail-open
  # on acquire timeout — the --expect-record compare is the backstop. Release on
  # every exit path only when this process acquired the lock.
  placement_lock_held=0
  if agmsg_placement_lock_acquire "$TEAM" "$NAME" 10; then
    placement_lock_held=1
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

  IFS=$'\t' read -r _id _proj _type <<<"$rec"
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
  [ -n "$WATCHDOG_INTENT" ] && [ -z "$WATCHDOG_TOKEN" ] \
    && rm -f -- "$WATCHDOG_INTENT" 2>/dev/null || true
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
  owner="$(actas_lock_owner "$TEAM" "$NAME")"
  [ -n "$owner" ] && actas_lock_release "$TEAM" "$NAME" "$owner" 2>/dev/null || true
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
state="$(actas_lock_state "$TEAM" "$NAME" "" 2>/dev/null || echo free)"
case "$state" in
  free)
    echo "despawn: '$NAME' holds no live actas lock — nothing to confirm a teardown against (a codex member has no watcher; a tmux member may already be gone). If a window remains, use --force." >&2
    rm -f "$SPAWN_REC" 2>/dev/null || true
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
  state="$(actas_lock_state "$TEAM" "$NAME" "" 2>/dev/null || echo free)"
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

rm -f "$SPAWN_REC" 2>/dev/null || true
gc_bridge_state
# Refresh telemetry after a successful state transition when the clock is
# still readable; success itself must not be turned into a failure by a clock
# error after the member released its role.
if [ -n "$wait_started" ] && wait_now="$(_agmsg_wait_epoch_seconds)"; then
  if [ "$wait_now" -lt "$wait_last" ]; then
    wait_elapsed=0
  else
    wait_elapsed=$((wait_now - wait_started))
  fi
fi
echo "status=ok name=$NAME team=$TEAM after=${wait_elapsed}s"
