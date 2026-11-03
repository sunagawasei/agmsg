#!/usr/bin/env bash
# cursor SessionStart/beforeSubmitPrompt plug — launches inject-watch.sh
# instead of Claude Code's Monitor tool (cursor-agent has none). _delivery.sh
# registers this same command for BOTH sessionStart and beforeSubmitPrompt, so
# it runs once per session AND once per turn — the fast-path predicate below
# exists specifically to keep the per-turn cost cheap.
#
# Uses session-start.sh's three type-overridable extension points rather than
# the early agmsg_session_start exit-hook codex's plug uses: cursor's watcher
# still needs join/dedup/GC to run at least once (session-team registration
# in particular — inject-watch.sh's target resolution, via
# lib/inbox-target.sh, depends on this session having joined its team), so it
# must not skip agmsg_session_start_common_init the way codex's bridge
# handoff does.
#
# Sourced by session-start.sh in its global context: sees TYPE, PROJECT,
# RUN_DIR, SCRIPT_DIR, SKILL_DIR, SESSION_ID (raw, pre-instance-id form)
# already set when (1)/(2) below are consulted; INSTANCE_ID, WATCH_PROJECT,
# ROLE_NAME, ROLE_TEAM additionally set by the time (3) runs (they're
# populated by agmsg_session_start_common_init, which executes between them).

HERDR="${AGMSG_HERDR_CMD:-herdr}"

# session-start.sh's early-plug dispatch (unconditional whenever this file
# exists, before agmsg_session_start_common_init is even defined) still
# expects agmsg_session_start unconditionally -- codex's plug uses it to hand
# the session off to its bridge and skip common_init entirely, but cursor's
# watcher needs common_init's join/dedup/GC (see the file header), so this
# stays a no-op and all of cursor's own behavior lives in (1)-(3) below.
agmsg_session_start() { :; }

# 1) Fast path predicate, consulted once right before
# agmsg_session_start_common_init runs. Unconditional yes: whether the
# process actually TAKES the fast path is decided by common_init's own gate
# (a cc-instance match plus the liveness check below plus session-team
# membership), which stays closed on a session's first call (no inject
# watcher yet, no cc-instance record yet) and opens once both exist.
agmsg_session_start_fast_path_ok() { :; }

# 2) Fast path's internal liveness gate. The default (watch.<iid>.pid) would
# never confirm alive here — cursor has no watch.sh — so without this
# override the fast path could never actually engage. Args: <instance_id>
# <project> <type>. Mirrors session-start.sh's own default (watcher_alive_
# default): verified via process-identity.sh's owner/lease sidecar
# (inject-watch.sh now bootstraps through process-owner-launch.sh with
# kind=inject-watch — see its header), not a bare `kill -0`, which review
# flagged as having no defense against a PID inject-watch.sh no longer owns
# being recycled by an unrelated process.
agmsg_session_start_watcher_alive() {
  local iid="$1" project="$2" type="$3"
  local pidfile="$RUN_DIR/inject-watch.$iid.pid"
  agmsg_process_dedup_should_suppress inject-watch "$pidfile" \
    "inject-watch|$iid|$project|$type" >/dev/null 2>&1
}

# Resolve the herdr pane to inject into. HERDR_PANE_ID (set when cursor-agent
# itself was launched inside a herdr pane) is authoritative and needs no
# herdr call for the pane_id itself; otherwise ask herdr which pane is running
# this project's cursor-agent. Either way, ALSO resolves that pane's
# terminal_id (best-effort) for inject-watch.sh's pane-reuse guard: herdr's
# pane_id names a layout slot, not a process, so a stale pane_id handed to a
# NEW session in the same project needs a second, process-identifying field
# to be told apart (see inject-watch.sh's header for how it uses this).
# Echoes "<pane_id>\t<terminal_id>" (terminal_id empty when unresolved, which
# inject-watch.sh treats as "skip that check", not as a reuse failure).
#
# Uses the same -escape off workaround as inject-watch.sh's _pane_sqlite_mem
# (agmsg_sqlite_mem lacks it; see that file's header for the sqlite3 >= 3.50
# caret-escaping bug — #102/#143's fix doesn't cover the :memory: helper).
# Local workaround, not a fix — agmsg_sqlite_mem itself should grow the same
# -escape off handling agmsg_sqlite already has.
_cursor_session_start_resolve_pane_id() {
  if [ -n "${HERDR_PANE_ID:-}" ]; then
    local pane_id="$HERDR_PANE_ID" terminal_id="" json esc pane_esc
    if command -v "$HERDR" >/dev/null 2>&1 \
        && json="$("$HERDR" agent list 2>/dev/null)" && [ -n "$json" ]; then
      esc="$(printf '%s' "$json" | sed "s/'/''/g")"
      pane_esc="$(printf '%s' "$pane_id" | sed "s/'/''/g")"
      _agmsg_escape_flag >/dev/null
      # shellcheck disable=SC2086
      terminal_id="$(sqlite3 $_AGMSG_ESCAPE_FLAG :memory: "
        WITH raw(j) AS (SELECT '$esc'),
        valid(j) AS (SELECT j FROM raw WHERE json_valid(j)),
        arr(j) AS (
          SELECT CASE
            WHEN json_type((SELECT j FROM valid)) = 'array' THEN (SELECT j FROM valid)
            WHEN json_type((SELECT j FROM valid), '\$.result.agents') = 'array' THEN json_extract((SELECT j FROM valid), '\$.result.agents')
            WHEN json_type((SELECT j FROM valid), '\$.result') = 'array' THEN json_extract((SELECT j FROM valid), '\$.result')
            WHEN json_type((SELECT j FROM valid), '\$.agents') = 'array' THEN json_extract((SELECT j FROM valid), '\$.agents')
            ELSE NULL END
        )
        SELECT coalesce(json_extract(e.value,'\$.terminal_id'),'')
        FROM arr, json_each(arr.j) AS e
        WHERE json_extract(e.value,'\$.pane_id') = '$pane_esc'
        LIMIT 1;
      " 2>/dev/null | tr -d '\r')"
    fi
    printf '%s\t%s' "$pane_id" "$terminal_id"
    return 0
  fi
  command -v "$HERDR" >/dev/null 2>&1 || return 1
  local json esc project_esc row
  json="$("$HERDR" agent list 2>/dev/null)" || return 1
  [ -n "$json" ] || return 1
  esc="$(printf '%s' "$json" | sed "s/'/''/g")"
  project_esc="$(printf '%s' "$PROJECT" | sed "s/'/''/g")"
  _agmsg_escape_flag >/dev/null
  # shellcheck disable=SC2086
  row="$(sqlite3 $_AGMSG_ESCAPE_FLAG :memory: "
    WITH raw(j) AS (SELECT '$esc'),
    valid(j) AS (SELECT j FROM raw WHERE json_valid(j)),
    arr(j) AS (
      SELECT CASE
        WHEN json_type((SELECT j FROM valid)) = 'array' THEN (SELECT j FROM valid)
        WHEN json_type((SELECT j FROM valid), '\$.result.agents') = 'array' THEN json_extract((SELECT j FROM valid), '\$.result.agents')
        WHEN json_type((SELECT j FROM valid), '\$.result') = 'array' THEN json_extract((SELECT j FROM valid), '\$.result')
        WHEN json_type((SELECT j FROM valid), '\$.agents') = 'array' THEN json_extract((SELECT j FROM valid), '\$.agents')
        ELSE NULL END
    )
    SELECT json_extract(e.value,'\$.pane_id') || char(9)
        || coalesce(json_extract(e.value,'\$.terminal_id'),'')
    FROM arr, json_each(arr.j) AS e
    WHERE json_extract(e.value,'\$.agent') = 'cursor'
      AND json_extract(e.value,'\$.cwd') = '$project_esc'
    LIMIT 1;
  " 2>/dev/null | tr -d '\r')"
  [ -n "$row" ] || return 1
  printf '%s' "$row"
}

# 3a) agmsgd. The project's recorded delivery choice, as the bare value ("agmsgd",
# "turn", ...) or empty when nobody chose. Only the literal "agmsgd" changes
# anything below; a project with no recorded choice keeps the watcher path.
_cursor_session_start_choice() {
  if ! declare -F agmsg_delivery_choice_get >/dev/null 2>&1; then
    # shellcheck disable=SC1091
    . "$SKILL_DIR/scripts/lib/daemon-state.sh"
  fi
  agmsg_delivery_choice_get "$TYPE" "$PROJECT" 2>/dev/null || true
}

# rc 0 only when no inject-watch of this instance is left running. A watcher is
# stopped only after process-identity.sh proves it is this instance's own, and its
# disappearance is read back from the same evidence rather than from `kill -0`.
_cursor_session_start_stop_inject_watch() {
  local pidfile="$RUN_DIR/inject-watch.$INSTANCE_ID.pid"
  local scope="inject-watch|$INSTANCE_ID|$PROJECT|$TYPE"
  agmsg_process_identity_state inject-watch "$pidfile" "$scope" || return 1
  case "$AGMSG_PROCESS_STATE" in
    stale|legacy-dead|degraded-dead|unverified-dead) ;;
    owned)
      agmsg_process_signal_owned inject-watch "$pidfile" "$scope" TERM --wait-release 5 || return 1
      agmsg_process_identity_state inject-watch "$pidfile" "$scope" || return 1
      case "$AGMSG_PROCESS_STATE" in
        stale|legacy-dead|degraded-dead|unverified-dead) ;;
        *) return 1 ;;
      esac
      ;;
    *) return 1 ;;
  esac
  agmsg_process_cleanup_observed "$pidfile" >/dev/null 2>&1 || true
  return 0
}

# Publish this session's herdr destination for agmsgd, in this order: stop this
# instance's inject-watch and confirm it is gone, then record the destination.
# Anything that cannot be confirmed leaves nothing published, and a destination an
# earlier process of this seat published is withdrawn (the pane may be someone
# else's now). Messages go to stderr: cursor reads hook stdout as its own JSON.
_cursor_session_start_agmsgd() {
  local bare_sid team="" agent="" locator resolved pane_id="" terminal_id="" reason=""
  local _tab _n
  _tab="$(printf '\t')"
  bare_sid="$(agmsg_instance_bare_sid "${SESSION_ID:-}" 2>/dev/null || true)"
  if [ -z "$bare_sid" ]; then
    echo "AGMSG delivery: this project's delivery is agmsgd, but this session's id is unknown, so agmsgd cannot deliver to it. Next: run agmsg doctor." >&2
    return 0
  fi

  # The seat the record belongs to: a resumed role, else this session's own team
  # seat (what inject-watch.sh would have watched), else the project's only pair.
  if [ -n "${ROLE_TEAM:-}" ] && [ -n "${ROLE_NAME:-}" ]; then
    team="$ROLE_TEAM"; agent="$ROLE_NAME"
  elif [ -n "${SESSION_TEAM:-}" ]; then
    team="$SESSION_TEAM"; agent="$(agmsg_session_seat "$TYPE")"
  else
    _n="$(printf '%s\n' "${PAIRS:-}" | grep -c '.' || true)"
    if [ "$_n" -eq 1 ]; then
      IFS="$_tab" read -r team agent <<EOF
${PAIRS:-}
EOF
    fi
  fi

  if ! locator="$(agmsg_cursor_herdr_locator 2>/dev/null)" || [ -z "$locator" ]; then
    reason=herdr_env_missing
    echo "AGMSG delivery: this project's delivery is agmsgd, but this session is not in a usable herdr pane (HERDR_SOCKET_PATH or HERDR_PANE_ID is missing or malformed), so agmsgd cannot deliver to it and no inject watcher is started. Next: run cursor-agent inside herdr, or choose another mode with: agmsg delivery turn" >&2
  elif ! resolved="$(_cursor_session_start_resolve_pane_id 2>/dev/null)" \
      || { IFS=$'\t' read -r pane_id terminal_id <<<"$resolved"; [ -z "${terminal_id:-}" ]; }; then
    reason=herdr_terminal_unresolved
    echo "AGMSG delivery: this project's delivery is agmsgd, but herdr did not name this pane's terminal, so agmsgd cannot tell it from a reused pane and nothing is published. Next: check that herdr agent list answers, then run agmsg doctor." >&2
  elif ! _cursor_session_start_stop_inject_watch; then
    reason=watcher_stop_unconfirmed
    echo "AGMSG delivery: this project's delivery is agmsgd, but this session's inject watcher could not be confirmed stopped, so nothing is published (the watcher exits on its own once it sees the agmsgd choice). Next: run agmsg doctor." >&2
  fi
  if [ -n "$reason" ]; then
    [ -z "$team" ] || [ -z "$agent" ] || agmsg_role_session_mark_herdr_blocked "$team" "$agent" "$reason" "$bare_sid" >/dev/null 2>&1 || true
    return 0
  fi
  if [ -z "$team" ] || [ -z "$agent" ]; then
    echo "AGMSG delivery: this project's delivery is agmsgd, but this session's seat is not decided (several registered seats and none recorded for it), so nothing is published. Next: run /agmsg actas <name>." >&2
    return 0
  fi

  # An instance id without a process id cannot hold the seat's lock.
  if ! agmsg_instance_is_composite "$INSTANCE_ID" 2>/dev/null; then
    agmsg_role_session_mark_herdr_blocked "$team" "$agent" seat_pid_unresolved "$bare_sid" >/dev/null 2>&1 || true
    echo "AGMSG delivery: this session's own process could not be identified, so nothing is published for $agent@$team. Next: run agmsg doctor." >&2
    return 0
  fi
  local claim_result
  claim_result="$(actas_lock_claim "$team" "$agent" "$INSTANCE_ID" 2>/dev/null || true)"
  [ -n "$claim_result" ] || claim_result="unknown:claim_failed"
  if [ "$claim_result" != ok ]; then
    echo "AGMSG delivery: seat $agent@$team could not be claimed ($claim_result), so nothing is published. Next: run agmsg doctor." >&2
    return 0
  fi
  # Holding the lock, the record is rewritten to this session's session/project/
  # type/owner whenever any of them differs (a seat taken over from another
  # project or type would otherwise keep that one's). A matching record is left
  # alone: the writer drops the herdr fields and the self-rename mark, so a
  # rewrite on every prompt would open a gap in the published destination.
  local project_phys
  project_phys="$(agmsg_canonical_path "${PROJECT:-}" 2>/dev/null || printf '%s' "${PROJECT:-}")"
  if [ "$(agmsg_role_session_get "$team" "$agent" type 2>/dev/null || true)" != "${TYPE:-}" ] \
      || [ "$(agmsg_role_session_get "$team" "$agent" project 2>/dev/null || true)" != "$project_phys" ] \
      || [ "$(agmsg_role_session_get "$team" "$agent" owner 2>/dev/null || true)" != "$INSTANCE_ID" ] \
      || [ "$(agmsg_role_session_uuid "$team" "$agent" 2>/dev/null || true)" != "$bare_sid" ]; then
    agmsg_role_session_record "$team" "$agent" "$bare_sid" "$project_phys" "${TYPE:-}" "$INSTANCE_ID"
  fi
  if agmsg_role_session_publish_herdr_messaging "$team" "$agent" "$locator" "$terminal_id" "$bare_sid" "$bare_sid"; then
    echo "AGMSG delivery: agmsgd delivers to this session's herdr pane ($agent@$team); no inject watcher is started." >&2
  else
    echo "AGMSG delivery: the delivery record for $agent@$team did not take, so agmsgd cannot deliver to it. Next: run agmsg doctor." >&2
  fi
  return 0
}

# 3) Directive emission. No Monitor tool exists for cursor in either the
# plain or resumed-role case (both leave stdout empty, unlike the default's
# "invoke Monitor" text) — the only effect is keeping inject-watch.sh alive
# for this instance. Idempotent: a no-op when (2) above already confirms this
# instance's watcher is alive, so a beforeSubmitPrompt re-fire never double
# launches.
agmsg_session_start_emit_directive() {
  # A project that chose agmsgd is delivered to by the daemon: this session
  # publishes its destination and never runs inject-watch.sh. Checked before the
  # liveness gate below, since a watcher still alive from an earlier choice must
  # be stopped, not reused.
  if [ "$(_cursor_session_start_choice)" = agmsgd ]; then
    _cursor_session_start_agmsgd
    return 0
  fi
  agmsg_session_start_watcher_alive "$INSTANCE_ID" "$WATCH_PROJECT" "$TYPE" && return 0

  local resolved pane_id terminal_id
  if ! resolved="$(_cursor_session_start_resolve_pane_id)" || [ -z "$resolved" ]; then
    echo "agmsg: cursor monitor/both delivery needs a herdr pane to inject into (no herdr binary, no HERDR_PANE_ID, or no pane running this project); inject watcher not started" >&2
    return 0
  fi
  IFS=$'\t' read -r pane_id terminal_id <<<"$resolved"
  if [ -z "$pane_id" ]; then
    echo "agmsg: cursor monitor/both delivery needs a herdr pane to inject into (no herdr binary, no HERDR_PANE_ID, or no pane running this project); inject watcher not started" >&2
    return 0
  fi

  mkdir -p "$RUN_DIR" 2>/dev/null || true
  nohup "$SKILL_DIR/scripts/drivers/types/cursor/inject-watch.sh" \
    "$SESSION_ID" "$PROJECT" "$TYPE" "$pane_id" "$INSTANCE_ID" "$terminal_id" \
    >>"$RUN_DIR/inject-watch.$INSTANCE_ID.log" 2>&1 3>&- 4>&- &
  disown 2>/dev/null || true
}
