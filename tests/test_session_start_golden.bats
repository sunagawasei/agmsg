#!/usr/bin/env bats

# Golden-parity harness for the session-start.sh common-init extraction and
# type-data session-team gate refactor. For 5 claude-code
# fixtures, this runs session-start.sh from the pre-refactor script (git
# HEAD) and from the current working tree side by side, in two isolated
# skill dirs, and asserts stdout/stderr/exit code and the run+teams
# filesystem state end up byte-identical. This is what guarantees the
# refactor changed claude-code's behavior by zero bytes, independent of
# whatever tests already cover the individual pieces (test_session_team.bats
# et al.).
#
# Both dirs are built by cloning the CURRENT working tree's scripts/ (this
# subtask's file set is scripts/session-start.sh,
# scripts/drivers/types/claude-code/type.conf, and this test file — nothing
# else has moved since HEAD), then overwriting the OLD side's two in-scope
# files with `git show HEAD:...`. This isolates the comparison to exactly
# what this subtask touched.
#
# Note: this compares against HEAD *right now*, before this subtask's diff
# is committed. Once committed, HEAD IS the refactored script, so a later
# run of this file would trivially compare the refactored script against
# itself. That is expected — this file's job is to gate this refactor, not
# to be a permanent behavior-freeze test.

load test_helper

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
PROJ="/tmp/agmsg-golden-proj"

setup() {
  OLD_DIR="$(mktemp -d)"
  NEW_DIR="$(mktemp -d)"
  FIXTURE_ROOT="$(mktemp -d)"
  test_fixture_registry_init "$FIXTURE_ROOT"
  # Same hermeticity guards as test_helper's setup_test_env: without them,
  # agmsg_agent_pid's ancestry walk resolves whatever real claude-code process
  # is running *this* bats invocation (a live ancestor of every subprocess
  # here) instead of the bare-session_id fallback most fixtures below assume.
  unset CLAUDE_CODE_SESSION_ID
  unset CLAUDE_PID
  export AGMSG_AGENT_PID=""
}

teardown() {
  test_fixture_cleanup
  rm -rf "$OLD_DIR" "$NEW_DIR" "$FIXTURE_ROOT"
}

# Full copy of <source_scripts> into <target>/scripts, plus the run/db/teams
# dirs and DB schema session-start.sh (via join.sh/config.sh/identities.sh)
# needs. Mirrors test_helper's setup_test_env, but parameterized so this file
# can build two independent sides in one test instead of relying on the
# single global TEST_SKILL_DIR that helper manages.
_mk_side_env() {
  local target="$1" source_scripts="$2"
  mkdir -p "$target"/{scripts,db,teams,run,home}
  cp -R "$source_scripts/." "$target/scripts/"
  chmod +x "$target/scripts/"*.sh
  chmod +x "$target/scripts/"*.js 2>/dev/null || true
  chmod +x "$target/scripts/drivers/types/"*/*.sh 2>/dev/null || true
  bash "$target/scripts/internal/init-db.sh"
}

_mk_old() {
  _mk_side_env "$OLD_DIR" "$REPO_ROOT/scripts"
  git -C "$REPO_ROOT" show HEAD:scripts/session-start.sh > "$OLD_DIR/scripts/session-start.sh"
  git -C "$REPO_ROOT" show HEAD:scripts/drivers/types/claude-code/type.conf \
    > "$OLD_DIR/scripts/drivers/types/claude-code/type.conf"
  chmod +x "$OLD_DIR/scripts/session-start.sh"
}

_mk_new() {
  _mk_side_env "$NEW_DIR" "$REPO_ROOT/scripts"
}

# Runs session-start.sh in <dir> with <json> on stdin, using <agent_pid> (may
# be empty) as the enclosing CC pid override. Both sides run inside the SAME
# bats test (same $$ throughout, subshells included), so any $$-keyed
# filename (cc-instance.$$, etc.) lines up between OLD_DIR and NEW_DIR
# without any extra bookkeeping, and a shared real pid (e.g. from
# test_fixture_start_reaped_process) lines up the same way.
run_side() {
  local dir="$1" json="$2" agent_pid="${3:-}"
  printf '%s' "$json" \
    | HOME="$dir/home" AGMSG_AGENT_PID="$agent_pid" \
      bash "$dir/scripts/session-start.sh" claude-code "$PROJ" \
      >"$dir/out" 2>"$dir/err"
  printf '%s' "$?" > "$dir/rc"
}

enable_session_team() {
  bash "$1/scripts/config.sh" set delivery.session_team true >/dev/null
}

join_side() {
  local dir="$1" team="$2" agent="$3"
  HOME="$dir/home" bash "$dir/scripts/join.sh" "$team" "$agent" claude-code "$PROJ" >/dev/null
}

# Byte-exact stdout/stderr/exit code, plus the same run/+teams/ file listing
# and byte-exact content for each of those files. stdout embeds
# $SKILL_DIR/scripts/watch.sh as an absolute path -- OLD_DIR and NEW_DIR are
# two distinct mktemp dirs, so that one substring necessarily differs even
# when the two sides behave identically; normalize it away before comparing.
assert_sides_match() {
  [ "$(cat "$OLD_DIR/rc")" = "$(cat "$NEW_DIR/rc")" ]
  sed "s#$OLD_DIR#<DIR>#g" "$OLD_DIR/out" > "$OLD_DIR/out.norm"
  sed "s#$NEW_DIR#<DIR>#g" "$NEW_DIR/out" > "$NEW_DIR/out.norm"
  sed "s#$OLD_DIR#<DIR>#g" "$OLD_DIR/err" > "$OLD_DIR/err.norm"
  sed "s#$NEW_DIR#<DIR>#g" "$NEW_DIR/err" > "$NEW_DIR/err.norm"
  diff "$OLD_DIR/out.norm" "$NEW_DIR/out.norm"
  diff "$OLD_DIR/err.norm" "$NEW_DIR/err.norm"
  diff <(cd "$OLD_DIR" && find run teams -type f | sort) \
       <(cd "$NEW_DIR" && find run teams -type f | sort)
  local f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$(basename "$f")" in
      # The first two tab-separated fields are a wall-clock timestamp and
      # join.sh's own subprocess pid -- both inherently differ per real
      # invocation regardless of which session-start.sh wrote them. Compare
      # from the team field onward.
      team-config-audit.log)
        diff <(cut -f3- "$OLD_DIR/$f") <(cut -f3- "$NEW_DIR/$f") ;;
      # join.sh stamps a fresh team's config.json with the wall-clock time it
      # was created -- same reasoning as the audit log above.
      config.json)
        diff <(sed -E 's/"created_at":"[^"]*"/"created_at":"<TS>"/' "$OLD_DIR/$f") \
             <(sed -E 's/"created_at":"[^"]*"/"created_at":"<TS>"/' "$NEW_DIR/$f") ;;
      # agmsg_role_session_record (this test's own fixture 4 setup, run once
      # per side a moment apart) stamps updated_at=<wall clock> -- same
      # reasoning again.
      role-session.*)
        diff <(sed -E 's/^updated_at=.*/updated_at=<TS>/' "$OLD_DIR/$f") \
             <(sed -E 's/^updated_at=.*/updated_at=<TS>/' "$NEW_DIR/$f") ;;
      *)
        diff "$OLD_DIR/$f" "$NEW_DIR/$f" ;;
    esac
  done < <(cd "$OLD_DIR" && find run teams -type f | sort)
}

# --- Fixture 1: fresh session, session-team mode on ---

@test "golden: fresh session, session-team mode on" {
  _mk_old; _mk_new
  enable_session_team "$OLD_DIR"; enable_session_team "$NEW_DIR"
  local sid="golden-fresh-$$"

  run_side "$OLD_DIR" "{\"session_id\":\"$sid\"}"
  run_side "$NEW_DIR" "{\"session_id\":\"$sid\"}"

  assert_sides_match
  [[ "$(cat "$NEW_DIR/out")" == *"invoke the Monitor tool"* ]]
}

# --- Fixture 2: resume across a CC pid change (composite instance id) ---

@test "golden: resume across a CC pid change (composite instance id)" {
  _mk_old; _mk_new
  enable_session_team "$OLD_DIR"; enable_session_team "$NEW_DIR"
  local sid="golden-resume-$$"

  # A real `claude --continue`/`--resume` re-fires SessionStart with the SAME
  # session_id from a NEW process (a different pid). Model that with two live
  # pids sharing one session_id: pid1 dies before pid2's SessionStart fires,
  # so the dead-cc-instance cleanup ("join の前に dedup") actually runs on
  # both sides, not just the fresh-session path fixture 1 already covers.
  test_fixture_start_reaped_process sleep 300
  local pid1="$TEST_REAPED_PID"

  run_side "$OLD_DIR" "{\"session_id\":\"$sid\"}" "$pid1"
  run_side "$NEW_DIR" "{\"session_id\":\"$sid\"}" "$pid1"

  kill "$pid1" 2>/dev/null || true
  local waited=0
  while kill -0 "$pid1" 2>/dev/null && [ "$waited" -lt 50 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done

  test_fixture_start_reaped_process sleep 300
  local pid2="$TEST_REAPED_PID"

  run_side "$OLD_DIR" "{\"session_id\":\"$sid\"}" "$pid2"
  run_side "$NEW_DIR" "{\"session_id\":\"$sid\"}" "$pid2"

  # Confirm the second pass actually exercised the dead-cc-instance cleanup
  # (not a no-op that would trivially match on both sides): pid1's record is
  # gone, pid2's is published, on the side under test.
  [ ! -e "$NEW_DIR/run/cc-instance.$pid1" ]
  [ -e "$NEW_DIR/run/cc-instance.$pid2" ]

  assert_sides_match
}

# --- Fixture 3: dedup skip when a watcher is already alive for this instance ---

@test "golden: dedup skip when a watcher is already alive for this instance" {
  skip_on_windows "watcher live-owner liveness under Git Bash (#182)"
  _mk_old; _mk_new
  enable_session_team "$OLD_DIR"; enable_session_team "$NEW_DIR"
  local sid="golden-dedup-$$"
  local team="s-$sid"
  join_side "$OLD_DIR" "$team" claude
  join_side "$NEW_DIR" "$team" claude

  # One real watch.sh process, owned by OLD_DIR. NEW_DIR's pidfile/owner/lease
  # sidecars are SYMLINKS to OLD_DIR's real files (not copies): the dedup
  # check's liveness probe locks the file by path, and a copy would be a
  # distinct, unlocked inode -- only a symlink to the same real file reflects
  # the same "genuinely alive and leased" state on both sides.
  AGMSG_WATCH_INTERVAL=60 bash "$OLD_DIR/scripts/watch.sh" "$sid" "$PROJ" claude-code \
    >/dev/null 2>&1 3>&- &
  local w=$!
  wait_for_file "$OLD_DIR/run/watch.$sid.pid"
  local f base
  for f in "$OLD_DIR"/run/watch."$sid".*; do
    [ -e "$f" ] || continue
    base="$(basename "$f")"
    ln -s "$f" "$NEW_DIR/run/$base"
  done

  run_side "$OLD_DIR" "{\"session_id\":\"$sid\"}"
  run_side "$NEW_DIR" "{\"session_id\":\"$sid\"}"

  kill "$w" 2>/dev/null || true
  wait "$w" 2>/dev/null || true

  sed "s#$OLD_DIR#<DIR>#g" "$OLD_DIR/out" > "$OLD_DIR/out.norm"
  sed "s#$NEW_DIR#<DIR>#g" "$NEW_DIR/out" > "$NEW_DIR/out.norm"
  sed "s#$OLD_DIR#<DIR>#g" "$OLD_DIR/err" > "$OLD_DIR/err.norm"
  sed "s#$NEW_DIR#<DIR>#g" "$NEW_DIR/err" > "$NEW_DIR/err.norm"
  diff "$OLD_DIR/out.norm" "$NEW_DIR/out.norm"
  diff "$OLD_DIR/err.norm" "$NEW_DIR/err.norm"
  [[ "$(cat "$NEW_DIR/out")" == *"already streaming"* ]]
  [[ "$(cat "$NEW_DIR/out")" != *"invoke the Monitor tool"* ]]
}

# --- Fixture 4: role-aware resume ---

@test "golden: role-aware resume directive" {
  _mk_old; _mk_new
  enable_session_team "$OLD_DIR"; enable_session_team "$NEW_DIR"
  local sid="golden-role-$$"
  join_side "$OLD_DIR" team alice
  join_side "$NEW_DIR" team alice
  SKILL_DIR="$OLD_DIR" HOME="$OLD_DIR/home" bash -c \
    "source '$OLD_DIR/scripts/lib/role-session.sh'; agmsg_role_session_record team alice '$sid' '$PROJ' claude-code"
  SKILL_DIR="$NEW_DIR" HOME="$NEW_DIR/home" bash -c \
    "source '$NEW_DIR/scripts/lib/role-session.sh'; agmsg_role_session_record team alice '$sid' '$PROJ' claude-code"

  run_side "$OLD_DIR" "{\"session_id\":\"$sid\"}"
  run_side "$NEW_DIR" "{\"session_id\":\"$sid\"}"

  assert_sides_match
  [[ "$(cat "$NEW_DIR/out")" == *"resumed role"* ]]
}

# --- Fixture 5: session-team mode off (runtime opt-in false) ---

@test "golden: session-team mode off (runtime opt-in false)" {
  _mk_old; _mk_new
  local sid="golden-off-$$"
  join_side "$OLD_DIR" team bob
  join_side "$NEW_DIR" team bob

  run_side "$OLD_DIR" "{\"session_id\":\"$sid\"}"
  run_side "$NEW_DIR" "{\"session_id\":\"$sid\"}"

  assert_sides_match
  [[ "$(cat "$NEW_DIR/out")" == *"invoke the Monitor tool"* ]]
  [[ "$(cat "$NEW_DIR/out")" != *"--team"* ]]
}
