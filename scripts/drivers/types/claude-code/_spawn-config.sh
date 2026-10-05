#!/usr/bin/env bash
# claude-code spawn plug: argument/config resolution, turn options and version check.
# Sourced by _spawn.sh after its constants and libs; do not source standalone.

agmsg_claude_safe_token() {
  local val="$1" rest
  [ -n "$val" ] || return 1
  rest="$(printf '%s' "$val" | LC_ALL=C tr -d 'A-Za-z0-9._-'; printf 'X%s' "$?")"
  [ "$rest" = "X0" ]
}

agmsg_claude_safe_model_id() {
  local val="$1" rest
  [ -n "$val" ] || return 1
  rest="$(printf '%s' "$val" | LC_ALL=C tr -d 'A-Za-z0-9._-'; printf 'X%s' "$?")"
  case "$rest" in
    X0) return 0 ;;
    '[]X0')
      case "$val" in
        ?*'['?*']') return 0 ;;
      esac
      ;;
  esac
  return 1
}

agmsg_claude_sanitize_for_log() {
  local val
  val="$(printf '%s' "$1" | LC_ALL=C tr -d '[:cntrl:]')"
  printf '%s' "${val:0:80}"
}

agmsg_claude_config_true() {
  case "$1" in true|1|yes|on) return 0 ;; *) return 1 ;; esac
}

# Spawn unwind is internal to this team; never remove an equivalent role elsewhere.
# Residual risk: reset remains best-effort so an unavailable registry does not
# change the existing spawn failure/cleanup contract.
agmsg_claude_reset_registration() {
  local team="$1" project="$2" name="$3"
  "$SCRIPT_DIR/reset.sh" --team "$team" "$project" claude-code "$name" >/dev/null 2>&1
}

# Explicit flags win. Per-worker implementer and inherit-add-dir keys are read
# only for safe name segments; unsafe names retain explicit flags/global defaults
# without ever entering config.sh's unescaped dotted-key matcher.
agmsg_spawn_resolve_modes() {
  local name_safe=1 inherit_value="__agmsg_unset__"
  agmsg_claude_safe_token "$NAME" || name_safe=0

  if [ "$HEADLESS_SET" = 0 ] \
    && agmsg_claude_config_true "$("$SCRIPT_DIR/config.sh" get spawn.claude_headless false 2>/dev/null || true)"; then
    HEADLESS=1
  fi
  if [ "$REVIEWER_SET" = 0 ] \
    && agmsg_claude_config_true "$("$SCRIPT_DIR/config.sh" get spawn.claude_reviewer false 2>/dev/null || true)"; then
    REVIEWER=1
  fi
  if [ "$IMPLEMENTER_SET" = 0 ]; then
    if [ "$name_safe" = 1 ]; then
      if agmsg_claude_config_true "$("$SCRIPT_DIR/config.sh" get "spawn.claude_implementer.$NAME" false 2>/dev/null || true)"; then
        IMPLEMENTER=1
      fi
    else
      echo "spawn: worker name '$(agmsg_claude_sanitize_for_log "$NAME")' is not a safe config-key segment (must match ^[A-Za-z0-9._-]+\$); skipping spawn.claude_implementer.<name> lookup (use --implementer)" >&2
    fi
  fi

  # Approved expansion: a per-name inherit gate overrides the global gate. The
  # selected KEY (not a hand-parsed value) is passed to the established shared
  # collector later, so JSON extraction remains centralized.
  CLAUDE_CODE_INHERIT_ADD_DIRS_KEY="spawn.claude_inherit_add_dirs"
  if [ "$name_safe" = 1 ]; then
    inherit_value="$("$SCRIPT_DIR/config.sh" get "spawn.claude_inherit_add_dirs.$NAME" "__agmsg_unset__" 2>/dev/null || true)"
    if [ "$inherit_value" != "__agmsg_unset__" ]; then
      CLAUDE_CODE_INHERIT_ADD_DIRS_KEY="spawn.claude_inherit_add_dirs.$NAME"
    fi
  else
    echo "spawn: worker name '$(agmsg_claude_sanitize_for_log "$NAME")' is not a safe config-key segment; skipping spawn.claude_inherit_add_dirs.<name> lookup and retaining the global gate" >&2
  fi

  # Same overlap normalization as codex: two explicit positive flags conflict;
  # an explicit reviewer beats a configured implementer; otherwise implementer
  # wins over a configured reviewer.
  if [ "$IMPLEMENTER" = 1 ] && [ "$REVIEWER" = 1 ]; then
    if [ "$IMPLEMENTER_SET" = 1 ] && [ "$REVIEWER_SET" = 1 ]; then
      die "--implementer and --reviewer are mutually exclusive"
    elif [ "$REVIEWER_SET" = 1 ]; then
      IMPLEMENTER=0
    else
      REVIEWER=0
    fi
  fi
}

agmsg_claude_resolve_turn_options() {
  local name="$1" name_safe=1 model="" effort="" timeout=""
  agmsg_claude_safe_token "$name" || name_safe=0

  if [ "$name_safe" != 1 ]; then
    echo "spawn: worker name '$(agmsg_claude_sanitize_for_log "$name")' is not a safe config-key segment; skipping spawn.claude_model/effort/turn_timeout.<name> lookups" >&2
  fi
  if [ -n "${MODEL_ID:-}" ]; then
    model="$MODEL_ID"
  elif [ "$name_safe" = 1 ]; then
    model="$("$SCRIPT_DIR/config.sh" get "spawn.claude_model.$name" "" 2>/dev/null || true)"
  fi
  if [ "$name_safe" = 1 ]; then
    effort="$("$SCRIPT_DIR/config.sh" get "spawn.claude_effort.$name" "" 2>/dev/null || true)"
    timeout="$("$SCRIPT_DIR/config.sh" get "spawn.claude_turn_timeout.$name" "" 2>/dev/null || true)"
  fi

  if [ -n "$model" ] && ! agmsg_claude_safe_model_id "$model"; then
    echo "spawn: ignoring unsafe Claude model id '$(agmsg_claude_sanitize_for_log "$model")' (must match ^[A-Za-z0-9._-]+(\\[[A-Za-z0-9._-]+\\])?\$)" >&2
    model=""
  fi
  if [ -n "$effort" ] && ! agmsg_claude_safe_token "$effort"; then
    echo "spawn: ignoring unsafe Claude effort value '$(agmsg_claude_sanitize_for_log "$effort")' (must match ^[A-Za-z0-9._-]+\$)" >&2
    effort=""
  fi
  if [ -n "$timeout" ]; then
    case "$timeout" in
      *[!0-9]*|0*|[0-9][0-9][0-9][0-9][0-9][0-9][0-9]*)
        echo "spawn: ignoring invalid Claude turn timeout '$(agmsg_claude_sanitize_for_log "$timeout")' (must be a positive integer of at most 6 digits, in seconds)" >&2
        timeout="" ;;
    esac
  fi

  CLAUDE_CODE_MODEL="$model"
  CLAUDE_CODE_EFFORT="$effort"
  CLAUDE_CODE_TURN_TIMEOUT="$timeout"
}

agmsg_claude_check_version() {
  local out major minor patch
  if ! out="$("$CLAUDE_CODE_BIN" --version 2>&1)"; then
    die "Claude Code version probe failed; refusing headless spawn (expected '$CLAUDE_CODE_MIN_VERSION (Claude Code)' or newer)"
  fi
  if [[ "$out" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)\ \(Claude\ Code\)$ ]]; then
    major="${BASH_REMATCH[1]}"
    minor="${BASH_REMATCH[2]}"
    patch="${BASH_REMATCH[3]}"
  else
    die "unparseable Claude Code version '$out' (expected '<semver> (Claude Code)'); refusing headless spawn"
  fi
  if (( 10#$major < 2 \
        || (10#$major == 2 && 10#$minor < 1) \
        || (10#$major == 2 && 10#$minor == 1 && 10#$patch < 226) )); then
    die "Claude Code $major.$minor.$patch is below the live-verified minimum $CLAUDE_CODE_MIN_VERSION; refusing headless spawn"
  fi
  CLAUDE_CODE_VERSION_OUTPUT="$out"
}
