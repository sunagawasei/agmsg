#!/usr/bin/env bash
set -uo pipefail

# Detached SessionEnd cleanup with capability-gated cooperative bridge drain.
# Usage: session-end-worker.sh <type> <project> <session_id> <instance_id> <snapshot_path>

TYPE="${1:-}"
PROJECT="${2:-}"
SESSION_ID="${3:-}"
INSTANCE_ID="${4:-$SESSION_ID}"
SNAPSHOT_PATH="${5-}"
[ -n "$TYPE" ] && [ -n "$PROJECT" ] || exit 0
[ -n "$SESSION_ID" ] || exit 0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RUN_DIR="$SKILL_DIR/run"
STEAM="s-${SESSION_ID%%.*}"
WATCHDOG_TOMBSTONE="$RUN_DIR/watchdog.$STEAM.tombstone"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/actas-lock.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/resolve-project.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/session-team.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/identity-key.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/team-lifecycle.sh"

duration_config() {
  local env_name="$1" key="$2" default="$3" raw
  eval "raw=\${$env_name-}"
  [ -n "$raw" ] || raw="$("$SCRIPT_DIR/config.sh" get "$key" "$default" 2>/dev/null || echo "$default")"
  case "$raw" in ''|*[!0-9]*) raw="$default" ;; esac
  [ "$raw" -gt 0 ] 2>/dev/null || raw="$default"
  printf '%s\n' "$raw"
}

DRAIN_DEADLINE_S="$(duration_config AGMSG_DRAIN_DEADLINE_S drain.deadline_s 600)"
DRAIN_LEASE_INTERVAL_S="$(duration_config AGMSG_DRAIN_LEASE_INTERVAL_S drain.lease_interval_s 30)"
DRAIN_LEASE_STALE_S="$(duration_config AGMSG_DRAIN_LEASE_STALE_S drain.lease_stale_s 120)"
DRAIN_POLL_INTERVAL="$(agmsg_wait_knob_resolve \
  "${AGMSG_DRAIN_POLL_INTERVAL-}" 1 0.01 60 decimal)"
LIFECYCLE_LOCK_TIMEOUT="${AGMSG_LIFECYCLE_LOCK_TIMEOUT:-10}"
case "$LIFECYCLE_LOCK_TIMEOUT" in ''|*[!0-9]*) LIFECYCLE_LOCK_TIMEOUT=10 ;; esac

DRAIN_NONCE=""
DRAIN_FENCE="$(agmsg_drain_fence_path "$STEAM")"
DRAIN_ABORTED=0

cleanup_owned_artifacts() {
  local current marker remove_tombstone=1
  # Fence removal is no more CAS-safe than stale takeover. Keep the final
  # owner check and removal under the same team lock so an exiting old owner
  # cannot unlink a replacement fence published between its read and rm.
  if agmsg_team_lifecycle_lock_acquire "$STEAM" "$LIFECYCLE_LOCK_TIMEOUT"; then
    if [ -e "$DRAIN_FENCE" ] || [ -L "$DRAIN_FENCE" ]; then
      if [ -z "$DRAIN_NONCE" ] || ! agmsg_drain_fence_read "$DRAIN_FENCE" "$STEAM" \
          || [ "$AGMSG_DRAIN_FENCE_NONCE" != "$DRAIN_NONCE" ] \
          || [ "$AGMSG_DRAIN_FENCE_OWNER" != "$INSTANCE_ID" ]; then
        # A competing/replacement fence may rely on the same team tombstone. The
        # loser must not remove shared watchdog protection it does not own.
        remove_tombstone=0
      fi
    fi
    if [ -n "$DRAIN_NONCE" ]; then
      agmsg_drain_fence_remove_owned \
        "$DRAIN_FENCE" "$DRAIN_NONCE" "$INSTANCE_ID" "$STEAM"
    fi
    if [ "$remove_tombstone" -eq 1 ] \
        && [ -f "$WATCHDOG_TOMBSTONE" ] && [ ! -L "$WATCHDOG_TOMBSTONE" ]; then
      current="$(cat "$WATCHDOG_TOMBSTONE" 2>/dev/null || true)"
      [ "$current" = "$INSTANCE_ID" ] \
        && rm -f -- "$WATCHDOG_TOMBSTONE" 2>/dev/null || true
    fi
    agmsg_team_lifecycle_lock_release "$STEAM" 2>/dev/null || true
  fi
  if [ -n "$DRAIN_NONCE" ]; then
    for marker in "$RUN_DIR"/draining.*; do
      [ -e "$marker" ] || [ -L "$marker" ] || continue
      agmsg_drain_marker_matches_nonce "$marker" "$DRAIN_NONCE" \
        && rm -f -- "$marker" 2>/dev/null || true
    done
  fi
  [ -n "$SNAPSHOT_PATH" ] && rm -f -- "$SNAPSHOT_PATH" 2>/dev/null || true
}
trap cleanup_owned_artifacts EXIT
trap 'DRAIN_ABORTED=1; exit 0' HUP INT TERM

session_sibling_alive() {
  local self_pid="" f pid sid
  agmsg_instance_is_composite "$INSTANCE_ID" && self_pid="${INSTANCE_ID##*.}"
  for f in "$RUN_DIR"/cc-instance.*; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    pid="${f##*.}"
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    [ -n "$self_pid" ] && [ "$pid" = "$self_pid" ] && continue
    _agmsg_pid_alive "$pid" || continue
    sid="$(cat "$f" 2>/dev/null || true)"
    [ "${sid%%.*}" = "${SESSION_ID%%.*}" ] && return 0
  done
  return 1
}

refresh_tombstone_owned() {
  local current tmp
  [ -f "$WATCHDOG_TOMBSTONE" ] && [ ! -L "$WATCHDOG_TOMBSTONE" ] || return 1
  current="$(cat "$WATCHDOG_TOMBSTONE" 2>/dev/null || true)"
  [ "$current" = "$INSTANCE_ID" ] || return 1
  tmp="$WATCHDOG_TOMBSTONE.tmp.$$"
  if ! printf '%s\n' "$INSTANCE_ID" > "$tmp" \
      || ! mv -f -- "$tmp" "$WATCHDOG_TOMBSTONE"; then
    rm -f -- "$tmp" 2>/dev/null || true
    return 1
  fi
}

ensure_tombstone_owned() {
  [ ! -L "$WATCHDOG_TOMBSTONE" ] || return 1
  if [ ! -e "$WATCHDOG_TOMBSTONE" ]; then
    (
      set -C
      umask 077
      printf '%s\n' "$INSTANCE_ID" > "$WATCHDOG_TOMBSTONE"
    ) 2>/dev/null || true
  fi
  refresh_tombstone_owned
}

fence_owned_and_live() {
  agmsg_drain_fence_is_live "$DRAIN_FENCE" "$STEAM" "$DRAIN_LEASE_STALE_S" \
    || return 1
  [ "$AGMSG_DRAIN_FENCE_NONCE" = "$DRAIN_NONCE" ] || return 1
  [ "$AGMSG_DRAIN_FENCE_OWNER" = "$INSTANCE_ID" ]
}

acquire_drain_fence() {
  local now age
  agmsg_team_lifecycle_lock_acquire "$STEAM" "$LIFECYCLE_LOCK_TIMEOUT" || return 1
  if session_sibling_alive; then
    agmsg_team_lifecycle_lock_release "$STEAM"
    return 2
  fi

  if [ -e "$DRAIN_FENCE" ] || [ -L "$DRAIN_FENCE" ]; then
    if [ -L "$DRAIN_FENCE" ] || ! agmsg_drain_fence_read "$DRAIN_FENCE" "$STEAM"; then
      agmsg_team_lifecycle_lock_release "$STEAM"
      return 3
    fi
    now="$(_agmsg_lifecycle_epoch)" || {
      agmsg_team_lifecycle_lock_release "$STEAM"
      return 3
    }
    [ "$now" -ge "$AGMSG_DRAIN_FENCE_LEASE_EPOCH" ] || {
      agmsg_team_lifecycle_lock_release "$STEAM"
      return 3
    }
    age=$((now - AGMSG_DRAIN_FENCE_LEASE_EPOCH))
    if [ "$age" -le "$DRAIN_LEASE_STALE_S" ]; then
      # Any live fence, including a duplicate owner invocation, has one winner.
      agmsg_team_lifecycle_lock_release "$STEAM"
      return 3
    fi
    # mv is not CAS. Stale takeover is therefore legal only while this team lock
    # excludes every cooperating issuer/refresher.
    rm -f -- "$DRAIN_FENCE" 2>/dev/null || {
      agmsg_team_lifecycle_lock_release "$STEAM"
      return 3
    }
  fi

  now="$(_agmsg_lifecycle_epoch)" || {
    agmsg_team_lifecycle_lock_release "$STEAM"
    return 1
  }
  DRAIN_NONCE="${INSTANCE_ID}.$$.${RANDOM:-0}.$now"
  if ! agmsg_drain_fence_create \
      "$DRAIN_FENCE" "$DRAIN_NONCE" "$INSTANCE_ID" "$STEAM" "$now"; then
    DRAIN_NONCE=""
    agmsg_team_lifecycle_lock_release "$STEAM"
    return 3
  fi
  if ! ensure_tombstone_owned; then
    agmsg_drain_fence_remove_owned \
      "$DRAIN_FENCE" "$DRAIN_NONCE" "$INSTANCE_ID" "$STEAM"
    DRAIN_NONCE=""
    agmsg_team_lifecycle_lock_release "$STEAM"
    return 3
  fi
  agmsg_team_lifecycle_lock_release "$STEAM"
  return 0
}

bridge_argv_matches() {
  local pid="$1" bridge_type="$2" name="$3" args identity_key arg expect_identity=0
  local bridge_token=0 identity_token=0
  local -a argv=()
  identity_key="$(agmsg_identity_key "$STEAM" "$name")"
  args="$(compat_get_cmdline "$pid" 2>/dev/null || true)"
  read -r -a argv <<<"$args" || true
  # Bash 3.2 + nounset: expanding an empty "${argv[@]}" aborts the worker.
  [ "${#argv[@]}" -gt 0 ] || return 1
  for arg in "${argv[@]}"; do
    if [ "$expect_identity" -eq 1 ]; then
      [ "$arg" = "$identity_key" ] && identity_token=1
      expect_identity=0
      continue
    fi
    [ "$arg" = "--identity-key" ] && expect_identity=1
    case "$arg" in
      "$bridge_type-bridge"|*/"$bridge_type-bridge"|\
      "$bridge_type-bridge.js"|*/"$bridge_type-bridge.js"|\
      "$bridge_type-bridge.sh"|*/"$bridge_type-bridge.sh")
        bridge_token=1 ;;
    esac
  done
  [ "$bridge_token" -eq 1 ] && [ "$identity_token" -eq 1 ]
}

# Set BRIDGE_{PID,CAPABLE}. The live spawn record and pid identity must both
# match the hook snapshot before a nudge can be sent.
inspect_snapshot_target() {
  local name="$1" record="$2" placement rest project bridge_type meta meta_pid capability
  BRIDGE_PID=""
  BRIDGE_CAPABLE=0
  [ "$(cat "$(agmsg_spawn_path "$STEAM" "$name")" 2>/dev/null || true)" = "$record" ] \
    || return 1
  placement="${record%%$'\t'*}"
  rest="${record#*$'\t'}"
  [ "$rest" != "$record" ] || return 1
  project="${rest%%$'\t'*}"
  bridge_type="${rest#*$'\t'}"
  [ "$bridge_type" != "$rest" ] || return 1
  case "$placement" in pid:*) BRIDGE_PID="${placement#pid:}" ;; *) return 1 ;; esac
  case "$BRIDGE_PID" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$project" ] && [ -n "$bridge_type" ] || return 1
  _agmsg_pid_alive "$BRIDGE_PID" || return 1

  meta="$RUN_DIR/$bridge_type-bridge.$STEAM.$name.meta"
  meta_pid=""
  capability=""
  if [ -f "$meta" ] && [ ! -L "$meta" ]; then
    meta_pid="$(sed -n 's/^pid=//p' "$meta" 2>/dev/null | head -1)"
    capability="$(sed -n 's/^drain_capable=//p' "$meta" 2>/dev/null | head -1)"
  fi
  if [ -n "$meta_pid" ]; then
    [ "$meta_pid" = "$BRIDGE_PID" ] || return 1
  else
    bridge_argv_matches "$BRIDGE_PID" "$bridge_type" "$name" || return 1
  fi
  [ "$capability" = 1 ] && BRIDGE_CAPABLE=1
}

# The only worker path allowed to mutate a target. Owner verification, final
# sibling decision, snapshot comparison, and despawn all occur under one team
# lifecycle critical section. despawn performs the final meta/argv PID check
# immediately before kill(2), and its placement lock preserves expect-record.
cleanup_target_locked() {
  local name="$1" record="$2" current despawn_rc
  agmsg_team_lifecycle_lock_acquire "$STEAM" "$LIFECYCLE_LOCK_TIMEOUT" || return 2
  if ! fence_owned_and_live || session_sibling_alive; then
    DRAIN_ABORTED=1
    agmsg_team_lifecycle_lock_release "$STEAM"
    return 2
  fi
  current="$(cat "$(agmsg_spawn_path "$STEAM" "$name")" 2>/dev/null || true)"
  if [ "$current" != "$record" ]; then
    agmsg_team_lifecycle_lock_release "$STEAM"
    return 1
  fi
  if "$SCRIPT_DIR/despawn.sh" "$STEAM" claude "$name" --force \
      --expect-record "$record" >/dev/null 2>&1; then
    despawn_rc=0
  else
    despawn_rc=$?
  fi
  agmsg_team_lifecycle_lock_release "$STEAM"
  if [ "$despawn_rc" -ne 0 ]; then
    echo "session-end-worker: teardown incomplete for $STEAM/$name (despawn status $despawn_rc); preserving its placement record" >&2
    return 4
  fi
  return 0
}

nudge_target_locked() {
  local name="$1" record="$2"
  agmsg_team_lifecycle_lock_acquire "$STEAM" "$LIFECYCLE_LOCK_TIMEOUT" || return 2
  if ! fence_owned_and_live || session_sibling_alive; then
    DRAIN_ABORTED=1
    agmsg_team_lifecycle_lock_release "$STEAM"
    return 2
  fi
  if ! inspect_snapshot_target "$name" "$record" || [ "$BRIDGE_CAPABLE" -ne 1 ]; then
    agmsg_team_lifecycle_lock_release "$STEAM"
    return 1
  fi
  kill -USR2 "$BRIDGE_PID" 2>/dev/null || true
  agmsg_team_lifecycle_lock_release "$STEAM"
  return 0
}

heartbeat_locked() {
  local now
  agmsg_team_lifecycle_lock_acquire "$STEAM" "$LIFECYCLE_LOCK_TIMEOUT" || return 1
  if ! fence_owned_and_live || session_sibling_alive; then
    DRAIN_ABORTED=1
    agmsg_team_lifecycle_lock_release "$STEAM"
    return 1
  fi
  now="$(_agmsg_lifecycle_epoch)" || {
    DRAIN_ABORTED=1
    agmsg_team_lifecycle_lock_release "$STEAM"
    return 1
  }
  if ! agmsg_drain_fence_refresh \
      "$DRAIN_FENCE" "$DRAIN_NONCE" "$INSTANCE_ID" "$STEAM" "$now" \
      || ! refresh_tombstone_owned; then
    DRAIN_ABORTED=1
    agmsg_team_lifecycle_lock_release "$STEAM"
    return 1
  fi
  agmsg_team_lifecycle_lock_release "$STEAM"
}

maintain_leases_if_due() {
  local now
  now="$(_agmsg_lifecycle_epoch)" || {
    DRAIN_ABORTED=1
    return 1
  }
  [ "$now" -ge "$next_lease" ] || return 0
  heartbeat_locked || return 1
  next_lease=$((now + DRAIN_LEASE_INTERVAL_S))
}

notify_drain_timeout() {
  local name="$1" pid="$2" outcome="${3:-forced}" body
  if [ "$outcome" = "unverified" ]; then
    body="[drain-timeout] session-end-worker could not verify teardown of $name (pid $pid) after ${DRAIN_DEADLINE_S}s; the worker may still be alive and its placement record was preserved. Read-but-unanswered rows remain queryable in messages.db; inspect with: SELECT id,from_agent,to_agent,created_at,read_at FROM messages WHERE team='$STEAM' AND to_agent='$name' AND read_at IS NOT NULL ORDER BY id DESC LIMIT 20;"
  else
    body="[drain-timeout] session-end-worker forced $name (pid $pid) after ${DRAIN_DEADLINE_S}s. Read-but-unanswered rows remain queryable in messages.db; inspect with: SELECT id,from_agent,to_agent,created_at,read_at FROM messages WHERE team='$STEAM' AND to_agent='$name' AND read_at IS NOT NULL ORDER BY id DESC LIMIT 20;"
  fi
  "$SCRIPT_DIR/send.sh" "$STEAM" session-end-worker claude "$body" --force \
    >/dev/null 2>&1 || true
}

cleanup_session_artifacts() {
  local f state
  rm -f "$RUN_DIR/watch.$INSTANCE_ID.watermark" 2>/dev/null || true
  for f in "$RUN_DIR"/cc-instance.*; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    state="$(cat "$f" 2>/dev/null || true)"
    [ "$state" = "$INSTANCE_ID" ] && rm -f "$f"
  done
  actas_lock_release_all "$INSTANCE_ID" 2>/dev/null || true
}

# Existing per-session cleanup before the drain decision.
agmsg_marker_gc_stale 2>/dev/null || true
PIDFILE="$RUN_DIR/watch.$INSTANCE_ID.pid"
if [ -f "$PIDFILE" ] && [ ! -L "$PIDFILE" ]; then
  pid="$(cat "$PIDFILE" 2>/dev/null || true)"
  if [ -n "$pid" ] && _agmsg_pid_alive "$pid"; then
    cmd="$(compat_get_cmdline "$pid" 2>/dev/null || true)"
    case "$cmd" in *"$SKILL_DIR/scripts/watch.sh"*) kill "$pid" 2>/dev/null || true ;; esac
  fi
  rm -f "$PIDFILE"
fi

if [ "$TYPE" != "claude-code" ] || ! agmsg_session_team_enabled; then
  cleanup_session_artifacts
  exit 0
fi

if session_sibling_alive; then
  cleanup_session_artifacts
  exit 0
fi

# Load the immutable hook snapshot before competing for fence ownership. A
# duplicate worker may unlink the shared temp path on its own exit; both workers
# must already hold the same rows in memory before one can become the winner.
SNAPSHOT_NAMES=()
SNAPSHOT_RECORDS=()
SNAPSHOT_COUNT=0
if [ -s "$SNAPSHOT_PATH" ]; then
  while IFS=$'\t' read -r _name _record || [ -n "${_name:-}${_record:-}" ]; do
    case "${_record%%$'\t'*}" in
      pid:*)
        SNAPSHOT_NAMES+=("$_name")
        SNAPSHOT_RECORDS+=("$_record")
        SNAPSHOT_COUNT=$((SNAPSHOT_COUNT + 1))
        ;;
    esac
  done < "$SNAPSHOT_PATH"
fi
if [ "$SNAPSHOT_COUNT" -eq 0 ]; then
  cleanup_session_artifacts
  exit 0
fi

acquire_rc=0
acquire_drain_fence || acquire_rc=$?
if [ "$acquire_rc" -ne 0 ]; then
  # A sibling or another live/invalid fence forbids all target mutation.
  cleanup_session_artifacts
  exit 0
fi

if lease_started="$(_agmsg_lifecycle_epoch)"; then
  next_lease=$((lease_started + DRAIN_LEASE_INTERVAL_S))
else
  # Without a trustworthy clock the worker cannot preserve either lease.
  DRAIN_ABORTED=1
  next_lease=0
fi
if [ "$DRAIN_ABORTED" -eq 1 ]; then
  cleanup_session_artifacts
  exit 0
fi

CAPABLE_NAMES=()
CAPABLE_RECORDS=()
CAPABLE_PIDS=()
CAPABLE_COUNT=0
i=0
while [ "$i" -lt "$SNAPSHOT_COUNT" ]; do
    NAME="${SNAPSHOT_NAMES[$i]}"
    RECORD="${SNAPSHOT_RECORDS[$i]}"
    if inspect_snapshot_target "$NAME" "$RECORD" && [ "$BRIDGE_CAPABLE" -eq 1 ]; then
      if nudge_target_locked "$NAME" "$RECORD"; then
        CAPABLE_NAMES+=("$NAME")
        CAPABLE_RECORDS+=("$RECORD")
        CAPABLE_PIDS+=("$BRIDGE_PID")
        CAPABLE_COUNT=$((CAPABLE_COUNT + 1))
      elif [ "$DRAIN_ABORTED" -eq 1 ]; then
        break
      else
        cleanup_target_locked "$NAME" "$RECORD" || true
      fi
    else
      # Old/non-capable or unverifiable bridges retain the historical immediate
      # force behavior. despawn itself refuses a PID-reuse kill, then cleans the
      # matching stale record through the same locked mutation path.
      cleanup_target_locked "$NAME" "$RECORD" || true
      [ "$DRAIN_ABORTED" -eq 0 ] || break
    fi
    [ "$DRAIN_ABORTED" -eq 0 ] && maintain_leases_if_due || true
    [ "$DRAIN_ABORTED" -eq 0 ] || break
    i=$((i + 1))
done

if [ "$DRAIN_ABORTED" -eq 1 ]; then
  cleanup_session_artifacts
  exit 0
fi

if started="$(_agmsg_lifecycle_epoch)"; then
  deadline=$((started + DRAIN_DEADLINE_S))
else
  # A missing clock cannot safely establish either the common deadline or the
  # next lease refresh. Abort without force instead of treating epoch zero as an
  # already-expired deadline.
  DRAIN_ABORTED=1
  deadline=0
  next_lease=0
fi
while :; do
  [ "$DRAIN_ABORTED" -eq 0 ] || break
  all_exited=1
  i=0
  while [ "$i" -lt "$CAPABLE_COUNT" ]; do
    if _agmsg_pid_alive "${CAPABLE_PIDS[$i]}"; then all_exited=0; break; fi
    i=$((i + 1))
  done
  [ "$all_exited" -eq 1 ] && break

  now="$(_agmsg_lifecycle_epoch)" || {
    DRAIN_ABORTED=1
    break
  }
  [ "$now" -ge "$deadline" ] && break
  maintain_leases_if_due || break
  sleep "$DRAIN_POLL_INTERVAL"
done

if [ "$DRAIN_ABORTED" -eq 0 ]; then
  maintain_leases_if_due || true
fi
if [ "$DRAIN_ABORTED" -eq 0 ]; then
  i=0
  while [ "$i" -lt "$CAPABLE_COUNT" ]; do
    timed_out=0
    cleanup_rc=0
    _agmsg_pid_alive "${CAPABLE_PIDS[$i]}" && timed_out=1
    cleanup_target_locked "${CAPABLE_NAMES[$i]}" "${CAPABLE_RECORDS[$i]}" \
      || cleanup_rc=$?
    if [ "$DRAIN_ABORTED" -eq 1 ]; then
      break
    fi
    if [ "$timed_out" -eq 1 ]; then
      if [ "$cleanup_rc" -eq 0 ]; then
        notify_drain_timeout "${CAPABLE_NAMES[$i]}" "${CAPABLE_PIDS[$i]}"
      elif [ "$cleanup_rc" -eq 4 ]; then
        notify_drain_timeout \
          "${CAPABLE_NAMES[$i]}" "${CAPABLE_PIDS[$i]}" unverified
      fi
    fi
    maintain_leases_if_due || true
    [ "$DRAIN_ABORTED" -eq 0 ] || break
    i=$((i + 1))
  done
fi

cleanup_session_artifacts
exit 0
