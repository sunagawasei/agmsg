#!/usr/bin/env bash
# codex spawn plug: name/model/effort/timeout argument validation and resolution.
# Sourced by _spawn.sh after its libs; do not source standalone.

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
# A model value that is a bare family name (`sol`, `luna`, ...) is resolved at
# spawn time to the newest listed `gpt-<version>-<family>` slug in the CLI's own
# catalog, so a new generation is picked up without editing config. A concrete
# slug (`gpt-5.6-sol`) is never touched. No match fails closed: an unpinned
# worker would silently fall back to the global default model.
agmsg_codex_resolve_model_family() {
  local family="$1" slug
  slug="$(codex debug models 2>/dev/null | node -e '
    let t = ""; process.stdin.on("data", d => t += d).on("end", () => {
      let ms; try { ms = JSON.parse(t).models; } catch (e) { process.exit(1); }
      const re = new RegExp("^gpt-([0-9]+(?:\\.[0-9]+)*)-" + process.argv[1] + "$");
      const key = s => re.exec(s)[1].split(".").map(Number);
      const cmp = (a, b) => { for (let i = 0; i < Math.max(a.length, b.length); i++) { const d = (a[i] || 0) - (b[i] || 0); if (d) return d; } return 0; };
      const hits = ms.filter(m => m.visibility === "list" && re.test(m.slug)).map(m => m.slug).sort((a, b) => cmp(key(b), key(a)));
      if (!hits.length) process.exit(1);
      console.log(hits[0]);
    });' "$family")" || slug=""
  if [ -z "$slug" ]; then
    echo "spawn: no listed codex model for family '$family' in 'codex debug models'; refusing to start unpinned" >&2
    return 1
  fi
  printf '%s' "$slug"
}

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

  case "$model" in
    [a-z]*) case "$model" in *[!a-z]*) ;; *) model="$(agmsg_codex_resolve_model_family "$model")" || return 1 ;; esac ;;
  esac

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
