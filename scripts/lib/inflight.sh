#!/usr/bin/env bash

# Durable per-turn consumption records. A record is published after message
# ids are known and before mark-read. Absence of a record must not authorize
# teardown. Reaping sends an at-least-once dead-letter only after the recorded
# process generation is dead or replaced. Retry uses an outbox that does not
# depend on a spawn record.
[ -n "${_AGMSG_INFLIGHT_SH:-}" ] && return 0
_AGMSG_INFLIGHT_SH=1

: "${SKILL_DIR:?inflight.sh requires SKILL_DIR}"

_agmsg_inflight_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$_agmsg_inflight_lib_dir/actas-lock.sh"
# shellcheck disable=SC1091
. "$_agmsg_inflight_lib_dir/type-registry.sh"
# shellcheck disable=SC1091
. "$_agmsg_inflight_lib_dir/validate.sh"
if ! command -v agmsg_db_path >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  . "$_agmsg_inflight_lib_dir/storage.sh"
fi

AGMSG_INFLIGHT_VERSION=1
AGMSG_INFLIGHT_MAX_SENDERS=31

_agmsg_inflight_genkey() {
  local digest=""
  if command -v openssl >/dev/null 2>&1; then
    digest="$(printf '%s' "$1" | openssl dgst -sha256 2>/dev/null | awk '{print $NF}')"
  fi
  if [ -z "$digest" ] && command -v shasum >/dev/null 2>&1; then
    digest="$(printf '%s' "$1" | shasum -a 256 2>/dev/null | awk '{print $1}')"
  fi
  if [ -z "$digest" ]; then
    digest="$(printf '%s' "$1" | cksum | awk '{print $1 $2}')"
  fi
  [ -n "$digest" ] || return 1
  printf '%s' "$digest" | awk '{ print substr($0, 1, 16) }'
}

agmsg_inflight_path() {
  local team="$1" name="$2" epoch="$3" start="$4" genkey
  [ -n "$start" ] || return 1
  genkey="$(_agmsg_inflight_genkey "$start")" || return 1
  printf '%s/run/inflight-record.%s=%s.%s.%s' "$SKILL_DIR" \
    "$(_actas_lock_encode "$team")" "$(_actas_lock_encode "$name")" "$genkey" "$epoch"
}

agmsg_inflight_outbox_dir() {
  local team="$1" name="$2"
  printf '%s/run/inflight-outbox.%s=%s' "$SKILL_DIR" \
    "$(_actas_lock_encode "$team")" "$(_actas_lock_encode "$name")"
}

_agmsg_inflight_encoded_canonical() {
  local encoded="$1" decoded
  decoded="$(_actas_lock_decode "$encoded" 2>/dev/null)" || return 1
  [ "$(_actas_lock_encode "$decoded" 2>/dev/null)" = "$encoded" ] || return 1
  printf '%s' "$decoded"
}

_agmsg_inflight_log_sanitize() {
  # Must not fail under `set -euo pipefail`: callers interpolate this in logs.
  local cleaned=""
  cleaned="$(printf '%s' "$1" | LC_ALL=C tr -d '\001-\037\177' 2>/dev/null | awk '{ print substr($0, 1, 80) }' 2>/dev/null)" || cleaned=""
  printf '%s' "${cleaned:-$1}"
}

_agmsg_inflight_ids_ok() {
  agmsg_validate_message_id_csv "$1"
}

_agmsg_inflight_sql_id_list() {
  agmsg_message_ids_sql_in_clause "$1"
}

_agmsg_inflight_read_field() {
  local line="$1" key="$2"
  case "$line" in "$key="*) printf '%s' "${line#*=}" ;; *) return 1 ;; esac
}

# Classify the recorded bridge PID.
# 0: live, same process generation
# 1: not running
# 2: live, different generation
# 3: live, generation unverifiable
_agmsg_inflight_generation() {
  local pid="$1" recorded_start="$2" current_start recorded_method current_method
  _agmsg_pid_alive "$pid" || return 1
  if [ -z "$recorded_start" ]; then
    return 3
  fi
  current_start="$(agmsg_pid_start_token "$pid" 2>/dev/null)" || return 3
  recorded_method="$(agmsg_pid_start_token_method "$recorded_start" 2>/dev/null || true)"
  current_method="$(agmsg_pid_start_token_method "$current_start" 2>/dev/null || true)"
  if [ -z "$recorded_method" ] || [ -z "$current_method" ] \
      || [ "$recorded_method" != "$current_method" ]; then
    return 3
  fi
  [ "$current_start" = "$recorded_start" ] && return 0
  return 2
}

# Populate AGMSG_INFLIGHT_* from one strict record. Returns 1 when malformed.
agmsg_inflight_read() {
  local path="$1" line key enc_team enc_name epoch_from_path rest genkey_from_path pair
  local version team worker type epoch created bridge_pid bridge_start count
  local sender_enc ids decoded_sender i
  local -a lines=()

  AGMSG_INFLIGHT_PATH="$path"
  AGMSG_INFLIGHT_TEAM=""
  AGMSG_INFLIGHT_WORKER=""
  AGMSG_INFLIGHT_TYPE=""
  AGMSG_INFLIGHT_EPOCH=""
  AGMSG_INFLIGHT_CREATED=""
  AGMSG_INFLIGHT_BRIDGE_PID=""
  AGMSG_INFLIGHT_BRIDGE_START=""
  AGMSG_INFLIGHT_SENDERS=()
  AGMSG_INFLIGHT_IDS=()

  [ -f "$path" ] && [ ! -L "$path" ] && [ -O "$path" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    lines[${#lines[@]}]="$line"
    [ "${#lines[@]}" -le 40 ] || return 1
  done <"$path"
  [ "${#lines[@]}" -ge 10 ] || return 1
  version="$(_agmsg_inflight_read_field "${lines[0]}" version)" || return 1
  [ "$version" = "$AGMSG_INFLIGHT_VERSION" ] || return 1
  team="$(_agmsg_inflight_read_field "${lines[1]}" team)" || return 1
  worker="$(_agmsg_inflight_read_field "${lines[2]}" worker)" || return 1
  type="$(_agmsg_inflight_read_field "${lines[3]}" type)" || return 1
  epoch="$(_agmsg_inflight_read_field "${lines[4]}" epoch)" || return 1
  created="$(_agmsg_inflight_read_field "${lines[5]}" created)" || return 1
  bridge_pid="$(_agmsg_inflight_read_field "${lines[6]}" bridge_pid)" || return 1
  bridge_start="$(_agmsg_inflight_read_field "${lines[7]}" bridge_start)" || return 1
  count="$(_agmsg_inflight_read_field "${lines[8]}" count)" || return 1

  AGMSG_INFLIGHT_TEAM="$(_agmsg_inflight_encoded_canonical "$team")" || return 1
  AGMSG_INFLIGHT_WORKER="$(_agmsg_inflight_encoded_canonical "$worker")" || return 1
  AGMSG_INFLIGHT_BRIDGE_START="$(_agmsg_inflight_encoded_canonical "$bridge_start")" || return 1
  AGMSG_INFLIGHT_TYPE="$type"
  AGMSG_INFLIGHT_EPOCH="$epoch"
  AGMSG_INFLIGHT_CREATED="$created"
  AGMSG_INFLIGHT_BRIDGE_PID="$bridge_pid"

  case "$epoch" in ''|*[!0-9]*) return 1 ;; esac
  [ "$epoch" -gt 0 ] 2>/dev/null || return 1
  case "$created" in ''|*[!0-9]*) return 1 ;; esac
  case "$bridge_pid" in ''|*[!0-9]*) return 1 ;; esac
  [ "$bridge_pid" -gt 0 ] 2>/dev/null || return 1
  case "$count" in ''|*[!0-9]*) return 1 ;; esac
  [ "$count" -gt 0 ] 2>/dev/null || return 1
  [ "${#lines[@]}" -eq $((9 + count)) ] || return 1
  [ -n "$AGMSG_INFLIGHT_BRIDGE_START" ] || return 1
  agmsg_is_known_type "$type" || return 1
  [ "$(agmsg_type_get "$type" headless no)" = yes ] || return 1

  key="${path##*/inflight-record.}"
  epoch_from_path="${key##*.}"
  rest="${key%.*}"
  genkey_from_path="${rest##*.}"
  pair="${rest%.*}"
  enc_team="${pair%%=*}"
  enc_name="${pair#*=}"
  [ "$enc_team" != "$pair" ] && [ -n "$enc_name" ] || return 1
  [ "$epoch_from_path" = "$epoch" ] || return 1
  [ "$(_actas_lock_encode "$AGMSG_INFLIGHT_TEAM")" = "$enc_team" ] || return 1
  [ "$(_actas_lock_encode "$AGMSG_INFLIGHT_WORKER")" = "$enc_name" ] || return 1
  [ "$(_agmsg_inflight_genkey "$AGMSG_INFLIGHT_BRIDGE_START")" = "$genkey_from_path" ] || return 1

  i=0
  while [ "$i" -lt "$count" ]; do
    line="${lines[$((9 + i))]}"
    sender_enc="${line%%=*}"
    ids="${line#*=}"
    [ "$sender_enc" != "$line" ] && [ -n "$sender_enc" ] || return 1
    _agmsg_inflight_ids_ok "$ids" || return 1
    decoded_sender="$(_agmsg_inflight_encoded_canonical "$sender_enc")" || return 1
    [ -n "$decoded_sender" ] || return 1
    AGMSG_INFLIGHT_SENDERS+=("$decoded_sender")
    AGMSG_INFLIGHT_IDS+=("$ids")
    i=$((i + 1))
  done
}

# consumers_file: one `sender<TAB or US>ids` line per sender.
agmsg_inflight_write() {
  local team="$1" name="$2" type="$3" epoch="$4" pid="$5" start="$6" consumers="$7"
  local created path tmp count line sender ids fs=$'\t' us=$'\x1f'
  local -a sender_lines=()

  [ -n "$team" ] && [ -n "$name" ] && [ -n "$type" ] || return 1
  [ -n "$start" ] || return 1
  [ -f "$consumers" ] && [ ! -L "$consumers" ] || return 1
  case "$epoch" in ''|*[!0-9]*) return 1 ;; esac
  [ "$epoch" -gt 0 ] 2>/dev/null || return 1
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ "$pid" -gt 0 ] 2>/dev/null || return 1
  agmsg_is_known_type "$type" || return 1
  [ "$(agmsg_type_get "$type" headless no)" = yes ] || return 1

  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    case "$line" in
      *$us*) fs=$us ;;
    esac
    sender="${line%%$fs*}"
    ids="${line#*$fs}"
    [ -n "$sender" ] && [ "$sender" != "$line" ] || return 1
    _agmsg_inflight_ids_ok "$ids" || return 1
    sender_lines+=("$(_actas_lock_encode "$sender")=$ids")
  done <"$consumers"
  count="${#sender_lines[@]}"
  [ "$count" -gt 0 ] || return 1
  [ "$count" -le "$AGMSG_INFLIGHT_MAX_SENDERS" ] || return 1

  created="$(date +%s 2>/dev/null)" || return 1
  case "$created" in ''|*[!0-9]*) return 1 ;; esac
  mkdir -p "$SKILL_DIR/run" 2>/dev/null || return 1
  path="$(agmsg_inflight_path "$team" "$name" "$epoch" "$start")" || return 1
  [ ! -e "$path" ] || return 1
  tmp="$SKILL_DIR/run/.inflight-write.$$.$RANDOM"
  if ! (
    umask 077
    {
      printf '%s\n' \
        "version=$AGMSG_INFLIGHT_VERSION" \
        "team=$(_actas_lock_encode "$team")" \
        "worker=$(_actas_lock_encode "$name")" \
        "type=$type" \
        "epoch=$epoch" \
        "created=$created" \
        "bridge_pid=$pid" \
        "bridge_start=$(_actas_lock_encode "$start")" \
        "count=$count"
      printf '%s\n' "${sender_lines[@]}"
    } >"$tmp" && mv -n -- "$tmp" "$path" && [ ! -e "$tmp" ] && [ -f "$path" ]
  ); then
    rm -f -- "$tmp" 2>/dev/null || true
    return 1
  fi
}

agmsg_inflight_settle() {
  local team="$1" name="$2" epoch="$3" start="$4" path
  path="$(agmsg_inflight_path "$team" "$name" "$epoch" "$start")" || return 0
  rm -f -- "$path" 2>/dev/null || true
}

# Verified success is exit 0 plus a decimal count on stdout. A missing DB,
# sqlite failure, or non-numeric output is unverifiable (exit 2, no count):
# callers must keep the in-flight record and not start a turn. Printing 0 for
# those cases would fail-open and let a caller settle a still-consumed request.
agmsg_inflight_unread_count() {
  local team="$1" name="$2" ids="$3" db t_esc n_esc count id_sql
  _agmsg_inflight_ids_ok "$ids" || return 2
  id_sql="$(_agmsg_inflight_sql_id_list "$ids")" || return 2
  db="$(agmsg_db_path)" || return 2
  [ -f "$db" ] || return 2
  t_esc="$(printf '%s' "$team" | sed "s/'/''/g")"
  n_esc="$(printf '%s' "$name" | sed "s/'/''/g")"
  count="$(agmsg_sqlite "$db" "
    SELECT COUNT(*) FROM (
      SELECT e.id FROM events e
      WHERE e.type='message_sent' AND e.team='$t_esc' AND e.to_agent='$n_esc'
        AND (e.id IN ($id_sql) OR CAST(e.legacy_id AS TEXT) IN ($id_sql))
        AND NOT EXISTS (SELECT 1 FROM events r WHERE r.type='message_read'
          AND r.team=e.team AND r.agent='$n_esc' AND r.msg_id=e.id)
      UNION ALL
      SELECT CAST(m.id AS TEXT) FROM messages m
      WHERE m.team='$t_esc' AND m.to_agent='$n_esc' AND m.read_at IS NULL
        AND CAST(m.id AS TEXT) IN ($id_sql)
        AND NOT EXISTS (SELECT 1 FROM events r WHERE r.type='message_read'
          AND r.team=m.team AND r.agent='$n_esc' AND r.msg_id=CAST(m.id AS TEXT))
        AND NOT EXISTS (SELECT 1 FROM events e2 WHERE e2.legacy_id=m.id)
    );
  " 2>/dev/null)" || return 2
  count="$(printf '%s' "$count" | tr -d '\r\n')"
  case "$count" in ''|*[!0-9]*) return 2 ;; esac
  printf '%s\n' "$count"
}

_agmsg_inflight_queue_outbox() {
  local team="$1" name="$2" to="$3" body="$4" dir item
  dir="$(agmsg_inflight_outbox_dir "$team" "$name")"
  mkdir -p "$dir" 2>/dev/null || return 1
  item="$(mktemp "$dir/XXXXXX")" || return 1
  rm -f -- "$item" 2>/dev/null || true
  printf '%s' "$to" >"$item.to" || { rm -f -- "$item.to"; return 1; }
  printf '%s' "$body" >"$item.body" || { rm -f -- "$item.to" "$item.body"; return 1; }
}

agmsg_inflight_outbox_flush() {
  local team="$1" name="$2"
  # The CLI (inflight.sh) runs under `set -euo pipefail`. Isolate the flush in a
  # subshell so a send failure cannot abort remaining notices or the bridge.
  # Do not use `local` here: a subshell is not a function (bash 3.2 errors).
  (
    set +e
    set +o pipefail
    dir="$(agmsg_inflight_outbox_dir "$team" "$name")"
    [ -d "$dir" ] || exit 0
    send="$SKILL_DIR/scripts/send.sh"
    if [ ! -x "$send" ]; then
      printf 'agmsg: inflight outbox flush missing executable send=%s\n' "$send" >&2
      exit 0
    fi
    shopt -s nullglob
    for tofile in "$dir"/*.to; do
      base="${tofile%.to}"
      [ -f "$base.body" ] || continue
      to="$(cat "$tofile" 2>/dev/null)"
      [ -n "$to" ] && [ -s "$base.body" ] || continue
      # Body file as stdin: no pipeline, so pipefail cannot abort the flush.
      if "$send" "$team" "$name" "$to" --stdin --force >/dev/null 2>&1 <"$base.body"; then
        rm -f -- "$tofile" "$base.body"
        printf 'agmsg: inflight outbox delivered team=%s worker=%s to=%s\n' \
          "$(_agmsg_inflight_log_sanitize "$team")" \
          "$(_agmsg_inflight_log_sanitize "$name")" \
          "$(_agmsg_inflight_log_sanitize "$to")" >&2
      else
        printf 'agmsg: inflight outbox retained team=%s worker=%s to=%s\n' \
          "$(_agmsg_inflight_log_sanitize "$team")" \
          "$(_agmsg_inflight_log_sanitize "$name")" \
          "$(_agmsg_inflight_log_sanitize "$to")" >&2
      fi
    done
    rmdir "$dir" 2>/dev/null
    exit 0
  )
  return 0
}

agmsg_inflight_outbox_flush_all() {
  local dir key enc_team enc_name team name restore
  restore="$(shopt -p nullglob 2>/dev/null || printf '%s\n' 'shopt -u nullglob')"
  shopt -s nullglob || true
  for dir in "$SKILL_DIR"/run/inflight-outbox.*; do
    [ -d "$dir" ] || continue
    key="${dir##*/inflight-outbox.}"
    enc_team="${key%%=*}"
    enc_name="${key#*=}"
    [ "$enc_team" != "$key" ] && [ -n "$enc_name" ] || continue
    team="$(_agmsg_inflight_encoded_canonical "$enc_team")" || continue
    name="$(_agmsg_inflight_encoded_canonical "$enc_name")" || continue
    agmsg_inflight_outbox_flush "$team" "$name" || true
  done
  eval "$restore" || true
}

_agmsg_inflight_send_or_queue() {
  local team="$1" name="$2" to="$3" body="$4" send
  send="$SKILL_DIR/scripts/send.sh"
  [ -x "$send" ] || return 1
  if printf '%s' "$body" | "$send" "$team" "$name" "$to" --stdin --force >/dev/null 2>&1; then
    return 0
  fi
  _agmsg_inflight_queue_outbox "$team" "$name" "$to" "$body"
}

# Owner-initiated or reap-time notice. Does not consult liveness. Deletes the
# record only after every sender's notice is sent or queued to the spawn-free
# outbox. Duplicate notices are allowed.
agmsg_inflight_compensate() {
  local path="$1" prefix notice i sender ids body persisted=1
  local log_team log_worker
  agmsg_inflight_read "$path" || return 1
  prefix="${AGMSG_INFLIGHT_PREFIX:-turn interrupted}"
  notice="${AGMSG_INFLIGHT_NOTICE:-the worker ended before the turn settled}"
  i=0
  while [ "$i" -lt "${#AGMSG_INFLIGHT_SENDERS[@]}" ]; do
    sender="${AGMSG_INFLIGHT_SENDERS[$i]}"
    ids="${AGMSG_INFLIGHT_IDS[$i]}"
    body="[bridge-error] ${AGMSG_INFLIGHT_TYPE} $prefix (ids $ids): $notice. Messages consumed; resend to retry."
    _agmsg_inflight_send_or_queue "$AGMSG_INFLIGHT_TEAM" "$AGMSG_INFLIGHT_WORKER" \
      "$sender" "$body" || persisted=0
    i=$((i + 1))
  done
  log_team="$(_agmsg_inflight_log_sanitize "$AGMSG_INFLIGHT_TEAM")"
  log_worker="$(_agmsg_inflight_log_sanitize "$AGMSG_INFLIGHT_WORKER")"
  if [ "$persisted" -eq 1 ]; then
    rm -f -- "$path" 2>/dev/null || true
    printf 'agmsg: inflight compensated team=%s worker=%s epoch=%s reason=persisted\n' \
      "$log_team" "$log_worker" "$AGMSG_INFLIGHT_EPOCH" >&2
    return 0
  fi
  printf 'agmsg: inflight retained team=%s worker=%s epoch=%s reason=notice-unpersisted\n' \
    "$log_team" "$log_worker" "$AGMSG_INFLIGHT_EPOCH" >&2
  return 1
}

# Dead-letter only after positive proof the recorded generation is gone.
# Live same-generation records are retained. This is not a kill path.
agmsg_inflight_reap_one() {
  local path="$1" gen_rc=0 log_team log_worker
  agmsg_inflight_read "$path" || {
    printf 'agmsg: inflight retained record=%s reason=malformed\n' \
      "$(_agmsg_inflight_log_sanitize "${path##*/}")" >&2
    return 0
  }
  if [ -n "${AGMSG_INFLIGHT_ONLY_TEAM:-}" ] \
      && [ "$AGMSG_INFLIGHT_TEAM" != "$AGMSG_INFLIGHT_ONLY_TEAM" ]; then
    return 0
  fi
  if [ -n "${AGMSG_INFLIGHT_SKIP_TEAM:-}" ] \
      && [ "$AGMSG_INFLIGHT_TEAM" = "$AGMSG_INFLIGHT_SKIP_TEAM" ]; then
    return 0
  fi
  _agmsg_inflight_generation "$AGMSG_INFLIGHT_BRIDGE_PID" \
    "$AGMSG_INFLIGHT_BRIDGE_START" || gen_rc=$?
  log_team="$(_agmsg_inflight_log_sanitize "$AGMSG_INFLIGHT_TEAM")"
  log_worker="$(_agmsg_inflight_log_sanitize "$AGMSG_INFLIGHT_WORKER")"
  case "$gen_rc" in
    0)
      printf 'agmsg: inflight retained team=%s worker=%s epoch=%s reason=bridge-live\n' \
        "$log_team" "$log_worker" "$AGMSG_INFLIGHT_EPOCH" >&2
      return 0
      ;;
    3)
      printf 'agmsg: inflight retained team=%s worker=%s epoch=%s reason=generation-unverified\n' \
        "$log_team" "$log_worker" "$AGMSG_INFLIGHT_EPOCH" >&2
      return 0
      ;;
  esac
  AGMSG_INFLIGHT_PREFIX="${AGMSG_INFLIGHT_PREFIX:-turn interrupted}" \
    AGMSG_INFLIGHT_NOTICE="${AGMSG_INFLIGHT_NOTICE:-the worker ended before the turn settled}" \
    agmsg_inflight_compensate "$path" || true
}

agmsg_inflight_reap_dead() {
  local path restore rc=0
  mkdir -p "$SKILL_DIR/run" 2>/dev/null || return 0
  restore="$(shopt -p nullglob)" || true
  shopt -s nullglob || true
  for path in "$SKILL_DIR"/run/inflight-record.*; do
    [ -f "$path" ] || continue
    agmsg_inflight_reap_one "$path" || true
  done
  eval "$restore" || true
  agmsg_inflight_outbox_flush_all || true
  return 0
}

agmsg_inflight_deadletter_for() {
  local team="$1" name="$2" path restore
  [ -n "$team" ] && [ -n "$name" ] || return 1
  agmsg_inflight_outbox_flush "$team" "$name" || true
  restore="$(shopt -p nullglob)" || true
  shopt -s nullglob || true
  for path in "$SKILL_DIR"/run/inflight-record."$(_actas_lock_encode "$team")"="$(_actas_lock_encode "$name")".*; do
    [ -f "$path" ] || continue
    agmsg_inflight_reap_one "$path" || true
  done
  eval "${restore:-:}" || true
  return 0
}

# Reap leftover records for a team that is itself being deleted.
# After reap, remaining records are live same-generation or generation-unverified.
# Those must stay (and the caller must keep team state) so a later bridge death
# can still dead-letter. Return 1 when any such record remains.
# Unflushed outboxes are retry state and are not deleted here.
agmsg_inflight_gc_team() {
  local team="$1" enc path restore remaining=0
  [ -n "$team" ] || return 0
  AGMSG_INFLIGHT_ONLY_TEAM="$team" agmsg_inflight_reap_dead || true
  enc="$(_actas_lock_encode "$team")"
  restore="$(shopt -p nullglob 2>/dev/null || printf '%s\n' 'shopt -u nullglob')"
  shopt -s nullglob || true
  for path in "$SKILL_DIR"/run/inflight-record."${enc}"=*; do
    [ -f "$path" ] || continue
    remaining=1
    break
  done
  eval "$restore" || true
  if [ "$remaining" -eq 1 ]; then
    printf 'agmsg: inflight gc retained team=%s reason=live-or-unverified\n' \
      "$(_agmsg_inflight_log_sanitize "$team")" >&2
    return 1
  fi
  return 0
}
