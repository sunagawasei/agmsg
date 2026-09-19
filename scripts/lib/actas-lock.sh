#!/usr/bin/env bash
# actas-lock.sh — per-(team, agent) exclusivity locks.
#
# Background: agmsg supports a project being registered with multiple agent
# identities of the same type (claude-code/codex/...). Without ownership
# tracking, every concurrent CC session in that project would subscribe to
# every registered identity's messages — duplicate delivery, confused mark-
# read semantics, and the `actas` "exclusive role" model breaking down.
#
# This file implements a small filesystem-based ownership protocol:
#
#   Lock file: $SKILL_DIR/run/actas.<team>__<agent>.session
#   Content  : one line — the owner session_id.
#
# A session_id is alive iff some $SKILL_DIR/run/cc-instance.<pid> file
# currently contains it AND that PID is alive. The same primitive used by
# session-start.sh's orphan-watcher cleanup. Stale locks (owner is no
# longer alive) are reclaimable.
#
# Atomic claim is implemented via `ln` of a per-call tmp file. POSIX
# guarantees the link target either appears or doesn't, even under
# concurrent claim attempts.
#
# Required caller-set variable:
#   SKILL_DIR — agmsg skill root.

: "${SKILL_DIR:?actas-lock.sh requires SKILL_DIR}"

# shellcheck disable=SC1091
. "$SKILL_DIR/scripts/lib/name-encode.sh"

# Owner tokens are per-process instance ids (see instance-id.sh), not bare
# session_ids — this is what keeps parallel --continue/--resume sessions that
# share a session_id from each appearing to own the other's locks (#93). The
# liveness check (actas_lock_sid_alive) delegates to agmsg_instance_alive.
# shellcheck disable=SC1091
. "$SKILL_DIR/scripts/lib/instance-id.sh"

_actas_lock_dir() { printf '%s/run' "$SKILL_DIR"; }

# Resolve a bounded wait knob without exposing malformed input to shell
# arithmetic or sleep. The five arguments are:
#
#   raw default minimum maximum kind
#
# kind is "decimal" for a polling interval or "integer" for a count. Bounds
# are inclusive and caller-owned, which lets despawn reuse this unchanged for
# both its kill-poll interval and maximum poll count. Defaults and bounds are
# trusted constants; an unset or malformed raw value always prints default.
agmsg_wait_knob_resolve() {
  local raw="${1-}" default="${2-}" minimum="${3-}" maximum="${4-}" kind="${5-}"

  if LC_ALL=C awk \
      -v value="$raw" -v minimum="$minimum" -v maximum="$maximum" -v kind="$kind" '
        BEGIN {
          if (kind == "decimal")
            valid = value ~ /^[0-9]+([.][0-9]+)?$/
          else if (kind == "integer")
            valid = value ~ /^[0-9]+$/
          else
            valid = 0

          if (!valid || value + 0 < minimum + 0 || value + 0 > maximum + 0)
            exit 1
        }
      ' </dev/null
  then
    # Canonicalize integer counts so a later arithmetic context cannot treat a
    # caller's leading zero as an octal prefix. Decimal sleep values are
    # returned byte-for-byte after validation.
    if [ "$kind" = "integer" ]; then
      while [ "$raw" != "0" ] && [ "${raw#0}" != "$raw" ]; do
        raw="${raw#0}"
      done
    fi
    printf '%s\n' "$raw"
  else
    printf '%s\n' "$default"
  fi
}

# Portable integer wall-clock sample used by bounded polling. A command that
# prints digits and then exits non-zero is a failed sample, not valid time.
_agmsg_wait_epoch_seconds() {
  local now
  now="$(date +%s 2>/dev/null)" || return 1
  case "$now" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$now"
}

# Bridge _agmsg_id_key_for's 3-way rc (0 resolved / 1 no id / 2 undetermined)
# into what a path function does next, in ONE place so the distinction is not
# re-decided three times. Prints the key and returns 0 when one resolved.
# Returns 1 with nothing printed when there is genuinely no id -- the caller
# must use <legacy> outright, its existing contract. Returns 2, with a
# reason on stderr, when resolution could not even be attempted -- the
# caller MUST NOT fall back (an id-keyed lock could already exist on disk;
# see the rc-2 note on _agmsg_id_key_for above) (#1241 review).
_agmsg_id_key_or_legacy() {   # <team> <agent>
  local key krc=0
  key="$(_agmsg_id_key_for "$1" "$2")" || krc=$?
  case "$krc" in
    0) printf '%s\n' "$key"; return 0 ;;
    1) return 1 ;;
    *) printf 'agmsg: ERROR: cannot tell whether %s/%s has an id-keyed lock (SKILL_DIR unresolved) -- refusing rather than risk missing one and creating a second lock at the legacy path\n' "$1" "$2" >&2
       return 2 ;;
  esac
}

# _agmsg_id_key_or_legacy's rc-2 refusal (above) is one level too deep to be
# the FIRST thing any of the three path functions below does: each builds
# <legacy> before calling it, and that build calls _actas_lock_dir, which
# reads SKILL_DIR bare. Under `set -u` -- every real entry point's shell --
# an unset SKILL_DIR aborts right there with "unbound variable", never
# reaching the rc-2 refusal at all (#1241 review, round 2: the first pass at
# this fix protected the resolver but not its own callers' earlier reads).
# This is the guard that actually runs first, called before any of the
# three touches SKILL_DIR in any way.
_agmsg_lock_paths_require_skill_dir() {   # <caller-name, for the message>
  [ -n "${SKILL_DIR:-}" ] && return 0
  printf 'agmsg: ERROR: %s: SKILL_DIR is not set -- refusing rather than guess a path\n' "$1" >&2
  return 1
}

# --- process-lifetime memoization of actas_lock_path's PRIMITIVES ------------
#
# team_id (config.json), member_id (the roster journal) and the two
# name-encodings are each a pure function of on-disk config that cannot
# change for the life of a long-running poller (watch.sh) without an
# external event this process has no way of observing anyway -- so
# recomputing them every poll cycle only forks sqlite3/tr/sed for the same
# answer every time. What CAN change on every call -- whether a lock file
# already exists under the id-keyed or legacy candidate path -- is NOT
# cached here: _actas_lock_path_cached still asks _agmsg_id_or_legacy_path
# fresh every time, exactly like actas_lock_path itself, so the #1023
# double-lock avoidance keeps seeing live filesystem state.
#
# Same shape as role-session.sh's _agmsg_role_session_path_into (#466):
# parallel arrays (bash 3.2 has no associative arrays), set in the CALLER's
# shell rather than via $(...) (a command-substitution write is lost with
# the subshell it runs in), capped growth.
_AGMSG_ALP_KEYS=()
_AGMSG_ALP_ENC_T=()
_AGMSG_ALP_ENC_A=()
_AGMSG_ALP_IDKEY=()
_AGMSG_ALP_IDKEY_RC=()
_AGMSG_ALP_MAX=64

# Sets _AGMSG_ALP_ENC_TEAM / _AGMSG_ALP_ENC_AGENT / _AGMSG_ALP_ID_KEY /
# _AGMSG_ALP_ID_KEY_RC in the CALLER's shell.
_actas_lock_primitives_into() {
  local team="$1" agent="$2" cachekey i n
  cachekey="${SKILL_DIR:-}"$'\x1f'"${team}"$'\x1f'"${agent}"
  n=${#_AGMSG_ALP_KEYS[@]}
  for ((i = 0; i < n; i++)); do
    if [ "${_AGMSG_ALP_KEYS[$i]}" = "$cachekey" ]; then
      _AGMSG_ALP_ENC_TEAM="${_AGMSG_ALP_ENC_T[$i]}"
      _AGMSG_ALP_ENC_AGENT="${_AGMSG_ALP_ENC_A[$i]}"
      _AGMSG_ALP_ID_KEY="${_AGMSG_ALP_IDKEY[$i]}"
      _AGMSG_ALP_ID_KEY_RC="${_AGMSG_ALP_IDKEY_RC[$i]}"
      return 0
    fi
  done
  _AGMSG_ALP_ENC_TEAM="$(_actas_lock_encode "$team")"
  _AGMSG_ALP_ENC_AGENT="$(_actas_lock_encode "$agent")"
  _AGMSG_ALP_ID_KEY_RC=0
  _AGMSG_ALP_ID_KEY="$(_agmsg_id_key_or_legacy "$team" "$agent")" || _AGMSG_ALP_ID_KEY_RC=$?
  # Cache a SUCCESSFUL resolution only (review, #1329 round 2). rc 1 ("no id")
  # and rc 2 ("could not even try") both cover a config.json or roster read
  # that did not go through -- which can be transient (the file mid-rewrite,
  # a momentary permission issue) as easily as a genuine decided absence, and
  # this function cannot tell the two apart. Caching either would make a
  # watcher that warmed at the wrong instant repeat the same failure for the
  # rest of its life even after the read would plainly succeed again; retrying
  # every call until one actually succeeds is what makes that self-correcting.
  if [ "$_AGMSG_ALP_ID_KEY_RC" -eq 0 ] && [ "$n" -lt "$_AGMSG_ALP_MAX" ]; then
    _AGMSG_ALP_KEYS[$n]="$cachekey"
    _AGMSG_ALP_ENC_T[$n]="$_AGMSG_ALP_ENC_TEAM"
    _AGMSG_ALP_ENC_A[$n]="$_AGMSG_ALP_ENC_AGENT"
    _AGMSG_ALP_IDKEY[$n]="$_AGMSG_ALP_ID_KEY"
    _AGMSG_ALP_IDKEY_RC[$n]="$_AGMSG_ALP_ID_KEY_RC"
  fi
  return 0
}

# Cached counterpart of actas_lock_path below: identical resolution rule,
# using the memoized primitives above in place of recomputing them on every
# call. Callers that need a fresh read on every call (most of the tree —
# spawn/despawn/actas-claim/etc., each a one-shot process where memoization
# buys nothing) keep using actas_lock_path unchanged; this is for a caller
# that resolves the SAME pairs over and over in one long-lived process.
actas_lock_path_cached() {
  local team="$1" agent="$2" legacy
  _agmsg_lock_paths_require_skill_dir actas_lock_path_cached || return 1
  _actas_lock_primitives_into "$team" "$agent"
  legacy="$(printf '%s/actas.%s__%s.session' "$(_actas_lock_dir)" "$_AGMSG_ALP_ENC_TEAM" "$_AGMSG_ALP_ENC_AGENT")"
  case "$_AGMSG_ALP_ID_KEY_RC" in
    0) _agmsg_id_or_legacy_path "$(printf '%s/actas.%s.session' "$(_actas_lock_dir)" "$_AGMSG_ALP_ID_KEY")" "$legacy" ;;
    1) printf '%s\n' "$legacy" ;;
    *) return 1 ;;
  esac
}

# Compute the lock file path for (team, agent). #1023: id-keyed when both ids
# resolve and a file already exists at either candidate path, or nothing does
# yet; the legacy name-keyed path otherwise -- see _agmsg_id_key_for above.
# Fails (empty stdout, rc 1) if BOTH candidates exist for the pair, or if id
# resolution itself was undetermined rather than genuinely absent -- see
# _agmsg_id_or_legacy_path and _agmsg_id_key_or_legacy. Every caller must
# check this.
actas_lock_path() {
  local team="$1" agent="$2"
  local t a; t="$(_actas_lock_encode "$team")"; a="$(_actas_lock_encode "$agent")"
  printf '%s/actas.%s__%s.session' "$(_actas_lock_dir)" "$t" "$a"
}

# Readiness sentinel path for (team, agent). watch.sh creates this when an
# exclusive (actas) watcher attaches and removes it on exit, so the file is
# present iff a live watcher is currently receiving for that role. `spawn`
# uses it to block until a freshly launched agent is actually listening,
# instead of racing the agent's first push. Same encoding as the lock path so
# both scripts agree without env plumbing. See #108.
agmsg_ready_path() {
  local team="$1" agent="$2"
  local t a; t="$(_actas_lock_encode "$team")"; a="$(_actas_lock_encode "$agent")"
  printf '%s/ready.%s__%s' "$(_actas_lock_dir)" "$t" "$a"
}

# Placement record path for a spawned (team, agent). `spawn` writes the
# member's tmux target id + project + type here at launch time so that
# `despawn --force` can tear the member down (kill its pane/window, drop its
# registration) even when the member's own watcher is dead and can't respond
# to a ctrl:despawn. Same encoding as the lock path. See #109.
agmsg_spawn_path() {
  local team="$1" agent="$2"
  local t a; t="$(_actas_lock_encode "$team")"; a="$(_actas_lock_encode "$agent")"
  printf '%s/spawn.%s__%s' "$(_actas_lock_dir)" "$t" "$a"
}

# Placement lock path for a spawned (team, agent). Distinct prefix from the spawn
# record so the session-team TTL GC's `spawn.<team>__*` glob never touches it.
_agmsg_placement_lock_path() {
  local t a; t="$(_actas_lock_encode "$1")"; a="$(_actas_lock_encode "$2")"
  printf '%s/placement.%s__%s.lock' "$(_actas_lock_dir)" "$t" "$a"
}

# Placement lock — serializes the spawn-record WRITE (spawn.sh launch_headless)
# against the teardown's record compare-and-REMOVE (despawn.sh --force) for one
# (team, agent). Without it a fast lazy-respawn could write a fresh record in the
# window between a detached teardown's --expect-record compare and its rm, letting
# the teardown delete the fresh record and drop the new worker's registration.
# mkdir is atomic on POSIX. A holder that crashes mid-section leaves the dir; it
# is reclaimed after 2 minutes (a real spawn/teardown is sub-second to a few
# seconds). Callers fail-open on acquire timeout — despawn's --expect-record
# compare is the backstop that still refuses to act on a changed record.
agmsg_placement_lock_acquire() {
  local team="$1" agent="$2" timeout="${3:-10}" lock stale_match=""
  local poll_interval now="" started="" last="" elapsed=0
  case "$timeout" in ''|*[!0-9]*) return 1 ;; esac
  poll_interval="$(agmsg_wait_knob_resolve \
    "${AGMSG_PLACEMENT_LOCK_POLL_INTERVAL-}" 1 0.01 60 decimal)"
  lock="$(_agmsg_placement_lock_path "$team" "$agent")"
  mkdir -p "$(_actas_lock_dir)" 2>/dev/null || true
  while :; do
    stale_match=""
    if [ -d "$lock" ]; then
      stale_match="$(find "$lock" -maxdepth 0 -mmin +2 -print -quit 2>/dev/null || true)"
    fi
    if [ -n "$stale_match" ]; then
      rmdir "$lock" 2>/dev/null || true
    fi
    mkdir "$lock" 2>/dev/null && return 0

    # Start the clock only after the first failed atomic acquisition, so an
    # uncontended early success does not depend on date(1). Timeout remains
    # seconds even when the independent polling interval is fractional.
    now="$(_agmsg_wait_epoch_seconds)" || return 1
    if [ -z "$started" ]; then
      started="$now"
      last="$now"
      elapsed=0
    elif [ "$now" -lt "$last" ]; then
      # Wall-clock time can move backward. Reset the local baseline instead of
      # retaining a future deadline that could wedge this acquisition.
      started="$now"
      last="$now"
      elapsed=0
    else
      last="$now"
      elapsed=$((now - started))
    fi
    [ "$elapsed" -ge "$timeout" ] && return 1
    sleep "$poll_interval"
  done
}

agmsg_placement_lock_release() {
  local lock; lock="$(_agmsg_placement_lock_path "$1" "$2")"
  rmdir "$lock" 2>/dev/null || true
}

# Read the owner session_id of a lock file. Empty if no lock or unreadable.
actas_lock_owner() {
  local lock; lock="$(actas_lock_path "$1" "$2")"
  [ -f "$lock" ] || { printf ''; return 0; }
  head -1 "$lock" 2>/dev/null
}

# Cached counterpart of actas_lock_read, via actas_lock_path_cached. See that
# function's comment for what is and is not memoized.
actas_lock_read_cached() {   # <team> <agent>
  local p
  p="$(actas_lock_path_cached "$1" "$2")" || { printf 'ambiguous\t\n'; return 0; }
  _actas_lock_read_path "$p"
}

# Return 0 if the given owner token is alive. The token is a per-process
# instance id (composite "<sid>.<pid>" or bare "<sid>" fallback); liveness is
# delegated to agmsg_instance_alive (composite → kill -0 the embedded pid; bare
# → live cc-instance.<pid> scan, with upgrade compat). Kept as a thin wrapper
# so existing callers (watch.sh subscription, session-start GC) need no change.
# Empty token → not alive. A false result is NOT proof of death; reclaim uses
# actas_lock_owner_reclaimable.
actas_lock_sid_alive() {
  agmsg_instance_alive "$1"
}

# Return 0 only when owner death is positively proved and the lock may be
# deleted or stolen. Bare UUIDs never authorize reclaim: missing cc-instance
# is false-dead, the same accident as #3/#22. Composite tokens reclaim only
# when the embedded pid is gone. Empty owner (corrupt lock) is reclaimable.
actas_lock_owner_reclaimable() {
  local token="${1:-}" pid
  [ -n "$token" ] || return 0
  if agmsg_instance_is_composite "$token"; then
    pid="${token##*.}"
    _agmsg_pid_alive "$pid" && return 1
    return 0
  fi
  return 1
}

# Internal: attempt one atomic claim. Echoes "ok" on success, "held:<sid>"
# when another sid currently owns it, or "stale" when the existing lock's
# owner is dead (caller should retry after removing).
_actas_lock_try_claim() {
  local team="$1" agent="$2" sid="$3"
  local lock dir tmp existing
  lock="$(actas_lock_path "$team" "$agent")"
  dir="$(_actas_lock_dir)"
  mkdir -p "$dir" 2>/dev/null || true

  tmp="$(mktemp "$dir/.actas-claim.XXXXXX" 2>/dev/null)" || return 1
  printf '%s\n' "$sid" > "$tmp"

  if ln "$tmp" "$lock" 2>/dev/null; then
    rm -f "$tmp"
    echo "ok"
    return 0
  fi
  rm -f "$tmp"

  existing="$(actas_lock_owner "$team" "$agent")"
  if [ "$existing" = "$sid" ]; then
    echo "ok"
    return 0
  fi
  if actas_lock_sid_alive "$existing"; then
    printf 'held:%s\n' "$existing"
    return 0
  fi
  if actas_lock_owner_reclaimable "$existing"; then
    echo "stale"
    return 0
  fi
  printf 'held:%s\n' "$existing"
  return 0
}

# Claim (team, agent) for session_id.
# Exit codes:
#   0  — claimed (now owned by this sid, was already ours, or stale-replaced).
#   1  — held by another live session. Stdout: "held:<other_sid>".
actas_lock_claim() {
  local team="$1" agent="$2" sid="$3"
  local attempts=0 result lock_path reclaim_dir _owner
  lock_path="$(actas_lock_path "$team" "$agent")"
  reclaim_dir="${lock_path}.reclaim.d"
  while [ "$attempts" -lt 3 ]; do
    result="$(_actas_lock_try_claim "$team" "$agent" "$sid")"
    case "$result" in
      ok) return 0 ;;
      stale)
        # Stale removal needs a re-check-under-mutex. A naked rm (or even an
        # atomic mv) reads-then-removes whatever sits at lock_path, with no
        # guard that the contents are still the stale value we decided on
        # earlier. So two concurrent callers can both see stale, A can
        # successfully install a live lock, and B's later rm/mv would delete
        # A's fresh lock — the original blocker from #65 review finding 1,
        # and the same hazard the mv-only variant inherited.
        #
        # Per-lock mutex via `mkdir` (atomic on POSIX). Re-check inside it:
        # only remove the lock if its current owner is still dead. If a peer
        # snuck a live owner in between our stale decision and the mutex,
        # leave it — the next try_claim observes it as held.
        if mkdir "$reclaim_dir" 2>/dev/null; then
          _owner="$(actas_lock_owner "$team" "$agent")"
          if actas_lock_owner_reclaimable "$_owner"; then
            rm -f "$lock_path"
          fi
          rmdir "$reclaim_dir" 2>/dev/null
        fi
        # If mkdir failed, another caller is mid-reclaim. Loop without
        # touching anything; the next try_claim sees whichever state they
        # end up in (live → held, or empty → we ln-claim).
        attempts=$((attempts + 1))
        continue
        ;;
      held:*)
        printf '%s\n' "$result"
        return 1
        ;;
    esac
    return 1
  done
  return 1
}

# Release a lock if we own it. Idempotent.
actas_lock_release() {
  local team="$1" agent="$2" sid="$3"
  local lock owner
  lock="$(actas_lock_path "$team" "$agent")"
  [ -f "$lock" ] || return 0
  owner="$(actas_lock_owner "$team" "$agent")"
  [ "$owner" = "$sid" ] && rm -f "$lock"
  return 0
}

# Release every lock currently owned by the given session_id. Used by
# session-end.sh when a CC session exits.
actas_lock_release_all() {
  local sid="$1"
  local dir; dir="$(_actas_lock_dir)"
  [ -d "$dir" ] || return 0
  local f owner
  for f in "$dir"/actas.*.session; do
    [ -f "$f" ] || continue
    owner="$(head -1 "$f" 2>/dev/null || true)"
    [ "$owner" = "$sid" ] && rm -f "$f"
  done
  return 0
}

# Garbage-collect locks whose owner session_id is no longer alive.
# Returns the number of locks reclaimed on stdout (for observability).
actas_lock_gc_stale() {
  local dir; dir="$(_actas_lock_dir)"
  [ -d "$dir" ] || { echo 0; return 0; }
  local f owner count=0
  for f in "$dir"/actas.*.session; do
    [ -f "$f" ] || continue
    owner="$(head -1 "$f" 2>/dev/null || true)"
    if actas_lock_owner_reclaimable "$owner"; then
      rm -f "$f"
      count=$((count + 1))
    fi
  done
  echo "$count"
}

# Classify a (team, agent) pair relative to the calling session.
# Prints "<state>\t<owner>"; the owner is empty when there is none to report.
# The states are _actas_lock_verdict's, documented there -- this function is the
# read plus that verdict, and nothing else, so that `observe` and `try_claim`
# cannot drift apart again (they did: review axis 5).
#
# Returning the owner alongside the state matters as much as the values: callers
# that need a baseline to compare against later were reading the state and then
# reading the owner in a SECOND call, and a claim landing between the two
# produced a stale state paired with a fresh owner. One read, both facts, no
# window. (#983, found in review.)
actas_lock_observe() {
  local _r
  _r="$(actas_lock_read "$1" "$2")"
  _actas_lock_verdict "$3" "${_r%%$'\t'*}" "${_r#*$'\t'}"
}

# Cached counterpart of actas_lock_observe, via actas_lock_read_cached. Same
# verdict rule, same owner read every call — only the path resolution behind
# it is memoized. See actas_lock_path_cached's comment for scope.
actas_lock_observe_cached() {
  local _r
  _r="$(actas_lock_read_cached "$1" "$2")"
  _actas_lock_verdict "$3" "${_r%%$'\t'*}" "${_r#*$'\t'}"
}

# Classify a (team, agent) pair relative to the calling session. Thin wrapper over
# actas_lock_observe so there is exactly one place that reads and one set of rules;
# callers needing the owner as well should use actas_lock_observe and split, rather
# than calling both (that pairing is what created the window described above).
actas_lock_state() {
  local team="$1" agent="$2" sid="$3"
  local owner
  owner="$(actas_lock_owner "$team" "$agent")"
  if [ -z "$owner" ]; then
    echo "free"; return 0
  fi
  if [ "$owner" = "$sid" ]; then
    echo "mine"; return 0
  fi
  if actas_lock_sid_alive "$owner"; then
    printf 'other:%s\n' "$owner"
  elif actas_lock_owner_reclaimable "$owner"; then
    echo "free"
  else
    printf 'other:%s\n' "$owner"
  fi
}
