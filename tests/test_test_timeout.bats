#!/usr/bin/env bats

# The per-test watchdog in tests/test_helper.bash (#61). Each case runs a
# nested bats whose test hangs, under an outer hard cap, because the failure
# being guarded is "bats never returns".

load test_helper

REAL_TESTS="$BATS_TEST_DIRNAME"

setup() {
  INNER="$BATS_TEST_TMPDIR/inner.bats"
  OUT="$BATS_TEST_TMPDIR/out.txt"
  LOG="$BATS_TEST_TMPDIR/timeouts.log"
  PIDS="$BATS_TEST_TMPDIR/pids"
  : > "$PIDS"
}

teardown() {
  local p
  for p in $(cat "$PIDS" 2>/dev/null); do kill -KILL "$p" 2>/dev/null || true; done
}

# inner_header [pre-setup lines]: file preamble. Each inner test records the
# pids it leaves behind in $PIDS so the outer teardown can remove them.
inner_header() {
  cat <<EOS
load "$REAL_TESTS/test_helper"
export AGMSG_TEST_SOURCE_TEST_DIR="$REAL_TESTS"
setup() { $1; setup_test_env; echo "\$TEST_SKILL_DIR" > "$BATS_TEST_TMPDIR/skilldir"; }
teardown() { teardown_test_env; }
EOS
}

# run_inner <timeout-secs> <cap-secs>: run $INNER with output through a pipe
# (a watchdog holding it would stall the pipeline) and kill it at the cap.
# Sets ELAPSED and CAPPED=1 when the cap was hit.
run_inner() {
  local limit="$1" cap="$2" start pid
  start=$SECONDS
  { AGMSG_TEST_TIMEOUT="$limit" AGMSG_TEST_TIMEOUT_LOG="$LOG" \
      bats "$INNER" 2>&1 | cat > "$OUT"; } &
  pid=$!
  CAPPED=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ $((SECONDS - start)) -ge "$cap" ]; then
      CAPPED=1
      pkill -KILL -P "$pid" 2>/dev/null || true
      kill -KILL "$pid" 2>/dev/null || true
      break
    fi
    sleep 0.2
  done
  wait "$pid" 2>/dev/null || true
  ELAPSED=$((SECONDS - start))
}

alive() { kill -0 "$1" 2>/dev/null; }

@test "hung test body is reported not ok and the next test still runs" {
  { inner_header :; cat <<EOS
@test "hangs" { sleep 40 & echo \$! >> "$PIDS"; wait \$!; }
@test "after" { true; }
EOS
  } > "$INNER"
  run_inner 2 30
  [ "$CAPPED" -eq 0 ]
  [ "$ELAPSED" -lt 20 ]
  grep -q '^not ok 1 hangs' "$OUT"
  grep -q '^ok 2 after' "$OUT"
  grep -q 'test timeout after 2s' "$LOG"
}

@test "hung test under run (grandchild) does not stall bats past the limit" {
  { inner_header :; cat <<EOS
@test "hangs under run" { run bash -c 'sleep 40 & echo \$! >> "$PIDS"; sleep 40'; }
@test "after" { true; }
EOS
  } > "$INNER"
  run_inner 2 30
  [ "$CAPPED" -eq 0 ]
  [ "$ELAPSED" -lt 20 ]
  grep -q '^not ok 1 hangs under run' "$OUT"
  grep -q '^ok 2 after' "$OUT"
  for p in $(cat "$PIDS"); do ! alive "$p" || return 1; done
}

@test "a child that ignores TERM is KILLed after the grace period" {
  { inner_header :; cat <<EOS
@test "stubborn" { bash -c 'trap "" TERM; echo \$\$ >> "$PIDS"; while :; do sleep 1; done'; }
@test "after" { true; }
EOS
  } > "$INNER"
  run_inner 2 30
  [ "$CAPPED" -eq 0 ]
  grep -q '^ok 2 after' "$OUT"
  [ -s "$PIDS" ]
  for p in $(cat "$PIDS"); do ! alive "$p" || return 1; done
}

@test "the watchdog completes its whole sequence and is not among the processes it stops" {
  { inner_header :; cat <<EOS
@test "hangs" { sleep 40; }
EOS
  } > "$INNER"
  run_inner 2 30
  [ "$CAPPED" -eq 0 ]
  # Only the watchdog's last step removes the skill dir of a killed test.
  [ -f "$BATS_TEST_TMPDIR/skilldir" ]
  [ ! -d "$(cat "$BATS_TEST_TMPDIR/skilldir")" ]
}

@test "a child that forks while handling TERM has that fork stopped too" {
  { inner_header :; cat <<EOS
@test "forker" {
  bash -c 'trap "sleep 40 & echo \$! >> \"$PIDS.forks\"" TERM; echo \$\$ >> "$PIDS"; while :; do sleep 1; done'
}
@test "after" { true; }
EOS
  } > "$INNER"
  run_inner 2 30
  [ "$CAPPED" -eq 0 ]
  [ "$ELAPSED" -lt 20 ]
  grep -q '^ok 2 after' "$OUT"
  [ -s "$PIDS" ]
  [ -s "$PIDS.forks" ]
  cat "$PIDS.forks" >> "$PIDS"
  for p in $(cat "$PIDS"); do ! alive "$p" || return 1; done
}

@test "a test that finishes in time is not signalled and the watchdog never fires later" {
  { inner_header :; cat <<EOS
@test "quick" { sleep 0.2; }
EOS
  } > "$INNER"
  run_inner 2 30
  [ "$CAPPED" -eq 0 ]
  grep -q '^ok 1 quick' "$OUT"
  sleep 3
  [ ! -s "$LOG" ]
}

@test "a timeout:N tag overrides AGMSG_TEST_TIMEOUT" {
  { inner_header :; cat <<EOS
# bats test_tags=timeout:1
@test "tagged" { sleep 40 & echo \$! >> "$PIDS"; wait \$!; }
EOS
  } > "$INNER"
  run_inner 60 30
  [ "$CAPPED" -eq 0 ]
  grep -q '^not ok 1 tagged' "$OUT"
  grep -q 'test timeout after 1s' "$LOG"
}

@test "AGMSG_TEST_TIMEOUT=0 disables the watchdog" {
  { inner_header :; cat <<EOS
@test "slow" { sleep 3; }
EOS
  } > "$INNER"
  run_inner 0 30
  [ "$CAPPED" -eq 0 ]
  grep -q '^ok 1 slow' "$OUT"
  [ ! -s "$LOG" ]
}

@test "a fake ps and sleep earlier on PATH do not disturb the watchdog" {
  mkdir -p "$BATS_TEST_TMPDIR/fakebin"
  printf '#!/bin/sh\nexit 1\n' > "$BATS_TEST_TMPDIR/fakebin/ps"
  cp "$BATS_TEST_TMPDIR/fakebin/ps" "$BATS_TEST_TMPDIR/fakebin/sleep"
  chmod +x "$BATS_TEST_TMPDIR/fakebin/ps" "$BATS_TEST_TMPDIR/fakebin/sleep"
  { inner_header "PATH=\"$BATS_TEST_TMPDIR/fakebin:\$PATH\""; cat <<EOS
@test "hangs" { /bin/sleep 40 & echo \$! >> "$PIDS"; wait \$!; }
@test "after" { true; }
EOS
  } > "$INNER"
  run_inner 2 30
  [ "$CAPPED" -eq 0 ]
  grep -q '^not ok 1 hangs' "$OUT"
  grep -q '^ok 2 after' "$OUT"
}

@test "a recorded pid is signalled only while it still has the recorded identity" {
  _WD_PS="$(PATH=/bin:/usr/bin command -v ps)"
  sleep 40 &
  local pid=$!
  echo "$pid" >> "$PIDS"
  local ident
  ident="$(_agmsg_wd_ident "$pid")"
  [ -n "$ident" ]
  _agmsg_wd_signal KILL "$pid" "Thu Jan  1 00:00:00 1970 other"
  alive "$pid"
  _agmsg_wd_signal KILL "$pid" "$ident"
  wait "$pid" 2>/dev/null || true
  ! alive "$pid"
}
