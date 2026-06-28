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
#     this team+name via `ps -o args=`. A recycled pid (now an unrelated process)
#     fails the match and is left alone. The old code skipped the guard entirely
#     when meta was missing and killed the pid blindly — a PID-reuse footgun.
# Neither verifiable (pid already gone) → nothing to do. SIGTERM first (the bridge
# stops its work loop and any child it owns, e.g. codex's stdio app-server),
# SIGKILL fallback.
kill_headless_pid() {
  local pid="$1" team="$2" name="$3" type="${4:-codex}" meta meta_pid n=0 args
  meta="$SKILL_DIR/run/$type-bridge.$team.$name.meta"
  [ -f "$meta" ] && meta_pid="$(sed -n 's/^pid=//p' "$meta" 2>/dev/null)"
  kill -0 "$pid" 2>/dev/null || return 0
  if [ -n "${meta_pid:-}" ]; then
    if [ "$meta_pid" != "$pid" ]; then
      echo "despawn: recorded pid $pid != bridge meta pid $meta_pid for $team/$name — skipping kill (stale record?)" >&2
      return 0
    fi
  else
    args="$(ps -o args= -p "$pid" 2>/dev/null || true)"
    case "$args" in
      *"$type-bridge"*"--team $team"*"--name $name"*) ;;   # ours → proceed
      *)
        echo "despawn: pid $pid is not a $type-bridge for $team/$name and no meta confirms it — skipping kill (pid reuse?)" >&2
        return 0 ;;
    esac
  fi
  kill "$pid" 2>/dev/null || true
  while kill -0 "$pid" 2>/dev/null && [ "$n" -lt 5 ]; do sleep 1; n=$((n + 1)); done
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null || true
    echo "despawn: bridge pid $pid did not exit on SIGTERM — sent SIGKILL" >&2
  fi
}

# Kill the placement described by a record LINE ("<id>\t<proj>\t<type>"). ids are
# self-describing: %N pane, @N window, pid:<n> headless bridge worker. Operates on
# the LINE passed in, never a re-read of the file, so a caller that snapshotted
# the record (despawn --expect-record) tears down exactly what it verified.
kill_recorded_placement() {
  local id _proj _type
  IFS=$'\t' read -r id _proj _type <<<"${1-}"
  [ -n "$id" ] || return 1
  case "$id" in
    pid:*) kill_headless_pid "${id#pid:}" "$TEAM" "$NAME" "${_type:-codex}" ;;
    %*|@*)
      if command -v tmux >/dev/null 2>&1; then
        case "$id" in
          %*) tmux kill-pane   -t "$id" 2>/dev/null || true ;;
          @*) tmux kill-window -t "$id" 2>/dev/null || true ;;
        esac
      fi ;;
  esac
}

if [ "$FORCE" = "1" ]; then
  # Serialize against a concurrent spawn-record write (spawn.sh launch_headless),
  # so the compare and the rm below can't straddle a fresh lazy-respawn. Fail-open
  # on acquire timeout — the --expect-record compare is the backstop. Released on
  # every exit path, including the early skip.
  agmsg_placement_lock_acquire "$TEAM" "$NAME" 10 || true

  # Resolve the record line to act on. With --expect-record, the live record must
  # still equal the snapshot or we do nothing (a respawn replaced it); and we act
  # on the SNAPSHOT's fields, never a value re-read from the (possibly rewritten)
  # file. Without it, fall back to the live record (manual despawn).
  rec=""
  if [ "$EXPECT_SET" = "1" ]; then
    cur="$(cat "$SPAWN_REC" 2>/dev/null || true)"
    if [ "$cur" != "$EXPECT_RECORD" ]; then
      agmsg_placement_lock_release "$TEAM" "$NAME"
      echo "status=skipped name=$NAME team=$TEAM reason=record-changed"
      exit 0
    fi
    rec="$EXPECT_RECORD"
  else
    if [ ! -f "$SPAWN_REC" ]; then
      agmsg_placement_lock_release "$TEAM" "$NAME"
      die "no placement record for '$TEAM/$NAME' — nothing to force (was it launched via 'spawn'? graceful despawn does not need this)"
    fi
    rec="$(cat "$SPAWN_REC" 2>/dev/null || true)"
  fi

  IFS=$'\t' read -r _id _proj _type <<<"$rec"
  kill_recorded_placement "$rec"
  # Drop the member's registration, and release its (now-stale) lock.
  if [ -n "${_proj:-}" ] && [ -n "${_type:-}" ]; then
    "$SCRIPT_DIR/reset.sh" "$_proj" "$_type" "$NAME" >/dev/null 2>&1 || true
  fi
  owner="$(actas_lock_owner "$TEAM" "$NAME")"
  [ -n "$owner" ] && actas_lock_release "$TEAM" "$NAME" "$owner" 2>/dev/null || true
  # Also drop the role snapshot: a forced teardown may SIGKILL the bridge before
  # its own cleanup runs, so remove run/<type>-bridge.<team>.<name>.role here too.
  rm -f "$SPAWN_REC" "$SKILL_DIR/run/${_type:-codex}-bridge.$TEAM.$NAME.role" 2>/dev/null || true
  agmsg_placement_lock_release "$TEAM" "$NAME"
  echo "status=forced name=$NAME team=$TEAM"
  exit 0
fi

# --- Graceful ---
state="$(actas_lock_state "$TEAM" "$NAME" "" 2>/dev/null || echo free)"
case "$state" in
  free)
    echo "despawn: '$NAME' holds no live actas lock — nothing to confirm a teardown against (a codex member has no watcher; a tmux member may already be gone). If a window remains, use --force." >&2
    rm -f "$SPAWN_REC" 2>/dev/null || true
    echo "status=ok name=$NAME team=$TEAM note=no-live-lock"
    exit 0
    ;;
esac

"$SCRIPT_DIR/send.sh" "$TEAM" "$FROM" "$NAME" "ctrl:despawn" >/dev/null

waited=0
while true; do
  state="$(actas_lock_state "$TEAM" "$NAME" "" 2>/dev/null || echo free)"
  [ "$state" = "free" ] && break
  if [ "$waited" -ge "$TIMEOUT" ]; then
    echo "status=timeout name=$NAME team=$TEAM after=${TIMEOUT}s"
    echo "despawn: '$NAME' did not tear down within ${TIMEOUT}s — its watcher may be dead. Retry with --force." >&2
    exit 3
  fi
  sleep 1
  waited=$((waited + 1))
done

rm -f "$SPAWN_REC" 2>/dev/null || true
echo "status=ok name=$NAME team=$TEAM after=${waited}s"
