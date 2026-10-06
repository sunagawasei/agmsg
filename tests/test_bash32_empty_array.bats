#!/usr/bin/env bats

# bash 3.2 (macOS /bin/bash) aborts under `set -u` when a bare "${a[@]}" expands
# an empty array, and bash 5 does not, so a developer shell never sees it (#69).
# Every such expansion in scripts/ must either use ${a[@]+"${a[@]}"} or be listed
# in tests/fixtures/bash32-nonempty-arrays.txt with the reason it is never empty.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
ALLOWLIST="$REPO_ROOT/tests/fixtures/bash32-nonempty-arrays.txt"

# Prints "<path>|<array>" for each bare array expansion outside comments.
# perl, not sed: BSD sed (macOS /usr/bin/sed) does not match a backreference in
# the pattern, so it cannot strip the guarded ${a[@]+"${a[@]}"} form.
bare_array_expansions() {
  local f
  cd "$REPO_ROOT"
  find scripts -name '*.sh' | LC_ALL=C sort | while IFS= read -r f; do
    perl -ne '
      next if /^\s*#/;
      s/\$\{(\w+)\[[@*]\]\+"\$\{\1\[[@*]\]\}"\}//g;
      $seen{$1} = 1 while /\$\{([A-Za-z_]\w*)\[[@*]\]\}/g;
      END { print "$ARGV|$_\n" for sort keys %seen }
    ' "$f"
  done | LC_ALL=C sort -u
}

allowlisted() {
  grep -vE '^[[:space:]]*(#|$)' "$ALLOWLIST" | cut -d'|' -f1,2 | LC_ALL=C sort -u
}

@test "bare array expansions are all listed as never empty" {
  local unlisted
  unlisted="$(comm -23 <(bare_array_expansions) <(allowlisted))"
  if [ -n "$unlisted" ]; then
    echo "bare \"\${a[@]}\" under set -u aborts on bash 3.2 when a is empty;" >&2
    echo "use \${a[@]+\"\${a[@]}\"} or list it in tests/fixtures/bash32-nonempty-arrays.txt:" >&2
    echo "$unlisted" >&2
  fi
  [ -z "$unlisted" ]
}

@test "allowlist has no entry without a bare array expansion" {
  local stale
  stale="$(comm -13 <(bare_array_expansions) <(allowlisted))"
  if [ -n "$stale" ]; then
    echo "stale entries in tests/fixtures/bash32-nonempty-arrays.txt:" >&2
    echo "$stale" >&2
  fi
  [ -z "$stale" ]
}

@test "team-list.sh runs under /bin/bash with no truncation flag" {
  [ -x /bin/bash ] || skip "no /bin/bash"
  command -v python3 >/dev/null 2>&1 || skip "python3 is required"
  # truncated_flag stays empty unless the team list was cut off.
  cd "$BATS_TEST_TMPDIR"
  mkdir -p teams
  run env HOME="$BATS_TEST_TMPDIR" /bin/bash "$REPO_ROOT/scripts/team-list.sh"
  case "$output" in
    *"unbound variable"*) echo "$output" >&2; return 1 ;;
  esac
  [ "$status" -eq 0 ]
}
