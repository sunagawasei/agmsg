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
# short sleep until AGMSG_LOCK_SECONDS elapse (default 10), then fails non-zero
# so the caller can abort rather than silently skip the team.
#
# BUDGETED IN TIME, NOT ITERATIONS (#779). The old budget was 1000 attempts and
# the comment beside it read "= ~10s", which is arithmetic that holds only where
# an mkdir and a sleep are free. Measured on macOS: 100 attempts take 3 seconds,
# not 1 — already three times the stated figure, before Windows, where the
# report that raised this saw minutes. A wait announced in seconds has to be
# counted in seconds, or the number in the message is not about the wait.
#
# AGMSG_LOCK_TRIES still caps the attempt count and still defaults to 1000. It
# is set by four tests to make them fail fast and by nothing in production, so
# it stays as a ceiling — whichever bound is reached first ends the wait, and
# each one names itself when it does.
# Who owns the directory and what this process is, for a failure that is about
# neither the team nor the lock. `ls -ld` and `id` rather than stat(1), whose
# flags differ between BSD and GNU, and both are already required here.
_agmsg_lock_describe_dir() {
  local dir="$1"
  echo "agmsg:   $(ls -ld "$dir" 2>/dev/null || printf '%s (cannot stat)' "$dir")" >&2
  echo "agmsg:   running as: $(id 2>/dev/null || echo 'unknown')" >&2
}

# A seam for the interleavings this file's correctness rests on. Production never
# overrides it; a test redefines it after sourcing to stop a process at a named
# point and act as the "other" process there. Without it the races below could
# only be argued, not exercised.
_agmsg_lock_test_hook() { :; }

# WHICH PROCESS TABLE A RECORDED PID BELONGS TO.
#
# A pid is a number in one process table, and "this pid is not running here" says
# nothing about a record written by a process in another table. A hostname does
# not name a table (a shared store is reachable from machines that share one, and
# HOSTNAME is a variable anyone can set). The record carries a scope instead,
# and a record is judged only by a process whose scope is IDENTICAL:
#   Linux  machine-id : boot_id : the pid namespace's identity (readlink of
#          /proc/self/ns/pid). Containers on one kernel share the first two and
#          differ in the third; a cloned image shares the first and differs in the
#          second.
#   macOS  IOPlatformUUID : kern.bootsessionuuid. macOS has no pid namespaces.
# Anything that cannot be read, or reads as a placeholder, leaves the scope empty
# -- and an empty scope is "cannot tell", never "the same". Windows is left empty
# on purpose: that is the behaviour before this existed, not a regression.
_AGMSG_LOCK_SCOPE=""
_AGMSG_LOCK_SCOPE_LOADED=""

_agmsg_lock_valid_id() {   # <value> <length>: lowercase hex, not all zeros
  local v="$1" n="$2" zeros=""
  [ "${#v}" -eq "$n" ] || return 1
  case "$v" in *[!0-9a-f]*) return 1 ;; esac
  while [ "${#zeros}" -lt "$n" ]; do zeros="${zeros}0"; done
  [ "$v" != "$zeros" ]
}

# Sets _AGMSG_LOCK_SCOPE (no subshell, so the answer is cached for the process).
_agmsg_lock_scope_load() {
  [ -z "$_AGMSG_LOCK_SCOPE_LOADED" ] || return 0
  _AGMSG_LOCK_SCOPE_LOADED=1
  local mid="" boot="" ns="" line
  case "${OSTYPE:-}" in
    linux*)
      { read -r mid < /etc/machine-id; } 2>/dev/null || [ -n "$mid" ] || { read -r mid < /var/lib/dbus/machine-id; } 2>/dev/null || true
      _agmsg_lock_valid_id "$mid" 32 || return 0
      { read -r boot < /proc/sys/kernel/random/boot_id; } 2>/dev/null || true
      [ -n "$boot" ] || return 0
      command -v readlink >/dev/null 2>&1 || return 0
      ns="$(readlink /proc/self/ns/pid 2>/dev/null)" || return 0
      [ -n "$ns" ] || return 0
      ;;
    darwin*)
      command -v ioreg >/dev/null 2>&1 && command -v sysctl >/dev/null 2>&1 || return 0
      # Read with builtins (one program fewer on every acquire), to the end of
      # the output so the program has finished before the lock is taken.
      while IFS= read -r line; do
        case "$line" in
          *'"IOPlatformUUID" = "'*)
            # The first one, as before; the rest is read only so the program ends.
            if [ -z "$mid" ]; then mid="${line#*\"IOPlatformUUID\" = \"}"; mid="${mid%%\"*}"; fi ;;
        esac
      done < <(ioreg -rd1 -c IOPlatformExpertDevice 2>/dev/null)
      boot="$(sysctl -n kern.bootsessionuuid 2>/dev/null)" || return 0
      [ -n "$mid" ] && [ -n "$boot" ] || return 0
      ns="-"
      ;;
    *) return 0 ;;
  esac
  # Recorded as a digest, not as the raw identifiers: a machine id is a stable
  # host identifier, and the record sits in a store other machines can read. The
  # digest still compares equal exactly when the three parts do. With no hash
  # tool there is no scope, which is "cannot tell".
  _AGMSG_LOCK_SCOPE="$(printf 'agmsg-lock-scope:%s:%s:%s' "$mid" "$boot" "$ns" | _agmsg_lock_digest)" || _AGMSG_LOCK_SCOPE=""
}

_agmsg_lock_digest() {   # stdin -> hex digest, or non-zero when nothing here can hash
  local h=""
  if command -v sha256sum >/dev/null 2>&1; then
    h="$(sha256sum)" || return 1
  elif command -v shasum >/dev/null 2>&1; then
    h="$(shasum -a 256)" || return 1
  else
    return 1
  fi
  h="${h%% *}"
  [ -n "$h" ] || return 1
  printf '%s' "$h"
}

# Read a holder record in ONE pass, with builtins only (no process is started:
# this runs on every failed mkdir of a contended acquire, and a wait that costs
# forks per spin starves a contender when the machine is busy).
# Sets _R_TOKEN _R_PID _R_SCOPE _R_BREAK, _R_HASBREAK=1 when a `break` line is
# present, and _R_DUP=1 when any of those four appears twice -- a record somebody
# wrote by hand, which is not trusted.
_agmsg_lock_parse() {   # <file>
  local line seen=" "
  _R_TOKEN=""; _R_PID=""; _R_SCOPE=""; _R_BREAK=""; _R_HASBREAK=""; _R_DUP=""
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "token "*|"pid "*|"scope "*|"break "*)
        case "$seen" in *" ${line%% *} "*) _R_DUP=1 ;; esac
        seen="$seen${line%% *} "
        case "$line" in
          "token "*) _R_TOKEN="${line#token }" ;;
          "pid "*) _R_PID="${line#pid }" ;;
          "scope "*) _R_SCOPE="${line#scope }" ;;
          "break "*) _R_BREAK="${line#break }"; _R_HASBREAK=1 ;;
        esac ;;
    esac
  done 2>/dev/null < "$1"
}

# How many holder records the lock directory holds, and which (the last one).
# A directory is one generation: exactly one `holder.<token>`. Zero is a lock
# nobody has recorded yet (or whose owner died before it could); more than one is
# an acquire race caught in the act. Neither is judged.
_agmsg_lock_holder_scan() {   # <lock> -> _H_COUNT, _H_FILE
  local f
  _H_COUNT=0; _H_FILE=""
  for f in "$1"/holder.*; do
    [ -f "$f" ] || continue
    _H_COUNT=$((_H_COUNT + 1)); _H_FILE="$f"
  done
}

# A path as ONE shell word, for a command that is meant to be pasted. The store
# root and the team name can both contain a space or an apostrophe (team names
# are validated against empty / `.` / `..` / `/` / `\` / a leading `-` / control
# characters, and nothing else), and a path that splits into several words, or
# closes its own quote, makes `rm -r` or `rmdir` act on something the operator
# did not read about. Same scheme as lib/shquote.sh, inline rather than sourced
# so this library keeps its single-file contract.
_agmsg_lock_quote() {   # <path>
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# A record, on one line, safe to print. The store can be shared, so a record is
# written by whoever can reach it, and its fields (the host name is an
# environment variable) reach the operator's terminal: anything that is not
# printable ASCII becomes `?`, which is what keeps an escape sequence from being
# one.
_agmsg_lock_show() {   # <file>
  tr '\n' ' ' < "$1" 2>/dev/null | LC_ALL=C tr -c '[:print:]' '?'
}

# LIVENESS, from the library that already answers this question (#865).
#
# `kill -0` on its own reads EPERM as dead, which in a sandbox turns "cannot
# signal" into "not running" -- and here that would break a lock somebody is
# holding. `_agmsg_pid_alive_local` treats EPERM as alive, a zombie as gone, and
# cross-checks with `ps`, and a failed `ps` observation is "cannot tell", not
# "dead" (#970). Sourced rather than reimplemented.
#
# LOADED ON FIRST USE, and located with builtins only. This file is sourced on
# PATHs that carry almost nothing (`join` is required to work on one, and a test
# runs a write with `rm` and `dirname` missing), so loading it must not need an
# external command, and the uncontended path -- which never asks who holds a
# lock -- must not pay for a library it does not use.
_AGMSG_LOCK_SELF="${BASH_SOURCE[0]:-$0}"
case "$_AGMSG_LOCK_SELF" in
  */*) _AGMSG_LOCK_SELF_DIR="$(cd "${_AGMSG_LOCK_SELF%/*}" 2>/dev/null && pwd)" || _AGMSG_LOCK_SELF_DIR="" ;;
  *) _AGMSG_LOCK_SELF_DIR="$(pwd)" ;;
esac

# Returns 0 when the liveness helpers are available, 1 when they could not be
# loaded -- and then nothing here can ask whether a holder is running, which is
# "cannot tell", never "dead".
_agmsg_lock_load_liveness() {
  if declare -f _agmsg_pid_alive_local >/dev/null 2>&1; then return 0; fi
  [ -n "$_AGMSG_LOCK_SELF_DIR" ] && [ -f "$_AGMSG_LOCK_SELF_DIR/instance-id.sh" ] || return 1
  # shellcheck source=instance-id.sh
  source "$_AGMSG_LOCK_SELF_DIR/instance-id.sh" 2>/dev/null || return 1
  declare -f _agmsg_pid_alive_local >/dev/null 2>&1
}

# `break writers`: the holder is gone, so ask about what it started. The holder
# records, inside the lock directory and under its own token, a `pending.<token>.<name>`
# file BEFORE it does anything that can leave a process running past its own death,
# and a `writer.<token>.<pid>` file once it knows that process's pid; the
# `pending` file is removed only after the pid is recorded. So at any moment after
# the holder (and each recorded writer) is dead, the files say the whole truth:
#
#   a pending file    a process may exist that nobody recorded -- cannot tell
#   writer files      every one of them has to be dead
#
# THE ORDER IS THE PROOF. The writers are checked first, then the directory is
# read AGAIN: a process that is dead cannot add a file, so once every recorded
# writer has been seen dead the second read is final for it. A writer or pending
# file that shows up only in the second read belongs to a process that was alive
# during the first, and is reported rather than guessed at (the caller asks again).
# Files of another generation (another token) are not this record's evidence.
# Builtins only: this runs on every failed mkdir of a contended acquire.
_agmsg_lock_writers_judge() {   # <lock> <token>
  local lock="$1" token="$2" f pid seen=" "
  for f in "$lock"/writer."$token".*; do
    [ -e "$f" ] || continue
    pid="${f##*.}"
    _agmsg_pid_valid "$pid" 2147483647 || { _J_VERDICT=malformed; return 1; }
    _J_EVID=1
    if _agmsg_pid_alive_local "$pid"; then _J_VERDICT=writer-alive; return 1; fi
    seen="$seen$pid "
  done
  _agmsg_lock_test_hook judge:after-writers "$lock"
  for f in "$lock"/pending."$token".*; do
    [ -e "$f" ] || continue
    _J_VERDICT=unbreakable; return 1
  done
  for f in "$lock"/writer."$token".*; do
    [ -e "$f" ] || continue
    pid="${f##*.}"
    case "$seen" in *" $pid "*) ;; *) _J_VERDICT=writer-alive; return 1 ;; esac
  done
  return 0
}

# Is this lock's holder gone? Sets _J_VERDICT, and _J_FILE for a single record.
#
#   gone      the one record is well formed, was written in THIS process table,
#             and its pid is positively not running -- the only verdict that
#             lets anything be broken
#   alive     same table, pid running
#   none      the directory holds no record (not yet written, or its owner died
#             first): nothing can tell this from a lock taken a moment ago
#   multi     more than one record: an acquire race caught in the act
#   unbreakable  pid not running, but the record says its pid is not the whole of
#             what holds the lock (see agmsg_lock_acquire): reported, never broken.
#             For `break writers` it means a writer may exist that nobody has
#             recorded yet (a `pending` file is still in the directory)
#   writer-alive  `break writers`: the holder is gone, but a writer it recorded is
#             still running
#   foreign   written in another process table, or this process cannot name its own
#   noscope / badpid / malformed / noliveness   the record or the check is unusable
#
# Everything but `gone` is "cannot tell", and breaking on "cannot tell" takes a
# live lock away, which is worse than the leak. A recycled pid reads as alive,
# which is the safe direction.
_agmsg_lock_judge() {   # <lock>
  local lock="$1" pid scope token f
  _J_VERDICT=""; _J_FILE=""; _J_EVID=""
  _agmsg_lock_holder_scan "$lock"
  case "$_H_COUNT" in
    0)
      # Nothing recorded. An empty directory is a lock nobody has recorded yet;
      # one with other things in it (what a failed release leaves) is not, and
      # `rmdir` would not remove it.
      _J_VERDICT=none
      for f in "$lock"/* "$lock"/.[!.]* "$lock"/..?*; do
        if [ -e "$f" ] || [ -L "$f" ]; then _J_VERDICT=nonempty; break; fi
      done
      return 1 ;;
    1) ;;
    *) _J_VERDICT=multi; return 1 ;;
  esac
  _J_FILE="$_H_FILE"
  _agmsg_lock_load_liveness || { _J_VERDICT=noliveness; return 1; }
  _agmsg_lock_parse "$_H_FILE"
  token="$_R_TOKEN"; pid="$_R_PID"; scope="$_R_SCOPE"
  # A field that appears twice, or a `break` that says anything but `no`, is a
  # record somebody wrote by hand: not trusted.
  if [ -n "$_R_DUP" ] || { [ -n "$_R_HASBREAK" ] && [ "$_R_BREAK" != "no" ] && [ "$_R_BREAK" != "writers" ]; }; then _J_VERDICT=malformed; return 1; fi
  # The name carries the generation and the content must agree with it.
  if [ -z "$token" ] || [ "${_H_FILE##*/}" != "holder.$token" ]; then _J_VERDICT=malformed; return 1; fi
  _agmsg_pid_valid "$pid" 2147483647 || { _J_VERDICT=badpid; return 1; }
  [ -n "$scope" ] || { _J_VERDICT=noscope; return 1; }
  _agmsg_lock_scope_load
  if [ -z "$_AGMSG_LOCK_SCOPE" ] || [ "$scope" != "$_AGMSG_LOCK_SCOPE" ]; then _J_VERDICT=foreign; return 1; fi
  if _agmsg_pid_alive_local "$pid"; then _J_VERDICT=alive; return 1; fi
  # Gone, but the holder said its pid is not the whole of what holds the lock.
  if [ -n "$_R_HASBREAK" ]; then
    if [ "$_R_BREAK" = writers ]; then
      _agmsg_lock_writers_judge "$lock" "$token" || return 1
    else
      _J_VERDICT=unbreakable; return 1
    fi
  fi
  _J_VERDICT=gone
  return 0
}

# Remove the writer evidence of ONE generation (see _agmsg_lock_writers_judge).
# Called only after the record of that generation has been claimed, and only for
# its token: a successor's files carry another token and are not matched.
_agmsg_lock_evidence_clear() {   # <lock> <token>
  # A lock that never recorded a writer pays nothing: no process is started on its
  # way out (a test holds the release path to mkdir, mv and rmdir).
  _agmsg_lock_evidence_present "$1" "$2" || return 0
  command -v rm >/dev/null 2>&1 || return 0
  rm -f "$1"/pending."$2".* "$1"/writer."$2".* 2>/dev/null || :
}

# Is there evidence of this generation in the directory?
_agmsg_lock_evidence_present() {   # <lock> <token>
  local f
  for f in "$1"/pending."$2".* "$1"/writer."$2".*; do
    [ -e "$f" ] && return 0
  done
  return 1
}

# For a holder that started `break writers`: files kept inside its own lock
# directory, under its token, that let a later acquirer tell whether anything it
# started is still running. See _agmsg_lock_writers_judge for how they are read.
#
#   agmsg_lock_pending_begin <team_dir> <name>   before starting something that can
#                              outlive this process; returns 1 when it could not be
#                              recorded -- then start nothing
#   agmsg_lock_writer_record <team_dir> <pid>    once the pid of what was started
#                              is known; returns 1 when it could not be recorded
#   agmsg_lock_pending_end <team_dir> <name>     after the pid is recorded. Never
#                              fails: a pending file that stays only keeps the lock
#                              (the safe direction), and a caller under `set -e`
#                              must not be ended by it with a writer running
_agmsg_lock_evidence_token() {   # <team_dir>
  _EV_LOCK="$1/.config.lock"
  _EV_TOKEN="$(_agmsg_lock_get_token "$_EV_LOCK" || printf '')"
  [ -n "$_EV_TOKEN" ]
}
agmsg_lock_pending_begin() {
  _agmsg_lock_evidence_token "$1" || return 1
  { : > "$_EV_LOCK/pending.$_EV_TOKEN.$2"; } 2>/dev/null
}
agmsg_lock_writer_record() {
  _agmsg_lock_evidence_token "$1" || return 1
  { : > "$_EV_LOCK/writer.$_EV_TOKEN.$2"; } 2>/dev/null
}
agmsg_lock_pending_end() {
  _agmsg_lock_evidence_token "$1" || return 0
  command -v rm >/dev/null 2>&1 || return 0
  rm -f "$_EV_LOCK/pending.$_EV_TOKEN.$2" 2>/dev/null || :
  return 0
}

# Break a lock whose recorded holder is gone.
#
# THE CLAIM IS A RENAME OF THE RECORD BY ITS EXACT NAME, and the name carries the
# generation. `mv <lock>/holder.<token>` succeeds only if the directory at that
# path still holds that very record, so a lock that changed hands between the
# judgement and the claim is not touched: the rename fails and this returns.
# Whoever wins the claim is the only process that can remove this generation, and
# the judgement made before it stands -- the record is a file nobody rewrites, so
# there is nothing to re-ask. (A re-judgement here could only come out
# differently by a pid being recycled, and then the record is already staged: it
# would leave a directory nobody can ever break.)
#
# `rmdir` then removes the directory only if it is empty. A successor that has
# published its own record makes it fail; a successor that has only made the
# directory sees its publish fail and starts over (see agmsg_lock_acquire).
_agmsg_lock_break_dead() {
  local lock="$1" f tok staged
  _agmsg_lock_judge "$lock" || return 1
  f="$_J_FILE"; tok="${f##*/holder.}"
  # The recorded writers' files have to be removed before the directory can go,
  # and that needs `rm`: without it, leave the lock as it is rather than claim it.
  if [ -n "$_J_EVID" ] && ! command -v rm >/dev/null 2>&1; then return 1; fi
  _agmsg_lock_test_hook break:after-judge "$lock"
  staged="$lock.dead.$tok.$$"
  mv "$f" "$staged" 2>/dev/null || return 1
  _agmsg_lock_test_hook break:after-claim "$lock"
  _agmsg_lock_evidence_clear "$lock" "$tok"
  if ! rmdir "$lock" 2>/dev/null; then
    # Not removed (a successor, or something else inside): the lock is still
    # there and is no longer recorded, which doctor reports.
    if command -v rm >/dev/null 2>&1; then rm -f "$staged" 2>/dev/null || :; fi
    return 1
  fi
  if command -v rm >/dev/null 2>&1; then rm -f "$staged" 2>/dev/null || :; fi
  return 0
}

# Publish this process's record into the directory it just made, and confirm it
# is the only record there. Returns 0 owned, 1 start over (the directory was not
# ours after all), 2 cannot publish (reported).
#
# The record goes in as `<lock>/holder.<token>`, INSIDE the directory it belongs
# to. A record beside the directory outlives it: the remedy printed for a failed
# release deletes the directory and leaves that record, and the next owner then
# has a fresh directory next to a dead owner's record that a breaker will happily
# judge and use to remove it. Inside, the record and the directory are one
# generation -- deleting the directory deletes the record.
#
# It is written whole in a private name beside the lock and renamed in, so a
# reader never sees half a record. The rename fails if the directory is gone, and
# that is how an owner learns that a breaker removed the still-empty directory it
# had just made: nothing to rmdir can tell a bare directory from a dead one, so
# the owner is the one that checks, and starts over.
#
# Two acquirers can both end up with a record in one directory (a breaker removes
# A's bare directory and B makes a new one before A's record lands). Each
# publishes and then counts: whoever finds more than one backs off completely --
# removes its own record and the directory if that leaves it empty -- and starts
# over, so the directory is never left recorded by nobody. The later publisher
# always sees the earlier one, so at most one of them proceeds.
_agmsg_lock_publish() {   # <lock> <token> <unbreakable|writers|""> <command> <host>
  local lock="$1" token="$2" pub body cmd="$4" host="$5"
  [ -n "$token" ] || return 0   # no entropy: nothing to publish, see the caller
  pub="$lock.pub.$token"
  _agmsg_lock_scope_load
  body="token $token
pid $$
command $cmd
host $host"
  [ -z "$_AGMSG_LOCK_SCOPE" ] || body="$body
scope $_AGMSG_LOCK_SCOPE"
  case "${3:-}" in
    '') ;;
    writers) body="$body
break writers" ;;
    *) body="$body
break no" ;;
  esac
  _agmsg_lock_test_hook acquire:after-mkdir "$lock"
  if ! { printf '%s\n' "$body" > "$pub"; } 2>/dev/null; then
    _agmsg_lock_abandon "$lock" "$pub"
    echo "agmsg: could not write this process's holder record beside $lock" >&2
    return 2
  fi
  if ! mv "$pub" "$lock/holder.$token" 2>/dev/null; then
    if [ ! -d "$lock" ]; then
      if command -v rm >/dev/null 2>&1; then rm -f "$pub" 2>/dev/null || :; fi
      return 1
    fi
    _agmsg_lock_abandon "$lock" "$pub"
    echo "agmsg: could not record this process as the holder of $lock" >&2
    return 2
  fi
  _agmsg_lock_test_hook acquire:after-publish "$lock"
  _agmsg_lock_holder_scan "$lock"
  if [ "$_H_COUNT" -ne 1 ] || [ "$_H_FILE" != "$lock/holder.$token" ]; then
    _agmsg_lock_drop "$lock" quiet || :
    return 1
  fi
  return 0
}

# A publish that failed with the directory still there: take back the directory
# this process made (rmdir removes an EMPTY one only) rather than retry against
# it for the rest of the budget.
_agmsg_lock_abandon() {   # <lock> <pub>
  # The directory first: it is the lock, and `rm` is a program other contenders
  # would wait behind.
  rmdir "$1" 2>/dev/null || :
  if command -v rm >/dev/null 2>&1; then rm -f "$2" 2>/dev/null || :; fi
}

# agmsg_lock_acquire <team_dir> [unbreakable|writers]
#
# `writers` marks the record `break writers`: the holder starts writers that can
# outlive it and records them (agmsg_lock_pending_begin and the two after it), and
# a later acquirer breaks the lock once the holder and every recorded writer are
# gone and nothing is pending.
#
# `unbreakable` marks the record `break no`: a later acquirer never breaks this
# lock on the strength of the holder's pid being gone, it only reports it. For a
# holder that hands the critical section to a process that can outlive it (the
# roster sync driver starts a writer in the background and holds the lock for it):
# that holder's pid dying does not mean the writer stopped, and a second writer
# entering beside a live one is worse than the leak.
# Library-prefixed, because this file is sourced into the caller's shell.
_agmsg_lock_now() {
  if [ -n "${SECONDS+x}" ] && [ -n "$SECONDS" ]; then _AGMSG_LOCK_NOW="$SECONDS"; else _AGMSG_LOCK_NOW="$(date +%s)"; fi
}

# Everything a holder record needs that costs a process, fetched BEFORE a lock is
# taken (see agmsg_lock_acquire for why). Sets _LK_NONCE, _LK_CMD and _LK_HOST.
_agmsg_lock_ident() {
  _LK_NONCE="$(LC_ALL=C od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')" || _LK_NONCE=""
  [ -n "$_LK_NONCE" ] || _LK_NONCE="${RANDOM:-}${RANDOM:-}${RANDOM:-}"
  _agmsg_lock_scope_load
  _LK_CMD="${0##*/}"
  _LK_HOST="${HOSTNAME:-}"
  [ -n "$_LK_HOST" ] || _LK_HOST="$(uname -n 2>/dev/null || echo unknown)"
  _LK_CMD="${_LK_CMD//[![:print:]]/?}"
  _LK_HOST="${_LK_HOST//[![:print:]]/?}"
}

_AGMSG_LOCK_ATTEMPT=0

# One attempt to take <lock> (a directory path), with no waiting and no traps:
# every wait loop that takes a lock built on this library -- the registry lock
# below, the placement lock, the claude-code bridge instance lock -- makes its
# attempt here and breaks a dead holder with _agmsg_lock_break_dead, so "who holds
# this, and is it gone" has one answer. Needs _agmsg_lock_ident to have run.
#
#   0  taken; the holder record is published and the token is kept for release
#   1  not ours after all (a breaker removed the directory between mkdir and
#      publish); it has been handed back, start over
#   2  could not publish; reported
#   3  somebody holds it, or mkdir failed for another reason (text in _LK_ERR)
#
# <held> 1 registers the lock in AGMSG_HELD_LOCKS, so the registry lock's
# EXIT/INT/TERM handlers release it. 0 leaves release to the caller
# (_agmsg_lock_drop), for a caller that owns its own traps.
_agmsg_lock_try() {   # <lock> <unbreakable|writers|""> <held 0|1>
  local lock="$1" unbreakable="$2" held="$3" token="" rc=0
  _LK_ERR=""
  if ! _LK_ERR="$(mkdir "$lock" 2>&1)"; then return 3; fi
  _LK_ERR=""
  # THE TOKEN IS THE GENERATION, per lock, not per process. This library's
  # contract is that a process can hold several locks at once (rename-team
  # takes two), so a single token would be overwritten by the second acquire.
  # It names the record inside the directory, and release and break remove
  # only a record they can name -- so a lock that changed hands is never
  # removed by someone who held the previous one. One per attempt: a lock
  # given up and taken again is a new generation.
  [ -z "$_LK_NONCE" ] || token="$$.$_LK_NONCE.$_AGMSG_LOCK_ATTEMPT"
  _AGMSG_LOCK_ATTEMPT=$((_AGMSG_LOCK_ATTEMPT + 1))
  # Registered before the record exists, so a signal in between still goes
  # through release and takes back a directory this process made.
  [ -z "$token" ] || _agmsg_lock_set_token "$lock" "$token"
  if [ "$held" = 1 ]; then
    AGMSG_HELD_LOCKS="${AGMSG_HELD_LOCKS:+$AGMSG_HELD_LOCKS
}$lock"
  fi
  _agmsg_lock_publish "$lock" "$token" "$unbreakable" "$_LK_CMD" "$_LK_HOST" || rc=$?
  case "$rc" in
    0) return 0 ;;
    2) [ "$held" = 1 ] && _agmsg_lock_unhold "$lock"; return 2 ;;
  esac
  [ "$held" = 1 ] && _agmsg_lock_unhold "$lock"
  return 1
}

agmsg_lock_acquire() {
  local team_dir="$1" unbreakable="${2:-}" lock i=0 max="${AGMSG_LOCK_TRIES:-1000}" err=""
  local budget="${AGMSG_LOCK_SECONDS:-10}" started elapsed
  local rc
  case "$unbreakable" in
    ''|unbreakable|writers) ;;
    *) echo "agmsg: agmsg_lock_acquire: unknown option '$unbreakable'" >&2; return 1 ;;
  esac
  lock="$team_dir/.config.lock"
  # EVERYTHING THAT NEEDS A PROCESS IS DONE BEFORE THE LOCK IS TAKEN. The time
  # between a successful mkdir and the release is serialised across every
  # contender, and each program started in it is paid by all of them in turn: on
  # a busy machine a waiter then spends its whole wait budget behind the others'
  # process spawns. The entropy and the process scope are needed for the record,
  # not for holding the lock, so they are fetched first.
  #
  # Entropy: a pid and a second are not unique across hosts on a shared store
  # and $RANDOM is 15 bits where it exists at all. FAIL SAFE MEANS NO TOKEN,
  # not a weak one: with none, this process records nothing, holds the lock,
  # and refuses to delete anything at release -- the lock leaks, which is the
  # failure this file chose over taking a live lock away.
  # The record is a line protocol and the command and host fields are display
  # text out of the environment; _agmsg_lock_ident makes each one printable line.
  _agmsg_lock_ident
  # The budget is for WAITING, so it starts after the above: a process that is
  # slow to start must not spend its wait on starting. The clock is the shell's
  # own SECONDS (no process per spin), `date` only where that is not available.
  _agmsg_lock_now; started="$_AGMSG_LOCK_NOW"
  while :; do
    rc=0
    _agmsg_lock_try "$lock" "$unbreakable" 1 || rc=$?
    err="$_LK_ERR"
    if [ "$rc" != 3 ]; then
      case "$rc" in
        0) break ;;
        2) return 1 ;;
      esac
      # 1: not ours after all, and it has been handed back. Start over.
    else
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
      # is locale-dependent. Absent AND writable is a lost race with a holder
      # that has already released -- genuinely transient, so it spins.
      if [ ! -d "$lock" ] && [ ! -w "$team_dir" ]; then
        echo "agmsg: cannot create the registry lock in $team_dir" >&2
        echo "agmsg: mkdir: $err" >&2
        echo "agmsg: nothing is holding the lock — this directory cannot be written to, so waiting will not clear it." >&2
        _agmsg_lock_describe_dir "$team_dir"
        return 1
      fi
      # IS ANYBODY THERE? Until #865 this loop never asked: a lock whose holder
      # had been killed waited out its budget and failed, every time, until
      # somebody removed a directory by hand. `kill -9`, an OOM kill and a
      # force-quit run no trap, so the lock stays.
      if _agmsg_lock_break_dead "$lock"; then
        echo "agmsg: broke a registry lock in $team_dir whose recorded holder is gone" >&2
        continue
      fi
    fi
    i=$((i + 1))
    _agmsg_lock_now; elapsed=$(( _AGMSG_LOCK_NOW - started ))
    # Whichever bound arrives first, and the message says which — "1000 tries"
    # and "10 seconds" are different facts about a wait, and an operator
    # deciding whether to retry needs the one that actually stopped it.
    if [ "$elapsed" -ge "$budget" ] || [ "$i" -ge "$max" ]; then
      # ONE PHRASE, then which bound. Callers match on "timed out acquiring
      # registry lock" — `test_remote.bats` does, with a short attempt budget.
      if [ "$elapsed" -ge "$budget" ]; then
        echo "agmsg: timed out acquiring registry lock for $team_dir after ${elapsed}s" >&2
      else
        echo "agmsg: timed out acquiring registry lock for $team_dir after $i attempts (${elapsed}s)" >&2
      fi
      _agmsg_lock_explain_timeout "$lock"
      # The reason travels with the timeout too. If the wait was hopeless for
      # a cause this function did not anticipate, the errno is the only thing
      # that will say so.
      [ -n "$err" ] && echo "agmsg: last mkdir error: $err" >&2
      return 1
    fi
    sleep 0.01
  done
  # Idempotent: re-arming the same handlers each acquire is harmless.
  #
  # WHAT THEY COVER, AND WHAT THEY DO NOT. These release every lock this process
  # holds, so an ordinary exit or a Ctrl-C leaves nothing behind. `SIGKILL`, an
  # OOM kill and the machine going down run no trap, and the lock stays; what
  # covers that is the staleness check in the loop above, not this.
  # EXIT releases only. INT/TERM release AND exit, so a signal arriving between
  # commands in a critical section can't release the lock and then let the script
  # continue into an unprotected config move/write (matters for 2-lock
  # rename-team). NOTE: no current registry writer sets its own trap; a future
  # caller that does must chain these in.
  trap 'agmsg_lock_release' EXIT
  trap 'agmsg_lock_release; exit 130' INT
  trap 'agmsg_lock_release; exit 143' TERM
}

# Forget a lock this process had registered but does not hold.
_agmsg_lock_unhold() {   # <lock>
  local kept="" l
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    [ "$l" = "$1" ] || kept="${kept:+$kept
}$l"
  done <<EOF
${AGMSG_HELD_LOCKS:-}
EOF
  AGMSG_HELD_LOCKS="$kept"
  _agmsg_lock_set_token "$1" ""
}

# WHAT WAS HOLDING IT, in the same breath as the timeout. Since #865 a timeout
# means one of a few things -- a holder that answered as alive, or a lock this
# process could not account for and would not break -- and which one decides
# where the operator looks next. ALIVE AND UNCHECKABLE ARE NOT THE SAME ANSWER:
# saying the first of a lock nothing could ask about puts the operator back
# hunting a process on the strength of a sentence that never checked.
_agmsg_lock_explain_timeout() {   # <lock>
  local lock="$1" q rec=""
  [ -d "$lock" ] || return 0
  _agmsg_lock_judge "$lock" || :
  [ -z "$_J_FILE" ] || rec="$(_agmsg_lock_show "$_J_FILE")"
  case "$_J_VERDICT" in
    alive)
      echo "agmsg: the lock records: $rec" >&2
      echo "agmsg: that process answered as alive, so this was contention." >&2 ;;
    gone)
      echo "agmsg: the lock records: $rec" >&2
      echo "agmsg: that process is not running — the lock was being broken as this wait ended." >&2 ;;
    foreign)
      echo "agmsg: the lock records: $rec" >&2
      echo "agmsg: that record was not written on this machine (or not in this process namespace), so nothing here could ask whether it is held." >&2 ;;
    writer-alive)
      echo "agmsg: the lock records: $rec" >&2
      echo "agmsg: that process is not running, but a writer it started is, so this was contention." >&2 ;;
    unbreakable)
      echo "agmsg: the lock records: $rec" >&2
      echo "agmsg: that process is not running, but the record marks the lock as not to be broken automatically: it may have started a writer that is still running." >&2
      echo "agmsg: check that no agmsg sync is running for this team, then remove the directory by hand." >&2 ;;
    noscope|badpid|malformed|noliveness)
      echo "agmsg: the lock records: $rec" >&2
      echo "agmsg: that record cannot be checked here ($_J_VERDICT), so nothing here could ask whether it is held." >&2 ;;
    nonempty)
      q="$(_agmsg_lock_quote "$lock")"
      echo "agmsg: the lock directory holds no holder record but is not empty, so nothing here could ask whether it is held." >&2
      echo "agmsg: look at what is in it first; if no agmsg command is running for this team, remove it:" >&2
      echo "agmsg:   ls -la $q" >&2
      echo "agmsg:   rm -r $q" >&2
      echo "agmsg: doctor.sh lists such locks." >&2 ;;
    multi)
      echo "agmsg: the lock directory holds more than one holder record, so nothing here could tell which one is current." >&2
      echo "agmsg: doctor.sh lists such locks." >&2 ;;
    *)
      # QUOTED, because this line is meant to be pasted: the store root and the
      # team name can both contain a space. `rmdir` rather than `rm -r`, so the
      # paste cannot remove anything but an empty lock directory.
      q="$(_agmsg_lock_quote "$lock")"
      echo "agmsg: the lock records no holder, so nothing here could ask whether it is held." >&2
      echo "agmsg: a lock with no holder record is not broken automatically. If no agmsg command is running for this team, remove it:" >&2
      echo "agmsg:   rmdir $q" >&2
      echo "agmsg: doctor.sh lists such locks." >&2 ;;
  esac
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
# Per-lock token storage, kept in one newline-separated variable because bash
# 3.2 has no associative arrays and this library targets it.
#
# Format: one "<lock path>\t<token>" per line. The path is matched WHOLE, for
# the reason AGMSG_HELD_LOCKS already documents: lock paths nest, so a substring
# test would let one team's entry answer for another's.
_agmsg_lock_set_token() {
  local path="$1" token="$2" kept="" line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      "$path	"*) ;;
      *) kept="${kept:+$kept
}$line" ;;
    esac
  done <<EOF
${_AGMSG_LOCK_TOKENS:-}
EOF
  _AGMSG_LOCK_TOKENS="${kept:+$kept
}$path	$token"
}

_agmsg_lock_get_token() {
  local path="$1" line
  while IFS= read -r line; do
    case "$line" in
      "$path	"*) printf '%s' "${line#*	}"; return 0 ;;
    esac
  done <<EOF
${_AGMSG_LOCK_TOKENS:-}
EOF
  return 1
}

# Release one lock, and forget its token whatever the outcome: a token that
# outlives its lock would be read as proof of ownership by the next acquire of
# the same path, including one that could not make a token of its own.
_agmsg_lock_drop() {   # <lock> [quiet]
  local _rc=0
  _agmsg_lock_drop_one "$@" || _rc=$?
  _agmsg_lock_set_token "$1" ""
  return "$_rc"
}

_agmsg_lock_drop_one() {   # <lock> [quiet]
  local l="$1" quiet="${2:-}" err="" mine="" staged q
  [ -d "$l" ] || return 0
  # OWNERSHIP FIRST, and it is the token, not the pid (a pid recurs). An empty
  # token means this process never proved ownership of this path -- the entropy
  # to make one was missing -- so it refuses rather than guess.
  mine="$(_agmsg_lock_get_token "$l" || printf '')"
  if [ -z "$mine" ]; then
    [ -n "$quiet" ] || echo "agmsg: not releasing $l — this process cannot prove the lock is its own" >&2
    return 0
  fi
  # The evidence of this generation has to be removed before the directory can
  # go, and that needs `rm`: without it the holder record stays, and so does the lock.
  if ! command -v rm >/dev/null 2>&1 && _agmsg_lock_evidence_present "$l" "$mine"; then
    [ -n "$quiet" ] || echo "agmsg: not releasing $l — it holds writer files and there is no rm to remove them" >&2
    return 1
  fi
  _agmsg_lock_test_hook drop:before-claim "$l"
  # THE CLAIM IS A RENAME OF THIS PROCESS'S OWN RECORD BY ITS EXACT NAME. The
  # directory being at the path this process locked is not evidence that it is the
  # same directory: an operator can remove a stuck lock -- the message below tells
  # them to -- and another process can take the path before this one releases.
  # `mv <lock>/holder.<token>` succeeds only if the directory at that path still
  # holds the record this process published, so it is the ownership check and the
  # claim in one step: no read-then-act gap for a successor to land in. The staged
  # name carries the token too (a pid is not unique across hosts on a shared
  # store, and two releases must not stage onto one name).
  #
  # Moving the record OUT is also what lets `rmdir` succeed, since the record
  # lives inside the directory. `mv` and `rmdir` are both on the minimal PATH this
  # file is required to work on; `rm` is not, and is used only to tidy the staged
  # copy afterwards.
  staged="$l.rel.$mine"
  if ! mv "$l/holder.$mine" "$staged" 2>/dev/null; then
    # Not this process's directory any more, or never published. Gone is a
    # released lock -- nothing to report. A directory with another process's
    # record is that process's lock, and removing it is exactly what this must
    # not do. An EMPTY directory is one this process made and could not record
    # (a signal, a failed publish), or a successor's not yet recorded; removing
    # it is safe either way, because a directory that is only made and not yet
    # recorded is found out by its owner when its publish fails.
    [ -d "$l" ] || return 0
    _agmsg_lock_holder_scan "$l"
    if [ "$_H_COUNT" -eq 0 ]; then
      rmdir "$l" 2>/dev/null || :
    elif [ -z "$quiet" ]; then
      echo "agmsg: not releasing $l — it is held by another process now" >&2
    fi
    return 0
  fi
  _agmsg_lock_test_hook drop:after-claim "$l"
  _agmsg_lock_evidence_clear "$l" "$mine"
  if err="$(rmdir "$l" 2>&1)"; then
    # Best-effort: nothing but the staged copy is left, and it sits under a name
    # no acquirer looks for. `|| :` matters: callers run under `set -e`, and an
    # unguarded failing `rm` after a SUCCESSFUL release would abort the caller
    # right after the lock was correctly let go.
    if command -v rm >/dev/null 2>&1; then rm -f "$staged" 2>/dev/null || :; fi
    return 0
  fi
  # rmdir failed. Gone meanwhile, or a successor's record inside, means this
  # lock is released and what is there is someone else's.
  if [ ! -d "$l" ]; then
    if command -v rm >/dev/null 2>&1; then rm -f "$staged" 2>/dev/null || :; fi
    return 0
  fi
  _agmsg_lock_holder_scan "$l"
  if [ "$_H_COUNT" -gt 0 ]; then
    if command -v rm >/dev/null 2>&1; then rm -f "$staged" 2>/dev/null || :; fi
    return 0
  fi
  # Something else is in the directory, and that is the leak this file's own
  # contract promises not to leave. The record is NOT put back: by the time it
  # could be, the path may belong to a successor, and a record of the previous
  # generation inside it would wedge that one. Who held the lock is said here,
  # where it is needed, and the record stays at its staged name.
  echo "agmsg: could not release the registry lock at $l" >&2
  echo "agmsg: rmdir: $err" >&2
  echo "agmsg: it was held by: $(_agmsg_lock_show "$staged")" >&2
  echo "agmsg: that record is kept at $staged" >&2
  echo "agmsg: until this directory is removed, commands for this team will wait" >&2
  echo "agmsg: for a lock nothing holds." >&2
  # The remedy has to work for the case that produced it. `rmdir` is what just
  # failed -- printing it back is a route that ends where the operator already
  # is. QUOTED, because a printed command is meant to be pasted into a shell: the
  # store root and the team name can both contain a space, and an unquoted path
  # becomes several arguments, and `rm -r` then removes something the operator
  # did not read about. Same scheme as lib/shquote.sh, inline rather than sourced
  # so this library keeps its single-file contract.
  q="$(_agmsg_lock_quote "$l")"
  echo "agmsg: look at what is in it, then remove the directory:" >&2
  echo "agmsg:   ls -la $q" >&2
  echo "agmsg:   rm -r $q" >&2
  echo "agmsg: nothing but this lock lives in there — it holds no team data." >&2
  return 1
}

agmsg_lock_release_one() {
  local lock="$1/.config.lock" kept="" l
  [ -n "${AGMSG_HELD_LOCKS:-}" ] || return 0
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    if [ "$l" = "$lock" ]; then
      # `|| true` here does NOT swallow the failure: `_agmsg_lock_drop` has
      # already reported it on stderr. What it does is keep the loop going, so
      # one stuck lock does not strand the others this process holds — the
      # opposite of the `rmdir … || true` this file replaced, where the failure
      # had nowhere else to appear.
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
    # Reported inside the helper; `|| true` only keeps the loop alive so one
    # stuck lock cannot strand the rest. See the note in release_one.
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
# Best effort, and said out loud rather than assumed: `rm` is NOT on the PATH
# that `join` is required to work under, so on that path a failed write leaves
# its temp behind. The temp is 0600 and holds no more than the destination
# would have, so what is lost is tidiness, not privacy -- and this is the one
# place in here allowed to shrug, because it runs only after a failure that has
# already been reported.
_agmsg_discard_temp() {
  if command -v rm >/dev/null 2>&1; then
    rm -f "$1"
  fi
}

# Remove what a failed attempt left, and NEVER let the removal speak for the
# attempt.
#
# Both commands are neutralised with `|| :`. Many of this repository's scripts
# run under `set -e`, where a `rmdir` that fails on a directory it could not
# empty aborts the shell BEFORE the caller's diagnostic is printed and before
# its `return 1` -- turning a named failure into a silent exit. Cleanup is
# allowed to fail here. It is not allowed to decide (#804, raised in review).
_agmsg_cleanup_attempt() {
  _agmsg_discard_temp "$1" || :
  rmdir "$2" 2>/dev/null || :
}

# SAID, NOT SWALLOWED (#802). On the PATH `join` is required to work under there
# is no `rm`, so a failed write cannot be removed and the directory holding it
# cannot be removed either. What survives is 0700 with a 0600 file inside --
# privacy intact, tidiness not -- and the operator is told WHERE in the same
# breath as the failure rather than finding it later.
_agmsg_say_residue() {
  if [ -d "$1" ]; then
    printf 'agmsg: a private copy of the failed attempt is left in %s\n' "$1" >&2
  fi
}

agmsg_write_atomic() {
  local dest="$1" content="$2" tmp
  # The temp is CREATED, never adopted, using only what the minimal PATH
  # guarantees: `umask` and `printf` from the shell, and `mkdir`, `mv` and
  # `rmdir`, which are on that list. It said "only shell builtins" while calling
  # three external commands -- true of a revision that used `noclobber`, and
  # contradicted twelve lines further down by the paragraph explaining why
  # `mkdir` and `rmdir` are safe to depend on.
  #
  # `> "$dest.tmp.$$"` onto a file a killed run left behind only truncates it:
  # the redirect does not touch the mode, and `umask` applies to creation, so
  # the content would exist at whatever that leftover was set to. For a binding
  # that is a disclosure -- `remote_binding.endpoint` is the credential on a
  # hosted deployment (#804).
  #
  # `mktemp` would solve it and CANNOT BE USED HERE. `join` is required to work
  # on a PATH that carries only bash, dirname, sqlite3, sed, date, mkdir, rmdir,
  # cat, mv, head, od, tr, sort, basename and paste -- there is a test for it,
  # and it caught the first attempt at this fix. `chmod` is not on that list
  # either; the version before this one called it and only survived because its
  # failure was ignored.
  #
  # So: `umask`, plus `mkdir` and `rmdir`, which that list does carry. An
  # earlier revision of this fix used `noclobber` (`set -C`) to refuse an
  # existing file; that is gone, and the paragraph describing it went with it,
  # because a comment that explains a primitive the code no longer uses is read
  # as enforcement by whoever arrives next. What replaced it is below: the temp
  # lives inside a directory this call created, and the name carries $RANDOM so
  # a leftover does not block the write forever.
  #
  # 0600 applies to every caller of this helper -- team configs, roster
  # journals, the codex port file, migrations. That is deliberate: it is how
  # this product already treats its own state (`key.sh`, the handoff bundle).
  # THE TEMP LIVES IN A DIRECTORY THIS CALL MADE, and that is the whole point.
  #
  # Two earlier shapes were refused by review, and the second one is why this is
  # a directory:
  #
  #   - creating the temp empty under `set -C` and then opening `$tmp` AGAIN to
  #     write it. The second open resolves the name a second time, so what the
  #     exclusive creation established could be replaced in between. An
  #     exclusive create whose result is reached BY NAME is not exclusive.
  #
  #   - merging those into one `>` and testing `[ -e ]` first. That test is a
  #     filter and not a guarantee -- which the comment said -- and then the
  #     failure branch removed `$tmp` on the reading that this process must have
  #     made it. When the loser of a real race takes that branch, the file it
  #     removes belongs to the WINNER. `$$` does not rescue the reasoning: a
  #     subshell shares its parent's pid, so two concurrent calls in one process
  #     tree draw from the same `$$.$RANDOM` space. The removal was the defect,
  #     not the detection.
  #
  # `mkdir` answers both. It is atomic, it fails rather than joining an existing
  # directory, and its SUCCESS is the proof of ownership that `[ -e ]` could
  # never be: everything inside belongs to this call, so the payload is written
  # into a name nothing else can be holding, and removing that name cannot
  # remove anyone else's. It is the same primitive this file already trusts for
  # the registry lock, for the same reason.
  #
  # `mkdir` and `rmdir` are both on the PATH `join` is required to work under --
  # checked, because that list is what ruled out `mktemp` and `chmod`.
  local attempts=0 tmpdir
  while :; do
    tmpdir="$dest.tmp.$$.$RANDOM.d"
    if ( umask 077; mkdir "$tmpdir" ) 2>/dev/null; then
      break
    fi
    # Taken, by anyone, for any reason: draw another name. Nothing is removed
    # here, because nothing here was created.
    attempts=$((attempts + 1))
    if [ "$attempts" -ge 32 ]; then
      printf 'agmsg: could not create a private temporary directory beside %s\n' "$dest" >&2
      return 1
    fi
  done
  tmp="$tmpdir/new"

  # 0700 on the directory and 0600 on the file. The content is written once,
  # into a fresh name inside a directory only this call can enter.
  if ! ( umask 077; printf '%s\n' "$content" > "$tmp" ) 2>/dev/null; then
    _agmsg_cleanup_attempt "$tmp" "$tmpdir"
    printf 'agmsg: could not write the new contents for %s\n' "$dest" >&2
    _agmsg_say_residue "$tmpdir"
    return 1
  fi

  # The `mv` is what makes a reader see the whole new file or the whole old one.
  # The gate above is what makes the CONTENT whole: a `printf` that wrote half
  # the payload and then failed would otherwise be published, indivisibly, as
  # the truncated destination.
  if ! mv "$tmp" "$dest"; then
    _agmsg_cleanup_attempt "$tmp" "$tmpdir"
    printf 'agmsg: could not move the new contents into place at %s\n' "$dest" >&2
    _agmsg_say_residue "$tmpdir"
    return 1
  fi

  # PUBLISHED. EVERYTHING BELOW IS TIDYING, AND TIDYING DOES NOT GET A VOTE.
  #
  # This function used to end on a bare `rmdir`, so the status of the tidy-up
  # became the status of the write: a `rmdir` that failed after a `mv` that
  # succeeded returned non-zero, and the caller treated a committed write as a
  # failure. That needs no `set -e` to happen -- the last command's status is
  # the function's -- and under `set -e` it is worse, because the caller aborts
  # on a write that in fact landed. Review named it (#804).
  #
  # So the removal is checked, its failure is SAID rather than swallowed (#802),
  # and the return is explicit and unconditional. After a successful `mv` the
  # directory is empty and 0700, so a failure here is close to impossible; if it
  # happens, what leaks is an empty private directory, and the operator is told
  # which one rather than left to find it.
  if ! rmdir "$tmpdir" 2>/dev/null; then
    printf 'agmsg: wrote %s, but could not remove the temporary directory %s\n' "$dest" "$tmpdir" >&2
  fi
  return 0
}
