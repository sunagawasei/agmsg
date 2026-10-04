#!/usr/bin/env bash
# session-retention.sh — message retention for finished session teams (s-<uuid>).
#
# The TTL GC in session-start.sh removes a dead session team's dir; this file
# removes that team's rows from the sqlite event log once they are older than
# delivery.message_retention_days. A team is eligible only when it carries
# proof it was a session team: teams/<team>/session-team (written when
# session-start created the dir) or run/session-tombstone.<team> (left when the
# dir was reaped). A name shaped like s-<uuid> is never enough on its own.
#
# Caller must have SKILL_DIR, RUN_DIR and SCRIPT_DIR set and storage.sh,
# team-lifecycle.sh, instance-id.sh, inflight.sh, pending-teardown.sh sourced.

agmsg_retention_days() {
  local d
  d="$("$SCRIPT_DIR/config.sh" get delivery.message_retention_days 7 2>/dev/null || echo 7)"
  case "$d" in ''|*[!0-9]*) d=7 ;; esac
  printf '%s' "$d"
}

# The delete below is sqlite SQL; another active storage driver would leave the
# real data untouched while the sweep reported success.
agmsg_retention_supported() {
  [ "$(agmsg_storage_driver 2>/dev/null || echo sqlite)" = sqlite ]
}

agmsg_retention_marker_path()    { printf '%s/teams/%s/session-team' "$SKILL_DIR" "$1"; }
agmsg_retention_tombstone_path() { printf '%s/run/session-tombstone.%s' "$SKILL_DIR" "$1"; }

# Echo the reason and return 0 when the team must keep its rows. Same four
# vetoes as the TTL dir GC in session-start.sh (test_session_retention.bats
# pins that both agree), plus: the dir exists again.
agmsg_retention_veto() {
  local team="$1" rec line placement pid live_pid="" unverified=0 log_team
  log_team="$(agmsg_pending_log_sanitize "$team")"
  if [ -d "$SKILL_DIR/teams/$team" ]; then
    printf 'dir-exists'; return 0
  fi
  if agmsg_instance_alive "${team#s-}" 2>/dev/null; then
    printf 'bare-owner-alive'; return 0
  fi
  for rec in "$RUN_DIR/spawn.${team}__"*; do
    [ -f "$rec" ] || continue
    line=""
    IFS= read -r line <"$rec" 2>/dev/null || true
    placement="${line%%$'\t'*}"
    case "$placement" in
      pid:*)
        pid="${placement#pid:}"
        case "$pid" in ''|*[!0-9]*) unverified=1; break ;; esac
        if ! [ "$pid" -gt 0 ] 2>/dev/null; then unverified=1; break; fi
        if _agmsg_pid_alive "$pid"; then live_pid="$pid"; break; fi
        ;;
      %*|@*|herdr:*) ;;
      *)
        [ -n "$line" ] || continue
        unverified=1; break
        ;;
    esac
  done
  if [ -n "$live_pid" ]; then printf 'live-bridge'; return 0; fi
  if [ "$unverified" -eq 1 ]; then printf 'unverified-placement'; return 0; fi
  if ! agmsg_inflight_gc_team "$team" 2>/dev/null; then
    printf 'live-inflight'; return 0
  fi
  : "$log_team"
  return 1
}

agmsg_retention_remaining() {
  local tl; tl="$(agmsg_sqlesc "$1")"
  agmsg_sqlite "$(agmsg_db_path)" \
    "SELECT (SELECT COUNT(*) FROM events WHERE team='$tl') + (SELECT COUNT(*) FROM messages WHERE team='$tl');" \
    2>/dev/null | tr -d '\r'
}

# One transaction: events, the legacy messages mirror and the read cursor go
# together or not at all (a half-deleted pair would resurrect hidden legacy
# rows). Rows are selected by team AND age, evaluated by sqlite, so a row
# inserted after the caller's checks is not touched. Returns non-zero on error.
agmsg_retention_delete_rows() {
  local team="$1" days="$2" tl db
  case "$days" in ''|*[!0-9]*) return 1 ;; esac
  tl="$(agmsg_sqlesc "$team")"; db="$(agmsg_db_path)"
  agmsg_sqlite "$db" <<SQL >/dev/null 2>&1
.bail on
BEGIN IMMEDIATE;
DELETE FROM events WHERE team='$tl' AND at < strftime('%Y-%m-%dT%H:%M:%SZ','now','-$days days');
DELETE FROM messages WHERE team='$tl' AND created_at < strftime('%Y-%m-%dT%H:%M:%SZ','now','-$days days');
DELETE FROM read_cursors WHERE team='$tl'
  AND NOT EXISTS (SELECT 1 FROM events WHERE team='$tl');
COMMIT;
SQL
}

# Delete one eligible team's old rows under the team's lifecycle lock, the one
# SessionStart takes before publishing cc-instance. A resume that starts after
# our veto check therefore either waits, or finds the dir back / owner alive on
# the re-check below. Echo a short outcome; return 0 when rows were handled.
# $2 is "dir-reaped" (called right after the TTL rm) or "tombstone" (sweep).
agmsg_retention_reap_team() {
  local team="$1" days reason
  agmsg_retention_supported || { printf 'unsupported-storage'; return 1; }
  days="$(agmsg_retention_days)"
  agmsg_team_lifecycle_lock_acquire "$team" "${AGMSG_LIFECYCLE_LOCK_TIMEOUT:-10}" \
    || { printf 'lock-timeout'; return 1; }
  if reason="$(agmsg_retention_veto "$team")"; then
    agmsg_team_lifecycle_lock_release "$team"
    printf '%s' "$reason"; return 1
  fi
  if agmsg_retention_delete_rows "$team" "$days"; then
    agmsg_team_lifecycle_lock_release "$team"
    printf 'deleted'; return 0
  fi
  agmsg_team_lifecycle_lock_release "$team"
  printf 'delete-failed'; return 1
}

# Called by the TTL GC right after `rm -rf teams/<team>`. $2 = 1 when the dir
# carried the session-team marker before it was removed.
agmsg_retention_after_dir_reap() {
  local team="$1" had_marker="$2" tomb
  [ "$had_marker" = 1 ] || return 0
  [ ! -d "$SKILL_DIR/teams/$team" ] || return 0   # rm failed: keep the rows
  tomb="$(agmsg_retention_tombstone_path "$team")"
  : >"$tomb" 2>/dev/null || return 0
  agmsg_retention_reap_team "$team" >/dev/null || true
}

# Rows younger than the window outlive the dir GC; later SessionStarts finish
# them. A tombstone goes only once the team has no rows AND is itself older
# than the window, which bounds the stray row a late `send --force` could leave.
agmsg_retention_sweep() {
  local tomb team days left
  agmsg_retention_supported || return 0
  days="$(agmsg_retention_days)"
  for tomb in "$RUN_DIR"/session-tombstone.s-*; do
    [ -f "$tomb" ] || continue
    team="${tomb##*/session-tombstone.}"
    agmsg_retention_reap_team "$team" >/dev/null || continue
    left="$(agmsg_retention_remaining "$team")"
    [ "$left" = 0 ] || continue
    [ -n "$(find "$tomb" -maxdepth 0 -mtime +"$days" 2>/dev/null)" ] || continue
    rm -f "$tomb" 2>/dev/null || true
  done
}
