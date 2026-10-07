#!/usr/bin/env bash
# session-retention.sh — message retention for finished session teams (s-<uuid>).
#
# agmsg_session_team_reap_dead removes a dead owner's team (dir, run state, rows)
# at once. The tombstone sweep below removes rows of a team whose dir was reaped
# by an older version, once they are older than
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

# Liveness of a spawn record's bridge pid, which a spawn shell minted ($!), so
# the local check applies (the native one asks tasklist under Git Bash and calls
# a live bridge dead). Prints alive|dead|unknown; an invalid value (leading zero,
# overflow) is unknown, never dead, so a damaged record cannot grant a reap.
agmsg_session_bridge_pid_state() {
  local pid="${1:-}"
  _agmsg_pid_valid "$pid" 2147483647 || { printf 'unknown'; return 0; }
  if _agmsg_pid_alive_local "$pid"; then printf 'alive'; else printf 'dead'; fi
}

# The vetoes shared by every deleter: owner alive, live bridge, unverified
# placement, live inflight. Echo the reason and return 0 to veto. $2 = readonly:
# replace the inflight reap (which deletes dead records and sends
# bridge-error/outbox messages) by "any inflight record vetoes", for dry-runs.
_agmsg_retention_veto_live() {
  local team="$1" readonly="${2:-}" rec line placement pid live_pid="" unverified=0
  if agmsg_instance_alive "${team#s-}" 2>/dev/null; then
    printf 'bare-owner-alive'; return 0
  fi
  for rec in "$RUN_DIR/spawn.${team}__"*; do
    [ -f "$rec" ] || continue
    line=""
    # A failed read of a non-empty record is unknown, not "no placement".
    IFS= read -r line <"$rec" 2>/dev/null || [ -n "$line" ] || [ ! -s "$rec" ] \
      || { unverified=1; break; }
    placement="${line%%$'\t'*}"
    case "$placement" in
      pid:*)
        pid="${placement#pid:}"
        case "$(agmsg_session_bridge_pid_state "$pid")" in
          alive) live_pid="$pid"; break ;;
          dead) ;;
          *) unverified=1; break ;;
        esac
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
  if [ "$readonly" = readonly ]; then
    for rec in "$RUN_DIR/inflight-record.$(_actas_lock_encode "$team")="*; do
      [ -f "$rec" ] || continue
      printf 'live-inflight'; return 0
    done
  elif ! agmsg_inflight_gc_team "$team" 2>/dev/null; then
    printf 'live-inflight'; return 0
  fi
  return 1
}

# For a team whose dir is gone (tombstone sweep, manual gc): the live vetoes,
# plus: the dir exists again.
agmsg_retention_veto() {
  if [ -d "$SKILL_DIR/teams/$1" ]; then
    printf 'dir-exists'; return 0
  fi
  _agmsg_retention_veto_live "$@"
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
  local team="$1" days="$2" strict="${3:-}" tl db cut guard_e="" guard_m=""
  case "$days" in ''|*[!0-9]*) return 1 ;; esac
  tl="$(agmsg_sqlesc "$team")"; db="$(agmsg_db_path)"
  cut="strftime('%Y-%m-%dT%H:%M:%SZ','now','-$days days')"
  # strict: delete nothing when the team has any row inside the window.
  if [ "$strict" = strict ]; then
    guard_e="AND NOT EXISTS (SELECT 1 FROM events WHERE team='$tl' AND at >= $cut) AND NOT EXISTS (SELECT 1 FROM messages WHERE team='$tl' AND created_at >= $cut)"
    guard_m="$guard_e"
  fi
  agmsg_sqlite "$db" <<SQL >/dev/null 2>&1
.bail on
BEGIN IMMEDIATE;
DELETE FROM events WHERE team='$tl' AND at < $cut $guard_e;
DELETE FROM messages WHERE team='$tl' AND created_at < $cut $guard_m;
DELETE FROM read_cursors WHERE team='$tl'
  AND NOT EXISTS (SELECT 1 FROM events WHERE team='$tl');
COMMIT;
SQL
}

# Delete one eligible team's old rows under the team's lifecycle lock, the one
# SessionStart takes before publishing cc-instance. A resume that starts after
# our veto check therefore either waits, or finds the dir back / owner alive on
# the re-check below. Echo a short outcome; return 0 when rows were handled.
# $2 = strict: delete only when no row is inside the window (manual apply).
agmsg_retention_reap_team() {
  local team="$1" strict="${2:-}" days reason
  agmsg_retention_supported || { printf 'unsupported-storage'; return 1; }
  days="$(agmsg_retention_days)"
  agmsg_team_lifecycle_lock_acquire "$team" "${AGMSG_LIFECYCLE_LOCK_TIMEOUT:-10}" \
    || { printf 'lock-timeout'; return 1; }
  if reason="$(agmsg_retention_veto "$team")"; then
    agmsg_team_lifecycle_lock_release "$team"
    printf '%s' "$reason"; return 1
  fi
  # The proof is re-read under the lock: a tombstone invalidated after the
  # caller looked (a newer project team of this name was reaped) must not
  # authorise this delete. Strict (manual) mode does not rely on a tombstone.
  if [ "$strict" != strict ] && [ ! -f "$(agmsg_retention_tombstone_path "$team")" ]; then
    agmsg_team_lifecycle_lock_release "$team"
    printf 'proof-gone'; return 1
  fi
  if agmsg_retention_delete_rows "$team" "$days" "$strict"; then
    agmsg_team_lifecycle_lock_release "$team"
    printf 'deleted'; return 0
  fi
  agmsg_team_lifecycle_lock_release "$team"
  printf 'delete-failed'; return 1
}

# TTL GC for a dir without the marker. Any tombstone of this name belongs to an
# earlier generation: drop it and remove the dir under the lifecycle lock, so a
# sweep either finishes before (and sees the dir) or starts after both are done.
# On lock timeout, or when the tombstone cannot be removed, the dir is kept
# (return 1) and retried at the next SessionStart.
agmsg_retention_reap_unmarked_dir() {
  local team="$1" dir="$2"
  agmsg_team_lifecycle_lock_acquire "$team" "${AGMSG_LIFECYCLE_LOCK_TIMEOUT:-10}" || return 1
  local tomb rc=0
  tomb="$(agmsg_retention_tombstone_path "$team")"
  # Absence is proven only by rm succeeding: a failed stat (unreadable run/)
  # also makes `-e` false. Any rm failure keeps the dir.
  if rm -f "$tomb" 2>/dev/null && [ ! -e "$tomb" ] && [ ! -L "$tomb" ] \
      && rm -rf "$dir" 2>/dev/null && [ ! -d "$dir" ]; then
    :
  else
    rc=1
  fi
  agmsg_team_lifecycle_lock_release "$team"
  return "$rc"
}

# Called by the TTL GC right after `rm -rf teams/<team>`. $2 = 1 when the dir
# carried the session-team marker before it was removed.
agmsg_retention_after_dir_reap() {
  local team="$1" had_marker="$2" tomb
  [ "$had_marker" = 1 ] || return 0   # unmarked dirs go through reap_unmarked_dir
  [ ! -d "$SKILL_DIR/teams/$team" ] || return 0   # rm failed: keep the rows
  tomb="$(agmsg_retention_tombstone_path "$team")"
  : >"$tomb" 2>/dev/null || return 0
  agmsg_retention_reap_team "$team" >/dev/null || true
}

# Rows younger than the window outlive the dir GC; later SessionStarts finish
# them. A tombstone goes only once the team has no rows AND is itself older
# than the window, which bounds the stray row a late `send --force` could leave.
# Finish a reap whose reaper died after the rename (run/reaping.<team>.<pid>.<n>).
# A live reaper pid, an unreadable one, or a lock that cannot be taken leaves the
# dir alone. Rows and run state go only when nothing vetoes and the renamed dir
# still carries the marker; otherwise only the dir is removed.
_agmsg_reaping_collect() {
  local path="$1" base rest pid team
  base="${path##*/reaping.}"
  rest="${base%.*}"; pid="${rest##*.}"; team="${rest%.*}"
  case "$team" in s-?*) ;; *) return 1 ;; esac
  [ "$(agmsg_session_bridge_pid_state "$pid")" = dead ] || return 1
  agmsg_team_lifecycle_lock_acquire "$team" "${AGMSG_LIFECYCLE_LOCK_TIMEOUT:-10}" || return 1
  if [ -f "$path/session-team" ] && [ ! -L "$path/session-team" ] \
      && [ ! -d "$SKILL_DIR/teams/$team" ] \
      && ! _agmsg_retention_veto_live "$team" >/dev/null; then
    if agmsg_retention_supported && ! agmsg_retention_delete_all_rows "$team"; then
      agmsg_team_lifecycle_lock_release "$team"
      return 1
    fi
    _agmsg_reap_run_files "$team" || true
  fi
  rm -rf "$path" 2>/dev/null || true
  agmsg_team_lifecycle_lock_release "$team"
}

agmsg_retention_sweep() {
  local tomb team days left
  for tomb in "$RUN_DIR"/reaping.s-*; do
    [ -e "$tomb" ] || continue
    _agmsg_reaping_collect "$tomb" || true
  done
  agmsg_retention_supported || return 0
  days="$(agmsg_retention_days)"
  for tomb in "$RUN_DIR"/session-tombstone.s-*; do
    [ -f "$tomb" ] || continue
    team="${tomb##*/session-tombstone.}"
    # A live dir without a marker is a newer team of the same name (a project
    # team): the tombstone belongs to the previous generation and proves nothing.
    if [ -d "$SKILL_DIR/teams/$team" ] && [ ! -f "$(agmsg_retention_marker_path "$team")" ]; then
      rm -f "$tomb" 2>/dev/null || true
      continue
    fi
    agmsg_retention_reap_team "$team" >/dev/null || continue
    left="$(agmsg_retention_remaining "$team")"
    [ "$left" = 0 ] || continue
    [ -n "$(find "$tomb" -maxdepth 0 -mtime +"$days" 2>/dev/null)" ] || continue
    rm -f "$tomb" 2>/dev/null || true
  done
}

# Rows of the team in every table the delete touches, read cursors included.
_agmsg_retention_remaining_all() {
  local tl db tbl have expr=""
  tl="$(agmsg_sqlesc "$1")"; db="$(agmsg_db_path)"
  have="$(agmsg_sqlite "$db" "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('events','messages','read_cursors');" 2>/dev/null | tr -d '\r')" \
    || return 1
  # An older database lacks some tables; a missing one holds no rows.
  for tbl in events messages read_cursors; do
    case $'\n'"$have"$'\n' in *$'\n'"$tbl"$'\n'*) ;; *) continue ;; esac
    expr="${expr:+$expr + }(SELECT COUNT(*) FROM $tbl WHERE team='$tl')"
  done
  [ -n "$expr" ] || { printf '0'; return 0; }
  agmsg_sqlite "$db" "SELECT $expr;" 2>/dev/null | tr -d '\r'
}

# Delete every row of the team in one transaction, with no age condition: the
# team's owner is gone, so nothing in it is wanted any more.
agmsg_retention_delete_all_rows() {
  local tl db tbl stmts="" have
  tl="$(agmsg_sqlesc "$1")"; db="$(agmsg_db_path)"
  [ -f "$db" ] || return 0   # no database yet: there is nothing to delete
  # A table appears with the first write to it; a missing one holds no rows.
  have="$(agmsg_sqlite "$db" "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('events','messages','read_cursors');" 2>/dev/null | tr -d '\r')" \
    || return 1
  for tbl in events messages read_cursors; do
    case $'\n'"$have"$'\n' in *$'\n'"$tbl"$'\n'*) ;; *) continue ;; esac
    stmts="${stmts}DELETE FROM $tbl WHERE team='$tl';"$'\n'
  done
  [ -n "$stmts" ] || return 0
  agmsg_sqlite "$db" <<SQL >/dev/null 2>&1
.bail on
BEGIN IMMEDIATE;
$stmts
COMMIT;
SQL
}

# Remove the per-team run state; non-zero when something is still there.
_agmsg_reap_run_files() {
  local team="$1" run="$SKILL_DIR/run" f
  rm -rf "$run/codex-$team-cwd" 2>/dev/null || true
  rm -f "$run/codex-bridge.$team".* 2>/dev/null || true
  rm -rf "$run/claude-code-$team-"*-cwd 2>/dev/null || true
  rm -f "$run/claude-code-bridge.$team".* 2>/dev/null || true
  rm -f "$run/cursor-bridge.$team".* 2>/dev/null || true
  rm -f "$run/spawn.$team"__* 2>/dev/null || true
  rm -f "$run/pending-teardown.$team"__* 2>/dev/null || true
  rm -rf "$run/placement.$team"__*.lock 2>/dev/null || true
  # A leftover outbox would be retried for a team that no longer exists.
  rm -rf "$run/inflight-outbox.$(_actas_lock_encode "$team")="* 2>/dev/null || true
  for f in "$run/codex-$team-cwd" "$run/codex-bridge.$team".* \
      "$run/claude-code-$team-"*-cwd "$run/claude-code-bridge.$team".* \
      "$run/cursor-bridge.$team".* "$run/spawn.$team"__* \
      "$run/pending-teardown.$team"__* "$run/placement.$team"__*.lock \
      "$run/inflight-outbox.$(_actas_lock_encode "$team")="*; do
    if [ -e "$f" ] || [ -L "$f" ]; then return 1; fi
  done
  return 0
}

# A name-shaped s-<id> dir that carries the session-team marker (not a symlink)
# and classifies as a session team.
_agmsg_reap_is_marked_session_dir() {
  local team="$1" marker
  marker="$(agmsg_retention_marker_path "$team")"
  [ -d "$SKILL_DIR/teams/$team" ] || return 1
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 2
  [ "$(agmsg_session_team_class "$team" 2>/dev/null)" = session ] || return 3
}

# Remove a session team whose owner is gone: dir, run state and every row.
# Echo reaped | reaped-with-leftovers | skipped:<reason> | unmarked |
# lock-timeout; the first two return 0. $2 = held: the caller already holds the
# team's lifecycle lock (SessionStart publishing cc-instance).
# The rows go first (a failure changes nothing), then the dir is renamed out of
# teams/, then the run state goes and the renamed dir is removed last, leftovers
# being collected by the sweep.
agmsg_session_team_reap_dead() {
  local team="$1" held="${2:-}" dir reason log_team trash rc out
  case "$team" in s-?*) ;; *) printf 'skipped:not-session'; return 1 ;; esac
  dir="$SKILL_DIR/teams/$team"
  [ -d "$dir" ] || { printf 'skipped:no-dir'; return 1; }
  # Early skip only: every one of these is checked again under the lock.
  rc=0; _agmsg_reap_is_marked_session_dir "$team" || rc=$?
  case "$rc" in 0) ;; 2) printf 'unmarked'; return 1 ;; *) printf 'skipped:not-session'; return 1 ;; esac
  log_team="$(agmsg_pending_log_sanitize "$team")"
  if [ "$held" != held ]; then
    if ! agmsg_team_lifecycle_lock_acquire "$team" "${AGMSG_LIFECYCLE_LOCK_TIMEOUT:-10}"; then
      printf 'agmsg: session-team TTL GC skipped team=%s reason=lock-timeout\n' "$log_team" >&2
      printf 'lock-timeout'; return 1
    fi
  fi
  # The dir may have been replaced while waiting for the lock (a project team of
  # this name; join.sh takes no lifecycle lock), so the proof is read again.
  rc=0; _agmsg_reap_is_marked_session_dir "$team" || rc=$?
  case "$rc" in
    0) reason="" ;;
    1) reason=no-dir ;;
    2) reason=unmarked ;;
    *) reason=not-session ;;
  esac
  if [ -z "$reason" ]; then
    reason="$(_agmsg_retention_veto_live "$team")" || reason=""
  fi
  if [ -n "$reason" ]; then
    [ "$held" = held ] || agmsg_team_lifecycle_lock_release "$team"
    [ "$reason" = unmarked ] && { printf 'unmarked'; return 1; }
    printf 'agmsg: session-team TTL GC skipped team=%s reason=%s\n' "$log_team" "$reason" >&2
    printf 'skipped:%s' "$reason"; return 1
  fi
  # Rows first: a failure here changes nothing. A send that lands between the
  # delete and the rename leaves a row for the next purge of this session id.
  if agmsg_retention_supported && ! agmsg_retention_delete_all_rows "$team"; then
    [ "$held" = held ] || agmsg_team_lifecycle_lock_release "$team"
    printf 'agmsg: session-team TTL GC skipped team=%s reason=db-failed\n' "$log_team" >&2
    printf 'skipped:db-failed'; return 1
  fi
  trash="$SKILL_DIR/run/reaping.$team.$$.$RANDOM"
  if ! mv "$dir" "$trash" 2>/dev/null || [ -d "$dir" ]; then
    [ "$held" = held ] || agmsg_team_lifecycle_lock_release "$team"
    printf 'agmsg: session-team TTL GC skipped team=%s reason=rename-failed\n' "$log_team" >&2
    printf 'skipped:rename-failed'; return 1
  fi
  out=reaped
  if ! _agmsg_reap_run_files "$team"; then
    out=reaped-with-leftovers
    printf 'agmsg: session-team TTL GC leftovers team=%s reason=run-files-not-removed\n' "$log_team" >&2
  fi
  rm -rf "$trash" 2>/dev/null || true
  [ "$held" = held ] || agmsg_team_lifecycle_lock_release "$team"
  printf '%s' "$out"
}

# A team that has no dir but may still own rows (a forced send, or a send that
# raced the reap): the next generation of the same session id starts empty.
# Caller holds the team's lifecycle lock. Echo purged | clean | skipped:<reason>.
agmsg_session_team_purge_orphan_rows() {
  local team="$1" reason left
  case "$team" in s-?*) ;; *) printf 'skipped:not-session'; return 1 ;; esac
  [ ! -d "$SKILL_DIR/teams/$team" ] || { printf 'skipped:dir-exists'; return 1; }
  agmsg_retention_supported || { printf 'skipped:unsupported-storage'; return 1; }
  [ -f "$(agmsg_db_path)" ] || { printf 'clean'; return 0; }
  if reason="$(_agmsg_retention_veto_live "$team")"; then
    printf 'skipped:%s' "$reason"; return 1
  fi
  left="$(_agmsg_retention_remaining_all "$team")"
  case "$left" in ''|*[!0-9]*) printf 'skipped:unreadable'; return 1 ;; esac
  [ "$left" -gt 0 ] || { printf 'clean'; return 0; }
  agmsg_retention_delete_all_rows "$team" || { printf 'skipped:delete-failed'; return 1; }
  printf 'purged'
}
