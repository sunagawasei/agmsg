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
# Security model (D2): read-only is enforced by a project-level .cursor/cli.json
# the bridge writes in its OWN scratch cwd, denying Write(**)/Shell(**) plus a
# secret-path Read() denylist. cursor merges that over the user's global config and
# deny takes precedence even under --trust — VERIFIED on a live host. Never passing
# --force is necessary but NOT sufficient on its own: with a global
# approvalMode:"unrestricted", a headless `--trust` cursor otherwise writes, runs
# shell, and reads anything (e.g. ~/.ssh). True allowlist read-scoping (codex
# parity) is NOT achievable here — headless cursor requires --trust and --trust
# permits all reads except explicit Read() denies, so reads stay broad minus the
# denylist. Enforcement is gated by spawn.cursor_readonly (default on). The bats
# suite pins the generated cli.json (deny Write/Shell present) and the bridge flag
# set (--trust present, --force/--yolo absent) as the regression guards. A live
# "try to write, refuse if it succeeds" probe is deliberately avoided: a ~10s,
# model-dependent, flaky agent turn per spawn that would not actually prove the
# boundary (the model may simply decline to attempt the write).

CURSOR_BIN="${AGMSG_CURSOR_AGENT_CMD:-cursor-agent}"

# Shared /add-dir harvest (agmsg_collect_add_dir_roots), used when the optional
# spawn.cursor_inherit_add_dirs gate is on. Sourced in spawn.sh's global context
# where config.sh + lib/storage.sh helpers are already available.
# shellcheck source=../../lib/reviewer-add-dirs.sh
. "$SCRIPT_DIR/lib/reviewer-add-dirs.sh"
# agmsg_validate_team_name — the same UTF-8-safe path-segment deny-list join.sh
# uses (rejects '/','\\','.'/'..', leading '-', control chars). Applied to the
# agent NAME too, BEFORE any run/ artifact is created from it (the bridge's
# scratch CFGDIR is rm -rf'd, so a path-unsafe name must never reach it).
# shellcheck source=../../lib/validate.sh
. "$SCRIPT_DIR/lib/validate.sh"

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

  # Fail closed BEFORE any run/ artifact (.chat/.adddirs/log) or the rm -rf'd
  # scratch CFGDIR is composed from TEAM/NAME. UTF-8-safe (deny-list, not ASCII).
  agmsg_validate_team_name "$TEAM" >/dev/null 2>&1 || die "spawn: team name '$TEAM' is not a path-safe segment"
  agmsg_validate_team_name "$NAME" >/dev/null 2>&1 || die "spawn: agent name '$NAME' is not a path-safe segment (no '/', '\\', '.', '..', leading '-', or control chars)"

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

  # Read-only enforcement (default ON; opt out with spawn.cursor_readonly=false).
  # Passed to the bridge, which materializes the deny rules in its scratch cwd.
  local readonly_on=1
  case "$("$SCRIPT_DIR/config.sh" get spawn.cursor_readonly true 2>/dev/null || true)" in
    false|0|no|off) readonly_on=0 ;;
  esac

  # Inherit the Claude session's /add-dir READ roots (opt-in, default off — same
  # gate semantics as codex's spawn.codex_inherit_add_dirs). cursor can already
  # read them, so this only advertises them to the reviewer via the bridge prompt.
  local adddirs_file="$run_dir/cursor-bridge.$TEAM.$NAME.adddirs"
  rm -f "$adddirs_file" 2>/dev/null || true
  local add_dir_list=""
  add_dir_list="$(agmsg_collect_add_dir_roots "$PROJECT" "spawn.cursor_inherit_add_dirs")"

  local -a extra_args=()
  [ "$readonly_on" = 1 ] && extra_args+=(--readonly)
  if [ -n "$add_dir_list" ]; then
    printf '%s\n' "$add_dir_list" > "$adddirs_file"
    extra_args+=(--add-dirs-file "$adddirs_file")
  fi

  local log="$run_dir/cursor-bridge.$TEAM.$NAME.log"
  nohup "${bridge_run[@]}" \
    --project "$PROJECT" --team "$TEAM" --name "$NAME" --chat-id "$chat_id" \
    ${extra_args[@]+"${extra_args[@]}"} \
    >> "$log" 2>&1 &
  local bpid=$!
  # Record placement as pid:<n> with type=cursor so despawn --force tears it down
  # by pid through the type-aware kill path (see despawn.sh kill_headless_pid).
  printf '%s\t%s\t%s\n' "pid:$bpid" "$PROJECT" "cursor" \
    > "$(agmsg_spawn_path "$TEAM" "$NAME")" 2>/dev/null || true
  echo "spawned headless cursor reviewer '$NAME' in team '$TEAM' (pid $bpid)"
  if [ "$readonly_on" = 1 ]; then
    echo "  read-only: ENFORCED (deny Write/Shell + credential-path Read denylist via scratch .cursor/cli.json; paths inside the workspace are exempt — see bridge log)"
  else
    echo "  read-only: DISABLED (spawn.cursor_readonly=false) — cursor can write & run shell"
  fi
  echo "  workspace (read): $PROJECT"
  [ -n "$add_dir_list" ] && echo "  add-dir reads: $(printf '%s' "$add_dir_list" | tr '\n' ' ')"
  echo "  chat: $chat_id"
  echo "  log: $log"
}
