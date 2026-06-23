#!/usr/bin/env bash
set -euo pipefail

# session-end-worker.sh — the detached cleanup body of the SessionEnd hook.
#
# Claude Code's SessionEnd hook budget is short (default 1500ms; overridable via
# CLAUDE_CODE_SESSIONEND_HOOKS_TIMEOUT_MS) and SessionEnd BLOCKS process exit
# while it runs. The real teardown — reaping this session's codex worker (SIGTERM
# + up to a few seconds wait), DB-backed registration drops, marker/lock GC —
# routinely exceeds that, so CC was killing the hook ("Hook cancelled") mid-
# teardown and leaving codex bridges + spawn records behind. session-end.sh (the
# hook entry) therefore snapshots the minimum it needs and detaches THIS script,
# which finishes the teardown after the hook has already returned 0. Nothing here
# is on CC's critical path, so it may take as long as it needs.
#
# Usage: session-end-worker.sh <type> <project> <session_id> <instance_id> <snapshot>
#
# <instance_id> is resolved by session-end.sh WHILE the Claude Code process tree
# is still alive. We MUST NOT recompute it here: a detached worker is reparented
# to init and can no longer see the agent pid, so agmsg_instance_id would fall
# back to the bare session_id and miss every artifact keyed under the composite
# "<sid>.<pid>" (#93) — watch pidfile/watermark, cc-instance, actas locks.
#
# <snapshot> is the exact contents of the session-team codex spawn record as seen
# at hook time (empty if there was none). It is handed to despawn --expect-record
# so we never tear down a codex that a fast lazy-respawn put in place AFTER the
# hook fired.
#
# Cleanup is best-effort: any missing piece just means nothing to do. Always
# exits 0.

TYPE="${1:?Usage: session-end-worker.sh <type> <project> <session_id> <instance_id> <snapshot>}"
PROJECT="${2:?Missing project_path}"
SESSION_ID="${3:-}"
INSTANCE_ID="${4:-$SESSION_ID}"
SNAPSHOT="${5-}"
[ -n "$SESSION_ID" ] || exit 0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RUN_DIR="$SKILL_DIR/run"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/actas-lock.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/resolve-project.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/session-team.sh"

# Drop project markers (#92) whose agent process has exited. Liveness-based, so
# a session that persists across /clear keeps its marker until the process dies.
agmsg_marker_gc_stale 2>/dev/null || true

# session-team mode: tear down THIS session's codex worker so it does not linger
# after the session ends — but ONLY if this is the last live instance of the
# session. Parallel --continue/--resume processes share the bare-session team
# s-<uuid> (and its single codex worker); if a sibling is still alive, killing
# the worker would break its in-flight ask. The team config and message history
# are kept regardless, so a later resume lazily re-spawns a codex.
#
# An empty snapshot means there was no codex spawn record at hook time — there is
# nothing of ours to reap, and we must NOT reap by pgrep alone (it could hit a
# worker a fast lazy-respawn just put up). Pass the snapshot to despawn
# --expect-record so the teardown no-ops if the live record changed since.
if [ "$TYPE" = "claude-code" ] && agmsg_session_team_enabled && [ -n "$SNAPSHOT" ]; then
  STEAM="s-${SESSION_ID%%.*}"
  self_pid=""
  agmsg_instance_is_composite "$INSTANCE_ID" && self_pid="${INSTANCE_ID##*.}"
  sibling_alive=0
  for f in "$RUN_DIR"/cc-instance.*; do
    [ -f "$f" ] || continue
    p=${f##*.}
    case "$p" in ''|*[!0-9]*) continue ;; esac
    [ -n "$self_pid" ] && [ "$p" = "$self_pid" ] && continue
    kill -0 "$p" 2>/dev/null || continue
    s="$(cat "$f" 2>/dev/null || true)"
    [ "${s%%.*}" = "${SESSION_ID%%.*}" ] && { sibling_alive=1; break; }
  done
  if [ "$sibling_alive" -eq 0 ]; then
    "$SCRIPT_DIR/despawn.sh" "$STEAM" claude codex --force --expect-record "$SNAPSHOT" \
      >/dev/null 2>&1 || true
  fi
fi

PIDFILE="$RUN_DIR/watch.$INSTANCE_ID.pid"
if [ -f "$PIDFILE" ]; then
  pid=$(cat "$PIDFILE" 2>/dev/null || true)
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    # Defensive: only kill if the pid's command line still looks like our
    # watch.sh. Pids can be recycled — a stale pidfile could point at an
    # unrelated process that took the same pid.
    cmd=$(ps -o args= -p "$pid" 2>/dev/null || true)
    case "$cmd" in
      *"$SKILL_DIR/scripts/watch.sh"*) kill "$pid" 2>/dev/null || true ;;
      *) ;;
    esac
  fi
  rm -f "$PIDFILE"
fi

# Drop the per-session stream watermark (see #107) — the session is ending, so
# there is no restart to resume; a future session_id reuse should start fresh.
rm -f "$RUN_DIR/watch.$INSTANCE_ID.watermark" 2>/dev/null || true

# Clean the cc-instance entry that points at this instance id. A sibling process
# that shares the bare session_id stores a different instance id, so it is
# untouched.
for f in "$RUN_DIR"/cc-instance.*; do
  [ -f "$f" ] || continue
  state=$(cat "$f" 2>/dev/null || true)
  [ "$state" = "$INSTANCE_ID" ] && rm -f "$f"
done

# Release any actas exclusivity locks owned by this instance so peers can reclaim
# those identities on their next watcher cycle. Keyed by instance id so a sibling
# resume process's locks are not released out from under it. See #62.
actas_lock_release_all "$INSTANCE_ID" 2>/dev/null || true

exit 0
