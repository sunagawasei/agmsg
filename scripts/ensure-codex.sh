#!/usr/bin/env bash
set -euo pipefail

# ensure-codex.sh — lazily spawn the current session's codex worker.
#
# In session-team mode the per-session codex (team s-<uuid>) is started on first
# use, not at SessionStart. The claude-code ask/send flow calls this right
# before it messages codex. It is a NO-OP when session-team mode is off or there
# is no CLAUDE_CODE_SESSION_ID, so it is safe to call unconditionally from that
# flow. It is deliberately NOT wired into send.sh itself: one-way / ctrl:* sends
# (e.g. despawn) must not resurrect a torn-down worker.
#
# Usage: ensure-codex.sh <project> [name]
#
# Concurrency: a mkdir lock serializes the check-then-spawn so two near-
# simultaneous ask/send calls cannot double-spawn. If the lock is held another
# spawn is already in flight, so we return 0 and let it come up.

PROJECT="${1:?Usage: ensure-codex.sh <project> [name]}"
NAME="${2:-codex}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/session-team.sh"

TEAM="$(agmsg_session_team_name)"
[ -n "$TEAM" ] || exit 0   # not in session-team mode (or no session id) → nothing to do

RUN_DIR="$SKILL_DIR/run"
mkdir -p "$RUN_DIR" 2>/dev/null || true

# A live codex-bridge.js bound to THIS exact team+name means we are done. Match
# the full flag signature so a bridge for another team never counts as ours.
BRIDGE_SIG="codex-bridge\.js .*--team $TEAM --name $NAME --inline-inbox"
if pgrep -f "$BRIDGE_SIG" >/dev/null 2>&1; then
  exit 0
fi

# Serialize the spawn. mkdir is atomic on POSIX. Filesystem-safe lock key.
key="$(printf '%s__%s' "$TEAM" "$NAME" | tr -c 'A-Za-z0-9._-' '_')"
LOCK="$RUN_DIR/ensure-codex.$key.lock"

# Reclaim a stale lock left by an owner that crashed before spawning. A normal
# spawn is sub-second; 2 minutes is a safe floor.
if [ -d "$LOCK" ] && find "$LOCK" -maxdepth 0 -mmin +2 >/dev/null 2>&1; then
  rmdir "$LOCK" 2>/dev/null || true
fi

if ! mkdir "$LOCK" 2>/dev/null; then
  # Another ensure-codex holds the lock and is bringing the worker up.
  exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT

# Re-check under the lock: a peer may have spawned between our pgrep and here.
if pgrep -f "$BRIDGE_SIG" >/dev/null 2>&1; then
  exit 0
fi

if "$SCRIPT_DIR/spawn.sh" codex "$NAME" --team "$TEAM" --project "$PROJECT" --headless >/dev/null 2>&1; then
  echo "ensure-codex: spawned headless codex '$NAME' in '$TEAM'"
else
  echo "ensure-codex: failed to spawn codex '$NAME' in '$TEAM'" >&2
  exit 1
fi
