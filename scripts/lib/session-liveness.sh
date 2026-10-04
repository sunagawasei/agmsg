#!/usr/bin/env bash
# session-liveness.sh — are there OTHER live instances of a non-Claude host
# session, judged only from positive evidence?
#
# A Claude Code session publishes run/cc-instance.<pid> (the pid is resolved from
# its process tree) and agmsg_instance_alive reads that. A Cursor session may
# have no resolvable agent pid, so no cc-instance; the evidence it does leave is
# its inject-watch (a leased, owner-verified process keyed by instance id) and,
# when the pid did resolve, the same cc-instance record. This reports one of:
#   alive    some other instance is positively live
#   unknown  evidence exists but cannot be verified (callers must hold)
#   dead     evidence exists and every record is positively dead
#   none     no evidence of any other instance
# Callers act (tear down) only on dead or none, and only when the owner they are
# acting for is already proven dead: absence of evidence never overrides that.
# A reused pid or an unverifiable lease is never read as dead.
#
# Requires SKILL_DIR, instance-id.sh and process-identity.sh to be sourced.

agmsg_session_peers_state() {
  local bare="$1" exclude="${2:-}" run="$SKILL_DIR/run" f iid content pid st
  local any_alive=0 any_unknown=0 any_dead=0
  [ -n "$bare" ] || { printf 'unknown'; return 0; }

  for f in "$run/inject-watch.$bare.pid" "$run"/inject-watch."$bare".[0-9]*.pid; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    iid="${f##*/inject-watch.}"; iid="${iid%.pid}"
    [ -z "$exclude" ] || [ "$iid" != "$exclude" ] || continue
    if [ -L "$f" ]; then any_unknown=1; continue; fi
    agmsg_process_identity_state inject-watch "$f" "" || true
    case "$AGMSG_PROCESS_STATE" in
      owned|held-unverified|unverified-live|degraded-live|legacy-exact-live) any_alive=1 ;;
      stale|legacy-dead|degraded-dead|unverified-dead|legacy-foreign-live) any_dead=1 ;;
      *) any_unknown=1 ;;
    esac
  done

  for f in "$run"/cc-instance.*; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    pid="${f##*.}"
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    content="$(cat "$f" 2>/dev/null || true)"
    case "$content" in
      "$bare"|"$bare".[0-9]*) ;;
      *) continue ;;
    esac
    [ -z "$exclude" ] || [ "$content" != "$exclude" ] || continue
    if _agmsg_pid_alive "$pid"; then any_alive=1; else any_dead=1; fi
  done

  if [ "$any_alive" -eq 1 ]; then printf 'alive'
  elif [ "$any_unknown" -eq 1 ]; then printf 'unknown'
  elif [ "$any_dead" -eq 1 ]; then printf 'dead'
  else printf 'none'
  fi
}
