#!/usr/bin/env bats

load test_helper

# agmsg_instance_alive reads each cc-instance file with a builtin instead of
# `$(cat ...)`. The text it compares must be what the cat form gave.

setup() {
  setup_test_env
  export SKILL_DIR="$TEST_SKILL_DIR"
  mkdir -p "$TEST_SKILL_DIR/run"
}

teardown() {
  teardown_test_env
}

_equivalence_script() {
  cat <<'SCRIPT'
. "$SKILL_DIR/scripts/lib/instance-id.sh"
d="$SKILL_DIR/run/files"
mkdir -p "$d"
bad=0
n=0
check() {   # <label>; the file $d/f is already written
  local a b
  a="$(cat "$d/f" 2>/dev/null || true)"
  _agmsg_file_text "$d/f"; b="$_AGMSG_FILE_TEXT"
  n=$((n+1))
  [ "$a" = "$b" ] || { bad=$((bad+1)); printf 'MISMATCH %s: cat=%q new=%q\n' "$1" "$a" "$b"; }
}
printf 'sid.123' > "$d/f"; check "no newline"
printf 'sid.123\n' > "$d/f"; check "one newline"
printf 'sid.123\n\n\n' > "$d/f"; check "several trailing newlines"
printf 'sid.123\nextra\n' > "$d/f"; check "two lines"
printf '\nsid.123\n' > "$d/f"; check "leading newline"
printf '  sid.123  \n' > "$d/f"; check "surrounding spaces"
printf '\tsid\t.123\t\n' > "$d/f"; check "tabs"
printf 'a\\nb\\\\c\n' > "$d/f"; check "backslashes"
printf 'sid.123\r\n' > "$d/f"; check "CRLF"
printf '' > "$d/f"; check "empty"
printf '\n' > "$d/f"; check "only a newline"
printf 'sid\0.123\n' > "$d/f"; check "NUL in the middle"
printf '\0sid.123\n' > "$d/f"; check "NUL first"
printf 'sid.123\0' > "$d/f"; check "NUL last"
printf 'caf\xc3\xa9.1\n' > "$d/f"; check "UTF-8"
printf '\xff\xfe.1\n' > "$d/f"; check "invalid UTF-8"
rm -f "$d/f"; check "missing file"
mkdir -p "$d/f"; check "directory"
echo "bash=$BASH_VERSION n=$n bad=$bad"
[ "$bad" -eq 0 ]
SCRIPT
}

@test "file text: equals the cat form for every shape of cc-instance file (default bash)" {
  run bash -c "$(_equivalence_script)"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "file text: equals the cat form under bash 3.2 as well" {
  [ -x /bin/bash ] || skip "no /bin/bash"
  case "$(/bin/bash -c 'echo "$BASH_VERSION"')" in 3.*) ;; *) skip "/bin/bash is not 3.x" ;; esac
  run /bin/bash -c "$(_equivalence_script)"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "file text: equals the cat form in a UTF-8 locale" {
  local loc
  loc="$(locale -a 2>/dev/null | grep -i -m1 'utf-\?8' || true)"
  [ -n "$loc" ] || skip "no UTF-8 locale installed"
  LC_ALL="$loc" run bash -c "$(_equivalence_script)"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "instance alive: a bare sid check over live cc-instance files starts no process" {
  sleep 300 &
  local pid=$!
  printf 'live-sid.%s\n' "$pid" > "$TEST_SKILL_DIR/run/cc-instance.$pid"
  # shellcheck disable=SC1091
  source "$SCRIPTS/lib/instance-id.sh"
  cat() { echo cat-called >&2; command cat "$@"; }
  run agmsg_instance_alive other-sid
  kill "$pid" 2>/dev/null || true
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "instance alive: verdicts for the bare and composite forms are unchanged" {
  sleep 300 &
  local pid=$!
  printf 'live-sid.%s\n' "$pid" > "$TEST_SKILL_DIR/run/cc-instance.$pid"
  # shellcheck disable=SC1091
  source "$SCRIPTS/lib/instance-id.sh"
  run agmsg_instance_alive "live-sid"
  [ "$status" -eq 0 ]
  run agmsg_instance_alive "live-sid.$pid"
  [ "$status" -eq 0 ]
  run agmsg_instance_alive "stale-sid.$pid"
  [ "$status" -eq 1 ]
  run agmsg_instance_alive "other-sid"
  [ "$status" -eq 1 ]
  kill "$pid" 2>/dev/null || true
}
