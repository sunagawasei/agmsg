#!/usr/bin/env bash
# cursor spawn plug — headless read-only-reviewer worker launch (Template Method).
#
# Sourced by spawn.sh in its global context (so it sees AGENT_TYPE, NAME, TEAM,
# PROJECT, HEADLESS, HEADLESS_SET, REVIEWER, REVIEWER_SET, SCRIPT_DIR, SKILL_DIR
# and the helpers agmsg_placement_lock_*, agmsg_spawn_path, agmsg_type_get and
# die()). Defines agmsg_spawn_resolve_modes + agmsg_spawn_headless, overriding
# spawn.sh's no-op / "unsupported" defaults — same Template Method convention as
# codex/_spawn.sh.
#
# Why this is so much smaller than codex/_spawn.sh: cursor-agent's headless
# interface is a ONE-SHOT CLI (`cursor-agent -p --output-format json --resume
# <chatId>`), NOT a long-lived app-server. There is no JSON-RPC daemon to manage,
# no turn-lifecycle protocol, and — crucially — the bridge runs cursor READ-ONLY
# (`--trust`, never `--force`) and sends the reply itself (approach b). cursor
# therefore never needs write/shell access to participate, so the entire codex
# apparatus (seatbelt nesting probes, writable_roots, reviewer permission
# profiles) is unnecessary. The whole worker is a small bash loop, cursor-bridge.sh.
#
# Security model (D2): the read-only boundary is "the bridge never passes
# --force", so cursor's own tool-approval gate denies writes/shell in headless
# mode. This is product behavior, not an OS sandbox. We deliberately do NOT run a
# live "try to write the repo, refuse if it succeeds" probe at spawn: it would be
# a full ~10s agent turn (plus tokens) on every spawn AND is model-dependent and
# flaky (the model may simply decline to attempt the write), so a green probe
# would not actually prove the boundary — security theater. The deterministic,
# fast guard is "never pass --force", and the bats suite pins the bridge flag set
# (--trust present, --force/--yolo absent) as the regression guard. If cursor-agent
# ever changes so --trust alone permits writes, that test is where it must be
# caught — and the fix is a flag/config change here, not a per-spawn probe.

CURSOR_BIN="${AGMSG_CURSOR_AGENT_CMD:-cursor-agent}"

# Resolve the headless default from config when no explicit flag was given.
#   precedence: --headless / --interactive  >  config spawn.cursor_headless  >  TUI
agmsg_spawn_resolve_modes() {
  if [ "$HEADLESS_SET" = 0 ]; then
    case "$("$SCRIPT_DIR/config.sh" get spawn.cursor_headless false 2>/dev/null || true)" in
      true|1|yes|on) HEADLESS=1 ;;
    esac
  fi
  # cursor has no reviewer/consultant split — a headless cursor is always a
  # read-only reviewer in the project dir — so --reviewer is meaningless. Reject
  # an explicit flag; the codex config opt-in must never silently apply here.
  if [ "$REVIEWER_SET" = 1 ] && [ "$REVIEWER" = 1 ]; then
    die "--reviewer is not supported for 'cursor' (a headless cursor is always a read-only reviewer in the project dir)"
  fi
  REVIEWER=0
}

# Launch a no-terminal cursor bridge worker and return. Called by spawn.sh when
# HEADLESS=1. cwd is the target repo (PROJECT); cursor reads it but — without
# --force — cannot modify it.
agmsg_spawn_headless() {
  local run_dir="$SKILL_DIR/run"
  mkdir -p "$run_dir"

  # Establish a persistent Cursor chat up-front so the bridge can --resume it on
  # every turn (server-side conversation memory). create-chat is cwd-independent
  # and needs no trust. Do this before registering anything so a failure (e.g.
  # not logged in) aborts cleanly without leaving a half-spawned worker.
  local chat_id
  chat_id="$("$CURSOR_BIN" create-chat 2>/dev/null | tr -d '\r' | head -1 | awk '{print $1}')"
  case "$chat_id" in
    *-*-*-*-*) ;;   # uuid-ish (5 dash-separated groups)
    *) die "cursor create-chat did not return a chat id (got: '${chat_id:-<empty>}') — is the Cursor CLI logged in? Check 'cursor-agent status'." ;;
  esac

  # The bridge runnable. An explicit AGMSG_CURSOR_BRIDGE_CMD is a complete runnable
  # (tests/stubs); otherwise run the default script through bash so a missing +x
  # bit (fresh checkout) can't stop it.
  local bridge_run
  if [ -n "${AGMSG_CURSOR_BRIDGE_CMD:-}" ]; then
    bridge_run=("$AGMSG_CURSOR_BRIDGE_CMD")
  else
    bridge_run=(bash "$SCRIPT_DIR/drivers/types/cursor/cursor-bridge.sh")
  fi

  # Serialize register→spawn→record-write against a concurrent despawn --force for
  # this (team,name), same critical section as codex/_spawn.sh. Released on every
  # return path via the trap.
  local _lk_held=0
  _agmsg_cursor_spawn_lk_release() {
    [ "$_lk_held" = 1 ] || return 0
    agmsg_placement_lock_release "$TEAM" "$NAME" 2>/dev/null || true
    _lk_held=0
  }
  trap _agmsg_cursor_spawn_lk_release RETURN
  agmsg_placement_lock_acquire "$TEAM" "$NAME" 10 || true
  _lk_held=1

  # Register cursor on the team (pin the path; opt out of #92 rewrite) so the
  # bridge's subscription resolves.
  AGMSG_RESOLVE_PROJECT=0 "$SCRIPT_DIR/join.sh" "$TEAM" "$NAME" cursor "$PROJECT" >/dev/null

  # Refuse a second bridge for the same (team,name) — two bridges on one identity
  # produce duplicate replies. pidfile first, then a pgrep fallback (the bridge can
  # remove its pidfile during its own cleanup while still alive).
  local pidfile="$run_dir/cursor-bridge.$TEAM.$NAME.pid"
  local running=""
  if [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile" 2>/dev/null)" 2>/dev/null; then
    running="$(cat "$pidfile" 2>/dev/null)"
  else
    running="$(pgrep -f "cursor-bridge\.sh .*--team $TEAM --name $NAME" 2>/dev/null | head -1 || true)"
  fi
  if [ -n "$running" ]; then
    echo "spawn: headless cursor '$NAME' already running in '$TEAM' (pid $running)"
    return 0
  fi

  # Persist the chat id for the bridge to --resume (and for despawn cleanup).
  printf '%s\n' "$chat_id" > "$run_dir/cursor-bridge.$TEAM.$NAME.chat"

  local log="$run_dir/cursor-bridge.$TEAM.$NAME.log"
  nohup "${bridge_run[@]}" \
    --project "$PROJECT" --team "$TEAM" --name "$NAME" --chat-id "$chat_id" \
    >> "$log" 2>&1 &
  local bpid=$!
  # Record placement as pid:<n> with type=cursor so despawn --force tears it down
  # by pid through the type-aware kill path (see despawn.sh kill_headless_pid).
  printf '%s\t%s\t%s\n' "pid:$bpid" "$PROJECT" "cursor" \
    > "$(agmsg_spawn_path "$TEAM" "$NAME")" 2>/dev/null || true
  echo "spawned headless cursor reviewer '$NAME' in team '$TEAM' (pid $bpid)"
  echo "  cwd (repo, read-only): $PROJECT"
  echo "  chat: $chat_id"
  echo "  log: $log"
}
