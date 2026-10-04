#!/usr/bin/env bash
# session-team.sh — opt-in "one team per host session" mode and the single
# resolver of "who is calling" (host + session id) shared by whoami, send,
# delivery, spawn, ensure-headless and the SessionStart/End hooks.
#
# When delivery.session_team is enabled, a session uses a team named
#   <prefix><bare session id>
# instead of the project-derived team. The prefix and the env var that carries
# the id come from each type's manifest (session_team_prefix / session_env), so
# a Claude Code session (s-<uuid>) and a Cursor session (cur-<uuid>) can never
# share a team even if their ids were equal. Every agmsg scope (messages, watch
# delivery, history, actas locks, the codex worker) already keys on team, so
# this isolates concurrent / resumed sessions that share a directory without
# adding any per-message axis. The bare id is stable across --continue/--resume,
# so a resumed session returns to the same team and its persisted history.
# Disabled (or no id) => callers fall back to the normal project->team
# resolution.
#
# Authority order for the caller's identity: an explicit id passed in by the
# caller (a hook's validated payload, with the host taken from the caller's
# type) > the session env var of exactly one host > none. Two hosts' env vars
# at once, or any invalid value, is "ambiguous" and callers fail closed.
#
# Callers should set SCRIPT_DIR (the scripts dir) before sourcing so config.sh
# is locatable; we fall back to BASH_SOURCE-based resolution otherwise.

# Echo the scripts dir (for locating config.sh).
agmsg_session_team_scripts_dir() {
  if [ -n "${SCRIPT_DIR:-}" ]; then
    printf '%s' "$SCRIPT_DIR"
    return 0
  fi
  if [ -n "${BASH_SOURCE[0]:-}" ]; then
    ( cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd )
    return 0
  fi
  return 1
}

# Return 0 when session-team mode is enabled in config (delivery.session_team).
agmsg_session_team_enabled() {
  local sd
  sd="$(agmsg_session_team_scripts_dir)" || return 1
  case "$("$sd/config.sh" get delivery.session_team false 2>/dev/null || echo false)" in
    true|1|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

# --- host manifest ---------------------------------------------------------

# Read <key> from builtin type <type>'s manifest. Plain grep on purpose: this
# sits on the send/whoami path and must not pull in type-registry.sh.
_agmsg_st_conf() {
  local type="$1" key="$2" sd conf line val
  sd="$(agmsg_session_team_scripts_dir)" || return 0
  case "$type" in ''|*[!A-Za-z0-9_-]*) return 0 ;; esac
  conf="$sd/drivers/types/$type/type.conf"
  [ -f "$conf" ] || return 0
  line="$( { grep -E "^[[:space:]]*${key}[[:space:]]*=" "$conf" 2>/dev/null || true; } | head -1)"
  [ -n "$line" ] || return 0
  val="${line#*=}"
  val="${val#"${val%%[![:space:]]*}"}"
  val="${val%"${val##*[![:space:]]}"}"
  printf '%s' "$val"
}

# Echo the host (type) names that declare a session_env, one per line.
agmsg_session_hosts() {
  local sd conf
  sd="$(agmsg_session_team_scripts_dir)" || return 0
  for conf in "$sd"/drivers/types/*/type.conf; do
    [ -f "$conf" ] || continue
    [ -n "$(_agmsg_st_conf "$(basename "$(dirname "$conf")")" session_env)" ] \
      && basename "$(dirname "$conf")"
  done
  return 0
}

# Echo every host's session env var name (one per line): what a spawned child of
# any type must not inherit from its parent.
agmsg_session_env_names() {
  local host
  while IFS= read -r host; do
    [ -n "$host" ] && _agmsg_st_conf "$host" session_env && printf '\n'
  done <<EOF
$(agmsg_session_hosts)
EOF
  return 0
}

# Unset every host's session id env var in the current shell. Launchers call this
# so a spawned child never inherits the id of the session that started it (the
# parent's id would otherwise be taken for the child's own, or collide with the
# child host's id). Types' spawn_unset_env (per-type runtime config) is separate
# and is applied only when that type is the one being started.
agmsg_session_unset_env() {
  local name
  while IFS= read -r name; do
    [ -n "$name" ] && unset "$name"
  done <<EOF2
$(agmsg_session_env_names)
EOF2
  return 0
}

# Seat (agent) name a host's session is registered under inside its own team.
agmsg_session_seat() {
  local seat
  seat="$(_agmsg_st_conf "${1:-claude-code}" session_seat)"
  printf '%s' "${seat:-claude}"
}

# --- id validation / team naming -------------------------------------------

# Echo the bare session id for <host> when <sid> is acceptable, else nothing.
# Acceptable: 1..128 chars of [0-9A-Za-z_-]. A dot is never accepted, so ids
# like "abc.1" and "abc.2" can never collapse into one team, and the per-process
# "<id>.<pid>" instance id (which only agmsg itself derives) is not a session id.
# A host that declares session_sid_strict_uuid=yes additionally needs 8-4-4-4-12
# hex.
agmsg_session_normalize_sid() {
  local host="$1" sid="${2:-}"
  [ -n "$sid" ] || return 0
  [ "${#sid}" -le 128 ] || return 0
  if ! (LC_ALL=C; case "$sid" in *[!0-9A-Za-z_-]*) exit 1 ;; esac); then
    return 0
  fi
  if [ "$(_agmsg_st_conf "$host" session_sid_strict_uuid)" = yes ]; then
    if ! (LC_ALL=C; case "$sid" in
            [0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]) exit 0 ;;
            *) exit 1 ;;
          esac); then
      return 0
    fi
  fi
  printf '%s' "$sid"
}

# Echo the session id a hook payload (JSON on $1) carries, or nothing when it is
# not a JSON object with a top-level string session_id, or when conversation_id /
# sessionId is present and is not that very string (a different value, a
# non-string or null). Nothing is echoed for a failed check either, so callers
# fail closed. The id is checked in SQL before it crosses the CLI/shell boundary
# (length, NUL, allowed characters), so a value with an embedded newline or NUL
# is refused rather than truncated to its first line; agmsg_session_normalize_sid
# then applies the host's own id shape.
agmsg_session_payload_id() {
  local input="${1:-}" lit sid bad
  lit="$(printf '%s' "$input" | sed "s/'/''/g")" || return 0
  sid="$(printf '%s\n' "
    WITH raw(j) AS (SELECT '$lit'),
    valid(j) AS (SELECT j FROM raw WHERE json_valid(j) AND json_type(j) = 'object')
    SELECT json_extract(j, '\$.session_id') AS sid FROM valid
    WHERE json_type(j, '\$.session_id') = 'text'
      AND length(json_extract(j, '\$.session_id')) BETWEEN 1 AND 128
      AND instr(json_extract(j, '\$.session_id'), char(0)) = 0
      AND json_extract(j, '\$.session_id') NOT GLOB '*[^0-9A-Za-z_-]*';" \
    | sqlite3 -init /dev/null -noheader -list :memory: 2>/dev/null | head -1 | tr -d '\r')" || return 0
  [ -n "$sid" ] || return 0
  case "$sid" in *\'*) return 0 ;; esac
  bad="$(printf '%s\n' "
    WITH raw(j) AS (SELECT '$lit'),
    valid(j) AS (SELECT j FROM raw WHERE json_valid(j) AND json_type(j) = 'object')
    SELECT 1 FROM valid
    WHERE (json_type(j, '\$.conversation_id') IS NOT NULL
           AND json_extract(j, '\$.conversation_id') IS NOT '$sid')
       OR (json_type(j, '\$.sessionId') IS NOT NULL
           AND json_extract(j, '\$.sessionId') IS NOT '$sid');" \
    | sqlite3 -init /dev/null -noheader -list :memory: 2>/dev/null)" || return 0
  [ -z "$bad" ] || return 0
  printf '%s' "$sid"
}

# Classify a hook payload (JSON on $1) for a session-team host:
#   id    a usable session id (agmsg_session_payload_id would echo it)
#   none  a JSON object that names no id at all ({} and the like)
#   bad   anything else: invalid JSON, a non-object, an id field that is empty,
#         null, not a string, unusable, or disagreeing with another id field
# Callers read no inbox for "bad" and fall back to project teams for "none".
agmsg_session_payload_kind() {
  local input="${1:-}" lit named
  [ -n "$(agmsg_session_payload_id "$input")" ] && { printf 'id'; return 0; }
  lit="$(printf '%s' "$input" | sed "s/'/''/g")" || { printf 'bad'; return 0; }
  named="$(printf '%s\n' "
    WITH raw(j) AS (SELECT '$lit')
    SELECT CASE
      WHEN NOT json_valid(j) OR json_type(j) != 'object' THEN 'bad'
      WHEN json_type(j, '\$.session_id') IS NULL
       AND json_type(j, '\$.sessionId') IS NULL
       AND json_type(j, '\$.conversation_id') IS NULL THEN 'none'
      ELSE 'bad' END FROM raw;" \
    | sqlite3 -init /dev/null -noheader -list :memory: 2>/dev/null)" || named=bad
  [ "$named" = none ] && printf 'none' || printf 'bad'
}

# Echo <host>'s team name for a bare session id, or nothing.
agmsg_session_team_for() {
  local host="$1" bare="$2" prefix
  [ -n "$bare" ] || return 0
  prefix="$(_agmsg_st_conf "$host" session_team_prefix)"
  [ -n "$prefix" ] || return 0
  printf '%s%s' "$prefix" "$bare"
}

# Echo the session team name for an EXPLICIT session id when mode is enabled;
# empty otherwise. Hooks (session-start/end) pass the authoritative session_id
# from their stdin hook input here. <host> defaults to claude-code, the only
# host there was before the resolver; pass the caller's type for any other.
agmsg_session_team_name_from_id() {
  agmsg_session_team_enabled || { printf ''; return 0; }
  local host="${2:-claude-code}" bare
  bare="$(agmsg_session_normalize_sid "$host" "${1:-}")"
  agmsg_session_team_for "$host" "$bare"
}

# Decode a session team name into "<host> <bare id>" (both empty when the name
# is not shaped like any host's session team). Name shape only: whether a
# marker-requiring host's team is trustworthy is agmsg_session_team_class's job.
agmsg_session_team_decode() {
  local team="$1" host prefix rest
  while IFS= read -r host; do
    [ -n "$host" ] || continue
    prefix="$(_agmsg_st_conf "$host" session_team_prefix)"
    [ -n "$prefix" ] || continue
    case "$team" in "$prefix"?*) ;; *) continue ;; esac
    rest="${team#"$prefix"}"
    [ -n "$(agmsg_session_normalize_sid "$host" "$rest")" ] || continue
    printf '%s %s' "$host" "$rest"
    return 0
  done <<EOF2
$(agmsg_session_hosts)
EOF2
  return 0
}

# Team name a SessionStart/End hook of <type> assigns session <sid>, ignoring the
# runtime mode flag (teardown must find the team even if the mode was switched
# off mid-session). Host types get their prefixed team (empty for an invalid
# id); types with no session identity keep the legacy s-<bare id> name, which
# matches no spawn record.
agmsg_session_hook_team() {
  local type="$1" sid="$2" bare
  if [ -n "$(_agmsg_st_conf "$type" session_env)" ]; then
    bare="$(agmsg_session_normalize_sid "$type" "$sid")"
    agmsg_session_team_for "$type" "$bare"
    return 0
  fi
  printf 's-%s' "${sid%%.*}"
}

# 0 when <type>'s session teams must carry teams/<team>/.session-team (see
# agmsg_session_team_class).
agmsg_session_needs_marker() {
  [ "$(_agmsg_st_conf "$1" session_marker)" = yes ]
}

# --- resolver --------------------------------------------------------------

# Resolve the caller's identity into globals:
#   AGMSG_SESSION_STATE  ok | none | ambiguous
#   AGMSG_SESSION_HOST   the host (type) when ok
#   AGMSG_SESSION_SID    the bare session id when ok
#   AGMSG_SESSION_TEAM   the session team name when ok and mode is enabled
# Usage: agmsg_session_resolve [<type> <explicit-sid>]
# With an explicit sid the host is the caller's type and the env is not read.
agmsg_session_resolve() {
  local type="${1:-}" xsid="${2:-}" host bare envname val n=0 hit_host="" hit_sid=""
  AGMSG_SESSION_STATE=none; AGMSG_SESSION_HOST=""; AGMSG_SESSION_SID=""; AGMSG_SESSION_TEAM=""

  if [ -n "$xsid" ]; then
    if [ -z "$(_agmsg_st_conf "$type" session_env)" ]; then
      AGMSG_SESSION_STATE=ambiguous
      return 0
    fi
    bare="$(agmsg_session_normalize_sid "$type" "$xsid")"
    if [ -z "$bare" ]; then
      AGMSG_SESSION_STATE=ambiguous
      return 0
    fi
    AGMSG_SESSION_STATE=ok; AGMSG_SESSION_HOST="$type"; AGMSG_SESSION_SID="$bare"
  else
    while IFS= read -r host; do
      [ -n "$host" ] || continue
      envname="$(_agmsg_st_conf "$host" session_env)"
      val="${!envname:-}"
      [ -n "$val" ] || continue
      n=$((n + 1))
      hit_host="$host"
      hit_sid="$(agmsg_session_normalize_sid "$host" "$val")"
      [ -n "$hit_sid" ] || { AGMSG_SESSION_STATE=ambiguous; return 0; }
    done <<EOF
$(agmsg_session_hosts)
EOF
    if [ "$n" -gt 1 ]; then
      AGMSG_SESSION_STATE=ambiguous
      return 0
    fi
    [ "$n" -eq 1 ] || return 0
    AGMSG_SESSION_STATE=ok; AGMSG_SESSION_HOST="$hit_host"; AGMSG_SESSION_SID="$hit_sid"
  fi

  if agmsg_session_team_enabled; then
    AGMSG_SESSION_TEAM="$(agmsg_session_team_for "$AGMSG_SESSION_HOST" "$AGMSG_SESSION_SID")"
  fi
  return 0
}

# Convenience: the session team of the env-identified caller (any host), empty
# when there is none, it is ambiguous, or mode is off.
agmsg_session_team_name() {
  agmsg_session_resolve
  [ "$AGMSG_SESSION_STATE" = ok ] || return 0
  # a team that merely shares a marker host's session team name is not one
  [ "$(agmsg_session_team_class "$AGMSG_SESSION_TEAM")" = session ] || return 0
  printf '%s' "$AGMSG_SESSION_TEAM"
  return 0
}

# --- classification --------------------------------------------------------

# Classify a team name as a session team, a project team, or unknown (a host
# that needs a marker could not read it). Guards and watchdog use this; nothing
# destructive does. A prefix is not reserved against project team names, so a
# host that sets session_marker=yes is only trusted when
# teams/<team>/.session-team names that host; legacy s-<id> teams (no marker
# requirement) classify by name as before.
agmsg_session_team_class() {
  local team="$1" host prefix rest sd marker content
  sd="$(agmsg_session_team_scripts_dir)" || { printf 'unknown'; return 0; }
  while IFS= read -r host; do
    [ -n "$host" ] || continue
    prefix="$(_agmsg_st_conf "$host" session_team_prefix)"
    [ -n "$prefix" ] || continue
    case "$team" in "$prefix"?*) ;; *) continue ;; esac
    rest="${team#"$prefix"}"
        [ -n "$(agmsg_session_normalize_sid "$host" "$rest")" ] || continue
    if [ "$(_agmsg_st_conf "$host" session_marker)" != yes ]; then
      printf 'session'; return 0
    fi
    marker="$sd/../teams/$team/.session-team"
    if [ -L "$marker" ]; then printf 'unknown'; return 0; fi
    if [ ! -e "$marker" ]; then
      if [ -d "$sd/../teams/$team" ] || [ ! -e "$sd/../teams/$team" ]; then
        printf 'project'; return 0
      fi
      printf 'unknown'; return 0
    fi
    if ! content="$(cat "$marker" 2>/dev/null)"; then printf 'unknown'; return 0; fi
    if [ "$content" = "$host" ]; then printf 'session'; else printf 'unknown'; fi
    return 0
  done <<EOF
$(agmsg_session_hosts)
EOF
  printf 'project'
}
