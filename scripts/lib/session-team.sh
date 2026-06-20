#!/usr/bin/env bash
# session-team.sh — opt-in "one team per Claude session" mode.
#
# When delivery.session_team is enabled, a Claude session uses a team named
#   s-<bare CLAUDE_CODE_SESSION_ID>
# instead of the project-derived team. Every agmsg scope (messages, watch
# delivery, history, actas locks, the codex worker) already keys on team, so
# this isolates concurrent / resumed Claude sessions that share a directory
# without adding any per-message axis. The bare session UUID is stable across
# --continue/--resume, so a resumed session returns to the same team — and its
# persisted history. Disabled (or no session id) => callers fall back to the
# normal project->team resolution.
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

# Echo the session team name (s-<bare-uuid>) when mode is enabled AND a bare
# session id is available; empty otherwise. The bare CLAUDE_CODE_SESSION_ID is
# used deliberately (NOT the "<uuid>.<pid>" instance id): it is preserved across
# --continue/--resume, so a resumed session keeps the same team instead of
# splitting per process. A composite token, if ever passed, is reduced to its
# bare part (UUIDs contain no '.').
agmsg_session_team_name() {
  agmsg_session_team_enabled || { printf ''; return 0; }
  local sid="${CLAUDE_CODE_SESSION_ID:-}"
  [ -n "$sid" ] || { printf ''; return 0; }
  printf 's-%s' "${sid%%.*}"
}
