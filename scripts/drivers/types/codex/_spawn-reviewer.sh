#!/usr/bin/env bash
# codex spawn plug: reviewer gh config, network assertion and per-launch execpolicy home.
# Sourced by _spawn.sh after its libs; do not source standalone.

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
  elif agmsg_reviewer_path_conflicts_execpolicy_home "$dir"; then
    echo "spawn: ignoring codex GH config dir under execpolicy home tree for '$name': $dir" >&2
    dir=""
  fi
  printf '%s' "$dir"
}

# Command-egress allowlist for the reviewer profile. Research workers use this
# same profile; there is no second network policy. The hosts are the ones the
# gh CLI reaches over HTTPS. Measured with codex 0.147.0 and network_proxy:
# each name returns an origin status (200/301/302/404), while https://example.com
# is a proxy 403. Direct HTTPS to 1.1.1.1 with --noproxy '*' is refused.
agmsg_codex_reviewer_network_config() {
  printf '%s' 'permissions.agmsg-reviewer.network={ enabled=true, domains={ "github.com"="allow", "api.github.com"="allow", "codeload.github.com"="allow", "uploads.github.com"="allow", "gist.github.com"="allow", "objects.githubusercontent.com"="allow", "raw.githubusercontent.com"="allow" } }'
}

# Fail closed unless this codex build enforces the allowlist. A build that
# ignores network_proxy must not launch a reviewer with unrestricted egress.
# Headless review then uses a different reviewer.
agmsg_codex_reviewer_assert_network() {
  local codex_bin="$1" cwd="$2" fs="$3" net_c="$4" out rc=0
  out="$("$codex_bin" sandbox --enable network_proxy -P agmsg-reviewer -C "$cwd" \
       -c "permissions.agmsg-reviewer.filesystem=$fs" \
       -c "$net_c" \
       -- /bin/sh -c '
         # Absolute path on purpose. A curl earlier on PATH, including one
         # planted in the repo, must not be able to fake this result.
         if /usr/bin/curl -sS -o /dev/null --max-time 20 https://example.com; then
           echo "disallowed-host-reachable"
           exit 10
         fi
         if /usr/bin/curl -sS -o /dev/null --max-time 20 --noproxy "*" -k https://1.1.1.1/; then
           echo "direct-ip-bypassed-proxy"
           exit 11
         fi
         /usr/bin/curl -sS -o /dev/null --max-time 20 https://api.github.com
       ' 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    die "reviewer network proxy is not enforced (example.com and a direct IP must fail, api.github.com must succeed); refusing to launch (rc=$rc got: ${out:-<empty>})."
  fi
}

# User execpolicy allow-rules are not part of the reviewer profile.
# codex 0.147.0's app-server has no --ignore-rules (that flag is only on
# `codex exec`). The reviewer process gets its own CODEX_HOME: rules is an
# empty real directory, config.toml is absent, and auth.json is a symlink
# only when the source home has one. Measured with `codex exec` on 0.147.0:
# a home with no trust_level does not load the repo's .codex/rules, including
# when .codex is a symlink; the same repo is loaded once config.toml marks it
# trusted. Leaving config.toml out is what keeps project rules unloaded for
# the life of the process. A build that loads project rules without trust is
# outside this fix.
# Sets AGMSG_REVIEWER_EXEC_HOME. Does not create or modify the directory:
# that happens only after the duplicate-worker check, so a rejected second
# spawn cannot replace a live worker's auth link or rules.
# Sets AGMSG_REVIEWER_EXEC_HOME to a per-spawn directory so concurrent spawns
# for the same team/name do not race on rules, auth links, or config.
agmsg_codex_reviewer_execpolicy_home_path() {
  local dest launch_id="$$.$RANDOM"
  case "$TEAM" in
    *[!A-Za-z0-9._-]*)
      die "spawn: reviewer team name cannot be used in the execpolicy home: $TEAM" ;;
  esac
  case "$NAME" in
    *[!A-Za-z0-9._-]*)
      die "spawn: reviewer name cannot be used in the execpolicy home: $NAME" ;;
  esac
  case "$launch_id" in
    *[!A-Za-z0-9._-]*)
      die "spawn: reviewer execpolicy launch id is not path-safe: $launch_id" ;;
  esac
  dest="$SKILL_DIR/reviewer-codex-home/$TEAM/$NAME/launch.$launch_id"
  case "$dest" in
    *[!A-Za-z0-9._/+-]*)
      die "spawn: reviewer execpolicy home path cannot be spliced safely: $dest" ;;
  esac
  case "$dest" in
    "$SKILL_DIR/run"|"$SKILL_DIR/run"/*|"$SKILL_DIR/teams"|"$SKILL_DIR/teams"/*)
      die "spawn: reviewer execpolicy home is inside a write grant: $dest" ;;
  esac
  AGMSG_REVIEWER_EXEC_HOME="$dest"
}

agmsg_codex_reviewer_discard_execpolicy_home() {
  [ -n "${AGMSG_REVIEWER_EXEC_HOME:-}" ] && rm -rf "$AGMSG_REVIEWER_EXEC_HOME" 2>/dev/null || true
}

# Not called from a command substitution: bash disables errexit there, so a
# failed rm would still look like success.
agmsg_codex_reviewer_prepare_execpolicy_home() {
  local source_home dest parent
  source_home="${CODEX_HOME:-$HOME/.codex}"
  dest="$AGMSG_REVIEWER_EXEC_HOME"
  parent="$SKILL_DIR/reviewer-codex-home"
  if [ -L "$parent" ] || [ -L "$parent/$TEAM" ] || [ -L "$parent/$TEAM/$NAME" ] || [ -L "$dest" ]; then
    die "spawn: reviewer execpolicy home is a symlink; refusing to launch ($dest)"
  fi
  if [ -e "$dest" ] && [ ! -d "$dest" ]; then
    die "spawn: reviewer execpolicy home exists and is not a directory: $dest"
  fi
  mkdir -p "$dest" || die "spawn: failed to create reviewer execpolicy home: $dest"
  if [ -L "$dest/rules" ]; then
    die "spawn: reviewer execpolicy rules path is a symlink; refusing to launch ($dest/rules)"
  fi
  rm -rf "$dest/rules" || die "spawn: failed to clear reviewer execpolicy rules: $dest/rules"
  mkdir -p "$dest/rules" || die "spawn: failed to create reviewer execpolicy rules: $dest/rules"
  if [ -L "$dest/marker" ]; then
    die "spawn: reviewer execpolicy home marker is a symlink; refusing to launch ($dest/marker)"
  fi
  printf 'agmsg-reviewer-home\n' > "$dest/marker" || die "spawn: failed to write reviewer execpolicy home marker: $dest/marker"
  # Drop a link left by an earlier source home. A spawn with no auth.json
  # must not keep the previous worker's credential.
  rm -f "$dest/auth.json" || die "spawn: failed to clear reviewer execpolicy auth link: $dest/auth.json"
  if [ -e "$source_home/auth.json" ]; then
    ln -sfn "$source_home/auth.json" "$dest/auth.json" || die "spawn: failed to link reviewer execpolicy auth: $dest/auth.json"
  fi
  # A leftover config.toml could mark this repo trusted and load project rules.
  if [ -L "$dest/config.toml" ] || [ -e "$dest/config.toml" ]; then
    rm -f "$dest/config.toml" || die "spawn: failed to remove reviewer execpolicy config: $dest/config.toml"
  fi
}

# A sandboxed command must not read the marker, plant a rule, or replace the
# auth symlink. Any other failure (missing binary, syntax, a proxy that does
# not apply "none") also refuses the launch. Absolute binaries so a curl-style
# PATH stand-in cannot choose the result.
agmsg_codex_reviewer_assert_exec_denied() {
  local label="$1"; shift
  local out rc=0
  out="$("$@" 2>&1)" || rc=$?
  if [ "$rc" -eq 0 ]; then
    agmsg_codex_reviewer_discard_execpolicy_home
    die "reviewer execpolicy home is not enforced ($label succeeded); refusing to launch (got: ${out:-<empty>})."
  fi
  case "$out" in
    *"Operation not permitted"*|*"Permission denied"*) ;;
    *)
      agmsg_codex_reviewer_discard_execpolicy_home
      die "reviewer execpolicy home probe failed unexpectedly ($label); refusing to launch (rc=$rc got: ${out:-<empty>})." ;;
  esac
}

agmsg_codex_reviewer_assert_execpolicy_home() {
  local codex_bin="$1" cwd="$2" fs="$3" net_c="$4" home="$5"
  local -a sandbox=(
    "$codex_bin" sandbox --enable network_proxy -P agmsg-reviewer -C "$cwd"
    -c "permissions.agmsg-reviewer.filesystem=$fs"
    -c "$net_c"
    -- /bin/sh -c
  )
  agmsg_codex_reviewer_assert_exec_denied "read marker" \
    "${sandbox[@]}" "/bin/cat -- '$home/marker'"
  agmsg_codex_reviewer_assert_exec_denied "write rules" \
    "${sandbox[@]}" "/usr/bin/touch -- '$home/rules/planted.rules'"
  agmsg_codex_reviewer_assert_exec_denied "replace auth link" \
    "${sandbox[@]}" "/bin/ln -sfn -- /tmp/agmsg-not-auth '$home/auth.json'"
}
