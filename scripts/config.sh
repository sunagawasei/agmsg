#!/usr/bin/env bash
set -euo pipefail

# Manage agmsg configuration.
# Usage: config.sh get <key> [default]
#        config.sh set <key> <value>
#        config.sh show

ACTION="${1:?Usage: config.sh get|set|show ...}"
shift

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/../db/config.yaml"

# --- Helpers ---

# Read a dotted key from YAML (simple flat key: value format)
# Supports dotted keys like "hook.check_interval" → looks for "check_interval" under "hook:"
yaml_get() {
  local key="$1"
  local default="${2:-}"

  if [ ! -f "$CONFIG_FILE" ]; then
    echo "$default"
    return
  fi

  local section="" field=""
  if [[ "$key" == *.* ]]; then
    section="${key%%.*}"
    field="${key#*.}"
  else
    field="$key"
  fi

  local value=""
  if [ -n "$section" ]; then
    # Find value under section. Key matching is a literal string-PREFIX
    # comparison (key_eq below), NOT an awk ERE built from $section/$field:
    # a dotted field (e.g. a per-worker key like "codex_implementer.<name>")
    # contains a literal "." that would silently become an ERE wildcard if
    # spliced into a pattern, letting a lookup for "codex_implementer.foo.bar"
    # match a stored key one character off, e.g. "codex_implementer.fooXbar"
    # — a real privilege-escalation-shaped hazard for a per-worker layout
    # flag (spawn.codex_implementer.<name>) keyed by an actas name that can
    # legally contain regex metacharacters. substr()-equality can't be
    # fooled this way: every byte of $section/$field is compared literally.
    value=$(awk -v section="$section" -v field="$field" '
      function key_eq(line, prefix,    n) {
        n = length(prefix)
        return substr(line, 1, n) == prefix
      }
      /^[^ #]/ { in_section = key_eq($0, section ":") }
      in_section && key_eq($0, "  " field ":") {
        sub(/^  [^ ]+:[ \t]*/, "")
        # Strip inline comments
        sub(/[ \t]+#.*$/, "")
        print
        exit
      }
    ' "$CONFIG_FILE")
  else
    # Top-level key — same literal-prefix matching as above.
    value=$(awk -v field="$field" '
      function key_eq(line, prefix,    n) {
        n = length(prefix)
        return substr(line, 1, n) == prefix
      }
      /^[^ #]/ && key_eq($0, field ":") {
        sub(/^[^ ]+:[ \t]*/, "")
        sub(/[ \t]+#.*$/, "")
        print
        exit
      }
    ' "$CONFIG_FILE")
  fi

  if [ -n "$value" ]; then
    echo "$value"
  else
    echo "$default"
  fi
}

# Set a dotted key in YAML
yaml_set() {
  local key="$1"
  local value="$2"

  local section="" field=""
  if [[ "$key" == *.* ]]; then
    section="${key%%.*}"
    field="${key#*.}"
  else
    field="$key"
  fi

  # Create config file with defaults if it doesn't exist
  if [ ! -f "$CONFIG_FILE" ]; then
    create_default_config
  fi

  # Same literal string-PREFIX matching as yaml_get (key_eq), for the same
  # reason: section/field come from a caller-supplied dotted key (e.g. a
  # per-worker key like "spawn.codex_implementer.<name>") and can legally
  # contain "." or other ERE metacharacters that must NOT be interpreted as
  # regex syntax — an unescaped "." would let set() silently rewrite/append
  # to the WRONG key one character off. grep's own "^pattern" is a BRE, so
  # it has the same hazard for the section-existence probe below; replaced
  # with the same awk key_eq() helper used everywhere else in this file.
  if [ -n "$section" ]; then
    # Check if section exists
    if ! awk -v section="$section" '
      function key_eq(line, prefix,    n) { n = length(prefix); return substr(line, 1, n) == prefix }
      /^[^ #]/ && key_eq($0, section ":") { found=1; exit }
      END { exit !found }
    ' "$CONFIG_FILE" 2>/dev/null; then
      printf '\n%s:\n  %s: %s\n' "$section" "$field" "$value" >> "$CONFIG_FILE"
    elif awk -v section="$section" -v field="$field" '
      function key_eq(line, prefix,    n) { n = length(prefix); return substr(line, 1, n) == prefix }
      /^[^ #]/ { in_section = key_eq($0, section ":") }
      in_section && key_eq($0, "  " field ":") { found=1; exit }
      END { exit !found }
    ' "$CONFIG_FILE" 2>/dev/null; then
      # Update existing field under section
      awk -v section="$section" -v field="$field" -v value="$value" '
        function key_eq(line, prefix,    n) { n = length(prefix); return substr(line, 1, n) == prefix }
        /^[^ #]/ { in_section = key_eq($0, section ":") }
        in_section && key_eq($0, "  " field ":") {
          print "  " field ": " value
          next
        }
        { print }
      ' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
    else
      # Add field to existing section
      awk -v section="$section" -v field="$field" -v value="$value" '
        function key_eq(line, prefix,    n) { n = length(prefix); return substr(line, 1, n) == prefix }
        { print }
        /^[^ #]/ && key_eq($0, section ":") {
          print "  " field ": " value
        }
      ' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
    fi
  else
    if awk -v field="$field" '
      function key_eq(line, prefix,    n) { n = length(prefix); return substr(line, 1, n) == prefix }
      /^[^ #]/ && key_eq($0, field ":") { found=1; exit }
      END { exit !found }
    ' "$CONFIG_FILE" 2>/dev/null; then
      # Update existing top-level key
      awk -v field="$field" -v value="$value" '
        function key_eq(line, prefix,    n) { n = length(prefix); return substr(line, 1, n) == prefix }
        key_eq($0, field ":") {
          print field ": " value
          next
        }
        { print }
      ' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
    else
      printf '%s: %s\n' "$field" "$value" >> "$CONFIG_FILE"
    fi
  fi
}

create_default_config() {
  cat > "$CONFIG_FILE" <<'YAML'
# agmsg configuration
# https://agmsg.cc/
#
# Mode (monitor | turn | both | off) is per-project — derived from each
# project's .claude/settings.local.json by `delivery.sh status`. There is
# no global "mode" key. Only machine-wide tuning lives here.

delivery:
  # Default delivery mode for a NEW project's join flow, so you are not prompted
  # to choose each time. One of: monitor | turn | both | off. Unset = ask.
  # Currently consulted by the claude-code join flow only (other agent types
  # still prompt); an unset/invalid/unsupported value falls back to asking.
  #   agmsg config set delivery.default_mode monitor
  # default_mode: monitor
  monitor:
    # watch.sh SQLite poll interval, seconds
    poll_interval: 5
  turn:
    # Stop hook cooldown, seconds. Legacy alias: hook.check_interval
    check_interval: 60
  # Opt-in: give each Claude session its OWN team (s-<session-uuid>) instead of
  # the project-derived team, so concurrent / resumed sessions sharing a
  # directory are fully isolated (no cross-session codex crosstalk). The session
  # codex is spawned lazily and torn down on session end. Off by default; enable:
  #   agmsg config set delivery.session_team true
  # session_team: false
  # Days before a dead session's team dir is garbage-collected (default 7):
  # session_team_ttl_days: 7
YAML
}

# --- Actions ---

case "$ACTION" in
  get)
    KEY="${1:?Usage: config.sh get <key> [default]}"
    DEFAULT="${2:-}"
    yaml_get "$KEY" "$DEFAULT"
    ;;
  set)
    KEY="${1:?Usage: config.sh set <key> <value>}"
    VALUE="${2:?Usage: config.sh set <key> <value>}"
    yaml_set "$KEY" "$VALUE"
    echo "Set $KEY = $VALUE"
    ;;
  show)
    if [ -f "$CONFIG_FILE" ]; then
      cat "$CONFIG_FILE"
    else
      echo "No config file. Using defaults."
      echo ""
      create_default_config
      cat "$CONFIG_FILE"
    fi
    ;;
  *)
    echo "Unknown action: $ACTION (use get|set|show)" >&2
    exit 1
    ;;
esac
