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

# 3) Directive emission. No Monitor tool exists for cursor in either the
# plain or resumed-role case (both leave stdout empty, unlike the default's
# "invoke Monitor" text) — the only effect is keeping inject-watch.sh alive
# for this instance. Idempotent: a no-op when (2) above already confirms this
# instance's watcher is alive, so a beforeSubmitPrompt re-fire never double
# launches.
agmsg_session_start_emit_directive() {
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
