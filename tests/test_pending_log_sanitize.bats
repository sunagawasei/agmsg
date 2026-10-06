#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
  export SKILL_DIR="$TEST_SKILL_DIR"
  # shellcheck disable=SC1091
  source "$SCRIPTS/lib/pending-teardown.sh"
}

teardown() {
  teardown_test_env
}

# The filter as it was before the no-fork fast path: the whole contract.
_sanitize_reference() {
  local val
  val="$(printf '%s' "${1:-}" | LC_ALL=C tr -d '\000-\037\177')"
  if [ "${#val}" -gt 80 ]; then
    printf '%s...' "${val:0:77}"
  else
    printf '%s' "$val"
  fi
}

# Both outputs end in an x so a trailing newline would show up as a difference.
_same_as_reference() {
  [ "$(agmsg_pending_log_sanitize "$1"; echo x)" = "$(_sanitize_reference "$1"; echo x)" ]
}

# Every non-NUL byte alone, between ASCII, after a split UTF-8 sequence and
# around the 80-character cut (NUL cannot be a bash argument).
_check_all_bytes() {
  local i hex b filler78 filler80
  filler78="$(printf 'x%.0s' $(seq 1 78))"
  filler80="$(printf 'x%.0s' $(seq 1 80))"
  for i in $(seq 1 255); do
    hex="$(printf '%02x' "$i")"
    # printf -v: $(...) would drop a trailing newline byte (0x0a) from b
    printf -v b "\\x$hex"
    _same_as_reference "$b" || { echo "byte 0x$hex"; return 1; }
    _same_as_reference "a${b}b" || { echo "between 0x$hex"; return 1; }
    _same_as_reference "日本${b}語" || { echo "multibyte 0x$hex"; return 1; }
    _same_as_reference "$(printf '\xe6\x97')${b}" || { echo "split 0x$hex"; return 1; }
    _same_as_reference "${filler78}${b}z" || { echo "cut 78 0x$hex"; return 1; }
    _same_as_reference "${filler80}${b}" || { echo "cut 80 0x$hex"; return 1; }
  done
}

@test "log sanitize: every byte value is filtered as the original tr did (C locale)" {
  LC_ALL=C run _check_all_bytes
  [ "$status" -eq 0 ]
}

@test "log sanitize: every byte value is filtered as the original tr did (UTF-8 locale)" {
  local loc
  loc="$(locale -a 2>/dev/null | grep -i -m1 'utf-\?8' || true)"
  [ -n "$loc" ] || skip "no UTF-8 locale installed"
  LC_ALL="$loc" run _check_all_bytes
  [ "$status" -eq 0 ]
}

@test "log sanitize: lengths around the 80 character cut match the original" {
  local len
  for len in 0 1 76 77 78 79 80 81 82 200; do
    _same_as_reference "$(printf 'y%.0s' $(seq 1 "$len") 2>/dev/null)"
    _same_as_reference "$(printf '日%.0s' $(seq 1 "$len") 2>/dev/null)"
  done
}

@test "log sanitize: matches the original under bash 3.2 as well" {
  [ -x /bin/bash ] || skip "no /bin/bash"
  case "$(/bin/bash -c 'echo "$BASH_VERSION"')" in 3.*) ;; *) skip "/bin/bash is not 3.x" ;; esac
  run /bin/bash -c '
    SKILL_DIR="$1"; . "$1/scripts/lib/pending-teardown.sh"
    ref() { local v; v="$(printf "%s" "${1:-}" | LC_ALL=C tr -d "\000-\037\177")"
      if [ "${#v}" -gt 80 ]; then printf "%s..." "${v:0:77}"; else printf "%s" "$v"; fi; }
    for i in $(seq 1 255); do
      printf -v b "\\x$(printf %02x "$i")"
      for s in "$b" "a${b}b" "日本${b}語"; do
        [ "$(agmsg_pending_log_sanitize "$s"; echo x)" = "$(ref "$s"; echo x)" ] || { echo "mismatch 0x$(printf %02x "$i")"; exit 1; }
      done
    done' _ "$TEST_SKILL_DIR"
  [ "$status" -eq 0 ]
}

@test "log sanitize: the common input starts no external command" {
  tr() { echo tr-called >&2; command tr "$@"; }
  run agmsg_pending_log_sanitize "s-0123-abc"
  [ "$status" -eq 0 ]
  [ "$output" = "s-0123-abc" ]
}

@test "log sanitize: a line feed and a carriage return are removed, not kept" {
  local lf cr
  printf -v lf '\n'
  printf -v cr '\r'
  [ "${#lf}" -eq 1 ]
  [ "$(agmsg_pending_log_sanitize "a${lf}b${cr}c"; echo x)" = "abcx" ]
}
