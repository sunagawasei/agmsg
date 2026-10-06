#!/usr/bin/env bats

@test "CI: a docs-only skip and a passing suite are not the same green (#798)" {
  # The docs-only path reports the bats checks green without running the
  # suite, which is right for the required context and wrong for a reader:
  # #776's green was once put forward as evidence that the base was fine, and
  # that shard had run nothing. What this pins is that the run SAYS which green
  # it is, in three places, and that the required context is not renamed.
  local workflow="$BATS_TEST_DIRNAME/../.github/workflows/tests.yml"
  # 1. The shard job's name carries the marker, keyed on the docs_only output.
  #    Shard checks are not required contexts, so the name may vary.
  grep -Fq "name: bats (\${{ matrix.os }} \${{ matrix.shard }}/5)\${{ needs.changes.outputs.docs_only == 'true' && ' — docs-only, suite skipped' || '' }}" "$workflow"
  # 2. The aggregate -- the required context -- keeps its exact name, once,
  #    unconditionally.
  [ "$(grep -c '^    name: bats$' "$workflow")" -eq 1 ]
  # 3. Both greens are named on the aggregate's own output: the skip as an
  #    annotation and a summary heading, the full pass as a summary heading
  #    that carries the file count.
  grep -Fq '::notice title=bats::docs-only diff — the bats suite did not run on any shard' "$workflow"
  grep -Fq '"## bats: docs-only, suite skipped"' "$workflow"
  grep -Fq '"## bats: suite ran"' "$workflow"
  grep -Fq 'The shards ran $count test files' "$workflow"
  # 4. And on the shard itself, so the checks tab shows it per job.
  grep -Fq '::notice title=bats shard skipped::docs-only diff — this shard ran 0 test files' "$workflow"
}

@test "CI: the #798 pins go red when the marker is taken back out (mutation control)" {
  # A pin that stays green when the thing it pins is removed is not a pin.
  local workflow="$BATS_TEST_DIRNAME/../.github/workflows/tests.yml" mutant="$BATS_TEST_TMPDIR/tests.yml"
  sed "s/ && ' — docs-only, suite skipped' || ''//" "$workflow" > "$mutant"
  # The mutation took: the marker is gone from the copy.
  if grep -Fq "docs-only, suite skipped' || ''" "$mutant"; then false; fi
  # ...and the name pin no longer matches it.
  if grep -Fq "name: bats (\${{ matrix.os }} \${{ matrix.shard }}/5)\${{ needs.changes.outputs.docs_only == 'true' && ' — docs-only, suite skipped' || '' }}" "$mutant"; then false; fi
}

# The suite has to run on the shape that actually gets dogfooded. A PR is only
# ever tested as "this head against the base it was opened on", so when several
# PRs collect on one integration branch, the tip -- all of them together -- is a
# tree no PR run has seen. The push leg on `integration/**` is what covers it.
@test "tests run on integration branches, on both legs" {
  local workflow="$BATS_TEST_DIRNAME/../.github/workflows/tests.yml"

  # Two occurrences: one under push:, one under pull_request:. Asserting the
  # count (not merely "present somewhere") is what makes this fail if only one
  # leg is widened -- the failure mode that leaves the merged shape untested
  # while every summary view still reads green.
  run bash -c "grep -c \"branches: \[main, 'integration/\*\*'\]\" '$workflow'"
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]
}

# Guards the OTHER direction. A group expression alone cannot fail this: swap
# cancel-in-progress to a bare `true` and the group still reads correctly while
# main runs begin cancelling each other -- and a cancelled main run leaves the
# commit a release ships with no verdict at all (#848). So the main arm is
# asserted by name, not inferred from the group.
@test "only main is exempt from cancellation" {
  local workflow="$BATS_TEST_DIRNAME/../.github/workflows/tests.yml"

  run grep -F "cancel-in-progress: \${{ github.event_name == 'pull_request' || github.ref != 'refs/heads/main' }}" "$workflow"
  [ "$status" -eq 0 ]

  # main pushes group by run id, so nothing can ever supersede them.
  run grep -F "github.ref == 'refs/heads/main' && github.run_id" "$workflow"
  [ "$status" -eq 0 ]

  # Every other push groups by ref, so a later merge supersedes an earlier one.
  run grep -F "format('push-{0}', github.ref)" "$workflow"
  [ "$status" -eq 0 ]
}
