#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
  PROJ="$BATS_TEST_TMPDIR/watchdog-project"
  mkdir -p "$PROJ"
  bash "$SCRIPTS/join.sh" team alice claude-code "$PROJ" >/dev/null
  bash "$SCRIPTS/join.sh" team bob claude-code "$PROJ" >/dev/null
  STUB_BIN="$TEST_SKILL_DIR/stub-bin"
  STAT_TARGET="$TEST_SKILL_DIR/run/watchdog.team.tombstone"
  export STAT_TARGET
  mkdir -p "$STUB_BIN" "$TEST_SKILL_DIR/tmp"
  write_date_stub
  write_stat_stub
  write_watchdog_stub
  WATCH_PID=""
}

teardown() {
  if [ -n "$WATCH_PID" ]; then
    kill "$WATCH_PID" 2>/dev/null || true
    wait "$WATCH_PID" 2>/dev/null || true
  fi
  teardown_test_env
}

write_date_stub() {
  cat > "$STUB_BIN/date" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" != +%s ]; then
  exit 1
fi
n=0
if [ -f "$DATE_INDEX" ]; then
  n="$(sed -n '1p' "$DATE_INDEX")"
fi
case "$n" in ''|*[!0-9]*) n=0 ;; esac
n=$((n + 1))
printf '%s\n' "$n" > "$DATE_INDEX"
value="$(sed -n "${n}p" "$DATE_VALUES")"
[ -n "$value" ] || value="$(tail -n 1 "$DATE_VALUES")"
printf '%s\n' "$value"
if [ "${DATE_ERROR:-0}" = 1 ]; then exit 2; fi
exit 0
STUB
  chmod +x "$STUB_BIN/date"
}

write_watchdog_stub() {
  cat > "$SCRIPTS/watchdog.sh" <<'STUB'
#!/usr/bin/env bash
printf 'WATCHDOG %s\n' "$1"
printf '%s\n' "$1" >> "$TEST_SKILL_DIR/watchdog.args"
case "${WATCHDOG_MODE:-ok}" in
  fail) exit 17 ;;
  sleep) sleep 3 ;;
esac
STUB
  chmod +x "$SCRIPTS/watchdog.sh"
}

write_stat_stub() {
  cat > "$STUB_BIN/stat" <<'STUB'
#!/usr/bin/env bash
if [ "$#" -ne 3 ] || [ "$3" != "${STAT_TARGET:?}" ]; then
  exit 97
fi
case "$1:$2" in
  -f:%m|-c:%Y) ;;
  *) exit 97 ;;
esac
printf '%s\n' "${STAT_MTIME:?}"
printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "${STAT_CALLED:?}"
if [ "${STAT_ERROR:-0}" = 1 ]; then exit 2; fi
exit 0
STUB
  chmod +x "$STUB_BIN/stat"
}

set_dates() {
  printf '%s\n' "$@" > "$TEST_SKILL_DIR/date.values"
  : > "$TEST_SKILL_DIR/date.index"
}

start_watcher() {
  local sid="$1" out="$2" err="$3"
  local controlled_bash_env="${WATCH_BASH_ENV:-}"
  env -i \
    HOME="$HOME" TMPDIR="$TEST_SKILL_DIR/tmp" \
    TEST_SKILL_DIR="$TEST_SKILL_DIR" \
    DATE_VALUES="$TEST_SKILL_DIR/date.values" \
    DATE_INDEX="$TEST_SKILL_DIR/date.index" \
    DATE_ERROR="${DATE_ERROR:-0}" \
    STAT_TARGET="$STAT_TARGET" STAT_MTIME="${STAT_MTIME:-}" \
    STAT_CALLED="${STAT_CALLED:-}" STAT_ERROR="${STAT_ERROR:-0}" \
    WATCHDOG_MODE="${WATCHDOG_MODE:-ok}" \
    REAL_GREP="${REAL_GREP:-}" \
    AGMSG_WATCHDOG_GREP_ERROR="${AGMSG_WATCHDOG_GREP_ERROR:-0}" \
    AGMSG_WATCHDOG_READ_ERROR="${AGMSG_WATCHDOG_READ_ERROR:-0}" \
    PATH="$STUB_BIN:$PATH" TZ=UTC LC_ALL=C AGMSG_WATCH_INTERVAL=1 \
    BASH_ENV="$controlled_bash_env" \
    bash "$SCRIPTS/watch.sh" "$sid" "$PROJ" claude-code --team team \
      >"$out" 2>"$err" 3>&- &
  WATCH_PID=$!
}

stop_watcher() {
  kill "$WATCH_PID" 2>/dev/null || true
  wait "$WATCH_PID" 2>/dev/null || true
  WATCH_PID=""
}

watchdog_count() {
  grep -c '^WATCHDOG team$' "$1" 2>/dev/null || true
}

wait_for_stat_calls() {
  wait_until 10 file_line_count_at_least "$1" "$2"
}

file_line_count_at_least() {
  local path="$1" expected="$2" count=0
  [ -f "$path" ] || return 1
  count="$(wc -l <"$path" | tr -d ' ')"
  [ "$count" -ge "$expected" ]
}

numeric_file_at_least() {
  local path="$1" expected="$2" value
  [ -f "$path" ] || return 1
  value="$(sed -n '1p' "$path")"
  case "$value" in ''|*[!0-9]*) return 1 ;; esac
  [ "$value" -ge "$expected" ]
}

watchdog_count_at_least() {
  [ "$(watchdog_count "$1")" -ge "$2" ]
}

@test "watchdog: default interval launches immediately once and uses own team" {
  set_dates 100 100 100
  local out="$TEST_SKILL_DIR/out" err="$TEST_SKILL_DIR/err"
  start_watcher default "$out" "$err"
  wait_for_file_contains "$out" "WATCHDOG team"
  wait_until 3 numeric_file_at_least "$TEST_SKILL_DIR/date.index" 2
  stop_watcher

  [ "$(watchdog_count "$out")" -eq 1 ]
  [ "$(cat "$TEST_SKILL_DIR/watchdog.args")" = team ]
}

@test "watchdog: configured interval fires below, at, and above the boundary" {
  bash "$SCRIPTS/config.sh" set watchdog.interval_s 10 >/dev/null
  set_dates 100 109 110 121
  local out="$TEST_SKILL_DIR/out" err="$TEST_SKILL_DIR/err"
  start_watcher boundary "$out" "$err"
  wait_until 5 watchdog_count_at_least "$out" 3
  stop_watcher

  [ "$(watchdog_count "$out")" -eq 3 ]
}

@test "watchdog: invalid and zero intervals fall back without a busy loop" {
  bash "$SCRIPTS/config.sh" set watchdog.interval_s invalid >/dev/null
  set_dates 100 100 100
  local out="$TEST_SKILL_DIR/out" err="$TEST_SKILL_DIR/err"
  start_watcher invalid "$out" "$err"
  wait_for_file_contains "$out" "WATCHDOG team"
  wait_until 3 numeric_file_at_least "$TEST_SKILL_DIR/date.index" 2
  stop_watcher

  [ "$(watchdog_count "$out")" -eq 1 ]
  [ "$(cat "$TEST_SKILL_DIR/date.index")" -le 3 ]

  bash "$SCRIPTS/config.sh" set watchdog.interval_s 0 >/dev/null
  : > "$TEST_SKILL_DIR/watchdog.args"
  set_dates 200 200 200
  start_watcher zero "$out" "$err"
  wait_for_file_contains "$out" "WATCHDOG team"
  wait_until 3 numeric_file_at_least "$TEST_SKILL_DIR/date.index" 2
  stop_watcher
  [ "$(watchdog_count "$out")" -eq 1 ]
  [ "$(cat "$TEST_SKILL_DIR/date.index")" -le 3 ]
}

@test "watchdog: background failure does not block message polling and stdout propagates" {
  bash "$SCRIPTS/config.sh" set watchdog.interval_s 60 >/dev/null
  set_dates 100 100
  local out="$TEST_SKILL_DIR/out" err="$TEST_SKILL_DIR/err"
  WATCHDOG_MODE=fail start_watcher failure "$out" "$err"
  wait_for_file_contains "$out" "WATCHDOG team"
  bash "$SCRIPTS/send.sh" team bob alice "watchdog-follow-up" >/dev/null
  wait_for_file_contains "$out" "watchdog-follow-up"
  stop_watcher

  grep -q '^WATCHDOG team$' "$out"
  grep -q "watchdog-follow-up" "$out"
}

@test "watchdog: a slow background run does not delay the poll loop" {
  bash "$SCRIPTS/config.sh" set watchdog.interval_s 60 >/dev/null
  set_dates 100 100
  local out="$TEST_SKILL_DIR/out" err="$TEST_SKILL_DIR/err"
  WATCHDOG_MODE=sleep start_watcher slow "$out" "$err"
  wait_for_file_contains "$out" "WATCHDOG team"
  bash "$SCRIPTS/send.sh" team bob alice "while-watchdog-runs" >/dev/null
  wait_for_file_contains "$out" "while-watchdog-runs"
  stop_watcher
}

@test "watchdog: a fresh valid tombstone suppresses launch" {
  local now=1609459201 mtime=1609459000 age
  age=$((now - mtime))
  [ "$now" -ge "$mtime" ]
  [ "$age" -ge 0 ]
  [ "$age" -le 600 ]
  set_dates "$now" "$((now + 60))" "$((now + 120))"
  mkdir -p "$TEST_SKILL_DIR/run"
  printf 'session-end-owner\n' > "$TEST_SKILL_DIR/run/watchdog.team.tombstone"
  export STAT_MTIME="$mtime" STAT_CALLED="$TEST_SKILL_DIR/stat-called"
  date() { printf '999\n'; }
  stat() { printf '91\n'; }
  export -f date stat
  export TZ=America/Los_Angeles
  local out="$TEST_SKILL_DIR/out" err="$TEST_SKILL_DIR/err"
  start_watcher tombstone "$out" "$err"
  # Reaching the second exact mtime query proves the first loop completed the
  # freshness decision without launching watchdog; this avoids a startup-speed
  # race while still proving suppression came from the production age source.
  wait_for_stat_calls "$STAT_CALLED" 2 || {
    printf 'watch stderr:\n' >&2
    sed -n '1,120p' "$err" >&2
    printf 'watch stdout:\n' >&2
    sed -n '1,120p' "$out" >&2
    printf 'date index: ' >&2
    sed -n '1p' "$TEST_SKILL_DIR/date.index" >&2
    return 1
  }
  stop_watcher

  [ ! -s "$TEST_SKILL_DIR/watchdog.args" ]
  [ -f "$STAT_CALLED" ]
  awk -F '\t' -v target="$STAT_TARGET" '
    (($1 == "-f" && $2 == "%m") || ($1 == "-c" && $2 == "%Y")) &&
      $3 == target { valid++ }
    END { exit(valid >= 2 ? 0 : 1) }
  ' "$STAT_CALLED"
  ! grep -q "WATCHDOG team" "$out"
}

@test "watchdog: a future tombstone fails open independently" {
  local now=1609459201 mtime=1609462800
  [ "$mtime" -gt "$now" ]
  local out="$TEST_SKILL_DIR/out" err="$TEST_SKILL_DIR/err"
  set_dates "$now" "$now" "$now"
  mkdir -p "$TEST_SKILL_DIR/run"
  printf 'session-end-owner\n' > "$TEST_SKILL_DIR/run/watchdog.team.tombstone"
  export STAT_MTIME="$mtime" STAT_CALLED="$TEST_SKILL_DIR/stat-called"
  rm -f "$TEST_SKILL_DIR/watchdog.args"
  start_watcher future "$out" "$err"
  wait_for_file "$TEST_SKILL_DIR/watchdog.args"
  stop_watcher
  [ -f "$STAT_CALLED" ]
  [ "$(cat "$TEST_SKILL_DIR/watchdog.args")" = team ]
}

@test "watchdog: FIFO, symlink, and directory tombstones fail open without blocking" {
  command -v mkfifo >/dev/null 2>&1 || skip "mkfifo is unavailable in this environment"
  local tombstone="$TEST_SKILL_DIR/run/watchdog.team.tombstone"
  local target="$TEST_SKILL_DIR/run/tombstone-target"
  local out="$TEST_SKILL_DIR/out" err="$TEST_SKILL_DIR/err"
  set_dates 100 100 100
  mkdir -p "$TEST_SKILL_DIR/run"

  mkfifo "$tombstone" || skip "FIFO creation is unavailable in this environment"
  rm -f "$TEST_SKILL_DIR/watchdog.args"
  start_watcher fifo "$out" "$err"
  wait_for_file "$TEST_SKILL_DIR/watchdog.args"
  stop_watcher

  rm -f "$tombstone"
  printf 'owner\n' > "$target"
  ln -s "$target" "$tombstone"
  rm -f "$TEST_SKILL_DIR/watchdog.args"
  start_watcher symlink "$out" "$err"
  wait_for_file "$TEST_SKILL_DIR/watchdog.args"
  stop_watcher

  rm -f "$tombstone"
  mkdir "$tombstone"
  rm -f "$TEST_SKILL_DIR/watchdog.args"
  start_watcher directory "$out" "$err"
  wait_for_file "$TEST_SKILL_DIR/watchdog.args"
  stop_watcher
}

@test "watchdog: oversized regular tombstone is bounded and fails open" {
  local tombstone="$TEST_SKILL_DIR/run/watchdog.team.tombstone"
  local out="$TEST_SKILL_DIR/out" err="$TEST_SKILL_DIR/err"
  mkdir -p "$TEST_SKILL_DIR/run"
  set_dates 100 100 100
  printf '%*s' 10000 '' | tr ' ' A > "$tombstone"
  export STAT_MTIME=100 STAT_CALLED="$TEST_SKILL_DIR/stat-called"
  rm -f "$TEST_SKILL_DIR/watchdog.args"
  start_watcher oversized "$out" "$err"
  wait_for_file "$TEST_SKILL_DIR/watchdog.args"
  stop_watcher
  [ ! -e "$STAT_CALLED" ]
}

@test "watchdog: NUL bytes are rejected before shell read normalization" {
  local tombstone="$TEST_SKILL_DIR/run/watchdog.team.tombstone"
  local out="$TEST_SKILL_DIR/out" err="$TEST_SKILL_DIR/err"
  mkdir -p "$TEST_SKILL_DIR/run"
  set_dates 100 100 100
  printf 'owner\0\n' > "$tombstone"
  export STAT_MTIME=100 STAT_CALLED="$TEST_SKILL_DIR/stat-called"
  rm -f "$TEST_SKILL_DIR/watchdog.args"
  start_watcher nul "$out" "$err"
  wait_for_file "$TEST_SKILL_DIR/watchdog.args"
  stop_watcher
  [ ! -e "$STAT_CALLED" ]
}

@test "watchdog: raw-byte grep errors fail open" {
  local tombstone="$TEST_SKILL_DIR/run/watchdog.team.tombstone"
  local out="$TEST_SKILL_DIR/out" err="$TEST_SKILL_DIR/err"
  local real_grep
  real_grep="$(command -v grep)"
  cat > "$STUB_BIN/grep" <<'STUB'
#!/usr/bin/env bash
if [ "${AGMSG_WATCHDOG_GREP_ERROR:-0}" = 1 ] && [ "${2:-}" = '(^|[[:space:]])00([[:space:]]|$)' ]; then
  exit 2
fi
exec "$REAL_GREP" "$@"
STUB
  chmod +x "$STUB_BIN/grep"
  mkdir -p "$TEST_SKILL_DIR/run"
  set_dates 100 100 100
  printf 'owner\n' > "$tombstone"
  export REAL_GREP="$real_grep" AGMSG_WATCHDOG_GREP_ERROR=1
  export STAT_MTIME=100 STAT_CALLED="$TEST_SKILL_DIR/stat-called"
  rm -f "$TEST_SKILL_DIR/watchdog.args"
  start_watcher grep-error "$out" "$err"
  wait_for_file "$TEST_SKILL_DIR/watchdog.args"
  stop_watcher
  [ ! -e "$STAT_CALLED" ]
}

@test "watchdog: bounded read errors fail open" {
  local tombstone="$TEST_SKILL_DIR/run/watchdog.team.tombstone"
  local out="$TEST_SKILL_DIR/out" err="$TEST_SKILL_DIR/err"
  local read_env="$TEST_SKILL_DIR/read-error-env.sh"
  cat > "$read_env" <<'STUB'
read() {
  if [ "${AGMSG_WATCHDOG_READ_ERROR:-0}" = 1 ] &&
    [ "${1:-}" = -r ] && [ "${2:-}" = -n ] &&
    [ "${3:-}" = 1 ] && [ "${4:-}" = extra ]; then
    return 2
  fi
  builtin read "$@"
}
STUB
  mkdir -p "$TEST_SKILL_DIR/run"
  set_dates 100 100 100
  printf 'owner\n' > "$tombstone"
  export WATCH_BASH_ENV="$read_env" AGMSG_WATCHDOG_READ_ERROR=1
  export STAT_MTIME=100 STAT_CALLED="$TEST_SKILL_DIR/stat-called"
  rm -f "$TEST_SKILL_DIR/watchdog.args"
  start_watcher read-error "$out" "$err"
  wait_for_file "$TEST_SKILL_DIR/watchdog.args"
  stop_watcher
  [ ! -e "$STAT_CALLED" ]
}

@test "watchdog: numeric mtime with stat error fails open" {
  local tombstone="$TEST_SKILL_DIR/run/watchdog.team.tombstone"
  local out="$TEST_SKILL_DIR/out" err="$TEST_SKILL_DIR/err"
  mkdir -p "$TEST_SKILL_DIR/run"
  set_dates 100 100 100
  printf 'owner\n' > "$tombstone"
  export STAT_MTIME=100 STAT_CALLED="$TEST_SKILL_DIR/stat-called" STAT_ERROR=1
  rm -f "$TEST_SKILL_DIR/watchdog.args"
  start_watcher stat-error "$out" "$err"
  wait_for_file "$TEST_SKILL_DIR/watchdog.args"
  stop_watcher
  [ -f "$STAT_CALLED" ]
}

@test "watchdog: numeric date with date error fails open" {
  local out="$TEST_SKILL_DIR/out" err="$TEST_SKILL_DIR/err"
  set_dates 100 100 100
  mkdir -p "$TEST_SKILL_DIR/run"
  printf 'owner\n' > "$TEST_SKILL_DIR/run/watchdog.team.tombstone"
  export DATE_ERROR=1
  rm -f "$TEST_SKILL_DIR/watchdog.args"
  start_watcher date-error-numeric "$out" "$err"
  wait_for_file "$TEST_SKILL_DIR/watchdog.args"
  stop_watcher
}

@test "watchdog: empty and malformed tombstones fail open" {
  local out="$TEST_SKILL_DIR/out" err="$TEST_SKILL_DIR/err"
  set_dates 100 100 100
  mkdir -p "$TEST_SKILL_DIR/run"
  : > "$TEST_SKILL_DIR/run/watchdog.team.tombstone"
  start_watcher empty "$out" "$err"
  wait_for_file_contains "$out" "WATCHDOG team"
  stop_watcher

  rm -f "$TEST_SKILL_DIR/watchdog.args"
  set_dates 100 100 100
  printf 'owner\nother\n' > "$TEST_SKILL_DIR/run/watchdog.team.tombstone"
  start_watcher malformed "$out" "$err"
  wait_for_file_contains "$out" "WATCHDOG team"
  stop_watcher
  [ "$(grep -c '^WATCHDOG team$' "$out")" -ge 1 ]

  rm -f "$TEST_SKILL_DIR/watchdog.args"
  : > "$TEST_SKILL_DIR/date.values"
  : > "$TEST_SKILL_DIR/date.index"
  rm -f "$TEST_SKILL_DIR/run/watchdog.team.tombstone"
  start_watcher date-error "$out" "$err"
  wait_for_file "$TEST_SKILL_DIR/watchdog.args"
  stop_watcher
}

@test "watchdog: unreadable and expired tombstones fail open" {
  local now=1609459201 mtime=1609455600 age
  age=$((now - mtime))
  [ "$now" -ge "$mtime" ]
  [ "$age" -ge 0 ]
  [ "$age" -gt 600 ]
  local out="$TEST_SKILL_DIR/out" err="$TEST_SKILL_DIR/err"
  set_dates "$now" "$now" "$now"
  mkdir -p "$TEST_SKILL_DIR/run"
  printf 'owner\n' > "$TEST_SKILL_DIR/run/watchdog.team.tombstone"
  chmod 000 "$TEST_SKILL_DIR/run/watchdog.team.tombstone"
  start_watcher unreadable "$out" "$err"
  wait_for_file_contains "$out" "WATCHDOG team"
  stop_watcher

  chmod 644 "$TEST_SKILL_DIR/run/watchdog.team.tombstone"
  rm -f "$TEST_SKILL_DIR/watchdog.args"
  export STAT_MTIME="$mtime" STAT_CALLED="$TEST_SKILL_DIR/stat-called"
  printf 'owner\n' > "$TEST_SKILL_DIR/run/watchdog.team.tombstone"
  rm -f "$out" "$err"
  start_watcher expired "$out" "$err"
  wait_for_file "$TEST_SKILL_DIR/watchdog.args"
  stop_watcher
  [ -f "$STAT_CALLED" ]
  [ "$(cat "$TEST_SKILL_DIR/watchdog.args")" = team ]
}

@test "watchdog: backward wall-clock jump resets the baseline" {
  bash "$SCRIPTS/config.sh" set watchdog.interval_s 10 >/dev/null
  set_dates 100 95 104 105
  local out="$TEST_SKILL_DIR/out" err="$TEST_SKILL_DIR/err"
  start_watcher backward "$out" "$err"
  wait_until 5 watchdog_count_at_least "$out" 2
  stop_watcher

  [ "$(watchdog_count "$out")" -eq 2 ]
}
