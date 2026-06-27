#!/usr/bin/env bash
# Daemon loop: NOT `set -e`. A long-running worker must survive a transient
# non-zero (empty grep, sqlite no-row, a failed cursor turn) instead of dying, so
# every fallible step is guarded explicitly with `|| true` / `if`. `-u`/pipefail
# stay on to catch real bugs.
set -uo pipefail

# cursor-bridge.sh — headless, read-only Cursor reviewer worker for agmsg.
#
# The cursor-side analogue of codex-bridge.js, but far smaller: cursor-agent's
# headless interface is a ONE-SHOT CLI (`cursor-agent -p --output-format json
# --resume <chatId>`), not a long-lived app-server. So there is no JSON-RPC
# daemon, no turn-lifecycle protocol, and no watchdog — a turn is one process that
# exits. The loop is:
#
#   1. poll the inbox (inbox.sh --format ids: id-tagged unread, NEVER marked read)
#   2. group unread by sender (from the DB id-list, not a fragile text parse)
#   3. per sender: run cursor-agent READ-ONLY (--trust, never --force) with their
#      messages, capture the JSON `.result`
#   4. on a valid result: the BRIDGE sends it back via send.sh --stdin, THEN marks
#      exactly those message ids read. cursor never runs send.sh — it stays a pure
#      read-only reviewer (approach b).
#
# Mark-read-on-success (not on fetch) is the key correctness property: a failed or
# timed-out turn leaves the messages unread so the next cycle retries, instead of
# silently consuming them (the hole codex/inbox.sh's fetch-marks-read path has).
#
# Chat continuity: --resume <chatId> replays the server-side Cursor conversation,
# so the worker keeps context across turns. The chat id is created at spawn time
# (_spawn.sh) and passed in via --chat-id.

usage() {
  cat <<EOF
Usage: cursor-bridge.sh --project <path> --team <team> --name <agent> --chat-id <id>
                        [--interval <sec>] [--once] [--help]

Headless read-only Cursor reviewer worker for agmsg.

  --project <path>   repo to review (cursor-agent cwd; read-only).
  --team <team>      agmsg team to receive/reply on.
  --name <agent>     this worker's agmsg identity.
  --chat-id <id>     Cursor chat id to --resume each turn (from create-chat).
  --interval <sec>   inbox poll interval (default 2).
  --once             drain the inbox a single time, then exit (for tests).
  --help             show this help.

Env:
  AGMSG_CURSOR_AGENT_CMD        cursor-agent binary (default: cursor-agent). Tests stub this.
  AGMSG_CURSOR_BRIDGE_INTERVAL  default poll interval.
  AGMSG_CURSOR_BRIDGE_TURN_TIMEOUT  seconds to wait for one cursor turn before
                                killing it and retrying (default 180; 0 disables).
EOF
}

PROJECT="" TEAM="" NAME="" CHAT_ID=""
INTERVAL="${AGMSG_CURSOR_BRIDGE_INTERVAL:-2}"
ONCE=0
TURN_TIMEOUT="${AGMSG_CURSOR_BRIDGE_TURN_TIMEOUT:-180}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --project) PROJECT="${2:?--project needs a path}"; shift 2 ;;
    --team)    TEAM="${2:?--team needs a name}"; shift 2 ;;
    --name)    NAME="${2:?--name needs a name}"; shift 2 ;;
    --chat-id) CHAT_ID="${2:?--chat-id needs an id}"; shift 2 ;;
    --interval) INTERVAL="${2:?--interval needs seconds}"; shift 2 ;;
    --once)    ONCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "cursor-bridge: unknown option: $1" >&2; exit 1 ;;
  esac
done

[ -n "$PROJECT" ] || { echo "cursor-bridge: --project is required" >&2; exit 1; }
[ -n "$TEAM" ] || { echo "cursor-bridge: --team is required" >&2; exit 1; }
[ -n "$NAME" ] || { echo "cursor-bridge: --name is required" >&2; exit 1; }
[ -n "$CHAT_ID" ] || { echo "cursor-bridge: --chat-id is required" >&2; exit 1; }
[ -d "$PROJECT" ] || { echo "cursor-bridge: project path is not a directory: $PROJECT" >&2; exit 1; }
case "$INTERVAL" in ''|*[!0-9]*) echo "cursor-bridge: --interval must be a whole number of seconds" >&2; exit 1 ;; esac
[ "$INTERVAL" -gt 0 ] || INTERVAL=1
case "$TURN_TIMEOUT" in ''|*[!0-9]*) echo "cursor-bridge: AGMSG_CURSOR_BRIDGE_TURN_TIMEOUT must be a whole number of seconds" >&2; exit 1 ;; esac

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
SCRIPTS_DIR="$SKILL_DIR/scripts"
RUN_DIR="$SKILL_DIR/run"
# shellcheck disable=SC1091
source "$SCRIPTS_DIR/lib/storage.sh"

CURSOR_BIN="${AGMSG_CURSOR_AGENT_CMD:-cursor-agent}"
# perl gives us a robust per-turn timeout that kills the WHOLE process group
# (cursor-agent + every descendant) — the primitive bash lacks on macOS (no
# setsid(1)/timeout(1)). perl ships on macOS, Linux and Git-for-Windows, so this
# is the normal path; without it the turn runs unbounded (see run_with_timeout).
PERL_BIN="$(command -v perl 2>/dev/null || true)"
US=$'\x1f'

mkdir -p "$RUN_DIR" 2>/dev/null || true
PIDFILE="$RUN_DIR/cursor-bridge.$TEAM.$NAME.pid"
METAFILE="$RUN_DIR/cursor-bridge.$TEAM.$NAME.meta"
LOG="$RUN_DIR/cursor-bridge.$TEAM.$NAME.log"
OUTFILE="$RUN_DIR/cursor-bridge.$TEAM.$NAME.last.json"
PROMPTFILE="$RUN_DIR/cursor-bridge.$TEAM.$NAME.prompt"

# --- single instance: refuse a second bridge for the same identity ------------
if [ -f "$PIDFILE" ]; then
  oldpid="$(cat "$PIDFILE" 2>/dev/null || true)"
  if [ -n "$oldpid" ] && kill -0 "$oldpid" 2>/dev/null; then
    echo "cursor-bridge: already running for $TEAM/$NAME (pid $oldpid)" >&2
    exit 1
  fi
fi
echo "$$" > "$PIDFILE"
printf 'pid=%s\nproject=%s\nteam=%s\nname=%s\ntype=cursor\n' "$$" "$PROJECT" "$TEAM" "$NAME" > "$METAFILE"

# In-flight turn pid, tracked so a despawn (SIGTERM) tears down the running turn
# instead of orphaning it. With perl this is the perl wrapper's pid; its SIGTERM
# handler kills the whole cursor process group, so signalling it tears the turn
# down cleanly. run_with_timeout maintains this.
CHILD_PID=""

# Kill the in-flight turn: SIGTERM (perl forwards it to the whole cursor process
# group), wait out a grace longer than perl's own 2s group-kill window, then
# SIGKILL the wrapper and its children as a backstop. So a despawn during an
# active turn can't leave an orphaned cursor-agent.
kill_inflight() {
  [ -n "${CHILD_PID:-}" ] || return 0
  kill "$CHILD_PID" 2>/dev/null || true
  local n=0
  while kill -0 "$CHILD_PID" 2>/dev/null && [ "$n" -lt 8 ]; do sleep 0.5; n=$((n + 1)); done
  if kill -0 "$CHILD_PID" 2>/dev/null; then
    pkill -9 -P "$CHILD_PID" 2>/dev/null || true
    kill -9 "$CHILD_PID" 2>/dev/null || true
  fi
}

cleanup() {
  # Stop any running cursor turn first so despawn never leaves an orphan.
  kill_inflight
  # Only remove the run files if we still own them (a re-spawn may have replaced us).
  # The chat id and transient JSON are ours; the .log is left for debugging (as
  # codex's bridge does). A re-spawn always create-chats a fresh id, so dropping
  # .chat here is safe.
  if [ "$(cat "$PIDFILE" 2>/dev/null || true)" = "$$" ]; then
    rm -f "$PIDFILE" "$METAFILE" "$OUTFILE" "$PROMPTFILE" \
          "$OUTFILE.one" "$OUTFILE.cand" \
          "$RUN_DIR/cursor-bridge.$TEAM.$NAME.chat" 2>/dev/null || true
  fi
}
trap cleanup EXIT
# SIGTERM/SIGINT → exit 0 → the EXIT trap (cleanup → kill_inflight) runs, so a
# despawn during an active turn stops the cursor-agent child too.
trap 'exit 0' INT TERM

# Restore a body's transport-escaped \n / \t (inbox.sh --format ids escapes them
# to keep one record per line) back to real newlines/tabs for the cursor prompt.
unescape() { printf '%s' "$1" | awk '{ gsub(/\\t/, "\t"); gsub(/\\n/, "\n"); print }'; }

# Run "$@" with a wall-clock timeout. Returns the command's exit status, 124 on
# timeout, or 128+signal if the command was killed by a signal — so the caller
# treats anything but a clean exit 0 as a failure and retries.
#
# perl path (taken whenever perl exists, even when timeout is disabled): perl runs
# the command in its OWN session/process group (setsid) and, on its alarm
# (timeout) OR a forwarded SIGTERM (despawn), kills the WHOLE group — cursor-agent
# and every descendant. It is a single tracked process (CHILD_PID = the perl
# wrapper) with no shared marker file and no watchdog subshell, so there is no
# cross-turn / re-spawn race: the 124 is internal to this one invocation and can
# never affect another turn. `alarm 0` (secs<=0) keeps the group management but
# disables the timeout. perl reports signal deaths as 128+signal (not 0), so a
# cursor-agent killed externally / crashing is never mistaken for success even if
# a complete JSON happens to sit in stdout. The command runs via the list form of
# exec (execvp, no shell) — no shell-injection surface. Signals are numeric (15/9)
# so the program needs no single quotes and embeds in the single-quoted -e below.
# (A child finishing in the same instant the alarm fires can still be scored a
# timeout — an inherent, fail-closed, this-turn-only retry.)
#
# No-perl fallback (degraded): run unbounded as a direct background child, tracked
# so kill_inflight can SIGTERM/SIGKILL it on despawn. Without setsid there is no
# process-group kill, so a cursor-agent that leaves descendants could orphan them.
# perl is present on macOS / Linux / Git-for-Windows, so this path is for exotic
# environments only.
run_with_timeout() {
  local secs="$1"; shift
  local rc=0
  case "$secs" in ''|*[!0-9-]*) secs=0 ;; esac
  [ "$secs" -ge 0 ] 2>/dev/null || secs=0
  if [ -n "$PERL_BIN" ]; then
    "$PERL_BIN" -e '
      use POSIX qw(setsid);
      my $secs = shift @ARGV;
      my $pid = fork();
      defined $pid or exit 127;
      if ($pid == 0) { setsid(); exec @ARGV; exit 127; }
      my $kg = sub { kill(15, -$pid); sleep 2; kill(9, -$pid); };
      $SIG{ALRM} = sub { $kg->(); waitpid($pid, 0); exit 124; };
      $SIG{TERM} = sub { $kg->(); waitpid($pid, 0); exit 143; };
      $SIG{INT}  = sub { $kg->(); waitpid($pid, 0); exit 130; };
      alarm $secs;
      waitpid($pid, 0);
      alarm 0;
      my $st = $?;
      exit($st & 127 ? 128 + ($st & 127) : ($st >> 8));
    ' "$secs" "$@" &
    CHILD_PID=$!
    if wait "$CHILD_PID" 2>/dev/null; then rc=0; else rc=$?; fi
    CHILD_PID=""
    return "$rc"
  fi
  "$@" &
  CHILD_PID=$!
  if wait "$CHILD_PID" 2>/dev/null; then rc=0; else rc=$?; fi
  CHILD_PID=""
  return "$rc"
}

# 0 if file $1 contains exactly one valid JSON document.
json_valid_file() {
  local esc v
  esc="$(agmsg_sql_readfile_path "$1")"
  v="$(agmsg_sqlite_mem "SELECT CASE WHEN json_valid(CAST(readfile('$esc') AS TEXT)) THEN 1 ELSE 0 END" 2>/dev/null || echo 0)"
  [ "$v" = 1 ]
}

# Run one read-only cursor turn for $1=prompt. On a valid, non-error result with
# a matching session id and non-empty text, set REPLY_TEXT and return 0; else
# return 1 (caller leaves the messages unread for a retry). NEVER passes --force,
# so cursor cannot write/run shell — it is a pure reviewer (see _spawn.sh D2 note).
# The prompt goes in via STDIN (a file), never argv, so an arbitrarily large
# inbound batch can't hit ARG_MAX. The call is bounded by TURN_TIMEOUT so a hung
# cursor-agent can't wedge the loop — on timeout the turn fails and the message
# stays unread for the next cycle (the retry half of the loss-safe contract).
REPLY_TEXT=""
run_cursor_turn() {
  local prompt="$1"
  : > "$OUTFILE"
  printf '%s' "$prompt" > "$PROMPTFILE"
  local rc=0
  run_with_timeout "$TURN_TIMEOUT" \
    "$CURSOR_BIN" -p --trust --output-format json --resume "$CHAT_ID" \
    <"$PROMPTFILE" >"$OUTFILE" 2>>"$LOG" || rc=$?
  rm -f "$PROMPTFILE" 2>/dev/null || true

  # A non-zero exit means cursor-agent failed or was killed by the watchdog. Even
  # if a complete-looking JSON happened to land in $OUTFILE, treat the turn as
  # failed and leave the message unread for the next cycle — never reply/ack off a
  # process that didn't exit cleanly (the loss-safe retry contract).
  if [ "$rc" -ne 0 ]; then
    echo "cursor-bridge: cursor-agent exited non-zero or timed out (rc=$rc); leaving message unread" >&2
    return 1
  fi

  # Resolve a SINGLE JSON document from stdout. The whole file must be one valid
  # JSON object; if not (e.g. a warning line precedes it) accept ONLY when exactly
  # one line is itself valid JSON. 0 or >1 valid-JSON lines → reject fail-closed,
  # so a multi-object / stream-json / garbage stdout never yields a false reply.
  local jsonfile=""
  if json_valid_file "$OUTFILE"; then
    jsonfile="$OUTFILE"
  else
    local ln count=0
    : > "$OUTFILE.one"
    while IFS= read -r ln; do
      [ -n "$ln" ] || continue
      printf '%s\n' "$ln" > "$OUTFILE.cand"
      if json_valid_file "$OUTFILE.cand"; then count=$((count + 1)); cp "$OUTFILE.cand" "$OUTFILE.one"; fi
    done < "$OUTFILE"
    rm -f "$OUTFILE.cand" 2>/dev/null || true
    if [ "$count" -eq 1 ]; then
      jsonfile="$OUTFILE.one"
    else
      rm -f "$OUTFILE.one" 2>/dev/null || true
      echo "cursor-bridge: cursor output was not a single JSON object ($count valid-json lines)" >&2
      return 1
    fi
  fi

  local esc is_err sid res
  esc="$(agmsg_sql_readfile_path "$jsonfile")"
  is_err="$(agmsg_sqlite_mem "SELECT COALESCE(json_extract(CAST(readfile('$esc') AS TEXT),'\$.is_error'),'true')" 2>/dev/null || echo true)"
  sid="$(agmsg_sqlite_mem "SELECT COALESCE(json_extract(CAST(readfile('$esc') AS TEXT),'\$.session_id'),'')" 2>/dev/null || echo '')"
  res="$(agmsg_sqlite_mem "SELECT COALESCE(json_extract(CAST(readfile('$esc') AS TEXT),'\$.result'),'')" 2>/dev/null || echo '')"
  rm -f "$OUTFILE.one" 2>/dev/null || true

  case "$is_err" in
    0|false) ;;
    *) echo "cursor-bridge: cursor reported is_error=$is_err" >&2; return 1 ;;
  esac
  if [ "$sid" != "$CHAT_ID" ]; then
    echo "cursor-bridge: session_id mismatch (got '$sid', expected '$CHAT_ID')" >&2
    return 1
  fi
  [ -n "$res" ] || { echo "cursor-bridge: empty result" >&2; return 1; }
  REPLY_TEXT="$res"
  return 0
}

# Drain the inbox once. Sets CYCLE_HAD_WORK / CYCLE_ACKED. Replies are routed
# per-sender (one turn each) so a multi-sender batch never cross-delivers a single
# answer to the wrong DM.
#
# Design note (vs codex bridge): this polls inbox.sh for its OWN fixed (team,name)
# directly, rather than going through watch-once.sh's subscription/actas-lock gate.
# That is deliberate — this is a dedicated single-identity worker whose lifecycle is
# the process itself (spawn starts it, despawn kills it by pid). The residual: if a
# registration is dropped with reset.sh WITHOUT a despawn, the live worker keeps
# answering until its pid is killed. despawn is the sanctioned teardown, so this is
# acceptable; subscription-gating the poll is a possible future hardening.
CYCLE_HAD_WORK=0
CYCLE_ACKED=0
process_cycle() {
  CYCLE_HAD_WORK=0
  CYCLE_ACKED=0
  local rows
  rows="$("$SCRIPTS_DIR/inbox.sh" "$TEAM" "$NAME" --format ids 2>/dev/null || true)"
  [ -n "$rows" ] || return 0
  CYCLE_HAD_WORK=1

  local senders sender
  senders="$(printf '%s\n' "$rows" | awk -F"$US" 'NF>=2 && !seen[$2]++ { print $2 }')"

  while IFS= read -r sender; do
    [ -n "$sender" ] || continue
    local ids="" body_block="" id from body ts ubody
    while IFS="$US" read -r id from body ts; do
      [ "$from" = "$sender" ] || continue
      ids="${ids:+$ids,}$id"
      ubody="$(unescape "$body")"
      body_block="${body_block}[$ts] ${from}: ${ubody}"$'\n'
    done <<< "$rows"
    [ -n "$ids" ] || continue

    # No size cap needed: the prompt is fed to cursor-agent via stdin (a file) in
    # run_cursor_turn, not argv, so a large batch cannot hit ARG_MAX.
    local prompt
    prompt="You are a headless agmsg reviewer (team '$TEAM', acting as '$NAME'), running read-only in $PROJECT. The following agmsg message(s) were sent to you by '$sender':

$body_block
Reply with ONLY your final answer for '$sender'. Do NOT run agmsg, send.sh, or any shell command to deliver it — the bridge delivers your reply automatically."

    if run_cursor_turn "$prompt"; then
      if printf '%s' "$REPLY_TEXT" | "$SCRIPTS_DIR/send.sh" "$TEAM" "$NAME" "$sender" --stdin >/dev/null 2>&1; then
        "$SCRIPTS_DIR/inbox.sh" "$TEAM" "$NAME" --mark-read-ids "$ids" >/dev/null 2>&1 || true
        CYCLE_ACKED=1
        echo "cursor-bridge: replied to $sender (ids $ids)" >&2
      else
        echo "cursor-bridge: send to $sender failed; leaving ids $ids unread for retry" >&2
      fi
    else
      echo "cursor-bridge: turn failed for $sender; leaving ids $ids unread for retry" >&2
    fi
  done <<< "$senders"
  return 0
}

echo "cursor-bridge: started for $TEAM/$NAME (chat $CHAT_ID, project $PROJECT)" >&2

if [ "$ONCE" = 1 ]; then
  process_cycle || true
  exit 0
fi

# Poll loop. Idle/success → poll at INTERVAL. Had-work-but-acked-nothing (a
# persistent failure, e.g. cursor not logged in) → exponential backoff capped at
# 60s so we don't hammer cursor-agent while the messages stay unread.
backoff=0
while true; do
  process_cycle || true
  if [ "$CYCLE_HAD_WORK" = 1 ] && [ "$CYCLE_ACKED" = 0 ]; then
    if [ "$backoff" -eq 0 ]; then backoff="$INTERVAL"; else backoff=$(( backoff * 2 )); fi
    [ "$backoff" -gt 60 ] && backoff=60
  else
    backoff=0
  fi
  sleep_for="$INTERVAL"
  [ "$backoff" -gt 0 ] && sleep_for="$backoff"
  sleep "$sleep_for"
done
