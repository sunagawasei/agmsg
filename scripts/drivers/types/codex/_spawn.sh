#!/usr/bin/env bash
# codex spawn plug — headless/reviewer worker launch (Template Method).
#
# Sourced by spawn.sh in its global context (so it sees AGENT_TYPE, NAME, TEAM,
# PROJECT, HEADLESS, HEADLESS_SET, REVIEWER, REVIEWER_SET, IMPLEMENTER,
# IMPLEMENTER_SET, SCRIPT_DIR, SKILL_DIR and the helpers agmsg_placement_lock_*,
# agmsg_spawn_path, agmsg_type_get, the die() function). Defines
# agmsg_spawn_resolve_modes (called right after arg-parse) and
# agmsg_spawn_headless (called when HEADLESS=1), overriding the no-op / "not
# supported" defaults spawn.sh installs before sourcing — same Template Method
# convention as _session-start.sh.
#
# Codex is the only headless-capable type (type.conf: headless=yes): instead of
# opening a TUI it can run a no-terminal codex-bridge.js worker that talks over
# the agmsg bus. Keeping this codex-specific logic in the plug is what lets
# spawn.sh stay fully data-driven (no per-type branch).

# Launch a no-terminal codex bridge worker and return. Called by spawn.sh when
# HEADLESS=1. The worker is a codex-bridge.js process driving its own stdio
# app-server. Three sandbox layouts, selected by IMPLEMENTER/REVIEWER:
#
#   default (consultant) — cwd is a neutral scratch dir under run/, NOT the repo,
#     under a permission profile that grants WRITE to that scratch cwd and agmsg's
#     db/teams/run state while explicitly disabling network access.
#
#   implementer — cwd IS the target repo, under a permission profile that grants
#     the repo WRITE access for implementation work delegated to codex. The
#     profile also grants agmsg's db/teams/run writes so replies via send.sh keep
#     working, while network access is disabled.
#
#   reviewer — cwd IS the target repo so codex can autonomously explore it, under
#     a permission profile (default_permissions) that grants the repo READ-only
#     and confines writes to agmsg's db/teams/run (replies via send.sh still work).
#     Command network is on, but only for the gh HTTPS hosts below. web_search
#     is a separate tool and is not covered by that allowlist. A credential that
#     can write to those hosts can still send data there.
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
# shellcheck source=../../lib/identity-key.sh
. "$SCRIPT_DIR/lib/identity-key.sh"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/process-identity.sh"

# shellcheck source=_spawn-modes.sh
. "$SCRIPT_DIR/drivers/types/codex/_spawn-modes.sh"
# shellcheck source=_spawn-fs-roots.sh
. "$SCRIPT_DIR/drivers/types/codex/_spawn-fs-roots.sh"
# shellcheck source=_spawn-args.sh
. "$SCRIPT_DIR/drivers/types/codex/_spawn-args.sh"
# shellcheck source=_spawn-reviewer.sh
. "$SCRIPT_DIR/drivers/types/codex/_spawn-reviewer.sh"


# Pid of a live codex-bridge for this team and name, or empty. Used before the
# placement lock so a reviewer home is not rebuilt for a worker that is already
# up, and so a failing home probe never holds that lock.
agmsg_codex_bridge_running_pid() {
  local pidfile="$1" bridge_scope="$2" idkey="$3" recorded_pid="" _p
  if [ -f "$pidfile" ] \
      && agmsg_process_dedup_should_suppress codex-bridge "$pidfile" "$bridge_scope" \
        codex-bridge "$idkey"; then
    recorded_pid="$(cat "$pidfile" 2>/dev/null || true)"
    if [ -n "$recorded_pid" ]; then
      printf '%s\n' "$recorded_pid"
      return 0
    fi
  fi
  for _p in $(pgrep -f "codex-bridge\.js" 2>/dev/null || true); do
    if ps -ww -o args= -p "$_p" 2>/dev/null | grep -qF -- "--identity-key $idkey"; then
      printf '%s\n' "$_p"
      return 0
    fi
  done
  return 1
}


# approval_policy=never in every mode because a headless worker cannot answer approvals.
agmsg_spawn_headless() {
  local run_dir="$SKILL_DIR/run"
  agmsg_pending_spawn_owner_capture
  local storage_dir; storage_dir="$(agmsg_storage_dir)"
  mkdir -p "$run_dir"   # reviewer mode's cwd is the repo, so nothing else creates run/

  # Fail closed BEFORE building any layout's appcmd/profile: SKILL_DIR and
  # run_dir are hand-spliced into the consultant / implementer / reviewer
  # filesystem-table profile bodies without shell-quoting the value
  # itself — a "'" breaks out of the single-quoted -c clause, a '"' breaks the
  # TOML string, and a "\" is a TOML escape character. Any of the three could
  # corrupt the spliced config or inject unintended -c/profile syntax. This is
  # a property of the agmsg install path (an admin-controlled, effectively
  # fixed value), not of any per-spawn input, so refusing here is a one-time
  # environment check, not a per-worker cost.
  case "$SKILL_DIR$run_dir$storage_dir" in
    *\'*|*\"*|*\\*)
      die "spawn: agmsg install path contains a quote/backslash and cannot be spliced into the codex sandbox config safely: $SKILL_DIR" ;;
  esac

  # Fail closed on a path-unsafe team/name BEFORE any run/ artifact (role snapshot,
  # pidfile, log) or registration is composed from them — the same guard cursor
  # applies, and required now that role staging runs before join.sh validates.
  agmsg_validate_team_name "$TEAM" >/dev/null 2>&1 || die "spawn: team name '$TEAM' is not a path-safe segment"
  agmsg_validate_agent_name "$NAME" >/dev/null 2>&1 || die "spawn: agent name '$NAME' is not valid (same rule join.sh applies: no '.', '..', '/', '\\', '\"', '[', ']', leading '-', or control chars)"
  local bridge="${AGMSG_CODEX_BRIDGE_CMD:-$SCRIPT_DIR/drivers/types/codex/codex-bridge.js}"
  local model_effort_args; model_effort_args="$(agmsg_codex_model_effort_args "$NAME")" || die "spawn: could not resolve the codex model for '$NAME'"
  local codex_client_name; codex_client_name="$(agmsg_codex_client_name "$NAME")"
  local codex_turn_timeout; codex_turn_timeout="$(agmsg_codex_turn_timeout "$NAME")"
  [ -z "$codex_turn_timeout" ] && codex_turn_timeout="${AGMSG_CODEX_BRIDGE_TURN_TIMEOUT:-}"
  local extra_fs; extra_fs="$(agmsg_codex_extra_fs_roots "$NAME")"
  local -a runtime_root_args=(
    --workspace-root "$storage_dir"
    --workspace-root "$SKILL_DIR/teams"
    --workspace-root "$run_dir"
  )
  local extra_write_roots extra_write_root
  extra_write_roots="$(agmsg_codex_extra_fs_roots "$NAME" runtime-write-roots)"
  while IFS= read -r extra_write_root; do
    [ -n "$extra_write_root" ] || continue
    runtime_root_args+=(--workspace-root "$extra_write_root")
  done <<< "$extra_write_roots"

  # Resolve the working dir + app-server sandbox for the selected mode.
  local cwd appcmd
  if [ "$IMPLEMENTER" = 1 ]; then
    cwd="$PROJECT"
    # Implementer: the repo IS writable, along with agmsg's state directories so
    # send.sh replies keep working. Toolchain and agmsg scripts remain read-only,
    # and the permission profile explicitly disables network access.
    local fs="{ \":minimal\"=\"read\", \":tmpdir\"=\"write\", \":workspace_roots\"={ \".\"=\"write\" }, \"/nix\"=\"read\", \"/opt/homebrew\"=\"read\", \"/usr/local\"=\"read\", \"$SKILL_DIR/scripts\"=\"read\", \"$storage_dir\"=\"write\", \"$SKILL_DIR/teams\"=\"write\", \"$run_dir\"=\"write\"$extra_fs }"
    appcmd="codex app-server --listen stdio:// -c default_permissions=agmsg-implementer -c 'permissions.agmsg-implementer.filesystem=$fs' -c 'permissions.agmsg-implementer.network={ enabled=false }' -c web_search=live -c approval_policy=never$model_effort_args"
  elif [ "$REVIEWER" = 1 ]; then
    cwd="$PROJECT"
    local net_c; net_c="$(agmsg_codex_reviewer_network_config)"
    # Resolve once to an absolute executable. `command -v` returns the bare
    # name when codex is a shell function, and a relative PATH entry stays
    # relative; `sh -lc` would then search PATH again. `type -P` skips
    # functions. Anything that is not an absolute executable is refused.
    local codex_bin; codex_bin="$(type -P codex 2>/dev/null || true)"
    case "$codex_bin" in
      /*) ;;
      *) die "spawn: codex must resolve to an absolute executable (got: ${codex_bin:-<empty>}); refusing to launch a reviewer" ;;
    esac
    [ -x "$codex_bin" ] || die "spawn: codex path is not executable: $codex_bin"
    case "$codex_bin" in
      *[!A-Za-z0-9._/+-]*)
        die "spawn: codex path cannot be spliced into the app-server command safely: $codex_bin" ;;
    esac
    # Research workers use this same reviewer path. Implementer and consultant
    # keep the user's CODEX_HOME, including its execpolicy rules.
    agmsg_codex_reviewer_execpolicy_home_path
    local execpolicy_home="$AGMSG_REVIEWER_EXEC_HOME"
    # Read-only repo + tmp/toolchain reads + writes confined to agmsg. The toolchain
    # roots let codex run git/rg/etc. installed outside the repo; extend this list if
    # a review needs another global read root (e.g. a language's module cache). The
    # -c values that contain spaces are single-quoted: the bridge runs the command
    # via `sh -lc`, which re-parses the string (see codex-bridge.js).
    local fs_base="\":minimal\"=\"read\", \":tmpdir\"=\"write\", \":workspace_roots\"={ \".\"=\"read\" }, \"/nix\"=\"read\", \"/opt/homebrew\"=\"read\", \"/usr/local\"=\"read\", \"$SKILL_DIR/scripts\"=\"read\", \"$storage_dir\"=\"write\", \"$SKILL_DIR/teams\"=\"write\", \"$run_dir\"=\"write\""
    fs_base="$fs_base$(agmsg_codex_extra_fs_roots "$NAME" profile reviewer "$cwd")"
    # Hide every per-launch CODEX_HOME from the reviewer sandbox, not only this
    # spawn's directory. Unlisted paths are writable; without this, one worker
    # could read or rewrite another launch's auth link or rules.
    fs_base="$fs_base, \"$SKILL_DIR/reviewer-codex-home\"=\"none\""
    # Additively grant READ on the Claude session's /add-dir directories (gated;
    # see agmsg_reviewer_add_dir_roots). Purely additive and fail-open: pre-flight
    # the augmented profile with a trivial sandboxed command, and if it fails to
    # apply (e.g. a pathological add-dir entry) drop the extra roots and fall back
    # to the base profile, so add-dir inheritance can never brick the spawn. The
    # base reviewer guarantee (repo read-only, secrets unreadable) is still proved
    # fail-closed by the negative/positive probes below.
    local add_dir_roots; add_dir_roots="$(agmsg_reviewer_add_dir_roots "$cwd")"
    if [ -n "$add_dir_roots" ] && ! "$codex_bin" sandbox --enable network_proxy -P agmsg-reviewer -C "$cwd" \
         -c "permissions.agmsg-reviewer.filesystem={ $fs_base$add_dir_roots }" \
         -c "$net_c" \
         -- /usr/bin/true >/dev/null 2>&1; then
      echo "spawn: reviewer add-dir inheritance disabled (augmented sandbox profile failed to apply); using base profile" >&2
      add_dir_roots=""
    fi
    # The optional gh config directory is reviewer-only. Probe it together with
    # the already-vetted add-dir roots so the profile used by app-server is the
    # exact augmented profile proved to apply. If this final augmentation fails,
    # drop only the gh grant/environment injection and retain the existing
    # reviewer/add-dir layout.
    local gh_config_dir; gh_config_dir="$(agmsg_codex_gh_config_dir "$NAME")"
    local gh_config_root="" gh_config_arg=""
    if [ -n "$gh_config_dir" ]; then
      gh_config_root=", \"$gh_config_dir\"=\"read\""
      if ! "$codex_bin" sandbox --enable network_proxy -P agmsg-reviewer -C "$cwd" \
           -c "permissions.agmsg-reviewer.filesystem={ $fs_base$add_dir_roots$gh_config_root }" \
           -c "$net_c" \
           -- /usr/bin/true >/dev/null 2>&1; then
        echo "spawn: reviewer codex GH config injection disabled (augmented sandbox profile failed to apply); using the existing reviewer profile" >&2
        gh_config_dir=""
        gh_config_root=""
      else
        gh_config_arg=" -c 'shell_environment_policy.set.GH_CONFIG_DIR=\"$gh_config_dir\"'"
      fi
    fi
    local fs="{ $fs_base$add_dir_roots$gh_config_root }"
    appcmd="CODEX_HOME='$execpolicy_home' ${codex_bin} app-server --listen stdio:// --enable network_proxy -c default_permissions=agmsg-reviewer -c 'permissions.agmsg-reviewer.filesystem=$fs' -c '${net_c}' -c web_search=live -c approval_policy=never$model_effort_args$gh_config_arg"
  else
    cwd="$run_dir/codex-$TEAM-cwd"
    mkdir -p "$cwd"
    local fs="{ \":minimal\"=\"read\", \":tmpdir\"=\"write\", \":workspace_roots\"={ \".\"=\"write\" }, \"/nix\"=\"read\", \"/opt/homebrew\"=\"read\", \"/usr/local\"=\"read\", \"$SKILL_DIR/scripts\"=\"read\", \"$storage_dir\"=\"write\", \"$SKILL_DIR/teams\"=\"write\", \"$run_dir\"=\"write\"$extra_fs }"
    appcmd="codex app-server --listen stdio:// -c default_permissions=agmsg-consultant -c 'permissions.agmsg-consultant.filesystem=$fs' -c 'permissions.agmsg-consultant.network={ enabled=false }' -c web_search=live -c approval_policy=never$model_effort_args"
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
    if probe_out="$("$codex_bin" sandbox --enable network_proxy -P agmsg-reviewer -C "$cwd" \
         -c "permissions.agmsg-reviewer.filesystem=$fs" \
         -c "$net_c" \
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
    if ! "$codex_bin" sandbox --enable network_proxy -P agmsg-reviewer -C "$cwd" \
         -c "permissions.agmsg-reviewer.filesystem=$fs" \
         -c "$net_c" \
         -- /bin/sh -c "touch -- \"$pos_probe\" && rm -f -- \"$pos_probe\"" \
         >/dev/null 2>&1; then
      die "reviewer sandbox can't write to run_dir ($run_dir); the worker would be unable to reply via send.sh. Check the filesystem profile's write grants for \$SKILL_DIR/run."
    fi
    agmsg_codex_reviewer_assert_network "$codex_bin" "$cwd" "$fs" "$net_c"
    # Home rebuild and its sandbox probes stay outside the placement lock.
    # die/exit does not run the lock's RETURN trap, and the probes are slower
    # than the lock timeout. A live worker is left untouched.
    local running_early=""
    running_early="$(agmsg_codex_bridge_running_pid \
      "$run_dir/codex-bridge.$TEAM.$NAME.pid" \
      "codex-bridge|$TEAM.$NAME" \
      "$(agmsg_identity_key "$TEAM" "$NAME")" || true)"
    if [ -n "$running_early" ]; then
      echo "spawn: headless codex '$NAME' already running in '$TEAM' (pid $running_early)"
      return 0
    fi
    agmsg_codex_reviewer_prepare_execpolicy_home
    agmsg_codex_reviewer_assert_execpolicy_home "$codex_bin" "$cwd" "$fs" "$net_c" "$execpolicy_home"
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
  # substrings) can never create argv-boundary or regex ambiguity. The shared
  # generator appends a non-base64url terminator so prefix-related identities
  # remain distinct even when --identity-key is the final argv pair.
  local _idkey
  _idkey="$(agmsg_identity_key "$TEAM" "$NAME")"

  local pidfile="$run_dir/codex-bridge.$TEAM.$NAME.pid"
  local bridge_scope="codex-bridge|$TEAM.$NAME"
  local running=""
  running="$(agmsg_codex_bridge_running_pid "$pidfile" "$bridge_scope" "$_idkey" || true)"
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
  AGMSG_CODEX_APP_SERVER_CMD="$appcmd" AGMSG_CODEX_CLIENT_NAME="$codex_client_name" AGMSG_CODEX_BRIDGE_TURN_TIMEOUT="$codex_turn_timeout" \
    nohup "$SCRIPT_DIR/internal/process-owner-launch.sh" \
    --kind codex-bridge --pidfile "$pidfile" --scope "$bridge_scope" \
    --legacy-needle codex-bridge --legacy-needle "$_idkey" -- "$bridge" \
    --project "$cwd" --type codex --inline-inbox \
    --identity-key "$_idkey" \
    --pair "$TEAM"$'\t'"$NAME" \
    "${runtime_root_args[@]}" \
    ${role_args[@]+"${role_args[@]}"} \
    >> "$log" 2>&1 &
  local bpid=$!
  # Record placement as pid:<n> so despawn tears it down by pid (not a tmux id).
  # The project field is the cwd we registered above so despawn --force's reset.sh
  # drops exactly that registration.
  local placement_record
  placement_record="$(printf '%s\t%s\t%s' "pid:$bpid" "$cwd" "codex")"
  printf '%s\n' "$placement_record" \
    > "$(agmsg_spawn_path "$TEAM" "$NAME")" 2>/dev/null || true
  # despawn takes the placement lock inside the lifecycle lock; release ours
  # before the pending record's publish takes the lifecycle lock.
  _agmsg_spawn_lk_release
  agmsg_pending_teardown_write_spawn_owner "$TEAM" "$NAME" codex "$placement_record" \
    "$(agmsg_pid_start_token "$bpid" 2>/dev/null || true)" || true
  local kind="headless codex"; [ "$REVIEWER" = 1 ] && kind="headless reviewer codex"
  [ "$IMPLEMENTER" = 1 ] && kind="headless implementer codex"
  echo "spawned $kind '$NAME' in team '$TEAM' (pid $bpid)"
  [ "$REVIEWER" = 1 ] && echo "  cwd (repo, read-only): $cwd"
  [ "$IMPLEMENTER" = 1 ] && echo "  workspace (WRITE): $cwd"
  [ "$REVIEWER" = 1 ] && [ -n "$add_dir_roots" ] && \
    echo "  add-dir reads (read-only):$(printf '%s' "$add_dir_roots" | sed 's/="read"//g; s/[",]/ /g')"
  [ -n "$rolefile" ] && echo "  role: $ROLE_FILE"
  echo "  log: $log"
}
