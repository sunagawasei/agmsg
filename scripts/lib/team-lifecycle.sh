#!/usr/bin/env bash
# team-lifecycle.sh — serialization and drain-fence primitives for one team.

: "${SKILL_DIR:?team-lifecycle.sh requires SKILL_DIR}"

if ! command -v agmsg_runtime_lock_acquire >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  . "$SKILL_DIR/scripts/lib/storage.sh"
fi
if ! command -v _actas_lock_encode >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  . "$SKILL_DIR/scripts/lib/actas-lock.sh"
fi

_agmsg_lifecycle_epoch() {
  local now
  now="$(date +%s 2>/dev/null)" || return 1
  case "$now" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$now"
}

agmsg_team_lifecycle_resource() {
  printf 'team-lifecycle:%s' "$(_actas_lock_encode "$1")"
}

# Serialize SessionStart registration, drain ownership, and the final
# check-and-despawn path. The SQLite lock survives across unrelated shell
# processes and supports an owner-checked stale takeover.
agmsg_team_lifecycle_lock_acquire() {
  local team="$1" timeout="${2:-10}" resource owner now started="" last="" elapsed=0
  local interval
  case "$timeout" in ''|*[!0-9]*) return 1 ;; esac
  interval="$(agmsg_wait_knob_resolve \
    "${AGMSG_LIFECYCLE_LOCK_POLL_INTERVAL-}" 0.05 0.01 60 decimal)"
  resource="$(agmsg_team_lifecycle_resource "$team")"

  while :; do
    owner="$(agmsg_runtime_lock_acquire "$resource" "$$" 2>/dev/null || true)"
    if [ "$owner" = "$$" ]; then
      return 0
    fi

    case "$owner" in
      ''|*[!0-9]*) ;;
      *)
        if ! kill -0 "$owner" 2>/dev/null; then
          owner="$(agmsg_runtime_lock_acquire "$resource" "$$" "$owner" 2>/dev/null || true)"
          [ "$owner" = "$$" ] && return 0
        fi
        ;;
    esac

    now="$(_agmsg_lifecycle_epoch)" || return 1
    if [ -z "$started" ] || [ "$now" -lt "$last" ]; then
      started="$now"
      last="$now"
      elapsed=0
    else
      last="$now"
      elapsed=$((now - started))
    fi
    [ "$elapsed" -ge "$timeout" ] && return 1
    sleep "$interval"
  done
}

agmsg_team_lifecycle_lock_verify() {
  agmsg_runtime_lock_verify "$(agmsg_team_lifecycle_resource "$1")" "$$"
}

agmsg_team_lifecycle_lock_release() {
  agmsg_runtime_lock_release "$(agmsg_team_lifecycle_resource "$1")" "$$"
}

agmsg_drain_fence_path() {
  printf '%s/run/drain.%s.fence' "$SKILL_DIR" "$(_actas_lock_encode "$1")"
}

agmsg_drain_marker_path() {
  local team="$1" name="$2" pid="$3"
  printf '%s/run/draining.%s__%s.%s' "$SKILL_DIR" \
    "$(_actas_lock_encode "$team")" "$(_actas_lock_encode "$name")" "$pid"
}

# Populate AGMSG_DRAIN_FENCE_{NONCE,OWNER,TEAM,LEASE_EPOCH}. Unknown, duplicate,
# missing, symlinked, or non-canonical records are rejected.
agmsg_drain_fence_read() {
  local path="$1" expected_team="$2" line key value lines=0
  AGMSG_DRAIN_FENCE_NONCE=""
  AGMSG_DRAIN_FENCE_OWNER=""
  AGMSG_DRAIN_FENCE_TEAM=""
  AGMSG_DRAIN_FENCE_LEASE_EPOCH=""
  [ -f "$path" ] && [ ! -L "$path" ] && [ -r "$path" ] || return 1

  while IFS= read -r line || [ -n "$line" ]; do
    lines=$((lines + 1))
    [ "$lines" -le 4 ] || return 1
    case "$line" in *=*) ;; *) return 1 ;; esac
    key="${line%%=*}"
    value="${line#*=}"
    [ -n "$value" ] || return 1
    case "$value" in *[![:graph:]]*) return 1 ;; esac
    case "$key" in
      nonce) [ -z "$AGMSG_DRAIN_FENCE_NONCE" ] || return 1; AGMSG_DRAIN_FENCE_NONCE="$value" ;;
      owner) [ -z "$AGMSG_DRAIN_FENCE_OWNER" ] || return 1; AGMSG_DRAIN_FENCE_OWNER="$value" ;;
      team) [ -z "$AGMSG_DRAIN_FENCE_TEAM" ] || return 1; AGMSG_DRAIN_FENCE_TEAM="$value" ;;
      lease_epoch) [ -z "$AGMSG_DRAIN_FENCE_LEASE_EPOCH" ] || return 1; AGMSG_DRAIN_FENCE_LEASE_EPOCH="$value" ;;
      *) return 1 ;;
    esac
  done < "$path"

  [ "$lines" -eq 4 ] || return 1
  [ "$AGMSG_DRAIN_FENCE_TEAM" = "$expected_team" ] || return 1
  case "$AGMSG_DRAIN_FENCE_LEASE_EPOCH" in ''|*[!0-9]*) return 1 ;; esac
}

agmsg_drain_fence_is_live() {
  local path="$1" team="$2" stale_s="$3" now age
  case "$stale_s" in ''|*[!0-9]*) return 1 ;; esac
  agmsg_drain_fence_read "$path" "$team" || return 1
  now="$(_agmsg_lifecycle_epoch)" || return 1
  [ "$now" -ge "$AGMSG_DRAIN_FENCE_LEASE_EPOCH" ] || return 1
  age=$((now - AGMSG_DRAIN_FENCE_LEASE_EPOCH))
  [ "$age" -le "$stale_s" ]
}

# The caller must hold the team lifecycle lock. noclobber is the publication
# primitive required by the drain protocol; one printf writes the complete
# record before any signal is sent to a bridge.
agmsg_drain_fence_create() {
  local path="$1" nonce="$2" owner="$3" team="$4" lease_epoch="$5"
  [ ! -L "$path" ] || return 1
  (
    set -C
    umask 077
    printf 'nonce=%s\nowner=%s\nteam=%s\nlease_epoch=%s\n' \
      "$nonce" "$owner" "$team" "$lease_epoch" > "$path"
  ) 2>/dev/null
}

# Refresh all fence content through a same-directory atomic rename. The old
# record must still belong to the expected nonce/owner/team before replacement.
agmsg_drain_fence_refresh() {
  local path="$1" nonce="$2" owner="$3" team="$4" lease_epoch="$5" tmp
  agmsg_drain_fence_read "$path" "$team" || return 1
  [ "$AGMSG_DRAIN_FENCE_NONCE" = "$nonce" ] || return 1
  [ "$AGMSG_DRAIN_FENCE_OWNER" = "$owner" ] || return 1
  tmp="$path.tmp.$$"
  umask 077
  if ! printf 'nonce=%s\nowner=%s\nteam=%s\nlease_epoch=%s\n' \
      "$nonce" "$owner" "$team" "$lease_epoch" > "$tmp" \
      || ! mv -f -- "$tmp" "$path"; then
    rm -f -- "$tmp" 2>/dev/null || true
    return 1
  fi
}

agmsg_drain_fence_remove_owned() {
  local path="$1" nonce="$2" owner="$3" team="$4"
  agmsg_drain_fence_read "$path" "$team" || return 0
  [ "$AGMSG_DRAIN_FENCE_NONCE" = "$nonce" ] || return 0
  [ "$AGMSG_DRAIN_FENCE_OWNER" = "$owner" ] || return 0
  rm -f -- "$path" 2>/dev/null || true
}

agmsg_drain_marker_publish() {
  local path="$1" nonce="$2" pid="$3" tmp
  [ ! -e "$path" ] && [ ! -L "$path" ] || return 0
  tmp="$path.tmp.$$"
  umask 077
  if ! printf 'nonce=%s\npid=%s\n' "$nonce" "$pid" > "$tmp"; then
    rm -f -- "$tmp" 2>/dev/null || true
    return 1
  fi
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    mv -- "$tmp" "$path" 2>/dev/null || rm -f -- "$tmp" 2>/dev/null || true
  else
    rm -f -- "$tmp" 2>/dev/null || true
  fi
}

agmsg_drain_marker_matches_nonce() {
  local path="$1" nonce="$2" marker_nonce marker_pid extra
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  marker_nonce="$(sed -n 's/^nonce=//p' "$path" 2>/dev/null | head -1)"
  marker_pid="$(sed -n 's/^pid=//p' "$path" 2>/dev/null | head -1)"
  extra="$(sed -n '3p' "$path" 2>/dev/null || true)"
  [ "$marker_nonce" = "$nonce" ] || return 1
  case "$marker_pid" in ''|*[!0-9]*) return 1 ;; esac
  [ -z "$extra" ]
}
