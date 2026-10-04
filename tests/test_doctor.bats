#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
  export AGMSG_AGENT_PID=""
  export PROJ="$(mktemp -d)"
  bash "$SCRIPTS/join.sh" team alice claude-code "$PROJ" >/dev/null
}

teardown() {
  teardown_test_env
  rm -rf "$PROJ"
}

# --- default scope: no filters = the whole installation -------------------
#     (koit's round-2 call: other doctor-style commands -- claude/codex/brew/
#     flutter -- all default to "everything", so this one now does too. The
#     old <project> <type>-required positional form is dropped, not kept for
#     compatibility -- see doctor.sh's header comment.) ----------------------

@test "doctor: no arguments defaults to the whole installation, not a usage error" {
  local other_proj="$(mktemp -d)"
  bash "$SCRIPTS/join.sh" other bob claude-code "$other_proj" >/dev/null

  run bash "$SCRIPTS/doctor.sh"
  [ "$status" -eq 0 ]
  # Both projects are represented (as their raw paths -- both pairs here have
  # nothing held and collapse to one line each, which shows the project path
  # but not the team/agent names; see the "nothing to report" tests below).
  [[ "$output" == *"$PROJ"* ]]
  [[ "$output" == *"$other_proj"* ]]

  rm -rf "$other_proj"
}

@test "doctor: a genuinely empty installation (no filters, zero registrations anywhere) is a clean 0/0/0, not a usage error" {
  # setup() always creates one registration; leave it so this test starts
  # from a truly empty installation (leave.sh also removes the now-empty
  # team). An explicit --project/--type/--team matching nothing is still a
  # usage error (exit 2, unchanged) -- only the no-filter default-scope case
  # changes, since a whole-install scan that finds nothing is a VALID result,
  # not a mistake the way a typo'd explicit filter would be.
  bash "$SCRIPTS/leave.sh" team alice >/dev/null

  run bash "$SCRIPTS/doctor.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == "0 team(s), 0 registration(s), 0 warning(s)"* ]]
  [[ "$output" == *"no warnings."* ]]
}

@test "doctor: an explicit --project matching nothing is still a usage error (exit 2), unlike the no-filter empty case" {
  run bash "$SCRIPTS/doctor.sh" --project "$(mktemp -d)"
  [ "$status" -eq 2 ]
  [[ "$output" == *"no registrations match this scope"* ]]
}

@test "doctor: a positional argument (the dropped <project> <type> form) is a usage error, not silently accepted" {
  run bash "$SCRIPTS/doctor.sh" "$PROJ" claude-code
  [ "$status" -eq 2 ]
  [[ "$output" == *"unexpected argument"* ]]
}

@test "doctor: --project alone shows every type registered for that project" {
  bash "$SCRIPTS/join.sh" team alice codex "$PROJ" >/dev/null

  run bash "$SCRIPTS/doctor.sh" --project "$PROJ"
  [ "$status" -eq 0 ]
  # Format-agnostic (full block or the "nothing to report" one-liner --
  # claude-code has nothing held so collapses, codex's own bridge status
  # line means it never does) -- both types are represented either way.
  [[ "$output" == *"claude-code"* ]]
  [[ "$output" == *"codex"* ]]
}

@test "doctor: bare --help exits 0 and prints usage, even with no other arguments" {
  run bash "$SCRIPTS/doctor.sh" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: doctor.sh"* ]]
}

@test "doctor: an unknown option is a usage error (exit 2)" {
  run bash "$SCRIPTS/doctor.sh" --project "$PROJ" --type claude-code --nonsense
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown option"* ]]
}

@test "doctor: an unknown --type is a usage error (exit 2), not a silent clean report" {
  run bash "$SCRIPTS/doctor.sh" --project "$PROJ" --type not-a-real-type
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown agent type"* ]]
  # Must not fall through to delivery.sh/identities.sh and report clean.
  [[ "$output" != *"no warnings."* ]]
}

@test "doctor: an unknown --team is a usage error (exit 2)" {
  run bash "$SCRIPTS/doctor.sh" --team not-a-real-team
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown team"* ]]
}

@test "doctor: --team is rejected as a path-traversal attempt even when it resolves to a real config-shaped file outside teams/" {
  # --team becomes a path segment (teams/$FILTER_TEAM/config.json). Without
  # running it through the existing agmsg_validate_team_name first, a value
  # containing ".." could resolve OUTSIDE teams/ entirely -- and if a
  # config-shaped file happens to exist there, the plain existence check
  # this file used before would have accepted it. Proves the rejection is
  # the validator firing, not an incidental "file doesn't exist": the
  # traversal target is made to exist first.
  mkdir -p "$TEST_SKILL_DIR/evil"
  printf '{"name": "evil", "agents": {}}' > "$TEST_SKILL_DIR/evil/config.json"

  run bash "$SCRIPTS/doctor.sh" --team "../evil"
  [ "$status" -eq 2 ]
  [[ "$output" == *"path traversal"* ]]
}

# --- BLOCKING fix: a type with no real delivery (delivery_modes is nothing
#     but "off" -- agmsg-app is the desktop app's own identity, which owns
#     its own send/receive UI) must never be queried against delivery.sh, and
#     must never turn into a warning. Running the pre-fix version against a
#     healthy real installation returned "9 team(s), 56 registration(s), 5
#     warning(s)" purely from this -- an exit-code-contract violation caught
#     by koit running doctor against real data, not by any of these fixtures,
#     which is exactly why real-data verification was asked for. -----------

@test "doctor: a type with delivery_modes=off only is never queried against delivery.sh and never warns" {
  bash "$SCRIPTS/join.sh" team carol agmsg-app "$PROJ" >/dev/null

  run bash "$SCRIPTS/doctor.sh" --project "$PROJ" --type agmsg-app
  [ "$status" -eq 0 ]
  [[ "$output" == *"no warnings."* ]]
  [[ "$output" != *"delivery.sh status exited"* ]]
}

@test "doctor: an installation with only no-delivery-type registrations is entirely clean (exit 0, 0 warnings)" {
  local app_proj="$(mktemp -d)"
  bash "$SCRIPTS/join.sh" team you agmsg-app "$app_proj" >/dev/null

  run bash "$SCRIPTS/doctor.sh" --project "$app_proj"
  [ "$status" -eq 0 ]
  [[ "$output" == "1 team(s), 1 registration(s), 0 warning(s)"* ]]
  [[ "$output" == *"no warnings."* ]]

  rm -rf "$app_proj"
}

# --- the "watch processes: N alive, M stale pidfiles" line default runtime
#     status emits scans the WHOLE run/ directory -- an installation-wide
#     fact, not a (project, type) fact. Printing it inside every group that
#     uses default runtime status repeats the identical line once per group;
#     tl2 flagged this as duplication on the same real-installation run. ---

@test "doctor: the install-wide 'watch processes' line appears once, not once per group" {
  # The line only appears when run/ exists (default runtime status guards
  # on it); both pairs below use claude-code, which has real delivery, so
  # each independently calls delivery.sh status and would each emit its own
  # copy of this line pre-fix.
  mkdir -p "$TEST_SKILL_DIR/run"
  local other_proj="$(mktemp -d)"
  bash "$SCRIPTS/join.sh" other bob claude-code "$other_proj" >/dev/null

  run bash "$SCRIPTS/doctor.sh"
  [ "$status" -eq 0 ]
  local line_count
  line_count="$(printf '%s\n' "$output" | grep -c '^watch processes: ')"
  [ "$line_count" -eq 1 ]

  rm -rf "$other_proj"
}

@test "doctor: a stale watch pidfile is still detected when every registration is codex or a no-delivery type" {
  # codex overrides runtime status with its own per-role bridge lines instead
  # of the default "watch processes: ..." line; a no-delivery type skips
  # calling delivery.sh at all. An earlier version captured the global line
  # opportunistically from whichever pair's own delivery.sh call happened to
  # emit it -- on an installation whose registrations are ALL one of these
  # two shapes, that line (and the stale-pidfile warning derived from it)
  # never appeared AT ALL, not just once instead of per-group. Regression for
  # the fix: capture it independently, once, regardless of what's in scope.
  bash "$SCRIPTS/leave.sh" team alice >/dev/null
  bash "$SCRIPTS/join.sh" team alice codex "$PROJ" >/dev/null
  mkdir -p "$TEST_SKILL_DIR/run"
  ( exit 0 ) & local deadpid=$!
  wait "$deadpid" 2>/dev/null || true
  printf '%s\n' "$deadpid" > "$TEST_SKILL_DIR/run/watch.faketoken.pid"

  run bash "$SCRIPTS/doctor.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"watch processes: 0 alive, 1 stale pidfiles"* ]]
  [[ "$output" == *"watcher pidfile present but process not running, installation-wide"* ]]
}

# A project whose settings file is READABLE and installs no agmsg hooks. That is
# a genuine `off`: the configuration was consulted and says delivery is not set
# up. Without this, a bare mktemp project has no settings file at all, and
# `delivery.sh` reports `off (unrecognized: no settings file found …)` -- which
# is a statement about what this check could not determine, not about the
# configuration, and is deliberately NOT collapsed.
configured_off() {
  mkdir -p "$1/.claude"
  printf '%s\n' '{"hooks":{}}' > "$1/.claude/settings.local.json"
}

@test "doctor: exits 0 and reports no warnings when nothing is registered as locked" {
  configured_off "$PROJ"
  run bash "$SCRIPTS/doctor.sh" --project "$PROJ" --type claude-code
  [ "$status" -eq 0 ]
  [[ "$output" == *"no warnings."* ]]
  # Nothing held, nothing configured -- collapses to the one-line "nothing
  # to report" form rather than a 6-line block naming lock=none per row.
  [[ "$output" == *"$PROJ  [claude-code]  1 registration, nothing to report"* ]]
  # The collapsed line keeps the settings file it consulted. Five lines become
  # one, but the four that go are the mode and three "entries: 0" -- the path is
  # the only one answering a different question: WHICH file was read. Without it
  # the line cannot be told apart from the case where nothing was read at all,
  # which is the distinction the unrecognized case exists to preserve.
  printf '%s\n' "$output" | grep -q -F -- "nothing to report — $PROJ/.claude/settings.local.json"
}

# --- readability: a (project, type) pair with nothing held, no warnings, and
#     no delivery worth mentioning collapses to one line instead of a full
#     block. A real installation had 27 such groups, each spending 6 lines to
#     say "nothing here" -- unreadable at real scale even before the
#     BLOCKING exit-code fix below stopped some of them being warnings. ------

@test "doctor: a project it could not read is not called 'nothing to report'" {
  # `off` and `off (unrecognized: …)` are different claims. The first is about
  # the configuration; the second is about this check, which could not find the
  # settings file. Collapsing the second tells the operator delivery is off when
  # what happened is that we could not tell -- and hides the one line that
  # explains an empty inbox ("this project may not be registered").
  #
  # $PROJ deliberately has NO settings file here.
  run bash "$SCRIPTS/doctor.sh" --project "$PROJ" --type claude-code
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q -F -- "unrecognized"
  printf '%s\n' "$output" | grep -q -F -- "may not be registered"
  refute grep -qF -- "nothing to report" <<<"$output"
}

@test "doctor: a boring (project, type) pair -- no lock, no warning, mode off -- collapses to one line" {
  configured_off "$PROJ"
  run bash "$SCRIPTS/doctor.sh" --project "$PROJ" --type claude-code
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to report"* ]]
  [[ "$output" != *"lock=none"* ]]
  [[ "$output" != *"project: $PROJ"* ]]
}

@test "doctor: a boring pair with more than one registration still collapses, with the plural noun and correct count" {
  configured_off "$PROJ"
  bash "$SCRIPTS/join.sh" team bob claude-code "$PROJ" >/dev/null

  run bash "$SCRIPTS/doctor.sh" --project "$PROJ" --type claude-code
  [ "$status" -eq 0 ]
  [[ "$output" == *"$PROJ  [claude-code]  2 registrations, nothing to report"* ]]
}

@test "doctor: the collapsed one-line form is still redacted under --redacted" {
  configured_off "$PROJ"
  case "$PROJ" in
    "$HOME"*) skip "fixture \$PROJ landed under \$HOME this run; this test needs it outside" ;;
  esac

  run bash "$SCRIPTS/doctor.sh" --project "$PROJ" --type claude-code --redacted
  [ "$status" -eq 0 ]
  [[ "$output" == *"<project1>  [claude-code]  1 registration, nothing to report"* ]]
  [[ "$output" != *"$PROJ"* ]]
}

@test "doctor: an explicitly configured mode (not off) is never collapsed, even with nothing held" {
  bash "$SCRIPTS/delivery.sh" set monitor claude-code "$PROJ" >/dev/null

  run bash "$SCRIPTS/doctor.sh" --project "$PROJ" --type claude-code
  [ "$status" -eq 0 ]
  [[ "$output" != *"nothing to report"* ]]
  [[ "$output" == *"mode: monitor"* ]]
}

@test "doctor: exits non-zero and names a stale lock (composite owner, dead pid, no cc-instance)" {
  mkdir -p "$TEST_SKILL_DIR/run"
  printf '%s\n' "deadtoken.999999" > "$TEST_SKILL_DIR/run/actas.team__alice.session"

  run bash "$SCRIPTS/doctor.sh" --project "$PROJ" --type claude-code
  [ "$status" -eq 1 ]
  [[ "$output" == *"stale lock: team/alice"* ]]
  [[ "$output" == *"cc-instance=absent"* ]]
}

@test "doctor: a live lock with a confirming cc-instance record and a running watcher is not a warning" {
  mkdir -p "$TEST_SKILL_DIR/run"
  local owner="livetoken.$$"
  printf '%s\n' "$owner" > "$TEST_SKILL_DIR/run/actas.team__alice.session"
  printf '%s\n' "$owner" > "$TEST_SKILL_DIR/run/cc-instance.$$"
  # watch.sh's pidfile is keyed on the same token actas-claim.sh records as
  # the lock owner -- see doctor.sh's comment on TYPE_HAS_ROLE_RUNTIME.
  printf '%s\n' "$$" > "$TEST_SKILL_DIR/run/watch.$owner.pid"

  run bash "$SCRIPTS/doctor.sh" --project "$PROJ" --type claude-code
  [ "$status" -eq 0 ]
  # Plain output shows the owner token in FULL -- shortening only applies
  # under --redacted (see doctor.sh's comment on _redact_owner: #605 was
  # resolved by matching this exact value against a bridge log line).
  [[ "$output" == *"lock=owner(alive)=$owner cc-instance=present watcher=running"* ]]
  [[ "$output" == *"no warnings."* ]]
}

@test "doctor: an alive lock with no watcher pidfile is a warning (claims exclusivity, not receiving)" {
  mkdir -p "$TEST_SKILL_DIR/run"
  local owner="livetoken.$$"
  printf '%s\n' "$owner" > "$TEST_SKILL_DIR/run/actas.team__alice.session"
  printf '%s\n' "$owner" > "$TEST_SKILL_DIR/run/cc-instance.$$"
  # No watch.<owner>.pid: the lock is legitimately live, but nothing is
  # watching for it -- exclusivity claimed, nothing receiving. #605's report
  # was exactly this shape.

  run bash "$SCRIPTS/doctor.sh" --project "$PROJ" --type claude-code
  [ "$status" -eq 1 ]
  [[ "$output" == *"lock=owner(alive)=$owner cc-instance=present watcher=none"* ]]
  [[ "$output" == *"actas lock held but no watcher: team/alice"* ]]
}

@test "doctor: a stale lock with no watcher does not double-warn about the missing watcher" {
  mkdir -p "$TEST_SKILL_DIR/run"
  printf '%s\n' "deadtoken.999999" > "$TEST_SKILL_DIR/run/actas.team__alice.session"

  run bash "$SCRIPTS/doctor.sh" --project "$PROJ" --type claude-code
  [ "$status" -eq 1 ]
  [[ "$output" == *"stale lock: team/alice"* ]]
  [[ "$output" != *"actas lock held but no watcher"* ]]
}

@test "doctor: codex's per-role bridge line already covers this, so no separate watcher= field is added" {
  bash "$SCRIPTS/join.sh" team bob codex "$PROJ" >/dev/null
  mkdir -p "$TEST_SKILL_DIR/run"
  printf '%s\n' "livetoken.$$" > "$TEST_SKILL_DIR/run/actas.team__bob.session"

  run bash "$SCRIPTS/doctor.sh" --project "$PROJ" --type codex
  [[ "$output" != *"watcher="* ]]
}

@test "doctor: --redacted hides the project path, team/agent names, and most of the owner token" {
  local home_proj="$HOME/redact-me"
  mkdir -p "$home_proj"
  bash "$SCRIPTS/join.sh" team alice claude-code "$home_proj" >/dev/null
  mkdir -p "$TEST_SKILL_DIR/run"
  printf '%s\n' "deadtoken.999999" > "$TEST_SKILL_DIR/run/actas.team__alice.session"

  run bash "$SCRIPTS/doctor.sh" --project "$home_proj" --type claude-code --redacted
  [ "$status" -eq 1 ]
  [[ "$output" == *"project: ~/redact-me"* ]]
  [[ "$output" != *"team/alice"* ]]
  [[ "$output" == *"team1/agent1"* ]]
  [[ "$output" == *"...999999"* ]]
  [[ "$output" != *"deadtoken.999999"* ]]
}

@test "doctor: --redacted also masks a project path outside \$HOME (a shared worktree, /Volumes, etc.), including in the embedded block" {
  # $PROJ (from setup(), a plain mktemp -d) is already outside the sandboxed
  # $HOME test_helper.bash sets up -- no extra fixture needed to get a
  # non-HOME path here, which is exactly the case that leaked before: only
  # the $HOME-relative path was masked, so a project anywhere else (a shared
  # worktree, /Volumes/..., /Users/Shared/...) passed through raw, in both
  # doctor's own "project:" line and the embedded delivery.sh block (whose
  # "settings hooks file:" line names the project directly).
  case "$PROJ" in
    "$HOME"*) skip "fixture \$PROJ landed under \$HOME this run; this test needs it outside" ;;
  esac
  # A stale lock keeps this pair out of the "nothing to report" collapse (see
  # the boring-pair tests below), so the FULL block -- and its "project: "
  # line -- is what's actually exercised here.
  mkdir -p "$TEST_SKILL_DIR/run"
  printf '%s\n' "deadtoken.999999" > "$TEST_SKILL_DIR/run/actas.team__alice.session"

  run bash "$SCRIPTS/doctor.sh" --project "$PROJ" --type claude-code --redacted
  # Numbered (<project1>, not a fixed <project>) since the default whole-
  # install scope needs distinct projects to read as distinct pseudonyms
  # within one run; a single-scope invocation just always lands on the
  # first number.
  [[ "$output" == *"project: <project1>"* ]]
  [[ "$output" != *"$PROJ"* ]]
}

@test "doctor: owner is shown in full by default, and --redacted splits a composite token on its last dot (not a fixed tail length)" {
  mkdir -p "$TEST_SKILL_DIR/run"
  # A pid genuinely dead by construction (spawn, wait, then use its now-freed
  # pid) rather than a hardcoded small number: a fixed guess like "42" can
  # collide with a real process on a container CI runner, where low pids are
  # far more likely to be in active use than on a real developer machine --
  # the same class of flake #595's marker-gc investigation found in a
  # hardcoded pid 4242. Whatever pid the OS actually hands back also isn't
  # guaranteed to be 6 digits, which is what this test needs: a fixed-tail
  # shortener would cut into the sid (e.g. "...02.42") on a short one, while
  # splitting on the last "." always lands exactly on the pid regardless of
  # its length.
  ( exit 0 ) & local deadpid=$!
  wait "$deadpid" 2>/dev/null || true
  local owner="459d8198-3fcf-4c9e-a4ff-5f8fbd18c802.$deadpid"

  printf '%s\n' "$owner" > "$TEST_SKILL_DIR/run/actas.team__alice.session"
  run bash "$SCRIPTS/doctor.sh" --project "$PROJ" --type claude-code
  [[ "$output" == *"lock=owner(STALE)=$owner"* ]]

  run bash "$SCRIPTS/doctor.sh" --project "$PROJ" --type claude-code --redacted
  [[ "$output" == *"lock=owner(STALE)=...$deadpid "* ]]
  [[ "$output" != *"$owner"* ]]
}

# --- scope selection: --project / --team narrow the default whole-install
#     scope; the underlying judgment logic is unchanged either way ---------

@test "doctor: --project narrows the report to just that project, even though others are registered" {
  local other_proj="$(mktemp -d)"
  bash "$SCRIPTS/join.sh" other bob claude-code "$other_proj" >/dev/null

  run bash "$SCRIPTS/doctor.sh" --project "$PROJ"
  [ "$status" -eq 0 ]
  [[ "$output" == *"$PROJ"* ]]
  [[ "$output" != *"$other_proj"* ]]

  rm -rf "$other_proj"
}

@test "doctor: --team narrows the report to just that team's own rows, even at a project/type another team also shares" {
  bash "$SCRIPTS/join.sh" other bob claude-code "$PROJ" >/dev/null
  # A live, healthy lock on alice's role (no warning) keeps this pair out of
  # the "nothing to report" collapse, so the per-registration rows -- what
  # --team is actually narrowing -- are visible to assert on.
  mkdir -p "$TEST_SKILL_DIR/run"
  local owner="livetoken.$$"
  printf '%s\n' "$owner" > "$TEST_SKILL_DIR/run/actas.team__alice.session"
  printf '%s\n' "$owner" > "$TEST_SKILL_DIR/run/cc-instance.$$"
  printf '%s\n' "$$" > "$TEST_SKILL_DIR/run/watch.$owner.pid"

  run bash "$SCRIPTS/doctor.sh" --team team
  [ "$status" -eq 0 ]
  [[ "$output" == "1 team(s),"* ]]
  [[ "$output" == *"team/alice"* ]]
  [[ "$output" != *"other/bob"* ]]
}

@test "doctor: --team still works when the LAST identities.sh row for a pair belongs to a DIFFERENT team" {
  # identities.sh orders rows by team name; "other" sorts before "team", so
  # filtering --team other means the last row _team_filter_lines reads for
  # this pair is "team"'s -- a non-match. Its filtering loop's own exit
  # status is that non-match's (short-circuited "&&") failure, which, with
  # no caller guarding the assignment, aborted the whole script under set -e
  # -- silently, with zero output. Found by running --team against the real
  # installation, where alphabetical luck went the other way from the test
  # above. This is the mirror-image fixture: same two registrations, the
  # OTHER of the two teams filtered for.
  bash "$SCRIPTS/join.sh" other bob claude-code "$PROJ" >/dev/null

  run bash "$SCRIPTS/doctor.sh" --team other
  [ "$status" -eq 0 ]
  # Confirms both "didn't crash" (the actual bug: silent exit 1, zero output)
  # and "actually filtered" (1 registration -- bob's -- not the 2 that exist
  # for this pair total).
  [[ "$output" == "1 team(s), 1 registration(s), 0 warning(s)"* ]]
}

@test "doctor: the default whole-install scope does not double-count a (project, type) registered under two different teams" {
  configured_off "$PROJ"
  # agmsg_registered_projects dedups within one team's config.json but
  # concatenates every team's file with no cross-file dedup -- a second team
  # registered in the SAME project/type this test's $PROJ already has (team/
  # alice, from setup()) is exactly the shape that came back twice before
  # scope-building added its own sort -u.
  bash "$SCRIPTS/join.sh" other bob claude-code "$PROJ" >/dev/null

  run bash "$SCRIPTS/doctor.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == "2 team(s), 2 registration(s), 0 warning(s)"* ]]
  # Exactly one project/type entry, not two -- both registrations are
  # lock=none so this collapses to the one-line "nothing to report" form,
  # which itself carries the correct (deduped) count: "2 registrations",
  # not two separate "1 registration" lines.
  [[ "$output" == *"$PROJ  [claude-code]  2 registrations, nothing to report"* ]]
  local line_count
  line_count="$(printf '%s\n' "$output" | grep -c 'nothing to report')"
  [ "$line_count" -eq 1 ]
}

@test "doctor: the default whole-install scope with --redacted masks paths from multiple projects with consistent, distinct pseudonyms" {
  local other_proj="$(mktemp -d)"
  bash "$SCRIPTS/join.sh" other bob claude-code "$other_proj" >/dev/null

  run bash "$SCRIPTS/doctor.sh" --redacted
  [ "$status" -eq 0 ]
  # Both real paths are gone...
  [[ "$output" != *"$PROJ"* ]]
  [[ "$output" != *"$other_proj"* ]]
  # ...replaced by two DISTINCT numbered placeholders, not one shared one --
  # a single fixed <project> would make two different projects indistinguishable.
  [[ "$output" == *"<project1>"* ]]
  [[ "$output" == *"<project2>"* ]]
  # Real team/agent names are also gone.
  [[ "$output" != *"team/alice"* ]]
  [[ "$output" != *"other/bob"* ]]

  rm -rf "$other_proj"
}

@test "doctor: warns when more than one registration exists under turn-mode delivery" {
  bash "$SCRIPTS/join.sh" team bob claude-code "$PROJ" >/dev/null
  bash "$SCRIPTS/delivery.sh" set turn claude-code "$PROJ" >/dev/null

  run bash "$SCRIPTS/doctor.sh" --project "$PROJ" --type claude-code
  [ "$status" -eq 1 ]
  [[ "$output" == *"registrations for this (project, type) under turn-mode delivery"* ]]
}

@test "doctor: multiple registrations under monitor mode is not a warning" {
  bash "$SCRIPTS/join.sh" team bob claude-code "$PROJ" >/dev/null
  bash "$SCRIPTS/delivery.sh" set monitor claude-code "$PROJ" >/dev/null

  run bash "$SCRIPTS/doctor.sh" --project "$PROJ" --type claude-code
  [ "$status" -eq 0 ]
  [[ "$output" != *"under turn-mode delivery"* ]]
}

# --- the delivery-status block is QUOTED from delivery.sh, not formatted by
#     doctor.sh itself -- --redacted has to run it through the same
#     substitutions or its only promise ("safe to paste") is broken. codex's
#     per-role bridge line is real-world proof: it names team/agent directly. -
@test "doctor: --redacted also redacts the embedded delivery-status block, not just its own formatting" {
  local home_proj="$HOME/embedded-leak-check"
  mkdir -p "$home_proj"
  bash "$SCRIPTS/join.sh" agmsg advisor codex "$home_proj" >/dev/null
  # A live codex bridge for agmsg/advisor, minimal enough for
  # _delivery.sh's agmsg_delivery_runtime_status to report it "alive": a
  # pidfile naming a real (this test's own) pid, and a matching metafile.
  mkdir -p "$TEST_SKILL_DIR/run"
  printf '%s\n' "$$" > "$TEST_SKILL_DIR/run/codex-bridge.agmsg.advisor.pid"
  {
    echo "pid=$$"
    echo "project=$home_proj"
    echo "type=codex"
  } > "$TEST_SKILL_DIR/run/codex-bridge.agmsg.advisor.meta"

  run bash "$SCRIPTS/doctor.sh" --project "$home_proj" --type codex --redacted
  [ "$status" -eq 0 ]
  [[ "$output" == *"Codex bridge: team1/agent1 alive"* ]]
  [[ "$output" != *"agmsg/advisor"* ]]
  [[ "$output" != *"$HOME"* ]]
}

# #1507: per-seat run/ records outlive their team and keep claiming its pane.
# One walk through the whole behavior, with the keep-set in the SAME run: the
# report never deletes, the prompt defaults to no, and --yes removes exactly the
# records whose team is provably gone -- not a live team's, not an ambiguous
# "__" one, not an id-keyed one.
@test "doctor: reports run/ records of a team that no longer exists, and removes only those on request (#1507)" {
  local run_dir="$TEST_SKILL_DIR/run" gone='%2Ftmp%2Fsome%2Fproj'   # a project path used as the team name
  local id_team='11111111-1111-1111-1111-111111111111' id_member='22222222-2222-2222-2222-222222222222'
  mkdir -p "$run_dir"
  # A live seat's records: must survive everything below.
  printf 'herdr:live:w1:p1\t/proj\tclaude-code\n' > "$run_dir/spawn.team__alice"
  printf 'name=team-alice\nteam=team\nagent=alice\n' > "$run_dir/role-session.team__alice"
  # The orphan: all four record families, the pane claimed by spawn.
  printf 'herdr:gone:w1:p9\t/proj\tclaude-code\n' > "$run_dir/spawn.${gone}__worker"
  printf 'name=x\nteam=/tmp/some/proj\nagent=worker\nsession=s1\n' > "$run_dir/role-session.${gone}__worker"
  printf 'owner\n' > "$run_dir/actas.${gone}__worker.session"
  : > "$run_dir/ready.${gone}__worker"
  # Cannot be attributed to one seat ("x___y" cuts as x_/y and as x/_y), and an id-keyed record.
  printf 'herdr:amb:w1:p2\n' > "$run_dir/spawn.x___y"
  printf 'herdr:id:w1:p3\n' > "$run_dir/spawn.${id_team}__${id_member}"
  # A dot-joined codex bridge key collides across teams: gone team "live" /
  # agent "part" and live team "live.part" / agent "worker" both spell
  # codex-bridge.live.part.worker.* -- the gone team's records are removed, the
  # live team's bridge file (never listed) must stay.
  bash "$SCRIPTS/join.sh" live.part worker claude-code "$PROJ" >/dev/null
  printf 'herdr:dot:w1:p5\t/proj\tclaude-code\n' > "$run_dir/spawn.live__part"
  printf '4242\n' > "$run_dir/codex-bridge.live.part.worker.pid"

  run bash "$SCRIPTS/doctor.sh"
  [ "$status" -eq 1 ]
  # grep and [ ], not [[ ]]: a [[ ]] that is not the last line of a test cannot
  # fail it on the macOS bash 3.2 CI runs (#670).
  grep -qF 'orphaned run/ records' <<<"$output"
  grep -qF 'team: /tmp/some/proj  agent: worker  pane: herdr:gone:w1:p9' <<<"$output"
  grep -qF 'team: live  agent: part  pane: herdr:dot:w1:p5' <<<"$output"
  grep -qF 'not attributable to one seat' <<<"$output"
  [ -z "$(grep -F 'agent: alice' <<<"$output")" ]
  [ -z "$(grep -F 'herdr:id:w1:p3' <<<"$output")" ]
  [ -f "$run_dir/spawn.${gone}__worker" ]            # reporting deletes nothing

  run bash -c 'echo n | bash "$1" --fix' _ "$SCRIPTS/doctor.sh"
  [ "$status" -eq 1 ]
  [ -f "$run_dir/spawn.${gone}__worker" ]            # the prompt defaults to no

  run bash "$SCRIPTS/doctor.sh" --fix --yes
  [ "$status" -eq 0 ]
  [ ! -e "$run_dir/spawn.${gone}__worker" ]
  [ ! -e "$run_dir/role-session.${gone}__worker" ]
  [ ! -e "$run_dir/actas.${gone}__worker.session" ]
  [ ! -e "$run_dir/ready.${gone}__worker" ]
  [ ! -e "$run_dir/spawn.live__part" ]
  [ -f "$run_dir/codex-bridge.live.part.worker.pid" ]   # not listed, so not removed
  [ -f "$run_dir/spawn.team__alice" ]
  [ -f "$run_dir/role-session.team__alice" ]
  [ -f "$run_dir/spawn.x___y" ]
  [ -f "$run_dir/spawn.${id_team}__${id_member}" ]
}

# --- fork: --fix must not touch what a live or unverifiable worker still owns --

# All four per-seat record families for <gone team>__<agent>, spawn holding $2.
_orphan_seat() {   # <agent> <spawn first field>
  local run_dir="$TEST_SKILL_DIR/run" gone="${GONE:-%2Ftmp%2Fgone}"
  mkdir -p "$run_dir"
  printf '%s\t/proj\tclaude-code\n' "$2" > "$run_dir/spawn.${gone}__$1"
  printf 'name=x\nteam=/tmp/gone\nagent=%s\n' "$1" > "$run_dir/role-session.${gone}__$1"
  printf 'owner\n' > "$run_dir/actas.${gone}__$1.session"
  : > "$run_dir/ready.${gone}__$1"
}
_seat_files() {   # <agent> -> how many of the 4 records exist
  local run_dir="$TEST_SKILL_DIR/run" gone="${GONE:-%2Ftmp%2Fgone}" n=0 f
  for f in "spawn.${gone}__$1" "role-session.${gone}__$1" "actas.${gone}__$1.session" "ready.${gone}__$1"; do
    if [ -e "$run_dir/$f" ]; then n=$((n + 1)); fi
  done
  echo "$n"
}

@test "doctor --fix: a gone team's seat whose headless worker (pid:) is alive is reported, kept; removed once the worker is dead" {
  # MSYSTEM + a tasklist that sees nothing: the plain pid helper would read the
  # live worker as dead there, the _local helper must not.
  local stub="$BATS_TEST_TMPDIR/stub-bin"
  mkdir -p "$stub"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$stub/tasklist"
  chmod +x "$stub/tasklist"
  test_fixture_start_reaped_process sleep 300
  local wpid="$TEST_REAPED_PID"
  _orphan_seat w "pid:$wpid"

  run env MSYSTEM=MINGW64 PATH="$stub:$PATH" bash "$SCRIPTS/doctor.sh"
  grep -qF 'worker process is still running' <<<"$output"
  [ -z "$(grep -F 'agent: w ' <<<"$output")" ]       # not listed as an orphan to remove

  run env MSYSTEM=MINGW64 PATH="$stub:$PATH" bash "$SCRIPTS/doctor.sh" --fix --yes
  [ "$status" -eq 0 ]
  [ "$(_seat_files w)" -eq 4 ]

  kill "$wpid"; sleep 0.3
  run bash "$SCRIPTS/doctor.sh" --fix --yes
  [ "$status" -eq 0 ]
  [ "$(_seat_files w)" -eq 0 ]
}

@test "doctor --fix: an empty, malformed, zero or oversized pid: placement is never removed" {
  _orphan_seat badstr "pid:abc"
  _orphan_seat zero "pid:0"
  _orphan_seat huge "pid:99999999999"
  _orphan_seat empty ""
  : > "$TEST_SKILL_DIR/run/spawn.%2Ftmp%2Fgone__empty"

  run bash "$SCRIPTS/doctor.sh" --fix --yes
  [ "$status" -eq 0 ]
  [ "$(_seat_files badstr)" -eq 4 ]
  [ "$(_seat_files zero)" -eq 4 ]
  [ "$(_seat_files huge)" -eq 4 ]
  [ "$(_seat_files empty)" -eq 4 ]
}

@test "doctor --fix: a spawn record that cannot be read as a file keeps its seat; --redacted hides the pinned names" {
  _orphan_seat d "herdr:gone:w1:p1"
  rm "$TEST_SKILL_DIR/run/spawn.%2Ftmp%2Fgone__d"
  mkdir "$TEST_SKILL_DIR/run/spawn.%2Ftmp%2Fgone__d"   # not a regular file
  run bash "$SCRIPTS/doctor.sh" --redacted
  grep -qF 'still running or whose pid cannot be verified' <<<"$output"
  [ -z "$(grep -F 'gone' <<<"$output")" ]
  run bash "$SCRIPTS/doctor.sh" --fix --yes
  [ "$status" -eq 0 ]
  [ -d "$TEST_SKILL_DIR/run/spawn.%2Ftmp%2Fgone__d" ]
  [ -e "$TEST_SKILL_DIR/run/role-session.%2Ftmp%2Fgone__d" ]
  [ -e "$TEST_SKILL_DIR/run/ready.%2Ftmp%2Fgone__d" ]
}

@test "doctor --fix: a live team whose name starts with a dot keeps its legacy records" {
  local run_dir="$TEST_SKILL_DIR/run" t
  for t in .dot ..dots; do
    bash "$SCRIPTS/join.sh" "$t" bob claude-code "$PROJ" >/dev/null
    printf 'herdr:live:w1:p1\t/proj\tclaude-code\n' > "$run_dir/spawn.${t}__bob"
    : > "$run_dir/ready.${t}__bob"
  done
  run bash "$SCRIPTS/doctor.sh" --fix --yes
  [ "$status" -eq 0 ]
  [ -e "$run_dir/spawn..dot__bob" ] && [ -e "$run_dir/ready..dot__bob" ]
  [ -e "$run_dir/spawn...dots__bob" ] && [ -e "$run_dir/ready...dots__bob" ]
}

@test "doctor --fix: a placement that turns into a live worker while the prompt waits is kept" {
  sleep 0 & local dead=$!; wait "$dead" || true
  _orphan_seat s "pid:$dead"
  mkfifo "$BATS_TEST_TMPDIR/in"
  bash "$SCRIPTS/doctor.sh" --fix < "$BATS_TEST_TMPDIR/in" > "$BATS_TEST_TMPDIR/out" 2>&1 &
  local dpid=$!
  exec 8> "$BATS_TEST_TMPDIR/in"
  local i=0
  while ! grep -q 'Remove the records' "$BATS_TEST_TMPDIR/out" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  test_fixture_start_reaped_process sleep 300
  local wpid="$TEST_REAPED_PID"
  printf 'pid:%s\t/proj\tclaude-code\n' "$wpid" > "$TEST_SKILL_DIR/run/spawn.%2Ftmp%2Fgone__s"
  echo y >&8; exec 8>&-
  wait "$dpid" || true
  [ "$(_seat_files s)" -eq 4 ]
  grep -qF 'left 1 seat(s) alone' "$BATS_TEST_TMPDIR/out"
}

@test "doctor --fix: a team created while the prompt waits keeps its records" {
  export GONE=late
  _orphan_seat t "herdr:gone:w1:p9"
  mkfifo "$BATS_TEST_TMPDIR/in"
  bash "$SCRIPTS/doctor.sh" --fix < "$BATS_TEST_TMPDIR/in" > "$BATS_TEST_TMPDIR/out" 2>&1 &
  local dpid=$!
  exec 8> "$BATS_TEST_TMPDIR/in"
  local i=0
  while ! grep -q 'Remove the records' "$BATS_TEST_TMPDIR/out" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  bash "$SCRIPTS/join.sh" late t claude-code "$PROJ" >/dev/null
  echo y >&8; exec 8>&-
  wait "$dpid" || true
  [ "$(_seat_files t)" -eq 4 ]
  grep -qF 'their team exists now' "$BATS_TEST_TMPDIR/out"
}

@test "doctor --fix: a failed removal is reported and exits 1; the other seats still go" {
  _orphan_seat a "herdr:gone:w1:p1"
  _orphan_seat b "herdr:gone:w1:p2"
  _orphan_seat c "herdr:gone:w1:p3"
  local shim="$BATS_TEST_TMPDIR/shim"
  mkdir -p "$shim"
  printf '%s\n' '#!/bin/sh' 'for a in "$@"; do case "$a" in *ready.*__b) exit 1 ;; esac; done' 'exec /bin/rm "$@"' > "$shim/rm"
  chmod +x "$shim/rm"

  run env PATH="$shim:$PATH" bash "$SCRIPTS/doctor.sh" --fix --yes
  [ "$status" -eq 1 ]
  [ "$(_seat_files a)" -eq 0 ]
  [ "$(_seat_files c)" -eq 0 ]
  [ "$(_seat_files b)" -eq 1 ]                       # only the one that failed is left
  grep -qF 'removed the run/ records of 2 seat(s)' <<<"$output"
  grep -qF 'failed to remove records of 1 seat(s)' <<<"$output"
  grep -qF 'ready.%2Ftmp%2Fgone__b' <<<"$output"
}

@test "doctor --fix: run/ artifacts that are not per-seat records survive, even named after a gone team" {
  local run_dir="$TEST_SKILL_DIR/run" gone='%2Ftmp%2Fgone'
  _orphan_seat x "herdr:gone:w1:p1"
  mkdir -p "$run_dir/claude-probe-ok"
  local keep=("claude-code-bridge.${gone}.x.session" "cursor-bridge.${gone}.x.pid" "watch.${gone}.pid"
    "watchdog.${gone}.tombstone" "pending-teardown.${gone}" "codex-bridge.${gone}.x.pid"
    "inflight-record.${gone}__x" ".session-end-snapshot.ABC123" "claude-probe-ok/${gone}__x"
    "spawn.${gone}" "role-session.${gone}" "ready.nounderscores")
  local f
  for f in "${keep[@]}"; do printf 'k\n' > "$run_dir/$f"; done

  run bash "$SCRIPTS/doctor.sh" --fix --yes
  [ "$status" -eq 0 ]
  [ "$(_seat_files x)" -eq 0 ]
  for f in "${keep[@]}"; do
    [ -e "$run_dir/$f" ] || { echo "removed: $f" >&2; return 1; }
  done
}

@test "doctor --fix: refuses scope flags, and --yes without --fix" {
  run bash "$SCRIPTS/doctor.sh" --fix --team team
  [ "$status" -eq 2 ]
  run bash "$SCRIPTS/doctor.sh" --fix --redacted
  [ "$status" -eq 2 ]
  run bash "$SCRIPTS/doctor.sh" --yes
  [ "$status" -eq 2 ]
}
