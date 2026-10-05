#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
  PROJ="$BATS_TEST_TMPDIR/project with spaces"
  mkdir -p "$PROJ"
  bash "$SCRIPTS/config.sh" set delivery.session_team true >/dev/null
}

teardown() { teardown_test_env; }

write_pgrep_stub() {
  local mode="$1" stub_bin="$TEST_SKILL_DIR/stub-bin"
  mkdir -p "$stub_bin"
  case "$mode" in
    match)
      cat > "$stub_bin/pgrep" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"$EXPECTED_BRIDGE"*"--identity-key $EXPECTED_IDENTITY_KEY"*) exit 0 ;;
  *) exit 1 ;;
esac
STUB
      ;;
    miss)
      cat > "$stub_bin/pgrep" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
      ;;
    wrong)
      cat > "$stub_bin/pgrep" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"$EXPECTED_BRIDGE"*"--identity-key wrong:"*) exit 0 ;;
  *) exit 1 ;;
esac
STUB
      ;;
  esac
  chmod +x "$stub_bin/pgrep"
  printf '%s\n' "$stub_bin"
}

write_spawn_stub() {
  local status="$1" stub="$TEST_SKILL_DIR/scripts/spawn.sh"
  cat > "$stub" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TEST_SKILL_DIR/spawn.args"
exit $status
STUB
  chmod +x "$stub"
}

enable_claude_headless_fixture() {
  cat > "$TYPES/claude-code/type.conf" <<'CONF'
name=claude-code
spawnable=yes
headless=yes
session_env=CLAUDE_CODE_SESSION_ID
session_team_prefix=s-
session_seat=claude
CONF
}

@test "ensure-codex: preserves no-op behavior outside session-team mode" {
  bash "$SCRIPTS/config.sh" set delivery.session_team false >/dev/null
  run env CLAUDE_CODE_SESSION_ID=sess-X bash "$SCRIPTS/ensure-codex.sh" "$PROJ"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "ensure-codex: delegates with default codex name and preserves spawn args" {
  local stub_bin
  stub_bin="$(write_pgrep_stub miss)"
  write_spawn_stub 37
  run env PATH="$stub_bin:$PATH" CLAUDE_CODE_SESSION_ID=sess-CODEX \
    bash "$SCRIPTS/ensure-codex.sh" "$PROJ"
  [ "$status" -eq 1 ]
  [[ "$output" == *"failed to spawn codex 'codex'"* ]]
  grep -q -- "codex codex --team s-sess-CODEX --project $PROJ --headless" "$TEST_SKILL_DIR/spawn.args"
}

@test "ensure-headless: claude-code uses its type bridge and explicit name" {
  enable_claude_headless_fixture
  local stub_bin
  stub_bin="$(write_pgrep_stub miss)"
  write_spawn_stub 0
  run env PATH="$stub_bin:$PATH" CLAUDE_CODE_SESSION_ID=sess-CLAUDE \
    bash "$SCRIPTS/ensure-headless.sh" claude-code "$PROJ" reviewer
  [ "$status" -eq 0 ]
  [[ "$output" == *"spawned headless claude-code 'reviewer'"* ]]
  grep -q -- "claude-code reviewer --team s-sess-CLAUDE --project $PROJ --headless" "$TEST_SKILL_DIR/spawn.args"
}

@test "ensure-headless: claude-code duplicate scan uses the claude-code-bridge token" {
  enable_claude_headless_fixture
  local stub_bin="$TEST_SKILL_DIR/claude-stub-bin"
  mkdir -p "$stub_bin"
  cat > "$stub_bin/pgrep" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *claude-code-bridge*--identity-key*) exit 0 ;;
  *) exit 1 ;;
esac
STUB
  chmod +x "$stub_bin/pgrep"
  run env PATH="$stub_bin:$PATH" CLAUDE_CODE_SESSION_ID=sess-CLAUDE-LIVE \
    bash "$SCRIPTS/ensure-headless.sh" claude-code "$PROJ"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already running"* ]]
}

@test "ensure-headless: live matching bridge skips spawn" {
  local key stub_bin
  key="$(source "$SCRIPTS/lib/identity-key.sh"; agmsg_identity_key s-sess-LIVE codex)"
  stub_bin="$(write_pgrep_stub match)"
  write_spawn_stub 37
  run env PATH="$stub_bin:$PATH" EXPECTED_BRIDGE='codex-bridge\.js' \
    EXPECTED_IDENTITY_KEY="$key" CLAUDE_CODE_SESSION_ID=sess-LIVE \
    bash "$SCRIPTS/ensure-headless.sh" codex "$PROJ"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already running"* ]]
  [ ! -e "$TEST_SKILL_DIR/spawn.args" ]
}

@test "ensure-headless: wrong identity or dead scan result spawns" {
  local key stub_bin
  key="$(source "$SCRIPTS/lib/identity-key.sh"; agmsg_identity_key s-sess-WRONG codex)"
  stub_bin="$(write_pgrep_stub wrong)"
  write_spawn_stub 0
  run env PATH="$stub_bin:$PATH" EXPECTED_BRIDGE='codex-bridge\.js' \
    EXPECTED_IDENTITY_KEY="$key" CLAUDE_CODE_SESSION_ID=sess-WRONG \
    bash "$SCRIPTS/ensure-headless.sh" codex "$PROJ" worker
  [ "$status" -eq 0 ]
  [[ "$output" == *"spawned headless codex 'worker'"* ]]
  grep -q -- "codex worker --team s-sess-WRONG --project $PROJ --headless" "$TEST_SKILL_DIR/spawn.args"
}

@test "ensure-headless: concurrent fresh lock contenders allow one spawn" {
  local stub_bin="$TEST_SKILL_DIR/stub-bin" pid1 pid2 status1 status2
  local spawn_release="$TEST_SKILL_DIR/spawn.release"
  mkdir -p "$stub_bin"
  mkfifo "$spawn_release"
  write_pgrep_stub miss >/dev/null
  cat > "$SCRIPTS/spawn.sh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TEST_SKILL_DIR/spawn.args"
: > "$TEST_SKILL_DIR/spawn.entered"
IFS= read -r _ < "${spawn_release}"
exit 0
STUB
  chmod +x "$SCRIPTS/spawn.sh"

  env PATH="$stub_bin:$PATH" CLAUDE_CODE_SESSION_ID=sess-FRESH \
    bash "$SCRIPTS/ensure-headless.sh" codex "$PROJ" >"$TEST_SKILL_DIR/out1" 2>&1 &
  pid1=$!
  # Establish pid1 as the winner before introducing the second contender.
  wait_for_file "$TEST_SKILL_DIR/spawn.entered"
  env PATH="$stub_bin:$PATH" CLAUDE_CODE_SESSION_ID=sess-FRESH \
    bash "$SCRIPTS/ensure-headless.sh" codex "$PROJ" >"$TEST_SKILL_DIR/out2" 2>&1 &
  pid2=$!
  # pid1 remains blocked in the FIFO while pid2 observes the fresh lock.
  wait_for_file_contains "$TEST_SKILL_DIR/out2" "spawn already in flight"
  status2=0; wait "$pid2" || status2=$?
  [ "$status2" -eq 0 ]
  kill -0 "$pid1" 2>/dev/null
  printf '\n' > "$spawn_release"
  status1=0; wait "$pid1" || status1=$?

  [ "$status1" -eq 0 ]
  [ "$(grep -c '^codex codex ' "$TEST_SKILL_DIR/spawn.args")" -eq 1 ]
  grep -q "spawned headless codex 'codex'" "$TEST_SKILL_DIR/out1"
  grep -q "spawn already in flight" "$TEST_SKILL_DIR/out2"
}

@test "ensure-headless: stale lock is reclaimed before spawning" {
  local stub_bin="$TEST_SKILL_DIR/stub-bin"
  local lock="$TEST_SKILL_DIR/run/ensure-codex.s-sess-STALE__codex.lock"
  mkdir -p "$stub_bin" "$lock"
  touch -t 200001010000 "$lock"
  write_pgrep_stub miss >/dev/null
  write_spawn_stub 0
  run env PATH="$stub_bin:$PATH" CLAUDE_CODE_SESSION_ID=sess-STALE \
    bash "$SCRIPTS/ensure-headless.sh" codex "$PROJ"
  [ "$status" -eq 0 ]
  [[ "$output" == *"spawned headless codex 'codex'"* ]]
  grep -q -- "codex codex --team s-sess-STALE --project $PROJ --headless" "$TEST_SKILL_DIR/spawn.args"
}

# Plant a lock owned by <pid> (token optional), back-dated far past any age limit.
plant_lock() {
  local team_sess="$1" pid="$2" tok="${3:-}"
  PLANTED_LOCK="$TEST_SKILL_DIR/run/ensure-codex.s-${team_sess}__codex.lock"
  mkdir -p "$PLANTED_LOCK"
  printf '%s\n%s\n' "$pid" "$tok" > "$PLANTED_LOCK/owner.$pid.1"
  touch -t 200001010000 "$PLANTED_LOCK/owner.$pid.1" "$PLANTED_LOCK"
}

@test "ensure-headless: lock of a live owner is kept however old it is" {
  local stub_bin="$TEST_SKILL_DIR/stub-bin"
  write_pgrep_stub miss >/dev/null
  write_spawn_stub 0
  sleep 30 & local owner=$!
  local live_tok
  live_tok="$(SKILL_DIR="$TEST_SKILL_DIR" bash -c 'source "$1"; agmsg_pid_start_token "$2"' _ "$SCRIPTS/lib/instance-id.sh" "$owner")"
  [ -n "$live_tok" ]
  plant_lock sess-LIVE "$owner" "$live_tok"
  run env PATH="$stub_bin:$PATH" CLAUDE_CODE_SESSION_ID=sess-LIVE \
    bash "$SCRIPTS/ensure-headless.sh" codex "$PROJ"
  kill "$owner" 2>/dev/null || true
  [ "$status" -eq 0 ]
  [[ "$output" == *"spawn already in flight"* ]]
  [ ! -e "$TEST_SKILL_DIR/spawn.args" ]
  [ -d "$PLANTED_LOCK" ]
}

@test "ensure-headless: lock of a dead owner is reclaimed" {
  local stub_bin="$TEST_SKILL_DIR/stub-bin"
  write_pgrep_stub miss >/dev/null
  write_spawn_stub 0
  sleep 0.1 & local owner=$!
  wait "$owner"
  plant_lock sess-DEAD "$owner"
  # Fresh mtimes: death alone, not age, must free it.
  touch "$PLANTED_LOCK" "$PLANTED_LOCK"/owner.*
  run env PATH="$stub_bin:$PATH" CLAUDE_CODE_SESSION_ID=sess-DEAD \
    bash "$SCRIPTS/ensure-headless.sh" codex "$PROJ"
  [ "$status" -eq 0 ]
  [[ "$output" == *"spawned headless codex 'codex'"* ]]
}

@test "ensure-headless: lock whose pid was recycled is reclaimed" {
  local stub_bin="$TEST_SKILL_DIR/stub-bin"
  write_pgrep_stub miss >/dev/null
  write_spawn_stub 0
  sleep 30 & local owner=$!
  # Same acquisition method as the live token, different start time.
  local live_tok
  live_tok="$(SKILL_DIR="$TEST_SKILL_DIR" bash -c 'source "$1"; agmsg_pid_start_token "$2"' _ "$SCRIPTS/lib/instance-id.sh" "$owner")"
  plant_lock sess-RECYCLED "$owner" "${live_tok}-old"
  run env PATH="$stub_bin:$PATH" CLAUDE_CODE_SESSION_ID=sess-RECYCLED \
    bash "$SCRIPTS/ensure-headless.sh" codex "$PROJ"
  kill "$owner" 2>/dev/null || true
  [ "$status" -eq 0 ]
  [[ "$output" == *"spawned headless codex 'codex'"* ]]
}

@test "ensure-headless: a start token from another method does not mark a live owner recycled" {
  local stub_bin="$TEST_SKILL_DIR/stub-bin"
  write_pgrep_stub miss >/dev/null
  write_spawn_stub 0
  sleep 30 & local owner=$!
  plant_lock sess-METHOD "$owner" "windows:1"
  run env PATH="$stub_bin:$PATH" CLAUDE_CODE_SESSION_ID=sess-METHOD \
    bash "$SCRIPTS/ensure-headless.sh" codex "$PROJ"
  kill "$owner" 2>/dev/null || true
  [ "$status" -eq 0 ]
  [[ "$output" == *"spawn already in flight"* ]]
  [ ! -e "$TEST_SKILL_DIR/spawn.args" ]
}

@test "ensure-headless: a fresh unreadable owner record is not reclaimed" {
  local stub_bin="$TEST_SKILL_DIR/stub-bin"
  local lock="$TEST_SKILL_DIR/run/ensure-codex.s-sess-JUNK__codex.lock"
  write_pgrep_stub miss >/dev/null
  write_spawn_stub 0
  mkdir -p "$lock"
  : > "$lock/owner.0.1"
  run env PATH="$stub_bin:$PATH" CLAUDE_CODE_SESSION_ID=sess-JUNK \
    bash "$SCRIPTS/ensure-headless.sh" codex "$PROJ"
  [ "$status" -eq 0 ]
  [[ "$output" == *"spawn already in flight"* ]]
  [ -d "$lock" ]
}

@test "ensure-headless: the lock is removed after the spawn" {
  local stub_bin="$TEST_SKILL_DIR/stub-bin"
  write_pgrep_stub miss >/dev/null
  write_spawn_stub 0
  run env PATH="$stub_bin:$PATH" CLAUDE_CODE_SESSION_ID=sess-REL \
    bash "$SCRIPTS/ensure-headless.sh" codex "$PROJ"
  [ "$status" -eq 0 ]
  [ ! -e "$TEST_SKILL_DIR/run/ensure-codex.s-sess-REL__codex.lock" ]
}

@test "ensure-headless: rejects an invalid type" {
  run bash "$SCRIPTS/ensure-headless.sh" bogus "$PROJ"
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown agent type"* ]]
}

# ---- empty-token owner records (#58) ----

REC_MTIME=1700000000  # fixed record mtime; "now" and ps etime are stubbed around it

# ps/date/stat/ls stubs: each answers only the query it is told to fake and
# delegates every other call to the real binary.
write_clock_stubs() {
  local stub_bin="$TEST_SKILL_DIR/stub-bin" name
  mkdir -p "$stub_bin"
  cat > "$stub_bin/stub" <<'STUB'
#!/usr/bin/env bash
cmd="$(basename "$0")"
real_var="STUB_REAL_$(printf '%s' "$cmd" | tr a-z A-Z)"
case "$cmd" in
  ps)
    case "$*" in *etime*)
      [ -z "${T_PS_ADVANCE:-}" ] || printf '%s' "$T_PS_ADVANCE" > "$T_NOW_FILE"
      printf '%s' "${T_ETIME-}"; exit "${T_ETIME_RC:-0}" ;;
    esac ;;
  date)
    if [ "$*" = "+%s" ] && [ -n "${T_NOW_FILE:-}" ]; then
      cat "$T_NOW_FILE"; exit "${T_NOW_RC:-0}"
    fi ;;
  stat)
    case "$1" in
      -c) if [ -n "${T_STAT_GNU+x}" ]; then printf '%s' "$T_STAT_GNU"; exit "${T_STAT_GNU_RC:-0}"; fi ;;
      -f) if [ -n "${T_STAT_BSD+x}" ]; then printf '%s' "$T_STAT_BSD"; exit "${T_STAT_BSD_RC:-0}"; fi ;;
    esac ;;
  ls)
    if [ "$1" = "-di" ] && [ -s "${T_LS_SEQ:-/nonexistent}" ]; then
      line="$(head -n 1 "$T_LS_SEQ")"; sed -i.bak 1d "$T_LS_SEQ"; rm -f "$T_LS_SEQ.bak"
      case "$line" in
        REAL) ;;
        EMPTY) exit 0 ;;
        RC1:*) printf '%s\n' "${line#RC1:}"; exit 1 ;;
        OUT:*) printf '%b\n' "${line#OUT:}"; exit 0 ;;
      esac
    fi ;;
esac
exec "${!real_var}" "$@"
STUB
  chmod +x "$stub_bin/stub"
  for name in ps date stat ls; do
    ln -sf stub "$stub_bin/$name"
    export "STUB_REAL_$(printf '%s' "$name" | tr a-z A-Z)=$(command -v "$name")"
  done
}

touch_epoch() {
  local ts
  ts="$(date -r "$1" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$1" +%Y%m%d%H%M.%S)"
  touch -t "$ts" "${@:2}"
}

assert_lock_kept() {
  [ "$status" -eq 0 ]
  [[ "$output" == *"spawn already in flight"* ]]
  [ ! -e "$TEST_SKILL_DIR/spawn.args" ]
  [ -d "$PLANTED_LOCK" ]
}

assert_lock_reaped() {
  [ "$status" -eq 0 ]
  [[ "$output" == *"spawned headless codex 'codex'"* ]]
}

# Run ensure-headless against an empty-token lock held by a live pid.
#   $1 now: "+N" = record mtime + N seconds, or a raw value for the date stub
#   $2 ps etime output; further args are env assignments for the stubs
#   RECORD_BODY overrides the record's bytes (default "<pid>\n\n")
run_empty_token() {
  local now="$1" etime="$2"; shift 2
  local stub_bin="$TEST_SKILL_DIR/stub-bin"
  write_pgrep_stub miss >/dev/null
  write_spawn_stub 0
  write_clock_stubs
  sleep 30 & local owner=$!
  plant_lock sess-EMPTY "$owner"
  if [ -n "${RECORD_BODY+x}" ]; then
    printf "$RECORD_BODY" "$owner" > "$PLANTED_LOCK/owner.$owner.1"
  fi
  touch_epoch "$REC_MTIME" "$PLANTED_LOCK/owner.$owner.1"
  case "$now" in +*) now=$((REC_MTIME + ${now#+})) ;; esac
  printf '%s' "$now" > "$TEST_SKILL_DIR/now"
  run env PATH="$stub_bin:$PATH" CLAUDE_CODE_SESSION_ID=sess-EMPTY \
    T_NOW_FILE="$TEST_SKILL_DIR/now" T_ETIME="$etime" "$@" \
    bash "$SCRIPTS/ensure-headless.sh" codex "$PROJ"
  kill "$owner" 2>/dev/null || true
}

@test "ensure-headless: a live owner with an empty token keeps its fresh lock" {
  local stub_bin="$TEST_SKILL_DIR/stub-bin"
  write_pgrep_stub miss >/dev/null
  write_spawn_stub 0
  sleep 30 & local owner=$!
  plant_lock sess-FRESH "$owner"
  touch "$PLANTED_LOCK" "$PLANTED_LOCK"/owner.*
  run env PATH="$stub_bin:$PATH" CLAUDE_CODE_SESSION_ID=sess-FRESH \
    bash "$SCRIPTS/ensure-headless.sh" codex "$PROJ"
  kill "$owner" 2>/dev/null || true
  assert_lock_kept
}

@test "ensure-headless: an empty-token lock whose pid now belongs to a newer process is reclaimed" {
  local stub_bin="$TEST_SKILL_DIR/stub-bin"
  write_pgrep_stub miss >/dev/null
  write_spawn_stub 0
  sleep 30 & local owner=$!
  # record mtime is 2000-01-01; the live holder started seconds ago
  plant_lock sess-ABA "$owner"
  run env PATH="$stub_bin:$PATH" CLAUDE_CODE_SESSION_ID=sess-ABA \
    bash "$SCRIPTS/ensure-headless.sh" codex "$PROJ"
  kill "$owner" 2>/dev/null || true
  assert_lock_reaped
}

# Holder started 600s before the observation; it is judged recycled only when
# that start is more than 120s after the record mtime.
@test "ensure-headless: empty token, holder started 119s after the record, keeps the lock" {
  run_empty_token +719 "10:00"
  assert_lock_kept
}

@test "ensure-headless: empty token, holder started 120s after the record, keeps the lock" {
  run_empty_token +720 "10:00"
  assert_lock_kept
}

@test "ensure-headless: empty token, holder started 121s after the record, is reclaimed" {
  run_empty_token +721 "10:00"
  assert_lock_reaped
}

@test "ensure-headless: etime 00:00 is read as zero seconds" {
  run_empty_token +121 "00:00"
  assert_lock_reaped
}

@test "ensure-headless: etime 08:09 is read in decimal" {
  run_empty_token +610 "08:09"
  assert_lock_reaped
}

@test "ensure-headless: etime hh:mm:ss is read as hours" {
  run_empty_token +3721 "  01:00:00 "
  assert_lock_reaped
}

@test "ensure-headless: etime dd-hh:mm:ss is read as days" {
  run_empty_token +86521 "1-00:00:00"
  assert_lock_reaped
}

# date is read before ps, so a ps that returns late cannot age a live holder.
@test "ensure-headless: now is read before ps, so a slow ps keeps the lock" {
  run_empty_token +720 "10:00" T_PS_ADVANCE=$((REC_MTIME + 1100))
  assert_lock_kept
}

# Known limit: etime counts elapsed time, the record mtime is wall clock, so a
# clock step between the two makes a live owner look recycled.
@test "ensure-headless: known limit, a wall-clock step of 70s twice frees a live owner's lock" {
  run_empty_token +1240 "16:40"
  assert_lock_reaped
}

# Each of these would reclaim the lock if the bad input were taken at face value.
keep_when_input_is() {
  run_empty_token "$@"
  assert_lock_kept
}
keep_when_record_is() {
  RECORD_BODY="$1" run_empty_token +721 "10:00"
  assert_lock_kept
}

for spec in \
  "etime is not time|+721|bogus" \
  "etime is empty|+721|" \
  "etime has minutes out of range|+721|10:60" \
  "etime has seconds out of range|+721|10:99" \
  "etime has hours out of range|+721|25:00:00" \
  "etime is seconds only|+721|10" \
  "etime is negative|+721|-10:00" \
  "etime has too many fields|+721|1:2:3:4" \
  "etime has days without hours|+721|1-10:00" \
  "etime is longer than now|+721|99999-00:00:00"; do
  IFS='|' read -r label now etime <<< "$spec"
  bats_test_function --description "ensure-headless: empty token, $label, keeps the lock" \
    -- keep_when_input_is "$now" "$etime"
done

bats_test_function --description "ensure-headless: empty token, etime is on two lines, keeps the lock" \
  -- keep_when_input_is +721 $'10:00\n10:00'
bats_test_function --description "ensure-headless: empty token, ps fails after printing a plausible etime, keeps the lock" \
  -- keep_when_input_is +721 "10:00" T_ETIME_RC=1
bats_test_function --description "ensure-headless: empty token, date prints text, keeps the lock" \
  -- keep_when_input_is abc "10:00"
bats_test_function --description "ensure-headless: empty token, date prints nothing, keeps the lock" \
  -- keep_when_input_is "" "10:00"
bats_test_function --description "ensure-headless: empty token, date prints two lines, keeps the lock" \
  -- keep_when_input_is $'1700000721\n1700000721' "10:00"
bats_test_function --description "ensure-headless: empty token, date prints 11 digits, keeps the lock" \
  -- keep_when_input_is 17000007210 "10:00"
bats_test_function --description "ensure-headless: empty token, date fails after printing a plausible time, keeps the lock" \
  -- keep_when_input_is +721 "10:00" T_NOW_RC=1
bats_test_function --description "ensure-headless: empty token, both stat forms fail after printing a plausible mtime, keeps the lock" \
  -- keep_when_input_is +721 "10:00" T_STAT_GNU=1700000000 T_STAT_GNU_RC=1 T_STAT_BSD=1700000000 T_STAT_BSD_RC=1
bats_test_function --description "ensure-headless: empty token, both stat forms print nothing, keeps the lock" \
  -- keep_when_input_is +721 "10:00" T_STAT_GNU= T_STAT_BSD=
bats_test_function --description "ensure-headless: empty token, stat prints two lines, keeps the lock" \
  -- keep_when_input_is +721 "10:00" T_STAT_GNU=$'1700000000\n1700000000' T_STAT_BSD=$'1700000000\n1700000000'
bats_test_function --description "ensure-headless: empty token, stat prints 11 digits, keeps the lock" \
  -- keep_when_input_is +721 "10:00" T_STAT_GNU=17000000000 T_STAT_BSD=17000000000
bats_test_function --description "ensure-headless: empty token, record mtime is after now, keeps the lock" \
  -- keep_when_input_is +721 "10:00" T_STAT_GNU=1700009999 T_STAT_BSD=1700009999

bats_test_function --description "ensure-headless: empty token, GNU stat fails and BSD stat answers, judges normally" \
  -- keep_when_input_is +720 "10:00" T_STAT_GNU=1700000000 T_STAT_GNU_RC=1 T_STAT_BSD=1700000000

bats_test_function --description "ensure-headless: empty-token record without the second line keeps the lock" \
  -- keep_when_record_is '%s\n'
bats_test_function --description "ensure-headless: empty-token record without any newline keeps the lock" \
  -- keep_when_record_is '%s'
bats_test_function --description "ensure-headless: empty-token record with a third line keeps the lock" \
  -- keep_when_record_is '%s\n\nextra\n'
bats_test_function --description "ensure-headless: empty-token record with an extra blank line keeps the lock" \
  -- keep_when_record_is '%s\n\n\n'

@test "ensure-headless: GNU stat failing while BSD answers a late holder still reclaims" {
  run_empty_token +721 "10:00" T_STAT_GNU= T_STAT_GNU_RC=1 T_STAT_BSD=1700000000
  assert_lock_reaped
}

# ---- lock directory identity (#58) ----

# $1 = newline-separated ls stub answers, one per `ls -di` call
run_with_ls_answers() {
  local stub_bin="$TEST_SKILL_DIR/stub-bin"
  write_pgrep_stub miss >/dev/null
  write_spawn_stub 0
  write_clock_stubs
  printf '%b\n' "$1" > "$TEST_SKILL_DIR/ls.seq"
  PLANTED_LOCK="$TEST_SKILL_DIR/run/ensure-codex.s-sess-INO__codex.lock"
  run env PATH="$stub_bin:$PATH" CLAUDE_CODE_SESSION_ID=sess-INO \
    T_LS_SEQ="$TEST_SKILL_DIR/ls.seq" \
    bash "$SCRIPTS/ensure-headless.sh" codex "$PROJ"
}

assert_no_spawn_and_no_record() {
  [ "$status" -eq 0 ]
  [[ "$output" == *"spawn already in flight"* ]]
  [ ! -e "$TEST_SKILL_DIR/spawn.args" ]
  set -- "$PLANTED_LOCK"/owner.*
  [ ! -e "$1" ]
}

inode_not_trusted() {
  run_with_ls_answers "$1"
  assert_no_spawn_and_no_record
}

bats_test_function --description "ensure-headless: lock dir recreated after publish (different inode) withdraws the record and does not spawn" \
  -- inode_not_trusted 'REAL\nOUT:999999 x'
bats_test_function --description "ensure-headless: inode unreadable after publish does not spawn" \
  -- inode_not_trusted 'REAL\nEMPTY'
bats_test_function --description "ensure-headless: inode unreadable at mkdir does not spawn" \
  -- inode_not_trusted 'EMPTY\nEMPTY'
bats_test_function --description "ensure-headless: ls failing with a numeric inode after publish does not spawn" \
  -- inode_not_trusted 'REAL\nRC1:12345 x'
bats_test_function --description "ensure-headless: ls failing with a numeric inode at mkdir does not spawn" \
  -- inode_not_trusted 'RC1:12345 x\nRC1:12345 x'
bats_test_function --description "ensure-headless: ls printing two inodes after publish does not spawn" \
  -- inode_not_trusted 'REAL\nOUT:1 x\\n1 y'
