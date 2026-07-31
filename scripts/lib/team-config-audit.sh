#!/usr/bin/env bash
# team-config-audit.sh — best-effort audit lines for team registry mutations.
#
# Callers invoke agmsg_team_config_audit only after a successful logical
# mutation. This helper never decides whether an operation succeeded or was a
# no-op, and it never changes team configuration.
#
# Fixed action vocabulary: join, leave, reset, rename-team, rename-agent.
#
# rename-team column semantics are fixed here for every later callsite:
#   team  = the old/source team, agent = empty, detail = the new team.
# rename-agent uses team = the containing team, agent = the old agent, and
# detail = the new agent.

: "${SKILL_DIR:?team-config-audit.sh requires SKILL_DIR}"

_AGMSG_TEAM_CONFIG_AUDIT_CAP_DEFAULT=5000

_agmsg_team_config_audit_sanitize() {
  # awk receives one record per input line, so explicitly replace record
  # separators as well as every remaining C0/DEL control byte. The shell
  # cannot carry NUL in an argument; all representable control bytes are
  # handled here.
  LC_ALL=C awk '
    BEGIN { ORS = "" }
    {
      if (NR > 1) printf " "
      gsub(/[\001-\011\013-\037\177]/, " ")
      printf "%s", $0
    }
  '
}

agmsg_team_config_audit() {
  local team="$1" action="$2" agent="$3" detail="$4"
  local caller timestamp pid line run_dir log lock cap tmp

  case "$action" in
    join|leave|reset|rename-team|rename-agent) ;;
    *) return 0 ;;
  esac

  caller="${0##*/}"
  [ -n "$caller" ] || caller="unknown"
  timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || true)"
  case "$timestamp" in
    ????-??-??T??:??:??Z) ;;
    *) return 0 ;;
  esac
  pid="$$"

  team="$(_agmsg_team_config_audit_sanitize <<<"$team" 2>/dev/null || true)"
  action="$(_agmsg_team_config_audit_sanitize <<<"$action" 2>/dev/null || true)"
  agent="$(_agmsg_team_config_audit_sanitize <<<"$agent" 2>/dev/null || true)"
  detail="$(_agmsg_team_config_audit_sanitize <<<"$detail" 2>/dev/null || true)"
  caller="$(_agmsg_team_config_audit_sanitize <<<"$caller" 2>/dev/null || true)"
  timestamp="$(_agmsg_team_config_audit_sanitize <<<"$timestamp" 2>/dev/null || true)"
  pid="$(_agmsg_team_config_audit_sanitize <<<"$pid" 2>/dev/null || true)"

  run_dir="$SKILL_DIR/run"
  log="$run_dir/team-config-audit.log"
  lock="$run_dir/team-config-audit.lock"
  cap="${AGMSG_TEAM_CONFIG_AUDIT_CAP:-$_AGMSG_TEAM_CONFIG_AUDIT_CAP_DEFAULT}"
  case "$cap" in ''|*[!0-9]*) cap="$_AGMSG_TEAM_CONFIG_AUDIT_CAP_DEFAULT" ;; esac
  [ "$cap" -gt 0 ] || cap="$_AGMSG_TEAM_CONFIG_AUDIT_CAP_DEFAULT"
  line="$timestamp	$pid	$caller	$team	$action	$agent	$detail"

  mkdir -p "$run_dir" 2>/dev/null || return 0
  # Non-blocking mkdir lock: contention, permission errors, and any other
  # lock failure deliberately drop this best-effort audit event.
  mkdir "$lock" 2>/dev/null || return 0

  if ! printf '%s\n' "$line" >> "$log" 2>/dev/null; then
    rmdir "$lock" 2>/dev/null || true
    return 0
  fi

  # Keep append and trim under the same lock. If trim cannot complete, retain
  # the successfully appended log rather than failing or rolling it back.
  tmp="$(mktemp "$run_dir/.team-config-audit.trim.XXXXXX" 2>/dev/null || true)"
  if [ -n "$tmp" ]; then
    if ! tail -n "$cap" "$log" > "$tmp" 2>/dev/null || ! mv -f "$tmp" "$log" 2>/dev/null; then
      rm -f "$tmp" 2>/dev/null || true
    fi
  fi
  rmdir "$lock" 2>/dev/null || true
  return 0
}
