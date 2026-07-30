#!/usr/bin/env bash
# A daemon must survive ordinary non-zero helper results. Keep nounset and
# pipefail, but guard every fallible operation explicitly.
set -uo pipefail

usage() {
  cat <<'EOF'
Usage: claude-code-bridge.sh --project <path> --team <team> --name <agent>
       [--model <model>] [--effort <level>] [--settings <json-or-file>]
       [--add-dir <path>] [--disallowedTools <tools>] [--role-file <path>]
       [--output-format json]
       [--interval <sec>] [--watch-timeout <sec>] [--turn-timeout <sec>]
       [--max-wakes <n>] [--once] [--identity-key <opaque>]

Headless one-shot Claude Code bridge for agmsg.

Environment:
  AGMSG_CLAUDE_CMD                    claude executable (default: claude)
  AGMSG_CLAUDE_BRIDGE_TURN_TIMEOUT    per-turn timeout in seconds (default: 300)
  AGMSG_CLAUDE_BRIDGE_TERM_GRACE      TERM-to-KILL grace in seconds (default: 2)
  AGMSG_CLAUDE_BRIDGE_BATCH_BYTES     stdin batch cap (default/max: 1048576)
EOF
}

PROJECT=""
TEAM=""
NAME=""
TYPE="claude-code"
MODEL=""
EFFORT=""
SETTINGS=""
OUTPUT_FORMAT="json"
ROLE_FILE=""
INTERVAL="${AGMSG_WATCH_ONCE_INTERVAL:-2}"
WATCH_TIMEOUT="${AGMSG_WATCH_ONCE_TIMEOUT:-300}"
TURN_TIMEOUT="${AGMSG_CLAUDE_BRIDGE_TURN_TIMEOUT:-300}"
TERM_GRACE="${AGMSG_CLAUDE_BRIDGE_TERM_GRACE:-2}"
MAX_WAKES=0
ONCE=0
ADD_DIRS=()
DISALLOWED_TOOLS=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --project) PROJECT="${2:?--project needs a path}"; shift 2 ;;
    --team) TEAM="${2:?--team needs a name}"; shift 2 ;;
    --name) NAME="${2:?--name needs a name}"; shift 2 ;;
    --type) TYPE="${2:?--type needs a value}"; shift 2 ;;
    --model) MODEL="${2:?--model needs a value}"; shift 2 ;;
    --effort) EFFORT="${2:?--effort needs a value}"; shift 2 ;;
    --settings|--settings-file) SETTINGS="${2:?--settings needs a value}"; shift 2 ;;
    --output-format) OUTPUT_FORMAT="${2:?--output-format needs a value}"; shift 2 ;;
    --add-dir) ADD_DIRS+=("${2:?--add-dir needs a path}"); shift 2 ;;
    --disallowedTools) DISALLOWED_TOOLS+=("${2:?--disallowedTools needs a value}"); shift 2 ;;
    --add-dirs-file)
      while IFS= read -r _add_dir; do
        [ -n "$_add_dir" ] && ADD_DIRS+=("$_add_dir")
      done < "${2:?--add-dirs-file needs a path}"
      shift 2 ;;
    --role-file) ROLE_FILE="${2:?--role-file needs a path}"; shift 2 ;;
    --interval) INTERVAL="${2:?--interval needs seconds}"; shift 2 ;;
    --watch-timeout|--timeout) WATCH_TIMEOUT="${2:?--watch-timeout needs seconds}"; shift 2 ;;
    --turn-timeout) TURN_TIMEOUT="${2:?--turn-timeout needs seconds}"; shift 2 ;;
    --max-wakes) MAX_WAKES="${2:?--max-wakes needs a number}"; shift 2 ;;
    --identity-key) shift 2 ;; # argv marker used by spawn/despawn duplicate checks
    --once) ONCE=1; MAX_WAKES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "claude-code-bridge: unknown option: $1" >&2; exit 1 ;;
  esac
done

[ -n "$PROJECT" ] || { echo "claude-code-bridge: --project is required" >&2; exit 1; }
[ -n "$TEAM" ] || { echo "claude-code-bridge: --team is required" >&2; exit 1; }
[ -n "$NAME" ] || { echo "claude-code-bridge: --name is required" >&2; exit 1; }
[ "$TYPE" = "claude-code" ] || { echo "claude-code-bridge: --type must be claude-code" >&2; exit 1; }
[ -d "$PROJECT" ] || { echo "claude-code-bridge: project path is not a directory: $PROJECT" >&2; exit 1; }
[ "$OUTPUT_FORMAT" = "json" ] || { echo "claude-code-bridge: --output-format must be json" >&2; exit 1; }
case "$INTERVAL" in ''|*[!0-9]*) echo "claude-code-bridge: --interval must be a whole number" >&2; exit 1 ;; esac
case "$WATCH_TIMEOUT" in ''|*[!0-9]*) echo "claude-code-bridge: --watch-timeout must be a whole number" >&2; exit 1 ;; esac
case "$TURN_TIMEOUT" in ''|*[!0-9]*) echo "claude-code-bridge: --turn-timeout must be a whole number" >&2; exit 1 ;; esac
case "$MAX_WAKES" in ''|*[!0-9]*) echo "claude-code-bridge: --max-wakes must be a whole number" >&2; exit 1 ;; esac
case "$TERM_GRACE" in ''|*[!0-9.]*|.*|*.*.*) echo "claude-code-bridge: AGMSG_CLAUDE_BRIDGE_TERM_GRACE must be numeric" >&2; exit 1 ;; esac
[ "$INTERVAL" -gt 0 ] || INTERVAL=1
[ "$WATCH_TIMEOUT" -gt 0 ] || WATCH_TIMEOUT=1

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
SCRIPTS_DIR="$SKILL_DIR/scripts"
RUN_DIR="$SKILL_DIR/run"
# shellcheck disable=SC1091
source "$SCRIPTS_DIR/lib/storage.sh"
# shellcheck disable=SC1091
source "$SCRIPTS_DIR/lib/actas-lock.sh"
# shellcheck disable=SC1091
source "$SCRIPTS_DIR/lib/resolve-project.sh"
# shellcheck disable=SC1091
source "$SCRIPTS_DIR/lib/subscription.sh"
# shellcheck disable=SC1091
source "$SCRIPTS_DIR/lib/validate.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/_delivery.sh"

agmsg_validate_team_name "$TEAM" >/dev/null 2>&1 \
  || { echo "claude-code-bridge: team name is not a path-safe segment: $TEAM" >&2; exit 1; }
agmsg_validate_agent_name "$NAME" >/dev/null 2>&1 \
  || { echo "claude-code-bridge: agent name is not a path-safe segment: $NAME" >&2; exit 1; }

PROJECT="$(agmsg_resolve_project "$PROJECT" "$TYPE")"
mkdir -p "$RUN_DIR" 2>/dev/null \
  || { echo "claude-code-bridge: cannot create run dir: $RUN_DIR" >&2; exit 1; }

BASE="$RUN_DIR/claude-code-bridge.$TEAM.$NAME"
PIDFILE="$BASE.pid"
METAFILE="$BASE.meta"
LOGFILE="$BASE.log"
ROLE_SNAPSHOT="$BASE.role"
SESSION_FILE="$BASE.session"
CANDIDATE_FILE="$BASE.candidate"
SPOOL_FILE="$BASE.outbound.json"
PROMPT_FILE="$BASE.prompt"
ROWS_FILE="$BASE.rows"
SELECTED_FILE="$BASE.selected"
CONSUMED_FILE="$BASE.consumed"
STDOUT_FILE="$BASE.stdout.json"
STDERR_FILE="$BASE.stderr"
WATCH_FILE="$BASE.watch"
LOCK_DIR="$BASE.lock"
LOCK_OWNER="$LOCK_DIR/owner"
WORK_DIR="$RUN_DIR/claude-code-$TEAM-$NAME-cwd"

CLAUDE_CONFIG_DIR="$SKILL_DIR/db/claude-worker-home"
export CLAUDE_CONFIG_DIR
unset CLAUDE_CODE_SESSION_ID CLAUDECODE CLAUDE_CODE_CHILD_SESSION
mkdir -p "$CLAUDE_CONFIG_DIR" "$WORK_DIR" 2>/dev/null \
  || { echo "claude-code-bridge: cannot create worker config/cwd" >&2; exit 1; }
cd "$WORK_DIR" \
  || { echo "claude-code-bridge: cannot enter neutral cwd: $WORK_DIR" >&2; exit 1; }

CLAUDE_BIN="${AGMSG_CLAUDE_CMD:-claude}"
PERL_BIN="$(command -v perl 2>/dev/null || true)"
PYTHON_BIN="$(command -v python3 2>/dev/null || true)"
GROUP_RUNNER=""
if [ -n "$PERL_BIN" ] && "$PERL_BIN" -e 'exit 0' >/dev/null 2>&1; then
  GROUP_RUNNER=perl
elif [ -n "$PYTHON_BIN" ] && "$PYTHON_BIN" -c 'import os; assert hasattr(os, "setsid")' >/dev/null 2>&1; then
  GROUP_RUNNER=python
else
  echo "claude-code-bridge: perl or python3 with setsid is required for process-group isolation" >&2
  exit 1
fi

BATCH_CAP="${AGMSG_CLAUDE_BRIDGE_BATCH_BYTES:-1048576}"
case "$BATCH_CAP" in ''|*[!0-9]*) BATCH_CAP=1048576 ;; esac
[ "$BATCH_CAP" -le 1048576 ] || BATCH_CAP=1048576
[ "$BATCH_CAP" -gt 0 ] || BATCH_CAP=1048576
US=$'\x1f'

log() {
  printf 'claude-code-bridge: %s\n' "$*" >&2
}

pid_alive() {
  local pid="$1" err
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  err="$(export LC_ALL=C; kill -0 "$pid" 2>&1)" && return 0
  case "$err" in *[Nn]'o such process'*) return 1 ;; *) return 0 ;; esac
}

# Atomically serialize bridge ownership. The pidfile alone has a check/write
# race when two launchers start together.
acquire_instance() {
  local owner=""
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    printf '%s\n' "$$" > "$LOCK_OWNER"
    return 0
  fi
  owner="$(cat "$LOCK_OWNER" 2>/dev/null || true)"
  if pid_alive "$owner"; then
    echo "claude-code-bridge: already running for $TEAM/$NAME (pid $owner)" >&2
    return 1
  fi
  rm -f "$LOCK_OWNER" 2>/dev/null || true
  rmdir "$LOCK_DIR" 2>/dev/null || true
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    printf '%s\n' "$$" > "$LOCK_OWNER"
    return 0
  fi
  echo "claude-code-bridge: could not acquire instance lock for $TEAM/$NAME" >&2
  return 1
}

acquire_instance || exit 1

old_pid="$(cat "$PIDFILE" 2>/dev/null || true)"
if [ -n "$old_pid" ] && [ "$old_pid" != "$$" ] && pid_alive "$old_pid"; then
  rm -f "$LOCK_OWNER" 2>/dev/null || true
  rmdir "$LOCK_DIR" 2>/dev/null || true
  echo "claude-code-bridge: already running for $TEAM/$NAME (pid $old_pid)" >&2
  exit 1
fi

printf '%s\n' "$$" > "$PIDFILE"
printf 'pid=%s\nproject=%s\nteam=%s\nname=%s\ntype=claude-code\n' \
  "$$" "$PROJECT" "$TEAM" "$NAME" > "$METAFILE"
: >> "$LOGFILE"

[ -n "$ROLE_FILE" ] || ROLE_FILE="$ROLE_SNAPSHOT"

CHILD_PID=""
WATCH_PID=""
STOPPING=0

kill_inflight() {
  local pid="${CHILD_PID:-}" n=0
  [ -n "$pid" ] || return 0
  kill "$pid" 2>/dev/null || true
  # The wrapper's signal handler gives the CLI process group this configured
  # TERM grace before issuing KILL. Do not kill the wrapper itself before that
  # handler has had time to finish, or its detached child group could survive.
  sleep "$TERM_GRACE"
  while pid_alive "$pid" && [ "$n" -lt 20 ]; do
    sleep 0.1
    n=$((n + 1))
  done
  if pid_alive "$pid"; then
    kill -9 "$pid" 2>/dev/null || true
  fi
  wait "$pid" 2>/dev/null || true
  CHILD_PID=""
}

cleanup() {
  kill_inflight
  if [ -n "${WATCH_PID:-}" ]; then
    kill "$WATCH_PID" 2>/dev/null || true
    wait "$WATCH_PID" 2>/dev/null || true
    WATCH_PID=""
  fi

  local pid_owner meta_owner lock_owner
  pid_owner="$(cat "$PIDFILE" 2>/dev/null || true)"
  meta_owner="$(sed -n 's/^pid=//p' "$METAFILE" 2>/dev/null | head -1)"
  lock_owner="$(cat "$LOCK_OWNER" 2>/dev/null || true)"
  if [ "$pid_owner" = "$$" ] && [ "$meta_owner" = "$$" ]; then
    rm -f "$PIDFILE" "$METAFILE" "$ROLE_SNAPSHOT" \
      "$PROMPT_FILE" "$ROWS_FILE" "$SELECTED_FILE" "$CONSUMED_FILE" \
      "$STDOUT_FILE" "$STDERR_FILE" "$WATCH_FILE" \
      "$SELECTED_FILE.next" "$PROMPT_FILE.next" 2>/dev/null || true
  fi
  if [ "$lock_owner" = "$$" ]; then
    rm -f "$LOCK_OWNER" 2>/dev/null || true
    rmdir "$LOCK_DIR" 2>/dev/null || true
  fi
}

on_signal() {
  STOPPING=1
  kill_inflight
  [ -n "${WATCH_PID:-}" ] && kill "$WATCH_PID" 2>/dev/null || true
  exit 0
}

trap cleanup EXIT
trap on_signal INT TERM

uuid_new() {
  local value="" hex=""
  if [ -n "${AGMSG_UUIDGEN_CMD:-}" ]; then
    value="$("$AGMSG_UUIDGEN_CMD" 2>/dev/null || true)"
  elif command -v uuidgen >/dev/null 2>&1; then
    value="$(uuidgen 2>/dev/null || true)"
  fi
  value="$(printf '%s' "$value" | tr 'A-Z' 'a-z' | tr -d '\r\n')"
  case "$value" in
    ????????-????-????-????-????????????) printf '%s' "$value"; return 0 ;;
  esac
  hex="$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \r\n')"
  [ "${#hex}" -eq 32 ] || return 1
  printf '%s-%s-%s-%s-%s' \
    "${hex:0:8}" "${hex:8:4}" "${hex:12:4}" "${hex:16:4}" "${hex:20:12}"
}

session_valid() {
  case "$1" in
    ????????-????-????-????-????????????) return 0 ;;
    *) return 1 ;;
  esac
}

transcript_path() {
  local sid="$1" munged
  munged="$(printf '%s' "$WORK_DIR" | LC_ALL=C sed 's/[^A-Za-z0-9-]/-/g')"
  printf '%s/projects/%s/%s.jsonl' "$CLAUDE_CONFIG_DIR" "$munged" "$sid"
}

transcript_exists() {
  [ -f "$(transcript_path "$1")" ]
}

write_session() {
  local sid="$1" tmp="$SESSION_FILE.tmp.$$"
  printf '%s\n' "$sid" > "$tmp" \
    && mv "$tmp" "$SESSION_FILE"
}

reclassify_candidate() {
  local sid
  [ -f "$CANDIDATE_FILE" ] || return 0
  sid="$(head -1 "$CANDIDATE_FILE" 2>/dev/null || true)"
  if session_valid "$sid" && transcript_exists "$sid"; then
    if write_session "$sid"; then
      log "recovered session $sid from the prior outcome-unknown turn"
      rm -f "$CANDIDATE_FILE" 2>/dev/null || true
    fi
  else
    rm -f "$CANDIDATE_FILE" 2>/dev/null || true
  fi
}

unescape_body() {
  printf '%s' "$1" | awk '{ gsub(/\\t/, "\t"); gsub(/\\n/, "\n"); print }'
}

build_prompt_from_rows() {
  local rows="$1" out="$2" senders sender id from body ts ubody
  : > "$out"
  if [ -n "$ROLE_FILE" ] && [ -r "$ROLE_FILE" ]; then
    cat "$ROLE_FILE" >> "$out"
    printf '\n\n' >> "$out"
  fi
  printf "You are a headless agmsg claude-code worker (team '%s', acting as '%s').\n" \
    "$TEAM" "$NAME" >> "$out"
  printf 'Unread agmsg messages are grouped by sender below.\n' >> "$out"

  senders="$(awk -F"$US" 'NF >= 2 && !seen[$2]++ { print $2 }' "$rows" 2>/dev/null || true)"
  while IFS= read -r sender; do
    [ -n "$sender" ] || continue
    printf "\nMessages from '%s':\n" "$sender" >> "$out"
    while IFS="$US" read -r id from body ts; do
      [ "$from" = "$sender" ] || continue
      ubody="$(unescape_body "$body")"
      printf '  [%s] %s: %s\n' "$ts" "$from" "$ubody" >> "$out"
    done < "$rows"
  done <<< "$senders"

  printf '\nReply to every sender that needs a response. You may send to any recipient represented by the work using:\n' >> "$out"
  printf '%s %s %s <to> <message>\n' "$SCRIPTS_DIR/send.sh" "$TEAM" "$NAME" >> "$out"
  printf 'Do not rely on stdout as delivery; the bridge verifies an agmsg send after this turn.\n' >> "$out"
}

make_consumed_snapshot() {
  local rows="$1" out="$2"
  awk -F"$US" -v OFS="$US" '
    NF >= 2 {
      if (!seen[$2]++) order[++n] = $2
      ids[$2] = ids[$2] (ids[$2] ? "," : "") $1
    }
    END {
      for (i = 1; i <= n; i++) print order[i], ids[order[i]]
    }
  ' "$rows" > "$out"
}

selected_ids() {
  awk -F"$US" 'NF >= 1 { ids = ids (ids ? "," : "") $1 } END { print ids }' "$1"
}

reject_poison_row() {
  local line="$1" rendered_bytes="$2" id sender _body _ts notice
  IFS="$US" read -r id sender _body _ts <<< "$line"
  case "$id" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$sender" ] || return 1

  # This row cannot become deliverable on a later wake: it exceeds the hard
  # cap even when rendered alone. Consume exactly this id and compensate its
  # sender explicitly; ordinary combined overflow never enters this path.
  if ! agmsg_claude_code_mark_exact "$TEAM" "$NAME" "$id"; then
    log "could not exact-mark terminally undeliverable message id $id"
    return 1
  fi
  notice="[bridge-error] claude-code message id $id is terminally undeliverable: its rendered prompt is $rendered_bytes bytes, exceeding the stdin batch cap of $BATCH_CAP bytes. The message was consumed; resend a smaller message."
  send_notice "$sender" "$notice" || true
  log "terminally rejected message id $id at $rendered_bytes bytes (stdin batch cap $BATCH_CAP)"
  return 0
}

# Fetch a prefix of unread rows whose complete rendered prompt is <= 1 MiB.
# Combined overflow stops at the first deferred row. A row that cannot fit by
# itself is terminally compensated, after which scanning continues in this wake.
prepare_batch() {
  local eligible line bytes ids selected_before terminal_count=0
  rm -f "$ROWS_FILE" "$SELECTED_FILE" "$CONSUMED_FILE" \
    "$PROMPT_FILE" "$SELECTED_FILE.next" "$PROMPT_FILE.next" 2>/dev/null || true

  eligible="$(agmsg_claude_code_eligible_pairs \
    "$PROJECT" "$TYPE" "$TEAM" "$NAME" "${TEAM}"$'\t'"${NAME}")" || return 1
  printf '%s\n' "$eligible" | grep -Fxq "${TEAM}"$'\t'"${NAME}" || return 1

  "$SCRIPTS_DIR/inbox.sh" "$TEAM" "$NAME" --format ids > "$ROWS_FILE" 2>/dev/null \
    || return 1
  [ -s "$ROWS_FILE" ] || return 2
  : > "$SELECTED_FILE"

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "${line%%$US*}" in ''|*[!0-9]*) continue ;; esac
    selected_before=0
    [ -s "$SELECTED_FILE" ] && selected_before=1
    cp "$SELECTED_FILE" "$SELECTED_FILE.next" || return 1
    printf '%s\n' "$line" >> "$SELECTED_FILE.next"
    build_prompt_from_rows "$SELECTED_FILE.next" "$PROMPT_FILE.next"
    bytes="$(wc -c < "$PROMPT_FILE.next" | tr -d ' ')"
    case "$bytes" in ''|*[!0-9]*) return 1 ;; esac
    if [ "$bytes" -gt "$BATCH_CAP" ]; then
      rm -f "$SELECTED_FILE.next" "$PROMPT_FILE.next" 2>/dev/null || true
      if [ "$selected_before" -eq 0 ]; then
        reject_poison_row "$line" "$bytes" || return 1
        terminal_count=$((terminal_count + 1))
        continue
      fi
      log "stdin batch cap reached at $BATCH_CAP bytes; overflow remains unread"
      break
    fi
    mv "$SELECTED_FILE.next" "$SELECTED_FILE"
    mv "$PROMPT_FILE.next" "$PROMPT_FILE"
  done < "$ROWS_FILE"

  if [ ! -s "$SELECTED_FILE" ]; then
    [ "$terminal_count" -gt 0 ] && return 4
    return 3
  fi
  [ -s "$PROMPT_FILE" ] || build_prompt_from_rows "$SELECTED_FILE" "$PROMPT_FILE"
  make_consumed_snapshot "$SELECTED_FILE" "$CONSUMED_FILE"
  ids="$(selected_ids "$SELECTED_FILE")"
  [ -n "$ids" ] || return 1
  if ! agmsg_claude_code_mark_exact "$TEAM" "$NAME" "$ids"; then
    notify_consumed "database error while confirming exact mark-read; no Claude turn was started"
    rm -f "$CONSUMED_FILE" 2>/dev/null || true
    return 1
  fi
  return 0
}

spool_valid() {
  local esc valid
  [ -f "$1" ] || return 1
  esc="$(agmsg_sql_readfile_path "$1")"
  valid="$(agmsg_sqlite_mem "
    SELECT CASE
      WHEN json_valid(CAST(readfile('$esc') AS TEXT))
       AND json_type(CAST(readfile('$esc') AS TEXT))='array'
      THEN 1 ELSE 0 END;
  " 2>/dev/null || echo 0)"
  [ "$valid" = 1 ]
}

queue_outbound() {
  local to="$1" body="$2" body_file="$BASE.notice.$$" tmp="$SPOOL_FILE.tmp.$$"
  local spool_esc body_esc to_esc
  printf '%s' "$body" > "$body_file" || return 1
  if [ -f "$SPOOL_FILE" ] && ! spool_valid "$SPOOL_FILE"; then
    mv "$SPOOL_FILE" "$SPOOL_FILE.corrupt-$(date +%s)" 2>/dev/null || true
  fi
  spool_esc="$(agmsg_sql_readfile_path "$SPOOL_FILE")"
  body_esc="$(agmsg_sql_readfile_path "$body_file")"
  to_esc="$(agmsg_claude_code_sql_escape "$to")"
  if [ -f "$SPOOL_FILE" ]; then
    agmsg_sqlite_mem "
      SELECT json_insert(
        CAST(readfile('$spool_esc') AS TEXT), '\$[#]',
        json_object('to','$to_esc','body',CAST(readfile('$body_esc') AS TEXT))
      );
    " > "$tmp" 2>/dev/null
  else
    agmsg_sqlite_mem "
      SELECT json_array(
        json_object('to','$to_esc','body',CAST(readfile('$body_esc') AS TEXT))
      );
    " > "$tmp" 2>/dev/null
  fi
  local rc=$?
  rm -f "$body_file" 2>/dev/null || true
  if [ "$rc" -eq 0 ] && [ -s "$tmp" ]; then
    mv "$tmp" "$SPOOL_FILE" && return 0
  fi
  rm -f "$tmp" 2>/dev/null || true
  return 1
}

send_notice() {
  local to="$1" body="$2"
  if printf '%s' "$body" \
    | "$SCRIPTS_DIR/send.sh" "$TEAM" "$NAME" "$to" --stdin >/dev/null 2>&1; then
    return 0
  fi
  queue_outbound "$to" "$body" || true
  log "notice for $to could not be sent; spooled to $SPOOL_FILE"
  return 1
}

notify_consumed() {
  local reason="$1" prefix="${2:-turn failed}" sender ids body
  [ -s "$CONSUMED_FILE" ] || return 0
  while IFS="$US" read -r sender ids; do
    [ -n "$sender" ] && [ -n "$ids" ] || continue
    body="[bridge-error] claude-code $prefix (ids $ids): $reason. Messages consumed; resend to retry."
    send_notice "$sender" "$body" || true
  done < "$CONSUMED_FILE"
}

notify_context_loss() {
  local old_sid="$1" sender ids body
  [ -s "$CONSUMED_FILE" ] || return 0
  while IFS="$US" read -r sender ids; do
    [ -n "$sender" ] && [ -n "$ids" ] || continue
    body="[bridge-error] claude-code resume context $old_sid was rejected (ids $ids); starting a fresh session. Prior conversational context is unavailable."
    send_notice "$sender" "$body" || true
  done < "$CONSUMED_FILE"
}

flush_outbound() {
  local esc count i to body failed="" tmp="$SPOOL_FILE.tmp.$$"
  [ -f "$SPOOL_FILE" ] || return 0
  if ! spool_valid "$SPOOL_FILE"; then
    mv "$SPOOL_FILE" "$SPOOL_FILE.corrupt-$(date +%s)" 2>/dev/null || true
    log "outbound spool was corrupt and was quarantined"
    return 1
  fi
  esc="$(agmsg_sql_readfile_path "$SPOOL_FILE")"
  count="$(agmsg_sqlite_mem \
    "SELECT json_array_length(CAST(readfile('$esc') AS TEXT));" 2>/dev/null || echo 0)"
  case "$count" in ''|*[!0-9]*) return 1 ;; esac
  i=0
  while [ "$i" -lt "$count" ]; do
    to="$(agmsg_sqlite_mem \
      "SELECT COALESCE(json_extract(CAST(readfile('$esc') AS TEXT),'\$[$i].to'),'');" \
      2>/dev/null || true)"
    body="$(agmsg_sqlite_mem \
      "SELECT COALESCE(json_extract(CAST(readfile('$esc') AS TEXT),'\$[$i].body'),'');" \
      2>/dev/null || true)"
    if [ -n "$to" ] && [ -n "$body" ] \
      && printf '%s' "$body" \
        | "$SCRIPTS_DIR/send.sh" "$TEAM" "$NAME" "$to" --stdin >/dev/null 2>&1; then
      log "delivered spooled notice to $to"
    else
      failed="${failed:+$failed,}$i"
    fi
    i=$((i + 1))
  done
  if [ -z "$failed" ]; then
    rm -f "$SPOOL_FILE" 2>/dev/null || true
    return 0
  fi
  agmsg_sqlite_mem "
    SELECT COALESCE(json_group_array(json(value)), '[]')
    FROM json_each(CAST(readfile('$esc') AS TEXT))
    WHERE key IN ($failed);
  " > "$tmp" 2>/dev/null \
    && mv "$tmp" "$SPOOL_FILE" \
    || rm -f "$tmp" 2>/dev/null || true
  log "spooled notice delivery is still pending"
  return 1
}

# Execute one turn in a fresh process group. The Perl wrapper owns the tracked
# pid; its child calls setsid(), and timeout/TERM sends TERM then KILL to the
# whole negative-pid group.
run_turn_group() {
  local secs="$1" grace="$2"; shift 2
  local rc=0
  if [ "$GROUP_RUNNER" = perl ]; then
    "$PERL_BIN" -e '
      use POSIX qw(setsid);
      my $secs = shift @ARGV;
      my $grace = shift @ARGV;
      my $pid = fork();
      defined $pid or exit 127;
      if ($pid == 0) { setsid(); exec @ARGV; exit 127; }
      my $kill_group = sub {
        kill(15, -$pid);
        select(undef, undef, undef, $grace);
        kill(9, -$pid);
      };
      $SIG{ALRM} = sub { $kill_group->(); waitpid($pid, 0); exit 124; };
      $SIG{TERM} = sub { $kill_group->(); waitpid($pid, 0); exit 143; };
      $SIG{INT}  = sub { $kill_group->(); waitpid($pid, 0); exit 130; };
      alarm($secs) if $secs > 0;
      waitpid($pid, 0);
      alarm 0;
      my $status = $?;
      exit($status & 127 ? 128 + ($status & 127) : ($status >> 8));
    ' "$secs" "$grace" "$@" \
      < "$PROMPT_FILE" > "$STDOUT_FILE" 2> "$STDERR_FILE" &
  else
    "$PYTHON_BIN" -c '
import os
import signal
import sys
import time

secs = int(sys.argv[1])
grace = float(sys.argv[2])
argv = sys.argv[3:]
pid = os.fork()
if pid == 0:
    os.setsid()
    os.execvp(argv[0], argv)
    os._exit(127)

def kill_group(exit_code):
    try:
        os.killpg(pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    time.sleep(grace)
    try:
        os.killpg(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    try:
        os.waitpid(pid, 0)
    except ChildProcessError:
        pass
    os._exit(exit_code)

signal.signal(signal.SIGTERM, lambda _s, _f: kill_group(143))
signal.signal(signal.SIGINT, lambda _s, _f: kill_group(130))
signal.signal(signal.SIGALRM, lambda _s, _f: kill_group(124))
if secs > 0:
    signal.alarm(secs)
_, status = os.waitpid(pid, 0)
signal.alarm(0)
if os.WIFSIGNALED(status):
    sys.exit(128 + os.WTERMSIG(status))
sys.exit(os.WEXITSTATUS(status))
' "$secs" "$grace" "$@" \
      < "$PROMPT_FILE" > "$STDOUT_FILE" 2> "$STDERR_FILE" &
  fi
  CHILD_PID=$!
  if wait "$CHILD_PID" 2>/dev/null; then rc=0; else rc=$?; fi
  CHILD_PID=""
  cat "$STDERR_FILE" >&2 2>/dev/null || true
  return "$rc"
}

resume_rejected() {
  cat "$STDERR_FILE" "$STDOUT_FILE" 2>/dev/null \
    | LC_ALL=C grep -Eiq \
      '(no (conversation|session).*(found|exists)|session.*(not found|does not exist|invalid|cannot be resumed|rejected)|resume.*(not found|invalid|rejected|failed))'
}

capture_watermark_or_fail() {
  local value
  value="$(agmsg_claude_code_max_id)" || return 1
  printf '%s' "$value"
}

run_cli_attempt() {
  local mode="$1" sid="$2" watermark rc=0 outbound_rc
  local args=(-p --output-format "$OUTPUT_FORMAT")
  [ -n "$MODEL" ] && args+=(--model "$MODEL")
  [ -n "$EFFORT" ] && args+=(--effort "$EFFORT")
  [ -n "$SETTINGS" ] && args+=(--settings "$SETTINGS")
  local add_dir
  for add_dir in "${ADD_DIRS[@]}"; do args+=(--add-dir "$add_dir"); done
  local disallowed_tools
  for disallowed_tools in "${DISALLOWED_TOOLS[@]}"; do
    args+=(--disallowedTools "$disallowed_tools")
  done
  if [ "$mode" = resume ]; then
    args+=(--resume "$sid")
  else
    args+=(--session-id "$sid")
  fi

  TURN_PROCESS_RC=70
  watermark="$(capture_watermark_or_fail)" || {
    notify_consumed "database error while capturing the pre-turn outbound watermark"
    return 70
  }
  TURN_PROCESS_RC=0
  log "started turn on session $sid"
  run_turn_group "$TURN_TIMEOUT" "$TERM_GRACE" "$CLAUDE_BIN" "${args[@]}" || rc=$?
  TURN_PROCESS_RC="$rc"
  TURN_WATERMARK="$watermark"
  if [ "$rc" -ne 0 ]; then
    return "$rc"
  fi

  if agmsg_claude_code_has_outbound_after "$TEAM" "$NAME" "$watermark"; then
    outbound_rc=0
  else
    outbound_rc=$?
  fi
  case "$outbound_rc" in
    0) return 0 ;;
    1) return 71 ;;
    *) return 72 ;;
  esac
}

process_wake() {
  local prep_rc=0 sid="" mode=fresh rc=0
  reclassify_candidate
  flush_outbound || true

  prepare_batch || prep_rc=$?
  case "$prep_rc" in
    0) ;;
    2) log "wakeup had no unread rows after eligibility re-check"; return 0 ;;
    3) log "no message fits within the $BATCH_CAP-byte stdin cap"; return 0 ;;
    4) log "wakeup terminally rejected undeliverable rows; no processable rows remain"; return 0 ;;
    *) log "could not prepare an exact consumed snapshot"; return 1 ;;
  esac

  if [ -f "$SESSION_FILE" ]; then
    sid="$(head -1 "$SESSION_FILE" 2>/dev/null || true)"
    if session_valid "$sid" && transcript_exists "$sid"; then
      mode=resume
    else
      [ -n "$sid" ] && notify_context_loss "$sid"
      rm -f "$SESSION_FILE" 2>/dev/null || true
      sid=""
      mode=fresh
    fi
  fi
  if [ "$mode" = fresh ]; then
    sid="$(uuid_new)" || {
      notify_consumed "could not generate a session UUID"
      rm -f "$CONSUMED_FILE" 2>/dev/null || true
      return 1
    }
    printf '%s\n' "$sid" > "$CANDIDATE_FILE"
  fi

  TURN_PROCESS_RC=0
  TURN_WATERMARK=""
  run_cli_attempt "$mode" "$sid" || rc=$?

  # A resume rejection is the one safe automatic retry: the rejected CLI did
  # not run a turn. Notify context loss first, then take a new watermark so the
  # bridge's own notice can never satisfy outbound verification.
  if [ "$mode" = resume ] \
    && [ "$rc" -ne 70 ] \
    && [ "$TURN_PROCESS_RC" -gt 0 ] \
    && [ "$TURN_PROCESS_RC" -lt 124 ] \
    && resume_rejected; then
    notify_context_loss "$sid"
    rm -f "$SESSION_FILE" "$CANDIDATE_FILE" 2>/dev/null || true
    sid="$(uuid_new)" || {
      notify_consumed "resume was rejected and a fresh session UUID could not be generated"
      rm -f "$CONSUMED_FILE" 2>/dev/null || true
      return 1
    }
    printf '%s\n' "$sid" > "$CANDIDATE_FILE"
    mode=fresh
    rc=0
    TURN_PROCESS_RC=0
    run_cli_attempt fresh "$sid" || rc=$?
  fi

  if [ "$rc" -eq 70 ]; then
    rm -f "$CONSUMED_FILE" 2>/dev/null || true
    return 0
  fi

  if [ "$TURN_PROCESS_RC" -ne 0 ]; then
    if [ "$TURN_PROCESS_RC" -eq 124 ]; then
      notify_consumed "Claude CLI timed out after ${TURN_TIMEOUT}s; outcome is unknown and the turn was not rerun" "turn outcome unknown"
    else
      notify_consumed "Claude CLI exited nonzero (rc=$TURN_PROCESS_RC); outcome is unknown and the turn was not rerun" "turn outcome unknown"
    fi
    rm -f "$CONSUMED_FILE" 2>/dev/null || true
    return 0
  fi

  if [ "$mode" = fresh ]; then
    if transcript_exists "$sid"; then
      write_session "$sid" || true
      rm -f "$CANDIDATE_FILE" 2>/dev/null || true
    else
      notify_consumed "Claude exited 0 but no transcript exists for session $sid"
      rm -f "$CONSUMED_FILE" 2>/dev/null || true
      return 0
    fi
  fi

  case "$rc" in
    0)
      rm -f "$CONSUMED_FILE" 2>/dev/null || true
      log "completed turn on session $sid with verified outbound"
      ;;
    70|72)
      notify_consumed "database error prevented outbound verification; this was not classified as no-outbound"
      rm -f "$CONSUMED_FILE" 2>/dev/null || true
      ;;
    71)
      notify_consumed "Claude exited 0 but wrote no agmsg outbound row after watermark $TURN_WATERMARK"
      rm -f "$CONSUMED_FILE" 2>/dev/null || true
      ;;
    *)
      notify_consumed "unexpected bridge turn status rc=$rc"
      rm -f "$CONSUMED_FILE" 2>/dev/null || true
      ;;
  esac
  return 0
}

reclassify_candidate
flush_outbound || true
wake_count=0

while [ "$STOPPING" -eq 0 ]; do
  log "armed $TEAM/$NAME"
  rm -f "$WATCH_FILE" 2>/dev/null || true
  bash "$SCRIPT_DIR/watch-once.sh" "$PROJECT" "$TYPE" \
    --team "$TEAM" --name "$NAME" --pair "${TEAM}"$'\t'"${NAME}" \
    --timeout "$WATCH_TIMEOUT" --interval "$INTERVAL" \
    > "$WATCH_FILE" 2>&1 &
  WATCH_PID=$!
  watch_rc=0
  if wait "$WATCH_PID" 2>/dev/null; then watch_rc=0; else watch_rc=$?; fi
  WATCH_PID=""
  [ "$STOPPING" -eq 0 ] || break

  case "$watch_rc" in
    0)
      wake_count=$((wake_count + 1))
      log "wakeup $wake_count for $TEAM/$NAME"
      process_wake || true
      if [ "$MAX_WAKES" -gt 0 ] && [ "$wake_count" -ge "$MAX_WAKES" ]; then
        break
      fi
      ;;
    2)
      [ "$ONCE" -eq 1 ] && break
      ;;
    *)
      cat "$WATCH_FILE" >&2 2>/dev/null || true
      [ "$ONCE" -eq 1 ] && exit 1
      sleep "$INTERVAL"
      ;;
  esac
done

exit 0
