#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck disable=SC1091
. "$SCRIPTS_DIR/lib/process-identity.sh"
# shellcheck disable=SC1091
. "$SCRIPTS_DIR/lib/compat.sh"

resolve_python() {
  local helper="$SCRIPT_DIR/process-owner-exec.py" candidate resolved seen="" count=0
  local -a candidates=()
  if [ -n "${AGMSG_TEST_PROCESS_PYTHON:-}" ]; then
    candidates+=("$AGMSG_TEST_PROCESS_PYTHON")
  else
    candidate="$(command -v python3 2>/dev/null || true)"
    [ -n "$candidate" ] && candidates+=("$candidate")
    candidates+=(/usr/bin/python3 /opt/homebrew/bin/python3 /usr/local/bin/python3)
  fi
  AGMSG_PROCESS_PYTHON_TRIED=0
  AGMSG_PROCESS_PYTHON=""
  for candidate in ${candidates[@]+"${candidates[@]}"}; do
    case "$candidate" in /*) ;; *) continue ;; esac
    resolved="$(cd "$(dirname "$candidate")" 2>/dev/null && pwd -P)/$(basename "$candidate")"
    case ":$seen:" in *:"$resolved":*) continue ;; esac
    seen="${seen:+$seen:}$resolved"
    count=$((count + 1))
    if "$resolved" -B "$helper" probe-interpreter >/dev/null 2>&1; then
      AGMSG_PROCESS_PYTHON_TRIED=$count
      AGMSG_PROCESS_PYTHON="$resolved"
      return 0
    fi
  done
  AGMSG_PROCESS_PYTHON_TRIED=$count
  return 1
}

# Internal handlers run as the child of lockf while the claim lease is held.
# Revalidation and mutation therefore share one publication barrier.
internal_cleanup_observed() {
  local pidfile="$1" expected_pid="$2" expected_generation="$3"
  local allow_missing="$4" owner claim current_pid current_generation artifact
  local -a artifacts companions
  shift 4
  companions=("$@")
  case "$allow_missing" in 0|1) ;; *) return 64 ;; esac
  owner="$(agmsg_process_owner_path "$pidfile")"
  claim="$(agmsg_process_lease_path "$pidfile")"
  current_pid="$(_agmsg_process_read_pid "$pidfile" 2>/dev/null || true)"
  current_generation="$(_agmsg_process_owner_field "$owner" generation || true)"
  if [ "$current_pid" = "$expected_pid" ] \
      && [ "$current_generation" = "$expected_generation" ]; then
    :
  elif [ "$allow_missing" -eq 1 ] && [ -z "$current_pid" ] \
      && { [ -z "$current_generation" ] \
        || [ "$current_generation" = "$expected_generation" ]; }; then
    :
  else
    return 75
  fi
  artifacts=("$pidfile" "$owner")
  if [ -n "$expected_generation" ]; then
    artifacts+=("$(agmsg_process_lease_path "$pidfile" "$expected_generation")")
  fi
  for artifact in ${companions[@]+"${companions[@]}"}; do
    case "$artifact" in /*) ;; *) return 64 ;; esac
    case "$artifact" in "$pidfile"|"$owner"|"$claim") return 64 ;; esac
    artifacts+=("$artifact")
  done
  rm -f -- ${artifacts[@]+"${artifacts[@]}"} 2>/dev/null || return 70
  return 0
}

internal_companions_match() {
  local pidfile="$1" expected_pid="$2" expected_generation="$3"
  local owner current_pid current_generation companion expected actual
  local -a companions
  shift 3
  companions=("$@")
  [ "$((${#companions[@]} % 2))" -eq 0 ] || return 64
  owner="$(agmsg_process_owner_path "$pidfile")"
  current_pid="$(_agmsg_process_read_pid "$pidfile" 2>/dev/null || true)"
  current_generation="$(_agmsg_process_owner_field "$owner" generation || true)"
  [ "$current_pid" = "$expected_pid" ] || return 75
  [ "$current_generation" = "$expected_generation" ] || return 75
  for ((companion_index = 0; companion_index < ${#companions[@]}; companion_index += 2)); do
    companion="${companions[$companion_index]}"
    expected="${companions[$((companion_index + 1))]}"
    case "$companion" in /*) ;; *) return 64 ;; esac
    actual=""
    IFS= read -r actual < "$companion" 2>/dev/null || true
    [ "$actual" = "$expected" ] || return 1
  done
  return 0
}

internal_publish_degraded() {
  local pidfile="$1" kind="$2" scope_hash="$3" generation="$4"
  local parent_pid="$5" replace_pid="$6" replace_generation="$7"
  local allow_missing_replace="$8"
  local owner claim owner_tmp pid_tmp current current_generation companion tmp value
  local -a companions companion_paths companion_tmps
  shift 8
  companions=("$@")
  case "$parent_pid" in ''|*[!0-9]*) return 64 ;; esac
  [ -n "$generation" ] || return 64
  case "$allow_missing_replace" in 0|1) ;; *) return 64 ;; esac
  [ "$((${#companions[@]} % 2))" -eq 0 ] || return 64
  current="$(_agmsg_process_read_pid "$pidfile" 2>/dev/null || true)"
  [ -z "$current" ] || [ "$current" = "$replace_pid" ] || return 75
  owner="$(agmsg_process_owner_path "$pidfile")"
  claim="$(agmsg_process_lease_path "$pidfile")"
  current_generation="$(_agmsg_process_owner_field "$owner" generation || true)"
  [ "$current_generation" = "$replace_generation" ] || return 75
  if [ -n "$replace_pid" ] && [ -z "$current" ] \
      && [ "$allow_missing_replace" -ne 1 ]; then
    return 75
  fi
  _agmsg_pid_alive "$parent_pid" || return 75

  owner_tmp="$owner.claim.$$"
  pid_tmp="$pidfile.claim.$$"
  umask 077
  for ((companion_index = 0; companion_index < ${#companions[@]}; companion_index += 2)); do
    companion="${companions[$companion_index]}"
    value="${companions[$((companion_index + 1))]}"
    case "$companion" in /*) ;; *) return 64 ;; esac
    case "$companion" in "$pidfile"|"$owner"|"$claim") return 64 ;; esac
    tmp="$companion.claim.$$"
    if ! printf '%s' "$value" > "$tmp"; then
      rm -f -- "$tmp" ${companion_tmps[@]+"${companion_tmps[@]}"} \
        2>/dev/null || true
      return 70
    fi
    companion_paths+=("$companion")
    companion_tmps+=("$tmp")
  done
  printf 'version=1\npid=%s\nkind=%s\nscope=%s\ngeneration=%s\nlease=degraded\ninterpreter=\n' \
    "$parent_pid" "$kind" "$scope_hash" "$generation" > "$owner_tmp" \
    || {
      rm -f -- ${companion_tmps[@]+"${companion_tmps[@]}"} \
        2>/dev/null || true
      return 70
    }
  printf '%s\n' "$parent_pid" > "$pid_tmp" || {
    rm -f -- "$owner_tmp" ${companion_tmps[@]+"${companion_tmps[@]}"} \
      2>/dev/null || true
    return 70
  }
  mv "$owner_tmp" "$owner" || {
    rm -f -- "$owner_tmp" "$pid_tmp" \
      ${companion_tmps[@]+"${companion_tmps[@]}"} 2>/dev/null || true
    return 70
  }
  if ! mv "$pid_tmp" "$pidfile"; then
    current_generation="$(_agmsg_process_owner_field "$owner" generation || true)"
    [ "$current_generation" != "$generation" ] || rm -f -- "$owner" 2>/dev/null || true
    rm -f -- "$pid_tmp" ${companion_tmps[@]+"${companion_tmps[@]}"} \
      2>/dev/null || true
    return 70
  fi
  for ((companion_index = 0; companion_index < ${#companion_paths[@]}; companion_index++)); do
    if ! mv "${companion_tmps[$companion_index]}" \
        "${companion_paths[$companion_index]}"; then
      internal_cleanup_observed "$pidfile" "$parent_pid" "$generation" 0 \
        ${companion_paths[@]+"${companion_paths[@]}"} >/dev/null 2>&1 || true
      rm -f -- ${companion_tmps[@]+"${companion_tmps[@]}"} \
        2>/dev/null || true
      return 70
    fi
  done
  return 0
}

if [ "${1:-}" = --internal-cleanup-observed ]; then
  [ "$#" -ge 6 ] && [ "$6" = -- ] || exit 64
  internal_cleanup_observed "$2" "$3" "$4" "$5" "${@:7}"
  exit $?
fi

if [ "${1:-}" = --internal-companions-match ]; then
  [ "$#" -ge 5 ] && [ "$5" = -- ] || exit 64
  internal_companions_match "$2" "$3" "$4" "${@:6}"
  exit $?
fi

if [ "${1:-}" = --internal-publish-degraded ]; then
  [ "$#" -ge 10 ] && [ "${10}" = -- ] || exit 64
  internal_publish_degraded "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" \
    "${@:11}"
  exit $?
fi

if [ "${1:-}" = --resolve-python ]; then
  if resolve_python; then
    printf '%s' "$AGMSG_PROCESS_PYTHON"
    exit 0
  fi
  exit 1
fi

bootstrap_mode="${AGMSG_PROCESS_BOOTSTRAP_MODE:-}"
bootstrap_generation="${AGMSG_PROCESS_OWNER_GENERATION:-}"
kind="" pidfile="" scope="" replace_owned=0 allow_missing_replace=0
legacy_needles=()
companion_pairs=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --kind) kind="${2:?--kind needs a value}"; shift 2 ;;
    --pidfile) pidfile="${2:?--pidfile needs a value}"; shift 2 ;;
    --scope) scope="${2:?--scope needs a value}"; shift 2 ;;
    --replace-owned) replace_owned=1; shift ;;
    --companion)
      [ "$#" -ge 3 ] || exit 64
      companion_pairs+=("${2:?--companion needs a path}" "${3-}")
      shift 3
      ;;
    --legacy-needle) legacy_needles+=("${2:?--legacy-needle needs a value}"); shift 2 ;;
    --) shift; break ;;
    *) echo "process-owner-launch: unknown option: $1" >&2; exit 64 ;;
  esac
done
[ -n "$kind" ] && [ -n "$pidfile" ] && [ -n "$scope" ] && [ "$#" -gt 0 ] || exit 64
[ "$replace_owned" -eq 0 ] || [ "$kind" = watch ] || exit 64
protected_owner="$(agmsg_process_owner_path "$pidfile")"
protected_claim="$(agmsg_process_lease_path "$pidfile")"
for ((companion_index = 0; companion_index < ${#companion_pairs[@]}; companion_index += 2)); do
  companion="${companion_pairs[$companion_index]}"
  case "$companion" in /*) ;; *) exit 64 ;; esac
  case "$companion" in "$pidfile"|"$protected_owner"|"$protected_claim") exit 64 ;; esac
done

target="$1"; shift
case "$target" in
  /*) target_abs="$target" ;;
  */*) target_abs="$(cd "$(dirname "$target")" 2>/dev/null && pwd -P)/$(basename "$target")" ;;
  *) target_abs="$(command -v "$target" 2>/dev/null || true)" ;;
esac
[ -n "$target_abs" ] || exit 70

# Never trust a marker supplied by the caller.  Only this launcher (degraded)
# or the Python helper after publication (leased) may create a re-entry marker.
unset AGMSG_PROCESS_BOOTSTRAP_MODE AGMSG_PROCESS_OWNER_GENERATION AGMSG_PROCESS_OWNER_FD

agmsg_process_identity_state "$kind" "$pidfile" "$scope" \
  ${legacy_needles[@]+"${legacy_needles[@]}"}
state="$AGMSG_PROCESS_STATE"
replace_pid="$AGMSG_PROCESS_PID"
replace_generation="$AGMSG_PROCESS_GENERATION"
case "$state" in
  owned)
    if [ "$replace_owned" -eq 1 ]; then
      # The helper signals the observed generation and waits on the same open
      # lease inode until the former owner releases it.  A timeout is a quiet
      # duplicate outcome; never escalate an uncooperative owner to SIGKILL.
      agmsg_process_signal_owned "$kind" "$pidfile" "$scope" TERM \
        --expected-owner "$replace_pid" "$AGMSG_PROCESS_GENERATION" \
        "$AGMSG_PROCESS_SCOPE_HASH" \
        --wait-release 5 \
        ${legacy_needles[@]+"${legacy_needles[@]}"} || {
          printf '%s\n' "$kind: could not safely replace the observed owner for $scope (pid ${replace_pid:-unknown}); successor not started" >&2
          exit 75
        }
      allow_missing_replace=1
    else
      echo "$kind: already running for $scope (pid ${replace_pid:-unknown})" >&2
      exit 75
    fi
    ;;
  degraded-live)
    if [ "$bootstrap_mode" = degraded ] && [ "$replace_pid" = "$$" ] \
        && [ -n "$bootstrap_generation" ] \
        && [ "$AGMSG_PROCESS_GENERATION" = "$bootstrap_generation" ]; then
      : # Backend recovery upgrades this process under the claim barrier below.
    else
      agmsg_process_dedup_should_suppress "$kind" "$pidfile" "$scope" \
        ${legacy_needles[@]+"${legacy_needles[@]}"} || true
      echo "$kind: already running for $scope (pid ${replace_pid:-unknown})" >&2
      exit 75
    fi
    ;;
  held-unverified|legacy-exact-live|legacy-unverified-live|unverified-live)
    agmsg_process_dedup_should_suppress "$kind" "$pidfile" "$scope" \
      ${legacy_needles[@]+"${legacy_needles[@]}"} || true
    echo "$kind: already running for $scope (pid ${replace_pid:-unknown})" >&2
    exit 75
    ;;
  stale|legacy-dead|legacy-foreign-live|degraded-dead|unverified-dead)
    if agmsg_process_cleanup_observed "$pidfile"; then
      replace_pid=""
      replace_generation=""
    fi
    ;;
esac

scope_hash="$(agmsg_process_scope_hash "$scope")"
python=""
if [ "${AGMSG_PROCESS_IDENTITY_BACKEND:-auto}" != unavailable ]; then
  if resolve_python; then python="$AGMSG_PROCESS_PYTHON"; fi
fi
if [ -n "$python" ]; then
  acquire_replace_args=(
    --replace-pid "$replace_pid"
    --replace-generation "$replace_generation"
  )
  acquire_companion_args=()
  for ((companion_index = 0; companion_index < ${#companion_pairs[@]}; companion_index += 2)); do
    acquire_companion_args+=(
      --companion "${companion_pairs[$companion_index]}"
      "${companion_pairs[$((companion_index + 1))]}"
    )
  done
  if [ "$allow_missing_replace" -eq 1 ]; then
    acquire_replace_args+=(--allow-missing-replace)
  fi
  echo "agmsg identity: lease interpreter selected: $python" >&2
  exec "$python" -B "$SCRIPT_DIR/process-owner-exec.py" acquire \
    --fd "$AGMSG_PROCESS_LEASE_FD" --pidfile "$pidfile" --kind "$kind" \
    --scope "$scope_hash" ${acquire_replace_args[@]+"${acquire_replace_args[@]}"} \
    ${acquire_companion_args[@]+"${acquire_companion_args[@]}"} \
    --interpreter "$python" \
    -- "$target_abs" "$@"
fi

tried="${AGMSG_PROCESS_PYTHON_TRIED:-0}"
echo "agmsg identity: lease unavailable; falling back to PID-only dedup and no-signal: tried $tried interpreter candidate(s)" >&2
# A verified takeover must publish under the claim lock.  If the backend
# vanished after signaling, preserve the empty slot for a later claimant.
[ "$allow_missing_replace" -eq 0 ] || exit 75

# Per-owner degrade: publish a sidecar declaring that THIS process has no
# lease.  Other leased owners remain fully verifiable via lockf.
generation="$(compat_uuidgen 2>/dev/null | tr -d '\r\n' || true)"
[ -n "$generation" ] || generation="degraded-$$-$(date +%s 2>/dev/null || echo 0)"
lockf_bin="$(_agmsg_process_lockf_bin)"
[ -n "$lockf_bin" ] || exit 75
claim="$(agmsg_process_lease_path "$pidfile")"
"$lockf_bin" -k -s -t 0 "$claim" "$SCRIPT_DIR/process-owner-launch.sh" \
  --internal-publish-degraded \
  "$pidfile" "$kind" "$scope_hash" "$generation" "$$" "$replace_pid" \
  "$replace_generation" "$allow_missing_replace" -- \
  ${companion_pairs[@]+"${companion_pairs[@]}"} || exit $?
export AGMSG_PROCESS_BOOTSTRAP_MODE=degraded
export AGMSG_PROCESS_OWNER_GENERATION="$generation"
unset AGMSG_PROCESS_OWNER_FD
cleanup_degraded_exec_failure() {
  AGMSG_PROCESS_PID="$$"
  AGMSG_PROCESS_GENERATION="$generation"
  companion_paths=()
  for ((companion_index = 0; companion_index < ${#companion_pairs[@]}; companion_index += 2)); do
    companion_paths+=("${companion_pairs[$companion_index]}")
  done
  agmsg_process_cleanup_observed "$pidfile" \
    ${companion_paths[@]+"${companion_paths[@]}"} >/dev/null 2>&1 || true
}
trap cleanup_degraded_exec_failure EXIT
exec "$target_abs" "$@"
