#!/usr/bin/env bash
# inbox-target.sh — resolve which (team, agent) THIS session's inbox is.
#
# Single resolver shared by the `stop` hook path (check-inbox.sh) and the
# injection watcher ([subtask:D]), so both agree on session-team vs. role vs.
# project-team routing instead of drifting via independent copies.
#
# Required caller-set variables (same convention as the libs sourced below):
#   SCRIPT_DIR — the scripts/ dir (whoami.sh, identities.sh live here)
#   SKILL_DIR  — agmsg skill root (actas-lock.sh / role-session.sh run/ dir)

: "${SKILL_DIR:?inbox-target.sh requires SKILL_DIR}"
: "${SCRIPT_DIR:?inbox-target.sh requires SCRIPT_DIR}"

# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/type-registry.sh"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/resolve-project.sh"  # agmsg_agent_pid, for agmsg_normalize_instance_id
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/session-team.sh"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/role-session.sh"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/actas-lock.sh"

# Resolve this session's inbox target. Echoes the SAME key=value grammar
# whoami.sh uses (agent=<a> teams=<t1,t2,...> type=<type> project=<p>, or its
# multiple=/suggest=/not_joined= variants), so callers reuse whoami.sh's
# existing parsing unchanged.
#
# Usage: agmsg_inbox_target <type> <project> <raw_session_id>
#   raw_session_id — the session id AS EXTRACTED FROM THE HOOK PAYLOAD, before
#   any instance-id normalization. agmsg_session_team_name_from_id strips a
#   trailing ".<pid>" itself (session-team.sh), and role-session records key on
#   the bare id — so this must be the raw value, never a hand-built
#   "s-$SESSION_ID": a caller's own SESSION_ID var is typically already
#   normalized to the "<sid>.<pid>" instance-id form for its own dedup checks,
#   and concatenating that by hand is what produces a broken "s-<sid>.<pid>"
#   team name instead of the correct "s-<sid>".
agmsg_inbox_target() {
  local type="$1" project="$2" raw_sid="$3"

  # Session-team routing needs BOTH the type's capability (session_team=yes in
  # its type.conf) AND the runtime opt-in (delivery.session_team). Capability
  # alone would read a never-created "claude@s-<sid>" once a type opts in,
  # silently stopping ordinary project-team delivery for everyone still on
  # delivery.session_team=false.
  if agmsg_type_has "$type" session_team yes && agmsg_session_team_enabled; then
    local steam
    steam="$(agmsg_session_team_name_from_id "$raw_sid")"
    if [ -n "$steam" ]; then
      # Role priority: mirrors session-start.sh's resumed-role directive taking
      # precedence over the session-team branch (its role lookup runs first and
      # exits before ever reaching session-team there) — reversing the order
      # would give this resolver a different opinion than session-start.sh's
      # Monitor directive about which identity a resumed role session is.
      local bare_sid rec r_agent r_team pairs instance_id state
      bare_sid="$(agmsg_instance_bare_sid "$raw_sid" 2>/dev/null || printf '%s' "$raw_sid")"
      rec="$(agmsg_role_session_lookup_by_sid "$bare_sid" 2>/dev/null || true)"
      if [ -n "$rec" ]; then
        r_agent="$(printf '%s\n' "$rec" | sed -n 's/^agent=//p' | head -1)"
        r_team="$(printf '%s\n' "$rec" | sed -n 's/^team=//p' | head -1)"
        # Cross-project sid collision guard, same as session-start.sh: only
        # honor the record when its (team, agent) is registered for THIS
        # project/type.
        pairs="$("$SCRIPT_DIR/identities.sh" "$project" "$type" 2>/dev/null || true)"
        if [ -n "$r_agent" ] && [ -n "$r_team" ] \
            && printf '%s\n' "$pairs" | grep -Fxq "$(printf '%s\t%s' "$r_team" "$r_agent")"; then
          # A live different session already holding this role's actas lock is
          # the rightful owner of its inbox right now. inbox.sh has no
          # actas-lock awareness, so this is the only place that guard can
          # live (mirrors check-inbox.sh's own "other:*" skip for the
          # project-team path). Free or mine both mean this session may act
          # as the role.
          instance_id="$(agmsg_normalize_instance_id "$raw_sid" "$type" 2>/dev/null || printf '%s' "$raw_sid")"
          state="$(actas_lock_state "$r_team" "$r_agent" "$instance_id")"
          case "$state" in
            other:*) ;;
            *)
              printf 'agent=%s teams=%s type=%s project=%s\n' "$r_agent" "$r_team" "$type" "$project"
              return 0
              ;;
          esac
        fi
      fi
      printf 'agent=claude teams=%s type=%s project=%s\n' "$steam" "$type" "$project"
      return 0
    fi
    # steam empty (no usable session id) -- fall through to project-team below.
  fi

  "$SCRIPT_DIR/whoami.sh" "$project" "$type"
}
