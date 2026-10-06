#!/usr/bin/env bash
#
# Deterministically partition the bats suite into shards, and print the test
# files belonging to one of them (one path per line).
#
#   .github/scripts/shard-tests.sh <index> <total> [tests-dir]
#
# The partition is computed from the tree itself, not from a list someone has
# to remember to update. That is the point: with a hand-maintained matrix, a
# newly added test file lands in no shard at all and simply never runs — a
# green CI that silently stopped testing something. Here every `*.bats` file in
# the directory is assigned to exactly one shard, so the union of all shards is
# always the whole suite (asserted by tests/test_ci_sharding.bats).
#
# Balancing is greedy longest-processing-time first, weighted by measured
# seconds per file from bats-weights.tsv (next to this script), not by @test
# count: per-test cost varies from ~0s to ~8s depending on how much a file forks
# or waits, so counts mispredict by a wide margin. Seconds differ by OS (a file
# can be 10x slower on macOS, or the other way round), so the table has one
# column per OS and the shard split is computed for the runner's OS: SHARD_OS,
# else RUNNER_OS (set by GitHub Actions). With neither set (local runs) the two
# columns are summed. The table goes stale as the suite changes; its header
# says how to re-measure it.
#
# A file missing from the table (a new test file) weighs its @test count times
# the table's *per-test seconds, so it is still spread rather than ignored.
# The floor either way is the slowest single file: no split beats that.
#
# Whatever the weights, the property that matters is coverage, not balance: the
# worst case of a bad weight is an unevenly filled shard, never a missing file.
set -euo pipefail

usage() {
  echo "usage: ${0##*/} <shard-index> <shard-total> [tests-dir]" >&2
  echo "  shard-index is 1-based and must be <= shard-total" >&2
  exit 2
}

[ "$#" -ge 2 ] || usage
index="$1"
total="$2"
dir="${3:-tests}"

case "$index" in ''|*[!0-9]*) usage ;; esac
case "$total" in ''|*[!0-9]*) usage ;; esac
[ "$total" -ge 1 ] || usage
[ "$index" -ge 1 ] || usage
[ "$index" -le "$total" ] || usage
[ -d "$dir" ] || { echo "${0##*/}: no such directory: $dir" >&2; exit 1; }

# LC_ALL=C keeps the enumeration order identical across the GNU and BSD
# userlands the suite already runs on, so a given tree always produces the same
# partition regardless of which runner computes it.
files="$(find "$dir" -maxdepth 1 -name '*.bats' | LC_ALL=C sort)"
[ -n "$files" ] || { echo "${0##*/}: no .bats files under $dir" >&2; exit 1; }

# The weight table: `file<TAB>macOS seconds<TAB>Linux seconds`, `#` comments,
# and a `*per-test` row (seconds per @test for a file not listed). Seconds are
# canonical non-negative integers: the LPT below is shell arithmetic, where 1.5
# is an error and 08 is read as octal. A malformed table is a hard error rather
# than a quietly different partition; an absent table falls back to the built-in
# per-test seconds with a warning.
os_name="${SHARD_OS:-${RUNNER_OS:-}}"
weights="${SHARD_WEIGHTS:-$(dirname "$0")/bats-weights.tsv}"
if [ -f "$weights" ]; then
  table="$weights"
else
  echo "${0##*/}: no weight table at $weights; weighting by @test count only" >&2
  table=/dev/null
fi

# First output line is `#per-test<TAB>seconds`; the rest are `seconds<TAB>path`,
# with `-` for a file the table does not list.
resolved="$(printf '%s\n' "$files" | awk -F'\t' -v os="$os_name" -v table="$table" '
  function fail(msg) { print "shard-tests.sh: " table ":" FNR ": " msg > "/dev/stderr"; exit 1 }
  function whole(x) { return x ~ /^(0|[1-9][0-9]*)$/ }
  function pick(m, l) { return os == "macOS" ? m : os == "Linux" ? l : m + l }
  BEGIN { per_test = pick(2, 2) }
  FILENAME == ARGV[1] {
    if ($0 ~ /^[ \t]*(#|$)/) next
    if (NF != 3) fail("expected 3 tab-separated columns")
    if (!whole($2) || !whole($3)) fail("seconds must be non-negative integers")
    if ($1 in seen) fail("duplicate row for " $1)
    seen[$1] = 1
    if ($1 == "*per-test") per_test = pick($2 + 0, $3 + 0)
    else w[$1] = pick($2 + 0, $3 + 0)
    next
  }
  FNR == 1 { print "#per-test\t" per_test }
  {
    n = $0; sub(/.*\//, "", n)
    print (n in w ? w[n] : "-") "\t" $0
  }
' "$table" -
)" || exit 1

per_test="${resolved%%$'\n'*}"
per_test="${per_test#*$'\t'}"
resolved="${resolved#*$'\n'}"

# Weight each file; a file the table does not list gets its @test count times
# the per-test seconds. `grep -c` exits 1 on no match after printing 0, which
# set -e would otherwise treat as fatal.
file_tests() {
  local n
  n="$(grep -c '^[[:space:]]*@test' "$1" || true)"
  [ -n "$n" ] || n=0
  printf '%s' "$n"
}

i=0
while [ "$i" -lt "$total" ]; do
  load[i]=0
  i=$((i + 1))
done

weighted=""
while IFS='	' read -r w f; do
  [ -n "$f" ] || continue
  if [ "$w" = - ]; then
    w=$(( $(file_tests "$f") * per_test ))
  fi
  weighted="${weighted}${w}	${f}
"
done <<EOF
$resolved
EOF

# Heaviest first; ties broken by path so the order is total, not incidental.
sorted="$(printf '%s' "$weighted" | LC_ALL=C sort -t'	' -k1,1nr -k2,2)"

# Greedy LPT: hand each file to the currently lightest shard.
while IFS='	' read -r n f; do
  [ -n "$f" ] || continue
  best=0
  best_load=${load[0]}
  j=1
  while [ "$j" -lt "$total" ]; do
    if [ "${load[j]}" -lt "$best_load" ]; then
      best=$j
      best_load=${load[j]}
    fi
    j=$((j + 1))
  done
  load[best]=$((best_load + n))
  # An `if`, not `[ ... ] && printf`: a false test as the loop's last command
  # becomes the script's exit status, so the caller would see failure or
  # success depending on nothing but whether the final file happened to land
  # in the requested shard.
  if [ "$best" -eq "$((index - 1))" ]; then
    printf '%s\n' "$f"
  fi
done <<EOF
$sorted
EOF

exit 0
