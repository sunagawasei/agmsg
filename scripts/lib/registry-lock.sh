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
agmsg_lock_release() {
  [ -n "${AGMSG_HELD_LOCKS:-}" ] || return 0
  local l
  while IFS= read -r l; do
    [ -n "$l" ] && { rmdir "$l" 2>/dev/null || true; }
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
