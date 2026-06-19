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
while [ $# -gt 0 ]; do
  case "$1" in
    --force) FORCE=1; shift ;;
    --timeout) TIMEOUT="${2:?--timeout needs seconds}"; shift 2 ;;
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

# Stop a headless codex bridge worker (placement recorded as pid:<n>) safely.
# Guard against PID reuse: if the bridge's meta records a different pid, the
# recorded pid is stale — skip rather than kill an unrelated process. SIGTERM
# first (the bridge stops its client and kills its stdio app-server child), then
# fall back to SIGKILL if it doesn't exit.
kill_headless_pid() {
  local pid="$1" team="$2" name="$3" meta meta_pid n=0
  meta="$SKILL_DIR/run/codex-bridge.$team.$name.meta"
  [ -f "$meta" ] && meta_pid="$(sed -n 's/^pid=//p' "$meta" 2>/dev/null)"
  if [ -n "${meta_pid:-}" ] && [ "$meta_pid" != "$pid" ]; then
    echo "despawn: recorded pid $pid != bridge meta pid $meta_pid for $team/$name — skipping kill (stale record?)" >&2
    return 0
  fi
  kill -0 "$pid" 2>/dev/null || return 0
  kill "$pid" 2>/dev/null || true
  while kill -0 "$pid" 2>/dev/null && [ "$n" -lt 5 ]; do sleep 1; n=$((n + 1)); done
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null || true
    echo "despawn: bridge pid $pid did not exit on SIGTERM — sent SIGKILL" >&2
  fi
}

# Kill the recorded placement. ids are self-describing: %N pane, @N window,
# pid:<n> headless bridge worker.
kill_recorded_placement() {
  [ -f "$SPAWN_REC" ] || return 1
  local id _proj _type
  IFS=$'\t' read -r id _proj _type < "$SPAWN_REC"
  [ -n "$id" ] || return 1
  case "$id" in
    pid:*) kill_headless_pid "${id#pid:}" "$TEAM" "$NAME" ;;
    %*|@*)
      if command -v tmux >/dev/null 2>&1; then
        case "$id" in
          %*) tmux kill-pane   -t "$id" 2>/dev/null || true ;;
          @*) tmux kill-window -t "$id" 2>/dev/null || true ;;
        esac
      fi ;;
  esac
  printf '%s\t%s\t%s' "$id" "$_proj" "$_type"   # echo back for the caller
}

if [ "$FORCE" = "1" ]; then
  [ -f "$SPAWN_REC" ] || die "no placement record for '$TEAM/$NAME' — nothing to force (was it launched via 'spawn'? graceful despawn does not need this)"
  IFS=$'\t' read -r _id _proj _type < "$SPAWN_REC"
  kill_recorded_placement >/dev/null
  # Drop the member's registration, and release its (now-stale) lock.
  if [ -n "${_proj:-}" ] && [ -n "${_type:-}" ]; then
    "$SCRIPT_DIR/reset.sh" "$_proj" "$_type" "$NAME" >/dev/null 2>&1 || true
  fi
  owner="$(actas_lock_owner "$TEAM" "$NAME")"
  [ -n "$owner" ] && actas_lock_release "$TEAM" "$NAME" "$owner" 2>/dev/null || true
  rm -f "$SPAWN_REC" 2>/dev/null || true
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
