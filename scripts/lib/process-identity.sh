#!/usr/bin/env bash

# Process identity for long-lived agmsg watchers and bridges.
#
# A pid answers only "is something using this number?".  An owner sidecar plus
# a kernel lease answers the stronger question used here: "is that process the
# current owner of this logical slot?".  PID liveness intentionally remains in
# instance-id.sh so its Windows/tasklist and sandbox EPERM behaviour is shared.
[ -n "${_AGMSG_PROCESS_IDENTITY_SH:-}" ] && return 0
_AGMSG_PROCESS_IDENTITY_SH=1

_agmsg_process_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$_agmsg_process_lib_dir/instance-id.sh"
# shellcheck disable=SC1091
. "$_agmsg_process_lib_dir/compat.sh"
# shellcheck disable=SC1091
. "$_agmsg_process_lib_dir/hash.sh"

AGMSG_PROCESS_LEASE_FD=19
readonly AGMSG_PROCESS_LEASE_FD

agmsg_process_owner_path() {
  case "$1" in
    *.pid) printf '%s.owner\n' "${1%.pid}" ;;
    *) printf '%s.owner\n' "$1" ;;
  esac
}

agmsg_process_lease_path() {
  local base generation="${2:-}"
  case "$1" in
    *.pid) base="${1%.pid}" ;;
    *) base="$1" ;;
  esac
  case "$generation" in
    '') printf '%s.lease.claim\n' "$base" ;;
    *) printf '%s.lease.%s\n' "$base" "$generation" ;;
  esac
}

agmsg_process_scope_hash() {
  local digest=""
  case "$1" in
    @hash:*) printf '%s\n' "${1#@hash:}"; return 0 ;;
  esac
  if command -v sha256sum >/dev/null 2>&1; then
    digest="$(printf '%s' "$1" | sha256sum 2>/dev/null | awk '{print $1}' || true)"
  fi
  if [ -z "$digest" ] && command -v openssl >/dev/null 2>&1; then
    digest="$(printf '%s' "$1" | openssl dgst -sha256 2>/dev/null | awk '{print $NF}' || true)"
  fi
  [ -n "$digest" ] \
    || digest="$(printf '%s' "$1" | cksum | awk '{print $1 ":" $2}')"
  printf '%s\n' "$digest"
}

_agmsg_process_read_pid() {
  local pid=""
  [ -f "$1" ] && IFS= read -r pid < "$1" 2>/dev/null || true
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ "$pid" -gt 0 ] 2>/dev/null || return 1
  printf '%s' "$pid"
}

_agmsg_process_owner_field() {
  local file="$1" key="$2"
  [ -f "$file" ] || return 1
  sed -n "s/^${key}=//p" "$file" 2>/dev/null | head -1
}

_agmsg_process_lockf_bin() {
  if [ -n "${AGMSG_TEST_PROCESS_LOCKF:-}" ]; then
    printf '%s' "$AGMSG_TEST_PROCESS_LOCKF"
  elif [ -x /usr/bin/lockf ]; then
    printf '%s' /usr/bin/lockf
  else
    command -v lockf 2>/dev/null || true
  fi
}

# Return 0 when free, 75 when held, 69 when this environment cannot probe.
agmsg_process_probe_lease() {
  local lease="$1" lockf_bin rc
  lockf_bin="$(_agmsg_process_lockf_bin)"
  [ -n "$lockf_bin" ] || return 69
  if "$lockf_bin" -k -s -t 0 "$lease" /usr/bin/true >/dev/null 2>&1; then
    rc=0
  else
    rc=$?
  fi
  case "$rc" in 0|75) return "$rc" ;; *) return 69 ;; esac
}

_agmsg_process_legacy_cmd_matches() {
  local kind="$1" cmd="$2" needle
  shift 2
  case "$kind:$cmd" in
    watch:*watch.sh*) ;;
    codex-bridge:*codex-bridge*) ;;
    cursor-bridge:*cursor-bridge.sh*) ;;
    claude-code-bridge:*claude-code-bridge.sh*) ;;
    *) return 1 ;;
  esac
  for needle in "$@"; do
    [ -n "$needle" ] || continue
    case "$cmd" in *"$needle"*) ;; *) return 1 ;; esac
  done
  return 0
}

# Populate AGMSG_PROCESS_* globals.  Optional arguments after scope are legacy
# cmdline needles; every non-empty needle must match before a legacy PID is
# classified exact.
agmsg_process_identity_state() {
  local kind="$1" pidfile="$2" scope="$3"
  shift 3
  local owner lease pid owner_pid owner_kind owner_scope owner_generation
  local owner_lease scope_hash probe_rc cmd version

  AGMSG_PROCESS_STATE=""
  AGMSG_PROCESS_PID=""
  AGMSG_PROCESS_GENERATION=""
  AGMSG_PROCESS_SCOPE_HASH=""
  AGMSG_PROCESS_OWNER_LEASE=""

  owner="$(agmsg_process_owner_path "$pidfile")"
  pid="$(_agmsg_process_read_pid "$pidfile" 2>/dev/null || true)"
  scope_hash="$(agmsg_process_scope_hash "$scope")"
  AGMSG_PROCESS_PID="$pid"
  AGMSG_PROCESS_SCOPE_HASH="$scope_hash"

  if [ -f "$owner" ]; then
    version="$(_agmsg_process_owner_field "$owner" version || true)"
    owner_pid="$(_agmsg_process_owner_field "$owner" pid || true)"
    owner_kind="$(_agmsg_process_owner_field "$owner" kind || true)"
    owner_scope="$(_agmsg_process_owner_field "$owner" scope || true)"
    owner_generation="$(_agmsg_process_owner_field "$owner" generation || true)"
    owner_lease="$(_agmsg_process_owner_field "$owner" lease || true)"
    lease="$(agmsg_process_lease_path "$pidfile" "$owner_generation")"
    AGMSG_PROCESS_GENERATION="$owner_generation"
    AGMSG_PROCESS_OWNER_LEASE="$owner_lease"
    [ -z "$scope" ] && AGMSG_PROCESS_SCOPE_HASH="$owner_scope"

    case "$owner_lease" in
      leased)
        if agmsg_process_probe_lease "$lease"; then
          AGMSG_PROCESS_STATE=stale
        else
          probe_rc=$?
          if [ "$probe_rc" -eq 75 ]; then
            if [ "$version" = 1 ] \
                && [ "$owner_kind" = "$kind" ] \
                && { [ -z "$scope" ] || [ "$owner_scope" = "$scope_hash" ]; } \
                && [ -n "$pid" ] && [ "$pid" = "$owner_pid" ] \
                && [ -n "$owner_generation" ] \
                && _agmsg_pid_alive "$pid"; then
              AGMSG_PROCESS_STATE=owned
            else
              AGMSG_PROCESS_STATE=held-unverified
            fi
          elif [ -n "$pid" ] && _agmsg_pid_alive "$pid"; then
            AGMSG_PROCESS_STATE=unverified-live
          else
            AGMSG_PROCESS_STATE=unverified-dead
          fi
        fi
        return 0
        ;;
      degraded)
        if [ "$version" = 1 ] \
            && [ "$owner_kind" = "$kind" ] \
            && { [ -z "$scope" ] || [ "$owner_scope" = "$scope_hash" ]; } \
            && [ -n "$pid" ] && [ "$pid" = "$owner_pid" ] \
            && [ -n "$owner_generation" ] && _agmsg_pid_alive "$pid"; then
          AGMSG_PROCESS_STATE=degraded-live
        elif [ -n "$pid" ] && _agmsg_pid_alive "$pid"; then
          AGMSG_PROCESS_STATE=unverified-live
        else
          AGMSG_PROCESS_STATE=degraded-dead
        fi
        return 0
        ;;
      *)
        if agmsg_process_probe_lease "$lease"; then
          AGMSG_PROCESS_STATE=stale
        else
          probe_rc=$?
          if [ "$probe_rc" -eq 75 ]; then
            AGMSG_PROCESS_STATE=held-unverified
          elif [ -n "$pid" ] && _agmsg_pid_alive "$pid"; then
            AGMSG_PROCESS_STATE=unverified-live
          else
            AGMSG_PROCESS_STATE=unverified-dead
          fi
        fi
        return 0
        ;;
    esac
  fi

  if [ -z "$pid" ] || ! _agmsg_pid_alive "$pid"; then
    AGMSG_PROCESS_STATE=legacy-dead
    return 0
  fi
  cmd="$(compat_get_cmdline "$pid" 2>/dev/null || true)"
  if [ -z "$cmd" ]; then
    AGMSG_PROCESS_STATE=legacy-unverified-live
  elif _agmsg_process_legacy_cmd_matches "$kind" "$cmd" "$@"; then
    AGMSG_PROCESS_STATE=legacy-exact-live
  else
    AGMSG_PROCESS_STATE=legacy-foreign-live
  fi
}

# Success means the caller must suppress a duplicate start/directive.
agmsg_process_dedup_should_suppress() {
  agmsg_process_identity_state "$@" || return 1
  case "$AGMSG_PROCESS_STATE" in
    owned|held-unverified)
      return 0
      ;;
    legacy-exact-live|legacy-unverified-live)
      echo "agmsg identity: legacy pidfile without owner record; falling back to PID-only dedup: $2" >&2
      return 0
      ;;
    degraded-live)
      echo "agmsg identity: degraded owner without lease; falling back to PID-only dedup: $2" >&2
      return 0
      ;;
    unverified-live)
      echo "agmsg identity: lease probe unavailable; falling back to PID-only dedup: $2" >&2
      return 0
      ;;
  esac
  return 1
}

# Print the immutable PID/generation/scope snapshot only for a confirmed owner.
agmsg_process_signal_decision() {
  local kind="$1" pidfile="$2" scope="$3"
  agmsg_process_identity_state "$@" || return 1
  if [ "$AGMSG_PROCESS_STATE" = owned ]; then
    printf '%s\t%s\t%s\n' "$AGMSG_PROCESS_PID" "$AGMSG_PROCESS_GENERATION" "$AGMSG_PROCESS_SCOPE_HASH"
    return 0
  fi
  case "$AGMSG_PROCESS_STATE" in
    legacy-*)
      echo "agmsg identity: legacy pidfile without owner record; signal not authorized: $pidfile" >&2 ;;
    degraded-*|unverified-*)
      echo "agmsg identity: owner lease unavailable; signal not authorized: $pidfile" >&2 ;;
  esac
  return 1
}

_agmsg_process_resolve_python() {
  local launcher="$_agmsg_process_lib_dir/../internal/process-owner-launch.sh"
  "$launcher" --resolve-python 2>/dev/null
}

# The only signal-authorizing API.  The Python helper re-reads owner/pidfile,
# re-probes the same lease and calls os.kill without returning to a shell race.
agmsg_process_signal_owned() {
  local kind="$1" pidfile="$2" scope="$3" signal=TERM
  if [ "$#" -ge 4 ]; then
    signal="$4"
    shift 4
  else
    shift 3
  fi
  local snapshot pid generation scope_hash python helper wait_release=""
  local expected_pid="" expected_generation="" expected_scope_hash=""
  local -a wait_args=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --expected-owner)
        expected_pid="${2:-}"
        expected_generation="${3:-}"
        expected_scope_hash="${4:-}"
        case "$expected_pid" in ''|*[!0-9]*) return 1 ;; esac
        [ -n "$expected_generation" ] && [ -n "$expected_scope_hash" ] || return 1
        shift 4
        ;;
      --wait-release)
        wait_release="${2:-}"
        case "$wait_release" in ''|*[!0-9]*) return 1 ;; esac
        [ "$wait_release" -gt 0 ] 2>/dev/null || return 1
        shift 2
        ;;
      *) break ;;
    esac
  done
  if [ -n "$expected_pid" ]; then
    pid="$expected_pid"
    generation="$expected_generation"
    scope_hash="$expected_scope_hash"
  else
    snapshot="$(agmsg_process_signal_decision "$kind" "$pidfile" "$scope" "$@")" || return 1
    IFS=$'\t' read -r pid generation scope_hash <<EOF
$snapshot
EOF
  fi
  if [ -n "$wait_release" ]; then
    wait_args=(--wait-release-timeout "$wait_release")
  fi
  python="$(_agmsg_process_resolve_python)"
  [ -n "$python" ] || return 1
  helper="$_agmsg_process_lib_dir/../internal/process-owner-exec.py"
  "$python" -B "$helper" signal \
    --kind "$kind" --pidfile "$pidfile" --scope "$scope_hash" \
    --pid "$pid" --generation "$generation" --signal "$signal" \
    ${wait_args[@]+"${wait_args[@]}"}
}

agmsg_process_cleanup_self() {
  local kind="$1" pidfile="$2" scope="$3"
  local owner owner_pid="" owner_kind="" owner_scope="" owner_generation=""
  local pid="" scope_hash lease base line value
  local seen_pid=0 seen_kind=0 seen_scope=0 seen_generation=0
  case "$pidfile" in
    *.pid) base="${pidfile%.pid}" ;;
    *) base="$pidfile" ;;
  esac
  owner="$base.owner"
  [ -f "$pidfile" ] && IFS= read -r pid < "$pidfile" 2>/dev/null || true
  case "$pid" in
    ''|*[!0-9]*) pid="" ;;
    *) [ "$pid" -gt 0 ] 2>/dev/null || pid="" ;;
  esac
  # Bash 3.2 can leak a failed stdout write into later command substitutions.
  # Read the cleanup identity directly so a closed consumer cannot taint it.
  if [ -f "$owner" ]; then
    while IFS= read -r line; do
      case "$line" in
        pid=*)
          value="${line#pid=}"
          if [ "$seen_pid" -eq 0 ]; then owner_pid="$value"; else owner_pid=""; fi
          seen_pid=$((seen_pid + 1))
          ;;
        kind=*)
          value="${line#kind=}"
          if [ "$seen_kind" -eq 0 ]; then owner_kind="$value"; else owner_kind=""; fi
          seen_kind=$((seen_kind + 1))
          ;;
        scope=*)
          value="${line#scope=}"
          if [ "$seen_scope" -eq 0 ]; then owner_scope="$value"; else owner_scope=""; fi
          seen_scope=$((seen_scope + 1))
          ;;
        generation=*)
          value="${line#generation=}"
          if [ "$seen_generation" -eq 0 ]; then owner_generation="$value"; else owner_generation=""; fi
          seen_generation=$((seen_generation + 1))
          ;;
      esac
    done < "$owner"
  fi
  case "$scope" in
    @hash:*) scope_hash="${scope#@hash:}" ;;
    *) scope_hash="$(agmsg_process_scope_hash "$scope")" ;;
  esac
  if [ "$pid" = "$$" ] && [ "$owner_pid" = "$$" ] \
      && [ "$owner_kind" = "$kind" ] && [ "$owner_scope" = "$scope_hash" ] \
      && [ -n "$owner_generation" ] \
      && [ -n "${AGMSG_PROCESS_OWNER_GENERATION:-}" ] \
      && [ "$owner_generation" = "$AGMSG_PROCESS_OWNER_GENERATION" ]; then
    lease="$base.lease.$owner_generation"
    rm -f "$pidfile" "$owner" "$lease" 2>/dev/null || true
  fi
}

# Revalidate and remove the observed generation under the publication claim.
# A successor either wins the claim first and changes identity, or waits.
agmsg_process_cleanup_observed() {
  local pidfile="$1" claim lockf_bin launcher observed_pid observed_generation rc
  local allow_missing=0
  local -a companions=()
  shift
  if [ "${1:-}" = --allow-missing-owner ]; then
    allow_missing=1
    shift
  fi
  companions=("$@")
  observed_pid="$AGMSG_PROCESS_PID"
  observed_generation="$AGMSG_PROCESS_GENERATION"
  lockf_bin="$(_agmsg_process_lockf_bin)"
  [ -n "$lockf_bin" ] || return 69
  claim="$(agmsg_process_lease_path "$pidfile")"
  launcher="$_agmsg_process_lib_dir/../internal/process-owner-launch.sh"
  if "$lockf_bin" -k -s -t 0 "$claim" "$launcher" \
      --internal-cleanup-observed "$pidfile" "$observed_pid" \
      "$observed_generation" "$allow_missing" -- \
      ${companions[@]+"${companions[@]}"}; then
    return 0
  fi
  rc=$?
  case "$rc" in 69|70|75) return "$rc" ;; *) return 1 ;; esac
}

# Return 0 for a valid re-entry, 75 when the caller must exec the launcher, and
# 70 for a forged/corrupt leased or degraded marker.
agmsg_process_assert_bootstrap() {
  local kind="$1" pidfile="$2" scope="$3" owner owner_pid owner_kind
  local owner_scope owner_generation owner_lease scope_hash
  case "${AGMSG_PROCESS_BOOTSTRAP_MODE:-}" in
    '') return 75 ;;
    leased|degraded) ;;
    *) return 70 ;;
  esac
  owner="$(agmsg_process_owner_path "$pidfile")"
  owner_pid="$(_agmsg_process_owner_field "$owner" pid || true)"
  owner_kind="$(_agmsg_process_owner_field "$owner" kind || true)"
  owner_scope="$(_agmsg_process_owner_field "$owner" scope || true)"
  owner_generation="$(_agmsg_process_owner_field "$owner" generation || true)"
  owner_lease="$(_agmsg_process_owner_field "$owner" lease || true)"
  scope_hash="$(agmsg_process_scope_hash "$scope")"
  [ "$owner_pid" = "$$" ] && [ "$owner_kind" = "$kind" ] \
    && [ "$owner_scope" = "$scope_hash" ] \
    && [ -n "$owner_generation" ] \
    && [ -n "${AGMSG_PROCESS_OWNER_GENERATION:-}" ] \
    && [ "$owner_generation" = "${AGMSG_PROCESS_OWNER_GENERATION:-}" ] \
    && [ "$owner_lease" = "$AGMSG_PROCESS_BOOTSTRAP_MODE" ] \
    && [ "$(_agmsg_process_read_pid "$pidfile" 2>/dev/null || true)" = "$$" ] \
    || return 70
  if [ "$AGMSG_PROCESS_BOOTSTRAP_MODE" = leased ]; then
    [ "${AGMSG_PROCESS_OWNER_FD:-}" = "$AGMSG_PROCESS_LEASE_FD" ] || return 70
    : <&19 2>/dev/null || return 70
    agmsg_process_probe_lease "$(agmsg_process_lease_path "$pidfile" "$owner_generation")"
    [ "$?" -eq 75 ] || return 70
  # Degraded re-entry is valid only while an execution probe still says that
  # the lease backend is unavailable.  Recovery must return through launcher.
  elif [ "${AGMSG_PROCESS_IDENTITY_BACKEND:-auto}" != unavailable ] \
      && [ -n "$(_agmsg_process_resolve_python)" ]; then
    return 75
  fi
  # Pin the already-validated hash for EXIT cleanup. Recomputing it after a
  # failed stdout write is unsafe on Bash 3.2, where $(...) can be contaminated.
  AGMSG_PROCESS_SCOPE_HASH="$scope_hash"
  return 0
}
