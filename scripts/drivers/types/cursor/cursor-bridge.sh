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
# Dead-letter exception (added after an incident: a NonRetriableError kept the
# same message unread, so loss-safe retried it ~1,860 times over 3 days at real
# $ cost): a failed turn is normally retried forever, but a TERMINAL failure —
# cursor-agent's stderr starts a line with "NonRetriableError:"/"ActionRequiredError:",
# or the same unread ids group has failed AGMSG_CURSOR_BRIDGE_MAX_CONSEC_FAILURES
# times in a row — first gets ONE retry of the same turn with `--model
# $AGMSG_CURSOR_BRIDGE_FALLBACK_MODEL` (a per-model outage — e.g. the fast tier
# out of usage — often clears on another model; set empty to disable). If that
# also fails, the ids are dead-lettered: the bridge sends the sender a
# `[bridge-error]` notice via the normal reply path, then marks the ids read (same
# as success) so the loop stops retrying. Normal turns never pass --model, so the
# user's global cursor model config applies outside the fallback.
#
# Once a payload is DETERMINED (a successful fallback reply, or the dead-letter
# notice) but its SEND fails, the ids stay unread (loss-safe) and the payload is
# spooled to run/…outbound.<sender>; from then on the bridge retries ONLY the
# send and never re-runs a turn for those ids — a broken send path (e.g. a
# nested-sandbox EPERM on send.sh) costs zero further cursor turns.
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
  --readonly         enforce read-only: write a scratch-cwd .cursor/cli.json that
                     denies Write/Shell (+ a secret-path Read denylist) and run
                     with --workspace <project>. Deny survives the user's global
                     approvalMode under --trust (verified). Without it, a global
                     approvalMode:"unrestricted" lets a --trust cursor write/shell.
  --add-dirs-file <path>  newline-listed extra readable directories (the asking
                     Claude session's /add-dir roots) to advertise in the prompt.
  --once             drain the inbox a single time, then exit (for tests).
  --help             show this help.

Env:
  AGMSG_CURSOR_AGENT_CMD        cursor-agent binary (default: cursor-agent). Tests stub this.
  AGMSG_CURSOR_BRIDGE_INTERVAL  default poll interval.
  AGMSG_CURSOR_BRIDGE_TURN_TIMEOUT  seconds to wait for one cursor turn before
                                killing it and retrying (default 180; 0 disables).
  AGMSG_CURSOR_BRIDGE_MAX_CONSEC_FAILURES  consecutive failed turns for the SAME
                                unread ids group before giving up and dead-lettering
                                them (default 10; see the dead-letter note above).
  AGMSG_CURSOR_BRIDGE_FALLBACK_MODEL  model to retry a terminal failure with, ONCE,
                                before dead-lettering (default composer-2.5; set to
                                an empty string to disable the fallback retry).
EOF
}

PROJECT="" TEAM="" NAME="" CHAT_ID=""
INTERVAL="${AGMSG_CURSOR_BRIDGE_INTERVAL:-2}"
ONCE=0
TURN_TIMEOUT="${AGMSG_CURSOR_BRIDGE_TURN_TIMEOUT:-180}"
READONLY=0          # --readonly: enforce read-only via a scratch-cwd .cursor/cli.json
ADD_DIRS_FILE=""    # --add-dirs-file: newline-listed extra readable dirs to advertise
ROLE_FILE=""        # --role-file: standing role prompt prepended to each turn (empty = generic reviewer intro)

while [ "$#" -gt 0 ]; do
  case "$1" in
    --project) PROJECT="${2:?--project needs a path}"; shift 2 ;;
    --team)    TEAM="${2:?--team needs a name}"; shift 2 ;;
    --name)    NAME="${2:?--name needs a name}"; shift 2 ;;
    --chat-id) CHAT_ID="${2:?--chat-id needs an id}"; shift 2 ;;
    --interval) INTERVAL="${2:?--interval needs seconds}"; shift 2 ;;
    --readonly) READONLY=1; shift ;;
    --add-dirs-file) ADD_DIRS_FILE="${2:?--add-dirs-file needs a path}"; shift 2 ;;
    --role-file) ROLE_FILE="${2:?--role-file needs a path}"; shift 2 ;;
    --identity-key) shift 2 ;;   # opaque dup-detection marker (spawn-side only); bridge ignores it
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
MAX_CONSEC_FAILURES="${AGMSG_CURSOR_BRIDGE_MAX_CONSEC_FAILURES:-10}"
case "$MAX_CONSEC_FAILURES" in ''|*[!0-9]*) echo "cursor-bridge: AGMSG_CURSOR_BRIDGE_MAX_CONSEC_FAILURES must be a whole number" >&2; exit 1 ;; esac
# Unset-only default (${VAR-...}, not ${VAR:-...}): an explicitly EMPTY value
# means "no fallback retry, dead-letter terminal failures immediately".
FALLBACK_MODEL="${AGMSG_CURSOR_BRIDGE_FALLBACK_MODEL-composer-2.5}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
SCRIPTS_DIR="$SKILL_DIR/scripts"
RUN_DIR="$SKILL_DIR/run"
# shellcheck disable=SC1091
source "$SCRIPTS_DIR/lib/storage.sh"
# Defense-in-depth (the parent _spawn.sh validates too): TEAM/NAME compose the
# pidfile/meta/log AND the rm -rf'd scratch CFGDIR. Reuse the same UTF-8-safe
# path-segment deny-list as join.sh (rejects '/','\\','.'/'..', leading '-',
# control chars) — NOT an ASCII allow-list, so legal UTF-8 identities still work.
# shellcheck disable=SC1091
source "$SCRIPTS_DIR/lib/validate.sh"
agmsg_validate_team_name "$TEAM" >/dev/null 2>&1 || { echo "cursor-bridge: team name '$TEAM' is not a path-safe segment" >&2; exit 1; }
agmsg_validate_team_name "$NAME" >/dev/null 2>&1 || { echo "cursor-bridge: agent name '$NAME' is not a path-safe segment (no '/', '\\', '.', '..', leading '-', or control chars)" >&2; exit 1; }

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
# Per-sender consecutive-failure counters for the dead-letter gate, keyed by
# (sender, ids-group). Deliberately NOT cleaned up in cleanup() below (like the
# .log) so a streak survives a crash/lazy-respawn of the same TEAM/NAME identity —
# the exact restart that let the incident this feature guards against keep
# retrying a permanently-broken message forever. A sanctioned permanent teardown
# (despawn.sh, incl. session-end's worker) retires it.
FAILSTATE="$RUN_DIR/cursor-bridge.$TEAM.$NAME.failstate"

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

# Read-only scaffolding (populated below when --readonly is set). Initialized here
# so the EXIT trap and `set -u` are safe even on an early exit before setup.
CFGDIR=""            # scratch cwd holding .cursor/cli.json (the deny rules)
ADD_DIRS_NOTE=""     # prompt fragment advertising extra readable dirs
WORKSPACE_ARGS=()    # (--workspace <project>) when read-only is enforced

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
          "$OUTFILE.one" "$OUTFILE.cand" "$OUTFILE.err" \
          "$RUN_DIR/cursor-bridge.$TEAM.$NAME.chat" \
          "$RUN_DIR/cursor-bridge.$TEAM.$NAME.role" \
          "${ADD_DIRS_FILE:-}" 2>/dev/null || true
    # The scratch cwd holds our generated .cursor/cli.json — drop the whole dir.
    [ -n "${CFGDIR:-}" ] && rm -rf "$CFGDIR" 2>/dev/null || true
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

# --- dead-letter state: consecutive failures per (sender, ids-group) ---------
# One line per sender in FAILSTATE: "<sender><US><ids><US><count>". Rewritten
# (not appended) on every update — PIDFILE already serializes one bridge process
# per identity, so there is no concurrent writer to race.

# Echo the persisted failure count for sender $1 when its stored ids match $2
# (the current cycle's ids group); 0 if absent or the ids group has changed
# (a changed group is a fresh streak, per the reset-on-ids-change contract).
failstate_get() {
  local sender="$1" ids="$2" s_sender s_ids s_count
  [ -f "$FAILSTATE" ] || { echo 0; return 0; }
  while IFS="$US" read -r s_sender s_ids s_count; do
    if [ "$s_sender" = "$sender" ]; then
      # Harden against a corrupt/partial line: a non-numeric count fed to the
      # caller's $(( )) would be expanded as a VARIABLE NAME and kill the bridge
      # under set -u. Pure digits only; 10# normalizes a zero-padded "08" that
      # bare arithmetic would reject as invalid octal. Anything else reads as 0.
      if [ "$s_ids" = "$ids" ]; then
        case "$s_count" in
          ''|*[!0-9]*) echo 0 ;;
          *) echo "$((10#$s_count))" ;;
        esac
      else
        echo 0
      fi
      return 0
    fi
  done < "$FAILSTATE"
  echo 0
}

# Replace sender $1's entry with ids=$2 count=$3 (count<=0 drops the entry —
# used on success and after a dead-letter to reset the streak to zero).
failstate_set() {
  local sender="$1" ids="$2" count="$3" tmp s_sender s_ids s_count
  tmp="$FAILSTATE.tmp.$$"
  : > "$tmp"
  if [ -f "$FAILSTATE" ]; then
    while IFS="$US" read -r s_sender s_ids s_count; do
      [ "$s_sender" = "$sender" ] && continue
      printf '%s%s%s%s%s\n' "$s_sender" "$US" "$s_ids" "$US" "$s_count" >> "$tmp"
    done < "$FAILSTATE"
  fi
  if [ "$count" -gt 0 ] 2>/dev/null; then
    printf '%s%s%s%s%s\n' "$sender" "$US" "$ids" "$US" "$count" >> "$tmp"
  fi
  mv "$tmp" "$FAILSTATE" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
}

# --- outbound spool: determined payloads whose SEND failed --------------------
# Once a payload for a sender is DETERMINED (a successful fallback reply, or a
# dead-letter notice), a broken send path must not re-burn cursor turns every
# cycle (real risk: a nested-sandbox EPERM makes send.sh fail permanently). The
# payload is spooled per sender (line 1 = the ids it answers, rest = the exact
# body) and later cycles retry ONLY the send. Like .failstate, spool files
# are not removed by cleanup() (they survive a crash/lazy-respawn on purpose);
# despawn.sh retires them on a permanent teardown.

# Map sender $1 to its spool path. Senders are agmsg-validated names, but
# sanitize for the filename anyway; the cksum suffix keeps two senders that
# sanitize to the same text from colliding.
outbound_file() {
  local sender="$1" safe sum
  safe="$(printf '%s' "$sender" | tr -c 'A-Za-z0-9_.-' '_')"
  sum="$(printf '%s' "$sender" | cksum | awk '{print $1}')"
  printf '%s\n' "$RUN_DIR/cursor-bridge.$TEAM.$NAME.outbound.$safe.$sum"
}

# Spool body $3 answering ids $2 for sender $1 (atomic tmp+mv, best-effort:
# on failure the caller just falls back to the old retry-the-turn behavior).
outbound_put() {
  local sender="$1" ids="$2" body="$3" ofile tmp
  ofile="$(outbound_file "$sender")"
  tmp="$ofile.tmp.$$"
  if { printf '%s\n' "$ids"; printf '%s' "$body"; } > "$tmp" 2>/dev/null \
     && mv "$tmp" "$ofile" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null || true
  return 1
}

# 0 if every id in comma-list $1 is also present in comma-list $2.
ids_subset() {
  local want="$1" have="$2" w
  local IFS=','
  for w in $want; do
    case ",$have," in *",$w,"*) ;; *) return 1 ;; esac
  done
  return 0
}

# Run one read-only cursor turn for $1=prompt, optionally forcing $2=model via
# --model (the fallback retry; omitted on normal turns so the user's global cursor
# model config keeps applying). On a valid, non-error result with a matching
# session id and non-empty text, set REPLY_TEXT and return 0; else return 1
# (caller leaves the messages unread for a retry, UNLESS TURN_ERR_LINE got set —
# see below). NEVER passes --force, so cursor cannot write/run shell — it is a
# pure reviewer (see _spawn.sh D2 note). The prompt goes in via STDIN (a file),
# never argv, so an arbitrarily large inbound batch can't hit ARG_MAX. The call is
# bounded by TURN_TIMEOUT so a hung cursor-agent can't wedge the loop — on timeout
# the turn fails and the message stays unread for the next cycle (the retry half
# of the loss-safe contract).
REPLY_TEXT=""
# First line matching /^(NonRetriableError|ActionRequiredError):/ found in this
# turn's cursor-agent output (stderr, then stdout), set only on a failed ("$rc"
# -ne 0) turn. Empty means no terminal pattern was seen this turn. The caller
# (process_cycle) dead-letters instead of retrying when this is non-empty.
TURN_ERR_LINE=""
run_cursor_turn() {
  local prompt="$1" model="${2:-}"
  local model_args=()
  [ -n "$model" ] && model_args=(--model "$model")
  : > "$OUTFILE"
  printf '%s' "$prompt" > "$PROMPTFILE"
  local errfile="$OUTFILE.err"
  : > "$errfile"
  TURN_ERR_LINE=""
  local rc=0
  # cursor-agent's stderr is captured to a PER-TURN file (not appended straight to
  # $LOG) so a terminal-error scan below sees only THIS turn's output, never a
  # prior turn's leftover text. It is still appended to $LOG right after, so the
  # cumulative debug log is unchanged.
  run_with_timeout "$TURN_TIMEOUT" \
    "$CURSOR_BIN" -p --trust ${WORKSPACE_ARGS[@]+"${WORKSPACE_ARGS[@]}"} ${model_args[@]+"${model_args[@]}"} --output-format json --resume "$CHAT_ID" \
    <"$PROMPTFILE" >"$OUTFILE" 2>"$errfile" || rc=$?
  rm -f "$PROMPTFILE" 2>/dev/null || true
  cat "$errfile" >> "$LOG" 2>/dev/null || true

  # A non-zero exit means cursor-agent failed or was killed by the watchdog. Even
  # if a complete-looking JSON happened to land in $OUTFILE, treat the turn as
  # failed and leave the message unread for the next cycle — never reply/ack off a
  # process that didn't exit cleanly (the loss-safe retry contract). Scan stderr
  # then stdout for a terminal, non-retriable error line (checked at line-start,
  # so it never matches the string appearing mid-sentence in ordinary text).
  if [ "$rc" -ne 0 ]; then
    TURN_ERR_LINE="$(awk '/^(NonRetriableError|ActionRequiredError):/ { print; exit }' "$errfile" "$OUTFILE" 2>/dev/null || true)"
    rm -f "$errfile" 2>/dev/null || true
    echo "cursor-bridge: cursor-agent exited non-zero or timed out (rc=$rc); leaving message unread" >&2
    return 1
  fi
  rm -f "$errfile" 2>/dev/null || true

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

    # Outbound-first: a payload already determined for this sender (spooled when
    # its send failed) is resent as-is — NO cursor turn runs while it exists, so
    # a broken send path costs zero turns per cycle. Delivered => same ack path
    # as a successful turn. Still failing => retry next cycle (the had-work-no-ack
    # backoff applies). Stale (its ids are no longer all unread, e.g. consumed
    # elsewhere) => discard loudly and fall through to a normal turn.
    local ofile o_ids
    ofile="$(outbound_file "$sender")"
    if [ -f "$ofile" ]; then
      o_ids="$(head -n 1 "$ofile" 2>/dev/null || true)"
      if [ -n "$o_ids" ] && ids_subset "$o_ids" "$ids"; then
        if tail -n +2 "$ofile" | "$SCRIPTS_DIR/send.sh" "$TEAM" "$NAME" "$sender" --stdin >/dev/null 2>&1; then
          "$SCRIPTS_DIR/inbox.sh" "$TEAM" "$NAME" --mark-read-ids "$o_ids" >/dev/null 2>&1 || true
          rm -f "$ofile" 2>/dev/null || true
          failstate_set "$sender" "$o_ids" 0
          CYCLE_ACKED=1
          echo "cursor-bridge: delivered spooled outbound to $sender (ids $o_ids)" >&2
        else
          echo "cursor-bridge: spooled outbound for $sender still undeliverable (ids $o_ids); no turn run, retrying next cycle" >&2
        fi
        continue
      fi
      rm -f "$ofile" 2>/dev/null || true
      echo "cursor-bridge: discarded stale outbound for $sender (spooled ids ${o_ids:-?} are no longer all unread)" >&2
    fi

    # No size cap needed: the prompt is fed to cursor-agent via stdin (a file) in
    # run_cursor_turn, not argv, so a large batch cannot hit ARG_MAX.
    # Role injection: a --role-file (spawn resolved db/spawn-roles/<name>.<type>.md)
    # becomes the standing role and replaces the generic "reviewer" intro; the
    # READ-ONLY + delivery meta is always appended. No role file => byte-identical.
    local prompt
    if [ -n "$ROLE_FILE" ] && [ -r "$ROLE_FILE" ]; then
      prompt="$(cat "$ROLE_FILE")

You are acting as '$NAME' in team '$TEAM', running READ-ONLY in $PROJECT$ADD_DIRS_NOTE. The following agmsg message(s) were sent to you by '$sender':

$body_block
Reply with ONLY your final answer for '$sender'. Do NOT run agmsg, send.sh, or any shell command to deliver it — the bridge delivers your reply automatically."
    else
      prompt="You are a headless agmsg reviewer (team '$TEAM', acting as '$NAME'), running read-only in $PROJECT$ADD_DIRS_NOTE. The following agmsg message(s) were sent to you by '$sender':

$body_block
Reply with ONLY your final answer for '$sender'. Do NOT run agmsg, send.sh, or any shell command to deliver it — the bridge delivers your reply automatically."
    fi

    if run_cursor_turn "$prompt"; then
      if printf '%s' "$REPLY_TEXT" | "$SCRIPTS_DIR/send.sh" "$TEAM" "$NAME" "$sender" --stdin >/dev/null 2>&1; then
        "$SCRIPTS_DIR/inbox.sh" "$TEAM" "$NAME" --mark-read-ids "$ids" >/dev/null 2>&1 || true
        failstate_set "$sender" "$ids" 0
        CYCLE_ACKED=1
        echo "cursor-bridge: replied to $sender (ids $ids)" >&2
      else
        echo "cursor-bridge: send to $sender failed; leaving ids $ids unread for retry" >&2
      fi
    else
      # Terminal failure: either THIS turn's output matched a known non-retriable
      # pattern, or this exact (sender, ids) group has now failed
      # MAX_CONSEC_FAILURES times in a row regardless of error shape. Either way,
      # retrying forever would just keep burning cursor-agent calls on a message
      # that can never succeed — dead-letter it instead of leaving it unread.
      local fail_count reason=""
      fail_count=$(( $(failstate_get "$sender" "$ids") + 1 ))
      if [ -n "$TURN_ERR_LINE" ]; then
        reason="$TURN_ERR_LINE"
      elif [ "$fail_count" -ge "$MAX_CONSEC_FAILURES" ]; then
        reason="$fail_count consecutive failures"
      fi
      # Before dead-lettering, retry the SAME turn once on the fallback model —
      # a terminal error is often per-model (e.g. only the fast tier is out of
      # usage), so one forced-model attempt can still salvage the reply.
      if [ -n "$reason" ] && [ -n "$FALLBACK_MODEL" ]; then
        echo "cursor-bridge: terminal failure for $sender ($reason); retrying once with fallback model $FALLBACK_MODEL" >&2
        if run_cursor_turn "$prompt" "$FALLBACK_MODEL"; then
          if printf '%s' "$REPLY_TEXT" | "$SCRIPTS_DIR/send.sh" "$TEAM" "$NAME" "$sender" --stdin >/dev/null 2>&1; then
            "$SCRIPTS_DIR/inbox.sh" "$TEAM" "$NAME" --mark-read-ids "$ids" >/dev/null 2>&1 || true
            failstate_set "$sender" "$ids" 0
            CYCLE_ACKED=1
            echo "cursor-bridge: fallback model used ($FALLBACK_MODEL); replied to $sender (ids $ids)" >&2
            continue
          fi
          # Fallback turn succeeded but the reply couldn't be delivered. Spool
          # the good reply so later cycles retry only the SEND — never re-burn
          # the turn (or the fallback) for an answer we already have. ids stay
          # unread (loss-safe) until the spooled send goes through.
          outbound_put "$sender" "$ids" "$REPLY_TEXT" || true
          failstate_set "$sender" "$ids" "$fail_count"
          echo "cursor-bridge: fallback turn ($FALLBACK_MODEL) succeeded but send to $sender failed; reply spooled to outbound (ids $ids stay unread)" >&2
          continue
        fi
        echo "cursor-bridge: fallback model $FALLBACK_MODEL also failed for $sender; dead-lettering" >&2
      fi
      if [ -n "$reason" ]; then
        local notice="[bridge-error] cursor turn failed permanently (ids $ids): $reason. Messages marked read; resend to retry."
        if printf '%s' "$notice" | "$SCRIPTS_DIR/send.sh" "$TEAM" "$NAME" "$sender" --stdin >/dev/null 2>&1; then
          "$SCRIPTS_DIR/inbox.sh" "$TEAM" "$NAME" --mark-read-ids "$ids" >/dev/null 2>&1 || true
          failstate_set "$sender" "$ids" 0
          CYCLE_ACKED=1
          echo "cursor-bridge: dead-lettered ids $ids for $sender ($reason)" >&2
        else
          # Notice couldn't be delivered — loss-safe: ids stay unread. Spool the
          # notice so later cycles retry only the SEND, never the terminal turn.
          outbound_put "$sender" "$ids" "$notice" || true
          failstate_set "$sender" "$ids" "$fail_count"
          echo "cursor-bridge: turn failed for $sender ($reason); dead-letter notice send failed, spooled to outbound (ids $ids stay unread)" >&2
        fi
      else
        failstate_set "$sender" "$ids" "$fail_count"
        echo "cursor-bridge: turn failed for $sender; leaving ids $ids unread for retry" >&2
      fi
    fi
  done <<< "$senders"
  return 0
}

# Write the read-only .cursor/cli.json into the scratch cwd $1. cursor merges this
# project-level config over the user's global one and DENY takes precedence — even
# under --trust and a global approvalMode:"unrestricted" (verified). Enforces
# deny Write(**)/Shell(**) plus a Read() denylist of common credential paths. This
# is a denylist, not codex-style allowlist scoping: --trust permits every read not
# explicitly denied, so reads stay broad minus these entries.
# Returns non-zero (fail-closed) if the deny config can't be written — the caller
# then refuses to start, so cursor never runs under the user's (possibly
# unrestricted) global config. WARNs to stderr (→ log) for each credential path
# left UNdenied because it sits inside the workspace, so the reduced denylist (e.g.
# PROJECT=$HOME or a dotfiles repo at ~/.config) is visible, not silent.
write_readonly_config() {
  local cfgdir="$1"
  mkdir -p "$cfgdir/.cursor" 2>/dev/null || return 1
  local proj_real; proj_real="$(cd "$PROJECT" 2>/dev/null && pwd -P || printf '%s' "$PROJECT")"
  local deny='"Write(**)", "Shell(**)"'
  local p base_real
  # Credential DIRECTORIES → deny Read(<dir>/**). Skip any that resolve inside the
  # workspace (a deny there would blind the reviewer to project content) or carry a
  # " or \ that would break the JSON string we splice into.
  for p in "$HOME/.ssh" "$HOME/.aws" "$HOME/.gnupg" "$HOME/.kube" \
           "$HOME/.config/gh" "$HOME/.config/gcloud" \
           "$HOME/.config/cursor" "$HOME/.config/codex"; do
    case "$p" in *'"'*|*'\'*) continue ;; esac
    base_real="$(cd "$p" 2>/dev/null && pwd -P || printf '%s' "$p")"
    case "$base_real/" in "$proj_real"/*)
      echo "cursor-bridge: WARNING: '$p' is inside the workspace ($proj_real); NOT denied — the reviewer can read it" >&2
      continue ;;
    esac
    deny="$deny, \"Read($p/**)\""
  done
  # Credential FILES → deny Read(<file>).
  for p in "$HOME/.netrc" "$HOME/.npmrc" "$HOME/.pypirc" \
           "$HOME/.git-credentials" "$HOME/.docker/config.json"; do
    case "$p" in *'"'*|*'\'*) continue ;; esac
    case "$p/" in "$proj_real"/*)
      echo "cursor-bridge: WARNING: '$p' is inside the workspace ($proj_real); NOT denied — the reviewer can read it" >&2
      continue ;;
    esac
    deny="$deny, \"Read($p)\""
  done
  printf '{ "permissions": { "allow": [], "deny": [ %s ] } }\n' "$deny" > "$cfgdir/.cursor/cli.json" || return 1
  return 0
}

if [ "$READONLY" = 1 ]; then
  CFGDIR="$RUN_DIR/cursor-cfg.$TEAM.$NAME"
  rm -rf "$CFGDIR" 2>/dev/null || true
  # Fail closed: if the deny config can't be generated, refuse to start. Running
  # cursor without it would fall back to the user's global config (possibly
  # approvalMode:"unrestricted") — the exact write/shell/read-anything hole this
  # feature exists to close.
  if ! write_readonly_config "$CFGDIR" \
     || [ ! -f "$CFGDIR/.cursor/cli.json" ] \
     || ! json_valid_file "$CFGDIR/.cursor/cli.json"; then
    echo "cursor-bridge: FATAL: could not generate a valid read-only .cursor/cli.json in $CFGDIR; refusing to start (would run cursor unrestricted)" >&2
    exit 1
  fi
  # cwd = scratch config dir (so cursor reads OUR .cursor/cli.json); workspace = the
  # real repo (so the reviewer still explores it). Every other bridge path is
  # absolute, so changing cwd here is safe.
  cd "$CFGDIR" || { echo "cursor-bridge: FATAL: cannot cd to scratch cfg dir $CFGDIR" >&2; exit 1; }
  WORKSPACE_ARGS=(--workspace "$PROJECT")
  echo "cursor-bridge: read-only enforced (cwd=$CFGDIR, workspace=$PROJECT)" >&2
fi

# Advertise inherited /add-dir read roots in every prompt (cursor can already read
# them under --trust; this just tells the model they are in scope).
if [ -n "$ADD_DIRS_FILE" ] && [ -s "$ADD_DIRS_FILE" ]; then
  _ad_list="$(tr '\n' ' ' < "$ADD_DIRS_FILE" | sed 's/  */ /g; s/^ //; s/ $//')"
  [ -n "$_ad_list" ] && ADD_DIRS_NOTE=" (you may also read these directories granted to the requesting Claude session: $_ad_list)"
fi

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
