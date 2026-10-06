#!/usr/bin/env bash
# Shared filesystem-name encoding for reservation and lock paths.
#
# This helper has no caller-environment requirements so core storage hooks can
# use the same encoding even when SKILL_DIR is unset.
#
# Builtins only: the SessionEnd hook runs this per spawn record inside a ~1.5s
# budget, where an awk fork per name does not fit. The output matches the awk
# implementation this replaced, quirks included (see tests/test_name_encode.bats):
# raw newlines are dropped, decode accepts only two UPPERCASE hex digits after
# '%' and yields nothing otherwise, and %00 yields nothing.

if ! declare -F _actas_lock_encode >/dev/null 2>&1; then
  _actas_lock_encode() {
    local LC_ALL=C s="$1" out="" c i n
    s="${s//$'\n'/}"
    for ((i = 0; i < ${#s}; i++)); do
      c="${s:i:1}"
      case "$c" in
        [A-Za-z0-9._-]) out+="$c" ;;
        # bash 3.2 sign-extends a high byte here; mask it back to 0-255.
        *) printf -v n '%d' "'$c"; printf -v c '%%%02X' "$((n & 255))"; out+="$c" ;;
      esac
    done
    printf '%s' "$out"
  }
fi

if ! declare -F _actas_lock_decode >/dev/null 2>&1; then
  _actas_lock_decode() {
    local LC_ALL=C rec rest hex c out=""
    while IFS= read -r rec || [ -n "$rec" ]; do
      rest="$rec"
      while [[ "$rest" == *%* ]]; do
        out+="${rest%%\%*}"
        rest="${rest#*%}"
        hex="${rest:0:2}"
        rest="${rest:2}"
        case "$hex" in
          [0-9A-F][0-9A-F]) printf -v c "\\x$hex"; out+="$c" ;;
        esac
      done
      out+="$rest"
    done <<<"$1"
    printf '%s' "$out"
  }
fi
