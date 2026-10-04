#!/usr/bin/env bash

# Deferred headless teardown. A record is actionable only after the process
# that owned the session is positively observed dead or replaced (same PID,
# different process-generation token). Missing or ambiguous evidence always
# retains the record and the target worker.
[ -n "${_AGMSG_PENDING_TEARDOWN_SH:-}" ] && return 0
_AGMSG_PENDING_TEARDOWN_SH=1

: "${SKILL_DIR:?pending-teardown.sh requires SKILL_DIR}"

_agmsg_pending_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$_agmsg_pending_lib_dir/actas-lock.sh"
# shellcheck disable=SC1091
. "$_agmsg_pending_lib_dir/type-registry.sh"
if ! command -v agmsg_team_lifecycle_lock_acquire >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  . "$_agmsg_pending_lib_dir/team-lifecycle.sh"
fi

AGMSG_PENDING_VERSION=2

agmsg_pending_teardown_path() {
  local team="$1" name="$2"
  printf '%s/run/pending-teardown.%s__%s' "$SKILL_DIR" \
    "$(_actas_lock_encode "$team")" "$(_actas_lock_encode "$name")"
}

_agmsg_pending_encoded_canonical() {
  local encoded="$1" decoded
  decoded="$(_actas_lock_decode "$encoded" 2>/dev/null)" || return 1
  [ "$(_actas_lock_encode "$decoded" 2>/dev/null)" = "$encoded" ] || return 1
  printf '%s' "$decoded"
}

# Keep one-record diagnostics on one physical line even when an untrusted path
# or decoded identity contains terminal controls. Printable non-ASCII bytes are
# preserved; only C0 controls and DEL are removed. Match the existing spawn-log
# convention of an 80-character field, reserving the final three for a visible
# truncation marker so one oversized identity cannot flood stderr.
agmsg_pending_log_sanitize() {
  local val
  val="$(printf '%s' "${1:-}" | LC_ALL=C tr -d '\000-\037\177')"
  if [ "${#val}" -gt 80 ]; then
    printf '%s...' "${val:0:77}"
  else
    printf '%s' "$val"
  fi
}

# Atomically publish one immutable target snapshot. owner_state is verified
# only when owner_instance, owner_pid, and owner_start describe one process
# generation. An unverified record is intentionally valid but never actionable.
agmsg_pending_teardown_write() {
  local team="$1" name="$2" type="$3" reason="$4" record="$5"
  local owner_state="$6" owner_instance="${7:-}" owner_pid="${8:-}"
  local owner_start="${9:-}" owner_env="${10:-}" owner_tombstone="${11:-}"
  local bridge_start="${12:-}" placement rest project record_type created path tmp
  local bridge_pid

  case "$record" in *$'\n'*) return 1 ;; esac
  case "$record" in *$'\t'*) ;; *) return 1 ;; esac
  placement="${record%%$'\t'*}"
  rest="${record#*$'\t'}"
  case "$rest" in *$'\t'*) ;; *) return 1 ;; esac
  project="${rest%%$'\t'*}"
  record_type="${rest#*$'\t'}"
  [ "$record_type" = "$type" ] || return 1
  case "$placement" in pid:[0-9]*) ;; *) return 1 ;; esac
  case "${placement#pid:}" in ''|*[!0-9]*) return 1 ;; esac
  [ "${placement#pid:}" -gt 0 ] 2>/dev/null || return 1
  bridge_pid="${placement#pid:}"
  if [ -z "$bridge_start" ] && _agmsg_pid_alive "$bridge_pid"; then
    bridge_start="$(agmsg_pid_start_token "$bridge_pid" 2>/dev/null || true)"
  fi
  [ -n "$project" ] && [ -n "$reason" ] || return 1
  agmsg_is_known_type "$type" || return 1
  [ "$(agmsg_type_get "$type" headless no)" = yes ] || return 1

  case "$owner_state" in
    verified)
      agmsg_instance_is_composite "$owner_instance" || return 1
      [ "${owner_instance##*.}" = "$owner_pid" ] || return 1
      case "$owner_pid" in ''|*[!0-9]*) return 1 ;; esac
      [ -n "$owner_start" ] || return 1
      ;;
    unverified) ;;
    *) return 1 ;;
  esac

  created="$(date +%s 2>/dev/null)" || return 1
  case "$created" in ''|*[!0-9]*) return 1 ;; esac
  mkdir -p "$SKILL_DIR/run" 2>/dev/null || return 1
  path="$(agmsg_pending_teardown_path "$team" "$name")"
  tmp="$SKILL_DIR/run/.pending-teardown-write.$$.$RANDOM"
  if ! (
    umask 077
    printf '%s\n' \
        "version=$AGMSG_PENDING_VERSION" \
        "owner_state=$owner_state" \
        "owner_instance=$(_actas_lock_encode "$owner_instance")" \
        "owner_pid=$owner_pid" \
        "owner_start=$(_actas_lock_encode "$owner_start")" \
        "owner_env=$(_actas_lock_encode "$owner_env")" \
        "owner_tombstone=$(_actas_lock_encode "$owner_tombstone")" \
        "team=$(_actas_lock_encode "$team")" \
        "worker=$(_actas_lock_encode "$name")" \
        "type=$type" \
        "reason=$(_actas_lock_encode "$reason")" \
        "created=$created" \
        "placement=$(_actas_lock_encode "$placement")" \
        "bridge_start=$(_actas_lock_encode "$bridge_start")" \
        "project=$(_actas_lock_encode "$project")" >"$tmp"
  ); then
    rm -f -- "$tmp" 2>/dev/null || true
    return 1
  fi
  _agmsg_pending_publish "$team" "$path" "$tmp" "$owner_state"
}

# Replace the team/worker pending file only when the incoming snapshot is
# allowed to supersede it. Unverified must not clobber verified. The team
# lifecycle lock serializes this mv with recover's unlink.
_agmsg_pending_publish() {
  local team="$1" path="$2" tmp="$3" owner_state="$4"
  local lock_acquired=0 lock_timeout existing_state
  lock_timeout="${AGMSG_LIFECYCLE_LOCK_TIMEOUT:-10}"
  case "$lock_timeout" in ''|*[!0-9]*) lock_timeout=10 ;; esac
  if [ "${AGMSG_TEAM_LIFECYCLE_HELD:-}" = "$team" ]; then
    :
  elif agmsg_team_lifecycle_lock_acquire "$team" "$lock_timeout"; then
    lock_acquired=1
  else
    rm -f -- "$tmp" 2>/dev/null || true
    return 1
  fi
  if [ -f "$path" ] && [ ! -L "$path" ]; then
    existing_state="$(awk -F= '/^owner_state=/ { print $2; exit }' "$path" 2>/dev/null || true)"
    if [ "$existing_state" = verified ] && [ "$owner_state" = unverified ]; then
      rm -f -- "$tmp" 2>/dev/null || true
      [ "$lock_acquired" -eq 1 ] && agmsg_team_lifecycle_lock_release "$team"
      return 1
    fi
  fi
  if ! mv -f -- "$tmp" "$path"; then
    rm -f -- "$tmp" 2>/dev/null || true
    [ "$lock_acquired" -eq 1 ] && agmsg_team_lifecycle_lock_release "$team"
    return 1
  fi
  [ "$lock_acquired" -eq 1 ] && agmsg_team_lifecycle_lock_release "$team"
  return 0
}

_agmsg_pending_read_field() {
  local line="$1" key="$2"
  case "$line" in "$key="*) printf '%s' "${line#*=}" ;; *) return 1 ;; esac
}

# Populate AGMSG_PENDING_* globals from one strict, canonical record.
# Returns 2 for an unsupported version and 1 for malformed input.
agmsg_pending_teardown_read() {
  local path="$1" line extra="" key enc_team enc_name
  local version owner_state owner_instance owner_pid owner_start owner_env
  local owner_tombstone team worker type reason created placement bridge_start project
  local -a lines=()

  AGMSG_PENDING_PATH="$path"
  AGMSG_PENDING_OWNER_STATE=""
  AGMSG_PENDING_OWNER_INSTANCE=""
  AGMSG_PENDING_OWNER_PID=""
  AGMSG_PENDING_OWNER_START=""
  AGMSG_PENDING_OWNER_ENV=""
  AGMSG_PENDING_OWNER_TOMBSTONE=""
  AGMSG_PENDING_TEAM=""
  AGMSG_PENDING_WORKER=""
  AGMSG_PENDING_TYPE=""
  AGMSG_PENDING_REASON=""
  AGMSG_PENDING_CREATED=""
  AGMSG_PENDING_PLACEMENT=""
  AGMSG_PENDING_BRIDGE_START=""
  AGMSG_PENDING_PROJECT=""
  AGMSG_PENDING_RECORD=""

  [ -f "$path" ] && [ ! -L "$path" ] && [ -O "$path" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    lines[${#lines[@]}]="$line"
    [ "${#lines[@]}" -le 15 ] || return 1
  done <"$path"
  [ "${#lines[@]}" -ge 1 ] || return 1
  version="$(_agmsg_pending_read_field "${lines[0]}" version)" || return 1
  [ "$version" = "$AGMSG_PENDING_VERSION" ] || return 2
  [ "${#lines[@]}" -eq 15 ] || return 1
  owner_state="$(_agmsg_pending_read_field "${lines[1]}" owner_state)" || return 1
  owner_instance="$(_agmsg_pending_read_field "${lines[2]}" owner_instance)" || return 1
  owner_pid="$(_agmsg_pending_read_field "${lines[3]}" owner_pid)" || return 1
  owner_start="$(_agmsg_pending_read_field "${lines[4]}" owner_start)" || return 1
  owner_env="$(_agmsg_pending_read_field "${lines[5]}" owner_env)" || return 1
  owner_tombstone="$(_agmsg_pending_read_field "${lines[6]}" owner_tombstone)" || return 1
  team="$(_agmsg_pending_read_field "${lines[7]}" team)" || return 1
  worker="$(_agmsg_pending_read_field "${lines[8]}" worker)" || return 1
  type="$(_agmsg_pending_read_field "${lines[9]}" type)" || return 1
  reason="$(_agmsg_pending_read_field "${lines[10]}" reason)" || return 1
  created="$(_agmsg_pending_read_field "${lines[11]}" created)" || return 1
  placement="$(_agmsg_pending_read_field "${lines[12]}" placement)" || return 1
  bridge_start="$(_agmsg_pending_read_field "${lines[13]}" bridge_start)" || return 1
  project="$(_agmsg_pending_read_field "${lines[14]}" project)" || return 1

  AGMSG_PENDING_OWNER_INSTANCE="$(_agmsg_pending_encoded_canonical "$owner_instance")" || return 1
  AGMSG_PENDING_OWNER_START="$(_agmsg_pending_encoded_canonical "$owner_start")" || return 1
  AGMSG_PENDING_OWNER_ENV="$(_agmsg_pending_encoded_canonical "$owner_env")" || return 1
  AGMSG_PENDING_OWNER_TOMBSTONE="$(_agmsg_pending_encoded_canonical "$owner_tombstone")" || return 1
  AGMSG_PENDING_TEAM="$(_agmsg_pending_encoded_canonical "$team")" || return 1
  AGMSG_PENDING_WORKER="$(_agmsg_pending_encoded_canonical "$worker")" || return 1
  AGMSG_PENDING_REASON="$(_agmsg_pending_encoded_canonical "$reason")" || return 1
  AGMSG_PENDING_PLACEMENT="$(_agmsg_pending_encoded_canonical "$placement")" || return 1
  AGMSG_PENDING_BRIDGE_START="$(_agmsg_pending_encoded_canonical "$bridge_start")" || return 1
  AGMSG_PENDING_PROJECT="$(_agmsg_pending_encoded_canonical "$project")" || return 1
  AGMSG_PENDING_OWNER_STATE="$owner_state"
  AGMSG_PENDING_OWNER_PID="$owner_pid"
  AGMSG_PENDING_TYPE="$type"
  AGMSG_PENDING_CREATED="$created"

  key="${path##*/pending-teardown.}"
  enc_team="${key%%__*}"
  enc_name="${key#*__}"
  [ "$enc_team" != "$key" ] && [ -n "$enc_name" ] || return 1
  [ "$(_actas_lock_encode "$AGMSG_PENDING_TEAM")" = "$enc_team" ] || return 1
  [ "$(_actas_lock_encode "$AGMSG_PENDING_WORKER")" = "$enc_name" ] || return 1
  case "$created" in ''|*[!0-9]*) return 1 ;; esac
  case "$AGMSG_PENDING_PLACEMENT" in pid:[0-9]*) ;; *) return 1 ;; esac
  case "${AGMSG_PENDING_PLACEMENT#pid:}" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$AGMSG_PENDING_PROJECT" ] && [ -n "$AGMSG_PENDING_REASON" ] || return 1
  agmsg_is_known_type "$type" || return 1
  [ "$(agmsg_type_get "$type" headless no)" = yes ] || return 1

  case "$owner_state" in
    verified)
      agmsg_instance_is_composite "$AGMSG_PENDING_OWNER_INSTANCE" || return 1
      case "$owner_pid" in ''|*[!0-9]*) return 1 ;; esac
      [ "$owner_pid" -gt 0 ] 2>/dev/null || return 1
      [ "${AGMSG_PENDING_OWNER_INSTANCE##*.}" = "$owner_pid" ] || return 1
      [ -n "$AGMSG_PENDING_OWNER_START" ] || return 1
      ;;
    unverified) ;;
    *) return 1 ;;
  esac

  AGMSG_PENDING_RECORD="${AGMSG_PENDING_PLACEMENT}"$'\t'"${AGMSG_PENDING_PROJECT}"$'\t'"${AGMSG_PENDING_TYPE}"
}

_agmsg_pending_log_record_problem() {
  local path="$1" kind="$2" record
  record="$(agmsg_pending_log_sanitize "${path##*/}")"
  printf 'agmsg: pending teardown retained record=%s reason=%s\n' \
    "$record" "$kind" >&2
}

# Classify the pending record's placement PID.
# 0: live, same process generation as the recorded start token
# 1: not running
# 2: live, different generation (PID reuse / replacement)
# 3: live, but the generation cannot be verified
_agmsg_pending_bridge_generation() {
  local bridge_pid current_start bridge_method current_method
  bridge_pid="${AGMSG_PENDING_PLACEMENT#pid:}"
  _agmsg_pid_alive "$bridge_pid" || return 1
  if [ -z "$AGMSG_PENDING_BRIDGE_START" ]; then
    return 3
  fi
  current_start="$(agmsg_pid_start_token "$bridge_pid" 2>/dev/null)" || return 3
  bridge_method="$(agmsg_pid_start_token_method \
    "$AGMSG_PENDING_BRIDGE_START" 2>/dev/null || true)"
  current_method="$(agmsg_pid_start_token_method "$current_start" 2>/dev/null || true)"
  if [ -z "$bridge_method" ] || [ -z "$current_method" ] \
      || [ "$bridge_method" != "$current_method" ]; then
    return 3
  fi
  [ "$current_start" = "$AGMSG_PENDING_BRIDGE_START" ] && return 0
  return 2
}

agmsg_pending_teardown_recover_one() {
  local path="$1" despawn="$2" read_rc=0 current_start="" current record_path
  local recovery_reason=owner-dead owner_method current_method bare_sid
  local log_team log_worker lock_timeout lock_acquired=0
  local despawn_rc=0 bridge_rc=0 extra="" enc_only enc_skip pending_snapshot=""
  local -a despawn_args
  if [ -n "${AGMSG_PENDING_ONLY_TEAM:-}" ]; then
    enc_only="$(_actas_lock_encode "$AGMSG_PENDING_ONLY_TEAM")"
    case "$path" in
      */pending-teardown."$enc_only"__*) ;;
      *) return 0 ;;
    esac
  fi
  if [ -n "${AGMSG_PENDING_SKIP_TEAM:-}" ]; then
    enc_skip="$(_actas_lock_encode "$AGMSG_PENDING_SKIP_TEAM")"
    case "$path" in
      */pending-teardown."$enc_skip"__*) return 0 ;;
    esac
  fi
  agmsg_pending_teardown_read "$path" || read_rc=$?
  if [ "$read_rc" -ne 0 ]; then
    if [ "$read_rc" -eq 2 ]; then
      _agmsg_pending_log_record_problem "$path" unsupported-version
    else
      _agmsg_pending_log_record_problem "$path" malformed
    fi
    return 0
  fi

  log_team="$(agmsg_pending_log_sanitize "$AGMSG_PENDING_TEAM")"
  log_worker="$(agmsg_pending_log_sanitize "$AGMSG_PENDING_WORKER")"
  record_path="$(agmsg_spawn_path "$AGMSG_PENDING_TEAM" "$AGMSG_PENDING_WORKER")"
  if [ -n "${AGMSG_PENDING_ONLY_TEAM:-}" ] \
      && [ "$AGMSG_PENDING_TEAM" != "$AGMSG_PENDING_ONLY_TEAM" ]; then
    return 0
  fi
  if [ -n "${AGMSG_PENDING_SKIP_TEAM:-}" ] \
      && [ "$AGMSG_PENDING_TEAM" = "$AGMSG_PENDING_SKIP_TEAM" ]; then
    return 0
  fi

  _agmsg_pending_retain() {
    extra="${3:-}"
    if [ -n "$extra" ]; then
      printf 'agmsg: pending teardown retained team=%s worker=%s %s reason=%s\n' \
        "$log_team" "$log_worker" "$extra" "$4" >&2
    else
      printf 'agmsg: pending teardown retained team=%s worker=%s reason=%s\n' \
        "$log_team" "$log_worker" "$4" >&2
    fi
  }

  pending_snapshot="$(cat "$path" 2>/dev/null || true)"
  _agmsg_pending_unlink_if_same() {
    local now
    now="$(cat "$path" 2>/dev/null || true)"
    if [ -n "$pending_snapshot" ] && [ "$now" = "$pending_snapshot" ]; then
      rm -f -- "$path" 2>/dev/null || true
    fi
  }

  if [ "$AGMSG_PENDING_OWNER_STATE" = unverified ]; then
    bridge_rc=0
    _agmsg_pending_bridge_generation || bridge_rc=$?
    current="$(cat "$record_path" 2>/dev/null || true)"
    if [ -z "$current" ] && [ "$bridge_rc" -eq 1 ]; then
      _agmsg_pending_unlink_if_same
      printf 'agmsg: pending teardown recovered team=%s worker=%s reason=already-absent\n' \
        "$log_team" "$log_worker" >&2
      return 0
    fi
    _agmsg_pending_retain "" "" "" owner-unverified
    return 0
  fi

  if _agmsg_pid_alive "$AGMSG_PENDING_OWNER_PID"; then
    current_start="$(agmsg_pid_start_token "$AGMSG_PENDING_OWNER_PID" 2>/dev/null)" || {
      _agmsg_pending_retain "" "" "owner_pid=$AGMSG_PENDING_OWNER_PID" start-unavailable
      return 0
    }
    owner_method="$(agmsg_pid_start_token_method \
      "$AGMSG_PENDING_OWNER_START" 2>/dev/null || true)"
    current_method="$(agmsg_pid_start_token_method "$current_start" 2>/dev/null || true)"
    if [ -z "$owner_method" ] || [ -z "$current_method" ] \
        || [ "$owner_method" != "$current_method" ]; then
      _agmsg_pending_retain "" "" "owner_pid=$AGMSG_PENDING_OWNER_PID" \
        start-method-unverifiable
      return 0
    fi
    if [ "$current_start" = "$AGMSG_PENDING_OWNER_START" ]; then
      _agmsg_pending_retain "" "" "owner_pid=$AGMSG_PENDING_OWNER_PID" owner-alive
      return 0
    fi
    recovery_reason=owner-replaced
  fi

  _agmsg_pending_unlock() {
    [ "$lock_acquired" -eq 1 ] && agmsg_team_lifecycle_lock_release "$AGMSG_PENDING_TEAM"
  }

  lock_timeout="${AGMSG_LIFECYCLE_LOCK_TIMEOUT:-10}"
  case "$lock_timeout" in ''|*[!0-9]*) lock_timeout=10 ;; esac
  if [ "${AGMSG_TEAM_LIFECYCLE_HELD:-}" = "$AGMSG_PENDING_TEAM" ]; then
    :
  elif agmsg_team_lifecycle_lock_acquire "$AGMSG_PENDING_TEAM" "$lock_timeout"; then
    lock_acquired=1
  else
    _agmsg_pending_retain "" "" "" lifecycle-lock-unavailable
    return 0
  fi

  current="$(cat "$record_path" 2>/dev/null || true)"
  bridge_rc=0
  _agmsg_pending_bridge_generation || bridge_rc=$?
  if [ -z "$current" ]; then
    case "$bridge_rc" in
      0)
        _agmsg_pending_unlock
        _agmsg_pending_retain "" "" "" spawn-record-absent
        return 0
        ;;
      3)
        _agmsg_pending_unlock
        _agmsg_pending_retain "" "" \
          "bridge_pid=${AGMSG_PENDING_PLACEMENT#pid:}" bridge-start-unavailable
        return 0
        ;;
      *)
        _agmsg_pending_unlink_if_same
        _agmsg_pending_unlock
        printf 'agmsg: pending teardown recovered team=%s worker=%s reason=already-absent\n' \
          "$log_team" "$log_worker" >&2
        return 0
        ;;
    esac
  fi
  if [ "$current" != "$AGMSG_PENDING_RECORD" ]; then
    case "$bridge_rc" in
      0|3)
        _agmsg_pending_unlock
        _agmsg_pending_retain "" "" "" record-replaced-bridge-live
        return 0
        ;;
      *)
        _agmsg_pending_unlink_if_same
        _agmsg_pending_unlock
        printf 'agmsg: pending teardown recovered team=%s worker=%s reason=record-replaced\n' \
          "$log_team" "$log_worker" >&2
        return 0
        ;;
    esac
  fi

  # A shared bare session id is a veto only. Reaching this point already proves
  # that the pending record's composite owner died or changed generation; a
  # dead bare check by itself never authorizes teardown. Recheck under the
  # team lifecycle lock so a resume's cc-instance publish cannot land between
  # the veto and despawn.
  case "$AGMSG_PENDING_TEAM" in
    s-?*)
      bare_sid="${AGMSG_PENDING_TEAM#s-}"
      if agmsg_instance_alive "$bare_sid" 2>/dev/null; then
        _agmsg_pending_unlock
        _agmsg_pending_retain "" "" "" bare-owner-alive
        return 0
      fi
      ;;
  esac

  case "$bridge_rc" in
    3)
      _agmsg_pending_unlock
      _agmsg_pending_retain "" "" \
        "bridge_pid=${AGMSG_PENDING_PLACEMENT#pid:}" bridge-start-unavailable
      return 0
      ;;
    2)
      _agmsg_pending_unlink_if_same
      _agmsg_pending_unlock
      printf 'agmsg: pending teardown recovered team=%s worker=%s reason=bridge-replaced\n' \
        "$log_team" "$log_worker" >&2
      return 0
      ;;
  esac

  if [ -z "$AGMSG_PENDING_BRIDGE_START" ]; then
    _agmsg_pending_unlock
    _agmsg_pending_retain "" "" \
      "bridge_pid=${AGMSG_PENDING_PLACEMENT#pid:}" bridge-start-unavailable
    return 0
  fi

  despawn_args=("$despawn" "$AGMSG_PENDING_TEAM" claude "$AGMSG_PENDING_WORKER" \
    --force --expect-record "$AGMSG_PENDING_RECORD" \
    --expect-bridge-start "$AGMSG_PENDING_BRIDGE_START")
  despawn_rc=0
  "${despawn_args[@]}" >/dev/null 2>&1 || despawn_rc=$?
  if [ "$despawn_rc" -eq 5 ]; then
    _agmsg_pending_unlink_if_same
    _agmsg_pending_unlock
    printf 'agmsg: pending teardown recovered team=%s worker=%s reason=bridge-replaced\n' \
      "$log_team" "$log_worker" >&2
    return 0
  fi
  if [ "$despawn_rc" -eq 0 ] && [ ! -e "$record_path" ]; then
    _agmsg_pending_unlink_if_same
    _agmsg_pending_unlock
    printf 'agmsg: pending teardown recovered team=%s worker=%s reason=%s\n' \
      "$log_team" "$log_worker" "$recovery_reason" >&2
  else
    _agmsg_pending_unlock
    _agmsg_pending_retain "" "" "" recovery-incomplete
  fi
}

agmsg_pending_teardown_recover_all() {
  local despawn="$1" path
  for path in "$SKILL_DIR"/run/pending-teardown.*__*; do
    [ -e "$path" ] || [ -L "$path" ] || continue
    agmsg_pending_teardown_recover_one "$path" "$despawn" || true
  done
}

# Print "unverified" when this exact target has a valid unverified pending
# record. Used by SessionStart's report-only orphan inventory.
agmsg_pending_teardown_owner_state() {
  local path
  path="$(agmsg_pending_teardown_path "$1" "$2")"
  agmsg_pending_teardown_read "$path" >/dev/null 2>&1 || return 1
  printf '%s\n' "$AGMSG_PENDING_OWNER_STATE"
}
