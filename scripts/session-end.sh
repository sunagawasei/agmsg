#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/lib/compat.sh"

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
#   3. Snapshot the session-team codex spawn record so the worker can pass it to
#      despawn --expect-record and refuse to tear down a worker a fast lazy-
#      respawn replaced after we fired.
#
# Cleanup is best-effort and the script always exits 0 — SessionEnd cannot block
# termination, and a non-zero exit would only add log noise.

TYPE="${1:?Usage: session-end.sh <type> <project_path>}"
PROJECT="${2:?Missing project_path}"

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
INSTANCE_ID="$(agmsg_instance_id "$SESSION_ID" "$TYPE")"

# Snapshot the session-team codex spawn record (team s-<uuid>, agent codex — both
# already filesystem-safe, so agmsg_spawn_path's encoding is the identity here).
# Empty if there is none.
STEAM="s-${SESSION_ID%%.*}"
SNAPSHOT="$(cat "$RUN_DIR/spawn.${STEAM}__codex" 2>/dev/null || true)"

# Detach the cleanup so it survives this hook returning AND CC exiting. Prefer
# setsid (a clean new session) where present; macOS has no setsid binary, so fall
# back to nohup + & — the same pattern spawn.sh uses to launch the codex bridge,
# which already outlives its launching session in this environment. stdio is fully
# redirected so the child is never tied to the hook's pipes.
mkdir -p "$RUN_DIR" 2>/dev/null || true
LOG="$RUN_DIR/session-end.log"
WORKER="$SCRIPT_DIR/session-end-worker.sh"
if command -v setsid >/dev/null 2>&1; then
  setsid "$WORKER" "$TYPE" "$PROJECT" "$SESSION_ID" "$INSTANCE_ID" "$SNAPSHOT" </dev/null >>"$LOG" 2>&1 &
else
  nohup "$WORKER" "$TYPE" "$PROJECT" "$SESSION_ID" "$INSTANCE_ID" "$SNAPSHOT" </dev/null >>"$LOG" 2>&1 &
fi

exit 0
