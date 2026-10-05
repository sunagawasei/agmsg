#!/usr/bin/env bash
# codex spawn plug: headless/reviewer/implementer mode resolution and the seatbelt-nesting preflight.
# Sourced by _spawn.sh after its libs; do not source standalone.

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
# lookups in _spawn-args.sh: NAME becomes a literal, unescaped fragment of a config.sh
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
