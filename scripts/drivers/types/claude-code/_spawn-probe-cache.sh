#!/usr/bin/env bash
# claude-code spawn plug: sandbox probe cache (key, hit check, write, discard).
# Sourced by _spawn.sh after its constants and libs; do not source standalone.

# --- Probe cache (see CLAUDE.md spawn.claude_probe_cache*) ------------------
#
# Reuse a prior sandbox probe result while the things it depends on have not
# changed, instead of paying a live Claude turn on every spawn. Key material
# and hit/uncacheable rules are spelled out next to each helper below; see
# [task:probe-cache] for the full design.

# Portable SHA-256 of stdin. Mirrors agmsg_sha1's fallback order (lib/hash.sh)
# one tier up; not security-sensitive here (single-user dev machine, no
# malicious-worker threat model — see [task:probe-cache]), so a non-cryptographic
# last resort is an acceptable tail case.
agmsg_claude_sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 | awk '{print $NF}'
  else
    cksum | awk '{print $1 "-" $2}'
  fi
}

# Length-prefix every argument and concatenate. Unlike separator-joined
# concatenation, this cannot collide when an item's own bytes contain the
# separator; each item boundary is only ever fixed by the byte count that
# precedes it.
agmsg_claude_probe_cache_lenprefix() {
  local item len
  for item in "$@"; do
    len="$(printf '%s' "$item" | wc -c | tr -d ' ')"
    printf '%s:' "$len"
    printf '%s' "$item"
  done
}

# Realpath of a FILE (the Claude binary), portable without a `realpath`
# binary — mirrors lib/resolve-project.sh's `cd && pwd -P` idiom for the
# directory part (chosen there for macOS bash 3.2 with no GNU realpath) plus a
# manual readlink loop for the file part, since agmsg_claude_physical_path's
# `cd`-based agmsg_canonical_path only resolves directories: `cd` into a file
# fails, so it would silently hand back the un-resolved symlink path instead.
agmsg_claude_probe_cache_bin_realpath() {
  local path="$1" dir base target seen=0
  [ -e "$path" ] || [ -L "$path" ] || return 1
  while [ -L "$path" ]; do
    seen=$((seen + 1))
    [ "$seen" -le 40 ] || return 1
    target="$(readlink "$path" 2>/dev/null)" || return 1
    case "$target" in
      /*) path="$target" ;;
      *) path="$(dirname "$path")/$target" ;;
    esac
  done
  [ -e "$path" ] || return 1
  dir="$(dirname "$path")"
  base="$(basename "$path")"
  dir="$(cd "$dir" 2>/dev/null && pwd -P)" || return 1
  printf '%s/%s' "$dir" "$base"
}

# mtime+size of the resolved Claude binary (key item 3). Returns 1 (uncacheable
# by the caller's convention) for anything but a clean stat.
agmsg_claude_probe_cache_bin_stat() {
  local file="$1" out
  [ -e "$file" ] || return 1
  # Prefer BSD `stat -f` then GNU `stat -c`. Do not key off `uname -s`: a
  # GNU coreutils stat on macOS treats `-f` as --file-system and would hash
  # a volatile filesystem dump (free inodes) into every cache key.
  if out="$(stat -f '%m %z' "$file" 2>/dev/null)" \
    && [[ "$out" =~ ^[0-9]+[[:space:]]+[0-9]+$ ]]; then
    printf '%s' "$out"
    return 0
  fi
  if out="$(stat -c '%Y %s' "$file" 2>/dev/null)" \
    && [[ "$out" =~ ^[0-9]+[[:space:]]+[0-9]+$ ]]; then
    printf '%s' "$out"
    return 0
  fi
  return 1
}

# OS identity (key item 4). sw_vers is Darwin-only; a box without it still
# gets a deterministic string from uname -r alone. If sw_vers is on PATH but
# fails, or uname -r fails, this is uncacheable (ENOENT-other read failure),
# not an empty cacheable placeholder.
agmsg_claude_probe_cache_os_string() {
  local sw="" kr=""
  if command -v sw_vers >/dev/null 2>&1; then
    sw="$(sw_vers -productVersion 2>/dev/null)" || return 1
    [ -n "$sw" ] || return 1
  fi
  kr="$(uname -r 2>/dev/null)" || return 1
  [ -n "$kr" ] || return 1
  printf '%s %s' "$sw" "$kr"
}

# Recursively hash one directory's files as sorted (relpath, length, content)
# tuples. Returns 1 (uncacheable) the moment any file cannot be read; a
# missing directory is quietly empty rather than an error (only used on
# directories this driver itself ships, see agmsg_claude_probe_cache_logic_hash).
# follow-symlinks: traverse directory/file symlinks (managed-settings.d).
# A find -L loop or unreadable referent is uncacheable, not a silent miss.
agmsg_claude_probe_cache_tree_lines() {
  local base="$1" follow="${2:-}" file rel len digest files
  [ -d "$base" ] || return 0
  [ -r "$base" ] && [ -x "$base" ] || return 1
  if [ "$follow" = follow-symlinks ]; then
    files="$(find -L "$base" -type f -print 2>/dev/null)" || return 1
  else
    files="$(find "$base" -type f -print 2>/dev/null)" || return 1
  fi
  [ -n "$files" ] || return 0
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    [ -r "$file" ] || return 1
    rel="${file#"$base"/}"
    len="$(wc -c < "$file" 2>/dev/null)" || return 1
    len="${len//[[:space:]]/}"
    digest="$(agmsg_claude_sha256 < "$file" 2>/dev/null)" || return 1
    [ -n "$digest" ] || return 1
    printf '%s\t%s\t%s\n' "$rel" "$len" "$digest"
  done < <(printf '%s\n' "$files" | LC_ALL=C sort)
}

# Key item 5: this driver's own files plus scripts/lib/, so a change to either
# invalidates every cached probe. *.sh is deliberately not the filter — see
# [task:probe-cache] design section 1.
agmsg_claude_probe_cache_logic_hash() {
  local base label chunk line lines="" rc=0
  for base in "$SCRIPT_DIR/drivers/types/claude-code" "$SCRIPT_DIR/lib"; do
    label="${base#"$SCRIPT_DIR"/}"
    chunk="$(agmsg_claude_probe_cache_tree_lines "$base")" || { rc=1; break; }
    if [ -n "$chunk" ]; then
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        lines="$lines$label/$line"$'\n'
      done <<< "$chunk"
    fi
  done
  [ "$rc" -eq 0 ] || return 1
  printf '%s' "$lines" | LC_ALL=C sort | agmsg_claude_sha256
}

# Key item 8 (single-file layers): "absent" for a nonexistent (including
# dangling-symlink) path is a valid, expected value — only an existing-but-
# unreadable path is uncacheable.
agmsg_claude_probe_cache_layer_value() {
  local file="$1" digest
  if [ ! -e "$file" ]; then
    printf 'absent'
    return 0
  fi
  [ -f "$file" ] && [ -r "$file" ] || return 1
  digest="$(agmsg_claude_sha256 < "$file" 2>/dev/null)" || return 1
  [ -n "$digest" ] || return 1
  printf '%s' "$digest"
}

# Key item 8 (managed-settings.d/): same "absent" contract as
# agmsg_claude_probe_cache_layer_value, but for a directory of files.
agmsg_claude_probe_cache_layer_dir_value() {
  local base="$1" lines
  if [ ! -e "$base" ]; then
    printf 'absent'
    return 0
  fi
  [ -d "$base" ] || return 1
  # Follow file and directory symlinks: a fixed managed-settings.d tree whose
  # referents change is ordinary config drift, not the out-of-scope
  # "malicious symlink swap" case.
  lines="$(agmsg_claude_probe_cache_tree_lines "$base" follow-symlinks)" || return 1
  printf '%s' "$lines" | LC_ALL=C sort | agmsg_claude_sha256
}

# Key item 6: re-render settings with the 3 spawn-unique inputs (scratch,
# child_tmp, sentinel) swapped for fixed placeholders, sorting inherited add-dirs
# first so only their set (not their order) affects the result. This calls the
# exact same generator as the real spawn — never a text substitution on already
# generated JSON — so a change to what the generator itself enumerates is
# always caught (design section 1, item 6).
agmsg_claude_probe_cache_normalized_settings() {
  local layout="$1" project="$2" storage_dir="$3" worker_home="$4"
  shift 4
  local -a inherited_sorted=()
  local line
  if [ "$#" -gt 0 ]; then
    while IFS= read -r line; do
      [ -n "$line" ] && inherited_sorted+=("$line")
    done < <(printf '%s\n' "$@" | LC_ALL=C sort)
  fi
  agmsg_claude_render_settings_json "$layout" "$project" \
    "$_AGMSG_CLAUDE_PROBE_CACHE_PLACEHOLDER_SCRATCH" \
    "$storage_dir" "$worker_home" \
    "$_AGMSG_CLAUDE_PROBE_CACHE_PLACEHOLDER_SENTINEL" \
    "$_AGMSG_CLAUDE_PROBE_CACHE_PLACEHOLDER_CHILD_TMP" \
    ${inherited_sorted[@]+"${inherited_sorted[@]}"}
}

# Combine every key item (design section 1) into one SHA-256. Prints the key
# and returns 0 on success; returns 1 (uncacheable, per design section 2) the
# moment any item other than the item-8 external layers cannot be read.
agmsg_claude_probe_cache_key() {
  local layout="$1" project="$2" storage_dir="$3" worker_home="$4"
  local model="$5" effort="$6" version_output="$7" bin="$8"
  shift 8
  local -a inherited_dirs=("$@")
  local bin_resolved bin_realpath bin_stat os_string logic_hash settings_hash
  local project_realpath managed_hash managed_d_hash
  local worker_settings_hash worker_remote_hash worker_policy_hash

  bin_resolved="$(command -v -- "$bin" 2>/dev/null || true)"
  [ -n "$bin_resolved" ] || return 1
  bin_realpath="$(agmsg_claude_probe_cache_bin_realpath "$bin_resolved")" || return 1
  [ -n "$bin_realpath" ] || return 1

  bin_stat="$(agmsg_claude_probe_cache_bin_stat "$bin_realpath")" || return 1
  os_string="$(agmsg_claude_probe_cache_os_string)" || return 1
  logic_hash="$(agmsg_claude_probe_cache_logic_hash)" || return 1

  settings_hash="$(agmsg_claude_probe_cache_normalized_settings \
    "$layout" "$project" "$storage_dir" "$worker_home" \
    ${inherited_dirs[@]+"${inherited_dirs[@]}"} | agmsg_claude_sha256)" || return 1
  [ -n "$settings_hash" ] || return 1

  project_realpath="$(agmsg_claude_physical_path "$project")"

  managed_hash="$(agmsg_claude_probe_cache_layer_value \
    "$AGMSG_CLAUDE_MANAGED_SETTINGS_DIR/managed-settings.json")" || return 1
  managed_d_hash="$(agmsg_claude_probe_cache_layer_dir_value \
    "$AGMSG_CLAUDE_MANAGED_SETTINGS_DIR/managed-settings.d")" || return 1
  worker_settings_hash="$(agmsg_claude_probe_cache_layer_value \
    "$worker_home/settings.json")" || return 1
  worker_remote_hash="$(agmsg_claude_probe_cache_layer_value \
    "$worker_home/remote-settings.json")" || return 1
  worker_policy_hash="$(agmsg_claude_probe_cache_layer_value \
    "$worker_home/policy-limits.json")" || return 1

  agmsg_claude_probe_cache_lenprefix \
    "$bin_realpath" "$version_output" "$bin_stat" "$os_string" \
    "$logic_hash" "$settings_hash" "$project_realpath" \
    "$managed_hash" "$managed_d_hash" \
    "$worker_settings_hash" "$worker_remote_hash" "$worker_policy_hash" \
    "$layout" "$model" "$effort" \
    | agmsg_claude_sha256
}

# Hit iff the record is a plain file (never a symlink) and
# 0 <= now - probed_at <= ttl (design section 4).
agmsg_claude_probe_cache_check_hit() {
  local key="$1" ttl="$2" record probed_at now delta
  record="$SKILL_DIR/run/claude-probe-ok/$key"
  [ -f "$record" ] && [ ! -L "$record" ] || return 1
  probed_at="$(sed -n 's/^probed_at=//p' "$record" 2>/dev/null | head -1)"
  case "$probed_at" in ''|*[!0-9]*) return 1 ;; esac
  [ "${#probed_at}" -le 18 ] || return 1
  now="$(date +%s 2>/dev/null)" || return 1
  case "$now" in ''|*[!0-9]*) return 1 ;; esac
  delta=$((now - probed_at))
  [ "$delta" -ge 0 ] && [ "$delta" -le "$ttl" ]
}

# Called right after agmsg_claude_probe_complete succeeds (design section 4).
# A write failure must never fail the spawn; the caller ignores this
# function's return status and just leaves the next spawn to miss again.
agmsg_claude_probe_cache_write() {
  local key="$1" layout="$2" version_output="$3"
  local dir="$SKILL_DIR/run/claude-probe-ok" record tmp now
  [ -n "$key" ] || return 1
  mkdir -p "$dir" 2>/dev/null || return 1
  now="$(date +%s 2>/dev/null)" || return 1
  record="$dir/$key"
  tmp="$record.tmp.$$"
  {
    printf 'version=%s\n' "$version_output"
    printf 'layout=%s\n' "$layout"
    printf 'probed_at=%s\n' "$now"
  } > "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null || true; return 1; }
  mv "$tmp" "$record" 2>/dev/null || { rm -f "$tmp" 2>/dev/null || true; return 1; }
}

# Called when a probe attempt ultimately fails, so a still-fresh record never
# outlives the environment it certified (design section 4). unlink first,
# truncate as a fallback (a truncated record's empty probed_at is a miss on
# its own), and only warn if both fail.
agmsg_claude_probe_cache_forget() {
  local key="$1" record
  [ -n "$key" ] || return 0
  record="$SKILL_DIR/run/claude-probe-ok/$key"
  [ -e "$record" ] || [ -L "$record" ] || return 0
  rm -f "$record" 2>/dev/null && return 0
  : > "$record" 2>/dev/null && return 0
  echo "spawn: could not remove or truncate stale Claude probe cache record $record" >&2
  return 1
}

# When the cache key itself cannot be computed, a failed live probe still
# must not leave a recoverable success record (the same environment may
# become keyable again once the transient read failure clears). Extra misses
# across other keys in this dir are accepted; a false hit is not.
#
# Do not enumerate children: an execute-only directory is traversable by a
# known name (so check_hit can still read $dir/$key) but `"$dir"/*` does not
# expand. Replace the directory instead.
agmsg_claude_probe_cache_forget_all() {
  local dir="$SKILL_DIR/run/claude-probe-ok" stale
  [ -e "$dir" ] || [ -L "$dir" ] || return 0
  stale="$dir.forgotten.$$"
  if mv "$dir" "$stale" 2>/dev/null; then
    mkdir -p "$dir" 2>/dev/null || true
    rm -rf "$stale" 2>/dev/null || true
    return 0
  fi
  echo "spawn: could not replace Claude probe cache directory $dir" >&2
  return 1
}
