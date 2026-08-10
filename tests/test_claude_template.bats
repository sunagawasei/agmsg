#!/usr/bin/env bats

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TEMPLATE="$ROOT/scripts/drivers/types/claude-code/template.md"
}

@test "Claude template distinguishes sandbox enablement from the write allowlist" {
  grep -Fq 'The allowlist does not enable sandboxing by itself.' "$TEMPLATE"
  grep -Fq '"enabled": true' "$TEMPLATE"
  grep -Fq '`/sandbox`' "$TEMPLATE"
}

@test "Claude template forbids bypassing the scripts with direct SQLite access" {
  grep -Fq 'never construct a database path or invoke `sqlite3` directly' "$TEMPLATE"
}

@test "Claude template tells actas and drop to distinguish 'unrecognized' from deliberate off (#687)" {
  # #684 recovery: a seat read the bare word "off" and reported no delivery
  # as a deliberate configuration, when delivery.sh actually could not find
  # the project. The instructions must not let that repeat by treating
  # "off (unrecognized: ...)" the same as a plain "mode: off" -- both cases
  # appear once for actas and once for drop, so both are checked.
  count=$(grep -c 'mode: off (unrecognized: \.\.\.)' "$TEMPLATE")
  [ "$count" -eq 2 ] || { echo "expected 2 occurrences (actas + drop), found $count" >&2; return 1; }
  grep -Fq 'Do not report `actas` as complete without saying this' "$TEMPLATE"
  grep -Fq 'Do not report the drop as complete without mentioning it' "$TEMPLATE"
}
