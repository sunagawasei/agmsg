#!/usr/bin/env bash
# codex spawn plug — headless/reviewer worker launch (Template Method).
#
# Sourced by spawn.sh in its global context (so it sees AGENT_TYPE, NAME, TEAM,
# PROJECT, HEADLESS, HEADLESS_SET, REVIEWER, REVIEWER_SET, SCRIPT_DIR, SKILL_DIR
# and the helpers agmsg_placement_lock_*, agmsg_spawn_path, agmsg_type_get, the
# die() function). Defines agmsg_spawn_resolve_modes (called right after arg-parse)
# and agmsg_spawn_headless (called when HEADLESS=1), overriding the no-op / "not
# supported" defaults spawn.sh installs before sourcing — same Template Method
# convention as _session-start.sh.
#
# Codex is the only headless-capable type (type.conf: headless=yes): instead of
# opening a TUI it can run a no-terminal codex-bridge.js worker that talks over
# the agmsg bus. Keeping this codex-specific logic in the plug is what lets
# spawn.sh stay fully data-driven (no per-type branch).

# Resolve the headless/reviewer defaults from config when no explicit flag was
# given. The config keys are codex-specific (spawn.codex_headless /
# spawn.codex_reviewer) — reading them here, not in spawn.sh, keeps the core
# free of any "codex" literal.
#   precedence: --headless / --interactive  >  config spawn.codex_headless  >  TUI
#   precedence: --reviewer / --no-reviewer  >  config spawn.codex_reviewer  >  off
agmsg_spawn_resolve_modes() {
  if [ "$HEADLESS_SET" = 0 ]; then
    case "$("$SCRIPT_DIR/config.sh" get spawn.codex_headless false 2>/dev/null || true)" in
      true|1|yes|on) HEADLESS=1 ;;
    esac
  fi
  if [ "$REVIEWER_SET" = 0 ]; then
    case "$("$SCRIPT_DIR/config.sh" get spawn.codex_reviewer false 2>/dev/null || true)" in
      true|1|yes|on) REVIEWER=1 ;;
    esac
  fi
}

# Refuse to start a headless codex from inside an outer macOS Seatbelt sandbox
# (e.g. Claude Code's bash sandbox, when this script is run by the Bash tool
# without a top-level excludedCommands rule). codex sandboxes every command it runs
# via sandbox-exec; a nested sandbox_apply is denied by a restrictive outer profile
# ("sandbox-exec: sandbox_apply: Operation not permitted"), so the worker could read
# but never run send.sh to reply — the bridge would just spin on "no available
# subscription". `codex sandbox -- <cmd>` exercises the exact same path, so it
# reproduces the failure before we register anything. Only a genuine nesting signal
# in stderr triggers the refusal; any other failure (old codex, CLI error) is left
# to the normal launch so we don't block on unrelated breakage.
preflight_seatbelt_nesting() {
  [ "$(uname -s)" = "Darwin" ] || return 0
  command -v codex >/dev/null 2>&1 || return 0
  local out
  out="$(codex sandbox -- /usr/bin/true 2>&1)" && return 0
  # Match the sandbox_apply failure specifically — NOT a bare "Operation not
  # permitted", which a normal in-sandbox file-write denial also prints.
  case "$out" in
    *sandbox_apply*)
      die "headless codex can't start inside an outer macOS Seatbelt sandbox: codex can't apply its own sandbox to run send.sh, so it could never reply (got: ${out}). Spawn from an unsandboxed session, add a top-level excludedCommands rule for this script (spawn.sh / ensure-codex.sh), or launch via the SessionStart hook/launcher path." ;;
  esac
  return 0
}

# Launch a no-terminal codex bridge worker and return. Called by spawn.sh when
# HEADLESS=1. The worker is a codex-bridge.js process driving its own stdio
# app-server. Two sandbox layouts, selected by REVIEWER:
#
#   default (consultant) — cwd is a neutral scratch dir under run/, NOT the repo.
#     codex's workspace-write sandbox always permits writing the cwd and
#     writable_roots is additive (it cannot revoke cwd write), so using the repo
#     as cwd would let codex write the repo. scratch + writable_roots scoped to
#     agmsg = codex can read anywhere but write only agmsg.
#
#   reviewer — cwd IS the target repo so codex can autonomously explore it, under
#     a permission profile (default_permissions) that grants the repo READ-only
#     and confines writes to agmsg's db/teams/run (replies via send.sh still work).
#     Reads are scoped to the repo + toolchain dirs + agmsg, so the repo cannot be
#     modified and unrelated secrets (e.g. ~/.ssh) stay unreadable. Permission
#     profiles supersede sandbox_mode — the two systems must not be mixed, so this
#     branch sets no sandbox_mode flag. :tmpdir=write and the toolchain read grants
#     are required for git/mktemp and tools installed under /nix or /opt/homebrew.
#
# approval_policy=never in both because a headless worker cannot answer approvals.
agmsg_spawn_headless() {
  local run_dir="$SKILL_DIR/run"
  mkdir -p "$run_dir"   # reviewer mode's cwd is the repo, so nothing else creates run/
  local bridge="${AGMSG_CODEX_BRIDGE_CMD:-$SCRIPT_DIR/drivers/types/codex/codex-bridge.js}"

  # Resolve the working dir + app-server sandbox for the selected mode.
  local cwd appcmd
  if [ "$REVIEWER" = 1 ]; then
    cwd="$PROJECT"
    # Read-only repo + tmp/toolchain reads + writes confined to agmsg. The toolchain
    # roots let codex run git/rg/etc. installed outside the repo; extend this list if
    # a review needs another global read root (e.g. a language's module cache). The
    # -c values that contain spaces are single-quoted: the bridge runs the command
    # via `sh -lc`, which re-parses the string (see codex-bridge.js).
    local fs="{ \":minimal\"=\"read\", \":tmpdir\"=\"write\", \":workspace_roots\"={ \".\"=\"read\" }, \"/nix\"=\"read\", \"/opt/homebrew\"=\"read\", \"/usr/local\"=\"read\", \"$SKILL_DIR/scripts\"=\"read\", \"$SKILL_DIR/db\"=\"write\", \"$SKILL_DIR/teams\"=\"write\", \"$run_dir\"=\"write\" }"
    appcmd="codex app-server --listen stdio:// -c default_permissions=agmsg-reviewer -c 'permissions.agmsg-reviewer.filesystem=$fs' -c 'permissions.agmsg-reviewer.network={ enabled=false }' -c web_search=live -c approval_policy=never"
  else
    cwd="$run_dir/codex-$TEAM-cwd"
    mkdir -p "$cwd"
    local wr="[\"$SKILL_DIR/db\",\"$SKILL_DIR/teams\",\"$run_dir\"]"
    appcmd="codex app-server --listen stdio:// -c sandbox_mode=workspace-write -c sandbox_workspace_write.writable_roots='$wr' -c web_search=live -c approval_policy=never"
  fi

  # Refuse before registering anything if we're nested inside an outer macOS
  # Seatbelt sandbox (see preflight_seatbelt_nesting): the bridge and its codex
  # app-server would inherit it and codex could never run send.sh to reply.
  preflight_seatbelt_nesting

  # Fail closed before registering anything: a reviewer runs approval_policy=never,
  # so if this codex build silently ignores default_permissions (e.g. too old for
  # permission profiles) it would fall back to workspace-write on the repo cwd and
  # could MODIFY the repo. Verify enforcement on the real binary — probe a repo
  # write under the same profile via `codex sandbox`. Capture stderr so we can tell
  # three outcomes apart: write succeeded → sandbox not enforcing (fail-open, refuse);
  # sandbox_apply denied → nested outer sandbox (preflight should have caught it, but
  # guard here too); write denied → enforcing as intended (proceed).
  if [ "$REVIEWER" = 1 ]; then
    local probe="$cwd/.agmsg_reviewer_probe" probe_out
    if probe_out="$(codex sandbox -P agmsg-reviewer -C "$cwd" \
         -c "permissions.agmsg-reviewer.filesystem=$fs" \
         -c 'permissions.agmsg-reviewer.network={ enabled=false }' \
         -- /bin/sh -c "touch -- \"$probe\"" 2>&1)"; then
      rm -f "$probe" 2>/dev/null || true
      die "reviewer sandbox is not enforced by this codex build (the repo would be writable); refusing to launch. Upgrade codex, or spawn with --no-reviewer for the scratch consultant."
    fi
    # Only sandbox_apply means a nested outer sandbox. A normal write denial here
    # is the enforcing-as-intended case and prints "touch: ...: Operation not
    # permitted" (no sandbox_apply) — must NOT be treated as nesting.
    case "$probe_out" in
      *sandbox_apply*)
        die "headless codex can't apply its sandbox — this spawn is running inside an outer macOS Seatbelt sandbox (e.g. Claude Code's bash sandbox). Spawn from an unsandboxed session, add a top-level excludedCommands rule for this script (spawn.sh / ensure-codex.sh), or use the hook/launcher path." ;;
    esac
  fi

  # Serialize the register→spawn→record-write critical section against a
  # concurrent teardown (despawn.sh --force) for this same (team,name), so a
  # detached SessionEnd teardown can't rm the record we are about to write (and
  # drop our fresh registration). Held only across the fast bookkeeping below,
  # NOT the slow sandbox probes above. Fail-open on acquire timeout — despawn's
  # --expect-record compare is the backstop. Released on every return path.
  agmsg_placement_lock_acquire "$TEAM" "$NAME" 10 || true

  # Register codex on the team (pin the path; opt out of #92 rewrite) so the
  # bridge has a subscription — otherwise it loops on "no available subscription".
  AGMSG_RESOLVE_PROJECT=0 "$SCRIPT_DIR/join.sh" "$TEAM" "$NAME" codex "$cwd" >/dev/null
  # Refuse to start a second bridge for the same (team,name) — two bridges on one
  # identity produce duplicate replies. The bridge writes its own pidfile, but it
  # can remove that file during its own cleanup while still running, so fall back
  # to scanning for a live codex-bridge.js bound to this team+name.
  local pidfile="$run_dir/codex-bridge.$TEAM.$NAME.pid"
  local running=""
  if [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile" 2>/dev/null)" 2>/dev/null; then
    running="$(cat "$pidfile" 2>/dev/null)"
  else
    running="$(pgrep -f "codex-bridge\.js .*--team $TEAM --name $NAME --inline-inbox" 2>/dev/null | head -1 || true)"
  fi
  if [ -n "$running" ]; then
    agmsg_placement_lock_release "$TEAM" "$NAME"
    echo "spawn: headless codex '$NAME' already running in '$TEAM' (pid $running)"
    return 0
  fi
  local log="$run_dir/codex-bridge.$TEAM.$NAME.log"
  AGMSG_CODEX_APP_SERVER_CMD="$appcmd" nohup "$bridge" \
    --project "$cwd" --type codex --team "$TEAM" --name "$NAME" --inline-inbox \
    >> "$log" 2>&1 &
  local bpid=$!
  # Record placement as pid:<n> so despawn tears it down by pid (not a tmux id).
  # The project field is the cwd we registered above so despawn --force's reset.sh
  # drops exactly that registration.
  printf '%s\t%s\t%s\n' "pid:$bpid" "$cwd" "codex" \
    > "$(agmsg_spawn_path "$TEAM" "$NAME")" 2>/dev/null || true
  agmsg_placement_lock_release "$TEAM" "$NAME"
  local kind="headless codex"; [ "$REVIEWER" = 1 ] && kind="headless reviewer codex"
  echo "spawned $kind '$NAME' in team '$TEAM' (pid $bpid)"
  [ "$REVIEWER" = 1 ] && echo "  cwd (repo, read-only): $cwd"
  echo "  log: $log"
}
