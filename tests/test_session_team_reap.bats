#!/usr/bin/env bats

# A session team (s-<uuid>) is removed, dir + run state + rows, as soon as its
# owner instance is gone; a resume re-fires SessionStart with the same session
# id and gets an empty team.

load test_helper

setup() {
  setup_test_env
  PROJ="/tmp/agmsg-reap-proj"
  export SKILL_DIR="$TEST_SKILL_DIR"
  DB="$TEST_SKILL_DIR/db/messages.db"
  PIDS=""
  mkdir -p "$TEST_SKILL_DIR/run"
  # the schema is created by the first send; seed with direct inserts after it
  bash "$SCRIPTS/send.sh" schema-init a b init --force >/dev/null
  bash "$SCRIPTS/config.sh" set delivery.session_team true >/dev/null
  # shellcheck disable=SC1091
  source "$SCRIPTS/lib/actas-lock.sh"
}

teardown() {
  local p
  for p in $PIDS; do kill "$p" 2>/dev/null || true; done
  teardown_test_env
}

# Session id "gc-current" belongs to the hook that runs; its team is s-gc-current.
run_session_start() {   # [sid]
  printf '{"session_id":"%s"}' "${1:-gc-current}" \
    | bash "$SCRIPTS/session-start.sh" claude-code "$PROJ"
}

make_team() {   # <team> [marked]
  mkdir -p "$TEST_SKILL_DIR/teams/$1"
  printf '{"name":"%s","agents":{}}\n' "$1" > "$TEST_SKILL_DIR/teams/$1/config.json"
  if [ "${2:-}" = marked ]; then : > "$TEST_SKILL_DIR/teams/$1/session-team"; fi
}

seed_rows() {   # <team> [count]: direct inserts, independent of send.sh
  local team="$1" n="${2:-1}" i
  for ((i = 0; i < n; i++)); do
    sqlite3 "$DB" "INSERT INTO events(type,id,team,from_agent,to_agent,body,at) VALUES('message_sent','id-$team-$i-$RANDOM','$team','a','b','seed$i',strftime('%Y-%m-%dT%H:%M:%SZ','now'));
                   INSERT INTO messages(team,from_agent,to_agent,body) VALUES('$team','a','b','seed$i');"
  done
}

rows() {
  sqlite3 "$DB" "SELECT (SELECT COUNT(*) FROM events WHERE team='$1') + (SELECT COUNT(*) FROM messages WHERE team='$1');"
}

live_pid() { sleep 300 & LIVE=$!; PIDS="$PIDS $LIVE"; }

@test "a dead owner's marked team loses its dir, run files and rows; other teams stay" {
  make_team s-dead-1 marked
  make_team s-other-1 marked
  seed_rows s-dead-1 2
  seed_rows s-other-1 2
  : > "$TEST_SKILL_DIR/run/cursor-bridge.s-dead-1.w.meta"
  : > "$TEST_SKILL_DIR/run/codex-bridge.s-dead-1.w.meta"
  : > "$TEST_SKILL_DIR/run/claude-code-bridge.s-dead-1.w.meta"
  printf '%%99\t%s\tclaude-code\n' "$PROJ" > "$TEST_SKILL_DIR/run/spawn.s-dead-1__w"
  : > "$TEST_SKILL_DIR/run/pending-teardown.s-dead-1__w"
  mkdir -p "$TEST_SKILL_DIR/run/codex-s-dead-1-cwd" "$TEST_SKILL_DIR/run/claude-code-s-dead-1-w-cwd"
  sleep 300 & local other_owner=$!; PIDS="$PIDS $other_owner"
  printf 'other-1\n' > "$TEST_SKILL_DIR/run/cc-instance.$other_owner"
  run run_session_start
  [ "$status" -eq 0 ]
  [ ! -d "$TEST_SKILL_DIR/teams/s-dead-1" ]
  [ "$(rows s-dead-1)" = 0 ]
  [ ! -e "$TEST_SKILL_DIR/run/cursor-bridge.s-dead-1.w.meta" ]
  [ ! -e "$TEST_SKILL_DIR/run/codex-bridge.s-dead-1.w.meta" ]
  [ ! -e "$TEST_SKILL_DIR/run/claude-code-bridge.s-dead-1.w.meta" ]
  [ ! -e "$TEST_SKILL_DIR/run/spawn.s-dead-1__w" ]
  [ ! -e "$TEST_SKILL_DIR/run/pending-teardown.s-dead-1__w" ]
  [ ! -e "$TEST_SKILL_DIR/run/codex-s-dead-1-cwd" ]
  [ ! -e "$TEST_SKILL_DIR/run/claude-code-s-dead-1-w-cwd" ]
  [ ! -e "$TEST_SKILL_DIR/run/session-tombstone.s-dead-1" ]
  [ -d "$TEST_SKILL_DIR/teams/s-other-1" ]
  [ "$(rows s-other-1)" != 0 ]
}

@test "a team whose owner is alive is not removed" {
  make_team s-live-1 marked
  seed_rows s-live-1
  live_pid
  printf 'live-1\n' > "$TEST_SKILL_DIR/run/cc-instance.$LIVE"
  run run_session_start
  [ -d "$TEST_SKILL_DIR/teams/s-live-1" ]
  [ "$(rows s-live-1)" != 0 ]
}

@test "a dir without the session-team marker is not removed" {
  make_team s-plain-1
  seed_rows s-plain-1
  run run_session_start
  [ "$status" -eq 0 ]
  [ -d "$TEST_SKILL_DIR/teams/s-plain-1" ]
  [ "$(rows s-plain-1)" != 0 ]
}

@test "a live bridge keeps the team" {
  make_team s-veto-bridge marked
  seed_rows s-veto-bridge
  live_pid
  printf 'pid:%s\t%s\tcodex\n' "$LIVE" "$PROJ" > "$TEST_SKILL_DIR/run/spawn.s-veto-bridge__w"
  run run_session_start
  [ -d "$TEST_SKILL_DIR/teams/s-veto-bridge" ]
  [ "$(rows s-veto-bridge)" != 0 ]
  [[ "$output" == *"reason=live-bridge"* ]]
}

@test "an unverified placement keeps the team" {
  make_team s-veto-unver marked
  seed_rows s-veto-unver
  printf 'pid:not-a-number\t%s\tcodex\n' "$PROJ" > "$TEST_SKILL_DIR/run/spawn.s-veto-unver__w"
  run run_session_start
  [ -d "$TEST_SKILL_DIR/teams/s-veto-unver" ]
  [ "$(rows s-veto-unver)" != 0 ]
  [[ "$output" == *"reason=unverified-placement"* ]]
}

@test "a live inflight record keeps the team" {
  make_team s-veto-infl marked
  seed_rows s-veto-infl
  printf 'garbage\n' > "$TEST_SKILL_DIR/run/inflight-record.$(_actas_lock_encode s-veto-infl)=x"
  run run_session_start
  [ -d "$TEST_SKILL_DIR/teams/s-veto-infl" ]
  [ "$(rows s-veto-infl)" != 0 ]
  [[ "$output" == *"reason=live-inflight"* ]]
}

@test "an explicit retention_days of 7 does not keep rows added in the same second" {
  bash "$SCRIPTS/config.sh" set delivery.message_retention_days 7 >/dev/null
  make_team s-same-sec marked
  seed_rows s-same-sec 3
  run run_session_start
  [ ! -d "$TEST_SKILL_DIR/teams/s-same-sec" ]
  [ "$(rows s-same-sec)" = 0 ]
}

@test "a fresh dead team is removed without waiting for a TTL" {
  make_team s-fresh-dead marked
  seed_rows s-fresh-dead
  run run_session_start
  [ ! -d "$TEST_SKILL_DIR/teams/s-fresh-dead" ]
}

@test "resume: the old team with unread messages is recreated empty" {
  local sid=resume-1 team=s-resume-1
  make_team "$team" marked
  seed_rows "$team" 2
  live_pid   # the resumed claude process
  AGMSG_AGENT_PID="$LIVE" run run_session_start "$sid"
  [ "$status" -eq 0 ]
  [ -f "$TEST_SKILL_DIR/teams/$team/session-team" ]
  [ "$(rows "$team")" = 0 ]
  run bash "$SCRIPTS/inbox.sh" "$team" claude
  [[ "$output" != *seed* ]]
  # cc-instance is published after the old generation is gone
  [ "$(cat "$TEST_SKILL_DIR/run/cc-instance.$LIVE")" = "$sid.$LIVE" ]
}

@test "resume: a live instance of the same session id on another pid keeps the team" {
  local sid=resume-2 team=s-resume-2
  make_team "$team" marked
  seed_rows "$team"
  live_pid; local first="$LIVE"
  printf '%s.%s\n' "$sid" "$first" > "$TEST_SKILL_DIR/run/cc-instance.$first"
  live_pid
  AGMSG_AGENT_PID="$LIVE" run run_session_start "$sid"
  [ "$status" -eq 0 ]
  [ "$(rows "$team")" != 0 ]
}

@test "a same-pid same-sid refire (compact) keeps the team" {
  local sid=compact-1 team=s-compact-1
  make_team "$team" marked
  seed_rows "$team"
  live_pid
  printf '%s.%s\n' "$sid" "$LIVE" > "$TEST_SKILL_DIR/run/cc-instance.$LIVE"
  AGMSG_AGENT_PID="$LIVE" run run_session_start "$sid"
  [ "$status" -eq 0 ]
  [ "$(rows "$team")" != 0 ]
}

@test "a bare SessionStart (no owner pid) keeps its own team" {
  local team=s-gc-current
  make_team "$team" marked
  seed_rows "$team"
  AGMSG_AGENT_PID="" run run_session_start gc-current
  [ "$status" -eq 0 ]
  [ -d "$TEST_SKILL_DIR/teams/$team" ]
  [ "$(rows "$team")" != 0 ]
}

@test "a lifecycle lock held by another process keeps the team" {
  make_team s-lock-1 marked
  seed_rows s-lock-1
  local libs='for l in compat actas-lock storage team-lifecycle instance-id process-identity pending-teardown inflight session-team session-retention; do . "$SCRIPT_DIR/lib/$l.sh"; done'
  SCRIPT_DIR="$SCRIPTS" RUN_DIR="$TEST_SKILL_DIR/run" bash -c "$libs"'; agmsg_team_lifecycle_lock_acquire s-lock-1 5; : > "$RUN_DIR/held"; sleep 300' &
  PIDS="$PIDS $!"
  local i
  for i in $(seq 1 100); do [ -e "$TEST_SKILL_DIR/run/held" ] && break; sleep 0.1; done
  [ -e "$TEST_SKILL_DIR/run/held" ]
  run env SCRIPT_DIR="$SCRIPTS" RUN_DIR="$TEST_SKILL_DIR/run" AGMSG_LIFECYCLE_LOCK_TIMEOUT=1 \
    bash -c "$libs"'; agmsg_session_team_reap_dead s-lock-1'
  [[ "$output" == *lock-timeout* ]]
  [ -d "$TEST_SKILL_DIR/teams/s-lock-1" ]
  [ "$(rows s-lock-1)" != 0 ]
}

@test "a dir replaced by a project team while waiting for the lock is not removed" {
  make_team s-race-1 marked
  seed_rows s-race-1
  local libs='for l in compat actas-lock storage team-lifecycle instance-id process-identity pending-teardown inflight session-team session-retention; do . "$SCRIPT_DIR/lib/$l.sh"; done'
  SCRIPT_DIR="$SCRIPTS" RUN_DIR="$TEST_SKILL_DIR/run" bash -c "$libs"'; agmsg_team_lifecycle_lock_acquire s-race-1 5; : > "$RUN_DIR/held"; sleep 2; rm -rf "$SKILL_DIR/teams/s-race-1"; mkdir -p "$SKILL_DIR/teams/s-race-1"; echo "{}" > "$SKILL_DIR/teams/s-race-1/config.json"' &
  PIDS="$PIDS $!"
  local i
  for i in $(seq 1 100); do [ -e "$TEST_SKILL_DIR/run/held" ] && break; sleep 0.1; done
  run env SCRIPT_DIR="$SCRIPTS" RUN_DIR="$TEST_SKILL_DIR/run" AGMSG_LIFECYCLE_LOCK_TIMEOUT=20 \
    bash -c "$libs"'; agmsg_session_team_reap_dead s-race-1'
  [ "$output" = unmarked ]
  [ -f "$TEST_SKILL_DIR/teams/s-race-1/config.json" ]
  [ "$(rows s-race-1)" != 0 ]
}

# A forced send can add rows to a team that has no dir.
@test "resume: rows left by a dir-less team are removed before the new generation" {
  local sid=orphan-1 team=s-orphan-1
  seed_rows "$team" 2
  [ ! -d "$TEST_SKILL_DIR/teams/$team" ]
  live_pid
  AGMSG_AGENT_PID="$LIVE" run run_session_start "$sid"
  [ "$status" -eq 0 ]
  [ "$(rows "$team")" = 0 ]
}

@test "a same-pid same-sid refire (compact) keeps the rows of a dir-less team" {
  local sid=orphan-2 team=s-orphan-2
  seed_rows "$team"
  live_pid
  printf '%s.%s\n' "$sid" "$LIVE" > "$TEST_SKILL_DIR/run/cc-instance.$LIVE"
  AGMSG_AGENT_PID="$LIVE" run run_session_start "$sid"
  [ "$(rows "$team")" != 0 ]
}

@test "a live same-sid instance on another pid keeps the rows of a dir-less team" {
  local sid=orphan-3 team=s-orphan-3
  seed_rows "$team"
  live_pid; local first="$LIVE"
  printf '%s.%s\n' "$sid" "$first" > "$TEST_SKILL_DIR/run/cc-instance.$first"
  live_pid
  AGMSG_AGENT_PID="$LIVE" run run_session_start "$sid"
  [ "$(rows "$team")" != 0 ]
}

@test "run files that cannot be removed are reported as reaped-with-leftovers" {
  make_team s-left-1 marked
  seed_rows s-left-1
  printf '%%99\t%s\tclaude-code\n' "$PROJ" > "$TEST_SKILL_DIR/run/spawn.s-left-1__w"
  mkdir "$TEST_SKILL_DIR/shim"
  printf '#!/bin/sh\ncase "$*" in *spawn.s-left-1*) exit 1 ;; esac\nexec /bin/rm "$@"\n' > "$TEST_SKILL_DIR/shim/rm"
  chmod +x "$TEST_SKILL_DIR/shim/rm"
  local libs='for l in compat actas-lock storage team-lifecycle instance-id process-identity pending-teardown inflight session-team session-retention; do . "$SCRIPT_DIR/lib/$l.sh"; done'
  run env PATH="$TEST_SKILL_DIR/shim:$PATH" SCRIPT_DIR="$SCRIPTS" RUN_DIR="$TEST_SKILL_DIR/run" \
    bash -c "$libs"'; agmsg_session_team_reap_dead s-left-1; echo "rc=$?"'
  [[ "$output" == *"leftovers team=s-left-1"* ]]
  [[ "$output" == *reaped-with-leftovers* ]]
  [[ "$output" == *"rc=0"* ]]
  [ ! -d "$TEST_SKILL_DIR/teams/s-left-1" ]
  [ "$(rows s-left-1)" = 0 ]
}

dead_pid() { bash -c 'exit 0' & DEAD=$!; wait "$DEAD" 2>/dev/null || true; }

# A reaper that died after the rename leaves run/reaping.<team>.<pid>.<n>.
make_reaping() {   # <team> <pid> [marked]
  local d="$TEST_SKILL_DIR/run/reaping.$1.$2.4242"
  mkdir -p "$d"
  printf '{"name":"%s","agents":{}}\n' "$1" > "$d/config.json"
  if [ "${3:-}" = marked ]; then : > "$d/session-team"; fi
  seed_rows "$1"
  printf '%%99\t%s\tclaude-code\n' "$PROJ" > "$TEST_SKILL_DIR/run/spawn.$1__w"
}

@test "sweep: a reaping dir of a dead reaper loses its rows, run files and the dir" {
  dead_pid
  make_reaping s-sw-1 "$DEAD" marked
  run run_session_start
  [ "$status" -eq 0 ]
  [ ! -e "$TEST_SKILL_DIR/run/reaping.s-sw-1.$DEAD.4242" ]
  [ "$(rows s-sw-1)" = 0 ]
  [ ! -e "$TEST_SKILL_DIR/run/spawn.s-sw-1__w" ]
}

@test "sweep: a reaping dir of a live reaper is left alone" {
  live_pid
  make_reaping s-sw-2 "$LIVE" marked
  run run_session_start
  [ -d "$TEST_SKILL_DIR/run/reaping.s-sw-2.$LIVE.4242" ]
  [ "$(rows s-sw-2)" != 0 ]
}

@test "sweep: with a live owner of the same sid only the reaping dir is removed" {
  dead_pid
  make_reaping s-sw-3 "$DEAD" marked
  live_pid
  printf 'sw-3\n' > "$TEST_SKILL_DIR/run/cc-instance.$LIVE"
  run run_session_start
  [ ! -e "$TEST_SKILL_DIR/run/reaping.s-sw-3.$DEAD.4242" ]
  [ "$(rows s-sw-3)" != 0 ]
  [ -e "$TEST_SKILL_DIR/run/spawn.s-sw-3__w" ]
}

@test "sweep: a reaping dir without the marker is only removed" {
  dead_pid
  make_reaping s-sw-4 "$DEAD"
  run run_session_start
  [ ! -e "$TEST_SKILL_DIR/run/reaping.s-sw-4.$DEAD.4242" ]
  [ "$(rows s-sw-4)" != 0 ]
  [ -e "$TEST_SKILL_DIR/run/spawn.s-sw-4__w" ]
}

@test "a failed row delete changes nothing: dir, marker, rows and run files stay" {
  make_team s-dbf-1 marked
  seed_rows s-dbf-1
  printf '%%99\t%s\tclaude-code\n' "$PROJ" > "$TEST_SKILL_DIR/run/spawn.s-dbf-1__w"
  sqlite3 "$DB" "CREATE TRIGGER block_msg_delete BEFORE DELETE ON messages BEGIN SELECT RAISE(ABORT,'no'); END;"
  local libs='for l in compat actas-lock storage team-lifecycle instance-id process-identity pending-teardown inflight session-team session-retention; do . "$SCRIPT_DIR/lib/$l.sh"; done'
  run env SCRIPT_DIR="$SCRIPTS" RUN_DIR="$TEST_SKILL_DIR/run" \
    bash -c "$libs"'; agmsg_session_team_reap_dead s-dbf-1'
  [[ "$output" == *skipped:db-failed ]]
  [ -f "$TEST_SKILL_DIR/teams/s-dbf-1/session-team" ]
  [ "$(rows s-dbf-1)" != 0 ]
  [ -e "$TEST_SKILL_DIR/run/spawn.s-dbf-1__w" ]
  [ -z "$(ls "$TEST_SKILL_DIR"/run/reaping.s-dbf-1.* 2>/dev/null)" ]
}

@test "a failed rename keeps the dir and marker, and the next reap finishes" {
  make_team s-rn-1 marked
  seed_rows s-rn-1
  mkdir "$TEST_SKILL_DIR/shim"
  printf '#!/bin/sh\ncase "$*" in *s-rn-1*) exit 1 ;; esac\nexec /bin/mv "$@"\n' > "$TEST_SKILL_DIR/shim/mv"
  chmod +x "$TEST_SKILL_DIR/shim/mv"
  local libs='for l in compat actas-lock storage team-lifecycle instance-id process-identity pending-teardown inflight session-team session-retention; do . "$SCRIPT_DIR/lib/$l.sh"; done'
  run env PATH="$TEST_SKILL_DIR/shim:$PATH" SCRIPT_DIR="$SCRIPTS" RUN_DIR="$TEST_SKILL_DIR/run" \
    bash -c "$libs"'; agmsg_session_team_reap_dead s-rn-1'
  [[ "$output" == *skipped:rename-failed ]]
  [ -f "$TEST_SKILL_DIR/teams/s-rn-1/session-team" ]
  [ "$(rows s-rn-1)" = 0 ]
  run env SCRIPT_DIR="$SCRIPTS" RUN_DIR="$TEST_SKILL_DIR/run" \
    bash -c "$libs"'; agmsg_session_team_reap_dead s-rn-1'
  [ "$output" = reaped ]
  [ ! -d "$TEST_SKILL_DIR/teams/s-rn-1" ]
}

@test "resume: a dir-less team's rows are purged from a database without read_cursors" {
  sqlite3 "$DB" "DROP TABLE read_cursors;"
  seed_rows s-old-1 2
  live_pid
  AGMSG_AGENT_PID="$LIVE" run run_session_start old-1
  [ "$status" -eq 0 ]
  [ "$(rows s-old-1)" = 0 ]
}

@test "resume: a dir-less team's rows are purged from a database without events" {
  sqlite3 "$DB" "DROP TABLE events; DROP TABLE read_cursors;"
  sqlite3 "$DB" "INSERT INTO messages(team,from_agent,to_agent,body) VALUES('s-old-2','a','b','x');"
  live_pid
  AGMSG_AGENT_PID="$LIVE" run run_session_start old-2
  [ "$status" -eq 0 ]
  [ "$(sqlite3 "$DB" "SELECT COUNT(*) FROM messages WHERE team='s-old-2'")" = 0 ]
}

@test "resume: a dir-less team that only has a read cursor is purged" {
  sqlite3 "$DB" "INSERT INTO read_cursors(team,agent,local_position) VALUES('s-cur-1','claude',5);"
  live_pid
  AGMSG_AGENT_PID="$LIVE" run run_session_start cur-1
  [ "$status" -eq 0 ]
  [ "$(sqlite3 "$DB" "SELECT COUNT(*) FROM read_cursors WHERE team='s-cur-1'")" = 0 ]
}

@test "the reap removes the team's inflight outbox" {
  make_team s-ob-1 marked
  local ob="$TEST_SKILL_DIR/run/inflight-outbox.$(_actas_lock_encode s-ob-1)=worker"
  mkdir -p "$ob"; : > "$ob/pending"
  run run_session_start
  [ ! -d "$TEST_SKILL_DIR/teams/s-ob-1" ]
  [ ! -e "$ob" ]
}
