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

# Resolve the headless/reviewer defaults from config when no explicit flag was
# given. The config keys are codex-specific (spawn.codex_headless /
# spawn.codex_reviewer) — reading them here, not in spawn.sh, keeps the core
# free of any "codex" literal.
#   precedence: --headless / --interactive  >  config spawn.codex_headless  >  TUI
#   precedence: --reviewer / --no-reviewer  >  config spawn.codex_reviewer  >  off
#   precedence: --implementer / --no-implementer  >  config spawn.codex_implementer.<name>  >  off
#
# NAME is already resolved (spawn.sh assigns it from $2 near the top of the
# script, well before this function is called) so the per-name
# spawn.codex_implementer.$NAME lookup below can run here. Gated on
# agmsg_codex_safe_token(NAME) first — same hazard and same fix as
# agmsg_codex_model_effort_args's spawn.codex_model.<name>/spawn.codex_effort.<name>
# lookups below: NAME becomes a literal, unescaped fragment of a config.sh
# dotted key, and a name containing an ERE metacharacter could silently
# misresolve to the wrong config line instead of erroring. An unsafe name
# skips the lookup (warn, don't guess) rather than risk that; --implementer
# has no such hazard and stays available for every name.
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
  if [ "$IMPLEMENTER_SET" = 0 ]; then
    if agmsg_codex_safe_token "$NAME"; then
      case "$("$SCRIPT_DIR/config.sh" get "spawn.codex_implementer.$NAME" false 2>/dev/null || true)" in
        true|1|yes|on) IMPLEMENTER=1 ;;
      esac
    else
      echo "spawn: worker name '$(agmsg_codex_sanitize_for_log "$NAME")' is not a safe config-key segment (must match ^[A-Za-z0-9._-]+\$); skipping spawn.codex_implementer.<name> lookup (use --implementer)" >&2
    fi
  fi
  # implementer/reviewer overlap normalization: explicit beats config; both
  # explicit is a contradiction; both config-derived lets the per-worker
  # implementer key beat the global reviewer default.
  if [ "$IMPLEMENTER" = 1 ] && [ "$REVIEWER" = 1 ]; then
    if [ "$IMPLEMENTER_SET" = 1 ] && [ "$REVIEWER_SET" = 1 ]; then
      die "spawn: --implementer and --reviewer are mutually exclusive"
    elif [ "$REVIEWER_SET" = 1 ]; then
      IMPLEMENTER=0
    else
      REVIEWER=0
    fi
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

# Resolve additive filesystem roots shared by every headless codex layout.
# The global spawn.codex_extra_fs_roots config value is a flat, comma-separated
# scalar of PATH=PERM tokens (PERM is read or write). In the default "profile"
# mode, echoes each accepted root as `, "<path>"="<perm>"`, ready to append to
# a filesystem table. In "runtime-write-roots" mode, echoes only PATHs whose
# permission is write, one per line, for bridge --workspace-root arguments.
# Read-only profile roots must never be promoted into writable runtime roots.
# The worker name argument is kept in the resolver signature for parity with
# the sibling codex config resolvers; this key is intentionally global, not
# per-worker.
#
# Paths beginning with ~/ or the literal $HOME/ are expanded without eval.
# Because the result is spliced through both a single-quoted -c clause and a
# TOML string, any quote or backslash is fatal rather than emitted unsafely.
agmsg_codex_extra_fs_roots() {
  local _name="$1" mode="${2:-profile}" value="" remaining="" token="" perm="" path_="" out=""
  case "$mode" in
    profile|runtime-write-roots) ;;
    *) die "spawn: internal error: unknown codex extra filesystem root output mode '$mode'" ;;
  esac
  value="$("$SCRIPT_DIR/config.sh" get "spawn.codex_extra_fs_roots" "" 2>/dev/null || true)"
  [ -n "$value" ] || return 0

  # Appending one delimiter lets the same loop handle a single token and retain
  # empty tokens at either edge; empty tokens are intentionally ignored.
  remaining="$value,"
  while [ -n "$remaining" ]; do
    token="${remaining%%,*}"
    remaining="${remaining#*,}"
    [ -n "$token" ] || continue

    perm="${token##*=}"
    path_="${token%=*}"
    case "$path_" in
      \~/*) path_="$HOME/${path_#\~/}" ;;
      \$HOME/*) path_="$HOME/${path_#\$HOME/}" ;;
    esac
    case "$path_" in
      *\'*|*\"*|*\\*)
        die "spawn: codex extra filesystem root contains a quote/backslash and cannot be spliced into the sandbox config safely" ;;
    esac
    case "$perm" in
      read|write) ;;
      *) die "spawn: invalid codex extra filesystem root permission (expected read or write)" ;;
    esac
    if [ "$mode" = "runtime-write-roots" ]; then
      [ "$perm" = "write" ] && printf '%s\n' "$path_"
    else
      out="$out, \"$path_\"=\"$perm\""
    fi
  done
  if [ "$mode" = "profile" ]; then
    printf '%s' "$out"
  fi
  return 0
}

# Byte-level, locale-independent membership test for the shared safe-token
# charset [A-Za-z0-9._-]: true (0) iff $1 is non-empty and every byte is in
# that set. Used to gate BOTH the worker-name segment spliced into a
# config.sh dotted key (spawn.codex_model.<name>) and the model/effort VALUES
# spliced into appcmd. Implemented by deleting the allowed bytes and checking
# the remainder is empty (`tr -d`, byte-wise) rather than a `case`/glob
# pattern: a bracket-expression range like [A-Za-z0-9] is interpreted per the
# shell's LC_COLLATE/LC_CTYPE and can silently accept/reject a different byte
# set under a non-C locale. LC_ALL=C forces plain ASCII byte semantics
# regardless of the caller's environment, and a `tr` byte-deletion cannot be
# fooled by an embedded newline the way a glob anchor test might be.
agmsg_codex_safe_token() {
  local val="$1" rest
  [ -n "$val" ] || return 1
  # `$(...)` strips ALL trailing newlines from what it captures. If the ONLY
  # disallowed byte(s) in $val were embedded newline(s) (e.g. every other
  # character is a plain letter/digit), tr's entire remainder would be just
  # "\n" — and capturing that via a bare `$(tr -d ...)` would silently strip
  # it to an empty string, i.e. a false "safe" verdict for a value that
  # smuggles a newline. Append a non-newline sentinel byte after tr in the
  # SAME command substitution so the captured stream's true last byte is
  # never a newline, and compare against the sentinel instead of testing for
  # emptiness — this can no longer be fooled by trailing-newline stripping.
  #
  # The sentinel also carries tr's own exit status ($? right after a pipeline
  # is that pipeline's LAST command's status, i.e. tr's, regardless of
  # pipefail). Without this, a broken/missing `tr` would make the pipeline
  # emit NOTHING — a bare `printf 'X'` afterwards would still unconditionally
  # succeed, so ANY value (including a genuinely unsafe one) would compare
  # equal to the sentinel and be misread as "nothing disallowed found", i.e.
  # fail-OPEN. Comparing against "X0" instead makes a tr failure of any kind
  # (missing binary, I/O error, killed by a signal, ...) read as unsafe.
  # (Empirically confirmed under `set -euo pipefail`: a failing command inside
  # a `var=$(...)` assignment does not itself abort the script, so this
  # capture always completes and `rest` is always compared, never skipped.)
  rest="$(printf '%s' "$val" | LC_ALL=C tr -d 'A-Za-z0-9._-'; printf 'X%s' "$?")"
  [ "$rest" = "X0" ]
}

# Sanitize an untrusted value before it is echoed into a spawn warning: strip
# control bytes (LF/CR forge a fake extra log line; ESC starts an ANSI escape
# that can rewrite/hide terminal output — both are C0 control bytes, covered
# by [:cntrl:] in the forced C locale, which also catches DEL/0x7f) and cap the
# length so one oversized value can't flood stderr. The surrounding printable
# text is otherwise left intact — this only removes the bytes that let a
# value escape being "just the next word in this one warning line".
agmsg_codex_sanitize_for_log() {
  local val
  val="$(printf '%s' "$1" | LC_ALL=C tr -d '[:cntrl:]')"
  printf '%s' "${val:0:80}"
}

# Resolve an optional model / reasoning-effort override for a headless codex
# worker, formatted as `-c model="<id>" -c model_reasoning_effort="<val>"`
# ready to splice onto the end of appcmd (empty when neither applies — today's
# behaviour, unset falls back to the worker's global ~/.codex/config.toml).
#
# Precedence:
#   model:  spawn.sh's --model (parsed into $MODEL_ID by spawn.sh, but otherwise
#           unconsumed on the headless path — the interactive/TUI path already
#           wires it via the manifest's model_arg=-m) > config
#           spawn.codex_model.<name> > unset.
#   effort: config spawn.codex_effort.<name> only (headless-only knob, no CLI
#           flag) > unset.
#
# The config lookups key on `$name` (the spawned actas name) as a literal
# fragment of a config.sh dotted key (`spawn.codex_model.$name`). config.sh's
# yaml_get/yaml_set interpolate that field UNESCAPED into an awk ERE — a name
# containing an ERE metacharacter (legal per validate.sh's agmsg_validate_agent_name,
# e.g. `+ * ? ( ) | ^ $` or a space) can silently misresolve to the wrong config
# line instead of erroring. Gate BOTH per-name config lookups on
# agmsg_codex_safe_token(name) so an unsafe name skips config entirely (warn,
# don't guess) rather than risk a wrong-field match; --model (MODEL_ID) has no
# such hazard (it never becomes part of a config key) and stays available for
# every name.
#
# Fail-closed input validation: appcmd is a single string re-parsed by `sh -lc`
# in codex-bridge.js (see AGMSG_CODEX_APP_SERVER_CMD), so an unvalidated value
# could inject shell syntax. Any model/effort value that is not a
# agmsg_codex_safe_token is DROPPED — warn to stderr (value sanitized via
# agmsg_codex_sanitize_for_log first) and continue the spawn without that
# override — rather than embedded verbatim. Applies to both the --model flag
# and the config values alike; neither is trusted here. Each accepted value is
# wrapped in a single-quoted `-c 'key="value"'` clause: the single quotes protect
# the clause across the `sh -lc` re-parse, and the literal double quotes inside
# make the spliced text a valid quoted TOML string for codex's -c KEY=VALUE.
agmsg_codex_model_effort_args() {
  local name="$1" model="" effort="" args="" name_safe=1
  agmsg_codex_safe_token "$name" || name_safe=0

  if [ "$name_safe" != 1 ]; then
    echo "spawn: worker name '$(agmsg_codex_sanitize_for_log "$name")' is not a safe config-key segment (must match ^[A-Za-z0-9._-]+\$); skipping spawn.codex_model.<name>/spawn.codex_effort.<name> lookup (use --model for the model id; effort has no CLI override)" >&2
  fi

  if [ -n "${MODEL_ID:-}" ]; then
    model="$MODEL_ID"
  elif [ "$name_safe" = 1 ]; then
    model="$("$SCRIPT_DIR/config.sh" get "spawn.codex_model.$name" "" 2>/dev/null || true)"
  fi
  if [ "$name_safe" = 1 ]; then
    effort="$("$SCRIPT_DIR/config.sh" get "spawn.codex_effort.$name" "" 2>/dev/null || true)"
  fi

  if [ -n "$model" ] && ! agmsg_codex_safe_token "$model"; then
    echo "spawn: ignoring unsafe codex model id '$(agmsg_codex_sanitize_for_log "$model")' (must match ^[A-Za-z0-9._-]+\$)" >&2
    model=""
  fi
  if [ -n "$effort" ] && ! agmsg_codex_safe_token "$effort"; then
    echo "spawn: ignoring unsafe codex reasoning-effort value '$(agmsg_codex_sanitize_for_log "$effort")' (must match ^[A-Za-z0-9._-]+\$)" >&2
    effort=""
  fi

  [ -n "$model" ]  && args="$args -c 'model=\"$model\"'"
  [ -n "$effort" ] && args="$args -c 'model_reasoning_effort=\"$effort\"'"
  printf '%s' "$args"
}

# Resolve an optional app-server clientInfo.name override for a headless codex
# worker. Default (empty) → the bridge advertises "agmsg-codex-bridge". Some
# limited-preview models (e.g. gpt-5.6-sol) are gated server-side to a
# first-party client identity on the app-server/thread API and reject the
# bridge's own name with a 400 "requires a newer version" — set
# spawn.codex_client_name.<name>=codex_cli to opt that worker into presenting
# the first-party name so the gate passes. Read by the bridge via
# AGMSG_CODEX_CLIENT_NAME (empty → the bridge keeps its default name).
agmsg_codex_client_name() {
  local name="$1" client=""
  if agmsg_codex_safe_token "$name"; then
    client="$("$SCRIPT_DIR/config.sh" get "spawn.codex_client_name.$name" "" 2>/dev/null || true)"
  fi
  if [ -n "$client" ] && ! agmsg_codex_safe_token "$client"; then
    echo "spawn: ignoring unsafe codex client name '$(agmsg_codex_sanitize_for_log "$client")' (must match ^[A-Za-z0-9._-]+\$)" >&2
    client=""
  fi
  printf '%s' "$client"
}

# Resolve an optional per-worker turn timeout (seconds) for a headless codex
# worker, injected as AGMSG_CODEX_BRIDGE_TURN_TIMEOUT. Empty → the bridge's
# built-in default (60s). The bridge treats this as an idle timeout and re-arms
# it on turn activity, so the value is the tolerated interval of true silence,
# not a fixed ceiling on research / deep-review turn duration. Set
# spawn.codex_turn_timeout.<name>=<seconds> to adjust that silence allowance.
# Validated as a positive integer with no leading zero and at most 6 digits, so
# seconds*1000 stays within the bridge's 32-bit setTimeout ceiling (a larger
# value would overflow to a near-immediate fire or Infinity and silently break
# the timeout). Anything else is ignored with a warning.
agmsg_codex_turn_timeout() {
  local name="$1" timeout=""
  if agmsg_codex_safe_token "$name"; then
    timeout="$("$SCRIPT_DIR/config.sh" get "spawn.codex_turn_timeout.$name" "" 2>/dev/null || true)"
  fi
  if [ -n "$timeout" ]; then
    case "$timeout" in
      *[!0-9]*|0*|[0-9][0-9][0-9][0-9][0-9][0-9][0-9]*)
        echo "spawn: ignoring invalid codex turn timeout '$(agmsg_codex_sanitize_for_log "$timeout")' (must be a positive integer of at most 6 digits, in seconds)" >&2
        timeout="" ;;
    esac
  fi
  printf '%s' "$timeout"
}

# Resolve an optional per-worker gh CLI config directory for a reviewer worker.
# Empty/unset means no gh-specific filesystem grant or environment injection.
# This helper is called ONLY from the reviewer layout so consultant/implementer
# workers ignore the key completely, including invalid-value warnings.
#
# The path is spliced into both a TOML filesystem table and appcmd (which the
# bridge re-parses via `sh -lc`), so fail closed unless it is an existing
# absolute directory with no whitespace, quote, backslash, or control byte.
# The sentinel preserves trailing newlines in the comparison and carries tr's
# status, preventing a broken tr from turning validation into fail-open.
agmsg_codex_gh_config_dir() {
  local name="$1" dir="" filtered="" valid=1
  if agmsg_codex_safe_token "$name"; then
    dir="$("$SCRIPT_DIR/config.sh" get "spawn.codex_gh_config_dir.$name" "" 2>/dev/null || true)"
  fi
  [ -n "$dir" ] || return 0

  case "$dir" in
    /*) ;;
    *) valid=0 ;;
  esac
  if [ "$valid" = 1 ]; then
    filtered="$(printf '%s' "$dir" | LC_ALL=C tr -d "[:cntrl:] '\"\\\\"; printf 'X%s' "$?")"
    [ "$filtered" = "${dir}X0" ] || valid=0
  fi
  if [ "$valid" != 1 ] || [ ! -d "$dir" ]; then
    echo "spawn: ignoring invalid codex GH config dir for '$name' (spawn.codex_gh_config_dir.<name> must be an existing absolute directory without whitespace, quotes, backslashes, or control characters)" >&2
    dir=""
  fi
  printf '%s' "$dir"
}

# approval_policy=never in every mode because a headless worker cannot answer approvals.
agmsg_spawn_headless() {
  local run_dir="$SKILL_DIR/run"
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
  local model_effort_args; model_effort_args="$(agmsg_codex_model_effort_args "$NAME")"
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
    # Read-only repo + tmp/toolchain reads + writes confined to agmsg. The toolchain
    # roots let codex run git/rg/etc. installed outside the repo; extend this list if
    # a review needs another global read root (e.g. a language's module cache). The
    # -c values that contain spaces are single-quoted: the bridge runs the command
    # via `sh -lc`, which re-parses the string (see codex-bridge.js).
    local fs_base="\":minimal\"=\"read\", \":tmpdir\"=\"write\", \":workspace_roots\"={ \".\"=\"read\" }, \"/nix\"=\"read\", \"/opt/homebrew\"=\"read\", \"/usr/local\"=\"read\", \"$SKILL_DIR/scripts\"=\"read\", \"$storage_dir\"=\"write\", \"$SKILL_DIR/teams\"=\"write\", \"$run_dir\"=\"write\""
    fs_base="$fs_base$extra_fs"
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
         -c 'permissions.agmsg-reviewer.network={ enabled=true }' \
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
      if ! codex sandbox -P agmsg-reviewer -C "$cwd" \
           -c "permissions.agmsg-reviewer.filesystem={ $fs_base$add_dir_roots$gh_config_root }" \
           -c 'permissions.agmsg-reviewer.network={ enabled=true }' \
           -- /usr/bin/true >/dev/null 2>&1; then
        echo "spawn: reviewer codex GH config injection disabled (augmented sandbox profile failed to apply); using the existing reviewer profile" >&2
        gh_config_dir=""
        gh_config_root=""
      else
        gh_config_arg=" -c 'shell_environment_policy.set.GH_CONFIG_DIR=\"$gh_config_dir\"'"
      fi
    fi
    local fs="{ $fs_base$add_dir_roots$gh_config_root }"
    appcmd="codex app-server --listen stdio:// -c default_permissions=agmsg-reviewer -c 'permissions.agmsg-reviewer.filesystem=$fs' -c 'permissions.agmsg-reviewer.network={ enabled=true }' -c web_search=live -c approval_policy=never$model_effort_args$gh_config_arg"
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
    if probe_out="$(codex sandbox -P agmsg-reviewer -C "$cwd" \
         -c "permissions.agmsg-reviewer.filesystem=$fs" \
         -c 'permissions.agmsg-reviewer.network={ enabled=true }' \
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
         -c 'permissions.agmsg-reviewer.network={ enabled=true }' \
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
  # substrings) can never create argv-boundary or regex ambiguity. The shared
  # generator appends a non-base64url terminator so prefix-related identities
  # remain distinct even when --identity-key is the final argv pair.
  local _idkey
  _idkey="$(agmsg_identity_key "$TEAM" "$NAME")"

  local pidfile="$run_dir/codex-bridge.$TEAM.$NAME.pid"
  local running="" recorded_pid=""
  [ -f "$pidfile" ] && recorded_pid="$(cat "$pidfile" 2>/dev/null || true)"
  if [ -n "$recorded_pid" ] && _agmsg_pid_alive "$recorded_pid"; then
    running="$recorded_pid"
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
  AGMSG_CODEX_APP_SERVER_CMD="$appcmd" AGMSG_CODEX_CLIENT_NAME="$codex_client_name" AGMSG_CODEX_BRIDGE_TURN_TIMEOUT="$codex_turn_timeout" nohup "$bridge" \
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
  printf '%s\t%s\t%s\n' "pid:$bpid" "$cwd" "codex" \
    > "$(agmsg_spawn_path "$TEAM" "$NAME")" 2>/dev/null || true
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
