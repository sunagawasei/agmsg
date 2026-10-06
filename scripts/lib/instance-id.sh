#!/usr/bin/env bash
# instance-id.sh — per-process runtime instance identity.
#
# A Claude Code `session_id` is NOT unique across parallel
# `claude --continue` / `--resume` processes (#93): the second process re-fires
# SessionStart with the *original* session_id, so two live processes claim to
# be the same session. Keying watcher/lock state (pidfile, watermark, actas
# owner) on session_id alone makes those two processes collide — most visibly
# the watch.sh "kill the previous holder for this session" logic (#66) turns
# into a mutual kill loop.
#
# We disambiguate by composing the session_id with the enclosing agent process
# pid, which IS unique per live process. The resulting "instance id":
#   - is stable across /clear within one agent process (sid + pid unchanged),
#     so the #66 dedup-on-relaunch still works;
#   - differs between parallel resume processes (different pid), so their
#     pidfile / watermark / actas owner stop colliding.
#
# Token shape:
#   "<session_id>.<pid>"   composite — pid is the enclosing agent process
#   "<session_id>"         bare — fallback when the agent pid can't be resolved
#                          (detached watcher, sandboxed ps, non-agent wrapper)
#
# session_ids are UUIDs / "agmsg-<...>" / "unknown-<pid>" — none contain a '.',
# so "last dot-segment is numeric" unambiguously marks the composite form.
#
# Requires: SKILL_DIR set. agmsg_instance_id / agmsg_normalize_instance_id
# additionally require resolve-project.sh sourced (for agmsg_agent_pid);
# agmsg_instance_alive and the pure helpers do not.

# Guard against double-source (these are sourced transitively via actas-lock.sh
# and directly by entry-point scripts).
[ -n "${_AGMSG_INSTANCE_ID_SH:-}" ] && return 0
_AGMSG_INSTANCE_ID_SH=1

# For _agmsg_detect_platform / _agmsg_platform, used below by
# _agmsg_pid_alive_local's MSYS branch. compat.sh has no include guard of its
# own (several other libs already source it unconditionally the same way;
# re-sourcing only resets the cheap, deterministic platform detection, not
# any state that matters).
# Located with builtins only: this file is sourced on PATHs without dirname, and
# a failed source here leaves _agmsg_detect_platform undefined.
_AGMSG_IID_SELF="${BASH_SOURCE[0]:-$0}"
case "$_AGMSG_IID_SELF" in
  */*) _AGMSG_IID_DIR="${_AGMSG_IID_SELF%/*}" ;;
  *) _AGMSG_IID_DIR="." ;;
esac
# shellcheck disable=SC1091
. "$_AGMSG_IID_DIR/compat.sh"

# Cross-platform pid liveness check, and the ONLY one any shipped script should
# use. A bare `kill -0 "$pid" 2>/dev/null` is not a liveness check: it answers
# "can I signal this", and the two differ exactly where it matters.
#
# Git Bash's kill(1) only sees MSYS2/Cygwin PIDs; native Windows processes
# (Claude Code, etc.) are invisible to it, so kill -0 always returns false for
# them (#134). On Windows we fall back to tasklist.exe, which queries the native
# process table.
#
# Everywhere else, saying "dead" requires kill(2) and ps to agree. A failed
# `kill -0` is ESRCH (dead) or EPERM (alive, but not signalable by us — a
# sandbox does exactly this). Reading only the exit status reports a live
# process as gone, which is how a running watcher or bridge gets printed as a
# stale pidfile, how a live lock owner gets its lock reclaimed out from under
# it, and how a second app-server gets started beside the first.
# True iff <value> is a plain positive decimal pid, i.e. a value that names one
# process when handed to kill(1).
#
# Digits-only is NOT enough. `kill -0 0` does not ask about pid 0 — 0 means "the
# caller's own process group" — so it succeeds, and a caller that then runs
# `kill "$pid"` TERMs the whole group, itself included. A corrupt or hostile
# pidfile holding 0 is all it takes. A leading zero is rejected for a related
# reason: nothing here writes one, and kill(1) may read it as octal, so it names
# an unpredictable process.
#
# Patterns only, never `$(( ))`: arithmetic evaluation runs its argument.
#
# Split out from _agmsg_pid_alive so a caller that kills a recorded pid WITHOUT
# asking about liveness first can still refuse the values that do not name one
# process.
# A ceiling may be passed as $2 to override the platform's. Which one is right is
# a property of what the value will be USED for, not of the host -- see the call
# in _agmsg_pid_alive_local, which hands the value to kill(1) even on Windows.
_agmsg_pid_valid() {
  local pid="${1:-}" max="${2:-}"
  case "$pid" in ''|*[!0-9]*|0*) return 1 ;; esac
  if [ -n "$max" ]; then
    [ "${#pid}" -le 10 ] || return 1
    if [ "${#pid}" -eq 10 ] && [ "$pid" \> "$max" ]; then return 1; fi
    return 0
  fi
  max=2147483647
  # The upper bound is the platform's, not one number. A Windows process id is a
  # DWORD, and the liveness path there queries the native process table via
  # tasklist rather than kill(1)'s signed pid_t — applying the POSIX bound to it
  # would call a legitimate native pid dead and its live watcher stale.
  case "${MSYSTEM:-}" in MINGW*|MSYS*|CLANGARM*) max=4294967295 ;; esac
  # And it has to fit whichever of those the platform uses. The POSIX ceiling is
  # what makes the rest of this library safe: past INT32_MAX, kill(1) rejects the
  # ARGUMENT ("not a pid or valid job spec") rather than reporting ESRCH — and
  # _agmsg_pid_alive reads every non-ESRCH failure as alive, so an oversized
  # value in a pidfile would read as alive forever: its lock never reclaimed, its
  # bridge never restarted, its status line permanently wrong. Bounding the input
  # is what keeps "not ESRCH" meaning "EPERM". The Windows ceiling is a plain
  # range check on the value tasklist will be asked about; nothing there parses
  # it as a signal target.
  #
  # Length is a builtin, and the digits are already known to have no leading
  # zero, so at equal length a STRING compare is the numeric one. No `$(( ))`
  # and no `-gt` on the untrusted value: both evaluate what they are given.
  [ "${#pid}" -le 10 ] || return 1
  if [ "${#pid}" -eq 10 ] && [ "$pid" \> "$max" ]; then return 1; fi
  return 0
}

# Liveness for a pid THIS codebase minted: $! or $$ in one of these shells, or
# read back from a pidfile one of them wrote. A pidfile does not launder the pid
# space -- the number in it is still whatever the shell that wrote it was given.
#
# Under Git Bash such a pid is numbered in the MSYS space, which `tasklist` does
# not report, so the Windows branch in _agmsg_pid_alive must not run for one:
# asking tasklist about an MSYS pid answers "dead" for a process that is running,
# which is how every Windows codex launch lost its bridge (#567).
#
# The EPERM reading and the ps cross-check are the same as _agmsg_pid_alive's --
# a pid we minted is still a pid a sandbox may refuse to let us signal (#505).
_agmsg_pid_alive_local() {
  local pid="$1" err stat probe rc canary tstat _p _s _rest
  # The POSIX ceiling, explicitly, whatever the host. _agmsg_pid_valid widens to
  # the DWORD range when MSYSTEM is set, which is right for a number tasklist
  # will be asked about and wrong for one kill(1) will parse: past INT32_MAX kill
  # rejects the ARGUMENT rather than reporting ESRCH, and everything below that
  # is not ESRCH reads as alive. Inheriting the wide ceiling here would put an
  # oversized pidfile value back to alive forever -- the shape #505 closed.
  _agmsg_pid_valid "$pid" 2147483647 || return 1
  # Fast path, and the common answer: the builtin, no fork. Callers poll this in
  # loops whose whole point is to be fork-free (#466), so the alive case must
  # not cost a subshell.
  kill -0 "$pid" 2>/dev/null && return 0
  # Only now pay for the error text. `export LC_ALL=C` (not a bare prefix, which
  # misses the builtin on bash 3.2) forces English for the match below.
  err="$(export LC_ALL=C; kill -0 "$pid" 2>&1)" && return 0
  case "$err" in
    *[Nn]'o such process'*) ;;
    *) return 0 ;;   # EPERM and anything unrecognised mean "assume alive"
  esac
  # kill(2) says gone. ps does not depend on signalling permission at all, so
  # requiring it to agree is what keeps a sandbox from turning "cannot signal"
  # into "not running" (#505). But an EMPTY ps result is NOT proof of death: a
  # transient ps failure and a truly-absent pid both produce nothing, and reading
  # that as "gone" is #954 -- callers delete files, release locks, and respawn on
  # it. Distinguish "proof of absence" from "absence of proof". Which technique
  # does that split by platform (#970 Windows follow-up): MSYS ps has no -o, so
  # the whole-table-snapshot-plus-canary approach below cannot run there at all;
  # _agmsg_detect_platform reads real uname(1) output, not the spoofable
  # MSYSTEM env var, so this only takes the MSYS branch on an actual MSYS host.
  _agmsg_detect_platform
  # shellcheck disable=SC2154  # set by compat.sh's _agmsg_detect_platform, sourced above
  case "$_agmsg_platform" in
    msys)
      # _agmsg_pid_gone_msys's own convention (0 = yes, gone) is the
      # inverse of this function's (0 = alive) -- branch explicitly rather
      # than propagating $? and hoping the two conventions happen to
      # cancel out.
      if _agmsg_pid_gone_msys "$pid"; then return 1; else return 0; fi
      ;;
  esac
  # Co-observe a known-live pid -- our own $$ -- in the SAME observation. Take
  # a FULL snapshot (no -p filter, so the target pid is never handed to ps and
  # cannot poison the query, e.g. macOS "process id too large"), parsed with
  # builtins so only ps is external and a stripped PATH cannot itself become
  # the failed observation:
  #   - $$ absent from the snapshot => ps produced nothing usable => UNKNOWN =>
  #     assume alive, exactly as the EPERM branch above. A failed observation is
  #     not proof of absence.
  #   - $$ present, target absent  => ps listed us and did not list the target =>
  #     positive proof the target is gone => dead.
  #   - target present, zombie     => gone too.
  # `|| rc=$?` keeps the assignment out of set -e's reach: a command-substitution
  # assignment returns the substituted command's exit status as its OWN, so under
  # errexit in a caller that did NOT invoke us as a condition, a non-zero ps would
  # terminate the shell right here -- leaking a failed observation to caller death
  # instead of the UNKNOWN => alive verdict below. The leaf helper's contract must
  # not depend on how the caller spelled the call.
  rc=0
  probe="$(ps -Ao pid=,stat= 2>/dev/null)" || rc=$?
  canary=0; tstat=""
  # IFS=$' \t' on the read, not inherited from the caller: this function is
  # called from inside `IFS=$'\t' read ... < <(...)` (cmd_sync_start's own
  # engine-status read), and that IFS leaks into the process substitution's
  # subshell -- everything run inside it, this loop included, otherwise reads
  # under a tab-only IFS. A tab-only IFS cannot split ps's space-separated
  # `pid= stat=` columns, so every line (including our own canary line) fails
  # to parse, canary stays 0 even in a complete listing, and the UNKNOWN path
  # below reads that as alive -- a genuinely dead engine then reports as
  # running (#970). The read that decides liveness must not depend on
  # whatever IFS happened to be in scope when it was called.
  while IFS=$' \t' read -r _p _s _rest; do
    if [ "$_p" = "$$" ]; then canary=1; fi
    if [ "$_p" = "$pid" ]; then tstat="${_s:-?}"; fi
  done <<PROBE
$probe
PROBE
  if [ -n "$tstat" ]; then
    case "$tstat" in Z*) return 1 ;; esac  # zombie: exited, not yet reaped
    return 0                                # target present -> alive (seeing it is proof enough)
  fi
  # Target not listed. Trust "absent" ONLY when ps COMPLETED the snapshot (exit 0)
  # AND that snapshot included our own $$. A non-zero exit means the listing was
  # truncated -- ps can print part of it (even our own line) and then fail -- and a
  # pid that would have come later proves nothing; canary presence shows only that
  # WE were listed, never that the listing FINISHED. Anything short of a complete,
  # self-including snapshot is UNKNOWN -> assume alive (#954), which also fails safe
  # where "ps -Ao" is unsupported (it exits non-zero rather than lying "gone").
  if [ "$rc" -eq 0 ] && [ "$canary" = 1 ]; then return 1; fi
  return 0
}

# MSYS counterpart of the POSIX whole-table-snapshot-plus-canary technique
# above, for _agmsg_pid_alive_local only. `ps -Ao pid=,stat=` is not available
# under MSYS2's ps (no -o support, scripts/lib/compat.sh's own header
# comment).
#
# #970's first attempt at this queried `ps -l -p PID` (pid-filtered) instead
# -- the same primitive compat_get_ppid/_compat_get_winpid already use for a
# LIVE pid, but never measured against a DEAD one before this. Measured live
# on real Windows Git Bash (2026-09-23): a dead pid makes `ps -l -p` exit 1,
# header line and all -- so requiring rc=0 before trusting absence (#954's
# own rule, correctly applied) made the dead case UNREACHABLE, permanently.
# The Windows CI hang this was meant to close never actually closed, because
# the query could never satisfy its own proof condition.
#
# The fix is the query, not the rule. `ps -l` with NO -p filter behaves like
# the POSIX `ps -Ao` snapshot: it exits 0 and lists every process, including
# our own -- so the SAME canary technique applies. Measured header (real
# Windows Git Bash, 2026-09-23): `PID PPID PGID WINPID TTY UID STIME
# COMMAND` -- PID is the list's own first column ordinarily; WINPID is a
# different number (the native Windows pid) and must never be read here. No
# process-state column exists in this shape, so unlike the POSIX branch
# above, a zombie cannot be told apart from a live process here -- out of
# scope for what #970 needs (a genuinely-exited pid, which the CI hang could
# never detect at all).
#
# review: Cygwin/MSYS `ps -l` documents an optional single-character state
# flag (S/I/O) that some rows -- not all, and not reflected in the header at
# all -- get PREPENDED as an extra leading field, pushing PID to the second
# column on exactly those rows. Reading column 1 unconditionally means a
# flagged row's real PID is never matched: an unflagged self row still
# proves the canary, so a flagged but genuinely LIVE target row reads as
# "absent" -- a live process misread as dead, #954's own failure shape.
# Fixed-width reading was considered and rejected: the flag is not a
# declared column at all, so there is no header position to key a fixed
# width on; detecting the flag value itself is the only thing that is
# actually documented.
#
#   - ps fails (rc != 0)                => UNKNOWN => caller reads as alive.
#   - rc = 0, but no row's PID field is our own $$ => the listing cannot be
#     trusted as complete (same canary logic as the POSIX branch) =>
#     UNKNOWN => alive.
#   - rc = 0, our own row present, target's row absent => positive proof of
#     death.
#   - rc = 0, our own row present, target's row also present => alive.
# A normal shell predicate: returns 0 (success) when the pid is proven gone,
# 1 otherwise (alive or unknown) -- `if _agmsg_pid_gone_msys ...; then` reads
# naturally. This is the OPPOSITE sense of _agmsg_pid_alive_local's own
# 0-means-alive convention, which is why the caller above branches on it
# explicitly instead of returning it straight through.
_agmsg_pid_gone_msys() {
  local pid="$1" out rc=0 verdict
  # `|| rc=$?` keeps the assignment out of set -e's reach, same reason the
  # POSIX snapshot above does this.
  out="$(ps -l 2>/dev/null)" || rc=$?
  [ "$rc" -eq 0 ] || return 1
  # awk's own field splitting, not the caller's IFS -- #970's original bug
  # was exactly a parse that silently inherited an ambient IFS it was never
  # written to expect; this reads each non-header row itself, with nothing
  # shell-side to leak into.
  verdict="$(printf '%s\n' "$out" | awk -v self="$$" -v want="$pid" '
    NR == 1 { next }
    {
      # A row whose first field is exactly one documented flag letter has
      # PID pushed to the next field -- a real pid is always numeric, so
      # this never misreads an actual pid value as the flag.
      p = ($1 ~ /^[SIO]$/) ? $2 : $1
      if (p == self) canary = 1
      if (p == want) found = 1
    }
    END {
      if (!canary) { print "unknown"; exit }
      print (found ? "alive" : "gone")
    }
  ')"
  [ "$verdict" = gone ]
}

# Liveness for a pid that came from OUTSIDE these shells -- reached by walking
# ancestors until the walk leaves the MSYS subsystem, so under Git Bash the
# number is a Windows pid and kill(1) there cannot see it at all (#134).
#
# Which of the two applies is decided by where the pid was minted, not by whether
# it arrived through a pidfile. For anything $! or $$ produced, and anything read
# back from a pidfile one of these shells wrote, use _agmsg_pid_alive_local.
_agmsg_pid_alive() {
  local pid="$1"
  _agmsg_pid_valid "$pid" || return 1
  case "${MSYSTEM:-}" in
    MINGW*|MSYS*|CLANGARM*)
      MSYS_NO_PATHCONV=1 tasklist /FI "PID eq $pid" 2>/dev/null | grep -q "$pid"
      return $?
      ;;
  esac
  _agmsg_pid_alive_local "$pid"
}

# Print a process-generation token that changes when a PID is reused. Linux's
# procfs starttime is preferred because it is a kernel tick counter and does not
# depend on wall-clock formatting. Other POSIX hosts use ps(1)'s full start
# timestamp. Git Bash may need PowerShell to inspect a native Windows process.
# Failure is deliberately distinct from "dead": callers that authorize
# teardown must fail closed when no generation token can be obtained.
agmsg_pid_start_token() {
  local pid="$1" line rest value=""
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ "$pid" -gt 0 ] 2>/dev/null || return 1

  if [ -r "/proc/$pid/stat" ]; then
    line="$(LC_ALL=C sed -n '1p' "/proc/$pid/stat" 2>/dev/null)" || return 1
    # comm is parenthesized and may contain spaces or ')'. Strip through the
    # final ") "; the remaining field 20 is proc stat field 22 (starttime).
    rest="${line##*) }"
    value="$(printf '%s\n' "$rest" | LC_ALL=C awk '{print $20}')"
    case "$value" in ''|*[!0-9]*) return 1 ;; esac
    printf 'proc:%s\n' "$value"
    return 0
  fi

  case "${MSYSTEM:-}" in
    MINGW*|MSYS*|CLANGARM*)
      if command -v powershell.exe >/dev/null 2>&1; then
        value="$(powershell.exe -NoProfile -NonInteractive -Command \
          '$p = Get-Process -Id ([int]$args[0]) -ErrorAction Stop; $p.StartTime.ToUniversalTime().Ticks' \
          "$pid" 2>/dev/null | tr -d '\r[:space:]')" || return 1
        case "$value" in ''|*[!0-9]*) return 1 ;; esac
        printf 'windows:%s\n' "$value"
        return 0
      fi
      ;;
  esac

  value="$(TZ=UTC LC_ALL=C ps -o lstart= -p "$pid" 2>/dev/null \
    | LC_ALL=C sed -n '1{s/^[[:space:]]*//;s/[[:space:]]*$//;p;}')" || return 1
  [ -n "$value" ] || return 1
  printf 'ps:%s\n' "$value"
}

# Print the acquisition method encoded in a process-generation token. Callers
# must never interpret a change of method as evidence that the process changed.
agmsg_pid_start_token_method() {
  case "${1:-}" in
    proc:*) printf 'proc\n' ;;
    windows:*) printf 'windows\n' ;;
    ps:*) printf 'ps\n' ;;
    *) return 1 ;;
  esac
}

# Compose from an explicit pid. Bare sid when pid is empty/non-numeric.
agmsg_instance_id_from_pid() {
  local sid="$1" pid="$2"
  case "$pid" in
    ''|*[!0-9]*) printf '%s' "$sid" ;;
    *)           printf '%s.%s' "$sid" "$pid" ;;
  esac
}

# True iff <token> is composite "<sid>.<pid>": a non-empty prefix, a '.', and
# an all-digits suffix.
agmsg_instance_is_composite() {
  local token="$1"
  case "$token" in
    *.*) ;;
    *) return 1 ;;
  esac
  local pid="${token##*.}" prefix="${token%.*}"
  [ -n "$prefix" ] || return 1
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

# Extract the bare session_id from an instance id <token>: strips the trailing
# ".<pid>" of a composite "<sid>.<pid>"; a bare "<sid>" is returned unchanged.
# The bare sid is the identity that is STABLE across resume generations (the
# enclosing pid changes on each resume, the session_id does not), so role→
# session records key on it rather than on the composite instance id — see
# role-session.sh.
agmsg_instance_bare_sid() {
  local token="$1"
  if agmsg_instance_is_composite "$token"; then
    printf '%s' "${token%.*}"
  else
    printf '%s' "$token"
  fi
}

# Derive an instance id for <session_id> from the enclosing agent <type>.
# Resolves the agent pid via agmsg_agent_pid; on failure falls back to the bare
# session_id and emits a one-line stderr warning. The fallback is a known
# degraded mode: if one entry point (e.g. the Bash tool path) resolves the pid
# while another (e.g. the Monitor persistent command) cannot, their tokens
# diverge — the warning makes that split traceable in logs.
agmsg_instance_id() {
  local sid="$1" type="$2" pid=""
  pid="$(agmsg_agent_pid "$type" 2>/dev/null || true)"
  if [ -z "$pid" ]; then
    printf 'agmsg: instance-id falling back to bare session_id (agent pid unresolved for type=%s); parallel --continue/--resume isolation is degraded\n' "$type" >&2
    printf '%s' "$sid"
    return 0
  fi
  agmsg_instance_id_from_pid "$sid" "$pid"
}

# Idempotent normalize: a token already in composite form is returned as-is; a
# bare session_id is upgraded via agmsg_instance_id. This is the single entry
# point every script calls on its raw first/owner argument, so a script handed
# a pre-computed instance id (hook/monitor path) does not re-derive, while a
# script handed a bare session_id (template path) self-derives.
agmsg_normalize_instance_id() {
  local token="$1" type="$2"
  if agmsg_instance_is_composite "$token"; then
    printf '%s' "$token"
    return 0
  fi
  agmsg_instance_id "$token" "$type"
}

# The instance cc-instance.<pid> currently names, read strictly enough to
# authorize a destructive decision (worker teardown), not just a comparison.
#   rc 0  prints the token: a regular file holding exactly one line
#         "<bare sid>.<pid>" for this very pid
#   rc 1  no such file
#   rc 2  something is there but is not that: a symlink (dangling included), a
#         directory, an unreadable file, extra lines/NULs/whitespace, a dotted
#         sid, another pid
# Callers treat rc 1 and rc 2 alike ("no instance-level evidence") and keep the
# owner; they are separate codes so a caller can say which one it saw.
agmsg_cc_instance_current() {   # <pid>
  local pid="$1" f current
  case "$pid" in ''|*[!0-9]*) return 2 ;; esac
  f="$SKILL_DIR/run/cc-instance.$pid"
  if [ ! -e "$f" ] && [ ! -L "$f" ]; then return 1; fi
  [ -f "$f" ] && [ ! -L "$f" ] || return 2
  current="$(cat "$f" 2>/dev/null)" || return 2
  case "$current" in
    ''|*[!A-Za-z0-9._-]*|.*|*..*) return 2 ;;
  esac
  # command substitution drops NULs and extra trailing newlines; the file must
  # be exactly the value plus one newline.
  [ "$(LC_ALL=C wc -c < "$f" 2>/dev/null | tr -d '[:space:]')" = "$((${#current} + 1))" ] \
    || return 2
  [ "${current%.*}" != "$current" ] || return 2
  case "${current%.*}" in *.*) return 2 ;; esac
  [ "${current##*.}" = "$pid" ] || return 2
  printf '%s' "$current"
}

# True iff <token> identifies a still-live instance.
#   composite "<sid>.<pid>" → the embedded pid is alive (kill -0), AND, when a
#                            cc-instance.<pid> record exists for that pid, its
#                            content still names this exact token. A shared pid
#                            (the Claude Code 2.1.x daemon, #349) can outlive
#                            the specific session that derived this token —
#                            session-start.sh's dedup overwrites cc-instance.
#                            <pid> with the newest attaching token, so a stale
#                            token's kill-0-only check would otherwise report
#                            "alive" forever via the shared pid. A host with no
#                            record is alive on pid alone; only lock-less codex
#                            is one today, so revisit before codex takes a lock.
#   bare "<sid>"            → some live cc-instance.<p> file references it. For
#                            upgrade compatibility a cc-instance whose content
#                            is either exactly "<sid>" or the composite
#                            "<sid>.<numeric>" counts — a pre-upgrade lock holds
#                            a bare sid while cc-instance may already store the
#                            composite, and we must not stale it out instantly.
agmsg_instance_alive() {
  local token="$1"
  [ -n "$token" ] || return 1
  if agmsg_instance_is_composite "$token"; then
    local pid="${token##*.}"
    _agmsg_pid_alive "$pid" || return 1
    local f s
    f="$SKILL_DIR/run/cc-instance.$pid"
    [ -f "$f" ] || return 0
    s="$(cat "$f" 2>/dev/null || true)"
    [ "$s" = "$token" ] && return 0
    return 1
  fi
  local run f p s
  run="$SKILL_DIR/run"
  [ -d "$run" ] || return 1
  for f in "$run"/cc-instance.*; do
    [ -f "$f" ] || continue
    p=${f##*.}
    case "$p" in ''|*[!0-9]*) continue ;; esac
    _agmsg_pid_alive "$p" || continue
    s="$(cat "$f" 2>/dev/null || true)"
    [ "$s" = "$token" ] && return 0
    # upgrade compat: cc-instance stores "<sid>.<pid>" but the lock holds "<sid>"
    if agmsg_instance_is_composite "$s" && [ "${s%.*}" = "$token" ]; then
      return 0
    fi
  done
  return 1
}
