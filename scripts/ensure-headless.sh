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

# An owner that could not read its start token leaves an empty token in its
# record, so a recycled pid is told apart by time: the record is written after
# the owner starts, hence a holder that started more than RECYCLE_SLACK seconds
# after the record's mtime is not the owner. Known limit: this assumes the file
# mtime and ps etime share one clock, so a wall-clock step or drift beyond the
# slack between the two can free the lock of a live owner.
RECYCLE_SLACK=120

lock_record() {
  set -- "$LOCK"/owner.*
  [ -e "$1" ] && [ "$#" -eq 1 ] && printf '%s\n' "$1"
}

# Prints a plain unsigned integer from "$@" (at most 10 digits); fails on a
# non-zero exit, empty, multi-line or non-numeric output.
lock_uint_from() {
  local out
  out="$("$@" 2>/dev/null)" || return 1
  [[ "$out" =~ ^[0-9]{1,10}$ ]] || return 1
  printf '%s\n' "$((10#$out))"
}

# ps etime ([[dd-]hh:]mm:ss) to seconds; fails on anything else.
lock_etime_secs() {
  local raw="$1" d h m s secs
  raw="${raw#"${raw%%[![:space:]]*}"}"
  raw="${raw%"${raw##*[![:space:]]}"}"
  [[ "$raw" =~ ^((([0-9]{1,5})-)?([0-9]{1,2}):)?([0-9]{1,2}):([0-9]{2})$ ]] || return 1
  d=$((10#${BASH_REMATCH[3]:-0})) h=$((10#${BASH_REMATCH[4]:-0}))
  m=$((10#${BASH_REMATCH[5]})) s=$((10#${BASH_REMATCH[6]}))
  [ "$h" -lt 24 ] && [ "$m" -lt 60 ] && [ "$s" -lt 60 ] || return 1
  secs=$((((d * 24 + h) * 60 + m) * 60 + s))
  [ "${#secs}" -le 10 ] || return 1
  printf '%s\n' "$secs"
}

# 0 only when the record is exactly "<pid>\n\n" (an empty token) and the pid's
# current holder started after the record was written. Every input that cannot
# be read or validated answers 1, i.e. the lock stays held.
lock_holder_started_after_record() {
  local pid="$1" rec="$2" content now raw etime mtime
  content="$(cat "$rec" 2>/dev/null; printf x)"
  [ "$content" = "$pid"$'\n\nx' ] || return 1
  # now is read before ps so that a slow ps can only make the holder look older.
  now="$(lock_uint_from date +%s)" || return 1
  raw="$(LC_ALL=C ps -o etime= -p "$pid" 2>/dev/null)" || return 1
  etime="$(lock_etime_secs "$raw")" || return 1
  mtime="$(lock_uint_from stat -c %Y "$rec")" || mtime="$(lock_uint_from stat -f %m "$rec")" || return 1
  [ "$etime" -le "$now" ] && [ "$mtime" -le "$now" ] || return 1
  [ $((now - etime)) -gt $((mtime + RECYCLE_SLACK)) ]
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
      # Tokens from different acquisition methods (proc: vs ps:) are not
      # comparable, so only a same-method mismatch proves a recycled pid.
      cur="$(agmsg_pid_start_token "$pid" 2>/dev/null || true)"
      if [ -n "$cur" ] && [ "$(agmsg_pid_start_token_method "$cur")" = "$(agmsg_pid_start_token_method "$tok" 2>/dev/null || true)" ] \
        && [ "$cur" != "$tok" ]; then dead=1; fi
    elif lock_holder_started_after_record "$pid" "$rec"; then
      dead=1
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
  # mv fails when the directory was removed meanwhile. If it was removed and
  # recreated by another owner first, the record landed in their directory:
  # the directory's inode no longer matches the one we created, so withdraw.
  mv "$tmp" "$OWNER_REC" 2>/dev/null || { rm -f "$tmp"; OWNER_REC=""; return 1; }
  # An unobservable inode (empty or failed ls) must not pass as "unchanged".
  if [ -z "$1" ] || [ "$(lock_dir_id)" != "$1" ]; then
    rm -f "$OWNER_REC"
    OWNER_REC=""
    return 1
  fi
}

# Prints the lock dir's inode; prints nothing unless ls exits 0 with exactly one.
lock_dir_id() {
  local out
  out="$(ls -di "$LOCK" 2>/dev/null)" || return 1
  [[ "$out" =~ ^[[:space:]]*([0-9]+)[[:space:]] ]] && [[ "$out" != *$'\n'* ]] || return 1
  printf '%s\n' "${BASH_REMATCH[1]}"
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
    if lock_publish "$(lock_dir_id)"; then acquired=1; break; fi
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
