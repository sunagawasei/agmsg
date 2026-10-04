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
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/instance-id.sh"

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

# The lock directory holds one record, owner.<pid>.<nonce>, naming the process
# that owns it. A lock is taken over only when that process is gone; elapsed
# time alone never frees it, because a live spawn can run for minutes. The
# record name is unique per acquisition, so a reaper that judged one owner dead
# can only remove that owner's record, never a successor's.
GRACE_MIN=1  # an ownerless or unreadable lock is a crash between mkdir and publish

lock_record() {
  set -- "$LOCK"/owner.*
  [ -e "$1" ] && [ "$#" -eq 1 ] && printf '%s\n' "$1"
}

# 0 = the holder is gone and its lock was removed (or already vanished); 1 = held.
lock_reap_if_gone() {
  local rec pid tok cur dead=0
  if [ ! -d "$LOCK" ]; then return 0; fi
  rec="$(lock_record)" || rec=""
  if [ -z "$rec" ]; then
    set -- "$LOCK"/owner.*
    [ ! -e "$1" ] || return 1
    [ -n "$(find "$LOCK" -maxdepth 0 -mmin +"$GRACE_MIN" -print 2>/dev/null)" ] || return 1
    rmdir "$LOCK" 2>/dev/null || true
    return 0
  fi
  pid="$(sed -n 1p "$rec" 2>/dev/null || true)"
  tok="$(sed -n 2p "$rec" 2>/dev/null || true)"
  if _agmsg_pid_valid "$pid"; then
    if ! _agmsg_pid_alive_local "$pid"; then
      dead=1
    elif [ -n "$tok" ]; then
      # Alive pid, different start time: the pid was recycled. No token now
      # means we cannot tell, which counts as alive.
      cur="$(agmsg_pid_start_token "$pid" 2>/dev/null || true)"
      if [ -n "$cur" ] && [ "$cur" != "$tok" ]; then dead=1; fi
    fi
  elif [ -n "$(find "$rec" -maxdepth 0 -mmin +"$GRACE_MIN" -print 2>/dev/null)" ]; then
    dead=1
  fi
  [ "$dead" -eq 1 ] || return 1
  # Re-check that the same record is still the only one, then claim it by name.
  [ "$(lock_record 2>/dev/null || true)" = "$rec" ] || return 1
  mv "$rec" "$LOCK/reaped.$$" 2>/dev/null || return 1
  rm -f "$LOCK/reaped.$$"
  rmdir "$LOCK" 2>/dev/null || true
  return 0
}

OWNER_REC=""
lock_publish() {
  local tmp="$RUN_DIR/.owner.$key.$$" tok
  tok="$(agmsg_pid_start_token "$$" 2>/dev/null || true)"
  printf '%s\n%s\n' "$$" "$tok" > "$tmp" 2>/dev/null || return 1
  OWNER_REC="$LOCK/owner.$$.$RANDOM$RANDOM"
  # mv fails when the directory was removed meanwhile, so a record is never
  # published into a lock somebody else now owns.
  mv "$tmp" "$OWNER_REC" 2>/dev/null || { rm -f "$tmp"; OWNER_REC=""; return 1; }
}

lock_release() {
  [ -n "$OWNER_REC" ] || return 0
  if mv "$OWNER_REC" "$LOCK/released.$$" 2>/dev/null; then
    rm -f "$LOCK/released.$$"
    rmdir "$LOCK" 2>/dev/null || true
  fi
}

acquired=0
for _try in 1 2 3; do
  if mkdir "$LOCK" 2>/dev/null; then
    if lock_publish; then acquired=1; break; fi
    rmdir "$LOCK" 2>/dev/null || true
    continue
  fi
  lock_reap_if_gone || break
done
if [ "$acquired" -ne 1 ]; then
  echo "ensure-${TYPE}: spawn already in flight for '$NAME' in team '$TEAM'"
  exit 0
fi
trap lock_release EXIT

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
