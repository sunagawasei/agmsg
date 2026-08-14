#!/usr/bin/env bash
# Per-team advisory lock for the team registry (teams/<team>/config.json).
#
# Every registry writer (join / leave / reset / rename / rename-team) does a
# read-modify-write: it reads the whole config, computes a new version, and
# overwrites the file. Run concurrently against the same team these races lost
# updates — two joins both read the old config, and whichever writes last clobbers
# the other's agent, so a registration silently disappears even though both
# commands exit 0 (#141).
#
# The fix serializes each team's read-modify-write behind a lock. A directory is
# the lock primitive: mkdir is atomic on POSIX and needs no daemon, so it works
# on macOS (where flock(1) is absent) under bash 3.2, and on Windows Git Bash.
# This is the same idiom the jsonl storage driver uses. The lock is per-team
# (teams/<team>/.config.lock), so operations on different teams never serialize
# against each other.
#
# A process may hold more than one team lock at a time (rename-team locks both the
# source and the target team), so the held locks are tracked as a set and all are
# released together by agmsg_lock_release / the cleanup trap.
#
# Callers pair the lock with a write through agmsg_write_atomic so an unlocked
# reader (whoami / identities / inbox read config.json without the lock) never
# observes a half-written file.

# Newline-separated set of lock dirs this process currently holds.
AGMSG_HELD_LOCKS="${AGMSG_HELD_LOCKS:-}"

# agmsg_lock_acquire <team_dir>
# Acquire <team_dir>'s lock. <team_dir> (teams/<team>) must already exist — the
# caller creates it for a brand-new/target team before locking, so this never
# resurrects a team dir that a concurrent leave/reset just removed. Spins with a
# short sleep up to AGMSG_LOCK_TRIES attempts (default 1000 = ~10s), then fails
# non-zero so the caller can abort rather than silently skip the team.
# Who owns the directory and what this process is, for a failure that is about
# neither the team nor the lock. `ls -ld` and `id` rather than stat(1), whose
# flags differ between BSD and GNU, and both are already required here.
_agmsg_lock_describe_dir() {
  local dir="$1"
  echo "agmsg:   $(ls -ld "$dir" 2>/dev/null || printf '%s (cannot stat)' "$dir")" >&2
  echo "agmsg:   running as: $(id 2>/dev/null || echo 'unknown')" >&2
}

agmsg_lock_acquire() {
  local team_dir="$1" lock i=0 max="${AGMSG_LOCK_TRIES:-1000}" err=""
  lock="$team_dir/.config.lock"
  until err="$(mkdir "$lock" 2>&1)"; do
    # WHY mkdir failed decides whether waiting can help, and only one reason
    # ever clears on its own: somebody holds the lock. Everything else -- no
    # write permission on the team dir, a read-only mount -- is a standing
    # condition, and spinning ten seconds on it then reporting a timeout
    # describes contention that never existed.
    #
    # That mattered in the field. A second machine, running as a different OS
    # account, pointed at the first one's store; the team dir was 0755 and
    # owned by the other user, so mkdir could never succeed. The message named
    # a lock, so the search went to processes: an unrelated sync engine was
    # killed, and when it happened again with no engine running and no lock
    # directory present, the same sentence was still the only evidence. The
    # `2>/dev/null` had thrown away the one line that said EACCES.
    #
    # Decided from the lock's presence rather than from the error text, which
    # is locale-dependent. Checked in this order because the lock existing is
    # the common case and settles it: only when it is absent is the question
    # "can we write here at all". Absent AND writable is a lost race with a
    # holder that has already released -- genuinely transient, so it spins.
    if [ ! -d "$lock" ] && [ ! -w "$team_dir" ]; then
      echo "agmsg: cannot create the registry lock in $team_dir" >&2
      echo "agmsg: mkdir: $err" >&2
      echo "agmsg: nothing is holding the lock — this directory cannot be written to, so waiting will not clear it." >&2
      _agmsg_lock_describe_dir "$team_dir"
      return 1
    fi
    i=$((i + 1))
    if [ "$i" -ge "$max" ]; then
      echo "agmsg: timed out acquiring registry lock for $team_dir" >&2
      # The reason travels with the timeout too. If the wait was hopeless for
      # a cause this function did not anticipate, the errno is the only thing
      # that will say so.
      [ -n "$err" ] && echo "agmsg: last mkdir error: $err" >&2
      return 1
    fi
    sleep 0.01
  done
  # WHO HOLDS IT, written the moment it is held (#778).
  #
  # A lock directory with nothing in it can say that something is holding it and
  # nothing about what. When one leaks, the operator's only options are to guess
  # or to remove it blind — and removing a live lock is worse than the leak. The
  # pid and the command are what turn "a lock is here" into "this process, and
  # it is gone".
  #
  # Best-effort on purpose: the lock is HELD as of the mkdir above, and a failure
  # to annotate it must not undo that. An unannotated lock is exactly the lock
  # this file had before, which is worse than one that names its holder and no
  # worse than nothing.
  {
    printf 'pid %s\n' "$$"
    printf 'command %s\n' "${0##*/}"
    printf 'host %s\n' "$(uname -n 2>/dev/null || echo unknown)"
  } > "$lock/holder" 2>/dev/null || true
  AGMSG_HELD_LOCKS="${AGMSG_HELD_LOCKS:+$AGMSG_HELD_LOCKS
}$lock"
  # Idempotent: re-arming the same handlers each acquire is harmless. They release
  # every held lock, so a crash with one or two locks held leaves no stale lock.
  # EXIT releases only. INT/TERM release AND exit, so a signal arriving between
  # commands in a critical section can't release the lock and then let the script
  # continue into an unprotected config move/write (matters for 2-lock
  # rename-team). NOTE: no current registry writer sets its own trap; a future
  # caller that does must chain these in.
  trap 'agmsg_lock_release' EXIT
  trap 'agmsg_lock_release; exit 130' INT
  trap 'agmsg_lock_release; exit 143' TERM
}

# agmsg_lock_release
# Release every lock this process holds (no-op if none). rmdir only removes the
# (empty) lock dirs, never a team dir or its config.
# agmsg_lock_release_one <team_dir>
# Release ONE lock and leave every other held lock alone.
#
# `agmsg_lock_release` drops everything this process holds, which is right for a
# command that is finishing and wrong for anything that acquires a lock inside a
# larger operation: the caller may hold locks for other teams, and this library's
# own contract is that it can. A caller that acquired one lock and released all
# of them has taken locks away from code that is still using them.
#
# The line is matched WHOLE, not as a substring: lock paths nest (a team named
# `a` and a team named `ab` under the same root), so a substring test would let
# one team's release take another's.
# Release one lock directory, and say so when it cannot be released (#778).
#
# `rmdir … || true` treated two different events as one. A lock that is already
# gone is a released lock — nothing to report. A lock that will not go is the
# leak this file's own contract promises not to leave, and the operator learned
# about it only when the next command blocked, with nothing naming the cause.
#
# The holder file written at acquire time makes the directory non-empty, so the
# removal is two steps. Both are this process's own file and its own lock; a
# failure of either is reported rather than swallowed.
_agmsg_lock_drop() {
  local l="$1" err=""
  [ -d "$l" ] || return 0
  rm -f "$l/holder" 2>/dev/null || true
  err="$(rmdir "$l" 2>&1)" && return 0
  # Still here. Say which lock, say why, and say what it costs — the next
  # acquire on this team will wait for a holder that is not coming back.
  echo "agmsg: could not release the registry lock at $l" >&2
  echo "agmsg: rmdir: $err" >&2
  echo "agmsg: until this directory is removed, commands for this team will wait" >&2
  echo "agmsg: for a lock nothing holds." >&2
  # The remedy has to work for the case that produced it. `rmdir` is what just
  # failed — printing it back is a route that ends where the operator already
  # is. Measured: the only reason release gets here with the directory present
  # is that something is inside it, and that is precisely what rmdir refuses.
  echo "agmsg: look at what is in it, then remove the directory:" >&2
  echo "agmsg:   ls -la $l" >&2
  echo "agmsg:   rm -r $l" >&2
  echo "agmsg: nothing but this lock lives in there — it holds no team data." >&2
  return 1
}

agmsg_lock_release_one() {
  local lock="$1/.config.lock" kept="" l
  [ -n "${AGMSG_HELD_LOCKS:-}" ] || return 0
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    if [ "$l" = "$lock" ]; then
      _agmsg_lock_drop "$l" || true
    else
      kept="${kept:+$kept
}$l"
    fi
  done <<EOF
$AGMSG_HELD_LOCKS
EOF
  AGMSG_HELD_LOCKS="$kept"
}

agmsg_lock_release() {
  [ -n "${AGMSG_HELD_LOCKS:-}" ] || return 0
  local l
  while IFS= read -r l; do
    [ -n "$l" ] && { _agmsg_lock_drop "$l" || true; }
  done <<EOF
$AGMSG_HELD_LOCKS
EOF
  AGMSG_HELD_LOCKS=""
}

# agmsg_write_atomic <dest> <content>
# Write <content> (plus a trailing newline, matching the previous `echo >`) to a
# temp file in the same directory, then rename(2) it over <dest>. The rename is
# atomic, so a concurrent unlocked reader sees either the old or the new file,
# never a truncated one.
agmsg_write_atomic() {
  local dest="$1" content="$2" tmp
  tmp="$dest.tmp.$$"
  printf '%s\n' "$content" > "$tmp"
  mv "$tmp" "$dest"
}
