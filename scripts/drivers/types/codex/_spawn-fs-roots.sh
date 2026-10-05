#!/usr/bin/env bash
# codex spawn plug: reviewer execpolicy-home roots and extra filesystem read/write roots.
# Sourced by _spawn.sh after its libs; do not source standalone.

# Canonical root of per-launch reviewer CODEX_HOME directories under SKILL_DIR.
agmsg_reviewer_execpolicy_home_root() {
  local private_home="$SKILL_DIR/reviewer-codex-home"
  if [ -d "$private_home" ]; then
    (cd "$private_home" && pwd -P)
  else
    printf '%s/reviewer-codex-home' "$(cd "$SKILL_DIR" && pwd -P)"
  fi
}

# True when a filesystem grant for $1 would expose any launch home (existing path,
# not-yet-created path under the tree, or a literal path under SKILL_DIR/...).
agmsg_reviewer_path_conflicts_execpolicy_home() {
  local d="$1" real_ph cand="" prefix suffix="" literal_root="$SKILL_DIR/reviewer-codex-home"
  case "$d" in
    "~") d="$HOME" ;;
    "~/"*) d="$HOME/${d#\~/}" ;;
  esac
  real_ph="$(agmsg_reviewer_execpolicy_home_root)"
  case "$d" in
    "$literal_root"|"$literal_root"/*) return 0 ;;
  esac
  if [ -d "$d" ] || [ -L "$d" ]; then
    cand="$(cd "$d" 2>/dev/null && pwd -P)" || return 1
  else
    prefix="$d"
    while [ "$prefix" != "/" ] && [ ! -e "$prefix" ] && [ ! -L "$prefix" ]; do
      suffix="/$(basename "$prefix")$suffix"
      prefix="$(dirname "$prefix")"
    done
    if [ -e "$prefix" ] || [ -L "$prefix" ]; then
      if [ -d "$prefix" ] || [ -L "$prefix" ]; then
        cand="$(cd "$prefix" && pwd -P)$suffix"
      else
        cand="$(cd "$(dirname "$prefix")" && pwd -P)/$(basename "$prefix")$suffix"
      fi
    else
      case "$d" in
        "$real_ph"|"$real_ph"/*) return 0 ;;
      esac
      return 1
    fi
  fi
  case "$cand" in
    "$real_ph"|"$real_ph"/*) return 0 ;;
  esac
  return 1
}

agmsg_reviewer_add_dir_roots() {
  # Wrap the shared harvest: format each collected dir as a codex filesystem-table
  # read entry (`, "<dir>"="read"`) to splice into the reviewer profile body. The
  # harvest's quote/backslash filter keeps the value safe for that splice.
  local d out=""
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    if agmsg_reviewer_path_conflicts_execpolicy_home "$d"; then
      echo "spawn: reviewer add-dir path skipped (execpolicy home tree): $d" >&2
      continue
    fi
    out="$out, \"$d\"=\"read\""
  done < <(agmsg_collect_add_dir_roots "$1" "spawn.codex_inherit_add_dirs")
  printf '%s' "$out"
}

# True when a write-perm extra filesystem root would expose the reviewer's
# read-only repo cwd — equal to it, an ancestor of it, or a descendant of it.
# String comparison of `pwd -P` output: catches ordinary symlink-normalized
# overlap (including "/" below) but not a macOS firmlink alias or a literal
# "//" root. The negative sandbox probe further down is the actual
# enforcement boundary (verified: it still denies a firmlink-aliased write);
# this check is a convenience that turns the ordinary misconfiguration into a
# skip-with-warning instead of that probe's hard refusal. Either realpath
# unresolvable (e.g. the root vanished between the -d check and here) is also
# a conflict: fail closed rather than risk granting write into the repo tree.
agmsg_reviewer_write_root_conflicts_cwd() {
  local root_real="$1" cwd_real="$2"
  [ -n "$root_real" ] && [ -n "$cwd_real" ] || return 0
  # "/" is an ancestor of every absolute path, but the glob below can't say
  # so: "$cwd_real/*" with cwd_real="/" becomes the literal "//*", which
  # requires a doubled leading slash and never matches an ordinary
  # single-slash path like "/tmp". Handle the root filesystem directly
  # rather than fall through to a false "no conflict".
  if [ "$root_real" = "/" ] || [ "$cwd_real" = "/" ]; then
    return 0
  fi
  case "$root_real" in
    "$cwd_real"|"$cwd_real"/*) return 0 ;;
  esac
  case "$cwd_real" in
    "$root_real"|"$root_real"/*) return 0 ;;
  esac
  return 1
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
# The reviewer profile ($3=reviewer) additionally never grants write on a
# root that overlaps its cwd ($4): a global write root configured for the
# implementer/consultant layouts (e.g. the project itself, so codex-impl can
# edit it) must not silently defeat the reviewer's read-only repo guarantee
# when the same config value is reused here. Non-overlapping write roots
# (e.g. a build cache) are kept as-is.
#
# Paths beginning with ~/ or the literal $HOME/ are expanded without eval.
# Because the result is spliced through both a single-quoted -c clause and a
# TOML string, any quote or backslash is fatal rather than emitted unsafely.
agmsg_codex_extra_fs_roots() {
  local _name="$1" mode="${2:-profile}" reviewer_filter="${3:-0}" cwd="${4:-}" value="" remaining="" token="" perm="" path_="" out="" cwd_real="" root_real=""
  case "$mode" in
    profile|runtime-write-roots) ;;
    *) die "spawn: internal error: unknown codex extra filesystem root output mode '$mode'" ;;
  esac
  value="$("$SCRIPT_DIR/config.sh" get "spawn.codex_extra_fs_roots" "" 2>/dev/null || true)"
  [ -n "$value" ] || return 0
  if [ "$reviewer_filter" = reviewer ] && [ -n "$cwd" ]; then
    cwd_real="$(cd "$cwd" 2>/dev/null && pwd -P)" || cwd_real=""
  fi

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
    if [ "$reviewer_filter" = reviewer ]; then
      # codex resolves a relative filesystem-table key against `-C "$cwd"`
      # (the reviewed project), not against this script's own cwd. Resolving
      # it here with plain `cd "$path_"` would judge it against the wrong
      # base and could wrongly clear a write grant that lands inside the
      # repo at apply time. Reject relative roots outright rather than
      # duplicate codex's own resolution — same absolute-only rule already
      # applied to spawn.codex_gh_config_dir.<name>.
      case "$path_" in
        /*) ;;
        *)
          echo "spawn: reviewer extra filesystem root skipped (relative path; ambiguous against \$cwd vs this script's cwd): $path_" >&2
          continue ;;
      esac
      if [ ! -d "$path_" ]; then
        echo "spawn: reviewer extra filesystem root skipped (not an existing directory): $path_" >&2
        continue
      fi
      if agmsg_reviewer_path_conflicts_execpolicy_home "$path_"; then
        echo "spawn: reviewer extra filesystem root skipped (execpolicy home tree): $path_" >&2
        continue
      fi
      if [ "$perm" = "write" ]; then
        root_real="$(cd "$path_" 2>/dev/null && pwd -P)" || root_real=""
        if agmsg_reviewer_write_root_conflicts_cwd "$root_real" "$cwd_real"; then
          echo "spawn: reviewer extra filesystem root skipped (write grant overlaps the reviewer's read-only repo cwd): $path_" >&2
          continue
        fi
      fi
    fi
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
