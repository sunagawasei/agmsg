#!/usr/bin/env bats

# The host-neutral session resolver (lib/session-team.sh) and what hangs off it:
# whoami / send.sh's cross-session guard / the headless worker provenance record /
# the session-team marker join.sh writes / SessionStart+SessionEnd for a Cursor
# session / the peer-liveness evidence a Cursor session leaves.
#
# A Claude Code session is s-<id> with the `claude` seat; a Cursor session is
# cur-<uuid> with the `cursor-host` seat. Neither may ever be taken for the other.

load test_helper

CUR_A="5bd60f15-0cd3-42d5-b5f2-d53c81336167"
CUR_B="72a71a78-44ec-43c7-9d92-f2a7a2a24223"

setup() {
  setup_test_env
  PROJ="$(mktemp -d)"
  bash "$SCRIPTS/config.sh" set delivery.session_team true >/dev/null
  # shellcheck disable=SC1091
  SCRIPT_DIR="$SCRIPTS" source "$SCRIPTS/lib/session-team.sh"
}

teardown() {
  teardown_test_env
}

# join a Cursor session team the way session-start does (marker + seat)
mk_cursor_team() {
  AGMSG_JOIN_SESSION_MARKER=cursor AGMSG_RESOLVE_PROJECT=0 \
    bash "$SCRIPTS/join.sh" "cur-$1" cursor-host cursor "$PROJ" >/dev/null
  bash "$SCRIPTS/join.sh" "cur-$1" human cursor "$PROJ" >/dev/null
}

mk_claude_team() {
  bash "$SCRIPTS/join.sh" "s-$1" claude claude-code "$PROJ" >/dev/null
  bash "$SCRIPTS/join.sh" "s-$1" human claude-code "$PROJ" >/dev/null
}

# run whoami for <type> with an exact environment: the harness's own session
# vars must not leak into the table.
who() {
  local type="$1"; shift
  run env -u CLAUDE_CODE_SESSION_ID -u CURSOR_CONVERSATION_ID "$@" \
    bash "$SCRIPTS/whoami.sh" "$PROJ" "$type"
}

# --- id normalization --------------------------------------------------------

@test "normalize: a session id never contains a dot" {
  [ "$(agmsg_session_normalize_sid claude-code abc)" = abc ]
  [ "$(agmsg_session_normalize_sid claude-code sess-X_1)" = sess-X_1 ]
  for bad in abc.one abc.two abc.1 abc.2 abc.1.2 .abc 'a/b' '..' 'a b' "$(printf 'a\nb')" "$(printf 'a%.0s' $(seq 1 129))"; do
    [ -z "$(agmsg_session_normalize_sid claude-code "$bad")" ]
  done
}

@test "normalize: a cursor id must be a uuid" {
  [ "$(agmsg_session_normalize_sid cursor "$CUR_A")" = "$CUR_A" ]
  [ -z "$(agmsg_session_normalize_sid cursor "$CUR_A.4242")" ]
  [ -z "$(agmsg_session_normalize_sid cursor sess-X)" ]
  [ -z "$(agmsg_session_normalize_sid cursor "${CUR_A}0")" ]
}

@test "team naming: the same id on two hosts gives two teams" {
  [ "$(agmsg_session_team_for claude-code "$CUR_A")" = "s-$CUR_A" ]
  [ "$(agmsg_session_team_for cursor "$CUR_A")" = "cur-$CUR_A" ]
}

# --- whoami decision table ---------------------------------------------------

@test "whoami: claude env only -> claude-code session team with the claude seat" {
  who claude-code CLAUDE_CODE_SESSION_ID=sess-X
  [ "$status" -eq 0 ]
  [[ "$output" == "agent=claude teams=s-sess-X type=claude-code "* ]]
}

@test "whoami: cursor env only -> cursor session team with the cursor-host seat" {
  who cursor CURSOR_CONVERSATION_ID="$CUR_A"
  [ "$status" -eq 0 ]
  [[ "$output" == "agent=cursor-host teams=cur-$CUR_A type=cursor "* ]]
}

@test "whoami: a cursor session never answers as claude-code, nor the reverse" {
  who claude-code CURSOR_CONVERSATION_ID="$CUR_A"
  [[ "$output" != *"cur-"* ]]
  [[ "$output" != *"agent=claude teams="* ]]
  who cursor CLAUDE_CODE_SESSION_ID=sess-X
  [[ "$output" != *"teams=s-sess-X"* ]]
}

@test "whoami: both hosts' session ids at once is ambiguous and yields no session team" {
  who claude-code CLAUDE_CODE_SESSION_ID=sess-X CURSOR_CONVERSATION_ID="$CUR_A"
  [[ "$output" != *"teams=s-"* ]]
  [[ "$output" != *"teams=cur-"* ]]
  who cursor CLAUDE_CODE_SESSION_ID=sess-X CURSOR_CONVERSATION_ID="$CUR_A"
  [[ "$output" != *"teams=s-"* ]]
  [[ "$output" != *"teams=cur-"* ]]
}

@test "whoami: no session env at all falls back to project resolution" {
  bash "$SCRIPTS/join.sh" base alice cursor "$PROJ" >/dev/null
  who cursor
  [[ "$output" == *"teams=base"* ]]
}

@test "whoami: an unusable cursor id (not a uuid) is not turned into a team" {
  bash "$SCRIPTS/join.sh" base alice cursor "$PROJ" >/dev/null
  who cursor CURSOR_CONVERSATION_ID=sess-X
  [[ "$output" == *"teams=base"* ]]
}

@test "whoami: session-team mode off ignores both envs" {
  bash "$SCRIPTS/config.sh" set delivery.session_team false >/dev/null
  bash "$SCRIPTS/join.sh" base alice cursor "$PROJ" >/dev/null
  who cursor CURSOR_CONVERSATION_ID="$CUR_A"
  [[ "$output" == *"teams=base"* ]]
}

# --- classification ----------------------------------------------------------

@test "class: legacy s-<id> is a session team by name; a plain project team is not" {
  [ "$(agmsg_session_team_class s-sess-X)" = session ]
  [ "$(agmsg_session_team_class myproject)" = project ]
}

@test "class: a cur-<uuid> team is a session team only with a marker naming cursor" {
  mkdir -p "$TEST_SKILL_DIR/teams/cur-$CUR_A"
  [ "$(agmsg_session_team_class "cur-$CUR_A")" = project ]
  printf 'cursor' > "$TEST_SKILL_DIR/teams/cur-$CUR_A/.session-team"
  [ "$(agmsg_session_team_class "cur-$CUR_A")" = session ]
  printf 'codex' > "$TEST_SKILL_DIR/teams/cur-$CUR_A/.session-team"
  [ "$(agmsg_session_team_class "cur-$CUR_A")" = unknown ]
}

@test "class: an unreadable marker is unknown, never project" {
  mkdir -p "$TEST_SKILL_DIR/teams/cur-$CUR_A/.session-team"
  [ "$(agmsg_session_team_class "cur-$CUR_A")" = unknown ]
}

@test "class: a project team that merely joined an agent called cursor-host stays a project team" {
  bash "$SCRIPTS/join.sh" "cur-$CUR_A" cursor-host cursor "$PROJ" >/dev/null
  [ "$(agmsg_session_team_class "cur-$CUR_A")" = project ]
}

# --- join.sh session marker --------------------------------------------------

@test "join marker: a new team gets the marker, then the seat" {
  AGMSG_JOIN_SESSION_MARKER=cursor bash "$SCRIPTS/join.sh" "cur-$CUR_A" cursor-host cursor "$PROJ" >/dev/null
  [ "$(cat "$TEST_SKILL_DIR/teams/cur-$CUR_A/.session-team")" = cursor ]
  [ -f "$TEST_SKILL_DIR/teams/cur-$CUR_A/config.json" ]
  # a second start is idempotent
  AGMSG_JOIN_SESSION_MARKER=cursor bash "$SCRIPTS/join.sh" "cur-$CUR_A" cursor-host cursor "$PROJ" >/dev/null
}

@test "join marker: an existing project team of the same name is refused and left untouched" {
  bash "$SCRIPTS/join.sh" "cur-$CUR_A" alice cursor "$PROJ" >/dev/null
  run env AGMSG_JOIN_SESSION_MARKER=cursor bash "$SCRIPTS/join.sh" "cur-$CUR_A" cursor-host cursor "$PROJ"
  [ "$status" -ne 0 ]
  [ ! -e "$TEST_SKILL_DIR/teams/cur-$CUR_A/.session-team" ]
  ! grep -q cursor-host "$TEST_SKILL_DIR/teams/cur-$CUR_A/config.json"
}

@test "join marker: a marker without a config (interrupted join) is completed by the next join" {
  mkdir -p "$TEST_SKILL_DIR/teams/cur-$CUR_A"
  printf 'cursor' > "$TEST_SKILL_DIR/teams/cur-$CUR_A/.session-team"
  AGMSG_JOIN_SESSION_MARKER=cursor bash "$SCRIPTS/join.sh" "cur-$CUR_A" cursor-host cursor "$PROJ" >/dev/null
  [ -f "$TEST_SKILL_DIR/teams/cur-$CUR_A/config.json" ]
}

@test "join marker: a marker naming another host or a symlinked marker is refused" {
  mkdir -p "$TEST_SKILL_DIR/teams/cur-$CUR_A"
  printf 'codex' > "$TEST_SKILL_DIR/teams/cur-$CUR_A/.session-team"
  run env AGMSG_JOIN_SESSION_MARKER=cursor bash "$SCRIPTS/join.sh" "cur-$CUR_A" cursor-host cursor "$PROJ"
  [ "$status" -ne 0 ]
  mkdir -p "$TEST_SKILL_DIR/teams/cur-$CUR_B"
  ln -s /nonexistent "$TEST_SKILL_DIR/teams/cur-$CUR_B/.session-team"
  run env AGMSG_JOIN_SESSION_MARKER=cursor bash "$SCRIPTS/join.sh" "cur-$CUR_B" cursor-host cursor "$PROJ"
  [ "$status" -ne 0 ]
}

# --- send.sh cross-session guard --------------------------------------------

sendas() {  # sendas <team> [VAR=value ...]  -- sends human -> the team's seat
  local team="$1" seat; shift
  case "$team" in cur-*) seat=cursor-host ;; *) seat=claude ;; esac
  run env -u CLAUDE_CODE_SESSION_ID -u CURSOR_CONVERSATION_ID "$@" \
    bash "$SCRIPTS/send.sh" "$team" human "$seat" "hello"
}

@test "send guard: a session may address its own team" {
  mk_claude_team sess-A; mk_cursor_team "$CUR_A"
  sendas s-sess-A CLAUDE_CODE_SESSION_ID=sess-A;            [ "$status" -eq 0 ]
  sendas "cur-$CUR_A" CURSOR_CONVERSATION_ID="$CUR_A";      [ "$status" -eq 0 ]
}

@test "send guard: a session may not address another session's team, on either host" {
  mk_claude_team sess-A; mk_claude_team sess-B; mk_cursor_team "$CUR_A"; mk_cursor_team "$CUR_B"
  sendas s-sess-B CLAUDE_CODE_SESSION_ID=sess-A;            [ "$status" -ne 0 ]
  sendas "cur-$CUR_A" CLAUDE_CODE_SESSION_ID=sess-A;        [ "$status" -ne 0 ]
  sendas "cur-$CUR_B" CURSOR_CONVERSATION_ID="$CUR_A";      [ "$status" -ne 0 ]
  sendas s-sess-A CURSOR_CONVERSATION_ID="$CUR_A";          [ "$status" -ne 0 ]
}

@test "send guard: a project team is never restricted, and a caller with no identity is not guarded" {
  bash "$SCRIPTS/join.sh" proj human cursor "$PROJ" >/dev/null
  bash "$SCRIPTS/join.sh" proj bob cursor "$PROJ" >/dev/null
  run env CURSOR_CONVERSATION_ID="$CUR_A" bash "$SCRIPTS/send.sh" proj human bob hi
  [ "$status" -eq 0 ]
  mk_cursor_team "$CUR_A"
  sendas "cur-$CUR_A";                                      [ "$status" -eq 0 ]
}

@test "send guard: two hosts' ids at once may not address any session team" {
  mk_claude_team sess-A; mk_cursor_team "$CUR_A"
  sendas s-sess-A CLAUDE_CODE_SESSION_ID=sess-A CURSOR_CONVERSATION_ID="$CUR_A"; [ "$status" -ne 0 ]
  sendas "cur-$CUR_A" CLAUDE_CODE_SESSION_ID=sess-A CURSOR_CONVERSATION_ID="$CUR_A"; [ "$status" -ne 0 ]
}

@test "send guard: a uuid-shaped project team without the marker is not treated as a session team" {
  bash "$SCRIPTS/join.sh" "cur-$CUR_B" human cursor "$PROJ" >/dev/null
  bash "$SCRIPTS/join.sh" "cur-$CUR_B" bob cursor "$PROJ" >/dev/null
  run env CURSOR_CONVERSATION_ID="$CUR_A" bash "$SCRIPTS/send.sh" "cur-$CUR_B" human bob hi
  [ "$status" -eq 0 ]
}

@test "send guard: an unreadable marker fails closed for an identified caller" {
  mkdir -p "$TEST_SKILL_DIR/teams/cur-$CUR_B/.session-team"
  run env CURSOR_CONVERSATION_ID="$CUR_A" bash "$SCRIPTS/send.sh" "cur-$CUR_B" human bob hi --force
  [ "$status" -ne 0 ]
}

@test "send guard: AGMSG_ALLOW_CROSS_TEAM=1 and session-team mode off both bypass it" {
  mk_claude_team sess-B
  sendas s-sess-B CLAUDE_CODE_SESSION_ID=sess-A AGMSG_ALLOW_CROSS_TEAM=1; [ "$status" -eq 0 ]
  bash "$SCRIPTS/config.sh" set delivery.session_team false >/dev/null
  sendas s-sess-B CLAUDE_CODE_SESSION_ID=sess-A;                          [ "$status" -eq 0 ]
}

# --- headless worker provenance ---------------------------------------------

# start a stand-in bridge: a process that publishes <sid> -> <team> and stays alive
start_bridge() {
  local sid="$1" team="$2"
  bash -c "
    export SKILL_DIR='$TEST_SKILL_DIR'
    source '$SCRIPTS/lib/compat.sh'; source '$SCRIPTS/lib/instance-id.sh'
    source '$SCRIPTS/lib/headless-provenance.sh'
    agmsg_headless_provenance_publish '$sid' '$team' && echo published
    sleep 60
  " > "$BATS_TEST_TMPDIR/bridge.$sid.out" 2>&1 &
  BRIDGE_PID=$!
  wait_until 10 grep -q published "$BATS_TEST_TMPDIR/bridge.$sid.out"
}

@test "provenance: a resumed worker (its own sid in the env) may reply to the team its bridge serves" {
  mk_claude_team parent
  start_bridge worker-sid s-parent
  sendas s-parent CLAUDE_CODE_SESSION_ID=worker-sid
  kill "$BRIDGE_PID" 2>/dev/null || true
  [ "$status" -eq 0 ]
}

@test "provenance: the same sid may not reach another session's team" {
  mk_claude_team parent; mk_claude_team other
  start_bridge worker-sid s-parent
  sendas s-other CLAUDE_CODE_SESSION_ID=worker-sid
  kill "$BRIDGE_PID" 2>/dev/null || true
  [ "$status" -ne 0 ]
}

@test "provenance: a worker whose env also carries a cursor id is still recognised by its record" {
  mk_cursor_team "$CUR_A"
  start_bridge worker-sid "cur-$CUR_A"
  sendas "cur-$CUR_A" CLAUDE_CODE_SESSION_ID=worker-sid CURSOR_CONVERSATION_ID="$CUR_A"
  kill "$BRIDGE_PID" 2>/dev/null || true
  [ "$status" -eq 0 ]
}

@test "provenance: no record, or a record whose bridge is dead, authorizes nothing" {
  mk_claude_team parent
  sendas s-parent CLAUDE_CODE_SESSION_ID=worker-sid
  [ "$status" -ne 0 ]
  start_bridge worker-sid s-parent
  kill "$BRIDGE_PID" 2>/dev/null || true
  wait "$BRIDGE_PID" 2>/dev/null || true
  sendas s-parent CLAUDE_CODE_SESSION_ID=worker-sid
  [ "$status" -ne 0 ]
}

@test "provenance: a recycled pid (start token mismatch) authorizes nothing" {
  mk_claude_team parent
  start_bridge worker-sid s-parent
  sed -i.bak 's/^start=.*/start=proc:1/' "$TEST_SKILL_DIR/run/headless-sid.worker-sid.$BRIDGE_PID"
  sendas s-parent CLAUDE_CODE_SESSION_ID=worker-sid
  kill "$BRIDGE_PID" 2>/dev/null || true
  [ "$status" -ne 0 ]
}

@test "provenance: each owner keeps its own record; a third process's cleanup removes neither" {
  start_bridge worker-sid s-parent
  local first="$BRIDGE_PID"
  start_bridge worker-sid s-parent
  local second="$BRIDGE_PID"
  [ -f "$TEST_SKILL_DIR/run/headless-sid.worker-sid.$first" ]
  [ -f "$TEST_SKILL_DIR/run/headless-sid.worker-sid.$second" ]
  run bash -c "
    export SKILL_DIR='$TEST_SKILL_DIR'
    source '$SCRIPTS/lib/compat.sh'; source '$SCRIPTS/lib/instance-id.sh'
    source '$SCRIPTS/lib/headless-provenance.sh'
    agmsg_headless_provenance_remove worker-sid
  "
  [ -f "$TEST_SKILL_DIR/run/headless-sid.worker-sid.$first" ]
  [ -f "$TEST_SKILL_DIR/run/headless-sid.worker-sid.$second" ]
  kill "$first" "$second" 2>/dev/null || true
}

@test "provenance: an owner's own cleanup removes only its record, leaving a newer owner's" {
  start_bridge worker-sid s-parent
  local first="$BRIDGE_PID"
  start_bridge worker-sid s-parent
  local second="$BRIDGE_PID"
  # emulate the first owner's cleanup: same pid as its record
  rm -f "$TEST_SKILL_DIR/run/headless-sid.worker-sid.$first"
  mk_claude_team parent
  sendas s-parent CLAUDE_CODE_SESSION_ID=worker-sid
  kill "$first" "$second" 2>/dev/null || true
  [ "$status" -eq 0 ]
}

@test "provenance: a record without a start token is never published and never accepted" {
  run bash -c "
    export SKILL_DIR='$TEST_SKILL_DIR'
    source '$SCRIPTS/lib/compat.sh'; source '$SCRIPTS/lib/instance-id.sh'
    source '$SCRIPTS/lib/headless-provenance.sh'
    agmsg_pid_start_token() { return 1; }
    agmsg_headless_provenance_publish worker-sid s-parent
  "
  [ "$status" -ne 0 ]
  ls "$TEST_SKILL_DIR"/run/headless-sid.worker-sid.* 2>/dev/null && return 1
  mkdir -p "$TEST_SKILL_DIR/run"
  sleep 30 & local live=$!
  printf 'team=s-parent\npid=%s\nstart=\n' "$live" > "$TEST_SKILL_DIR/run/headless-sid.worker-sid.$live"
  run bash -c "
    export SKILL_DIR='$TEST_SKILL_DIR'
    source '$SCRIPTS/lib/compat.sh'; source '$SCRIPTS/lib/instance-id.sh'
    source '$SCRIPTS/lib/headless-provenance.sh'
    agmsg_headless_provenance_allows worker-sid s-parent
  "
  kill "$live" 2>/dev/null || true
  [ "$status" -ne 0 ]
}

@test "provenance: the record is private, written through an unpredictable temp, and a symlink in its place is not followed" {
  start_bridge worker-sid s-parent
  local rec="$TEST_SKILL_DIR/run/headless-sid.worker-sid.$BRIDGE_PID"
  [ "$(stat -f %Lp "$rec" 2>/dev/null || stat -c %a "$rec")" = 600 ]
  kill "$BRIDGE_PID" 2>/dev/null || true
  mv "$rec" "$TEST_SKILL_DIR/run/real"
  ln -s "$TEST_SKILL_DIR/run/real" "$rec"
  run bash -c "
    export SKILL_DIR='$TEST_SKILL_DIR'
    source '$SCRIPTS/lib/compat.sh'; source '$SCRIPTS/lib/instance-id.sh'
    source '$SCRIPTS/lib/headless-provenance.sh'
    agmsg_headless_provenance_allows worker-sid s-parent
  "
  [ "$status" -ne 0 ]
}

@test "provenance: a link planted where the record will land is replaced, never written through" {
  local victim="$BATS_TEST_TMPDIR/victim"
  printf 'keep' > "$victim"
  mkdir -p "$TEST_SKILL_DIR/run"
  run bash -c "
    export SKILL_DIR='$TEST_SKILL_DIR'
    source '$SCRIPTS/lib/compat.sh'; source '$SCRIPTS/lib/instance-id.sh'
    source '$SCRIPTS/lib/headless-provenance.sh'
    ln -s '$victim' \"\$SKILL_DIR/run/headless-sid.worker-sid.\$\$\"
    agmsg_headless_provenance_publish worker-sid s-parent
  "
  [ "$status" -eq 0 ]
  [ "$(cat "$victim")" = keep ]
}

# --- SessionStart / SessionEnd for a Cursor session --------------------------

@test "session-start (cursor): registers cur-<uuid> with the cursor-host seat and a marker, never claude" {
  run env -u CLAUDE_CODE_SESSION_ID bash "$SCRIPTS/session-start.sh" cursor "$PROJ" \
    <<< "{\"session_id\":\"$CUR_A\",\"conversation_id\":\"$CUR_A\"}"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_SKILL_DIR/teams/cur-$CUR_A/.session-team")" = cursor ]
  grep -q cursor-host "$TEST_SKILL_DIR/teams/cur-$CUR_A/config.json"
  ! grep -q '"claude"' "$TEST_SKILL_DIR/teams/cur-$CUR_A/config.json"
  [ ! -d "$TEST_SKILL_DIR/teams/s-$CUR_A" ]
}

@test "session-start (cursor): a conversation_id that disagrees with session_id is refused" {
  run env -u CLAUDE_CODE_SESSION_ID bash "$SCRIPTS/session-start.sh" cursor "$PROJ" \
    <<< "{\"session_id\":\"$CUR_A\",\"conversation_id\":\"$CUR_B\"}"
  [ "$status" -eq 0 ]
  [ ! -d "$TEST_SKILL_DIR/teams/cur-$CUR_A" ]
  [ ! -d "$TEST_SKILL_DIR/teams/cur-$CUR_B" ]
}

@test "session-start (cursor): a non-string, null, empty, padded or whitespace alternate id is refused" {
  for alt in '""' '" "' "\" $CUR_A\"" "\"$CUR_A \"" '5' 'null'; do
    run env -u CLAUDE_CODE_SESSION_ID bash "$SCRIPTS/session-start.sh" cursor "$PROJ" \
      <<< "{\"session_id\":\"$CUR_A\",\"conversation_id\":$alt}"
    [ "$status" -eq 0 ]
    [ ! -d "$TEST_SKILL_DIR/teams/cur-$CUR_A" ]
  done
}

@test "session-start (cursor): a session id that is not a uuid is refused" {
  run env -u CLAUDE_CODE_SESSION_ID bash "$SCRIPTS/session-start.sh" cursor "$PROJ" \
    <<< '{"session_id":"sess-X"}'
  [ "$status" -eq 0 ]
  [ ! -d "$TEST_SKILL_DIR/teams/cur-sess-X" ]
  [ ! -d "$TEST_SKILL_DIR/teams/s-sess-X" ]
}

@test "session-start (cursor): an existing project team with the same name is not converted" {
  bash "$SCRIPTS/join.sh" "cur-$CUR_A" alice cursor "$PROJ" >/dev/null
  run env -u CLAUDE_CODE_SESSION_ID bash "$SCRIPTS/session-start.sh" cursor "$PROJ" \
    <<< "{\"session_id\":\"$CUR_A\"}"
  [ "$status" -eq 0 ]
  [ ! -e "$TEST_SKILL_DIR/teams/cur-$CUR_A/.session-team" ]
  ! grep -q cursor-host "$TEST_SKILL_DIR/teams/cur-$CUR_A/config.json"
  [[ "$output" != *"--team cur-$CUR_A"* ]]
}

@test "session-end (cursor): the tombstone and snapshot are keyed on cur-<uuid>" {
  mkdir -p "$TEST_SKILL_DIR/run"
  agmsg_test_start_session_owner
  printf '{"session_id":"%s"}' "$CUR_A" | env -u CLAUDE_CODE_SESSION_ID \
    bash "$SCRIPTS/session-end.sh" cursor "$PROJ" 2>/dev/null
  agmsg_test_stop_session_owner
  [ -f "$TEST_SKILL_DIR/run/watchdog.cur-$CUR_A.tombstone" ]
  [ ! -e "$TEST_SKILL_DIR/run/watchdog.s-$CUR_A.tombstone" ]
}

@test "watchdog: a project team and a marker-less cur-<uuid> team are refused, a marked one is not" {
  run bash "$SCRIPTS/watchdog.sh" myproject
  [ "$status" -ne 0 ]
  mkdir -p "$TEST_SKILL_DIR/teams/cur-$CUR_A"
  run bash "$SCRIPTS/watchdog.sh" "cur-$CUR_A"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a session-team name"* ]]
}

# --- children never inherit a session id ------------------------------------

@test "unset: every host's session id is dropped for a launched child, nothing else" {
  run env CLAUDE_CODE_SESSION_ID=a CURSOR_CONVERSATION_ID="$CUR_A" AGMSG_CODEX_KEEP=1 bash -c "
    SCRIPT_DIR='$SCRIPTS'; source '$SCRIPTS/lib/session-team.sh'
    agmsg_session_unset_env
    echo \"[\${CLAUDE_CODE_SESSION_ID:-}][\${CURSOR_CONVERSATION_ID:-}][\${AGMSG_CODEX_KEEP:-}]\""
  [ "$output" = "[][][1]" ]
}

# --- rename-team.sh ----------------------------------------------------------

@test "rename: a marked host session team is refused as source and as target" {
  mk_cursor_team "$CUR_A"
  run bash "$SCRIPTS/rename-team.sh" "cur-$CUR_A" renamed
  [ "$status" -ne 0 ]
  [ -f "$TEST_SKILL_DIR/teams/cur-$CUR_A/config.json" ]
  bash "$SCRIPTS/join.sh" plain alice cursor "$PROJ" >/dev/null
  run bash "$SCRIPTS/rename-team.sh" plain "cur-$CUR_A"
  [ "$status" -ne 0 ]
  mkdir -p "$TEST_SKILL_DIR/teams/cur-$CUR_B"
  printf 'cursor' > "$TEST_SKILL_DIR/teams/cur-$CUR_B/.session-team"
  run bash "$SCRIPTS/rename-team.sh" plain "cur-$CUR_B"
  [ "$status" -ne 0 ]
  [ -f "$TEST_SKILL_DIR/teams/plain/config.json" ]
}

@test "rename: an ordinary project team still renames" {
  bash "$SCRIPTS/join.sh" plain alice cursor "$PROJ" >/dev/null
  run bash "$SCRIPTS/rename-team.sh" plain renamed
  [ "$status" -eq 0 ]
  [ -f "$TEST_SKILL_DIR/teams/renamed/config.json" ]
}
