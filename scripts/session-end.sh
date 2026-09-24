#!/usr/bin/env bash
set -uo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/lib/compat.sh"

# The headless cursor worker's own turns set this so this SessionEnd hook never
# treats a worker turn's --resume-triggered sessionEnd as the interactive
# session ending (cursor fires sessionEnd on --resume even for the worker's own
# read-only turns; misreading that here would publish a tombstone and snapshot
# teardown for a session that never ended). Same guard, same reasoning, as
# check-inbox.sh's. See _spawn.sh / cursor-bridge.sh.
if [ -n "${AGMSG_CURSOR_BRIDGE:-}" ]; then
  exit 0
fi

# SessionEnd hook — symmetric counterpart of session-start.sh.
#
# Usage: session-end.sh <type> <project_path>
#
# Claude Code's SessionEnd hook budget is short (default 1500ms; override with
# CLAUDE_CODE_SESSIONEND_HOOKS_TIMEOUT_MS) and SessionEnd BLOCKS process exit
# while the hook runs. The full teardown (reaping this session's codex worker via
# SIGTERM + a short wait, DB-backed registration drops, marker/lock GC) routinely
# overruns that, so CC was force-killing the hook ("Hook cancelled") part-way
# through — leaving codex bridges and spawn records behind, and stalling the
# user's exit. So this entry does only the sub-millisecond bookkeeping it must do
# synchronously, then DETACHES session-end-worker.sh to finish the teardown after
# we have already returned 0.
#
# Synchronous work kept here (all cheap — no despawn, DB writes, or sleeps):
#   1. Read session_id from the hook input JSON on stdin.
#   2. Resolve the per-process instance id (#93) WHILE the enclosing Claude Code
#      process tree is still alive. This MUST happen here, not in the detached
#      worker: the worker is reparented to init and can no longer see the agent
#      pid, so it would fall back to the bare session_id and miss every artifact
#      keyed under the composite "<sid>.<pid>" (watch pidfile/watermark,
#      cc-instance, actas locks). The worker is handed the resolved id.
#   3. Snapshot every spawn record for the session team into one temp file so
#      the worker can pass each hook-time record to despawn --expect-record and
#      refuse to tear down a worker a fast lazy-respawn replaced after we fired.
#
# Cleanup is best-effort and the script always exits 0 — SessionEnd cannot block
# termination, and a non-zero exit would only add log noise.

TYPE="${1:-}"
PROJECT="${2:-}"
[ -n "$TYPE" ] && [ -n "$PROJECT" ] || exit 0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RUN_DIR="$SKILL_DIR/run"

# Read session_id from the hook input JSON on stdin.
INPUT=$(cat 2>/dev/null || true)
SESSION_ID=""
if [ -n "$INPUT" ]; then
  SESSION_ID=$(printf '%s' "$INPUT" \
    | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    | head -1)
fi
[ -z "$SESSION_ID" ] && exit 0

# Resolve the instance id in-process (see #93 note above). actas-lock.sh pulls in
# instance-id.sh; resolve-project.sh provides agmsg_agent_pid. Both are cheap.
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/actas-lock.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/resolve-project.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/process-identity.sh"
INSTANCE_ID="$(agmsg_instance_id "$SESSION_ID" "$TYPE")"

# Stop this session's cursor inject watcher (inject-watch.sh), keyed on the
# same INSTANCE_ID as watch.sh's pidfile but under its own name — it does not
# share watch.*.pid, so it is not reached by that pidfile's owner-stop path
# (which can sit waiting on a re-verification round-trip; a watcher whose pipe
# closes during that wait would go unnoticed, leaving it running and still
# injecting into a pane for a session that has already ended). A bare TERM is
# enough: inject-watch.sh's own trap removes its pidfile on receipt.
#
# Verify ownership from the sidecar file before signalling, using only plain
# reads (process-identity.sh's own field parser, no fork) — a PID this
# session's own inject-watch.sh already released could otherwise have been
# recycled by an unrelated process by the time this hook runs. This stops
# short of process-identity.sh's full lease-probing verification
# (agmsg_process_signal_owned): that forks a python/lockf helper and this
# section must stay non-blocking (see this file's header on why teardown that
# can stall is detached to session-end-worker.sh instead) — a pid+kind match
# on the owner sidecar is enough to rule out the PID-reuse case review flagged,
# and this script already declares itself best-effort throughout.
INJECT_PIDFILE="$RUN_DIR/inject-watch.$INSTANCE_ID.pid"
INJECT_PID="$(_agmsg_process_read_pid "$INJECT_PIDFILE" 2>/dev/null || true)"
if [ -n "$INJECT_PID" ]; then
  INJECT_OWNER="$(agmsg_process_owner_path "$INJECT_PIDFILE")"
  INJECT_OWNER_PID="$(_agmsg_process_owner_field "$INJECT_OWNER" pid 2>/dev/null || true)"
  INJECT_OWNER_KIND="$(_agmsg_process_owner_field "$INJECT_OWNER" kind 2>/dev/null || true)"
  if [ "$INJECT_PID" = "$INJECT_OWNER_PID" ] && [ "$INJECT_OWNER_KIND" = "inject-watch" ]; then
    kill -TERM "$INJECT_PID" 2>/dev/null || true
  fi
fi

# Snapshot every session-team spawn record. Use the exact encoded-team prefix
# that agmsg_spawn_path writes, strip only that known prefix, then decode the
# remaining worker name. One temp file keeps the detached argv small even when
# several headless workers belong to the session.
STEAM="s-${SESSION_ID%%.*}"
mkdir -p "$RUN_DIR" 2>/dev/null || true
SNAPSHOT_PATH="$(mktemp "$RUN_DIR/.session-end-snapshot.XXXXXX" 2>/dev/null || true)"
if [ -n "$SNAPSHOT_PATH" ]; then
  ENCODED_STEAM="$(_actas_lock_encode "$STEAM")"
  SPAWN_PREFIX="$RUN_DIR/spawn.${ENCODED_STEAM}__"
  for SPAWN_FILE in "${SPAWN_PREFIX}"*; do
    [ -f "$SPAWN_FILE" ] || continue
    ENCODED_NAME="${SPAWN_FILE#"$SPAWN_PREFIX"}"
    [ "$ENCODED_NAME" != "$SPAWN_FILE" ] || continue
    NAME="$(_actas_lock_decode "$ENCODED_NAME")"
    RECORD="$(cat "$SPAWN_FILE" 2>/dev/null || true)"
    printf '%s\t%s\n' "$NAME" "$RECORD" >>"$SNAPSHOT_PATH" 2>/dev/null || true
  done
fi

# Publish the intentional teardown before detaching the slow cleanup worker. A
# watchdog recovery that races this hook must see one team-scoped owner stamp;
# the worker removes it only when the stamp still belongs to this instance.
printf '%s\n' "$INSTANCE_ID" >"$RUN_DIR/watchdog.$STEAM.tombstone" 2>/dev/null || true

# Detach the cleanup so it survives this hook returning AND CC exiting. Prefer
# setsid (a clean new session) where present; macOS has no setsid binary, so fall
# back to nohup + & — the same pattern spawn.sh uses to launch the codex bridge,
# which already outlives its launching session in this environment. stdio is fully
# redirected so the child is never tied to the hook's pipes.
LOG="$RUN_DIR/session-end.log"
WORKER="$SCRIPT_DIR/session-end-worker.sh"
if command -v setsid >/dev/null 2>&1; then
  setsid "$WORKER" "$TYPE" "$PROJECT" "$SESSION_ID" "$INSTANCE_ID" "$SNAPSHOT_PATH" </dev/null >>"$LOG" 2>&1 &
else
  nohup "$WORKER" "$TYPE" "$PROJECT" "$SESSION_ID" "$INSTANCE_ID" "$SNAPSHOT_PATH" </dev/null >>"$LOG" 2>&1 &
fi

exit 0
