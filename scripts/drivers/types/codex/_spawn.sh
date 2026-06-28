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
#     Reads are scoped to the repo + toolchain dirs + agmsg (+ the Claude
#     session's /add-dir directories when spawn.codex_inherit_add_dirs is on),
#     so the repo cannot be modified and unrelated secrets (e.g. ~/.ssh) stay
#     unreadable. Permission
#     profiles supersede sandbox_mode — the two systems must not be mixed, so this
#     branch sets no sandbox_mode flag. :tmpdir=write and the toolchain read grants
#     are required for git/mktemp and tools installed under /nix or /opt/homebrew.
#
# Collect extra READ roots for the reviewer filesystem profile from the Claude
# session's /add-dir list (permissions.additionalDirectories in the spawned
# project's .claude/settings.json + settings.local.json). This lets a headless
# reviewer codex read the same out-of-repo directories the asking Claude session
# was granted via /add-dir, while every other path (e.g. ~/.ssh) stays
# unreadable.
#
# Gated by config spawn.codex_inherit_add_dirs (default off — it widens the
# reviewer read scope, so it is opt-in). Echoes codex filesystem-table entries,
# each prefixed ', "<dir>"="read"', ready to splice into the profile body; empty
# when the gate is off or nothing qualifies. Skips non-existent / non-directory /
# unsafe paths (an embedded ' " or \ would break the shell or TOML quoting the
# value is spliced into — see the filter below) and the project root itself
# (already :workspace_roots), and dedups by resolved path. A malformed settings
# file yields no roots (the sqlite error is swallowed) — fail-safe, never fatal.
# shellcheck source=../../lib/reviewer-add-dirs.sh
. "$SCRIPT_DIR/lib/reviewer-add-dirs.sh"
# agmsg_validate_team_name — the path-segment guard join.sh and cursor/_spawn.sh
# use; applied below before any run/ artifact is composed from TEAM/NAME.
# shellcheck source=../../lib/validate.sh
. "$SCRIPT_DIR/lib/validate.sh"
agmsg_reviewer_add_dir_roots() {
  # Wrap the shared harvest: format each collected dir as a codex filesystem-table
  # read entry (`, "<dir>"="read"`) to splice into the reviewer profile body. The
  # harvest's quote/backslash filter keeps the value safe for that splice.
  local d out=""
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    out="$out, \"$d\"=\"read\""
  done < <(agmsg_collect_add_dir_roots "$1" "spawn.codex_inherit_add_dirs")
  printf '%s' "$out"
}

# approval_policy=never in both because a headless worker cannot answer approvals.
agmsg_spawn_headless() {
  local run_dir="$SKILL_DIR/run"
  mkdir -p "$run_dir"   # reviewer mode's cwd is the repo, so nothing else creates run/
  # Fail closed on a path-unsafe team/name BEFORE any run/ artifact (role snapshot,
  # pidfile, log) or registration is composed from them — the same guard cursor
  # applies, and required now that role staging runs before join.sh validates.
  agmsg_validate_team_name "$TEAM" >/dev/null 2>&1 || die "spawn: team name '$TEAM' is not a path-safe segment"
  agmsg_validate_agent_name "$NAME" >/dev/null 2>&1 || die "spawn: agent name '$NAME' is not valid (same rule join.sh applies: no '.', '..', '/', '\\', '\"', '[', ']', leading '-', or control chars)"
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
    local fs_base="\":minimal\"=\"read\", \":tmpdir\"=\"write\", \":workspace_roots\"={ \".\"=\"read\" }, \"/nix\"=\"read\", \"/opt/homebrew\"=\"read\", \"/usr/local\"=\"read\", \"$SKILL_DIR/scripts\"=\"read\", \"$SKILL_DIR/db\"=\"write\", \"$SKILL_DIR/teams\"=\"write\", \"$run_dir\"=\"write\""
    # Additively grant READ on the Claude session's /add-dir directories (gated;
    # see agmsg_reviewer_add_dir_roots). Purely additive and fail-open: pre-flight
    # the augmented profile with a trivial sandboxed command, and if it fails to
    # apply (e.g. a pathological add-dir entry) drop the extra roots and fall back
    # to the base profile, so add-dir inheritance can never brick the spawn. The
    # base reviewer guarantee (repo read-only, secrets unreadable) is still proved
    # fail-closed by the negative/positive probes below.
    local add_dir_roots; add_dir_roots="$(agmsg_reviewer_add_dir_roots "$cwd")"
    if [ -n "$add_dir_roots" ] && ! codex sandbox -P agmsg-reviewer -C "$cwd" \
         -c "permissions.agmsg-reviewer.filesystem={ $fs_base$add_dir_roots }" \
         -c 'permissions.agmsg-reviewer.network={ enabled=false }' \
         -- /usr/bin/true >/dev/null 2>&1; then
      echo "spawn: reviewer add-dir inheritance disabled (augmented sandbox profile failed to apply); using base profile" >&2
      add_dir_roots=""
    fi
    local fs="{ $fs_base$add_dir_roots }"
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
  # could MODIFY the repo. Verify enforcement on the real binary — two probes via
  # `codex sandbox`:
  #
  #   Negative probe (repo write): must be DENIED. Four outcomes:
  #     write succeeded  → sandbox not enforcing (fail-open) → refuse
  #     "sandbox_apply"  → nested outer sandbox              → refuse
  #     "Operation not permitted" / "Permission denied"       → enforcing → proceed
  #     anything else    → unknown error (old codex, parse)  → refuse (fail-closed)
  #
  #   Positive probe (run_dir write): must SUCCEED — proves the worker can reply via
  #     send.sh; catches mis-configured writable_roots before we register anything.
  #
  # Use a PID-qualified probe name so concurrent spawns don't collide (fix #2) and
  # no pre-existing repo file of the same name is accidentally removed.
  if [ "$REVIEWER" = 1 ]; then
    local probe="$cwd/.agmsg_reviewer_probe.$$" probe_out
    if probe_out="$(codex sandbox -P agmsg-reviewer -C "$cwd" \
         -c "permissions.agmsg-reviewer.filesystem=$fs" \
         -c 'permissions.agmsg-reviewer.network={ enabled=false }' \
         -- /bin/sh -c "touch -- \"$probe\"" 2>&1)"; then
      rm -f "$probe" 2>/dev/null || true
      die "reviewer sandbox is not enforced by this codex build (the repo would be writable); refusing to launch. Upgrade codex, or spawn with --no-reviewer for the scratch consultant."
    fi
    # Classify non-zero exit — only "Operation not permitted"/"Permission denied"
    # on the probe file itself means enforcing-as-intended. Any other failure is
    # unknown (unsupported -P flag, profile parse error, codex too old) → refuse
    # fail-closed so we never accidentally grant the worker repo write access.
    case "$probe_out" in
      *sandbox_apply*)
        die "headless codex can't apply its sandbox — this spawn is running inside an outer macOS Seatbelt sandbox (e.g. Claude Code's bash sandbox). Spawn from an unsandboxed session, add a top-level excludedCommands rule for this script (spawn.sh / ensure-codex.sh), or use the hook/launcher path." ;;
      *"Operation not permitted"* | *"Permission denied"*)
        ;;  # enforcing — proceed
      *)
        die "reviewer sandbox probe failed with an unexpected error; refusing to launch fail-closed (got: ${probe_out:-<empty>}). Verify 'codex sandbox -P' is supported by this build, or spawn with --no-reviewer for the scratch consultant." ;;
    esac
    # Positive probe: verify the worker can actually write to run_dir (replies via
    # send.sh need db/teams/run writes). If this fails the profile is misconfigured.
    local pos_probe="$run_dir/.agmsg_reviewer_probe.$$"
    if ! codex sandbox -P agmsg-reviewer -C "$cwd" \
         -c "permissions.agmsg-reviewer.filesystem=$fs" \
         -c 'permissions.agmsg-reviewer.network={ enabled=false }' \
         -- /bin/sh -c "touch -- \"$pos_probe\" && rm -f -- \"$pos_probe\"" \
         >/dev/null 2>&1; then
      die "reviewer sandbox can't write to run_dir ($run_dir); the worker would be unable to reply via send.sh. Check the filesystem profile's write grants for \$SKILL_DIR/run."
    fi
  fi

  # Serialize the register→spawn→record-write critical section against a
  # concurrent teardown (despawn.sh --force) for this same (team,name), so a
  # detached SessionEnd teardown can't rm the record we are about to write (and
  # drop our fresh registration). Held only across the fast bookkeeping below,
  # NOT the slow sandbox probes above. Fail-open on acquire timeout — despawn's
  # --expect-record compare is the backstop.
  #
  # The trap releases on every return path, including unexpected set -e exits,
  # so the lock is never left held if join.sh or later steps fail.
  local _lk_held=0
  _agmsg_spawn_lk_release() {
    [ "$_lk_held" = 1 ] || return 0
    agmsg_placement_lock_release "$TEAM" "$NAME" 2>/dev/null || true
    _lk_held=0
  }
  trap _agmsg_spawn_lk_release RETURN
  agmsg_placement_lock_acquire "$TEAM" "$NAME" 10 || true
  _lk_held=1

  # Refuse to start a second bridge for the same (team,name) BEFORE registering or
  # staging anything — two bridges on one identity produce duplicate replies, and
  # an early return here must have NO side effects (no role overwrite, no fresh
  # registration). The bridge writes its own pidfile, but it can remove that file
  # during its own cleanup while still running, so fall back to scanning for a live
  # codex-bridge.js bound to this team+name.
  # Opaque per-identity marker handed to the bridge below; the dup-check fallback
  # matches on THIS, so team/name content (spaces, regex metachars, flag-like
  # substrings) can never create argv-boundary or regex ambiguity. base64url(team\tname).
  local _idkey
  _idkey="$(printf '%s\t%s' "$TEAM" "$NAME" | base64 | tr -d '\n' | tr '+/' '-_')"

  local pidfile="$run_dir/codex-bridge.$TEAM.$NAME.pid"
  local running=""
  if [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile" 2>/dev/null)" 2>/dev/null; then
    running="$(cat "$pidfile" 2>/dev/null)"
  else
    # Fallback: list codex-bridge candidates, then confirm identity by the opaque
    # --identity-key via grep -F (-- guards the leading dashes). ps -ww avoids argv
    # truncation. No regex escaping / argv-boundary trick needed.
    local _p
    for _p in $(pgrep -f "codex-bridge\.js" 2>/dev/null || true); do
      if ps -ww -o args= -p "$_p" 2>/dev/null | grep -qF -- "--identity-key $_idkey"; then
        running="$_p"; break
      fi
    done
  fi
  if [ -n "$running" ]; then
    echo "spawn: headless codex '$NAME' already running in '$TEAM' (pid $running)"
    return 0
  fi

  # Snapshot the role file: AFTER the dup check (so an already-running worker is
  # never silently re-roled) and BEFORE registration (so a cp failure releases the
  # lock and dies with nothing registered to unwind). ROLE_FILE is a readable
  # regular file (resolver-guaranteed); `--` guards a '-' path. The snapshot pins
  # the role so a later edit/delete of the source can't change this live worker.
  local rolefile=""
  if [ -n "${ROLE_FILE:-}" ]; then
    rolefile="$run_dir/codex-bridge.$TEAM.$NAME.role"
    rm -f "$rolefile" 2>/dev/null || true
    cp -- "$ROLE_FILE" "$rolefile" 2>/dev/null \
      || { _agmsg_spawn_lk_release; die "failed to stage role file ($ROLE_FILE) for codex '$NAME'; refusing to start role-less"; }
  fi

  # Register codex on the team (pin the path; opt out of #92 rewrite) so the
  # bridge has a subscription — otherwise it loops on "no available subscription".
  # On failure, unwind the just-staged role snapshot and release the lock before
  # dying (the RETURN trap does not run on a die/exit), so a rejected registration
  # leaves no lock or run/ role behind.
  AGMSG_RESOLVE_PROJECT=0 "$SCRIPT_DIR/join.sh" "$TEAM" "$NAME" codex "$cwd" >/dev/null \
    || { [ -n "$rolefile" ] && rm -f "$rolefile" 2>/dev/null; _agmsg_spawn_lk_release; die "join failed for codex '$NAME' in team '$TEAM'"; }
  # Hand the bridge the run/ snapshot staged before registration. The app-server
  # command is left UNTOUCHED, so role injection can never break the sandbox/-c
  # quoting or the worker's subscription (a broken appcmd loops on "no available
  # subscription").
  local -a role_args=()
  [ -n "$rolefile" ] && role_args+=(--role-file "$rolefile")
  local log="$run_dir/codex-bridge.$TEAM.$NAME.log"
  AGMSG_CODEX_APP_SERVER_CMD="$appcmd" nohup "$bridge" \
    --project "$cwd" --type codex --team "$TEAM" --name "$NAME" --inline-inbox \
    --identity-key "$_idkey" \
    ${role_args[@]+"${role_args[@]}"} \
    >> "$log" 2>&1 &
  local bpid=$!
  # Record placement as pid:<n> so despawn tears it down by pid (not a tmux id).
  # The project field is the cwd we registered above so despawn --force's reset.sh
  # drops exactly that registration.
  printf '%s\t%s\t%s\n' "pid:$bpid" "$cwd" "codex" \
    > "$(agmsg_spawn_path "$TEAM" "$NAME")" 2>/dev/null || true
  local kind="headless codex"; [ "$REVIEWER" = 1 ] && kind="headless reviewer codex"
  echo "spawned $kind '$NAME' in team '$TEAM' (pid $bpid)"
  [ "$REVIEWER" = 1 ] && echo "  cwd (repo, read-only): $cwd"
  [ "$REVIEWER" = 1 ] && [ -n "$add_dir_roots" ] && \
    echo "  add-dir reads (read-only):$(printf '%s' "$add_dir_roots" | sed 's/="read"//g; s/[",]/ /g')"
  [ -n "$rolefile" ] && echo "  role: $ROLE_FILE"
  echo "  log: $log"
}
