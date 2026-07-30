#!/usr/bin/env bash
set -euo pipefail

# ensure-headless.sh — lazily spawn the current session's headless worker.
#
# Usage: ensure-headless.sh <type> <project> [name]
#
# The session-team guard intentionally mirrors ensure-codex.sh: outside
# session-team mode, or without a session id, there is no session-scoped worker
# to ensure and this command is a safe no-op.

TYPE="${1:?Usage: ensure-headless.sh <type> <project> [name]}"
PROJECT="${2:?Usage: ensure-headless.sh <type> <project> [name]}"
NAME="${3:-$TYPE}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/session-team.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/identity-key.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/type-registry.sh"

if ! agmsg_is_known_type "$TYPE"; then
  echo "ensure-headless: unknown agent type '$TYPE'" >&2
  exit 1
fi
if [ "$(agmsg_type_get "$TYPE" headless)" != yes ]; then
  echo "ensure-headless: agent type '$TYPE' is not headless-capable" >&2
  exit 1
fi

TEAM="$(agmsg_session_team_name)"
[ -n "$TEAM" ] || exit 0

RUN_DIR="$SKILL_DIR/run"
mkdir -p "$RUN_DIR" 2>/dev/null || true

# A bridge's executable name is type-scoped. Prefer the implementation file
# shipped by the type driver so codex-bridge.js and cursor-bridge.sh are both
# matched as an exact argv token; add-on types without a local bridge file use
# the registry type's conventional <type>-bridge token.
TYPE_DIR="$(agmsg_type_dir "$TYPE")"
BRIDGE_BASENAME=""
BRIDGE_EXT_RE=""
for bridge_file in "$TYPE_DIR"/"$TYPE"-bridge.*; do
  [ -f "$bridge_file" ] || continue
  BRIDGE_BASENAME="$(basename "$bridge_file")"
  break
done
if [ -z "$BRIDGE_BASENAME" ]; then
  BRIDGE_BASENAME="${TYPE}-bridge"
  BRIDGE_EXT_RE="(\\.[A-Za-z0-9_-]+)?"
fi
BRIDGE_RE="$(printf '%s' "$BRIDGE_BASENAME" | sed 's/[.[\*^$()+?{|\\]/\\&/g')"

# The identity-key terminator makes this an exact token match: a key that is a
# prefix of another worker's key cannot satisfy the trailing argv boundary.
IDENTITY_KEY="$(agmsg_identity_key "$TEAM" "$NAME")"
BRIDGE_SIG="(^|[[:space:]/])${BRIDGE_RE}${BRIDGE_EXT_RE}([[:space:]]|$).*([[:space:]])--identity-key ${IDENTITY_KEY}([[:space:]]|$)"
if pgrep -f "$BRIDGE_SIG" >/dev/null 2>&1; then
  echo "ensure-${TYPE}: ${TYPE} '$NAME' already running in team '$TEAM'"
  exit 0
fi

# Serialize the check-then-spawn. Keep the historical codex lock spelling so
# ensure-codex remains behaviorally compatible with its former implementation.
key="$(printf '%s__%s' "$TEAM" "$NAME" | tr -c 'A-Za-z0-9._-' '_')"
LOCK="$RUN_DIR/ensure-${TYPE}.$key.lock"

# Reclaim a stale lock left by an owner that crashed before spawning. A normal
# spawn is sub-second; two minutes is a safe floor.
if [ -d "$LOCK" ] && [ -n "$(find "$LOCK" -maxdepth 0 -mmin +2 -print 2>/dev/null)" ]; then
  rmdir "$LOCK" 2>/dev/null || true
fi

if ! mkdir "$LOCK" 2>/dev/null; then
  echo "ensure-${TYPE}: spawn already in flight for '$NAME' in team '$TEAM'"
  exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT

# Re-check under the lock: a peer may have spawned between our pgrep and here.
if pgrep -f "$BRIDGE_SIG" >/dev/null 2>&1; then
  echo "ensure-${TYPE}: ${TYPE} '$NAME' already running in team '$TEAM'"
  exit 0
fi

if "$SCRIPT_DIR/spawn.sh" "$TYPE" "$NAME" --team "$TEAM" --project "$PROJECT" --headless >/dev/null 2>&1; then
  echo "ensure-${TYPE}: spawned headless ${TYPE} '$NAME' in team '$TEAM'"
else
  echo "ensure-${TYPE}: failed to spawn ${TYPE} '$NAME' in team '$TEAM' — run spawn.sh directly to see why" >&2
  exit 1
fi
