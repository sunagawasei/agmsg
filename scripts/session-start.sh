#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/lib/compat.sh"

# SessionStart hook for delivery modes `monitor` and `both`.
#
# Usage: session-start.sh <type> <project_path>
#
# Reads the hook input JSON from stdin to extract the session_id, then emits
# an instruction telling Claude to invoke the Monitor tool against watch.sh.
# The hook input includes session_id for SessionStart events.
#
# Before emitting the directive, this script also takes care of preventing
# duplicate watchers across `/clear` (and similar) re-fires of SessionStart
# within the same Claude Code instance. State is kept in
# `~/.agents/agmsg/run/cc-instance.<cc_pid>`, which records the last
# session_id this CC instance attached to. On each fire we kill the watcher
# for the previous session_id, then record the new one. Multiple CC
# instances of the same project get their own cc_pid, so they never step
# on each other.
#
# Quietly exits 0 when whoami says the agent isn't joined to anything yet.
# Mode is implicit: if this script is being invoked at all, it's because
# `delivery.sh set monitor` (or `both`) installed it in the project's
# settings.local.json — that fact alone is the source of truth for "should
# we emit the directive?". No separate global mode value to consult.

TYPE="${1:?Usage: session-start.sh <type> <project_path>}"
PROJECT="${2:?Missing project_path}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RUN_DIR="$SKILL_DIR/run"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/actas-lock.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/resolve-project.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/node.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/hash.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/storage.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/team-lifecycle.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/type-registry.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/session-team.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/role-session.sh"  # role->session reverse lookup (#339)
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/process-identity.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/pending-teardown.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/inflight.sh"
# Only DEFINES agmsg_close_inherited_fds; nothing is closed here. The type
# plug calls it inside a subshell around its own long-lived spawn, so this
# shell's descriptors are untouched. See lib/close-fds.sh.
source "$SCRIPT_DIR/lib/close-fds.sh"

# Read the hook input JSON (stdin) up-front. The hook's session_id is the
# authoritative source for the session team, and stdin can be read only once —
# the type plug and the claude-code path below both rely on this single read.
# Fall back to the env, then to a synthetic id outside the hook flow.
#
# mkdir -p is idempotent and RUN_DIR is created again further down once this
# script's later state needs it; done early here too because the claude-code
# branch below needs RUN_DIR to exist before mktemp can place a file in it.
mkdir -p "$RUN_DIR" 2>/dev/null || true
#
# Only the claude-code + session-team-mode-on gate below needs stdin captured
# byte-for-byte on disk (to check for a raw NUL that $(...) would otherwise
# drop silently, splicing the surrounding bytes together — verified
# empirically 2026-08-23). Every other type/mode keeps the plain read: writing
# every SessionStart's hook payload (which can include cwd/session_id) to
# disk as a side effect of a check that only fires in one mode is not a cost
# to impose on codex/cursor/gemini/grok/copilot and the (default) mode-off
# path. $TYPE and agmsg_session_team_enabled are both already resolvable here.
if [ "$TYPE" = "claude-code" ] && agmsg_session_team_enabled; then
  # Template + $RUN_DIR (not bare mktemp in $TMPDIR) match this repo's other
  # temp-file conventions (delivery.sh, hooks-json.sh, driver-registry.sh) so
  # a leftover is identifiable as agmsg's. Nothing currently sweeps
  # agmsg-hookin.* on a later SessionStart (unlike cc-instance.*/watch.*.pid),
  # so an untrapped kill (SIGTERM/SIGKILL skip the EXIT trap below) leaves it
  # with no automatic recovery short of a full uninstall (keep-data mode
  # doesn't touch run/) — that gap is a known, accepted tradeoff for
  # attribution + staying inside the sandboxed writable root, not a claim
  # that hygiene already covers it.
  _claude_raw_input_file="$(mktemp "$RUN_DIR/agmsg-hookin.XXXXXX" 2>/dev/null || true)"
  _claude_raw_capture_ok=0
  INPUT=""
  if [ -n "$_claude_raw_input_file" ]; then
    trap 'rm -f "$_claude_raw_input_file"' EXIT
    # Both the write and the read-back must succeed for capture to count:
    # a read-back failure (rare, but e.g. a mid-read I/O error) must not
    # silently hand a truncated INPUT to the gate below as if it were the
    # complete hook payload.
    if cat > "$_claude_raw_input_file" 2>/dev/null \
        && INPUT="$(cat "$_claude_raw_input_file" 2>/dev/null)"; then
      _claude_raw_capture_ok=1
    else
      INPUT=""
    fi
  else
    INPUT=$(cat 2>/dev/null || true)
  fi
else
  _claude_raw_input_file=""
  _claude_raw_capture_ok=0
  INPUT=$(cat 2>/dev/null || true)
fi
SESSION_ID=""
if [ -n "$INPUT" ]; then
  # The session id field name differs by vendor: Claude Code emits snake_case
  # "session_id"; Grok Build (and Cursor) emit camelCase "sessionId". Try snake
  # first (claude-code unaffected), then camel.
  #
  # This runs for every type, not just claude-code, and is a best-effort
  # extraction (env/synthetic fallbacks follow below) — not the fail-closed
  # gate. A bare assignment would let a sed/head failure (bad locale,
  # malformed UTF-8 in the payload, missing binary) kill the whole script
  # via errexit before that gate even runs, so a failure here falls through
  # to those fallbacks instead (verified: reproduces on macOS's BSD sed with
  # LC_ALL=C.UTF-8 + invalid UTF-8 input; nix's GNU sed 4.9 does not fail on
  # that same input, but a hook actually runs under the host's shell, so the
  # BSD-sed exposure is real regardless of what this repo's tests use).
  SESSION_ID=$(printf '%s' "$INPUT" \
    | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    | head -1) || SESSION_ID=""
  if [ -z "$SESSION_ID" ]; then
    SESSION_ID=$(printf '%s' "$INPUT" \
      | sed -n 's/.*"sessionId"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
      | head -1) || SESSION_ID=""
  fi
fi
[ -z "$SESSION_ID" ] && SESSION_ID="${CLAUDE_CODE_SESSION_ID:-}"
[ -z "$SESSION_ID" ] && SESSION_ID="${GROK_SESSION_ID:-}"

# Claude Code's session-team registration is fail-closed: only a valid,
# top-level, non-empty string session_id from the hook payload is authoritative.
# Keep the generic SESSION_ID resolver above for watcher compatibility, but in
# Claude Code session-team mode replace its fallback result with the validated
# stdin value below, never with its camelCase/env fallbacks.
if [ "$TYPE" = "claude-code" ] && agmsg_session_team_enabled; then
  # If the temp-file capture above didn't fully succeed (mktemp failed, or
  # the write into it failed), there is no way to check stdin for a raw NUL
  # byte, and a partial write could register a truncated payload as if it
  # were the whole hook input. Fail closed instead of falling back to the
  # NUL-blind INPUT read: "can't verify NUL-freedom" is a rejection here,
  # not license to skip the check.
  if [ "$_claude_raw_capture_ok" != "1" ]; then
    echo "agmsg: refusing Claude Code session-team registration: stdin must contain a non-empty top-level string session_id" >&2
    exit 0
  fi
  # A raw NUL byte in stdin (not the JSON \u0000 escape) never reaches the
  # SQL gate below as a NUL at all: $(...) command substitution silently
  # drops it. Comparing byte counts against INPUT would false-positive on
  # any trailing newline (also stripped by $(...) -- verified empirically
  # 2026-08-23), so instead measure NUL bytes directly in the saved file:
  # if stripping them changes its length, stdin had a raw NUL that INPUT
  # can no longer show.
  # set -e means a bare `x="$(pipeline)"` assignment where the pipeline
  # fails (pipefail) would kill the script right here with no message —
  # the digit checks below would never run. Guarding with `if !`, like the
  # sqlite3 call above, keeps a wc/tr failure inside this fail-closed path
  # instead of an unannounced non-zero exit.
  if ! _claude_raw_len="$(wc -c < "$_claude_raw_input_file" 2>/dev/null | tr -d '[:space:]')" \
      || ! _claude_nonul_len="$(LC_ALL=C tr -d '\000' < "$_claude_raw_input_file" 2>/dev/null | wc -c | tr -d '[:space:]')"; then
    echo "agmsg: refusing Claude Code session-team registration: stdin must contain a non-empty top-level string session_id" >&2
    exit 0
  fi
  # Require both to actually be digit strings too: a successful wc/tr that
  # printed something non-numeric must not be compared as if it were a length.
  case "$_claude_raw_len" in
    ''|*[!0-9]*)
      echo "agmsg: refusing Claude Code session-team registration: stdin must contain a non-empty top-level string session_id" >&2
      exit 0
      ;;
  esac
  case "$_claude_nonul_len" in
    ''|*[!0-9]*)
      echo "agmsg: refusing Claude Code session-team registration: stdin must contain a non-empty top-level string session_id" >&2
      exit 0
      ;;
  esac
  if [ "$_claude_raw_len" != "$_claude_nonul_len" ]; then
    echo "agmsg: refusing Claude Code session-team registration: stdin must contain a non-empty top-level string session_id" >&2
    exit 0
  fi
  # Same reasoning as the wc/tr guard above: a bare assignment here would let
  # a sed failure (missing binary, locale error) kill the script via errexit
  # with no message instead of falling into this fail-closed path.
  if ! _claude_input_sql="$(printf '%s' "$INPUT" | sed "s/'/''/g")"; then
    echo "agmsg: refusing Claude Code session-team registration: stdin must contain a non-empty top-level string session_id" >&2
    exit 0
  fi
  # INVARIANT: keep the substitution inside this open string literal. sqlite3's
  # stdin mode treats a line starting with "." as a dot-command only when no
  # statement is open, so an embedded ".shell"/".print" payload line cannot
  # execute here (verified empirically 2026-08-22).
  _claude_session_sql="
    WITH raw(j) AS (SELECT '$_claude_input_sql'),
    valid(j) AS (SELECT j FROM raw WHERE json_valid(j)),
    candidate(sid) AS (
      SELECT trim(json_extract(j, '\$.session_id'))
      FROM valid
      WHERE json_type(j) = 'object'
        AND json_type(j, '\$.session_id') = 'text'
    )
    SELECT sid
    FROM candidate
    WHERE length(sid) > 0
      AND length(sid) <= 128
      AND instr(sid, char(0)) = 0
      AND sid NOT GLOB '*[^0-9A-Za-z._-]*'
      AND sid NOT GLOB '.*'
    LIMIT 1;
  "
  # -init /dev/null skips a host ~/.sqliterc that could otherwise change the
  # output rendering (.headers on, .mode line, ...) before we treat this
  # value as validated. -noheader -list pins that rendering explicitly.
  #
  # length()/GLOB stop at the first NUL byte, but json_extract's decoded
  # value keeps every byte after it (verified via hex()). instr(sid, char(0))
  # sees those trailing bytes, so it — not length()/GLOB — is what actually
  # rejects a NUL-embedded session_id above.
  if ! _claude_stdin_session_id="$(printf '%s\n' "$_claude_session_sql" \
      | sqlite3 -init /dev/null -noheader -list :memory: 2>/dev/null | tr -d '\r')" \
      || [ -z "$_claude_stdin_session_id" ]; then
    echo "agmsg: refusing Claude Code session-team registration: stdin must contain a non-empty top-level string session_id" >&2
    exit 0
  fi
  # Defense in depth against two distinct failure modes, do not remove as
  # "redundant with the SQL predicates":
  # (a) sqlite3's CLI TEXT output truncates at the first NUL byte (bash's
  #     own command substitution does not truncate — it only drops NUL
  #     bytes and splices the surrounding text together, per the raw-input
  #     capture above), so this re-check cannot catch that specific attack
  #     (instr() above already did) — but the SQL predicates could be
  #     edited independently later.
  # (b) it is the only check that catches a value corrupted by CLI output
  #     rendering (a hostile ~/.sqliterc, a build where -init is a no-op, a
  #     future -escape default change): such corruption injects allowlist-
  #     violating bytes (newlines, quotes, spaces) that only this catches.
  # LC_ALL=C in a subshell keeps the character ranges byte-value-based
  # instead of collation-order-based (bash's globasciiranges default differs
  # by version), so this matches the same ASCII set as the SQL GLOB above.
  if ! (LC_ALL=C
        case "$_claude_stdin_session_id" in
          .*|*[!0-9A-Za-z._-]*) exit 1 ;;
        esac); then
    echo "agmsg: refusing Claude Code session-team registration: stdin must contain a non-empty top-level string session_id" >&2
    exit 0
  fi
  if [ "${#_claude_stdin_session_id}" -gt 128 ]; then
    echo "agmsg: refusing Claude Code session-team registration: stdin must contain a non-empty top-level string session_id" >&2
    exit 0
  fi
  SESSION_ID="$_claude_stdin_session_id"
fi

# Session-team mode: a claude-code session belongs to its own team s-<uuid>,
# resolved from the REAL session id in the validated stdin payload above — NOT
# the generic env or synthetic fallback below. This applies only when the
# gate above ran (claude-code AND session-team mode on): invalid input has
# already exited in that case. Mode-off and non-Claude paths never reach the
# gate and keep their legacy rules below.
# Gated to claude-code (codex never gets a session team here).
SESSION_TEAM=""
[ "$TYPE" = "claude-code" ] && SESSION_TEAM="$(agmsg_session_team_name_from_id "$SESSION_ID")"

# SessionEnd publishes an intentional-teardown tombstone before detaching its
# worker. Clear only this session's marker on its next start; other session
# teams may still be tearing down and must remain protected from recovery.
if [ -n "$SESSION_TEAM" ]; then
  rm -f "$RUN_DIR/watchdog.$SESSION_TEAM.tombstone" 2>/dev/null || true
fi

# Synthetic fallback for the watcher instance id only (keeps the directive
# actionable outside the hook flow); deliberately AFTER team resolution so it
# never feeds the session team.
[ -z "$SESSION_ID" ] && SESSION_ID="unknown-$$"

# Identity sanity check — no point launching a watcher with an empty pair set,
# UNLESS session-team mode will create one.
PAIRS=$("$SCRIPT_DIR/identities.sh" "$PROJECT" "$TYPE" 2>/dev/null || true)
if [ -z "$PAIRS" ] && [ -z "$SESSION_TEAM" ]; then exit 0; fi

# In session-team mode the validated hook session owns a dedicated team and a
# single `claude` identity. Register it before type-specific startup and refresh
# the pair list so every later narrowing/delivery decision sees the new seat.
if [ -n "$SESSION_TEAM" ]; then
  AGMSG_RESOLVE_PROJECT=0 "$SCRIPT_DIR/join.sh" \
    "$SESSION_TEAM" claude "$TYPE" "$PROJECT" >/dev/null 2>&1 || true
  PAIRS=$("$SCRIPT_DIR/identities.sh" "$PROJECT" "$TYPE" 2>/dev/null || true)
fi

# Type-specific SessionStart behaviour (Template Method). A type may ship
# scripts/drivers/types/<type>/_session-start.sh defining agmsg_session_start to override the
# default no-op — codex uses it to hand the session off to the bridge. The plug
# is sourced in this script's context so it sees PROJECT / RUN_DIR / SKILL_DIR /
# PAIRS and the helpers sourced above; it may exit 0 (codex does, having no
# Monitor tool) to skip the Monitor-directive path below.
agmsg_session_start_default() { :; }

_tdir="$(agmsg_type_dir "$TYPE" 2>/dev/null || true)"
if [ -n "$_tdir" ] && [ -f "$_tdir/_session-start.sh" ]; then
  # shellcheck disable=SC1090
  . "$_tdir/_session-start.sh"
  agmsg_session_start
else
  agmsg_session_start_default
fi

# (INPUT / SESSION_ID were parsed at the top — stdin is read only once.)

# --- Skip spawned worktree sub-sessions (.claude/worktrees checkouts). ---
# Claude Code's background-task feature runs a short-lived sub-session in an
# isolated worktree under .claude/worktrees/<name>. SessionStart still fires
# there (#92's resolve-project normalizes its cwd back to the registered
# project, so identities resolve fine), so a persistent inbox watcher was
# getting launched for it too — but that watcher keeps the sub-session's
# Monitor alive past the point its task finishes, so the parent session never
# receives the sub-session's completion notification (#367). The sub-session
# is also not normally an agmsg team member in its own right, so a watcher
# has little value there anyway. cwd may arrive as forward slashes or
# JSON-escaped backslashes depending on platform (a single escaped backslash
# decodes to two raw '\' bytes in the captured substring), so normalize both
# to '/' and squeeze doubled separators before matching. Match the exact
# ".claude/worktrees" PATH SEGMENT sequence, not a loose substring — a naive
# `*.claude*worktrees*` glob would also skip an unrelated project merely
# named e.g. ".claude-tools/my-worktrees-app".
HOOK_CWD=""
if [ -n "$INPUT" ]; then
  # Same failure mode as the SESSION_ID extraction above and the same fix:
  # a bare assignment would let a sed failure (malformed UTF-8 in the
  # payload, bad locale) kill the whole script via errexit. This one runs
  # unconditionally for every type/mode, so it's reachable even more often.
  HOOK_CWD=$(printf '%s' "$INPUT" \
    | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    | head -1) || HOOK_CWD=""
fi
[ -z "$HOOK_CWD" ] && HOOK_CWD="${PWD:-}"
# Same reasoning, but falling back to the un-normalized value (not "") if
# this sed fails: an empty HOOK_CWD_NORM would never match the worktree
# case below, silently skipping the worktree guard instead of just losing
# path normalization for this one hook invocation.
HOOK_CWD_NORM=$(printf '%s' "$HOOK_CWD" | tr '\\' '/' | sed 's#//*#/#g') || HOOK_CWD_NORM="$HOOK_CWD"
case "$HOOK_CWD_NORM" in
  */.claude/worktrees|*/.claude/worktrees/*|.claude/worktrees|.claude/worktrees/*) exit 0 ;;
esac

mkdir -p "$RUN_DIR" 2>/dev/null || true

# --- Identify the enclosing Claude Code process. ---
# Reuse the shared agent-process resolver (#92) instead of a local ps-walk: it
# checks both the `comm` name and argv[0] basename against the type's binaries,
# which is more robust to wrapper/launch shapes than matching only "claude".
# Empty when no agent ancestor is found (detached / sandboxed) — in that case
# the instance id degrades to the bare session_id and the dedup step is skipped.
CC_PID=$(agmsg_agent_pid "$TYPE" 2>/dev/null || true)
if [ -z "$CC_PID" ]; then
  echo "agmsg: owner PID unresolved; using a bare session_id without a cc-instance record, so other sessions' orphan GC may see this session as dead" >&2
fi

# Per-process instance id (see instance-id.sh): "<session_id>.<cc_pid>", or the
# bare session_id when cc_pid is unresolved. This — not the bare session_id — is
# what keys the watcher pidfile / watermark / actas owner, so parallel
# --continue/--resume processes that share a session_id stay isolated (#93).
# The cc-instance dedup record and the emitted watch.sh directive both use it.
INSTANCE_ID="$(agmsg_instance_id_from_pid "$SESSION_ID" "$CC_PID")"
WATCH_PROJECT="$(agmsg_resolve_project "$PROJECT" "$TYPE")"

# --- Cleanup of stale cc-instance files and their orphan watchers. ---
# A cc-instance.<pid> whose CC pid is dead is left over from a previous CC.
# Before removing it, optionally kill the watcher bound to its last
# session_id — but only if that session_id isn't still referenced by a
# LIVE cc-instance file. The same session_id can move from one CC pid to
# another (e.g. on `claude --continue` / `--resume`), so a dead-pid record
# alone is not evidence the session is gone.

# First pass: collect session_ids that are still referenced by a LIVE CC.
live_sids=""
for f in "$RUN_DIR"/cc-instance.*; do
  [ -f "$f" ] || continue
  pid=${f##*.}
  case "$pid" in ''|*[!0-9]*) continue ;; esac
  if _agmsg_pid_alive "$pid"; then
    s=$(cat "$f" 2>/dev/null || true)
    [ -n "$s" ] && live_sids="$live_sids|$s"
  fi
done

# Second pass: clean each dead cc-instance, killing its bound watcher only
# when no live CC still references that session_id.
for f in "$RUN_DIR"/cc-instance.*; do
  [ -f "$f" ] || continue
  pid=${f##*.}
  case "$pid" in ''|*[!0-9]*) continue ;; esac
  _agmsg_pid_alive "$pid" && continue
  dead_sid=$(cat "$f" 2>/dev/null || true)
  if [ -n "$dead_sid" ] \
      && ! printf '%s\n' "$live_sids" | tr '|' '\n' | grep -Fxq "$dead_sid"; then
    orphan_pidfile="$RUN_DIR/watch.$dead_sid.pid"
    if [ -f "$orphan_pidfile" ]; then
      agmsg_process_identity_state watch "$orphan_pidfile" "" \
        "$SKILL_DIR/scripts/watch.sh" "$dead_sid"
      if [ "$AGMSG_PROCESS_STATE" = owned ]; then
        agmsg_process_signal_owned watch "$orphan_pidfile" \
          "@hash:$AGMSG_PROCESS_SCOPE_HASH" TERM \
          "$SKILL_DIR/scripts/watch.sh" "$dead_sid" >/dev/null || true
      fi
      case "$AGMSG_PROCESS_STATE" in
        stale|legacy-dead|legacy-foreign-live|legacy-unverified-live|degraded-dead|unverified-dead)
          agmsg_process_cleanup_observed "$orphan_pidfile" || true ;;
      esac
    fi
  fi
  rm -f "$f"
done

# Same defensive pass for stale watcher pidfiles. A live leased owner holds its
# lease for its whole life, so an unheld lease means the recorded pid was reused.
for f in "$RUN_DIR"/watch.*.pid; do
  [ -f "$f" ] || continue
  agmsg_process_identity_state watch "$f" ""
  case "$AGMSG_PROCESS_STATE" in
    stale|legacy-dead|legacy-foreign-live|degraded-dead|unverified-dead)
      agmsg_process_cleanup_observed "$f" || true ;;
  esac
done

# Garbage-collect actas exclusivity locks whose owner session_id no longer
# maps to a live cc-instance. Must run after the dead cc-instance cleanup
# above, since the liveness check enumerates the remaining cc-instance.*
# files. See #62.
actas_lock_gc_stale >/dev/null 2>&1 || true

# --- Record this session's real project root, keyed by the agent process. ---
# Slash commands resolve the project from $(pwd), which breaks when the user
# cd's into a subdir/worktree (see #92). Persist the authoritative project (our
# $2, baked into the hook at delivery time) keyed by the enclosing agent PID so
# actas/join/whoami can recover it without a stable session_id — the key that
# makes this work for Codex too. Drop markers whose agent process has died.
agmsg_marker_gc_stale 2>/dev/null || true
AGENT_PID=$(agmsg_agent_pid "$TYPE" 2>/dev/null || true)
[ -n "$AGENT_PID" ] && agmsg_write_project_marker "$AGENT_PID" "$PROJECT" 2>/dev/null || true

# Garbage-collect stream watermarks (#107) and readiness sentinels (#108) whose
# owner session_id is no longer alive — left behind when a watcher dies without
# running its EXIT trap (SIGKILL, terminal crash). Runs after the dead
# cc-instance cleanup so actas_lock_sid_alive reflects current liveness. Both
# are advisory (a live watcher rewrites them on attach; spawn clears the
# sentinel before use), so this is hygiene, not correctness.
for f in "$RUN_DIR"/watch.*.watermark; do
  [ -f "$f" ] || continue
  wm_sid=${f##*/}; wm_sid=${wm_sid#watch.}; wm_sid=${wm_sid%.watermark}
  actas_lock_sid_alive "$wm_sid" || rm -f "$f"
done
for f in "$RUN_DIR"/ready.*; do
  [ -f "$f" ] || continue
  rd_sid=$(cat "$f" 2>/dev/null || true)
  { [ -n "$rd_sid" ] && actas_lock_sid_alive "$rd_sid"; } || rm -f "$f"
done


# --- Dedup against the previous watcher in this CC instance. ---
if [ -n "$CC_PID" ]; then
  STATE="$RUN_DIR/cc-instance.$CC_PID"
  if [ -f "$STATE" ]; then
    # Records the previous instance id this CC attached to. Comparing/killing
    # by instance id (not bare session_id) keeps the prev_pidfile lookup aligned
    # with watch.sh's pidfile key.
    prev=$(cat "$STATE" 2>/dev/null || true)
    if [ -n "$prev" ] && [ "$prev" != "$INSTANCE_ID" ]; then
      prev_pidfile="$RUN_DIR/watch.$prev.pid"
      if [ -f "$prev_pidfile" ]; then
        prev_pid=$(cat "$prev_pidfile" 2>/dev/null || true)
        if [ -n "$prev_pid" ] && _agmsg_pid_alive_local "$prev_pid"; then
          kill "$prev_pid" 2>/dev/null || true
        fi
      fi
    fi
  fi
  # Serialize publication with SessionEnd's final sibling check and teardown.
  # Failing closed is safer than publishing outside the lock: an unlocked write
  # could arrive after the worker's sibling check and before its force action.
  _lifecycle_team="s-${SESSION_ID%%.*}"
  if ! agmsg_team_lifecycle_lock_acquire "$_lifecycle_team" \
      "${AGMSG_LIFECYCLE_LOCK_TIMEOUT:-10}"; then
    echo "agmsg: could not serialize SessionStart registration for $_lifecycle_team" >&2
    exit 0
  fi
  printf '%s\n' "$INSTANCE_ID" > "$STATE"
  # Recover this team under the same lock that published cc-instance so a
  # resume's bare-sid veto and the kill decision cannot straddle another
  # SessionStart. Other teams are recovered after release to avoid holding
  # two team locks at once.
  AGMSG_TEAM_LIFECYCLE_HELD="$_lifecycle_team" \
    AGMSG_PENDING_ONLY_TEAM="$_lifecycle_team" \
    agmsg_pending_teardown_recover_all "$SCRIPT_DIR/despawn.sh" || true
  agmsg_team_lifecycle_lock_release "$_lifecycle_team"
  AGMSG_PENDING_SKIP_TEAM="$_lifecycle_team" \
    agmsg_pending_teardown_recover_all "$SCRIPT_DIR/despawn.sh" || true
  agmsg_inflight_reap_dead || true
else
  # A bare SessionStart cannot publish cc-instance, so it cannot veto
  # recovery for its own team. Do not recover here. In-flight reap is not
  # teardown: it only dead-letters records whose process generation is gone.
  agmsg_inflight_reap_dead || true
fi

# --- Orphan headless inventory (session-team mode). ---
# Bare session-id liveness is advisory: its absence cannot authorize teardown.
# Report every headless placement that would historically have been reaped, but
# never signal a process or remove registration here. Deferred teardown above
# is the sole automatic recovery path and requires direct owner-process proof.
if agmsg_session_team_enabled; then
  # Spawn records use the same reversible encoding as actas locks:
  #   spawn.<encoded-team>__<encoded-agent>
  # Session-team names use the UUID-safe `s-<hex-and-dash>` contract, so the
  # first `__` is the unambiguous team/worker delimiter. Worker names may still
  # contain `__` and are decoded after stripping the team segment.
  _orphan_gc_record() {
    local _gc_rec="$1" _gc_key _gc_enc_team _gc_enc_name
    local _gc_team _gc_sid _gc_name _gc_snapshot _gc_id _gc_project _gc_type
    local _gc_pid _gc_now _gc_mtime _gc_age _gc_pending_state _gc_pending_field
    local _gc_log_team _gc_log_name
    _gc_key="${_gc_rec##*/spawn.}"
    _gc_enc_team="${_gc_key%%__*}"
    _gc_enc_name="${_gc_key#*__}"
    case "$_gc_enc_team" in s-*) ;; *) return 0 ;; esac
    _gc_sid="${_gc_enc_team#s-}"
    case "$_gc_sid" in ''|*[!0-9A-Fa-f-]*) return 0 ;; esac
    _gc_team="$(_actas_lock_decode "$_gc_enc_team" 2>/dev/null || true)"
    [ -n "$_gc_enc_name" ] || return 0
    _gc_name="$(_actas_lock_decode "$_gc_enc_name" 2>/dev/null || true)"
    [ -n "$_gc_name" ] || return 0
    [ "$(_actas_lock_encode "$_gc_name" 2>/dev/null || true)" = "$_gc_enc_name" ] || return 0
    agmsg_instance_alive "$_gc_sid" 2>/dev/null && return 0

    # Read once. The same immutable snapshot drives eligibility and the
    # compare-and-act guard, so a headless→interactive replacement cannot
    # cause despawn to act on the new interactive placement.
    _gc_snapshot="$(cat "$_gc_rec" 2>/dev/null || true)"
    [ -n "$_gc_snapshot" ] || return 0
    IFS=$'\t' read -r _gc_id _gc_project _gc_type <<<"$_gc_snapshot" || return 0
    case "${_gc_id:-}" in
      pid:*)
        _gc_pid="${_gc_id#pid:}"
        _gc_age=unknown
        _gc_now="$(date +%s 2>/dev/null || true)"
        _gc_mtime="$(compat_file_mtime "$_gc_rec" 2>/dev/null || true)"
        case "$_gc_now:$_gc_mtime" in
          *[!0-9:]*) ;;
          *:|:*) ;;
          *)
            if [ "$_gc_now" -ge "$_gc_mtime" ]; then
              _gc_age=$((_gc_now - _gc_mtime))
            fi
            ;;
        esac
        _gc_pending_state="$(agmsg_pending_teardown_owner_state \
          "$_gc_team" "$_gc_name" 2>/dev/null || true)"
        _gc_pending_field=""
        [ "$_gc_pending_state" = unverified ] \
          && _gc_pending_field=" pending_owner=unverified"
        _gc_log_team="$(agmsg_pending_log_sanitize "$_gc_team")"
        _gc_log_name="$(agmsg_pending_log_sanitize "$_gc_name")"
        printf 'agmsg: orphan candidate team=%s worker=%s bridge_pid=%s spawn_age_s=%s%s\n' \
          "$_gc_log_team" "$_gc_log_name" "$_gc_pid" "$_gc_age" \
          "$_gc_pending_field" >&2
        ;;
      *) ;; # interactive placements (%*, @*, herdr:*) are preserved
    esac
  }

  for _spawn_rec in "$RUN_DIR"/spawn.s-*__*; do
    [ -f "$_spawn_rec" ] || continue
    _orphan_gc_record "$_spawn_rec"
  done
fi

# --- Stale session-team GC (session-team mode). ---
# Session teams accumulate one dir per session. Reap teams/s-<uuid> whose owner
# session is no longer alive AND whose dir has been untouched past the TTL
# (delivery.session_team_ttl_days, default 7). A resume re-joins and bumps the
# mtime, so active/recent sessions are safe, and the liveness check guards
# in-flight ones. Scratch cwd, pidfiles, placement and logs go too. Messages are
# deliberately KEPT — rows keyed on the team stay queryable as history and are
# governed by a separate retention policy, not this hygiene pass.
if agmsg_session_team_enabled; then
  _ttl="$("$SCRIPT_DIR/config.sh" get delivery.session_team_ttl_days 7 2>/dev/null || echo 7)"
  case "$_ttl" in ''|*[!0-9]*) _ttl=7 ;; esac
  for _d in "$SKILL_DIR"/teams/s-*/; do
    [ -d "$_d" ] || continue
    _tn="$(basename "$_d")"                                       # s-<uuid>
    _ttl_log_team="$(agmsg_pending_log_sanitize "$_tn")"
    if agmsg_instance_alive "${_tn#s-}" 2>/dev/null; then
      printf 'agmsg: session-team TTL GC skipped team=%s reason=bare-owner-alive\n' \
        "$_ttl_log_team" >&2
      continue
    fi
    # A live bridge recorded by this exact team is an independent veto.
    # Malformed or unverifiable pid: placements also veto: they must not grant
    # deletion the way HEAD's unverified despawn used to keep the team.
    _ttl_live_bridge_pid=""
    _ttl_unverified_placement=0
    for _ttl_rec in "$RUN_DIR/spawn.${_tn}__"*; do
      [ -f "$_ttl_rec" ] || continue
      _ttl_line=""
      IFS= read -r _ttl_line <"$_ttl_rec" 2>/dev/null || true
      _ttl_placement="${_ttl_line%%$'\t'*}"
      case "$_ttl_placement" in
        pid:*)
          _ttl_pid="${_ttl_placement#pid:}"
          case "$_ttl_pid" in
            ''|*[!0-9]*)
              _ttl_unverified_placement=1
              break
              ;;
          esac
          if ! [ "$_ttl_pid" -gt 0 ] 2>/dev/null; then
            _ttl_unverified_placement=1
            break
          fi
          if _agmsg_pid_alive "$_ttl_pid"; then
            _ttl_live_bridge_pid="$_ttl_pid"
            break
          fi
          ;;
        %*|@*|herdr:*) ;;
        *)
          [ -n "$_ttl_line" ] || continue
          _ttl_unverified_placement=1
          break
          ;;
      esac
    done
    if [ -n "$_ttl_live_bridge_pid" ]; then
      printf 'agmsg: session-team TTL GC skipped team=%s reason=live-bridge bridge_pid=%s\n' \
        "$_ttl_log_team" "$_ttl_live_bridge_pid" >&2
      continue
    fi
    if [ "$_ttl_unverified_placement" -eq 1 ]; then
      printf 'agmsg: session-team TTL GC skipped team=%s reason=unverified-placement\n' \
        "$_ttl_log_team" >&2
      continue
    fi
    # `find -mtime` exits 0 whether or not the dir matches, so gate on its
    # OUTPUT (non-empty == older than the TTL), not its exit code.
    [ -n "$(find "$_d" -maxdepth 0 -mtime +"$_ttl" 2>/dev/null)" ] || continue  # too recent → keep
    # Live/unverified inflight is independent proof of a still-consumed turn.
    # Spawn may already be gone, so the live-bridge veto above cannot see it.
    # Reap dead generations first; if any record remains, keep the whole team.
    if ! agmsg_inflight_gc_team "$_tn"; then
      printf 'agmsg: session-team TTL GC skipped team=%s reason=live-inflight\n' \
        "$_ttl_log_team" >&2
      continue
    fi
    rm -rf "$_d" 2>/dev/null || true
    rm -rf "$SKILL_DIR/run/codex-$_tn-cwd" 2>/dev/null || true
    rm -f "$SKILL_DIR/run/codex-bridge.$_tn".* 2>/dev/null || true
    rm -rf "$SKILL_DIR/run/claude-code-$_tn-"*-cwd 2>/dev/null || true
    rm -f "$SKILL_DIR/run/claude-code-bridge.$_tn".* 2>/dev/null || true
    rm -f "$SKILL_DIR/run/spawn.$_tn"__* 2>/dev/null || true
    rm -f "$SKILL_DIR/run/pending-teardown.$_tn"__* 2>/dev/null || true
    rm -rf "$SKILL_DIR/run/placement.$_tn"__*.lock 2>/dev/null || true
  done
fi

# --- Skip directive when a watcher is already alive for this instance. ---
# /compact re-fires SessionStart within the same CC process and session_id, so
# INSTANCE_ID is identical to the already-running watcher's.  Without this
# guard the agent spawns a second Monitor whose watch.sh kills the incumbent,
# the old Monitor task emits "stream ended", and the agent loops trying to
# restart.  Mirrors emit_monitor_directive in delivery.sh.
WATCHER_PIDFILE="$RUN_DIR/watch.$INSTANCE_ID.pid"
if [ -f "$WATCHER_PIDFILE" ]; then
  existing=$(cat "$WATCHER_PIDFILE" 2>/dev/null || true)
  if [ -n "$existing" ] && _agmsg_pid_alive_local "$existing"; then
    cat <<EOF
AGMSG monitor mode: a watch.sh is already streaming for this session (pid $existing).
No action needed — the existing watcher is the active one.
EOF
    exit 0
  fi
fi

# --- Role-aware resume (#339). ---
# If this session's bare sid was recorded as a role's seat (by actas-claim, or
# codex actas), and that (team, agent) is registered for THIS project, emit the
# ROLE-FILTERED directive instead of the generic unfiltered one: watch.sh with a
# 4th <agent> arg restricts receive to that role AND re-claims its exclusivity
# lock. This covers a manual `claude --resume <uuid>` that bypasses spawn's actas
# boot prompt -- the resumed session re-arms as its role automatically. When no
# record matches, narrowing (#982) tries the actas lock this sid owns; if the
# seat still cannot be established the fallback is fail-CLOSED, not the generic
# unfiltered watcher (which would consume other seats' unread) -- see the two
# blocks below.
ROLE_NAME=""; ROLE_TEAM=""; ROLE_BASIS=""
_bare_sid="$(agmsg_instance_bare_sid "$SESSION_ID" 2>/dev/null || printf '%s' "$SESSION_ID")"
_rec="$(agmsg_role_session_lookup_by_sid "$_bare_sid" 2>/dev/null || true)"
if [ -n "$_rec" ]; then
  _r_agent="$(printf '%s\n' "$_rec" | sed -n 's/^agent=//p' | head -1)"
  _r_team="$(printf '%s\n' "$_rec" | sed -n 's/^team=//p' | head -1)"
  # Guard against a cross-project sid collision: only honor the record when its
  # (team, agent) is actually one of this project's registered pairs.
  if [ -n "$_r_agent" ] && [ -n "$_r_team" ] \
     && printf '%s\n' "$PAIRS" | grep -Fxq "$(printf '%s\t%s' "$_r_team" "$_r_agent")"; then
    ROLE_NAME="$_r_agent"; ROLE_TEAM="$_r_team"; ROLE_BASIS=record
  fi
fi

# --- Narrowing when the role-session record is missing (#982). ---
# The record above is advisory and can be absent even for a session that IS a
# seat (a resume that bypassed actas-claim, an unreadable record). The same fact
# it would carry may still be on disk: an actas.<team>__<agent>.session lock this
# very sid owns. Match the lock owner's BARE sid (stable across resume; the pid
# half changes) against ours, iterating THIS project's registered pairs rather
# than raw lock filenames (those are percent-encoded, and iterating PAIRS keeps
# us to locks that are actually registered here). Exactly one match re-seats us;
# zero leaves ROLE_NAME empty for the fail-closed decision below, and an ambiguous
# 2+ deliberately does the same — an unfiltered watcher is the one thing we must
# not fall back to (it consumes other seats' unread; see the block after the
# role-filtered emit).
if [ -z "$ROLE_NAME" ]; then
  _narrow_n=0; _narrow_agent=""; _narrow_team=""
  _tab="$(printf '\t')"
  while IFS="$_tab" read -r _p_team _p_agent; do
    [ -n "$_p_team" ] && [ -n "$_p_agent" ] || continue
    _owner="$(actas_lock_owner "$_p_team" "$_p_agent" 2>/dev/null || true)"
    [ -n "$_owner" ] || continue
    _owner_bare="$(agmsg_instance_bare_sid "$_owner" 2>/dev/null || printf '%s' "$_owner")"
    if [ "$_owner_bare" = "$_bare_sid" ]; then
      _narrow_n=$((_narrow_n + 1)); _narrow_agent="$_p_agent"; _narrow_team="$_p_team"
    fi
  done <<EOF
$PAIRS
EOF
  if [ "$_narrow_n" -eq 1 ]; then
    ROLE_NAME="$_narrow_agent"; ROLE_TEAM="$_narrow_team"; ROLE_BASIS=actas
  fi
fi

WATCH="$SKILL_DIR/scripts/watch.sh"
# AGMSG_CC_MONITOR_KEEP_ALIVE, default OFF: timeout_ms: 1800000 always stays
# in both directives below (the Monitor tool caps every watch there
# regardless). What differs is whether re-arming on expiry is UNCONDITIONAL
# or read off the expiry notification itself. Claude Code counts the events
# on its own side and names that count in the notification -- agmsg never
# counts it -- so the default case below is worded as a plain word match on
# that notification ("no events" present or not), never as reading a
# number: the exact phrasing may drift, and a seat that has to parse a
# count is a seat this can break by rewording the notification later. Kept
# word-for-word identical to scripts/delivery.sh's emit_monitor_directive
# and scripts/drivers/types/claude-code/template.md's actas overlay -- the
# three surfaces must never disagree with each other.
REARM_NOTE=""
if [ -n "${AGMSG_CC_MONITOR_KEEP_ALIVE:-}" ]; then
  REARM_NOTE="
This watch expires after at most 30 minutes; when the expiry notice arrives,
immediately re-arm it by invoking Monitor again with this exact command and
description — delivery depends on it, since nothing else keeps the stream
running. Re-arm it silently: no message to the user, no \"re-armed\", no
acknowledgement, no summary — just invoke Monitor again and continue,
since announcing it every 30 minutes wastes tokens for no benefit."
else
  REARM_NOTE="
This watch expires after at most 30 minutes.
If the expiry notification says it delivered no events, do not re-arm it.
Otherwise (it says it delivered something), re-arm it by invoking Monitor again with this exact command and description.
Re-arm it silently, when you do: no message to the user, no \"re-armed\", no
acknowledgement, no summary — just invoke Monitor again and continue, since
announcing it every 30 minutes wastes tokens for no benefit."
fi
# Shell-quote each argv so the host can paste the command into Monitor and run
# it verbatim. A plain '...' wrap breaks on paths with an apostrophe
# (/Users/o'brien/...); printf %q escapes spaces, quotes and other metacharacters
# safely for shell re-execution (#188). A resumed role adds the 4th <agent> arg.
if [ -n "$ROLE_NAME" ]; then
  WATCH_COMMAND="$(printf '%q %q %q %q %q' "$WATCH" "$INSTANCE_ID" "$PROJECT" "$TYPE" "$ROLE_NAME")"
  # State the seat's basis honestly: the reader launches a watcher on the strength
  # of this sentence, so a recorded seat and an inferred one must not read alike
  # (#982/#993). The record path has an explicit role-session record; the narrowing
  # path has only the actas lock this sid still owns — say which, and why it stands
  # in for the record, so the reader can weigh "what if the lock is stale?".
  if [ "$ROLE_BASIS" = record ]; then
    SEAT_CLAIM="this session was recorded as that role's seat"
  else
    SEAT_CLAIM="no role record was found for this session, but it still owns that role's actas exclusivity lock — claimed by this seat and carried across the resume — which is taken to stand in for the record (so if that lock were stale, this seating would be too)"
  fi
  cat <<EOF
AGMSG monitor mode (resumed role \`$ROLE_NAME\` in team \`$ROLE_TEAM\`):
$SEAT_CLAIM, so invoke the Monitor tool now with the following parameters, before
any other action in this session.

  command: $WATCH_COMMAND
  description: agmsg inbox stream (acting as $ROLE_NAME)
  persistent: true
  timeout_ms: 1800000
$REARM_NOTE

The 4th argument restricts receive to \`$ROLE_NAME\` only and re-claims its actas
exclusivity lock — a resume restores context but not runtime state, so this
re-establishes the role. Send with \`send.sh ... $ROLE_NAME ...\` (this session's
active FROM is \`$ROLE_NAME\`). Each output line is one message:
\`<ts> | <team> | <from> → <to> | <body>\`. React as they arrive.

Use Claude Code's generic Monitor tool only. First confirm ToolSearch
select:Monitor finds that generic tool; Azure Monitor, MCP monitor, or other
monitor-branded tools are not valid for agmsg delivery. Do not start watch.sh
with Bash/background/nohup or a shell task. Success is:

  - Monitor(agmsg inbox stream (acting as $ROLE_NAME)) starts
  - TaskList shows a task whose description begins with "agmsg inbox
    stream (acting as $ROLE_NAME)" for this session (the reliable check;
    the background-task footer is not)
  - the transcript later contains Monitor event: "agmsg inbox stream
    (acting as $ROLE_NAME)"

If the generic Monitor tool is unavailable, do not treat a background shell
watcher as success. Switch to turn delivery or run manual inbox checks instead;
those fallbacks are not real-time monitor delivery.

Note: On a /clear or --continue/--resume re-fire, you may shortly see a
"Monitor … stopped" notification for an earlier 'agmsg inbox stream'
task. That is the previous watcher being cleaned up — expected. Do NOT
relaunch it; the Monitor you invoke from this directive replaces it.
EOF
  exit 0
fi

# --- Fail-closed fallback (#982). ---
# No seat was established (no role-session record, and no single actas lock this
# sid owns). Emitting the generic, unfiltered watch.sh here is NOT a "receive a
# bit more" degradation: on a project with several registered pairs it subscribes
# to ALL of them, and watch.sh stamps read_at + advances every pair's read_cursor
# to the tip as it delivers — so it CONSUMES other seats' unread mail, silently,
# and irreversibly short of hand-editing the store. That is the expensive
# direction to default to. So reserve the generic watcher for a single-pair
# project, where there is no one else's mail to take; with more than one pair,
# stand down and say why (a silent no-watcher is indistinguishable from "no
# messages arriving"), naming `/agmsg actas <name>` so the seat can be set
# explicitly — which re-fires this hook down the role-filtered path above.
_pair_count="$(printf '%s\n' "$PAIRS" | grep -c '.' || true)"
if [ -n "$SESSION_TEAM" ] || [ "${_pair_count:-0}" -le 1 ]; then
  WATCH_COMMAND="$(printf '%q %q %q %q' "$WATCH" "$INSTANCE_ID" "$PROJECT" "$TYPE")"
  if [ -n "$SESSION_TEAM" ]; then
    WATCH_COMMAND="$WATCH_COMMAND $(printf '%q %q %q' claude --team "$SESSION_TEAM")"
  fi
  cat <<EOF
AGMSG monitor mode: invoke the Monitor tool now with the following parameters,
before any other action in this session.

  command: $WATCH_COMMAND
  description: agmsg inbox stream
  persistent: true
  timeout_ms: 1800000
$REARM_NOTE

This streams incoming agmsg messages into the session in real time. Each
output line is one message: \`<ts> | <team> | <from> → <to> | <body>\`.
React to messages as they arrive; reply with \`send.sh\`.

Use Claude Code's generic Monitor tool only. First confirm ToolSearch
select:Monitor finds that generic tool; Azure Monitor, MCP monitor, or other
monitor-branded tools are not valid for agmsg delivery. Do not start watch.sh
with Bash/background/nohup or a shell task. Success is:

  - Monitor(agmsg inbox stream) starts
  - TaskList shows a task whose description begins with "agmsg inbox
    stream" for this session (the reliable check; the background-task
    footer is not)
  - the transcript later contains Monitor event: "agmsg inbox stream"

If the generic Monitor tool is unavailable, do not treat a background shell
watcher as success. Switch to turn delivery or run manual inbox checks instead;
those fallbacks are not real-time monitor delivery.

Note: On a /clear or --continue/--resume re-fire, you may shortly see a
"Monitor … stopped" notification for an earlier 'agmsg inbox stream'
task. That is the previous watcher being cleaned up to avoid duplicates
— it is expected. Do NOT relaunch it; the Monitor you invoke from this
directive replaces it.
EOF
  exit 0
fi

# Multiple registered seats here and none identified as this session: stand down.
# Emit NO watch.sh directive — there is nothing for the host to launch, so no
# other seat's mail can be consumed — and explain the state so it is not mistaken
# for silence.
_seat_list="$(printf '%s\n' "$PAIRS" | awk -F'\t' 'NF>=2 && $2!="" {print "  - /agmsg actas "$2}')"
cat <<EOF
AGMSG monitor mode: standing down — no inbox watcher was started for this session.

This resumed session could not be matched to a seat (no role-session record, and
no actas lock it owns), and this project has more than one registered seat. An
unfiltered watcher would subscribe to every seat here and mark THEIR unread
messages read as it delivered them — consuming mail addressed to other sessions.
So no watcher is started rather than the wrong one.

No messages are lost: they remain in the store (\`history.sh <team> <agent>\`
returns them). What is paused is live delivery into THIS session.

To start receiving as your seat, claim it explicitly — this re-fires the monitor
directive on the role-filtered path:

$_seat_list

If you are not any of these seats, no watcher is the correct state.
EOF
exit 0
