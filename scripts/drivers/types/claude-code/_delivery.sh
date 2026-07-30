#!/usr/bin/env bash
# claude-code delivery plug and headless bridge delivery helpers.
#
# The delivery hook functions are sourced by delivery.sh. The bridge helpers
# are sourced by claude-code-bridge.sh and watch-once.sh after storage.sh,
# actas-lock.sh, and subscription.sh have been loaded.

agmsg_delivery_on_enable() {
  echo "Future sessions: SessionStart hook will auto-launch the watcher."
  emit_monitor_directive "$2" "$3"
}

# Resolve the currently eligible subscription rows for this worker. Ownership
# is intentionally re-read on every call: watch-once invokes this on each poll,
# and the bridge invokes it again after a wake before fetching any message.
agmsg_claude_code_eligible_pairs() {
  local project="$1" type="$2" team_filter="${3:-}" name_filter="${4:-}"
  local requested_pairs="${5:-}" pairs selected="" team name

  pairs="$(agmsg_subscription_pairs "$project" "$type" "" "$name_filter")" || return 1
  while IFS=$'\t' read -r team name; do
    [ -n "$team" ] && [ -n "$name" ] || continue
    [ -z "$team_filter" ] || [ "$team" = "$team_filter" ] || continue
    if [ -n "$requested_pairs" ]; then
      printf '%s\n' "$requested_pairs" \
        | grep -Fxq "${team}"$'\t'"${name}" || continue
    fi
    selected="${selected:+$selected$'\n'}${team}"$'\t'"${name}"
  done <<< "$pairs"
  printf '%s' "$selected"
}

agmsg_claude_code_sql_escape() {
  printf '%s' "$1" | sed "s/'/''/g"
}

# Test-only fault seam used by the Layer-1 fake-CLI suite. Production callers
# leave AGMSG_CLAUDE_BRIDGE_DB_FAIL_AT unset.
agmsg_claude_code_db_fault() {
  local phase="$1"
  case ",${AGMSG_CLAUDE_BRIDGE_DB_FAIL_AT:-}," in
    *",$phase,"*) return 0 ;;
    *) return 1 ;;
  esac
}

# Print the global outbound watermark. A missing DB or any malformed result is
# an error, not watermark zero: zero would let a later bridge notice masquerade
# as the worker's reply.
agmsg_claude_code_max_id() {
  agmsg_claude_code_db_fault watermark && return 1
  local db value
  db="$(agmsg_db_path)" || return 1
  [ -f "$db" ] || return 1
  value="$(agmsg_sqlite "$db" \
    "SELECT COALESCE(MAX(id), 0) FROM messages;" 2>/dev/null)" || return 1
  value="$(printf '%s' "$value" | tr -d '\r\n')"
  case "$value" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$value"
}

# Return success only when a message sent by this worker exists after the
# supplied watermark. Recipient is deliberately unconstrained: a turn may
# answer any sender represented in its batch.
agmsg_claude_code_has_outbound_after() {
  local team="$1" from="$2" watermark="$3" db count t_esc f_esc
  agmsg_claude_code_db_fault outbound && return 2
  case "$watermark" in ''|*[!0-9]*) return 2 ;; esac
  db="$(agmsg_db_path)" || return 2
  [ -f "$db" ] || return 2
  t_esc="$(agmsg_claude_code_sql_escape "$team")"
  f_esc="$(agmsg_claude_code_sql_escape "$from")"
  count="$(agmsg_sqlite "$db" "
    SELECT COUNT(*) FROM messages
    WHERE team='$t_esc' AND from_agent='$f_esc' AND id > $watermark;
  " 2>/dev/null)" || return 2
  count="$(printf '%s' "$count" | tr -d '\r\n')"
  case "$count" in ''|*[!0-9]*) return 2 ;; esac
  [ "$count" -gt 0 ]
}

# Mark exactly the selected ids, then independently verify that none remains
# unread. inbox.sh's ack path is intentionally best-effort and returns zero on a
# sqlite failure, so the verification query is required before launching a turn.
agmsg_claude_code_mark_exact() {
  local team="$1" name="$2" ids="$3" db count t_esc n_esc
  case "$ids" in
    ''|*[!0-9,]*|,*|*,|*,,*) return 1 ;;
  esac
  agmsg_claude_code_db_fault mark && return 1
  "$SKILL_DIR/scripts/inbox.sh" "$team" "$name" \
    --mark-read-ids "$ids" >/dev/null 2>&1 || return 1
  db="$(agmsg_db_path)" || return 1
  [ -f "$db" ] || return 1
  t_esc="$(agmsg_claude_code_sql_escape "$team")"
  n_esc="$(agmsg_claude_code_sql_escape "$name")"
  count="$(agmsg_sqlite "$db" "
    SELECT COUNT(*) FROM messages
    WHERE team='$t_esc' AND to_agent='$n_esc'
      AND read_at IS NULL AND id IN ($ids);
  " 2>/dev/null)" || return 1
  count="$(printf '%s' "$count" | tr -d '\r\n')"
  [ "$count" = 0 ]
}
