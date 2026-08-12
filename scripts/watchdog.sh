#!/usr/bin/env bash
set -euo pipefail

# watchdog.sh — one bounded recovery pass for one session team.
#
# Usage: watchdog.sh <s-session-team>
#
# This is deliberately not a daemon. watch.sh invokes it periodically, and the
# team lock below makes overlapping invocations a successful no-op. Bash has no
# portable monotonic clock, so cooldown/attempt/intent ages use wall time. A
# backward jump resets the affected state instead of leaving recovery wedged.

die() { echo "watchdog: $*" >&2; exit 1; }

[ "$#" -eq 1 ] || die "Usage: watchdog.sh <session-team>"
TEAM="$1"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RUN_DIR="$SKILL_DIR/run"

# Validate the caller-controlled team before it participates in any path.
# Session teams are the path-safe `s-<bare-session-id>` namespace; ordinary
# project teams are explicitly outside this watchdog's scope.
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/validate.sh"
agmsg_validate_team_name "$TEAM" || exit 1
case "$TEAM" in
  s-?*) ;;
  *) die "'$TEAM' is not a session-team name (expected s-<session-id>)" ;;
esac

mkdir -p "$RUN_DIR" 2>/dev/null || die "cannot create run directory"
TEAM_LOCK="$RUN_DIR/watchdog.$TEAM.lock"

# Hold one non-blocking advisory lock for the complete original-process pass.
# GNU/BSD hosts use flock(1); stock macOS exposes the same kernel operation via
# lockf(1). A child acquires and holds the lock while this original process does
# the work. There is no re-exec context for a caller to forge with environment
# variables or inherited descriptors. Exit 75 is reserved for contention.
LOCK_HOLDER_PID=""
LOCK_STATE_DIR="$(mktemp -d "$RUN_DIR/.watchdog-lock.XXXXXX")" \
  || die "cannot create lock state"
LOCK_READY="$LOCK_STATE_DIR/ready"
LOCK_RELEASE="$LOCK_STATE_DIR/release"

release_team_lock() {
  if [ -n "$LOCK_HOLDER_PID" ]; then
    : >"$LOCK_RELEASE" 2>/dev/null || true
    wait "$LOCK_HOLDER_PID" 2>/dev/null || true
    LOCK_HOLDER_PID=""
  fi
  rm -f -- "$LOCK_READY" "$LOCK_RELEASE" 2>/dev/null || true
  rmdir "$LOCK_STATE_DIR" 2>/dev/null || true
}
trap release_team_lock EXIT
trap 'release_team_lock; exit 129' HUP
trap 'release_team_lock; exit 130' INT
trap 'release_team_lock; exit 143' TERM

lock_holder_script='
  ready=$1
  release=$2
  parent=$3
  printf "ready\n" >"$ready" || exit 70
  while kill -0 "$parent" 2>/dev/null && [ ! -e "$release" ]; do
    sleep 0.05
  done
'
if command -v flock >/dev/null 2>&1; then
  flock -n -E 75 "$TEAM_LOCK" \
    env -u BASH_ENV -u ENV bash -c "$lock_holder_script" watchdog-lock \
      "$LOCK_READY" "$LOCK_RELEASE" "$$" &
elif command -v lockf >/dev/null 2>&1; then
  lockf -s -t 0 "$TEAM_LOCK" \
    env -u BASH_ENV -u ENV bash -c "$lock_holder_script" watchdog-lock \
      "$LOCK_READY" "$LOCK_RELEASE" "$$" &
else
  release_team_lock
  trap - EXIT HUP INT TERM
  die "flock/lockf is required"
fi
LOCK_HOLDER_PID=$!

while [ ! -f "$LOCK_READY" ] || [ -L "$LOCK_READY" ]; do
  if ! kill -0 "$LOCK_HOLDER_PID" 2>/dev/null; then
    lock_rc=0
    if wait "$LOCK_HOLDER_PID" 2>/dev/null; then
      lock_rc=0
    else
      lock_rc=$?
    fi
    LOCK_HOLDER_PID=""
    release_team_lock
    trap - EXIT HUP INT TERM
    [ "$lock_rc" -eq 75 ] && exit 0
    exit "$lock_rc"
  fi
  sleep 0.01
done

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/actas-lock.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/compat.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/identity-key.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/storage.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/type-registry.sh"

PROCESS_TIMEOUT="${AGMSG_WATCHDOG_PROCESS_TIMEOUT:-60}"
PROCESS_GRACE="${AGMSG_WATCHDOG_PROCESS_GRACE:-1}"
case "$PROCESS_TIMEOUT" in ''|*[!0-9]*) PROCESS_TIMEOUT=60 ;; esac
[ "$PROCESS_TIMEOUT" -gt 0 ] || PROCESS_TIMEOUT=60
case "$PROCESS_GRACE" in
  ''|*[!0-9.]*|.*|*.*.*|*.) PROCESS_GRACE=1 ;;
esac

PERL_BIN="$(command -v perl 2>/dev/null || true)"
PYTHON_BIN="$(command -v python3 2>/dev/null || true)"
GROUP_RUNNER=""
if [ -n "$PYTHON_BIN" ] \
    && "$PYTHON_BIN" -c 'import os; assert hasattr(os, "setsid")' >/dev/null 2>&1; then
  GROUP_RUNNER=python
elif [ -n "$PERL_BIN" ] \
    && ( "$PERL_BIN" -e 'exit 0' ) >/dev/null 2>&1; then
  GROUP_RUNNER=perl
else
  die "perl or python3 with setsid is required for process-group isolation"
fi

RUNNER_PID=""
PROCESS_OUTPUT_FILE=""
cleanup_runner() {
  if [ -n "$RUNNER_PID" ]; then
    kill "$RUNNER_PID" 2>/dev/null || true
    wait "$RUNNER_PID" 2>/dev/null || true
    RUNNER_PID=""
  fi
  [ -n "$PROCESS_OUTPUT_FILE" ] \
    && rm -f -- "$PROCESS_OUTPUT_FILE" 2>/dev/null || true
}
cleanup_all() {
  cleanup_runner
  release_team_lock
}
trap cleanup_all EXIT
trap 'cleanup_all; exit 129' HUP
trap 'cleanup_all; exit 130' INT
trap 'cleanup_all; exit 143' TERM

# Run one command in its own session/process group. The wrapper is the Bash
# watchdog: at 60s it sends TERM to the whole group, waits a grace interval,
# sends KILL to the whole group, reaps, and returns 124.
run_process_group() {
  local secs="$1" grace="$2"; shift 2
  local rc=0
  if [ "$GROUP_RUNNER" = perl ]; then
    "$PERL_BIN" -e '
      use POSIX qw(setsid);
      my $secs = shift @ARGV;
      my $grace = shift @ARGV;
      my $pid = fork();
      defined $pid or exit 127;
      if ($pid == 0) { setsid(); exec @ARGV; exit 127; }
      my $kill_group = sub {
        kill(15, -$pid);
        select(undef, undef, undef, $grace);
        kill(9, -$pid);
      };
      $SIG{ALRM} = sub { $kill_group->(); waitpid($pid, 0); exit 124; };
      $SIG{TERM} = sub { $kill_group->(); waitpid($pid, 0); exit 143; };
      $SIG{INT}  = sub { $kill_group->(); waitpid($pid, 0); exit 130; };
      alarm($secs);
      waitpid($pid, 0);
      alarm 0;
      my $status = $?;
      exit($status & 127 ? 128 + ($status & 127) : ($status >> 8));
    ' "$secs" "$grace" "$@" </dev/null &
  else
    "$PYTHON_BIN" -c '
import os
import signal
import sys
import time

secs = int(sys.argv[1])
grace = float(sys.argv[2])
argv = sys.argv[3:]
pid = os.fork()
if pid == 0:
    os.setsid()
    os.execvp(argv[0], argv)
    os._exit(127)

def kill_group(exit_code):
    try:
        os.killpg(pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    time.sleep(grace)
    try:
        os.killpg(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    try:
        os.waitpid(pid, 0)
    except ChildProcessError:
        pass
    os._exit(exit_code)

signal.signal(signal.SIGTERM, lambda _s, _f: kill_group(143))
signal.signal(signal.SIGINT, lambda _s, _f: kill_group(130))
signal.signal(signal.SIGALRM, lambda _s, _f: kill_group(124))
signal.alarm(secs)
_, status = os.waitpid(pid, 0)
signal.alarm(0)
if os.WIFSIGNALED(status):
    sys.exit(128 + os.WTERMSIG(status))
sys.exit(os.WEXITSTATUS(status))
' "$secs" "$grace" "$@" </dev/null &
  fi
  RUNNER_PID=$!
  if wait "$RUNNER_PID" 2>/dev/null; then rc=0; else rc=$?; fi
  RUNNER_PID=""
  return "$rc"
}

LAST_PROCESS_OUTPUT=""
run_bounded() {
  local rc=0
  PROCESS_OUTPUT_FILE="$(mktemp "$RUN_DIR/.watchdog-output.XXXXXX")" || return 1
  if run_process_group "$PROCESS_TIMEOUT" "$PROCESS_GRACE" "$@" \
      >"$PROCESS_OUTPUT_FILE" 2>&1; then
    rc=0
  else
    rc=$?
  fi
  LAST_PROCESS_OUTPUT="$(cat "$PROCESS_OUTPUT_FILE" 2>/dev/null || true)"
  rm -f -- "$PROCESS_OUTPUT_FILE" 2>/dev/null || true
  PROCESS_OUTPUT_FILE=""
  return "$rc"
}

atomic_write() {
  local path="$1" value="$2" tmp
  tmp="$(mktemp "$RUN_DIR/.watchdog-write.XXXXXX")" || return 1
  if ! printf '%s' "$value" >"$tmp" || ! mv -f -- "$tmp" "$path"; then
    rm -f -- "$tmp" 2>/dev/null || true
    return 1
  fi
}

safe_remove() {
  rm -f -- "$@" 2>/dev/null || true
}

record_parse() {
  local record="$1" rest
  RECORD_ID=""
  RECORD_PROJECT=""
  RECORD_TYPE=""
  case "$record" in *$'\n'*) return 1 ;; esac
  case "$record" in *$'\t'*) ;; *) return 1 ;; esac
  RECORD_ID="${record%%$'\t'*}"
  rest="${record#*$'\t'}"
  case "$rest" in *$'\t'*) ;; *) return 1 ;; esac
  RECORD_PROJECT="${rest%%$'\t'*}"
  RECORD_TYPE="${rest#*$'\t'}"
  case "$RECORD_TYPE" in *$'\t'*|'') return 1 ;; esac
  [ -n "$RECORD_PROJECT" ] || return 1
  case "$RECORD_ID" in
    pid:[0-9]*) [ "${RECORD_ID#pid:}" -gt 0 ] 2>/dev/null || return 1 ;;
    *) return 1 ;;
  esac
  agmsg_is_known_type "$RECORD_TYPE" || return 1
  [ "$(agmsg_type_get "$RECORD_TYPE" headless no)" = yes ] || return 1
}

# Return success when the live placement is dead/unverifiable. This is the
# read-only mirror of despawn's meta-absent PID-reuse guard.
placement_dead() {
  local pid="$1" type="$2" name="$3"
  local meta meta_pid args identity_key arg expect_identity=0
  local bridge_token=0 identity_token=0
  local -a argv=()
  meta="$RUN_DIR/$type-bridge.$TEAM.$name.meta"
  meta_pid=""
  [ -f "$meta" ] \
    && meta_pid="$(sed -n 's/^pid=//p' "$meta" 2>/dev/null | head -1 || true)"
  if [ -n "$meta_pid" ] && [ "$meta_pid" != "$pid" ]; then
    return 0
  fi
  _agmsg_pid_alive "$pid" || return 0
  [ -n "$meta_pid" ] && return 1

  identity_key="$(agmsg_identity_key "$TEAM" "$name")"
  args="$(compat_get_cmdline "$pid" 2>/dev/null || true)"
  read -r -a argv <<<"$args" || true
  for arg in "${argv[@]}"; do
    if [ "$expect_identity" -eq 1 ]; then
      [ "$arg" = "$identity_key" ] && identity_token=1
      expect_identity=0
      continue
    fi
    [ "$arg" = "--identity-key" ] && expect_identity=1
    case "$arg" in
      "$type-bridge"|*/"$type-bridge"|"$type-bridge".js|*/"$type-bridge".js|\
      "$type-bridge".sh|*/"$type-bridge".sh)
        bridge_token=1 ;;
    esac
  done
  [ "$bridge_token" -eq 1 ] && [ "$identity_token" -eq 1 ] && return 1
  return 0
}

intent_read() {
  local path="$1" now="$2" owner_line created_line record extra="" age
  local owner_tag owner_pid owner_epoch owner_nonce owner_extra
  INTENT_OWNER=""
  INTENT_CREATED=""
  INTENT_RECORD=""
  [ -f "$path" ] && [ ! -L "$path" ] && [ -O "$path" ] || return 1
  exec 8<"$path" 2>/dev/null || return 1
  IFS= read -r owner_line <&8 || { exec 8<&-; return 1; }
  IFS= read -r created_line <&8 || { exec 8<&-; return 1; }
  IFS= read -r record <&8 || {
    [ -n "$record" ] || { exec 8<&-; return 1; }
  }
  if IFS= read -r extra <&8; then
    exec 8<&-
    return 1
  fi
  exec 8<&-
  case "$owner_line" in owner=?*) INTENT_OWNER="${owner_line#owner=}" ;; *) return 1 ;; esac
  case "$created_line" in
    created=[0-9]*) INTENT_CREATED="${created_line#created=}" ;;
    *) return 1 ;;
  esac
  case "$INTENT_CREATED" in ''|*[!0-9]*) return 1 ;; esac
  IFS=: read -r owner_tag owner_pid owner_epoch owner_nonce owner_extra \
    <<<"$INTENT_OWNER"
  [ "$owner_tag" = watchdog ] && [ -z "$owner_extra" ] || return 1
  case "$owner_pid:$owner_epoch:$owner_nonce" in
    *[!0-9:]*) return 1 ;;
  esac
  [ -n "$owner_pid" ] && [ -n "$owner_epoch" ] && [ -n "$owner_nonce" ] || return 1
  [ "$owner_epoch" = "$INTENT_CREATED" ] || return 1
  [ "$now" -ge "$INTENT_CREATED" ] || return 1
  age=$((now - INTENT_CREATED))
  [ "$age" -le 600 ] || return 1
  record_parse "$record" || return 1
  INTENT_RECORD="$record"
}

intent_write() {
  local path="$1" owner="$2" created="$3" record="$4"
  atomic_write "$path" "$(printf 'owner=%s\ncreated=%s\n%s\n' \
    "$owner" "$created" "$record")"
}

intent_is_owned() {
  local path="$1" owner="$2" record="$3" now="$4"
  intent_read "$path" "$now" \
    && [ "$INTENT_OWNER" = "$owner" ] \
    && [ "$INTENT_RECORD" = "$record" ]
}

intent_remove_owned() {
  local path="$1" owner="$2" record="$3" now="$4"
  intent_is_owned "$path" "$owner" "$record" "$now" && safe_remove "$path"
  return 0
}

WATCHDOG_STAMP_MAX=256
# Mirror watch.sh's SessionEnd fence rule: only an owned, readable, bounded,
# single-line stamp whose mtime is no more than 600 seconds old is affirmative.
# Missing, expired, malformed, symlinked, or otherwise ambiguous markers fail
# open so a stale tombstone cannot suppress recovery indefinitely.
watchdog_tombstone_fresh() {
  local path="$1" now="$2" stamp extra mtime age
  local mtime_status=0 read_status extra_status valid=1
  local -a probe_status=()
  [ -f "$path" ] || return 1
  [ ! -L "$path" ] || return 1
  [ -O "$path" ] || return 1
  [ -r "$path" ] || return 1

  dd if="$path" bs=1 count=$((WATCHDOG_STAMP_MAX + 1)) 2>/dev/null \
    | od -An -tx1 2>/dev/null \
    | grep -Eq '(^|[[:space:]])00([[:space:]]|$)'
  probe_status=( "${PIPESTATUS[@]}" )
  [ "${probe_status[0]:-1}" -eq 0 ] || return 1
  [ "${probe_status[1]:-1}" -eq 0 ] || return 1
  [ "${probe_status[2]:-1}" -eq 1 ] || return 1

  exec 9<"$path" 2>/dev/null || return 1
  IFS= read -r -n $((WATCHDOG_STAMP_MAX + 1)) stamp <&9
  read_status=$?
  if [ "${#stamp}" -eq 0 ] || [ "${#stamp}" -gt "$WATCHDOG_STAMP_MAX" ]; then
    valid=0
  fi
  if [ "$valid" -eq 1 ]; then
    IFS= read -r -n 1 extra <&9
    extra_status=$?
    [ "$extra_status" -eq 1 ] || valid=0
  fi
  exec 9<&-
  [ "$valid" -eq 1 ] || return 1
  case "$read_status" in
    0) ;;
    1) [ -n "$stamp" ] || return 1 ;;
    *) return 1 ;;
  esac
  case "$stamp" in *[![:graph:]]*) return 1 ;; esac

  mtime="$(compat_file_mtime "$path" 2>/dev/null)" || mtime_status=$?
  [ "$mtime_status" -eq 0 ] || return 1
  case "$mtime" in ''|*[!0-9]*) return 1 ;; esac
  [ "$now" -ge "$mtime" ] || return 1
  age=$((now - mtime))
  [ "$age" -le 600 ]
}

load_attempts() {
  local path="$1" now="$2" epoch delta text="" reset=0
  ATTEMPT_COUNT=0
  ATTEMPT_TEXT=""
  if [ -e "$path" ] || [ -L "$path" ]; then
    if [ ! -f "$path" ] || [ -L "$path" ] || [ ! -O "$path" ]; then
      safe_remove "$path"
      return 0
    fi
    while IFS= read -r epoch || [ -n "$epoch" ]; do
      case "$epoch" in ''|*[!0-9]*) reset=1; break ;; esac
      if [ "$epoch" -gt "$now" ]; then
        reset=1
        break
      fi
      delta=$((now - epoch))
      if [ "$delta" -le 3600 ]; then
        text="${text}${epoch}"$'\n'
        ATTEMPT_COUNT=$((ATTEMPT_COUNT + 1))
      fi
    done <"$path"
  fi
  if [ "$reset" -eq 1 ]; then
    ATTEMPT_COUNT=0
    text=""
  fi
  ATTEMPT_TEXT="$text"
  if [ -n "$text" ]; then
    atomic_write "$path" "$text" || return 1
  else
    safe_remove "$path"
  fi
}

state_clear_recovered() {
  safe_remove "$1.last" "$1.attempts" "$1.capped"
}

cooldown_active() {
  local path="$1" now="$2" last
  [ -f "$path" ] && [ ! -L "$path" ] && [ -O "$path" ] || return 1
  last="$(cat "$path" 2>/dev/null || true)"
  case "$last" in ''|*[!0-9]*) safe_remove "$path"; return 1 ;; esac
  if [ "$last" -gt "$now" ]; then
    safe_remove "$path"
    return 2
  fi
  [ $((now - last)) -lt 60 ]
}

registered_roster() {
  local config="$SKILL_DIR/teams/$TEAM/config.json" cfg_sql team_sql
  [ -f "$config" ] || return 0
  cfg_sql="$(agmsg_sql_readfile_path "$config")"
  team_sql="$(printf '%s' "$TEAM" | sed "s/'/''/g")"
  agmsg_sqlite_mem "
    WITH raw(json) AS (SELECT CAST(readfile('$cfg_sql') AS TEXT)),
    cfg(json) AS (
      SELECT CASE
        WHEN json_valid(json) AND json_extract(json, '\$.name') = '$team_sql'
        THEN json
      END
      FROM raw
    )
    SELECT key
    FROM cfg, json_each(json_extract(cfg.json, '\$.agents'))
    ORDER BY key;
  " 2>/dev/null || true
}

name_is_registered() {
  registered_roster | grep -Fxq -- "$1"
}

NOW=""
if ! NOW="$(date +%s 2>/dev/null)"; then
  exit 0
fi
case "$NOW" in ''|*[!0-9]*) exit 0 ;; esac
TOMBSTONE="$RUN_DIR/watchdog.$TEAM.tombstone"
ABORT_PASS=0
ROSTER="$(registered_roster)"

# An intent is never an authority to resurrect an unregistered name. Prune only
# this exact team's intent namespace; records and intents belonging to other
# teams are not enumerated.
for ORPHAN_INTENT in "$RUN_DIR/watchdog.$TEAM."*.intent; do
  [ -e "$ORPHAN_INTENT" ] || [ -L "$ORPHAN_INTENT" ] || continue
  ORPHAN_NAME="${ORPHAN_INTENT#"$RUN_DIR/watchdog.$TEAM."}"
  ORPHAN_NAME="${ORPHAN_NAME%.intent}"
  if ! printf '%s\n' "$ROSTER" | grep -Fxq "$ORPHAN_NAME"; then
    safe_remove "$ORPHAN_INTENT"
  fi
done

while IFS= read -r NAME; do
  [ -n "$NAME" ] || continue
  agmsg_validate_agent_name "$NAME" >/dev/null 2>&1 || continue
  name_is_registered "$NAME" || continue

  BASE="$RUN_DIR/watchdog.$TEAM.$NAME"
  INTENT="$BASE.intent"
  SPAWN_REC="$(agmsg_spawn_path "$TEAM" "$NAME")"
  RECORD=""
  FROM_INTENT=0

  if [ -f "$SPAWN_REC" ] && [ ! -L "$SPAWN_REC" ]; then
    RECORD="$(cat "$SPAWN_REC" 2>/dev/null || true)"
    if ! record_parse "$RECORD"; then
      continue
    fi
  elif [ -e "$SPAWN_REC" ] || [ -L "$SPAWN_REC" ]; then
    continue
  elif intent_read "$INTENT" "$NOW"; then
    # Lead binding: an absent placement can only resume through a fresh,
    # well-formed owner-stamped intent, and this loop itself proves NAME is
    # still in this exact team's registered roster.
    RECORD="$INTENT_RECORD"
    FROM_INTENT=1
    record_parse "$RECORD" || { safe_remove "$INTENT"; continue; }
  else
    safe_remove "$INTENT"
    state_clear_recovered "$BASE"
    continue
  fi

  PID="${RECORD_ID#pid:}"
  PROJECT="$RECORD_PROJECT"
  TYPE="$RECORD_TYPE"

  # A fresh valid SessionEnd stamp is an intentional-stop fence. Pre-check
  # avoids destructive work; the mandatory post-spawn recheck below closes the
  # final check-to-use race with both SessionEnd and plain despawn.
  if watchdog_tombstone_fresh "$TOMBSTONE" "$NOW"; then
    safe_remove "$INTENT"
    continue
  fi

  if [ "$FROM_INTENT" -eq 0 ] && ! placement_dead "$PID" "$TYPE" "$NAME"; then
    safe_remove "$INTENT"
    state_clear_recovered "$BASE"
    continue
  fi

  load_attempts "$BASE.attempts" "$NOW" || continue
  if [ "$ATTEMPT_COUNT" -ge 3 ]; then
    # Stable one-time transition notification (stdout, never agmsg send):
    #   watchdog: crashloop capped <name> (attempts>=3/hour)
    capped_value=""
    if [ -f "$BASE.capped" ] && [ ! -L "$BASE.capped" ] \
        && [ -O "$BASE.capped" ]; then
      capped_value="$(cat "$BASE.capped" 2>/dev/null || true)"
    fi
    if [ "$capped_value" != capped ]; then
      atomic_write "$BASE.capped" "capped"$'\n' || continue
      printf 'watchdog: crashloop capped %s (attempts>=3/hour)\n' "$NAME"
    fi
    continue
  fi
  safe_remove "$BASE.capped"

  if cooldown_active "$BASE.last" "$NOW"; then
    continue
  else
    cooldown_rc=$?
    if [ "$cooldown_rc" -eq 2 ]; then
      # Wall clock moved backward relative to persisted state. Reset every
      # rate-limit artifact; a negative delta must never suppress indefinitely.
      state_clear_recovered "$BASE"
      ATTEMPT_COUNT=0
      ATTEMPT_TEXT=""
    fi
  fi

  OWNER="watchdog:$$:$NOW:$RANDOM"
  intent_write "$INTENT" "$OWNER" "$NOW" "$RECORD" || continue
  if ! name_is_registered "$NAME"; then
    intent_remove_owned "$INTENT" "$OWNER" "$RECORD" "$NOW"
    continue
  fi

  if [ "$FROM_INTENT" -eq 0 ]; then
    # A plain despawn invalidates this reservation. The scoped token only tells
    # despawn that this exact owner is its caller; reset.sh and every other
    # teardown behavior remain unchanged.
    despawn_rc=0
    if run_bounded env AGMSG_WATCHDOG_INTENT_TOKEN="$OWNER" \
        "$SCRIPT_DIR/despawn.sh" "$TEAM" claude "$NAME" --force \
        --expect-record "$RECORD"; then
      despawn_rc=0
    else
      despawn_rc=$?
    fi
    if [ "$despawn_rc" -eq 124 ]; then
      printf 'watchdog: despawn incomplete %s/%s (status=%s)\n' \
        "$TEAM" "$NAME" "$despawn_rc"
      ABORT_PASS=1
      break
    fi
    if [ "$despawn_rc" -ne 0 ]; then
      printf 'watchdog: despawn incomplete %s/%s (status=%s)\n' \
        "$TEAM" "$NAME" "$despawn_rc"
      if [ "$despawn_rc" -eq 4 ]; then
        ATTEMPT_TEXT="${ATTEMPT_TEXT}${NOW}"$'\n'
        atomic_write "$BASE.attempts" "$ATTEMPT_TEXT" || continue
        atomic_write "$BASE.last" "$NOW"$'\n' || continue
      fi
      continue
    fi
    if printf '%s\n' "$LAST_PROCESS_OUTPUT" \
        | grep -q 'status=skipped .*reason=record-changed'; then
      intent_remove_owned "$INTENT" "$OWNER" "$RECORD" "$NOW"
      continue
    fi

    # Successful despawn removes the exact record. A replacement/no-op record
    # is never overwritten by recovery.
    if [ -e "$SPAWN_REC" ] || [ -L "$SPAWN_REC" ]; then
      intent_remove_owned "$INTENT" "$OWNER" "$RECORD" "$NOW"
      continue
    fi
  fi
  if ! intent_is_owned "$INTENT" "$OWNER" "$RECORD" "$NOW" \
      || watchdog_tombstone_fresh "$TOMBSTONE" "$NOW"; then
    intent_remove_owned "$INTENT" "$OWNER" "$RECORD" "$NOW"
    continue
  fi

  ATTEMPT_TEXT="${ATTEMPT_TEXT}${NOW}"$'\n'
  atomic_write "$BASE.attempts" "$ATTEMPT_TEXT" || {
    intent_remove_owned "$INTENT" "$OWNER" "$RECORD" "$NOW"
    continue
  }
  atomic_write "$BASE.last" "$NOW"$'\n' || {
    intent_remove_owned "$INTENT" "$OWNER" "$RECORD" "$NOW"
    continue
  }

  spawn_rc=0
  if run_bounded "$SCRIPT_DIR/spawn.sh" "$TYPE" "$NAME" \
      --team "$TEAM" --project "$PROJECT" --headless; then
    spawn_rc=0
  else
    spawn_rc=$?
  fi
  if [ "$spawn_rc" -eq 124 ]; then
    ABORT_PASS=1
    break
  fi
  if [ "$spawn_rc" -ne 0 ]; then
    # Keep the anchor. If spawn re-registered the name, a later pass can retry;
    # if it did not, the roster gate removes the intent without resurrection.
    continue
  fi

  NEW_RECORD="$(cat "$SPAWN_REC" 2>/dev/null || true)"
  if ! record_parse "$NEW_RECORD" \
      || [ "$RECORD_PROJECT" != "$PROJECT" ] \
      || [ "$RECORD_TYPE" != "$TYPE" ]; then
    continue
  fi

  POST_NOW="$NOW"
  post_now_candidate=""
  post_now_status=0
  post_now_candidate="$(date +%s 2>/dev/null)" || post_now_status=$?
  if [ "$post_now_status" -eq 0 ]; then
    case "$post_now_candidate" in
      ''|*[!0-9]*) ;;
      *) POST_NOW="$post_now_candidate" ;;
    esac
  fi

  # Plain despawn can invalidate the reservation, and SessionEnd can publish a
  # fresh tombstone, while spawn is running. Recheck only after the exact new
  # record is verified. If fenced, compare-and-act against that captured record
  # rather than any later reread. Compensation is bounded best-effort; an
  # uncompensated worker is reaped by SessionEnd teardown / SessionStart orphan
  # GC.
  if ! intent_is_owned "$INTENT" "$OWNER" "$RECORD" "$POST_NOW" \
      || watchdog_tombstone_fresh "$TOMBSTONE" "$POST_NOW"; then
    compensation_rc=0
    if run_bounded env AGMSG_WATCHDOG_INTENT_TOKEN="$OWNER" \
        "$SCRIPT_DIR/despawn.sh" "$TEAM" claude "$NAME" --force \
        --expect-record "$NEW_RECORD"; then
      compensation_rc=0
    else
      compensation_rc=$?
    fi
    if [ "$compensation_rc" -ne 0 ] \
        || printf '%s\n' "$LAST_PROCESS_OUTPUT" \
          | grep -q 'status=skipped .*reason=record-changed'; then
      # Stable incomplete-compensation notification (stdout, never agmsg send):
      #   watchdog: compensation incomplete <team>/<name>
      printf 'watchdog: compensation incomplete %s/%s\n' "$TEAM" "$NAME"
    fi
    intent_remove_owned "$INTENT" "$OWNER" "$RECORD" "$POST_NOW"
    if [ "$compensation_rc" -eq 124 ]; then
      ABORT_PASS=1
      break
    fi
    continue
  fi
  intent_remove_owned "$INTENT" "$OWNER" "$RECORD" "$NOW"
  printf 'watchdog: respawned %s (reason=dead)\n' "$NAME"
done <<<"$ROSTER"

[ "$ABORT_PASS" -eq 0 ] || exit 0
exit 0
