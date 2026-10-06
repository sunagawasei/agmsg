#!/usr/bin/env bats
# #83: macOS /usr/bin/awk (BSD awk 20200816) does not decode "\x1f" in
# `awk -v FS="\x1f"`, so US-separated rows were parsed as one field. These
# tests pin the US parser to both awk implementations by absolute path.

load test_helper

US=$'\x1f'


# Run the parser with `awk` resolving to the given binary.
run_parser_with_awk() {
  local awk_bin="$1" row="$2" dir="$BATS_TEST_TMPDIR/bin-$(basename "$(dirname "$awk_bin")")"
  mkdir -p "$dir"
  ln -sf "$awk_bin" "$dir/awk"
  PATH="$dir:$PATH" run bash -c '
    source "$1/scripts/lib/validate.sh"
    agmsg_parse_machine_inbox_row "$2"
  ' _ "$BATS_TEST_DIRNAME/.." "$row"
}

check_parser() {
  local awk_bin="$1"
  run_parser_with_awk "$awk_bin" "id1${US}alice${US}hello${US}2026-01-01"
  [ "$status" -eq 0 ]
  [ "$output" = $'id1\nalice\nhello\n2026-01-01' ]

  # body keeps the US it contains
  run_parser_with_awk "$awk_bin" "id2${US}bob${US}a${US}b${US}ts2"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'id2\nbob\na%sb\nts2' "$US")" ]

  # empty body, and consecutive US inside the body
  run_parser_with_awk "$awk_bin" "id3${US}carol${US}${US}ts3"
  [ "$status" -eq 0 ]
  [ "$output" = $'id3\ncarol\n\nts3' ]
  run_parser_with_awk "$awk_bin" "id4${US}dave${US}x${US}${US}y${US}ts4"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'id4\ndave\nx%s%sy\nts4' "$US" "$US")" ]

  # literal backslash sequences in the body are not decoded
  run_parser_with_awk "$awk_bin" "id5${US}erin${US}a\\tb\\nc${US}ts5"
  [ "$status" -eq 0 ]
  [ "$output" = 'id5
erin
a\tb\nc
ts5' ]

  # fewer than four fields is rejected
  run_parser_with_awk "$awk_bin" "id6${US}frank${US}only3"
  [ "$status" -eq 1 ]
}

@test "machine inbox row parses identically under BSD awk (/usr/bin/awk)" {
  [ -x /usr/bin/awk ] || skip "no /usr/bin/awk"
  check_parser /usr/bin/awk
}

@test "machine inbox row parses identically under GNU awk" {
  local gawk_bin
  gawk_bin="$(command -v gawk)" || skip "gawk not installed"
  check_parser "$gawk_bin"
}

# Guard scope: scripts/ only, awk lines that hand a "\x.." escape to -F or to a
# -v FS/OFS/RS/ORS assignment. BSD awk leaves "\x" undecoded there; pass a real
# byte (-F "$US") or an octal escape ('\037') instead. awk-program-internal
# escapes such as "\t" are not matched.
GUARD_RE='awk.*(-F *["'"'"']?\\x|-v *(FS|OFS|RS|ORS)=["'"'"']?\\x)'

@test "guard regex matches the BSD-awk-unsafe forms" {
  local l
  for l in 'awk -v FS="\x1f" x' "awk -v FS='\\x1f' x" 'awk -F"\x1f" x' 'awk -F "\x1f" x' 'awk -v RS="\x1e" x' 'awk -v OFS="\x1f" x' 'awk -v ORS="\x1e" x'; do
    printf '%s\n' "$l" | grep -qE -- "$GUARD_RE" || { echo "not matched: $l"; return 1; }
  done
}

@test "guard regex leaves the portable forms alone" {
  local l
  for l in 'awk -F"$US" x' "awk -F'\\037' x" "awk -v FS='\\037' x" 'awk -F"\t" x' "awk '{ gsub(/\\t/, \"\\t\") }'"; do
    if printf '%s\n' "$l" | grep -qE -- "$GUARD_RE"; then echo "matched: $l"; return 1; fi
  done
}

@test "scripts/ passes no \\x escape to awk -F or -v FS/OFS/RS/ORS" {
  run git -C "$BATS_TEST_DIRNAME/.." grep -nE -- "$GUARD_RE" -- scripts
  [ "$status" -eq 1 ]
}
